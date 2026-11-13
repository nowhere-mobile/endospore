package com.nowhere.chooser;

import android.app.Application;

/**
 * Process-level entry point for the Profile app (#141). Its whole job is to start the reap watcher on EVERY
 * process birth -- not just when the gate Activity is created.
 *
 * WHY THIS EXISTS. The reap watcher is the sole consumer of the daemon's no-reboot teardown queue (the
 * SWITCH/REAP/LOCK steps a logoff or a profile-delete depends on to return to the gate and remove the
 * ephemeral user). It was started only from ChooserActivity.onCreate. But the user-0 process is
 * android:persistent and can be RESTARTED by the system while a roamed session owns the screen -- at which
 * point there is no foreground gate task, so no Activity is recreated, so onCreate never runs, so the watcher
 * never starts. The queue then has no consumer and every teardown strands on its terminal screen until a
 * reboot (found by Chester deleting odtest, 2026-08-15). Application.onCreate runs on every process start,
 * Activity or not, which closes the gap. ensureReapWatcher is idempotent (user-0 guard + a started flag), so
 * the Activity call site keeps calling it with no double-start.
 */
public class NowhereApp extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        try {
            ChooserActivity.ensureReapWatcher(this);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NowhereApp: reap watcher start", t);
        }
        // NWP-20261122-07: the blocked-encrypted-DNS watcher, for the same reason as the reap watcher: this process is
        // android:persistent and can restart during a session with no gate Activity, and h49 #2 rule (ii) restores
        // strict mode at EVERY start. Idempotent (user-0 guard + a started flag).
        try {
            PrivateDnsWatch.start(this);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NowhereApp: private dns watch start", t);
        }
        // NWP-20260824-03: arm the OTA wake-up here for the SAME reason the reap watcher lives here -- this
        // process is android:persistent and can be restarted with no foreground gate task, so
        // ChooserActivity.onCreate is not a reliable place to own a device-wide timer. Idempotent
        // (FLAG_UPDATE_CURRENT replaces any pending alarm), so re-arming on every birth is free.
        try {
            OtaWakeReceiver.arm(this);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NowhereApp: ota wake arm", t);
        }
        // NWP-20261108-08: the preferred-time install alarm, for the same reason. Alarms do not survive a reboot, so it is
        // re-armed at every birth from the daemon's GET-OTA-TIME; the daemon may not be up yet, so the gate's onResume
        // arms it too. User-0 guard inside.
        try {
            OtaTimeReceiver.armFromDaemon(this);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NowhereApp: ota time arm", t);
        }
        // NWP-20260922-06: the user-switch teardown watcher belongs here for the SAME reason as the two above.
        // It has to be live whenever a session can be walked away from, and that includes the case where this
        // persistent process was restarted while a roamed session owned the screen -- exactly when no gate
        // Activity exists to register it. Idempotent (user-0 guard + a started flag).
        try {
            ChooserActivity.ensureUserSwitchWatcher(this);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NowhereApp: user-switch watcher start", t);
        }
        // NWP-20260825-19: AppInstallReceiver must be registered AT RUNTIME, not in the manifest. A manifest
        // receiver does not receive implicit broadcasts on Android 8+ unless the action is on the platform's
        // exemption list, and ACTION_PACKAGE_ADDED is not on it -- so the manifest declaration it shipped with
        // for four slices never fired once. Context-registered receivers are exempt from that ban. (Proven on
        // lynx: an explicit `am broadcast -n ...` runs it; the same broadcast sent implicitly as ROOT, which
        // already bypasses the exported check, never arrives. android:exported="true" would not have helped.)
        try {
            android.content.IntentFilter f = new android.content.IntentFilter(
                    android.content.Intent.ACTION_PACKAGE_ADDED);
            // NWP-20260904-06: also listen for REMOVAL. Same runtime-registration reason as above --
            // ACTION_PACKAGE_REMOVED is not on the implicit-broadcast exemption list either, so a manifest
            // declaration would never fire.
            f.addAction(android.content.Intent.ACTION_PACKAGE_REMOVED);
            // NWP-20261119-10: also an UPDATE (Play, or a materialise over an archived placeholder), so the code list
            // names the new /data/app dir before the next periodic seal. Same runtime-registration reason as above.
            f.addAction(android.content.Intent.ACTION_PACKAGE_REPLACED);
            f.addDataScheme("package");
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                registerReceiver(new AppInstallReceiver(), f, android.content.Context.RECEIVER_NOT_EXPORTED);
            } else {
                registerReceiver(new AppInstallReceiver(), f);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NowhereApp: install receiver register", t);
        }
        // NWP-20261130-12: a package can land while the session's process is dead; a tile that waited for it comes back
        // here. A no-op in user 0.
        new Thread(() -> SettingsRoamLive.reconcile(this), "nowhere-settings-roam").start();
        // ...and because a runtime receiver dies with its process (android:persistent covers ONLY user 0, so a
        // roamed session's chooser can be killed), reconcile on every process birth. Off the main thread: it
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
        // .ensurePushDozeExemption) when any of them is installed, replaced or removed in ANY user. A session's
        // (re)install gives the app a new appId, which is exactly what leaves the allow-list stale, and the gate
        // Activity cannot see it: it finish()es at the switch, so none of its triggers run during a session. The
        // filter lists each push package, and the handler re-scans the whole set. USER 0 ONLY -- this Application
        // also runs in session users' chooser processes, and one device-wide owner is enough. Also once at process
        // birth, for a restart while a session holds one of them.
        if (android.os.UserHandle.myUserId() == 0) {
            try {
                android.content.IntentFilter pf = new android.content.IntentFilter(android.content.Intent.ACTION_PACKAGE_ADDED);
                pf.addAction(android.content.Intent.ACTION_PACKAGE_REPLACED);
                pf.addAction(android.content.Intent.ACTION_PACKAGE_REMOVED);
                pf.addDataScheme("package");
                for (String pkg : ChooserActivity.PUSH_DOZE_PKGS)
                    pf.addDataSchemeSpecificPart(pkg, android.os.PatternMatcher.PATTERN_LITERAL);
                registerReceiverForAllUsers(new android.content.BroadcastReceiver() {
                    @Override public void onReceive(android.content.Context c, android.content.Intent i) {
                        new Thread(() -> ChooserActivity.ensurePushDozeExemption(NowhereApp.this), "nowhere-pushdoze").start();
                    }
                }, pf, null, null, android.content.Context.RECEIVER_NOT_EXPORTED);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NowhereApp: push-doze receiver register", t);
            }
            new Thread(() -> ChooserActivity.ensurePushDozeExemption(this), "nowhere-pushdoze").start();
            // NWP-20261110-15: MMS_ALWAYS_ALLOWED is a persistent per-SIM policy and its ref count (MmsInFlight) dies
            // with this process: a crash, low-memory kill or power loss inside a gate MMS download left it on, across
            // reboots. Turn it off at every user-0 process birth on each active SIM with no download in flight.
            new Thread(() -> WapPushDeliverReceiver.resetIdlePolicies(this), "nowhere-mms-policy").start();
            // NWP-20261126-10: the idle cold lock lives in this process's statics and runtime receivers, and a restart
            // during a session loses both. Once the reap watcher's self-heal marks the session live, ask the session to
            // resend its lock prefs, so applyLivePrefs re-arms the idle watcher. RestartRearm owns the window and retry.
            try {
                RestartRearm.atProcessBirth(this);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "NowhereApp: restart rearm", t);
            }
        }
    }
}
