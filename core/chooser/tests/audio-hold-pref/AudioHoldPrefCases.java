package com.nowhere.chooser;

import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** NWP-20261124-17: the "audio playing" box's roamed key holdaudio= end to end, run by
 *  core/vendor-common/bin/test-audio-hold-pref-java.sh. Lifted holds what the suite lifts from the chooser's sources:
 *  prefsText and prefsUpdated (ProfileActivity), the receiver's parse call and its EXTRA_* names (PrefsLiveReceiver),
 *  applyRoamedPrefs's line loop, parse call and static writes (signIn), and applyLivePrefs's static writes (applyLive). */
public final class AudioHoldPrefCases {
    private static final long D = 1_000L;
    private static int fails = 0;

    private static void eq(String what, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("  ok    " + what);
        } else {
            fails++;
            System.out.println("  FAIL  " + what + ": want <" + want + ">, got <" + got + ">");
        }
    }

    private static Map<String, String> extras(String... kv) {
        Map<String, String> m = new HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    public static void main(String[] a) {
        // A1/A2: RoamedPrefs.parse. Absent, empty or anything but "0" holds; only "0" is Off; read apart from holdlock.
        eq("A1 holdaudio absent holds", true, RoamedPrefs.parse(null, null, null, null, null, D, D).holdAudio);
        eq("A1 holdaudio empty holds", true, RoamedPrefs.parse(null, null, null, null, "", D, D).holdAudio);
        eq("A1 holdaudio 1 holds", true, RoamedPrefs.parse(null, null, null, null, "1", D, D).holdAudio);
        eq("A2 holdaudio 0 is Off", false, RoamedPrefs.parse(null, null, null, null, "0", D, D).holdAudio);
        eq("A2 holdlock 0 leaves the audio hold on", true, RoamedPrefs.parse(null, null, null, "0", null, D, D).holdAudio);
        eq("A2 holdaudio 0 leaves the install hold on", true, RoamedPrefs.parse(null, null, null, null, "0", D, D).holdLock);

        // A3: a live Save. The receiver's parse of its extras, then applyLivePrefs's writes.
        Lifted.sHoldLockForAudio = true;
        Lifted.applyLive(Lifted.receiverParse(extras(Lifted.EXTRA_IDLE, "5", Lifted.EXTRA_HOLDAUDIO, "0")));
        eq("A3 the live extra holdaudio=0 turns sHoldLockForAudio off", false, Lifted.sHoldLockForAudio);
        eq("A3 ... and leaves sHoldLockForInstalls on", true, Lifted.sHoldLockForInstalls);
        Lifted.sHoldLockForAudio = false;
        Lifted.applyLive(Lifted.receiverParse(extras(Lifted.EXTRA_IDLE, "5")));
        eq("A3 a live send without the extra turns sHoldLockForAudio on", true, Lifted.sHoldLockForAudio);
        Lifted.sHoldLockForAudio = false;
        Lifted.applyLive(Lifted.receiverParse(extras(Lifted.EXTRA_HOLDAUDIO, "")));
        eq("A3 an empty extra turns sHoldLockForAudio on", true, Lifted.sHoldLockForAudio);
        eq("A3 the extra's name is nowhere.prefs.holdaudio", "nowhere.prefs.holdaudio", Lifted.EXTRA_HOLDAUDIO);

        // A3b: sign-in. applyRoamedPrefs reads GET-PREFS's lines; a profile without the key holds.
        Lifted.sHoldLockForAudio = false;
        Lifted.signIn(Arrays.asList("tz=", "locale=en-US", "idle=15"));
        eq("A3b sign-in without holdaudio= turns sHoldLockForAudio on", true, Lifted.sHoldLockForAudio);
        Lifted.sHoldLockForAudio = true;
        Lifted.signIn(Arrays.asList("tz=", "locale=en-US", "idle=5", "holdaudio=0"));
        eq("A3b sign-in with holdaudio=0 turns sHoldLockForAudio off", false, Lifted.sHoldLockForAudio);
        eq("A3b ... and leaves sHoldLockForInstalls on", true, Lifted.sHoldLockForInstalls);
        Lifted.sHoldLockForAudio = true;
        Lifted.signIn(Arrays.asList("holdlock=0"));
        eq("A3b sign-in with holdlock=0 only keeps the audio hold on", true, Lifted.sHoldLockForAudio);
        eq("A3b ... and turns the install hold off", false, Lifted.sHoldLockForInstalls);

        // A4: prefsText writes holdaudio=0 only when Off, right after holdlock=0; On is today's file, byte for byte.
        final String head = "tz=UTC\nlocale=en-US\nidle=15\nwipe=12\nholdlock=0\n";
        eq("A4 Off writes holdaudio=0 after holdlock=0", head + "holdaudio=0\n",
                Lifted.prefsText("UTC", "en-US", "15", "12", "0", "0", "", "", "", "", "", "", ""));
        for (String v : new String[] { "", "1", " " })
            eq("A4 holdaudio '" + v + "' writes no holdaudio line", head,
                    Lifted.prefsText("UTC", "en-US", "15", "12", "0", v, "", "", "", "", "", "", ""));

        // A5: setPref's read-modify step keeps, adds and removes the line.
        String cur = "tz=UTC\nlocale=en-US\nidle=15\n";
        String off = Lifted.prefsUpdated(cur, "holdaudio", "0", "en-US");
        eq("A5 setPref(holdaudio, 0) adds the line", cur + "holdaudio=0\n", off);
        eq("A5 another key's write keeps holdaudio=0", "tz=UTC\nlocale=en-US\nidle=5\nholdaudio=0\n",
                Lifted.prefsUpdated(off, "idle", "5", "en-US"));
        eq("A5 setPref(holdaudio, \"\") removes it", cur, Lifted.prefsUpdated(off, "holdaudio", "", "en-US"));

        // A6/A7: the preset picker reads the key; absent is Standard, "0" is part of Hardened.
        Map<String, String> none = PresetPicker.current("", "", "");
        eq("A6 current() with no holdaudio= is On", "", none.get("holdaudio"));
        eq("A6 a profile with no keys at all is Standard", ProfilePresets.STANDARD, ProfilePresets.match(none));
        eq("A6 holdaudio=0 alone is Custom", ProfilePresets.CUSTOM,
                ProfilePresets.match(PresetPicker.current("holdaudio=0\n", "", "")));
        final String hCfg = "media.default=ondemand\napps.default.napps=ondemand\n", hRec = "86400000\n";
        eq("A7 Hardened's files with holdaudio=0 are Hardened", ProfilePresets.HARDENED,
                ProfilePresets.match(PresetPicker.current("idle=5\nwipe=6\nholdlock=0\nholdaudio=0\n", hCfg, hRec)));
        eq("A7 Hardened's files without holdaudio=0 are Custom", ProfilePresets.CUSTOM,
                ProfilePresets.match(PresetPicker.current("idle=5\nwipe=6\nholdlock=0\n", hCfg, hRec)));

        // A8: the row's column values.
        String[][] col = { { ProfilePresets.UNSHIELDED, "" }, { ProfilePresets.STANDARD, "" },
                { ProfilePresets.HARDENED, "0" }, { ProfilePresets.ISOLATED, "0" }, { ProfilePresets.ZERO, "0" } };
        for (String[] c : col) eq("A8 " + c[0] + " holdaudio", c[1], ProfilePresets.valuesOf(c[0]).get("holdaudio"));
        eq("A8 the row's label", "Security > Auto standby when idle > \"Before standby, wait for:\" > \"audio playing\"",
                labelOf("holdaudio"));
        eq("A8 the install row's label", "Security > Auto standby when idle > \"Before standby, wait for:\" > \"app installs\"",
                labelOf("holdlock"));

        // A9: Standard -> Hardened writes holdaudio=0 to nowhere-prefs.
        List<String> plan = new java.util.ArrayList<>();
        for (PresetPicker.Write w : PresetPicker.plan(none, ProfilePresets.valuesOf(ProfilePresets.HARDENED)))
            plan.add(w.toString());
        eq("A9 Standard -> Hardened writes nowhere-prefs holdaudio=0", true, plan.contains("nowhere-prefs|holdaudio|0"));

        if (fails > 0) { System.out.println("FAIL: " + fails + " case(s)"); System.exit(1); }
        System.out.println("PASS: audio hold pref cases");
    }

    private static String labelOf(String key) {
        for (ProfilePresets.Row r : ProfilePresets.ROWS) if (r.key.equals(key)) return r.label;
        return null;
    }
}
