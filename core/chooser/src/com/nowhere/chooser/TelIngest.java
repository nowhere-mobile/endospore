package com.nowhere.chooser;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import java.util.List;

/**
 * #135 delivery v2: insert this session's decrypted telephony inbox (calls/SMS that arrived while the
 * profile was away, sealed at the gate, decrypted by the agent at roam-in) into the roamed user's OWN
 * SMS/CallLog providers.
 *
 * This runs IN the roamed user (started via CredentialService at login) because the previous deliverer --
 * the su:s0 roamd worker doing cross-user `content insert` -- structurally cannot know whether a row
 * landed: DIA-56 denies capturing cmd output (a query read-back is blind) and `content insert` exits 0
 * even when the provider drops the row. That blindness either lost the call-log record (provider DB not
 * settled right after roam-in) or duplicated the SMS (#360's blind retry -> 15 copies). Here we are a
 * normal app in the target user: our ContentResolver query WORKS, so every insert is verify-first
 * (idempotent, keyed on the unique arrival-ms date) and can retry safely.
 *
 * Delivery runs THREE passes (after an initial settle delay): the roam-in E2E showed a row can vanish
 * AFTER an apparently-successful insert (the provider DB is being settled/clobbered during session
 * bring-up -- roamd's warmed insert was lost even though an identical one minutes later persisted), so a
 * verified row is re-verified -- and re-inserted if gone -- on the later passes. Best-effort by contract:
 * the buffer is ACKed (dropped) after the passes either way; it is session-scoped tmpfs.
 */
final class TelIngest {
    private static final long SETTLE_MS = 20_000;               // initial wait: let grant/seed/restore churn pass
    private static final long[] REVERIFY_MS = {15_000, 45_000}; // later passes catch a clobbered-after-insert row
    private static final int MAX_TEL_RETRIES = 3;               // #135 Part 3: cap RESTAGE re-attempts of a call that won't persist
    private static final String MESSAGING = "com.android.messaging"; // the roamed default SMS app (the #148 cede)

    // NWP-20261010-13: there is no record here of which notices are showing. The tag of each message notice names its
    // row (noticeTag), and MessagingSuppressor clears the read (or deleted) ones all session (clearReadNotices). This
    // used to be two static maps drained by a read-watch that gave up after 3 minutes and lived only as long as the
    // delivery worker, and each run's finally cleared BOTH maps, so a second text inside those 3 minutes lost its
    // tracking when the first watch ended. A text read later than that kept its notice for the rest of the session.

    private TelIngest() {}

    /** NWP-20261019-27: which token of a claimed row carries its retry count, or -1 for a row this loop does not
     *  re-stage. calls=true is the call-log loop (a "call" row of 6+ tokens: deliver() reads f[0..5], retry is f[6]);
     *  calls=false is the SMS/MMS loop (sms: 6 fields then the retry; mms: 3 fields then the retry). A call row is never
     *  taken by the SMS/MMS loop, or a missing call would be re-staged twice and land twice in the call log. */
    static int restageBase(String[] f, boolean calls) {
        if (calls) return f.length >= 6 && "call".equals(f[0]) ? 6 : -1;
        if ("sms".equals(f[0]) && f.length >= 6) return 6;
        if ("mms".equals(f[0]) && f.length >= 3) return 3;
        return -1;
    }

    /** The row to hand back to the daemon: f[0..base-1] verbatim (a call's f[5] "-<simTag>" included) plus the retry
     *  count + 1, or null once the count has reached maxRetries. A retry token that does not parse counts as 0. */
    static String restageLine(String[] f, int base, int maxRetries) {
        int retry = 0;
        if (f.length > base) { try { retry = Integer.parseInt(f[base]); } catch (Throwable ignore) {} }
        if (retry >= maxRetries) return null;
        StringBuilder row = new StringBuilder(f[0]);
        for (int k = 1; k < base; k++) row.append(' ').append(f[k]);
        return row.append(' ').append(retry + 1).toString();
    }

    // NWP-20261112-21: what a delivery does with a row, from its pre-insert lookup (exists / mmsExists).
    static final int DONE = 0;   // the row is there: verified, nothing to insert
    static final int INSERT = 1; // the lookup completed and found no row: insert it
    static final int RETRY = 2;  // the lookup did not complete: insert nothing; the next pass or sign-in asks again

    /** NWP-20261112-21: TRUE -> DONE, FALSE -> INSERT, null (the lookup did not complete) -> RETRY. Never unboxes. */
    static int rowStep(Boolean present) {
        if (Boolean.TRUE.equals(present)) return DONE;
        if (Boolean.FALSE.equals(present)) return INSERT;
        return RETRY;
    }

    /** NWP-20261112-21: the post-insert read-back. Only TRUE stands in for a null insert result; a lookup that did not
     *  complete (null) counts in unknown, like every other lookup site, and is not ok. Never unboxes. */
    static boolean readBack(Boolean present, int[] unknown) {
        if (present == null) unknown[0]++;
        return Boolean.TRUE.equals(present);
    }

