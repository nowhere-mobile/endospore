package com.nowhere.chooser;

import android.content.Context;
import android.net.Uri;
import android.provider.CallLog;
import android.util.Log;

/**
 * #135 B5: the telephony janitor. Keeps user 0's telephony providers EMPTY of readable content, except the
 * SMS `raw` reassembly table (below), so the non-amnesiac gate leaves no SMS/MMS/call trace. The record the
 * OWNER sees is rebuilt from the sealed tmpfs inbox at their next login (roamd telingest), so user 0's sms,
 * mms and call-log rows are never a delivery path: deleting them loses nothing and closes the leak. user 0
 * has ZERO legitimate telephony history (the gate sends nothing; a roamed session's messages/calls live in
 * that user and are wiped at logoff), so a blanket delete-all of THOSE rows is always correct here.
 *
 * The `raw` table is the exception (NWP-20260927-10). It IS a delivery path: the framework reassembles a
 * text from its rows before SMS_DELIVER reaches us, so a blanket delete there loses texts -- the segments
 * of any text still arriving, likeliest in the power-on burst. sms() says what it removes, and when.
 *
 * This is the APP-side half (runs as user 0 with the default-SMS-app + WRITE_CALL_LOG grants, through the
 * providers). The SECURE-ERASE half -- collapsing the deleted rows' freed pages so nothing survives in the
 * db file -- is the per-boot su:s0 sqlite3 VACUUM in nowhere_gate.sh (the app can't VACUUM via a provider).
 * Together: prevent (SMS: we own+skip the inbox write, B3) + delete (here) + secure-erase + per-boot
 * backstop (nowhere_gate.sh). See docs/telephony-owner-mode.md.
 */
final class TelScrub {
    private TelScrub() {}

    private static final Uri SMS = Uri.parse("content://sms");
    // The multipart reassembly buffer, through the one URI that REMOVES rows. A delete on content://sms/raw only
    // sets deleted=1 (SmsProvider, SMS_RAW_MESSAGE), and the framework reassembles only rows with deleted=0.
    private static final Uri SMS_RAW_PERMANENT = Uri.parse("content://sms/raw/permanentDelete");
    // The same table, for ONE read-only query (rawSegmentAge). Never a delete target: a delete here only marks every
    // row deleted=1, which is how the old blanket scrub lost the segments of a text still arriving.
    private static final Uri SMS_RAW = Uri.parse("content://sms/raw");
    // sms() runs on three threads (SmsDeliverReceiver's worker, the gate's resume scrub thread, BootReceiver):
    // one scan at a time, so two cannot interleave the read of the record and its rewrite.
    private static final Object RAW_AGE_LOCK = new Object();
    // How long the framework keeps a dispatched segment to discard a network re-send of it as a duplicate:
    // SmsProvider.RAW_MESSAGE_EXPIRE_AGE_MS, measured against the raw row's `date`, the SMSC timestamp.
    private static final long RAW_DEDUP_WINDOW_MS = 3_600_000L;
    private static final Uri MMS = Uri.parse("content://mms");         // #150: the MMS pdu table (+ parts/files)

    /** Delete every user-0 CallLog row. Best-effort + idempotent; needs WRITE_CALL_LOG (pre-granted). A
     *  SecurityException / SQLiteException (db busy) must never crash the caller. */
    static void callLog(Context ctx) {
        try { ctx.getContentResolver().delete(CallLog.Calls.CONTENT_URI, null, null); } catch (Throwable ignore) {}
    }

