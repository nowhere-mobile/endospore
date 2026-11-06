package com.nowhere.chooser;

import android.content.Context;
import android.os.DropBoxManager;
import android.os.Process;
import android.os.UserManager;

/** This session's app crashes, read from DropBox for Profile › Report an issue (NWP-20261128-17, Q121 in
 *  docs/product-decisions.md, the 2026-10-20 "eighteen recommendations accepted" entry).
 *
 *  DropBox is device-wide, so four filters keep only this session's records: the four app-crash tags; a record time
 *  at or after this user's creation time (every sign-in is a new Android user); no {@code UID:} header line of
 *  another Android user (an inference the decision asks to check on a handset: a record with no such line is kept,
 *  as the start time already filters it); and the newest {@link #MAX}, each cut to {@link #MAX_CHARS} chars.
 *
 *  {@link #read} answers {@code access} "ok", "denied" or "error", and the report carries it: that value IS the
 *  decision's check whether PEEK_DROPBOX_DATA works on each edition. "denied" is ONLY a SecurityException from
 *  DropBox, the permission answer; any other failure, the UserManager read included, is "error".
 *
 *  Nothing here logs or writes a file: a crash text leaves the process only in the report the user previews and
 *  sends. The agent drops both keys from a gate report and scrubs the stacks. */
final class CrashRecords {
    private CrashRecords() {}

    static final java.util.List<String> TAGS = java.util.Collections.unmodifiableList(java.util.Arrays.asList(
            "data_app_crash", "data_app_native_crash", "system_app_crash", "system_app_native_crash"));
    static final int MAX = 5;
    static final int MAX_CHARS = 4096;
    static final int AID_USER = 100000;

    static final class Entry {
        final String tag;
        final long timeMs;
        final String text;
        Entry(String tag, long timeMs, String text) { this.tag = tag; this.timeMs = timeMs; this.text = text; }
    }

    static final class Result {
        final String access;
        final java.util.List<String> crashes;
        Result(String access, java.util.List<String> crashes) { this.access = access; this.crashes = crashes; }
    }

    static java.util.List<String> select(java.util.List<Entry> es, long sessionStartMs, int myUserId) {
        return select(es, sessionStartMs, myUserId, System.currentTimeMillis());
    }

    /** The newest {@link #MAX} entries that pass {@link #keep}, newest first, each as
     *  {@code "<tag> age_s=<n>\n"} and its text cut to {@link #MAX_CHARS} chars. Never null. */
    static java.util.List<String> select(java.util.List<Entry> es, long sessionStartMs, int myUserId, long nowMs) {
        java.util.List<Entry> kept = new java.util.ArrayList<>();
        if (es != null) for (Entry e : es) if (keep(e, sessionStartMs, myUserId)) kept.add(e);
        kept.sort((a, b) -> Long.compare(b.timeMs, a.timeMs));
        java.util.List<String> out = new java.util.ArrayList<>();
        for (Entry e : kept) {
            if (out.size() >= MAX) break;
            String t = e.text.length() > MAX_CHARS ? e.text.substring(0, MAX_CHARS) : e.text;
            out.add(e.tag + " age_s=" + Math.max(0L, (nowMs - e.timeMs) / 1000) + "\n" + t);
        }
        return out;
    }

    /** The filter: a crash tag, at or after the session start, and no header UID of another Android user. */
    static boolean keep(Entry e, long sessionStartMs, int myUserId) {
        if (e == null || e.tag == null || e.text == null || !TAGS.contains(e.tag)) return false;
        if (e.timeMs < sessionStartMs) return false;
        int uid = headerUid(e.text);
        return uid < 0 || uid / AID_USER == myUserId;
    }

    /** The rolling window of the reader: add {@code e} at the end, and drop the first (the oldest, as DropBox reads
     *  oldest first) while the window holds more than {@code cap}. */
    static void keepNewest(java.util.ArrayDeque<Entry> w, Entry e, int cap) {
        if (e == null) return;
        w.addLast(e);
        while (w.size() > cap) w.removeFirst();
    }

    /** The uid of the first {@code UID: <digits>} line before the first empty line, or -1. */
    static int headerUid(String text) {
        if (text == null) return -1;
        for (String ln : text.replace("\r\n", "\n").split("\n", -1)) {
            if (ln.isEmpty()) break;
            String s = ln.trim();
            if (!s.startsWith("UID:")) continue;
            String n = s.substring(4).trim();
            if (n.isEmpty()) return -1;
            for (int i = 0; i < n.length(); i++) if (n.charAt(i) < '0' || n.charAt(i) > '9') return -1;
            try { return Integer.parseInt(n); } catch (NumberFormatException x) { return -1; }
        }
        return -1;
    }

    /** Read this session's crashes. Never throws; run it off the UI thread. */
    static Result read(Context ctx) {
        final java.util.List<String> none = java.util.Collections.emptyList();
        try {
            long start;
            int me;
            try {
                UserManager um = ctx.getSystemService(UserManager.class);
                start = um.getUserCreationTime(Process.myUserHandle());
                me = Process.myUserHandle().getIdentifier();
            } catch (Throwable t) {
                return new Result("error", none); // not "denied": that answers only the DropBox permission check
            }
            DropBoxManager db = ctx.getSystemService(DropBoxManager.class);
            if (db == null) return new Result("error", none);
            java.util.List<Entry> es = new java.util.ArrayList<>();
            try {
                for (String tag : TAGS) {
                    java.util.ArrayDeque<Entry> w = new java.util.ArrayDeque<>();
                    long t = start - 1;
                    // Every record of the tag from the session start: DropBox serves oldest first, so a read cap
                    // would keep the oldest and lose the newest. DropBox's own quota bounds the count; the window
                    // keeps at most MAX of them.
                    while (true) {
                        DropBoxManager.Entry e = db.getNextEntry(tag, t);
                        if (e == null) break;
                        long time;
                        String etag, text;
                        try {
                            time = e.getTimeMillis();
                            etag = e.getTag();
                            text = e.getText(MAX_CHARS);
                        } finally {
                            e.close();
                        }
                        if (time <= t) break; // DropBox times increase strictly; this stops a read that cannot advance
                        t = time;
                        Entry en = new Entry(etag, time, text == null ? "" : text);
                        if (keep(en, start, me)) keepNewest(w, en, MAX);
                    }
                    es.addAll(w);
                }
            } catch (SecurityException se) {
                return new Result("denied", none);
            }
            return new Result("ok", select(es, start, me));
        } catch (Throwable t) {
            return new Result("error", none);
        }
    }
}
