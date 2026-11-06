package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

/**
 * Search and filters for the issue report's "View what's sent" screen (NWP-20261113-39, backlog row "The issue
 * report's "View what's sent" is one block of plain text: no search, no filter by log or tag").
 *
 * <p>The preview is core/agent/report_issue.go's {@code json.MarshalIndent(rep, "", "  ")} of its issueReport: the
 * top-level scalars at two spaces, the {@code "status"} object's entries at four, each {@code "logs"} key at four
 * and that log's lines at six, one escaped JSON string per line. This class reads that shape line by line and never
 * unescapes: what {@link #filter} returns is only FEWER LINES of the preview, byte for byte, so the screen still shows
 * nothing but the scrubbed bytes the daemon would send.
 *
 * <p>The parse is strict. A preview in which any line does not fit (an older or different daemon) has no sections and
 * no tags, and {@link #filter} returns it whole: a half-understood preview would let a filter hide lines it had put in
 * the wrong section. Pure java.lang / java.util; it logs nothing.
 */
final class ReportPreviewFilter {
    private ReportPreviewFilter() {}

    /** The pseudo-section holding the report's "status" entries. */
    static final String STATUS = "status";

    /** One line of the preview: its section ("" = none), its tag (null = none), and whether it heads a section. */
    private static final class Line {
        final String text, section, tag;
        final boolean header;

        Line(String text, String section, String tag, boolean header) {
            this.text = text; this.section = section; this.tag = tag; this.header = header;
        }
    }

    private static final int TOP = 0, IN_STATUS = 1, IN_LOGS = 2, IN_SECTION = 3;

    /** The preview's lines classified, or null when any line does not fit the MarshalIndent shape. */
    private static List<Line> parse(String preview) {
        if (preview == null) return null;
        String[] ls = preview.split("\n", -1);
        int n = ls.length;
        while (n > 0 && ls[n - 1].isEmpty()) n--;
        if (n < 2 || !ls[0].equals("{") || !ls[n - 1].equals("}")) return null;
        List<Line> out = new ArrayList<>();
        int state = TOP;
        boolean sawStatus = false, sawLogs = false;
        String cur = null;
        for (int i = 1; i < n - 1; i++) {
            String l = ls[i];
            int ind = 0;
            while (ind < l.length() && l.charAt(ind) == ' ') ind++;
            String rest = l.substring(ind);
            switch (state) {
                case TOP: {
                    if (ind != 2) return null;
                    String key = key(rest), val = value(rest);
                    if (key == null || val == null || val.isEmpty()) return null;
                    if (key.equals(STATUS)) {
                        if (sawStatus) return null;
                        sawStatus = true;
                        if (val.equals("{")) state = IN_STATUS;
                        else if (!empty(val, "{}")) return null;
                        out.add(new Line(l, STATUS, null, true));
                    } else if (key.equals("logs")) {
                        if (sawLogs) return null;
                        sawLogs = true;
                        if (val.equals("{")) state = IN_LOGS;
                        else if (!empty(val, "{}")) return null;
                        out.add(new Line(l, "", null, false));
                    } else {
                        out.add(new Line(l, "", null, false));
                    }
                    break;
                }
                case IN_STATUS:
                    if (ind == 2 && closes(rest, "}")) {
                        state = TOP;
                        out.add(new Line(l, "", null, false));
                    } else if (ind == 4 && key(rest) != null && value(rest) != null) {
                        out.add(new Line(l, STATUS, null, false));
                    } else {
                        return null;
                    }
                    break;
                case IN_LOGS: {
                    if (ind == 2 && closes(rest, "}")) {
                        state = TOP;
                        out.add(new Line(l, "", null, false));
                        break;
                    }
                    String key = ind == 4 ? key(rest) : null, val = key == null ? null : value(rest);
                    if (val == null || key.isEmpty()) return null;
                    if (val.equals("[")) {
                        state = IN_SECTION;
                        cur = key;
                    } else if (!empty(val, "[]")) {
                        return null;
                    }
                    out.add(new Line(l, key, null, true));
                    break;
                }
                default: // IN_SECTION
                    if (ind == 4 && closes(rest, "]")) {
                        state = IN_LOGS;
                        out.add(new Line(l, "", null, false));
                    } else if (ind == 6 && logLine(rest)) {
                        out.add(new Line(l, cur, tagOf(rest), false));
                    } else {
                        return null;
                    }
                    break;
            }
        }
        return state == TOP && sawLogs ? out : null;
    }

