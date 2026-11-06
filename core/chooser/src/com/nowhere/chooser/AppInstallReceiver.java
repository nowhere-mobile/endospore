package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** NWP-20260825-15/-18/-19: apply the profile's configured default when an app is installed.
 *
 *  ⚠ NWP-20260825-19 -- THIS CLASS NEVER RAN. It was declared in the manifest with an intent-filter on
 *  ACTION_PACKAGE_ADDED, and a MANIFEST receiver does not receive implicit broadcasts on Android 8+ unless the
 *  action is on the platform's exemption list. PACKAGE_ADDED is not. So every version of this receiver since
 *  -15 was dead code, and the two slices that "fixed" it (-17's collapse to two buckets, -18's restoration of
 *  four) were both diagnosing a classifier that was never reached. Device-proven on lynx 2026-08-25: an
 *  explicit `am broadcast -n com.nowhere.chooser/.AppInstallReceiver` fires it and logs
 *  `bucket=aurora default=auto -> kept`, while the SAME broadcast sent implicitly -- as root, so the exported
 *  check is already bypassed -- reaches AudioService and ShortcutService and never reaches us.
 *  ⚠ `android:exported="true"` would NOT have fixed it: the ban is on manifest registration, not on export.
 *  So the receiver is registered AT RUNTIME from NowhereApp, which is exempt, and the manifest entry is gone.
 *
 *  ⚠ A RUNTIME RECEIVER DIES WITH ITS PROCESS, which is the tradeoff being bought: a manifest receiver can
 *  start a dead process, a runtime one cannot. android:persistent only keeps the USER-0 process alive, so in a
 *  roamed session the chooser can be killed and an install would then go unseen. applyDefaultsToUndecided()
 *  is the backstop, and it makes the outcome deterministic rather than probabilistic.
 *
 *  ⚠ NEW INSTALLS ONLY. It fires on ACTION_PACKAGE_ADDED, so it cannot reach back and change an app already on
 *  the profile. Chester chose that explicitly: making a default retroactive would mean setting a default to Off
 *  silently stopped existing apps roaming and dropped their data at the next logoff. EXTRA_REPLACING is skipped
 *  for the same reason -- an update is not a new install. That rule is about the keep DEFAULT: since
 *  NWP-20261119-10 an install or an update of a KEPT app re-captures its code line (recaptureCode), which is not a
 *  keep decision.
 *
 *  ⚠ BUNDLED APPS MUST BE SKIPPED. Every login, provisionRoamedApps runs `pm install-existing` over baseApps()
 *  -- the launcher-visible bundled apps, 28 of them on lynx -- and install-existing DOES broadcast
 *  PACKAGE_ADDED for the target user. Those carry no installer, so they land in the catch-all bucket; without
 *  this guard a non-Off catch-all would write ~28 keep lines at every login for apps that ship in the image.
 *
 *  ⚠ AN EXPLICIT OFF IS A CHOICE, AND keepInMode CANNOT SEE IT. Turning an app off REMOVES its keep line, so
 *  nowhere-appkeep looks identical to never-decided. Re-keeping cancels the drop outright, sealing data the
 *  user asked us to let go -- so the off list is consulted here. */
public class AppInstallReceiver extends BroadcastReceiver {