    /** Fetch this user's staged rows from the daemon, insert-with-verify into our own providers, ack.
     *  live=false is the roam-in path (wait out session bring-up, then re-verify across passes). live=true
     *  (#149) is a text/call that arrived while this session is already up and running: insert immediately,
     *  no settle, single pass, and post an in-session notification so a message the user is waiting for pings. */
    static void run(Context ctx, boolean live) {
        // CLAIM the staged rows FIRST (GET-TELINGEST atomically takes the mailbox on the daemon side), THEN,
        // for a login (non-live) delivery, wait out session bring-up and re-verify. Claiming before the settle
        // is what makes a live SMS arriving during that window land in a FRESH mailbox delivered by its OWN
        // run -- so it can neither eat this login's backlog nor post a notification for every backlog row.
        List<String> reply = DaemonSocket.roundTripLines("GET-TELINGEST\n", 10_000);
        if (reply.isEmpty() || !reply.get(0).startsWith("OK") || reply.size() < 2) return;
        ensureSmsWrite(ctx);     // #149: cede moved OP_WRITE_SMS to Messaging; re-grant it so our insert lands.
        ensureCallLogGrant(ctx); // #135: grant our own CALL_LOG in this roamed user so the call insert lands.
        ensureSmsRead(ctx);      // NWP-20261006-07: so a resent text is found in Messages, not inserted twice.
        ensureReadRestrictedMessages(ctx); // #150: needed to write MMS part data (MmsProvider.openFile restricted-read).
        ensureNotificationListener(ctx); // task_c272758a (force-ours): our listener cancels Bugle's duplicate SMS notice
        if (!live) { try { Thread.sleep(SETTLE_MS); } catch (InterruptedException ignored) { return; } }
        int verified = 0;
        // insertedThisRun: SMS/MMS dedup across the 3 passes (#371) -- the in-memory guard, kept for an image or
        // session where the read grant below did not take. Since NWP-20261006-07 the chooser reads its own
        // Messages back (ensureSmsRead), so a text that is ALREADY there -- from an earlier session whose
        // acknowledgement was lost, NWP-20261006-05 -- is found and not inserted again. CALL rows do NOT use it
        // (a completed exists() is authoritative via READ_CALL_LOG), so their re-verify passes re-check + re-insert a
        // dropped row. notified: post each missed-call notice once, independent of re-inserts. unknown (NWP-20261112-21):
        // how many row lookups this run did not complete -- counted for the log line after the final acknowledgement.
        final java.util.Set<Long> insertedThisRun = new java.util.HashSet<>();
        final java.util.Set<Long> notified = new java.util.HashSet<>();
        final int[] unknown = new int[1];
        final int passes = live ? 1 : REVERIFY_MS.length + 1; // login: settle + 2 re-verifies; live: once
        final boolean[] everOk = new boolean[reply.size()]; // NWP-20261005-15: did this row land on ANY pass
        final boolean[] acked = new boolean[reply.size()];  // NWP-20261006-05: its sealed copy released
        for (int pass = 0; pass < passes; pass++) {
            verified = 0;
            for (int i = 1; i < reply.size(); i++) {
                if (deliver(ctx, reply.get(i), insertedThisRun, notified, unknown)) { verified++; everOk[i] = true; }
            }
            // NWP-20261006-05: release the sealed copy of each SMS/MMS that landed, as soon as its pass ends -- not
            // after the settle and the re-verify passes, so a session that ends mid-run does not get back a text it
            // already holds. Calls wait for the final call-log check below.
            ackLanded(ctx, reply, everOk, acked, false, unknown);
            if (pass + 1 >= passes) break;
            try { Thread.sleep(REVERIFY_MS[pass]); } catch (InterruptedException ignored) { break; }
        }
        android.util.Log.i("NowhereChooser", "telingest" + (live ? " (live)" : "") + ": " + verified + "/"
                + (reply.size() - 1) + " telephony row(s) verified in " + android.os.Process.myUserHandle());
        // #135 Part 3: GET-TELINGEST already CLAIMED (removed) the mailbox, so a call that never persisted would
        // be lost. For CALL rows a completed exists() is authoritative; one that did not complete re-stages -- do a
        // FINAL check and, for any still missing (or unknown), RE-STAGE it (RESTAGE-TELINGEST) so a later kick (a
        // cold-lock resume re-kick, #385) retries it, rather than dropping it silently. A trailing retry token caps
        // the attempts so a permanently-failing row can't loop; once capped, log it LOUDLY and drop. (With
        // ensureCallLogGrant the insert normally succeeds, so this is the rare-transient-failure safety net.)
        for (int i = 1; i < reply.size(); i++) {
            String[] f = reply.get(i).split(" ");
            if (restageBase(f, true) >= 0) {
                try {
                    long when = Long.parseLong(f[1]);
                    Boolean present = exists(ctx, android.provider.CallLog.Calls.CONTENT_URI, when);
                    if (present == null) unknown[0]++;
                    if (Boolean.TRUE.equals(present)) continue; // persisted -> fine; unknown re-stages like absent (the redelivery re-checks)
                    // Retry count = a 7th token (deliver() uses f[0..5]); f[5] echoed VERBATIM: a call row's "-<simTag>" (NWP-20260924-07).
                    String line = restageLine(f, 6, MAX_TEL_RETRIES);
                    if (line != null) {
                        DaemonSocket.roundTrip("RESTAGE-TELINGEST\n" + line + "\n", 5_000);
                        android.util.Log.w("NowhereChooser", "telingest: call row " + when + " did NOT persist after "
                                + passes + " pass(es) -- RE-STAGED (retry " + line.substring(line.lastIndexOf(' ') + 1)
                                + "/" + MAX_TEL_RETRIES + ")");
                    } else {
                        android.util.Log.w("NowhereChooser", "telingest: call row " + when
                                + " did NOT persist after " + MAX_TEL_RETRIES + " retries -- DROPPED");
                    }
                } catch (Throwable ignore) {}
            }
        }
        // NWP-20261005-15: ...and an SMS or MMS that never landed is re-staged too. Until now only calls were: an SMS
        // whose insert the provider refused (a session still under no_sms, frankel 0.5.41) was ACKed and lost, and the
        // daemon keeps no other copy of a row it handed to a live owner. "Never landed" is this run's own record --
        // deliver() returned false on every pass, i.e. the insert returned no row and the read-back did not see one
        // -- because an SMS read-back alone was not authoritative when this was written (READ_SMS was ceded; it is
        // granted back since NWP-20261006-07, and a session where that grant fails still behaves as here). The
        // daemon returns the row to the mailbox of the SIM it was claimed from, or drops it if that SIM was unassigned meanwhile. Same retry
        // cap as a call, carried the same way: one trailing token after the row's own fields.
        for (int i = 1; i < reply.size(); i++) {
            if (everOk[i]) continue;
            String[] f = reply.get(i).split(" ");
            int base = restageBase(f, false);
            if (base < 0) continue;
            long when = 0;
            try { when = Long.parseLong(f[1]); } catch (Throwable ignore) {}
            String line = restageLine(f, base, MAX_TEL_RETRIES);
            if (line != null) {
                DaemonSocket.roundTrip("RESTAGE-TELINGEST\n" + line + "\n", 5_000);
                android.util.Log.w("NowhereChooser", "telingest: " + f[0] + " row " + when + " did NOT land after "
                        + passes + " pass(es) -- RE-STAGED (retry " + line.substring(line.lastIndexOf(' ') + 1)
                        + "/" + MAX_TEL_RETRIES + ")");
            } else {
                android.util.Log.w("NowhereChooser", "telingest: " + f[0] + " row " + when
                        + " did NOT land after " + MAX_TEL_RETRIES + " retries -- DROPPED");
            }
        }
        ackLanded(ctx, reply, everOk, acked, true, unknown);
        // NWP-20261112-21: counts only, never a number, a body or a time.
        if (unknown[0] > 0) android.util.Log.w("NowhereChooser", "telingest: " + unknown[0]
                + " row lookup(s) did not complete -- not inserted or acknowledged on that answer, asked again later");
        DaemonSocket.roundTrip("ACK-TELINGEST\n", 5_000);
        // NB (task_c272758a): deliver() posts OUR own in-session SMS notice for every injected row (single,
        // consistent ping, live + backlog); the default messaging app's OWN duplicate notice for a live row is
        // cancelled by MessagingSuppressor (our listener). Calls get postMissedCallNotice; MMS -> postRoamedMessageNotice.
        // #175 + task_c272758a, NWP-20261010-13: reading the message -- through our notice or by opening Messaging
        // directly -- clears our notice through MessagingSuppressor (clearReadNotices), at any time in the session.
        // Nothing waits for it here.
    }

    /** NWP-20261010-13: the tag of the notice for the message row that arrived at `when` -- "sms:<ms>" or "mms:<ms>".
     *  The tag IS the record of what the notice stands for (noticeRow reads it back), which is what lets the clear
     *  be stateless. The MMS notice was tagged "nowhere_mms" with an id hashed from the arrival, which cannot be read
     *  back, so it needed a static map to find its message. */
    static String noticeTag(String kind, long when) { return kind + ":" + when; }

    /** NWP-20261010-13: the message row a notice tag names, as {kind, arrival-ms} -- or null for any tag that is not
     *  exactly one noticeTag wrote (a missed-call notice, a gate notice, a malformed or non-canonical number), which
     *  the clear never touches. Canonical means the round trip: "sms:007" and "sms:+7" name no row. */
    static String[] noticeRow(String tag) {
        if (tag == null) return null;
        int c = tag.indexOf(':');
        if (c < 0) return null;
        String kind = tag.substring(0, c), ms = tag.substring(c + 1);
        if (!"sms".equals(kind) && !"mms".equals(kind)) return null;
        long when;
        try { when = Long.parseLong(ms); } catch (NumberFormatException e) { return null; }
        if (when <= 0 || !tag.equals(noticeTag(kind, when))) return null;
        return new String[]{kind, ms};
    }

    /** NWP-20261010-13: the provider query that finds the row a notice names, as {uri, selection, argument}. An SMS by
     *  its arrival-ms date, the key every insert is verified by (exists()); an MMS by the message id stamped at its
     *  insert (mmsKey) -- its date is in seconds, too coarse to name one message, and its row id is not in the tag. */
    static String[] rowQuery(String[] row) {
        if ("mms".equals(row[0])) return new String[]{"content://mms", "m_id=?", mmsKey(Long.parseLong(row[1]))};
        return new String[]{"content://sms", "date=?", row[1]};
    }

