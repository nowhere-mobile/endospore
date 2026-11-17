package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.function.Predicate;

/** Cases for YourAppsFetch and PlayFetchAsk.CONFIRMED (NWP-20261205-12), run by
 *  core/vendor-common/bin/test-yourapps-fetch-java.sh. */
public class YourAppsFetchCases {
    static int failed;

    static void check(String what, Object got, Object want) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("  ok    " + what);
        } else {
            failed++;
            System.out.println("  FAIL  " + what + ": got <" + got + ">, want <" + want + ">");
        }
    }

    public static void main(String[] a) {
        Predicate<String> any = d -> false;
        Predicate<String> bHasCode = d -> d.equals("b");

        // C1-C2: sizeSet is the deps with no code, in order, then the tapped package.
        check("C1 sizeSet drops a dep with code, keeps order, ends with pkg",
                YourAppsFetch.sizeSet("app", Arrays.asList("a", "b", "c"), bHasCode), Arrays.asList("a", "c", "app"));
        check("C2 sizeSet of no deps is [pkg]",
                YourAppsFetch.sizeSet("app", Collections.<String>emptyList(), any), Arrays.asList("app"));
        check("C2 sizeSet of null deps is [pkg]", YourAppsFetch.sizeSet("app", null, any), Arrays.asList("app"));

        // C3-C5: the body. A known size is the Play setup's words, either way.
        for (long b : new long[] {1L, 5L * 1048576, 130L * 1048576}) {
            check("C3 message(" + b + ", true) is PlayFetchAsk.message", YourAppsFetch.message(b, true),
                    PlayFetchAsk.message(b));
            check("C3 message(" + b + ", false) is PlayFetchAsk.message", YourAppsFetch.message(b, false),
                    PlayFetchAsk.message(b));
        }
        check("C4 message(-1, true) is PlayFetchAsk.UNKNOWN", YourAppsFetch.message(-1, true), PlayFetchAsk.UNKNOWN);
        check("C4 message(0, true) is PlayFetchAsk.UNKNOWN", YourAppsFetch.message(0, true), PlayFetchAsk.UNKNOWN);
        check("C5 message(-1, false) is UNKNOWN_APP", YourAppsFetch.message(-1, false), YourAppsFetch.UNKNOWN_APP);
        check("C5 UNKNOWN_APP is not the Play stack's words",
                YourAppsFetch.UNKNOWN_APP.equals(PlayFetchAsk.UNKNOWN), false);
        check("C5 UNKNOWN_APP says where the download shows",
                YourAppsFetch.UNKNOWN_APP.contains(PlayFetchAsk.WHERE), true);
        check("C6 ICON_DESC", YourAppsFetch.ICON_DESC, "Download ");

        // K1-K7: CONFIRMED is a one-shot mark per package, within CONFIRM_MS. A static: one package per case.
        long t = 1_000_000_000L;
        PlayFetchAsk.Confirmed c = PlayFetchAsk.CONFIRMED;
        check("K1 take without a mark is false", c.take("p1", t), false);
        c.mark("p2", t);
        check("K2 mark then take is true", c.take("p2", t + 1), true);
        check("K2 a second take is false", c.take("p2", t + 2), false);
        c.mark("p3", t);
        check("K3 take at mark + CONFIRM_MS is true", c.take("p3", t + PlayFetchAsk.CONFIRM_MS), true);
        c.mark("p4", t);
        check("K4 take at mark + CONFIRM_MS + 1 is false", c.take("p4", t + PlayFetchAsk.CONFIRM_MS + 1), false);
        c.mark("p5", t);
        check("K5 take of another package is false", c.take("p6", t), false);
        check("K5 the marked package still takes", c.take("p5", t), true);
        c.mark("p7", t);
        c.clear("p7");
        check("K6 clear then take is false", c.take("p7", t), false);
        check("K7 CONFIRM_MS is ten minutes", PlayFetchAsk.CONFIRM_MS, 600000L);

        if (failed > 0) {
            System.out.println(failed + " case(s) FAILED");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
