package com.nowhere.chooser;

/** NWP-20261202-22 (docs/product-decisions.md, 2026-11-10, "Create offers to finish setting up Google Play after the
 *  first switch-in, ...", item 1): the rule and the words of the one-time "Finish setting up Google Play" card. Pure
 *  java.lang (and PlayChoice.State), so test-play-finish-prompt-java.sh compiles and runs it as-is.
 *
 *  The marker is the nowhere-config key play.finish, so it roams with nowhere-config: the card shows once per profile,
 *  on any phone. PlayAtCreateReceiver writes PENDING with play.wanted=1 at Create; PlayFinishActivity.check, at the
 *  switch-landing, shows the card or settles the marker, and the card writes DONE at its first onResume. Only the
 *  exact PENDING value shows anything: an absent key (cfgStatic answers "off") and DONE are NONE, so a profile made
 *  before this slice never sees the card. */
final class PlayFinishPrompt {
    private PlayFinishPrompt() {}

    static final String CFG_KEY = "play.finish";
    static final String PENDING = "1";
    static final String DONE = "0";

    /** Decided (2026-11-10, item 1). */
    static final String TITLE = "Finish setting up Google Play";
    // DRAFTS awaiting Chester's approval; only TITLE is decided. The PR body and the commit message carry the mockup.
    static final String DRAFT_BODY = "You chose Google Play for this profile. Install it from the GrapheneOS App Store; "
            + "it downloads about 130 MB.";
    static final String DRAFT_OPEN = "Open App Store";
    static final String DRAFT_LATER = "Not now";

    /** A LandingLine.EXTRA_OPEN value: ProfileActivity opens Your apps, then the GrapheneOS App Store. */
    static final String OPEN_PLAY = "play-entry";

    enum Verdict { SHOW, SETTLE, NONE }

    /** What the switch-landing does with the marker. Not exactly PENDING: nothing. Play not on here (off, no choice,
     *  or no GrapheneOS App Store, as PlayChoice.effective reads it), or Play Store already on the phone (installed or
     *  an archived placeholder): settle the marker without a card. Else show the card. */
    static Verdict decide(String marker, PlayChoice.State effective, boolean playStoreOnPhone) {
        if (!PENDING.equals(marker)) return Verdict.NONE;
        if (effective != PlayChoice.State.ON) return Verdict.SETTLE;
        if (playStoreOnPhone) return Verdict.SETTLE;
        return Verdict.SHOW;
    }
}