    /** NWP-20261029-19: the one serial worker onReceive hands every package broadcast to (see onReceive). */
    private static final java.util.concurrent.ExecutorService WORKER =
            java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
                Thread t = new Thread(r, "nowhere-appinstall");
                t.setDaemon(true);
                return t;
            });

    @Override
    public void onReceive(Context context, Intent intent) {
        // NWP-20261029-19 (backlog row "Three UI-thread paths still wait on `APPKEEP_LOCK`"): this receiver is
        // registered at runtime with no Handler, so it runs on the MAIN thread, and its body reaches
        // StoreInstaller.APPKEEP_LOCK (decide -> keepSetHas / keepInMode / appGoneThisSession, noteAppGone).
        // That lock is a leaf held for milliseconds, but this path must not wait on it from the main thread:
        // any slow work later added under the lock would freeze it. So the WHOLE body runs on ONE serial worker
        // under goAsync(); one thread keeps broadcasts in arrival order (an update's removed+added, an uninstall
        // then a reinstall). The logic and its guards are unchanged -- only where they run.
        final PendingResult pending = goAsync();
        WORKER.execute(() -> {
            try {
                // NWP-20260904-06: THE UNINSTALL HALF. A keep line is a claim the app exists; the removal
                // broadcast is the moment that claim stops being true, so act on it directly instead of
                // inferring it at logoff from a session receipt.
                //
                // This is the fix Chester asked for after reproducing the bug on a clean profile: "the keep-set
                // should get updated when an app gets uninstalled ... that is fine for an installed app set to
                // Off in Your apps, but not for uninstalled." The receipt gate exists because no POINT-IN-TIME
                // query separates "the user removed it" from "on-demand, not materialised yet" -- but a removal
                // broadcast is not a point-in-time query, it is the TRANSITION the receipt was invented to
                // approximate. Acting on it needs no receipt, so it also covers the two doors that never wrote
                // one (a Play/Aurora/sideload heal, and the Your-apps mode toggle).
                if (Intent.ACTION_PACKAGE_REMOVED.equals(intent.getAction())) {
                    android.net.Uri d = intent.getData();
                    String gone = d == null ? null : d.getSchemeSpecificPart();
                    if (gone == null || gone.isEmpty() || gone.equals(context.getPackageName())) return;
                    // An UPDATE fires removed+added; dropping the keep line there would silently un-keep an app
                    // the user still has, on every update.
                    if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return;
                    // An ARCHIVE (on-demand parking) also broadcasts removal. Reading that as an uninstall would
                    // delete the very opt-in that makes the app on-demand -- the exact regression NWP-20260821-15
                    // guards against. EXTRA_ARCHIVAL is API 35+, so it is read by name; and the pmKnows check
                    // below is the real guard, since an archived placeholder stays KNOWN to PM.
                    try {
                        if (intent.getBooleanExtra("android.intent.extra.ARCHIVAL", false)) return;
                    } catch (Throwable ignore) {}
                    try {
                        if (ProfileActivity.pmKnows(context.getPackageManager(), gone)) return; // still known -> not gone
                    } catch (Throwable ignore) { return; } // unknown => assume present => never prune
                    StoreInstaller.noteAppGone(context, gone);
                    return;
                }
                // NWP-20261119-10: an UPDATE (Play, or a materialise over an archived placeholder) moves the app to a
                // new /data/app dir, so its code line is re-captured. Android sends ADDED(EXTRA_REPLACING) and then
                // REPLACED for one update; the ADDED branch below already ran decide, heal and the SMS role for it,
                // so this branch does the re-capture ONLY.
                if (Intent.ACTION_PACKAGE_REPLACED.equals(intent.getAction())) {
                    android.net.Uri u = intent.getData();
                    String up = u == null ? null : u.getSchemeSpecificPart();
                    if (up == null || up.isEmpty() || up.equals(context.getPackageName())) return;
                    recaptureCode(context, up, "update");
                    return;
                }
                if (!Intent.ACTION_PACKAGE_ADDED.equals(intent.getAction())) return;
                android.net.Uri data = intent.getData();
                String pkg = data == null ? null : data.getSchemeSpecificPart();
                if (pkg == null || pkg.isEmpty() || pkg.equals(context.getPackageName())) return;
                boolean replacing = intent.getBooleanExtra(Intent.EXTRA_REPLACING, false);
                decide(context, pkg, replacing, "broadcast");
                heal(context, pkg, replacing);
                // NWP-20261010-13: the profile's SMS app may be this one, reinstalled -- it takes its role back.
                SmsRoleRoam.onMaterialised(context, pkg);
                if (!replacing) recaptureCode(context, pkg, "new"); // NWP-20261119-10: REPLACED covers an update
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "AppInstallReceiver", t);
            } finally {
                pending.finish();
            }
        });
    }

    /** THE BACKSTOP for the runtime receiver's one weakness -- a session whose chooser process was dead when
     *  the install landed. A third-party package in NEITHER nowhere-appkeep NOR nowhere-appoff.list has never
     *  been decided about, and on an amnesiac device that means it arrived during THIS session: every restored
     *  app carries a keep line (that is why it was restored) and so does every on-demand placeholder. So
     *  "third-party AND undecided" is exactly the set the receiver would have acted on.
     *
     *  This is therefore NOT the retroactive behaviour Chester ruled out -- it cannot touch an app the user has
     *  decided about in either direction, and it is idempotent. */
    static void applyDefaultsToUndecided(Context ctx) {
        try {
            // The gate holds no session apps, and its own files dir is not a profile. Public-API form of
            // "am I user 0" (UserHandle.SYSTEM and UserHandle.myUserId() are both @hide).
            if (android.os.Process.myUserHandle().equals(
                    android.os.UserHandle.getUserHandleForUid(android.os.Process.SYSTEM_UID))) return;
            android.content.pm.PackageManager pm = ctx.getPackageManager();
            int n = 0;
            for (android.content.pm.ApplicationInfo ai : pm.getInstalledApplications(0)) {
                if (ai.packageName == null || ai.packageName.equals(ctx.getPackageName())) continue;
                if ((ai.flags & (android.content.pm.ApplicationInfo.FLAG_SYSTEM
                        | android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0) continue;
                if (decide(ctx, ai.packageName, false, "catch-up")) n++;
            }
            if (n > 0) {
                android.util.Log.i("NowhereChooser", "install default catch-up: applied to " + n
                        + " undecided app(s) (NWP-20260825-19)");
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "applyDefaultsToUndecided", t);
        }
    }


    /** NWP-20260903-11 (NWP-20260820-10 + the Play "You're offline" row): the install-heal. Every install
     *  path except the tap left two things broken: an on-demand app's PARKED data stayed sealed in the hold
     *  (the app came up factory-fresh -- nApps, Aurora, Play and sideload all bypassed RESTORE-ODDATA, and
     *  the accidental tap-path self-heal could then DOWNGRADE-install our sealed APK over a newer one), and
     *  a freshly installed app could land with INTERNET granted=false, no USER_SET, across two installers
     *  (device-measured: vending AND a Play-installed app, same evening) -- Play's only symptom being its
     *  own "You're offline" screen. ONE existing verb fixes both: RESTORE-ODDATA moves the hold back when
     *  one exists and ALWAYS runs roamd's package-filtered grant_perms_for -- the same INTERNET-default the
     *  next login would apply, just not hours late. Its no-hold reply is a documented clean "OK NOSRC".
     *
     *  UNLIKE decide(), THIS FIRES ON EXTRA_REPLACING TOO. An install over the ARCHIVED PLACEHOLDER --
     *  Play updating an on-demand app, the row's own case -- is a replacement by PackageManager's lights,
     *  and the reunite must still happen. decide() skipping updates is Chester's recorded keep-line rule;
     *  the heal is not a keep decision. A plain update with no hold costs one idempotent NOSRC grant.
     *
     *  THE MARKER IS WRITTEN ON EVERY OK, NOSRC INCLUDED: once the real APK is installed and any hold is
     *  reunited, a later launcher tap must LAUNCH, not materialise our sealed (possibly older) APK over the
     *  installed one -- writing the marker is what closes the downgrade half of the row. (Since
     *  NWP-20261012-04 the marker is no longer a downgrade guard at all: an app that has code is never
     *  installed over, marker or not -- UnarchiveService.autoAction.)
     *
     *  ⚠ NWP-20260922-09 -- THE MARKER DOES TWO JOBS AND THEY NOW DISAGREE ON ONE PATH. It closes the
     *  downgrade half (above) AND it records that the DATA restore landed, which is what lets a later tap
     *  re-materialise anything that did not (markOdRestored's own comment). Those never conflicted only
     *  because roamd answered "OK" even when it had deliberately KEPT every hold -- so the downgrade half
     *  was closed by suppressing the data retry, silently, and a hold stranded that way stayed stranded for
     *  the life of the profile. That is the WhatsApp loss: the stale hold then roamed beside the real data
     *  and hold_ondemand handed it back over the top on every later login.
     *
     *  roamd now answers ERR-NOTREADY on exactly that path, so THIS CASE WRITES NO MARKER. ~~A later tap
     *  re-materialises -- which re-fires RESTORE-ODDATA (the only thing that can un-strand the hold) and may
     *  re-install our sealed, possibly older APK over the installed one. That downgrade is the accepted cost.~~
     *  SUPERSEDED by NWP-20261012-04: the two jobs are split. The marker now records ONLY that the restore
     *  landed. Nothing that has code is ever fetched or installed again, whoever installed it (this heal's
     *  installers, or our own materialise): UnarchiveService.autoAction gives it a RESTORE-ODDATA retry and
     *  nothing more, in the sweep, a queued tap and a group's dep list. So a missing marker retries the
     *  restore without re-downloading or re-installing the APK -- what NWP-20260923-01 requires before
     *  odrestore's reply may go per-volume -- and that is still this op's own rule: "keeping a hold is
     *  always recoverable, consuming one wrongly never is".
     *
     *  BROADCAST-ONLY, deliberately: a dead-chooser install misses this and self-heals at the NEXT login
     *  (the hold rides the seal and the normal restore reunites it) -- the pre-existing behaviour, not a
     *  regression. For an Auto app the next #130 sweep also retries its restore, restore-only
     *  (NWP-20261012-04). The catch-up walk cannot see the root-owned hold, so a catch-up heal would fire blind on
     *  every undecided app at every chooser start.
     *
     *  NWP-20261128-05: THE HEAL RETRIES. One send gave up after 130 s while a seal can hold the RW slot for 7-9
     *  minutes, and nothing in the session retried an On-demand app, so it ran on fresh data. ~~The "no reply -- next
     *  login reunites" outcome~~ is superseded for the session: an empty reply, ERR-WORKER-BUSY, ERR-TIMEOUT and
     *  ERR-NOTREADY are sent again six times over about an hour (HealRetry). Before each retry the heal stops at a
     *  sign-out (SignOutGate.begun()), when the package has no code any more, or when another path wrote the marker.
     *  A retry while the first request still waits for the slot can queue a second odrestore; both are idempotent
     *  (the second answers OK NOSRC). A process death ends the retries; the next sign-in reunites the hold, as before.
     *  The heal also SKIPS a package with no code (an archived placeholder: its restore can only keep the hold and
     *  answer ERR-NOTREADY, 5-10 s of RW lane). Its real install fires the heal again, as ADDED with EXTRA_REPLACING.
     *
     *  Fire-and-forget on its own worker thread: RESTORE-ODDATA rides the RW worker lane, which a running seal
     *  can hold for minutes. ~~onReceive runs on the main thread with a ~10s ANR budget.~~ superseded by
     *  NWP-20261029-19: onReceive now runs on one serial worker under goAsync(), and the heal keeps its OWN
     *  thread because a RESTORE-ODDATA wait there would stall every later package broadcast in that queue. */
    private static void heal(Context context, String pkg, boolean replacing) {
        try {
            android.content.pm.PackageManager pm = context.getPackageManager();
            if (ProfileActivity.isBundledSystem(pm, pkg)) return; // install-existing at login broadcasts these
            // The gate holds no session data and no hold -- same user-0 short-circuit as the catch-up.
            if (android.os.Process.myUserHandle().equals(
                    android.os.UserHandle.getUserHandleForUid(android.os.Process.SYSTEM_UID))) return;
            if (!UnarchiveService.hasInstalledCode(context, pkg)) {
                android.util.Log.i("NowhereChooser", "install-heal skipped: " + pkg
                        + ": no code yet -- its install fires the heal again (NWP-20261128-05)");
                return;
            }
            new Thread(() -> {
                for (int attempt = 1; ; attempt++) {
                    String r = "";
                    try {
                        r = DaemonSocket.roundTrip("RESTORE-ODDATA\n" + pkg + "\n", 130000).trim();
                        if (r.startsWith("OK")) UnarchiveService.markOdRestored(context, pkg);
                    } catch (Throwable t) {
                        android.util.Log.w("NowhereChooser", "install-heal " + pkg, t);
                    }
                    long delay = HealRetry.delayMs(r, attempt);
                    android.util.Log.i("NowhereChooser", "install-heal (" + (replacing ? "update" : "new") + ") try "
                            + attempt + "/" + HealRetry.MAX_TRIES + ": " + pkg + " -> " + (r.isEmpty() ? "no reply" : r)
                            + (delay < 0 ? "" : " -- retry in " + delay / 1000 + " s")
                            + " (NWP-20260903-11, NWP-20261128-05)");
                    if (delay < 0) return;
                    try {
                        Thread.sleep(delay);
                    } catch (InterruptedException e) {
                        return;
                    }
                    String stop = SignOutGate.begun() ? "sign-out begun"
                            : !UnarchiveService.hasInstalledCode(context, pkg) ? "no code any more"
                            : UnarchiveService.odRestored(context, pkg) ? "already restored" : null;
                    if (stop != null) {
                        android.util.Log.i("NowhereChooser", "install-heal stopped before try " + (attempt + 1)
                                + ": " + pkg + " -- " + stop + " (NWP-20261128-05)");
                        return;
                    }
                }
            }, "nowhere-install-heal").start();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "install-heal " + pkg, t);
        }
    }

    /** NWP-20261119-10 (backlog row "A periodic seal's `#apps` staging spends two to three minutes staging nothing:
     *  ..."): rewrite ONE kept package's line in files/nowhere-appcode.list after it is installed or updated in a
     *  session. The list was written only at sign-out (ProfileActivity.captureAppCode), so after a materialise or a
     *  Play update its line named the previous /data/app/~~rand~~ dir, and every periodic seal staged nothing for it.
     *
     *  Runs on the serial worker (off the main thread). User 0: no write (the gate holds no session apps). A package
     *  not in the keep-set, a missing list, or a package that fails captureAppCode's guards (FLAG_SYSTEM,
     *  FLAG_UPDATED_SYSTEM_APP, no sourceDir -- an archived placeholder has none): no write. The mode is the
     *  keep-set's; the group token is the old line's (groupFor, as captureAppCode, when there is no old line). For a
     *  deferred mode (ondemand/auto) the archived meta is re-captured FIRST, so the line never names code its meta
     *  does not describe. Holds AppCodeLine.LOCK, as captureAppCode does, and takes no other lock.
     *
     *  Nothing else: no prune, no drop record, no meta prune, no other line -- the keep-set prune is safe only at
     *  sign-out, where captureAppCode still does it. The dev property persist.nowhere.appcode is not read here. */
    private static void recaptureCode(Context ctx, String pkg, String via) {
        try {
            if (android.os.UserHandle.myUserId() == 0) return;
            synchronized (AppCodeLine.LOCK) {
                java.io.File out = new java.io.File(ctx.getFilesDir(), "nowhere-appcode.list");
                if (!out.isFile()) return;
                String mode = ProfileActivity.readAppModesIn(ctx.getFilesDir()).get(pkg);
                if (mode == null) return;
                android.content.pm.PackageManager pm = ctx.getPackageManager();
                android.content.pm.ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                if ((ai.flags & android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0) return;
                if ((ai.flags & android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0) return;
                if (ai.sourceDir == null || ai.sourceDir.isEmpty()) return;
                long vc;
                try { vc = pm.getPackageInfo(pkg, 0).getLongVersionCode(); } catch (Throwable ignore) { vc = 0; }
                // ONE whole-content read: a line reader drops terminators and CRs, and replaceIn must see the exact bytes.
                String text = new String(java.nio.file.Files.readAllBytes(out.toPath()), java.nio.charset.StandardCharsets.UTF_8);
                String old = AppCodeLine.lineOf(text, pkg);
                String group = old != null ? AppCodeLine.groupOf(old) : ProfileActivity.groupFor(ctx, pkg);
                if (ProfileActivity.deferredMode(mode)) ProfileActivity.captureArchivedMeta(ctx, pm, pkg, vc);
                String line = AppCodeLine.build(pkg, vc, ProfileActivity.isSideloaded(pm, pkg), mode,
                        ai.sourceDir, ai.splitSourceDirs, group);
                StoreInstaller.writeAtomic(out, AppCodeLine.replaceIn(text, pkg, line));
                android.util.Log.i("NowhereChooser", "appcode re-capture (" + via + "): " + pkg + " mode=" + mode
                        + (old == null ? " -> line appended" : " -> line rewritten") + " (NWP-20261119-10)");
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "appcode re-capture " + pkg, t);
        }
    }

    /** The single decision, shared by the broadcast and the catch-up so the two can never disagree. Returns
     *  true iff a keep line was written. Logs UNCONDITIONALLY on the broadcast path: every exit from this used
     *  to be silent, which is why a receiver that had never once executed read as "the classifier is wrong"
     *  across three slices. */
    private static boolean decide(Context ctx, String pkg, boolean replacing, String via) {
        android.content.pm.PackageManager pm = ctx.getPackageManager();
        String installer = null;
        try {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                installer = pm.getInstallSourceInfo(pkg).getInstallingPackageName();
            } else {
                installer = pm.getInstallerPackageName(pkg);
            }
        } catch (Throwable ignore) {
        }

        String key = ProfileActivity.cfgKeyForInstaller(installer);
        String mode = ProfileActivity.appDefaultForInstaller(ctx, installer);
        // NWP-20261122-06 (h50 #7 A1): with Google Play turned on, Play Store, Play services and GSF are kept
        // On-demand whatever their installer's default says. Absent and off leave the default; so does every other app.
        // Without the GrapheneOS App Store (Diaspore) a roamed flag reads as absent, so it changes nothing there.
        PlayChoice.State play = PlayChoice.effective(PlayChoice.parse(ProfileActivity.cfgStatic(ctx, PlayChoice.CFG_KEY)),
                ProfileActivity.gosStorePresent(ctx));
        mode = PlayChoice.keepModeOnInstall(play, pkg, mode);
        // NWP-20260922-01: is this package BACK, rather than new? Chester, 2026-09-21: an app set to
        // on-demand, uninstalled from Settings and installed again came back ON-DEMAND instead of at its
        // bucket's default.
        //
        // ⚠⚠ THE KEEP LINE OUTLIVES THE APP, BECAUSE ITS PRUNE IS DEFERRED. An uninstall reaches
        // noteAppGone(), which only RECORDS the package; the keep line is pruned in captureAppCode(), and
        // that runs at LOGOFF. A re-install in the same session therefore arrives while the previous
        // incarnation's line is still in nowhere-appkeep -- and both branches below that could have noticed
        // return without touching it, so readAppModes() (what "Your apps" renders) keeps showing the old
        // tier. It is not specific to a bucket or a store: the line survives in every bucket, and an
        // off-default one like Aurora merely makes it VISIBLE, because that is where the default and the
        // stale value differ.
        //
        // The discriminator is the one this file already built for exactly this question -- a TRANSITION
        // observed within one session, not a point-in-time "is it installed" test, which cannot tell "the
        // user removed it" from "on-demand, not materialised yet".
        //
        // ⚠ DELIBERATELY NOT APPLIED TO THE THREE BRANCHES ABOVE IT. `replacing` is an update, where the app
        // never left. A bundled system app cannot reach here (the removal branch exempts it, and pmKnows
        // stays true). And an nApps install has ALREADY had its keep line written by StoreInstaller on the
        // install path before this broadcast lands -- clearing it here would delete the line that install
        // just made, turning a fix for a stale tier into a fresh bug that drops the new one.
        boolean returning = !replacing && StoreInstaller.appGoneThisSession(ctx).contains(pkg);
        boolean wrote = false;
        String outcome;
        if (replacing) {
            outcome = "skipped (an update, not a new install)";
        } else if (ProfileActivity.isBundledSystem(pm, pkg)) {
            outcome = "skipped (ships in the image -- there is nothing to keep)";
        } else if (ProfileActivity.CFG_APPS_NAPPS.equals(key)) {
            // nApps installs get their keep line from StoreInstaller on the install path itself, which is where
            // the over-plan prompt lives. Doing it again here is harmless but pointless.
            outcome = "skipped (nApps -- StoreInstaller applied it on the install path)";
        } else if (ProfileActivity.APPDEF_OFF.equals(mode)) {
            // The bucket default is "do not keep", which means NO keep line -- so a stale one from the
            // previous incarnation has to go, or the app reads as kept at a tier the user never chose for it.
            if (returning && StoreInstaller.keepSetHas(ctx, pkg)) {
                StoreInstaller.removeKeepLines(ctx, java.util.Collections.singleton(pkg));
                outcome = "not kept (this bucket's default is off) -- and the previous install's keep line was cleared";
            } else {
                outcome = "not kept (this bucket's default is off)";
            }
        } else if (ProfileActivity.explicitlyTurnedOff(ctx).contains(pkg)) {
            outcome = "not kept (the user switched this app off)";
        } else if (returning && StoreInstaller.keepSetHas(ctx, pkg)) {
            // Back from an uninstall into a bucket that DOES keep: the line must be rewritten at the
            // bucket's default rather than left at whatever the last incarnation was set to.
            StoreInstaller.removeKeepLines(ctx, java.util.Collections.singleton(pkg));
            wrote = StoreInstaller.keepInMode(ctx, pkg, false, mode);
            outcome = wrote ? "re-installed -- reset to this bucket's default" : "refused by keepInMode";
        } else if (StoreInstaller.keepSetHas(ctx, pkg)) {
            // Already decided -- typically the broadcast path got here seconds before the catch-up did.
            // keepInMode would return true for this case too, so without the check the catch-up counts apps
            // it never touched and says it applied a default it did not apply.
            outcome = "left alone (already has a keep line)";
        } else {
            wrote = StoreInstaller.keepInMode(ctx, pkg, false, mode);
            outcome = wrote ? "kept" : "refused by keepInMode";
        }
        // NWP-20261122-06: a Play Store kept here with Play on is the user's own choice, so it goes in nowhere-playdeps,
        // as a keep from its own row does. keepInMode leaves it out (recordPlayDepAtInstall skips the stack), and
        // without it reconcilePlayStack drops Play Store at the next keep-set edit while no other app needs Play.
        if (wrote && PlayChoice.userKeepsOnInstall(play, pkg)) {
            try {
                ProfileActivity.setPlayDep(ctx, pkg, true);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "install default: setPlayDep " + pkg, t);
            }
        }
        // The catch-up walks every third-party app on every chooser start, so staying quiet when it had nothing
        // to do keeps the log readable. The broadcast path always speaks.
        if (!"catch-up".equals(via) || wrote) {
            android.util.Log.i("NowhereChooser", "install default (" + via + "): " + pkg
                    + " installer=" + installer + " bucket=" + key.replace("apps.default.", "")
                    + " default=" + mode + " -> " + outcome + " (NWP-20260825-19)");
        }
        return wrote;
    }
}
