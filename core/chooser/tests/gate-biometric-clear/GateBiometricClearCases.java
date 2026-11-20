package com.nowhere.chooser;

import com.nowhere.chooser.GateBiometricClear.Action;

/** NWP-20261208-20 (h45 #1): the cases for GateBiometricClear. Compiled with GateBiometricClear.java alone by
 *  core/vendor-common/bin/test-gate-biometric-clear-java.sh. Prints "ok <case>" or "FAIL <case>: ..." per case and exits
 *  1 when any case failed. */
public final class GateBiometricClearCases {
    private static int failed;

    /** The suite's own copies of the two texts, byte for byte. */
    private static final String WANT_REMOVED = "A fingerprint or face had been saved on this phone's gate, so it was removed: what is saved there stays for every profile.";
    private static final String WANT_REPORTED = "A fingerprint or face is saved on this phone's gate and could not be removed. Remove it in System settings: it stays for every profile.";

    private static final java.util.regex.Pattern SUMMARY =
            java.util.regex.Pattern.compile("^biometric-clear: before=-?[0-9]+ after=-?[0-9]+ -> [A-Z]+$");
    private static final java.util.regex.Pattern EXCEPTION_LINE =
            java.util.regex.Pattern.compile("^[a-zA-Z ]+ \\([A-Za-z0-9_$]+\\)$");

    /** Every log line of every run, for B9. */
    private static final java.util.List<String> ALL_LOGS = new java.util.ArrayList<>();

    private static void check(String name, boolean cond, String why) {
        if (!cond) { failed++; System.out.println("FAIL " + name + ": " + why); }
    }

    private static void run(String name, Runnable body) {
        int before = failed;
        try { body.run(); } catch (Throwable t) { failed++; System.out.println("FAIL " + name + ": threw " + t); }
        if (failed == before) System.out.println("ok " + name);
    }

    /** A fake platform: enrolled() answers from a queue (an Integer, or THROW), and it counts the calls. */
    private static final Object THROW = new Object();
    private static final class Fake implements GateBiometricClear.Port {
        final java.util.ArrayDeque<Object> counts = new java.util.ArrayDeque<>();
        boolean canRemove = true, removeAllThrows;
        int enrolledCalls, removeAlls, markers;
        final java.util.List<String> logs = new java.util.ArrayList<>();

        Fake(Object... answers) { counts.addAll(java.util.Arrays.asList(answers)); }

        @Override public int enrolled() throws Exception {
            enrolledCalls++;
            Object a = counts.isEmpty() ? THROW : counts.poll();
            if (a == THROW) throw new java.io.IOException("no service");
            return (Integer) a;
        }
        @Override public boolean canRemove() { return canRemove; }
        @Override public void removeAll() throws Exception {
            removeAlls++;
            if (removeAllThrows) throw new SecurityException("refused");
        }
        @Override public void writeMarker() { markers++; }
        @Override public void log(String line) { logs.add(line); ALL_LOGS.add(line); }

        /** The summary lines this run logged. */
        long summaries() { return logs.stream().filter(l -> l.startsWith("biometric-clear: ")).count(); }
    }

