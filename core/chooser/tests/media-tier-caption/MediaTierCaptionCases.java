// NWP-20261105-10 (Q074): the caption and the three words of the Offline media tier control. The run.sh next to
// this file prepends the package line and compiles it with MediaTierCopy.
public class MediaTierCaptionCases {
    static int failed = 0;

    static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok   " : "  FAIL ") + name);
        if (!ok) failed++;
    }

    public static void main(String[] args) {
        check("c1 the caption is \"Maps & files\"", MediaTierCopy.CAPTION.equals("Maps & files"));
        check("c2 labels() is Essential, Auto, On-demand in order",
            java.util.Arrays.equals(MediaTierCopy.labels(), new String[]{"Essential", "Auto", "On-demand"}));
        String[] a = MediaTierCopy.labels();
        a[2] = "Streamed";
        a[0] = null;
        check("c3 changing the returned array leaves the next labels() alone",
            a != MediaTierCopy.labels()
            && java.util.Arrays.equals(MediaTierCopy.labels(), new String[]{"Essential", "Auto", "On-demand"}));
        if (failed > 0) System.exit(1);
    }
}
