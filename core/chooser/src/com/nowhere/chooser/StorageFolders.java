package com.nowhere.chooser;

/**
 * The words "What's using your space" puts on its folder rows (NWP-20261125-09). They live here so a javac suite can
 * pin them.
 *
 * The shape is decided in docs/product-decisions.md, h51 #4 A1 (2026-11-01): "one row per top-level folder (Download,
 * Pictures, DCIM and the others, plus one row for files outside them), each with both figures, in place of the one
 * row". The daemon's GET-STORAGE-BREAKDOWN reply carries the list as {@code folders} ([{name, bytes, store}], "" = the
 * files outside every folder) and says by {@code folders_measured} whether the store figures are real.
 *
 * The sizes arrive already formatted: humanBytes stays in ProfileActivity.
 */
final class StorageFolders {
    private StorageFolders() {}

    /** The title of the row that holds the files outside every top-level folder (the daemon's name ""). */
    static final String OUTSIDE = "Files outside folders";

    /** The row's title: the folder's name, or {@link #OUTSIDE} for the daemon's "". */
    static String title(String name) {
        if (name == null || name.isEmpty()) return OUTSIDE;
        return name;
    }

    /**
     * The row's line. Measured: the plan figure first, as the remainder row leads with it, so the plan column adds up.
     * Not measured: the words of the one row this list replaces, because the store figure is not known yet.
     */
    static String line(String phone, String plan, boolean measured) {
        if (measured) return plan + " of your plan · " + phone + " on this phone";
        return phone + " on this phone · always comes with you";
    }

    /** Draw the folder rows in place of the one row only when the reply named a folder (an older daemon names none). */
    static boolean useFolderRows(int n) {
        return n > 0;
    }
}
