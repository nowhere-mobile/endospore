package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

// NWP-20261127-13: the cases for InterruptedInstall.settle, the rule UnarchiveService.awaitInterruptedInstall
// (NWP-20261005-11) adapts: abandon only an uncommitted session of the package, wait out a committed one to the bound,
// then answer whether the package is installed. Run against a fake installer and a fake clock that sleep advances.
public final class InterruptedInstallCases {
    static int fails = 0, runs = 0;
    static final String PKG = "com.example.big";
    static final String OTHER = "com.example.other";
    static final long BOUND = 600_000, POLL = 2_000;
    static final long MAX_SLEEPS = BOUND / POLL + 1;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    /** A recording fake installer. left: per id, how many present() answers are true before it reads false (-1 =
     *  never ends). Its sleep advances the clock and throws an AssertionError after 10x the bound's sleeps, so a lost
     *  deadline fails the case instead of hanging the suite. */
    static final class FakeSessions implements InterruptedInstall.Sessions {
        final List<InterruptedInstall.Mine> list = new ArrayList<>();
        final Map<Integer, Integer> left = new HashMap<>();
        final Set<Integer> presentThrows = new HashSet<>();
        final Set<Integer> abandonThrows = new HashSet<>();
        final List<String> calls = new ArrayList<>();
        final List<String> infos = new ArrayList<>();
        final List<String> warns = new ArrayList<>();
        final List<Throwable> warnT = new ArrayList<>();
        boolean scanThrows, installedAnswer, interruptOnSleep;
        long now = 1_000;
        int sleeps;
        /** The ids still present when installed() was asked. */
        List<Integer> presentAtInstalled;

        FakeSessions add(int id, boolean committed, String pkg) {
            list.add(new InterruptedInstall.Mine(id, committed, pkg));
            return this;
        }
        FakeSessions lasts(int id, int polls) { left.put(id, polls); return this; }

        public List<InterruptedInstall.Mine> mine() throws Exception {
            calls.add("mine");
            if (scanThrows) throw new IllegalStateException("scan boom");
            return list;
        }
        public void abandon(int id) throws Exception {
            calls.add("abandon:" + id);
            if (abandonThrows.contains(id)) throw new SecurityException("abandon boom");
        }
        public boolean present(int id) throws Exception {
            calls.add("present:" + id);
            if (presentThrows.contains(id)) throw new SecurityException("present boom");
            Integer n = left.get(id);
            if (n == null || n == 0) return false;
            if (n > 0) left.put(id, n - 1);
            return true;
        }
        public boolean installed() {
            calls.add("installed");
            presentAtInstalled = new ArrayList<>();
            for (Map.Entry<Integer, Integer> e : left.entrySet()) if (e.getValue() != 0) presentAtInstalled.add(e.getKey());
            return installedAnswer;
        }
        public long nowMs() { return now; }
        public void sleep(long ms) throws InterruptedException {
            calls.add("sleep");
            if (interruptOnSleep) throw new InterruptedException("interrupted");
            sleeps++;
            if (sleeps > 10 * MAX_SLEEPS) throw new AssertionError("the wait never ended: " + sleeps + " sleeps");
            now += ms;
        }
        public void info(String m) { infos.add(m); }
        public void warn(String m, Throwable t) { warns.add(m); warnT.add(t); }

        long count(String prefix) { return calls.stream().filter(c -> c.startsWith(prefix)).count(); }
        String all() { return "answer calls=" + calls + " infos=" + infos + " warns=" + warns; }
    }

    interface Case { void run() throws Throwable; }

    static void run(String name, Case c) {
        try { c.run(); } catch (Throwable t) { check(name + " (threw)", false, t); }
    }

    static String abandoned(int id) {
        return "unarchive install " + PKG + ": abandoned an uncommitted session " + id + " left by an interrupted run (NWP-20261005-11)";
    }
    static String running(String ids) {
        return "unarchive install " + PKG + ": an interrupted install is still running " + ids
                + " -- waiting for it instead of committing a duplicate (NWP-20261005-11)";
    }
    static final String ENDED_YES = "unarchive install " + PKG + ": the interrupted install ended -> installed, using it (NWP-20261005-11)";
    static final String ENDED_NO = "unarchive install " + PKG + ": the interrupted install ended -> not installed, installing again (NWP-20261005-11)";
    static final String BOUND_HIT = "unarchive install " + PKG + ": the interrupted install is still running at the 10-minute bound -- installing anyway";

    static Boolean settle(FakeSessions f) { return InterruptedInstall.settle(f, PKG, BOUND, POLL); }

