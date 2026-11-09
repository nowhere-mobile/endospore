#!/usr/bin/env bash
# test-tel-seal.sh [<chooser src dir> [<AndroidManifest.xml>]] [--mutate] -- the chooser half of the arrival path
# (NWP-20260930-05).
#
# WHY THIS IS COMMITTED. An arrival -- a text, a call, an MMS -- reaches the gate once. The chooser used to seal it with
# one attempt (a text) or three in three seconds (a call), each a new request the daemon could not tell from a new
# arrival, so a timed-out attempt that still landed was sealed twice, and a text whose one attempt failed was lost.
# It guessed a SIM it could not identify, read "OK ... 0" as nothing kept, posted no trace for an arrival it could not
# keep, and sealed a call rejected in a stranger's session from that stranger's own process. Now every attempt at one
# arrival carries the same arrival id and stamp (TelArrival), retries run to a deadline, each reply has its meaning
# (SmsDeliverReceiver.settle), the unassigned-SIM and loss notices go to user 0, and every seal runs in user 0
# (RejectedCallSealReceiver). The chooser has no unit-test harness, so these are source-level checks; CI executes this
# suite and its --mutate run.
#
# HOW IT CHECKS. The methods that decide these properties are PINNED BYTE FOR BYTE, comments included -- a line check
# on a spelling passes a commented-out step or a swallowed failure (test-owner-conf.sh says why) -- so any edit to one
# fails here and the pin is updated with it, on purpose. A pinned method must occur exactly once, so a dead copy left
# in a comment cannot stand in for a changed one. The line checks below the pins say WHY each property matters; they
# read the code with its comments removed (code(), which follows /* */ across lines and strings across // and /*), so
# a statement that survives only in a comment reads as absent. Every mutation must convict the suite twice: with the
# pins, and with TEL_SEAL_NOPIN=1, which skips them -- so each property is held by a line check, not only by a pin.
#
#   bash test-tel-seal.sh            # the invariants
#   bash test-tel-seal.sh --mutate   # ... plus mutations that must each CONVICT the suite, with and without the pins
set -uo pipefail

