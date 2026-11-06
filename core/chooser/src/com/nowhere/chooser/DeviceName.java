package com.nowhere.chooser;

/**
 * NWP-20261114-28: the name the owner gives this phone at first-run setup. Decided 2026-09-12 (NWP-20260912-01):
 * the name is set in first run's device-passphrase step, "The name field goes there and nothing moves"; seeded from
 * Build.MODEL (#37, 2026-10-22). The agent keeps it in /data/nowhere/device-label (G-07, NWP-20261114-24) and puts it
 * beside this phone's chip slot, where another phone reads it.
 *
 * <p>{@link #valid} mirrors validDeviceLabel in core/agent/device_label.go: 1 to 40 runes after a trim, every rune
 * printable as Go's unicode.IsPrint defines it. The agent stays the authority: a name it refuses answers ERR-ARGS and
 * its label falls back to the model. Managed units never see first run; their name arrives in signed configuration.
 *
 * <p>Pure java, no android imports, so a javac suite compiles it alone (core/vendor-common/bin/test-device-name-java.sh).
 */
final class DeviceName {
    private DeviceName() {}

    /** maxDeviceLabelRunes in core/agent/device_label.go. */
    static final int MAX = 40;

    /** The one inline line an invalid name shows. Setup does not go on until the name is valid. */
    static final String INVALID_LINE = "Name this phone in 1 to 40 characters, on one line";

    /** Go's strings.TrimSpace: drops leading and trailing white space code points. null gives "". */
    static String trim(String s) {
        if (s == null) return "";
        int b = 0, e = s.length();
        while (b < e) {
            int cp = s.codePointAt(b);
            if (!space(cp)) break;
            b += Character.charCount(cp);
        }
        while (e > b) {
            int cp = s.codePointBefore(e);
            if (!space(cp)) break;
            e -= Character.charCount(cp);
        }
        return s.substring(b, e);
    }

    /** Go's unicode.IsSpace, the set strings.TrimSpace drops: '\t' '\n' '\v' '\f' '\r' ' ' U+0085 U+00A0, and above
     *  Latin-1 the White_Space code points, which are category Z (Character.isSpaceChar). Not Character.isWhitespace:
     *  that also takes U+001C..U+001F (control chars the agent refuses) and leaves out U+0085 and U+00A0. */
    static boolean space(int cp) {
        switch (cp) {
            case '\t': case '\n': case 0x0B: case '\f': case '\r': case ' ': case 0x85: case 0xA0:
                return true;
            default:
                return cp > 0xFF && Character.isSpaceChar(cp);
        }
    }

    /** validDeviceLabel: 1 to MAX code points after trim, every one printable (no control, format or separator but ' '). */
    static boolean valid(String s) {
        if (s == null) return false;
        String t = trim(s);
        int n = t.codePointCount(0, t.length());
        if (n < 1 || n > MAX) return false;
        for (int i = 0; i < t.length(); ) {
            int cp = t.codePointAt(i);
            if (!printable(cp)) return false;
            i += Character.charCount(cp);
        }
        return true;
    }

    /** Go's unicode.IsPrint: categories L, M, N, P, S, and the ASCII space. A lone surrogate is category Cs: refused. */
    private static boolean printable(int cp) {
        if (cp == ' ') return true;
        switch (Character.getType(cp)) {
            case Character.UPPERCASE_LETTER: case Character.LOWERCASE_LETTER: case Character.TITLECASE_LETTER:
            case Character.MODIFIER_LETTER: case Character.OTHER_LETTER:
            case Character.NON_SPACING_MARK: case Character.ENCLOSING_MARK: case Character.COMBINING_SPACING_MARK:
            case Character.DECIMAL_DIGIT_NUMBER: case Character.LETTER_NUMBER: case Character.OTHER_NUMBER:
            case Character.CONNECTOR_PUNCTUATION: case Character.DASH_PUNCTUATION: case Character.START_PUNCTUATION:
            case Character.END_PUNCTUATION: case Character.INITIAL_QUOTE_PUNCTUATION:
            case Character.FINAL_QUOTE_PUNCTUATION: case Character.OTHER_PUNCTUATION:
            case Character.MATH_SYMBOL: case Character.CURRENCY_SYMBOL: case Character.MODIFIER_SYMBOL:
            case Character.OTHER_SYMBOL:
                return true;
            default:
                return false;
        }
    }

    /** The first-run prefill: the trimmed model when it is a valid name, else "" (the owner types one). */
    static String seed(String model) {
        return valid(model) ? trim(model) : "";
    }

    /**
     * The field's length cap, as android.text.InputFilter.filter: MAX code points, not UTF-16 units (LengthFilter counts
     * units, so it kept only 20 of 40 emoji and cut a supplementary model). Returns null to take the source whole, else
     * the part of source[start, end) that fits, cut on a code point boundary ("" when nothing fits).
     */
    static CharSequence cap(CharSequence source, int start, int end, CharSequence dest, int dstart, int dend) {
        int kept = Character.codePointCount(dest, 0, dest.length()) - Character.codePointCount(dest, dstart, dend);
        int room = MAX - kept;
        if (room <= 0) return "";
        if (Character.codePointCount(source, start, end) <= room) return null;
        return source.subSequence(start, Character.offsetByCodePoints(source, start, room));
    }

    /** The gate-only verb's request. The trailing newline ends the label: the agent reads it with ReadString('\n'). */
    static String request(String label) {
        return "SET-DEVICE-LABEL\n" + trim(label) + "\n";
    }
}
