package com.nowhere.chooser;

import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.telecom.Call;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.util.Base64;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;
import java.util.concurrent.ConcurrentHashMap;

/**
 * NWP-20260930-05: the chooser half of the arrival path (docs/owner-inbox-plan.md, PR C). The daemon half,
 * NWP-20260930-04, answers the v2 SEAL-TEL and SEAL-MMS wire this sends.
 *
 * ONE ARRIVAL, ONE ID. Every attempt at one arrival carries the same arrival id and the same monotonic stamp, so
 * the daemon answers a repeat from its replay table instead of sealing it twice, and resolves the arrival against
 * the SIM links in force when it came in. That is what makes a retry safe: an SMS used to get one attempt, and a
 * call or MMS whose first attempt timed out while it still landed was sealed again under a new name.
 *
 * RETRIED TO A DEADLINE, NOT A COUNT. A refused connect returns at once (DaemonSocket), so a few attempts covered a
 * few seconds; the daemon can be starting, or restarting after a crash, for longer (SEAL_DEADLINE_MS says how
 * much). A reply that is not ERR ends the retries; after the deadline the arrival counts as not kept, and the gate
 * shows the loss notice unless the line is known to be Private (docs/product-decisions.md 2026-09-30, answer 2).
 *
 * WHICH SIM. An arrival whose SIM the platform does not name is NOT given the default SIM any more (a guess could
 * seal one line's arrival to another line's owners). The framework names, on a text's and a WAP push's intent alike,
 * the SIM slot it came in on and that slot's subscription, the subscription only when it is valid
 * (InboundSmsHandler.dispatchIntent). So the subscription named is taken, else the slot's active one, and with neither
 * the arrival goes as unidentified, which the daemon answers UNRESOLVED (subIdOr).
 */
final class TelArrival {
    private TelArrival() {}

    /** How long, from when its seal starts -- a text: its arrival; a call: its end, when it is recorded; an MMS: its
     *  download callback -- the chooser keeps retrying a seal the daemon has not answered. At boot the daemon starts
     *  within about a second of user 0's unlock (lynx, 2026-09-29: its first log line 0.3 s before the unlock
     *  broadcast). A crashed daemon is restarted by init after its restart period, and then listens once its start-up
     *  is done; how long that takes on lynx is not measured yet, and closing docs/backlog.md, "An SMS whose seal times
     *  out is never retried, ...", needs it measured and this deadline checked against it. */
    static final long SEAL_DEADLINE_MS = 60_000L;

    /** GET-BINDINGS answered "ERR damaged": bindings.conf cannot be read at all (the daemon's bindings_check.go). A
     *  sentinel, compared by identity, so the owner-mode screen says so instead of "the phone is busy". */
    static final java.util.List<String[]> DAMAGED_BINDINGS = java.util.Collections.unmodifiableList(new java.util.ArrayList<>());

    /** A row GET-BINDINGS' closing "DAMAGED" line adds to the list: a line of bindings.conf did not read back. */
    static final String[] DAMAGED_ROW = { "", "", "" };

    /** What owner mode says when bindings.conf cannot be read at all: docs/backlog.md, "A damaged line of bindings.conf
     *  leaves its SIM's arrivals unkept, and some damage cannot be repaired from the phone". */
    static final String BINDINGS_DAMAGED = "This phone's SIM bindings file can't be read, so texts and calls to its lines "
            + "can't be kept. Repair SIM bindings, under SIM lines, replaces it.";

    /** ...and when a line of it did not read back. NWP-20261110-06 (Q031): both point at owner mode's "Repair SIM
     *  bindings" (BindingsRepair), which keeps the readable lines and drops the damaged ones; a SIM whose line was
     *  dropped is then bound again -- docs/backlog.md, "A damaged line of bindings.conf ...". */
    static final String BINDING_LINE_DAMAGED = "A SIM binding on this phone is damaged. Repair SIM bindings keeps the "
            + "readable ones; after it, any SIM that lost its binding can be bound again.";

    /** SET-BINDING answered "ERR unstorable": a field would not read back as written, an ICCID holding "|" say. */
    static final String BINDING_UNSTORABLE = "that ICCID can't be saved as entered — check it and try again";

    /** The back-off between attempts: 1, 2 and 4 s, then 8 s until the deadline. */
    static long backoffMs(int attempt) { return attempt >= 3 ? 8_000L : 1_000L << attempt; }

