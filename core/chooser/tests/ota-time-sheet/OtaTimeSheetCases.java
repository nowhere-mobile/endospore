package com.nowhere.chooser;

import java.util.List;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-05: the install-time sheet's model, its reply parse and its HH:MM format. Each failure line names its
 *  case. */
final class OtaTimeSheetCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("--- FAIL " + name);
    }

    private static boolean button(Button b, String label, Style style) {
        return b != null && label.equals(b.label) && b.style == style;
    }

    private static void current(String reply, int h, int m) {
        String name = "C4 current(" + (reply == null ? "null" : "\"" + reply + "\"") + ") is {" + h + ", " + m + "}";
        try {
            int[] hm = OtaTimeSheet.current(reply);
            check(name, hm != null && hm.length == 2 && hm[0] == h && hm[1] == m);
        } catch (RuntimeException e) {
            check(name + " (threw " + e.getClass().getSimpleName() + ")", false);
        }
    }

    public static void main(String[] args) {
        Confirm c = OtaTimeSheet.model();

        List<String> v = PopupSheet.violations(c);
        check("C1 model() breaks no popup rule " + v, v.isEmpty());
        check("C1 model() is ROUTINE", c.tone == Tone.ROUTINE);

        check("C2 model() has three buttons", c.buttons.size() == 3);
        check("C2 the indexes are 0, 1, 2", OtaTimeSheet.SET_INDEX == 0 && OtaTimeSheet.ANY_TIME_INDEX == 1
                && OtaTimeSheet.NOT_NOW_INDEX == 2);
        if (c.buttons.size() == 3) {
            check("C2 Set is the green button at SET_INDEX",
                    button(c.buttons.get(OtaTimeSheet.SET_INDEX), "Set", Style.GREEN_FILLED));
            check("C2 Any time is outlined at ANY_TIME_INDEX",
                    button(c.buttons.get(OtaTimeSheet.ANY_TIME_INDEX), "Any time", Style.OUTLINED));
            check("C2 Not now is outlined at NOT_NOW_INDEX",
                    button(c.buttons.get(OtaTimeSheet.NOT_NOW_INDEX), PopupSheet.NOT_NOW, Style.OUTLINED));
        }
        check("C2 SET and ANY_TIME are the decided words", "Set".equals(OtaTimeSheet.SET)
                && "Any time".equals(OtaTimeSheet.ANY_TIME) && "Not now".equals(PopupSheet.NOT_NOW));

        check("C3 TITLE is today's title", "Install time (while charging)".equals(OtaTimeSheet.TITLE));
        check("C3 model() shows TITLE", OtaTimeSheet.TITLE.equals(c.title));
        check("C3 model() shows CONTEXT_DRAFT", OtaTimeSheet.CONTEXT_DRAFT.equals(c.context));
        check("C3 model() has no lines", c.lines.isEmpty());

        current("03:00", 3, 0);
        current("23:59", 23, 59);
        current("07:05", 7, 5);
        current(null, 3, 0);
        current("", 3, 0);
        current("ERR", 3, 0);
        current("24:00", 3, 0);
        current("12:60", 3, 0);
        current("ab:cd", 3, 0);
        current("7:05 ", 3, 0);

        check("C5 hhmm(7, 5) is 07:05", "07:05".equals(OtaTimeSheet.hhmm(7, 5)));
        check("C5 hhmm(0, 0) is 00:00", "00:00".equals(OtaTimeSheet.hhmm(0, 0)));
        check("C5 hhmm(23, 59) is 23:59", "23:59".equals(OtaTimeSheet.hhmm(23, 59)));

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: cases C1-C5");
    }
}
