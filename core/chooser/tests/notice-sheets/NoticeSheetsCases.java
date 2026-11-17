package com.nowhere.chooser;

import java.util.List;

/** NWP-20261206-08: the three notice sheets of NoticeSheets, run by test-notice-sheets-java.sh. The titles and the
 *  "Got it" label are literals here, not the constants, so an emptied or changed constant fails a case. */
public final class NoticeSheetsCases {
    private static boolean failed;

    private static void check(String name, boolean ok) {
        if (!ok) {
            System.out.println("  FAIL  " + name);
            failed = true;
        }
    }

    private static void sheet(String f, PopupSheet.Confirm c, String title, String msg) {
        check(f + " not null", c != null);
        if (c == null) return;
        check(f + " tone", c.tone == PopupSheet.Tone.WARNING);
        check(f + " title", title.equals(c.title));
        check(f + " context", msg.equals(c.context));
        check(f + " no lines", c.lines.isEmpty());
        check(f + " one Got it", c.buttons.size() == 1 && c.buttons.get(0) != null
                && "Got it".equals(c.buttons.get(0).label) && c.buttons.get(0).style == PopupSheet.Style.GREEN_FILLED);
        List<String> v = PopupSheet.violations(c);
        if (!v.isEmpty()) System.out.println("  violations of " + f + ": " + v);
        check(f + " violations", v.isEmpty());
    }

    public static void main(String[] args) {
        sheet("notDone", NoticeSheets.notDone("Your phone hasn't restarted."),
                "That didn't go through", "Your phone hasn't restarted.");
        sheet("saveExists", NoticeSheets.saveExists("That passphrase already opens a saved profile."),
                "Not saved yet", "That passphrase already opens a saved profile.");
        sheet("saveSplit", NoticeSheets.saveSplit("Nothing was saved."),
                "Save didn't finish", "Nothing was saved.");
        if (failed) System.exit(1);
        System.out.println("  ok: notDone, saveExists, saveSplit");
    }
}
