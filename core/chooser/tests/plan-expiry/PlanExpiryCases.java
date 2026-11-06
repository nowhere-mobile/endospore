package com.nowhere.chooser;

import java.text.DateFormat;
import java.util.Locale;
import java.util.TimeZone;

/** NWP-20261118-08: the cases for PlanExpiry (run by core/vendor-common/bin/test-plan-expiry-java.sh). */
public class PlanExpiryCases {
    static int pass = 0, fail = 0;

    static void eq(String what, Object want, Object got) {
        if (want.equals(got)) { pass++; System.out.println("  ok    " + what); }
        else { fail++; System.out.println("  FAIL  " + what + ": want " + want + ", got " + got); }
    }

    // Day 20400 is 2025-11-08 (UTC). Every date below is a literal, worked out with `date -u`, never with df.
    static final long D = 20400, NOW = D * 86400 + 3600, ENT = 53687091200L;
    static final String KEEP = " Start or extend a plan in Profile › Storage to keep your data.";

    static String live(long left, String extra) {
        return "OK credit=0 through=" + (D + left) + " epochsec=86400 sub=0" + extra;
    }

    static String grace(String extra) { return "OK credit=0 through=" + (D - 3) + " epochsec=86400 sub=0" + extra; }

    public static void main(String[] a) {
        final DateFormat df = DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.US);
        df.setTimeZone(TimeZone.getTimeZone("UTC"));

        eq("left 31 -> NONE", PlanExpiry.NONE, PlanExpiry.stage(live(31, ""), ENT, NOW));
        eq("left 30 -> SOON", PlanExpiry.SOON, PlanExpiry.stage(live(30, ""), ENT, NOW));
        eq("left 8 -> SOON", PlanExpiry.SOON, PlanExpiry.stage(live(8, ""), ENT, NOW));
        eq("left 7 -> WEEK", PlanExpiry.WEEK, PlanExpiry.stage(live(7, ""), ENT, NOW));
        eq("left 1 -> WEEK", PlanExpiry.WEEK, PlanExpiry.stage(live(1, ""), ENT, NOW));
        eq("left 0 -> TODAY", PlanExpiry.TODAY, PlanExpiry.stage(live(0, ""), ENT, NOW));
        eq("left 7, entitled -1 (the gateway did not answer) -> NONE", PlanExpiry.NONE, PlanExpiry.stage(live(7, ""), -1, NOW));
        eq("left 7, entitled 0 (Storage's stranger arm) -> NONE", PlanExpiry.NONE, PlanExpiry.stage(live(7, ""), 0, NOW));
        eq("left 7, pending=1 -> NONE", PlanExpiry.NONE, PlanExpiry.stage(live(7, " pending=1"), ENT, NOW));
        eq("left 7, moving=<unix> -> NONE", PlanExpiry.NONE, PlanExpiry.stage(live(7, " moving=" + (NOW - 60)), ENT, NOW));
        eq("reply NONE -> NONE", PlanExpiry.NONE, PlanExpiry.stage("NONE", ENT, NOW));
        eq("null reply -> NONE", PlanExpiry.NONE, PlanExpiry.stage(null, ENT, NOW));
        eq("OK with through=0 -> NONE", PlanExpiry.NONE, PlanExpiry.stage("OK credit=0 through=0 epochsec=86400 sub=0", ENT, NOW));
        eq("OK with epochsec=0 -> NONE", PlanExpiry.NONE, PlanExpiry.stage("OK credit=0 through=" + D + " epochsec=0 sub=0", ENT, NOW));
        eq("epochsec absent counts in 604800 epochs -> WEEK", PlanExpiry.WEEK,
                PlanExpiry.stage("OK credit=0 through=" + (NOW / 604800 + 7) + " sub=0", ENT, NOW));
        eq("epochsec absent, 31 weeks left -> NONE", PlanExpiry.NONE,
                PlanExpiry.stage("OK credit=0 through=" + (NOW / 604800 + 31) + " sub=0", ENT, NOW));

        eq("grace, entitled 0, deadline ahead -> GRACE", PlanExpiry.GRACE, PlanExpiry.stage(grace(" deadline=" + (D + 27)), 0, NOW));
        eq("grace, entitled 0, deadline today -> GRACE", PlanExpiry.GRACE, PlanExpiry.stage(grace(" deadline=" + D), 0, NOW));
        eq("grace, deadline absent -> NONE", PlanExpiry.NONE, PlanExpiry.stage(grace(""), 0, NOW));
        eq("grace, deadline passed -> NONE", PlanExpiry.NONE, PlanExpiry.stage(grace(" deadline=" + (D - 1)), 0, NOW));
        eq("grace, entitled > 0 (a plan this wallet does not hold) -> NONE", PlanExpiry.NONE,
                PlanExpiry.stage(grace(" deadline=" + (D + 27)), ENT, NOW));
        eq("grace, entitled -1 -> NONE", PlanExpiry.NONE, PlanExpiry.stage(grace(" deadline=" + (D + 27)), -1, NOW));
        eq("grace, pending=1 -> NONE", PlanExpiry.NONE, PlanExpiry.stage(grace(" deadline=" + (D + 27) + " pending=1"), 0, NOW));

