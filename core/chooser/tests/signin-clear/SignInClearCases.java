package com.nowhere.chooser;

/** NWP-20261117-09: cases for SignInClear, compiled with the class as it ships (test-signin-clear-java.sh). */
public final class SignInClearCases {
    private static int fails = 0;

    private static void check(String label, boolean got, boolean want) {
        if (got == want) {
            System.out.println("ok   " + label);
        } else {
            System.out.println("FAIL " + label + " (got " + got + ", want " + want + ")");
            fails++;
        }
    }

    public static void main(String[] args) {
        check("usable(\"a\",\"x\")", SignInClear.usable("a", "x"), true);
        check("usable(\"\",\"x\")", SignInClear.usable("", "x"), false);
        check("usable(\"  \",\"x\") (the name is trimmed)", SignInClear.usable("  ", "x"), false);
        check("usable(null,\"x\")", SignInClear.usable(null, "x"), false);
        check("usable(\"a\",\"\")", SignInClear.usable("a", ""), false);
        check("usable(\"a\",null)", SignInClear.usable("a", null), false);
        check("endsKeyWait(true,false)", SignInClear.endsKeyWait(true, false), true);
        check("endsKeyWait(true,true) (a round trip keeps the park)", SignInClear.endsKeyWait(true, true), false);
        check("endsKeyWait(false,false)", SignInClear.endsKeyWait(false, false), false);
        check("endsKeyWait(false,true)", SignInClear.endsKeyWait(false, true), false);
        check("NEED_CREDS byte for byte",
                "Enter your name and passphrase first, then tap again.".equals(SignInClear.NEED_CREDS), true);
        if (fails > 0) {
            System.out.println(fails + " case(s) failed");
            System.exit(1);
        }
        System.out.println("all cases pass");
    }
}