    /** Beat the framework's async call-log write around onCallRemoved: delete now, keep deleting ~1.2s. MUST
     *  run on a worker thread (it sleeps). */
    static void callLogRetry(Context ctx) {
        for (int i = 0; i < 8; i++) {
            callLog(ctx);
            try { Thread.sleep(150); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); return; }
        }
    }

    /** Delete every user-0 SMS row, and the reassembly rows the framework no longer needs. As the default SMS app
     *  we may delete content://sms; the reassembly table is best-effort, and this is its only scrub -- the su:s0
     *  per-boot janitor leaves it alone (NWP-20260927-10). B3 already SKIPS the inbox write, so this clears
     *  reassembly residue + any stray write, not our own persisted messages.
     *
     *  NWP-20260927-10: a raw row goes only when the framework has marked it deleted=1 (its message was
     *  dispatched) AND its SMSC timestamp is past the framework's one-hour duplicate window. The framework keeps a
     *  dispatched segment that hour on purpose (InboundSmsHandler: "keep in db for message de-duping"): the
     *  network re-sends a text whose acknowledgement it lost, the re-send matches the kept row and is discarded,
     *  and without the row it is delivered, sealed and noticed a second time. SmsProvider purges the same rows at
     *  the same age, but only on its next raw-table query; this also does it after every text, on every gate
     *  onResume and at boot.
     *
     *  Q033 (decided 2026-10-20, NWP-20261108-10): a row still at deleted=0 is a segment waiting for its siblings,
     *  and nothing can tell a slow sibling from one that will never come, so it goes 24 hours after the gate FIRST
     *  SAW it (rawSegmentAge). Never on `date`, which is the SMSC timestamp: a text the network held while the phone
     *  was off arrives already old. The accepted loss: a text whose segments arrive more than a day apart. A loss
     *  Q033 does NOT name, asked of Chester in the NWP-20261108-10 PR: deleted = 0 also selects a complete text the
     *  framework stored but never dispatched (one stranded at a power loss, say). On lynx such a text waits for the
     *  framework's day-in-service rescan (docs/backlog.md, "At boot the framework scans for undelivered texts before
     *  the SIMs are ready, so on lynx that scan delivers none of them"), and this 24 h window usually removes it
     *  before that rescan runs, so it is never delivered. The selection stays as it is until he answers.
     *  (superseded by NWP-20261115-07, #36 2026-10-22: complete texts are excluded and only orphan segments go)
     *  Before this a segment that never completed stayed, across reboots, until the framework expired it -- at a boot seven
     *  days after its SMSC timestamp by default (SmsBroadcastUndelivered), or after a day in service within one boot
     *  (SmsDispatchersController) -- and until then could be spliced into a later text from the same sender that
     *  reuses its reference number (docs/backlog.md, "A multipart segment whose siblings never arrive keeps its
     *  cleartext on user 0, across power-offs, until the framework expires it").
     *  Before this, the scrub deleted content://sms/raw with no selection. That removes no row -- it marks EVERY
     *  row deleted=1 -- so it also marked the segments of any OTHER multipart text still being reassembled, which
     *  the framework had already acknowledged to the network and then never reassembled: that text never reached
     *  SmsDeliverReceiver, with no record and no notice. */
    static void sms(Context ctx) {
        try { ctx.getContentResolver().delete(SMS, null, null); } catch (Throwable ignore) {}
        final String[] cutoff = { Long.toString(System.currentTimeMillis() - RAW_DEDUP_WINDOW_MS) };
        try { ctx.getContentResolver().delete(SMS_RAW_PERMANENT, "deleted = 1 AND date < ?", cutoff); } catch (Throwable ignore) {}
        rawSegmentAge(ctx);
    }

    /** Q033: remove a waiting raw row 24 hours after the gate first saw it. User 0 only: the record is user 0's
     *  chooser files (`nowhere-rawseen`, row ids and first-sight times, no content), which survive a reboot and
     *  never roam. The clock is the wall clock on purpose -- first sight must outlive a power-off, which a monotonic
     *  clock cannot. Any failure (a refused or failed query, an unreadable record) removes nothing and leaves the
     *  record as it was; a missing record reads as empty, so every waiting row is stamped now. The provider's raw
     *  query also purges deleted=1 rows past the hour, the same rule sms() applies above. One log line, counts only.
     *
     *  Residuals: a row id SQLite reuses before any scan saw the old row go inherits the old stamp (each scan drops
     *  ids no longer waiting, and every delivered text runs one); a wall clock wrong-early at first sight and
     *  corrected forward later can remove a segment early; and while any SIM is linked to the gate user, this raw
     *  query sees only the SIMs linked to it (sms-raw-no-sim-filter.sh unfilters only the phone and the system, and
     *  the chooser is neither), so an orphan on a SIM hidden from user 0 is never seen, stamped or removed while
     *  that link stands (docs/backlog.md, "While any SIM is linked to the gate user, the gate's own SMS and MMS
     *  scrubs, and most sends at the gate, see only the SIMs linked to it"). */
    private static void rawSegmentAge(Context ctx) {
        if (android.os.UserHandle.myUserId() != 0) return;
        synchronized (RAW_AGE_LOCK) {
            try {
                final android.content.ContentResolver cr = ctx.getContentResolver();
                final java.io.File rec = new java.io.File(ctx.getFilesDir(), "nowhere-rawseen");
                String old = "";
                if (rec.exists()) {
                    old = new String(java.nio.file.Files.readAllBytes(rec.toPath()), java.nio.charset.StandardCharsets.UTF_8);
                }
                final java.util.List<RawSegmentAge.Row> rows = new java.util.ArrayList<>();
                final String[] cols = { "_id", "address", "reference_number", "count", "sequence", "destination_port" };
                try (android.database.Cursor c = cr.query(SMS_RAW, cols, "deleted = 0", null, null)) {
                    if (c == null) return;
                    while (c.moveToNext()) {
                        rows.add(new RawSegmentAge.Row(c.getLong(0), c.isNull(1) ? null : c.getString(1),
                                c.isNull(2) ? null : c.getInt(2), c.isNull(3) ? null : c.getInt(3),
                                c.isNull(4) ? null : c.getInt(4), c.isNull(5) ? null : c.getInt(5)));
                    }
                }
                final java.util.List<Long> waiting = RawSegmentAge.orphans(rows);
                final RawSegmentAge.Plan p = RawSegmentAge.plan(RawSegmentAge.parse(old), waiting, System.currentTimeMillis());
                int removed = 0;
                for (long id : p.remove) {
                    try {
                        removed += cr.delete(SMS_RAW_PERMANENT, "_id = ? AND deleted = 0", new String[] { Long.toString(id) });
                    } catch (Throwable ignore) {}
                }
                final String now = RawSegmentAge.format(p.record);
                if (!now.equals(old)) {
                    final java.io.File tmp = new java.io.File(rec.getParentFile(), rec.getName() + ".tmp");
                    boolean ok = false;
                    try (java.io.FileOutputStream out = new java.io.FileOutputStream(tmp)) {
                        out.write(now.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                        out.getFD().sync();
                        ok = true;
                    } catch (java.io.IOException ignore) {}
                    if (!ok || !tmp.renameTo(rec)) tmp.delete();
                }
                if (!rows.isEmpty() || removed > 0) {
                    Log.i("NowhereChooser", "rawseen: waiting=" + waiting.size() + " complete=" + (rows.size() - waiting.size())
                            + " stamped=" + p.stamped + " removed=" + removed);
                }
            } catch (Throwable t) {
                Log.i("NowhereChooser", "rawseen: skipped " + t.getClass().getSimpleName());
            }
        }
    }

    /** #150: delete every user-0 MMS row. In practice user 0's content://mms stays EMPTY -- the gate downloads
     *  an inbound MMS to a staging FILE and seals it (a parser-only path; no PduPersister ever writes the
     *  provider) -- so this is defense-in-depth against a stray write, exactly like sms(). Deleting via the
     *  MmsProvider (we are the default SMS app on user 0) cascades to the `part` rows AND their on-disk
     *  app_parts/PART_* payload files, which a raw sqlite DELETE would orphan (why nowhere_gate.sh also rm's
     *  the part store). Runs app-side at gate return + boot, so it closes the window BEFORE the next per-boot
     *  su:s0 janitor rather than relying on it alone. */
    static void mms(Context ctx) {
        try { ctx.getContentResolver().delete(MMS, null, null); } catch (Throwable ignore) {}
    }

    /** The general gate/boot backstop: scrub call log, SMS, and MMS. */
    static void all(Context ctx) {
        callLog(ctx);
        sms(ctx);
        mms(ctx);
    }
}
