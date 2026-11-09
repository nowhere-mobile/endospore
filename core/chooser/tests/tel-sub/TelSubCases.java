package com.nowhere.chooser;

import android.content.ContentValues;
import java.util.Arrays;
import java.util.List;

// TelSubCases -- NWP-20261130-01: the SIM tag -> subscription mapping, the fallback, the read-back's blind rule, the ack
// rule and the batch line, run against the real TelSub.java. Exit 1 on any failure.
public class TelSubCases {
    static int fails = 0;

    static void eq(String what, Object want, Object got) {
        boolean ok = want == null ? got == null : want.equals(got);
        if (!ok) { fails++; System.out.println("FAIL " + what + ": want " + want + " got " + got); }
        else System.out.println("ok   " + what);
    }

    static final String ICCID_A = "89014103211118510720", ICCID_B = "89440000000000000022";
    static final String GOLDEN = "cb8e5339c47c9acc"; // core/agent TestSimTagGoldenVector holds the same answer
    static final TelSub.Sims TWO = new TelSub.Sims(new int[]{3, 7}, new String[]{ICCID_A, ICCID_B});

    static String[] row(String s) { return s.split(" "); }

    public static void main(String[] a) {
        // the tag: the same answer as the agent, with and without the filler nibble
        eq("golden", GOLDEN, TelSub.simTag(ICCID_A));
        eq("golden, f filler", GOLDEN, TelSub.simTag(ICCID_A + "f"));
        eq("golden, F filler and spaces", GOLDEN, TelSub.simTag(" " + ICCID_A + "F "));

        // the mapping
        eq("match", 3, TelSub.subFor(GOLDEN, TWO));
        eq("two SIMs, the other tag", 7, TelSub.subFor(TelSub.simTag(ICCID_B), TWO));
        eq("two SIMs in the other order", 7, TelSub.subFor(TelSub.simTag(ICCID_B),
                new TelSub.Sims(new int[]{7, 3}, new String[]{ICCID_B, ICCID_A})));
        eq("no match", TelSub.NO_SUB, TelSub.subFor("0123456789abcdef", TWO));
        eq("untagged", TelSub.NO_SUB, TelSub.subFor(null, TWO));
        eq("no SIMs", TelSub.NO_SUB, TelSub.subFor(GOLDEN, TelSub.Sims.NONE));
        TelSub.Sims unread = new TelSub.Sims(new int[]{4, 5, 6}, new String[]{null, "", "F"});
        eq("a null ICCID matches nothing", TelSub.NO_SUB, TelSub.subFor(GOLDEN, unread));
        eq("an empty ICCID's own tag matches nothing", TelSub.NO_SUB, TelSub.subFor(TelSub.simTag(""), unread));
        eq("an unread SIM does not stop the search", 8, TelSub.subFor(GOLDEN,
                new TelSub.Sims(new int[]{4, 8}, new String[]{null, ICCID_A})));

        // the row's slot: its own position only, the agent's rowTag
        String slot = "sim:" + GOLDEN;
        eq("sms tag", GOLDEN, TelSub.rowTag(row("sms 1 0 0 KzE aGk= " + slot)));
        eq("sms tag, retry", GOLDEN, TelSub.rowTag(row("sms 1 0 0 KzE aGk= " + slot + " 2")));
        eq("mms tag", GOLDEN, TelSub.rowTag(row("mms 1 e30= " + slot)));
        eq("mms tag, retry", GOLDEN, TelSub.rowTag(row("mms 1 e30= " + slot + " 2")));
        eq("sms untagged", null, TelSub.rowTag(row("sms 1 0 0 KzE aGk=")));
        eq("sms untagged, retry", null, TelSub.rowTag(row("sms 1 0 0 KzE aGk= 2")));
        eq("mms untagged", null, TelSub.rowTag(row("mms 1 e30=")));
        eq("mms untagged, retry", null, TelSub.rowTag(row("mms 1 e30= 1")));
        eq("sms, the slot after a retry", null, TelSub.rowTag(row("sms 1 0 0 KzE aGk= 1 " + slot)));
        eq("mms, the slot after a retry", null, TelSub.rowTag(row("mms 1 e30= 1 " + slot)));
        eq("sms, a bad tag", null, TelSub.rowTag(row("sms 1 0 0 KzE aGk= sim:zz")));
        eq("mms, upper case", null, TelSub.rowTag(row("mms 1 e30= sim:ABCDEF0123456789")));
        eq("call row", null, TelSub.rowTag(row("call 1 3 0 KzE -" + GOLDEN)));
        eq("call row with a slot", null, TelSub.rowTag(row("call 1 3 0 KzE - " + slot)));

        // what the insert carries
        ContentValues v = new ContentValues();
        eq("file returns the mapped sub", 3, TelSub.file(v, GOLDEN, TWO));
        eq("file puts the mapped sub", 3, v.get("sub_id"));
        v = new ContentValues();
        eq("file, the other SIM", 7, TelSub.file(v, TelSub.simTag(ICCID_B), TWO));
        eq("file puts the other SIM's sub", 7, v.get("sub_id"));
        v = new ContentValues();
        eq("fallback: file returns -1", -1, TelSub.file(v, "0123456789abcdef", TWO));
        eq("fallback: file puts -1", -1, v.get("sub_id"));
        v = new ContentValues();
        eq("untagged row: file returns -1", -1, TelSub.file(v, null, TWO));
        eq("untagged row: file puts -1", -1, v.get("sub_id"));

        // the duplicate check: a blind reader's answer means nothing
        eq("blind, empty cursor", null, TelSub.lookup(false, Boolean.FALSE));
        eq("blind, found", null, TelSub.lookup(false, Boolean.TRUE));
        eq("blind, failed", null, TelSub.lookup(false, null));
        eq("seeing, found", Boolean.TRUE, TelSub.lookup(true, Boolean.TRUE));
        eq("seeing, absent", Boolean.FALSE, TelSub.lookup(true, Boolean.FALSE));
        eq("seeing, failed", null, TelSub.lookup(true, null));

        // the ack: an SMS or MMS only on a read-back, a call as before
        eq("sms landed, not read back", false, TelSub.ackable("sms", true, false));
        eq("sms read back", true, TelSub.ackable("sms", true, true));
        eq("mms landed, not read back", false, TelSub.ackable("mms", true, false));
        eq("mms read back", true, TelSub.ackable("mms", true, true));
        eq("sms never landed", false, TelSub.ackable("sms", false, false));
        eq("call landed", true, TelSub.ackable("call", true, false));
        eq("call not landed", false, TelSub.ackable("call", false, false));

        List<String> reply = Arrays.asList("OK", "sms 1 x", "mms 2 x", "call 3 x", "sms 4 x", "sms 5 x");
        boolean[] everOk = {false, true, true, true, true, false};
        boolean[] readOk = {false, true, false, false, false, false};
        eq("not read back: landed sms and mms only", 2, TelSub.notReadBack(reply, everOk, readOk));

        // the batch line
        TelSub.Tally t = new TelSub.Tally();
        t.inserted(3);
        t.inserted(7);
        t.inserted(TelSub.NO_SUB);
        eq("tally delivered", 3, t.delivered);
        eq("tally real", 2, t.real);
        eq("tally fell back", 1, t.fellBack);
        eq("batch line", "telingest batch: delivered=3 real-sub=2 fell-back=1 not-read-back=4", t.line(false, 4));
        eq("batch line, live", "telingest (live) batch: delivered=3 real-sub=2 fell-back=1 not-read-back=0", t.line(true, 0));

        if (fails > 0) { System.out.println(fails + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
