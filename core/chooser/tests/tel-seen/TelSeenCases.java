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

    /** C6: a fresh TelSeen with defaultSms set, one mmsDefault call, "offDefault defaultAway". */
    static String def(int defaultSms, int filedSub, int[] sessionSubs) {
        TelSeen s = new TelSeen();
        s.defaultSms = defaultSms;
        s.mmsDefault(filedSub, sessionSubs);
        return s.mmsOffDefault + " " + s.mmsDefaultAway;
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
        eq("C1", "a re-inserted row", "2 0 1 0 0 0 0 0 0", s.line());
        java.util.List<Long> smsOrder = new java.util.ArrayList<>();
        for (long w : s.sms) smsOrder.add(w);
        eq("C1", "insertion order", java.util.Arrays.asList(9L, 5L), smsOrder);
        report("C1"); bad |= failed; failed = false;

        // C2: TRUE counts nothing, FALSE is hidden in its own kind, null is unknown only.
        s = new TelSeen();
        s.readBack("sms", Boolean.TRUE); s.readBack("mms", Boolean.TRUE);
        eq("C2", "TRUE", "0 0 0 0 0 0 0 0 0", s.line());
        s = new TelSeen();
        s.readBack("sms", Boolean.FALSE);
        eq("C2", "sms FALSE", "0 1 0 0 0 0 0 0 0", s.line());
        s = new TelSeen();
        s.readBack("mms", Boolean.FALSE);
        eq("C2", "mms FALSE", "0 0 0 1 0 0 0 0 0", s.line());
        s = new TelSeen();
        s.readBack("sms", null); s.readBack("mms", null);
        eq("C2", "null", "0 0 0 0 2 0 0 0 0", s.line());
        report("C2"); bad |= failed; failed = false;

        // C3: only a false addr or part counts, and it alone makes any() true.
        s = new TelSeen();
        s.addr(true); s.part(true);
        eq("C3", "true counts nothing", "0 0 0 0 0 0 0 0 0", s.line());
        eq("C3", "any() after true alone", Boolean.FALSE, s.any());
        s = new TelSeen();
        s.addr(false);
        eq("C3", "addr false", "0 0 0 0 0 1 0 0 0", s.line());
        eq("C3", "any() after addr false alone", Boolean.TRUE, s.any());
        s = new TelSeen();
        s.part(false); s.part(false);
        eq("C3", "part false", "0 0 0 0 0 0 2 0 0", s.line());
        eq("C3", "any() after part false alone", Boolean.TRUE, s.any());
        report("C3"); bad |= failed; failed = false;

        // C4: nine numbers, digits and single spaces only, each clamped to 0..99999.
        s = new TelSeen();
        for (long w = 0; w < 100000L; w++) { s.inserted("sms", w); s.inserted("mms", w); }
        s.smsHidden = 100000; s.mmsHidden = 100000; s.unknown = 100000; s.addrNotInserted = 100000; s.partsNotInserted = 100000;
        s.mmsOffDefault = 100000; s.mmsDefaultAway = 100000;
        eq("C4", "100000 in every field", "99999 99999 99999 99999 99999 99999 99999 99999 99999", s.line());
        s = new TelSeen();
        s.smsHidden = -1; s.mmsHidden = -1; s.unknown = -1; s.addrNotInserted = -1; s.partsNotInserted = -1;
        s.mmsOffDefault = -1; s.mmsDefaultAway = -1;
        eq("C4", "a negative field", "0 0 0 0 0 0 0 0 0", s.line());
        s = hiddenSms();
        eq("C4", "the shape of the line", Boolean.TRUE, s.line().matches("[0-9]+( [0-9]+){8}"));
        report("C4"); bad |= failed; failed = false;

        // C5: a live run never sends; a non-live run sends only when it has something to say.
        eq("C5", "sends(true, null)", Boolean.FALSE, TelSeen.sends(true, null));
        eq("C5", "sends(true, empty)", Boolean.FALSE, TelSeen.sends(true, new TelSeen()));
        eq("C5", "sends(true, one hidden sms)", Boolean.FALSE, TelSeen.sends(true, hiddenSms()));
        eq("C5", "sends(false, null)", Boolean.FALSE, TelSeen.sends(false, null));
        eq("C5", "sends(false, empty)", Boolean.FALSE, TelSeen.sends(false, new TelSeen()));
        eq("C5", "sends(false, one hidden sms)", Boolean.TRUE, TelSeen.sends(false, hiddenSms()));
        report("C5"); bad |= failed; failed = false;

        // C6 (NWP-20261204-11): mmsDefault against the default SMS subscription run read; -1 counts nothing.
        eq("C6", "no default, filed in session", "0 0", def(-1, 3, new int[] {3}));
        eq("C6", "no default, empty session", "0 0", def(-1, 3, new int[0]));
        eq("C6", "no default, null session", "0 0", def(-1, 3, null));
        eq("C6", "default == filed, in session", "0 0", def(3, 3, new int[] {2, 3}));
        eq("C6", "default != filed, in session", "1 0", def(3, 2, new int[] {2, 3}));
        eq("C6", "default == filed, not in session", "0 1", def(3, 3, new int[] {2}));
        eq("C6", "default 3, null session", "0 1", def(3, 3, null));
        eq("C6", "a fallback row (-1) with a valid default", "1 0", def(3, -1, new int[] {3}));
        eq("C6", "default 0 is a valid id", "0 0", def(0, 0, new int[] {0}));
        eq("C6", "default 0, filed 1, session without 0", "1 1", def(0, 1, new int[] {1}));
        s = new TelSeen();
        s.defaultSms = 3;
        s.mmsDefault(2, new int[] {2});
        eq("C6", "line() carries off-default then away last", "0 0 0 0 0 0 0 1 1", s.line());
        eq("C6", "any() unchanged: mmsDefault alone says nothing", Boolean.FALSE, s.any());
        report("C6"); bad |= failed; failed = false;

        System.exit(bad ? 1 : 0);
    }
}
