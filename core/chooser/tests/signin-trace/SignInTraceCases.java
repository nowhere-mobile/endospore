// NWP-20261203-04: SignInTrace's words and numbers, compiled with the real source and EXECUTED. run.sh puts this file in
// the package, so it reaches the package-private class.
package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

public final class SignInTraceCases {
    private static int failed = 0;

    private static void expect(String name, Object want, Object got) {
        if (java.util.Objects.equals(want, got)) System.out.println("  ok   " + name);
        else { System.out.println("  FAIL " + name + " (want " + want + ", got " + got + ")"); failed++; }
    }

    private static String kind(String... extras) {
        final Set<String> s = new HashSet<>(Arrays.asList(extras));
        return SignInTrace.startKind(s::contains);
    }

    public static void main(String[] a) {
        final String self = "com.nowhere.chooser", msg = "com.android.messaging", other = "org.example.sms";
        System.out.println("== holderClass");
        expect("holder-null -> -1", -1, SignInTrace.holderClass(null, self, msg));
        expect("holder-empty -> 0", 0, SignInTrace.holderClass(Collections.emptyList(), self, msg));
        expect("holder-self-among-others -> 1", 1, SignInTrace.holderClass(Arrays.asList(other, self), self, msg));
        expect("holder-messaging -> 2", 2, SignInTrace.holderClass(Arrays.asList(msg), self, msg));
        expect("holder-other -> 3", 3, SignInTrace.holderClass(Arrays.asList(other), self, msg));
        System.out.println("== permBits");
        expect("perms-all -> 63", 63, SignInTrace.permBits(new boolean[] {true, true, true, true, true, true}));
        expect("perms-none -> 0", 0, SignInTrace.permBits(new boolean[6]));
        expect("perms-bit5 -> 32", 32, SignInTrace.permBits(new boolean[] {false, false, false, false, false, true}));
        expect("perms-null -> -1", -1, SignInTrace.permBits(null));
        System.out.println("== startKind: one word per onStartCommand branch, in branch order");
        String[][] one = {
            {"claimsLogin", "claimslogin"}, {"claims", "claims"}, {"alarm", "alarm"}, {"relayprefs", "relayprefs"},
            {"gosstate", "gosstate"}, {"ingest", "ingest"}, {"smsrole", "smsrole"}, {"smsretry", "smsretry"},
            {"telingest", "telingest"},
        };
        for (String[] c : one) expect("kind-" + c[0] + " -> " + c[1], c[1], kind(c[0]));
        expect("kind-none -> pw", "pw", kind());
        expect("kind-two-extras ingest+claimsLogin -> claimslogin", "claimslogin", kind("ingest", "claimsLogin"));
        expect("kind-two-extras telingest+smsrole -> smsrole", "smsrole", kind("telingest", "smsrole"));
        System.out.println("== exitLine: a 15 min window, both edges in");
        long w = 15 * 60 * 1000L;
        expect("exit-ago-0 -> kept", "reason=8 ago=0", SignInTrace.exitLine(8, 0));
        expect("exit-ago-15min -> kept", "reason=8 ago=" + w, SignInTrace.exitLine(8, w));
        expect("exit-ago-15min+1 -> null", null, SignInTrace.exitLine(8, w + 1));
        expect("exit-ago-negative -> null", null, SignInTrace.exitLine(8, -1));
        expect("exit-text (8,118)", "reason=8 ago=118", SignInTrace.exitLine(8, 118));
        if (failed > 0) { System.out.println("FAILED: " + failed + " case(s)"); System.exit(1); }
        System.out.println("all SignInTrace cases pass");
    }
}
