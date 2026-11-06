package com.nowhere.chooser;

import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.Locale;
import java.util.TreeSet;

/**
 * Cases for LostPhoneCopy (NWP-20261111-14, NWP-20261114-22, Q011 / #45). args[0] and args[1] are the decided tied
 * and not-tied texts, which the suite reads out of docs/product-decisions.md. Exits 1 on any failure.
 */
public class LostPhoneLineCases {
    private static int failures = 0;

    private static void check(String what, boolean ok) {
        if (!ok) { failures++; System.err.println("  CASE FAIL " + what); }
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\r", "\\r").replace("\n", "\\n") + "\"";
    }

    public static void main(String[] args) {
        if (args.length != 2) {
            System.err.println("  CASE FAIL want 2 args (the decided tied and not-tied texts), got " + args.length);
            System.exit(1);
        }
        String tied = LostPhoneCopy.TIED, notTied = LostPhoneCopy.NOT_TIED;
        check("TIED is set", tied != null && !tied.trim().isEmpty());
        check("NOT_TIED is set", notTied != null && !notTied.trim().isEmpty());
        if (tied == null) tied = "";
        if (notTied == null) notTied = "";
        // #45 (2026-10-22): both texts are the decision's, byte for byte.
        check("TIED equals the decided tied text " + show(args[0]) + ", is " + show(tied), tied.equals(args[0]));
        check("NOT_TIED equals the decided not-tied text " + show(args[1]) + ", is " + show(notTied),
                notTied.equals(args[1]));

        // OK TIED and OK TIED PARTIAL (trimmed, exact) are TIED; every other reply, null included, is NOT_TIED.
        for (String r : new String[] {"OK TIED", "OK TIED PARTIAL", " OK TIED\n", "OK TIED PARTIAL\r\n"}) {
            String got = LostPhoneCopy.line(r);
            check("line(" + show(r) + ") is TIED, is " + show(got), tied.equals(got));
        }
        for (String r : new String[] {"OK UNTIED", "OK NOCHIP", "OK OTHER", "ERR-NOSESSION", "ERR-CALLER",
                "ERR-NOTSTORED", "NOSTORE", "ERR", "", null, "ok tied", "OK TIEDX", "OK TIED PARTIALLY"}) {
            String got = LostPhoneCopy.line(r);
            check("line(" + show(r) + ") is NOT_TIED, is " + show(got), notTied.equals(got));
        }

        // TIED names the 12 words (a kept phone is added again with them); NOT_TIED never does, because on an untied
        // profile a kept phone needs only the new passphrase.
        check("TIED names the 12 words", tied.contains("12 words"));
        check("NOT_TIED does not name the 12 words", !notTied.contains("12"));
        // The lever is the passphrase change.
        check("TIED names the passphrase change", tied.contains("Change your passphrase"));
        check("NOT_TIED names the passphrase change", notTied.contains("Change your passphrase"));
        // Recovery answers a forgotten passphrase, never a compromised one (2026-09-15), so it is never named as the
        // lever; and the change does not reach a cold-locked session already on the lost phone, so neither text
        // claims to erase or wipe it.
        for (String banned : new String[] {"recovery", "erase", "wipe"}) {
            check("TIED does not say \"" + banned + "\"", !tied.toLowerCase(Locale.ROOT).contains(banned));
            check("NOT_TIED does not say \"" + banned + "\"", !notTied.toLowerCase(Locale.ROOT).contains(banned));
        }

        // The class holds exactly the two texts: the one unconditional LINE is gone (one line for every profile was
        // not chosen).
        TreeSet<String> fields = new TreeSet<>();
        for (Field f : LostPhoneCopy.class.getDeclaredFields()) {
            if (f.isSynthetic() || !Modifier.isStatic(f.getModifiers()) || f.getType() != String.class) continue;
            fields.add(f.getName());
        }
        check("LostPhoneCopy's static String fields are [NOT_TIED, TIED], are " + fields,
                fields.toString().equals("[NOT_TIED, TIED]"));

        if (failures > 0) {
            System.err.println("  " + failures + " case(s) failed");
            System.exit(1);
        }
        System.out.println("  cases ok");
    }
}
