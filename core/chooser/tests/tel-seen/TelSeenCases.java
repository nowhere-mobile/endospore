package com.nowhere.chooser;

/** NWP-20261129-02: test-tel-seen-java.sh compiles this with TelSeen.java, ALONE, and runs it. */
public final class TelSeenCases {
    static boolean failed = false;

    static void eq(String id, String what, Object want, Object got) {
        if (want.equals(got)) {
            return;
        }
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        failed = true;
    }

    static TelSeen hiddenSms() {
        TelSeen s = new TelSeen();
        s.inserted("sms", 7L);
        s.readBack("sms", Boolean.FALSE);
        return s;
    }

    static void report(String id) {
        if (!failed) System.out.println("ok " + id);
    }

    public static void main(String[] a) {
        boolean bad = false;

        // C1: a row counts once however many passes insert it, per kind, in arrival order.
        TelSeen s = new TelSeen();
        s.inserted("sms", 9L); s.inserted("sms", 5L); s.inserted("sms", 9L);
        s.inserted("mms", 9L); s.inserted("mms", 9L);
        eq("C1", "a re-inserted row", "2 0 1 0 0 0 0", s.line());
        java.util.List<Long> smsOrder = new java.util.ArrayList<>();
        for (long w : s.sms) smsOrder.add(w);
        eq("C1", "insertion order", java.util.Arrays.asList(9L, 5L), smsOrder);
        report("C1"); bad |= failed; failed = false;

        // C2: TRUE counts nothing, FALSE is hidden in its own kind, null is unknown only.
        s = new TelSeen();
        s.readBack("sms", Boolean.TRUE); s.readBack("mms", Boolean.TRUE);
        eq("C2", "TRUE", "0 0 0 0 0 0 0", s.line());
        s = new TelSeen();
        s.readBack("sms", Boolean.FALSE);
        eq("C2", "sms FALSE", "0 1 0 0 0 0 0", s.line());
        s = new TelSeen();
        s.readBack("mms", Boolean.FALSE);
        eq("C2", "mms FALSE", "0 0 0 1 0 0 0", s.line());
        s = new TelSeen();
        s.readBack("sms", null); s.readBack("mms", null);
        eq("C2", "null", "0 0 0 0 2 0 0", s.line());
        report("C2"); bad |= failed; failed = false;

        // C3: only a false addr or part counts, and it alone makes any() true.
        s = new TelSeen();
        s.addr(true); s.part(true);
        eq("C3", "true counts nothing", "0 0 0 0 0 0 0", s.line());
        eq("C3", "any() after true alone", Boolean.FALSE, s.any());
        s = new TelSeen();
        s.addr(false);
        eq("C3", "addr false", "0 0 0 0 0 1 0", s.line());
        eq("C3", "any() after addr false alone", Boolean.TRUE, s.any());
        s = new TelSeen();
        s.part(false); s.part(false);
        eq("C3", "part false", "0 0 0 0 0 0 2", s.line());
        eq("C3", "any() after part false alone", Boolean.TRUE, s.any());
        report("C3"); bad |= failed; failed = false;

        // C4: seven numbers, digits and single spaces only, each clamped to 0..99999.
        s = new TelSeen();
        for (long w = 0; w < 100000L; w++) { s.inserted("sms", w); s.inserted("mms", w); }
        s.smsHidden = 100000; s.mmsHidden = 100000; s.unknown = 100000; s.addrNotInserted = 100000; s.partsNotInserted = 100000;
        eq("C4", "100000 in every field", "99999 99999 99999 99999 99999 99999 99999", s.line());
        s = new TelSeen();
        s.smsHidden = -1; s.mmsHidden = -1; s.unknown = -1; s.addrNotInserted = -1; s.partsNotInserted = -1;
        eq("C4", "a negative field", "0 0 0 0 0 0 0", s.line());
        s = hiddenSms();
        eq("C4", "the shape of the line", Boolean.TRUE, s.line().matches("[0-9]+( [0-9]+){6}"));
        report("C4"); bad |= failed; failed = false;

        // C5: a live run never sends; a non-live run sends only when it has something to say.
        eq("C5", "sends(true, null)", Boolean.FALSE, TelSeen.sends(true, null));
        eq("C5", "sends(true, empty)", Boolean.FALSE, TelSeen.sends(true, new TelSeen()));
        eq("C5", "sends(true, one hidden sms)", Boolean.FALSE, TelSeen.sends(true, hiddenSms()));
        eq("C5", "sends(false, null)", Boolean.FALSE, TelSeen.sends(false, null));
        eq("C5", "sends(false, empty)", Boolean.FALSE, TelSeen.sends(false, new TelSeen()));
        eq("C5", "sends(false, one hidden sms)", Boolean.TRUE, TelSeen.sends(false, hiddenSms()));
        report("C5"); bad |= failed; failed = false;

        System.exit(bad ? 1 : 0);
    }
}
