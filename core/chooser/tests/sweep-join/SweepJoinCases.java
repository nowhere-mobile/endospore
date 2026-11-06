package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/** NWP-20261126-04: SweepJoin, compiled with that file ALONE and executed by
 *  core/vendor-common/bin/test-sweep-join-java.sh. Nothing sleeps and nothing runs on a second thread: a start that
 *  arrives during a pass is called from inside that pass, which is exactly when the field's second start arrived. */
public final class SweepJoinCases {
    static int bad = 0;
    static void check(String id, boolean cond, String what) {
        if (cond) return;
        System.out.println("FAIL " + id + " " + what);
        failed.add(id);
        bad++;
    }
    static final Set<String> failed = new LinkedHashSet<>();
    static void ok(String id, String what) { if (!failed.contains(id)) System.out.println("ok " + id + " " + what); }

    /** One sweepAuto pass, given the flags it runs with. */
    interface Pass { void run(int flags) throws Exception; }

    /** UnarchiveService.sweepAutoJoined's loop, step for step: a start that finds a sweep running joins it and
     *  returns; the owner runs one pass per iteration, catches a throw inside the loop, ends every pass with exit()
     *  in the finally, and runs another pass with the joiners' flags while exit() returns >= 0. */
    static void start(int flags, Pass pass) {
        if (!SweepJoin.enter(flags)) return;
        while (true) {
            int next;
            try { pass.run(flags); }
            catch (Throwable t) { /* sweepAutoJoined logs it */ }
            finally { next = SweepJoin.exit(); }
            if (next < 0) return;
            flags = next;
        }
    }

    /** A model sign-in: the Auto apps a and b, a pending list that drops what the fake install marked installed, and
     *  a count of how often each app was processed. Each pass walks the list it read at its start. */
    static final class SignIn {
        final List<String> auto = Arrays.asList("a", "b");
        final Set<String> installed = new LinkedHashSet<>();
        final Map<String, Integer> processed = new TreeMap<>();
        final Map<String, Integer> fetched = new TreeMap<>();
        final List<List<String>> lists = new ArrayList<>(); // the list each pass read, in order
        final List<Integer> passFlags = new ArrayList<>();  // the flags each pass ran with, in order
        List<String> pending() {
            List<String> l = new ArrayList<>();
            for (String p : auto) if (!installed.contains(p)) l.add(p);
            return l;
        }
    }

