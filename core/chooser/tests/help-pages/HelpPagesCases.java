package com.nowhere.chooser;

import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.function.IntFunction;

/** NWP-20261119-16, NWP-20261122-05: the in-app Help pages (decisions 2026-10-31, Part B, and 2026-11-02), run by
 *  test-help-pages-java.sh. Two page sets: the gate's "?" (GateHelpPages) and Profile › Help (HelpPages). */
public final class HelpPagesCases {
    private static int fails = 0;

    private static void check(boolean ok, String what) {
        if (!ok) {
            fails++;
            System.out.println("  FAIL  " + what);
        }
    }

    /** Decision 2026-11-02: the gate's ? covers the gate and Owner settings only, in this order. */
    static final String[] WANT_GATE_TITLES = {
        "Signing in and creating a profile", "Gate settings", "Owner settings", "When the phone is locked",
    };

    /** Decision 2026-11-02: Profile › Help covers the session ("Profile presets" waits for its picker). */
    static final String[] WANT_PROFILE_TITLES = {
        "Your profile on any phone", "Your apps", "Saving and storage", "Locking and signing out",
        "Calls, texts and SIMs", "Privacy controls",
    };

    /** NWP-20261124-15: Gate settings' sun/moon step. The owner can hide the sun/moon (GateLookGlyph.OWNER_ONLY_KEY),
     *  so the step says the owner can lock the look in Owner settings (NWP-20261130-13). */
    static final String WANT_GATE_LOOK =
            "The sun or moon left of ? switches between light and dark, unless the owner has locked the look in Owner "
                    + "settings.";

    /** NWP-20261126-03 (decision 2026-11-03): Store settings moved from Gate settings to Owner settings, so its
     *  sentence is part of Owner settings' Lock screen clock step (page 2 keeps 6 steps). NWP-20261130-14 (decision
     *  2026-11-06): Backup moved the same way, into the same step. */
    static final String WANT_OWNER_STORE =
            "Lock screen clock: show a dim clock while the phone is resting. Store settings: choose where profiles "
                    + "are saved. Backup: choose how often.";

    /** B4: a body says what a feature does and how to use it, never what it protects. Titles are exempt. */
    static final String[] B4_WORDS = {
        "protect", "secure", "safe", "encrypt", "private", "privacy", "anonymous", "untrace", "track",
        "can't see", "can’t see", "never see", "nobody", "no one",
    };

    /** The per-page rules for one set: every page answers, 3 to 6 steps, at most 650 characters, no B4 word; and
     *  body() has exactly as many pages as titles (no page before the first, none past the last). */
    private static void pages(String cls, String[] titles, IntFunction<String> body) {
        for (int i = 0; i < titles.length; i++) {
            String b;
            try {
                b = body.apply(i);
            } catch (RuntimeException e) {
                check(false, cls + ".body(" + i + ") throws " + e);
                continue;
            }
            check(b != null && !b.trim().isEmpty(), cls + ".body(" + i + ") is empty");
            if (b == null) continue;
            int steps = 0;
            for (String line : b.split("\n")) if (!line.trim().isEmpty()) steps++;
            check(steps >= 3 && steps <= 6, cls + ".body(" + i + ") has " + steps + " steps, want 3 to 6");
            check(b.length() <= 650, cls + ".body(" + i + ") is " + b.length() + " characters, want at most 650");
            String low = b.toLowerCase(Locale.ROOT);
            for (String w : B4_WORDS) {
                check(!low.contains(w), cls + ".body(" + i + ") contains the B4 word \"" + w + "\"");
            }
        }
        for (int i : new int[] { -1, titles.length }) {
            boolean threw = false;
            try {
                body.apply(i);
            } catch (RuntimeException e) {
                threw = true;
            }
            check(threw, cls + ".body(" + i + ") answers; the pages are exactly the " + titles.length + " titles");
        }
    }

    public static void main(String[] args) {
        check(Arrays.equals(GateHelpPages.TITLES, WANT_GATE_TITLES), "GateHelpPages.TITLES is "
                + Arrays.toString(GateHelpPages.TITLES) + ", want " + Arrays.toString(WANT_GATE_TITLES));
        check(Arrays.equals(HelpPages.TITLES, WANT_PROFILE_TITLES), "HelpPages.TITLES is "
                + Arrays.toString(HelpPages.TITLES) + ", want " + Arrays.toString(WANT_PROFILE_TITLES));

        // The two sets are apart: no title of one is in the other, and the gate shows no session topic.
        List<String> gate = Arrays.asList(GateHelpPages.TITLES);
        List<String> profile = Arrays.asList(HelpPages.TITLES);
        for (String t : gate) check(!profile.contains(t), "\"" + t + "\" is in both GateHelpPages and HelpPages");
        for (String t : profile) check(!gate.contains(t), "\"" + t + "\" is in both HelpPages and GateHelpPages");
        for (String t : new String[] { "Your apps", "Saving and storage" }) {
            check(!gate.contains(t), "the gate's ? shows \"" + t + "\", which is Profile › Help only");
        }

        pages("GateHelpPages", GateHelpPages.TITLES, GateHelpPages::body);
        check(Arrays.asList(GateHelpPages.body(1).split("\n\n")).contains(WANT_GATE_LOOK),
                "GateHelpPages.body(1) has no step \"" + WANT_GATE_LOOK + "\"");
        // NWP-20261126-03 (decision 2026-11-03): Store settings is named under Owner settings, not Gate settings.
        check(!GateHelpPages.body(1).contains("Store settings"), "GateHelpPages.body(1) still names Store settings");
        // NWP-20261130-14 (decision 2026-11-06): so is Backup, in the same step.
        check(!GateHelpPages.body(1).contains("Backup") && GateHelpPages.body(2).contains("Backup"),
                "GateHelpPages does not name Backup under Owner settings only");
        check(Arrays.asList(GateHelpPages.body(2).split("\n\n")).contains(WANT_OWNER_STORE),
                "GateHelpPages.body(2) has no step \"" + WANT_OWNER_STORE + "\"");
        pages("HelpPages", HelpPages.TITLES, HelpPages::body);

        check("Help".equals(HelpPages.indexTitle()), "HelpPages.indexTitle() is \"" + HelpPages.indexTitle() + "\"");
        check("Help".equals(GateHelpPages.indexTitle()),
                "GateHelpPages.indexTitle() is \"" + GateHelpPages.indexTitle() + "\"");
        String more = "More help is on the support pages at nowhere.mobile.";
        check(more.equals(HelpPages.moreLine()), "HelpPages.moreLine() is \"" + HelpPages.moreLine() + "\"");
        check(more.equals(GateHelpPages.moreLine()),
                "GateHelpPages.moreLine() is \"" + GateHelpPages.moreLine() + "\"");

        if (fails > 0) {
            System.out.println(fails + " case(s) failed");
            System.exit(1);
        }
        System.out.println("HelpPagesCases: all cases pass");
    }
}
