package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-10: the sign-out group's sheets (SignOutSheets) and OtaUpdate's split text. Each failure names its case. */
final class SignOutSheetsCases {
    private static int failed;

    private static void check(String name, boolean ok) {
        if (ok) return;
        failed++;
        System.out.println("  FAIL  " + name);
    }

    private static final String SAVED = "You'll be signed out first, and this session is saved as usual.";
    private static final String LOCAL =
            "You'll be signed out first. This session isn't saved to your store, so it's erased when you sign out.";
    private static final List<String> INSTALL_LINES = Arrays.asList("Then the update downloads and installs.",
            "It takes a while, and the phone restarts when it's done.");

    private static List<String> texts(Confirm c) {
        List<String> out = new ArrayList<>();
        for (Line l : c.lines) out.add(l == null ? null : l.text);
        return out;
    }

    private static boolean noLinks(Confirm c) {
        for (Line l : c.lines) if (l == null || l.linkKey != null) return false;
        return true;
    }

    private static String buttons(Confirm c) {
        StringBuilder sb = new StringBuilder();
        for (Button b : c.buttons) sb.append('[').append(b.label).append(' ').append(b.style).append(']');
        return sb.toString();
    }

    private static boolean noAmpersand(Confirm c) {
        StringBuilder sb = new StringBuilder().append(c.title).append(c.context);
        for (Line l : c.lines) sb.append(l.text);
        for (Button b : c.buttons) sb.append(b.label);
        return sb.indexOf("&") < 0;
    }

    public static void main(String[] args) {
        for (boolean local : new boolean[] { false, true }) {
            Confirm m = SignOutSheets.install(local);
            String v = "install(" + local + ")";
            check(v + " tone", m.tone == Tone.ROUTINE);
            check(v + " title", "Sign out and install?".equals(m.title));
            check(v + " context", (local ? LOCAL : SAVED).equals(m.context));
            check(v + " lines", INSTALL_LINES.equals(texts(m)) && noLinks(m));
            check(v + " joins to installConfirm",
                    (m.context + " " + String.join(" ", texts(m))).equals(OtaUpdate.installConfirm(local)));
            check(v + " buttons", "[Sign out and install GREEN_FILLED][Not now OUTLINED]".equals(buttons(m)));
            check(v + " no ampersand", noAmpersand(m));
            check(v + " no violations", PopupSheet.violations(m).isEmpty());
        }
        // Today's text, as a literal: the split did not change one byte of installConfirm.
        check("installConfirm(false) literal", ("You'll be signed out first, and this session is saved as usual. Then the"
                + " update downloads and installs. It takes a while, and the phone restarts when it's done.")
                .equals(OtaUpdate.installConfirm(false)));
        check("installConfirm(true) literal", ("You'll be signed out first. This session isn't saved to your store, so"
                + " it's erased when you sign out. Then the update downloads and installs. It takes a while, and the phone"
                + " restarts when it's done.").equals(OtaUpdate.installConfirm(true)));

        Confirm one = SignOutSheets.release("App A", false);
        check("release one title", "Release App A?".equals(one.title));
        check("release one context",
                "Your other device will be able to open it. Nothing is deleted and App A keeps working here.".equals(one.context));
        check("release one lines", Arrays.asList(
                "If your other device then opens it, it becomes held THERE — and you won't be able to open it here until"
                        + " that device lets go.",
                "Either way it takes a few minutes to reach your other device.").equals(texts(one)) && noLinks(one));

        Confirm all = SignOutSheets.release("3 apps", true);
        check("release all title", "Release 3 apps?".equals(all.title));
        check("release all context",
                "Your other device will be able to open them. Nothing is deleted and 3 apps keeps working here.".equals(all.context));
        check("release all lines", Arrays.asList(
                "If your other device then opens them, them becomes held THERE — and you won't be able to open them here"
                        + " until that device lets go.",
                "Either way it takes a few minutes to reach your other device.").equals(texts(all)) && noLinks(all));

        for (Confirm m : new Confirm[] { one, all }) {
            String v = m == one ? "release one" : "release all";
            check(v + " tone", m.tone == Tone.ROUTINE);
            check(v + " buttons", "[Release GREEN_FILLED][Keep holding OUTLINED]".equals(buttons(m)));
            check(v + " no violations", PopupSheet.violations(m).isEmpty());
        }

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("ok: SignOutSheets cases");
    }
}
