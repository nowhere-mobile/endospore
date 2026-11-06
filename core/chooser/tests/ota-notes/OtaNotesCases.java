package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.regex.Pattern;

// NWP-20261012-03: the cases for OtaNotes -- the "what's in it" and "what's new" dialogs of the gate's Software update
// screen, from an OTA-NOTES reply (run.sh).
public final class OtaNotesCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static List<String> L(String... s) { return new ArrayList<>(Arrays.asList(s)); }

    static List<String> cat(List<String> a, String... more) {
        List<String> r = new ArrayList<>(a);
        r.addAll(Arrays.asList(more));
        return r;
    }

    // Neutral points: features and fixes, as the agent's notes rule requires.
    static final String R1 = "Fixed the clock on the lock screen after a restart.";
    static final String R2 = "Added a battery line to Settings.";
    static final String A1 = "Sign-in is faster on a slow connection.";
    static final String B1 = "New wallpaper picker.";
    static final String B2 = "Fixed a crash when opening Settings twice.";
    static final String C1 = "Calls show the caller's name sooner.";

    // RUNNING 0.5.44 with its own two notes.
    static final List<String> RUN = L("RUNNING 0.5.44", "NOTE " + R1, "NOTE " + R2);
    static final String RUN_BODY = "•  " + R1 + "\n•  " + R2;

    // The agent's claim words (core/agent/ota_notes.go, otaNotesClaimWords): our own copy must not use any of them.
    static final Pattern CLAIM = Pattern.compile("(?i)\\b(privacy|private|privately|anonymous|anonymity|anonymously|secure"
            + "|securely|security|encrypt\\w*|decrypt\\w*|tracking|tracker\\w*|untrack\\w*|surveil\\w*|safe|safer|safely"
            + "|safety|protect\\w*|confidential\\w*|zero[- ]knowledge|no[- ]logs?|can'?t see|cannot see|never see)\\b");

    static final List<OtaNotes.View> seen = new ArrayList<>();

    static OtaNotes.View in(List<String> l) { OtaNotes.View v = OtaNotes.render(l, OtaNotes.Mode.IN_IT); seen.add(v); return v; }
    static OtaNotes.View nw(List<String> l) { OtaNotes.View v = OtaNotes.render(l, OtaNotes.Mode.NEW); seen.add(v); return v; }

    static boolean is(OtaNotes.View v, String title, String body) { return title.equals(v.title) && body.equals(v.body); }

    public static void main(String[] a) {
        // A one-step update: 0.5.45 is offered and its previous is this phone's 0.5.44.
        List<String> oneStep = cat(RUN, "OFFERED 0.5.45", "NOTE " + A1, "END");
        // Several steps: 0.5.47 <- 0.5.46 <- 0.5.45 <- (this phone) 0.5.44.
        List<String> several = cat(RUN, "OFFERED 0.5.47", "NOTE " + C1, "OFFERED 0.5.46", "NOTE " + B1, "NOTE " + B2,
                "OFFERED 0.5.45", "NOTE " + A1, "END");
        // Several steps, and the walk stopped before reaching this phone.
        List<String> severalMore = cat(RUN, "OFFERED 0.5.47", "NOTE " + C1, "OFFERED 0.5.46", "NOTE " + B1, "MORE", "END");
        // One block, but MORE: the versions under it are not named, so it is not one step.
        List<String> oneMore = cat(RUN, "OFFERED 0.5.47", "NOTE " + C1, "MORE", "END");
        // An update is available but its walk has not run yet: no OFFERED block.
        List<String> notReady = cat(RUN, "END");
        // The walk ran and stopped at the offered version -- its notes were never published, or reading them failed
        // and the agent will retry: MORE, no OFFERED.
        List<String> notReadyMore = cat(RUN, "MORE", "END");
        // Up to date: no update, so no OFFERED block -- the same reply as notReady, which is the point.
        List<String> upToDate = cat(RUN, "END");

        // ---- "what's in it": the installed version, its notes, nothing else ----
        OtaNotes.View v = in(upToDate);
        check("in it: up to date -> this version's notes", is(v, "What's in 0.5.44", RUN_BODY), v);
        v = in(oneStep);
        check("in it: an update offered changes nothing", is(v, "What's in 0.5.44", RUN_BODY), v);
        v = in(several);
        check("in it: several offered changes nothing", is(v, "What's in 0.5.44", RUN_BODY), v);
        v = in(severalMore);
        check("in it: MORE changes nothing", is(v, "What's in 0.5.44", RUN_BODY), v);
        v = in(L("RUNNING 0.5.44", "OFFERED 0.5.45", "NOTE " + A1, "END"));
        check("in it: no notes of its own -> says so, and never borrows the offered ones",
                is(v, "What's in 0.5.44", OtaNotes.NO_NOTES), v);
        v = in(L("RUNNING 0.5.44", "END"));
        check("in it: no notes at all", is(v, "What's in 0.5.44", OtaNotes.NO_NOTES), v);
        v = in(L("END"));
        check("in it: no RUNNING line -> no version in the title", is(v, "What's in this version", OtaNotes.NO_NOTES), v);
        v = in(L("RUNNING 0.5.44", "NOTE " + R1));
        check("in it: a reply cut short -> couldn't load", is(v, "What's in 0.5.44", OtaNotes.NOT_LOADED), v);
        v = in(L());
        check("in it: no reply", is(v, "What's in this version", OtaNotes.NOT_LOADED), v);
        v = OtaNotes.render(null, OtaNotes.Mode.IN_IT);
        check("in it: null reply", is(v, "What's in this version", OtaNotes.NOT_LOADED), v);

        // ---- "what's new", one step: that version's points only ----
        v = nw(oneStep);
        check("new: one step -> titled with the offered version, its points only", is(v, "What's new in 0.5.45", "•  " + A1), v);
        v = nw(cat(RUN, "OFFERED 0.5.45", "END"));
        check("new: one step with no points", is(v, "What's new in 0.5.45", OtaNotes.NO_NOTES), v);

        // ---- "what's new", several steps: one section per version, newest first ----
        String hdr = "Your phone: 0.5.44 · Update: 0.5.47";
        v = nw(several);
        check("new: several steps", is(v, "Changes since your version", hdr
                + "\n\nVersion 0.5.47\n•  " + C1
                + "\n\nVersion 0.5.46\n•  " + B1 + "\n•  " + B2
                + "\n\nVersion 0.5.45\n•  " + A1), v);
        v = nw(severalMore);
        check("new: several steps + MORE", is(v, "Changes since your version", hdr
                + "\n\nVersion 0.5.47\n•  " + C1
                + "\n\nVersion 0.5.46\n•  " + B1
                + "\n\n…and earlier changes not listed."), v);
        v = nw(oneMore);
        check("new: one block + MORE is several, not one step", is(v, "Changes since your version", hdr
                + "\n\nVersion 0.5.47\n•  " + C1
                + "\n\n…and earlier changes not listed."), v);
        v = nw(L("OFFERED 0.5.47", "NOTE " + C1, "OFFERED 0.5.46", "NOTE " + B1, "END"));
        check("new: several, no RUNNING line", v.body.startsWith("Your phone: unknown · Update: 0.5.47\n\n"), v);

        // ---- "what's new" with no OFFERED block: not ready or none available, never the running notes ----
        v = nw(notReady);
        check("new: no OFFERED, no MORE (the walk has not run) -> not ready", is(v, "What's new", OtaNotes.NOT_READY), v);
        v = nw(notReadyMore);
        check("new: no OFFERED, MORE (none published, or the read failed) -> none available yet, no try again",
                is(v, "What's new", OtaNotes.NOT_AVAILABLE) && !v.body.contains("Try again"), v);
        check("new: the not-available copy", "No notes are available for this update yet.".equals(OtaNotes.NOT_AVAILABLE),
                OtaNotes.NOT_AVAILABLE);
        check("new: the not-ready copy", "Notes for this update aren't ready yet. Try again in a moment.".equals(OtaNotes.NOT_READY),
                OtaNotes.NOT_READY);
        v = nw(upToDate);
        check("new: an up-to-date phone -> not ready, not its own notes", is(v, "What's new", OtaNotes.NOT_READY), v);
        v = nw(cat(RUN, "OFFERED 0.5.45", "NOTE " + A1));
        check("new: a reply cut short -> couldn't load", is(v, "What's new", OtaNotes.NOT_LOADED), v);
        v = nw(L());
        check("new: no reply", is(v, "What's new", OtaNotes.NOT_LOADED), v);

        // ---- the parse ----
        v = nw(cat(oneStep, "OFFERED 0.5.99", "NOTE " + B1, "MORE"));
        check("parse: nothing after END is read", is(v, "What's new in 0.5.45", "•  " + A1), v);
        v = in(L("NOTE " + B1, "RUNNING 0.5.44", "NOTE " + R1, "END"));
        check("parse: a NOTE before any version belongs to none", is(v, "What's in 0.5.44", "•  " + R1), v);
        v = in(L("NOTE " + B1, "OFFERED 0.5.45", "NOTE " + A1, "END"));
        check("parse: with no RUNNING line, a stray NOTE is not this version's", is(v, "What's in this version", OtaNotes.NO_NOTES), v);

        // ---- the rule: "what's new" never shows the installed version's notes ----
        for (List<String> l : Arrays.asList(oneStep, several, severalMore, oneMore, notReady, notReadyMore, upToDate)) {
            v = nw(l);
            check("new never shows the installed notes: " + l, !v.body.contains(R1) && !v.body.contains(R2), v);
        }
        // ... and "what's in it" never shows an offered version's.
        for (List<String> l : Arrays.asList(oneStep, several, severalMore, oneMore)) {
            v = in(l);
            check("in it never shows offered notes: " + l, !v.body.contains(A1) && !v.body.contains(B1)
                    && !v.body.contains(C1) && !v.body.contains("Version "), v);
        }

        // ---- Profile's Update card: cardNotes (NWP-20261124-14) -- the gate's "what's new" body, or null ----
        String card = OtaNotes.cardNotes(L());
        check("card: no reply -> null (nothing drawn)", card == null, card);
        card = OtaNotes.cardNotes(null);
        check("card: null reply -> null", card == null, card);
        card = OtaNotes.cardNotes(cat(RUN, "OFFERED 0.5.45", "NOTE " + A1));
        check("card: a reply cut short -> null, never couldn't-load text", card == null, card);
        card = OtaNotes.cardNotes(oneStep);
        check("card: one offered version -> its bullets", ("•  " + A1).equals(card), card);
        card = OtaNotes.cardNotes(cat(RUN, "OFFERED 0.5.45", "END"));
        check("card: one offered version with no points", OtaNotes.NO_NOTES.equals(card), card);
        card = OtaNotes.cardNotes(several);
        check("card: several -> the changes-since-your-version body", (hdr
                + "\n\nVersion 0.5.47\n•  " + C1
                + "\n\nVersion 0.5.46\n•  " + B1 + "\n•  " + B2
                + "\n\nVersion 0.5.45\n•  " + A1).equals(card), card);
        card = OtaNotes.cardNotes(severalMore);
        check("card: several + MORE ends with the MORE line", card != null && card.startsWith(hdr) && card.endsWith(OtaNotes.MORE_LINE), card);
        card = OtaNotes.cardNotes(notReady);
        check("card: no OFFERED, no MORE -> not ready", OtaNotes.NOT_READY.equals(card), card);
        card = OtaNotes.cardNotes(notReadyMore);
        check("card: no OFFERED, MORE -> none available", OtaNotes.NOT_AVAILABLE.equals(card), card);
        for (List<String> l : Arrays.asList(oneStep, several, severalMore, oneMore, notReady, notReadyMore, upToDate)) {
            card = OtaNotes.cardNotes(l);
            check("card: the gate's what's-new words: " + l, card != null && card.equals(OtaNotes.render(l, OtaNotes.Mode.NEW).body), card);
            check("card: never the running notes: " + l, card != null && !card.contains(R1) && !card.contains(R2), card);
            check("card: makes no claim: " + l, card != null && !CLAIM.matcher(card).find(), card);
        }
        check("card: the heading", "What's in this update".equals(OtaNotes.CARD_HEADING), OtaNotes.CARD_HEADING);
        check("card: the heading makes no claim", !CLAIM.matcher(OtaNotes.CARD_HEADING).find(), OtaNotes.CARD_HEADING);

        // ---- our copy keeps to the notes rule: no privacy or security claims ----
        for (String c : new String[]{OtaNotes.NOT_LOADED, OtaNotes.NO_NOTES, OtaNotes.NOT_READY, OtaNotes.NOT_AVAILABLE, OtaNotes.MORE_LINE}) {
            check("copy makes no claim: " + c, !CLAIM.matcher(c).find(), c);
        }
        for (OtaNotes.View s : seen) {
            check("rendered copy makes no claim: " + s.title, !CLAIM.matcher(s.title + "\n" + s.body).find(), s);
        }
        check("the claim matcher matches a claim (control)", CLAIM.matcher("Your data stays private.").find(), "");

        System.out.println(runs + " cases, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
