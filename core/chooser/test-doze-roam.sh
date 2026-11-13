#!/usr/bin/env bash
# test-doze-roam.sh [--mutate] -- a profile's own battery-Unrestricted (Doze) choices roam per profile, and only the
# user-0 gate ever removes them (NWP-20261002-02, NWP-20261002-03; route 2 of docs/product-decisions.md 2026-10-02).
#
# WHY COMMITTED. The Doze allow-list is device-wide and keyed name->appId, and a login reinstalls an app under a new
# appId, so a user's "Unrestricted" choice silently stops taking effect. Route 2 records the profile's own
# non-curated choices (the session ONLY records) at logoff AND live during the session -- the user-0 gate relays an
# allow-list change to DozeCaptureReceiver in the armed session, so a periodic seal carries a choice made in a session
# that later ends in a cold lock -- seals them WITH the profile, and the user-0 gate re-applies them by current appId
# at that profile's next login after RESETTING the list's user-installed part to that profile's set (dropForeign),
# arming the live record only on a strict read and a reset that held. The gate is the only remover: it drops a
# profile's choices when that profile's USER is removed (ACTION_USER_REMOVED -> sweepDeparted). NWP-20261002-03
# exists because -02 removed at logoff, before the outcome was known: a logoff that failed and kept the session
# signed in (#86) left it de-exempted, and a retry then sealed an EMPTY set. Every piece is silent when broken. So
# every Java method and call site, the receiver and its manifest entry, the strict daemon read, the daemon
# dispatch and handler, the offline truncation and the worker surfacing are pinned BYTE FOR BYTE, call sites and the
# truncations with neighbouring lines (a dead-code wrap of the call line alone, or a move, is caught); the login apply
# must precede the switchToUser( call; call sites are counted, method references included (as
# `DozeAppsMirror::name`, whitespace allowed), with comments stripped in one string-aware pass rather than whole lines
# skipped (so a wrapper after a one-line javadoc, or after a `//` inside a string, counts); the surfaced file and the
# daemon verb have exact-count controls in main.go and across every non-test file of the agent package, and the
# manifest entry one of its own (no second writer, dispatch or declaration); and the tree-wide rule "only
# ChooserActivity (exactly 2, both in ensurePushDozeFor: route 1's pass and route 2's re-bind / absent branch) and
# DozeAppsMirror (exactly 2: sweep, drop) call removeFromPermanentAllowList" is checked with exact counts, its own
# control. --mutate also runs must-stay-GREEN probes, so a check that fails on a harmless edit is caught too.
# Deliberately NOT chased: a removal spelled through another API (reflection, IDeviceIdleController, a shell
# command), and a call or method reference spelled any other way (a space around the `.`, a static import, a split
# line). A rule keyed on spellings never converges -- each new spelling needs a new pattern -- so the guard is the byte
# pin on every method and call site, plus review.
#
#   bash test-doze-roam.sh            # the invariants
#   bash test-doze-roam.sh --mutate   # ... plus mutations that must each CONVICT the checks
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
D="$(dirname "$0")"
SRC="$D/src/com/nowhere/chooser"
ACT="$SRC/ChooserActivity.java"
DM="$SRC/DozeAppsMirror.java"
PROF="$SRC/ProfileActivity.java"
REL="$SRC/ReloginReceiver.java"
NAPP="$SRC/NowhereApp.java"
IDLE="$SRC/IdleLogoffReceiver.java"
RCV="$SRC/DozeCaptureReceiver.java"
DS="$SRC/DaemonSocket.java"
MAN="$D/AndroidManifest.xml"
GO="$D/../agent/main.go"
ROAMD="$D/../vendor-common/bin/nowhere_roamd.sh"
AGENT="$D/../agent"
for f in "$ACT" "$DM" "$PROF" "$REL" "$NAPP" "$IDLE" "$RCV" "$DS" "$MAN" "$GO" "$ROAMD"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

PIN_CANDIDATE=$(cat <<'PIN'
    static boolean candidate(ApplicationInfo ai, java.util.Set<Integer> allow) {
        return ai != null && choiceEligible(ai.packageName, UserHandle.getAppId(ai.uid),
                allow.contains(UserHandle.getAppId(ai.uid)), java.util.Arrays.asList(ChooserActivity.PUSH_DOZE_PKGS));
    }
PIN
)
PIN_ALLOW=$(cat <<'PIN'
    static java.util.Set<Integer> allowListed(PowerExemptionManager pem) {
        java.util.Set<Integer> allow = new java.util.HashSet<>();
        for (int a : pem.getAllowListedAppIds(true)) allow.add(a);
        return allow;
    }
PIN
)
PIN_INSTALLED=$(cat <<'PIN'
    static java.util.List<ApplicationInfo> installedFor(Context ctx, int userId) {
        PackageManager pm = userId == UserHandle.myUserId() ? ctx.getPackageManager()
                : ctx.createContextAsUser(UserHandle.of(userId), 0).getPackageManager();
        return pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(
                PackageManager.MATCH_ARCHIVED_PACKAGES | PackageManager.MATCH_DIRECT_BOOT_AWARE
                        | PackageManager.MATCH_DIRECT_BOOT_UNAWARE));
    }
PIN
)
PIN_CAPTURE=$(cat <<'PIN'
    static void capture(Context ctx) {
        // NWP-20261117-06 (dn-1023 #3): a session whose login apply did not arm seals nothing over its restored record.
        // doLogoffImpl runs this on the UI thread and DaemonSocket's connect alone may wait 8 s, so the WHOLE wait for
        // the daemon's answer, connect included, is capped at 1.5 s on a thread of its own; no answer captures as today.
        String arm = "";
        try {
            java.util.concurrent.FutureTask<String> ask = new java.util.concurrent.FutureTask<>(
                    () -> DaemonSocket.roundTrip("GET-DOZE-ARM\n", 1500));
            Thread asker = new Thread(ask, "nowhere-doze-arm");
            asker.setDaemon(true);
            asker.start();
            arm = ask.get(1500, java.util.concurrent.TimeUnit.MILLISECONDS);
        } catch (Throwable t) {
            arm = ""; // a timeout is no answer
        }
        if (!DozeApplyRetry.mayCapture(arm)) {
            android.util.Log.i("NowhereChooser", "doze-apps: this session is unarmed; the restored record is kept");
            return;
        }
        java.util.Set<String> gone; // read BEFORE CAPTURE_LOCK: appGoneThisSession takes APPKEEP_LOCK; never nest them
        try {
            gone = StoreInstaller.appGoneThisSession(ctx);
        } catch (Throwable t) {
            gone = java.util.Collections.emptySet(); // leans toward keeping, like an unreadable keep record
        }
        synchronized (CAPTURE_LOCK) {
            try {
                PowerExemptionManager pem = ctx.getSystemService(PowerExemptionManager.class);
                if (pem == null) return;
                java.util.Set<Integer> allow = allowListed(pem);
                java.util.List<ApplicationInfo> installed = installedFor(ctx, UserHandle.myUserId());
                java.util.TreeSet<String> keep = recordOf(installed, allow);
                java.io.File dir = ctx.getFilesDir();
                keep.addAll(absentFrom(installed, new java.io.File(dir, "nowhere-doze-apps"),
                        new java.io.File(dir, "nowhere-appkeep"), gone));
                StringBuilder sb = new StringBuilder();
                for (String p : keep) sb.append(p).append('\n');
                java.io.File tmp = new java.io.File(dir, "nowhere-doze-apps.tmp");
                try (java.io.FileOutputStream fo = new java.io.FileOutputStream(tmp)) {
                    fo.write(sb.toString().getBytes("UTF-8"));
                }
                if (!tmp.renameTo(new java.io.File(dir, "nowhere-doze-apps"))) {
                    tmp.delete();
                    throw new java.io.IOException("rename nowhere-doze-apps");
                }
                ChooserActivity.idleTrace("pushdoze-capture n=" + keep.size());
                android.util.Log.i("NowhereChooser", "doze-apps: sealed " + keep.size() + " app(s) for user "
                        + UserHandle.myUserId()); // COUNT only, never the names
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "doze-apps capture", t);
            }
        }
    }
