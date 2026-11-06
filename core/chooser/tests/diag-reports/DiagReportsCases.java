package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** NWP-20261126-02: executes DiagReports, the rules of a beta profile's scheduled diagnostic reports. */
public class DiagReportsCases {
    static int runs = 0, fails = 0;
    static final long H = 3600_000L;

    static void eq(String name, Object want, Object got) {
        runs++;
        if (want == null ? got != null : !want.equals(got)) {
            fails++;
            System.out.println("FAIL " + name + "\n     want " + want + ", got " + got);
        }
    }

    /** A Random whose first {@code digits} draws are digit indexes of ALPHABET (26..31), then letters. */
    static Random digitsFirst(final int digits) {
        return new Random(1) {
            int n = 0;
            @Override public int nextInt(int bound) { return n++ < digits ? 26 + (n % 6) : 0; }
        };
    }

    /** A DiagReports.Port that records every call; the hooks run inside status / report / off. */
    static class Fake implements DiagReports.Port {
        final Map<String, String> files = Collections.synchronizedMap(new HashMap<>());
        final List<String> ev = Collections.synchronizedList(new ArrayList<>());
        volatile String statusReply = "OFFERED 1 ON 1", onReply = "OK", reportReply = "OK 4711";
        volatile boolean online = true, wifi = true;
        volatile long now = 1_800_000_000_000L;
        volatile Runnable duringStatus, duringReport, duringOff;
        Fake optIn() { files.put(DiagReports.OPT_FILE, DiagReports.optLine(now - 24 * H)); return this; }
        @Override public String read(String f) { String v = files.get(f); return v == null ? "" : v; }
        @Override public boolean write(String f, String t) { files.put(f, t); ev.add("write " + f); return true; }
        @Override public void remove(String f) { files.remove(f); ev.add("remove " + f); }
        @Override public String status() { ev.add("status"); Runnable r = duringStatus; if (r != null) r.run(); return statusReply; }
        @Override public String on() { ev.add("on"); return onReply; }
        @Override public String off() { ev.add("off"); Runnable r = duringOff; if (r != null) r.run(); return "OK"; }
        @Override public String report(Map<String, String> extra) {
            ev.add("report " + extra); Runnable r = duringReport; if (r != null) r.run(); ev.add("report done"); return reportReply;
        }
        @Override public void schedule() { ev.add("schedule"); }
        @Override public void cancel() { ev.add("cancel"); }
        @Override public boolean[] net() { return new boolean[] {online, wifi}; }
        @Override public long now() { return now; }
        @Override public String newTag() { return "t-abcdefghij"; }
        int count(String prefix) { int n = 0; synchronized (ev) { for (String e : ev) if (e.startsWith(prefix)) n++; } return n; }
        int last(String e) { synchronized (ev) { return ev.lastIndexOf(e); } }
    }

    /** Run {@code r} on another thread and wait for it ({@code waitMs} at most); true when it finished. */
    static boolean onOtherThread(Runnable r, long waitMs) {
        Thread t = new Thread(r);
        t.setDaemon(true);
        t.start();
        try { t.join(waitMs); } catch (InterruptedException e) { return false; }
        return !t.isAlive();
    }

    static void await(CountDownLatch l) { try { l.await(5, TimeUnit.SECONDS); } catch (InterruptedException ignore) {} }

