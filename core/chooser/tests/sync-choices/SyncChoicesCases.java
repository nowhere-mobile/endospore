// Cases for SyncChoices (NWP-20261202-25). Run by run.sh; prints "  ok   <case>" or "--- FAIL <case>: <detail>" per
// case and exits 1 on any failure.
public class SyncChoicesCases {
    static int fails = 0;

    static void ok(String name, boolean cond, String detail) {
        if (cond) System.out.println("  ok   " + name);
        else { System.out.println("--- FAIL " + name + ": " + detail); fails++; }
    }

    public static void main(String[] a) {
        int[] s = SyncChoices.SECS;
        String[] l = SyncChoices.LABELS;
        ok("C1 SECS is {120, 300, 600, 900, 1800}",
                java.util.Arrays.equals(s, new int[] {120, 300, 600, 900, 1800}), "got " + java.util.Arrays.toString(s));
        ok("C2 one label per choice", l.length == s.length, l.length + " labels for " + s.length + " choices");

        int marked = 0, at = -1;
        for (int i = 0; i < l.length; i++) if (l[i].endsWith(" (default)")) { marked++; at = i; }
        ok("C3 exactly one label is marked (default)", marked == 1, marked + " marked");
        ok("C3 DEFAULT_SECS is 900", SyncChoices.DEFAULT_SECS == 900, "got " + SyncChoices.DEFAULT_SECS);
        ok("C3 the marked label is DEFAULT_SECS's choice",
                marked == 1 && at < s.length && s[at] == SyncChoices.DEFAULT_SECS,
                "marked index " + at + ", DEFAULT_SECS " + SyncChoices.DEFAULT_SECS);

        int low = Integer.MAX_VALUE;
        for (int v : s) low = Math.min(low, v);
        ok("C4 no choice is under 2 minutes", low >= 120, "lowest " + low);

        StringBuilder bad = new StringBuilder();
        for (int i = 0; i < Math.min(s.length, l.length); i++) {
            String want = "E" + ReplyCopy.prettyInterval(s[i]).substring(1);
            String got = l[i].endsWith(" (default)") ? l[i].substring(0, l[i].length() - " (default)".length()) : l[i];
            if (!want.equals(got)) bad.append(" [").append(i).append("] '").append(got).append("' != '").append(want).append("'");
        }
        ok("C5 each label says its choice as the backup row does", bad.length() == 0, bad.toString());

        if (fails > 0) System.exit(1);
    }
}
