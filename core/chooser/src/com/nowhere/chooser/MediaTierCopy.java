package com.nowhere.chooser;

/**
 * The words on each Offline media row's tier control (NWP-20261105-10, docs/product-decisions.md 2026-10-20, Q074).
 * The words stay -- they mean the same as the Apps screens' keep-mode chip (at sign-in, in the background, when
 * opened) -- and the caption says what the tier is OF: the app's maps & files, not the app itself. They live here so
 * a javac suite can pin them.
 */
final class MediaTierCopy {
    private MediaTierCopy() {}

    /** Shown above each row's control, and read by TalkBack as the control's description. */
    static final String CAPTION = "Maps & files";

    /** The control's segments, in tier order: 0 = Essential, 1 = Auto, 2 = On-demand. */
    private static final String[] LABELS = { "Essential", "Auto", "On-demand" };

    /** A copy, so no caller can rename a segment for every later row. */
    static String[] labels() {
        return LABELS.clone();
    }
}