    static void jobAndSwitch() throws Exception {
        // D6 runJob.
        Fake f = new Fake().optIn();
        eq("D6 on, offered, Wi-Fi, never sent -> SENT", DiagReports.R_SENT, DiagReports.runJob(f, new AtomicBoolean()));
        eq("D6 the report carries the tag and report_kind=scheduled", 1, f.count("report {tester_tag=t-abcdefghij, report_kind=scheduled}"));
        eq("D6 an OK reply records SENT_FILE", true, f.files.containsKey(DiagReports.SENT_FILE));
        eq("D6 a sent run does not cancel", 0, f.count("cancel"));

        f = new Fake();
        eq("D6 the opt-in off -> OFF", DiagReports.R_OFF, DiagReports.runJob(f, new AtomicBoolean()));
        eq("D6 the opt-in off cancels the job", 1, f.count("cancel"));
        eq("D6 the opt-in off asks no status and sends nothing", 0, f.count("status") + f.count("report"));

        f = new Fake().optIn(); f.statusReply = "OFFERED 0 ON 0";
        eq("D6 OFFERED 0 -> NOT-OFFERED", DiagReports.R_NOT_OFFERED, DiagReports.runJob(f, new AtomicBoolean()));
        eq("D6 OFFERED 0 cancels the job", 1, f.count("cancel"));
        eq("D6 OFFERED 0 sends no report", 0, f.count("report"));

        f = new Fake().optIn(); f.statusReply = "";
        eq("D6 no status reply -> UNAVAILABLE", DiagReports.R_UNAVAILABLE, DiagReports.runJob(f, new AtomicBoolean()));
        eq("D6 no status reply keeps the schedule (no cancel)", 0, f.count("cancel"));
        eq("D6 no status reply sends no report", 0, f.count("report"));
        f = new Fake().optIn(); f.statusReply = "garbage";
        eq("D6 a garbage status reply keeps the schedule (no cancel)", 0, f.count("cancel"));
        eq("D6 a garbage status reply -> UNAVAILABLE", DiagReports.R_UNAVAILABLE, DiagReports.runJob(f, new AtomicBoolean()));

        final Fake g = new Fake().optIn();
        g.duringStatus = () -> eq("D6 the Off during the status request finished", true,
                onOtherThread(() -> DiagReports.switchOff(g), 2000));
        eq("D6 an Off during the status request -> OFF", DiagReports.R_OFF, DiagReports.runJob(g, new AtomicBoolean()));
        eq("D6 an Off during the status request sends no report", 0, g.count("report"));
        eq("D6 the Off removed OPT_FILE and cancelled", true, !g.files.containsKey(DiagReports.OPT_FILE) && g.count("cancel") == 1);

        final AtomicBoolean stop = new AtomicBoolean();
        f = new Fake().optIn(); f.duringStatus = () -> stop.set(true);
        eq("D6 a stop during the status request -> STOPPED", DiagReports.R_STOPPED, DiagReports.runJob(f, stop));
        eq("D6 a stop during the status request sends no report", 0, f.count("report"));

        f = new Fake().optIn(); f.statusReply = "OFFERED 1 ON 0";
        DiagReports.runJob(f, new AtomicBoolean());
        eq("D6 armedOff sends DIAG-SUMMARY on before the report", true, f.last("on") >= 0 && f.last("on") < f.last("report done"));

        f = new Fake().optIn(); f.reportReply = "ERR-GATEWAY";
        eq("D6 an ERR reply -> NOT-SENT", DiagReports.R_NOT_SENT, DiagReports.runJob(f, new AtomicBoolean()));
        eq("D6 an ERR reply records no SENT_FILE", false, f.files.containsKey(DiagReports.SENT_FILE));
        eq("D6 an ERR reply is not retried", 1, f.count("report {"));

        f = new Fake().optIn(); f.files.put(DiagReports.SENT_FILE, (f.now - H) + "\n");
        eq("D6 sent 1 h ago -> WAIT", DiagReports.R_WAIT, DiagReports.runJob(f, new AtomicBoolean()));
        eq("D6 sent 1 h ago sends no report", 0, f.count("report"));

        f = new Fake().optIn(); f.online = false; f.wifi = false;
        eq("D6 offline -> WAIT", DiagReports.R_WAIT, DiagReports.runJob(f, new AtomicBoolean()));

        final Fake k = new Fake().optIn();
        final boolean[] offDuringSend = {false};
        final Thread[] offT = {null};
        k.duringReport = () -> {
            offT[0] = new Thread(() -> DiagReports.switchOff(k));
            offT[0].setDaemon(true);
            offT[0].start();
            try { offT[0].join(300); } catch (InterruptedException ignore) {}
            offDuringSend[0] = !k.files.containsKey(DiagReports.OPT_FILE);
        };
        DiagReports.runJob(k, new AtomicBoolean());
        offT[0].join(2000);
        eq("D6 an Off tapped during a send waits for it (the consent lock)", false, offDuringSend[0]);
        eq("D6 that Off lands after the send", true, k.last("remove " + DiagReports.OPT_FILE) > k.last("report done"));

        // D7 the switch's transitions.
        f = new Fake();
        eq("D7 switchOn with OK -> true", true, DiagReports.switchOn(f));
        eq("D7 switchOn writes OPT_FILE and the tag, schedules", true, DiagReports.optedIn(f.read(DiagReports.OPT_FILE))
                && DiagReports.tagOk(f.read(DiagReports.TAG_FILE).trim()) && f.count("schedule") == 1);
        f = new Fake(); f.onReply = "ERR-NOT-BETA";
        eq("D7 switchOn with ERR-NOT-BETA -> false", false, DiagReports.switchOn(f));
        eq("D7 switchOn with ERR-NOT-BETA removes OPT_FILE, no schedule", true,
                !f.files.containsKey(DiagReports.OPT_FILE) && f.count("schedule") == 0);
        f = new Fake(); f.onReply = "";
        eq("D7 switchOn with no reply -> false", false, DiagReports.switchOn(f));
        f = new Fake().optIn();
        DiagReports.switchOff(f);
        eq("D7 switchOff removes OPT_FILE, sends off, cancels", true,
                !f.files.containsKey(DiagReports.OPT_FILE) && f.count("off") == 1 && f.count("cancel") == 1);
        f = new Fake().optIn();
        DiagReports.arm(f);
        eq("D7 arm with the opt-in on sends on and schedules", true, f.count("on") == 1 && f.count("schedule") == 1);
        f = new Fake();
        DiagReports.arm(f);
        eq("D7 arm with the opt-in off only cancels", true, f.count("cancel") == 1 && f.count("on") + f.count("schedule") == 0);

        // D7 SWITCH runs one transition at a time, in submit order.
        final CountDownLatch hold = new CountDownLatch(1);
        final AtomicBoolean second = new AtomicBoolean();
        Future<?> a = DiagReports.SWITCH.submit(() -> await(hold));
        Future<?> b = DiagReports.SWITCH.submit(() -> second.set(true));
        Thread.sleep(200);
        eq("D7 SWITCH does not start a second transition while one runs", false, second.get());
        hold.countDown();
        a.get(5, TimeUnit.SECONDS); b.get(5, TimeUnit.SECONDS);

        // D7 an Off whose request is slow, then a newer On: the final state is on and scheduled.
        final Fake o = new Fake().optIn();
        final CountDownLatch slowOff = new CountDownLatch(1);
        o.duringOff = () -> await(slowOff);
        Future<?> off = DiagReports.SWITCH.submit(() -> DiagReports.switchOff(o));
        Future<Boolean> on = DiagReports.SWITCH.submit(() -> DiagReports.switchOn(o));
        Thread.sleep(200);
        eq("D7 the newer On waits for the older Off", 0, o.count("on"));
        slowOff.countDown();
        off.get(5, TimeUnit.SECONDS);
        eq("D7 the newer On succeeds", true, on.get(5, TimeUnit.SECONDS));
        eq("D7 after Off then On: OPT_FILE on", true, DiagReports.optedIn(o.read(DiagReports.OPT_FILE)));
        eq("D7 after Off then On: the agent's last request is on", true, o.last("on") > o.last("off"));
        eq("D7 after Off then On: the job is scheduled after the cancel", true, o.last("schedule") > o.last("cancel"));
    }

