package com.nowhere.chooser;

/** NWP-20261126-10: the pure decision of RestartRearm (core/vendor-common/bin/test-restart-rearm-java.sh). */
final class RestartRearmCases {
    private static int fails = 0;

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) fails++;
    }

    private static boolean same(String[] got, String... want) {
        return java.util.Arrays.equals(got, want);
    }

    public static void main(String[] args) {
        check("R1 shouldAsk(true, 10, true) asks", RestartRearm.Rule.shouldAsk(true, 10, true));
        check("R1 shouldAsk(true, 11, true) asks", RestartRearm.Rule.shouldAsk(true, 11, true));
        check("R2 shouldAsk is false when the session is not live", !RestartRearm.Rule.shouldAsk(false, 10, true));
        check("R3 shouldAsk is false for user 0", !RestartRearm.Rule.shouldAsk(true, 0, true));
        check("R3 shouldAsk is false for user -1", !RestartRearm.Rule.shouldAsk(true, -1, true));
        check("R4 shouldAsk is false when the current user is locked", !RestartRearm.Rule.shouldAsk(true, 10, false));
        check("W  WAIT_MS is 120 s and POLL_MS is 2 s",
                RestartRearm.Rule.WAIT_MS == 120_000L && RestartRearm.Rule.POLL_MS == 2_000L);

        String fixture = "idle=30\nwipe=0\nwipesaved=1\nholdlock=0\nholdaudio=1\n";
        check("R5 extras reads idle, wipe, wipesaved, holdlock, holdaudio in order",
                same(RestartRearm.Rule.extras(fixture), "30", "0", "1", "0", "1"));
        check("R5 extras maps by key, not by line order",
                same(RestartRearm.Rule.extras("holdaudio=1\nholdlock=0\nwipesaved=1\nwipe=0\nidle=30\n"),
                        "30", "0", "1", "0", "1"));
        check("R5 the first match wins",
                same(RestartRearm.Rule.extras("idle=30\nidle=5\nholdaudio=1\nholdaudio=0\n"), "30", "", "", "", "1"));
        check("R5 an absent key reads as absent",
                same(RestartRearm.Rule.extras("idle=30\n"), "30", "", "", "", ""));
        check("R5 an empty text reads every value absent",
                same(RestartRearm.Rule.extras(""), "", "", "", "", ""));
        check("R5 the wipesaved key is WipeOnSave.PREF", "wipesaved".equals(WipeOnSave.PREF)
                && same(RestartRearm.Rule.extras(WipeOnSave.PREF + "=1\n"), "", "", "1", "", ""));

        if (fails > 0) {
            System.out.println("FAILED: " + fails + " case(s)");
            System.exit(1);
        }
        System.out.println("cases: ok");
    }
}
