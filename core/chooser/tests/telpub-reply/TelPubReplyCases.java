package com.nowhere.chooser;

/** Cases for TelPubReply.classify (NWP-20261120-13). An exception in a case is a FAIL, not a crash. */
public final class TelPubReplyCases {
    private static int failed = 0, ran = 0;

    private static void expect(String name, String want, String reply) {
        ran++;
        try {
            String got = TelPubReply.classify(reply);
            if (!want.equals(got)) {
                failed++;
                System.out.println("--- FAIL " + name + ": want " + want + " got " + got);
            }
        } catch (Throwable t) {
            failed++;
            System.out.println("--- FAIL " + name + " threw " + t);
        }
    }

    public static void main(String[] args) {
        expect("an OK line is OK", "OK", "OK cHVia2V5 refv2abc\n");
        expect("OK with no space is not the OK prefix", "NONE", "OK");
        expect("OKAY is not the OK prefix", "NONE", "OKAY x\n");
        expect("NOKEY is NOKEY", "NOKEY", "NOKEY\n");
        expect("ERR-NET with its newline is NET", "NET", "ERR-NET\n");
        expect("bare ERR-NET is NET", "NET", "ERR-NET");
        expect("ERR-NETWORK is not ERR-NET", "NONE", "ERR-NETWORK\n");
        expect("ERR-NET with a field is not ERR-NET", "NONE", "ERR-NET x\n");
        expect("ERR is not ERR-NET", "NONE", "ERR\n");
        expect("NONE is NONE", "NONE", "NONE\n");
        expect("NOSTORE is blind NONE", "NONE", "NOSTORE\n");
        expect("BLANK is blind NONE", "NONE", "BLANK\n");
        expect("no reply (null) is NONE", "NONE", null);
        expect("an empty reply is NONE", "NONE", "");
        expect("garbage is NONE", "NONE", "garbage");
        System.out.println(ran + " cases, " + failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
