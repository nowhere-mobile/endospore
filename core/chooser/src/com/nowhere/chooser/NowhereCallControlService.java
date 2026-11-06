package com.nowhere.chooser;

import android.content.Context;
import android.telecom.Call;
import android.telecom.InCallService;

/**
 * Gate CONTROL InCallService (#163 wrong-user fix; DIA-20260714). The UI InCallService (NowhereInCallService,
 * IN_CALL_SERVICE_UI) is bound ONLY for the foreground user's dialer, so it is SKIPPED when a roamed user is
 * foreground (proven 2026-07-13). This CONTROL one (no IN_CALL_SERVICE_UI + CONTROL_INCALL_EXPERIENCE, the class
 * Android Auto / Wear use) gets onCallAdded for EVERY inbound call, whoever is foreground. ⚠ It runs as the
 * FOREGROUND user, not user 0 (NWP-20260930-05, a source read: a SIM's phone account is MULTI_USER, so Telecom
 * binds for the current user, UserUtil.getAssociatedUserForCall); onCallAdded logs which user it runs as.
 *
 * P1 = the wrong-user privacy fix. Native routing rings the SIM's inbound call in WHOEVER is foreground, so a
 * non-owner (throwaway/unbound) session receives the owner's calls (a locked session can't ANSWER -- the
 * keyguard bouncer -- but an unlocked one could, and either way the owner loses the call to the stranger's
 * wiped session). #158 already re-instates DISALLOW_OUTGOING_CALLS on exactly those non-owner sessions; by
 * symmetry they must not receive on the owner's SIM either. So if the foreground user carries that restriction,
 * REJECT the call from this cross-user hook. Owner-foreground (restriction cleared) and gate (user 0) fall
 * through untouched -> native rings for the owner; the UI away-path handles user-0 foreground. Fail-OPEN.
 *
 * P2 (DONE, DIA-20260714): before rejecting, SEAL a missed-call record to the SIM's bound owner (SEAL-TEL, in
 * user 0 through RejectedCallSealReceiver since NWP-20260930-05) so the owner receives the missed call at their
 * next login instead of it only reaching carrier voicemail.
 *
 * ⚠ NWP-20260901-12 -- EMERGENCY CALLBACKS ARE EXEMPT, and the gap this closed was live on the DEFAULT state
 * of a fresh device. The "stranger" test above is DISALLOW_OUTGOING_CALLS, which #158 sets on a session whose
 * profile does not own the SIM. On an UNBOUND SIM, TEL-OWNER answers NO for EVERY profile -- so every roamed
 * session is a stranger, so EVERY inbound call was declined, a PSAP calling back included. It rang first and
 * TelScrub then wiped user 0's log, so the outcome was ring, vanish, no record: exactly what #196 was decided
 * to prevent, reached by a different route. See emergencyExemption for the four signals and why the
 * foreground "stranger" is, on a callback, the person who dialled.
 */
public final class NowhereCallControlService extends InCallService {

    /** NWP-20260901-12: when this device last placed a call to an emergency number, or 0.
     *
     *  ⚠ THIS EXISTS BECAUSE ECBM IS NOT DEPENDABLE. Emergency Callback Mode is the platform's own
     *  "a callback may be coming" signal, but whether it is entered at all is a network/modem decision --
     *  historically a CDMA behaviour, and on many LTE/VoLTE networks it is simply never set. Relying on it
     *  alone would leave the callback rejected on exactly the networks where it is not set, and the failure
     *  would be invisible until someone needed it. So we also remember, locally, that an emergency call went out.
     *  ⚠ NWP-20260930-05: a PER-PROCESS static, and Telecom binds this service as the FOREGROUND user, so it does
     *  NOT survive a user switch -- docs/backlog.md, "The emergency-callback window does not survive a user switch, so a PSAP callback after a login can be rejected".
     *  Static and RAM-only, deliberately: it must not survive a power-off (nothing does here), and a fresh
     *  boot starting at 0 is correct -- the phone has placed no emergency call this boot. */
    private static volatile long sLastEmergencyOutboundAt = 0L;

    /** How long after an outbound emergency call any inbound call is treated as a possible callback.
     *
     *  15 minutes is deliberately generous. A PSAP callback is not prompt by design -- a dispatcher calls back
     *  when they have a moment, and a re-dispatch can be much later. The cost of the window being too long is
     *  that, ONLY on a handset that has just dialled an emergency number, some of the SIM owner's calls may
     *  ring in a non-owner session for 15 minutes. The cost of it being too short is that someone in an
     *  emergency does not get the call back. That asymmetry is not close. */
    private static final long EMERGENCY_CALLBACK_WINDOW_MS = 15L * 60L * 1000L;

