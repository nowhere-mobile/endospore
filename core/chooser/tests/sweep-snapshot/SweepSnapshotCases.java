package com.nowhere.chooser;

import java.util.LinkedHashSet;
import java.util.Set;

/** NWP-20261203-07: SweepSnapshot, compiled with that file ALONE and executed by
 *  core/vendor-common/bin/test-sweep-snapshot-java.sh. argv[0] is the agent's reIssueKV pattern, read from
 *  core/agent/report_issue.go by the suite, so C10 runs the REAL scrub over the values. */
public final class SweepSnapshotCases {
    static int bad = 0;
    static final Set<String> failed = new LinkedHashSet<>();
    static void check(String id, boolean cond, String what) {
        if (cond) return;
        System.out.println("FAIL " + id + " " + what);
        failed.add(id);
        bad++;
    }
    static void ok(String id, String what) { if (!failed.contains(id)) System.out.println("ok " + id + " " + what); }

    static StackTraceElement f(String cls, String method, int line) {
        return new StackTraceElement(cls, method, "Secret" + "File.java", line);
    }

    static final long NOW = 1_000_000L;

    public static void main(String[] args) {
        String kv = args.length > 0 ? args[0] : "";
        Thread sweep = new Thread(() -> {}, "secret-name-NWP0703");
        Thread tap = new Thread(() -> {}, "secret-name-NWP0703-tap");
        String st = sweep.getState().name();

        // C1 idle
        check("C1", "idle".equals(SweepSnapshot.state(null, NOW)), "a null input is not exactly idle");
        check("C1", "idle".equals(SweepSnapshot.state(new SweepSnapshot.Input(null, 0L, tap, 1, 2, 3, 4), NOW)),
                "no sweep thread is not exactly idle");
        ok("C1", "no sweep thread reads exactly idle");

        // C2 running, lane free, the whole line
        SweepSnapshot.Input free = new SweepSnapshot.Input(sweep, NOW - 37_500L, null, 0, 1, 2, 3);
        String freeLine = SweepSnapshot.state(free, NOW);
        String want = "running age_s=37 thread=" + st + " lane=free lane_queue=0 taps=1 queue=2 workers=3";
        check("C2", want.equals(freeLine), "lane free: got [" + freeLine + "], want [" + want + "]");
        check("C2", SweepSnapshot.state(new SweepSnapshot.Input(sweep, NOW + 5_000L, null, 0, 0, 0, 0), NOW)
                .startsWith("running age_s=0 "), "a start after now is not age_s=0");
        ok("C2", "running with a free lane is the whole line, age in seconds");

        // C3 the sweep holds the lane
        SweepSnapshot.Input own = new SweepSnapshot.Input(sweep, NOW, sweep, 2, 0, 5, 1);
        String ownLine = SweepSnapshot.state(own, NOW);
        check("C3", ownLine.contains(" lane=sweep lane_queue=2 "), "the sweep's own lane is not lane=sweep: " + ownLine);
        check("C3", SweepSnapshot.tapHolder(own) == null, "tapHolder is not null when the sweep holds the lane");
        ok("C3", "the sweep holding the lane reads lane=sweep, no tap holder");

        // C4 a tap holds the lane
        SweepSnapshot.Input tapIn = new SweepSnapshot.Input(sweep, NOW, tap, 1, 1, 4, 2);
        String tapLine = SweepSnapshot.state(tapIn, NOW);
        check("C4", tapLine.contains(" lane=tap lane_queue=1 "), "a tap holding the lane is not lane=tap: " + tapLine);
        check("C4", SweepSnapshot.tapHolder(tapIn) == tap, "tapHolder is not the tap thread");
        check("C4", SweepSnapshot.tapHolder(free) == null, "tapHolder is not null on a free lane");
        ok("C4", "a tap holding the lane reads lane=tap and is the tap holder");

        // C5 an app's class is ?
        String app = SweepSnapshot.frames(new StackTraceElement[] {
            f("com.example.app.Main", "run", 12), f("org.unknown.Foo$$Lambda$3", "accept", -1),
        });
        check("C5", "? < ?".equals(app), "an app class or unknown lambda is not ?: [" + app + "]");
        check("C5", !app.contains("example") && !app.contains("unknown"), "an app class name is sent: " + app);
        ok("C5", "an app class and a lambda in an unknown package are written ?");

        // C6 chooser and platform frames are kept
        String kept = SweepSnapshot.frames(new StackTraceElement[] {
            f("com.nowhere.chooser.UnarchiveService", "materializeAndInstall", 1450),
            f("android.os.BinderProxy", "transact", 584),
        });
        String keptWant = "com.nowhere.chooser.UnarchiveService.materializeAndInstall:1450 < android.os.BinderProxy.transact:584";
        check("C6", keptWant.equals(kept), "chooser + platform frames: got [" + kept + "]");
        check("C6", !kept.contains("SecretFile"), "a frame's file name is sent");
        ok("C6", "a chooser frame and an android.os.BinderProxy frame keep method and line");

        // C7 at most 12 frames
        StackTraceElement[] thirteen = new StackTraceElement[13];
        for (int i = 0; i < 13; i++) thirteen[i] = f("java.lang.Frame" + i, "m" + i, i + 1);
        String twelve = SweepSnapshot.frames(thirteen);
        int parts = twelve.split(" < ", -1).length;
        check("C7", parts == 12, "13 frames gave " + parts + " parts");
        check("C7", !twelve.contains("m12:"), "the 13th frame is sent");
        ok("C7", "13 frames are cut to 12");

        // C8 1500-char cap
        StringBuilder m = new StringBuilder();
        for (int i = 0; i < 2000; i++) m.append('a');
        String longOne = SweepSnapshot.frames(new StackTraceElement[] { f("java.lang.Thread", m.toString(), 1) });
        check("C8", longOne.length() == 1500, "a 2000-char frame gave " + longOne.length() + " chars, not 1500");
        ok("C8", "the value is cut to 1500 chars");

        // C9 the thread's name never appears
        String all = freeLine + ownLine + tapLine + SweepSnapshot.state(tapIn, NOW)
                + SweepSnapshot.frames(sweep.getStackTrace()) + SweepSnapshot.frames(tap.getStackTrace())
                + SweepSnapshot.frames(Thread.currentThread().getStackTrace());
        check("C9", !all.contains("secret-name") && !all.contains("NWP0703"), "a thread name is in an output: " + all);
        ok("C9", "no output carries a thread name");

        // C10 the agent's KV scrub leaves the values whole
        check("C10", !kv.isEmpty(), "no reIssueKV pattern was passed");
        if (!kv.isEmpty()) {
            for (String v : new String[] { freeLine, tapLine, kept }) {
                String s = v.replaceAll(kv, "$1$2<redacted>");
                check("C10", s.equals(v), "the agent's reIssueKV scrub changes [" + v + "] to [" + s + "]");
            }
        }
        ok("C10", "the agent's reIssueKV scrub leaves the state line and the frames whole");

        if (bad > 0) { System.out.println("SweepSnapshotCases: " + bad + " failure(s)"); System.exit(1); }
        System.out.println("SweepSnapshotCases: all cases pass");
    }
}