    /** The arrival stamp: SystemClock.elapsedRealtime, the daemon's CLOCK_BOOTTIME. */
    static long stamp() { return SystemClock.elapsedRealtime(); }

    static String smsId(int subId, long when, String from, String body) {
        return sha256Hex("sms\0" + subId + "\0" + when + "\0" + from + "\0" + body);
    }

    static String callId(int subId, long createdMs) {
        return sha256Hex("call\0" + subId + "\0" + createdMs);
    }

    /** An MMS is named by its transaction id, else its content location, else its arrival time. */
    static String mmsId(int subId, String txn, String loc, long when) {
        String key = txn != null && !txn.isEmpty() ? "t" + txn : loc != null && !loc.isEmpty() ? "l" + loc : "w" + when;
        return sha256Hex("mms\0" + subId + "\0" + key);
    }

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

    /** The arrival's subscription: the one the intent names, when valid; else the active subscription of the slot it
     *  names -- a SIM whose subscription came up after the framework looked; else INVALID, which the daemon answers
     *  UNRESOLVED. Never the default SIM. (WapPushOverSms fills in the default SMS SIM for its own parse, but that value
     *  never reaches the intent: GrapheneOS 2026061600, WapPushOverSms.java:259 and InboundSmsHandler.java:1451.) */
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

    // Each call's stamp, taken at its first onCallAdded -- before the #145 re-check can delay adopting it.
    private static final Map<Call, Long> CALL_STAMPS = new WeakHashMap<>();

    static void stampCall(Call call) {
        synchronized (CALL_STAMPS) { if (!CALL_STAMPS.containsKey(call)) CALL_STAMPS.put(call, stamp()); }
    }

    static long callStamp(Call call) {
        synchronized (CALL_STAMPS) { Long s = CALL_STAMPS.get(call); return s == null ? stamp() : s; }
    }

    /** The v2 SEAL-TEL request. */
    static String telRequest(String aid, long mono, String kind, int subId, String iccid, String from, long when,
                             String body, int callType, int durSec) {
        return "SEAL-TEL\nv2\n" + aid + "\n" + kind + "\n" + subId + "\n" + iccid + "\n" + b64(from) + "\n" + when + "\n"
                + mono + "\n" + b64(body) + "\n" + callType + "\n" + durSec + "\n";
    }

    /** The v2 SEAL-MMS request. */
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

    private static String b64(String s) {
        return Base64.encodeToString((s == null ? "" : s).getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    /** One reply of the v2 wire, parsed. kind is the first token: OK, NONE, OWNER, UNRESOLVED, REMOVED, FULL or ERR;
     *  an unknown token reads as NONE. OWNER (Slice D) is an unbound SIM's arrival sealed to the device-owner inbox;
     *  settle treats it like NONE at the gate -- the same notice -- so neither reveals whether it was kept. Either may
     *  carry vis "number", the owner's opt-in. For ERR, vis is set only by "ERR nobody <vis>". */
    static final class Reply {
        String kind = "NONE", vis = "", label = "";
        int liveUid = -1;
        boolean stripped;
        boolean partial;
        long deadline; // elapsedRealtime the seal's retries ran to, set by sealAndNotify and sealMmsAndNotify; 0 = unknown
    }

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
            case "OWNER": case "NONE":
                r.kind = f[0];
                if (f.length > 1) r.vis = f[1];
                break;
            case "UNRESOLVED": case "REMOVED": case "FULL":
                r.kind = f[0];
                if ("FULL".equals(f[0]) && f.length > 1) r.vis = f[1];
                break;
            default:
                r.kind = "NONE";
        }
        return r;
    }

    /** Sends req until the daemon answers something other than ERR, or until deadline (elapsedRealtime) passes.
     *  Returns the last reply parsed, or null when the daemon never answered at all. */
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

    // The dial each line last answered with in this process, by ICCID: a line last seen as Private stays quiet on a
    // failure that got no reply. Lost with the process, and a stale entry can err either way -- the case the
    // 2026-09-30 answer 2 accepted when the line is not known.
    private static final Map<String, String> DIALS = new ConcurrentHashMap<>();

    static void rememberDial(String iccid, String vis) {
        if (iccid != null && !iccid.isEmpty() && vis != null && !vis.isEmpty()) DIALS.put(iccid, vis);
    }

    static boolean knownPrivate(String iccid) {
        return iccid != null && "private".equals(DIALS.get(iccid));
    }
}
