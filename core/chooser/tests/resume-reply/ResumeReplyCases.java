package com.nowhere.chooser;

/** NWP-20261109-19: the RESUME reply verdict, run against the real ResumeReply.java. Exit 1 on any failed case.
 *  With "--kinds tok..." it prints "tok<TAB>KIND[<TAB>uid]" per token instead (the suite's cross-side check). */
public class ResumeReplyCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("  FAIL " + what); } else System.out.println("  ok   " + what);
    }

    static String kindName(int k) {
        switch (k) {
            case ResumeReply.SWITCH: return "SWITCH";
            case ResumeReply.GONE: return "GONE";
            case ResumeReply.RESTORE_FAILED: return "RESTORE_FAILED";
            case ResumeReply.NEEDKEY: return "NEEDKEY";
            case ResumeReply.WRONG: return "WRONG";
            case ResumeReply.RETRY: return "RETRY";
            case ResumeReply.NOTMPFS: return "NOTMPFS";
            default: return "?" + k;
        }
    }

    static void is(String in, int kind, int uid) {
        ResumeReply.Verdict v = ResumeReply.of(in);
        check(v.kind == kind && v.uid == uid, (in == null ? "null" : "\"" + in.replace("\r", "\\r") + "\"")
                + " -> " + kindName(kind) + (kind == ResumeReply.SWITCH ? " " + uid : "")
                + " (got " + kindName(v.kind) + " " + v.uid + ")");
    }

    static void is(String in, int kind) { is(in, kind, -1); }

    public static void main(String[] a) {
        if (a.length > 0 && a[0].equals("--kinds")) {
            for (int i = 1; i < a.length; i++) {
                ResumeReply.Verdict v = ResumeReply.of(a[i]);
                System.out.println(a[i] + "\t" + kindName(v.kind) + (v.kind == ResumeReply.SWITCH ? "\t" + v.uid : ""));
            }
            return;
        }
        is("OK 12", ResumeReply.SWITCH, 12);
        is(" OK 12\r", ResumeReply.SWITCH, 12);
        is("OK", ResumeReply.RETRY);
        is("OK x", ResumeReply.RETRY);
        is("OK 0", ResumeReply.RETRY);
        is("OK -3", ResumeReply.RETRY);
        is("NONE", ResumeReply.GONE);
        is("ERR-RESTORE", ResumeReply.RESTORE_FAILED);
        is("NEEDKEY", ResumeReply.NEEDKEY);
        is("WRONGPASS", ResumeReply.WRONG);
        is("ERR-WORKER-BUSY", ResumeReply.RETRY);
        is("", ResumeReply.RETRY);
        is(null, ResumeReply.RETRY);
        is("WRONGPASSX", ResumeReply.RETRY);
        is("NONEX", ResumeReply.RETRY);
        is("ERR", ResumeReply.RETRY);
        // NWP-20261117-12 (#30): the dispatch's refusal when the state dir is not a tmpfs; exact, like every token.
        is("ERR-NOTMPFS", ResumeReply.NOTMPFS);
        is(" ERR-NOTMPFS\r", ResumeReply.NOTMPFS);
        is("ERR-NOTMPFSX", ResumeReply.RETRY);
        System.out.println(fails == 0 ? "all cases ok" : fails + " case(s) FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