    /** The key of a {@code "key": value} line (keys here carry no escapes), or null. */
    private static String key(String rest) {
        if (!rest.startsWith("\"")) return null;
        int q = rest.indexOf('"', 1);
        if (q < 0 || !rest.startsWith("\": ", q)) return null;
        String k = rest.substring(1, q);
        return k.indexOf('\\') >= 0 ? null : k;
    }

    /** The value text after a key's {@code ": }, or null. */
    private static String value(String rest) {
        int q = rest.indexOf('"', 1);
        return q < 0 || !rest.startsWith("\": ", q) ? null : rest.substring(q + 3);
    }

    /** True for an empty block value: {@code {}} / {@code []} or {@code null}, with an optional trailing comma. */
    private static boolean empty(String val, String pair) {
        String v = val.endsWith(",") ? val.substring(0, val.length() - 1) : val;
        return v.equals(pair) || v.equals("null");
    }

    /** True for a block closer, {@code }} or {@code ]}, with an optional trailing comma. */
    private static boolean closes(String rest, String closer) {
        return rest.equals(closer) || rest.equals(closer + ",");
    }

    /** True for a log line's JSON string: {@code "..."} or {@code "...",}. */
    private static boolean logLine(String rest) {
        if (!rest.startsWith("\"")) return false;
        String s = rest.endsWith(",") ? rest.substring(0, rest.length() - 1) : rest;
        return s.length() >= 2 && s.endsWith("\"");
    }

    /** The leading {@code [tag]} of a log line's text (brackets included): 1-32 of A-Z a-z 0-9 . _ : -, or null. */
    private static String tagOf(String rest) {
        if (rest.length() < 4 || rest.charAt(1) != '[') return null;
        int j = 2;
        while (j < rest.length() && j - 2 < 32) {
            char c = rest.charAt(j);
            boolean ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                    || c == '.' || c == '_' || c == ':' || c == '-';
            if (!ok) break;
            j++;
        }
        return j > 2 && j < rest.length() && rest.charAt(j) == ']' ? rest.substring(1, j + 1) : null;
    }

    /** "status" (when the report has the key) then the keys of "logs" in the preview's order; [] if unparseable. */
    static List<String> sections(String preview) {
        List<Line> ls = parse(preview);
        List<String> out = new ArrayList<>();
        if (ls == null) return out;
        for (Line l : ls) if (l.header) out.add(l.section);
        return out;
    }

    /** The distinct leading [tag]s of the log lines, in first-seen order; [] if unparseable. */
    static List<String> tags(String preview) {
        List<Line> ls = parse(preview);
        LinkedHashSet<String> out = new LinkedHashSet<>();
        if (ls != null) for (Line l : ls) if (l.tag != null) out.add(l.tag);
        return new ArrayList<>(out);
    }

    /** The preview's lines in {@code section} with {@code tag} (null = all, for either), each section that keeps a
     *  line led by its own header line; every line exactly as the preview has it. Both null, or an unparseable
     *  preview, returns the preview itself; nothing kept returns "". */
    static String filter(String preview, String section, String tag) {
        if (section == null && tag == null) return preview;
        List<Line> ls = parse(preview);
        if (ls == null) return preview;
        StringBuilder sb = new StringBuilder();
        Line head = null;
        for (Line l : ls) {
            if (l.header) { head = l; continue; }
            if (l.section.isEmpty()) continue;
            boolean keep = (section == null || section.equals(l.section)) && (tag == null || tag.equals(l.tag));
            if (!keep) continue;
            if (head != null) { sb.append(head.text).append('\n'); head = null; }
            sb.append(l.text).append('\n');
        }
        return sb.toString();
    }

    /** The start offsets of {@code query} in {@code text}, case-insensitive and not overlapping; none for an empty or
     *  null query. regionMatches, not toLowerCase, so every offset indexes the shown text itself. */
    static int[] matches(String text, String query) {
        if (text == null || query == null || query.isEmpty()) return new int[0];
        int q = query.length();
        int[] hits = new int[16];
        int k = 0;
        for (int i = 0; i + q <= text.length(); ) {
            if (text.regionMatches(true, i, query, 0, q)) {
                if (k == hits.length) hits = java.util.Arrays.copyOf(hits, k * 2);
                hits[k++] = i;
                i += q;
            } else {
                i++;
            }
        }
        return java.util.Arrays.copyOf(hits, k);
    }
}
