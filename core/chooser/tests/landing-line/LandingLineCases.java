package com.nowhere.chooser;

/** NWP-20261122-15, NWP-20261126-05, NWP-20261130-09, NWP-20261201-34: LandingLine's rules and words, compiled with LandingLine.java
 *  and AppDeps.java, the rule the card's list reads (test-landing-line-java.sh). */
public class LandingLineCases {
    static int fails = 0;

    static void is(String what, boolean got, boolean want) {
        if (got == want) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + got + ", want " + want);
    }

    static void eq(String what, String got, String want) {
        if (want.equals(got)) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + (got == null ? "null" : "\"" + got + "\""));
    }

    static void eqi(String what, long got, long want) {
        if (got == want) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + got + ", want " + want);
    }

    static void eqa(String what, int[] got, int[] want) {
        if (java.util.Arrays.equals(got, want)) { System.out.println("ok " + what); return; }
        fails++;
        System.out.println("FAIL " + what + ": got " + java.util.Arrays.toString(got) + ", want "
                + java.util.Arrays.toString(want));
    }

    static String[] pkgs(int total) {
        String[] p = new String[total];
        for (int i = 0; i < total; i++) p[i] = "p" + i;
        return p;
    }

    /** The first k of total apps landed. */
    static boolean[] firstLanded(int total, int k) {
        boolean[] l = new boolean[total];
        for (int i = 0; i < k; i++) l[i] = true;
        return l;
    }

    static void rows(String what, int total, boolean[] landed, int[] want, int wantMore) {
        eqa(what + ": rows", LandingLine.rows(pkgs(total), landed, -1, -1), want);
        eqi(what + ": moreCount", LandingLine.moreCount(pkgs(total), landed, -1, -1), wantMore);
    }

    /** The card's window read from LandingLine.Sweep, as the card's sync() and render() read it. */
    static void win(String what, String[] p, long sweep, int wantInstalling, int[] want, int wantMore) {
        boolean[] l = LandingLine.Sweep.landed(sweep);
        int in = LandingLine.Sweep.installing(sweep), last = LandingLine.Sweep.lastLanded(sweep);
        eqi(what + ": installing", in, wantInstalling);
        eqa(what + ": rows", LandingLine.rows(p, l, in, last), want);
        eqi(what + ": moreCount", LandingLine.moreCount(p, l, in, last), wantMore);
    }

    static final String GMS = "com.google.android.gms", GSF = "com.google.android.gsf", VENDING = "com.android.vending";
    static final String YT = "com.google.android.youtube";

    /** The card's rows through the real AppDeps rule, with ProfileActivity's three names and groups: {@code deferred}
     *  is the deferred keep-set, {@code clients} is nowhere-playdeps, {@code installed} has code. */
    static String[] card(java.util.List<String> work, java.util.List<String> deferred, java.util.List<String> clients,
            java.util.List<String> installed) {
        java.util.Map<String, String> none = new java.util.HashMap<>(), groups = new java.util.HashMap<>();
        for (String s : new String[] {VENDING, GMS, GSF}) groups.put(s, "sandboxed-play");
        return LandingLine.cardPkgs(work,
                p -> AppDeps.appDeps(p, none, groups, deferred, new java.util.HashSet<>(clients), GMS, GSF, VENDING),
                installed::contains);
    }

    static java.util.List<String> list(String... s) {
        return java.util.Arrays.asList(s);
    }

    static void eqs(String what, String[] got, String... want) {
        eq(what, java.util.Arrays.toString(got), java.util.Arrays.toString(want));
    }

    public static void main(String[] a) {
        is("C1 landing, 1 to fetch, no stamp: shown", LandingLine.show(true, 1, null, "12"), true);
        is("C2 landing, 12 to fetch, no stamp: shown", LandingLine.show(true, 12, null, "12"), true);
        is("C3 landing, nothing to fetch: not shown", LandingLine.show(true, 0, null, "12"), false);
        is("C4 not landing (a re-kick, a by-hand sweep): not shown", LandingLine.show(false, 5, null, "12"), false);
        is("C5 the stamp is this serial (a resume): not shown", LandingLine.show(true, 5, "12", "12"), false);
        is("C6 the stamp is another serial: shown", LandingLine.show(true, 5, "11", "12"), true);
        is("C7 no serial, no stamp: not shown", LandingLine.show(true, 5, null, null), false);
        is("C7 no serial, a stamp: not shown", LandingLine.show(true, 5, "12", null), false);

        eq("C8 headline(3, 4) verbatim", LandingLine.headline(3, 4), "3 of 4 apps back");
        eq("C9 headline(12, 50) verbatim", LandingLine.headline(12, 50), "12 of 50 apps back");
        eq("C10 headline(50, 50) verbatim", LandingLine.headline(50, 50), "All 50 apps are back");
        eq("C11 headline(4, 4) verbatim", LandingLine.headline(4, 4), "All 4 apps are back");
        eq("C12 more(47) verbatim", LandingLine.more(47), "+47 more");

        eq("C13 TITLE", LandingLine.TITLE, "Welcome back");
        eq("C13 READY", LandingLine.READY, "ready");
        eq("C13 COMING", LandingLine.COMING, "coming back");
        eq("C13 KEEP", LandingLine.KEEP, "You can keep using the phone.");
        eq("C13 GOT_IT", LandingLine.GOT_IT, "Got it");
        eq("C13 TICK is U+2713", LandingLine.TICK, "✓");
        eq("C13 CLOCK is U+25F7", LandingLine.CLOCK, "◷");
        eqi("C13 ROWS_MAX", LandingLine.ROWS_MAX, 4);
        eqi("C13 ROWS_BIG", LandingLine.ROWS_BIG, 3);
        eqi("C13 CLOSE_AFTER_MS", LandingLine.CLOSE_AFTER_MS, 4000);
        is("C13 WIDTH_SHARE is 0.85f", LandingLine.WIDTH_SHARE == 0.85f, true);
        eq("C13 EXTRA_OPEN", LandingLine.EXTRA_OPEN, "nowhere.profile.open");
        eq("C13 OPEN_YOUR_APPS", LandingLine.OPEN_YOUR_APPS, "your-apps");

        eqi("C14 widthPx(1080) is 85 %", LandingLine.widthPx(1080), 918);
        eqi("C14 widthPx(1440) is 85 %", LandingLine.widthPx(1440), 1224);

        rows("C15 total 1, none landed", 1, firstLanded(1, 0), new int[] {0}, 0);
        rows("C16 total 4, none landed: every app, in order", 4, firstLanded(4, 0), new int[] {0, 1, 2, 3}, 0);
        rows("C17 total 4, two landed: every app still has its row", 4, new boolean[] {true, false, true, false},
                new int[] {0, 1, 2, 3}, 0);
        rows("C18 total 5, none landed: 3 rows", 5, firstLanded(5, 0), new int[] {0, 1, 2}, 2);
        rows("C19 total 5, the first landed: the rows advance", 5, firstLanded(5, 1), new int[] {1, 2, 3}, 1);
        rows("C20 total 50, none landed", 50, firstLanded(50, 0), new int[] {0, 1, 2}, 47);
        rows("C21 total 50, 12 landed", 50, firstLanded(50, 12), new int[] {12, 13, 14}, 35);
        rows("C22 total 50, 2 left: 2 rows, no more row", 50, firstLanded(50, 48), new int[] {48, 49}, 0);
        boolean[] gaps = new boolean[50];
        gaps[0] = true; gaps[2] = true; gaps[3] = true;
        rows("C23 total 50, 0, 2 and 3 landed: sweep order", 50, gaps, new int[] {1, 4, 5}, 44);
        rows("C24 total 6, all landed: no rows", 6, firstLanded(6, 6), new int[] {}, 0);
        is("C25 big(4) is false", LandingLine.big(4), false);
        is("C25 big(5) is true", LandingLine.big(5), true);

        // C26-C32 LandingLine.Sweep, the record the card reads after it registers (RF-001, RF-002). The card's render()
        // gives rows/moreCount Sweep.landed(...) as is, so these are the card's rows.
        String[] five = pkgs(5);
        long s1 = LandingLine.Sweep.begin(five);
        is("C26 begin gives a non-zero id", s1 != 0, true);
        is("C26 a new sweep has not ended", LandingLine.Sweep.done(s1), false);
        LandingLine.Sweep.outcome(s1, "p0", false);
        rows("C27 total 5, the first FAILED: it keeps its row and counts in +more", 5, LandingLine.Sweep.landed(s1),
                new int[] {0, 1, 2}, 2);
        for (int i = 1; i < 5; i++) LandingLine.Sweep.outcome(s1, "p" + i, false);
        rows("C27 total 5, all FAILED: 3 rows and +2 more, nothing landed", 5, LandingLine.Sweep.landed(s1),
                new int[] {0, 1, 2}, 2);
        long s2 = LandingLine.Sweep.begin(five);
        LandingLine.Sweep.outcome(s2, "p0", true);
        LandingLine.Sweep.outcome(s2, "p1", true);
        LandingLine.Sweep.end(s2);
        // The card started late: every outcome and the end came before it read the record.
        rows("C28 outcomes before the card read: the rows advance", 5, LandingLine.Sweep.landed(s2),
                new int[] {2, 3, 4}, 0);
        is("C28 the end before the card read: done", LandingLine.Sweep.done(s2), true);
        // A recreated card reads the same record again: nothing sent in its receiver gap is lost.
        rows("C29 a recreated card reads the same rows", 5, LandingLine.Sweep.landed(s2), new int[] {2, 3, 4}, 0);
        is("C29 a recreated card reads done", LandingLine.Sweep.done(s2), true);
        boolean[] copy = LandingLine.Sweep.landed(s2);
        copy[4] = true;
        is("C30 landed() is a copy", LandingLine.Sweep.landed(s2)[4], false);
        long s3 = LandingLine.Sweep.begin(new String[] {"a", "a", "b"});
        LandingLine.Sweep.outcome(s3, "a", true);
        LandingLine.Sweep.outcome(s3, "a", false);
        LandingLine.Sweep.outcome(s3, "zz", true);
        LandingLine.Sweep.outcome(s3, null, true);
        boolean[] l3 = LandingLine.Sweep.landed(s3);
        is("C31 a repeated package: the first outcome lands the first", l3[0], true);
        is("C31 a repeated package: the second outcome is the second's (failed)", l3[1], false);
        is("C31 an unknown or null package lands nothing", l3[2], false);
        LandingLine.Sweep.outcome(s2, "b", true);
        LandingLine.Sweep.end(s2);
        is("C32 an older sweep's outcome changes nothing", LandingLine.Sweep.landed(s3)[2], false);
        is("C32 an older sweep's end changes nothing", LandingLine.Sweep.done(s3), false);
        is("C32 an older sweep reads as ended (its card closes)", LandingLine.Sweep.done(s2), true);
        is("C32 an older sweep has no landed flags", LandingLine.Sweep.landed(s2) == null, true);
        is("C32 id 0 (no card) reads as ended", LandingLine.Sweep.done(0), true);
        is("C32 id 0 has no landed flags", LandingLine.Sweep.landed(0) == null, true);

        // C33-C41 NWP-20261130-09: the card's rows, through the real AppDeps rule.
        java.util.List<String> none = list();
        eqs("C33 Play on: Play Store in the work list, gms deferred: the services row is there",
                card(list(VENDING, "a"), list(VENDING, GMS, "a"), none, none), GMS, VENDING, "a");
        eqs("C34 ordered first, the work list's order unchanged, for a client at the end of it",
                card(list("a", "b", YT), list("a", "b", YT, GMS), list(YT), none), GMS, "a", "b", YT);
        eqs("C35 Play off: no stack deferred, a client still listed: the list is the work list",
                card(list("a", YT), list("a", YT), list(YT), none), "a", YT);
        eqs("C36 Play services already has code: no row",
                card(list(VENDING, "a"), list(VENDING, GMS, "a"), none, list(GMS)), VENDING, "a");
        eqs("C37 GSF separate: both rows, gms first",
                card(list(VENDING, "a"), list(VENDING, GMS, GSF, "a"), none, none), GMS, GSF, VENDING, "a");
        eqs("C38 GSF absent (Endospore): no GSF row",
                card(list(VENDING), list(VENDING, GMS), none, none), GMS, VENDING);
        eqs("C39 gms first whatever the keep-set order",
                card(list(VENDING), list(GSF, VENDING, GMS), none, none), GMS, GSF, VENDING);
        eqs("C40 Play Off with a client that still demands gms: the sweep fetches it, so the row is there",
                card(list(YT), list(YT, GMS), list(YT), none), GMS, YT);
        eqs("C41 plain apps only: no row, even with gms deferred",
                card(list("a", "b"), list("a", "b", GMS), none, none), "a", "b");
        eqs("C47 gms in the work list itself: one row, at its place",
                card(list(VENDING, GMS), list(VENDING, GMS), none, none), VENDING, GMS);

        // C42-C45 NWP-20261130-09: the tick. The work loop gives a dep no outcome, so depLanded is its only way.
        long d1 = LandingLine.Sweep.begin(new String[] {GMS, "a"});
        is("C42 depLanded changed a row", LandingLine.Sweep.depLanded(GMS), true);
        is("C42 the row ticked", LandingLine.Sweep.landed(d1)[0], true);
        is("C42 another row did not", LandingLine.Sweep.landed(d1)[1], false);
        is("C42 a second call changes nothing", LandingLine.Sweep.depLanded(GMS), false);
        is("C42 null changes nothing", LandingLine.Sweep.depLanded(null), false);
        is("C42 a package with no row changes nothing", LandingLine.Sweep.depLanded(GSF), false);
        long d2 = LandingLine.Sweep.begin(new String[] {GMS, "a"});
        // A failed dep calls nothing (materializeLocked aborts first): the entry point's outcome settles the entry point.
        LandingLine.Sweep.outcome(d2, "a", false);
        is("C43 a failed dep leaves its row open", LandingLine.Sweep.landed(d2)[0], false);
        is("C43 the retry's landing ticks it", LandingLine.Sweep.depLanded(GMS), true);
        is("C43 the row is ticked after the retry", LandingLine.Sweep.landed(d2)[0], true);
        long d3 = LandingLine.Sweep.begin(new String[] {"p", "q"});
        LandingLine.Sweep.outcome(d3, "p", false);
        is("C44 depLanded beats an earlier failed outcome", LandingLine.Sweep.depLanded("p"), true);
        LandingLine.Sweep.outcome(d3, "p", false);
        is("C44 a later failed outcome cannot undo it", LandingLine.Sweep.landed(d3)[0], true);
        // depLanded settled the row, so this outcome is the next row's of that package, never this one's again.
        long d4 = LandingLine.Sweep.begin(new String[] {VENDING, "a"});
        LandingLine.Sweep.depLanded(VENDING);
        LandingLine.Sweep.outcome(d4, VENDING, false);
        is("C44 a Play Store a client's dep loop landed stays ticked at its own outcome", LandingLine.Sweep.landed(d4)[0], true);
        String[] six = {GMS, "a", "b", "c", "d", "e"};
        long d5 = LandingLine.Sweep.begin(six);
        for (String p : new String[] {"a", "b", "c"}) LandingLine.Sweep.outcome(d5, p, true);
        eqa("C45 from-5 card: the services row stays on top while plain apps land",
                LandingLine.rows(six, LandingLine.Sweep.landed(d5), -1, -1), new int[] {0, 4, 5});
        LandingLine.Sweep.depLanded(GMS);
        eqa("C45 from-5 card: its row leaves when it lands",
                LandingLine.rows(six, LandingLine.Sweep.landed(d5), -1, -1), new int[] {4, 5});

        eq("C46 depLabel names Play services", LandingLine.depLabel(GMS), "Google Play services");
        eq("C46 depLabel names GSF", LandingLine.depLabel(GSF), "Google Services Framework");
        is("C46 depLabel names nothing else", LandingLine.depLabel("a") == null, true);
        is("C46 depLabel of null is null", LandingLine.depLabel(null) == null, true);

        // C48-C52 NWP-20261201-31: a row keeps one name for the life of the card.
        String[] nameRows = {VENDING, "a"};
        long n1 = LandingLine.Sweep.begin(nameRows);
        eq("C48 the first read is the row's name", LandingLine.Sweep.keepLabel(n1, 0, "Play Store"), "Play Store");
        LandingLine.Sweep.outcome(n1, VENDING, true);
        eq("C48 the app landing does not rename the row", LandingLine.Sweep.keepLabel(n1, 0, "Google Play Store"), "Play Store");
        eq("C49 a recreated card reads the stored name", LandingLine.Sweep.keepLabel(n1, 0, "Google Play Store"), "Play Store");
        eq("C49 another row is independent", LandingLine.Sweep.keepLabel(n1, 1, "A"), "A");
        long n2 = LandingLine.Sweep.begin(nameRows);
        eq("C50 a new sweep forgets the old names", LandingLine.Sweep.keepLabel(n2, 0, "Google Play Store"), "Google Play Store");
        eq("C51 another sweep id reads its own name", LandingLine.Sweep.keepLabel(n2 - 1, 0, "X"), "X");
        eq("C51 sweep id 0 reads its own name", LandingLine.Sweep.keepLabel(0, 0, "X"), "X");
        eq("C51 neither stored anything", LandingLine.Sweep.keepLabel(n2, 0, "Y"), "Google Play Store");
        eq("C51 an index past the end stores nothing", LandingLine.Sweep.keepLabel(n2, 5, "Z"), "Z");
        eq("C51 a negative index stores nothing", LandingLine.Sweep.keepLabel(n2, -1, "Z"), "Z");
        long n3 = LandingLine.Sweep.begin(nameRows);
        is("C52 a null read returns null", LandingLine.Sweep.keepLabel(n3, 0, null) == null, true);
        eq("C52 a null read stored nothing", LandingLine.Sweep.keepLabel(n3, 0, "A"), "A");

        // W1-W7 NWP-20261201-34: the rolling window and the installing row (h62 #3).
        String[] fifty = pkgs(50);
        long w1 = LandingLine.Sweep.begin(fifty);
        is("W1 starting p0 changes the installing row", LandingLine.Sweep.started(w1, "p0"), true);
        win("W1 p0 started: 0 installing, the next two coming back", fifty, w1, 0, new int[] {0, 1, 2}, 47);
        is("W1 a RETRY of p0 changes nothing", LandingLine.Sweep.started(w1, "p0"), false);
        LandingLine.Sweep.outcome(w1, "p0", true);
        eqi("W1 p0's outcome ends its install", LandingLine.Sweep.installing(w1), -1);
        LandingLine.Sweep.started(w1, "p1");
        win("W1 p0 ready, p1 installing, p2 coming back", fifty, w1, 1, new int[] {0, 1, 2}, 47);
        LandingLine.Sweep.outcome(w1, "p1", true);
        LandingLine.Sweep.started(w1, "p2");
        win("W1 p1 ready: the previous ready left and all moved up", fifty, w1, 2, new int[] {1, 2, 3}, 46);

        long w2 = LandingLine.Sweep.begin(fifty);
        LandingLine.Sweep.outcome(w2, "p0", true);
        LandingLine.Sweep.started(w2, "p1");
        LandingLine.Sweep.outcome(w2, "p1", false);
        LandingLine.Sweep.started(w2, "p2");
        win("W2 p1 failed: the window passes it and it counts in +more", fifty, w2, 2, new int[] {0, 2, 3}, 47);

        String[] gmsSix = {GMS, "a0", "a1", "a2", "a3", "a4", "a5"};
        long w3 = LandingLine.Sweep.begin(gmsSix);
        LandingLine.Sweep.started(w3, "a0");
        eqi("W3 a0 installing", LandingLine.Sweep.installing(w3), 1);
        is("W3 the dep's start changes the installing row", LandingLine.Sweep.depStarted(GMS), true);
        win("W3 the dep installing: its row is first", gmsSix, w3, 0, new int[] {0, 1, 2}, 4);
        is("W3 the same dep again changes nothing", LandingLine.Sweep.depStarted(GMS), false);
        LandingLine.Sweep.depLanded(GMS);
        win("W3 the dep landed: back to a0, the dep is the ready row", gmsSix, w3, 1, new int[] {0, 1, 2}, 4);

        long w4 = LandingLine.Sweep.begin(gmsSix);
        LandingLine.Sweep.started(w4, "a0");
        LandingLine.Sweep.depStarted(GMS);
        LandingLine.Sweep.outcome(w4, "a0", false);
        eqi("W4 a failed dep and a0's failed outcome: nothing installing", LandingLine.Sweep.installing(w4), -1);

        String[] sixApps = pkgs(6);
        long w5 = LandingLine.Sweep.begin(sixApps);
        LandingLine.Sweep.started(w5, "p0");
        LandingLine.Sweep.end(w5);
        eqi("W5 the end clears the installing row", LandingLine.Sweep.installing(w5), -1);
        is("W5 a dep start after the end changes nothing", LandingLine.Sweep.depStarted("p1"), false);
        is("W5 an app start after the end changes nothing", LandingLine.Sweep.started(w5, "p1"), false);
        eqi("W5 the installing row stays clear after the end", LandingLine.Sweep.installing(w5), -1);
        long w5b = LandingLine.Sweep.begin(sixApps);
        for (int i = 0; i < 6; i++) {
            LandingLine.Sweep.started(w5b, "p" + i);
            LandingLine.Sweep.outcome(w5b, "p" + i, true);
        }
        LandingLine.Sweep.end(w5b);
        win("W5 the last app landed: its row alone, no more row", sixApps, w5b, -1, new int[] {5}, 0);

        long w6 = LandingLine.Sweep.begin(sixApps);
        is("W6 another sweep's start changes nothing", LandingLine.Sweep.started(w6 + 1, "p0"), false);
        eqi("W6 this sweep has no installing row after it", LandingLine.Sweep.installing(w6), -1);
        LandingLine.Sweep.started(w6, "p0");
        LandingLine.Sweep.outcome(w6, "p0", true);
        LandingLine.Sweep.started(w6, "p1");
        eqi("W6 installing(another sweep) is -1", LandingLine.Sweep.installing(w6 + 1), -1);
        eqi("W6 lastLanded(another sweep) is -1", LandingLine.Sweep.lastLanded(w6 + 1), -1);
        long w6b = LandingLine.Sweep.begin(sixApps);
        eqi("W6 a new sweep has no installing row", LandingLine.Sweep.installing(w6b), -1);
        eqi("W6 a new sweep has no last-landed row", LandingLine.Sweep.lastLanded(w6b), -1);

        boolean[] w7 = {true, false, false};
        eqa("W7 3 apps: every row, in order", LandingLine.rows(pkgs(3), w7, 1, 0), new int[] {0, 1, 2});
        eqi("W7 3 apps: no more row", LandingLine.moreCount(pkgs(3), w7, 1, 0), 0);
        eq("W7 INSTALLING", LandingLine.INSTALLING, "installing");
        eq("W7 state: ready", LandingLine.state(true, false), "✓ ready");
        eq("W7 state: landed wins over installing", LandingLine.state(true, true), "✓ ready");
        eq("W7 state: installing, no glyph", LandingLine.state(false, true), "installing");
        eq("W7 state: coming back", LandingLine.state(false, false), "◷ coming back");
        System.exit(fails == 0 ? 0 : 1);
    }
}
