package com.nowhere.chooser;

/** RoamedPrefs.parse: the sign-in rules for idle=, wipe=, wipesaved=, holdlock= and holdaudio=, which the live apply
 *  now shares (NWP-20261119-21; holdaudio= NWP-20261124-17). Run by core/vendor-common/bin/test-roamed-prefs-live-java.sh. The defaults are odd values, so a
 *  parse that hard-codes ChooserActivity's defaults fails. */
public final class RoamedPrefsCases {
    private static final long D_IDLE = 123_000L, D_WIPE = 4_567_000L;
    private static int fails = 0;

    private static void eq(String what, Object want, Object got) {
        if (!want.equals(got)) { fails++; System.out.println("  FAIL  " + what + ": want " + want + ", got " + got); }
    }

    private static RoamedPrefs.Values p(String idle, String wipe, String saved, String hold) {
        return p(idle, wipe, saved, hold, null);
    }

    private static RoamedPrefs.Values p(String idle, String wipe, String saved, String hold, String audio) {
        return RoamedPrefs.parse(idle, wipe, saved, hold, audio, D_IDLE, D_WIPE);
    }

    public static void main(String[] a) {
        // The idle picker's values: minutes x 60000; "0" is Never (0 ms), not the default.
        for (int m : new int[] { 5, 15, 30, 60 }) eq("idle " + m, m * 60_000L, p(String.valueOf(m), null, null, null).idleMs);
        eq("idle 0 is Never", 0L, p("0", null, null, null).idleMs);
        // The wipe picker's six choices, as WipeChoice writes them: hours x 3600000, "0" Never, wipesaved per choice.
        for (int i = 0; i < WipeChoice.HOURS.length; i++) {
            RoamedPrefs.Values v = p(null, WipeChoice.wipeValue(i), WipeChoice.savedValue(i), null);
            eq("wipe choice " + i + " ms", WipeChoice.HOURS[i] * 3_600_000L, v.wipeMs);
            eq("wipe choice " + i + " onsave", WipeChoice.SAVED[i], v.wipeOnSave);
        }
        // Each hour value with and without wipesaved=1: the two keys are read apart.
        for (int h : WipeChoice.HOURS) {
            eq("wipe " + h + " saved=1 ms", h * 3_600_000L, p(null, String.valueOf(h), "1", null).wipeMs);
            eq("wipe " + h + " saved=1 onsave", true, p(null, String.valueOf(h), "1", null).wipeOnSave);
            eq("wipe " + h + " saved= ms", h * 3_600_000L, p(null, String.valueOf(h), "", null).wipeMs);
            eq("wipe " + h + " saved= onsave", false, p(null, String.valueOf(h), "", null).wipeOnSave);
        }
        // Unset, empty and junk: the passed default, for idle and for wipe.
        for (String s : new String[] { null, "", "abc", "5m", "1.5" }) {
            eq("idle [" + s + "] default", D_IDLE, p(s, null, null, null).idleMs);
            eq("wipe [" + s + "] default", D_WIPE, p(null, s, null, null).wipeMs);
        }
        // holdlock: only "0" turns it off.
        eq("holdlock 0", false, p(null, null, null, "0").holdLock);
        eq("holdlock empty", true, p(null, null, null, "").holdLock);
        eq("holdlock unset", true, p(null, null, null, null).holdLock);
        eq("holdlock 1", true, p(null, null, null, "1").holdLock);
        // holdaudio (NWP-20261124-17): only "0" turns it off, and it is read apart from holdlock.
        eq("holdaudio 0", false, p(null, null, null, null, "0").holdAudio);
        eq("holdaudio empty", true, p(null, null, null, null, "").holdAudio);
        eq("holdaudio unset", true, p(null, null, null, null, null).holdAudio);
        eq("holdaudio 1", true, p(null, null, null, null, "1").holdAudio);
        eq("holdaudio 0 leaves holdlock", true, p(null, null, null, null, "0").holdLock);
        eq("holdlock 0 leaves holdaudio", true, p(null, null, null, "0", null).holdAudio);
        // wipesaved: WipeOnSave.on's rule.
        for (String s : new String[] { null, "", "0", "2" }) eq("wipesaved [" + s + "]", false, p(null, null, s, null).wipeOnSave);
        eq("wipesaved 1", true, p(null, null, "1", null).wipeOnSave);
        eq("wipesaved ' 1 '", true, p(null, null, " 1 ", null).wipeOnSave);
        // The defaults are the ones passed in, not constants of RoamedPrefs.
        RoamedPrefs.Values none = p(null, null, null, null);
        eq("all unset idle", D_IDLE, none.idleMs);
        eq("all unset wipe", D_WIPE, none.wipeMs);
        eq("all unset onsave", false, none.wipeOnSave);
        eq("all unset hold", true, none.holdLock);
        eq("all unset audio", true, none.holdAudio);
        RoamedPrefs.Values other = RoamedPrefs.parse(null, null, null, null, null, 7L, 9L);
        eq("second defaults idle", 7L, other.idleMs);
        eq("second defaults wipe", 9L, other.wipeMs);
        if (fails > 0) { System.out.println("FAIL: " + fails + " case(s)"); System.exit(1); }
        System.out.println("PASS: RoamedPrefs cases");
    }
}
