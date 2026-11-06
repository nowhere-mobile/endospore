package com.nowhere.chooser;

/** NWP-20261109-25: the XML attribute escaper behind the Export a copy's messages.xml and calls.xml, lifted out of
 *  ProfileActivity so a test can run it (core/vendor-common/bin/test-export-xml-java.sh). Pure java.lang -- no Android.
 *
 *  The old xmlAttr had two gaps. (1) A C0 control other than tab/LF/CR, U+FFFE/U+FFFF or an unpaired surrogate was
 *  written raw; XML 1.0 forbids them (the Char production), so one such text made the whole file unparseable by a
 *  conforming reader, and an unpaired surrogate also became '?' through getBytes("UTF-8"). (2) A tab was written raw
 *  inside an attribute value, which a parser normalizes to a space, so a tabbed text came back changed. */
final class ExportXml {
    private ExportXml() {}

    /** Escape a value for an XML attribute: & < > " as entities, CRLF / LF / CR as one &#10; each, tab as &#9;, and
     *  every code point outside the Char production (or an unpaired surrogate) as U+FFFD. A valid surrogate pair is
     *  kept whole. null is "". */
    static String attr(String s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder(s.length() + 16);
        int i = 0, n = s.length();
        while (i < n) {
            int cp = s.codePointAt(i);
            i += Character.charCount(cp);
            switch (cp) {
                case '&': b.append("&amp;"); break;
                case '<': b.append("&lt;"); break;
                case '>': b.append("&gt;"); break;
                case '"': b.append("&quot;"); break;
                case '\r':
                    if (i < n && s.charAt(i) == '\n') i++;
                    b.append("&#10;");
                    break;
                case '\n': b.append("&#10;"); break;
                case '\t': b.append("&#9;"); break;
                default:
                    boolean ok = (cp >= 0x20 && cp <= 0xD7FF) || (cp >= 0xE000 && cp <= 0xFFFD)
                            || (cp >= 0x10000 && cp <= 0x10FFFF);
                    // U+FFFD as a char value, not a unicode escape: test-tel-scrub.sh refuses an escape it does not list
                    // in every Java source the chooser compiles.
                    if (ok) b.appendCodePoint(cp); else b.append((char) 0xFFFD);
            }
        }
        return b.toString();
    }
}
