package com.nowhere.chooser;

import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.database.ContentObserver;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.telecom.Call;
import android.telecom.CallAudioState;
import android.telecom.InCallService;
import android.telecom.PhoneAccountHandle;
import android.telecom.VideoProfile;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * #135 B4: gate incoming calls. user 0 owns the radio, so as user 0's DEFAULT DIALER the framework binds
 * this InCallService for every inbound call (docs/telephony-owner-mode.md). Two jobs:
 *
 *  - DATA (B4.a): on call END, seal a content-minimal call record to the SIM's bound profile(s) via the
 *    daemon's SEAL-TEL verb (reusing SmsDeliverReceiver.sealAndNotify with kind="call") and raise a
 *    content-free notice per the owner-set visibility dial. Nothing readable is kept on the non-amnesiac
 *    user 0: the auto-written CallLog.Calls row is SCRUBBED (TelScrub).
 *  - UI (B4.b): surface a full-screen IncomingCallActivity so an open line can be ANSWERED at the gate (or
 *    during cold-lock, over the insecure keyguard, without unlocking). The activity is a thin view; THIS
 *    service is the single source of truth for the Call and for sealing/scrubbing.
 *
 * Records ONLY when user 0 is foreground; a call arriving while a ROAMED user is foreground is left to the
 * native path (the V1 case, a later slice). The whole surface runs in the persistent user-0 chooser process
 * (android:persistent), so the static bridge below never crosses processes.
 */
public final class NowhereInCallService extends InCallService {

    /** The activity registers here to observe the live call + audio state. Package-visible; same process. */
    interface UiListener {
        void onCallState(int state);
        void onAudioState(CallAudioState s);
    }

    static volatile NowhereInCallService INSTANCE;      // set in onCreate, cleared in onDestroy
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<Call, Recorder> recorders = new HashMap<>(); // one Recorder per live call (seal-once)
    private Call current;                                // the single call we SURFACE (single-line gate)
    private Call pendingEnd;                             // NWP-20261114-02: an answered call an emergency callback displaced
    private volatile UiListener ui;                      // non-null only while the activity is bound
    private ContentObserver logObserver;                 // scrubs any CallLog row written during a call

