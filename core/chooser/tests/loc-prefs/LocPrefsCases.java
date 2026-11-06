// NWP-20261016-45: the cases for the chooser's Location services prefs, run against Lifted (run.sh): the nowhere-prefs
// parser (prefValueIn), the On rule (locPrefOn), the composer (prefsText), setPref's read-modify step (prefsUpdated), who
// is offered the switches (locOffered), the reply rules (locReplyValue, locApplied), the two toasts (locApplyToast,
// locNotSavedToast) and the file's name (PREFS_FILE). roamd's loc_on reads the same file with the same rule;
// test-locglobals.sh pins that side.
public final class LocPrefsCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) { fails++; System.out.println("  FAIL  " + name + "  got: [" + got + "]"); }
    }

    static boolean on(String text, String key) { return Lifted.locPrefOn(Lifted.prefValueIn(text, key)); }

    // What every chooser before this slice wrote, for one profile with every older key set.
    static final String OLD = "tz=Europe/Paris\nlocale=fr-FR\nidle=15\nwipe=12\nholdlock=0\nvpn=org.example.vpn\nvpnlockdown=1\n";

    // Every key set to a value that is not its default, and the two switches set differently from each other, so a key
    // carried from the wrong place, or dropped, or two arguments trading places, all show.
    static final String[] KEYS = {"tz", "locale", "idle", "wipe", "holdlock", "vpn", "vpnlockdown", "netloc", "geocoder"};
    static final String BASE = "tz=Europe/Paris\nlocale=fr-FR\nidle=15\nwipe=12\nholdlock=0\nvpn=org.example.vpn\nvpnlockdown=0\n";
    static final String NET_ONLY = BASE + "netloc=1\n";
    static final String GEO_ONLY = BASE + "geocoder=1\n";
    static final String BOTH = BASE + "netloc=1\ngeocoder=1\n";

    static final String NET = "OK APPLIED network_location=2 geocoder=0";

    public static void main(String[] a) {
        try {
            cases();
        } catch (RuntimeException e) {
            // A member that throws where it must answer is a failed case, not a broken harness.
            fails++;
            System.out.println("  FAIL  a lifted member threw: " + e);
        }
        System.out.println("  " + (runs - fails) + " of " + runs + " checks passed");
        System.exit(fails == 0 ? 0 : 1);
    }

    static void cases() {
        // --- the keys are the ones roamd reads
        check("K1 the network-location key is netloc", "netloc".equals(Lifted.PREF_NETLOC), Lifted.PREF_NETLOC);
        check("K2 the geocoding key is geocoder", "geocoder".equals(Lifted.PREF_GEOCODER), Lifted.PREF_GEOCODER);
        check("K3 the prefs file is nowhere-prefs, the name roamd reads", "nowhere-prefs".equals(Lifted.PREFS_FILE),
                Lifted.PREFS_FILE);

        // --- parse: an old file, and every shape the rule has to get right
        check("P1 a file written before this slice reads netloc Off", !on(OLD, "netloc"), Lifted.prefValueIn(OLD, "netloc"));
        check("P1 ...and geocoder Off", !on(OLD, "geocoder"), Lifted.prefValueIn(OLD, "geocoder"));
        check("P1 ...and its own keys are untouched", "fr-FR".equals(Lifted.prefValueIn(OLD, "locale")),
                Lifted.prefValueIn(OLD, "locale"));
        check("P2 netloc=1 is On", on("tz=\nlocale=en-US\nnetloc=1\n", "netloc"), "");
        check("P3 the FIRST matching line wins", !on("netloc=0\nnetloc=1\n", "netloc"), Lifted.prefValueIn("netloc=0\nnetloc=1\n", "netloc"));
        check("P4 CRLF lines", on("tz=X\r\nnetloc=1\r\ngeocoder=1\r\n", "geocoder"), Lifted.prefValueIn("tz=X\r\nnetloc=1\r\ngeocoder=1\r\n", "geocoder"));
        check("P4 lone-CR lines end where readLine ends them", on("tz=X\rnetloc=1\r", "netloc"),
                Lifted.prefValueIn("tz=X\rnetloc=1\r", "netloc"));
        check("P5 blanks around the value are trimmed", "1".equals(Lifted.prefValueIn("netloc= 1 \n", "netloc")),
                Lifted.prefValueIn("netloc= 1 \n", "netloc"));
        check("P6 no prefix or suffix match", !on("netlocx=1\nmygeocoder=1\n", "netloc") && !on("netlocx=1\nmygeocoder=1\n", "geocoder"), "");
        check("P7 null text", "".equals(Lifted.prefValueIn(null, "netloc")), Lifted.prefValueIn(null, "netloc"));
        check("P7 empty text", "".equals(Lifted.prefValueIn("", "netloc")), Lifted.prefValueIn("", "netloc"));
        check("P8 a last line with no newline counts", on("tz=\ngeocoder=1", "geocoder"), "");

        // --- the On rule: exactly 1, blanks trimmed; everything else, and nothing, is Off
        check("V1 \"1\" is On", Lifted.locPrefOn("1"), "1");
        check("V2 \" 1 \" is On", Lifted.locPrefOn(" 1 "), " 1 ");
        for (String v : new String[] {null, "", "0", "2", "3", "true", "yes", "on", "11", "1x", "-1"}) {
            check("V3 \"" + v + "\" is Off", !Lifted.locPrefOn(v), v);
        }

        // --- compose: byte-compatible when Off, exactly "1" when On
        String minimal = Lifted.prefsText("", "en-US", "", "", "", "", "", "", "1", "", "", "", "");
        check("S1 a fresh profile with only the switch", "tz=\nlocale=en-US\nnetloc=1\n".equals(minimal), minimal);
        for (String v : new String[] {"0", "2", "true", "on"}) {
            String t = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", v, v, "", "", "");
            check("S2 a non-1 value \"" + v + "\" is never written", OLD.equals(t), t);
        }
        String trimmed = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", " 1 ", "1 ", "", "", "");
        check("S3 an On value is written as exactly 1", (OLD + "netloc=1\ngeocoder=1\n").equals(trimmed), trimmed);

        // --- NWP-20261026-07: the Mobile data choice, a tri-state: no line is no choice
        String mdNone = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "", "", "", "", "");
        check("M1 no mobile data choice: byte for byte today's file", OLD.equals(mdNone), mdNone);
        for (String v : new String[] {null, " ", "2", "true", "on", "-1", "01"}) {
            String t = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "", "", v, "", "");
            check("M1b a non-choice \"" + v + "\" writes nothing", OLD.equals(t), t);
        }
        String mdOn = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "1", "1", "1", "", "");
        check("M2 choice 1 appends exactly one line, after the geocoder line",
                (OLD + "netloc=1\ngeocoder=1\nmobiledata=1\n").equals(mdOn), mdOn);
        String mdOff = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "", "", " 0 ", "", "");
        check("M3 choice 0 appends exactly one line, trimmed", (OLD + "mobiledata=0\n").equals(mdOff), mdOff);
        String keepMd = Lifted.prefsUpdated(OLD + "netloc=1\nmobiledata=0\n", "netloc", "", "en-US");
        check("M4 a netloc change keeps mobiledata", (OLD + "mobiledata=0\n").equals(keepMd), keepMd);
        String keepNet = Lifted.prefsUpdated(OLD + "netloc=1\nmobiledata=0\n", "mobiledata", "1", "en-US");
        check("M5 a mobiledata change keeps netloc", (OLD + "netloc=1\nmobiledata=1\n").equals(keepNet), keepNet);
        String mdClear = Lifted.prefsUpdated(OLD + "mobiledata=1\n", "mobiledata", "", "en-US");
        check("M6 a mobiledata write of no choice removes its line", OLD.equals(mdClear), mdClear);
        String capMd = Lifted.prefsUpdated(OLD + "geocoder=1\nmobiledata=1\n", "locale", "de-DE", "en-US");
        check("M7 the logoff capture keeps mobiledata", (OLD.replace("fr-FR", "de-DE") + "geocoder=1\nmobiledata=1\n").equals(capMd), capMd);

        // --- NWP-20261028-09: the Data roaming choice, the same tri-state, written after mobiledata
        String drNone = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "", "", "", "", "");
        check("D1 no roaming choice: byte for byte today's file", OLD.equals(drNone), drNone);
        for (String v : new String[] {null, " ", "2", "true", "on", "-1", "01"}) {
            String t = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "", "", "1", v, "");
            check("D1b a non-choice \"" + v + "\" writes nothing", (OLD + "mobiledata=1\n").equals(t), t);
        }
        String drOn = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "1", "1", "1", "1", "");
        check("D2 choice 1 appends exactly one line, after the mobiledata line",
                (OLD + "netloc=1\ngeocoder=1\nmobiledata=1\ndataroaming=1\n").equals(drOn), drOn);
        String drOff = Lifted.prefsText("Europe/Paris", "fr-FR", "15", "12", "0", "", "org.example.vpn", "1", "", "", "", " 0 ", "");
        check("D3 choice 0 appends exactly one line, trimmed", (OLD + "dataroaming=0\n").equals(drOff), drOff);
        String keepDr = Lifted.prefsUpdated(OLD + "mobiledata=1\ndataroaming=0\n", "mobiledata", "0", "en-US");
        check("D4 a mobiledata change keeps dataroaming", (OLD + "mobiledata=0\ndataroaming=0\n").equals(keepDr), keepDr);
        String keepMd2 = Lifted.prefsUpdated(OLD + "mobiledata=1\ndataroaming=0\n", "dataroaming", "1", "en-US");
        check("D5 a dataroaming change keeps mobiledata", (OLD + "mobiledata=1\ndataroaming=1\n").equals(keepMd2), keepMd2);
        String keepDr2 = Lifted.prefsUpdated(OLD + "netloc=1\ndataroaming=1\n", "netloc", "", "en-US");
        check("D6 another key's write keeps dataroaming", (OLD + "dataroaming=1\n").equals(keepDr2), keepDr2);
        String drClear = Lifted.prefsUpdated(OLD + "dataroaming=1\n", "dataroaming", "", "en-US");
        check("D7 a dataroaming write of no choice removes its line", OLD.equals(drClear), drClear);
        String capDr = Lifted.prefsUpdated(OLD + "mobiledata=1\ndataroaming=1\n", "locale", "de-DE", "en-US");
        check("D8 the logoff capture keeps both", (OLD.replace("fr-FR", "de-DE") + "mobiledata=1\ndataroaming=1\n").equals(capDr), capDr);

        // --- setPref's read-modify step (prefsUpdated), through the method setPref calls
        String same = Lifted.prefsUpdated(OLD, "tz", "Europe/Paris", "en-US");
        check("U1 an old file rewritten with both Off is byte for byte what it was", OLD.equals(same), same);
        String offAgain = Lifted.prefsUpdated(OLD, "netloc", "", "en-US");
        check("U1b ...including a switch written Off", OLD.equals(offAgain), offAgain);
        String netOn = Lifted.prefsUpdated(OLD, "netloc", "1", "en-US");
        check("U2 Network location on: the old file plus exactly netloc=1", (OLD + "netloc=1\n").equals(netOn), netOn);
        String geoOn = Lifted.prefsUpdated(netOn, "geocoder", "1", "en-US");
        check("U2b ...then Geocoding on keeps it: plus geocoder=1", (OLD + "netloc=1\ngeocoder=1\n").equals(geoOn), geoOn);
        String netOff = Lifted.prefsUpdated(geoOn, "netloc", "", "en-US");
        check("U2c ...then Network location off removes only its line", (OLD + "geocoder=1\n").equals(netOff), netOff);
        String capture = Lifted.prefsUpdated(BOTH, "locale", "de-DE", "en-US");
        check("U3 the logoff capture (a locale write) keeps both switches, every key and the order",
                BOTH.replace("locale=fr-FR", "locale=de-DE").equals(capture), capture);
        String tzNet = Lifted.prefsUpdated(NET_ONLY, "tz", "Asia/Tokyo", "en-US");
        check("U3b a tz write on a Network-location-only profile keeps it, and Geocoding stays off",
                NET_ONLY.replace("tz=Europe/Paris", "tz=Asia/Tokyo").equals(tzNet), tzNet);
        String idleGeo = Lifted.prefsUpdated(GEO_ONLY, "idle", "30", "en-US");
        check("U3c an idle write on a Geocoding-only profile keeps it, and Network location stays off",
                GEO_ONLY.replace("idle=15", "idle=30").equals(idleGeo), idleGeo);
        String hold = Lifted.prefsUpdated(BOTH, "holdlock", "", "en-US");
        check("U3d holdlock back to on drops only its line; vpn and the switches stay, in order",
                BOTH.replace("holdlock=0\n", "").equals(hold), hold);
        String fb = Lifted.prefsUpdated("tz=X\nlocale=\n", "tz", "Y", "en-GB");
        check("U4 an empty stored locale becomes the device's", "tz=Y\nlocale=en-GB\n".equals(fb), fb);
        String fresh = Lifted.prefsUpdated("", "netloc", "1", "en-GB");
        check("U4b a profile with no file at all", "tz=\nlocale=en-GB\nnetloc=1\n".equals(fresh), fresh);
        String locEmpty = Lifted.prefsUpdated(OLD, "locale", "", "en-GB");
        check("U4c a locale written empty becomes the device's", "en-GB".equals(Lifted.prefValueIn(locEmpty, "locale")), locEmpty);
        // Each key in turn, on three profiles: that key changes, and every other key reads back what it was.
        for (String base : new String[] {NET_ONLY, GEO_ONLY, BOTH}) {
            for (String k : KEYS) {
                String v = changed(base, k);
                String t = Lifted.prefsUpdated(base, k, v, "en-US");
                String want = ("netloc".equals(k) || "geocoder".equals(k)) ? (Lifted.locPrefOn(v) ? "1" : "") : v;
                check("U5 setting " + k + " on " + label(base) + " sets it", want.equals(Lifted.prefValueIn(t, k)), t);
                for (String j : KEYS) {
                    if (j.equals(k)) continue;
                    check("U5 setting " + k + " on " + label(base) + " keeps " + j,
                            Lifted.prefValueIn(base, j).equals(Lifted.prefValueIn(t, j)), t);
                }
            }
        }

        // --- who is offered the switches: a stored session on an image with the provider, nobody else
        check("O1 a stored profile on Endospore is offered Location services", Lifted.locOffered("STORED", false, true), "");
        check("O2 a throwaway is not (Chester's NWP-20260924-02 rule)", !Lifted.locOffered("LOCAL", false, true), "");
        check("O3 an offline sign-in is not", !Lifted.locOffered("LOCAL", true, true), "");
        check("O4 the offline flag wins over a STORED answer", !Lifted.locOffered("STORED", true, true), "");
        for (String t : new String[] {"UNKNOWN", "NONE", "", null}) {
            check("O5 a session of type \"" + t + "\" is not", !Lifted.locOffered(t, false, true), t);
        }
        check("O6 no provider (Diaspore): nobody", !Lifted.locOffered("STORED", false, false), "");

        // --- the reply: the value roamd read back for THIS key
        check("R1 network_location read back", "2".equals(Lifted.locReplyValue(NET, "netloc")), Lifted.locReplyValue(NET, "netloc"));
        check("R1 geocoder read back", "0".equals(Lifted.locReplyValue(NET, "geocoder")), Lifted.locReplyValue(NET, "geocoder"));
        check("R1b no value for any other key", "".equals(Lifted.locReplyValue(NET, "tz")), Lifted.locReplyValue(NET, "tz"));
        for (String r : new String[] {null, "", "OK", "OK UNAVAILABLE", "OK APPLIEDX network_location=2 geocoder=2", "NONE",
                "SKIP-ENDED", "ERR-LOC network_location=2,geocoder=2", "ERR-LOC network_location=2 geocoder=2",
                "ERR-TIMEOUT", "ERR-WORKER-BUSY"}) {
            for (String k : new String[] {"netloc", "geocoder"}) {
                check("R2 \"" + r + "\" carries no " + k + " value", "".equals(Lifted.locReplyValue(r, k)), Lifted.locReplyValue(r, k));
                check("R2 \"" + r + "\" confirms no " + k + " on", !Lifted.locApplied(r, k, true), r);
                check("R2 \"" + r + "\" confirms no " + k + " off", !Lifted.locApplied(r, k, false), r);
                for (boolean o : new boolean[] {true, false}) {
                    String t = Lifted.locApplyToast("Network location", k, o, r, true);
                    check("R3 \"" + r + "\" " + k + (o ? " on" : " off") + ": the toast says it is saved, not applied",
                            t != null && t.contains("hasn't confirmed") && t.contains("saved with this profile")
                                    && t.contains("next sign in or come back from standby")
                                    && !t.contains("only while you're signed in") && !t.equals("Network location off"), t);
                }
            }
        }
        String onT = Lifted.locApplyToast("Network location", "netloc", true, NET, true);
        check("R4 applied On", "Network location on — only while you're signed in to this profile".equals(onT), onT);
        String offT = Lifted.locApplyToast("Geocoding", "geocoder", false, NET, true);
        check("R5 applied Off, judged by geocoder= alone", "Geocoding off".equals(offT), offT);
        String r6 = Lifted.locApplyToast("Network location", "netloc", true, "OK APPLIED network_location=0 geocoder=0", true);
        check("R6 On answered network_location=0 is not confirmed", r6 != null && r6.contains("hasn't confirmed"), r6);
        String r7 = Lifted.locApplyToast("Network location", "netloc", false, NET, true);
        check("R7 Off answered network_location=2 is not confirmed", r7 != null && r7.contains("hasn't confirmed"), r7);
        String r8 = Lifted.locApplyToast("Geocoding", "geocoder", true, NET, true);
        check("R8 Geocoding On is judged by geocoder=, not network_location=", r8 != null && r8.contains("hasn't confirmed"), r8);
        String r8b = Lifted.locApplyToast("Geocoding", "geocoder", true, "OK APPLIED network_location=0 geocoder=2", true);
        check("R8b ...and confirmed by geocoder=2 alone", "Geocoding on — only while you're signed in to this profile".equals(r8b), r8b);
        String r8c = Lifted.locApplyToast("Network location", "netloc", false, "OK APPLIED network_location=0 geocoder=2", true);
        check("R8c Network location Off confirmed by network_location=0 alone", "Network location off".equals(r8c), r8c);
        for (String v : new String[] {"1", "22", "2,", "?", "null", ""}) {
            String r = "OK APPLIED network_location=" + v + " geocoder=" + v;
            check("R10 a read-back of \"" + v + "\" confirms no On", !Lifted.locApplied(r, "netloc", true)
                    && !Lifted.locApplied(r, "geocoder", true), r);
        }
        for (String r : new String[] {NET, "OK APPLIED network_location=0 geocoder=0", "SKIP-ENDED", ""}) {
            for (boolean o : new boolean[] {true, false}) {
                String t = Lifted.locApplyToast("Network location", "netloc", o, r, false);
                check("R9 a tap a later tap replaced says nothing (\"" + r + "\")", t == null, t);
            }
        }

        // --- a write that failed: the screen is redrawn from the file and roamd still applies the file, so the toast
        // says what the FILE holds for that switch (nowOn), never the tap, and calls it the phone's state only when
        // roamd read that setting back as that value
        String n1 = Lifted.locNotSavedToast("Network location", "netloc", false, "OK APPLIED network_location=0 geocoder=2", true);
        check("N1 not saved, read back off", ("Network location: the change couldn't be saved on this phone. "
                + "Network location is now off").equals(n1), n1);
        String n2 = Lifted.locNotSavedToast("Geocoding", "geocoder", true, "OK APPLIED network_location=0 geocoder=2", true);
        check("N2 not saved, read back on", ("Geocoding: the change couldn't be saved on this phone. "
                + "Geocoding is now on, only while you're signed in to this profile").equals(n2), n2);
        // The handler's nowOn is locPrefOn(readPrefValue(key)) after the failure; here, the files a failed write leaves.
        String[][] after = {
            // the file the failed write left, key, roamd's reply once it applied that file, what the toast must say
            {"", "netloc", "OK APPLIED network_location=0 geocoder=0", "off", "an emptied file"},
            {"", "geocoder", "OK APPLIED network_location=0 geocoder=0", "off", "an emptied file"},
            {"tz=Europe/Paris\nlocale=fr", "netloc","OK APPLIED network_location=0 geocoder=0", "off", "part of the text"},
            {NET_ONLY, "netloc", "OK APPLIED network_location=2 geocoder=0", "on", "a Network-location-only file intact"},
            {NET_ONLY, "geocoder", "OK APPLIED network_location=2 geocoder=0", "off", "a Network-location-only file intact"},
            {GEO_ONLY, "netloc", "OK APPLIED network_location=0 geocoder=2", "off", "a Geocoding-only file intact"},
            {BOTH, "geocoder", "OK APPLIED network_location=2 geocoder=2", "on", "a file with both on intact"},
        };
        for (String[] c : after) {
            boolean nowOn = Lifted.locPrefOn(Lifted.prefValueIn(c[0], c[1]));
            String t = Lifted.locNotSavedToast("Network location", c[1], nowOn, c[2], true);
            check("N3 a failed " + c[1] + " write that left " + c[4] + ": the toast says it is now " + c[3],
                    t != null && t.contains("couldn't be saved") && t.contains(" is now " + c[3])
                            && !t.contains("hasn't confirmed"), t);
        }
        for (String r : new String[] {null, "", "OK", "OK UNAVAILABLE", "SKIP-ENDED", "ERR-LOC network_location=0 geocoder=0",
                "ERR-TIMEOUT", "ERR-WORKER-BUSY"}) {
            for (boolean o : new boolean[] {true, false}) {
                String t = Lifted.locNotSavedToast("Geocoding", "geocoder", o, r, true);
                check("N4 \"" + r + "\"" + (o ? " on" : " off") + ": not saved, and the phone is not said to be at it",
                        t != null && t.startsWith("Geocoding: the change couldn't be saved on this phone.")
                                && t.contains("This profile's setting is " + (o ? "on" : "off") + ",")
                                && t.contains("hasn't confirmed") && t.contains("next sign in or come back from standby")
                                && !t.contains(" is now ") && !t.contains("saved with this profile"), t);
            }
        }
        String n5 = Lifted.locNotSavedToast("Network location", "netloc", false, NET, true);
        check("N5 off read back as network_location=2 is not confirmed", n5 != null && n5.contains("hasn't confirmed"), n5);
        String n6 = Lifted.locNotSavedToast("Geocoding", "geocoder", true, NET, true);
        check("N6 Geocoding is judged by geocoder=, not network_location=", n6 != null && n6.contains("hasn't confirmed"), n6);
        for (String r : new String[] {NET, "OK APPLIED network_location=0 geocoder=0", "SKIP-ENDED", ""}) {
            for (boolean o : new boolean[] {true, false}) {
                String t = Lifted.locNotSavedToast("Network location", "netloc", o, r, false);
                check("N7 a failed write a later tap replaced says nothing (\"" + r + "\")", t == null, t);
            }
        }
        for (String r : new String[] {NET, "OK APPLIED network_location=0 geocoder=0", "OK UNAVAILABLE"}) {
            for (boolean o : new boolean[] {true, false}) {
                String ns = Lifted.locNotSavedToast("Network location", "netloc", o, r, true);
                String ok = Lifted.locApplyToast("Network location", "netloc", o, r, true);
                check("N8 a failed write is never toasted as a saved one (\"" + r + "\"" + (o ? " on" : " off") + ")",
                        ns != null && !ns.equals(ok) && ns.contains("couldn't be saved")
                                && (ok == null || !ok.contains("couldn't be saved")), ns);
            }
        }
    }

    // A value for key that differs from the one base holds (the two switches flip, holdlock goes back to on).
    static String changed(String base, String k) {
        switch (k) {
            case "tz": return "Asia/Tokyo";
            case "locale": return "de-DE";
            case "idle": return "30";
            case "wipe": return "24";
            case "holdlock": return "";
            case "vpn": return "org.other.vpn";
            case "vpnlockdown": return "1";
            default: return Lifted.locPrefOn(Lifted.prefValueIn(base, k)) ? "" : "1";
        }
    }

    static String label(String base) {
        return base == NET_ONLY ? "a Network-location-only profile" : base == GEO_ONLY ? "a Geocoding-only profile"
                : "a profile with both on";
    }
}
