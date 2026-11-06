package com.nowhere.chooser;

/**
 * NWP-20261126-10: re-arm the idle cold lock after the user-0 chooser process restarts during a session.
 *
 * WHY THIS EXISTS. The idle cold lock -- the real at-rest bound, since the keyguard alone leaves CE warm -- lives
 * entirely in user-0 process memory: ChooserActivity.armIdleWatcher registers its screen-off receiver at runtime and
 * keeps the alarm and the five lock values (idle, wipe, erase once saved, hold for installs, hold for audio) in
 * statics, set by applyRoamedPrefs at sign-in and by applyLivePrefs. armIdleWatcher has three callers: the login path,
 * the resume path and applyLivePrefs. The process is android:persistent and is restarted by the system while a session
 * owns the screen (NowhereApp's header, found 2026-08-15); an uncaught throw in a raw gate worker thread does the same.
 * After that restart no gate Activity is created, the reap watcher's #123 self-heal marks the session live again, and
 * nothing re-arms: the session never cold-locks, and the hard wipe and "erase once saved", armed only at a cold lock,
 * never arm either.
 *
 * THE FIX CALLS THE EXISTING PATH. The prefs live in the session's CE, which user 0 cannot read, so user 0 asks the
 * session to resend them (atProcessBirth -> CredentialService "relayprefs" in the session user). The session sends the
 * same broadcast ProfileActivity.sendLivePrefs sends (sendFromSession -> PrefsLiveReceiver in user 0), and
 * applyLivePrefs, unchanged, refuses anything but the current, live session and re-arms through armIdleWatcher. It
 * rides in CredentialService because a NEW manifest component does not register over a pinned-fingerprint reflash
 * without a data wipe (the B4 lesson, 2026-07-11); PrefsLiveReceiver's header says why its cross-user send passes.
 *
 * OPEN RESIDUALS, not closed here: (a) a restart while the screen is already off arms only at the next screen-off
 * (armIdleWatcher arms on SCREEN_OFF); (b) a restart while the session is cold-locked finds no live session, so its
 * later resume re-arms with the gate's default idle and wipe values, not the profile's.
 */
final class RestartRearm {
    private RestartRearm() {}

    private static final String TAG = "NowhereChooser";

    /** The pure decision. java.lang only (plus ProfileActivity.prefValueIn and WipeOnSave.PREF), so a javac suite
     *  compiles it off the build host (core/vendor-common/bin/test-restart-rearm-java.sh). */
    static final class Rule {
        private Rule() {}

        /** How long process birth waits for the reap watcher's self-heal to mark the session live. */
        static final long WAIT_MS = 120_000L;
        /** How often it looks. */
        static final long POLL_MS = 2_000L;

        /** The nowhere-prefs keys sendLivePrefs sends, in the order of its five extras. */
        static final String[] KEYS = { "idle", "wipe", WipeOnSave.PREF, "holdlock", "holdaudio" };

        /** Ask the session only when it is live, a secondary user owns the screen and that user is unlocked (a
         *  cold-locked user is stopped and is never re-armed from here). */
        static boolean shouldAsk(boolean sessionLive, int currentUser, boolean currentUnlocked) {
            return sessionLive && currentUser >= 10 && currentUnlocked;
        }

        /** The five values of KEYS from the prefs text, in order, by ProfileActivity.prefValueIn's rule; "" = absent. */
        static String[] extras(String prefsText) {
            final String[] v = new String[KEYS.length];
            for (int i = 0; i < KEYS.length; i++) v[i] = ProfileActivity.prefValueIn(prefsText, KEYS[i]);
            return v;
        }
    }