    @Override public void onCreate() {
        super.onCreate();
        INSTANCE = this;
        final Context app = getApplicationContext();
        // Standing scrub while any call is live: the framework can write the CallLog row at any point around
        // onCallRemoved, including after the on-end retry budget. Delete on any change so no readable row
        // lingers -- but QUERY FIRST and delete only when a row actually exists, else our own delete's change
        // notification would re-fire onChange forever (delete -> notify -> delete). Needs READ_CALL_LOG (the
        // dialer role grants it); if the query is denied we skip -- the retry + gate/boot sweeps still cover it.
        try {
            logObserver = new ContentObserver(main) {
                @Override public void onChange(boolean selfChange) {
                    new Thread(() -> {
                        try (android.database.Cursor c = app.getContentResolver().query(
                                android.provider.CallLog.Calls.CONTENT_URI,
                                new String[]{ android.provider.CallLog.Calls._ID }, null, null, null)) {
                            if (c != null && c.moveToFirst()) TelScrub.callLog(app);
                        } catch (Throwable ignore) {}
                    }, "nowhere-scrub-obs").start();
                }
            };
            getContentResolver().registerContentObserver(
                    android.provider.CallLog.Calls.CONTENT_URI, true, logObserver);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "reg call-log observer", t);
        }
    }

    @Override public void onDestroy() {
        try { if (logObserver != null) getContentResolver().unregisterContentObserver(logObserver); }
        catch (Throwable ignore) {}
        final Context app = getApplicationContext();
        new Thread(() -> TelScrub.callLogRetry(app), "nowhere-scrub-final").start(); // sweep after last call
        INSTANCE = null;
        super.onDestroy();
    }

    @Override public void onCallAdded(Call call) {
        super.onCallAdded(call); TelArrival.stampCall(call); // NWP-20260930-05: the arrival's stamp, before the #145 re-check
        try {
            if (!isIncoming(call)) {
                // NWP-20261001-04: the gate's ONLY self-originated outgoing calls are owner-mode transmit on the
                // unbound SIM (637). Surface control UI (Hang up / Mute / Speaker) for it WITHOUT a sealing Recorder,
                // so the owner can end the call and fire-and-forget holds (no sent record). Scoped by the arm flag
                // placeOwnerCall sets just before placing: an emergency call, placed via the system emergency dialer
                // (never placeOwnerCall), is not armed and keeps its own UI — the proven T2 path, unchanged.
                if (consumeOwnerOutgoing()) adoptOutgoingForUi(call);
                return;
            }
            if (ActivityManager.getCurrentUser() != 0) {
                // #145 ring continuity: Telecom (re)binds this user-0 UI service as a logoff switches back
                // to the gate and redelivers the still-ringing call here -- but getCurrentUser() can still
                // report the outgoing roamed user for a beat mid-switch. Don't drop the call outright:
                // re-check once the switch settles, and adopt if the gate has landed and the call is still
                // up. A genuinely roamed-foreground call bails again at the re-check (native path, V1).
                main.postDelayed(() -> {
                    try {
                        if (ActivityManager.getCurrentUser() != 0 || !getCalls().contains(call)) return;
                        adoptIncoming(call);
                    } catch (Throwable t) {
                        android.util.Log.w("NowhereChooser", "onCallAdded recheck (#145)", t);
                    }
                }, 1200);
                return;
            }
            adoptIncoming(call);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "onCallAdded", t);
        }
    }

    /** Adopt one inbound call at the gate: register its seal Recorder and surface the answer UI (or settle a
     *  second concurrent line by secondCall). Idempotent per call -- a re-entry from the #145 switch-race re-check
     *  is a no-op once the Recorder is registered, so a call can never be double-sealed.
     *
     *  NWP-20261114-02 (Q044, docs/product-decisions.md 2026-10-20): an emergency callback that arrives as the
     *  second line takes it from an ordinary call. Only the two calls' OWN details count (callIsEmergency): the
     *  callback-mode flags and the 15-minute window describe the phone, not the call. A ringing first call is
     *  rejected (its Recorder seals it as missed); an answered one stays connected off screen (pendingEnd) and
     *  ends when the callback is answered. Call waiting was not chosen, so the accepted cost is twofold: an
     *  ordinary call can be lost, and a PSAP that calls back from an administrative number is still rejected. */
    private void adoptIncoming(Call call) {
        if (recorders.containsKey(call)) return;
        Recorder r = new Recorder(getApplicationContext());
        recorders.put(call, r);
        call.registerCallback(r);
        if (current == null) {
            // First inbound: surface the full-screen answer UI.
            current = call;
            call.registerCallback(uiForward);
            launchUi();
        } else {
            // A second concurrent inbound. The amnesiac gate is a single line with no call-waiting UI, so it
            // never shows two screens and never lets a call ring unanswerable. Any throw while classifying
            // falls back to REJECT_NEW, today's path.
            int act = REJECT_NEW;
            try {
                final Context app = getApplicationContext();
                act = secondCall(callIsEmergency(app, call.getDetails()),
                        callIsEmergency(app, current.getDetails()),
                        current.getState() == Call.STATE_RINGING);
            } catch (Throwable t) {
                act = REJECT_NEW;
            }
            if (act == TAKE_REJECT_CURRENT) {
                // The callback takes the screen FIRST, so the old call's DISCONNECTED never reaches it; the old
                // call's Recorder then seals it as MISSED on the reject.
                Call old = current;
                handOver(call);
                try { old.reject(false, null); } catch (Throwable ignore) {}
            } else if (act == TAKE_END_ON_ANSWER) {
                // The answered call stays connected off screen until the callback is answered (answer()), or
                // comes back on screen if the callback is declined or ends (declineOrHangup, onCallRemoved).
                pendingEnd = current;
                handOver(call);
            } else {
                // REJECT_NEW: reject it. Its Recorder (registered above) still seals + scrubs it as MISSED.
                try {
                    if (call.getState() == Call.STATE_RINGING) call.reject(false, null);
                    else call.disconnect();
                } catch (Throwable ignore) {}
            }
        }
    }

    // NWP-20261114-02 (Q044): what a second concurrent inbound call at the gate does.
    static final int REJECT_NEW = 0;          // reject the new call (the single-line gate's default)
    static final int TAKE_REJECT_CURRENT = 1; // the new call takes the screen; the ringing current is rejected
    static final int TAKE_END_ON_ANSWER = 2;  // the new call takes the screen; the answered current ends on answer

    /** Pure (no android types): a second call takes the line only when IT is an emergency call and the call on
     *  screen is not. An emergency call on screen is never displaced. */
    static int secondCall(boolean incomingIsEmergency, boolean currentIsEmergency, boolean currentRinging) {
        if (!incomingIsEmergency || currentIsEmergency) return REJECT_NEW;
        return currentRinging ? TAKE_REJECT_CURRENT : TAKE_END_ON_ANSWER;
    }

    /** True only when the call's OWN details mark it as an emergency call: the network identified it as one, or
     *  its caller number is an emergency number. Each signal has its own try/catch, so a throw removes only that
     *  signal. It never reads the emergency-callback-mode property, the callback-mode state or any time window
     *  (Q044): those describe the PHONE, not the call. Inside the window every call passes them, so a later
     *  ordinary call would push a ringing callback off the line. */
    static boolean callIsEmergency(Context app, Call.Details d) {
        try {
            if (d != null && d.hasProperty(Call.Details.PROPERTY_NETWORK_IDENTIFIED_EMERGENCY_CALL)) return true;
        } catch (Throwable ignore) {}
        try {
            String from = numberOf(d);
            if (!from.isEmpty()) {
                TelephonyManager tm = app.getSystemService(TelephonyManager.class);
                if (tm != null && tm.isEmergencyNumber(from)) return true;
            }
        } catch (Throwable ignore) {}
        return false;
    }

    /** NWP-20261114-02: move the screen from the current call to `next`. uiForward leaves the old call first, so
     *  its later DISCONNECTED never finishes the screen; the bound screen then repaints from currentCall(). A
     *  DISCONNECTED or DISCONNECTING state is never forwarded here: either would finish the screen, and that
     *  call's own onCallRemoved handles its end. */
    private void handOver(Call next) {
        Call old = current;
        if (old != null) { try { old.unregisterCallback(uiForward); } catch (Throwable ignore) {} }
        current = next;
        if (next == null) return;
        try { next.registerCallback(uiForward); } catch (Throwable ignore) {}
        UiListener l = ui;
        if (l != null) {
            int st = Call.STATE_NEW;
            try { st = next.getState(); } catch (Throwable ignore) {}
            if (st != Call.STATE_DISCONNECTED && st != Call.STATE_DISCONNECTING) l.onCallState(st);
        }
        launchUi();
    }

    /** NWP-20261001-04 (637): surface the owner's OWN outgoing call for control ONLY — Hang up / Mute / Speaker via
     *  the shared IncomingCallActivity — with NO Recorder, so the call is never sealed (fire-and-forget, decided
     *  2026-10-01). Single-line gate: if a call is already surfaced, do not open a second screen. */
    private void adoptOutgoingForUi(Call call) {
        if (current != null) return;
        current = call;
        call.registerCallback(uiForward);
        launchUi();
    }

    // placeOwnerCall arms this just before TelecomManager.placeCall so the next outgoing call added is known to be
    // the owner's own transmit and gets control UI (above). Time-bounded so a stale arm can never mis-adopt a later
    // call, and consumed once. An emergency call never arms it (placed via the system dialer, not placeOwnerCall).
    private static volatile long sOwnerOutgoingArmedAt = 0;
    static void armOwnerOutgoing() { sOwnerOutgoingArmedAt = android.os.SystemClock.elapsedRealtime(); }
    private static boolean consumeOwnerOutgoing() {
        long t = sOwnerOutgoingArmedAt;
        if (t != 0 && android.os.SystemClock.elapsedRealtime() - t < 15000) { sOwnerOutgoingArmedAt = 0; return true; }
        return false;
    }

    @Override public void onCallRemoved(Call call) {
        super.onCallRemoved(call);
        // Seal-once safety net: Telecom does NOT guarantee an observed STATE_DISCONNECTED before onCallRemoved
        // (last-call teardown, coalesced disconnect). Recorder.finish()'s `done` guard makes this idempotent
        // with the DISCONNECTED path, so driving finish() here too guarantees the seal + scrub run for EVERY
        // call -- the amnesiac guarantee cannot depend on a callback Telecom may skip.
        try {
            Recorder r = recorders.remove(call);
            if (r != null) r.finish(call);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "onCallRemoved seal", t);
        }
        if (call == pendingEnd) {
            pendingEnd = null; // NWP-20261114-02: the displaced answered call ended; its Recorder sealed it above
        } else if (call == current) {
            // NWP-20261114-02: the emergency callback ended while the answered call it displaced is still live.
            // Hand the screen back to that call instead of finishing it.
            Call back = pendingEnd;
            pendingEnd = null;
            boolean live = false;
            if (back != null) {
                try {
                    int st = back.getState();
                    live = st != Call.STATE_DISCONNECTED && st != Call.STATE_DISCONNECTING;
                } catch (Throwable ignore) {}
            }
            if (live) {
                handOver(back);
            } else {
                try { call.unregisterCallback(uiForward); } catch (Throwable ignore) {}
                current = null;
                UiListener l = ui;
                if (l != null) l.onCallState(Call.STATE_DISCONNECTED); // tell the activity to finish
            }
        }
    }

    @Override public void onCallAudioStateChanged(CallAudioState s) {
        super.onCallAudioStateChanged(s);
        UiListener l = ui;
        if (l != null) l.onAudioState(s);
    }

    /** Forwards the surfaced call's state changes to the bound activity (ring -> active -> gone). */
    private final Call.Callback uiForward = new Call.Callback() {
        @Override public void onStateChanged(Call call, int state) {
            UiListener l = ui;
            if (l != null) l.onCallState(state);
        }
    };

    private void launchUi() {
        startCallUi();
        // Bounded retry: we hold START_ACTIVITIES_FROM_BACKGROUND (platform-signed), so the direct start is
        // normally a single success even cold-locked; the retry only covers a roam-in/switch edge where the
        // chooser task is briefly not foreground and the first start is throttled. Inside the kiosk a
        // full-screen-intent notification is NOT an option (LockTask has no NOTIFICATIONS feature + the shade
        // is DISABLE_EXPAND'd), so a direct start is the only launch path -- hence the retry.
        main.postDelayed(() -> {
            if (current != null && !IncomingCallActivity.isShowing()) startCallUi();
        }, 600);
    }

    private void startCallUi() {
        try {
            startActivity(new Intent(this, IncomingCallActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "launch call UI", t);
        }
    }

    // ===== control surface for IncomingCallActivity (null-guarded: the service can be torn down between the
    // last call and a queued button tap, and this is the persistent HOME process -- an NPE here would crash
    // the gate and drop the kiosk) =====

    static Call currentCall() { NowhereInCallService s = INSTANCE; return s == null ? null : s.current; }
    static void bindUi(UiListener l) { NowhereInCallService s = INSTANCE; if (s != null) s.ui = l; }
    static void unbindUi(UiListener l) { NowhereInCallService s = INSTANCE; if (s != null && s.ui == l) s.ui = null; }

    static CallAudioState audioState() {
        NowhereInCallService s = INSTANCE;
        if (s == null) return null;
        try { return s.getCallAudioState(); } catch (Throwable t) { return null; }
    }
    static boolean isMuted() { CallAudioState a = audioState(); return a != null && a.isMuted(); }
    static boolean isSpeaker() { CallAudioState a = audioState(); return a != null && a.getRoute() == CallAudioState.ROUTE_SPEAKER; }

    static void answer() {
        NowhereInCallService s = INSTANCE;
        if (s == null || s.current == null) return;
        try {
            if (s.current.getState() == Call.STATE_RINGING) {
                // NWP-20261114-02 (Q044): answering the emergency callback ends the answered call it displaced.
                // pendingEnd is cleared first, so that call's onCallRemoved never hands the screen back to it.
                Call end = s.pendingEnd;
                if (end != null) { s.pendingEnd = null; try { end.disconnect(); } catch (Throwable ignore) {} }
                s.current.answer(VideoProfile.STATE_AUDIO_ONLY);
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "answer", t); }
    }

    /** Decline a ringing call (reject) or hang up a connected one (disconnect) -- chosen by live state, since
     *  reject() is only valid while RINGING and disconnect() is required once connected. */
    static void declineOrHangup() {
        NowhereInCallService s = INSTANCE;
        if (s == null || s.current == null) return;
        try {
            Call c = s.current;
            Call back = s.pendingEnd;
            if (back != null && c.getState() == Call.STATE_RINGING) {
                // NWP-20261114-02 (Q044): decline the ringing emergency callback only; the answered call it
                // displaced comes back on screen. handOver moves uiForward off the callback first, so the
                // callback's DISCONNECTING/DISCONNECTED never finishes the screen.
                Call cb = c;
                s.pendingEnd = null;
                s.handOver(back);
                cb.reject(false, null);
                return;
            }
            if (c.getState() == Call.STATE_RINGING) c.reject(false, null);
            else c.disconnect();
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "declineOrHangup", t); }
    }

    static void toggleMute() {
        NowhereInCallService s = INSTANCE;
        if (s == null) return;
        try { s.setMuted(!isMuted()); } catch (Throwable t) { android.util.Log.w("NowhereChooser", "mute", t); }
    }

    static void setSpeaker(boolean on) {
        NowhereInCallService s = INSTANCE;
        if (s == null) return;
        // ROUTE_WIRED_OR_EARPIECE (not bare EARPIECE) so turning speaker off still works with a wired headset.
        try { s.setAudioRoute(on ? CallAudioState.ROUTE_SPEAKER : CallAudioState.ROUTE_WIRED_OR_EARPIECE); }
        catch (Throwable t) { android.util.Log.w("NowhereChooser", "speaker", t); }
    }

    private static boolean isIncoming(Call call) {
        if (call.getState() == Call.STATE_RINGING) return true;
        try { return call.getDetails().getCallDirection() == Call.Details.DIRECTION_INCOMING; }
        catch (Throwable t) { return false; }
    }

    /** Watches one incoming call and seals + scrubs a record when it ends. Registered per-call; seal-once. */
    private static final class Recorder extends Call.Callback {
        private final Context app;
        private boolean connected = false; // reached STATE_ACTIVE -> the call was answered (else it's missed)
        private boolean done = false;
        Recorder(Context app) { this.app = app; }

        @Override public void onStateChanged(Call call, int state) {
            if (state == Call.STATE_ACTIVE) connected = true;
            if (state == Call.STATE_DISCONNECTED) finish(call);
        }

        void finish(Call call) {
            if (done) return; // DISCONNECTED can arrive alongside onCallRemoved; seal + scrub once
            done = true;
            try { call.unregisterCallback(this); } catch (Throwable ignore) {}
            try {
                final Call.Details d = call.getDetails();
                final String from = numberOf(d);
                final long when = d.getCreationTimeMillis();
                // CallLog.Calls.TYPE: INCOMING=1 (answered), MISSED=3 (rang, never connected).
                final int callType = connected ? 1 : 3;
                final int durSec = (connected && d.getConnectTimeMillis() > 0)
                        ? (int) Math.max(0, (System.currentTimeMillis() - d.getConnectTimeMillis()) / 1000) : 0;
                final int[] subOut = { SubscriptionManager.INVALID_SUBSCRIPTION_ID }; // NWP-20260930-05: never the default SIM
                final String iccid = resolveSubIccid(app, d, subOut);
                final int subId = subOut[0];
                // SCRUB regardless of the seal, and no longer after it (NWP-20260930-05: the seal now retries to
                // TelArrival.SEAL_DEADLINE_MS). user 0's CallLog row is NOT how the owner receives the record (that is
                // the sealed inbox), so it is pure leak -- delete it. #197 amnesia: the AOSP MissedCallNotifier posts
                // its OWN "Missed call" + the caller's number in the CLEAR on user 0 -- a pure leak too, so cancel it
                // (we are user 0's default dialer); it is posted async right after the call ends, so both retry.
                new Thread(() -> {
                    TelScrub.callLogRetry(app);
                    cancelFrameworkMissedCall(app);
                }, "nowhere-scrub-call").start();
                // The arrival's stamp was taken at onCallAdded, before the #145 re-check could delay adopting the call;
                // its id is the call's subId and creation time, which the call-control service computes alike.
                final long mono = TelArrival.callStamp(call);
                new Thread(() -> {
                    // SEAL, retried to the deadline with one arrival id: the daemon can be starting, restarting, or
                    // transiently wedged right after a cold-lock resume (#77), and a repeat is answered from its
                    // replay table, never sealed twice. The record's only home is the volatile tmpfs inbox
                    // (delivered at the owner's next login), so this is best-effort by design; an arrival it could
                    // not keep leaves the gate's loss notice (SmsDeliverReceiver.settle). Amnesia is the
                    // non-negotiable invariant: the scrub above runs whatever happens here. (callType is
                    // CallLog.Calls.TYPE: INCOMING=1, answered; MISSED=3, rang and never connected.)
                    SmsDeliverReceiver.sealAndNotify(app, "call", subId, iccid, from, when, "", callType, durSec,
                            true, TelArrival.callId(subId, when), mono);
                }, "nowhere-seal-call").start();
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "seal call record", t);
            }
        }
    }

    /** #197 amnesia: cancel the framework's own missed-call notification (com.android.server.telecom /
     *  MissedCallNotifier, channel TelecomMissedCalls), which posts the caller's number in the CLEAR on user 0.
     *  We are user 0's default dialer, so cancelMissedCallsNotification() is ours to call. Retried because the
     *  framework posts it ASYNC just after the call ends. Runs on the seal worker thread (the sleeps are off the
     *  main thread).
     *  NWP-20261012-07: with MissedCallReceiver declared, Telecom posts no notification of its own to cancel -- it
     *  hands the broadcast to that receiver instead -- and this call then zeroes Telecom's per-user missed-call count,
     *  and Telecom answers with a count-0 broadcast, which the receiver drops. It still cancels a framework notification on
     *  an image whose receiver does not resolve. Package-visible for the gate-return scrub (ChooserActivity.onResume). */
    static void cancelFrameworkMissedCall(Context app) {
        android.telecom.TelecomManager tm = app.getSystemService(android.telecom.TelecomManager.class);
        if (tm == null) return;
        for (int i = 0; i < 4; i++) {
            try { tm.cancelMissedCallsNotification(); } catch (Throwable ignore) {}
            try { Thread.sleep(400); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); return; }
        }
    }

    /** Caller number from the tel: handle (raw -- there are no contacts at the gate). "" if withheld/unknown.
     *  Package-visible so NowhereCallControlService can seal a rejected wrong-user call for the owner (#163 P2). */
    static String numberOf(Call.Details d) {
        try {
            Uri h = d.getHandle();
            if (h != null && "tel".equals(h.getScheme())) return h.getSchemeSpecificPart();
        } catch (Throwable ignore) {}
        return "";
    }

    /** Resolve the call's SIM -> subId (written to subOut[0]) + ICCID (returned) for the daemon binding lookup.
     *  #197: resolve the subId DIRECTLY from the call's PhoneAccountHandle via TelephonyManager.getSubscriptionId.
     *  The handle id is NOT always the ICCID -- on some modems it is a short id (e.g. "2") -- so the old
     *  "handle-id == ICCID" match failed on a DUAL-SIM device and the subId fell back to the DEFAULT subscription.
     *  SEAL-TEL then carried the wrong subId+ICCID, the daemon's bindingForSubID missed (NONE), and the missed
     *  call was never sealed (bug: an inbound call on the non-default SIM was dropped on the floor). Derive the
     *  ICCID from the resolved subscription; keep the legacy handle-id-as-ICCID path as a fallback. */
    static String resolveSubIccid(Context app, Call.Details d, int[] subOut) {
        String iccid = "";
        try {
            PhoneAccountHandle h = d.getAccountHandle();
            SubscriptionManager sm = app.getSystemService(SubscriptionManager.class);
            List<SubscriptionInfo> list = (sm == null) ? null : sm.getActiveSubscriptionInfoList();
            int sub = SubscriptionManager.INVALID_SUBSCRIPTION_ID; subOut[0] = sub; // unresolved stays -1: the agent refuses it, never a guessed default SIM (NWP-20260924-07)
            if (h != null) {
                try {
                    android.telephony.TelephonyManager tm = app.getSystemService(android.telephony.TelephonyManager.class);
                    if (tm != null) sub = tm.getSubscriptionId(h); // the handle's real subId (API 30+); needs default-dialer/READ_PHONE_STATE
                } catch (Throwable ignore) { /* fall through to the ICCID path */ }
            }
            if (sub != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                subOut[0] = sub;
                if (list != null) for (SubscriptionInfo si : list) {
                    if (si != null && si.getSubscriptionId() == sub) { iccid = si.getIccId(); break; }
                }
            }
            // Fallback (getSubscriptionId unavailable / builds where the handle id IS the ICCID): match by ICCID, and
            // send the handle id ONLY if it is one -- a short id ("2") reads as an unbound SIM (NWP-20260924-07).
            if (iccid.isEmpty() && h != null && h.getId() != null) {
                if (list != null) for (SubscriptionInfo si : list) {
                    if (si != null && h.getId().equals(si.getIccId())) { iccid = h.getId(); subOut[0] = si.getSubscriptionId(); break; }
                }
            }
        } catch (Throwable ignore) {}
        return iccid;
    }
}
