package com.nowhere.chooser;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

import com.google.android.mms.pdu.EncodedStringValue;
import com.google.android.mms.pdu.GenericPdu;
import com.google.android.mms.pdu.MultimediaMessagePdu;
import com.google.android.mms.pdu.PduBody;
import com.google.android.mms.pdu.PduParser;
import com.google.android.mms.pdu.PduPart;
import com.google.android.mms.pdu.RetrieveConf;

/**
 * #150 fires when SmsManager.downloadMultimediaMessage finishes fetching the M-Retrieve.conf body into our
 * app-private staging file (WapPushDeliverReceiver + MmsFileProvider). Reads and parses it, UNLINKS the staging
 * file + revokes the MmsService's Uri grant as soon as the body is in RAM, then SEALS it to the SIM's bound
 * owner(s) (SmsDeliverReceiver.sealMmsAndNotify -> daemon SEAL-MMS, retried to TelArrival.SEAL_DEADLINE_MS) and
 * raises the notice its reply calls for. Nothing readable persists on user 0 -- the amnesia posture: the
 * cleartext body exists only in RAM, from the download to the seal's answer, exactly like an inbound SMS.
 *
 * onReceive returns fast; the parse + seal run on a worker thread. goAsync() holds the broadcast until the body
 * is parsed; the seal's retries then run on in the gate's process, which is persistent.
 */
public final class MmsDownloadedReceiver extends BroadcastReceiver {

    static final String EXTRA_NAME  = "nowhere.mms.name";
    static final String EXTRA_URI   = "nowhere.mms.uri";
    static final String EXTRA_SUBID = "nowhere.mms.subid";
    static final String EXTRA_WHEN  = "nowhere.mms.when";
    static final String EXTRA_FROM  = "nowhere.mms.from";
    static final String EXTRA_TXN   = "nowhere.mms.txn", EXTRA_AID = "nowhere.mms.aid", EXTRA_MONO = "nowhere.mms.mono"; // #150; NWP-20260930-05

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
        new Thread(() -> {
            boolean delivered = false;
            try {
                delivered = sealDownloaded(app, result, httpStatus, staged, subId, when, fromHint, done, aid, mono);
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
            }
        }).start();
    }

    /** Returns true when the daemon answered the seal -- kept, unbound (now sealed to the device-owner inbox, Slice D),
     *  unassigned since, UNRESOLVED or FULL -- so the transaction-id claim is kept: it answers a repeat of this arrival id
     *  the same (its replay table). False on a download or parse failure, or a seal that failed, so a re-push retries. */
    private static boolean sealDownloaded(Context app, int result, int httpStatus, File staged, int subId, long when,
                                          String fromHint, Runnable done, String aid, long mono) throws Exception {
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
        int outcome = SmsDeliverReceiver.sealMmsAndNotify(app, subId, from, when, subject, parts, aid, mono);
        android.util.Log.i("NowhereChooser", "#150 MMS sealed: from=" + WapPushDeliverReceiver.redact(from)
                + " parts=" + parts.size() + " totalBytes=" + totalBytes + " outcome=" + outcome);
        // Only a seal that failed (ERR, or no answer) lets a re-push retry: re-downloading an answered one gets the same answer.
        return outcome != SmsDeliverReceiver.SEAL_FAILED;
    }

    private static String esv(EncodedStringValue v) {
        return v == null ? "" : WapPushDeliverReceiver.safe(v.getString());
    }

    private static String bytesToStr(byte[] b) {
        return b == null ? "" : new String(b, StandardCharsets.ISO_8859_1);
    }
}