    /** NWP-20260901-12: the reason this inbound call must NOT be rejected, or null if none applies.
     *
     *  ⚠ THE BUG THIS FIXES, and it was live on the DEFAULT state of a fresh device. This service declines an
     *  inbound call whenever the foreground user carries DISALLOW_OUTGOING_CALLS -- the "stranger session"
     *  test. But an UNBOUND SIM makes TEL-OWNER answer NO for EVERY profile, so #158 sets that restriction on
     *  every roamed session, so every session is a stranger, so EVERY inbound call was declined. Including a
     *  PSAP calling back. The call rang first and TelScrub then wiped user 0's log, so the outcome was ring,
     *  vanish, no record -- which is precisely what #196 was decided to prevent, arrived at by a different
     *  route. There was no emergency check anywhere in this file, and a whole-tree grep for isEmergencyNumber
     *  / ACTION_EMERGENCY / ECBM returned nothing.
     *
     *  ⚠ AND THE PERSON WE WERE PROTECTING THE OWNER FROM IS THE PERSON WHO DIALLED. The foreground session is
     *  whoever is holding the phone, so on a callback they are not a stranger to that call at all -- they are
     *  the caller. Ringing it for them is not a leak being tolerated for safety; it is the correct routing.
     *
     *  Four independent signals, any one of which exempts. Each is guarded separately so that a throw in one
     *  only removes THAT signal rather than the whole check.
     *
     *  Returning null (reject) is only reached when every signal was evaluated and none fired. */
    static String emergencyExemption(Context app, Call.Details d) {
        // 1. The platform flagged this very call as being in emergency callback mode. Local, cannot throw.
        try {
            if (d != null && d.hasProperty(Call.Details.PROPERTY_EMERGENCY_CALLBACK_MODE)) {
                return "call has PROPERTY_EMERGENCY_CALLBACK_MODE";
            }
        } catch (Throwable ignore) {}
        // 2. The NETWORK identified this call as an emergency call.
        try {
            if (d != null && d.hasProperty(Call.Details.PROPERTY_NETWORK_IDENTIFIED_EMERGENCY_CALL)) {
                return "call has PROPERTY_NETWORK_IDENTIFIED_EMERGENCY_CALL";
            }
        } catch (Throwable ignore) {}
        // 3. The device is in Emergency Callback Mode right now. @SystemApi + READ_PRIVILEGED_PHONE_STATE,
        //    which this app holds (platform-signed, platform_apis). See the field comment for why this is
        //    necessary but NOT sufficient on its own.
        try {
            android.telephony.TelephonyManager tm =
                    app.getSystemService(android.telephony.TelephonyManager.class);
            if (tm != null && tm.getEmergencyCallbackMode()) return "device is in emergency callback mode";
        } catch (Throwable ignore) {}
        // 4. We saw an emergency call leave this handset recently (see sLastEmergencyOutboundAt).
        long since = sLastEmergencyOutboundAt;
        if (since > 0) {
            long age = System.currentTimeMillis() - since;
            // A backwards clock jump would make age negative; treat that as inside the window rather than
            // outside it, because the safe direction here is "do not reject".
            if (age < EMERGENCY_CALLBACK_WINDOW_MS) {
                return "an emergency call left this phone " + (age < 0 ? 0 : age / 1000) + "s ago";
            }
        }
        // 5. The caller's number is itself an emergency number. Public API. Last because a PSAP callback
        //    usually arrives from an ordinary administrative number, so this rarely fires -- but when it does
        //    it is decisive.
        try {
            String from = NowhereInCallService.numberOf(d);
            if (from != null && !from.isEmpty()) {
                android.telephony.TelephonyManager tm =
                        app.getSystemService(android.telephony.TelephonyManager.class);
                if (tm != null && tm.isEmergencyNumber(from)) return "caller is an emergency number";
            }
        } catch (Throwable ignore) {}
        return null;
    }

