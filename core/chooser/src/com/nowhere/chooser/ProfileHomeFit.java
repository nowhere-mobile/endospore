package com.nowhere.chooser;

/**
 * NWP-20261130-10: the vertical spacings of the Profile app's main screen (ProfileActivity.showConfirm and
 * addPrivacyLevelCard), in dp, so that the name, the status line, Lock and Log off, the Privacy level card, the six-row
 * menu, Delete this profile and Done fit one screen with no scrollbar at default display and font size
 * (docs/backlog.md, "The Profile app's main screen scrolls: ..."). Larger text still scrolls: the screen's container
 * stays a ScrollView.
 *
 * The budget is the smallest release device: Pixel 7a (lynx), 1080x2400 at density 420, is 914dp high; less a 52dp
 * status bar and a 24dp gesture bar is 838dp, or 814dp with three-button navigation. The Standard level adds up to
 * about 789dp with these values and about 882dp with the values before this class. Those heights are estimates;
 * core/chooser/test-profile-home-fit-java.sh holds the model, and only a handset proves the fit.
 *
 * Pure so a javac suite can compile it off the build host.
 */
final class ProfileHomeFit {
    private ProfileHomeFit() {}

    /** Above the name. */
    static final int PAD_TOP = 16;
    /** Below Done. */
    static final int PAD_BOTTOM = 8;
    /** The name to the status line. The status line's 48dp tap target (MIN_TOUCH) holds the space, so no margin. */
    static final int NAME_TO_STATUS = 0;
    /** The status line to Lock. No margin, as above. */
    static final int STATUS_TO_LOCK = 0;
    static final int LOCK_TO_LOGOFF = 8;
    /** Above the Privacy level card. */
    static final int CARD_GAP = 12;
    static final int CARD_PAD_TOP = 12;
    static final int CARD_PAD_BOTTOM = 2;
    /** The card's title to its five-step scale. */
    static final int SCALE_GAP = 8;
    /** The card's scale to the level's name. */
    static final int LEVEL_GAP = 4;
    /** Above and below the text of the card's dropdown row. */
    static final int PICK_PAD = 6;
    /** Above the six-row menu. */
    static final int MENU_GAP = 12;
    /** The menu to Delete this profile. */
    static final int LINK_GAP = 4;
    /** Above and below the text of Delete this profile and of Done. */
    static final int LINK_PAD = 8;
    /** The lowest a tap target on this screen may be. */
    static final int MIN_TOUCH = 48;
}
