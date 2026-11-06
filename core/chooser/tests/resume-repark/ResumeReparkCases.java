package com.nowhere.chooser;

/** NWP-20261111-12: the failed-switch re-park's reply reading, run against the real ResumeRepark.java. Exit 1 on any
 *  failed case. */
public class ResumeReparkCases {
    static int fails = 0;

    static void check(boolean ok, String what) {
        if (!ok) { fails++; System.out.println("  FAIL " + what); } else System.out.println("  ok   " + what);
    }

    static void landed(String in, boolean want) {
        boolean got = ResumeRepark.landed(in);
        check(got == want, "landed(" + (in == null ? "null" : "\"" + in.replace("\r", "\\r").replace("\n", "\\n") + "\"")
                + ") == " + want + " (got " + got + ")");
    }

    public static void main(String[] args) {
        landed("OK LOCKING", true);
        landed("OK LOCKING\r", true);
        landed(" OK LOCKING \n", true);
        landed("OK NOSESSION", false);
        landed("OK LOGOFF", false);
        landed("OK", false);
        landed("", false);
        landed(null, false);
        landed("OK LOCKINGX", false);
        landed("ok locking", false);
        String t = ResumeRepark.failedSwitchLine(true);
        check("Couldn't open your session. It's locked again; try again.".equals(t), "failedSwitchLine(true) -> [" + t + "]");
        String f = ResumeRepark.failedSwitchLine(false);
        check("couldn't resume \u2014 try again".equals(f), "failedSwitchLine(false) -> [" + f + "]");
        if (fails > 0) { System.out.println("  " + fails + " case(s) failed"); System.exit(1); }
    }
}
