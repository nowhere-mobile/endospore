package com.nowhere.chooser;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.PowerExemptionManager;
import android.os.UserHandle;

/**
 * NWP-20261002-02 / NWP-20261002-03 -- roam a profile's OWN battery-Unrestricted (Doze allow-list) app choices.
 * Route 2 of docs/product-decisions.md 2026-10-02; route 1 (the curated set, ChooserActivity.PUSH_DOZE_PKGS) is
 * kept device-wide by ChooserActivity.ensurePushDozeExemption and is EXCLUDED here (see candidate).
 *
 * WHY IT IS NEEDED: the Doze allow-list is device-wide and keyed package-name -> appId, and a login reinstalls
 * the app under a NEW appId, so a stale entry silently stops taking effect (the mechanism proven for Play on
 * lynx: appId 10222 -> 10230 -> 10237). So the user's choice is sealed per profile and re-applied by current
 * appId at that profile's next login (ChooserActivity.applyRoamedDozeApps).
 *
 * WHO REMOVES WHAT, AND WHEN (NWP-20261002-03). ⚠ SUPERSEDES NWP-20261002-02's "the session REMOVES the captured
 * names at logoff": that removal ran BEFORE the logoff's outcome was known, so a logoff that failed and kept the
 * session signed in (#86) left its apps de-exempted for the rest of that live session, and a retry logoff then
 * re-captured against the already-shrunken list and sealed an EMPTY set, losing the choice for good.
 *  - THE SESSION ONLY RECORDS. capture() writes files/nowhere-doze-apps (roams with the profile CE, like
 *    nowhere-apps.list) and removes nothing. No logoff outcome -- sealed, FAILED, an unanswered LOGOUT, the
 *    process dying -- can de-exempt a session that stays live, because the session no longer touches the list.
 *  - THE USER-0 GATE REMOVES, and only once the session's USER is gone: sweepDeparted runs on ACTION_USER_REMOVED,
 *    which the removal paths send (the logoff reap, DELETE, ROLLBACK, the cold-lock hard wipe, the #123
 *    supersede, the #73 orphan sweep, the boot-wipe after a battery death). The one exception: a removeUser cut
 *    short by power loss is finished at the next boot by UserManagerService's partial-user cleanup, which sends
 *    no broadcast. The framework sends it with a result receiver (unordered, but a registered receiver is then
 *    not assumed delivered) and removes the user's package state only after every receiver has returned
 *    (android16 UserManagerService.finishRemoveUser), so the departed user's packages and appIds are still
 *    readable inside onReceive.
 *  - EVERY LOGIN RESETS the user-chosen part of the list (candidate: not the curated set, not gmscompat, not a system
 *    uid; bundled apps included since Q052, NWP-20261114-26) to the arriving profile's own set (dropForeign, from
 *    applyRoamedDozeApps). That also closes the cold-lock-supersede carry: a cold-locked user keeps its packages, so
 *    install-existing in the new user reuses the same appId, and the cold-locked profile's entry would otherwise
 *    apply to the next profile.
 * The user-0 gate already owns device-wide Doze state for route 1; this makes it the only remover for route 2.
 *
 * capture() runs at the two true-logoff sites (ProfileActivity.doLogoff, ReloginReceiver) AND, during a session,
 * whenever the gate relays a change (THE LIVE RECORD, below). ⚠ SUPERSEDED: "a cold lock records nothing ... the
 * login reset drops it even when the SAME profile signs in fresh over its own cold-locked session" held until
 * the live record. A cold lock still records nothing itself (the idle lock runs in user 0, and no cold lock
 * seals), but the record is now kept current in the session, so the last periodic seal before the lock carries
 * it, and a fresh sign-in of the SAME profile restores it from that profile's own store head; a different profile
 * restores its own head and never sees it. No identity check is made: one would be an offline passphrase oracle
 * on a cold-locked phone. Residual: a change made after the last successful seal walk before a cold lock (about
 * one seal cycle, longer if the phone suspends) is lost (docs/backlog.md §B). A resume keeps everything: the
 * cold-locked session persists.
 *
 * THE LIVE RECORD: the user-0 gate hears ACTION_POWER_SAVE_WHITELIST_CHANGED (sent to user 0 only, no extras), waits
 * for a 2 s quiet spell, and relays an explicit, extra-free broadcast to DozeCaptureReceiver in the live session,
 * which re-runs capture(). It relays only to the session armed by a login apply whose GET-DOZE-APPS read (framed:
 * OK or ERR) AND reset both succeeded (so a failed read or a foreign-contaminated list is never recorded live), only
 * while that session is the current, unlocked user, and only when its own set actually changed; it also re-runs when
 * the armed session becomes current or unlocked again, so a relay dropped mid-switch is retried. A gate restart
 * mid-session leaves it disarmed (fail closed); the logoff capture still records. A capture keeps a name whose
 * app is not installed for this user only while the profile's keep record (files/nowhere-appkeep) still carries the
 * app and this session did not watch it be uninstalled (StoreInstaller.appGoneThisSession; the keep line of an
 * uninstall is pruned only at logoff, after capture). So an app this login could not provision keeps its choice, and a
 * removed app's choice goes with it (Q054, docs/product-decisions.md 2026-10-20, NWP-20261104-16). Once the app is
 * installed again, capture records what the device says (absentFrom's note).
 *
 * One predicate (candidate) serves capture, the sweep and the login reset. Logs and login.log carry counts and
 * user ids only, never a package name.
 */