    public static void main(String[] args) throws Exception {
        // D1 offered: only "OFFERED 1 ...".
        eq("D1 offered(\"OFFERED 1 ON 0\")", true, DiagReports.offered("OFFERED 1 ON 0"));
        eq("D1 offered(\"OFFERED 1 ON 1\")", true, DiagReports.offered("OFFERED 1 ON 1"));
        eq("D1 offered(\" OFFERED 1 ON 1\\n\")", true, DiagReports.offered(" OFFERED 1 ON 1\n"));
        eq("D1 offered(\"OFFERED 0 ON 1\")", false, DiagReports.offered("OFFERED 0 ON 1"));
        eq("D1 offered(\"OFFERED 0 ON 0\")", false, DiagReports.offered("OFFERED 0 ON 0"));
        eq("D1 offered(\"OFFERED 10 ON 0\")", false, DiagReports.offered("OFFERED 10 ON 0"));
        eq("D1 offered(\"DENIED\")", false, DiagReports.offered("DENIED"));
        eq("D1 offered(\"garbage\")", false, DiagReports.offered("garbage"));
        eq("D1 offered(\"\")", false, DiagReports.offered(""));
        eq("D1 offered(null)", false, DiagReports.offered(null));

        // D2 armedOff: offered and the agent's marker off.
        eq("D2 armedOff(\"OFFERED 1 ON 0\")", true, DiagReports.armedOff("OFFERED 1 ON 0"));
        eq("D2 armedOff(\"OFFERED 1 ON 1\")", false, DiagReports.armedOff("OFFERED 1 ON 1"));
        eq("D2 armedOff(\"OFFERED 0 ON 0\")", false, DiagReports.armedOff("OFFERED 0 ON 0"));
        eq("D2 armedOff(\"\")", false, DiagReports.armedOff(""));
        eq("D2 armedOff(null)", false, DiagReports.armedOff(null));

        // D3 newTag / tagOk.
        Random r = new Random(1535);
        boolean allOk = true;
        for (int i = 0; i < 1000; i++) {
            String t = DiagReports.newTag(r);
            if (!DiagReports.tagOk(t) || !t.startsWith("t-")) { allOk = false; System.out.println("     bad tag " + t); break; }
        }
        eq("D3 1000 newTag draws are tagOk", true, allOk);
        String redraw = DiagReports.newTag(digitsFirst(10));
        eq("D3 an all-digit body is drawn again", "t-aaaaaaaaaa", redraw);
        String nine = DiagReports.newTag(digitsFirst(9));
        eq("D3 nine digits and a letter are kept", true, nine.matches("t-[2-7]{9}a"));
        eq("D3 tagOk(\"t-k3m7qa2zpx\")", true, DiagReports.tagOk("t-k3m7qa2zpx"));
        eq("D3 tagOk rejects upper case", false, DiagReports.tagOk("T-K3M7QA2ZPX"));
        eq("D3 tagOk rejects upper-case body", false, DiagReports.tagOk("t-K3m7qa2zpx"));
        eq("D3 tagOk rejects 32 hex", false, DiagReports.tagOk("0123456789abcdef0123456789abcdef"));
        eq("D3 tagOk rejects too short", false, DiagReports.tagOk("t-abc"));
        eq("D3 tagOk rejects too long", false, DiagReports.tagOk("t-k3m7qa2zpxx"));
        eq("D3 tagOk rejects 1 (not in the alphabet)", false, DiagReports.tagOk("t-k3m7qa2zp1"));
        eq("D3 tagOk rejects 8 (not in the alphabet)", false, DiagReports.tagOk("t-k3m7qa2zp8"));
        eq("D3 tagOk rejects a trailing newline", false, DiagReports.tagOk("t-k3m7qa2zpx\n"));
        eq("D3 tagOk(null)", false, DiagReports.tagOk(null));

        // D4 due(now, lastSent, lastWifi, onSince, onWifi, online).
        long now = 1_800_000_000_000L;
        eq("D4 offline -> WAIT", DiagReports.WAIT, DiagReports.due(now, 0, 0, now - 24 * H, true, false));
        eq("D4 Wi-Fi, never sent -> SEND", DiagReports.SEND, DiagReports.due(now, 0, 0, now, true, true));
        eq("D4 Wi-Fi, sent 6 h - 1 ms ago -> WAIT", DiagReports.WAIT, DiagReports.due(now, now - 6 * H + 1, now, now - 24 * H, true, true));
        eq("D4 Wi-Fi, sent 6 h ago -> SEND", DiagReports.SEND, DiagReports.due(now, now - 6 * H, now, now - 24 * H, true, true));
        eq("D4 mobile, no Wi-Fi seen, on 12 h - 1 ms -> WAIT", DiagReports.WAIT, DiagReports.due(now, 0, 0, now - 12 * H + 1, false, true));
        eq("D4 mobile, no Wi-Fi seen, on 12 h -> SEND", DiagReports.SEND, DiagReports.due(now, 0, 0, now - 12 * H, false, true));
        eq("D4 mobile, Wi-Fi 1 h ago, on long ago -> WAIT", DiagReports.WAIT, DiagReports.due(now, 0, now - H, now - 48 * H, false, true));
        eq("D4 mobile, Wi-Fi 12 h ago, sent 7 h ago -> SEND", DiagReports.SEND, DiagReports.due(now, now - 7 * H, now - 12 * H, now - 48 * H, false, true));
        eq("D4 mobile, Wi-Fi 13 h ago, sent 5 h ago -> WAIT", DiagReports.WAIT, DiagReports.due(now, now - 5 * H, now - 13 * H, now - 48 * H, false, true));

        // D5 status keys and the file parsers.
        Map<String, String> s = DiagReports.status("t-k3m7qa2zpx", true);
        eq("D5 status(tag, true)", "{tester_tag=t-k3m7qa2zpx, report_kind=scheduled}", s.toString());
        eq("D5 status(tag, false)", "{tester_tag=t-k3m7qa2zpx, report_kind=by_hand}", DiagReports.status("t-k3m7qa2zpx", false).toString());
        eq("D5 optedIn(optLine)", true, DiagReports.optedIn(DiagReports.optLine(now)));
        eq("D5 onSince(optLine)", now, DiagReports.onSince(DiagReports.optLine(now)));
        eq("D5 optedIn(\"\")", false, DiagReports.optedIn(""));
        eq("D5 optedIn(null)", false, DiagReports.optedIn(null));
        eq("D5 optedIn(\"off\")", false, DiagReports.optedIn("off"));
        eq("D5 optedIn(\"on\")", false, DiagReports.optedIn("on"));
        eq("D5 optedIn(\"on x\")", false, DiagReports.optedIn("on x"));
        eq("D5 onSince(\"junk\")", 0L, DiagReports.onSince("junk"));
        eq("D5 parseMs(\"123\\n\")", 123L, DiagReports.parseMs("123\n"));
        eq("D5 parseMs(\"\")", 0L, DiagReports.parseMs(""));
        eq("D5 parseMs(\"-5\")", 0L, DiagReports.parseMs("-5"));
        eq("D5 parseMs(null)", 0L, DiagReports.parseMs(null));

        jobAndSwitch();

        System.out.println(runs + " cases, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
