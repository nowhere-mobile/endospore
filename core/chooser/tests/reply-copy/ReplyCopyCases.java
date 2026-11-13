
/** Cases for ReplyCopy (NWP-20261020-11). Run by test-reply-copy-java.sh. Exits 1 on the first set of failures. */
public class ReplyCopyCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("--- FAIL " + what); }
    }

    static final String KEEPS_NONE = "This profile keeps no apps, so there are none to save.";
    static final String APPS_UNKNOWN = "Apps in your store: unknown right now.";

    static final String LEFT_APPS = "Your last save didn't store your apps' latest changes — your stored copy has them from an earlier save.";

    static void apps(boolean known, int count, boolean measured, java.util.List<String> labels, String text, boolean warn) {
        apps(known, count, measured, labels, false, text, warn);
    }

    static void apps(boolean known, int count, boolean measured, java.util.List<String> labels, boolean left, String text,
                     boolean warn) {
        ReplyCopy.AppsLine l = ReplyCopy.storedAppsLine(known, count, measured, labels, left);
        String c = "storedAppsLine(" + known + ", " + count + ", " + measured + ", " + labels + ", " + left + ")";
        check(l.text.equals(text), c + " text '" + l.text + "' want '" + text + "'");
        check(l.warn == warn, c + " warn " + l.warn + " want " + warn);
    }

    static void strength(String reply, String state, String text) {
        ReplyCopy.Strength s = ReplyCopy.strength(reply);
        check(s.state.name().equals(state), "strength(" + show(reply) + ") state " + s.state + " want " + state);
        if (text != null) check(s.text.equals(text), "strength(" + show(reply) + ") text '" + s.text + "' want '" + text + "'");
    }

    static void unknown(String reply) {
        ReplyCopy.Strength s = ReplyCopy.strength(reply);
        check(s.state == ReplyCopy.State.UNKNOWN, "strength(" + show(reply) + ") is UNKNOWN, got " + s.state);
        String t = s.text.toLowerCase();
        check(!t.contains("weak") && !t.contains("strong"), "UNKNOWN text names no verdict: '" + s.text + "'");
        check(!s.text.isEmpty(), "UNKNOWN text is not empty");
    }

    static void row(String reply, String every) {
        String r = ReplyCopy.backupRow(reply);
        if (every != null) {
            check(r.equals("Your data is backed up " + every + "  ·  tap to change"), "backupRow(" + show(reply) + ") = '" + r + "'");
        } else {
            check(!r.contains("every") && !r.contains("backed up"), "backupRow(" + show(reply) + ") names no cadence: '" + r + "'");
            check(r.contains("tap to change"), "backupRow(" + show(reply) + ") still offers the picker");
        }
    }

    static String show(String s) { return s == null ? "null" : "\"" + s.replace("\n", "\\n") + "\""; }

    public static void main(String[] a) {
        strength("OK", "STRONG", "strong");
        strength("OK\n", "STRONG", "strong");
        strength("WEAK too short", "WEAK", "too short");
        strength("WEAK too short\n", "WEAK", "too short");
        strength("WEAK", "WEAK", "too weak");
        strength("WEAK\n", "WEAK", "too weak");
        unknown(null);
        unknown("");
        unknown("ERR x");
        unknown("BUSY");
        unknown("OKAY then");
        unknown("\n");

        row("120", "every 2 minutes");
        row("120\n", "every 2 minutes");
        row("60", "every minute");
        row("30", "every 30 seconds");
        row("600", "every 10 minutes");
        row("", null);
        row("ERR", null);
        row("0", null);
        row("-5", null);
        row("abc", null);
        row(null, null);

        check(ReplyCopy.cadenceSaved("OK"), "cadenceSaved(OK)");
        check(ReplyCopy.cadenceSaved("OK\n"), "cadenceSaved(OK\\n)");
        check(!ReplyCopy.cadenceSaved("ERR"), "!cadenceSaved(ERR)");
        check(!ReplyCopy.cadenceSaved(""), "!cadenceSaved(empty)");
        check(!ReplyCopy.cadenceSaved(null), "!cadenceSaved(null)");
        check(ReplyCopy.settingSaved("OK"), "settingSaved(OK)");
        check(ReplyCopy.settingSaved("OK\nmore"), "settingSaved(OK\\nmore)");
        check(ReplyCopy.settingSaved(" OK"), "settingSaved( OK): the first line is trimmed");
        check(!ReplyCopy.settingSaved("ERR"), "!settingSaved(ERR)");
        check(!ReplyCopy.settingSaved(""), "!settingSaved(empty)");
        check(!ReplyCopy.settingSaved(null), "!settingSaved(null)");
        check(ReplyCopy.flagOf("1") == Boolean.TRUE, "flagOf(1) is TRUE");
        check(ReplyCopy.flagOf("0") == Boolean.FALSE, "flagOf(0) is FALSE");
        check(ReplyCopy.flagOf(" 1 ") == Boolean.TRUE, "flagOf( 1 ) is TRUE");
        check(ReplyCopy.flagOf("") == null, "flagOf(empty) is null");
        check(ReplyCopy.flagOf(null) == null, "flagOf(null) is null");
        check(ReplyCopy.flagOf("2") == null, "flagOf(2) is null");
        check(ReplyCopy.flagOf("ERR") == null, "flagOf(ERR) is null");

        final String running = "A save is already running, and this tap joined it.";
        final String signin = "Your sign-in or unlock is still finishing, so the save wasn't started. Try again in a moment.";
        final String userop = "The phone is busy with something you asked for, such as setting up an app, so the save wasn't started. Try again in a moment.";
        final String generic = "The phone is busy, so the save wasn't started. Try again in a moment.";
        check(running.equals(ReplyCopy.backupBusy("BUSY seal-in-flight")), "backupBusy(seal-in-flight)");
        check(running.equals(ReplyCopy.backupBusy("BUSY seal-run:periodic")), "backupBusy(seal-run:periodic)");
        check(running.equals(ReplyCopy.backupBusy("BUSY seal-run:logoff")), "backupBusy(seal-run:logoff)");
        check(running.equals(ReplyCopy.backupBusy("BUSY seal-run:")), "backupBusy(seal-run: any kind)");
        check(signin.equals(ReplyCopy.backupBusy("BUSY login")), "backupBusy(login)");
        check(userop.equals(ReplyCopy.backupBusy("BUSY user-op-waiting")), "backupBusy(user-op-waiting)");
        check(signin.equals(ReplyCopy.backupBusy("BUSY  login ")), "backupBusy(blanks trimmed)");
        check(generic.equals(ReplyCopy.backupBusy("BUSY")), "backupBusy(bare BUSY)");
        check(generic.equals(ReplyCopy.backupBusy("BUSYlogin")), "backupBusy(BUSYlogin) is not a token");
        check(generic.equals(ReplyCopy.backupBusy("BUSY something-new")), "backupBusy(unknown token)");
        check(signin.equals(ReplyCopy.backupBusy("BUSY login\nBUSY seal-in-flight")), "backupBusy(multi-line: first line only)");
        check(generic.equals(ReplyCopy.backupBusy("")), "backupBusy(empty)");
        check(generic.equals(ReplyCopy.backupBusy(null)), "backupBusy(null)");
        for (String b : new String[] {"BUSY seal-in-flight", "BUSY seal-run:periodic", "BUSY login", "BUSY user-op-waiting", "BUSY", "", null})
            check(!ReplyCopy.backupBusy(b).contains("Try again once it finishes"), "backupBusy(" + b + ") has no retry-once-it-finishes text");
        // NWP-20261026-18: the "Your data" apps line.
        apps(true, 0, true, java.util.List.of(), KEEPS_NONE, false);
        apps(true, 0, false, null, KEEPS_NONE, false);
        apps(false, 0, true, null, APPS_UNKNOWN, false);
        apps(false, 0, true, java.util.List.of(), APPS_UNKNOWN, false);
        apps(false, 0, false, null, APPS_UNKNOWN, false);
        apps(true, 3, false, null, APPS_UNKNOWN, false);
        apps(true, 2, true, null, APPS_UNKNOWN, false);
        apps(true, 2, true, java.util.List.of(), "All your kept apps are saved.", false);
        apps(true, 4, true, java.util.List.of("Maps"), "Not saved yet: Maps — back up before powering off.", true);
        apps(true, 4, true, java.util.List.of("Maps", "Signal", "Notes"),
            "Not saved yet: Maps, Signal, Notes — back up before powering off.", true);
        apps(true, 5, true, java.util.List.of("Maps", "Signal", "Notes", "Bank", "Mail"),
            "Not saved yet: Maps, Signal, Notes +2 more — back up before powering off.", true);
        // NWP-20261113-11 (case 1): the last save's parts name apps=, so the store holds the kept apps from an earlier
        // save: never "All your kept apps are saved.", and not the warning. The other arms do not change.
        ReplyCopy.AppsLine left = ReplyCopy.storedAppsLine(true, 3, true, java.util.List.of(), true);
        check(!left.text.equals("All your kept apps are saved."), "storedAppsLine(lastSaveLeftApps) still says all saved");
        check(left.text.contains("earlier save"), "storedAppsLine(lastSaveLeftApps) names no earlier save: '" + left.text + "'");
        apps(true, 3, true, java.util.List.of(), true, LEFT_APPS, false);
        apps(true, 0, true, java.util.List.of(), true, KEEPS_NONE, false);
        apps(true, 3, false, null, true, APPS_UNKNOWN, false);
        apps(true, 4, true, java.util.List.of("Maps"), true, "Not saved yet: Maps — back up before powering off.", true);

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
