package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** NWP-20261126-02: the rules of a beta profile's scheduled diagnostic reports (slice 2 of the backlog row "A beta
 *  profile has no way to send a diagnostic report on a schedule: every report is sent by hand, ..."). Decision of
 *  2026-11-02 in docs/product-decisions.md (NWP-20261102-29): on the beta stack only, a profile can opt in to a report
 *  every 6 hours with the day's summary; no counsel step (2026-11-03, NWP-20261103-23).
 *
 *  The agent's opt-in marker lives on the state tmpfs and dies at sign-out, so the choice roams here, in the profile's
 *  own files (getFilesDir(), carried by the profile seal). Pure: java.lang / java.util only, so the javac suite
 *  (core/vendor-common/bin/test-diag-reports-java.sh) runs it with no Android SDK. ProfileActivity.showReportIssue
 *  draws the switch, DiagReportJob sends the reports.
 *
 *  NWP-20261202-08: every arm, schedule, job start and stop, run outcome and send reply is kept as codes in RUNS_FILE,
 *  and a report made with the switch on carries it as diag_job (jobStatus), so a by-hand report names the step where
 *  the scheduled sender stops. */
final class DiagReports {
    private DiagReports() {}

    /** One line `on <onSince ms>`. Absent, empty or unparsable = off. */
    static final String OPT_FILE = "nowhere-diag-reports";
    /** The tester tag, "t-" + 10 of [a-z2-7]. */
    static final String TAG_FILE = "nowhere-diag-tag";
    /** ms of the last scheduled report the gateway took (an `OK ` reply). */
    static final String SENT_FILE = "nowhere-diag-sent";
    /** ms of the last job run on an unmetered validated network. */
    static final String WIFI_FILE = "nowhere-diag-wifi";
    /** NWP-20261202-08: the scheduled sender's run record, `<ms> <ev> <code>` per line, the newest RUNS_KEEP kept.
     *  Codes and ms only; a report carries it as diag_job, ages in minutes (jobStatus). */
    static final String RUNS_FILE = "nowhere-diag-runs";
    static final int RUNS_KEEP = 16;
    static final String RUN_EVENTS = "arm|on|off|sched|start|stop|run|send";
    static final String RUN_CODE = "[a-z0-9-]{1,16}";
    static final String RUN_LINE = "[0-9]{1,15} (" + RUN_EVENTS + ") " + RUN_CODE;

    static final long SIX_H = 6 * 3600_000L;
    static final long TWELVE_H = 12 * 3600_000L;

    static final String SEND = "SEND";
    static final String WAIT = "WAIT";

    static final String TITLE = "Send diagnostic reports";
    static final String SUBLINE = "Every 6 hours this phone sends the same report as Send report, with a summary of the "
            + "day's sign-ins, saves and app restores, and one tag that links the reports together. Only on the beta "
            + "service.";
    static final String RESET = "Reset tag";
    static final String ON_FAILED = "Couldn't turn on diagnostic reports.";
    static final String RESET_DONE = "New tag set. Reports from now on carry it.";
    static final String RESET_FAILED = "Couldn't set a new tag.";

    /** The tag alphabet (RFC 4648 base32, lower case): no 0, 1, 8 or 9, so a tag never reads as a long number. */
    static final String ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

    /** The agent's explicit off-beta reply, "OFFERED 0 ON <0|1>". An empty reply (no daemon, a timeout) is NOT this. */
    static boolean notOffered(String statusReply) {
        return statusReply != null && statusReply.trim().startsWith("OFFERED 0 ");
    }

    /** OPT_FILE's text says on. */
    static boolean optedIn(String text) {
        return text != null && text.trim().matches("on [0-9]{1,15}");
    }

    /** The ms the switch was turned on, from OPT_FILE's text; 0 when off. */
    static long onSince(String text) {
        return optedIn(text) ? Long.parseLong(text.trim().substring(3)) : 0L;
    }

    /** OPT_FILE's text for a switch turned on at {@code now}. */
    static String optLine(long now) {
        return "on " + now + "\n";
    }

