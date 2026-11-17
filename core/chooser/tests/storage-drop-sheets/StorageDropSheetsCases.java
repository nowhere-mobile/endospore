package com.nowhere.chooser;

import java.util.List;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261205-15: the Storage screen's three sheets. Each failure line names its case. The "today" literals are the
 *  AlertDialog messages these sheets replace, so the split keeps today's words. */
final class StorageDropSheetsCases {
    private static int failed;

    private static final String TODAY_STOP_KEEPING = "It stays on this phone and keeps working until you log off. It "
            + "just won't come back on your next phone. Its data stops being carried when you log off — what your plan "
            + "counts then takes a few days to drop, because recent backups are kept for a while.";
    private static final String TODAY_STOP_CARRYING = "This app is not on your phone any more, but your profile is "
            + "still carrying its data — and still counting it against your plan. Stopping means the data is not kept "
            + "when you log off. What your plan counts takes a few days to drop, because recent backups are kept for "
            + "a while.";
    private static final String TODAY_OVER_PLAN = "Keeping Maps would put your account over the storage your plan "
            + "covers. Free up space or add storage, then try again.";

    private static void check(String name, boolean ok) {
        if (ok) {
            System.out.println("  ok    " + name);
            return;
        }
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static int greens(Confirm c) {
        int n = 0;
        for (Button b : c.buttons) if (b.style == Style.GREEN_FILLED) n++;
        return n;
    }

    private static String message(Confirm c) {
        StringBuilder sb = new StringBuilder(c.context);
        for (Line l : c.lines) sb.append(' ').append(l.text);
        return sb.toString();
    }

    private static boolean line(List<Line> lines, int i, String text) {
        return lines.size() > i && text.equals(lines.get(i).text) && lines.get(i).linkKey == null;
    }

    private static boolean button(Confirm c, int i, String label, Style style) {
        return c.buttons.size() > i && label.equals(c.buttons.get(i).label) && c.buttons.get(i).style == style;
    }

    /** The seven cases of a stop sheet: amber, the label in the title, the green way out first, the red Stop second. */
    private static void stop(String n, Confirm c, String title, String keep, String stop, String context,
            String line1, String line2, String today) {
        check(n + " tone", c.tone == Tone.WARNING);
        check(n + " title", title.equals(c.title));
        check(n + " green button", greens(c) == 1 && button(c, 0, keep, Style.GREEN_FILLED)
                && !c.buttons.get(0).label.startsWith("Stop"));
        check(n + " stop button", c.buttons.size() == 2 && button(c, 1, stop, Style.RED_OUTLINED));
        check(n + " lines", context.equals(c.context) && c.lines.size() == 2 && line(c.lines, 0, line1)
                && line(c.lines, 1, line2));
        check(n + " message", today.equals(message(c)));
        check(n + " violations", PopupSheet.violations(c).isEmpty());
    }

    public static void main(String[] args) {
        stop("stopKeeping", StorageDropSheets.stopKeeping("Maps"), "Stop keeping Maps?", "Keep it", "Stop keeping it",
                "It stays on this phone and keeps working until you log off.",
                "It just won't come back on your next phone.",
                "Its data stops being carried when you log off — what your plan counts then takes a few days to drop, "
                        + "because recent backups are kept for a while.",
                TODAY_STOP_KEEPING);
        stop("stopCarrying", StorageDropSheets.stopCarrying("Maps"), "Stop carrying Maps?", "Keep carrying it",
                "Stop carrying it",
                "This app is not on your phone any more, but your profile is still carrying its data — and still "
                        + "counting it against your plan.",
                "Stopping means the data is not kept when you log off.",
                "What your plan counts takes a few days to drop, because recent backups are kept for a while.",
                TODAY_STOP_CARRYING);

        Confirm o = StorageDropSheets.overPlan("Maps");
        check("overPlan tone", o.tone == Tone.ROUTINE);
        check("overPlan title", "Not enough storage for Maps".equals(o.title));
        check("overPlan context", "Keeping Maps would put your account over the storage your plan covers.".equals(o.context));
        check("overPlan buttons", o.buttons.size() == 2 && greens(o) == 1
                && button(o, 0, "See what's using space", Style.GREEN_FILLED)
                && button(o, 1, "Not now", Style.OUTLINED));
        check("overPlan lines", o.lines.size() == 1 && line(o.lines, 0, "Free up space or add storage, then try again."));
        check("overPlan message", TODAY_OVER_PLAN.equals(message(o)));
        check("overPlan violations", PopupSheet.violations(o).isEmpty());

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases pass");
    }
}