PIN
)
PIN_SWEEP=$(cat <<'PIN'
    static void sweepDeparted(Context app, int departed) {
        if (UserHandle.myUserId() != 0 || departed <= 0) return;
        synchronized (ChooserActivity.PUSH_DOZE_LOCK) {
            try {
                PowerExemptionManager pem = app.getSystemService(PowerExemptionManager.class);
                if (pem == null) return;
                java.util.Set<Integer> allow = allowListed(pem);
                android.app.admin.DevicePolicyManager dpm =
                        app.getSystemService(android.app.admin.DevicePolicyManager.class);
                android.content.ComponentName admin = new android.content.ComponentName(app, AdminReceiver.class);
                java.util.Set<String> held = new java.util.HashSet<>();
                for (UserHandle u : dpm.getSecondaryUsers(admin)) {
                    if (u.getIdentifier() == departed) continue;
                    for (ApplicationInfo ai : installedFor(app, u.getIdentifier())) held.add(ai.packageName);
                }
                int removed = 0, kept = 0;
                for (ApplicationInfo ai : installedFor(app, departed)) {
                    if (!candidate(ai, allow)) continue;
                    if (held.contains(ai.packageName)) { kept++; continue; }
                    try { pem.removeFromPermanentAllowList(ai.packageName); removed++; } catch (Throwable systemEntry) {}
                }
                ChooserActivity.idleTrace("pushdoze-sweep user=" + departed + " removed=" + removed + " kept=" + kept);
            } catch (Throwable t) {
                ChooserActivity.idleTrace("pushdoze-sweep err user=" + departed);
                android.util.Log.w("NowhereChooser", "doze-apps sweep", t);
            }
        }
    }
PIN
)
PIN_DROP=$(cat <<'PIN'
    static int dropForeign(Context ctx, PowerExemptionManager pem, java.util.Set<String> own) {
        java.util.Set<Integer> allow = allowListed(pem);
        android.app.admin.DevicePolicyManager dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
        android.content.ComponentName admin = new android.content.ComponentName(ctx, AdminReceiver.class);
        java.util.List<Integer> users = new java.util.ArrayList<>();
        users.add(0);
        for (UserHandle u : dpm.getSecondaryUsers(admin)) users.add(u.getIdentifier());
        java.util.Set<String> drop = new java.util.TreeSet<>();
        for (int u : users) {
            for (ApplicationInfo ai : installedFor(ctx, u)) {
                if (candidate(ai, allow) && !own.contains(ai.packageName)) drop.add(ai.packageName);
            }
        }
        for (String p : drop) { try { pem.removeFromPermanentAllowList(p); } catch (Throwable systemEntry) {} }
        return drop.size();
    }
PIN
)
PIN_REG=$(cat <<'PIN'
    static void registerRemovalSweep(Context ctx) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        try {
            android.os.HandlerThread ht = new android.os.HandlerThread("nowhere-dozesweep");
            ht.start();
            app.registerReceiver(new android.content.BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) {
                    int departed = i.getIntExtra(Intent.EXTRA_USER_HANDLE, -1);
                    disarmLiveRecordFor(departed); // its names leave the gate's memory with it
                    PermsLiveRecord.disarmFor(departed); // NWP-20261112-10
                    sweepDeparted(app, departed);
                }
            }, new android.content.IntentFilter(Intent.ACTION_USER_REMOVED), null,
                    new android.os.Handler(ht.getLooper()), Context.RECEIVER_NOT_EXPORTED);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "doze-apps sweep register", t);
        }
    }
PIN
)
PIN_RECORDFOR=$(cat <<'PIN'
    static java.util.TreeSet<String> recordFor(Context ctx, int userId, java.util.Set<Integer> allow) {
        return recordOf(installedFor(ctx, userId), allow);
    }
PIN
)
PIN_RECORDOF=$(cat <<'PIN'
    static java.util.TreeSet<String> recordOf(java.util.List<ApplicationInfo> installed, java.util.Set<Integer> allow) {
        java.util.TreeSet<String> out = new java.util.TreeSet<>();
        for (ApplicationInfo ai : installed) if (candidate(ai, allow)) out.add(ai.packageName);
        return out;
    }
PIN
)
PIN_RELAYREG=$(cat <<'PIN'
    static void registerLiveRecordRelay(Context ctx) {
        if (UserHandle.myUserId() != 0) return;
        final Context app = ctx.getApplicationContext();
        try {
            android.os.HandlerThread ht = new android.os.HandlerThread("nowhere-dozerelay");
            ht.start();
            final android.os.Handler h = new android.os.Handler(ht.getLooper());
            final Runnable relay = () -> relayToLiveSession(app);
            app.registerReceiverForAllUsers(new android.content.BroadcastReceiver() {
                @Override public void onReceive(Context c, Intent i) {
                    h.removeCallbacks(relay);
                    h.postDelayed(relay, RELAY_QUIET_MS);
                }
            }, relayFilter(), null, h, Context.RECEIVER_NOT_EXPORTED);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "doze-apps relay register", t);
        }
    }
PIN
)
PIN_RELAY=$(cat <<'PIN'
    static void relayToLiveSession(Context app) {
        try {
            int cur = android.app.ActivityManager.getCurrentUser();
            if (cur <= 0) return;
            synchronized (LIVE_LOCK) {
                if (cur != liveUid) return;
                android.os.UserManager um = app.getSystemService(android.os.UserManager.class);
                if (um == null || !um.isUserUnlocked(UserHandle.of(cur))) return;
                PowerExemptionManager pem = app.getSystemService(PowerExemptionManager.class);
                if (pem == null) return;
                java.util.TreeSet<String> now = recordFor(app, cur, allowListed(pem));
                if (now.equals(liveSeen)) return;
                app.sendBroadcastAsUser(new Intent(app, DozeCaptureReceiver.class)
                        .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES), UserHandle.of(cur));
                liveSeen = now;
            }
            ChooserActivity.idleTrace("pushdoze-relay user=" + cur);
        } catch (Throwable t) {
            ChooserActivity.idleTrace("pushdoze-relay err");
            android.util.Log.w("NowhereChooser", "doze-apps relay", t);
        }
    }
PIN
)
PIN_ABSENT=$(cat <<'PIN'
    static java.util.Set<String> absentFrom(java.util.List<ApplicationInfo> installed, java.io.File rec,
            java.io.File keepFile, java.util.Set<String> gone) throws java.io.IOException {
        if (!rec.exists()) return new java.util.TreeSet<>();
        java.util.Set<String> names = new java.util.HashSet<>();
        for (ApplicationInfo ai : installed) names.add(ai.packageName);
        java.util.List<String> recorded = new java.util.ArrayList<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.FileReader(rec))) {
            String l;
            while ((l = br.readLine()) != null) { l = l.trim(); if (!l.isEmpty()) recorded.add(l); }
        }
        return absentKept(names, recorded, keptPackages(keepFile), gone);
    }
