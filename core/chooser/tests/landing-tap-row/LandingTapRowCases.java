package com.nowhere.chooser;

/** NWP-20261210-25: the landing card's installing row while a tap holds the materialise lock. Compiled with
 *  LandingLine.java and AppDeps.java (test-landing-tap-row-java.sh). The rule: the card names the app the notification
 *  names; when that app has no row, no row is installing and the sweep's app reads coming back. */
public class LandingTapRowCases {
    static int fails = 0;

    static void is(String what, boolean got, boolean want) {
        if (got == want) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + got + ", want " + want);
    }

    static void eqi(String what, long got, long want) {
        if (got == want) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + got + ", want " + want);
    }

    static void eq(String what, String got, String want) {
        if (want.equals(got)) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + (got == null ? "null" : "\"" + got + "\"") + ", want \""
                + want + "\"");
    }

    static final String G = LandingLine.GMS, A = "com.example.a", B = "com.example.b", T = "com.example.tapped";
    static final String[] ROWS = {G, A, B, T};
    static final int IA = 1, IT = 3;

    /** The state words of row i as the card paints them (LandingNoticeActivity.paintRow). */
    static String words(long id, int i) {
        return LandingLine.state(LandingLine.Sweep.landed(id)[i], i == LandingLine.Sweep.installing(id));
    }

    public static void main(String[] args) {
        // T1 the row's case: the sweep starts A while a tap of T holds the lock; the notification names T.
        long id = LandingLine.Sweep.begin(ROWS);
        is("T1 startedBehind(A, named T) changes the row", LandingLine.Sweep.startedBehind(id, A, T), true);
        eqi("T1 the installing row is T's, the app the notification names", LandingLine.Sweep.installing(id), IT);
        eq("T1 A's row reads coming back", words(id, IA), LandingLine.state(false, false));
        eq("T1 T's row reads installing", words(id, IT), LandingLine.state(false, true));
        is("T1 the same call again changes nothing", LandingLine.Sweep.startedBehind(id, A, T), false);

        // T4 the hand-back: the sweep holds the lock and marks its own app (named is null then).
        is("T4 started(A) after the tap changes the row", LandingLine.Sweep.started(id, A), true);
        eqi("T4 the installing row is A's", LandingLine.Sweep.installing(id), IA);
        is("T4 started(A) again changes nothing", LandingLine.Sweep.started(id, A), false);
        is("T4 startedBehind(A, null) again changes nothing", LandingLine.Sweep.startedBehind(id, A, null), false);

        // T2 the notification names an app with no row (a tap of a non-Auto app).
        id = LandingLine.Sweep.begin(ROWS);
        is("T2 named with no row and nothing installing: no change",
                LandingLine.Sweep.startedBehind(id, A, "com.example.notauto"), false);
        eqi("T2 no row is installing", LandingLine.Sweep.installing(id), -1);
        LandingLine.Sweep.started(id, B);
        is("T2 named with no row after B installed: the row changes",
                LandingLine.Sweep.startedBehind(id, A, "com.example.notauto"), true);
        eqi("T2 no row is installing, B's mark is cleared", LandingLine.Sweep.installing(id), -1);
        eq("T2 A's row reads coming back", words(id, IA), LandingLine.state(false, false));

        // T3 named null, and named equal to pkg: exactly started(id, A).
        long s1 = LandingLine.Sweep.begin(ROWS);
        boolean r1 = LandingLine.Sweep.started(s1, A);
        int i1 = LandingLine.Sweep.installing(s1);
        long s2 = LandingLine.Sweep.begin(ROWS);
        boolean r2 = LandingLine.Sweep.startedBehind(s2, A, null);
        int i2 = LandingLine.Sweep.installing(s2);
        long s3 = LandingLine.Sweep.begin(ROWS);
        boolean r3 = LandingLine.Sweep.startedBehind(s3, A, A);
        int i3 = LandingLine.Sweep.installing(s3);
        is("T3 started(A) returns true", r1, true);
        eqi("T3 started(A) marks A", i1, IA);
        is("T3 named null returns what started returns", r2, r1);
        eqi("T3 named null marks what started marks", i2, i1);
        is("T3 named == pkg returns what started returns", r3, r1);
        eqi("T3 named == pkg marks what started marks", i3, i1);

        // T5 named's row already has an outcome: it is not marked again.
        id = LandingLine.Sweep.begin(ROWS);
        LandingLine.Sweep.outcome(id, T, true);
        LandingLine.Sweep.started(id, B);
        is("T5 named landed: the row changes", LandingLine.Sweep.startedBehind(id, A, T), true);
        eqi("T5 named landed: no row is installing", LandingLine.Sweep.installing(id), -1);
        id = LandingLine.Sweep.begin(ROWS);
        LandingLine.Sweep.outcome(id, T, false);
        is("T5 named settled (failed): no change from none", LandingLine.Sweep.startedBehind(id, A, T), false);
        eqi("T5 named settled (failed): no row is installing", LandingLine.Sweep.installing(id), -1);
        id = LandingLine.Sweep.begin(ROWS);
        LandingLine.Sweep.depLanded(T);
        is("T5 named landed as a dep: no change from none", LandingLine.Sweep.startedBehind(id, A, T), false);
        eqi("T5 named landed as a dep: no row is installing", LandingLine.Sweep.installing(id), -1);

        // T6 another sweep's id, or after the end: false, nothing changes.
        long old = LandingLine.Sweep.begin(ROWS);
        id = LandingLine.Sweep.begin(ROWS);
        LandingLine.Sweep.started(id, B);
        is("T6 another sweep's id returns false", LandingLine.Sweep.startedBehind(old, A, T), false);
        eqi("T6 another sweep's id leaves the row", LandingLine.Sweep.installing(id), 2);
        is("T6 another sweep's id, named null, returns false", LandingLine.Sweep.startedBehind(old, A, null), false);
        LandingLine.Sweep.end(id);
        is("T6 after the end returns false", LandingLine.Sweep.startedBehind(id, A, T), false);
        eqi("T6 after the end no row is installing", LandingLine.Sweep.installing(id), -1);
        is("T6 a null pkg returns false", LandingLine.Sweep.startedBehind(LandingLine.Sweep.begin(ROWS), null, T),
                false);

        if (fails != 0) {
            System.out.println("FAILED " + fails);
            System.exit(1);
        }
        System.out.println("ok T1-T6 the installing row while a tap holds the lock");
    }
}
