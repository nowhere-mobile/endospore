package com.nowhere.chooser;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.telephony.SmsManager;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;

import java.nio.charset.StandardCharsets;

import com.google.android.mms.pdu.EncodedStringValue;
import com.google.android.mms.pdu.GenericPdu;
import com.google.android.mms.pdu.NotificationInd;
import com.google.android.mms.pdu.PduParser;

/**
 * #135 B3 / #150: WAP_PUSH_DELIVER (MMS) receiver. The chooser is the DEFAULT SMS app on user 0, so an
 * inbound MMS arrives here as a small M-Notification.ind WAP-push carrying only a content-location URL (the
 * body sits on the carrier's MMSC). RECEIVE_MMS (granted, part 1) is what lets this broadcast reach us.
 *
 * #150 strategy B ("gate download"): only user 0 has a valid subId + MMSC config, so the GATE downloads the
 * body over the SIM's MMS APN, then seals it for the bound owner (delivered at their next login) -- the
 * roamed/ephemeral user can never fetch an MMS itself. This mirrors the SMS seal path (SmsDeliverReceiver).
 *
 * The path: parse the notification -> claim its transaction id, so a carrier re-push is skipped -> download the
 * M-Retrieve.conf to an app-private staging file via MmsFileProvider -> (in MmsDownloadedReceiver) parse it into
 * RAM, DELETE the staging file, and seal it with SEAL-MMS (P2), which keeps or releases the claim by the seal's
 * outcome. Nothing readable persists on user 0.
 *
 * onReceive must return fast (main thread); parse + the download kick run on a worker thread.
 */
public final class WapPushDeliverReceiver extends BroadcastReceiver {

    static final String MMS_SERVICE_PKG = "com.android.phone"; // MmsService runs here (uid 1001)

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

    /** Parse the M-Notification.ind and kick a gate-side download of the body over the SIM's MMS APN. */
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

    // #150: cleanup coordination for gate MMS downloads lives in MmsInFlight: one token per live download so its
    // staging body + MMS-PDN ref are released EXACTLY ONCE -- by whichever of {completion callback, timeout}
    // runs first -- and a per-subId ref count of the (subscription-persistent) MMS_ALWAYS_ALLOWED policy so each
    // sub's mms PDN stays up only while one of ITS downloads is in flight. The policy call runs under
    // MmsInFlight's lock, so one SIM's on and off can never land out of order.
    private static final long DOWNLOAD_TIMEOUT_MS = 90_000;  // MMS PDN bring-up + fetch; generous for a flaky SIM
    private static final long STALE_STAGING_MS = 5 * 60_000; // a staging file untouched this long is orphaned

    // #150: de-dup carrier RE-PUSHES of the same M-Notification.ind. We send no M-NotifyResp.ind, so the MMSC
    // re-pushes the notification until the MMS expires -- great for RETRY (a failed download gets another go),
    // but without idempotency a SUCCESSFUL download would be re-fetched + re-sealed + re-delivered on every
    // re-push (deliverMms dedups on arrival-ms, which differs per re-push). Keyed on the transaction-id:
    // CLAIMED at receipt (so a re-push while one download is in flight is skipped) and KEPT after delivery (so
    // later re-pushes are skipped); RELEASED on a download failure so the NEXT re-push retries. Cleared with
    // the process (gate reboot); a long window (MmsInFlight.TXN_WINDOW_MS) bounds memory to the handful of MMS
    // in a boot session.

    /** Claim a transaction-id for this download attempt. Returns true if newly claimed (proceed), false if it
     *  is already in flight or was recently delivered (a duplicate re-push to skip). Prunes stale entries. */
    private static boolean claimTxn(String txn) {
        return MmsInFlight.claimTxn(txn, System.currentTimeMillis());
    }

    /** Release a transaction-id after a FAILED download so the carrier's next re-push retries it. No-op on
     *  success (the claim is intentionally kept, to dedup future re-pushes of the delivered MMS). */
    static void releaseTxn(String txn) {
        MmsInFlight.releaseTxn(txn);
    }

    /** Hex of the M-Notification.ind transaction-id (the MMSC's stable id for this message across re-pushes),
     *  or "" if absent -- in which case we can't dedup and fall through to downloading (never drop an MMS). */
    private static String txnId(NotificationInd n) {
        try {
            byte[] t = n.getTransactionId();
            if (t == null || t.length == 0) return "";
            StringBuilder sb = new StringBuilder(t.length * 2);
            for (byte x : t) {
                sb.append(Character.forDigit((x >> 4) & 0xF, 16)).append(Character.forDigit(x & 0xF, 16));
            }
            return sb.toString();
        } catch (Throwable t) { return ""; }
    }