    /** A ms file's value; 0 when absent or unparsable, never negative. */
    static long parseMs(String text) {
        if (text == null) return 0L;
        String t = text.trim();
        return t.matches("[0-9]{1,15}") ? Long.parseLong(t) : 0L;
    }

    /** A new tester tag. An all-digit body is drawn again: the agent's report scrub rewrites a run of 7 or more digits
     *  (report_issue.go, `\b\d{7,}\b`) to <num>, and the `-` before the body is a word boundary. */
    static String newTag(Random r) {
        while (true) {
            StringBuilder sb = new StringBuilder("t-");
            boolean letter = false;
            for (int i = 0; i < 10; i++) {
                char c = ALPHABET.charAt(r.nextInt(ALPHABET.length()));
                if (c >= 'a' && c <= 'z') letter = true;
                sb.append(c);
            }
            if (letter) return sb.toString();
        }
    }

    /** The tag has newTag's exact shape. */
    static boolean tagOk(String t) {
        return t != null && t.matches("t-[a-z2-7]{10}");
    }

    /** The agent's `DIAG-SUMMARY status` reply offers the switch: "OFFERED 1 ON <0|1>". */
    static boolean offered(String statusReply) {
        return statusReply != null && statusReply.trim().startsWith("OFFERED 1 ");
    }

    /** Offered, but the agent's marker is off (it died with the last session): send `DIAG-SUMMARY on` again. */
    static boolean armedOff(String statusReply) {
        return statusReply != null && statusReply.trim().equals("OFFERED 1 ON 0");
    }

    /** SEND or WAIT for one job run. Never while offline; never within 6 h of the last send (lastSent 0 = never sent);
     *  then on Wi-Fi, or on mobile data only after 12 h without Wi-Fi, counted from the switch's onSince when the job
     *  has not yet seen Wi-Fi. */
    static String due(long now, long lastSent, long lastWifi, long onSince, boolean onWifi, boolean online) {
        if (!online) return WAIT;
        if (lastSent > 0 && now - lastSent < SIX_H) return WAIT;
        if (onWifi) return SEND;
        if (now - Math.max(lastWifi, onSince) >= TWELVE_H) return SEND;
        return WAIT;
    }

    /** The two report status keys: the tag, and whether the job or the user sent it. */
    static Map<String, String> status(String tag, boolean scheduled) {
        Map<String, String> m = new LinkedHashMap<>();
        m.put("tester_tag", tag);
        m.put("report_kind", scheduled ? "scheduled" : "by_hand");
        return m;
    }

    /** The record's code for a daemon reply (`DIAG-SUMMARY on` or `REPORT-ISSUE`). An `OK <ticket>` is ok-ticket: the
     *  ticket is never kept. */
    static String replyClass(String r) {
        String t = r == null ? "" : r.trim();
        if (t.isEmpty()) return "noreply";
        if (t.equals("OK")) return "ok";
        if (t.startsWith("OK ")) return "ok-ticket";
        if (t.matches("ERR [0-9]+")) return "err-http";
        switch (t.split("\\s+", 2)[0]) {
            case "ERR-NOT-BETA": return "err-not-beta";
            case "DENIED": return "denied";
            case "ERR-STATE": return "err-state";
            case "ERR-NET": return "err-net";
            case "ERR-NOGW": return "err-nogw";
            case "ERR-TOOBIG": return "err-toobig";
            case "ERR-DISABLED": return "err-disabled";
            default: return "other";
        }
    }

    /** The record's code for a failed JobScheduler call. */
    static String throwCode(Throwable t) {
        if (t instanceof IllegalArgumentException) return "err-iae";
        if (t instanceof SecurityException) return "err-sec";
        if (t instanceof IllegalStateException) return "err-ise";
        return "err-other";
    }

    /** The record's code for a run's network state: o<online>w<onWifi>. */
    static String netCode(boolean online, boolean onWifi) {
        return "o" + (online ? 1 : 0) + "w" + (onWifi ? 1 : 0);
    }