    // NWP-20261010-13: what the provider says about a notice's row, besides its "read" column (0 unread, >0 read).
    static final int ROW_BLIND = -1; // could not ask: no READ_SMS grant or op, no cursor, or the query threw
    static final int ROW_GONE = -2;  // asked and answered: there is no such row
    // ...and what a sweep does with the notice.
    static final int NOTICE_CLEAR = 1; // cancel it
    static final int NOTICE_POLL = 0;  // keep it, and keep the re-sweep going for it
    static final int NOTICE_KEEP = -1; // keep it, and do not re-sweep for it
    // A row the provider says is gone, in a notice younger than this, may still be on its way: at sign-in an
    // immediate read-back races the provider's commit and false-negatives (see deliver()). Longer than the whole
    // login delivery (SETTLE_MS + REVERIFY_MS).
    static final long GONE_GRACE_MS = 120_000L;

    /** NWP-20261010-13: a row's state from one read-back. canRead is our READ_SMS permission AND its app-op: with the
     *  op ignored the provider answers an EMPTY cursor, not an error, so without this a blind read-back would look
     *  like every row gone. answered is a cursor came back; found is it had a row; read is that row's column. */
    static int rowState(boolean canRead, boolean answered, boolean found, int read) {
        if (!canRead || !answered) return ROW_BLIND;
        if (!found) return ROW_GONE;
        return Math.max(read, 0);
    }

    /** NWP-20261010-13: what a sweep does with a notice, from its row's state and the notice's age:
     *  - read: CLEAR -- reading the message, anywhere, clears our notice, as a native one clears.
     *  - unread: POLL -- keep it; a read that notifies no observer is caught by the bounded re-sweep.
     *  - gone, and older than GONE_GRACE_MS: CLEAR -- the conversation was deleted, and Bugle drops its notice on a
     *    delete too. Younger: POLL, since the row may still be committing; the re-sweep decides it once it is old.
     *  - blind: KEEP, and no re-sweep -- nothing is cleared on a read-back that could not see, and polling a
     *    read-back that cannot see would never end. A tap or a swipe still clears it. */
    static int noticeAction(int state, long ageMs) {
        if (state > 0) return NOTICE_CLEAR;
        if (state == 0) return NOTICE_POLL;
        if (state == ROW_GONE) return ageMs >= GONE_GRACE_MS ? NOTICE_CLEAR : NOTICE_POLL;
        return NOTICE_KEEP;
    }

    /** NWP-20261010-13: each of these active notice tags that names a message row, in order, with what a sweep does
     *  with it (noticeAction). ageOf gives a notice's age in ms; stateOf answers a rowQuery with rowState. A tag that
     *  names no row (noticeRow) is left out and never looked up; a repeated tag is decided once. */
    static java.util.Map<String, Integer> noticeActions(java.util.List<String> tags,
                                                        java.util.function.ToLongFunction<String> ageOf,
                                                        java.util.function.ToIntFunction<String[]> stateOf) {
        java.util.Map<String, Integer> out = new java.util.LinkedHashMap<>();
        if (tags == null) return out;
        for (String tag : tags) {
            String[] row = noticeRow(tag);
            if (row == null || out.containsKey(tag)) continue;
            out.put(tag, noticeAction(stateOf.applyAsInt(rowQuery(row)), ageOf.applyAsLong(tag)));
        }
        return out;
    }

    /** NWP-20261010-13 (#175, task_c272758a): cancel each of our message notices whose message is now read -- or whose
     *  conversation is gone -- so reading it in Messaging, not only tapping our notice, clears ours, as a native
     *  notice would. STATELESS: the notices come from the NotificationManager (this package, this user) and the
     *  rows from the provider, on every call, so it holds nothing that a second text, a second delivery run or a
     *  restarted process can lose. Called by MessagingSuppressor. Returns {notices to re-sweep for (POLL), notices
     *  cleared}. Same user throughout: the notice, Messaging and the rows are all the roamed user's. */
    static int[] clearReadNotices(Context ctx) {
        android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
        if (nm == null) return new int[]{0, 0};
        android.service.notification.StatusBarNotification[] active;
        try { active = nm.getActiveNotifications(); } catch (Throwable t) { return new int[]{0, 0}; }
        if (active == null) return new int[]{0, 0};
        final long now = System.currentTimeMillis();
        final java.util.Map<String, Long> posted = new java.util.HashMap<>();
        java.util.List<String> tags = new java.util.ArrayList<>();
        for (android.service.notification.StatusBarNotification sbn : active) {
            if (noticeRow(sbn.getTag()) == null) continue;
            tags.add(sbn.getTag());
            posted.put(sbn.getTag(), sbn.getPostTime());
        }
        if (tags.isEmpty()) return new int[]{0, 0};
        final boolean canRead = canReadMessages(ctx);
        final java.util.Set<String> gone = new java.util.HashSet<>(); // the rowQuery args answered ROW_GONE
        java.util.Map<String, Integer> act = noticeActions(tags, tag -> now - posted.get(tag), q -> {
            int st = readState(ctx, q, canRead);
            if (st == ROW_GONE) gone.add(q[0] + "|" + q[2]);
            return st;
        });
        int poll = 0, cleared = 0, clearedGone = 0;
        for (android.service.notification.StatusBarNotification sbn : active) {
            Integer a = act.get(sbn.getTag());
            if (a == null) continue;
            if (a == NOTICE_CLEAR) {
                try { nm.cancel(sbn.getTag(), sbn.getId()); cleared++; } catch (Throwable ignore) {}
                String[] q = rowQuery(noticeRow(sbn.getTag()));
                if (gone.contains(q[0] + "|" + q[2])) clearedGone++;
            } else if (a == NOTICE_POLL) {
                poll++;
            }
        }
        // Counts only, never a number, a body or a time. GONE cannot tell a conversation the user deleted from a row
        // that vanished after its insert (the provider settling at sign-in, see deliver()), so a gone clear is counted
        // apart: a vanished text leaves this trace even though its notice goes.
        if (cleared > 0) {
            android.util.Log.i("NowhereChooser", "NWP-20261010-13 cleared " + cleared + " message notice(s), "
                    + clearedGone + " of them for a row that is gone (deleted, or vanished after its insert)");
        }
        if (cleared > 0) syncMessageSummary(ctx); // NWP-20261118-16: the summary goes with the group's last notice
        if (!canRead) android.util.Log.w("NowhereChooser", "NWP-20261010-13 cannot read Messages: notices kept, not polled");
        return new int[]{poll, cleared};
    }

    /** NWP-20261010-13: whether our read-back can see Messages at all: READ_SMS granted (ensureSmsRead) AND its app-op
     *  allowed, the op the #148 cede moves to Messaging. Only MODE_ALLOWED counts -- anything else reads as blind. */
    private static boolean canReadMessages(Context ctx) {
        try {
            if (ctx.checkSelfPermission(android.Manifest.permission.READ_SMS)
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) return false;
            android.app.AppOpsManager ao = ctx.getSystemService(android.app.AppOpsManager.class);
            return ao != null && ao.unsafeCheckOpNoThrow(android.app.AppOpsManager.OPSTR_READ_SMS,
                    android.os.Process.myUid(), ctx.getPackageName()) == android.app.AppOpsManager.MODE_ALLOWED;
        } catch (Throwable t) {
            return false;
        }
    }

    /** NWP-20261010-13: one read-back of the row a rowQuery finds, as rowState. */
    private static int readState(Context ctx, String[] q, boolean canRead) {
        if (!canRead) return rowState(false, false, false, 0);
        try (Cursor c = ctx.getContentResolver().query(Uri.parse(q[0]), new String[]{"read"}, q[1],
                new String[]{q[2]}, null)) {
            if (c == null) return rowState(true, false, false, 0);
            boolean found = c.moveToFirst();
            return rowState(true, true, found, found ? c.getInt(0) : 0);
        } catch (Throwable t) {
            return rowState(true, false, false, 0);
        }
    }

