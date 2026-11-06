package com.nowhere.chooser;

import android.app.KeyguardManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Idle-timeout auto-lock (P3/P4, docs/resumable-session.md). The user-0 gate arms an AlarmManager alarm on
 * screen-off (cancelled on unlock); if it fires, the roamed session has been LOCKED + IDLE for the timeout.
 * In the resumable-cold model that idle action is a COLD-LOCK, not a wipe: stop the user so its CE key is
 * evicted (ciphertext at rest, resumable with the passphrase), keeping the data on the device. The keyguard
 * alone leaves CE decrypted while merely locked (lock-model.md L3), so this timeout -> cold-lock is the real
 * at-rest guarantee for an unattended locked phone, while preserving the session (no re-download on resume).
 * The longer 12 h hard bound that escalates a still-cold-locked, un-resumed session to a full amnesiac WIPE
 * is a separate alarm armed AT cold-lock (ColdWipeReceiver / armWipeWatcher, DIA-20260626-03); this is the
 * 15-min default cold-lock that fires first.
 *
 * This runs in USER 0 (the alarm's user) and must NOT depend on the locked roamed UI: launching cross-user
 * into a locked, screen-off user is DEFERRED by Android until unlock (so an attacker who never unlocks would
 * never trigger it). Instead it drives the lock HEADLESSLY -- the daemon's COLD-LOCK reads the *marked* roam
 * session (readRoamSession, not the connecting user) and queues the switch+stop for the user-0 reap watcher.
 * Not exported; only the gate's own alarm PendingIntent reaches it.
 */
public class IdleLogoffReceiver extends BroadcastReceiver {
    private static final String SOCKET = "nowhere_login";
    // Hard cap on the COLD-LOCK round-trip, WELL under the 60s background-broadcast ANR limit. LocalSocket has
    // NO connect timeout, so a wedged/offline daemon (accept loop stuck in a store retry) blocks connect()
    // indefinitely; goAsync() then holds the broadcast pending until 60s, when Android ANRs and KILLS the
    // persistent gate process (proven on FP3 2026-07-01 -- the "black screen" gate-kill cascade, #77). The
    // cold-lock is best-effort (the alarm re-fires on the next screen-off), so we bound the whole round-trip
    // and finish the broadcast no matter what -- the gate is never taken down by an unresponsive daemon.
    private static final int CONNECT_CAP_MS = 8000; // watchdog: covers the unbounded connect()
    private static final int READ_CAP_MS = 5000;    // socket read timeout (daemon replies at once)
    /** NWP-20260922-07: how long to wait before retrying a fire that produced NO lock. Longer than the
     *  #181 screen-on defer because the dominant cause is a logoff seal, which is minutes-to-tens-of-
     *  minutes, not seconds -- retrying every 60s would spin the daemon for the whole logoff. Short
     *  enough that a session whose logoff fails regains its at-rest bound quickly. */
    static final long NOLOCK_REGRACE_MS = 5 * 60 * 1000L;

    @Override
    public void onReceive(Context ctx, Intent intent) {
        try {
            KeyguardManager km = (KeyguardManager) ctx.getSystemService(Context.KEYGUARD_SERVICE);
            // Belt-and-suspenders to the USER_PRESENT cancel: if the user unlocked since the alarm was armed,
            // the keyguard is gone -> they're active, so do NOT lock them out.
            boolean locked = km == null || km.isKeyguardLocked();
            boolean live = ChooserActivity.isSessionLive();
            android.util.Log.i("NowhereChooser", "idle cold-lock alarm live=" + live + " locked=" + locked);
            // NWP-20260909-01: THE FIRE ITSELF HAD NO TRACE -- only its outcomes did (a defer line, or the
            // daemon's cold-lock line), so "when did the alarm actually arrive, and what screen state did it
            // read?" could only be INFERRED from how other lines happened to interleave. That inference is
            // exactly what NW-7c23f559d2d7 needed, and login.log is the only channel a locked user build can
            // send. late= is the direct measurement NWP-20260901-31 wanted for lead 2 (Doze throttling).
            final long lateBy = ChooserActivity.idleFiredLateBy();
            final boolean screenOn = ChooserActivity.isScreenOn();
            ChooserActivity.idleTrace("fire late=" + (lateBy / 1000L)
                    + " screenon=" + (screenOn ? 1 : 0)
                    + " live=" + (live ? 1 : 0) + " locked=" + (locked ? 1 : 0));
            if (!live || !locked) return;

            // NWP-20261021-02: the whole pre-commit decision is IdleLockGate.decide (java.* only, executed by
            // core/chooser/tests/idle-lock-gate); this method gathers its inputs and acts on the verdict.
            // The call check is skipped when the screen is on: the screen-on defer wins first, as it always has.
            // TRUE = in a call, FALSE = not (or no TelecomManager), null = the check itself failed -> PROCEED.
            Boolean inCall = Boolean.FALSE;
            if (!screenOn) {
                try {
                    android.telecom.TelecomManager tm = ctx.getSystemService(android.telecom.TelecomManager.class);
                    inCall = tm != null && tm.isInCall();
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "idle cold-lock: isInCall check failed -- proceeding", t);
                    inCall = null;
                }
            }
            // NWP-20261120-02: is audio playing in a signed-in user? TRUE / FALSE, null = the check failed -> PROCEED.
            // Only STARTED players with a media-like usage count; user 0's own players (the gate's alarm, ringtone)
            // never do. No log line here names an app or a package.
            Boolean audioPlaying = Boolean.FALSE;
            if (!screenOn && ChooserActivity.sHoldLockForAudio) {
                try {
                    android.media.AudioManager am = ctx.getSystemService(android.media.AudioManager.class);
                    if (am == null) {
                        android.util.Log.w("NowhereChooser", "idle cold-lock: no AudioManager -- proceeding");
                        audioPlaying = null;
                    } else {
                        boolean playing = false;
                        for (android.media.AudioPlaybackConfiguration c : am.getActivePlaybackConfigurations()) {
                            int u = c.getAudioAttributes().getUsage();
                            boolean media = u == android.media.AudioAttributes.USAGE_MEDIA
                                    || u == android.media.AudioAttributes.USAGE_GAME
                                    || u == android.media.AudioAttributes.USAGE_UNKNOWN;
                            boolean started = c.getPlayerState()
                                    == android.media.AudioPlaybackConfiguration.PLAYER_STATE_STARTED;
                            if (IdleLockGate.countsAsAudio(started, media, c.getClientUid())) playing = true;
                        }
                        audioPlaying = playing;
                    }
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "idle cold-lock: playback check failed -- proceeding", t);
                    audioPlaying = null;
                }
            }
            final IdleLockGate.Verdict v = IdleLockGate.decide(live, locked, screenOn, lateBy,
                    ChooserActivity::claimIdleLateGrace, inCall, ChooserActivity.sHoldLockForInstalls,
                    () -> DaemonSocket.roundTrip("GET-SWEEP\n", 2000),
                    ChooserActivity.sHeldForInstallsSince, android.os.SystemClock::elapsedRealtime, ChooserActivity.HOLD_FOR_INSTALLS_CAP_MS,
                    ChooserActivity.sHoldLockForAudio, audioPlaying, ChooserActivity.sAudioHolding,
                    ChooserActivity.HOLD_FOR_AUDIO_CAP_MS, ChooserActivity.idleTimeoutMs());
            if (v.heldSinceMs != ChooserActivity.sHeldForInstallsSince) {
                ChooserActivity.sHeldForInstallsSince = v.heldSinceMs;
            }
            ChooserActivity.sAudioHolding = v.audioHolding;
            switch (v.reason) {
                case SCREEN_ON:
                    // #181: the at-rest cold-lock is for an UNATTENDED phone; the screen being ON means the user
                    // is right there. DEFER and retry; USER_PRESENT cancels the alarm on unlock. NB: screen state
                    // comes from ChooserActivity.isScreenOn(), NOT PowerManager.isInteractive() (reads FALSE from
                    // this backgrounded user-0 process even screen-on).
                    android.util.Log.i("NowhereChooser", "idle cold-lock: screen ON (user present) -> deferred 60s (#181)");
                    // NWP-20260901-31: lead 1's tell is this REPEATING with no preceding "screen off" -- a
                    // missed ACTION_SCREEN_OFF leaves sScreenOn stale-true and the defer loops forever.
                    ChooserActivity.idleTrace(v.trace);
                    ChooserActivity.rearmIdleShort(ctx, v.delayMs);
                    return;
                case LATE_FIRE:
                    // NWP-20260909-01: a late delivery can have lost the race to the event that woke us; step
                    // aside ONCE per arm cycle (claimed only when the delivery is late) and look again.
                    android.util.Log.i("NowhereChooser",
                            "idle cold-lock: delivery " + lateBy + "ms late -> regrace " + IdleLockGate.LATE_REGRACE_MS + "ms (NWP-20260909-01)");
                    ChooserActivity.idleTrace(v.trace);
                    ChooserActivity.rearmIdleShort(ctx, v.delayMs);
                    return;
                case IN_CALL:
                    // #145: never cold-lock mid-call. If the check itself fails we PROCEED -- the cold-lock is
                    // the at-rest security bound and outranks ring continuity.
                    android.util.Log.i("NowhereChooser", "idle cold-lock: call in progress -> deferred 2 min (#145)");
                    ChooserActivity.idleTrace(v.trace); // NWP-20260901-31
                    ChooserActivity.rearmIdleShort(ctx, v.delayMs);
                    return;
                case AUDIO_HELD:
                    // NWP-20261120-02 (decision 2026-11-01): wait while audio plays in a signed-in user, for at most
                    // HOLD_FOR_AUDIO_CAP_MS from the start shared with the installs hold. A failed check proceeds.
                    android.util.Log.i("NowhereChooser", "idle cold-lock: audio playing -> deferred 60s (held "
                            + (v.heldMs / 60000L) + " of " + (ChooserActivity.HOLD_FOR_AUDIO_CAP_MS / 60000L)
                            + " min, NWP-20261120-02)");
                    ChooserActivity.idleTrace(v.trace);
                    ChooserActivity.rearmIdleShort(ctx, v.delayMs);
                    return;
                case AUDIO_STOPPED:
                    // NWP-20261120-02: playback stopped after a held fire, so the standby countdown starts again.
                    android.util.Log.i("NowhereChooser", "idle cold-lock: audio stopped -> standby countdown "
                            + "restarted (" + (v.delayMs / 1000L) + "s, NWP-20261120-02)");
                    ChooserActivity.idleTrace(v.trace);
                    ChooserActivity.rearmIdleShort(ctx, v.delayMs);
                    return;
                case AUDIO_CAP:
                    android.util.Log.i("NowhereChooser", "idle cold-lock: audio still playing after the "
                            + (ChooserActivity.HOLD_FOR_AUDIO_CAP_MS / 60000L) + " min cap -> locking anyway");
                    ChooserActivity.idleTrace(v.trace);
                    break;
                case INSTALLS_HELD:
                    // NWP-20261005-02: wait for the session's Auto apps to finish installing, for at most
                    // HOLD_FOR_INSTALLS_CAP_MS. It weakens the at-rest bound, so it fails toward LOCKING: any
                    // GET-SWEEP answer but LIVE -- none, an error, an older daemon -- proceeds.
                    android.util.Log.i("NowhereChooser", "idle cold-lock: apps installing -> deferred 5 min (held "
                            + (v.heldMs / 60000L) + " of " + (ChooserActivity.HOLD_FOR_INSTALLS_CAP_MS / 60000L)
                            + " min, NWP-20261005-02)");
                    ChooserActivity.idleTrace(v.trace);
                    ChooserActivity.rearmIdleShort(ctx, v.delayMs);
                    return;
                case INSTALLS_CAP:
                    android.util.Log.i("NowhereChooser", "idle cold-lock: apps still installing after the "
                            + (ChooserActivity.HOLD_FOR_INSTALLS_CAP_MS / 60000L) + " min cap -> locking anyway");
                    ChooserActivity.idleTrace(v.trace);
                    break;
                case NOT_LIVE_OR_UNLOCKED:
                    return;
                default:
                    break;
            }

            // #134 v3: a cold-lock is now committed. Arm the gate's switch-back cover BEFORE the daemon COLD-LOCK
            // (the reap watcher's doSwitch fronts the gate right after), so the whole switch+seal window shows the
            // opaque "Welcome back…" splash instead of the bare login form. Windowed + torn down at the reveal.
            // NWP-20260902-04: stamp the DECISION. The daemon revokes this lock iff an authenticated unlock
            // happened at or after this instant, so it must be sampled HERE -- after the guards passed and
            // before the round trip -- not at send time, or an unlock during the send would be missed.
            final long decidedAt = android.os.SystemClock.elapsedRealtime();
            ChooserActivity.markColdLockIncoming();
            // NWP-20260914-01: block suspend for the WHOLE teardown, SYNCHRONOUSLY and HERE.
            //
            // Here, because this is a _WAKEUP broadcast and the framework implicit wakelock is still held --
            // it drops a few lines below, in finish.run(), as soon as the daemon replies. And synchronously,
            // because the alternative considered (hand it to the reap watcher) cannot work: the watcher naps
            // on Thread.sleep, which is monotonic and does not run once the device has suspended. It would
            // need the CPU awake to acquire the thing that keeps the CPU awake.
            //
            // Released by the watcher after the LOCK ack; COLD_WAKE_MS bounds every other path.
            ChooserActivity.coldWakeAcquire(ctx);

            final PendingResult pr = goAsync();     // keep the receiver alive for the (quick) socket round-trip
            final LocalSocket s = new LocalSocket();
            final AtomicBoolean done = new AtomicBoolean(false);
            // Finish the broadcast EXACTLY once, whichever of worker/watchdog gets there first.
            final Runnable finish = () -> { if (done.compareAndSet(false, true)) pr.finish(); };

            // NWP-20260922-07: TWO separate questions, deliberately not one flag.
            //   rearm       -- did a lock positively START? Its ABSENCE drives the alarm re-arm, which is
            //                  correctly broad: re-arming a lock that did happen is harmless.
            //   releaseWake -- did the daemon positively LOOK and find no session? Only this may release
            //                  the cold wakelock, which is the narrow, affirmative question. See below.
            // IdleLockGate.afterReply maps the daemon's first line onto the two, on exact tokens.
            final java.util.concurrent.atomic.AtomicReference<String> replyRef =
                    new java.util.concurrent.atomic.AtomicReference<>();
            Thread worker = new Thread(() -> {
                try {
                    s.connect(new LocalSocketAddress(SOCKET, LocalSocketAddress.Namespace.RESERVED));
                    s.setSoTimeout(READ_CAP_MS); // the daemon replies at once; the switch+stop runs via the reap watcher
                    OutputStream os = s.getOutputStream();
                    // NWP-20260902-04: the ABORTABLE verb. This decision is correct when made but can act minutes
                    // later, so it must be revocable by a genuine unlock. Profile's explicit "lock now" keeps
                    // the plain COLD-LOCK and is deliberately NOT abortable.
                    os.write(("COLD-LOCK-IDLE\n" + decidedAt + "\n").getBytes("UTF-8"));
                    os.flush();
                    BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
                    String reply = br.readLine();
                    android.util.Log.i("NowhereChooser", "idle COLD-LOCK reply=" + reply);
                    // NWP-20260922-07: only a POSITIVE "LOCKING" counts. An older agent answers a bare "OK" and
                    // is treated as no-lock -- the safe direction, because re-arming a lock that did happen is
                    // harmless (doColdLock's cancelIdleWatcher clears it) while NOT re-arming one that did not
                    // is the defect this exists to close.
                    replyRef.set(reply);
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "idle COLD-LOCK", t);
                } finally {
                    try { s.close(); } catch (Throwable ignore) {}
                    IdleLockGate.AfterReply after = IdleLockGate.afterReply(replyRef.get());
                    // ⚠⚠ NWP-20260922-07: THE FOURTH DECLINE. THIS ALARM IS ALREADY SPENT.
                    //
                    // The three defers above (#181 screen-on, the late-fire regrace, #145 mid-call) each call
                    // rearmIdleShort because a fire that does not lock must not cost the session its backstop.
                    // This path -- the daemon declining, the socket failing, the watchdog giving up -- is the
                    // FOURTH way a fire produces no lock, and it was the only one that just returned.
                    //
                    // What that cost: sIdleArmed stays TRUE (it is cleared in exactly two places,
                    // ChooserActivity ACTION_USER_PRESENT and cancelIdleWatcher, and neither runs here), so the
                    // screen-off armer's early-return refuses to arm again for the REST OF THE SESSION. The
                    // reachable shape is a logoff: handleLogout removes .roamsession first, so the daemon
                    // answers "nothing to lock" -- and if that logoff then FAILS (#86 keeps the session signed
                    // in and re-arms .roamsession) the session is live, CE-UNLOCKED, with no idle bound AND no
                    // 12h hard wipe, since armWipeWatcher's only caller is inside doColdLock. Only the user
                    // coming back and unlocking would have restored it -- which is exactly what someone who
                    // walked away from a 45-minute logoff is not doing. The comment on the watchdog below said
                    // "the alarm retries next screen-off"; that is the assumption this breaks.
                    //
                    // rearmIdleShort no-ops when the watcher was never armed or the session already ended, so
                    // it is safe on every path through here.
                    if (after.rearm) {
                        android.util.Log.i("NowhereChooser",
                                "idle cold-lock: no lock started -> re-armed (NWP-20260922-07)");
                        ChooserActivity.idleTrace("defer nolock");
                        ChooserActivity.rearmIdleShort(ctx, NOLOCK_REGRACE_MS);
                    }
                    // ⚠⚠ THE WAKELOCK RELEASE IS A DIFFERENT QUESTION FROM THE RE-ARM, AND MUST BE AFFIRMATIVE.
                    //
                    // An earlier cut of this released on `after.rearm`, reasoning "no teardown is coming". That
                    // does not follow: `after.rearm` is true on a socket error, a read timeout, the watchdog, and
                    // an older agent's bare OK -- none of which mean no teardown. The reachable case is ugly.
                    // COLD-LOCK-IDLE is NOT on the daemon's concurrentSafeCmd allowlist, so it waits on
                    // sessionMu, which "a materialise/login/logoff holds for MINUTES"; our read times out at
                    // READ_CAP_MS, we conclude "no lock", and the daemon THEN acquires the lock, finds a live
                    // session and runs the FULL teardown -- with the CPU no longer held.
                    //
                    // And this wakelock is NOT REFERENCE-COUNTED, deliberately ("a single release always frees
                    // it", ChooserActivity coldWakeAcquire). So one stray release here frees the lock the REAP
                    // WATCHER took for the stopUser + CE-evict leg, and the one the NWP-20260922-06 hand-switch
                    // teardown takes. That is verbatim the defect NWP-20260914-01 exists to prevent, measured
                    // twice on frankel: the lock advanced only when something else happened to wake the phone.
                    //
                    // So release ONLY when the daemon positively told us it looked and found nothing to lock.
                    // Every ambiguous outcome keeps the lock and lets COLD_WAKE_MS bound it, which is the
                    // contract this file already documented: "Released by the watcher after the LOCK ack;
                    // COLD_WAKE_MS bounds every other path."
                    if (after.releaseWake) {
                        ChooserActivity.coldWakeRelease();
                    }
                    finish.run();
                }
            });
            worker.setDaemon(true);
            worker.start();

            // Watchdog: connect() has no timeout, so if the daemon is wedged the worker never returns. At the
            // cap, close the socket (unblocks the worker's blocking connect/read) and finish the broadcast
            // anyway -- so it can NEVER reach the 60s ANR and kill the gate. The alarm retries next screen-off.
            Thread watchdog = new Thread(() -> {
                try { Thread.sleep(CONNECT_CAP_MS); } catch (InterruptedException ignore) {}
                if (!done.get()) {
                    android.util.Log.w("NowhereChooser", "idle COLD-LOCK: daemon unresponsive, abandoning (will retry)");
                    try { s.close(); } catch (Throwable ignore) {}
                    finish.run();
                }
            });
            watchdog.setDaemon(true);
            watchdog.start();
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "idle cold-lock", t);
        }
    }
}