    /** The report's two record keys: diag_job, RUNS_FILE's lines newest first as `<ev>:<code>:<age min>` (capped at
     *  999999, a future or unparsable line left out, `none` when no line is left), and diag_job_pending. Ages in
     *  minutes, so no ms and no time of day leaves the phone. */
    static Map<String, String> jobStatus(String runsText, long now, String pending) {
        StringBuilder sb = new StringBuilder();
        String[] ls = runsText == null ? new String[0] : runsText.split("\n");
        for (int i = ls.length - 1; i >= 0; i--) {
            String l = ls[i].trim();
            if (!l.matches(RUN_LINE)) continue;
            String[] f = l.split(" ");
            long ms = Long.parseLong(f[0]);
            if (ms > now) continue;
            long min = Math.min((now - ms) / 60_000L, 999_999L);
            if (sb.length() > 0) sb.append(',');
            sb.append(f[1]).append(':').append(f[2]).append(':').append(min);
        }
        Map<String, String> m = new LinkedHashMap<>();
        m.put("diag_job", sb.length() == 0 ? "none" : sb.toString());
        m.put("diag_job_pending", pending == null ? "err" : pending);
        return m;
    }

    // ---- The job run and the switch transitions, over a Port so the javac suite runs them with no Android SDK. ----

    /** What a run or a transition touches: the profile's files, the four daemon requests, the JobScheduler job, the
     *  network and the clock. DiagReportJob.AndroidPort is the device's; the suite's cases supply a fake. */
    interface Port {
        /** A profile file's text; "" when absent or unreadable. */
        String read(String file);
        /** Write a profile file whole; false on failure. */
        boolean write(String file, String text);
        void remove(String file);
        /** `DIAG-SUMMARY status`, `on` and `off`: the one reply line, "" when the daemon did not answer. */
        String status();
        String on();
        String off();
        /** One scheduled `REPORT-ISSUE` with these extra status keys; the one reply line. */
        String report(Map<String, String> extra);
        /** Schedule the job; the record's code (DiagReportJob.schedule). */
        String schedule();
        /** 1 when the job is pending, 0 when not, err when JobScheduler could not say. */
        String pending();
        void cancel();
        /** {online, onWifi}. */
        boolean[] net();
        long now();
        String newTag();
    }

    /** The consent lock. A transition holds it whole; a run holds it from its last read of OPT_FILE through its
     *  REPORT-ISSUE send. So once switchOff has removed OPT_FILE no run starts a send, and a send in flight finishes
     *  before switchOff goes on. */
    static final Object LOCK = new Object();

    /** record's own lock, never LOCK: onStopJob runs on the main thread while a send can hold LOCK 120 s. Nothing takes
     *  LOCK while it holds RUNS_LOCK. */
    static final Object RUNS_LOCK = new Object();