    /** NWP-20261006-05: tell the daemon which rows LANDED, so it drops their sealed copies (ACK-TELROWS). A row never
     *  acknowledged keeps its copy, pending, and comes back at the profile's next sign-in if this session ends first.
     *  An SMS or MMS landed when deliver() said so on some pass; a call (only when calls is set, after the final pass)
     *  only if the call log shows it -- the check the call re-stage uses, so a call that vanished keeps its copy.
     *  Each row is acknowledged once; acked records which. A call lookup that did not complete counts in unknown and
     *  acknowledges nothing (NWP-20261112-21). */
    private static void ackLanded(Context ctx, List<String> reply, boolean[] everOk, boolean[] acked, boolean calls,
                                  int[] unknown) {
        StringBuilder keys = new StringBuilder();
        int n = 0;
        for (int i = 1; i < reply.size(); i++) {
            if (acked[i] || !everOk[i]) continue;
            String[] f = reply.get(i).split(" ");
            if (f.length < 2) continue;
            if ("call".equals(f[0])) {
                if (!calls) continue;
                try {
                    Boolean present = exists(ctx, android.provider.CallLog.Calls.CONTENT_URI, Long.parseLong(f[1]));
                    if (present == null) unknown[0]++;
                    if (!Boolean.TRUE.equals(present)) continue; // NWP-20261112-21: acknowledged only on a lookup that found it
                } catch (Throwable t) { continue; }
            }
            keys.append(f[0]).append(' ').append(f[1]).append('\n');
            acked[i] = true;
            n++;
        }
        if (n > 0) DaemonSocket.roundTrip("ACK-TELROWS\n" + n + "\n" + keys, 5_000);
    }

    /** One row, verify-first: "&lt;kind&gt; &lt;when_ms&gt; &lt;call_type&gt; &lt;dur_sec&gt; &lt;from_b64&gt; &lt;body_b64&gt;"
     *  (the agent's telingest wire format; an EMPTY from/body is the "-" sentinel -- an empty base64 token would not survive
     *  DaemonSocket's line trim + split(" ")'s trailing-empty drop, which silently rejected every call row in the first cut;
     *  a CALL's body slot is "-" or "-<simTag>", never read, NWP-20260924-07). Returns true when the row is VERIFIED present;
     *  false, inserting nothing, when its lookup did not complete (counted in unknown, NWP-20261112-21). */
    private static boolean deliver(Context ctx, String line, java.util.Set<Long> insertedThisRun,
                                   java.util.Set<Long> notified, int[] unknown) {
        try {
            String[] f = line.split(" ");
            // #150 P4: MMS arrives as "mms <when> <telItem_json_b64>" (3 tokens, not the 6-token sms/call
            // line) -- route it to the multi-table content://mms insert before the 6-token guard.
            if (f.length >= 3 && "mms".equals(f[0])) return deliverMms(ctx, f, insertedThisRun, unknown);
            if (f.length < 6) return false;
            long when = Long.parseLong(f[1]);
            String from = decTok(f[4]);
            Uri uri;
            boolean missedCall = false;
            final boolean isCall = "call".equals(f[0]);
            ContentValues v = new ContentValues();
            if ("sms".equals(f[0])) {
                uri = android.provider.Telephony.Sms.Inbox.CONTENT_URI;
                v.put("address", from);
                v.put("body", decTok(f[5]));
                v.put("date", when);
                v.put("read", 0);
                // #148: INVALID_SUBSCRIPTION_ID(-1). The telephony provider filters SMS reads by
                // allowInteractingWithEntryOfSubscription = sub-associated-with-caller-user OR sub_id==-1. We do
                // NOT associate the SIM (that reroutes inbound delivery natively to Messaging, which as an
                // ordinary app cannot WRITE it) -- instead our privileged agent stays the writer and tags the
                // row -1 so the roamed user's Messaging can DISPLAY it. Safe now that the provider is PER-USER:
                // the row lives in this user's own CE mmssms.db (wipes with the session, no cross-profile leak).
                v.put("sub_id", -1);
            } else if (isCall) {
                uri = android.provider.CallLog.Calls.CONTENT_URI; // WRITE/READ_CALL_LOG granted per-user (ensureCallLogGrant)
                int callType = Integer.parseInt(f[2]);            // agent stores CallLog.Calls types (incoming/missed)
                v.put("number", from);
                v.put("date", when);
                v.put("type", callType);
                v.put("duration", Long.parseLong(f[3]));
                v.put("new", 1);
                missedCall = callType == android.provider.CallLog.Calls.MISSED_TYPE; // 3 -> owner needs a ping at login
            } else return false;
            // Dedup / re-verify strategy differs by kind (#135 Part 3):
            //  - SMS: insertedThisRun guards the 3 passes against a double-insert (#371). Its cost: a row that
            //    VANISHES after an apparently-good insert is never re-checked (the short-circuit hides it). Since
            //    NWP-20261006-07 exists() below can read Messages (ensureSmsRead), so a text ANOTHER session already
            //    inserted -- redelivered because its acknowledgement was lost -- is found and not shown twice.
            //  - CALL: READ_CALL_LOG IS granted (ensureCallLogGrant), so a completed exists() is AUTHORITATIVE. We do
            //    NOT short-circuit on insertedThisRun -- every pass re-checks exists() and RE-INSERTS a call row that
            //    the provider dropped after insert. Idempotent because only a completed lookup that found no row
            //    inserts: a lookup that did not complete (the provider restarting during bring-up) answers unknown and
            //    inserts nothing (rowStep RETRY, NWP-20261112-21).
            if (!isCall && insertedThisRun.contains(when)) return true; // SMS dedup
            int step = rowStep(exists(ctx, uri, when));
            if (step == DONE) return true; // present: fresh dedup, or confirmed-persisted on a re-verify pass
            if (step != INSERT) { unknown[0]++; return false; } // NWP-20261112-21: unknown -- insert nothing, ask again later
            // insert() returns the new row's Uri on success -- trust it on the FIRST insert (an immediate exists()
            // re-read races the provider's async commit and false-negatives). A later re-verify pass then re-checks
            // exists() (settled by then) and, for a CALL, re-inserts if the row vanished.
            Uri ins = ctx.getContentResolver().insert(uri, v);
            boolean ok = ins != null || readBack(exists(ctx, uri, when), unknown); // read back only on a null result
            if (ok) {
                if (!isCall) insertedThisRun.add(when); // SMS: remember it so no later pass re-inserts (calls rely on exists())
                // Post the missed-call notice EXACTLY ONCE per row (notified.add is true only the first time), so a
                // re-verify re-insert of a vanished call doesn't re-ping the owner. A missed call delivered at
                // login has no live MissedCallNotifier behind it and the dialer doesn't notify on an inserted row,
                // so without this the seal-for-owner miss (#163 P2) would land silently. Owner's own in-session
                // data -> showing the caller number matches native behaviour (no leak).
                if (missedCall && notified.add(when)) postMissedCallNotice(ctx, from, when);
                // task_c272758a: post OUR own in-session SMS notice for every injected row -- the single, consistent
                // ping in BOTH the live and backlog cases (Chester's ask: always ours, not the messaging app's). The
                // default messaging app's OWN duplicate notice for a live row is cancelled by MessagingSuppressor
                // (our NotificationListenerService, enabled at login), which also clears ours once the message is
                // read: its tag names the row (noticeTag, clearReadNotices -- NWP-20261010-13).
                if (!isCall && notified.add(when)) {
                    postRoamedMessageNotice(ctx, noticeTag("sms", when), from, null, decTok(f[5]), null, when);
                }
            }
            return ok;
        } catch (Throwable t) {
            // SecurityException here means a perm/role regression -- log it loudly; the verify-first shape
            // makes the next pass a safe no-op retry either way.
            android.util.Log.w("NowhereChooser", "telingest row", t);
            return false;
        }
    }

