package com.nowhere.chooser;

import java.util.Locale;

/**
 * NWP-20261117-43: Profile's time zone search and its row label, lifted out of ProfileActivity so they run under javac.
 *
 * A row shows the Olson id with every '_' as a space ("America/New York"), so the search folds '_' to a space on both
 * the id and the typed text: a city typed as its row spells it is found. Case folds with Locale.ROOT, not the default
 * locale: under tr-TR "Europe/Istanbul".toLowerCase() is "europe/ıstanbul" (dotless i), and "istanbul" never matched.
 * The label formats its digits with Locale.ROOT too, so the offset reads the same in every locale. The offset is a
 * parameter, so test-zone-search-java.sh runs the label without a clock or zone data.
 */
final class ZoneSearch {
    private ZoneSearch() {}

    /** The form both sides are compared in: null reads as "", '_' becomes ' ', lower case in Locale.ROOT, trimmed. */
    static String fold(String s) {
        if (s == null) return "";
        return s.replace('_', ' ').toLowerCase(Locale.ROOT).trim();
    }

    /** True when the query is empty or the zone's folded id holds the folded query. */
    static boolean matches(String olsonId, String query) {
        String f = fold(query);
        return f.isEmpty() || fold(olsonId).contains(f);
    }

    /** True when the "Automatic" row is listed: an empty query, or one that starts the word "automatic". */
    static boolean automaticMatches(String query) {
        String f = fold(query);
        return f.isEmpty() || "automatic".startsWith(f);
    }

    /** "America/New York  (GMT-05:00)" for an offset of -300 minutes. */
    static String label(String olsonId, int offsetMinutes) {
        char sign = offsetMinutes < 0 ? '-' : '+';
        int off = Math.abs(offsetMinutes);
        return olsonId.replace('_', ' ') + "  (GMT" + sign
                + String.format(Locale.ROOT, "%02d:%02d", off / 60, off % 60) + ")";
    }
}