    public static void main(String[] a) {
        run("1 no sessions", () -> {
            FakeSessions f = new FakeSessions();
            Boolean r = settle(f);
            check("1 no sessions -> null", r == null, r);
            check("1 nothing abandoned, polled or asked", f.calls.equals(Arrays.asList("mine")), f.all());
        });

        run("2 other package only", () -> {
            FakeSessions f = new FakeSessions().add(5, false, OTHER).add(6, true, OTHER).lasts(6, -1);
            Boolean r = settle(f);
            check("2 another package's sessions -> null", r == null, r);
            check("2 another package's sessions are never abandoned", f.count("abandon") == 0, f.all());
            check("2 another package's sessions are never polled", f.count("present") == 0 && f.count("sleep") == 0, f.all());
            check("2 installed never asked", f.count("installed") == 0, f.all());
        });

        run("3 one uncommitted", () -> {
            FakeSessions f = new FakeSessions().add(7, false, PKG);
            Boolean r = settle(f);
            check("3 one uncommitted -> null", r == null, r);
            check("3 the uncommitted session abandoned once", f.calls.equals(Arrays.asList("mine", "abandon:7")), f.all());
            check("3 the abandoned line", f.infos.equals(Arrays.asList(abandoned(7))), f.infos);
        });

        run("4 committed, installed", () -> {
            FakeSessions f = new FakeSessions().add(11, true, PKG).lasts(11, 3);
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("4 a committed install that ends installed -> TRUE", Boolean.TRUE.equals(r), r);
            check("4 the committed session is never abandoned", f.count("abandon") == 0, f.all());
            check("4 polled until gone: 4 present, 3 sleeps", f.count("present:11") == 4 && f.sleeps == 3, f.all());
            check("4 installed asked once, after the wait", f.calls.get(f.calls.size() - 1).equals("installed") && f.count("installed") == 1, f.all());
            check("4 the log lines, byte for byte", f.infos.equals(Arrays.asList(running("[11]"), ENDED_YES)), f.infos);
        });

        run("5 committed, not installed", () -> {
            FakeSessions f = new FakeSessions().add(11, true, PKG).lasts(11, 3);
            f.installedAnswer = false;
            Boolean r = settle(f);
            check("5 a committed install that ends not installed -> FALSE", Boolean.FALSE.equals(r), r);
            check("5 the committed session is never abandoned", f.count("abandon") == 0, f.all());
            check("5 the log lines", f.infos.equals(Arrays.asList(running("[11]"), ENDED_NO)), f.infos);
        });

        run("6 uncommitted + committed", () -> {
            FakeSessions f = new FakeSessions().add(8, false, PKG).add(12, true, PKG).lasts(12, 2);
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("6 -> TRUE", Boolean.TRUE.equals(r), r);
            check("6 only the uncommitted session abandoned", f.count("abandon") == 1 && f.calls.contains("abandon:8"), f.all());
            check("6 the committed session is never abandoned", !f.calls.contains("abandon:12"), f.all());
            check("6 the committed session waited", f.count("present:12") == 3 && f.sleeps == 2, f.all());
            check("6 the log lines", f.infos.equals(Arrays.asList(abandoned(8), running("[12]"), ENDED_YES)), f.infos);
        });

        run("7 never ends", () -> {
            FakeSessions f = new FakeSessions().add(13, true, PKG).lasts(13, -1);
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("7 a committed install that never ends -> null at the bound", r == null, r);
            check("7 at most bound/poll + 1 sleeps", f.sleeps <= MAX_SLEEPS, f.sleeps);
            check("7 the wait lasted the whole bound", f.now - 1_000 >= BOUND, f.now);
            check("7 installed never asked", f.count("installed") == 0, f.all());
            check("7 the bound line", f.warns.equals(Arrays.asList(BOUND_HIT)) && f.warnT.get(0) == null, f.warns);
            check("7 never abandoned", f.count("abandon") == 0, f.all());
        });

        run("8 scan throws", () -> {
            FakeSessions f = new FakeSessions().add(14, true, PKG).lasts(14, 1);
            f.scanThrows = true;
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("8 a scan that throws -> null", r == null, r);
            check("8 the scan-failed line with its throwable",
                    f.warns.equals(Arrays.asList("unarchive install " + PKG + ": session scan failed")) && f.warnT.get(0) != null, f.warns);
            check("8 nothing else called", f.calls.equals(Arrays.asList("mine")), f.all());
        });

        run("9 present throws", () -> {
            FakeSessions f = new FakeSessions().add(15, true, PKG).lasts(15, -1);
            f.presentThrows.add(15);
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("9 a throwing present reads as gone -> the installed answer (TRUE)", Boolean.TRUE.equals(r), r);
            check("9 no sleep", f.sleeps == 0 && f.count("sleep") == 0, f.all());
            check("9 installed asked", f.count("installed") == 1, f.all());
        });

        run("10 sleep interrupted", () -> {
            FakeSessions f = new FakeSessions().add(16, true, PKG).lasts(16, -1);
            f.interruptOnSleep = true;
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("10 an interrupted sleep -> null", r == null, r);
            check("10 installed never asked", f.count("installed") == 0, f.all());
        });

        run("11 two committed", () -> {
            FakeSessions f = new FakeSessions().add(21, true, PKG).add(22, true, PKG).lasts(21, 2).lasts(22, 4);
            f.installedAnswer = true;
            Boolean r = settle(f);
            check("11 two committed -> TRUE", Boolean.TRUE.equals(r), r);
            check("11 both waited until gone before installed is asked",
                    f.presentAtInstalled != null && f.presentAtInstalled.isEmpty(), f.presentAtInstalled + " " + f.all());
            check("11 both polled", f.count("present:21") == 3 && f.count("present:22") == 5 && f.sleeps == 6, f.all());
            check("11 never abandoned", f.count("abandon") == 0, f.all());
            check("11 the running line lists both", f.infos.get(0).equals(running("[21, 22]")), f.infos);
        });

        run("12 abandon throws", () -> {
            FakeSessions f = new FakeSessions().add(9, false, PKG);
            f.abandonThrows.add(9);
            Boolean r = settle(f);
            check("12 a throwing abandon is ignored -> null", r == null, r);
            check("12 the abandoned line is still written", f.infos.equals(Arrays.asList(abandoned(9))), f.infos);
            check("12 no warn", f.warns.isEmpty(), f.warns);
        });

        run("13 null package", () -> {
            FakeSessions f = new FakeSessions().add(30, false, null).add(31, true, null).lasts(31, -1);
            f.list.add(null);
            Boolean r = settle(f);
            check("13 a session with no package and a null entry are skipped -> null", r == null, r);
            check("13 nothing abandoned or polled", f.calls.equals(Arrays.asList("mine")), f.all());
        });

        if (fails == 0) System.out.println("ok: " + runs + " checks");
        System.exit(fails == 0 ? 0 : 1);
    }
}