    @Override
    public void onCallAdded(Call call) {
        super.onCallAdded(call); final long mono = TelArrival.stamp(); // NWP-20260930-05: the arrival's stamp
        try {
            Call.Details d = call.getDetails();
            int dir = (d == null) ? -1 : d.getCallDirection();
            int cur = android.app.ActivityManager.getCurrentUser();
            android.util.Log.i("NowhereChooser",
                    "call-control: onCallAdded dir=" + dir + " curUser=" + cur + " myUser=" + android.os.UserHandle.myUserId() + " state=" + call.getState());
            if (dir != Call.Details.DIRECTION_INCOMING) {
                // NWP-20260901-12: OUTBOUND -- remember an emergency dial so a later callback is exempt.
                // This runs BEFORE the inbound-only return that used to be the first thing here, because this
                // service is the only cross-user hook that observes every call on the SIM, so it is the only
                // place that can see the outgoing leg at all.
                if (dir == Call.Details.DIRECTION_OUTGOING) {
                    try {
                        String to = NowhereInCallService.numberOf(d);
                        android.telephony.TelephonyManager tm =
                                getApplicationContext().getSystemService(android.telephony.TelephonyManager.class);
                        if (to != null && !to.isEmpty() && tm != null && tm.isEmergencyNumber(to)) {
                            sLastEmergencyOutboundAt = System.currentTimeMillis();
                            // No number in the log line: this is user-0's logcat and the number is the
                            // emergency service, but the FACT of the call is still the user's business.
                            android.util.Log.i("NowhereChooser",
                                    "call-control: emergency call placed -- inbound calls are exempt from the "
                                    + "wrong-user reject for the next "
                                    + (EMERGENCY_CALLBACK_WINDOW_MS / 60000) + " min (NWP-20260901-12)");
                        }
                    } catch (Throwable ignore) {}
                }
                return; // only inbound past this point
            }
            if (cur <= 0) return; // gate foreground -> the UI away-path (NowhereInCallService) owns it
            boolean stranger = false;
            try {
                Context uc = createContextAsUser(android.os.UserHandle.of(cur), 0);
                android.os.UserManager um = uc.getSystemService(android.os.UserManager.class);
                stranger = um != null && um.hasUserRestriction(android.os.UserManager.DISALLOW_OUTGOING_CALLS);
            } catch (Throwable ignore) { /* fail-open */ }
            if (stranger) {
                // NWP-20260901-12: an emergency callback is NEVER rejected, whoever is foreground. Checked
                // BEFORE the seal, so an exempt call takes no side effect at all -- it is not a missed call,
                // so sealing a MISSED record for it would be a second, quieter lie.
                String exempt = emergencyExemption(getApplicationContext(), d);
                if (exempt != null) {
                    android.util.Log.i("NowhereChooser",
                            "call-control: NOT rejecting in non-owner session (user " + cur + ") -- " + exempt
                            + " (NWP-20260901-12)");
                    return; // let it ring: on a callback the foreground session IS the caller
                }
                android.util.Log.i("NowhereChooser",
                        "call-control: sealing (missed) + rejecting owner's call in non-owner session (user " + cur + ")");
                // #163 P2: SEAL a MISSED-call record to the SIM's BOUND OWNER (SEAL-TEL looks up the binding, not
                // the foreground stranger) so the owner receives it at their next login -- BEFORE we decline.
                // Snapshot the details now (the reject ends the call), and hand the seal to user 0 (NWP-20260930-05,
                // RejectedCallSealReceiver): this process is the stranger's, which can be frozen or stopped during the
                // retries, and whose record of Private lines (TelArrival.knownPrivate) is empty. The record's only home
                // is the tmpfs inbox, wiped at power-off -- best-effort by the amnesiac contract. Also scrub user 0's
                // CallLog in case the rejected call left a row there (belt-and-suspenders; the janitor also covers it).
                final Context app = getApplicationContext();
                final String from = NowhereInCallService.numberOf(d);
                final long when = d.getCreationTimeMillis();
                final int[] subOut = { android.telephony.SubscriptionManager.INVALID_SUBSCRIPTION_ID }; // never the default SIM
                final String iccid = NowhereInCallService.resolveSubIccid(app, d, subOut);
                final int subId = subOut[0];
                new Thread(() -> TelScrub.callLogRetry(app), "nowhere-scrub-rejected-call").start(); // not after the seal
                // The stamp is elapsedRealtime, one clock for every process. A hand-off that throws keeps nothing, so it
                // posts the loss notice itself (SmsDeliverReceiver.settle's rule; this process cannot know whether the
                // line is Private). The call is declined either way: the stranger must not be able to answer it.
                try {
                    app.sendBroadcastAsUser(new android.content.Intent(app, RejectedCallSealReceiver.class)
                            .putExtra(RejectedCallSealReceiver.EXTRA_SUB, subId).putExtra(RejectedCallSealReceiver.EXTRA_ICCID, iccid)
                            .putExtra(RejectedCallSealReceiver.EXTRA_FROM, from).putExtra(RejectedCallSealReceiver.EXTRA_WHEN, when)
                            .putExtra(RejectedCallSealReceiver.EXTRA_MONO, mono), android.os.UserHandle.SYSTEM);
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "call-control: seal hand-off to user 0 failed", t); SmsDeliverReceiver.postLossNotice(app, "call", 3, TelArrival.callId(subId, when)); }
                // decline the ringing call so the stranger session can't answer it.
                call.reject(false, null);
            }
            // owner-foreground (non-stranger) / error -> leave the call alone: native rings it for the owner.
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "call-control onCallAdded", t);
        }
    }
}
