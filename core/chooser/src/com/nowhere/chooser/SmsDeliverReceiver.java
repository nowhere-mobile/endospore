package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.util.Base64;

import java.nio.charset.StandardCharsets;

/**
 * #135 B3: gate SMS. The chooser is the DEFAULT SMS APP on user 0, so an inbound SMS arrives as SMS_DELIVER
 * -- and as the default app WE own the write into mmssms.db, which we simply SKIP: nothing readable is
 * persisted on the non-amnesiac user 0 (docs/telephony-owner-mode.md, the "achievable zero-window" for SMS).
 *
 * Instead we shuttle the message to the daemon's SEAL-TEL verb, which looks up the SIM's binding and seals
 * the message to EACH owning profile's telephony pubkey (delivered at that profile's next login; gone at
 * reboot). Then, per the SIM's owner-set visibility dial, we raise a CONTENT-FREE notice at the gate
 * ("New message - <label>") -- never the sender or the body. Private lines show nothing. An unbound SIM is the
 * device owner's line: the daemon seals it to the device-owner inbox (Slice D), read behind the owner passphrase,
 * and the gate still shows only the content-free UNBOUND_LINE notice (see there).
 *
 * onReceive must return fast (main thread), so the seal round-trip + notice run on a worker thread.
 */
public final class SmsDeliverReceiver extends BroadcastReceiver {

    @Override public void onReceive(Context ctx, Intent intent) {
        if (!Telephony.Sms.Intents.SMS_DELIVER_ACTION.equals(intent.getAction())) return;
        final SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (parts == null || parts.length == 0 || parts[0] == null) return;

        final String from = safe(parts[0].getDisplayOriginatingAddress());
        // Arrival time (not the SMSC's PDU timestamp): what the owner's Messaging should show as "received".
        final long when = System.currentTimeMillis(), mono = TelArrival.stamp(); // NWP-20260930-05: the stamp, taken once
        final int subId = TelArrival.subIdOr(ctx, intent, intent.getIntExtra("subscription", SubscriptionManager.INVALID_SUBSCRIPTION_ID)); // never the default SIM
        final StringBuilder body = new StringBuilder();
        for (SmsMessage p : parts) { // reassemble a multi-part message
            if (p != null && p.getDisplayMessageBody() != null) body.append(p.getDisplayMessageBody());
        }
        final Context app = ctx.getApplicationContext();
        final String iccid = iccidForSub(app, subId); // stable binding key; best-effort ("" if unavailable)
        final String text = body.toString();
        new Thread(() -> {
            sealAndNotify(app, "sms", subId, iccid, from, when, text, 0, 0, true, TelArrival.smsId(subId, when, from, text), mono);
            // #135 B5: we own+skip the inbox write, but the framework stores every segment in the SMS `raw` table
            // before SMS_DELIVER reaches us. This removes stray sms rows, and the raw rows of dispatched texts once
            // their SMSC timestamp is an hour old (TelScrub.sms): the framework keeps them that hour to discard a
            // network re-send. The per-boot su:s0 janitor leaves raw alone and secure-erases the freed pages.
            TelScrub.sms(app);
        }).start();
    }

    // sealAndNotify's outcome. NWP-20260930-05: it retries itself now; the MMS path releases its claim only on FAILED.
    static final int SEAL_SEALED = 1;   // kept for at least one bound owner, sealed or queued
    static final int SEAL_NONE   = 0;   // nothing for a bound owner or a live session: an unbound arrival (now sealed to the device-owner inbox, Slice D) or unassigned since
    static final int SEAL_FAILED = -1;  // ERR, or no answer, to the deadline: it may or may not have been kept
    static final int SEAL_UNKEPT = -2;  // UNRESOLVED or FULL: not kept; a repeat of this arrival id is answered the same