final class DozeAppsMirror {
    private DozeAppsMirror() {}

    /** The user's own Unrestricted choice, under choiceEligible's rule. A bundled (FLAG_SYSTEM) app counts like a
     *  user-installed one: Q052 (docs/product-decisions.md 2026-10-20, NWP-20261114-26) makes its choice per profile,
     *  so capture records it and the sweep and the login reset remove it. Only the curated set route 1 owns,
     *  gmscompat and system or shared uids stay out. */
    static boolean candidate(ApplicationInfo ai, java.util.Set<Integer> allow) {
        return ai != null && choiceEligible(ai.packageName, UserHandle.getAppId(ai.uid),
                allow.contains(UserHandle.getAppId(ai.uid)), java.util.Arrays.asList(ChooserActivity.PUSH_DOZE_PKGS));
    }

    static final String GMSCOMPAT_PKG = "app.grapheneos.gmscompat"; // GrapheneOS's own; the image exempts it

    /** Q052 (NWP-20261114-26): a package's Doze entry is a profile's own choice unless the image itself exempts the
     *  app. Never a choice: no package name, a system or shared uid (appId below 10000), the curated set route 1
     *  keeps device-wide, or gmscompat. Anything else, bundled or user-installed, is a choice when it is on the
     *  allow-list. ⚠ allowListed merges the image's system entries with the user's, so a bundled app the image's
     *  own sysconfig exempts is a choice here too (docs/backlog.md §B, the bundled-app row's residual). Pure. */
    static boolean choiceEligible(String pkg, int appId, boolean allowListed, java.util.Collection<String> curated) {
        if (pkg == null || pkg.isEmpty()) return false;
        if (appId < 10000) return false;             // system / shared uid
        if (curated.contains(pkg)) return false;     // route 1 owns the curated set
        if (GMSCOMPAT_PKG.equals(pkg)) return false; // the image exempts gmscompat
        return allowListed;
    }

    /** The effective allow-list as appIds -- the system allow-in-power-save set plus the user list (the except-idle
     *  set is the other array, for includingIdle=false) -- the set netpolicy's Doze chain uses. */
    static java.util.Set<Integer> allowListed(PowerExemptionManager pem) {
        java.util.Set<Integer> allow = new java.util.HashSet<>();
        for (int a : pem.getAllowListedAppIds(true)) allow.add(a);
        return allow;
    }