    static void setMmsAlwaysAllowed(Context app, int subId, boolean on) {
        try {
            TelephonyManager tm = app.getSystemService(TelephonyManager.class).createForSubscriptionId(subId);
            tm.setMobileDataPolicyEnabled(TelephonyManager.MOBILE_DATA_POLICY_MMS_ALWAYS_ALLOWED, on);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "#150 MMS_ALWAYS_ALLOWED policy=" + on, t);
        }
    }

    private static MmsInFlight.Policy policy(Context app) {
        return (s, on) -> setMmsAlwaysAllowed(app, s, on);
    }

    /** NWP-20261110-15: at a user-0 process start, switch MOBILE_DATA_POLICY_MMS_ALWAYS_ALLOWED off on every active
     *  SIM with no download in flight. The policy outlives the process and the ref count (MmsInFlight) does not: a
     *  chooser that died inside a download's 90 s window (a crash, a low-memory kill, power loss) left the owner's
     *  SIM with its MMS PDN allowed, across reboots, until the next full download on that SIM. Session users'
     *  chooser processes return at once: one device-wide owner of the SIM policy. Logs counts only, never a
     *  subscription identifier, and a failure by its class name only. */
    static void resetIdlePolicies(Context app) {
        if (android.os.UserHandle.myUserId() != 0) return;
        try {
            SubscriptionManager sm = app.getSystemService(SubscriptionManager.class);
            java.util.List<android.telephony.SubscriptionInfo> subs = sm == null ? null : sm.getActiveSubscriptionInfoList();
            if (subs == null || subs.isEmpty()) return;
            java.util.List<Integer> ids = new java.util.ArrayList<>(subs.size());
            for (android.telephony.SubscriptionInfo si : subs) ids.add(si.getSubscriptionId());
            int n = MmsInFlight.resetIdle(ids, policy(app));
            android.util.Log.i("NowhereChooser", "#150 MMS data policy reset at process start: " + n + " of "
                    + ids.size() + " SIM(s)");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "#150 MMS data policy reset at process start failed: "
                    + t.getClass().getName());
        }
    }

    /** Clean up ONE gate MMS download exactly once (whoever wins MmsInFlight's token): delete the cleartext
     *  staging body, revoke the MmsService's Uri grant, and release the MMS-PDN ref. Idempotent + safe to call
     *  from both the completion receiver (MmsDownloadedReceiver) and the timeout backstop. Returns true only
     *  for the caller that finished the download. {@code subId} is unused: MmsInFlight releases the SIM the
     *  download registered with. */
    static boolean finishDownload(Context app, String name, String uriStr, int subId) {
        if (name == null || !MmsInFlight.finish(name, policy(app))) return false; // already finished (or never registered)
        try { new java.io.File(MmsFileProvider.stagingDir(app), name).delete(); } catch (Throwable ignore) {}
        try {
            if (uriStr != null) app.revokeUriPermission(Uri.parse(uriStr),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } catch (Throwable ignore) {}
        return true;
    }

    /** If the download-complete callback never fires (MMS PDN never comes up -> the documented silent timeout),
     *  clean up anyway so the cleartext staging body never lingers on user 0's disk, and leave the loss notice. */
    private static void armDownloadTimeout(Context app, String name, String uriStr, int subId, String txn, String aid) {
        new Thread(() -> {
            try { Thread.sleep(DOWNLOAD_TIMEOUT_MS); } catch (InterruptedException ignore) { return; }
            if (finishDownload(app, name, uriStr, subId)) {
                android.util.Log.w("NowhereChooser", "#150 MMS download timed out (no callback); sweeping staging");
                releaseTxn(txn); // a timeout is a failure -> free the txn so the next re-push retries
                SmsDeliverReceiver.postDownloadLoss(app, subId, aid); // only here: a callback that finished it posts nothing more
            }
        }).start();
    }

    /** Delete staging bodies from downloads that never completed this boot (older than STALE_STAGING_MS) so a
     *  crash between body-write and cleanup can't leave cleartext MMS on user 0's disk. Only touches files old
     *  enough to be certainly orphaned, never an in-flight download. */
    private static void sweepStaleStaging(Context app) {
        try {
            java.io.File[] files = MmsFileProvider.stagingDir(app).listFiles();
            if (files == null) return;
            long cutoff = System.currentTimeMillis() - STALE_STAGING_MS;
            for (java.io.File f : files) {
                if (f.lastModified() < cutoff) { try { f.delete(); } catch (Throwable ignore) {} }
            }
        } catch (Throwable ignore) {}
    }

    static String safe(String s) { return s == null ? "" : s; }

    /** Log only the shape of PII (length + a short prefix), never the full sender/URL in the clear. */
    static String redact(String s) {
        if (s == null || s.isEmpty()) return "<empty>";
        int keep = Math.min(4, s.length());
        return s.substring(0, keep) + "…(" + s.length() + ")";
    }
}