    /** #196: the line shown for an arrival on a SIM that NO profile is bound to. The device-owner key exists since
     *  NWP-20260928-01, but nothing is sealed to it until the seal-to-owner slice, so nothing is kept yet -- but the
     *  phone still RANG (telecom rings first), and a ring that leaves no trace is the worst of the three possible
     *  behaviours. Proven on lynx 2026-07-23 -- a call to the unbound SIM rang the gate and vanished, while the same
     *  test on the bound SIM sealed and surfaced on the resume banner. So raise the SAME content-free gate notice the
     *  bound path uses; the in-gate banner (task_eefa24b6) renders it, since Lock Task disables the shade.
     *  Content-free is structural: with no profile owner there is no visibility dial, so the number is NEVER passed.
     *  The NOTICE is decided and stays (product-decisions.md 2026-09-01 (e): it gains a tap route to the owner
     *  verify). SUPERSEDED by Slice D (NWP-20261001-01): the DROP behind it is gone. An unbound SIM is the DEVICE
     *  OWNER's line, and the daemon now SEALS its arrivals to the device-owner inbox (reply OWNER), read behind the
     *  owner passphrase (ChooserActivity.buildOwnerInboxScreen). This same content-free notice is still what the gate
     *  shows; only when no owner key exists yet (reply NONE, a device not verified since the key landed) is the
     *  arrival an accepted loss. */
    static final String UNBOUND_LINE = "an unassigned SIM";

    /** Shuttle one inbound telephony event to SEAL-TEL and, per the reply, raise a content-free gate notice.
     *  Shared by the SMS receiver and the call handlers. Returns a SEAL_* outcome.
     *  NWP-20260930-05: the v2 wire. aid and mono are this arrival's id and stamp (TelArrival), the same on every
     *  attempt, so the daemon answers a retry from its replay table and never seals it twice, and resolves it against
     *  the SIM links in force when it came in; attempts go on until SEAL_DEADLINE_MS after the seal starts (a call's at its end).
     *  gateNotice=false seals SILENTLY: the cross-user reject-and-seal path (NowhereCallControlService, sealed in user 0
     *  by RejectedCallSealReceiver) seals a call rejected while a STRANGER held the phone, so a labelled notice would
     *  show that stranger the owner's line label -- an amnesia leak; the owner still gets the record at next login.
     *  The unassigned-SIM and loss notices carry no label and are always posted in user 0 (settle), so gateNotice does
     *  not govern them. Every caller runs in user 0, the only caller SEAL-TEL answers since NWP-20260930-05. */
    static int sealAndNotify(Context ctx, String kind, int subId, String iccid, String from, long when, String body,
                             int callType, int durSec, boolean gateNotice, String aid, long mono) {
        final String req = TelArrival.telRequest(aid, mono, kind, subId, safe(iccid), from, when, body, callType, durSec);
        final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;
        final TelArrival.Reply r = TelArrival.untilAnswered(req, 5000, deadline, safe(iccid));
        if (r != null) r.deadline = deadline;
        return settle(ctx, r, kind, callType, safe(iccid), from, gateNotice, aid);
    }

