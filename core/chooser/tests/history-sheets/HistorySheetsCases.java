package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261205-14: the History screen's two confirmations as sheet models. Each failure line names its case. The
 *  expected words are literals, never read back from HistorySheets or SnapshotCopy. */
final class HistorySheetsCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static boolean button(Confirm c, int i, String label, Style style) {
        return c.buttons.size() > i && c.buttons.get(i) != null && label.equals(c.buttons.get(i).label)
                && c.buttons.get(i).style == style;
    }

    private static int count(Confirm c, Style style) {
        int n = 0;
        for (Button b : c.buttons) if (b != null && b.style == style) n++;
        return n;
    }

    private static boolean lines(Confirm c, String... want) {
        if (c.lines.size() != want.length) return false;
        for (int i = 0; i < want.length; i++) {
            Line l = c.lines.get(i);
            if (l == null || !want[i].equals(l.text) || l.linkKey != null) return false;
        }
        return true;
    }

    private static boolean okOrCancel(Confirm c) {
        for (Button b : c.buttons) {
            if (b == null || b.label == null) continue;
            String l = b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) return true;
        }
        return false;
    }

    private static String join(Confirm c) {
        List<String> parts = new ArrayList<>();
        parts.add(c.context);
        for (Line l : c.lines) parts.add(l == null ? "" : l.text);
        return String.join(" ", parts);
    }

    static final String LABEL = "Oct 3, 4:05 PM";
    /** The delete message before NWP-20261205-14. */
    static final String OLD_DELETE = "The version saved Oct 3, 4:05 PM will be deleted from your store. This can't be "
            + "undone, and you won't be able to restore it. Your current data and your other saved versions are not "
            + "affected.";

    public static void main(String[] args) {
        Confirm d = HistorySheets.delete(LABEL);
        check("delete tone", d.tone == Tone.DESTRUCTIVE);
        check("delete title", "Delete this version?".equals(d.title));
        check("delete context", "The version saved Oct 3, 4:05 PM will be deleted from your store.".equals(d.context));
        check("delete lines", lines(d, "This can't be undone, and you won't be able to restore it.",
                "Your current data and your other saved versions are not affected."));
        check("delete buttons", d.buttons.size() == 2);
        check("delete red first", button(d, 0, "Delete this version", Style.RED_FILLED));
        check("delete keep second", button(d, 1, "Keep this version", Style.OUTLINED));
        check("delete no green", count(d, Style.GREEN_FILLED) == 0);

        Confirm r = HistorySheets.rollback(LABEL);
        check("rollback tone", r.tone == Tone.WARNING);
        check("rollback title", "Restore this version?".equals(r.title));
        check("rollback context", "This rolls your data back to the version saved Oct 3, 4:05 PM.".equals(r.context));
        check("rollback lines", lines(r, "Your current data on this device will be discarded.",
                "You'll be signed out — sign in again to load the earlier version."));
        check("rollback buttons", r.buttons.size() == 2);
        check("rollback green first", button(r, 0, "Keep my current data", Style.GREEN_FILLED)
                && count(r, Style.GREEN_FILLED) == 1);
        check("rollback restore red-outlined", button(r, 1, "Restore", Style.RED_OUTLINED));

        check("no OK or Cancel", !okOrCancel(d) && !okOrCancel(r));

        List<String> dv = PopupSheet.violations(d);
        if (!dv.isEmpty()) System.out.println("  delete breaches: " + dv);
        check("delete violations", dv.isEmpty());
        List<String> rv = PopupSheet.violations(r);
        if (!rv.isEmpty()) System.out.println("  rollback breaches: " + rv);
        check("rollback violations", rv.isEmpty());

        for (String l : Arrays.asList(LABEL, "earlier")) {
            check("label in context", HistorySheets.delete(l).context.contains(l)
                    && HistorySheets.rollback(l).context.contains(l));
        }
        check("old message kept", OLD_DELETE.equals(join(d)));

        if (failed > 0) {
            System.out.println(failed + " failure(s)");
            System.exit(1);
        }
        System.out.println("ok history sheets");
    }
}