    public static void main(String[] args) {
        run("B1 nothing enrolled: NONE, removeAll never called, no marker", () -> {
            Fake f = new Fake(0);
            Action a = GateBiometricClear.run(f);
            check("B1", a == Action.NONE, "run = " + a);
            check("B1", f.removeAlls == 0, "removeAll called " + f.removeAlls + " time(s)");
            check("B1", f.markers == 0, "marker written " + f.markers + " time(s)");
            check("B1", f.enrolledCalls == 1, "enrolled read " + f.enrolledCalls + " time(s), not once");
            check("B1", f.summaries() == 1, "summary lines: " + f.logs);
        });

        run("B2 two enrolled, the removal clears them: REMOVED, one marker", () -> {
            Fake f = new Fake(2, 0);
            Action a = GateBiometricClear.run(f);
            check("B2", a == Action.REMOVED, "run = " + a);
            check("B2", f.removeAlls == 1, "removeAll called " + f.removeAlls + " time(s)");
            check("B2", f.markers == 1, "marker written " + f.markers + " time(s)");
            check("B2", f.logs.contains("biometric-clear: before=2 after=0 -> REMOVED"), "logs: " + f.logs);
        });

        run("B3 no removal call: REPORT, removeAll never called, no marker", () -> {
            Fake f = new Fake(2, 0);
            f.canRemove = false;
            Action a = GateBiometricClear.run(f);
            check("B3", a == Action.REPORT, "run = " + a);
            check("B3", f.removeAlls == 0, "removeAll called " + f.removeAlls + " time(s)");
            check("B3", f.markers == 0, "marker written " + f.markers + " time(s)");
            check("B3", f.summaries() == 1, "summary lines: " + f.logs);
        });

        run("B4 removeAll throws: REPORT, no marker", () -> {
            Fake f = new Fake(2, 0);
            f.removeAllThrows = true;
            Action a = GateBiometricClear.run(f);
            check("B4", a == Action.REPORT, "run = " + a);
            check("B4", f.markers == 0, "marker written " + f.markers + " time(s)");
            check("B4", f.summaries() == 1, "summary lines: " + f.logs);
        });

        run("B5 one template left after the removal: REPORT, no marker", () -> {
            Fake f = new Fake(2, 1);
            Action a = GateBiometricClear.run(f);
            check("B5", a == Action.REPORT, "run = " + a);
            check("B5", f.markers == 0, "marker written " + f.markers + " time(s)");
            check("B5", f.logs.contains("biometric-clear: before=2 after=1 -> REPORT"), "logs: " + f.logs);
        });

        run("B6 the first read throws: null, removeAll never called, no marker", () -> {
            Fake f = new Fake(THROW, 0);
            Action a = GateBiometricClear.run(f);
            check("B6", a == null, "run = " + a);
            check("B6", f.removeAlls == 0, "removeAll called " + f.removeAlls + " time(s)");
            check("B6", f.markers == 0, "marker written " + f.markers + " time(s)");
            check("B6", f.summaries() == 0, "a summary line after a failed read: " + f.logs);
        });

        run("B7 the second read throws: REPORT, no marker", () -> {
            Fake f = new Fake(2, THROW);
            Action a = GateBiometricClear.run(f);
            check("B7", a == Action.REPORT, "run = " + a);
            check("B7", f.removeAlls == 1, "removeAll called " + f.removeAlls + " time(s)");
            check("B7", f.markers == 0, "marker written " + f.markers + " time(s)");
            check("B7", f.logs.contains("biometric-clear: before=2 after=-1 -> REPORT"), "logs: " + f.logs);
        });

        run("B8 the notice: REMOVED once, REPORTED while the last run reported, else nothing", () -> {
            check("B8", WANT_REMOVED.equals(GateBiometricClear.REMOVED), "REMOVED = " + GateBiometricClear.REMOVED);
            check("B8", WANT_REPORTED.equals(GateBiometricClear.REPORTED), "REPORTED = " + GateBiometricClear.REPORTED);
            Action[] lasts = { null, Action.NONE, Action.REMOVED, Action.REPORT };
            for (Action l : lasts) {
                String withMarker = GateBiometricClear.noticeLine(true, l);
                check("B8", WANT_REMOVED.equals(withMarker), "noticeLine(true, " + l + ") = " + withMarker);
                String without = GateBiometricClear.noticeLine(false, l);
                String want = l == Action.REPORT ? WANT_REPORTED : null;
                check("B8", java.util.Objects.equals(want, without), "noticeLine(false, " + l + ") = " + without);
            }
            check("B8", !GateBiometricClear.keepsMarker(WANT_REMOVED), "the marker is kept after REMOVED was shown");
            check("B8", GateBiometricClear.keepsMarker(WANT_REPORTED), "the marker is dropped after REPORTED was shown");
            // The flow: a removal shows REMOVED on the first menu and nothing on the second.
            Fake f = new Fake(1, 0);
            Action last = GateBiometricClear.run(f);
            boolean marker = f.markers == 1;
            String first = GateBiometricClear.noticeLine(marker, last);
            check("B8", WANT_REMOVED.equals(first), "the first menu shows " + first);
            marker = marker && GateBiometricClear.keepsMarker(first);
            String second = GateBiometricClear.noticeLine(marker, last);
            check("B8", second == null, "the second menu shows " + second);
        });

        run("B9 every log line is a digits-and-action summary or an exception class", () -> {
            check("B9", !ALL_LOGS.isEmpty(), "no log lines were collected");
            for (String l : ALL_LOGS) {
                check("B9", SUMMARY.matcher(l).matches() || EXCEPTION_LINE.matcher(l).matches(), "log line: " + l);
            }
        });

        if (failed > 0) { System.out.println(failed + " check(s) failed"); System.exit(1); }
        System.out.println("all cases pass");
    }
}