    /** Every package installed for userId, including a stopped (CE-locked) user's and archived placeholders.
     *  ⚠ MATCH_ARCHIVED_PACKAGES is a LONG, so it only reaches PM through ApplicationInfoFlags.of() -- the int
     *  overload would silently drop it (ProfileActivity's keptFlags note). The direct-boot flags are explicit
     *  because a departed or cold-locked user is CE-locked. Exceptions propagate: every caller fails closed. */
    static java.util.List<ApplicationInfo> installedFor(Context ctx, int userId) {
        PackageManager pm = userId == UserHandle.myUserId() ? ctx.getPackageManager()
                : ctx.createContextAsUser(UserHandle.of(userId), 0).getPackageManager();
        return pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(
                PackageManager.MATCH_ARCHIVED_PACKAGES | PackageManager.MATCH_DIRECT_BOOT_AWARE
                        | PackageManager.MATCH_DIRECT_BOOT_UNAWARE));
    }

    /** The live-record arm's and the relay's listing: userId's own choices, archived apps included (installedFor), so
     *  an on-demand app still archived at logoff keeps its choice. capture applies the same pair (installedFor +
     *  recordOf) to a listing it shares with absentFrom, so a filter belongs in recordOf or installedFor, never here.
     *  Exceptions propagate. */
    static java.util.TreeSet<String> recordFor(Context ctx, int userId, java.util.Set<Integer> allow) {
        return recordOf(installedFor(ctx, userId), allow);
    }

    /** recordFor over a listing the caller already holds, so capture judges both of its halves on ONE listing.
     *  Sorted, so the record is written stably. */
    static java.util.TreeSet<String> recordOf(java.util.List<ApplicationInfo> installed, java.util.Set<Integer> allow) {
        java.util.TreeSet<String> out = new java.util.TreeSet<>();
        for (ApplicationInfo ai : installed) if (candidate(ai, allow)) out.add(ai.packageName);
        return out;
    }

    /** NWP-20261104-16 (Q054, docs/product-decisions.md 2026-10-20): the packages the profile's own keep record
     *  (files/nowhere-appkeep, lines `pkg[\tmode[\tgroup:<name>]]`) carries -- the package field of every non-blank,
     *  non-`#` line. An absent file carries nothing (an EMPTY set). A read error returns null, never an empty set:
     *  an unreadable record must not read as "the profile carries no app". Takes no lock: every keep writer lands by
     *  temp + rename under StoreInstaller.APPKEEP_LOCK, so a reader sees a whole file, and capture holds CAPTURE_LOCK,
     *  which APPKEEP_LOCK must never nest inside. */
    static java.util.Set<String> keptPackages(java.io.File keep) {
        java.util.Set<String> out = new java.util.HashSet<>();
        if (!keep.exists()) return out;
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.FileReader(keep))) {
            String l;
            while ((l = br.readLine()) != null) {
                l = l.trim();
                if (l.isEmpty() || l.startsWith("#")) continue;
                String pkg = l.split("\t", 2)[0].trim();
                if (!pkg.isEmpty()) out.add(pkg);
            }
        } catch (java.io.IOException e) {
            return null;
        }
        return out;
    }

    /** NWP-20261104-16 (Q054): of the recorded names, those whose app is NOT installed that the profile still
     *  carries (kept) and this session did not watch leave (gone). An app the sign-in could not provision is still in
     *  the keep record and kept; an app the user uninstalled is dropped -- this session's uninstall by gone (its keep
     *  line is pruned only at logoff, by captureAppCode, AFTER capture), an earlier session's by kept. kept == null
     *  (the keep record could not be read) keeps every absent name not in gone: an unreadable record must not drop
     *  choices, and an uninstall this session watched is still gone. Installed names are never returned: capture
     *  records what the device says for them. Pure. */
    static java.util.Set<String> absentKept(java.util.Set<String> installed, java.util.List<String> recorded,
            java.util.Set<String> kept, java.util.Set<String> gone) {
        java.util.TreeSet<String> out = new java.util.TreeSet<>();
        for (String p : recorded) {
            if (installed.contains(p) || gone.contains(p)) continue;
            if (kept != null && !kept.contains(p)) continue;
            out.add(p);
        }
        return out;
    }

    /** The names in the existing record whose package is NOT in the listing (installed for this user, not even
     *  archived) and that absentKept keeps: only while the profile's keep record (keepFile) still carries the app
     *  and this session (gone) did not watch it be uninstalled. An app this login could not provision is not a
     *  choice turned off, so capture keeps its name; a deliberate uninstall means the app is gone (the 2026-09-06
     *  decision), so its choice goes too, and a later reinstall comes back Optimized (Q054, NWP-20261104-16). Once
     *  the app is installed again capture records what the device says, so an app reinstalled in the session comes
     *  back Optimized, as on stock Android (Q054's (1), accepted). A record that cannot be read throws, so capture
     *  leaves it untouched rather than overwrite what it could not read. */
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

    private static final Object CAPTURE_LOCK = new Object();

    /** THE SESSION: record this profile's own choices, never remove. Called SYNCHRONOUSLY at a true logoff, before
     *  the logoff is sent (so the file is written before roamd seals the CE), and from DozeCaptureReceiver when the
     *  gate relays a change during the session (the live record; the next periodic seal carries it). Read and write
     *  both run under CAPTURE_LOCK, so the last writer has also read last; the write is atomic (tmp + rename), so a
     *  capture killed mid-write leaves the previous record. Written even when empty, so a choice the user turned OFF
     *  does not resurrect at the next login -- unless the existing record cannot be read: absentFrom throws, and the
     *  record stays as it was restored. An absent name is kept only under absentKept's rule (the gone set is read
     *  before the lock, for lock order). Both halves are judged on ONE listing, so an app that is installed or removed
     *  mid-capture cannot be counted as present by one half and absent by the other.
     *  NWP-20261117-06 (dn-1023 #3): first it asks the login daemon GET-DOZE-ARM; an UNARMED answer (the gate's login
     *  apply did not arm) returns before anything is read or written, so the record stays as restored. The wait,
     *  connect included, is capped at 1.5 s, because a true logoff runs this on the UI thread; no answer captures.
     *  Best-effort; never throws. */
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

    /** USER 0, on ACTION_USER_REMOVED: drop the departed user's own choices from the device-wide list, by name. A
     *  package another existing secondary user still holds (live, cold-locked or orphan) is KEPT -- removing it would
     *  de-exempt a session that can still resume. The holders are listed IN FULL before anything is removed, and
     *  any listing failure removes nothing: fail closed, because a stale entry is residue while a wrong removal is
     *  a live de-exemption. User 0 is deliberately not a holder: nobody makes choices on the gate.
     *  Q052 (NWP-20261114-26): every user holds a bundled app, so it goes at the last one's removal or dropForeign. */
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

    /** USER 0, at login (applyRoamedDozeApps, which holds PUSH_DOZE_LOCK): remove every candidate entry, for a
     *  package installed for ANY existing user including user 0, that the arriving profile's own set does not
     *  name. Collect everything first and remove only after ALL listing succeeded; a listing failure propagates
     *  and removes nothing. ⚠ Unlike the sweep, failing here is the LEAK-OPEN direction (a foreign entry stays
     *  live for this session), which is why the caller retries once and traces `dropped=-1`. Returns how many
     *  names it removed. */
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

    /** USER 0, at every process birth (NowhereApp): run sweepDeparted on ACTION_USER_REMOVED. Runtime-registered so
     *  it runs on its own HandlerThread inside the persistent user-0 process (USER_REMOVED is on the platform's
     *  implicit-broadcast exemption list, so the NWP-20260825-19 manifest rule is not the reason). NOT
     *  ACTION_USER_STOPPED, which fires on every resumable cold lock. The sweep runs SYNCHRONOUSLY on that
     *  HandlerThread, never a new Thread: the framework waits for onReceive to return before it removes the user's
     *  packages, which is why they are still readable there. Delivered because the chooser holds MANAGE_USERS. */
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

    // ---- THE LIVE RECORD (NWP-20261002-03). User-0 process memory only: never logged, never persisted. ----
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

    /** USER 0, at every process birth (NowhereApp): on any relayFilter broadcast -- ACTION_POWER_SAVE_WHITELIST_CHANGED
     *  (sent to user 0 only, to registered receivers only, no extras, on every change to the list's names), or a user
     *  switch or unlock -- wait for a 2 s quiet spell, then relayToLiveSession. Its own HandlerThread, so neither the
     *  wait nor the listing touches the UI thread. The constant is @hide; the chooser builds with platform_apis.
     *  ⚠ Registered for ALL users (INTERACT_ACROSS_USERS_FULL): ACTION_USER_UNLOCKED goes only to the user being
     *  unlocked, so a user-0-only registration never hears a session's unlock -- the class of ACTION_USER_PRESENT,
     *  which ChooserActivity's idle receiver registers the same way. The other two reach it as well: the allow-list
     *  broadcast goes to user 0, ACTION_USER_SWITCHED to every user. */
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

    /** What re-runs the relay: a change to the allow-list's names, and the armed session becoming current or unlocked
     *  again -- a relay that gave up because the session was not current (a lock within the quiet spell) or not yet
     *  unlocked is then retried, since liveSeen was not advanced. The unlock is heard only because the registration
     *  covers all users (registerLiveRecordRelay). */
    static android.content.IntentFilter relayFilter() {
        android.content.IntentFilter f =
                new android.content.IntentFilter(android.os.PowerManager.ACTION_POWER_SAVE_WHITELIST_CHANGED);
        f.addAction(Intent.ACTION_USER_SWITCHED);
        f.addAction(Intent.ACTION_USER_UNLOCKED);
        return f;
    }

    /** USER 0: ask the live session to re-record its own set, only when (a) the current user is a session, (b) it is
     *  the session the last successful login apply armed, (c) it is unlocked, and (d) its own set differs from what
     *  was last recorded or relayed -- so the gate's own churn (route 1, the sweep, the login reset) relays nothing.
     *  The intent is explicit and carries nothing: capture reads the system itself. Traces the user id only. */
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
}
