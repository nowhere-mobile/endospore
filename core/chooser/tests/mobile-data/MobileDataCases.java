// NWP-20261026-07: the cases for the Profile screen's Mobile data decisions (MobileData.java), compiled directly by run.sh.
public final class MobileDataCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) { fails++; System.out.println("  FAIL  " + name + "  got: [" + got + "]"); }
    }

    static final String SUFFIX = " is saved with this profile, but the phone hasn't confirmed the change yet — it takes "
            + "effect when you next sign in or come back from standby, at the latest";

    public static void main(String[] a) {
        // --- choice: exactly 1 or 0 after trimming; anything else is no choice
        check("C1 \"1\"", "1".equals(MobileData.choice("1")), MobileData.choice("1"));
        check("C2 \"0\"", "0".equals(MobileData.choice("0")), MobileData.choice("0"));
        check("C3 \" 1 \" is trimmed", "1".equals(MobileData.choice(" 1 ")), MobileData.choice(" 1 "));
        check("C4 \"\\t0\\r\" is trimmed", "0".equals(MobileData.choice("\t0\r")), MobileData.choice("\t0\r"));
        for (String v : new String[] {null, "", " ", "2", "-1", "01", "10", "11", "true", "false", "on", "off", "yes", "1x", "x0"}) {
            check("C5 \"" + v + "\" is no choice", "".equals(MobileData.choice(v)), MobileData.choice(v));
        }
        check("C6 the key roamd reads", "mobiledata".equals(MobileData.PREF), MobileData.PREF);

        // --- offered: a stored, online session only
        check("O1 STORED online", MobileData.offered("STORED", false), "");
        check("O2 LOCAL (a throwaway) is not", !MobileData.offered("LOCAL", false), "");
        check("O3 LOCAL offline is not", !MobileData.offered("LOCAL", true), "");
        check("O4 STORED but offline is not", !MobileData.offered("STORED", true), "");
        for (String t : new String[] {"UNKNOWN", "NONE", "", "stored", null}) {
            check("O5 a session of type \"" + t + "\" is not", !MobileData.offered(t, false), t);
        }

        // --- switchChecked
        check("W1 choice 1 is On whatever the phone has", MobileData.switchChecked("1", false) && MobileData.switchChecked("1", null), "");
        check("W2 choice 0 is Off whatever the phone has", !MobileData.switchChecked("0", true) && !MobileData.switchChecked("0", null), "");
        check("W3 no choice follows the phone: on", MobileData.switchChecked("", true), "");
        check("W4 no choice follows the phone: off", !MobileData.switchChecked("", false), "");
        check("W5 no choice and the phone unreadable is Off", !MobileData.switchChecked("", null), "");
        check("W6 a non-choice value follows the phone", MobileData.switchChecked("2", true) && !MobileData.switchChecked("2", false), "");

        // --- replyValue / applied
        check("R1 OK APPLIED 1", "1".equals(MobileData.replyValue("OK APPLIED mobile_data=1")), MobileData.replyValue("OK APPLIED mobile_data=1"));
        check("R2 OK APPLIED 0", "0".equals(MobileData.replyValue("OK APPLIED mobile_data=0")), MobileData.replyValue("OK APPLIED mobile_data=0"));
        check("R2b a trailing newline", "1".equals(MobileData.replyValue("OK APPLIED mobile_data=1\n")), MobileData.replyValue("OK APPLIED mobile_data=1\n"));
        for (String r : new String[] {"ERR-MD mobile_data=1", "ERR-MD mobile_data=?", "SKIP-ENDED", "NONE", "", null,
                "mobile_data=1", "OK mobile_data=1", "OK APPLIED", "OK APPLIED geocoder=1"}) {
            check("R3 \"" + r + "\" carries no value", "".equals(MobileData.replyValue(r)), MobileData.replyValue(r));
            check("R4 \"" + r + "\" confirms neither", !MobileData.applied(r, true) && !MobileData.applied(r, false), r);
        }
        check("R5 applied 1 for On", MobileData.applied("OK APPLIED mobile_data=1", true), "");
        check("R6 applied 0 for Off", MobileData.applied("OK APPLIED mobile_data=0", false), "");
        check("R7 a read-back of 1 does not confirm Off", !MobileData.applied("OK APPLIED mobile_data=1", false), "");
        check("R8 a read-back of 0 does not confirm On", !MobileData.applied("OK APPLIED mobile_data=0", true), "");
        check("R9 a read-back of 2 confirms nothing", !MobileData.applied("OK APPLIED mobile_data=2", true) && !MobileData.applied("OK APPLIED mobile_data=2", false), "");

        // --- applyToast: says on/off only when the read-back matches; nothing when a later tap replaced this one
        check("T1 applied On", "Mobile data on — only while you're signed in to this profile".equals(MobileData.applyToast(true, "OK APPLIED mobile_data=1", true)), MobileData.applyToast(true, "OK APPLIED mobile_data=1", true));
        check("T2 applied Off", "Mobile data off — only while you're signed in to this profile".equals(MobileData.applyToast(false, "OK APPLIED mobile_data=0", true)), MobileData.applyToast(false, "OK APPLIED mobile_data=0", true));
        for (String r : new String[] {"ERR-MD mobile_data=0", "ERR-MD mobile_data=?", "SKIP-ENDED", "NONE", "", null, "OK APPLIED mobile_data=0"}) {
            String on = MobileData.applyToast(true, r, true);
            check("T3 On, answer \"" + r + "\": saved, not confirmed", ("Mobile data on" + SUFFIX).equals(on), on);
        }
        for (String r : new String[] {"ERR-MD mobile_data=1", "SKIP-ENDED", "NONE", "", null, "OK APPLIED mobile_data=1"}) {
            String off = MobileData.applyToast(false, r, true);
            check("T4 Off, answer \"" + r + "\": saved, not confirmed", ("Mobile data off" + SUFFIX).equals(off), off);
        }
        for (String r : new String[] {"OK APPLIED mobile_data=1", "OK APPLIED mobile_data=0", "ERR-MD mobile_data=?", "", null}) {
            check("T5 a replaced tap says nothing (On, \"" + r + "\")", MobileData.applyToast(true, r, false) == null, "");
            check("T5 a replaced tap says nothing (Off, \"" + r + "\")", MobileData.applyToast(false, r, false) == null, "");
        }

        // --- notSavedToast
        String head = "Mobile data: the change couldn't be saved on this phone. ";
        String n1 = MobileData.notSavedToast(true, "OK APPLIED mobile_data=1", true);
        check("N1 now On, read back", (head + "Mobile data is now on, only while you're signed in to this profile").equals(n1), n1);
        String n2 = MobileData.notSavedToast(false, "OK APPLIED mobile_data=0", true);
        check("N2 now Off, read back", (head + "Mobile data is now off, only while you're signed in to this profile").equals(n2), n2);
        for (String r : new String[] {"OK APPLIED mobile_data=0", "ERR-MD mobile_data=?", "SKIP-ENDED", "NONE", "", null}) {
            String t = MobileData.notSavedToast(true, r, true);
            check("N3 now On, answer \"" + r + "\": not confirmed", t != null && t.startsWith(head) && t.contains("setting is on")
                    && !t.contains("is now") && t.endsWith("at the latest"), t);
        }
        for (String r : new String[] {"OK APPLIED mobile_data=1", "ERR-MD mobile_data=?", "", null}) {
            String t = MobileData.notSavedToast(false, r, true);
            check("N4 now Off, answer \"" + r + "\": not confirmed", t != null && t.startsWith(head) && t.contains("setting is off")
                    && !t.contains("is now") && t.endsWith("at the latest"), t);
        }
        check("N5 a replaced failed write says nothing", MobileData.notSavedToast(true, "OK APPLIED mobile_data=1", false) == null
                && MobileData.notSavedToast(false, "", false) == null, "");


        // --- NWP-20261028-09: Data roaming
        check("DC0 the key roamd reads", "dataroaming".equals(MobileData.ROAM_PREF), MobileData.ROAM_PREF);
        check("DC1 \"1\"", "1".equals(MobileData.roamChoice("1")), "");
        check("DC2 \"0\"", "0".equals(MobileData.roamChoice("0")), "");
        check("DC3 \" 1 \" and \"\\t0\\r\" are trimmed", "1".equals(MobileData.roamChoice(" 1 ")) && "0".equals(MobileData.roamChoice("\t0\r")), "");
        for (String v : new String[] {null, "", " ", "2", "-1", "01", "10", "true", "false", "on", "1x"}) {
            check("DC4 \"" + v + "\" is no choice", "".equals(MobileData.roamChoice(v)), MobileData.roamChoice(v));
        }
        String[][] rv = {
            {"OK APPLIED mobile_data=1 data_roaming=0", "0"}, {"OK APPLIED mobile_data=0 data_roaming=1", "1"},
            {"OK APPLIED mobile_data=1 data_roaming=1\n", "1"}, {"OK APPLIED mobile_data=1 data_roaming=?", ""},
            {"OK APPLIED mobile_data=1", ""}, {"OK APPLIED mobile_data=1 data_roaming=2", ""},
            {"ERR-MD mobile_data=1 data_roaming=0", ""}, {"SKIP-ENDED", ""}, {"NONE", ""}, {"", ""}, {null, ""},
            {"data_roaming=1", ""}, {"OK APPLIED data_roaming=1", "1"}};
        for (String[] c : rv) {
            check("DR \"" + c[0] + "\" reads \"" + c[1] + "\"", c[1].equals(MobileData.roamReplyValue(c[0])), MobileData.roamReplyValue(c[0]));
        }
        check("DR2 mobile_data's value is not roaming's", !MobileData.roamApplied("OK APPLIED mobile_data=1", true)
                && !MobileData.roamApplied("OK APPLIED mobile_data=1 data_roaming=?", true)
                && !MobileData.roamApplied("OK APPLIED mobile_data=0 data_roaming=?", false), "");
        check("DR3 applied only on a matching token", MobileData.roamApplied("OK APPLIED mobile_data=0 data_roaming=1", true)
                && MobileData.roamApplied("OK APPLIED mobile_data=1 data_roaming=0", false)
                && !MobileData.roamApplied("OK APPLIED mobile_data=1 data_roaming=0", true)
                && !MobileData.roamApplied("OK APPLIED mobile_data=0 data_roaming=1", false), "");
        String RS = " is saved with this profile, but the phone hasn't confirmed the change yet — it takes "
                + "effect when you next sign in or come back from standby, at the latest";
        String ra = MobileData.roamApplyToast(true, "OK APPLIED mobile_data=0 data_roaming=1", true);
        check("DT1 applied On", "Data roaming on — only while you're signed in to this profile".equals(ra), ra);
        String rb = MobileData.roamApplyToast(false, "OK APPLIED mobile_data=1 data_roaming=0", true);
        check("DT2 applied Off", "Data roaming off — only while you're signed in to this profile".equals(rb), rb);
        for (String r : new String[] {"OK APPLIED mobile_data=1", "OK APPLIED mobile_data=1 data_roaming=?", "OK APPLIED mobile_data=1 data_roaming=0",
                "ERR-MD mobile_data=1 data_roaming=1", "SKIP-ENDED", "NONE", "", null}) {
            String t = MobileData.roamApplyToast(true, r, true);
            check("DT3 On, answer \"" + r + "\": saved, not confirmed", ("Data roaming on" + RS).equals(t), t);
        }
        for (String r : new String[] {"OK APPLIED mobile_data=0", "OK APPLIED mobile_data=0 data_roaming=1", "ERR-MD mobile_data=0 data_roaming=0", "", null}) {
            String t = MobileData.roamApplyToast(false, r, true);
            check("DT4 Off, answer \"" + r + "\": saved, not confirmed", ("Data roaming off" + RS).equals(t), t);
        }
        for (String r : new String[] {"OK APPLIED mobile_data=1 data_roaming=1", "OK APPLIED mobile_data=0 data_roaming=0", "", null}) {
            check("DT5 a replaced tap says nothing (\"" + r + "\")", MobileData.roamApplyToast(true, r, false) == null
                    && MobileData.roamApplyToast(false, r, false) == null && MobileData.roamNotSavedToast(true, r, false) == null, "");
        }
        String rh = "Data roaming: the change couldn't be saved on this phone. ";
        String rn1 = MobileData.roamNotSavedToast(true, "OK APPLIED mobile_data=0 data_roaming=1", true);
        check("DN1 now On, read back", (rh + "Data roaming is now on, only while you're signed in to this profile").equals(rn1), rn1);
        String rn2 = MobileData.roamNotSavedToast(false, "OK APPLIED mobile_data=1 data_roaming=0", true);
        check("DN2 now Off, read back", (rh + "Data roaming is now off, only while you're signed in to this profile").equals(rn2), rn2);
        for (String r : new String[] {"OK APPLIED mobile_data=1", "OK APPLIED mobile_data=1 data_roaming=0", "OK APPLIED mobile_data=1 data_roaming=?", "", null}) {
            String t = MobileData.roamNotSavedToast(true, r, true);
            check("DN3 now On, answer \"" + r + "\": not confirmed", t != null && t.startsWith(rh) && t.contains("setting is on")
                    && !t.contains("is now") && t.endsWith("at the latest"), t);
        }
        String rn4 = MobileData.roamNotSavedToast(false, "OK APPLIED mobile_data=0 data_roaming=1", true);
        check("DN4 now Off, a roaming read-back of 1: not confirmed", rn4 != null && rn4.contains("setting is off") && !rn4.contains("is now"), rn4);
        check("DM the mobile data members are unchanged by a roaming token", "1".equals(MobileData.replyValue("OK APPLIED mobile_data=1 data_roaming=0"))
                && MobileData.applied("OK APPLIED mobile_data=0 data_roaming=1", false), "");

        System.out.println("  " + (runs - fails) + " of " + runs + " checks passed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
