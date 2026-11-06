// NWP-20261106-15: the erase picker's choices and the prefs text they write, compiled beside Lifted (prefsText,
// prefsUpdated, prefsUpdatedWipe lifted from ProfileActivity), WipeChoice, WipeOnSave and MobileData.
// Run by core/vendor-common/bin/test-wipe-choice-java.sh.
public class WipeChoiceCases {
    static int run, bad;

    static void check(String name, boolean ok, String got) {
        run++;
        if (!ok) { bad++; System.out.println("  FAIL  " + name + (got == null ? "" : " -- got: " + got.replace("\n", "\\n"))); }
        else System.out.println("  ok    " + name);
    }

    static void eq(String name, String want, String got) { check(name, want.equals(got), got); }

    static final String OLD = "tz=Europe/Paris\nlocale=fr-FR\nidle=15\nwipe=12\nholdlock=0\nvpn=org.example.vpn\nvpnlockdown=1\n"
            + "netloc=1\ngeocoder=1\nmobiledata=1\ndataroaming=0\n";

    static void body() {
        check("A1 three arrays of six", WipeChoice.LABELS.length == 6 && WipeChoice.HOURS.length == 6
                && WipeChoice.SAVED.length == 6, null);
        check("A2 labels in order", java.util.Arrays.equals(WipeChoice.LABELS, new String[] {
                "Right away, once saved", "After 1 hour", "After 6 hours", "After 12 hours", "After 1 day",
                "Only on power-off" }), java.util.Arrays.toString(WipeChoice.LABELS));
        check("A3 hours", java.util.Arrays.equals(WipeChoice.HOURS, new int[] { 1, 1, 6, 12, 24, 0 }), null);
        check("A4 saved", java.util.Arrays.equals(WipeChoice.SAVED,
                new boolean[] { true, false, false, false, false, false }), null);

        check("S1 (1,1) -> 0", WipeChoice.selected("1", "1") == 0, null);
        check("S2 (1,'') -> 1", WipeChoice.selected("1", "") == 1, null);
        check("S3 (6,'') -> 2", WipeChoice.selected("6", "") == 2, null);
        check("S4 (0,'') -> 5", WipeChoice.selected("0", "") == 5, null);
        check("S5 ('','') -> 3", WipeChoice.selected("", "") == 3, null);
        check("S6 (x,'') -> 3", WipeChoice.selected("x", "") == 3, null);
        check("S7 (7,'') -> 3", WipeChoice.selected("7", "") == 3, null);
        check("S8 (null,null) -> 3", WipeChoice.selected(null, null) == 3, null);
        check("S9 (24,'') -> 4", WipeChoice.selected("24", "") == 4, null);
        check("S10 ( 12 ,'') -> 3", WipeChoice.selected(" 12 ", "") == 3, null);
        check("S11 wipesaved other than 1 is ignored", WipeChoice.selected("12", "0") == 3, null);
        check("S12 wipesaved=1 wins over any wipe", WipeChoice.selected("0", "1") == 0, null);

        boolean v = true;
        String[] w = { "1", "1", "6", "12", "24", "0" };
        String[] sv = { "1", "", "", "", "", "" };
        for (int i = 0; i < 6; i++) v &= w[i].equals(WipeChoice.wipeValue(i)) && sv[i].equals(WipeChoice.savedValue(i));
        check("V1 wipeValue and savedValue per choice", v, null);

        String t0 = Lifted.prefsUpdatedWipe(OLD, WipeChoice.wipeValue(0), WipeChoice.savedValue(0), "en-US");
        eq("C1 choice 0 writes wipe=1 then wipesaved=1", "tz=Europe/Paris\nlocale=fr-FR\nidle=15\nwipe=1\nwipesaved=1\n"
                + "holdlock=0\nvpn=org.example.vpn\nvpnlockdown=1\nnetloc=1\ngeocoder=1\nmobiledata=1\ndataroaming=0\n", t0);
        String t1 = Lifted.prefsUpdatedWipe(t0, WipeChoice.wipeValue(1), WipeChoice.savedValue(1), "en-US");
        check("C2 choice 1 on a wipesaved=1 file: wipe=1, no wipesaved", Lifted.prefValueIn(t1, "wipe").equals("1")
                && Lifted.prefValueIn(t1, "wipesaved").isEmpty() && !t1.contains("wipesaved"), t1);
        eq("C3 choice 5 writes wipe=0 and only that changes", OLD.replace("wipe=12", "wipe=0"),
                Lifted.prefsUpdatedWipe(t0, WipeChoice.wipeValue(5), WipeChoice.savedValue(5), "en-US"));

        String f = "tz=Europe/Paris\nlocale=fr-FR\nwipe=1\nwipesaved=1\n";
        String[][] kv = { {"tz", "UTC"}, {"locale", "de-DE"}, {"idle", "5"}, {"holdlock", "0"}, {"vpn", "x.y"},
                {"vpnlockdown", "0"}, {"netloc", "1"}, {"geocoder", "1"}, {"mobiledata", "1"}, {"dataroaming", "1"} };
        for (String[] p : kv) {
            String t = Lifted.prefsUpdated(f, p[0], p[1], "en-US");
            check("K1 " + p[0] + " keeps wipe=1 and wipesaved=1", t.contains("wipe=1\nwipesaved=1\n"), t);
        }
        check("K2 an empty value removes wipesaved", !Lifted.prefsUpdated(f, "wipesaved", "", "en-US").contains("wipesaved"), null);
        check("K2 ' 1 ' writes exactly wipesaved=1", Lifted.prefsUpdated("tz=a\nlocale=b\n", "wipesaved", " 1 ", "en-US")
                .equals("tz=a\nlocale=b\nwipesaved=1\n"), null);

        String lit = "tz=Europe/Paris\nlocale=fr-FR\nidle=15\nwipe=12\nholdlock=0\nvpn=org.example.vpn\nvpnlockdown=1\n"
                + "netloc=1\ngeocoder=1\nmobiledata=1\ndataroaming=0\n";
        for (String s : new String[] { "", "0", "2", "x" })
            eq("B1 wipesaved '" + s + "' is today's file", lit, Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "",
                    "org.example.vpn", "1", "1", "1", "1", "0", s));
        eq("B3 wipesaved 1 follows the wipe line", lit.replace("wipe=12\n", "wipe=12\nwipesaved=1\n"),
                Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "1", "1", "1", "0", "1"));
    }

    public static void main(String[] a) {
        try { body(); } catch (RuntimeException e) { bad++; run++; System.out.println("  FAIL  exception " + e); }
        System.out.println((run - bad) + " of " + run + " checks passed");
        System.exit(bad == 0 ? 0 : 1);
    }
}
