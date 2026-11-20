package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.function.Supplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * NWP-20261208-08: the cases for GateInputProbe.Rule (compiled unchanged), the gateLogVerbs map check and the
 * source pins on the sampler. main(args) = gate_log.go, GateInputProbe.java, NowhereApp.java. Exit 0 pass, 1 a
 * case or pin failed. Each check runs in its own try: an exception is a --- FAIL for that check.
 */
public class GateInputProbeCases {
    static int fails = 0;

    static void eq(String name, Object want, Supplier<Object> got) {
        Object g;
        try {
            g = got.get();
        } catch (Throwable t) {
            System.out.println("--- FAIL: " + name + ": threw " + t);
            fails++;
            return;
        }
        if (want == null ? g == null : want.equals(g)) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + ": want " + want + " got " + g); fails++; }
    }

    static void ok(String name, boolean cond) {
        if (cond) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name); fails++; }
    }

    static int why(long pending, long batch, long stage, long frame, boolean interactive, long main, boolean anr) {
        return GateInputProbe.Rule.why(pending, batch, stage, frame, interactive, main, anr);
    }

    static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    static String strip(String s) {
        return s.replaceAll("(?s)/\\*.*?\\*/", "").replaceAll("//[^\\n]*", "");
    }

    static int count(String s, String sub) {
        int n = 0;
        for (int i = s.indexOf(sub); i >= 0; i = s.indexOf(sub, i + sub.length())) n++;
        return n;
    }

    /**
     * The tick's episode branches over Rule, for the sequence case. Returns {blocks after the held stall, clears
     * after it, clears after a completed clean read, blocks after a later stall}.
     */
    static long[] sequence() {
        boolean inEpisode = false;
        int written = 0, clears = 0;
        long[] r = new long[4];
        // Ten ticks: even ticks complete a read (stage age 6000, 7000, ...); odd ticks find the read outstanding.
        for (int t = 0; t < 10; t++) {
            boolean out = t % 2 == 1;
            long snapStage = 6000L + 1000L * t;
            int cause = GateInputProbe.Rule.why(GateInputProbe.Rule.tickAge(out, -1), GateInputProbe.Rule.tickAge(out, -1),
                    GateInputProbe.Rule.tickAge(out, snapStage), GateInputProbe.Rule.tickAge(out, -1), true,
                    GateInputProbe.Rule.mainLate(out, 1000L * t, 1000L * t + 1000L), false);
            boolean observed = GateInputProbe.Rule.observed(out, true);
            if (GateInputProbe.Rule.shouldWrite(cause != 0, inEpisode, written)) { inEpisode = true; written++; }
            else if (GateInputProbe.Rule.shouldClear(inEpisode, cause, observed)) { inEpisode = false; clears++; }
        }
        r[0] = written; r[1] = clears;
        // A completed read with nothing held.
        int clean = GateInputProbe.Rule.why(-1, -1, -1, -1, true, 0, false);
        if (GateInputProbe.Rule.shouldWrite(clean != 0, inEpisode, written)) { inEpisode = true; written++; }
        else if (GateInputProbe.Rule.shouldClear(inEpisode, clean, GateInputProbe.Rule.observed(false, true))) { inEpisode = false; clears++; }
        r[2] = clears;
        // A later, independent pending-queue stall.
        int later = GateInputProbe.Rule.why(7000, -1, -1, -1, true, 0, false);
        if (GateInputProbe.Rule.shouldWrite(later != 0, inEpisode, written)) { inEpisode = true; written++; }
        r[3] = written;
        return r;
    }

    public static void main(String[] args) throws Exception {
        // Constants.
        eq("STALL_MS is 5000", 5000L, () -> GateInputProbe.Rule.STALL_MS);
        eq("TICK_MS is 1000", 1000L, () -> GateInputProbe.Rule.TICK_MS);
        eq("MAX_BLOCKS is 4", 4, () -> GateInputProbe.Rule.MAX_BLOCKS);

        // why: each cause alone just over the threshold.
        eq("why pending 5001 -> 1", 1, () -> why(5001, -1, -1, -1, true, 0, false));
        eq("why batch 5001 -> 2", 2, () -> why(-1, 5001, -1, -1, true, 0, false));
        eq("why stage 5001 -> 5", 5, () -> why(-1, -1, 5001, -1, true, 0, false));
        eq("why frame 5001 interactive -> 3", 3, () -> why(-1, -1, -1, 5001, true, 0, false));
        eq("why main 5001 -> 4", 4, () -> why(-1, -1, -1, -1, true, 5001, false));
        eq("why all unknown, anrFlagged -> 6", 6, () -> why(-1, -1, -1, -1, true, -1, true));
        // Strict >: exactly STALL_MS is not a stall.
        eq("why pending 5000 -> 0", 0, () -> why(5000, -1, -1, -1, true, 0, false));
        eq("why batch 5000 -> 0", 0, () -> why(-1, 5000, -1, -1, true, 0, false));
        eq("why stage 5000 -> 0", 0, () -> why(-1, -1, 5000, -1, true, 0, false));
        eq("why frame 5000 -> 0", 0, () -> why(-1, -1, -1, 5000, true, 0, false));
        eq("why main 5000 -> 0", 0, () -> why(-1, -1, -1, -1, true, 5000, false));
        // Unknown ages never trigger.
        eq("why all -1 not flagged -> 0", 0, () -> why(-1, -1, -1, -1, true, -1, false));
        eq("why all -100000 -> 0", 0, () -> why(-100000, -100000, -100000, -100000, true, -100000, false));
        eq("why frame late 60000, not interactive -> 0", 0, () -> why(-1, -1, -1, 60000, false, -1, false));
        // Order 1, 2, 5, 3, 4, 6.
        eq("order pending + main -> 1", 1, () -> why(6000, -1, -1, -1, true, 6000, false));
        eq("order stage + frame -> 5", 5, () -> why(-1, -1, 6000, 6000, true, 0, false));
        eq("order batch + stage -> 2", 2, () -> why(-1, 6000, 6000, -1, true, 0, false));
        eq("order frame + main -> 3", 3, () -> why(-1, -1, -1, 6000, true, 6000, false));
        eq("order pending beats anr -> 1", 1, () -> why(6000, -1, -1, -1, true, 0, true));
        eq("order batch beats anr -> 2", 2, () -> why(-1, 6000, -1, -1, true, 0, true));
        eq("order stage beats anr -> 5", 5, () -> why(-1, -1, 6000, -1, true, 0, true));
        eq("order frame beats anr -> 3", 3, () -> why(-1, -1, -1, 6000, true, 0, true));
        eq("order main beats anr -> 4", 4, () -> why(-1, -1, -1, -1, true, 6000, true));
        // IDLE CASE, the row's: the main thread idle, nothing in a Java queue, the system marks the gate not responding.
        eq("idle anrFlagged -> 6", 6, () -> why(-1, -1, -1, -1, true, 0, true));
        eq("idle stage 6000 -> 5", 5, () -> why(-1, -1, 6000, -1, true, 0, false));

        // stageCode.
        eq("stageCode(1,2) -> 12", 12, () -> GateInputProbe.Rule.stageCode(1, 2));
        eq("stageCode(9,1) -> 91", 91, () -> GateInputProbe.Rule.stageCode(9, 1));
        eq("stageCode(15,3) -> 93", 93, () -> GateInputProbe.Rule.stageCode(15, 3));
        eq("stageCode(0,9) -> 9", 9, () -> GateInputProbe.Rule.stageCode(0, 9));
        eq("stageCode(-3,4) -> 4", 4, () -> GateInputProbe.Rule.stageCode(-3, 4));
        // secMs.
        eq("secMs(999) -> 0", 0, () -> GateInputProbe.Rule.secMs(999));
        eq("secMs(5500) -> 5000", 5000, () -> GateInputProbe.Rule.secMs(5500));
        eq("secMs(5000) -> 5000", 5000, () -> GateInputProbe.Rule.secMs(5000));
        eq("secMs(10^9) -> 600000", 600000, () -> GateInputProbe.Rule.secMs(1_000_000_000L));
        eq("secMs(600999) -> 600000", 600000, () -> GateInputProbe.Rule.secMs(600_999L));
        eq("secMs(-5) -> 0", 0, () -> GateInputProbe.Rule.secMs(-5));
        // winCode, focusCode.
        eq("winCode(1,1,0) -> 110", 110, () -> GateInputProbe.Rule.winCode(1, 1, 0));
        eq("winCode(12,3,15) -> 939", 939, () -> GateInputProbe.Rule.winCode(12, 3, 15));
        eq("winCode(2,5,4) -> 254", 254, () -> GateInputProbe.Rule.winCode(2, 5, 4));
        eq("focusCode(1,1,2) -> 112", 112, () -> GateInputProbe.Rule.focusCode(1, 1, 2));
        eq("focusCode(0,0,9) -> 9", 9, () -> GateInputProbe.Rule.focusCode(0, 0, 9));
        eq("focusCode(1,4,0) -> 140", 140, () -> GateInputProbe.Rule.focusCode(1, 4, 0));
        // vriFlags: each bit alone.
        for (int b = 0; b < 8; b++) {
            final boolean[] x = new boolean[8];
            x[b] = true;
            eq("vriFlags bit " + b + " alone -> " + (1 << b), 1 << b,
                    () -> GateInputProbe.Rule.vriFlags(x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7]));
        }
        eq("vriFlags all -> 255", 255, () -> GateInputProbe.Rule.vriFlags(true, true, true, true, true, true, true, true));
        eq("vriFlags none -> 0", 0, () -> GateInputProbe.Rule.vriFlags(false, false, false, false, false, false, false, false));
        // imeCode: each bit alone.
        for (int b = 0; b < 4; b++) {
            final boolean[] x = new boolean[4];
            x[b] = true;
            eq("imeCode bit " + b + " alone -> " + (1 << b), 1 << b, () -> GateInputProbe.Rule.imeCode(x[0], x[1], x[2], x[3]));
        }
        eq("imeCode none -> 0", 0, () -> GateInputProbe.Rule.imeCode(false, false, false, false));

        // tickAge, mainLate: a window age is unknown only while an earlier tick's read has not run.
        eq("tickAge(false,6000) -> 6000", 6000L, () -> GateInputProbe.Rule.tickAge(false, 6000));
        eq("tickAge(true,6000) -> -1", -1L, () -> GateInputProbe.Rule.tickAge(true, 6000));
        eq("tickAge(false,-1) -> -1", -1L, () -> GateInputProbe.Rule.tickAge(false, -1));
        eq("mainLate(true,1000,7001) -> 6001", 6001L, () -> GateInputProbe.Rule.mainLate(true, 1000, 7001));
        eq("mainLate(false,1000,7001) -> 0", 0L, () -> GateInputProbe.Rule.mainLate(false, 1000, 7001));
        eq("mainLate(true,9000,7001) -> 0", 0L, () -> GateInputProbe.Rule.mainLate(true, 9000, 7001));
        // IDLE TICK: the read from the earlier tick ran, so its ages decide.
        eq("idle tick: pending 6000 -> 1", 1, () -> why(GateInputProbe.Rule.tickAge(false, 6000), GateInputProbe.Rule.tickAge(false, -1),
                GateInputProbe.Rule.tickAge(false, -1), GateInputProbe.Rule.tickAge(false, -1), true,
                GateInputProbe.Rule.mainLate(false, 0, 99999), false));
        eq("idle tick: stage 6000 -> 5", 5, () -> why(GateInputProbe.Rule.tickAge(false, -1), GateInputProbe.Rule.tickAge(false, -1),
                GateInputProbe.Rule.tickAge(false, 6000), GateInputProbe.Rule.tickAge(false, -1), true,
                GateInputProbe.Rule.mainLate(false, 0, 99999), false));

        // maxAge over all roots.
        eq("maxAge {-1,7000,3000} -> 7000", 7000L, () -> GateInputProbe.Rule.maxAge(new long[]{-1, 7000, 3000}));
        eq("maxAge {-1,-1} -> -1", -1L, () -> GateInputProbe.Rule.maxAge(new long[]{-1, -1}));
        eq("maxAge {} -> -1", -1L, () -> GateInputProbe.Rule.maxAge(new long[0]));
        eq("maxAge null -> -1", -1L, () -> GateInputProbe.Rule.maxAge(null));
        eq("maxAge {0} -> 0", 0L, () -> GateInputProbe.Rule.maxAge(new long[]{0}));
        // worstRoot.
        eq("worstRoot IME-held event in a dialog -> 1", 1, () -> GateInputProbe.Rule.worstRoot(
                new long[]{-1, -1}, new long[]{-1, 8000}, new long[]{-1, -1}, 0));
        eq("worstRoot stage 8000 beats pending 6000 -> 1", 1, () -> GateInputProbe.Rule.worstRoot(
                new long[]{6000, -1}, new long[]{-1, 8000}, new long[]{-1, -1}, 0));
        eq("worstRoot pending 9000 beats stage 8000 -> 0", 0, () -> GateInputProbe.Rule.worstRoot(
                new long[]{9000, -1}, new long[]{-1, 8000}, new long[]{-1, -1}, 1));
        eq("worstRoot tie -> lower index", 0, () -> GateInputProbe.Rule.worstRoot(
                new long[]{7000, 7000}, new long[]{-1, -1}, new long[]{-1, -1}, 1));
        eq("worstRoot no event, held batch -> 1", 1, () -> GateInputProbe.Rule.worstRoot(
                new long[]{-1, -1}, new long[]{-1, -1}, new long[]{-1, 6000}, 0));
        eq("worstRoot nothing -> gate 1", 1, () -> GateInputProbe.Rule.worstRoot(
                new long[]{-1, -1}, new long[]{-1, -1}, new long[]{-1, -1}, 1));
        eq("worstRoot nothing, no gate -> 0", 0, () -> GateInputProbe.Rule.worstRoot(
                new long[]{-1, -1}, new long[]{-1, -1}, new long[]{-1, -1}, -1));
        eq("worstRoot no roots -> -1", -1, () -> GateInputProbe.Rule.worstRoot(new long[0], new long[0], new long[0], -1));
        // AGGREGATE: a stage-deferred event in a second root decides.
        eq("aggregate: stage 6000 in root 1 -> 5", 5, () -> why(GateInputProbe.Rule.maxAge(new long[]{-1, -1}),
                GateInputProbe.Rule.maxAge(new long[]{-1, -1}), GateInputProbe.Rule.maxAge(new long[]{-1, 6000}), -1, true, 0, false));

        // shouldWrite.
        eq("shouldWrite(true,false,3)", true, () -> GateInputProbe.Rule.shouldWrite(true, false, 3));
        eq("shouldWrite(true,false,4)", false, () -> GateInputProbe.Rule.shouldWrite(true, false, 4));
        eq("shouldWrite(true,true,0)", false, () -> GateInputProbe.Rule.shouldWrite(true, true, 0));
        eq("shouldWrite(false,false,0)", false, () -> GateInputProbe.Rule.shouldWrite(false, false, 0));

        // observed, shouldClear: an episode ends only on a completed read that finds no stall.
        eq("observed(false,true)", true, () -> GateInputProbe.Rule.observed(false, true));
        eq("observed(true,true)", false, () -> GateInputProbe.Rule.observed(true, true));
        eq("observed(false,false)", false, () -> GateInputProbe.Rule.observed(false, false));
        eq("shouldClear(true,0,true)", true, () -> GateInputProbe.Rule.shouldClear(true, 0, true));
        eq("shouldClear(true,0,false)", false, () -> GateInputProbe.Rule.shouldClear(true, 0, false));
        eq("shouldClear(true,5,true)", false, () -> GateInputProbe.Rule.shouldClear(true, 5, true));
        eq("shouldClear(false,0,true)", false, () -> GateInputProbe.Rule.shouldClear(false, 0, true));
        // SEQUENCE: one IME-held event, with every second read still outstanding 1000 ms late. Completed reads see
        // the stage age grow from 6000; outstanding ones see unknown ages and no ANR flag. One block, no clear.
        // Then a completed read finds nothing (one clear), and a later independent stall gets its own block.
        long[] seq = sequence();
        eq("sequence: delayed reads in one IME stall -> 1 block", 1L, () -> seq[0]);
        eq("sequence: delayed reads in one IME stall -> 0 clears", 0L, () -> seq[1]);
        eq("sequence: recovery seen by a completed read -> 1 clear", 1L, () -> seq[2]);
        eq("sequence: a later stall -> a second block", 2L, () -> seq[3]);

        // VERBS.
        Set<String> want = new HashSet<>(Arrays.asList("input-stall", "input-stall-why", "input-stall-win", "input-stall-vri",
                "input-stall-focus", "input-stall-ime", "input-stall-stage", "input-stall-clear"));
        String[] verbs = GateInputProbe.Rule.VERBS;
        eq("VERBS has 8 entries", 8, () -> verbs.length);
        eq("VERBS has 8 distinct entries", 8, () -> new HashSet<>(Arrays.asList(verbs)).size());
        eq("VERBS is the input-stall set", want, () -> new HashSet<>(Arrays.asList(verbs)));

        // Map: the daemon records a verb outside gateLogVerbs as trace-unknown.
        String go = read(args[0]);
        int a = go.indexOf("var gateLogVerbs = map[string]bool{");
        Set<String> map = new HashSet<>();
        if (a < 0) { System.out.println("--- FAIL: map: gateLogVerbs not found in " + args[0]); fails++; }
        else {
            int b = go.indexOf("\n}", a);
            Matcher m = Pattern.compile("\"([a-z-]+)\":\\s*true").matcher(go.substring(a, b));
            while (m.find()) map.add(m.group(1));
        }
        for (String v : verbs) ok("map: " + v + " is in gateLogVerbs", map.contains(v));

        // Source pins, on comment-stripped text.
        String probe = strip(read(args[1]));
        String app = strip(read(args[2]));
        // P1: the Application starts the probe at every process birth.
        int oc = app.indexOf("public void onCreate()");
        ok("P1 NowhereApp.onCreate calls GateInputProbe.start(this)", oc >= 0 && app.indexOf("GateInputProbe.start(this);", oc) > oc);
        // P2: user 0 only, checked before the thread starts.
        int st = probe.indexOf("static void start(");
        int th = st < 0 ? -1 : probe.indexOf("new Thread(", st);
        ok("P2 start() returns unless myUserId() == 0, before new Thread(",
                st >= 0 && th > st && probe.substring(st, th).contains("myUserId() != 0) return;"));
        // P3: every GateTrace.ev sends a VERBS literal under ms or fields; every verb is sent.
        Matcher ev = Pattern.compile("GateTrace\\.ev\\(\"([a-z-]+)\", \"(ms|fields)\", ").matcher(probe);
        Set<String> verbSet = new HashSet<>(Arrays.asList(verbs));
        Set<String> sent = new HashSet<>();
        int shaped = 0;
        boolean allKnown = true;
        while (ev.find()) {
            shaped++;
            sent.add(ev.group(1));
            if (!verbSet.contains(ev.group(1))) { allKnown = false; System.out.println("    sends " + ev.group(1) + ", not in VERBS"); }
        }
        int calls = count(probe, "GateTrace.ev(");
        ok("P3 every GateTrace.ev has the shape (VERBS literal, ms|fields, code): " + shaped + " of " + calls, calls == shaped && calls >= 8);
        ok("P3 every GateTrace.ev verb is in VERBS", allKnown);
        ok("P3 every VERBS entry is sent", sent.equals(verbSet));
        // P4: no window title, no text, no class name in a log line.
        ok("P4 no getTitle(", !probe.contains("getTitle("));
        boolean logClean = true;
        for (String line : probe.split("\n")) {
            if (line.contains("Log.") && (line.contains("getTitle") || line.contains("Title") || line.contains("getText(")
                    || line.contains("getSimpleName("))) logClean = false;
        }
        ok("P4 no Log. line carries a title, text or class name", logClean);
        // P5: the error-state entry is matched on this process's pid and NOT_RESPONDING, on one line.
        boolean anrLine = false;
        for (String line : probe.split("\n")) {
            if (line.contains(".pid == android.os.Process.myPid()") && line.contains("NOT_RESPONDING")) anrLine = true;
        }
        ok("P5 getProcessesInErrorState is read", probe.contains("getProcessesInErrorState("));
        ok("P5 matched on Process.myPid() and NOT_RESPONDING", anrLine);
        // P6: nothing but pid and condition is read from an entry.
        for (String bad : new String[]{"shortMsg", "longMsg", ".tag", "stackTrace"}) ok("P6 no " + bad, !probe.contains(bad));
        // P7: one tick reads, decides, then posts the next read LAST, once.
        int tk = probe.indexOf("private static void tick(");
        int te = tk < 0 ? -1 : probe.indexOf("\n    }\n", tk);
        String tick = tk >= 0 && te > tk ? probe.substring(tk, te) : "";
        ok("P7 tick( found", !tick.isEmpty());
        int ip = tick.indexOf("long p = postedAt;"), is = tick.indexOf("Snap s = lastSnap;"),
                iw = tick.indexOf("Rule.why("), io = tick.indexOf(".post(");
        ok("P7 tick reads postedAt and lastSnap before Rule.why(", ip >= 0 && is >= 0 && iw > ip && iw > is);
        ok("P7 tick posts after Rule.why(", io > iw && iw >= 0);
        eq("P7 tick has exactly one .post(", 1, () -> count(tick, ".post("));
        for (String x : new String[]{"Rule.tickAge(out, Rule.maxAge(s.pendingAge))", "Rule.tickAge(out, Rule.maxAge(s.stageAge))",
                "Rule.tickAge(out, Rule.maxAge(s.batchHeld))", "Rule.tickAge(out, s.frameLate)"}) {
            ok("P7 tick has " + x, tick.contains(x));
        }
        // P8: the worst root over all roots; the batch hold per root; the read never leaves postedAt set.
        ok("P8 worstRoot over pending, stage and batch", probe.contains("Rule.worstRoot(s.pendingAge, s.stageAge, s.batchHeld, s.gateIdx)"));
        ok("P8 batch hold tracked per root (batchSince[i])", probe.contains("batchSince[i]"));
        ok("P8 the read clears postedAt in finally", probe.contains("finally { postedAt = 0; }"));
        // P9: the tick ends an episode only through Rule.shouldClear, on a completed read.
        ok("P9 tick has Rule.observed(out, s != null) before Snap.EMPTY", tick.contains("boolean observed = Rule.observed(out, s != null);")
                && tick.indexOf("Rule.observed(out, s != null)") < tick.indexOf("Snap.EMPTY"));
        ok("P9 tick clears on Rule.shouldClear(inEpisode, cause, observed)", tick.contains("else if (Rule.shouldClear(inEpisode, cause, observed))"));
        eq("P9 tick writes input-stall-clear once", 1, () -> count(tick, "\"input-stall-clear\""));

        System.exit(fails == 0 ? 0 : 1);
    }
}
