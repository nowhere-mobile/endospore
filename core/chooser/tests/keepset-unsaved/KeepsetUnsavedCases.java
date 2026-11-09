package com.nowhere.chooser;

/** NWP-20261128-15: the Storage chip's toast words, from StorageDropCopy.line. Exit 1 on any failed case. */
public final class KeepsetUnsavedCases {
    private static int fails = 0;

    private static void eq(String name, String want, String got) {
        if (want.equals(got)) {
            System.out.println("  ok    " + name);
        } else {
            fails++;
            System.out.println("  FAIL  " + name + "\n        want: " + want + "\n        got:  " + got);
        }
    }

    public static void main(String[] a) {
        eq("saved: the rewrite landed, the toast says it stopped",
                "Stopped keeping Maps. It's still here until you log off.",
                StorageDropCopy.line(true, true, "OK", false, null, "Maps"));
        String unsaved = StorageDropCopy.line(true, false, "OK", false, null, "Maps");
        eq("not saved: the rewrite did not land, the toast says NOT_SAVED", SettingsSaveCopy.NOT_SAVED, unsaved);
        if (unsaved != null && unsaved.contains("Stopped keeping")) {
            fails++;
            System.out.println("  FAIL  not saved: the toast still claims \"Stopped keeping\"");
        }
        eq("NONE keeps its words", "No active session.",
                StorageDropCopy.line(false, false, "NONE", false, null, "Maps"));
        eq("BUSY keeps its words",
                "The phone is busy saving or downloading. Nothing changed — tap it again in a moment.",
                StorageDropCopy.line(false, false, "BUSY", false, null, "Maps"));
        eq("a failed reply keeps its words",
                "Nothing changed — the phone was busy and didn't answer in time. Tap it again in a moment.",
                StorageDropCopy.line(false, false, "", true, "the phone was busy and didn't answer in time", "Maps"));
        eq("the generic refusal keeps its words", "Couldn't prepare that change — try again.",
                StorageDropCopy.line(false, false, "ERR x", false, null, "Maps"));
        eq("BUSY is checked before a failed reply, as before",
                "The phone is busy saving or downloading. Nothing changed — tap it again in a moment.",
                StorageDropCopy.line(false, false, "BUSY", true, "r", "Maps"));
        System.out.println(fails == 0 ? "  all cases passed" : "  " + fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
