package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import com.nowhere.chooser.PopupSheet.Button;
import com.nowhere.chooser.PopupSheet.Confirm;
import com.nowhere.chooser.PopupSheet.Line;
import com.nowhere.chooser.PopupSheet.Style;
import com.nowhere.chooser.PopupSheet.Tone;

/** NWP-20261206-16: Profile > Security's three confirmations (remove a security key, confirm it with a key, remove the
 *  session PIN) as sheet models. Each failure line names its case. The expected words are literals copied from
 *  ProfileActivity.java before this slice, never read back from KeyPinSheets. */
final class KeyPinSheetsCases {
    private static int failed;
    private static int checks;

    private static void check(String name, boolean ok) {
        checks++;
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

    private static boolean okOrCancel(Confirm c) {
        for (Button b : c.buttons) {
            if (b == null || b.label == null) continue;
            String l = b.label.trim().toLowerCase(Locale.ROOT);
            if (l.equals("ok") || l.equals("okay") || l.equals("cancel")) return true;
        }
        return false;
    }

    private static boolean plainLines(Confirm c) {
        for (Line l : c.lines) if (l == null || l.text == null || l.linkKey != null) return false;
        return true;
    }

    private static String join(Confirm c) {
        List<String> parts = new ArrayList<>();
        parts.add(c.context);
        for (Line l : c.lines) parts.add(l == null ? "" : l.text);
        return String.join(" ", parts);
    }

    static final String LABEL = "USB-C key 1";
    /** confirmRemoveKey's message for the last key, before NWP-20261206-16. */
    static final String OLD_LAST = "This is your only security key. Removing it means signing in needs just your "
            + "passphrase again — no key. You can add one back any time. Your recovery code is unchanged.";
    /** ... and for one of several keys. */
    static final String OLD_OTHER = "Sign-in will still need one of your other keys. Your recovery code is unchanged.";
    /** confirmRemoveKey's tapMsg, last key and one of several. */
    static final String OLD_TAP_LAST = "Touch this key to confirm.";
    static final String OLD_TAP_OTHER = "Touch one of your other keys to confirm. The key you're removing doesn't "
            + "count.";
    /** showSessionPin's Remove PIN message. */
    static final String OLD_PIN = "Sign-in will have no device credential. That also switches off the safeguard "
            + "that cancels a pending cold lock when you pick the phone up — with no credential, "
            + "unlocking is only a swipe, so it cannot count as proof it’s you. Expect the phone "
            + "to cold-lock in your hand sometimes. You can set a PIN again any time.";

    /** The checks every warning here shares: Keep it green first and alone, Remove red-outlined second. */
    private static void warning(String s, Confirm c, String title, String context, String old) {
        check(s + " tone", c.tone == Tone.WARNING);
        check(s + " keep green first",
                button(c, 0, "Keep it", Style.GREEN_FILLED) && count(c, Style.GREEN_FILLED) == 1);
        check(s + " remove red-outlined", c.buttons.size() == 2 && button(c, 1, "Remove", Style.RED_OUTLINED));
        check(s + " title", title.equals(c.title));
        check(s + " context", context.equals(c.context));
        check(s + " join", old.equals(join(c)) && plainLines(c));
        check(s + " no OK or Cancel", !okOrCancel(c));
        check(s + " rules", PopupSheet.violations(c).isEmpty());
    }

    private static void routine(String s, Confirm c, String context) {
        check(s + " tone", c.tone == Tone.ROUTINE);
        check(s + " title", "Confirm with a key".equals(c.title));
        check(s + " usb green", button(c, 0, "USB-C key", Style.GREEN_FILLED) && count(c, Style.GREEN_FILLED) == 1);
        check(s + " not now outlined", c.buttons.size() == 2 && button(c, 1, "Not now", Style.OUTLINED));
        check(s + " context", context.equals(c.context));
        check(s + " no lines", c.lines.isEmpty());
        check(s + " no OK or Cancel", !okOrCancel(c));
        check(s + " rules", PopupSheet.violations(c).isEmpty());
    }

    public static void main(String[] args) {
        Confirm last = KeyPinSheets.removeKey(LABEL, true);
        warning("removeKey last", last, "Remove USB-C key 1?", "This is your only security key.", OLD_LAST);
        check("removeKey last title holds the label", last.title != null && last.title.contains(LABEL));

        Confirm other = KeyPinSheets.removeKey(LABEL, false);
        warning("removeKey other", other, "Remove USB-C key 1?", "Sign-in will still need one of your other keys.",
                OLD_OTHER);
        check("removeKey other title holds the label", other.title != null && other.title.contains(LABEL));

        routine("confirmWithKey last", KeyPinSheets.confirmWithKey(true), OLD_TAP_LAST);
        routine("confirmWithKey other", KeyPinSheets.confirmWithKey(false), OLD_TAP_OTHER);

        warning("removePin", KeyPinSheets.removePin(), "Remove PIN?", "Sign-in will have no device credential.",
                OLD_PIN);

        if (failed > 0) {
            System.out.println("  " + failed + " of " + checks + " cases failed");
            System.exit(1);
        }
        System.out.println("ok: " + checks + " cases");
    }
}
