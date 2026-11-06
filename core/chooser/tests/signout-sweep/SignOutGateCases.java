package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** NWP-20261109-06: executes SignOutGate, the flag a sign-out raises to stop the Auto sweep (Q116). */
public class SignOutGateCases {
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    public static void main(String[] args) {
        // G1: the flag's lifecycle.
        check("G1 begun() is false at start", !SignOutGate.begun(), String.valueOf(SignOutGate.begun()));
        SignOutGate.begin();
        check("G1 begun() is true after begin()", SignOutGate.begun(), String.valueOf(SignOutGate.begun()));
        SignOutGate.end();
        check("G1 begun() is false after end()", !SignOutGate.begun(), String.valueOf(SignOutGate.begun()));

        // G2: rest() is the not-started tail, as a NEW list.
        List<String> work = new ArrayList<>(Arrays.asList("a", "b", "c"));
        List<String> r1 = SignOutGate.rest(work, 1);
        check("G2 rest([a,b,c],1) is [b, c]", r1.equals(Arrays.asList("b", "c")), String.valueOf(r1));
        List<String> r0 = SignOutGate.rest(work, 0);
        check("G2 rest([a,b,c],0) is [a, b, c]", r0.equals(Arrays.asList("a", "b", "c")), String.valueOf(r0));
        List<String> r2 = SignOutGate.rest(work, 2);
        check("G2 rest([a,b,c],2) is [c]", r2.equals(Arrays.asList("c")), String.valueOf(r2));
        List<String> r3 = SignOutGate.rest(work, 3);
        check("G2 rest([a,b,c],3) is empty", r3.isEmpty(), String.valueOf(r3));
        check("G2 rest() returns a new list, not work", r0 != work, "the same list");
        r1.add("x");
        r0.clear();
        check("G2 mutating the result leaves work unchanged", work.equals(Arrays.asList("a", "b", "c")),
                String.valueOf(work));

        System.out.println(runs + " checks, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
