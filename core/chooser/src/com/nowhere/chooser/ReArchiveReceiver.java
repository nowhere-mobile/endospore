package com.nowhere.chooser;

import android.app.AlarmManager;
import android.app.AppOpsManager;
import android.app.PendingIntent;
import android.app.role.RoleManager;
import android.app.usage.UsageStats;
import android.app.usage.UsageStatsManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.os.Process;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicLong;

/**
 * On-demand apps (#206): time-based reclaim. A materialised on-demand app the user hasn't opened for a while is
 * RE-ARCHIVED (back to a placeholder icon) to free device storage. Its APK bytes still live in the sealed
 * name#apps head (leased), so a later tap re-fetches it -- the only cost of a too-eager re-archive is a
 * re-download. Under amnesia everything wipes at logoff anyway, so this only reclaims space WITHIN a long session.
 *
 * Runs in the ROAMED user: usage stats + archiving are per-user, and the chooser is the installer of record for a
 * materialised on-demand app, so requestArchive() is permitted. {@link UnarchiveService} arms the chain right after
 * a tap's materialise, which is the only thing that creates a reclaimable app. The chain then self-re-arms on a
 * ~hourly alarm. A user stop kills the alarm: at logoff that is the end, but a cold lock stops the user too, and
 * the resume does not restart the alarm. So the post-seal claims kick ({@link CredentialService}) keeps the chain
 * armed through {@link #keepArmed} (NWP-20261120-12). An offline session gets no claims kick; its next tap re-arms.
 * A re-arm never moves a pending sweep later ({@link ReArchiveGate#armAt}), so frequent taps cannot postpone it.
 * The sweep keeps an app that holds a job ({@link ReArchiveGate#holdsJob}: the current keyboard, the always-on VPN,
 * an enabled accessibility service or notification listener, a role holder), and archives nothing in a sweep that
 * cannot read one of those sources (h51 #6, NWP-20261122-10). {@link #freeNow} is "Free on this phone": the user
 * frees one app now, under the same job guards and with no idle threshold (h51 #4 B2, NWP-20261125-11).
 */
public class ReArchiveReceiver extends BroadcastReceiver {
    static final String ACTION = "com.nowhere.chooser.REARCHIVE_SWEEP";
    static final long CHECK_MS = 60 * 60 * 1000L;      // sweep about hourly
    private static final long USAGE_WINDOW_MS = 7L * 24 * 60 * 60 * 1000L;
    // The Settings.Secure keys a job lives in, in holdsJob's order (h51 #6). always_on_vpn_app is a hidden key, so
    // all four are literals.
    private static final String[] JOB_KEYS = { "default_input_method", "always_on_vpn_app",
            "enabled_accessibility_services", "enabled_notification_listeners" };
    // The roles whose holder works without being opened. NOTES and WALLET by their string names.
    private static final String[] JOB_ROLES = { RoleManager.ROLE_SMS, RoleManager.ROLE_DIALER,
            RoleManager.ROLE_BROWSER, RoleManager.ROLE_HOME, RoleManager.ROLE_ASSISTANT,
            RoleManager.ROLE_CALL_SCREENING, RoleManager.ROLE_CALL_REDIRECTION, RoleManager.ROLE_EMERGENCY,
            "android.app.role.NOTES", "android.app.role.WALLET" };
    // The pending sweep's due time, 0 = none known. Process-lifetime on purpose: a user stop (logoff or cold lock)
    // kills this process and drops the user's alarms, so a resumed session rightly starts at 0.
    private static final AtomicLong DUE = new AtomicLong(0L);

