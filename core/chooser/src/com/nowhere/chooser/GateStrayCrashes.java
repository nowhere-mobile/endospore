package com.nowhere.chooser;

import java.util.LinkedHashMap;
import java.util.Set;

/**
 * NWP-20261210-24: what a GATE issue report carries for the backlog row "Stray broadcasts wake providers INTO a user
 * whose CE storage is already gone, and they crash on the gate (NWP-20260826-10 tail)". The row saw the same two
 * platform providers crash in a user whose storage was gone, after a sign-out (lynx) and during a sign-in (husky). Its
 * next step is a measurement: is this routine or rare? One gate report now answers that for the current boot.
 *
 * What it counts. DropBox's four app-crash tags (CrashRecords.TAGS), records at or after this boot, whose Process
 * header is EXACTLY one of the two providers the row names ({@link #CAL}, {@link #MEDIA}), in an Android user other
 * than 0 and other than a running one: a user that is "gone" (no longer exists) or "stopped" (exists, not running).
 * A record of one of the two with no UID header counts as "nouid" only, which also answers Q121's open check whether
 * a header carries the uid. A record of any other process is not counted at all, not even as a total.
 *
 * Gate scope (Q121 in docs/product-decisions.md, the 2026-10-20 "eighteen recommendations accepted" entry). The gate
 * preview shows the report to whoever holds the phone, and a gate report stays crash-free. So this carries no record,
 * no record text, no process or app name and no user id: only gate_crash_access (ok, denied or error) and five
 * bucketed counts ("0".."9", then "10+"). The record text is read into a local, reduced to its process header, its
 * uid and its time, and dropped. Nothing here logs or writes a file.
 *
 * Retention. On this OS DropBox keeps 2 hours and 200 files (nowhere_provision.sh), so "since boot" means since boot
 * within that window; the 200-entry read cap per tag never truncates it.
 *
 * Every value is a String (the daemon decodes the report's status as map[string]string) and every key is always
 * written: a missing key means an older chooser. A failed user or DropBox read writes "unreadable" for every count.
 */
final class GateStrayCrashes {
    private GateStrayCrashes() {}

    static final String CAL = "com.android.providers.calendar";
    static final String MEDIA = "android.process.media";
    static final int MAX_READ = 200;

    /** The trimmed value of the first {@code Process:} line before the first empty line, or null. */
    static String process(String text) {
        if (text == null) return null;
        for (String ln : text.replace("\r\n", "\n").split("\n", -1)) {
            if (ln.isEmpty()) break;
            String s = ln.trim();
            if (!s.startsWith("Process:")) continue;
            return s.substring(8).trim();
        }
        return null;
    }

    /** "calendar" or "media" for an exact match of one of the two providers, else null. */
    static String code(String process) {
        if (CAL.equals(process)) return "calendar";
        if (MEDIA.equals(process)) return "media";
        return null;
    }

    /** "nouid" for no uid; null for user 0 and a running user (the live session's own report covers it); "stopped"
     *  for a user that exists and is not running; else "gone". */
    static String userState(int uid, Set<Integer> existing, Set<Integer> running) {
        if (uid < 0) return "nouid";
        int user = uid / CrashRecords.AID_USER;
        if (user == 0) return null;
        if (running.contains(user)) return null;
        if (existing.contains(user)) return "stopped";
        return "gone";
    }

    /** "0".."9", then "10+". */
    static String bucket(int n) {
        if (n <= 0) return "0";
        return n >= 10 ? "10+" : String.valueOf(n);
    }

    /** The five counts, bucketed, over parallel arrays of a record's process, time and header uid. */
    static LinkedHashMap<String, String> tally(String[] procs, long[] times, int[] uids, long bootMs,
            Set<Integer> existing, Set<Integer> running) {
        int cal = 0, media = 0, gone = 0, stopped = 0, nouid = 0;
        for (int i = 0; i < procs.length; i++) {
            String c = code(procs[i]);
            if (c == null) continue;
            if (times[i] < bootMs) continue;
            String s = userState(uids[i], existing, running);
            if (s == null) continue;
            if (s.equals("nouid")) { nouid++; continue; }
            if (c.equals("calendar")) cal++; else media++;
            if (s.equals("gone")) gone++; else stopped++;
        }
        LinkedHashMap<String, String> m = new LinkedHashMap<>();
        m.put("stray_crash_calendar", bucket(cal));
        m.put("stray_crash_media", bucket(media));
        m.put("stray_crash_gone", bucket(gone));
        m.put("stray_crash_stopped", bucket(stopped));
        m.put("stray_crash_nouid", bucket(nouid));
        return m;
    }

