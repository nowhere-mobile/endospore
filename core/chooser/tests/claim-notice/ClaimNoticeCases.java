package com.nowhere.chooser;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;
import java.util.Locale;

/** NWP-20261208-04: Profile's claim notice. Each failure line starts with its case id (K1 count, K2 the requests, K3
 *  the sheet), so the mutant harness can name the assertion that convicts a mutant. */
final class ClaimNoticeCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) {
            System.out.println("  ok    " + name);
            return;
        }
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\n", "\\n") + "\"";
    }

    private static void count(String reply, int want) {
        int got;
        try {
            got = ClaimNoticeCopy.count(reply);
        } catch (RuntimeException e) {
            check("K1 count(" + show(reply) + ") threw " + e, false);
            return;
        }
        check("K1 count(" + show(reply) + ") = " + want + " (got " + got + ")", got == want);
    }

    private static boolean button(Confirm c, int i, String label, Style style) {
        return c.buttons.size() > i && label.equals(c.buttons.get(i).label) && c.buttons.get(i).style == style;
    }

    private static boolean okOrCancel(Confirm c) {
        for (Button b : c.buttons) {
            String l = b.label == null ? "" : b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) return true;
        }
        return false;
    }

    private static void sheet(int n, String title) {
        Confirm c = ClaimNoticeCopy.sheet(n);
        String k = "K3 sheet(" + n + ") ";
        check(k + "title", title.equals(c.title));
        check(k + "tone", c.tone == Tone.ROUTINE);
        check(k + "context", ClaimNoticeCopy.CONTEXT.equals(c.context));
        check(k + "line", c.lines.size() == 1 && ClaimNoticeCopy.LINE.equals(c.lines.get(0).text)
                && c.lines.get(0).linkKey == null);
        check(k + "buttons", c.buttons.size() == 2 && button(c, 0, ClaimNoticeCopy.ADD, Style.GREEN_FILLED)
                && button(c, 1, PopupSheet.GOT_IT, Style.OUTLINED));
        check(k + "no OK or Cancel", !okOrCancel(c));
        check(k + "rules " + PopupSheet.violations(c), PopupSheet.violations(c).isEmpty());
    }

    public static void main(String[] args) {
        count("NOTICE 1", 1);
        count(" NOTICE 3\n", 3);
        count("NOTICE 12", 12);
        for (String r : new String[] { "NONE", "ERR", "ERR-ARGS", "", null, "NOTICE 0", "NOTICE -1", "NOTICE +1",
                "NOTICE x", "NOTICE", "NOTICE ", "NOTICES 2", "NOTICE 2 3", "NOTICE 99999999999", "ERR-VERB" }) {
            count(r, 0);
        }

        check("K2 ackRequest(2)", "CLAIM-NOTICE-SHOWN\n2\n".equals(ClaimNoticeCopy.ackRequest(2)));
        check("K2 ackRequest(1)", "CLAIM-NOTICE-SHOWN\n1\n".equals(ClaimNoticeCopy.ackRequest(1)));
        check("K2 GET_REQUEST", "GET-CLAIM-NOTICE\n".equals(ClaimNoticeCopy.GET_REQUEST));

        sheet(1, ClaimNoticeCopy.TITLE_ONE);
        sheet(2, ClaimNoticeCopy.TITLE_MANY);
        sheet(5, ClaimNoticeCopy.TITLE_MANY);
        check("K3 TITLE_ONE differs from TITLE_MANY", !ClaimNoticeCopy.TITLE_ONE.equals(ClaimNoticeCopy.TITLE_MANY));
        check("K3 ADD is the label on screen", "Start or extend a plan".equals(ClaimNoticeCopy.ADD));
        check("K3 the second button is Got it", "Got it".equals(PopupSheet.GOT_IT));

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: K1-K3");
    }
}