        // NOWHERE-1313: a store-refused footprint surfaces as an error from GET-ENTITLEMENT; that is unanswered.
        eq("entitled(ERR store refused) -> -1", -1L, PlanExpiry.entitled("ERR store refused"));
        eq("store-refused entitlement in grace -> NONE", PlanExpiry.NONE,
                PlanExpiry.stage(grace(" deadline=" + (D + 27)), PlanExpiry.entitled("ERR store refused"), NOW));
        eq("store-refused entitlement at left 7 -> NONE", PlanExpiry.NONE,
                PlanExpiry.stage(live(7, ""), PlanExpiry.entitled("ERR store refused"), NOW));
        eq("entitled(OK ...) -> the value", ENT,
                PlanExpiry.entitled("OK used=1 free=1073741824 entitled=53687091200 covered=1"));
        eq("entitled(OK ... entitled=0) -> 0", 0L, PlanExpiry.entitled("OK used=1 free=1073741824 entitled=0 covered=1"));
        eq("entitled(NONE) -> -1", -1L, PlanExpiry.entitled("NONE"));
        eq("entitled(LOCAL) -> -1", -1L, PlanExpiry.entitled("LOCAL"));
        eq("entitled(UNKNOWN) -> -1", -1L, PlanExpiry.entitled("UNKNOWN"));
        eq("entitled(\"\") (no reply in the bound) -> -1", -1L, PlanExpiry.entitled(""));
        eq("entitled(null) -> -1", -1L, PlanExpiry.entitled(null));
        eq("entitled(OK entitled=abc) -> -1", -1L, PlanExpiry.entitled("OK used=1 entitled=abc"));
        eq("entitled(OK without entitled=) -> -1", -1L, PlanExpiry.entitled("OK used=1 free=2"));

        eq("first check 10 min after a sign-in", 600000L, PlanExpiry.PLAN_FIRST_DELAY_MS);
        eq("recheck 24 h after an answered check", 86400000L, PlanExpiry.PLAN_RECHECK_MS);
        eq("retry 1 h after an unanswered check", 3600000L, PlanExpiry.PLAN_RETRY_MS);

        eq("title, left 30", "Your plan ends in 30 days", PlanExpiry.title(live(30, " plangb=50"), NOW, df));
        eq("text, left 30, 50 GB", "Your 50 GB plan expires Dec 9, 2025." + KEEP, PlanExpiry.text(live(30, " plangb=50"), NOW, df));
        eq("title, left 7", "Your plan ends in 7 days", PlanExpiry.title(live(7, ""), NOW, df));
        eq("title, left 1", "Your plan ends in 1 day", PlanExpiry.title(live(1, ""), NOW, df));
        eq("text, left 1, no plangb", "Your plan expires Nov 10, 2025." + KEEP, PlanExpiry.text(live(1, ""), NOW, df));
        eq("title, left 0", "Your plan ends today", PlanExpiry.title(live(0, " plangb=50"), NOW, df));
        eq("text, left 0, 50 GB", "Your 50 GB plan expires today." + KEEP, PlanExpiry.text(live(0, " plangb=50"), NOW, df));
        eq("title, grace", "Your plan has expired", PlanExpiry.title(grace(" deadline=" + (D + 27) + " plangb=50"), NOW, df));
        eq("text, grace", "Your plan expired Nov 6, 2025. Your data is kept until Dec 6, 2025. After that it is deleted, "
                + "unless it fits the free 1 GB — then it stays as a free profile. Over 1 GB, nothing new can be added "
                + "until you start a plan.", PlanExpiry.text(grace(" deadline=" + (D + 27) + " plangb=50"), NOW, df));
        eq("title, NONE reply -> \"\"", "", PlanExpiry.title("NONE", NOW, df));
        eq("text, NONE reply -> \"\"", "", PlanExpiry.text("NONE", NOW, df));

        System.out.println(fail == 0 ? "all cases ok (" + pass + ")" : fail + " case(s) FAILED");
        if (fail != 0) System.exit(1);
    }
}
