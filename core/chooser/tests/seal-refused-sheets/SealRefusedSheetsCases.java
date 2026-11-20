package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-11: the sign-out refusal pair's models. Each failure line names its assertion, then its case. The
 *  expected words are today's dialog text, copied here as literals; the several-apps lines are written out whole, so
 *  "these apps are switched off ... their data" and "These apps stay ... turn them back on" are pinned word for word. */
final class SealRefusedSheetsCases {
    private static int failed;

    private static void check(String name, String kase, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name + " (" + kase + ")");
    }

    private static List<String> texts(Confirm c) {
        List<String> out = new ArrayList<>();
        for (Line l : c.lines) out.add(l == null ? null : l.text + (l.linkKey == null ? "" : " ->" + l.linkKey));
        return out;
    }

    private static List<String> buttons(Confirm c) {
        List<String> out = new ArrayList<>();
        for (Button b : c.buttons) out.add(b.label + " " + b.style);
        return out;
    }

    private static void refused(String kase, String who, String one, boolean many, boolean restSaved) {
        Confirm c = SealRefusedSheets.refused(who, one, many, restSaved);
        check("refused tone", kase, c.tone == Tone.WARNING);
        check("refused title", kase, c.title.equals(who + (many ? " are blocking sign-out" : " is blocking sign-out")));
        check("refused context", kase, c.context.equals("nowhere couldn't read some of " + who
                + "'s files, so it can't save this session safely and has not signed you out."));
        check("refused lines", kase, texts(c).equals(Arrays.asList(
                restSaved ? "Everything else in your session IS saved, and your stored copy is intact."
                          : "Not everything else in your session could be saved either, but your stored copy is intact.",
                many ? "You can sign out without these apps. If you do, these apps are switched off for this profile"
                        + " and their data from this session is NOT kept."
                     : "You can sign out without " + one + ". If you do, " + one
                        + " is switched off for this profile and its data from this session is NOT kept.")));
        check("refused buttons", kase, buttons(c).equals(Arrays.asList(
                "Stay signed in " + Style.GREEN_FILLED,
                "Sign out without " + one + " " + Style.RED_OUTLINED,
                "Report this " + Style.OUTLINED)));
        check("refused violations", kase, PopupSheet.violations(c).isEmpty());
    }

    private static void drop(String kase, String who, String one, boolean many, boolean restSaved) {
        Confirm c = SealRefusedSheets.drop(who, one, many, restSaved);
        check("drop tone", kase, c.tone == Tone.DESTRUCTIVE);
        check("drop title", kase, c.title.equals("Sign out without " + one + "?"));
        check("drop context", kase,
                c.context.equals(who + "'s data from this session will NOT be saved, and cannot be recovered."));
        List<String> lines = new ArrayList<>();
        lines.add(many
                ? "These apps stay switched off for this profile until you turn them back on in Your apps, "
                        + "so later sessions will not carry them either."
                : one + " stays switched off for this profile until you turn it back on in Your apps, "
                        + "so later sessions will not carry it either.");
        if (restSaved) lines.add("Everything else in this session is saved either way.");
        check("drop lines", kase, texts(c).equals(lines));
        check("drop buttons", kase, buttons(c).equals(Arrays.asList(
                "Drop " + one + " and sign out " + Style.RED_FILLED,
                "Keep me signed in " + Style.OUTLINED)));
        check("drop violations", kase, PopupSheet.violations(c).isEmpty());
    }

    public static void main(String[] args) {
        String many = "App A, App B and App C";
        refused("refused one restSaved", "App A", "App A", false, true);
        refused("refused one not saved", "App A", "App A", false, false);
        refused("refused many restSaved", many, "these apps", true, true);
        refused("refused many not saved", many, "these apps", true, false);
        drop("drop one restSaved", "App A", "App A", false, true);
        drop("drop one not saved", "App A", "App A", false, false);
        drop("drop many restSaved", many, "these apps", true, true);
        drop("drop many not saved", many, "these apps", true, false);
        if (failed > 0) {
            System.out.println(failed + " check(s) failed");
            System.exit(1);
        }
        System.out.println("ok: 8 cases (refused x4, drop x4)");
    }
}