    @Override
    public void onReceive(Context ctx, Intent intent) {
        try {
            sweep(ctx);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "rearchive sweep", t);
        } finally {
            // Keep the chain alive until a user stop cancels it. Re-arm even on an empty sweep: a NEW app may be
            // materialised. The alarm that fired is no longer pending, so clear its due time first, else arm
            // could keep it and the chain would stop here.
            DUE.set(0L);
            arm(ctx, System.currentTimeMillis() + CHECK_MS);
        }
    }

    private void sweep(Context ctx) {
        Set<String> od = ProfileActivity.ondemandKeepSet(ctx);
        if (od.isEmpty()) return;
        grantUsageStats(ctx);
        UsageStatsManager usm = ctx.getSystemService(UsageStatsManager.class);
        // ⚠ THIS SWEEP HAS BEEN RUNNING BLIND, and it could not tell anyone. Until NWP-20260912-06 the
        // chooser had no service_manager find on usagestats_service, so this returned NULL and the map
        // below was empty on every sweep -- and the materialise floor in `ReArchiveGate.archive` further down
        // then made the predicate collapse to materialise-age alone, with no log, no exception and no
        // behavioural tell. A feature deciding what to ARCHIVE deserves to say when its input is missing.
        if (usm == null) {
            android.util.Log.w("NowhereChooser",
                    "rearchive: NO UsageStatsManager -- archiving on materialise age alone");
        }
        PackageManager pm = ctx.getPackageManager();
        long now = System.currentTimeMillis();
        long idle = idleMs(ctx);
        if (idle <= 0) return; // #206: this profile set reclaim to Never -- keep every materialised app until logoff
        // h51 #6: an app can work without being opened. Read who holds a job ONCE, and archive nothing when any
        // source cannot be read: a keyboard or a VPN that loses its APK fails mid-session, a skipped sweep costs
        // nothing (onReceive re-arms the next one).
        String[] jobs = new String[JOB_KEYS.length];
        Set<String> roles = new HashSet<>();
        String failed = readJobs(ctx, jobs, roles);
        if (failed != null) {
            android.util.Log.w("NowhereChooser", "rearchive: job source " + failed
                    + " unreadable -- archiving nothing this sweep");
            return;
        }
        Map<String, UsageStats> stats = usm != null
                ? usm.queryAndAggregateUsageStats(now - USAGE_WINDOW_MS, now)
                : Collections.emptyMap();
        for (String pkg : od) {
            try {
                // getApplicationInfo (no MATCH_ARCHIVED_PACKAGES) throws for an archived/absent app -> only a
                // currently-installed (materialised) app has local APK bytes to reclaim.
                pm.getApplicationInfo(pkg, 0);
                long lastUsed = 0L, lastVisible = 0L, lastFgs = 0L;
                UsageStats s = stats.get(pkg);
                if (s != null) {
                    lastUsed = s.getLastTimeUsed();
                    lastVisible = s.getLastTimeVisible();
                    lastFgs = s.getLastTimeForegroundServiceUsed();
                }
                // Floor the "last active" at the (re)install time so a freshly materialised app that hasn't been
                // foregrounded yet is NOT re-archived on the very next sweep. lastUpdateTime is the materialise
                // time (install-over-placeholder), which is what we want -- firstInstallTime can predate archiving.
                // The max of the four times (on screen, visible, foreground service, materialise) is
                // ReArchiveGate.archive's.
                long lastUpdate = 0L;
                try { lastUpdate = pm.getPackageInfo(pkg, 0).lastUpdateTime; } catch (Throwable ignore) {}
                boolean job = ReArchiveGate.holdsJob(pkg, jobs[0], jobs[1], jobs[2], jobs[3], roles);
                if (job) android.util.Log.i("NowhereChooser", "rearchive keep " + pkg + ": holds a job");
                if (!ReArchiveGate.archive(now, idle, lastUsed, lastVisible, lastFgs, lastUpdate, job)) {
                    continue; // holds a job, or used/materialised recently -> keep
                }
                archive(ctx, pkg);
            } catch (PackageManager.NameNotFoundException e) {
                // already a placeholder (or gone) -> nothing to reclaim
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "rearchive " + pkg, t);
            }
        }
    }

    /** The job sources, read once per sweep in this (roamed) user: the four JOB_KEYS into settings, in order, and
     *  every JOB_ROLES holder into roles. Same-user getRoleHolders, as PermDeclines does (not getRoleHoldersAsUser).
     *  A role this build does not define is skipped, as PermDeclines skips it. Null when every source was read;
     *  else the name of the first that failed (a settings key, a role, or RoleManager), never a package. A null
     *  setting or an empty holder list is a read, not a failure. */
    private static String readJobs(Context ctx, String[] settings, Set<String> roles) {
        android.content.ContentResolver cr = ctx.getContentResolver();
        for (int i = 0; i < JOB_KEYS.length; i++) {
            try {
                settings[i] = android.provider.Settings.Secure.getString(cr, JOB_KEYS[i]);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "rearchive: read " + JOB_KEYS[i], t);
                return JOB_KEYS[i];
            }
        }
        RoleManager rm;
        try {
            rm = ctx.getSystemService(RoleManager.class);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "rearchive: RoleManager", t);
            return "RoleManager";
        }
        if (rm == null) return "RoleManager";
        for (String role : JOB_ROLES) {
            try {
                if (!rm.isRoleAvailable(role)) continue;
                List<String> h = rm.getRoleHolders(role);
                if (h != null) roles.addAll(h);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "rearchive: read role " + role, t);
                return role;
            }
        }
        return null;
    }

    /** Re-archive pkg: the framework drops its APK, keeps the archived placeholder (icon + launcher metadata), and
     *  a later tap re-runs the on-demand unarchive. We are the installer of record, so this is permitted. */
    private static boolean archive(Context ctx, String pkg) {
        return archive(ctx, pkg, "idle reclaim");
    }

    /** archive, with why in its log line: the sweep's "(idle reclaim)" line stays the sweep's own. False when
     *  requestArchive threw. */
    private static boolean archive(Context ctx, String pkg, String why) {
        try {
            Intent st = new Intent(ctx.getPackageName() + ".REARCHIVE_STATUS").setPackage(ctx.getPackageName());
            PendingIntent pi = PendingIntent.getBroadcast(ctx, pkg.hashCode(), st,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            ctx.getPackageManager().getPackageInstaller().requestArchive(pkg, pi.getIntentSender());
            android.util.Log.i("NowhereChooser", "rearchive requested " + pkg + " (" + why + ")");
            return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "requestArchive " + pkg, t);
            return false;
        }
    }

    /** "Free on this phone" (h51 #4 B2, NWP-20261125-11): archive pkg NOW, under the sweep's own guards. It reads
     *  the job sources once, and archives only when every source was read and pkg holds no job. No usage-time
     *  check: the user asked now. Runs on the caller's worker thread and never throws. Returns the verdict: "ok"
     *  (requested), "job", "unread", or "failed" (requestArchive threw). */
    static String freeNow(Context ctx, String pkg) {
        try {
            String[] jobs = new String[JOB_KEYS.length];
            Set<String> roles = new HashSet<>();
            String failed = readJobs(ctx, jobs, roles);
            String v = FreeOnPhone.verdict(failed, failed == null
                    && ReArchiveGate.holdsJob(pkg, jobs[0], jobs[1], jobs[2], jobs[3], roles));
            if ("ok".equals(v)) {
                if (!archive(ctx, pkg, "free on this phone")) v = "failed";
            }
            if (!"ok".equals(v)) {
                android.util.Log.i("NowhereChooser", "rearchive free-now " + pkg + ": not freed (" + v + ")");
            }
            return v;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "rearchive free-now " + pkg, t);
            return "failed";
        }
    }

    /** UsageStatsManager needs GET_USAGE_STATS; the chooser holds MANAGE_APP_OPS_MODES, so self-grant it
     *  (idempotent) -- the same pattern the WAP-push + restricted-messages ops use elsewhere in the chooser. */
    static void grantUsageStats(Context ctx) {
        try {
            AppOpsManager ao = ctx.getSystemService(AppOpsManager.class);
            if (ao != null) {
                int op = AppOpsManager.strOpToOp(AppOpsManager.OPSTR_GET_USAGE_STATS);
                ao.setUidMode(op, Process.myUid(), AppOpsManager.MODE_ALLOWED);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "grant usagestats", t);
        }
    }

    /** The idle threshold in ms (0 = Never, disabled). Source of truth is the PER-PROFILE setting the "Your apps"
     *  screen writes (ProfileActivity.reclaimIdleMs, roams with the profile). A dev/test override still wins:
     *  `settings put global nowhere.rearchive_idle_ms N` (chooser holds WRITE_SECURE_SETTINGS). */
    private static long idleMs(Context ctx) {
        long v = 0L;
        try {
            v = android.provider.Settings.Global.getLong(
                    ctx.getContentResolver(), "nowhere.rearchive_idle_ms", 0L);
        } catch (Throwable ignore) {}
        return ReArchiveGate.effectiveIdle(v, ProfileActivity.reclaimIdleMs(ctx));
    }

    /** (Re)schedule the next sweep. Package-visible so UnarchiveService can arm the first one after a materialise.
     *  Setting a time for the one PendingIntent REPLACES the pending alarm, so this keeps an earlier pending sweep
     *  ({@link ReArchiveGate#armAt}) and records a new due time only after the set returned. Synchronized: the
     *  receiver, UnarchiveService's worker and the claims worker all call it. */
    static synchronized void arm(Context ctx, long whenMs) {
        try {
            long at = ReArchiveGate.armAt(DUE.get(), System.currentTimeMillis(), whenMs);
            if (at == DUE.get() && at > 0) return; // an earlier sweep is already pending: keep it
            AlarmManager am = ctx.getSystemService(AlarmManager.class);
            if (am == null) return;
            Intent i = new Intent(ctx, ReArchiveReceiver.class).setAction(ACTION);
            PendingIntent pi = PendingIntent.getBroadcast(ctx, 0, i,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            am.setAndAllowWhileIdle(AlarmManager.RTC, at, pi);
            DUE.set(at);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "arm rearchive", t);
        }
    }

    /** Re-arm the sweep after a cold-lock resume. The post-seal claims kick (CredentialService) calls this after
     *  every periodic seal; while a sweep is pending it changes nothing (arm keeps the earlier one). No on-demand
     *  app means nothing to reclaim: a tap's materialise arms the chain then. Never throws. */
    static void keepArmed(Context ctx) {
        try {
            if (ProfileActivity.ondemandKeepSet(ctx).isEmpty()) return;
            arm(ctx, System.currentTimeMillis() + CHECK_MS);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "keep rearchive armed", t);
        }
    }
}
