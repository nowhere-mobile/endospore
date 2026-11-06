package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Launches the blind-login chooser once the device finishes booting -- the login front door.
 *
 * Safe by construction: a fresh boot lands on the gate with an EMPTY roaming tmpfs -- there is no
 * auto-restore (the Arc-1 baked-identity baseline is gone), and launcher3 stays a fallback home, so a
 * failure here can't bootloop or strand the device. The restore happens only on an explicit blind login.
 */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        // USER-0 ONLY (#50/#96 root cause, proven on FP3 2026-07-03): Android delivers BOOT_COMPLETED to a
        // user EVERY time it is started+unlocked -- so this fired INSIDE the roamed user on every login and
        // cold-resume (am_proc_start: [11,...,broadcast,{...BootReceiver}]) and launched the chooser's login
        // form over the session's launcher for ~1.5s (THE resume/login "gate flash"). The gate is user 0's
        // front door; in any other user this receiver must do nothing.
        if (android.os.UserHandle.myUserId() != 0) return;
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            final Context app = context.getApplicationContext();
            // Bring the gate up IMMEDIATELY -- never wait on the wipe (no home-flash, and no ANR if it stalls).
            // NO_ANIMATION + bring-to-front: come up at once over launcher3 (shown at boot_completed).
            Intent i = new Intent(app, ChooserActivity.class);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_NO_ANIMATION
                    | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
            app.startActivity(i);
            // BOOT SCREEN (2026-07-13): SystemUI does a one-shot goToSleep a few seconds into boot (the kiosk
            // disables the keyguard, so nothing holds the display awake), dozing the screen and leaving this
            // freshly launched gate behind a BLACK screen until a power press. Wake it after that sleep so boot
            // lands on a visible gate. (Persistent process -> the delayed wake survives this receiver returning.)
            ChooserActivity.scheduleBootWake(app);
            // NWP-20260824-03: an alarm does not survive a reboot, so re-arm the OTA wake here. NowhereApp
            // also arms on process birth; both are idempotent and either alone is sufficient.
            try { OtaWakeReceiver.arm(app); }
            catch (Throwable t) { android.util.Log.w("NowhereChooser", "boot: ota wake arm", t); }
            // Wipe leftover roamed users OFF the main thread (#47): the wipe makes BLOCKING daemon socket calls
            // (cleanUserStorage -> pollDaemon, up to 5s each), and running them inline on this receiver's main
            // thread froze the gate into a 5s ANR ("nowhere isn't responding") whenever the daemon was slow to
            // answer right after boot. goAsync keeps the process alive until the background wipe finishes; the
            // gate's onResume orphan-sweep (#73) is a second net if the process dies mid-wipe.
            final PendingResult pr = goAsync();
            new Thread(() -> {
                try {
                    // DIA-20260807-09: Bluetooth FIRST, and unconditionally. Until now the only boot-time BT
                    // clear was a side effect of removeUser below -- so it ran late (the gate is already
                    // drawing, the radio already live) and only if a leftover user existed. Neither holds
                    // after a battery death. Cheap when there is nothing to do: the adapter is usually off
                    // this early, so no stack toggle is needed.
                    ChooserActivity.btWipe();
                    // DIA-20260807-15: and the device locale, for the same reason and the same case -- after
                    // a battery death no reap ever ran, so the gate would come up in the departed language.
                    ChooserActivity.revertDeviceLocale();
                    // DIA-20260815-12 (#110): and the user-switch session messages, for the same reason and
                    // one more. They live on user 0's DO admin in /data/system/device_policies.xml, which is
                    // OUTSIDE every user -- and wipeLeftoverRoamedUsers below works by removing a USER, so it
                    // has never reached them. Historically the welcome carried the profile NAME, which then
                    // survived power-off, the boot-wipe and every reap, and was readable on any boot with no
                    // credential. The messages are nameless as of this change, so this clear is what heals a
                    // device that is ALREADY carrying one; without it only a factory reset would.
                    clearSessionMessages(app);
                    wipeLeftoverRoamedUsers(app); // P2: amnesiac-on-(unclean)-power-off + free the tight 4-user cap
                    // #135 B5: telephony amnesia backstop -- erase any SMS/MMS or CallLog row the framework wrote
                    // that outlived a reboot (user 0 keeps no telephony history); TelScrub.sms spares raw rows still in
                    // flight or undelivered (NWP-20260927-10) until 24 h after the gate first saw them
                    // (NWP-20261108-10). The su:s0 janitor (nowhere_gate.sh), run earlier at
                    // sys.boot_completed, leaves raw alone -- it can hold this boot's undelivered texts -- and VACUUMs.
                    TelScrub.all(app);
                    // DIA-20260816-04 (amnesia audit fixes 4-7): LAST, and that ordering is the point.
                    // wipeLeftoverRoamedUsers above calls removeUser, and removeUser MINTS dropbox entries
                    // naming the slot it just erased -- the audit measured all 1,000 entries landing at
                    // 39-54s uptime, i.e. the wipe generating the very records this sweep removes. Running
                    // the sweep before the removals would delete the old ones and leave the fresh ones.
                    ChooserActivity.bootSweep();
                } finally {
                    pr.finish();
                }
            }, "nowhere-boot-wipe").start();
        }
    }

    /**
     * P2 (DIA-20260625-12, docs/resumable-session.md): on every boot, crypto-shred any leftover roamed user.
     *
     * With the resumable model the roamed user is NON-ephemeral, so a clean logoff removes it but an UNCLEAN
     * power-off (battery death) — or a cold-locked idle session that was never logged off — leaves its encrypted
     * /data on disk across the reboot. This restores the amnesiac "nothing physically kept" guarantee for the
     * OFF state, and, just as importantly, frees the device's tight max-users cap (1 system + only 3 secondary
     * here): leftover non-ephemeral users otherwise pile up and break sign-in (createAndManageUser fails).
     *
     * A fresh boot never has a LIVE roamed session — the gate is the boot state and the .roamsession marker
     * lives in the power-off-cleared tmpfs — so every leftover device-owner-managed secondary user is removed here.
     * SUPERSEDED (NWP-20261014-22): the clause "can't race a login (none has happened yet)" was wrong. The gate is
     * HOME and accepts a sign-in while this thread runs, so a user a sign-in has created, or is creating, can be
     * listed here. The wipe skips a user while ChooserActivity.isLoginInProgress() and any uid in
     * ChooserActivity.sCreatedThisBoot, leaving it to the #73 parked sweep, and cleans a user's storage only after
     * removeUser was accepted. The store still holds each profile's
     * last-sealed state, so the next login restores it; only post-last-sync changes from an unclean shutdown
     * are lost, which is the amnesiac contract.
     */
    /**
     * DIA-20260815-12 (#110): clear the user-switch session messages on every boot, unconditionally.
     *
     * These are DO policy state on user 0, not per-user state, so nothing in the reap or the boot-wipe has
     * ever touched them — only a factory reset did. That mattered because the welcome string used to embed
     * the profile name ("Welcome back, <name> · last active <rel>"), giving a seized handset a plaintext
     * identity that outlived every wipe. Combined with a name+passphrase-derived value elsewhere on disk it
     * also completed an offline passphrase oracle (see docs/amnesia-poweroff-audit.md).
     *
     * Unconditional and cheap: user 0 has no session worth a custom message at boot, so clearing is always
     * correct. Best-effort by design — a failure here must never block the wipes that follow.
     */
    private void clearSessionMessages(Context context) {
        try {
            android.app.admin.DevicePolicyManager dpm = (android.app.admin.DevicePolicyManager)
                    context.getSystemService(Context.DEVICE_POLICY_SERVICE);
            if (dpm == null || !dpm.isDeviceOwnerApp(context.getPackageName())) return;
            android.content.ComponentName admin = new android.content.ComponentName(context, AdminReceiver.class);
            dpm.setStartUserSessionMessage(admin, null);
            dpm.setEndUserSessionMessage(admin, null);
            android.util.Log.i("NowhereChooser", "boot-wipe: cleared session messages (#110)");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "clearSessionMessages", t);
        }
    }

    private void wipeLeftoverRoamedUsers(Context context) {
        try {
            android.app.admin.DevicePolicyManager dpm = (android.app.admin.DevicePolicyManager)
                    context.getSystemService(Context.DEVICE_POLICY_SERVICE);
            if (dpm == null || !dpm.isDeviceOwnerApp(context.getPackageName())) return;
            android.content.ComponentName admin = new android.content.ComponentName(context, AdminReceiver.class);
            for (android.os.UserHandle uh : dpm.getSecondaryUsers(admin)) {
                int uid = uh.getIdentifier();
                if (ChooserActivity.isLoginInProgress()) {
                    android.util.Log.i("NowhereChooser", "boot-wipe: skip user " + uid + " -- a sign-in is in progress; the #73 parked sweep retries");
                    continue;
                }
                if (ChooserActivity.sCreatedThisBoot.contains(uid)) {
                    android.util.Log.i("NowhereChooser", "boot-wipe: skip user " + uid + " -- created by a sign-in this boot; the #73 parked sweep retries");
                    continue;
                }
                boolean ok = dpm.removeUser(admin, uh);
                android.util.Log.i("NowhereChooser", "boot-wipe: removeUser " + uid + " ok=" + ok);
                // removeUser leaves /data/system_ce/<uid> behind; rm it so a reused uid can't inherit the stale,
                // key-mismatched CE and crash system_server on unlock (DIA-20260625-13). Only after an accepted
                // removal: cleanstorage rm's the FBE trees without checking the user is gone (NWP-20261011-38).
                if (ok) ChooserActivity.cleanUserStorage(uid);
                else android.util.Log.w("NowhereChooser", "boot-wipe: removeUser " + uid + " refused -- storage NOT cleaned");
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "boot-wipe", t);
        }
    }
}
