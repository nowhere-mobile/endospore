package com.nowhere.chooser;

import java.util.List;
import java.util.Locale;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-18: the Turn Google Play off and Sign out of Google sheets. Each failure line names its case. */
final class GoogleSheetsCases {
    private static int failed;

    /** The Off dialog's message before NWP-20261206-18, written out. */
    private static final String OFF_MESSAGE_BEFORE = "Turning Google Play off removes Play Store from this profile at the"
            + " next save. Your Google account is signed out here, and apps that sign in with it will ask again.";
    /** The decided sign-out words (docs/product-decisions.md 2026-10-21, dn-1106 #2), written out. */
    private static final String SIGN_OUT_DECIDED = "Signing out here removes this account from your profile at the next"
            + " save. Signing out in Android Settings does not stick.";

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static boolean is(Button b, String label, Style style) {
        return b != null && label.equals(b.label) && b.style == style;
    }

    private static boolean noOkOrCancel(Confirm c) {
        for (Button b : c.buttons) {
            String l = b.label == null ? "" : b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) return false;
        }
        return true;
    }

    public static void main(String[] args) {
        Confirm off = GoogleSheets.playOff();
        List<Button> ob = off.buttons;
        check("C1 playOff is a WARNING", off.tone == Tone.WARNING);
        check("C1 playOff's title is \"Turn Google Play off?\"", "Turn Google Play off?".equals(off.title));
        check("C1 playOff has two buttons", ob.size() == 2);
        check("C1 playOff's first button is green and is not \"Turn ...\"", ob.size() == 2
                && ob.get(0).style == Style.GREEN_FILLED && ob.get(0).label != null && !ob.get(0).label.startsWith("Turn"));
        check("C1 playOff's first button is \"Keep Google Play\"", ob.size() == 2 && "Keep Google Play".equals(ob.get(0).label));
        check("C1 playOff's second button is \"Turn off\" red-outlined", ob.size() == 2 && is(ob.get(1), "Turn off", Style.RED_OUTLINED));
        check("C2 playOff has one line, no link", off.lines.size() == 1 && off.lines.get(0).linkKey == null);
        check("C2 playOff's context and line are the Off message before the sheet", off.lines.size() == 1
                && OFF_MESSAGE_BEFORE.equals(off.context + " " + off.lines.get(0).text));

        Confirm so = GoogleSheets.signOut();
        List<Button> sb = so.buttons;
        check("C3 signOut is ROUTINE", so.tone == Tone.ROUTINE);
        check("C3 signOut's title is \"Sign out of Google\"", "Sign out of Google".equals(so.title));
        check("C3 signOut's context is the decided sentence pair", SIGN_OUT_DECIDED.equals(so.context));
        check("C3 signOut has no lines", so.lines.isEmpty());
        check("C3 signOut has \"Sign out\" green, then \"Not now\" outlined", sb.size() == 2
                && is(sb.get(0), "Sign out", Style.GREEN_FILLED) && is(sb.get(1), "Not now", Style.OUTLINED));

        check("C4 playOff has no OK or Cancel button", noOkOrCancel(off));
        check("C4 signOut has no OK or Cancel button", noOkOrCancel(so));
        check("C5 playOff breaks no popup rule " + PopupSheet.violations(off), PopupSheet.violations(off).isEmpty());
        check("C5 signOut breaks no popup rule " + PopupSheet.violations(so), PopupSheet.violations(so).isEmpty());

        System.out.println(failed == 0 ? "  cases passed" : "  cases FAILED (" + failed + ")");
        System.exit(failed == 0 ? 0 : 1);
    }
}