    public static void main(String[] args) {
        // J1 enter on an idle join is true.
        SweepJoin.reset();
        check("J1", SweepJoin.enter(0), "enter on an idle join is not true");
        ok("J1", "enter on an idle join owns the walk");

        // J2 a second enter while running is false.
        SweepJoin.reset();
        SweepJoin.enter(0);
        check("J2", !SweepJoin.enter(0), "a second enter while a sweep runs is not false");
        check("J2", !SweepJoin.enter(SweepJoin.BY_HAND), "a third enter while a sweep runs is not false");
        ok("J2", "a start while a sweep runs joins it");

        // J3 exit with no join ends the sweep; a later enter owns the walk again.
        SweepJoin.reset();
        SweepJoin.enter(0);
        int e3 = SweepJoin.exit();
        check("J3", e3 == -1, "exit with no join returned " + e3 + ", want -1");
        check("J3", SweepJoin.enter(0), "enter after the sweep ended is not true");
        ok("J3", "exit with no join ends the sweep");

        // J4 one join: exit returns its bits once and keeps the sweep running; the next exit ends it.
        SweepJoin.reset();
        SweepJoin.enter(0);
        SweepJoin.enter(SweepJoin.BY_HAND);
        int e4a = SweepJoin.exit();
        check("J4", e4a == SweepJoin.BY_HAND, "exit after one BY_HAND join returned " + e4a + ", want 1");
        check("J4", !SweepJoin.enter(0), "the sweep is not still running during the rerun");
        SweepJoin.reset();
        SweepJoin.enter(0);
        SweepJoin.enter(SweepJoin.BY_HAND);
        SweepJoin.exit();
        int e4b = SweepJoin.exit();
        check("J4", e4b == -1, "the exit after the rerun returned " + e4b + ", want -1");
        ok("J4", "one join gives one rerun with its bits");

        // J5 two joins collapse into ONE rerun carrying both; a join with no bits still gives a rerun.
        SweepJoin.reset();
        SweepJoin.enter(0);
        SweepJoin.enter(SweepJoin.BY_HAND);
        SweepJoin.enter(SweepJoin.LANDING);
        int e5a = SweepJoin.exit();
        int e5b = SweepJoin.exit();
        check("J5", e5a == (SweepJoin.BY_HAND | SweepJoin.LANDING), "two joins (BY_HAND, LANDING) gave " + e5a + ", want 3");
        check("J5", e5b == -1, "two joins gave a second rerun (" + e5b + "), want one");
        SweepJoin.reset();
        SweepJoin.enter(SweepJoin.LANDING);
        SweepJoin.enter(0);
        int e5c = SweepJoin.exit();
        check("J5", e5c == 0, "a plain join (flags 0) gave " + e5c + ", want a rerun with 0");
        ok("J5", "joins collapse into one rerun carrying every joiner's bits");

        // J6 a pass that throws still ends the join, and still runs a rerun a join asked for.
        SweepJoin.reset();
        start(0, f -> { throw new IllegalStateException("pass 1"); });
        check("J6", SweepJoin.enter(0), "a pass that threw with no join left the sweep running");
        SweepJoin.reset();
        final List<Integer> ran6 = new ArrayList<>();
        start(0, f -> {
            ran6.add(f);
            if (ran6.size() == 1) {
                start(SweepJoin.BY_HAND, g -> ran6.add(-100)); // joins: never runs this body
                throw new IllegalStateException("pass 1, a join pending");
            }
        });
        check("J6", ran6.equals(Arrays.asList(0, SweepJoin.BY_HAND)),
                "a pass that threw with a join pending ran " + ran6 + ", want [0, 1]");
        check("J6", SweepJoin.enter(0), "the rerun after a throw left the sweep running");
        ok("J6", "a throw ends the pass, never the join");

        // J7 (the row's CLOSES WHEN): two starts within one sign-in process each app once. A, the switch-landing
        // start, reads [a, b]; B (a network re-kick, say) arrives during A's first app, before its install ends, and
        // joins; the rerun reads a fresh list, which is empty.
        SweepJoin.reset();
        final SignIn s7 = new SignIn();
        final boolean[] bStarted = { false };
        final Pass[] p7 = new Pass[1];
        p7[0] = f -> {
            List<String> list = s7.pending();
            s7.lists.add(list);
            s7.passFlags.add(f);
            for (String app : list) {
                s7.processed.merge(app, 1, Integer::sum);
                if (!bStarted[0]) {
                    bStarted[0] = true;
                    start(0, p7[0]); // B
                }
                s7.installed.add(app);
            }
        };
        start(SweepJoin.LANDING, p7[0]); // A
        Map<String, Integer> once = new TreeMap<>();
        once.put("a", 1);
        once.put("b", 1);
        check("J7", s7.processed.equals(once), "two starts processed " + s7.processed + ", want each app once " + once);
        check("J7", s7.lists.size() == 2 && s7.lists.get(1).isEmpty(),
                "the passes read " + s7.lists + ", want [[a, b], []] (one rerun, over a fresh list)");
        check("J7", SweepJoin.enter(0), "the sweep is still running after the sign-in's starts ended");
        ok("J7", "two starts within one sign-in process each app once: " + s7.processed);

        // J8 a by-hand join after a pass whose apps waited for Wi-Fi reruns with BY_HAND, so they are fetched.
        SweepJoin.reset();
        final SignIn s8 = new SignIn();
        final boolean[] tapped = { false };
        final Pass[] p8 = new Pass[1];
        p8[0] = f -> {
            List<String> list = s8.pending();
            s8.lists.add(list);
            s8.passFlags.add(f);
            boolean mayFetch = (f & SweepJoin.BY_HAND) != 0; // metered network, "Download over mobile data" off
            if (!mayFetch) {
                if (!tapped[0]) {
                    tapped[0] = true;
                    start(SweepJoin.BY_HAND, p8[0]); // "Install pending apps now", tapped during the pass
                }
                return; // the apps wait for Wi-Fi
            }
            for (String app : list) {
                s8.fetched.merge(app, 1, Integer::sum);
                s8.installed.add(app);
            }
        };
        start(SweepJoin.LANDING, p8[0]);
        check("J8", s8.passFlags.size() == 2 && (s8.passFlags.get(1) & SweepJoin.BY_HAND) != 0,
                "the passes ran with flags " + s8.passFlags + ", want a rerun with BY_HAND");
        check("J8", s8.fetched.equals(once), "the by-hand rerun fetched " + s8.fetched + ", want each app once " + once);
        check("J8", SweepJoin.enter(0), "the sweep is still running after the by-hand rerun");
        ok("J8", "a by-hand join reruns by hand and fetches the waiting apps");

        if (bad > 0) {
            System.out.println("SweepJoinCases: " + bad + " check(s) FAILED");
            System.exit(1);
        }
        System.out.println("SweepJoinCases: all cases pass");
    }
}