    /** The switch's transitions run here, one at a time and in tap order, so an older Off can never land after a
     *  newer On (a bare lock does not keep the order: two waiting threads take it in any order). */
    static final ExecutorService SWITCH = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "diag-switch");
        t.setDaemon(true);
        return t;
    });

    static final String R_OFF = "OFF";
    static final String R_NOT_OFFERED = "NOT-OFFERED";
    static final String R_UNAVAILABLE = "UNAVAILABLE";
    static final String R_STOPPED = "STOPPED";
    static final String R_WAIT = "WAIT";
    static final String R_SENT = "SENT";
    static final String R_NOT_SENT = "NOT-SENT";

    /** The tag, a new one written first when TAG_FILE is absent or holds another shape. */
    static String ensureTag(Port p) {
        String tag = p.read(TAG_FILE).trim();
        if (tagOk(tag)) return tag;
        tag = p.newTag();
        p.write(TAG_FILE, tag + "\n");
        return tag;
    }

    /** One line `<now> <ev> <code>` added to RUNS_FILE, the newest RUNS_KEEP kept, an unparsable old line dropped. An
     *  unknown ev records nothing; a code of another shape is recorded as other. A failed write is ignored and it never
     *  throws: the record is evidence, never a gate. */
    static void record(Port p, String ev, String code) {
        if (ev == null || !ev.matches(RUN_EVENTS)) return;
        String c = code != null && code.matches(RUN_CODE) ? code : "other";
        try {
            synchronized (RUNS_LOCK) {
                ArrayList<String> keep = new ArrayList<>();
                for (String l : p.read(RUNS_FILE).split("\n")) if (l.trim().matches(RUN_LINE)) keep.add(l.trim());
                keep.add(p.now() + " " + ev + " " + c);
                StringBuilder sb = new StringBuilder();
                for (int i = Math.max(0, keep.size() - RUNS_KEEP); i < keep.size(); i++) {
                    sb.append(keep.get(i)).append('\n');
                }
                p.write(RUNS_FILE, sb.toString());
            }
        } catch (Throwable ignore) {
            // never throws into a run or a transition
        }
    }

    /** A run's result, recorded as `run <result lower-cased>`. */
    static String ran(Port p, String r) {
        record(p, "run", r.toLowerCase(Locale.ROOT));
        return r;
    }

    /** One job run. The opt-in off: cancel. The agent says OFFERED 0: cancel, no report ever. No status reply (a
     *  timeout): skip this run only, the period stays. Then, under LOCK, OPT_FILE is read again and {@code stopped}
     *  (onStopJob) checked, so an Off or a stop during the status request sends nothing. At most one REPORT-ISSUE,
     *  never retried; only an `OK ` reply records SENT_FILE. Every step but an opt-in-off return is recorded in RUNS_FILE
     *  (NWP-20261202-08). */
    static String runJob(Port p, AtomicBoolean stopped) {
        if (!optedIn(p.read(OPT_FILE))) { p.cancel(); return R_OFF; }
        String st = p.status();
        if (notOffered(st)) { p.cancel(); return ran(p, R_NOT_OFFERED); }
        if (!offered(st)) return ran(p, R_UNAVAILABLE);
        synchronized (LOCK) {
            String opt = p.read(OPT_FILE);
            if (!optedIn(opt)) return R_OFF; // switchOff ran during the status request; it cancelled the job
            if (stopped.get()) return ran(p, R_STOPPED);
            if (armedOff(st)) p.on();
            boolean[] net = p.net();
            boolean online = net[0], onWifi = net[1];
            record(p, "run", netCode(online, onWifi));
            long now = p.now();
            if (onWifi) p.write(WIFI_FILE, now + "\n");
            long lastSent = parseMs(p.read(SENT_FILE));
            long lastWifi = parseMs(p.read(WIFI_FILE));
            if (!SEND.equals(due(now, lastSent, lastWifi, onSince(opt), onWifi, online))) return ran(p, R_WAIT);
            if (stopped.get()) return ran(p, R_STOPPED);
            String reply = p.report(status(ensureTag(p), true));
            record(p, "send", replyClass(reply));
            if (reply == null || !reply.startsWith("OK ")) return ran(p, R_NOT_SENT);
            p.write(SENT_FILE, p.now() + "\n");
            return ran(p, R_SENT);
        }
    }

    /** The switch turned on: OPT_FILE, the tag, `DIAG-SUMMARY on`; only an OK schedules the job, anything else
     *  (ERR-NOT-BETA included) removes OPT_FILE again. True when on. Run it on SWITCH. */
    static boolean switchOn(Port p) {
        synchronized (LOCK) {
            if (!p.write(OPT_FILE, optLine(p.now()))) return false;
            ensureTag(p);
            String r = p.on();
            record(p, "on", replyClass(r));
            boolean ok = r != null && "OK".equals(r.trim());
            if (ok) record(p, "sched", p.schedule());
            else p.remove(OPT_FILE);
            return ok;
        }
    }

    /** The switch turned off: OPT_FILE removed, `DIAG-SUMMARY off`, the job cancelled. Run it on SWITCH. */
    static void switchOff(Port p) {
        synchronized (LOCK) {
            p.remove(OPT_FILE);
            p.off();
            p.cancel();
            record(p, "off", "ok"); // the one record made with the opt-in gone
        }
    }

    /** At a session landing: the opt-in roamed in, the agent's marker did not. Re-arm both, or cancel. */
    static void arm(Port p) {
        synchronized (LOCK) {
            if (!optedIn(p.read(OPT_FILE))) { p.cancel(); return; }
            record(p, "arm", replyClass(p.on()));
            record(p, "sched", p.schedule());
        }
    }
}
