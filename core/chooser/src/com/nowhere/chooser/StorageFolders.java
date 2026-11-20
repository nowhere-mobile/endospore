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

    // NWP-20261210-22 (h51 #4): "a folder row gets the same for its streamed copies". A named folder row offers
    // Free on this phone (FreeOnPhone.LINK), which sends FREE-MEDIA-FOLDER and shows the reply in these words.

    // Draft words, for Chester to correct.
    static final String FREED_PREFIX = "Freed ";
    static final String FREED_SUFFIX = " of streamed copies";
    static final String NOTHING = "Nothing streamed from this folder is on the phone";
    static final String NO_SESSION = "No active session";
    static final String FAILED = "Couldn't free space — try again";

    /**
     * True when a folder row offers Free on this phone: a named folder (the daemon refuses "", so the files outside
     * every folder are never offered) whose store figures are measured and hold something. The reply carries no
     * per-folder streamed figure, so a folder with nothing fetched is offered too, and answers {@link #NOTHING}.
     */
    static boolean freeOffer(String name, long store, boolean measured) {
        if (name == null || name.isEmpty()) return false;
        return measured && store > 0;
    }

    /** The bytes an "OK <n>" reply freed (n digits only); -1 for any other reply. */
    static long freedBytes(String reply) {
        if (reply == null) return -1;
        String r = reply.trim();
        if (!r.startsWith("OK ")) return -1;
        String d = r.substring(3);
        if (d.isEmpty()) return -1;
        for (int i = 0; i < d.length(); i++) {
            char c = d.charAt(i);
            if (c < '0' || c > '9') return -1;
        }
        try {
            return Long.parseLong(d);
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** The toast for a FREE-MEDIA-FOLDER reply; {@code freed} is the formatted size, used only for "OK n" n > 0. */
    static String freeMessage(String reply, String freed) {
        long n = freedBytes(reply);
        if (n > 0) return FREED_PREFIX + freed + FREED_SUFFIX;
        if (n == 0) return NOTHING;
        String r = reply == null ? "" : reply.trim();
        if ("NONE".equals(r)) return NO_SESSION;
        return FAILED;
    }
}