    /** #150 P4: insert one sealed-then-decrypted MMS into THIS roamed user's own per-user MMS provider so
     *  its Messaging displays it. Wire: "mms &lt;when_ms&gt; &lt;telItem_json_b64&gt;" (serializeTelIngest).
     *  Multi-table, mirroring an inbound M-Retrieve.conf persist (a minimal PduPersister): a pdu row
     *  (content://mms, msg_box=inbox, m_type=RETRIEVE_CONF, date in SECONDS, sub_id=-1 so the read-filter's
     *  INVALID clause lets the roamed Messaging show it -- the same #148 trick as SMS), the FROM address row,
     *  then each part (text/smil -&gt; the "text" column; media -&gt; the bytes via openOutputStream). Dedup
     *  via insertedThisRun within a run, and across sessions by the message id it stamps (mmsExists,
     *  NWP-20261006-07). OP_WRITE_SMS (ensureSmsWrite, run())
     *  authorises the mms write too. A lookup that did not complete inserts nothing (unknown, NWP-20261112-21). */
    private static boolean deliverMms(Context ctx, String[] f, java.util.Set<Long> insertedThisRun, int[] unknown) {
        try {
            long when = Long.parseLong(f[1]);
            if (insertedThisRun.contains(when)) return true; // dedup across the 3 verify passes
            // NWP-20261006-07: and across sessions -- an MMS an earlier session inserted, redelivered because its
            // acknowledgement was lost (NWP-20261006-05), is already in this profile's Messages. Found by the
            // message id we stamp on every insert below: its date is only in SECONDS, too coarse to name one message.
            int step = rowStep(mmsExists(ctx, when));
            if (step == DONE) return true;
            if (step != INSERT) { unknown[0]++; return false; } // NWP-20261112-21: unknown -- insert nothing, ask again later
            byte[] jb = android.util.Base64.decode(f[2], android.util.Base64.NO_WRAP);
            org.json.JSONObject o = new org.json.JSONObject(new String(jb, java.nio.charset.StandardCharsets.UTF_8));
            String from = o.optString("from", "");
            String subject = o.optString("subject", "");
            String note = o.optString("note", ""); // #150 degrade tag (e.g. "too-large"): rendered as a hint below
            org.json.JSONArray parts = o.optJSONArray("parts");

            // Compute the conversation thread from the SENDER and set it on the pdu. Without this the MMS
            // never joins the sender's thread (for MMS the addr row is inserted AFTER the pdu, so the provider
            // can't auto-derive it at pdu-insert time) -> Messaging shows "unknown sender" AND skips notifying
            // (Bugle notifies on messages it can attribute). getOrCreateThreadId also creates the canonical
            // address so the sender resolves.
            long threadId = 0;
            if (!from.isEmpty()) {
                try {
                    java.util.HashSet<String> recips = new java.util.HashSet<>();
                    recips.add(from);
                    threadId = android.provider.Telephony.Threads.getOrCreateThreadId(ctx, recips);
                } catch (Throwable ignore) {}
            }

            ContentValues pdu = new ContentValues();
            pdu.put("date", when / 1000L); // MMS date is SECONDS (SMS date is ms) -- wrong scale => wrong day
            pdu.put("msg_box", 1);         // MESSAGE_BOX_INBOX
            pdu.put("read", 0);
            pdu.put("seen", 0);
            pdu.put("m_type", 132);        // PduHeaders.MESSAGE_TYPE_RETRIEVE_CONF
            pdu.put("ct_t", "application/vnd.wap.multipart.related");
            pdu.put("sub_id", -1);         // #148 INVALID_SUBSCRIPTION_ID: lets the roamed Messaging display it
            pdu.put("m_id", mmsKey(when)); // NWP-20261006-07: names this delivery, so a redelivery finds it (mmsExists)
            if (threadId > 0) pdu.put("thread_id", threadId); // join the sender's conversation (fixes attribution + notify)
            if (!subject.isEmpty()) { pdu.put("sub", subject); pdu.put("sub_cs", 106); }
            Uri mmsUri = ctx.getContentResolver().insert(Uri.parse("content://mms"), pdu);
            if (mmsUri == null) return false;
            long id = android.content.ContentUris.parseId(mmsUri);

            // FROM address (type 137) so Messaging attributes the sender; charset 106 = UTF-8.
            ContentValues addr = new ContentValues();
            addr.put("address", from.isEmpty() ? "insert-address-token" : from);
            addr.put("type", 137);
            addr.put("charset", 106);
            try { ctx.getContentResolver().insert(Uri.parse("content://mms/" + id + "/addr"), addr); } catch (Throwable ignore) {}

            int n = parts == null ? 0 : parts.length();
            StringBuilder preview = new StringBuilder();
            boolean hasMedia = false;
            String mediaLabel = null; // #150: label the notice by the media KIND, not a hardcoded "Photo"
            for (int i = 0; i < n; i++) {
                org.json.JSONObject p = parts.getJSONObject(i);
                String ct = p.optString("ct", "application/octet-stream");
                String name = p.optString("name", "");
                byte[] data = android.util.Base64.decode(p.optString("data", ""), android.util.Base64.NO_WRAP);
                insertMmsPart(ctx, id, i, ct, name, data);
                if (ct.startsWith("text/plain")) {
                    String s = new String(data, java.nio.charset.StandardCharsets.UTF_8).trim();
                    if (!s.isEmpty()) { if (preview.length() > 0) preview.append(' '); preview.append(s); }
                } else if (ct.startsWith("image/") || ct.startsWith("video/") || ct.startsWith("audio/")) {
                    hasMedia = true;
                    // #150: a video MMS was reading "Photo". Label by kind, video winning over a co-attached image.
                    String kind = ct.startsWith("video/") ? "🎥 Video" : ct.startsWith("audio/") ? "🎙 Audio" : "📷 Photo";
                    if (mediaLabel == null || "🎥 Video".equals(kind)) mediaLabel = kind;
                }
            }
            // #150: a DEGRADED MMS (e.g. over-cap -> media dropped by the seal, note="too-large") arrives with
            // no parts. Render the reason as a text part so the thread isn't a blank bubble and the in-session
            // notice says something useful instead of a bare "New message".
            if (!note.isEmpty() && preview.length() == 0 && !hasMedia) {
                String hint = "too-large".equals(note)
                        ? "[Attachment too large to download]"
                        : "[Message couldn't be downloaded]";
                insertMmsPart(ctx, id, n, "text/plain", "hint.txt",
                        hint.getBytes(java.nio.charset.StandardCharsets.UTF_8));
                preview.append(hint);
            }
            insertedThisRun.add(when);
            // #150 (i): Bugle imports a sealed MMS delivered at login via its provider sync, but -- unlike a
            // live SMS -- treats the back-dated row as historical catch-up and does NOT raise a notification
            // (verified on lynx: read=0 at insert, no com.android.messaging notice; the owner missed it). MMS
            // has NO live path (every MMS lands via this login/backlog path, see P2), so the chooser is the sole
            // notifier here -> post our own; there is no Bugle notification to double with.
            // #175, NWP-20261010-13: tagged by its arrival, so MessagingSuppressor clears it once the MMS is read.
            postRoamedMessageNotice(ctx, noticeTag("mms", when), from, subject, preview.toString(), mediaLabel, when);
            android.util.Log.i("NowhereChooser", "#150 MMS ingested id=" + id + " parts=" + n);
            return true;
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "mms ingest row", t);
            return false;
        }
    }

    /** #150 (i): post a NEW-MESSAGE notification for a delivered MMS in the ROAMED owner's OWN session.
     *  (Reuses TEL_CHANNEL, defined below alongside postMissedCallNotice -- same "Messages & calls" channel.)
     *  Distinct from SmsDeliverReceiver.postMessageNotice, which is the CONTENT-FREE notice shown at the GATE
     *  (a shared, pre-login screen) -- here we are inside the authenticated owner's session, so a normal
     *  content notification (sender + a short preview, tappable to the conversation) is appropriate, exactly
     *  like a phone's built-in messaging notification. VISIBILITY_PRIVATE still hides the content on a
     *  warm-locked keyguard. Tapping opens the sender's thread in the default messaging app (Bugle).
     *  NWP-20261010-13: the lock screen shows the PUBLIC version, which is content-free ("New message", no sender,
     *  no text) -- with none, a redacted row said only the app's label. Both versions are named "Messages" instead of
     *  the chooser's label, "Profile" (Chester, 2026-10-10; SmsDeliverReceiver.substituteAppName): the public version
     *  is drawn from its own extras, so it carries the name too. The name stays "Messages" whichever app holds the
     *  SMS role: since 2026-10-11 that is the profile's own choice (SmsRoleRoam), and the tap opens THAT app
     *  (messageTapPackage) -- the sender's thread when it handles VIEW sms:, else its SENDTO smsto: compose screen.
     *  NWP-20261118-16: every message notice is in one group (MessageGroup.KEY), with a summary of ours. */
    private static void postRoamedMessageNotice(Context ctx, String tag, String from, String subject, String preview,
                                                String mediaLabel, long when) {
        try {
            android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            SmsDeliverReceiver.ensureTelChannel(nm); // HIGH + explicit sound + vibrate -> the roamed session alerts
            String title = from == null || from.isEmpty() ? "New message" : from;
            String body = preview == null ? "" : preview.trim();
            if (body.isEmpty() && subject != null) body = subject.trim();
            if (mediaLabel != null) body = body.isEmpty() ? mediaLabel : (body + "  " + mediaLabel);
            if (body.isEmpty()) body = "New message";
            android.app.PendingIntent pi = android.app.PendingIntent.getActivity(ctx, (int) when,
                    messageTapIntent(ctx, from),
                    android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT);
            android.os.Bundle named = new android.os.Bundle();
            named.putString(SmsDeliverReceiver.EXTRA_SUBST_APP_NAME, SmsDeliverReceiver.substituteAppName(tag.startsWith("mms:") ? "mms" : "sms"));
            android.app.Notification locked = new android.app.Notification.Builder(ctx, TEL_CHANNEL) // the public version
                    .setSmallIcon(R.drawable.ic_notif_message)
                    .addExtras(named)
                    .setContentTitle("New message")
                    .setCategory(android.app.Notification.CATEGORY_MESSAGE)
                    .setWhen(when)
                    .setShowWhen(true)
                    .build();
            android.app.Notification.Builder b = new android.app.Notification.Builder(ctx, TEL_CHANNEL)
                    .setSmallIcon(R.drawable.ic_notif_message)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setCategory(android.app.Notification.CATEGORY_MESSAGE)
                    .setGroup(MessageGroup.KEY)
                    .setVisibility(android.app.Notification.VISIBILITY_PRIVATE)
                    .setPublicVersion(locked)
                    .addExtras(named)
                    .setWhen(when)
                    .setShowWhen(true)
                    .setAutoCancel(true)
                    .setContentIntent(pi);
            // id keyed on the arrival-ms so a re-verify pass or re-login updates rather than stacks duplicates,
            // while two different MMS still get distinct notifications.
            nm.notify(tag, (int) (when ^ (when >>> 32)), b.build());
            syncMessageSummary(ctx); // NWP-20261118-16: the group's own summary, so Android never posts its own
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "roamed message notice", t);
        }
    }

    /** NWP-20261010-13: where a tap on a message notice goes -- the sender's thread, in the default SMS app, never
     *  through a "Open with" chooser. The tap used to be an IMPLICIT VIEW sms:<from>. The SMS role pins a preferred
     *  activity for SENDTO, not for VIEW, so with a second handler installed (WhatsApp) the system asked which app.
     *  Now it is pinned to a package (messageTapPackage) and takes the action that package handles (messageTapAction).
     *  Resolved when the notice is posted. */
    private static android.content.Intent messageTapIntent(Context ctx, String from) {
        android.content.pm.PackageManager pm = ctx.getPackageManager();
        String holder = null;
        try { holder = android.provider.Telephony.Sms.getDefaultSmsPackage(ctx); } catch (Throwable ignore) {}
        boolean messaging = false;
        try { pm.getPackageInfo(MESSAGING, 0); messaging = true; } catch (Throwable ignore) {}
        String pkg = messageTapPackage(holder, ctx.getPackageName(), messaging ? MESSAGING : null);
        boolean hasFrom = from != null && !from.isEmpty();
        android.content.Intent view = hasFrom
                ? new android.content.Intent(android.content.Intent.ACTION_VIEW, Uri.fromParts("sms", from, null)) : null;
        boolean viewResolves = false;
        if (view != null && pkg != null) {
            view.setPackage(pkg);
            try { viewResolves = view.resolveActivity(pm) != null; } catch (Throwable ignore) {}
        }
        android.content.Intent open;
        switch (messageTapAction(hasFrom, pkg != null, viewResolves)) {
            case "view":
                open = view;
                break;
            case "sendto":
                open = new android.content.Intent(android.content.Intent.ACTION_SENDTO, Uri.fromParts("smsto", from, null))
                        .setPackage(pkg);
                break;
            default: // "launch": no sender to open a thread for -- the app's own entry, else any messaging app
                open = pkg == null ? null : pm.getLaunchIntentForPackage(pkg);
                if (open == null) {
                    open = new android.content.Intent(android.content.Intent.ACTION_MAIN)
                            .addCategory(android.content.Intent.CATEGORY_APP_MESSAGING);
                }
        }
        open.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
        return open;
    }

    /** NWP-20261010-13: the package a message notice's tap opens. The SMS role holder, unless there is none or it is
     *  the chooser itself (it holds the role only if the #148 cede did not land, and its SMS components are inert
     *  stubs that are disabled in a roamed user); then `fallback`, Messaging -- the default the sign-in gives -- when it
     *  is installed. null leaves the tap unpinned: the old implicit intent, the last resort when no messaging app is
     *  known at all. */
    static String messageTapPackage(String roleHolder, String self, String fallback) {
        if (roleHolder != null && !roleHolder.isEmpty() && !roleHolder.equals(self)) return roleHolder;
        return fallback == null || fallback.isEmpty() || fallback.equals(self) ? null : fallback;
    }

    /** NWP-20261010-13: the action of a message notice's tap: "view" (VIEW sms:<from>, the thread), "sendto"
     *  (SENDTO smsto:<from>), or "launch" (the app's entry, when there is no sender). VIEW is the thread, but no
     *  contract makes an SMS app handle it; SENDTO smsto: is one the SMS role requires of its holder, so it is the
     *  fallback when the pinned package does not take VIEW (Bugle takes both, into the same conversation). An
     *  unpinned tap stays VIEW, as before. */
    static String messageTapAction(boolean hasFrom, boolean pinned, boolean viewResolves) {
        if (!hasFrom) return "launch";
        return !pinned || viewResolves ? "view" : "sendto";
    }

    /** NWP-20261118-16: post or cancel the summary of the message group (MessageGroup), from the number of message
     *  notices showing (noticeRow names a row for their tags, never for the summary's). The backlog row "Tapping a text
     *  notification in a session sometimes opens the Profile screen instead of the message": with no summary of ours,
     *  Android bundles the notices under its own, whose tap is the chooser's launch activity, Profile. This summary's
     *  tap is messageTapIntent(ctx, null), the SMS app's own entry, never the chooser. It never alerts on its own
     *  (GROUP_ALERT_CHILDREN): each notice still alerts once. It holds a count only, no sender, number or text, and its
     *  public version holds none either. Best effort: a failure is logged without content and the notices stand. */
    static void syncMessageSummary(Context ctx) {
        try {
            android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            android.service.notification.StatusBarNotification[] active = nm.getActiveNotifications();
            int n = 0;
            if (active != null) {
                for (android.service.notification.StatusBarNotification sbn : active) {
                    if (noticeRow(sbn.getTag()) != null) n++;
                }
            }
            if (MessageGroup.wantSummary(n)) {
                SmsDeliverReceiver.ensureTelChannel(nm);
                android.os.Bundle extras = new android.os.Bundle();
                extras.putString(SmsDeliverReceiver.EXTRA_SUBST_APP_NAME, SmsDeliverReceiver.substituteAppName("sms"));
                android.app.Notification hidden = new android.app.Notification.Builder(ctx, TEL_CHANNEL) // the public version
                        .setSmallIcon(R.drawable.ic_notif_message)
                        .addExtras(extras)
                        .setContentTitle("New messages")
                        .setCategory(android.app.Notification.CATEGORY_MESSAGE)
                        .build();
                android.app.PendingIntent tap = android.app.PendingIntent.getActivity(ctx, MessageGroup.SUMMARY_REQUEST,
                        messageTapIntent(ctx, null),
                        android.app.PendingIntent.FLAG_IMMUTABLE | android.app.PendingIntent.FLAG_UPDATE_CURRENT);
                android.app.Notification summary = new android.app.Notification.Builder(ctx, TEL_CHANNEL)
                        .setSmallIcon(R.drawable.ic_notif_message)
                        .addExtras(extras)
                        .setContentTitle(MessageGroup.summaryText(n))
                        .setCategory(android.app.Notification.CATEGORY_MESSAGE)
                        .setGroup(MessageGroup.KEY)
                        .setGroupSummary(true)
                        .setGroupAlertBehavior(android.app.Notification.GROUP_ALERT_CHILDREN)
                        .setVisibility(android.app.Notification.VISIBILITY_PRIVATE)
                        .setPublicVersion(hidden)
                        .setAutoCancel(true)
                        .setContentIntent(tap)
                        .build();
                nm.notify(MessageGroup.SUMMARY_TAG, MessageGroup.SUMMARY_ID, summary);
            } else {
                nm.cancel(MessageGroup.SUMMARY_TAG, MessageGroup.SUMMARY_ID);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "NWP-20261118-16 message summary", t);
        }
    }

    /** #150 P4: insert one MMS part row + (for media) stream its bytes into the provider. text/plain +
     *  application/smil go in the "text" column; binary media (image/...) is written via openOutputStream on
     *  the returned part Uri (the provider stores it at _data). */
    private static void insertMmsPart(Context ctx, long mid, int seq, String ct, String name, byte[] data) {
        try {
            ContentValues v = new ContentValues();
            v.put("mid", mid);
            v.put("seq", seq);
            v.put("ct", ct);
            if (!name.isEmpty()) { v.put("cl", name); v.put("name", name); v.put("fn", name); }
            boolean isText = MmsText.storedAsText(ct);
            if (isText) {
                v.put("chset", 106); // UTF-8
                v.put("text", new String(data, java.nio.charset.StandardCharsets.UTF_8));
            }
            Uri partUri = ctx.getContentResolver().insert(Uri.parse("content://mms/" + mid + "/part"), v);
            if (!isText && partUri != null && data.length > 0) {
                // Write the media bytes. During login bring-up the per-user provider is still settling, so the
                // just-inserted part row can be briefly invisible to openFile's lookup -> FileNotFoundException
                // "No entry for content://mms/part/N", which would leave the image a 0-byte file. Retry with
                // backoff until it opens (the same settle window the sms/call re-verify passes ride out).
                for (int attempt = 0; ; attempt++) {
                    try (java.io.OutputStream os = ctx.getContentResolver().openOutputStream(partUri)) {
                        if (os != null) os.write(data);
                        break;
                    } catch (java.io.FileNotFoundException fnf) {
                        if (attempt >= 20) { // ~10s total -- give up, log loudly (the row still shows, no image)
                            android.util.Log.w("NowhereChooser", "#150 mms part data never writable: " + partUri, fnf);
                            break;
                        }
                        try { Thread.sleep(500); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
                    }
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "mms part", t);
        }
    }

    /** #149: grant OUR OWN OP_WRITE_SMS in this roamed user so the ContentResolver.insert into content://sms
     *  lands. cede makes Messaging the default SMS app, which moves OP_WRITE_SMS to Messaging and leaves ours
     *  at "ignore". We hold MANAGE_APP_OPS_MODES (platform-signed) so we can set our own app-op. Idempotent
     *  and cheap. (READ_SMS is not granted here: a runtime permission needs the profile-owner path, which
     *  ensureSmsRead takes since NWP-20261006-07. insertedThisRun in run() still prevents the multi-pass
     *  duplicate on its own, whether or not exists() can read.) */
    private static void ensureSmsWrite(Context ctx) {
        try {
            android.app.AppOpsManager ao = ctx.getSystemService(android.app.AppOpsManager.class);
            if (ao != null) {
                int op = android.app.AppOpsManager.strOpToOp(android.app.AppOpsManager.OPSTR_WRITE_SMS);
                ao.setMode(op, android.os.Process.myUid(), ctx.getPackageName(),
                        android.app.AppOpsManager.MODE_ALLOWED);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "telingest ensure WRITE_SMS", t);
        }
    }

    /** NWP-20261006-07: grant the chooser READ_SMS in THIS roamed user, so exists() and mmsExists() can see what is
     *  already in the profile's Messages. A text whose acknowledgement was lost (NWP-20261006-05) comes back at the
     *  next sign-in, and without this the chooser could not tell it already held it, so it showed twice. The same
     *  profile-owner path as ensureCallLogGrant (the chooser cannot self-grant a runtime permission, and READ_SMS is
     *  hard-restricted like CALL_LOG; the chooser is RESTRICTION_SYSTEM_EXEMPT), plus our OP_READ_SMS app-op, which
     *  cede moved to Messaging with the write op. It adds no knowledge: the chooser decrypted and wrote every row it
     *  will look for, and the lookups ask only whether one exists. A failure leaves the read-back blind, as before. */
    private static void ensureSmsRead(Context ctx) {
        try {
            android.app.admin.DevicePolicyManager dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            if (dpm != null) {
                dpm.setPermissionGrantState(new android.content.ComponentName(ctx, AdminReceiver.class),
                        ctx.getPackageName(), android.Manifest.permission.READ_SMS,
                        android.app.admin.DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "telingest grant READ_SMS", t); }
        try {
            android.app.AppOpsManager ao = ctx.getSystemService(android.app.AppOpsManager.class);
            if (ao != null) {
                ao.setMode(android.app.AppOpsManager.strOpToOp(android.app.AppOpsManager.OPSTR_READ_SMS),
                        android.os.Process.myUid(), ctx.getPackageName(), android.app.AppOpsManager.MODE_ALLOWED);
            }
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "telingest ensure READ_SMS op", t); }
    }

    /** NWP-20261006-07: the message id stamped on each MMS the chooser inserts, from the row's arrival ms. */
    private static String mmsKey(long when) { return "nowhere:" + when; }

    /** NWP-20261006-07, NWP-20261112-21: whether an MMS this chooser inserted for the row arriving at `when` is already
     *  in Messages -- TRUE found, FALSE the query completed with no row, null the lookup did not complete. */
    private static Boolean mmsExists(Context ctx, long when) {
        try (Cursor c = ctx.getContentResolver().query(Uri.parse("content://mms"), new String[]{"_id"},
                "m_id=?", new String[]{mmsKey(when)}, null)) {
            if (c == null) return null;
            return c.moveToFirst();
        } catch (Throwable t) {
            return null;
        }
    }

    /** task_c272758a (force-ours): grant our MessagingSuppressor NotificationListenerService access in THIS (roamed)
     *  user so it binds + cancels Bugle's duplicate live-SMS notice. Uses NotificationManager.setNotificationListener
     *  AccessGranted -- the @SystemApi (platform_apis) that `cmd notification allow_listener` uses, which the
     *  framework does NOT permission-gate for the same-user/own-component case (setNotificationListenerAccessGranted
     *  ForUser). Writing enabled_notification_listeners directly does NOT rebind the listener -- proven on lynx. */
    static void ensureNotificationListener(Context ctx) {
        try {
            android.content.ComponentName comp = new android.content.ComponentName(ctx, MessagingSuppressor.class);
            android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
            if (nm != null && !nm.isNotificationListenerAccessGranted(comp)) {
                nm.setNotificationListenerAccessGranted(comp, true);
                android.util.Log.i("NowhereChooser", "task_c272758a granted MessagingSuppressor listener in " + android.os.Process.myUserHandle());
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "grant notif listener", t);
        }
    }

    /** #150: self-grant OP_READ_RESTRICTED_MESSAGES so we can write MMS part media bytes. To store a media
     *  part's bytes the chooser does openOutputStream(content://mms/part/N); MmsProvider.openFile runs an
     *  INTERNAL restricted-read query, and (with the secureAccessToRestrictedRcsMessages flag on) that query
     *  filters parts by canReadRestrictedMessages = isSystemOrPhone OR isDefaultSmsApp OR the
     *  OP_READ_RESTRICTED_MESSAGES app-op. In the roamed user the chooser is NOT the default SMS app (Messaging
     *  is, per the #368 cede), so without this op the part is filtered out -> "No entry for content://mms/part/N"
     *  -> the image lands as a 0-byte file. We hold MANAGE_APP_OPS_MODES (platform-signed), so grant our own op.
     *  Idempotent; text/smil parts don't need it (they use the "text" column, no openFile). */
    private static void ensureReadRestrictedMessages(Context ctx) {
        try {
            android.app.AppOpsManager ao = ctx.getSystemService(android.app.AppOpsManager.class);
            if (ao != null) {
                int op = android.app.AppOpsManager.strOpToOp(android.app.AppOpsManager.OPSTR_READ_RESTRICTED_MESSAGES);
                ao.setMode(op, android.os.Process.myUid(), ctx.getPackageName(),
                        android.app.AppOpsManager.MODE_ALLOWED);
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "telingest ensure READ_RESTRICTED_MESSAGES", t);
        }
    }

    private static final String TEL_CHANNEL = "nowhere_telephony2"; // MUST match SmsDeliverReceiver.TEL_CHANNEL (v2 id; ensureTelChannel sets HIGH+sound+vibrate)

    /** Post an in-session "Missed call" notification for a call delivered at login/roam-in. The framework's
     *  MissedCallNotifier only fires for a LIVE miss and the dialer does not notify on an inserted row, so
     *  without this a seal-for-owner missed call lands silently in the log. One per call (id keyed on the
     *  unique arrival-ms so distinct misses don't collapse), tappable to open the call log. Runs in the roamed
     *  owner's own user, so the caller number is the owner's own data -- shown as native does. Best-effort.
     *  NWP-20261123-24: named "Phone" (SmsDeliverReceiver.substituteAppName), drawn with the white handset ic_notif_call. */
    private static void postMissedCallNotice(Context ctx, String number, long when) {
        try {
            android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            SmsDeliverReceiver.ensureTelChannel(nm); // HIGH + explicit sound + vibrate -> the roamed session alerts
            String who = (number == null || number.isEmpty()) ? "Unknown caller" : number;
            android.content.Intent view = new android.content.Intent(android.content.Intent.ACTION_VIEW)
                    .setType(android.provider.CallLog.Calls.CONTENT_TYPE)
                    .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
            android.app.PendingIntent pi = android.app.PendingIntent.getActivity(
                    ctx, (int) when, view, android.app.PendingIntent.FLAG_IMMUTABLE);
            android.os.Bundle named = new android.os.Bundle(); // NWP-20261123-24: named "Phone", not the chooser's label
            named.putString(SmsDeliverReceiver.EXTRA_SUBST_APP_NAME, SmsDeliverReceiver.substituteAppName("call"));
            android.app.Notification.Builder b = new android.app.Notification.Builder(ctx, TEL_CHANNEL)
                    .setSmallIcon(R.drawable.ic_notif_call)
                    .addExtras(named)
                    .setContentTitle("Missed call")
                    .setContentText(who)
                    .setContentIntent(pi)
                    .setAutoCancel(true);
            nm.notify("nowhere_missed_call", (int) when, b.build());
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "telingest missed-call notice", t);
        }
    }

    /** #135: ensure the chooser holds READ/WRITE_CALL_LOG in THIS roamed user before the call insert.
     *  Why this is needed and why it must live here (proven on lynx 2026-07-14): READ/WRITE_CALL_LOG are the
     *  CALL_LOG HARD-RESTRICTED permission group, which DefaultPermissionGrantPolicy grants only to user 0 --
     *  our default-permissions XML (nowhere-chooser-calls.xml) grants ANSWER_PHONE_CALLS to a roamed secondary
     *  but NOT the CALL_LOG group, so the roamed chooser has WRITE_CALL_LOG=granted=false and the delivered-call
     *  insert throws SecurityException. The chooser can't self-grant a RUNTIME perm (no GRANT_RUNTIME_PERMISSIONS)
     *  the way ensureSmsWrite self-grants the OP_WRITE_SMS APP-OP, and su:s0 roamd (endospore_priv) can't grant a
     *  hard-restricted perm either. But the chooser IS the PROFILE OWNER of the roamed user, and a profile owner
     *  CAN grant its user's apps runtime perms via DevicePolicyManager.setPermissionGrantState -- the one
     *  privileged path that works here. Runs as the roamed user (TelIngest is kicked in it), idempotent. */
    private static void ensureCallLogGrant(Context ctx) {
        try {
            android.app.admin.DevicePolicyManager dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            if (dpm == null) return;
            android.content.ComponentName admin = new android.content.ComponentName(ctx, AdminReceiver.class);
            for (String p : new String[]{ android.Manifest.permission.WRITE_CALL_LOG,
                                          android.Manifest.permission.READ_CALL_LOG }) {
                try {
                    dpm.setPermissionGrantState(admin, ctx.getPackageName(), p,
                            android.app.admin.DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "telingest grant " + p, t); }
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "telingest ensureCallLogGrant", t);
        }
    }

    /** Decode a wire token: the "-" sentinel is an empty value, anything else is standard base64. */
    private static String decTok(String tok) throws java.io.UnsupportedEncodingException {
        if ("-".equals(tok)) return "";
        return new String(android.util.Base64.decode(tok, android.util.Base64.DEFAULT), "UTF-8");
    }

    /** NWP-20261112-21: whether `uri` holds a row dated `when` -- TRUE found, FALSE the query completed with no row,
     *  null the lookup did not complete (no cursor, or the query threw while the provider churns at sign-in). */
    private static Boolean exists(Context ctx, Uri uri, long when) {
        try (Cursor c = ctx.getContentResolver().query(uri, new String[]{"_id"},
                "date=?", new String[]{Long.toString(when)}, null)) {
            if (c == null) return null;
            return c.moveToFirst();
        } catch (Throwable t) {
            return null;
        }
    }
}