MUTATE=no; SRC=""; AM=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) if [ -z "$SRC" ]; then SRC="$a"; else AM="$a"; fi ;; esac; done
SRC="${SRC:-$(dirname "$0")/src/com/nowhere/chooser}"; AM="${AM:-$(dirname "$0")/AndroidManifest.xml}"
TA="$SRC/TelArrival.java"; SD="$SRC/SmsDeliverReceiver.java"; IC="$SRC/NowhereInCallService.java"
CC="$SRC/NowhereCallControlService.java"; WP="$SRC/WapPushDeliverReceiver.java"; MD="$SRC/MmsDownloadedReceiver.java"
CA="$SRC/ChooserActivity.java"; RC="$SRC/RejectedCallSealReceiver.java"
for f in "$TA" "$SD" "$IC" "$CC" "$WP" "$MD" "$CA" "$RC" "$AM"; do [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }; done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q` (see test-owner-key.sh).

# body <file> <signature fragment> <indent>: from the signature to the first line that is exactly <indent>} -- or a
# marker that fails every pin and check when the signature does not occur exactly once.
body(){ [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "<signature not exactly once: $2>"; return; }; awk -v sig="$2" -v end="$3}" 'index($0, sig) { on = 1 } on { print } on && $0 == end { exit }' "$1"; }
# code <text>: the text without its comments -- // to the end of a line and /* */ across lines, but not inside a
# string or char literal -- and without the lines that leave blank.
code(){ printf '%s\n' "$1" | awk '
{ out = ""; n = length($0); i = 1; str = 0; chr = 0
  while (i <= n) {
    c = substr($0, i, 1); d = substr($0, i, 2)
    if (blk) { if (d == "*/") { blk = 0; i += 2 } else i++; continue }
    if (str || chr) {
      out = out c
      if (c == "\\") { out = out substr($0, i + 1, 1); i += 2; continue }
      if ((str && c == "\"") || (chr && c == "\047")) { str = 0; chr = 0 }
      i++; continue
    }
    if (d == "/*") { blk = 1; i += 2; continue }
    if (d == "//") break
    if (c == "\"") str = 1; else if (c == "\047") chr = 1
    out = out c; i++
  }
  if (out ~ /[^[:space:]]/) print out
}'; }
# has <text> <fixed string> / count <text> <fixed string>, on the code only.
has(){ code "$1" | grep -cF -- "$2" >/dev/null; }
count(){ code "$1" | grep -cF -- "$2"; }
# line <text> <fixed string>: the 1-based line of its first match in the code, or 0.
line(){ code "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1 | grep . || echo 0; }
# pin <name> <actual> <expected> / lpin <name> <file> <the whole line>: skipped under TEL_SEAL_NOPIN=1.
pin(){ [ "${TEL_SEAL_NOPIN:-}" = 1 ] && return 0; if [ "$2" = "$3" ]; then ok "$1 is the pinned block"; else no "$1 differs from the pinned block"; fi; }
lpin(){ [ "${TEL_SEAL_NOPIN:-}" = 1 ] && return 0; if [ "$(grep -cxF -- "$3" "$2")" = 1 ]; then ok "$1 is the pinned line"; else no "$1 differs from the pinned line"; fi; }

echo "== the pinned blocks and lines (byte for byte, comments included) =="
pin "TelArrival.untilAnswered" "$(body "$TA" 'static Reply untilAnswered(String req, int timeoutMs, long deadline, String iccid)' '    ')" "$(cat <<'PIN'
    static Reply untilAnswered(String req, int timeoutMs, long deadline, String iccid) {
        Reply last = null;
        for (int attempt = 0; ; attempt++) {
            String line = DaemonSocket.roundTrip(req, timeoutMs);
            if (line != null && !line.isEmpty()) {
                last = parse(line);
                rememberDial(iccid, last.vis);
                if (!"ERR".equals(last.kind)) return last;
            }
            long wait = backoffMs(attempt);
            if (stamp() + wait > deadline) return last;
            try { Thread.sleep(wait); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); return last; }
        }
    }
PIN
)"
pin "TelArrival.parse" "$(body "$TA" 'static Reply parse(String line)' '    ')" "$(cat <<'PIN'
    static Reply parse(String line) {
        Reply r = new Reply();
        String[] f = line.trim().split(" ");
        switch (f[0]) {
            case "OK":
                r.kind = "OK";
                r.vis = f.length > 1 ? f[1] : "open";
                if (f.length > 2 && !f[2].isEmpty()) {
                    try { r.label = new String(Base64.decode(f[2], Base64.NO_WRAP), StandardCharsets.UTF_8); } catch (Throwable ignore) {}
                }
                for (int i = 4; i < f.length; i++) {
                    if ("STRIPPED".equals(f[i])) r.stripped = true;
                    if ("PARTIAL".equals(f[i])) r.partial = true;
                    if ("LIVE".equals(f[i]) && i + 1 < f.length) {
                        try { r.liveUid = Integer.parseInt(f[i + 1].trim()); } catch (Throwable ignore) {}
                    }
                }
                break;
            case "ERR":
                r.kind = "ERR";
                if (f.length > 2 && "nobody".equals(f[1])) r.vis = f[2];
                break;
            case "UNRESOLVED": case "REMOVED": case "FULL": case "OWNER":
                r.kind = f[0];
                if ("FULL".equals(f[0]) && f.length > 1) r.vis = f[1];
                break;
            default:
                r.kind = "NONE";
        }
        return r;
    }
PIN
)"
pin "TelArrival.telRequest" "$(body "$TA" 'static String telRequest(String aid, long mono, String kind, int subId, String iccid, String from, long when,' '    ')" "$(cat <<'PIN'
    static String telRequest(String aid, long mono, String kind, int subId, String iccid, String from, long when,
                             String body, int callType, int durSec) {
        return "SEAL-TEL\nv2\n" + aid + "\n" + kind + "\n" + subId + "\n" + iccid + "\n" + b64(from) + "\n" + when + "\n"
                + mono + "\n" + b64(body) + "\n" + callType + "\n" + durSec + "\n";
    }
PIN
)"
pin "TelArrival.mmsRequest" "$(body "$TA" 'static String mmsRequest(String aid, long mono, int subId, String iccid, String from, long when, String subject,' '    ')" "$(cat <<'PIN'
    static String mmsRequest(String aid, long mono, int subId, String iccid, String from, long when, String subject,
                             List<SmsDeliverReceiver.MmsPart> parts) {
        StringBuilder req = new StringBuilder(128 + parts.size() * 64);
        req.append("SEAL-MMS\nv2\n").append(aid).append('\n').append(subId).append('\n').append(iccid).append('\n')
                .append(SmsDeliverReceiver.b64tok(from)).append('\n').append(when).append('\n').append(mono).append('\n')
                .append(SmsDeliverReceiver.b64tok(subject)).append('\n').append(parts.size()).append('\n');
        for (SmsDeliverReceiver.MmsPart p : parts) {
            req.append(SmsDeliverReceiver.b64tok(p.contentType)).append('\n')
                    .append(SmsDeliverReceiver.b64tok(p.name)).append('\n')
                    .append(Base64.encodeToString(p.data, Base64.NO_WRAP)).append('\n');
        }
        return req.toString();
    }
PIN
)"
pin "TelArrival.subIdOr" "$(body "$TA" 'static int subIdOr(Context ctx, Intent intent, int named)' '    ')" "$(cat <<'PIN'
    static int subIdOr(Context ctx, Intent intent, int named) {
        if (named != SubscriptionManager.INVALID_SUBSCRIPTION_ID) return named;
        int slot = intent.getIntExtra(SubscriptionManager.EXTRA_SLOT_INDEX, -1);
        if (slot < 0) return SubscriptionManager.INVALID_SUBSCRIPTION_ID;
        try {
            SubscriptionManager sm = ctx.getSystemService(SubscriptionManager.class);
            SubscriptionInfo si = sm == null ? null : sm.getActiveSubscriptionInfoForSimSlotIndex(slot);
            if (si != null) return si.getSubscriptionId();
        } catch (Throwable ignore) {}
        return SubscriptionManager.INVALID_SUBSCRIPTION_ID;
    }
PIN
)"
pin "TelArrival.smsId" "$(body "$TA" 'static String smsId(int subId, long when, String from, String body)' '    ')" "$(cat <<'PIN'
    static String smsId(int subId, long when, String from, String body) {
        return sha256Hex("sms\0" + subId + "\0" + when + "\0" + from + "\0" + body);
    }
PIN
)"
pin "TelArrival.callId" "$(body "$TA" 'static String callId(int subId, long createdMs)' '    ')" "$(cat <<'PIN'
    static String callId(int subId, long createdMs) {
        return sha256Hex("call\0" + subId + "\0" + createdMs);
    }
PIN
)"
pin "TelArrival.mmsId" "$(body "$TA" 'static String mmsId(int subId, String txn, String loc, long when)' '    ')" "$(cat <<'PIN'
    static String mmsId(int subId, String txn, String loc, long when) {
        String key = txn != null && !txn.isEmpty() ? "t" + txn : loc != null && !loc.isEmpty() ? "l" + loc : "w" + when;
        return sha256Hex("mms\0" + subId + "\0" + key);
    }
PIN
)"
pin "TelArrival.sha256Hex" "$(body "$TA" 'private static String sha256Hex(String s)' '    ')" "$(cat <<'PIN'
    private static String sha256Hex(String s) {
        try {
            byte[] h = MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(64);
            for (byte b : h) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new IllegalStateException(e); // SHA-256 is always present
        }
    }
PIN
)"
pin "TelArrival.b64" "$(body "$TA" 'private static String b64(String s)' '    ')" "$(cat <<'PIN'
    private static String b64(String s) {
        return Base64.encodeToString((s == null ? "" : s).getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }
PIN
)"
pin "TelArrival.stampCall" "$(body "$TA" 'static void stampCall(Call call)' '    ')" "$(cat <<'PIN'
    static void stampCall(Call call) {
        synchronized (CALL_STAMPS) { if (!CALL_STAMPS.containsKey(call)) CALL_STAMPS.put(call, stamp()); }
    }
PIN
)"
pin "TelArrival.callStamp" "$(body "$TA" 'static long callStamp(Call call)' '    ')" "$(cat <<'PIN'
    static long callStamp(Call call) {
        synchronized (CALL_STAMPS) { Long s = CALL_STAMPS.get(call); return s == null ? stamp() : s; }
    }
PIN
)"
pin "TelArrival.rememberDial" "$(body "$TA" 'static void rememberDial(String iccid, String vis)' '    ')" "$(cat <<'PIN'
    static void rememberDial(String iccid, String vis) {
        if (iccid != null && !iccid.isEmpty() && vis != null && !vis.isEmpty()) DIALS.put(iccid, vis);
    }
PIN
)"
pin "TelArrival.knownPrivate" "$(body "$TA" 'static boolean knownPrivate(String iccid)' '    ')" "$(cat <<'PIN'
    static boolean knownPrivate(String iccid) {
        return iccid != null && "private".equals(DIALS.get(iccid));
    }
PIN
)"
pin "SmsDeliverReceiver.onReceive" "$(body "$SD" '@Override public void onReceive(Context ctx, Intent intent)' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "SmsDeliverReceiver.sealAndNotify" "$(body "$SD" 'static int sealAndNotify(Context ctx, String kind, int subId, String iccid, String from, long when, String body,' '    ')" "$(cat <<'PIN'
    static int sealAndNotify(Context ctx, String kind, int subId, String iccid, String from, long when, String body,
                             int callType, int durSec, boolean gateNotice, String aid, long mono) {
        final String req = TelArrival.telRequest(aid, mono, kind, subId, safe(iccid), from, when, body, callType, durSec);
        final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;
        final TelArrival.Reply r = TelArrival.untilAnswered(req, 5000, deadline, safe(iccid));
        if (r != null) r.deadline = deadline;
        return settle(ctx, r, kind, callType, safe(iccid), from, gateNotice, aid);
    }
PIN
)"
pin "SmsDeliverReceiver.settle" "$(body "$SD" 'static int settle(Context ctx, TelArrival.Reply r, String kind, int callType, String iccid, String from,' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "SmsDeliverReceiver.asGate" "$(body "$SD" 'static Context asGate(Context ctx)' '    ')" "$(cat <<'PIN'
    static Context asGate(Context ctx) {
        try { return ctx.createContextAsUser(android.os.UserHandle.SYSTEM, 0); } catch (Throwable t) { return ctx; }
    }
PIN
)"
pin "SmsDeliverReceiver.postLossNotice" "$(body "$SD" 'static void postLossNotice(Context ctx, String kind, int callType, String aid)' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "SmsDeliverReceiver.postDownloadLoss" "$(body "$SD" 'static void postDownloadLoss(Context ctx, int subId, String aid)' '    ')" "$(cat <<'PIN'
    static void postDownloadLoss(Context ctx, int subId, String aid) {
        android.util.Log.w("NowhereChooser", "#150 gate MMS download failed: loss notice unless the line is known Private");
        if (!TelArrival.knownPrivate(safe(iccidForSub(ctx, subId)))) postLossNotice(ctx, "mms", 0, aid);
    }
PIN
)"
pin "SmsDeliverReceiver.postMessageNotice" "$(body "$SD" 'private static void postMessageNotice(Context ctx, String label, String kind, int callType, String number)' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "SmsDeliverReceiver.sealMmsAndNotify" "$(body "$SD" 'static int sealMmsAndNotify(Context ctx, int subId, String from, long when, String subject,' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "NowhereInCallService.onCallAdded" "$(body "$IC" '@Override public void onCallAdded(Call call)' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "NowhereInCallService.Recorder.finish" "$(body "$IC" 'void finish(Call call)' '        ')" "$(cat <<'PIN'
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
PIN
)"
pin "NowhereInCallService.resolveSubIccid" "$(body "$IC" 'static String resolveSubIccid(Context app, Call.Details d, int[] subOut)' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "NowhereCallControlService.onCallAdded" "$(body "$CC" 'public void onCallAdded(Call call)' '    ')" "$(cat <<'PIN'
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
PIN
)"
pin "RejectedCallSealReceiver.onReceive" "$(body "$RC" '@Override public void onReceive(Context ctx, Intent intent)' '    ')" "$(cat <<'PIN'
    @Override public void onReceive(Context ctx, Intent intent) {
        final Context app = ctx.getApplicationContext();
        final int subId = intent.getIntExtra(EXTRA_SUB, SubscriptionManager.INVALID_SUBSCRIPTION_ID);
        final String iccid = intent.getStringExtra(EXTRA_ICCID), from = intent.getStringExtra(EXTRA_FROM);
        final long when = intent.getLongExtra(EXTRA_WHEN, 0L), mono = intent.getLongExtra(EXTRA_MONO, TelArrival.stamp());
        new Thread(() -> seal(app, subId, iccid, from, when, mono), "nowhere-seal-rejected-call").start();
    }
PIN
)"
pin "RejectedCallSealReceiver.seal" "$(body "$RC" 'static void seal(Context app, int subId, String iccid, String from, long when, long mono)' '    ')" "$(cat <<'PIN'
    static void seal(Context app, int subId, String iccid, String from, long when, long mono) {
        SmsDeliverReceiver.sealAndNotify(app, "call", subId, iccid, from, when, "", 3 /*MISSED*/, 0 /*durSec*/,
                false /*gateNotice*/, TelArrival.callId(subId, when), mono);
    }
PIN
)"
pin "WapPushDeliverReceiver.onReceive" "$(body "$WP" '@Override public void onReceive(Context ctx, Intent intent)' '    ')" "$(cat <<'PIN'
    @Override public void onReceive(Context ctx, Intent intent) {
        final byte[] data = intent.getByteArrayExtra("data");
        final int subId = TelArrival.subIdOr(ctx, intent, intent.getIntExtra("subscription",
                intent.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX",
                        SubscriptionManager.INVALID_SUBSCRIPTION_ID))); // NWP-20260930-05: never the default SIM
        if (data == null || data.length == 0) {
            android.util.Log.w("NowhereChooser", "#150 WAP_PUSH_DELIVER with no PDU data");
            return;
        }
        // Notification arrival = the MMS "received" time the owner's Messages should show (the download
        // completes seconds later; the notification is the true receipt).
        final long when = System.currentTimeMillis(), mono = TelArrival.stamp(); // NWP-20260930-05: the arrival's stamp
        final Context app = ctx.getApplicationContext();
        new Thread(() -> handleNotification(app, data, subId, when, mono)).start();
    }
PIN
)"
pin "WapPushDeliverReceiver.handleNotification" "$(body "$WP" 'private static void handleNotification(Context app, byte[] data, int subId, long when, long mono)' '    ')" "$(cat <<'PIN'
    private static void handleNotification(Context app, byte[] data, int subId, long when, long mono) {
        try {
            GenericPdu pdu = new PduParser(data, true).parse();
            if (!(pdu instanceof NotificationInd)) {
                android.util.Log.w("NowhereChooser", "#150 WAP-push is not an M-Notification.ind (type="
                        + (pdu == null ? "null" : pdu.getMessageType()) + "); dropping");
                return;
            }
            NotificationInd nInd = (NotificationInd) pdu;
            byte[] locBytes = nInd.getContentLocation();
            if (locBytes == null || locBytes.length == 0) {
                android.util.Log.w("NowhereChooser", "#150 notification has no content-location; dropping");
                return;
            }
            String loc = new String(locBytes, StandardCharsets.ISO_8859_1);
            EncodedStringValue fromEsv = nInd.getFrom();
            String from = fromEsv == null ? "" : safe(fromEsv.getString());
            long size = nInd.getMessageSize();
            android.util.Log.i("NowhereChooser", "#150 M-Notification.ind: from=" + redact(from)
                    + " size=" + size + " subId=" + subId + " loc=" + redact(loc));

            // NWP-20260930-05: no identifiable SIM -> the download would run on subscription -1 (MmsService refuses it,
            // and the on-demand MMS PDN would come up on the default SIM), so do not download. The arrival cannot be
            // kept, so leave the loss notice, the same as an unresolved text or call (docs/product-decisions.md
            // 2026-09-30, answer 2). No txn is claimed, so a later push that DOES name a SIM is not skipped.
            final String t0 = txnId(nInd);
            final String aid = TelArrival.mmsId(subId, t0, loc, when); // NWP-20260930-05: a re-push has the same id
            if (subId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                SmsDeliverReceiver.postLossNotice(app, "mms", 0, aid);
                return;
            }

            // #150: skip a carrier RE-PUSH already downloading or delivered (claimTxn keeps it; a failure releases it).
            final String txn = t0.isEmpty() ? "" : subId + "|" + t0; // NWP-20260930-05: per (SIM, id)
            if (!txn.isEmpty() && !claimTxn(txn)) {
                android.util.Log.i("NowhereChooser", "#150 duplicate MMS notification (txn already handled); skipping re-download");
                return;
            }

            // Amnesia: sweep any orphaned staging bodies from a prior hung download this boot before starting a
            // new one (belt-and-suspenders with the per-download timeout below + the gate-boot wipe).
            sweepStaleStaging(app);

            // Staging target: one app-private file, addressed by a content:// Uri the MmsService can write.
            String name = "dl-" + subId + "-" + System.nanoTime();
            Uri contentUri = MmsFileProvider.uriFor(name);
            // Let the MmsService (com.android.phone) read+write THIS Uri for the duration of the download.
            app.grantUriPermission(MMS_SERVICE_PKG, contentUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);

            // Download-complete callback -> MmsDownloadedReceiver (explicit component; our own PendingIntent).
            Intent done = new Intent(app, MmsDownloadedReceiver.class)
                    .putExtra(MmsDownloadedReceiver.EXTRA_NAME, name)
                    .putExtra(MmsDownloadedReceiver.EXTRA_URI, contentUri.toString())
                    .putExtra(MmsDownloadedReceiver.EXTRA_SUBID, subId)
                    .putExtra(MmsDownloadedReceiver.EXTRA_WHEN, when)
                    .putExtra(MmsDownloadedReceiver.EXTRA_FROM, from)
                    .putExtra(MmsDownloadedReceiver.EXTRA_TXN, txn).putExtra(MmsDownloadedReceiver.EXTRA_MONO, mono)
                    .putExtra(MmsDownloadedReceiver.EXTRA_AID, aid); // NWP-20260930-05
            PendingIntent pi = PendingIntent.getBroadcast(app, name.hashCode(), done,
                    PendingIntent.FLAG_ONE_SHOT | PendingIntent.FLAG_MUTABLE);

            // Register this download BEFORE the kick so a fast completion finds its cleanup token, then bring up
            // the on-demand MMS PDN. The gate is a Wi-Fi-only kiosk (cellular DATA is off), but the MMS body
            // lives on the carrier's MMSC, reachable ONLY over the cellular MMS PDN; MOBILE_DATA_POLICY_MMS_
            // ALWAYS_ALLOWED brings up the `mms` APN on demand WITHOUT enabling general cellular data (needs
            // MODIFY_PHONE_STATE, platform-signed). Without it downloadMultimediaMessage silently times out with
            // no callback (proven on lynx). That policy is a PERSISTENT per-subscription setting, so it MUST be
            // turned back off when the download resolves -- else it is a standing, remotely-triggerable metered-
            // data channel on the owner's SIM. MmsInFlight.register/finish (via finishDownload) ref-count it to the
            // download's lifetime; a timeout backstops the no-callback case.
            MmsInFlight.register(name, subId, policy(app));

            final String fName = name, fUri = contentUri.toString();
            try {
                SmsManager sm = app.getSystemService(SmsManager.class).createForSubscriptionId(subId);
                sm.downloadMultimediaMessage(app, loc, contentUri, null /* default MMSC config for subId */, pi);
            } catch (Throwable kick) {
                finishDownload(app, fName, fUri, subId); // undo the grant + PDN ref + token on a failed kick
                releaseTxn(txn);                         // and free the txn so the next re-push retries
                SmsDeliverReceiver.postDownloadLoss(app, subId, aid); // docs/product-decisions.md 2026-11-05, #14
                throw kick;
            }
            android.util.Log.i("NowhereChooser", "#150 download kicked (uri=" + contentUri + ")");
            armDownloadTimeout(app, fName, fUri, subId, txn, aid);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "#150 notification handling failed", t);
        }
    }
PIN
)"
pin "MmsDownloadedReceiver.onReceive" "$(body "$MD" '@Override public void onReceive(Context ctx, Intent intent)' '    ')" "$(cat <<'PIN'
    @Override public void onReceive(Context ctx, Intent intent) {
        // getResultCode() MUST be read BEFORE goAsync() -- goAsync() detaches the result state onto the
        // PendingResult, after which getResultCode() returns the default 0 (RESULT_CANCELED). Reading it
        // after cost us a false "download FAILED: result=0" even on a successful 200-OK download.
        final int result = getResultCode();
        final PendingResult pr = goAsync();
        final int httpStatus = intent.getIntExtra("android.telephony.extra.MMS_HTTP_STATUS", -1);
        final String name = intent.getStringExtra(EXTRA_NAME);
        final String uriStr = intent.getStringExtra(EXTRA_URI);
        final int subId = intent.getIntExtra(EXTRA_SUBID, -1);
        final long when = intent.getLongExtra(EXTRA_WHEN, System.currentTimeMillis()), mono = intent.getLongExtra(EXTRA_MONO, TelArrival.stamp());
        final String fromHint = intent.getStringExtra(EXTRA_FROM);
        final String txn = intent.getStringExtra(EXTRA_TXN), aid = intent.hasExtra(EXTRA_AID) ? intent.getStringExtra(EXTRA_AID) : TelArrival.mmsId(subId, txn, "", when);
        final Context app = ctx.getApplicationContext();
        final File staged = (name == null) ? null : new File(MmsFileProvider.stagingDir(app), name);
        // Amnesia + policy lifecycle, EXACTLY once, as soon as the body is parsed (NWP-20260930-05: the seal now retries):
        // unlink the staging body, drop the MmsService's grant, release the MMS-PDN ref (IN_FLIGHT arbitrates), finish.
        final java.util.concurrent.atomic.AtomicBoolean fin = new java.util.concurrent.atomic.AtomicBoolean();
        final Runnable done = () -> { if (fin.compareAndSet(false, true)) { WapPushDeliverReceiver.finishDownload(app, name, uriStr, subId); pr.finish(); } };
        final java.util.concurrent.atomic.AtomicBoolean sealStarted = new java.util.concurrent.atomic.AtomicBoolean();
        new Thread(() -> {
            boolean delivered = false;
            try {
                delivered = sealDownloaded(app, result, httpStatus, staged, subId, when, fromHint, done, aid, mono, sealStarted);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "#150 downloaded-MMS handling failed", t);
            } finally {
                // #150 txn dedup: a download or parse that FAILED, or a seal that failed (ERR, no answer), frees the transaction
                // id so the carrier's next re-push retries; any answer keeps the claim, since a repeat would be answered the same.
                if (!delivered) WapPushDeliverReceiver.releaseTxn(txn);
                // #150 P3: scrub user 0's content://mms in case the framework staged a pending-download pdu row
                // for this WAP push (the SMS twin is SmsDeliverReceiver -> TelScrub.sms). Our own path never
                // persists the provider, so this is defense-in-depth; the gate-return + boot TelScrub.all and the
                // per-boot su:s0 janitor are the backstops.
                TelScrub.mms(app);
                done.run(); // if the parse never got that far; whatever happened, the cleartext body does not outlive this
                // docs/product-decisions.md 2026-11-05, #14: a body that never reached the seal leaves the loss notice. A seal
                // that started keeps settle's own answer, so one failure never posts two. This comes after the cleanup, which
                // never waits for a notice.
                if (!delivered && !sealStarted.get()) SmsDeliverReceiver.postDownloadLoss(app, subId, aid);
            }
        }).start();
    }
PIN
)"
pin "MmsDownloadedReceiver.sealDownloaded" "$(body "$MD" 'private static boolean sealDownloaded(Context app, int result, int httpStatus, File staged, int subId, long when,' '    ')" "$(cat <<'PIN'
    private static boolean sealDownloaded(Context app, int result, int httpStatus, File staged, int subId, long when,
                                          String fromHint, Runnable done, String aid, long mono,
                                          java.util.concurrent.atomic.AtomicBoolean sealStarted) throws Exception {
        if (result != Activity.RESULT_OK) {
            android.util.Log.w("NowhereChooser", "#150 MMS download FAILED: result=" + result
                    + " httpStatus=" + httpStatus);
            return false;
        }
        if (staged == null || !staged.exists()) {
            android.util.Log.w("NowhereChooser", "#150 download OK but staging file missing");
            return false;
        }
        byte[] body = Files.readAllBytes(staged.toPath());
        GenericPdu pdu = new PduParser(body, true).parse(); done.run(); // NWP-20260930-05: the body is in RAM now
        if (!(pdu instanceof RetrieveConf)) {
            android.util.Log.w("NowhereChooser", "#150 downloaded PDU is not an M-Retrieve.conf (type="
                    + (pdu == null ? "null" : pdu.getMessageType()) + "); " + body.length + " bytes");
            return false;
        }
        RetrieveConf rc = (RetrieveConf) pdu;
        String from = esv(rc.getFrom());
        if (from.isEmpty()) from = WapPushDeliverReceiver.safe(fromHint);
        String subject = esv(((MultimediaMessagePdu) rc).getSubject());
        PduBody pb = rc.getBody();
        int n = pb == null ? 0 : pb.getPartsNum();
        List<SmsDeliverReceiver.MmsPart> parts = new ArrayList<>(n);
        long totalBytes = 0;
        for (int i = 0; i < n; i++) {
            PduPart p = pb.getPart(i);
            if (p == null) continue;
            byte[] d = p.getData();
            totalBytes += (d == null ? 0 : d.length);
            String nm = bytesToStr(p.getName());
            if (nm.isEmpty()) nm = bytesToStr(p.getFilename());
            String ct = bytesToStr(p.getContentType());
            parts.add(new SmsDeliverReceiver.MmsPart(ct, nm, MmsText.toUtf8(ct, p.getCharset(), d)));
        }
        sealStarted.set(true);
        int outcome = SmsDeliverReceiver.sealMmsAndNotify(app, subId, from, when, subject, parts, aid, mono);
        android.util.Log.i("NowhereChooser", "#150 MMS sealed: from=" + WapPushDeliverReceiver.redact(from)
                + " parts=" + parts.size() + " totalBytes=" + totalBytes + " outcome=" + outcome);
        // Only a seal that failed (ERR, or no answer) lets a re-push retry: re-downloading an answered one gets the same answer.
        return outcome != SmsDeliverReceiver.SEAL_FAILED;
    }
PIN
)"
pin "ChooserActivity.bindingSummaries" "$(body "$CA" 'private java.util.List<String[]> bindingSummaries()' '    ')" "$(cat <<'PIN'
    private java.util.List<String[]> bindingSummaries() {
        return bindingSummaries(bindingReply());
    }
PIN
)"
pin "ChooserActivity.bindingReply" "$(body "$CA" 'private java.util.List<String> bindingReply()' '    ')" "$(cat <<'PIN'
    private java.util.List<String> bindingReply() {
        return DaemonSocket.roundTripLines("GET-BINDINGS\n", 90000);
    }
PIN
)"
pin "ChooserActivity.bindingSummaries(lines)" "$(body "$CA" 'private java.util.List<String[]> bindingSummaries(java.util.List<String> lines)' '    ')" "$(cat <<'PIN'
    private java.util.List<String[]> bindingSummaries(java.util.List<String> lines) {
        java.util.List<String[]> out = new java.util.ArrayList<>();
        // NWP-20260924-10: "NONE" = no bindings file, and "ERR damaged" one that cannot be read (NWP-20260930-04); NO reply is not
        // an answer -- the daemon was busy past its 60 s deadline, or unreachable -- so null, and fillSimRows says so.
        if (!lines.isEmpty() && lines.get(0).startsWith("NONE")) return out; if (!lines.isEmpty() && lines.get(0).startsWith("ERR damaged")) return TelArrival.DAMAGED_BINDINGS;
        if (lines.isEmpty() || !lines.get(0).startsWith("OK")) return null;
        for (String line : lines) {
            String[] f = line.split("\\|", 5);
            // NWP-20261006-01: e[3] = the line's label, e[4] = its visibility. NWP-20261011-19: the label is base64 on the
            // wire, because a stored label CAN hold '|' or a newline (bindings.conf base64s it, so setBindingOwner's
            // read-back check lets one through), and a raw '|' shifted the fields while still passing f.length == 5. A
            // field that does not decode is a daemon/chooser mismatch, shown as a damaged line rather than as "not bound".
            if (f.length == 5) {
                String label;
                try { label = new String(android.util.Base64.decode(f[2], android.util.Base64.DEFAULT), java.nio.charset.StandardCharsets.UTF_8); }
                catch (IllegalArgumentException e) { out.add(TelArrival.DAMAGED_ROW); continue; }
                out.add(new String[]{ f[0].trim(), f[1].trim(), f[4].trim() + " bound · " + f[3].trim(), label, f[3].trim() });
            } else if ("DAMAGED".equals(line.trim())) out.add(TelArrival.DAMAGED_ROW);
        }
        return out;
    }
PIN
)"
pin "ChooserActivity.fillSimRows" "$(body "$CA" 'private void fillSimRows(LinearLayout rows, java.util.List<String[]> sums, java.util.List<SimInfo> sims, int inactiveEsims)' '    ')" "$(cat <<'PIN'
    private void fillSimRows(LinearLayout rows, java.util.List<String[]> sums, java.util.List<SimInfo> sims, int inactiveEsims) {
        rows.removeAllViews();
        if (sums == null || sums == TelArrival.DAMAGED_BINDINGS || sums.contains(TelArrival.DAMAGED_ROW)) { // NWP-20260930-05: say so
            TextView err = new TextView(this); StatusLine.error(err, sums == null ? "Couldn't read the SIM bindings — the phone is busy. Go Back and try again." : sums == TelArrival.DAMAGED_BINDINGS ? TelArrival.BINDINGS_DAMAGED : TelArrival.BINDING_LINE_DAMAGED); err.setTextColor(MUTED); err.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13); err.setGravity(Gravity.CENTER); err.setPadding(dp(8), dp(8), dp(8), dp(8));
            rows.addView(err, new LinearLayout.LayoutParams(MATCH, WRAP));
            if (sums != null) rows.addView(settingsRow(BindingsRepair.ROW, BindingsRepair.ROW_SUMMARY, v -> confirmRepairBindings(err)), new LinearLayout.LayoutParams(MATCH, WRAP)); // NWP-20261110-06 (Q031): both damage states, not the busy one
            if (sums == null || sums == TelArrival.DAMAGED_BINDINGS) return; // a damaged line: the SIMs still list, to bind again
        }
        for (SimInfo s : sims) {
            final SimInfo fs = s;
            String bound = "not bound"; // e = {subId, iccid, "n bound · vis"}: the ICCID first, the subId only without one
            String[] hit = null;
            for (String[] e : sums) if (iccEq(s.iccid, e[1])) { hit = e; break; }
            if (hit == null && (s.iccid == null || s.iccid.trim().isEmpty()) && s.subId >= 0)
                for (String[] e : sums) if (String.valueOf(s.subId).equals(e[0])) { hit = e; break; }
            if (hit != null) {
                bound = hit[2];
                // NWP-20261006-01: carry the line's label + visibility into its bind form. Binding a co-owner rewrites both
                // (setBindingOwner), and the form used to open blank and "Open", so adding a second profile to a line
                // labelled "Work" quietly unlabelled it, and a "Private" line went "Open".
                if (hit.length >= 5) { fs.label = hit[3]; fs.vis = hit[4]; }
                fs.rebuilt = false; fs.mine = false; // NWP-20261110-07: a bound SIM's binding decides, so its form has no mine row
            } else if (fs.rebuilt) bound = fs.mine ? BindingMarks.OWN_LINE : BindingMarks.NOT_OWN_LINE; // Q031: unresolved until bound or marked
            android.util.Log.i("NowhereChooser", "SIM-lines sub=" + s.subId + " iccidLen="
                    + (s.iccid == null ? -1 : s.iccid.length()) + " bindings=" + sums.size() + " -> " + bound);
            rows.addView(settingsRow(s.carrier, simRowSummary(bound, s.embedded), v -> setContentView(buildBindSimScreen(fs))), new LinearLayout.LayoutParams(MATCH, WRAP));
        }
        if (sims.isEmpty()) {
            TextView none = new TextView(this); none.setText("No SIM detected."); none.setTextColor(MUTED); none.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13); none.setGravity(Gravity.CENTER); none.setPadding(dp(8), dp(8), dp(8), dp(8));
            rows.addView(none, new LinearLayout.LayoutParams(MATCH, WRAP));
        }
        // NWP-20261116-20 (#73, Q118): each stored binding whose SIM is not in the phone gets its own row, so its owner
        // can see it and Unbind it. Matched as the rows above match: by ICCID, by subId only for a SIM read with no
        // ICCID. Logged by count only -- an ICCID is a SIM serial.
        final java.util.List<String> activeIccids = new java.util.ArrayList<>();
        final java.util.List<Integer> activeSubIdsWithoutIccid = new java.util.ArrayList<>();
        for (SimInfo s : sims) {
            if (s.iccid != null && !s.iccid.trim().isEmpty()) activeIccids.add(s.iccid);
            else if (s.subId >= 0) activeSubIdsWithoutIccid.add(s.subId);
        }
        final java.util.List<String[]> absent = AbsentSims.rows(sums, activeIccids, activeSubIdsWithoutIccid);
        for (String[] e : absent) {
            final SimInfo fs = new SimInfo();
            fs.iccid = e[1]; fs.carrier = AbsentSims.TITLE; fs.label = e[3]; fs.vis = e[4];
            rows.addView(settingsRow(AbsentSims.TITLE, AbsentSims.summary(e), v -> setContentView(buildBindSimScreen(fs))), new LinearLayout.LayoutParams(MATCH, WRAP));
        }
        android.util.Log.i("NowhereChooser", "SIM-lines absent=" + absent.size());
        int activeEsims = 0;
        for (SimInfo s : sims) if (s.embedded) activeEsims++;
        android.util.Log.i("NowhereChooser", "SIM-lines esim active=" + activeEsims + " inactive=" + inactiveEsims);
        final String esim = esimNote(activeEsims, inactiveEsims);
        if (esim != null) {
            TextView note = new TextView(this); note.setText(esim); note.setTextColor(MUTED); note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13); note.setGravity(Gravity.CENTER); note.setPadding(dp(8), dp(8), dp(8), dp(8));
            rows.addView(note, new LinearLayout.LayoutParams(MATCH, WRAP));
        }
    }
PIN
)"
pin "ChooserActivity.telNotices" "$(body "$CA" 'private java.util.List<String[]> telNotices(java.util.Set<String> skip)' '    ')" "$(cat <<'PIN'
    private java.util.List<String[]> telNotices(java.util.Set<String> skip) {
        try {
            android.app.NotificationManager nm = getSystemService(android.app.NotificationManager.class);
            if (nm == null) return null;
            android.service.notification.StatusBarNotification[] act = nm.getActiveNotifications();
            if (act == null || act.length == 0) return null;
            java.util.ArrayList<String[]> notices = new java.util.ArrayList<>();
            for (android.service.notification.StatusBarNotification sbn : act) {
                if (sbn == null || sbn.getNotification() == null) continue;
                if (!SmsDeliverReceiver.TEL_CHANNEL.equals(sbn.getNotification().getChannelId())) continue;
                if (skip.contains(sbn.getKey())) continue;
                android.os.Bundle ex = sbn.getNotification().extras;
                if (ex == null) continue;
                CharSequence title = ex.getCharSequence(android.app.Notification.EXTRA_TITLE);
                if (title == null || title.length() == 0) continue;
                // "call" (missed) | "incoming" (answered at the gate) | "message" (NWP-20261128-18)
                String kind = TelNoticeClear.kindOf(ex.getString("nowhere_kind", ""), ex.getString("nowhere_call", ""), title.toString());
                boolean isLoss = !ex.getString("nowhere_class", "").isEmpty(); // "may not have been saved" (NWP-20260930-05)
                boolean unbound = "unbound".equals(ex.getString("nowhere_line", ""))
                        || title.toString().endsWith(SmsDeliverReceiver.UNBOUND_LINE); // the unassigned line's (NWP-20261006-04)
                CharSequence text = ex.getCharSequence(android.app.Notification.EXTRA_TEXT); // opted-in "From <number>"
                notices.add(new String[]{noticeLabel(sbn), kind,
                        String.valueOf(Math.max(1, ex.getInt("nowhere_count", 1))), String.valueOf(isLoss),
                        (text != null && text.length() > 0) ? title + "  ·  " + text : title.toString(),
                        String.valueOf(unbound)});
            }
            return notices;
        } catch (Throwable t) {
            return null;
        }
    }
PIN
)"
pin "ChooserActivity.telNoticeSummary" "$(body "$CA" 'private String telNoticeSummary(java.util.Set<String> skip)' '    ')" "$(cat <<'PIN'
    private String telNoticeSummary(java.util.Set<String> skip) {
        java.util.List<String[]> n = telNotices(skip);
        return n == null ? null : summarize(n);
    }
PIN
)"
pin "ChooserActivity.cancelTelNotices" "$(body "$CA" 'private void cancelTelNotices(java.util.Set<String> labels)' '    ')" "$(cat <<'PIN'
    private void cancelTelNotices(java.util.Set<String> labels) {
        final java.util.Set<String> gone = new java.util.HashSet<>();
        try {
            android.app.NotificationManager nm = getSystemService(android.app.NotificationManager.class);
            if (nm != null) {
                android.service.notification.StatusBarNotification[] act = nm.getActiveNotifications();
                if (act != null) for (android.service.notification.StatusBarNotification sbn : act) {
                    if (sbn == null || sbn.getNotification() == null) continue;
                    if (!SmsDeliverReceiver.TEL_CHANNEL.equals(sbn.getNotification().getChannelId())) continue;
                    if (labels != null && !labels.contains(noticeLabel(sbn))) continue; // a stranger's throwaway owns nothing
                    if (!sbn.getNotification().extras.getString("nowhere_class", "").isEmpty()) continue; // a loss notice: the arrival's only trace
                    nm.cancel(sbn.getTag(), sbn.getId());
                    gone.add(sbn.getKey());
                }
            }
        } catch (Throwable ignore) {}
        if (noticeBanner == null) return;
        if (labels == null) { runOnUiThread(() -> noticeBanner.setVisibility(View.GONE)); return; }
        final String summary = telNoticeSummary(gone); // a cancel lands asynchronously: skip what was just cancelled
        runOnUiThread(() -> {
            if (coverShown || sOwnerSession || summary == null) { noticeBanner.setVisibility(View.GONE); return; }
            noticeBanner.setText(summary);
            noticeBanner.setVisibility(View.VISIBLE);
        });
    }
PIN
)"
lpin "SEAL_DEADLINE_MS" "$TA" '    static final long SEAL_DEADLINE_MS = 60_000L;'
lpin "backoffMs" "$TA" '    static long backoffMs(int attempt) { return attempt >= 3 ? 8_000L : 1_000L << attempt; }'
lpin "stamp" "$TA" '    static long stamp() { return SystemClock.elapsedRealtime(); }'
lpin "CALL_STAMPS" "$TA" '    private static final Map<Call, Long> CALL_STAMPS = new WeakHashMap<>();'
lpin "DIALS" "$TA" '    private static final Map<String, String> DIALS = new ConcurrentHashMap<>();'
lpin "DAMAGED_BINDINGS" "$TA" '    static final java.util.List<String[]> DAMAGED_BINDINGS = java.util.Collections.unmodifiableList(new java.util.ArrayList<>());'
lpin "DAMAGED_ROW" "$TA" '    static final String[] DAMAGED_ROW = { "", "", "" };'
lpin "BINDINGS_DAMAGED" "$TA" '    static final String BINDINGS_DAMAGED = "This phone'\''s SIM bindings file can'\''t be read, so texts and calls to its lines "'
lpin "BINDING_LINE_DAMAGED" "$TA" '    static final String BINDING_LINE_DAMAGED = "A SIM binding on this phone is damaged. Repair SIM bindings keeps the "'
lpin "BINDING_LINE_DAMAGED (2)" "$TA" '            + "readable ones; after it, any SIM that lost its binding can be bound again.";'
lpin "BINDING_UNSTORABLE" "$TA" '    static final String BINDING_UNSTORABLE = "that ICCID can'\''t be saved as entered — check it and try again";'
lpin "the SEAL_* outcomes (sealed)" "$SD" '    static final int SEAL_SEALED = 1;   // kept for at least one bound owner, sealed or queued'
lpin "the SEAL_* outcomes (none)" "$SD" '    static final int SEAL_NONE   = 0;   // nothing for a bound owner or a live session: an unbound arrival (now sealed to the device-owner inbox, Slice D) or unassigned since'
lpin "the SEAL_* outcomes (failed)" "$SD" '    static final int SEAL_FAILED = -1;  // ERR, or no answer, to the deadline: it may or may not have been kept'
lpin "the SEAL_* outcomes (unkept)" "$SD" '    static final int SEAL_UNKEPT = -2;  // UNRESOLVED or FULL: not kept; a repeat of this arrival id is answered the same'
lpin "TEL_LOSS_TAG" "$SD" '    static final String TEL_LOSS_TAG = "nowhere_telephony_loss"; // own tag; id per arrival, so a repeat replaces its own'
lpin "LOSS_ANNOUNCED" "$SD" '    private static final java.util.Set<String> LOSS_ANNOUNCED = java.util.concurrent.ConcurrentHashMap.newKeySet(); // chime once'

R=$(body "$SD" '@Override public void onReceive(Context ctx, Intent intent)' '    ')
S=$(body "$SD" 'static int sealAndNotify(Context ctx, String kind, int subId, String iccid, String from, long when, String body,' '    ')
ST=$(body "$SD" 'static int settle(Context ctx, TelArrival.Reply r, String kind, int callType, String iccid, String from,' '    ')
L=$(body "$SD" 'static void postLossNotice(Context ctx, String kind, int callType, String aid)' '    ')
M=$(body "$SD" 'static int sealMmsAndNotify(Context ctx, int subId, String from, long when, String subject,' '    ')
U=$(body "$TA" 'static Reply untilAnswered(String req, int timeoutMs, long deadline, String iccid)' '    ')
SI=$(body "$TA" 'static int subIdOr(Context ctx, Intent intent, int named)' '    ')
F=$(body "$IC" 'void finish(Call call)' '        ')
IA=$(body "$IC" '@Override public void onCallAdded(Call call)' '    ')
C=$(body "$CC" 'public void onCallAdded(Call call)' '    ')
RR=$(body "$RC" '@Override public void onReceive(Context ctx, Intent intent)' '    ')
RS=$(body "$RC" 'static void seal(Context app, int subId, String iccid, String from, long when, long mono)' '    ')
WR=$(body "$WP" '@Override public void onReceive(Context ctx, Intent intent)' '    ')
WH=$(body "$WP" 'private static void handleNotification(Context app, byte[] data, int subId, long when, long mono)' '    ')
MR=$(body "$MD" '@Override public void onReceive(Context ctx, Intent intent)' '    ')
SDn=$(body "$MD" 'private static boolean sealDownloaded(Context app, int result, int httpStatus, File staged, int subId, long when,' '    ')
AT=$(body "$WP" 'private static void armDownloadTimeout(Context app, String name, String uriStr, int subId, String txn, String aid)' '    ')
PL=$(body "$SD" 'static void postDownloadLoss(Context ctx, int subId, String aid)' '    ')
BS=$(body "$CA" 'private java.util.List<String[]> bindingSummaries(java.util.List<String> lines)' '    ')
FS=$(body "$CA" 'private void fillSimRows(LinearLayout rows, java.util.List<String[]> sums, java.util.List<SimInfo> sims, int inactiveEsims)' '    ')
TS=$(body "$CA" 'static String summarize(java.util.List<String[]> notices)' '    ')
N=$(body "$CA" 'private void cancelTelNotices(java.util.Set<String> labels)' '    ')
CAC=$(code "$(cat "$CA")")

echo
echo "== one arrival, one id and one stamp, on every attempt =="
if has "$R" 'final long when = System.currentTimeMillis(), mono = TelArrival.stamp();' && has "$R" 'TelArrival.smsId(subId, when, from, text), mono);'; then ok "a text's id and stamp are taken once, in onReceive"; else no "a text's id or stamp is not taken once at its arrival"; fi
if [ "$(count "$U" 'DaemonSocket.roundTrip(req, timeoutMs)')" = 1 ] && ! has "$U" 'req ='; then ok "every attempt sends the same request bytes"; else no "an attempt builds a new request -- a retry would be a new arrival"; fi
if has "$F" 'final long mono = TelArrival.callStamp(call);' && has "$F" 'true, TelArrival.callId(subId, when), mono);' && has "$IA" 'super.onCallAdded(call); TelArrival.stampCall(call);'; then ok "a call's stamp is taken at its first onCallAdded, before the #145 re-check"; else no "a call's stamp is not its arrival's"; fi
if has "$(body "$TA" 'static String callId(int subId, long createdMs)' '    ')" 'return sha256Hex("call\0" + subId + "\0" + createdMs);'; then ok "the call id is its subId and creation time, as both call services compute it"; else no "the call id is not its subId and creation time"; fi
if has "$WH" 'final String aid = TelArrival.mmsId(subId, t0, loc, when);' && has "$WH" '.putExtra(MmsDownloadedReceiver.EXTRA_AID, aid);' && has "$WH" '.putExtra(MmsDownloadedReceiver.EXTRA_TXN, txn).putExtra(MmsDownloadedReceiver.EXTRA_MONO, mono)' && has "$MR" 'aid = intent.hasExtra(EXTRA_AID) ? intent.getStringExtra(EXTRA_AID)' && has "$MR" 'mono = intent.getLongExtra(EXTRA_MONO, TelArrival.stamp());'; then ok "an MMS's id and stamp are taken at its push and carried to the seal"; else no "an MMS's id or stamp is taken at its download"; fi
if has "$(body "$TA" 'static String mmsId(int subId, String txn, String loc, long when)' '    ')" 'String key = txn != null && !txn.isEmpty() ? "t" + txn : loc != null && !loc.isEmpty() ? "l" + loc : "w" + when;'; then ok "an MMS is named by its transaction id first, so a carrier re-push has the same id"; else no "an MMS is named by something a re-push changes"; fi

echo
echo "== retried to the deadline, and only an ERR or no answer is retried =="
if has "$U" 'if (!"ERR".equals(last.kind)) return last;' && has "$U" 'if (stamp() + wait > deadline) return last;'; then ok "an answer other than ERR ends the retries, and the deadline ends them too"; else no "the retries do not stop at an answer, or never stop"; fi
if [ "$(count "$S" 'final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;')" = 1 ] && has "$S" 'TelArrival.untilAnswered(req, 5000, deadline, safe(iccid));'; then ok "a text's and a call's deadline runs from when the seal starts"; else no "the deadline runs from the arrival -- a call's own length uses up its retries"; fi
if [ "$(count "$M" 'final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;')" = 1 ] && has "$M" 'TelArrival.untilAnswered(req, 10_000, deadline, iccid);'; then ok "an MMS's deadline runs from its download callback"; else no "an MMS's deadline runs from its push, which a 90 s download can use up"; fi

echo
echo "== each reply has its meaning =="
if [ "$(count "$ST" 'return SEAL_SEALED;')" = 3 ] && ! has "$ST" 'count'; then ok "OK is kept, whatever its count"; else no "an OK is read by its count again -- OK ... 0 also means queued"; fi
if ! has "$(body "$TA" 'static Reply parse(String line)' '    ')" 'f[3]'; then ok "the OK count field (f[3]) is never parsed, so no code can read an OK by its count"; else no "the OK count field is parsed -- an OK ... 0 could then be read as nothing kept"; fi
if has "$ST" 'return r == null || "ERR".equals(r.kind) ? SEAL_FAILED : SEAL_UNKEPT;'; then ok "UNRESOLVED and FULL are answered, not failed; only ERR or no answer is"; else no "an UNRESOLVED or FULL reads as a failure -- an MMS would be downloaded again for the same answer"; fi
if has "$ST" 'postMessageNotice(asGate(ctx), UNBOUND_LINE, kind, callType, null);'; then ok "the unassigned-SIM notice goes to user 0, with no number"; else no "the unassigned-SIM notice is not posted in user 0"; fi
if has "$ST" 'if (!TelArrival.knownPrivate(iccid) && (r == null || !"private".equals(r.vis))) postLossNotice(ctx, kind, callType, aid);'; then ok "an arrival not kept leaves the loss notice unless its line is known to be Private"; else no "an arrival not kept leaves no trace, or ignores a Private line"; fi
if has "$ST" 'if ("REMOVED".equals(r.kind)) return SEAL_NONE;'; then ok "REMOVED leaves nothing: the unassign deleted its records and notices"; else no "REMOVED is announced"; fi
if has "$ST" 'if (gateNotice && !"private".equals(r.vis)) postMessageNotice(ctx, r.label, kind, callType, "number".equals(r.vis) ? from : null);' && [ "$(code "$ST" | grep -F 'gateNotice' | grep -cvF 'boolean gateNotice, String aid) {')" = 1 ]; then ok "gateNotice governs only the labelled notice"; else no "gateNotice governs a notice with no label -- a stranger-session call would leave no trace"; fi

echo
echo "== the loss notice: user 0's, one per arrival, and the arrival's only trace =="
if has "$L" 'final Context gate = asGate(ctx);' && has "$(body "$SD" 'static Context asGate(Context ctx)' '    ')" 'try { return ctx.createContextAsUser(android.os.UserHandle.SYSTEM, 0); }'; then ok "the loss notice is posted in user 0"; else no "the loss notice is posted in the caller's user"; fi
if has "$L" 'nx.putString("nowhere_class", "unsaved");'; then ok "the loss notice is classed, so the label-based clears pass it by"; else no "the loss notice is unclassed"; fi
if has "$L" 'nm.notify(TEL_LOSS_TAG, java.util.Objects.hashCode(aid),'; then ok "one loss notice per arrival: a repeat replaces its own, and never another's"; else no "a loss notice replaces another arrival's, or a repeat posts a second"; fi
if has "$L" 'if (LOSS_ANNOUNCED.add(String.valueOf(aid)) && !isCall) alertGateArrival(gate);' && has "$L" 'if (LOSS_ANNOUNCED.size() >= 4096) LOSS_ANNOUNCED.clear();'; then ok "a text's loss notice chimes once per arrival, from a bounded set"; else no "a repeat chimes again, or the set grows without bound"; fi
if has "$L" '.setContentTitle((isCall ? (callType == 1 ? "Incoming call" : "Missed call") : "New message") + " — may not have been saved").build());'; then ok "an answered call's loss notice says Incoming call, as the gate's own notice does"; else no "an answered call's loss notice says Missed call"; fi
if has "$N" 'if (!sbn.getNotification().extras.getString("nowhere_class", "").isEmpty()) continue;'; then ok "no label-based clear removes a loss notice"; else no "a login or a resume clears a loss notice"; fi
if has "$TS" 'if ("true".equals(n[3])) c[2] += k; else if ("call".equals(n[1])) c[0] += k; else if ("incoming".equals(n[1])) c[3] += k; else c[1] += k;'; then ok "the gate's banner counts loss notices as their own kind"; else no "the banner counts a loss notice as a missed call or a message"; fi

echo
echo "== the SIM is never guessed =="
for f in "$SD" "$IC" "$CC" "$WP" "$MD" "$TA" "$RC"; do
  if [ "$(code "$(cat "$f")" | grep -cE 'getDefault(Sms|Voice|Data)?SubscriptionId\(\)')" = 0 ]; then ok "no default-SIM guess in $(basename "$f")"; else no "$(basename "$f") guesses the default SIM"; fi
done
if has "$SI" 'if (named != SubscriptionManager.INVALID_SUBSCRIPTION_ID) return named;' && has "$SI" 'int slot = intent.getIntExtra(SubscriptionManager.EXTRA_SLOT_INDEX, -1);' && has "$SI" 'SubscriptionInfo si = sm == null ? null : sm.getActiveSubscriptionInfoForSimSlotIndex(slot);' && has "$SI" 'if (si != null) return si.getSubscriptionId();' && ! has "$SI" 'getActiveSubscriptionInfoList'; then ok "an arrival's SIM is the one named, else its slot's, else unidentified"; else no "an arrival's SIM is guessed"; fi
if has "$R" 'final int subId = TelArrival.subIdOr(ctx, intent, intent.getIntExtra("subscription", SubscriptionManager.INVALID_SUBSCRIPTION_ID));' && has "$WR" 'final int subId = TelArrival.subIdOr(ctx, intent, intent.getIntExtra("subscription",'; then ok "a text's and a WAP push's SIM both go through subIdOr"; else no "a text's or a WAP push's SIM is only what the intent names -- one whose subscription came up late is unidentified"; fi
if has "$WH" 'if (subId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {' && has "$WH" 'SmsDeliverReceiver.postLossNotice(app, "mms", 0, aid);'; then ok "an MMS whose SIM is not identified leaves the loss notice and is not downloaded on subscription -1"; else no "an MMS whose SIM is not identified is downloaded on subscription -1, or dropped with no trace"; fi

echo
echo "== the calls: the scrub does not wait, and a rejected call is sealed in user 0 =="
sc=$(line "$F" 'TelScrub.callLogRetry(app);'); se=$(line "$F" 'SmsDeliverReceiver.sealAndNotify(app, "call"')
if [ "$sc" -gt 0 ] && [ "$sc" -lt "$se" ] && has "$F" '}, "nowhere-scrub-call").start();'; then ok "the call log scrub starts on its own thread before the seal"; else no "the call log scrub waits for the seal -- the number sits on user 0 up to the deadline"; fi
ex=$(line "$C" 'String exempt = emergencyExemption(getApplicationContext(), d);'); ho=$(line "$C" 'app.sendBroadcastAsUser(new android.content.Intent(app, RejectedCallSealReceiver.class)')
hf=$(line "$C" 'android.util.Log.w("NowhereChooser", "call-control: seal hand-off to user 0 failed", t);'); rj=$(line "$C" 'call.reject(false, null);')
if [ "$ex" -gt 0 ] && [ "$ex" -lt "$ho" ] && [ "$hf" -gt "$ho" ] && [ "$rj" -gt "$hf" ]; then ok "the emergency exemption comes first, then the hand-off, then the decline, whatever the hand-off did"; else no "a call is handed off before the exemption, or declined only when the hand-off works"; fi
if has "$C" '.putExtra(RejectedCallSealReceiver.EXTRA_MONO, mono), android.os.UserHandle.SYSTEM);' && ! has "$C" 'sealAndNotify(' && ! has "$C" 'RejectedCallSealReceiver.seal('; then ok "a call rejected in a stranger's session is sealed in user 0, not in the stranger's process"; else no "a rejected call is sealed in the stranger's process, which can be frozen and does not know the Private lines"; fi
if has "$C" '.putExtra(RejectedCallSealReceiver.EXTRA_SUB, subId).putExtra(RejectedCallSealReceiver.EXTRA_ICCID, iccid)' && has "$C" '.putExtra(RejectedCallSealReceiver.EXTRA_FROM, from).putExtra(RejectedCallSealReceiver.EXTRA_WHEN, when)' && has "$RR" 'final int subId = intent.getIntExtra(EXTRA_SUB, SubscriptionManager.INVALID_SUBSCRIPTION_ID);' && has "$RR" 'final String iccid = intent.getStringExtra(EXTRA_ICCID), from = intent.getStringExtra(EXTRA_FROM);' && has "$RR" 'final long when = intent.getLongExtra(EXTRA_WHEN, 0L), mono = intent.getLongExtra(EXTRA_MONO, TelArrival.stamp());'; then ok "the hand-off carries the call's SIM, number, time and stamp"; else no "the hand-off drops a field, or user 0 stamps the call on receipt"; fi
if has "$C" '"call-control: seal hand-off to user 0 failed", t); SmsDeliverReceiver.postLossNotice(app, "call", 3, TelArrival.callId(subId, when)); }'; then ok "a hand-off that fails leaves the loss notice"; else no "a hand-off that fails leaves no trace"; fi
if has "$RR" 'new Thread(() -> seal(app, subId, iccid, from, when, mono), "nowhere-seal-rejected-call").start();' && has "$RS" 'SmsDeliverReceiver.sealAndNotify(app, "call", subId, iccid, from, when, "", 3 , 0 ,' && has "$RS" 'false , TelArrival.callId(subId, when), mono);'; then ok "user 0 seals it off the main thread, silently, as a missed call with the call's id"; else no "user 0 seals it on the main thread, with its label shown, or under another id"; fi
if [ "$(grep -cxF '    <receiver android:name=".RejectedCallSealReceiver" android:exported="false"/>' "$AM")" = 1 ] && [ "$(grep -cF 'RejectedCallSealReceiver' "$AM")" = 1 ]; then ok "RejectedCallSealReceiver is declared once, not exported"; else no "RejectedCallSealReceiver is exported -- any app could plant a missed call"; fi

echo
echo "== the MMS: claimed per (SIM, transaction), finished before the retries, and released only on a failure =="
if [ "$(code "$(cat "$WP")" | grep -cF 'final String txn = t0.isEmpty() ? "" : subId + "|" + t0;')" = 1 ]; then ok "a transaction is claimed per SIM"; else no "a transaction id is claimed across SIMs"; fi
pa=$(line "$SDn" 'GenericPdu pdu = new PduParser(body, true).parse(); done.run();'); sm=$(line "$SDn" 'SmsDeliverReceiver.sealMmsAndNotify(')
if [ "$pa" -gt 0 ] && [ "$pa" -lt "$sm" ]; then ok "the download is finished (body unlinked, grant and PDN released, broadcast finished) before the seal's retries"; else no "the download is finished only after the seal -- the retries hold the body and the MMS PDN"; fi
if has "$SDn" 'return outcome != SmsDeliverReceiver.SEAL_FAILED;' && has "$MR" 'if (!delivered) WapPushDeliverReceiver.releaseTxn(txn);'; then ok "an answered seal keeps the claim, and only a failed one releases it for the re-push"; else no "an MMS the daemon answered is downloaded again, or a failed one is never retried"; fi

echo
echo "== a failed download leaves the loss notice, once per failure (docs/product-decisions.md 2026-11-05, #14) =="
LP='SmsDeliverReceiver.postDownloadLoss(app, subId, aid);'
if has "$PL" 'if (!TelArrival.knownPrivate(safe(iccidForSub(ctx, subId)))) postLossNotice(ctx, "mms", 0, aid);' && [ "$(count "$PL" 'postLossNotice(')" = 1 ]; then ok "a failed download posts the 2026-09-30 notice, unless the line is known Private"; else no "a failed download's notice ignores the Private rule, a Private line would show one"; fi
if [ "$(count "$PL" 'android.util.Log.')" = 1 ] && [ "$(code "$PL" | grep -F 'android.util.Log.' | grep -cF '+')" = 0 ]; then ok "its one log line is fixed text: no number and no id"; else no "its log line is missing or carries a value"; fi
kc=$(line "$WH" 'catch (Throwable kick)'); kf=$(line "$WH" 'finishDownload(app, fName, fUri, subId);'); kr=$(line "$WH" 'releaseTxn(txn);'); kp=$(line "$WH" "$LP"); kt=$(line "$WH" 'throw kick;')
if [ "$(count "$WH" "$LP")" = 1 ] && [ "$kc" -gt 0 ] && [ "$kc" -lt "$kf" ] && [ "$kf" -lt "$kr" ] && [ "$kr" -lt "$kp" ] && [ "$kp" -lt "$kt" ]; then ok "a failed kick posts it once, after the cleanup and before the rethrow"; else no "a failed kick leaves no trace, or posts outside its catch"; fi
af=$(line "$AT" 'if (finishDownload(app, name, uriStr, subId)) {'); ar=$(line "$AT" 'releaseTxn(txn);'); ap=$(line "$AT" "$LP"); ae=$(code "$AT" | awk -v s="$af" 'NR > s && $0 == "            }" { print NR; exit }')
if [ "$(count "$AT" "$LP")" = 1 ] && [ "$af" -gt 0 ] && [ "$af" -lt "$ar" ] && [ "$ar" -lt "$ap" ] && [ "$ap" -lt "${ae:-0}" ]; then ok "a timeout posts it once, inside its finishDownload test: a callback that finished the download posts nothing more"; else no "a timeout leaves no trace, or posts after a callback already finished the download"; fi
ml=$(line "$MR" 'finally {'); md=$(line "$MR" 'done.run();'); mf=$(line "$MR" "if (!delivered && !sealStarted.get()) $LP")
if [ "$(count "$MR" 'postDownloadLoss(')" = 1 ] && [ "$ml" -gt 0 ] && [ "$ml" -lt "$md" ] && [ "$md" -lt "$mf" ] && has "$MR" 'fromHint, done, aid, mono, sealStarted);'; then ok "a body that never reached the seal posts it once, after the cleanup, and a started seal keeps settle's answer"; else no "a failed callback leaves no trace, or a failed seal posts two notices"; fi
fs=$(line "$SDn" 'sealStarted.set(true);')
if [ "$(count "$SDn" 'sealStarted.set(')" = 1 ] && [ "$fs" -gt 0 ] && [ "$sm" = "$((fs+1))" ]; then ok "the flag is set immediately before the seal"; else no "the flag is set too early (a parse failure reads as a started seal), or too late"; fi
if [ "$(count "$SDn" 'postDownloadLoss(')" = 0 ]; then ok "the delivered path posts no loss notice"; else no "an MMS the daemon answered also posts the loss notice"; fi

echo
echo "== the v2 wire =="
if has "$(body "$TA" 'static String telRequest(String aid, long mono, String kind, int subId, String iccid, String from, long when,' '    ')" 'return "SEAL-TEL\nv2\n" + aid + "\n" + kind + "\n" + subId + "\n" + iccid + "\n" + b64(from) + "\n" + when + "\n"'; then ok "SEAL-TEL is v2, with the sender in base64"; else no "SEAL-TEL is not v2, or sends the sender raw"; fi
if has "$(body "$TA" 'static String mmsRequest(String aid, long mono, int subId, String iccid, String from, long when, String subject,' '    ')" 'req.append("SEAL-MMS\nv2\n").append(aid)'; then ok "SEAL-MMS is v2"; else no "SEAL-MMS is not v2"; fi
if [ "$(code "$(cat "$SD")" | grep -cxF '            TelScrub.sms(app);')" = 1 ]; then ok "TelScrub.sms(app); is unchanged (test-tel-scrub.sh anchors on it)"; else no "the TelScrub.sms(app); line changed"; fi

echo
echo "== owner mode says what the daemon found =="
if has "$BS" 'if (!lines.isEmpty() && lines.get(0).startsWith("ERR damaged")) return TelArrival.DAMAGED_BINDINGS;' && has "$BS" 'else if ("DAMAGED".equals(line.trim())) out.add(TelArrival.DAMAGED_ROW);'; then ok "GET-BINDINGS' unreadable file and its closing DAMAGED line are both read"; else no "a damaged bindings.conf reads as busy, or as fine"; fi
if has "$FS" 'if (sums == null || sums == TelArrival.DAMAGED_BINDINGS || sums.contains(TelArrival.DAMAGED_ROW)) {' && has "$FS" 'sums == TelArrival.DAMAGED_BINDINGS ? TelArrival.BINDINGS_DAMAGED : TelArrival.BINDING_LINE_DAMAGED' && has "$FS" 'if (sums == null || sums == TelArrival.DAMAGED_BINDINGS) return;'; then ok "a damaged line is said, and the SIMs still list, so one that lost its line can be bound again"; else no "a damaged line is not said, or hides the SIMs that must be bound again"; fi
if printf '%s\n' "$CAC" | grep -cF '(sr != null && sr.startsWith("ERR unstorable")) ? "UNSTORABLE" : "ERR";' >/dev/null && printf '%s\n' "$CAC" | grep -cF 'else if ("UNSTORABLE".equals(result)) StatusLine.error(msg, TelArrival.BINDING_UNSTORABLE);' >/dev/null; then ok "an ICCID that would not read back says so"; else no "an ICCID that would not read back reads as a failed save, to retry forever"; fi
if printf '%s\n' "$CAC" | grep -cF "else StatusLine.error(msg, r != null && r.startsWith(\"ERR damaged\") ? TelArrival.BINDINGS_DAMAGED : \"couldn't unbind — try again\");" >/dev/null && printf '%s\n' "$CAC" | grep -cF 'else if ("DAMAGED".equals(result)) StatusLine.error(msg, TelArrival.BINDINGS_DAMAGED);' >/dev/null; then ok "a bind or unbind against an unreadable file says so"; else no "a bind or unbind against an unreadable file reads as try again"; fi

echo
echo "== an arrival alerts only at the gate (NWP-20261007-03) =="
pin "SmsDeliverReceiver.gateInFront" "$(body "$SD" 'static boolean gateInFront()' '    ')" "$(cat <<'PIN'
    static boolean gateInFront() {
        try {
            return android.app.ActivityManager.getCurrentUser() == 0;
        } catch (Throwable t) {
            return false;
        }
    }
PIN
)"
AGA="$(body "$SD" 'private static void alertGateArrival(Context ctx)' '    ')"
if [ "$(code "$AGA" | grep -m1 -E 'getSystemService|vibrate|Ringtone|gateInFront' | grep -cF 'if (!gateInFront()) return;')" = 1 ]; then ok "the gate alert returns before any buzz or chime unless the gate is in front"; else no "the gate alert can buzz or chime while a session is in front (a stranger feels the owner's line)"; fi
if has "$(body "$SD" 'static boolean gateInFront()' '    ')" 'return false;'; then ok "a foreground check that cannot answer stays silent"; else no "a foreground check that cannot answer buzzes"; fi

echo
echo "== the gate's notices are named and drawn by kind: a message as a message, a call as a call (NWP-20261010-13, NWP-20261123-24) =="
PM=$(body "$SD" 'private static void postMessageNotice(Context ctx, String label, String kind, int callType, String number)' '    ')
SUBST='if (substituteAppName(kind) != null) nx.putString(EXTRA_SUBST_APP_NAME, substituteAppName(kind));'
if has "$L" "$SUBST" && [ "$(line "$L" "$SUBST")" -lt "$(line "$L" '.addExtras(nx)')" ]; then ok "the loss notice carries the substitute name, set before its extras are added"; else no "the loss notice is not named Messages (it shows the chooser's label, Profile)"; fi
if has "$PM" "$SUBST" && [ "$(line "$PM" "$SUBST")" -lt "$(line "$PM" 'b.addExtras(nx);')" ]; then ok "the gate notice carries the substitute name, set before its extras are added"; else no "the gate notice is not named Messages (it shows the chooser's label, Profile)"; fi
if has "$(cat "$SD")" 'static final String EXTRA_SUBST_APP_NAME = "android.substName";'; then ok "the extra is Notification.EXTRA_SUBSTITUTE_APP_NAME's value"; else no "the substitute-name extra is not android.substName -- the framework ignores it"; fi
if has "$(body "$SD" 'static String substituteAppName(String kind)' '    ')" 'return "call".equals(kind) ? "Phone" : "Messages";'; then ok "a message is named Messages, a call is named Phone"; else no "the substitute name is wrong for a message or a call"; fi
if [ "$(grep -cF '<uses-permission android:name="android.permission.SUBSTITUTE_NOTIFICATION_APP_NAME"/>' "$AM")" = 1 ]; then ok "the chooser requests SUBSTITUTE_NOTIFICATION_APP_NAME"; else no "SUBSTITUTE_NOTIFICATION_APP_NAME is not requested -- the framework strips the name with only a log line"; fi
ICON='.setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message)'
if has "$L" "$ICON" && has "$PM" "$ICON" && ! has "$(cat "$SD")" 'sym_action_email'; then ok "the loss and gate notices draw a handset for a call and the white envelope otherwise, and the legacy glyph is gone"; else no "a gate notice draws the envelope for a call, or the legacy sym_action_email glyph"; fi

echo
echo "== a resume clears only the resuming profile's own lines, after the switch lands (NWP-20261017-10) =="
RES=$(awk 'index($0, "String reply = sendDaemon(\"RESUME") { on = 1 } on { print } on && index($0, "kickResumeTelingest(appCtx, fuid, 0);") { exit }' "$CA")
SW=$(body "$CA" 'private boolean switchToUser(int uid, java.util.Set<String> ownedLabels)' '    ')
if [ -n "$RES" ] && [ "$(count "$RES" 'cancelTelNotices(')" = 0 ]; then ok "the resume block clears no notice itself, so no clear-all runs before the switch lands"; else no "the resume block calls cancelTelNotices -- it runs before the switch outcome is known and a null clears every line's notice"; fi
if has "$RES" 'final java.util.Set<String> ownedLbls = ownedLabels(nm, pass);' && has "$RES" 'if (switchToUser(fuid, ownedLbls)) {'; then ok "the resume's switch is given the owned-label set of the resuming profile's name and passphrase"; else no "the resume's switch is not given ownedLabels(nm, pass)"; fi
if [ "$(count "$SW" 'cancelTelNotices(')" = 1 ] && has "$SW" 'if (ok) cancelTelNotices(ownedLabels);'; then ok "switchToUser clears its scope only if the switch landed"; else no "switchToUser clears without a landed switch, or more than once"; fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted, with the pins and without them) =="
  M2=$(mktemp -d)
  mutate(){ # mutate <label> <file basename> <sed script>
    rm -rf "$M2/src"; cp -r "$SRC" "$M2/src"; cp "$AM" "$M2/AndroidManifest.xml"
    local f="$M2/src/$2" o="$SRC/$2"; [ "$2" = AndroidManifest.xml ] && { f="$M2/AndroidManifest.xml"; o="$AM"; }
    if ! sed -i "$3" "$f" 2>"$M2/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$o"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M2/src" "$M2/AndroidManifest.xml" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    elif TEL_SEAL_NOPIN=1 bash "$0" "$M2/src" "$M2/AndroidManifest.xml" >/dev/null 2>&1; then no "CONVICTED ONLY BY A PIN: $1 -- no line check holds it"
    else ok "convicted: $1"; fi
  }
  # one arrival, one id and one stamp
  mutate "a text's stamp taken later, not at its arrival"   SmsDeliverReceiver.java 's/TelArrival.smsId(subId, when, from, text), mono);/TelArrival.smsId(subId, when, from, text), TelArrival.stamp());/'
  mutate "the request reassigned in the retry loop"         TelArrival.java '/String line = DaemonSocket.roundTrip(req, timeoutMs);/i\            req = req + "\\n";'
  mutate "a call stamped at its end"                        NowhereInCallService.java 's/final long mono = TelArrival.callStamp(call);/final long mono = TelArrival.stamp();/'
  mutate "a call stamped only once adopted"                 NowhereInCallService.java 's/super.onCallAdded(call); TelArrival.stampCall(call);/super.onCallAdded(call);/'
  mutate "a call's id from the wall clock"                  TelArrival.java 's/return sha256Hex("call\\0" + subId + "\\0" + createdMs);/return sha256Hex("call\\0" + subId + "\\0" + System.currentTimeMillis());/'
  mutate "an MMS's id minted at its download"               MmsDownloadedReceiver.java 's/aid = intent.hasExtra(EXTRA_AID) ? intent.getStringExtra(EXTRA_AID) : /aid = /'
  mutate "an MMS named by its arrival time first"           TelArrival.java 's/String key = txn != null \&\& !txn.isEmpty() ? "t" + txn : /String key = when > 0 ? "w" + when : txn != null \&\& !txn.isEmpty() ? "t" + txn : /'
  # retries
  mutate "an OK retried"                                    TelArrival.java 's/if (!"ERR".equals(last.kind)) return last;/if ("NONE".equals(last.kind)) return last;/'
  mutate "retries never stop"                               TelArrival.java 's/if (stamp() + wait > deadline) return last;/if (false) return last;/'
  mutate "a text's and a call's deadline from the arrival"  SmsDeliverReceiver.java '/static int sealAndNotify(/,/^    }$/s/final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;/final long deadline = mono + TelArrival.SEAL_DEADLINE_MS;/'
  mutate "an MMS's deadline from its push"                  SmsDeliverReceiver.java '/static int sealMmsAndNotify(/,/^    }$/s/final long deadline = TelArrival.stamp() + TelArrival.SEAL_DEADLINE_MS;/final long deadline = mono + TelArrival.SEAL_DEADLINE_MS;/'
  # each reply's meaning
  mutate "OK read by its count"                             SmsDeliverReceiver.java '/^        \/\/ Private (owner opted out) OR gateNotice=false/{n;n;s/return SEAL_SEALED;/return r.label.isEmpty() ? SEAL_NONE : SEAL_SEALED;/}'
  mutate "the OK count field parsed"                        TelArrival.java 's/r.vis = f.length > 1 ? f\[1\] : "open";/r.vis = f.length > 3 ? f[3] : f.length > 1 ? f[1] : "open";/'
  mutate "an unidentified MMS dropped with no notice"       WapPushDeliverReceiver.java 's/                SmsDeliverReceiver.postLossNotice(app, "mms", 0, aid);//'
  mutate "an unidentified MMS downloaded on subscription -1" WapPushDeliverReceiver.java 's/if (subId == SubscriptionManager.INVALID_SUBSCRIPTION_ID) {/if (false) {/'
  mutate "an UNRESOLVED read as a failure"                  SmsDeliverReceiver.java 's/return r == null || "ERR".equals(r.kind) ? SEAL_FAILED : SEAL_UNKEPT;/return SEAL_FAILED;/'
  mutate "the unassigned-SIM notice in the caller's user"   SmsDeliverReceiver.java 's/postMessageNotice(asGate(ctx), UNBOUND_LINE, kind, callType, null);/postMessageNotice(ctx, UNBOUND_LINE, kind, callType, null);/'
  mutate "an unkept arrival leaves no trace"                SmsDeliverReceiver.java 's/(r == null || !"private".equals(r.vis))) postLossNotice(ctx, kind, callType, aid);/(r == null || !"private".equals(r.vis))) { }/'
  mutate "a Private line announced"                         SmsDeliverReceiver.java 's/if (!TelArrival.knownPrivate(iccid) \&\& (r == null || !"private".equals(r.vis))) postLossNotice/if (true) postLossNotice/'
  mutate "REMOVED announced"                                SmsDeliverReceiver.java 's/if ("REMOVED".equals(r.kind)) return SEAL_NONE;/if ("REMOVED".equals(r.kind)) { postLossNotice(ctx, kind, callType, aid); return SEAL_NONE; }/'
  mutate "gateNotice silences the unassigned-SIM notice"    SmsDeliverReceiver.java 's/            postMessageNotice(asGate(ctx), UNBOUND_LINE, kind, callType, null);/            if (gateNotice) postMessageNotice(asGate(ctx), UNBOUND_LINE, kind, callType, null);/'
  # the loss notice
  mutate "the loss notice in the caller's user"             SmsDeliverReceiver.java 's/final Context gate = asGate(ctx);/final Context gate = ctx;/'
  mutate "asGate the caller's own context"                  SmsDeliverReceiver.java 's/try { return ctx.createContextAsUser(android.os.UserHandle.SYSTEM, 0); }/try { return ctx; }/'
  mutate "the loss notice unclassed"                        SmsDeliverReceiver.java 's/nx.putString("nowhere_class", "unsaved");/nx.putString("nowhere_kind2", "unsaved");/'
  mutate "every loss notice under one id"                   SmsDeliverReceiver.java 's/nm.notify(TEL_LOSS_TAG, java.util.Objects.hashCode(aid),/nm.notify(TEL_LOSS_TAG, 1,/'
  mutate "a repeat of one arrival posts a second notice"    SmsDeliverReceiver.java 's/nm.notify(TEL_LOSS_TAG, java.util.Objects.hashCode(aid),/nm.notify(TEL_LOSS_TAG, (int) System.nanoTime(),/'
  mutate "a repeat chimes again"                            SmsDeliverReceiver.java 's/if (LOSS_ANNOUNCED.add(String.valueOf(aid)) \&\& !isCall) alertGateArrival(gate);/if (!isCall) alertGateArrival(gate);/'
  mutate "the chime set unbounded"                          SmsDeliverReceiver.java 's/ if (LOSS_ANNOUNCED.size() >= 4096) LOSS_ANNOUNCED.clear();//'
  mutate "an answered call's loss notice says Missed"       SmsDeliverReceiver.java '/may not have been saved").build());/s/(callType == 1 ? "Incoming call" : "Missed call")/"Missed call"/'
  mutate "a login clears a loss notice"                     ChooserActivity.java '/if (!sbn.getNotification().extras.getString("nowhere_class", "").isEmpty()) continue;/d'
  mutate "a loss notice counted as a call or a message"     ChooserActivity.java 's/if ("true".equals(n\[3\])) c\[2\] += k; else if/if (false) c[2] += k; else if/'
  # the SIM
  mutate "the default SMS SIM guessed again"                SmsDeliverReceiver.java 's/SubscriptionManager.INVALID_SUBSCRIPTION_ID)); \/\/ never the default SIM/SubscriptionManager.getDefaultSmsSubscriptionId())); \/\/ never the default SIM/'
  mutate "the default SIM preset for a call again"          NowhereInCallService.java 's/final int\[\] subOut = { SubscriptionManager.INVALID_SUBSCRIPTION_ID };/final int[] subOut = { SubscriptionManager.getDefaultSubscriptionId() };/'
  mutate "an unidentified SIM given the voice SIM"          TelArrival.java 's/^        return SubscriptionManager.INVALID_SUBSCRIPTION_ID;$/        return SubscriptionManager.getDefaultVoiceSubscriptionId();/'
  mutate "the slot ignored"                                 TelArrival.java 's/int slot = intent.getIntExtra(SubscriptionManager.EXTRA_SLOT_INDEX, -1);/int slot = -1;/'
  mutate "an unidentified SIM given the only active one"    TelArrival.java '/if (si != null) return si.getSubscriptionId();/a\            java.util.List<SubscriptionInfo> l = sm == null ? null : sm.getActiveSubscriptionInfoList(); if (l != null && l.size() == 1) return l.get(0).getSubscriptionId();'
  mutate "a text's SIM only what its intent names"          SmsDeliverReceiver.java 's/final int subId = TelArrival.subIdOr(ctx, intent, intent.getIntExtra("subscription", SubscriptionManager.INVALID_SUBSCRIPTION_ID));/final int subId = intent.getIntExtra("subscription", SubscriptionManager.INVALID_SUBSCRIPTION_ID);/'
  mutate "a WAP push's SIM only what its intent names"      WapPushDeliverReceiver.java 's/final int subId = TelArrival.subIdOr(ctx, intent, intent.getIntExtra("subscription",/final int subId = (intent.getIntExtra("subscription",/'
  # the calls
  mutate "the call scrub waits for the seal"                NowhereInCallService.java '/^                    TelScrub.callLogRetry(app);$/d; s/^                    SmsDeliverReceiver.sealAndNotify(app, "call", subId, iccid, from, when, "", callType, durSec,$/                    TelScrub.callLogRetry(app); SmsDeliverReceiver.sealAndNotify(app, "call", subId, iccid, from, when, "", callType, durSec,/'
  mutate "a call handed off before the exemption"           NowhereCallControlService.java '/String exempt = emergencyExemption(getApplicationContext(), d);/i\                app.sendBroadcastAsUser(new android.content.Intent(app, RejectedCallSealReceiver.class), android.os.UserHandle.SYSTEM);'
  mutate "the decline only when the hand-off works"         NowhereCallControlService.java '/^                call.reject(false, null);$/d; /\.putExtra(RejectedCallSealReceiver.EXTRA_MONO, mono), android.os.UserHandle.SYSTEM);$/a\                    call.reject(false, null);'
  mutate "a rejected call sealed in the stranger's process" NowhereCallControlService.java 's/^                try {$/                new Thread(() -> RejectedCallSealReceiver.seal(app, subId, iccid, from, when, mono)).start();\n                try {/'
  mutate "a rejected call handed to the foreground user"    NowhereCallControlService.java 's/.putExtra(RejectedCallSealReceiver.EXTRA_MONO, mono), android.os.UserHandle.SYSTEM);/.putExtra(RejectedCallSealReceiver.EXTRA_MONO, mono), android.os.UserHandle.of(cur));/'
  mutate "user 0 stamps the call on receipt"                RejectedCallSealReceiver.java 's/mono = intent.getLongExtra(EXTRA_MONO, TelArrival.stamp());/mono = TelArrival.stamp();/'
  mutate "the number not handed over"                       NowhereCallControlService.java 's/.putExtra(RejectedCallSealReceiver.EXTRA_FROM, from).putExtra/.putExtra/'
  mutate "a failed hand-off leaves no trace"                NowhereCallControlService.java 's/ SmsDeliverReceiver.postLossNotice(app, "call", 3, TelArrival.callId(subId, when)); }/ }/'
  mutate "the stranger-session call posts its label"        RejectedCallSealReceiver.java 's/false \/\*gateNotice\*\/, TelArrival.callId(subId, when), mono);/true \/*gateNotice*\/, TelArrival.callId(subId, when), mono);/'
  mutate "user 0 seals on the broadcast's main thread"      RejectedCallSealReceiver.java 's/new Thread(() -> seal(app, subId, iccid, from, when, mono), "nowhere-seal-rejected-call").start();/seal(app, subId, iccid, from, when, mono);/'
  mutate "the seal hand-off receiver exported"              AndroidManifest.xml 's/<receiver android:name=".RejectedCallSealReceiver" android:exported="false"\/>/<receiver android:name=".RejectedCallSealReceiver" android:exported="true"\/>/'
  # the MMS
  mutate "a transaction claimed across SIMs"                WapPushDeliverReceiver.java 's/txn = t0.isEmpty() ? "" : subId + "|" + t0;/txn = t0;/'
  mutate "the download finished after the seal"             MmsDownloadedReceiver.java 's/GenericPdu pdu = new PduParser(body, true).parse(); done.run();/GenericPdu pdu = new PduParser(body, true).parse();/'
  mutate "an answered MMS releases its claim"               MmsDownloadedReceiver.java 's/return outcome != SmsDeliverReceiver.SEAL_FAILED;/return outcome == SmsDeliverReceiver.SEAL_SEALED || outcome == SmsDeliverReceiver.SEAL_NONE;/'
  mutate "a failed MMS keeps its claim"                     MmsDownloadedReceiver.java 's/if (!delivered) WapPushDeliverReceiver.releaseTxn(txn);/if (false) WapPushDeliverReceiver.releaseTxn(txn);/'
  mutate "X1 a failed kick posts nothing"                   WapPushDeliverReceiver.java '/catch (Throwable kick)/,/throw kick;/{/SmsDeliverReceiver.postDownloadLoss(app, subId, aid);/d}'
  mutate "X2 a timeout posts nothing"                       WapPushDeliverReceiver.java '/private static void armDownloadTimeout(/,/^    }$/{/SmsDeliverReceiver.postDownloadLoss(app, subId, aid);/d}'
  mutate "X3 a failed callback posts nothing"               MmsDownloadedReceiver.java '/if (!delivered \&\& !sealStarted.get()) SmsDeliverReceiver.postDownloadLoss(app, subId, aid);/d'
  mutate "X4 the Private rule dropped"                      SmsDeliverReceiver.java 's/if (!TelArrival.knownPrivate(safe(iccidForSub(ctx, subId)))) postLossNotice(ctx, "mms", 0, aid);/postLossNotice(ctx, "mms", 0, aid);/'
  mutate "X5 a started seal posts a second notice"          MmsDownloadedReceiver.java 's/if (!delivered \&\& !sealStarted.get()) SmsDeliverReceiver/if (!delivered) SmsDeliverReceiver/'
  mutate "X6 the timeout posts outside its test"            WapPushDeliverReceiver.java '/private static void armDownloadTimeout(/,/^    }$/{/SmsDeliverReceiver.postDownloadLoss(app, subId, aid);/{N;s/^\([^\n]*\)\n\([^\n]*\)$/\2\n            SmsDeliverReceiver.postDownloadLoss(app, subId, aid);/}}'
  mutate "X7 the flag set at the top of the method"         MmsDownloadedReceiver.java '/^        sealStarted.set(true);$/d; /AtomicBoolean sealStarted) throws Exception {$/a\        sealStarted.set(true);'
  mutate "X8 a delivered MMS posts the loss notice"         MmsDownloadedReceiver.java 's/^        return outcome != SmsDeliverReceiver.SEAL_FAILED;$/        SmsDeliverReceiver.postDownloadLoss(app, subId, aid);\n&/'
  mutate "X9 the log line carries the arrival id"           SmsDeliverReceiver.java 's/known Private");$/known Private " + aid);/'
  # the wire
  mutate "SEAL-TEL v1 again"                                TelArrival.java 's/return "SEAL-TEL\\nv2\\n" + aid + "\\n" + kind/return "SEAL-TEL\\n" + kind/'
  mutate "the sender raw again"                             TelArrival.java 's/+ iccid + "\\n" + b64(from) + "\\n" + when + "\\n"/+ iccid + "\\n" + from + "\\n" + when + "\\n"/'
  mutate "SEAL-MMS v1 again"                                TelArrival.java 's/req.append("SEAL-MMS\\nv2\\n").append(aid)/req.append("SEAL-MMS\\n").append(aid)/'
  mutate "the TelScrub.sms line changed"                    SmsDeliverReceiver.java 's/^            TelScrub.sms(app);$/            TelScrub.sms(app.getApplicationContext());/'
  # owner mode
  mutate "a damaged line not read"                          ChooserActivity.java 's/ else if ("DAMAGED".equals(line.trim())) out.add(TelArrival.DAMAGED_ROW);//'
  mutate "an unreadable file read as busy"                  ChooserActivity.java 's/ if (!lines.isEmpty() \&\& lines.get(0).startsWith("ERR damaged")) return TelArrival.DAMAGED_BINDINGS;//'
  mutate "a damaged line not said"                          ChooserActivity.java 's/ || sums.contains(TelArrival.DAMAGED_ROW)) {/) {/'
  mutate "a damaged line hides the SIMs"                    ChooserActivity.java 's/if (sums == null || sums == TelArrival.DAMAGED_BINDINGS) return;/return;/'
  mutate "an unstorable ICCID read as a failed save"        ChooserActivity.java 's/(sr != null \&\& sr.startsWith("ERR unstorable")) ? "UNSTORABLE" : //'
  mutate "an unbind against an unreadable file says retry"  ChooserActivity.java 's/else StatusLine.error(msg, r != null \&\& r.startsWith("ERR damaged") ? TelArrival.BINDINGS_DAMAGED : /else StatusLine.error(msg, /'
  # an arrival alerts only at the gate
  mutate "the gate alert buzzes whoever is in front"        SmsDeliverReceiver.java '/            if (!gateInFront()) return;/d'
  mutate "an unanswerable foreground check buzzes"          SmsDeliverReceiver.java '/static boolean gateInFront()/,/^    }/s/return false;/return true;/'
  # the notices' name and icon (NWP-20261010-13)
  mutate "the loss notice unnamed"                          SmsDeliverReceiver.java '/nx.putString("nowhere_class", "unsaved");/{n;d}'
  mutate "the gate notice unnamed"                          SmsDeliverReceiver.java '/a message notice is named "Messages", not the chooser.s label/{n;d}'
  mutate "the substitute name set after the extras"         SmsDeliverReceiver.java '/a message notice is named "Messages", not the chooser.s label/{n;h;d}; /^            b.addExtras(nx);$/G'
  mutate "the extra misspelled"                             SmsDeliverReceiver.java 's/static final String EXTRA_SUBST_APP_NAME = "android.substName";/static final String EXTRA_SUBST_APP_NAME = "android.substituteName";/'
  mutate "a call named Messages"                            SmsDeliverReceiver.java 's/return "call".equals(kind) ? "Phone" : "Messages";/return "Messages";/'
  mutate "the substitute-name permission not requested"     AndroidManifest.xml '/<uses-permission android:name="android.permission.SUBSTITUTE_NOTIFICATION_APP_NAME"\/>/d'
  mutate "the legacy glyph back on the gate notice"         SmsDeliverReceiver.java 's/.setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message) \/\/ NWP-20261010-13: a white envelope, not the legacy glyph; NWP-20261123-24: a handset for a call/.setSmallIcon(android.R.drawable.sym_action_email)/'
  mutate "the legacy glyph back on the loss notice"         SmsDeliverReceiver.java 's/.setSmallIcon(isCall ? R.drawable.ic_notif_call : R.drawable.ic_notif_message).setAutoCancel(true).addExtras(nx)/.setSmallIcon(android.R.drawable.sym_action_email).setAutoCancel(true).addExtras(nx)/'
  # a resume's notice clear (NWP-20261017-10)
  mutate "the clear-all restored in the resume block"       ChooserActivity.java '/^                    kickResumeTelingest(appCtx, fuid, 0);$/i\                    cancelTelNotices(null);'
  mutate "switchToUser clears without a landed switch"      ChooserActivity.java 's/if (ok) cancelTelNotices(ownedLabels);/cancelTelNotices(ownedLabels);/'
  mutate "the resume switch given null, not the owned set"  ChooserActivity.java 's/if (switchToUser(fuid, ownedLbls)) {/if (switchToUser(fuid, null)) {/'
  rm -rf "$M2"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