    static final String[] COUNT_KEYS = {
        "stray_crash_calendar", "stray_crash_media", "stray_crash_gone", "stray_crash_stopped", "stray_crash_nouid",
    };

    private static void putQuiet(org.json.JSONObject st, String k, String v) {
        try { st.put(k, v); } catch (Throwable ignore) {}
    }

    /** Writes gate_crash_access and the five counts; "unreadable" for every count when counts is null. */
    private static void write(org.json.JSONObject st, String access, java.util.Map<String, String> counts) {
        putQuiet(st, "gate_crash_access", access);
        for (String k : COUNT_KEYS) putQuiet(st, k, counts == null ? "unreadable" : counts.get(k));
    }

    /** Never throws; run it off the UI thread (both gateReportJson callers do). */
    static void put(android.content.Context ctx, org.json.JSONObject st) {
        try {
            long bootMs = System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime();
            java.util.HashSet<Integer> existing = new java.util.HashSet<>();
            java.util.HashSet<Integer> running = new java.util.HashSet<>();
            // The users as GateAlarmReceiver reads them. A failed read is "error", never "denied" and never empty.
            try {
                android.app.admin.DevicePolicyManager dpm =
                        ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
                android.os.UserManager um = ctx.getSystemService(android.os.UserManager.class);
                if (dpm == null || um == null || !dpm.isDeviceOwnerApp(ctx.getPackageName())) {
                    write(st, "error", null);
                    return;
                }
                java.util.List<android.os.UserHandle> us =
                        dpm.getSecondaryUsers(new android.content.ComponentName(ctx, AdminReceiver.class));
                if (us == null) {
                    write(st, "error", null);
                    return;
                }
                for (android.os.UserHandle uh : us) {
                    existing.add(uh.getIdentifier());
                    if (um.isUserRunning(uh)) running.add(uh.getIdentifier());
                }
            } catch (Throwable t) {
                write(st, "error", null);
                return;
            }
            android.os.DropBoxManager db = ctx.getSystemService(android.os.DropBoxManager.class);
            if (db == null) {
                write(st, "error", null);
                return;
            }
            java.util.ArrayList<String> procs = new java.util.ArrayList<>();
            java.util.ArrayList<Long> times = new java.util.ArrayList<>();
            java.util.ArrayList<Integer> uids = new java.util.ArrayList<>();
            try {
                for (String tag : CrashRecords.TAGS) {
                    long t = bootMs - 1;
                    for (int n = 0; n < MAX_READ; n++) {
                        android.os.DropBoxManager.Entry e = db.getNextEntry(tag, t);
                        if (e == null) break;
                        long time;
                        String p;
                        int uid;
                        try {
                            time = e.getTimeMillis();
                            String text = e.getText(CrashRecords.MAX_CHARS);
                            p = process(text);
                            uid = CrashRecords.headerUid(text);
                        } finally {
                            e.close();
                        }
                        if (time <= t) break; // DropBox times increase strictly; this stops a read that cannot advance
                        t = time;
                        procs.add(code(p) == null ? null : p); // keep no other process's name, not even here
                        times.add(time);
                        uids.add(uid);
                    }
                }
            } catch (SecurityException se) {
                write(st, "denied", null); // ONLY the DropBox permission answer
                return;
            }
            int n = procs.size();
            String[] pa = procs.toArray(new String[0]);
            long[] ta = new long[n];
            int[] ua = new int[n];
            for (int i = 0; i < n; i++) {
                ta[i] = times.get(i);
                ua[i] = uids.get(i);
            }
            write(st, "ok", tally(pa, ta, ua, bootMs, existing, running));
        } catch (Throwable t) {
            write(st, "error", null);
        }
    }
}
