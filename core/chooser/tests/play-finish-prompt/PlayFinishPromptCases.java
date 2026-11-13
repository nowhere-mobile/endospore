package com.nowhere.chooser;

/** NWP-20261202-22: PlayFinishPrompt's rule and words, compiled as-is with PlayChoice (test-play-finish-prompt-java.sh). */
public final class PlayFinishPromptCases {
    private static int pass, fail;

    private static void check(String name, boolean ok) {
        if (ok) { pass++; System.out.println("  PASS " + name); }
        else { fail++; System.out.println("  FAIL " + name); }
    }

    public static void main(String[] args) {
        // C1: decide over every marker x state x Play Store on the phone.
        String[] markers = {null, "", "0", "off", "1", " 1", "1 "};
        for (String m : markers) {
            for (PlayChoice.State s : PlayChoice.State.values()) {
                for (boolean on : new boolean[] {false, true}) {
                    PlayFinishPrompt.Verdict want = !"1".equals(m) ? PlayFinishPrompt.Verdict.NONE
                            : (s != PlayChoice.State.ON || on) ? PlayFinishPrompt.Verdict.SETTLE
                            : PlayFinishPrompt.Verdict.SHOW;
                    PlayFinishPrompt.Verdict got = PlayFinishPrompt.decide(m, s, on);
                    check("C1 decide(" + (m == null ? "null" : "\"" + m + "\"") + ", " + s + ", " + on + ") = " + want
                            + " (got " + got + ")", got == want);
                }
            }
        }
        // C2: the three that matter, spelled out.
        check("C2 pending, Play on, no Play Store: SHOW",
                PlayFinishPrompt.decide("1", PlayChoice.State.ON, false) == PlayFinishPrompt.Verdict.SHOW);
        check("C2 pending, Play on, Play Store on the phone: SETTLE",
                PlayFinishPrompt.decide("1", PlayChoice.State.ON, true) == PlayFinishPrompt.Verdict.SETTLE);
        check("C2 pending, Play off: SETTLE",
                PlayFinishPrompt.decide("1", PlayChoice.State.OFF, false) == PlayFinishPrompt.Verdict.SETTLE);
        check("C2 pending, no App Store (effective absent): SETTLE",
                PlayFinishPrompt.decide("1", PlayChoice.effective(PlayChoice.State.ON, false), false)
                        == PlayFinishPrompt.Verdict.SETTLE);
        check("C2 the cfgStatic fallback for an absent key (\"off\"): NONE",
                PlayFinishPrompt.decide("off", PlayChoice.State.ON, false) == PlayFinishPrompt.Verdict.NONE);
        // C3: the decided title verbatim, the key and its values.
        check("C3 TITLE is the decided \"Finish setting up Google Play\"",
                "Finish setting up Google Play".equals(PlayFinishPrompt.TITLE));
        check("C3 CFG_KEY is play.finish", "play.finish".equals(PlayFinishPrompt.CFG_KEY));
        check("C3 PENDING is \"1\", DONE is \"0\"", "1".equals(PlayFinishPrompt.PENDING) && "0".equals(PlayFinishPrompt.DONE));
        check("C3 the marker key is not play.wanted", !PlayFinishPrompt.CFG_KEY.equals(PlayChoice.CFG_KEY));
        check("C3 OPEN_PLAY is set and is not LandingLine's \"your-apps\"",
                PlayFinishPrompt.OPEN_PLAY != null && !PlayFinishPrompt.OPEN_PLAY.isEmpty()
                        && !"your-apps".equals(PlayFinishPrompt.OPEN_PLAY));
        // C4: the popup rules: no "&" and no OK or Cancel button.
        String[] words = {PlayFinishPrompt.TITLE, PlayFinishPrompt.DRAFT_BODY, PlayFinishPrompt.DRAFT_OPEN,
                PlayFinishPrompt.DRAFT_LATER};
        boolean amp = false;
        for (String w : words) amp |= w == null || w.isEmpty() || w.contains("&");
        check("C4 every word is set and holds no \"&\"", !amp);
        for (String b : new String[] {PlayFinishPrompt.DRAFT_OPEN, PlayFinishPrompt.DRAFT_LATER}) {
            check("C4 button \"" + b + "\" is not OK or Cancel", !"OK".equalsIgnoreCase(b) && !"Cancel".equalsIgnoreCase(b));
        }
        System.out.println(fail == 0 ? "ALL " + pass + " PASS" : fail + " FAIL, " + pass + " pass");
        System.exit(fail == 0 ? 0 : 1);
    }
}
