// NWP-20261012-05, -08, NWP-20261102-10 (the carry for every permission, Q059): cases for PermDeclines' PURE block, run by run.sh against the lifted class. The parse cases mirror
// core/vendor-common/bin/test-grant-declined-flags.sh D6: the chooser's re-apply after a role add must honour exactly
// the lines roamd's declined pass honours, and refuse exactly the ones it refuses.
import java.util.List;

final class Cases {
    private static int pass, fail;

    private static void check(boolean cond, String what) {
        if (cond) { pass++; System.out.println("  ok    " + what); }
        else { fail++; System.out.println("  FAIL  " + what); }
    }

    private static String show(List<String[]> l) {
        StringBuilder b = new StringBuilder("[");
        for (String[] d : l) b.append(d[0]).append('/').append(d[1]).append(' ');
        return b.append(']').toString();
    }

    private static boolean is(List<String[]> l, String... permWord) {
        if (l.size() * 2 != permWord.length) return false;
        for (int i = 0; i < l.size(); i++)
            if (!l.get(i)[0].equals(permWord[2 * i]) || !l.get(i)[1].equals(permWord[2 * i + 1])) return false;
        return true;
    }

    public static void main(String[] a) {
        final String N = "android.permission.POST_NOTIFICATIONS", C = "android.permission.CAMERA",
                L = "android.permission.ACCESS_FINE_LOCATION", I = "android.permission.INTERNET";

        System.out.println("== flagWord: the words capturePerms writes");
        check("user-set".equals(Lifted.flagWord(true, false)), "USER_SET -> user-set");
        check("user-fixed".equals(Lifted.flagWord(false, true)), "USER_FIXED alone -> user-fixed");
        check("user-set,user-fixed".equals(Lifted.flagWord(true, true)), "both -> user-set,user-fixed");
        check(Lifted.flagWord(false, false) == null, "neither -> null (never answered, not a decline)");

        System.out.println("== wordBits: exactly roamd's allowlist");
        check(Lifted.wordBits("user-set") == 1 && Lifted.wordBits("user-fixed") == 2
                && Lifted.wordBits("user-set,user-fixed") == 3, "the three forms map to their bits");
        boolean refused = true;
        for (String w : new String[] { "review-required", "revoked-compat", "user-fixed,user-set", "user-set,revoked-compat",
                "", "USER-SET", " user-set", null })
            refused &= Lifted.wordBits(w) == 0;
        check(refused, "every other word is refused");
        check(Lifted.wordBits(Lifted.flagWord(true, false)) == 1 && Lifted.wordBits(Lifted.flagWord(false, true)) == 2
                && Lifted.wordBits(Lifted.flagWord(true, true)) == 3, "every word the capture writes is one apply honours");

        System.out.println("== plainName: nothing pm could read as an option");
        check(Lifted.plainName("com.foo") && Lifted.plainName(N) && Lifted.plainName("a_b.C9"), "plain names pass");
        boolean bad = false;
        for (String s : new String[] { "", null, "-x", "--user", "1abc", "_x", ".x", "a b", "a$b", "a/b", "a\r", "a-b" })
            bad |= Lifted.plainName(s);
        check(!bad, "dash-led, digit-led, blank, metacharacter and CR names fail");

        System.out.println("== parse: the declines of one package, as roamd's declined pass reads the file");
        String d6 = "com.foo flags:review-required:" + N + "\n" + "com.foo flags:user-set,revoked-compat:" + C + "\n"
                + "com.foo flags:user-set:" + I + "\n" + "com.foo flags:user-set:--user\n" + "-x flags:user-set:" + N + "\n"
                + "com.foo flags:user-set\n" + "com.foo flags:user-set:a$b\n" + "com.foo flags::" + N + "\n"
                + "com.foo flags:user-set:" + L + "\n";
        List<String[]> r = Lifted.parse(d6, "com.foo");
        check(is(r, L, "user-set"), "D6's file: only the LOCATION line is honoured " + show(r));
        r = Lifted.parse(d6, "-x");
        check(r.isEmpty(), "an option-shaped package is refused " + show(r));
        String mixed = "com.foo " + C + "\ncom.foo deny:" + I + "\ncom.foo appop:android:system_alert_window\n"
                + "com.bar flags:user-set:" + N + "\ncom.foobar flags:user-set:" + N + "\n"
                + "com.foo flags:user-fixed:" + N + "\ncom.foo flags:user-set,user-fixed:" + C + "\n";
        r = Lifted.parse(mixed, "com.foo");
        check(is(r, N, "user-fixed", C, "user-set,user-fixed"), "grant, deny:, appop: and other packages' lines are ignored " + show(r));
        r = Lifted.parse("  com.foo \t flags:user-set:" + N + " \t\n", "com.foo");
        check(is(r, N, "user-set"), "blanks around and between the fields are read as `read` reads them " + show(r));
        r = Lifted.parse("com.foo flags:user-set:" + C + "\ncom.foo flags:user-set:" + N, "com.foo");
        check(is(r, C, "user-set"), "an unterminated last line is ignored, as `read` ignores it " + show(r));
        r = Lifted.parse("com.foo flags:user-set:" + N + "\r\n", "com.foo");
        check(r.isEmpty(), "a CRLF line is refused (the CR is part of the permission) " + show(r));
        check(Lifted.parse(null, "com.foo").isEmpty() && Lifted.parse("", "com.foo").isEmpty(), "no file text -> no declines");

        System.out.println("== softenedDecline: a materialised-then-archived app's carried decline");
        check(("com.foo flags:user-set:" + N).equals(Lifted.softenedDecline("com.foo flags:user-fixed:" + N, "com.foo")),
                "user-fixed is softened to user-set (the app may still ask)");
        check(("com.foo flags:user-set:" + N).equals(Lifted.softenedDecline("com.foo flags:user-set,user-fixed:" + N, "com.foo")),
                "user-set,user-fixed is softened to user-set");
        check(("com.foo flags:user-set:" + N).equals(Lifted.softenedDecline("com.foo flags:user-set:" + N, "com.foo")),
                "user-set is kept as is");
        boolean dropped = true;
        for (String ln : new String[] { "com.foo " + C, "com.foo deny:" + I, "com.foo appop:android:system_alert_window",
                "com.foobar flags:user-set:" + N, "com.foo flags:review-required:" + N, "com.foo flags:user-set" })
            dropped &= Lifted.softenedDecline(ln, "com.foo") == null;
        check(dropped, "grants, deny:, appop:, another package's and malformed lines are not carried");

        System.out.println("== NWP-20261012-08: the SMS app keeps its SMS permissions");
        final String RS = "android.permission.READ_SMS", RV = "android.permission.RECEIVE_SMS",
                RM = "android.permission.RECEIVE_MMS", RW = "android.permission.RECEIVE_WAP_PUSH",
                SS = "android.permission.SEND_SMS", RC = "android.permission.READ_CONTACTS",
                CB = "android.permission.READ_CELL_BROADCASTS", PH = "android.permission.READ_PHONE_STATE";
        boolean all6 = true;
        for (String p : new String[] { RS, RV, RM, RW, SS, CB }) all6 &= Lifted.smsRolePerm(p);
        check(all6, "READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, SEND_SMS and READ_CELL_BROADCASTS are the SMS role's");
        boolean none = false;
        for (String p : new String[] { N, C, L, I, RC, PH, "android.permission.CALL_PHONE", "READ_SMS",
                "android.permission.READ_SMS ", "", null })
            none |= Lifted.smsRolePerm(p);
        check(!none, "nothing else is: notifications, camera, location, contacts, phone, near-misses");
        check(Lifted.SMS_ROLE_PERMS.length == 6, "exactly six names (the SMS role's sms permission-set; Chester: All six)");

        java.util.List<String[]> ds = new java.util.ArrayList<>();
        for (String p : new String[] { N, RS, C, SS, RC, RW, CB })
            ds.add(new String[] { p, "user-set" });
        r = Lifted.exceptSmsRole(ds);
        check(is(r, N, "user-set", C, "user-set", RC, "user-set"), "exceptSmsRole keeps every other decline, in order " + show(r));
        r = Lifted.onlySmsRole(ds);
        check(is(r, RS, "user-set", SS, "user-set", RW, "user-set", CB, "user-set"), "onlySmsRole keeps just the SMS ones " + show(r));
        check(Lifted.exceptSmsRole(null).isEmpty() && Lifted.onlySmsRole(null).isEmpty(), "no declines -> none either way");

        final String MSG = "com.android.messaging", SELF = "com.nowhere.chooser";
        check(Lifted.smsCandidates(null, SELF, MSG).equals(java.util.Arrays.asList(MSG)), "no record: Messaging alone");
        check(Lifted.smsCandidates("com.foo", SELF, MSG).equals(java.util.Arrays.asList(MSG, "com.foo")),
                "a recorded app AND Messaging, its stand-in");
        check(Lifted.smsCandidates(SELF, SELF, MSG).equals(java.util.Arrays.asList(MSG)), "the chooser is never one");
        check(Lifted.smsCandidates(MSG, SELF, MSG).equals(java.util.Arrays.asList(MSG)), "Messaging recorded: once");

        java.util.List<String> old = java.util.Arrays.asList("com.foo " + C, "com.foo flags:user-fixed:" + RS,
                "com.bar flags:user-set:" + SS, "com.foo flags:review-required:" + SS, "com.foo flags:user-set:" + RS + "X",
                "com.foo flags:user-set,user-fixed:" + RV);
        check("user-fixed".equals(Lifted.oldDeclineWord(old, "com.foo", RS)), "oldDeclineWord finds pkg's word for perm");
        check("user-set,user-fixed".equals(Lifted.oldDeclineWord(old, "com.foo", RV)), "... in every flag form");
        check(Lifted.oldDeclineWord(old, "com.foo", SS) == null, "another package's line, or a refused word, is no decline");
        check(Lifted.oldDeclineWord(old, "com.foo", C) == null, "a grant line is no decline");
        check(Lifted.oldDeclineWord(java.util.Arrays.asList("com.foo flags:" + RS), "com.foo", RS) == null
                && Lifted.oldDeclineWord(null, "com.foo", RS) == null, "a malformed line or no lines -> null");

        check("user-fixed".equals(Lifted.keptDecline(RS, false, false, "user-fixed")),
                "a role grant over a decline (neither flag) keeps the decline recorded");
        check(Lifted.keptDecline(RS, true, false, "user-fixed") == null && Lifted.keptDecline(RS, false, true, "user-set") == null,
                "the user answering (either flag) wins: the live state is recorded");
        check("user-set".equals(Lifted.keptDecline(N, false, false, "user-set"))
                && "user-set".equals(Lifted.keptDecline(RC, false, false, "user-set")),
                "outside the SMS role's six too: a grant with neither flag keeps the decline on record (Q059)");
        check("user-fixed".equals(Lifted.keptDecline(C, false, false, "user-fixed")),
                "any permission: CAMERA granted by a role fill with neither flag keeps the recorded decline (Q059)");
        check(Lifted.keptDecline(C, true, false, "user-fixed") == null && Lifted.keptDecline(C, false, true, "user-set") == null,
                "the user answering wins for every permission, not only the six");
        check(Lifted.keptDecline(C, false, false, null) == null && Lifted.keptDecline(C, false, false, "") == null
                && Lifted.keptDecline(C, false, false, "review-required") == null,
                "nothing on record (or a refused word) -> nothing kept, for any permission");
        check(Lifted.keptDecline(RS, false, false, null) == null && Lifted.keptDecline(RS, false, false, "review-required") == null,
                "nothing recorded before (or a refused word) -> nothing kept");

        check("user-fixed".equals(Lifted.oldDeclineWord(old, "com.foo", RS)),
                "oldDeclineWord: an SMS-role decline on record is found without a read");
        check(Lifted.oldDeclineWord(old, "com.bar", RS) == null && Lifted.oldDeclineWord(old, "com.foo", SS) == null,
                "... only pkg's own line for that permission");
        check("user-set".equals(Lifted.oldDeclineWord(java.util.Arrays.asList("com.foo flags:user-set:" + C), "com.foo", C)),
                "... and a recorded decline of any permission, CAMERA included (Q059)");

        // A dialer added to an empty role mid-session re-granted CALL_PHONE and cleared its flags: the capture's decision.
        final String CP = "android.permission.CALL_PHONE";
        java.util.List<String> dialer = java.util.Arrays.asList("com.dialer flags:user-fixed:" + CP);
        check("user-fixed".equals(Lifted.keptDecline(CP, false, false, Lifted.oldDeclineWord(dialer, "com.dialer", CP))),
                "a dialer added mid-session re-granted CALL_PHONE and cleared the flags: the capture keeps the decline");
        check(Lifted.keptDecline(CP, true, false, Lifted.oldDeclineWord(dialer, "com.dialer", CP)) == null,
                "... but a CALL_PHONE grant the user gave (USER_SET) is recorded as a grant");

        System.out.println("passed " + pass + ", failed " + fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