PIN
)
PIN_RELAYFILTER=$(cat <<'PIN'
    static android.content.IntentFilter relayFilter() {
        android.content.IntentFilter f =
                new android.content.IntentFilter(android.os.PowerManager.ACTION_POWER_SAVE_WHITELIST_CHANGED);
        f.addAction(Intent.ACTION_USER_SWITCHED);
        f.addAction(Intent.ACTION_USER_UNLOCKED);
        return f;
    }
PIN
)
PIN_LIVE=$(cat <<'PIN'
    private static final Object LIVE_LOCK = new Object();
    private static int liveUid = -1;                 // the session armed by the last successful login apply
    private static java.util.Set<String> liveSeen;   // its own set at the arm, or at the last relay
    private static final long RELAY_QUIET_MS = 2000;

    /** USER 0: forget any armed session. applyRoamedDozeApps calls this first, before its reset. */
    static void disarmLiveRecord() {
        synchronized (LIVE_LOCK) { liveUid = -1; liveSeen = null; }
    }

    /** USER 0, on ACTION_USER_REMOVED: if the departed user is the armed session, forget it -- otherwise the persistent
     *  gate would keep that profile's Unrestricted app names in memory until the next login. */
    static void disarmLiveRecordFor(int departed) {
        synchronized (LIVE_LOCK) { if (departed == liveUid) { liveUid = -1; liveSeen = null; } }
    }

    /** USER 0, at the end of a login apply whose GET-DOZE-APPS read AND reset both succeeded: from now on, relay
     *  changes of this session's own set to it. The baseline is listed before taking the lock; a failure propagates
     *  and nothing is armed. */
    static void armLiveRecord(Context ctx, int uid, PowerExemptionManager pem) {
        java.util.TreeSet<String> seen = recordFor(ctx, uid, allowListed(pem));
        synchronized (LIVE_LOCK) { liveSeen = seen; liveUid = uid; }
    }
PIN
)
PIN_RECEIVER=$(cat <<'PIN'
    public void onReceive(Context ctx, Intent intent) {
        if (android.os.UserHandle.myUserId() == 0) return; // nobody makes choices on the gate
        final PendingResult pending = goAsync();
        final Context app = ctx.getApplicationContext();
        new Thread(() -> {
            try { DozeAppsMirror.capture(app); } finally { pending.finish(); }
        }, "nowhere-dozecap").start();
    }
PIN
)
PIN_ORNULL=$(cat <<'PIN'
    static List<String> roundTripLinesOrNull(String msg, int readCapMs) {
        ArrayList<String> lines = new ArrayList<>();
        LocalSocket s = connect();
        if (s == null) return null;
        try {
            s.setSoTimeout(readCapMs);
            OutputStream os = s.getOutputStream();
            os.write(msg.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            String line;
            while ((line = br.readLine()) != null) { line = line.trim(); if (!line.isEmpty()) lines.add(line); }
            return lines;
        } catch (Throwable t) {
            return null;
        } finally {
            try { s.close(); } catch (Throwable ignore) {}
        }
    }
PIN
)
PIN_MANIFEST=$(cat <<'PIN'
    <receiver android:name=".DozeCaptureReceiver" android:exported="false"/>
PIN
)
PIN_APPLY=$(cat <<'PIN'
    private void applyRoamedDozeApps(int uid) {
        final long t0 = android.os.SystemClock.elapsedRealtime();
        final boolean[] armed = { false }; // NWP-20261117-06: the session is told whether this apply armed its record
        DozeAppsMirror.disarmLiveRecord(); // any reset invalidates an earlier arm
        try {
            final android.os.PowerExemptionManager pem = getSystemService(android.os.PowerExemptionManager.class);
            if (pem == null) return;
            // dn-1023 #3: one attempt is the read, then the reset; DozeApplyRetry repeats a failed one for about 10 s.
            final java.util.concurrent.atomic.AtomicReference<java.util.Set<String>> good =
                    new java.util.concurrent.atomic.AtomicReference<>();
            final int[] last = { -1, 0 }; // the last attempt's dropped count, and the number of attempts
            final long[] firstEnd = { -1 }; // when the first attempt ended: the retry budget runs from it
            boolean held = DozeApplyRetry.run(() -> {
                int timeout = DozeApplyRetry.readTimeoutMs(last[1]++, firstEnd[0], android.os.SystemClock.elapsedRealtime());
                java.util.Set<String> own = new java.util.LinkedHashSet<>();
                java.util.List<String> lines = DaemonSocket.roundTripLinesOrNull("GET-DOZE-APPS\n", timeout);
                // Framed reply: "OK" then the set, or "ERR". Anything else -- no answer, ERR, unframed -- is a FAILED read.
                if (lines == null || lines.isEmpty() || !"OK".equals(lines.get(0))) lines = null;
                else for (String line : lines.subList(1, lines.size())) { String pkg = line.trim(); if (!pkg.isEmpty()) own.add(pkg); }
                if (lines != null) good.set(own); // a failed read resets to the last good set, never to an empty one
                else if (good.get() != null) own = good.get();
                int dropped = -1; // a reset that fails leaves a foreign entry live, so the attempt has not held
                synchronized (PUSH_DOZE_LOCK) {
                    try { dropped = DozeAppsMirror.dropForeign(this, pem, own); } catch (Throwable t) { dropped = -1; }
                }
                last[0] = dropped;
                if (firstEnd[0] < 0) firstEnd[0] = android.os.SystemClock.elapsedRealtime();
                if (lines != null && dropped >= 0) {
                    return true; // held: a strict read AND a reset that held
                }
                return false;
            }, android.os.SystemClock::elapsedRealtime, android.os.SystemClock::sleep);
            synchronized (PUSH_DOZE_LOCK) {
                java.util.Set<String> own = good.get() != null ? good.get() : java.util.Collections.<String>emptySet();
                int n = 0;
                for (String pkg : own) { ensurePushDozeFor(this, pem, pkg); n++; }
                boolean live = false; // arm the live record only when the last attempt held
                if (held) {
                    try { DozeAppsMirror.armLiveRecord(this, uid, pem); live = true; } catch (Throwable t) { live = false; }
                }
                armed[0] = live;
                idleTrace("pushdoze-roam applied=" + n + " dropped=" + last[0] + " live=" + (live ? 1 : 0) + " tries=" + last[1]);
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "applyRoamedDozeApps", t); }
        finally {
            // dn-1023 #3: tell the daemon, outside PUSH_DOZE_LOCK; a session that is not armed seals nothing at sign-out.
            String ack = DaemonSocket.roundTrip("DOZE-ARM\n" + uid + "\n" + (armed[0] ? "armed" : "unarmed") + "\n", 3000);
            idleTrace("pushdoze-roam live=" + (armed[0] ? 1 : 0) + " ok=" + ("OK".equals(ack) ? 1 : 0));
        }
        gateTiming("dozeapply", android.os.SystemClock.elapsedRealtime() - t0);
    }
PIN
)
PIN_APPLYCALL=$(cat <<'PIN'
                provisionRoamedApps(uid); // reinstall the roamed identity's apps (device-local, for now)
                applyRoamedPrefs(); // re-apply this profile's roamed timezone + locale (or the baked default)
                applyRoamedSettings(uid); // NWP-20261130-12 (Q012): replay the curated settings allowlist, before switch-in
                applyRoamedDozeApps(uid); // NWP-20261002-02: re-apply this profile's own battery-Unrestricted apps
                ensureRoamedHomeRole(uid); // #131: pin launcher3 as the HOME role holder BEFORE switch-in so the
PIN
)
PIN_LOCK=$(cat <<'PIN'
    static final Object PUSH_DOZE_LOCK = new Object(); // NWP-20261002-03: shared with DozeAppsMirror's sweep
PIN
)
PIN_APPCALL=$(cat <<'PIN'
        // walks the installed-package list and touches the keep-set file.
        new Thread(() -> AppInstallReceiver.applyDefaultsToUndecided(this), "nowhere-appdefaults").start();
        // NWP-20261130-03: and the launch barrier: an app installed while this process was dead and not relayed is held here.
        new Thread(() -> OdDataBarrierHost.reconcile(this), "nowhere-od-barrier-reconcile").start();
        // NWP-20261130-03 (RF-013): the same event must reach a session whose chooser process is dead. User-0 guard inside.
        OdDataInstallWatch.register(this);
        // NWP-20261002-03: the user-0 gate is the only remover of a profile's own Doze choices, and it removes them
        // when that profile's USER is removed (ACTION_USER_REMOVED), never at logoff. Registered at process birth so
        // it is live before the boot-wipe removes a leftover session (BootReceiver). User-0 guard inside.
        DozeAppsMirror.registerRemovalSweep(this); // NWP-20261002-03
        // NWP-20261002-03: keep the live session's own Doze record current, so a periodic seal carries a choice made
        // in a session that later ends in a cold lock. User-0 guard inside; armed per login by applyRoamedDozeApps.
        DozeAppsMirror.registerLiveRecordRelay(this); // NWP-20261002-03
        // NWP-20261112-10 (Q061): the same for a permission answered in the live session -- relayed to its
        // PermsCaptureReceiver after 2 s of quiet. User-0 guard inside; armed per login after an OK GRANT-PERMS.
        PermsLiveRecord.register(this); // NWP-20261112-10
        // NWP-20261001-05 / NWP-20261002-01: keep the push apps on the Doze allow-list (ChooserActivity
PIN
)
PIN_LOGOFF_WRAP=$(cat <<'PIN'
    private void doLogoff() {
        doLogoffImpl(false);
    }
PIN
)
PIN_LOGOFF=$(cat <<'PIN'
    private void doLogoffImpl(final boolean forInstall) {
        mirrorWifiToGate(); // #98: capture BEFORE the session stops (best-effort)
        DozeAppsMirror.capture(this); // NWP-20261002-02: seal this profile's own Doze-exempt apps. Removes nothing
                                      // (NWP-20261002-03): the gate drops them when this user is removed, so a
                                      // logoff that fails and keeps the session cannot de-exempt it. SYNCHRONOUS so
                                      // the file is written before LOGOUT seals the CE.
PIN
)
PIN_RELOGIN=$(cat <<'PIN'
                    WifiMirror.capture(ctx);
                    DozeAppsMirror.capture(ctx); // NWP-20261002-02: seal this profile's Doze-exempt apps (removes
                                                 // nothing, NWP-20261002-03), same BEFORE-the-logoff point as the
                                                 // Wi-Fi capture above. Kept: a promoted offline session can reach
                                                 // the daemon's SEALING logoff through RELOGIN.
                    s.connect(new LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.RESERVED));
PIN
)
PIN_DISPATCH=$(cat <<'PIN'
	if name == "GET-DOZE-APPS" {
		// NWP-20261002-02: hand back this profile's own battery-Unrestricted app set (one package per line),
		// which the worker surfaced to doze-apps.out from the sealed nowhere-doze-apps, mirroring apps.out. The
		// user-0 gate re-applies it to the device-wide Doze allow-list at login (ensurePushDozeFor); the su:s0
		// worker cannot, as it is not the device owner.
		handleGetDozeApps(conn, dest)
		return
	}
PIN
)
PIN_HANDLER=$(cat <<'PIN'
func handleGetDozeApps(conn net.Conn, dest string) {
	b, err := os.ReadFile(filepath.Join(dest, "doze-apps.out"))
	if err != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	conn.Write(append([]byte("OK\n"), b...))
}
PIN
)
PIN_OFFLINE=$(cat <<'PIN'
	os.WriteFile(filepath.Join(dest, "apps.out"), []byte{}, 0o600)      // base apps only; no roamed list offline
	os.WriteFile(filepath.Join(dest, "prefs.out"), []byte{}, 0o600)     // baked default prefs; nothing roamed offline
	os.WriteFile(filepath.Join(dest, "doze-apps.out"), []byte{}, 0o600) // NWP-20261002-02: no roamed Doze set offline
PIN
)
PIN_SURFACE=$(cat <<'PIN'
      ( : > "$STATE/apps.out" )
      [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-apps.list" ] \
        && cp "$USERDIR/com.nowhere.chooser/files/nowhere-apps.list" "$STATE/apps.out" 2>> "$LOG"
      # NWP-20261002-02: surface this profile's own battery-Unrestricted app set (nowhere-doze-apps, sealed with
      # the profile's CE like nowhere-apps.list) into the tmpfs, so the device-owner gate can re-apply it to the
      # Doze allow-list at login via GET-DOZE-APPS (the worker is not the device owner, so it cannot).
      # NWP-20261002-03: a FAILED copy removes the file, so GET-DOZE-APPS answers ERR instead of an empty set
      # that would read as "this profile has no choices" (the gate arms its live record only on a known-good read).
      ( : > "$STATE/doze-apps.out" )
      [ -f "$USERDIR/com.nowhere.chooser/files/nowhere-doze-apps" ] \
        && { cp "$USERDIR/com.nowhere.chooser/files/nowhere-doze-apps" "$STATE/doze-apps.out" 2>> "$LOG" \
             || rm -f "$STATE/doze-apps.out"; }
PIN
)

# A pinned block must occur in the file exactly once, byte for byte. Pins go through ENVIRON (awk -v would interpret
# backslash escapes inside the pins).
once(){ PINV="$1" awk 'BEGIN { n = split(ENVIRON["PINV"], P, "\n") }
  { L[++m] = $0; if (m >= n) { same = 1; for (k = 1; k <= n; k++) if (L[m - n + k] != P[k]) same = 0; if (same) hits++ } }
  END { exit !(hits == 1) }' "$2"; }
c_candidate(){ once "$PIN_CANDIDATE" "$1"; }  # delegates to choiceEligible (test-doze-candidate-java.sh runs it)
c_allow(){     once "$PIN_ALLOW" "$1"; }      # the effective allow-list (system allow-in-power-save + user)
c_installed(){ once "$PIN_INSTALLED" "$1"; }  # archived + direct-boot flags via ApplicationInfoFlags, cross-user
c_capture(){   once "$PIN_CAPTURE" "$1"; }    # asks GET-DOZE-ARM before CAPTURE_LOCK; records through candidate, seals the file, count trace, NO removal
c_sweep(){     once "$PIN_SWEEP" "$1"; }      # user 0, locked, holders listed first, keep-if-held, counts only
c_drop(){      once "$PIN_DROP" "$1"; }       # users {0}+secondaries, collect then remove, !own
c_reg(){       once "$PIN_REG" "$1"; }        # USER_REMOVED, own HandlerThread, synchronous sweep, EXTRA_USER_HANDLE
c_apply(){     once "$PIN_APPLY" "$1"; }      # read outside the lock; read + reset retried ~10 s (DozeApplyRetry), then re-bind under it, then DOZE-ARM after the arm decision
c_applycall(){ once "$PIN_APPLYCALL" "$1"; }  # provision -> prefs -> doze apply -> home role, contiguous
c_lockshared(){ once "$PIN_LOCK" "$1"; }      # PUSH_DOZE_LOCK is package-visible to the sweep
c_appcall(){   once "$PIN_APPCALL" "$1"; }    # NowhereApp registers the sweep at process birth
c_logoff(){    once "$PIN_LOGOFF_WRAP" "$1" && once "$PIN_LOGOFF" "$1"; }  # doLogoff routes through doLogoffImpl (NWP-20261017-17), whose 2nd statement is the capture, before LOGOUT is sent
c_relogin(){   once "$PIN_RELOGIN" "$1"; }    # capture sits between the Wi-Fi capture and the RELOGIN connect
c_dispatch(){  once "$PIN_DISPATCH" "$1" && [ "$(grep -c '"GET-DOZE-APPS"' "$1")" = "1" ]; }  # ... and nothing else in main.go answers the verb
c_handler(){   once "$PIN_HANDLER" "$1" && [ "$(grep -c '"doze-apps\.out"' "$1")" = "2" ]; }  # framed, ONE write; in main.go only it + the offline truncation name the file
c_offline(){   once "$PIN_OFFLINE" "$1"; }    # an offline roam-in truncates the set (no other profile's set served)
c_surface(){   once "$PIN_SURFACE" "$1" && [ "$(grep -c 'doze-apps\.out' "$1")" = "3" ]; }  # truncate, copy, rm on failure; no other line
c_recordfor(){ once "$PIN_RECORDFOR" "$1"; }  # one listing: archived included (installedFor) ...
c_recordof(){  once "$PIN_RECORDOF" "$1"; }   # ... through candidate, sorted
c_live(){      once "$PIN_LIVE" "$1"; }       # arm state is user-0 process memory; disarm; arm lists before locking
c_relayreg(){  once "$PIN_RELAYREG" "$1"; }   # ALL users (a session's unlock), own HandlerThread, 2 s debounce
c_relay(){     once "$PIN_RELAY" "$1"; }      # only the armed, current, unlocked session, on a real change, no extras
c_receiver(){  once "$PIN_RECEIVER" "$1"; }   # session side: never in user 0; goAsync + worker; capture only
c_ornull(){    once "$PIN_ORNULL" "$1"; }     # a failed read is null, never "no choices"
c_manifest(){  once "$PIN_MANIFEST" "$1" && [ "$(grep -c 'DozeCaptureReceiver' "$1")" = "1" ]; }  # declared ONCE (any quoting), not exported
c_absent(){    once "$PIN_ABSENT" "$1"; }     # an app not installed here is not a choice turned off; unreadable -> throw
c_relayfilter(){ once "$PIN_RELAYFILTER" "$1"; } # the relay also re-runs on a switch / unlock of the armed session
# Lines of a file that match a pattern once its COMMENTS are blanked, for in-file call counts. ONE left-to-right pass:
# string, text-block and char literals are matched first and kept, so a `//` or `/*` inside one, or a `/*` inside a
# `//` comment, cannot hide code. A comment becomes spaces with its newlines kept -- javac reads it as whitespace, so
# `else/**/capture(c)` still counts and line numbers hold -- and the call patterns allow space before `(`. Blanking
# comments, not skipping lines that start like one, is what counts `/** w */ static void x() { capture(c); }`. Exact
# non-zero counts are their own control: no perl, no match.
codecount(){ perl -0777 -pe 's{("""(?:\\.|.)*?"""|"(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|/\*.*?\*/|//[^\n]*}{ defined $1 ? $1 : do { (my $c = $&) =~ tr/\n/ /c; $c } }gse' "$1" | grep -c -- "$2"; }
# The agent is ONE Go package over many files (verb handlers and $dest writers already live outside main.go), so the
# "no second writer or dispatch" counts also run over every non-test file of it. Exact counts are their own control.
agentcount(){ local f; for f in "$1"/*.go; do case "$f" in *_test.go) ;; *) cat "$f";; esac; done | grep -c -- "$2"; }
c_agentonly(){ [ "$(agentcount "$1" '"doze-apps\.out"')" = "2" ] && [ "$(agentcount "$1" '"GET-DOZE-APPS"')" = "1" ]; }
c_coldclean(){ ! grep -q 'DozeAppsMirror' "$1"; }
# The login apply must run before the switch-in: the first switchToUser(uid CALL in the login worker comes after it,
# and must exist (the method DECLARATION is `switchToUser(int uid`, which does not match). The earlier
# `switchingIn = true` there is a pre-arm for cover routing during provisioning, not the switch.
c_applyorder(){ awk '/int supersedeColdUid = -1;/ { inlogin = 1 }
  inlogin && /^                applyRoamedDozeApps\(uid\);/ && !a { a = NR }
  inlogin && /switchToUser\(uid/ && !s { s = NR }
  END { exit !(a > 0 && s > 0 && a < s) }' "$1"; }
# Tree-wide (take the chooser source DIR). Exact counts are their own control: zero means the tool did not run.
c_nondestr(){ local files
  files=$(grep -rl 'removeFromPermanentAllowList' "$1" | sed 's#.*/##' | sort | tr '\n' ' ')
  [ "$files" = "ChooserActivity.java DozeAppsMirror.java " ] \
    && [ "$(grep -c 'removeFromPermanentAllowList' "$1/DozeAppsMirror.java")" = "2" ] \
    && [ "$(grep -c 'removeFromPermanentAllowList' "$1/ChooserActivity.java")" = "2" ]; }
callers(){ grep -rl "$2" "$1" | sed 's#.*/##' | sort | tr '\n' ' '; }
c_cap_callers(){  [ "$(callers "$1" 'DozeAppsMirror.capture(\|DozeAppsMirror[[:space:]]*::[[:space:]]*capture\b')" = "DozeCaptureReceiver.java ProfileActivity.java ReloginReceiver.java " ] \
  && [ "$(grep -c 'DozeAppsMirror.capture(\|DozeAppsMirror[[:space:]]*::[[:space:]]*capture\b' "$1/ProfileActivity.java")" = "1" ] \
  && [ "$(grep -c 'DozeAppsMirror.capture(\|DozeAppsMirror[[:space:]]*::[[:space:]]*capture\b' "$1/ReloginReceiver.java")" = "1" ] \
  && [ "$(grep -c 'DozeAppsMirror.capture(\|DozeAppsMirror[[:space:]]*::[[:space:]]*capture\b' "$1/DozeCaptureReceiver.java")" = "1" ] \
  && [ "$(codecount "$1/DozeAppsMirror.java" '[^a-zA-Z]capture[[:space:]]*(\|DozeAppsMirror[[:space:]]*::[[:space:]]*capture\b')" = "1" ]; }
c_live_callers(){ [ "$(callers "$1" 'DozeAppsMirror.registerLiveRecordRelay(\|DozeAppsMirror[[:space:]]*::[[:space:]]*registerLiveRecordRelay\b')" = "NowhereApp.java " ] \
  && [ "$(grep -c 'DozeAppsMirror.registerLiveRecordRelay(\|DozeAppsMirror[[:space:]]*::[[:space:]]*registerLiveRecordRelay\b' "$1/NowhereApp.java")" = "1" ] \
  && [ "$(callers "$1" 'DozeAppsMirror.armLiveRecord(\|DozeAppsMirror[[:space:]]*::[[:space:]]*armLiveRecord\b')" = "ChooserActivity.java " ] \
  && [ "$(grep -c 'DozeAppsMirror.armLiveRecord(\|DozeAppsMirror[[:space:]]*::[[:space:]]*armLiveRecord\b' "$1/ChooserActivity.java")" = "1" ] \
  && [ "$(callers "$1" 'DozeAppsMirror.disarmLiveRecord(\|DozeAppsMirror[[:space:]]*::[[:space:]]*disarmLiveRecord\b')" = "ChooserActivity.java " ] \
  && [ "$(grep -c 'DozeAppsMirror.disarmLiveRecord(\|DozeAppsMirror[[:space:]]*::[[:space:]]*disarmLiveRecord\b' "$1/ChooserActivity.java")" = "1" ] \
  && [ "$(callers "$1" 'relayToLiveSession(\|DozeAppsMirror[[:space:]]*::[[:space:]]*relayToLiveSession\b')" = "DozeAppsMirror.java " ] \
  && [ "$(callers "$1" 'DozeCaptureReceiver.class')" = "DozeAppsMirror.java " ] \
  && [ "$(codecount "$1/DozeAppsMirror.java" 'relayToLiveSession[[:space:]]*(\|DozeAppsMirror[[:space:]]*::[[:space:]]*relayToLiveSession\b')" = "2" ] \
  && [ "$(codecount "$1/DozeAppsMirror.java" 'DozeCaptureReceiver.class')" = "1" ] \
  && [ "$(codecount "$1/DozeAppsMirror.java" '[^a-zA-Z]armLiveRecord[[:space:]]*(\|DozeAppsMirror[[:space:]]*::[[:space:]]*armLiveRecord\b')" = "1" ] \
  && [ "$(codecount "$1/DozeAppsMirror.java" 'disarmLiveRecord[[:space:]]*(\|DozeAppsMirror[[:space:]]*::[[:space:]]*disarmLiveRecord\b')" = "1" ] \
  && [ "$(codecount "$1/DozeAppsMirror.java" 'disarmLiveRecordFor[[:space:]]*(\|DozeAppsMirror[[:space:]]*::[[:space:]]*disarmLiveRecordFor\b')" = "2" ]; }
c_reg_callers(){  [ "$(callers "$1" 'DozeAppsMirror.registerRemovalSweep(\|DozeAppsMirror[[:space:]]*::[[:space:]]*registerRemovalSweep\b')" = "NowhereApp.java " ] \
  && [ "$(grep -c 'DozeAppsMirror.registerRemovalSweep(\|DozeAppsMirror[[:space:]]*::[[:space:]]*registerRemovalSweep\b' "$1/NowhereApp.java")" = "1" ]; }
c_sweep_callers(){ [ "$(callers "$1" 'sweepDeparted(\|DozeAppsMirror[[:space:]]*::[[:space:]]*sweepDeparted\b')" = "DozeAppsMirror.java " ] \
  && [ "$(grep -c 'sweepDeparted(\|DozeAppsMirror[[:space:]]*::[[:space:]]*sweepDeparted\b' "$1/DozeAppsMirror.java")" = "2" ]; }
c_drop_callers(){ [ "$(callers "$1" 'DozeAppsMirror.dropForeign(\|DozeAppsMirror[[:space:]]*::[[:space:]]*dropForeign\b')" = "ChooserActivity.java " ] \
  && [ "$(grep -c 'DozeAppsMirror.dropForeign(\|DozeAppsMirror[[:space:]]*::[[:space:]]*dropForeign\b' "$1/ChooserActivity.java")" = "1" ] \
  && [ "$(grep -c 'dropForeign(\|DozeAppsMirror[[:space:]]*::[[:space:]]*dropForeign\b' "$1/DozeAppsMirror.java")" = "1" ] \
  && [ "$(grep -c 'applyRoamedDozeApps(\|DozeAppsMirror[[:space:]]*::[[:space:]]*applyRoamedDozeApps\b' "$1/ChooserActivity.java")" = "2" ]; }

echo "== the session only records; the user-0 gate removes (at USER_REMOVED) and resets (at login) =="
c_candidate "$DM"  && ok "candidate is the pinned predicate (delegates to choiceEligible)"            || no "candidate differs from the pinned block"
c_allow "$DM"      && ok "allowListed reads the effective list (getAllowListedAppIds(true))"         || no "allowListed differs from the pinned block"
c_installed "$DM"  && ok "installedFor lists archived + CE-locked users via ApplicationInfoFlags"    || no "installedFor differs from the pinned block"
c_capture "$DM"    && ok "capture asks GET-DOZE-ARM first, records through candidate, seals the file, traces a count, removes NOTHING" || no "capture differs from the pinned block"
c_sweep "$DM"      && ok "sweepDeparted is the pinned block (user 0, locked, holders first, fail closed)" || no "sweepDeparted differs from the pinned block"
c_drop "$DM"       && ok "dropForeign is the pinned block (all users, collect then remove)"         || no "dropForeign differs from the pinned block"
c_reg "$DM"        && ok "registerRemovalSweep is the pinned block (USER_REMOVED, synchronous)"     || no "registerRemovalSweep differs from the pinned block"
c_apply "$ACT"     && ok "applyRoamedDozeApps is the pinned block (read + reset retried ~10 s, then re-bind, locked, then DOZE-ARM)" || no "applyRoamedDozeApps differs from the pinned block"
c_applycall "$ACT" && ok "applied at login: provision -> prefs -> doze apply -> home role (pinned)"  || no "the login apply call is missing, moved, wrapped or changed"
c_applyorder "$ACT" && ok "the login apply runs before the switch-in is posted"                      || no "the login apply is not before the switch-in"
c_lockshared "$ACT" && ok "PUSH_DOZE_LOCK is package-visible (shared with the sweep)"               || no "PUSH_DOZE_LOCK changed"
c_appcall "$NAPP"  && ok "NowhereApp registers the removal sweep at process birth (pinned in context)" || no "the NowhereApp registration is missing, moved, wrapped or changed"
c_logoff "$PROF"   && ok "doLogoff records first, before anything is sent (pinned)"                  || no "the doLogoff capture is missing, moved, disabled or changed"
c_relogin "$REL"   && ok "ReloginReceiver records before the RELOGIN connect (pinned)"               || no "the ReloginReceiver capture is missing, moved, disabled or changed"
c_dispatch "$GO"   && ok "daemon dispatches GET-DOZE-APPS to handleGetDozeApps, and only there in main.go (pinned)" || no "the GET-DOZE-APPS dispatch changed or gained a second branch in main.go"
c_handler "$GO"    && ok "handleGetDozeApps frames the reply in one write; no other writer in main.go (pinned)" || no "handleGetDozeApps changed, or another main.go line names doze-apps.out"
c_agentonly "$AGENT" && ok "no other agent file names doze-apps.out or answers GET-DOZE-APPS (package-wide)" || no "another agent file names doze-apps.out or answers GET-DOZE-APPS"
c_offline "$GO"    && ok "an offline roam-in truncates doze-apps.out (pinned)"                       || no "the offline truncation of doze-apps.out changed"
c_surface "$ROAMD" && ok "roamd truncates, surfaces only this profile's set, removes it on a failed copy; no other line" || no "the worker surfacing of the sealed set changed, or another roamd line names doze-apps.out"

echo "== the live record: the gate relays a change to the armed session, which re-records =="
c_recordfor "$DM"  && ok "recordFor lists through installedFor (archived included, pinned)"       || no "recordFor differs from the pinned block"
c_recordof "$DM"   && ok "recordOf keeps candidates only, sorted (pinned)"                          || no "recordOf differs from the pinned block"
c_live "$DM"       && ok "the arm state, disarm and arm are the pinned block"                      || no "the live-record arm state changed"
c_relayreg "$DM"   && ok "the relay is registered for ALL users, on its own thread, debounced 2 s"  || no "registerLiveRecordRelay differs from the pinned block"
c_relay "$DM"      && ok "the relay targets only the armed, current, unlocked session on a real change" || no "relayToLiveSession differs from the pinned block"
c_receiver "$RCV"  && ok "DozeCaptureReceiver never acts in user 0 and only re-runs capture (pinned)" || no "DozeCaptureReceiver.onReceive differs from the pinned block"
c_ornull "$DS"     && ok "the strict read returns null on failure, never an empty set (pinned)"     || no "roundTripLinesOrNull differs from the pinned block"
c_manifest "$MAN"  && ok "DozeCaptureReceiver is declared once, in any quoting, and NOT exported"   || no "the DozeCaptureReceiver manifest entry is missing, duplicated or exported"
c_absent "$DM"     && ok "capture keeps a name whose app is not in the listing (absentFrom, pinned)" || no "absentFrom differs from the pinned block"
c_relayfilter "$DM" && ok "the relay re-runs on an allow-list change, a user switch and an unlock (pinned)" || no "relayFilter differs from the pinned block"

echo "== tree-wide: who may remove, and who may call what =="
c_nondestr "$SRC"      && ok "only ensurePushDozeFor (2) and DozeAppsMirror's sweep + drop (2) remove" || no "removeFromPermanentAllowList appears outside the gate's removers or a count changed -- a session-side removal de-exempts a live session"
c_cap_callers "$SRC"   && ok "capture is called once each from doLogoff, ReloginReceiver and DozeCaptureReceiver" || no "capture is called from an unexpected file or more than once"
c_live_callers "$SRC"  && ok "the relay is registered once (NowhereApp), armed/disarmed only by the login apply" || no "a live-record entry point gained a caller"
c_reg_callers "$SRC"   && ok "registerRemovalSweep is called once, from NowhereApp"                    || no "registerRemovalSweep is called from an unexpected file or more than once"
c_sweep_callers "$SRC" && ok "sweepDeparted is reached only from DozeAppsMirror's receiver"            || no "sweepDeparted is called from outside DozeAppsMirror or more than once"
c_drop_callers "$SRC"  && ok "dropForeign is called once, from the login apply (and the apply once)"   || no "dropForeign or the login apply gained a call site"
c_coldclean "$IDLE"    && ok "IdleLogoffReceiver (idle cold-lock, user 0) does not touch DozeAppsMirror" || no "IdleLogoffReceiver references DozeAppsMirror -- the idle lock runs in user 0, cannot write the session's record, and must not remove"

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  mut(){ # <label> <check> <file> <sed>
    if ! sed "$4" "$3" > "$M/x" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$3" "$M/x"; then no "MUTATION INERT: $1"; return; fi
    if "$2" "$M/x"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi; }
  mutdir(){ # <label> <check> <file under SRC> <sed> -- mutate a copy of the whole tree
    rm -rf "$M/tree"; cp -r "$SRC" "$M/tree"
    if ! sed -i "$4" "$M/tree/$3" 2>/dev/null; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SRC/$3" "$M/tree/$3"; then no "MUTATION INERT: $1"; return; fi
    if "$2" "$M/tree"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi; }
  keep(){ # <label> <check> <file under SRC> <sed> -- a HARMLESS edit to a copy of the tree that the check must still PASS
    rm -rf "$M/tree"; cp -r "$SRC" "$M/tree"
    if ! sed -i "$4" "$M/tree/$3" 2>/dev/null; then no "PROBE BROKEN (sed): $1"; return; fi
    if cmp -s "$SRC/$3" "$M/tree/$3"; then no "PROBE INERT: $1"; return; fi
    if "$2" "$M/tree"; then ok "stays green: $1"; else no "FALSE FAILURE: $1"; fi; }
  mutagent(){ # <label> <new file> <body> -- add a file to a copy of the agent package
    rm -rf "$M/agent"; mkdir "$M/agent"; cp "$AGENT"/*.go "$M/agent/"
    printf '%s\n' "$3" > "$M/agent/$2"
    if c_agentonly "$M/agent"; then no "NOT CONVICTED: $1"; else ok "convicted: $1"; fi; }
  # The defect itself, and every way back to a session-side removal.
  mut    "the remove loop re-inserted into capture (the -02 defect)"   c_capture "$DM" 's#^                ChooserActivity.idleTrace("pushdoze-capture n=" + keep.size());#                for (String p : keep) { try { pem.removeFromPermanentAllowList(p); } catch (Throwable ignore) {} }\n&#'
  mutdir "the remove loop re-inserted into capture (tree-wide)"        c_nondestr DozeAppsMirror.java 's#^                ChooserActivity.idleTrace("pushdoze-capture n=" + keep.size());#                for (String p : keep) { try { pem.removeFromPermanentAllowList(p); } catch (Throwable ignore) {} }\n&#'
  mutdir "a removal injected into the live-record receiver"           c_nondestr DozeCaptureReceiver.java 's#^        final PendingResult pending = goAsync();#        ctx.getSystemService(android.os.PowerExemptionManager.class).removeFromPermanentAllowList("x");\n&#'
  mutdir "a removal injected into ProfileActivity.doLogoff"            c_nondestr ProfileActivity.java 's#^        DozeAppsMirror.capture(this); // NWP-20261002-02#        getSystemService(android.os.PowerExemptionManager.class).removeFromPermanentAllowList("x");\n&#'
  mutdir "a removal injected into ReloginReceiver"                     c_nondestr ReloginReceiver.java 's#^                    DozeAppsMirror.capture(ctx); // NWP-20261002-02#                    ctx.getSystemService(android.os.PowerExemptionManager.class).removeFromPermanentAllowList("x");\n&#'
  mutdir "a removal laundered through a new ChooserActivity helper"   c_nondestr ChooserActivity.java 's#^    static final Object PUSH_DOZE_LOCK = new Object();#    static void dropOne(android.os.PowerExemptionManager p, String n) { p.removeFromPermanentAllowList(n); }\n&#'
  # The shared predicate.
  # NWP-20261114-26: the FLAG_SYSTEM mutant is gone with its line (Q052), and the uid floor now lives in choiceEligible,
  # whose cases test-doze-candidate-java.sh runs ("choiceEligible drops the appId floor" convicts its removal).
  mut    "candidate drops the curated exclusion"                       c_candidate "$DM" 's#java.util.Arrays.asList(ChooserActivity.PUSH_DOZE_PKGS)#java.util.Collections.emptyList()#'
  mut    "candidate drops the allow-list membership test"              c_candidate "$DM" 's#allow.contains(UserHandle.getAppId(ai.uid)), #true, #'
  mut    "allowListed reads the non-idle list"                         c_allow "$DM" 's#pem.getAllowListedAppIds(true)#pem.getAllowListedAppIds(false)#'
  # Capture.
  mut    "the record listing bypasses candidate"                       c_recordof "$DM" 's#if (candidate(ai, allow)) out.add(ai.packageName);#out.add(ai.packageName);#'
  mut    "the record listing drops archived apps (back to flags 0)"     c_recordfor "$DM" 's#return recordOf(installedFor(ctx, userId), allow);#return recordOf(ctx.getPackageManager().getInstalledApplications(0), allow);#'
  mut    "capture no longer uses the shared record listing"            c_capture "$DM" 's#java.util.TreeSet<String> keep = recordOf(installed, allow);#java.util.TreeSet<String> keep = new java.util.TreeSet<>();#'
  mut    "capture lists twice (absentFrom on a listing of its own)"     c_capture "$DM" 's#keep.addAll(absentFrom(installed, #keep.addAll(absentFrom(installedFor(ctx, UserHandle.myUserId()), #'
  mut    "capture lists twice (the record half on a listing of its own)" c_capture "$DM" 's#recordOf(installed, allow)#recordFor(ctx, UserHandle.myUserId(), allow)#'
  mut    "capture is not serialized"                                   c_capture "$DM" 's#^        synchronized (CAPTURE_LOCK) {#        {#'
  mut    "the GET-DOZE-ARM check removed from capture"                c_capture "$DM" '/^        if (!DozeApplyRetry.mayCapture(arm)) {$/,/^        }$/d'
  mut    "capture writes the record in place (not atomic)"             c_capture "$DM" 's#new java.io.File(dir, "nowhere-doze-apps.tmp")#new java.io.File(dir, "nowhere-doze-apps")#'
  mut    "a failed rename is ignored"                                  c_capture "$DM" '/throw new java.io.IOException("rename nowhere-doze-apps");/d'
  mut    "capture no longer writes the sealed file"                    c_capture "$DM" '/fo.write(sb.toString().getBytes("UTF-8"));/d'
  mut    "the capture trace prints the names"                          c_capture "$DM" 's#"pushdoze-capture n=" + keep.size()#"pushdoze-capture n=" + keep#'
  # Listing.
  mut    "installedFor drops MATCH_ARCHIVED_PACKAGES"                  c_installed "$DM" 's#PackageManager.MATCH_ARCHIVED_PACKAGES | ##'
  mut    "installedFor drops the direct-boot flags"                    c_installed "$DM" '/| PackageManager.MATCH_DIRECT_BOOT_UNAWARE));/d'
  mut    "installedFor passes an int, not ApplicationInfoFlags"        c_installed "$DM" 's#getInstalledApplications(PackageManager.ApplicationInfoFlags.of(#getInstalledApplications((int) (#'
  # The removal sweep.
  mut    "the sweep's keep-if-held line is deleted"                    c_sweep "$DM" '/if (held.contains(ai.packageName)) { kept++; continue; }/d'
  mut    "the sweep counts the departed user as its own holder"        c_sweep "$DM" '/if (u.getIdentifier() == departed) continue;/d'
  mut    "the sweep loses its user-0 guard"                            c_sweep "$DM" 's#if (UserHandle.myUserId() != 0 || departed <= 0) return;#if (departed <= 0) return;#'
  mut    "the sweep is not synchronized on PUSH_DOZE_LOCK"             c_sweep "$DM" 's#synchronized (ChooserActivity.PUSH_DOZE_LOCK) {#{#'
  mut    "the sweep bypasses candidate"                                c_sweep "$DM" '/if (!candidate(ai, allow)) continue;/d'
  mut    "the sweep removes while still listing holders"               c_sweep "$DM" 's#for (ApplicationInfo ai : installedFor(app, u.getIdentifier())) held.add(ai.packageName);#for (ApplicationInfo ai : installedFor(app, u.getIdentifier())) { held.add(ai.packageName); pem.removeFromPermanentAllowList(ai.packageName); }#'
  mut    "the sweep trace prints package names"                        c_sweep "$DM" 's#" removed=" + removed#" removed=" + held#'
  # Registration.
  mut    "the receiver filters ACTION_USER_STOPPED (fires on every cold lock)" c_reg "$DM" 's#Intent.ACTION_USER_REMOVED#Intent.ACTION_USER_STOPPED#'
  mut    "the receiver runs the sweep on a new Thread"                 c_reg "$DM" 's#^                    sweepDeparted(app, departed);#                    new Thread(() -> sweepDeparted(app, departed)).start();#'
  mut    "the receiver reads EXTRA_UID"                                c_reg "$DM" 's#Intent.EXTRA_USER_HANDLE#Intent.EXTRA_UID#'
  mut    "registerRemovalSweep loses its user-0 guard"                 c_reg "$DM" '/static void registerRemovalSweep/,/^    }/{/        if (UserHandle.myUserId() != 0) return;/d}'
  mut    "the NowhereApp registration is deleted"                      c_appcall "$NAPP" '/DozeAppsMirror.registerRemovalSweep(this);/d'
  mut    "the NowhereApp registration is wrapped in dead code"         c_appcall "$NAPP" 's#^        DozeAppsMirror.registerRemovalSweep(this); // NWP-20261002-03#        if (false) {\n&\n        }#'
  mutdir "the NowhereApp registration is deleted (tree-wide)"          c_reg_callers NowhereApp.java '/DozeAppsMirror.registerRemovalSweep(this);/d'
  # The login apply and its reset.
  mut    "the apply no longer resets (dropForeign deleted)"            c_apply "$ACT" '/try { dropped = DozeAppsMirror.dropForeign(this, pem, own); } catch (Throwable t) { dropped = -1; }/d'
  mut    "the read and reset are no longer retried (DozeApplyRetry call removed)" c_apply "$ACT" 's#DozeApplyRetry.run(() -> {#((java.util.function.BooleanSupplier) () -> {#'
  mut    "the apply runs outside PUSH_DOZE_LOCK"                       c_apply "$ACT" 's#            synchronized (PUSH_DOZE_LOCK) {#            {#'
  mut    "the apply skips an empty set (no reset for throwaway/offline)" c_apply "$ACT" 's#^            synchronized (PUSH_DOZE_LOCK) {#            if (own.isEmpty()) return;\n&#'
  mut    "the DOZE-ARM send removed from applyRoamedDozeApps"         c_apply "$ACT" '/DaemonSocket.roundTrip("DOZE-ARM\\n/d'
  mut    "the apply reads the wrong daemon verb"                       c_apply "$ACT" 's#GET-DOZE-APPS#GET-APPS#'
  mut    "the apply no longer re-binds by current appId"               c_apply "$ACT" 's#for (String pkg : own) { ensurePushDozeFor(this, pem, pkg); n++; }#for (String pkg : own) { n++; }#'
  mut    "the login apply call is deleted"                             c_applycall "$ACT" '/applyRoamedDozeApps(uid);/d'
  mut    "the login apply is wrapped in dead code"                     c_applycall "$ACT" 's#^                applyRoamedDozeApps(uid);.*$#                if (false) {\n&\n                }#'
  mut    "the switch-in is posted before the login apply"             c_applyorder "$ACT" 's#^                provisionRoamedApps(uid);#                runOnUiThread(() -> switchToUser(uid));\n&#'
  mutdir "a second dropForeign call site"                             c_drop_callers ChooserActivity.java 's#^                applyRoamedPrefs();#                DozeAppsMirror.dropForeign(this, null, null);\n&#'
  mutdir "an in-file wrapper around dropForeign"                      c_drop_callers DozeAppsMirror.java 's#^    static void registerRemovalSweep(Context ctx) {#    static int dropAll(Context c, PowerExemptionManager p) { return dropForeign(c, p, new java.util.HashSet<>()); }\n&#'
  mut    "the switch-in post is deleted (no vacuous pass)"            c_applyorder "$ACT" '/switchToUser(uid, ownedLbls)/d'
  mutdir "a second login apply call site"                             c_drop_callers ChooserActivity.java 's#^                ensureRoamedHomeRole(uid);#                applyRoamedDozeApps(uid);\n&#'
  mut    "dropForeign is inverted (drops the profile's own set)"       c_drop "$DM" 's#candidate(ai, allow) \&\& !own.contains(ai.packageName)#candidate(ai, allow) \&\& own.contains(ai.packageName)#'
  mut    "dropForeign skips user 0"                                    c_drop "$DM" '/        users.add(0);/d'
  mut    "dropForeign skips the secondary users"                       c_drop "$DM" '/for (UserHandle u : dpm.getSecondaryUsers(admin)) users.add(u.getIdentifier());/d'
  mut    "dropForeign removes inside the listing loop"                 c_drop "$DM" 's#drop.add(ai.packageName);#{ drop.add(ai.packageName); pem.removeFromPermanentAllowList(ai.packageName); }#'
  mut    "PUSH_DOZE_LOCK goes private again"                           c_lockshared "$ACT" 's#^    static final Object PUSH_DOZE_LOCK#    private static final Object PUSH_DOZE_LOCK#'
  # The live record.
  mut    "the live record arms even after a FAILED read"               c_apply "$ACT" 's#if (lines != null \&\& dropped >= 0) {#if (dropped >= 0) {#'
  mut    "the live record arms even after a FAILED reset"              c_apply "$ACT" 's#if (lines != null \&\& dropped >= 0) {#if (lines != null) {#'
  mut    "an earlier arm is not dropped before the reset"              c_apply "$ACT" '/        DozeAppsMirror.disarmLiveRecord(); \/\/ any reset invalidates an earlier arm/d'
  mut    "the login read is not strict (back to roundTripLines)"       c_apply "$ACT" 's#DaemonSocket.roundTripLinesOrNull("GET-DOZE-APPS#DaemonSocket.roundTripLines("GET-DOZE-APPS#'
  mut    "a failed read returns an empty list"                         c_ornull "$DS" '/static List<String> roundTripLinesOrNull/,/^    }/{s#^            return null;#            return lines;#}'
  mut    "an unreachable daemon returns an empty list"                 c_ornull "$DS" '/static List<String> roundTripLinesOrNull/,/^    }/{s#if (s == null) return null;#if (s == null) return lines;#}'
  mut    "the relay is not debounced"                                  c_relayreg "$DM" 's#h.postDelayed(relay, RELAY_QUIET_MS);#h.post(relay);#'
  mut    "the relay listens to the temp-allowlist broadcast"           c_relayfilter "$DM" 's#new android.content.IntentFilter(android.os.PowerManager.ACTION_POWER_SAVE_WHITELIST_CHANGED)#new android.content.IntentFilter(android.os.PowerManager.ACTION_POWER_SAVE_TEMP_WHITELIST_CHANGED)#'
  mut    "the relay registration ignores relayFilter"                  c_relayreg "$DM" 's#}, relayFilter(), null, h, Context.RECEIVER_NOT_EXPORTED);#}, new android.content.IntentFilter(Intent.ACTION_USER_SWITCHED), null, h, Context.RECEIVER_NOT_EXPORTED);#'
  mut    "registerLiveRecordRelay loses its user-0 guard"              c_relayreg "$DM" '/static void registerLiveRecordRelay/,/^    }/{/        if (UserHandle.myUserId() != 0) return;/d}'
  mut    "the relay ignores the arm (any current session)"             c_relay "$DM" '/                if (cur != liveUid) return;/d'
  mut    "the relay reaches a locked session"                          c_relay "$DM" '/if (um == null || !um.isUserUnlocked(UserHandle.of(cur))) return;/d'
  mut    "the relay fires when nothing changed"                        c_relay "$DM" '/                if (now.equals(liveSeen)) return;/d'
  mut    "the relay targets the gate itself"                           c_relay "$DM" 's#if (cur <= 0) return;#if (cur < 0) return;#'
  mut    "the relay carries the names"                                 c_relay "$DM" 's#.addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)#.putExtra("names", now.toString()).addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)#'
  mut    "the relay trace prints the names"                            c_relay "$DM" 's#"pushdoze-relay user=" + cur#"pushdoze-relay user=" + cur + liveSeen#'
  mut    "the relay forgets what it sent"                              c_relay "$DM" '/                liveSeen = now;/d'
  mut    "the arm keeps no baseline"                                   c_live "$DM" 's#synchronized (LIVE_LOCK) { liveSeen = seen; liveUid = uid; }#synchronized (LIVE_LOCK) { liveUid = uid; }#'
  mut    "disarm leaves the session armed"                             c_live "$DM" 's#synchronized (LIVE_LOCK) { liveUid = -1; liveSeen = null; }#synchronized (LIVE_LOCK) { liveSeen = null; }#'
  mut    "the receiver acts in user 0"                                 c_receiver "$RCV" '/        if (android.os.UserHandle.myUserId() == 0) return;/d'
  mut    "the receiver no longer re-records"                           c_receiver "$RCV" 's#DozeAppsMirror.capture(app);##'
  mut    "the receiver is exported"                                    c_manifest "$MAN" 's#android:name=".DozeCaptureReceiver" android:exported="false"#android:name=".DozeCaptureReceiver" android:exported="true"#'
  mut    "the receiver is not declared"                                c_manifest "$MAN" '/android:name=".DozeCaptureReceiver"/d'
  mut    "the relay registration is deleted"                           c_appcall "$NAPP" '/DozeAppsMirror.registerLiveRecordRelay(this);/d'
  mut    "a second, fully-qualified, exported receiver declaration"    c_manifest "$MAN" 's#^    <receiver android:name=".DozeCaptureReceiver" android:exported="false"/>#&\n    <receiver android:name="com.nowhere.chooser.DozeCaptureReceiver" android:exported="true"/>#'
  mut    "capture no longer keeps names of apps not installed here"    c_capture "$DM" '/keep.addAll(absentFrom(installed, new java.io.File(dir, "nowhere-doze-apps"),$/d'
  mut    "absentFrom keeps installed apps too (resurrects a turned-off choice)" c_absent "$DM" 's#absentKept(names, recorded, #absentKept(new java.util.HashSet<String>(), recorded, #'
  mut    "absentFrom reads the record without the installed check"     c_absent "$DM" '/for (ApplicationInfo ai : installed) names.add(ai.packageName);/d'
  mut    "the relay is not retried on a user switch"                   c_relayfilter "$DM" '/f.addAction(Intent.ACTION_USER_SWITCHED);/d'
  mut    "the relay is not retried on an unlock"                       c_relayfilter "$DM" '/f.addAction(Intent.ACTION_USER_UNLOCKED);/d'
  mut    "the departed session stays armed (names kept in memory)"     c_reg "$DM" '/disarmLiveRecordFor(departed); \/\/ its names leave/d'
  mut    "the apply accepts an unframed reply"                         c_apply "$ACT" 's#if (lines == null || lines.isEmpty() || !"OK".equals(lines.get(0))) lines = null;#if (lines == null) lines = null;#'
  mut    "the apply reads the OK header as a package"                  c_apply "$ACT" 's#lines.subList(1, lines.size())#lines#'
  mut    "a failed roamd copy no longer removes the file"              c_surface "$ROAMD" '/|| rm -f "\$STATE\/doze-apps.out"; }/d'
  mut    "a failed daemon read is not reported as ERR"                 c_handler "$GO" 's#fmt.Fprint(conn, "ERR\\n")#return#'
  mutdir "an in-file wrapper around capture"                           c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static void captureAll(Context c) { capture(c); }\n&#'
  mutdir "an unguarded second relay sender"                            c_live_callers DozeAppsMirror.java 's#^    static android.content.IntentFilter relayFilter() {#    static void relayNow(Context a) { a.sendBroadcast(new Intent(a, DozeCaptureReceiver.class)); }\n&#'
  mutdir "an in-file wrapper around armLiveRecord"                     c_live_callers DozeAppsMirror.java 's#^    static void disarmLiveRecord() {#    static void rearm(Context c, int u, PowerExemptionManager p) { armLiveRecord(c, u, p); }\n&#'
  mutdir "the relay is registered twice"                               c_live_callers NowhereApp.java 's#^        DozeAppsMirror.registerLiveRecordRelay(this); // NWP-20261002-03#&\n        DozeAppsMirror.registerLiveRecordRelay(this);#'
  mutdir "the live record is armed outside the login apply"            c_live_callers ProfileActivity.java 's#^        mirrorWifiToGate();#&\n        DozeAppsMirror.armLiveRecord(this, 0, null);#'
  # The refutation's escapes (NWP-20261002-03, third round): each stayed green on the previous suite.
  mut    "the relay is registered for user 0 only (never hears a session's unlock)" c_relayreg "$DM" 's#app.registerReceiverForAllUsers(new android.content.BroadcastReceiver() {#app.registerReceiver(new android.content.BroadcastReceiver() {#'
  mutdir "a wrapper around capture after a one-line javadoc"           c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    /** w */ static void captureAll(Context c) { capture(c); }\n&#'
  mutdir "a wrapper around capture on a block comment's closing line"  c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    /* w\n     */ static void captureAll(Context c) { capture(c); }\n&#'
  mutdir "a method reference to capture"                               c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static final java.util.function.Consumer<Context> CAP = DozeAppsMirror::capture;\n&#'
  mutdir "a method reference to capture from another file"             c_cap_callers ProfileActivity.java 's#^        mirrorWifiToGate();#&\n        java.util.function.Consumer<android.content.Context> c = DozeAppsMirror::capture;#'
  mutdir "a method reference to relayToLiveSession"                    c_live_callers DozeAppsMirror.java 's#^    static android.content.IntentFilter relayFilter() {#    static final java.util.function.Consumer<Context> RELAY = DozeAppsMirror::relayToLiveSession;\n&#'
  mutdir "a wrapper around armLiveRecord after a one-line javadoc"     c_live_callers DozeAppsMirror.java 's#^    static void disarmLiveRecord() {#    /** x */ static void rearm(Context c, int u, PowerExemptionManager p) { armLiveRecord(c, u, p); }\n&#'
  mutdir "a second sender on a continuation line starting with *"      c_live_callers DozeAppsMirror.java 's#^    static android.content.IntentFilter relayFilter() {#    static int relayNow(Context a) { return 1\n        * sendTo(a, DozeCaptureReceiver.class); }\n&#'
  mutdir "a method reference to sweepDeparted from another file"       c_sweep_callers ChooserActivity.java 's#^                applyRoamedDozeApps(uid);#                java.util.function.BiConsumer<Context, Integer> s = DozeAppsMirror::sweepDeparted;\n&#'
  mut    "roamd recreates an empty set after a failed copy"            c_surface "$ROAMD" 's#^             || rm -f "\$STATE/doze-apps.out"; }$#&\n      [ -e "$STATE/doze-apps.out" ] || : > "$STATE/doze-apps.out"#'
  mut    "a second, unframed GET-DOZE-APPS branch before the pinned one" c_dispatch "$GO" 's#^\tif name == "GET-DOZE-APPS" {#\tif name == "GET-DOZE-APPS" \&\& legacy {\n\t\treturn\n\t}\n&#'
  mut    "a second writer of doze-apps.out in the agent"              c_handler "$GO" 's#^func handleGetDozeApps(conn net.Conn, dest string) {#func resetDoze(dest string) { os.WriteFile(filepath.Join(dest, "doze-apps.out"), nil, 0o600) }\n\n&#'
  mut    "a second, single-quoted, exported receiver declaration"      c_manifest "$MAN" 's#^    <receiver android:name=".DozeCaptureReceiver" android:exported="false"/>#&\n    <receiver android:name='"'"'com.nowhere.chooser.DozeCaptureReceiver'"'"' android:exported='"'"'true'"'"'/>#'
  # The final-delta review's escapes (NWP-20261002-03, fourth round): each stayed green on v7.
  mutdir "a wrapper around capture after a // inside a string"         c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static void captureAll(Context c) { android.util.Log.i("NowhereChooser", "see https://x"); capture(c); }\n&#'
  mutdir "a wrapper around capture after a /* inside a // comment"     c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    // drains files/*\n    static void captureAll(Context c) { capture(c); }\n&#'
  mutdir "a wrapper around capture after a /* inside a text block"     c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static final String GLOB = """\n        files/*\n        """;\n    static void captureAll(Context c) { capture(c); }\n&#'
  mutdir "a capture call after a // in a text block, same line"         c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static void captureAll(Context c) { String u = """\n        https://x"""; capture(c); }\n&#'
  mutdir "a capture call glued to a comment (else/**/capture)"          c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static void captureAll(Context c, boolean b) { if (b) { } else/**/capture(c); }\n&#'
  mutdir "a capture call with a space before its ("                     c_cap_callers DozeAppsMirror.java 's#^    private static final Object CAPTURE_LOCK = new Object();#    static void captureAll(Context c) { capture (c); }\n&#'
  mutdir "a spaced method reference to capture from another file"     c_cap_callers ProfileActivity.java 's#^        mirrorWifiToGate();#&\n        java.util.function.Consumer<android.content.Context> c = DozeAppsMirror :: capture;#'
  mutagent "a second writer of doze-apps.out in a new agent file"      doze_reset.go 'func resetDozeApps(dest string) { os.WriteFile(filepath.Join(dest, "doze-apps.out"), nil, 0o600) }'
  mutagent "a second GET-DOZE-APPS dispatch in a new agent file"       doze_dispatch2.go 'func legacyDoze(name string) bool { return name == "GET-DOZE-APPS" }'
  # Harmless edits that must stay GREEN (each failed on v7).
  keep   "another class's method reference (WifiMirror::capture)"      c_cap_callers ChooserActivity.java 's#^    static final Object PUSH_DOZE_LOCK = new Object();#&\n    static final java.util.function.Consumer<android.content.Context> WIFI_CAP = WifiMirror::capture;#'
  keep   "a comment with a /* inside a // line (no code hidden)"      c_live_callers DozeAppsMirror.java 's#^    static void registerLiveRecordRelay(Context ctx) {#    // heard for users/* (all users)\n&#'
  # Wiring in the wrong place.
  mut    "the sweep is wired into the cold-lock receiver"              c_coldclean "$IDLE" 's#public void onReceive(Context ctx, Intent intent) {#public void onReceive(Context ctx, Intent intent) { DozeAppsMirror.sweepDeparted(ctx, 0);#'
  mutdir "dropForeign is called from ProfileActivity"                  c_drop_callers ProfileActivity.java 's#^        DozeAppsMirror.capture(this); // NWP-20261002-02#        DozeAppsMirror.dropForeign(this, null, null);\n&#'
  mutdir "capture is called from the cold-lock receiver"               c_cap_callers IdleLogoffReceiver.java 's#public void onReceive(Context ctx, Intent intent) {#public void onReceive(Context ctx, Intent intent) { DozeAppsMirror.capture(ctx);#'
  mutdir "capture is called twice in doLogoff"                         c_cap_callers ProfileActivity.java 's#^        mirrorWifiToGate();#&\n        DozeAppsMirror.capture(this);#'
  mutdir "the sweep is called from outside DozeAppsMirror"             c_sweep_callers ChooserActivity.java 's#^                applyRoamedDozeApps(uid);#                DozeAppsMirror.sweepDeparted(this, uid);\n&#'
  # The record's path through the roam.
  mut    "the doLogoff capture is removed"                             c_logoff "$PROF" '/DozeAppsMirror.capture(this); \/\/ NWP-20261002-02/d'
  mut    "doLogoff stops routing through doLogoffImpl"                 c_logoff "$PROF" 's#^        doLogoffImpl(false);#        // doLogoffImpl(false);#'
  mut    "the doLogoff capture is commented out"                       c_logoff "$PROF" 's#^        DozeAppsMirror.capture(this);#        // DozeAppsMirror.capture(this);#'
  mut    "the doLogoff capture moves after the LOGOUT write"           c_logoff "$PROF" '/^        DozeAppsMirror.capture(this); \/\/ NWP-20261002-02/d; s#^ *os.write("LOGOUT.*$#&\n                DozeAppsMirror.capture(ProfileActivity.this);#'
  mut    "the ReloginReceiver capture is removed"                      c_relogin "$REL" '/DozeAppsMirror.capture(ctx); \/\/ NWP-20261002-02/d'
  mut    "the ReloginReceiver capture is commented out"                c_relogin "$REL" 's#^                    DozeAppsMirror.capture(ctx);#                    // DozeAppsMirror.capture(ctx);#'
  mut    "the GET-DOZE-APPS dispatch is commented out"                 c_dispatch "$GO" 's#^\t\thandleGetDozeApps(conn, dest)#\t\t// handleGetDozeApps(conn, dest)#'
  mut    "handleGetDozeApps no longer writes the reply"                c_handler "$GO" '/^func handleGetDozeApps/,/^}/{/conn.Write(append(/d}'
  mut    "the header and the set are written separately again"         c_handler "$GO" 's#conn.Write(append(\[\]byte("OK\\n"), b...))#fmt.Fprint(conn, "OK\\n"); conn.Write(b)#'
  mut    "the offline roam-in no longer truncates doze-apps.out"       c_offline "$GO" '/filepath.Join(dest, "doze-apps.out"), \[\]byte{}, 0o600)/d'
  mut    "the offline truncation is wrapped in dead code"              c_offline "$GO" 's#^\tos.WriteFile(filepath.Join(dest, "doze-apps.out").*$#\tif false {\n&\n\t}#'
  mut    "roamd's doze surfacing moved out of the apps.out block"      c_surface "$ROAMD" '/^      # NWP-20261002-02: surface this profile.s own battery-Unrestricted app set/d'
  mut    "roamd no longer truncates doze-apps.out first"               c_surface "$ROAMD" '/^      ( : > "\$STATE\/doze-apps.out" )$/d'
  mut    "roamd no longer surfaces the sealed set"                     c_surface "$ROAMD" '/cp "\$USERDIR\/com.nowhere.chooser\/files\/nowhere-doze-apps" "\$STATE\/doze-apps.out"/d'
  rm -rf "$M"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