    /** At every process birth (NowhereApp.onCreate), user 0 only: wait for a live, unlocked session and ask it once to
     *  resend its lock prefs. Logs carry the user id only. */
    static void atProcessBirth(final android.content.Context ctx) {
        if (android.os.UserHandle.myUserId() != 0) return;
        final android.content.Context app = ctx.getApplicationContext();
        new Thread(() -> {
            int uid = -1;
            final long end = android.os.SystemClock.elapsedRealtime() + Rule.WAIT_MS;
            while (true) {
                int cur = -1;
                boolean unlocked = false;
                try { cur = android.app.ActivityManager.getCurrentUser(); } catch (Throwable t) { cur = -1; }
                try {
                    android.os.UserManager um =
                            (android.os.UserManager) app.getSystemService(android.content.Context.USER_SERVICE);
                    unlocked = cur >= 0 && um != null && um.isUserUnlocked(android.os.UserHandle.of(cur));
                } catch (Throwable t) { unlocked = false; }
                boolean ask = false;
                try { ask = Rule.shouldAsk(ChooserActivity.isSessionLive(), cur, unlocked); } catch (Throwable t) { ask = false; }
                if (ask) { uid = cur; break; }
                if (android.os.SystemClock.elapsedRealtime() >= end) break;
                try { Thread.sleep(Rule.POLL_MS); } catch (InterruptedException ie) { return; }
            }
            if (uid < 0) {
                android.util.Log.i(TAG, "restart rearm: no live session at process birth (NWP-20261126-10)");
                return;
            }
            for (int try_ = 0; try_ < 8; try_++) {
                try {
                    if (app.startServiceAsUser(new android.content.Intent(app, CredentialService.class)
                            .putExtra("relayprefs", true), android.os.UserHandle.of(uid)) != null) {
                        android.util.Log.i(TAG, "restart rearm: asked user " + uid
                                + " to resend its lock prefs (try " + (try_ + 1) + ") (NWP-20261126-10)");
                        return;
                    }
                } catch (Throwable t) { android.util.Log.w(TAG, "restart rearm: ask user " + uid, t); }
                try { Thread.sleep(2000); } catch (InterruptedException ie) { return; }
            }
            android.util.Log.w(TAG, "restart rearm: the ask never resolved for user " + uid + " (NWP-20261126-10)");
        }, "nowhere-restart-rearm").start();
    }

    /** In the session user (CredentialService "relayprefs"): read nowhere-prefs and send its five values to the gate,
     *  exactly as ProfileActivity.sendLivePrefs does after a Save. An absent file sends every value absent, which is
     *  what the sign-in's GET-PREFS gave such a profile (roamd reads the same file). An unreadable file sends nothing:
     *  an unreadable record is not an empty one, and the gate defaults would overwrite the profile's choices. */
    static void sendFromSession(final android.content.Context ctx) {
        final int uid = android.os.UserHandle.myUserId();
        String text;
        try {
            text = new String(java.nio.file.Files.readAllBytes(
                    new java.io.File(ctx.getFilesDir(), ProfileActivity.PREFS_FILE).toPath()),
                    java.nio.charset.StandardCharsets.UTF_8);
        } catch (java.nio.file.NoSuchFileException absent) {
            text = "";
        } catch (Throwable t) {
            android.util.Log.w(TAG, "restart rearm: prefs present but unreadable for user " + uid
                    + ", nothing sent (NWP-20261126-10)");
            return;
        }
        final String[] v = Rule.extras(text);
        try {
            ctx.sendBroadcastAsUser(new android.content.Intent(ctx, PrefsLiveReceiver.class)
                    .putExtra(PrefsLiveReceiver.EXTRA_IDLE, v[0])
                    .putExtra(PrefsLiveReceiver.EXTRA_WIPE, v[1])
                    .putExtra(PrefsLiveReceiver.EXTRA_WIPESAVED, v[2])
                    .putExtra(PrefsLiveReceiver.EXTRA_HOLDLOCK, v[3])
                    .putExtra(PrefsLiveReceiver.EXTRA_HOLDAUDIO, v[4])
                    .putExtra(PrefsLiveReceiver.EXTRA_UID, uid), android.os.UserHandle.SYSTEM);
            android.util.Log.i(TAG, "restart rearm: sent lock prefs from user " + uid + " (NWP-20261126-10)");
        } catch (Throwable t) {
            android.util.Log.w(TAG, "restart rearm: send from user " + uid, t);
        }
    }
}