    /** What an arrival's final reply means, and the notice it raises (NWP-20260930-05):
     *  - OK: kept for at least one owner, sealed or queued -- an "OK ... 0" used to read as nothing kept, when it also
     *    means queued for the session being brought up. A LIVE uid is kicked to insert it there, with no gate notice.
     *  - OK PARTIAL (Q029, docs/product-decisions.md 2026-10-20): kept for some owners of a co-owned SIM, not every one.
     *    A LIVE uid is still kicked (the owner in session has it); then the gate waits until the arrival's seal deadline
     *    (r.deadline) and posts the loss notice under the same arrival id, unless the line is Private by the rule the
     *    failure case below applies -- never the line's normal notice, and never both, so a partial failure looks like
     *    a total one in text and in timing and shows no one that the line has more than one owner. Like the loss
     *    notice of a failure, it does not depend on gateNotice.
     *  - OWNER (Slice D: the unbound SIM's arrival sealed to the device-owner inbox) or NONE (no owner key yet): the
     *    content-free unassigned-SIM notice, in user 0 -- the gate shows the same either way and never reveals whether
     *    the arrival was kept. A call rejected in a stranger's session is sealed by user 0, where the notice is posted.
     *  - UNRESOLVED (the SIM was not identified, or its link is unknown), FULL (the store is full), ERR, or no answer
     *    by the deadline: the loss notice, unless the line is known to be Private -- docs/product-decisions.md
     *    2026-09-30, answer 2. An ERR or no answer may still have been kept (a request queued at the daemon can land
     *    after the chooser stops waiting), which is why the notice says "may not have been saved".
     *  - REMOVED: its SIM was unassigned since it came in, which deleted its records and notices: nothing.
     *  An unknown reply reads as NONE (TelArrival.parse). */
    static int settle(Context ctx, TelArrival.Reply r, String kind, int callType, String iccid, String from,
                      boolean gateNotice, String aid) {
        if (r == null || "ERR".equals(r.kind) || "UNRESOLVED".equals(r.kind) || "FULL".equals(r.kind)) {
            if (!TelArrival.knownPrivate(iccid) && (r == null || !"private".equals(r.vis))) postLossNotice(ctx, kind, callType, aid);
            return r == null || "ERR".equals(r.kind) ? SEAL_FAILED : SEAL_UNKEPT;
        }
        if ("REMOVED".equals(r.kind)) return SEAL_NONE;
        if (!"OK".equals(r.kind)) { // OWNER (sealed to the device-owner inbox, Slice D) or NONE (no owner key yet):
            // the SAME content-free unassigned-SIM notice in user 0 -- the gate never reveals whether it was kept.
            postMessageNotice(asGate(ctx), UNBOUND_LINE, kind, callType, null); // #196
            return SEAL_NONE; // no bound owner to count, no live session to kick -- the owner reads it in the inbox
        }
        if (r.partial) { // Q029: kept for some owners, not every one -- the loss notice at the deadline, never the line's own
            if (r.liveUid >= 0) kickLiveTelingest(ctx, r.liveUid); // the owner in session has it
            try { Thread.sleep(holdMs(r.deadline, TelArrival.stamp())); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); }
            if (partialLoss(r, TelArrival.knownPrivate(iccid))) postLossNotice(ctx, kind, callType, aid);
            return SEAL_SEALED;
        }
        if (r.liveUid >= 0) { // #149 live delivery: the owner is in session, so the gate shows nothing
            kickLiveTelingest(ctx, r.liveUid);
            return SEAL_SEALED;
        }
        // Private (owner opted out) OR gateNotice=false (stranger foreground, cross-user seal-for-owner): show nothing.
        if (gateNotice && !"private".equals(r.vis)) postMessageNotice(ctx, r.label, kind, callType, "number".equals(r.vis) ? from : null);
        return SEAL_SEALED;
    }

    /** Q029: how long a partial seal's notice waits -- until the deadline its retries ran to; 0 when that is unknown
     *  (deadline 0) or already passed. */
    static long holdMs(long deadline, long now) {
        return deadline <= 0 ? 0 : Math.max(0, deadline - now);
    }

    /** Q029: whether a partial seal leaves the loss notice -- an OK PARTIAL, under the Private rule settle's failure
     *  case applies: not when the line is known to be Private, nor when the reply says it is. */
    static boolean partialLoss(TelArrival.Reply r, boolean knownPrivate) {
        return r != null && "OK".equals(r.kind) && r.partial && !knownPrivate && !"private".equals(r.vis);
    }

    /** NWP-20260930-05: user 0's context, whichever user runs the caller. The unassigned-SIM and loss notices are the
     *  gate's, and one caller runs in a stranger's session: NowhereCallControlService, posting the loss notice when it
     *  cannot hand a rejected call's seal to user 0. A notice posted in that context would land in the stranger's
     *  shade, or not at all. The chooser holds INTERACT_ACROSS_USERS_FULL. Falls back to ctx if the system will not. */
    static Context asGate(Context ctx) {
        try { return ctx.createContextAsUser(android.os.UserHandle.SYSTEM, 0); } catch (Throwable t) { return ctx; }
    }

    /** NWP-20261010-13: Notification.EXTRA_SUBSTITUTE_APP_NAME, a @SystemApi constant, spelled out so this file also
     *  compiles against the public SDK. The framework drops the extra from any notice whose package does not hold
     *  SUBSTITUTE_NOTIFICATION_APP_NAME (signature|privileged; the platform-signed chooser holds it, AndroidManifest.xml). */
    static final String EXTRA_SUBST_APP_NAME = "android.substName";

    /** The app name a telephony notice of this kind shows in place of the chooser's own label, "Profile". Never null,
     *  so the != null guards at its callers always hold. NWP-20261010-13 (Chester, 2026-10-10: message notices are
     *  named "Messages"): a text, an MMS or any other kind that is not a call is "Messages". NWP-20261123-24 (Chester,
     *  2026-10-29, asked that call notices not read "Profile"): a call is "Phone". "Phone" is an INFERENCE: it is the
     *  dialer's own name on both editions; he did not name the label. Its users: the gate's two notices
     *  (postMessageNotice, postLossNotice) and TelIngest's session notices (postRoamedMessageNotice, the delivered-SMS
     *  notice, postMissedCallNotice). */
    static String substituteAppName(String kind) {
        return "call".equals(kind) ? "Phone" : "Messages";
    }

    static final String TEL_LOSS_TAG = "nowhere_telephony_loss"; // own tag; id per arrival, so a repeat replaces its own
    private static final java.util.Set<String> LOSS_ANNOUNCED = java.util.concurrent.ConcurrentHashMap.newKeySet(); // chime once

    /** The loss notice (docs/product-decisions.md 2026-09-30, answer 2): content-free and unlabelled, in user 0 only,
     *  for an arrival the phone could not keep or never heard back about -- "may not have been saved", because one
     *  whose seal went unanswered may still have been kept. Its nowhere_class extra keeps it out of the label-based
     *  clears (ChooserActivity.cancelTelNotices): it is the arrival's only trace. INFERENCE, mine: a call gets the
     *  call form of it, Incoming or Missed as the gate's own notice; the option as put named only the message form. */
    static void postLossNotice(Context ctx, String kind, int callType, String aid) {
        try {
            final Context gate = asGate(ctx);
            android.app.NotificationManager nm = gate.getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            ensureTelChannel(nm);
            final boolean isCall = "call".equals(kind); if (LOSS_ANNOUNCED.size() >= 4096) LOSS_ANNOUNCED.clear(); // bounded
            android.os.Bundle nx = new android.os.Bundle();
            nx.putString("nowhere_kind", isCall ? "call" : "message");
            nx.putString("nowhere_class", "unsaved");
            if (substituteAppName(kind) != null) nx.putString(EXTRA_SUBST_APP_NAME, substituteAppName(kind)); // NWP-20261010-13
            nm.notify(TEL_LOSS_TAG, java.util.Objects.hashCode(aid), new android.app.Notification.Builder(gate, TEL_CHANNEL)
                    .setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message).setAutoCancel(true).addExtras(nx)
                    .setContentTitle((isCall ? (callType == 1 ? "Incoming call" : "Missed call") : "New message") + " — may not have been saved").build());
            try { gate.sendBroadcast(new Intent(ACTION_TEL_NOTICE).setPackage(gate.getPackageName())); } catch (Throwable ignore) {}
            if (LOSS_ANNOUNCED.add(String.valueOf(aid)) && !isCall) alertGateArrival(gate); // a call already rang through telecom
        } catch (Throwable ignore) {}
    }

    /** A gate MMS whose download failed, timed out or whose kick failed (docs/product-decisions.md 2026-11-05, #14): the
     *  loss notice, under the Private rule settle's failure case applies. A later successful re-push also posts the
     *  line's ordinary notice, as decided. The log line carries no number and no id. */
    static void postDownloadLoss(Context ctx, int subId, String aid) {
        android.util.Log.w("NowhereChooser", "#150 gate MMS download failed: loss notice unless the line is known Private");
        if (!TelArrival.knownPrivate(safe(iccidForSub(ctx, subId)))) postLossNotice(ctx, "mms", 0, aid);
    }

    /** #150 P2: one downloaded MMS part (content-type + name + raw bytes) for the SEAL-MMS wire. */
    static final class MmsPart {
        final String contentType, name;
        final byte[] data;
        MmsPart(String ct, String nm, byte[] d) {
            contentType = ct == null ? "" : ct;
            name = nm == null ? "" : nm;
            data = d == null ? new byte[0] : d;
        }
    }

    /** #150 P2: seal a downloaded MMS to the SIM's bound owner(s) via the daemon's SEAL-MMS verb, then raise the
     *  notice its reply calls for (settle) -- the MMS analogue of sealAndNotify (subject + multipart body instead of
     *  one text). The seal buffers ciphertext for next-login delivery; nothing readable lands on user 0. Computes the
     *  SIM's iccid itself (like the SMS caller does). NWP-20260930-05: the v2 wire, with aid and mono taken at the
     *  push; the deadline runs from here, the download callback, since the download may already have used up to 90 s
     *  of the arrival's time. Over the size cap the daemon keeps it without its media (STRIPPED): the owner still
     *  gets a "New message" at login, just without the attachment, and the gate has nothing extra to do. */
    static int sealMmsAndNotify(Context ctx, int subId, String from, long when, String subject,
                                java.util.List<MmsPart> parts, String aid, long mono) {
        final String iccid = safe(iccidForSub(ctx, subId));
        final String req = TelArrival.mmsRequest(aid, mono, subId, iccid, from, when, subject, parts);
        final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;
        final TelArrival.Reply r = TelArrival.untilAnswered(req, 10_000, deadline, iccid);
        if (r != null) r.deadline = deadline;
        final int st = settle(ctx, r, "mms", 0, iccid, from, true, aid);
        // #150 (i): fallback live delivery. The daemon's LIVE path is unreliable for a large MMS (appendTelIngest
        // can fail -> the MMS falls to the tmpfs inbox with NO LIVE token, so it only surfaced at the owner's next
        // login or when an unrelated SMS's ingest happened to drain the inbox -- the "send an SMS to receive the
        // MMS" wart the user hit). If a roamed session is signed in RIGHT NOW, kick its TelIngest: GET-TELINGEST
        // drains this just-sealed MMS from the inbox immediately (the exact mechanism the SMS nudge relied on). A
        // no-op if the signed-in user isn't a bound owner (empty mailbox); idempotent with the LIVE path above
        // (GET-TELINGEST claims the mailbox, so a double-kick's second run finds it empty).
        if (st == SEAL_SEALED && r.liveUid < 0) { int curUser = currentForegroundUser(); if (curUser > 0) kickLiveTelingest(ctx, curUser); }
        return st;
    }

    /** base64(s) for a SEAL-MMS wire token, or "-" for empty -- the Java mirror of the Go b64tok encoder. */
    static String b64tok(String s) {
        if (s == null || s.isEmpty()) return "-";
        return Base64.encodeToString(s.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    /** #149: kick the roamed user's own CredentialService to pull + insert its just-staged live telephony row
     *  (immediate mode -- no roam-in settle). Cross-user startServiceAsUser needs INTERACT_ACROSS_USERS_FULL,
     *  which the chooser holds. The roamed chooser is NOT the SMS-role holder there (the profile's SMS app holds it,
     *  SmsRoleRoam, and NWP-20261010-13 disables the chooser's SMS components in that user); its insert is authorized
     *  by its own OP_WRITE_SMS app-op (TelIngest.ensureSmsWrite). */
    static void kickLiveTelingest(Context ctx, int uid) { // package-visible: NWP-20261005-15 kicks it after a lift
        try {
            ctx.startServiceAsUser(new Intent(ctx, CredentialService.class)
                            .putExtra("telingest", true).putExtra("live", true),
                    android.os.UserHandle.of(uid));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "live telingest kick", t);
        }
    }

    /** #150 (i): the current foreground user id via ActivityManager.getCurrentUser() (hidden API; the chooser
     *  holds INTERACT_ACROSS_USERS_FULL). >0 = a roamed session is signed in (kick its live MMS ingest); 0 = the
     *  gate; -1 on failure. */
    private static int currentForegroundUser() {
        try {
            return (Integer) android.app.ActivityManager.class.getMethod("getCurrentUser").invoke(null);
        } catch (Throwable t) {
            return -1;
        }
    }

    // task_eefa24b6: package-visible so ChooserActivity can render the gate's own active notices as an
    // in-gate BANNER (the locked kiosk disables the shade, so this channel's notifications are otherwise
    // invisible -- see lockGate's LOCK_TASK_FEATURE set) and cancel them on login.
    // v2 id: a channel's importance/sound/vibration are LOCKED at first creation, so bumping the id is how we
    // apply the HIGH + explicit-sound + vibrate settings (ensureTelChannel) even on the PERSISTENT user-0 gate
    // channel (a roamed user is ephemeral so it always gets fresh settings; user 0 persists). A new message /
    // missed call must CHIME -- the old IMPORTANCE_DEFAULT channel with no explicit sound could come out silent.
    static final String TEL_CHANNEL = "nowhere_telephony2";

    /** Create the "Messages & calls" channel with an EXPLICIT notification sound + vibration at HIGH importance so
     *  a message / missed call reliably alerts (and heads-up in a roamed session). All three notice posters route
     *  through this so the channel is identical wherever it's first created. */
    static void ensureTelChannel(android.app.NotificationManager nm) {
        // Remove the orphaned v1 channel so Settings doesn't show two identical "Messages & calls" rows (the v2
        // id bump left the old IMPORTANCE_DEFAULT channel behind). Idempotent no-op once it's gone.
        try { nm.deleteNotificationChannel("nowhere_telephony"); } catch (Throwable ignore) {}
        android.app.NotificationChannel ch = new android.app.NotificationChannel(
                TEL_CHANNEL, "Messages & calls", android.app.NotificationManager.IMPORTANCE_HIGH);
        ch.enableVibration(true);
        ch.setSound(android.provider.Settings.System.DEFAULT_NOTIFICATION_URI,
                new android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build());
        nm.createNotificationChannel(ch);
    }
    // Broadcast raised after a gate notice is (un)posted so a live gate refreshes its banner immediately,
    // rather than only on the next onResume. Explicitly package-targeted (setPackage) -- internal only.
    static final String ACTION_TEL_NOTICE = "com.nowhere.chooser.TEL_NOTICE_CHANGED";

    /** An arrival notice on the (pre-login) gate. CONTENT-FREE by default -- the owner-set line label only,
     *  never the text. The caller/sender `number` is shown ONLY when the daemon returned visibility "number"
     *  (the owner opted in via Settings -> Messages & calls, #146); otherwise it is null and withheld, so a
     *  stranger holding the locked phone can't see who called. Distinct id per (label, KIND) so neither two
     *  lines NOR a call+message on one line collapse. On TEL_CHANNEL, which is IMPORTANCE_HIGH (ensureTelChannel);
     *  the locked gate mutes it all the same, which is why alertGateArrival exists. */
    private static void postMessageNotice(Context ctx, String label, String kind, int callType, String number) {
        try {
            android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            ensureTelChannel(nm); // HIGH + explicit sound + vibrate -> alerts in a roamed session (real shade)
            String line = label == null || label.isEmpty() ? "" : label;
            // callType (CallLog.Calls.TYPE): INCOMING=1 (answered at the gate), MISSED=3. B4.b can now answer,
            // so an answered gate call is "Incoming call", not "Missed call".
            boolean isCall = "call".equals(kind);
            String title = isCall ? (callType == 1 ? "Incoming call" : "Missed call") : "New message";
            // Distinct id per (line, KIND): a call and a message on the SAME line must NOT replace each other
            // (keying on the line alone collapsed them to whichever arrived last -- the "only the latest" bug).
            // NWP-20261128-18: an answered call ("ci") and a missed call ("c") are apart too: on one id the last call
            // re-titled the whole running count, so an answered call then a missed one read "2 missed calls". A missed
            // call keeps "c", so a missed-call notice posted before this build is still found and counted.
            final int nid = Math.abs(("t" + line + "|" + (isCall ? (callType == 1 ? "ci" : "c") : "m")).hashCode());
            // NWP-20261013-41: a second arrival replaces the first in place, so the running count rides on the notice
            // (nowhere_count) -- 1 for a notice posted before this build, 0 when there is none -- and the title says so.
            int count = 1;
            try {
                for (android.service.notification.StatusBarNotification old : nm.getActiveNotifications()) {
                    if (old == null || old.getId() != nid || !TEL_CHANNEL.equals(old.getTag())) continue;
                    android.os.Bundle ox = old.getNotification() == null ? null : old.getNotification().extras;
                    count = ox == null ? 1 : Math.max(1, ox.getInt("nowhere_count", 1)) + 1;
                    break;
                }
            } catch (Throwable ignore) {}
            if (count > 1) title = count + (isCall ? (callType == 1 ? " incoming calls" : " missed calls") : " new messages");
            android.app.Notification.Builder b = new android.app.Notification.Builder(ctx, TEL_CHANNEL)
                    .setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message) // NWP-20261010-13: a white envelope, not the legacy glyph; NWP-20261123-24: a handset for a call
                    .setContentTitle(line.isEmpty() ? title : title + "  -  " + line)
                    .setAutoCancel(true);
            // Mark the event kind so the gate banner (telNoticeSummary) can classify each active notice and show
            // BOTH a missed call AND a new message on one line ("Missed call · New message"), not just the latest.
            android.os.Bundle nx = new android.os.Bundle();
            nx.putString("nowhere_kind", isCall ? "call" : "message");
            if (isCall) nx.putString("nowhere_call", callType == 1 ? "incoming" : "missed"); // NWP-20261128-18: which call, for the banner (TelNoticeClear.kindOf)
            nx.putInt("nowhere_count", count);
            // NWP-20261006-04: mark the unassigned line's notice, so the gate banner knows a tap may lead to the owner inbox.
            if (UNBOUND_LINE.equals(line)) nx.putString("nowhere_line", "unbound");
            // NWP-20261010-13: a message notice is named "Messages", not the chooser's label (substituteAppName).
            if (substituteAppName(kind) != null) nx.putString(EXTRA_SUBST_APP_NAME, substituteAppName(kind));
            b.addExtras(nx);
            // #146: opted-in only -- append the caller/sender number as the second line.
            if (number != null && !number.trim().isEmpty()) b.setContentText("From " + number.trim());
            nm.notify(TEL_CHANNEL, nid, b.build());
            // task_eefa24b6: nudge a live gate to re-render its banner now (the shade is disabled at the locked
            // gate, so the notification above is only the STORE -- the banner is the visible surface).
            try {
                ctx.sendBroadcast(new Intent(ACTION_TEL_NOTICE).setPackage(ctx.getPackageName()));
            } catch (Throwable ignore) {}
            // The locked kiosk mutes NOTIFICATION effects (DISABLE_NOTIFICATION_ALERTS), so the HIGH channel above
            // is SILENT at the gate no matter its importance -- alert the user ourselves for a message/MMS. A call
            // already rang via telecom's own over-keyguard Ringtone path (not a notification), so skip it there.
            if (!isCall) alertGateArrival(ctx);
        } catch (Throwable ignore) {}
    }

    // Hold the last gate chime so it isn't GC'd mid-playback (Ringtone plays async in the media server; a Java
    // object going out of scope can cut it short).
    private static android.media.Ringtone sGateChime;

    /** Play the arrival alert (short chime + a two-pulse buzz) OURSELVES at the locked gate. The kiosk's LockTask
     *  status-bar mask includes DISABLE_NOTIFICATION_ALERTS -- the gate omits LOCK_TASK_FEATURE_NOTIFICATIONS so
     *  the shade stays an unusable escape surface, and that same mask globally mutes NOTIFICATION sound+vibration.
     *  So the HIGH channel can't chime here regardless of importance (verified via the notification service's
     *  disable_effects=booleanState log). This is the message analogue of telecom ringing an incoming call over
     *  the keyguard: telecom's ring isn't a notification, which is exactly why calls alert but our message notice
     *  didn't. Respects the ringer: SILENT -> nothing; VIBRATE -> buzz only; NORMAL -> chime + buzz. Runs on the
     *  SMS receiver's worker thread; postMessageNotice is only reached in the gate path (a live in-session owner
     *  takes sealAndNotify's LIVE branch instead), so this never double-alerts an in-session channel chime. */
    private static void alertGateArrival(Context ctx) {
        try {
            // NWP-20261007-03: only when the GATE is in front. This alert is the vibrator and a ringtone, both
            // device-wide, and an arrival on a line that is not the session's -- the unassigned SIM, or a SIM bound
            // to another profile -- reaches here while a stranger's session is in front: it buzzed in their hands
            // for the owner's line (Chester, lynx 2026100606). The state matrix (docs/telephony-owner-mode.md)
            // says that session is not interrupted. The notice itself is the gate's and alerts only there; a
            // check that cannot answer says nothing rather than buzz the wrong person.
            if (!gateInFront()) return;
            android.media.AudioManager am = ctx.getSystemService(android.media.AudioManager.class);
            int ringer = am == null ? android.media.AudioManager.RINGER_MODE_NORMAL : am.getRingerMode();
            if (ringer == android.media.AudioManager.RINGER_MODE_SILENT) return; // honor Do-not-disturb/silent
            android.media.AudioAttributes aa = new android.media.AudioAttributes.Builder()
                    .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build();
            // Buzz. Requires the nowhere_chooser sepolicy grant `find` on vibrator_manager_service (nowhere.te):
            // without it ServiceManager can't locate VibratorManager (which lives in system_server) -> the vibrator
            // list is empty -> hasVibrator()=false -> vibrate() SILENTLY no-ops. With the grant this fires normally
            // (that grant is why telecom's ring + the keyboard's haptics buzz but our app domain previously couldn't).
            // Usage=ALARM: the class proven to fire at the LOCKED gate (the gate alarm uses it); NOTIFICATION-class
            // haptics get policy-suppressed by the kiosk. Ringer gating (SILENT -> nothing) is handled above.
            android.os.Vibrator vib = ctx.getSystemService(android.os.Vibrator.class);
            if (vib != null) {
                try {
                    android.os.VibrationAttributes va = new android.os.VibrationAttributes.Builder()
                            .setUsage(android.os.VibrationAttributes.USAGE_ALARM).build();
                    vib.vibrate(android.os.VibrationEffect.createWaveform(new long[]{0, 220, 120, 220}, -1), va);
                } catch (Throwable ignore) {}
            }
            if (ringer == android.media.AudioManager.RINGER_MODE_NORMAL) {
                android.media.Ringtone rt = android.media.RingtoneManager.getRingtone(
                        ctx, android.provider.Settings.System.DEFAULT_NOTIFICATION_URI);
                if (rt != null) {
                    rt.setAudioAttributes(aa);
                    sGateChime = rt; // pin against GC while it plays
                    rt.play();
                }
            }
        } catch (Throwable ignore) {}
    }

    /** NWP-20261007-03: the gate (user 0) is the foreground user. False when it cannot tell. */
    static boolean gateInFront() {
        try {
            return android.app.ActivityManager.getCurrentUser() == 0;
        } catch (Throwable t) {
            return false;
        }
    }

    /** Best-effort ICCID for a subscription (the stable binding key). Needs READ_PRIVILEGED_PHONE_STATE
     *  (privapp-granted). Returns "" if unavailable -- SEAL-TEL falls back to the sub_id match. */
    private static String iccidForSub(Context ctx, int subId) {
        try {
            SubscriptionManager sm = ctx.getSystemService(SubscriptionManager.class);
            if (sm == null) return "";
            SubscriptionInfo si = sm.getActiveSubscriptionInfo(subId);
            return si == null ? "" : safe(si.getIccId());
        } catch (Throwable t) {
            return "";
        }
    }

    private static String safe(String s) { return s == null ? "" : s; }
}
