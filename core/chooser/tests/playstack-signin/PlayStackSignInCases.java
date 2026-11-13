package com.nowhere.chooser;

import java.util.HashMap;
import java.util.Map;

/** NWP-20261201-06: what the sign-in Play-stack reconcile may change, compiled with PlayStackSignIn ALONE (java.* only).
 *  A label is printed with a space after it, so a search for "FAIL c2 " does not also match c2b. */
public class PlayStackSignInCases {
    static final String V = "com.android.vending", G = "com.google.android.gms", F = "com.google.android.gsf";
    static final String CLIENT = "org.example.client";
    static int runs = 0, fails = 0;

    static void check(String label, String what, boolean ok, Object got) {
        runs++;
        if (ok) { System.out.println("ok   " + label + " " + what); return; }
        fails++;
        System.out.println("FAIL " + label + " " + what + "\n     got: " + got);
    }

    static Map<String,String> map(String... kv) {
        HashMap<String,String> m = new HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    static Map<String,String> raises(Map<String,String> keep, String need, boolean vendingHeld) {
        return PlayStackSignIn.raises(keep, need, vendingHeld, G, F, V);
    }

    public static void main(String[] a) {
        Map<String,String> r;

        r = raises(map(CLIENT, "auto", V, "ondemand", G, "ondemand"), "auto", false);
        check("c1", "an auto need raises an on-demand Play Store and gms, and names nothing else",
              r.equals(map(V, "auto", G, "auto")), r);

        r = raises(map(CLIENT, "auto", V, "ondemand", G, "ondemand"), "auto", true);
        check("c2", "a user-kept Play Store is untouched and gms is still raised", r.equals(map(G, "auto")), r);

        r = raises(map(V, "auto", G, "ondemand"), "installed", true);
        check("c2b", "Play turned Off holds an auto-pulled Play Store, and gms is still raised",
              r.equals(map(G, "installed")), r);

        r = raises(map(V, "auto", G, "installed", F, "auto"), "ondemand", false);
        check("c3", "an on-demand need never lowers a member", r.isEmpty(), r);

        r = raises(map(V, "auto", G, "auto", F, "auto"), null, false);
        check("c4", "a null need never drops a member", r.isEmpty(), r);

        r = raises(map(V, "ondemand", G, "ondemand"), "auto", false);
        check("c5", "a member absent from the keep-set is not added", !r.containsKey(F), r);

        String in = "org.example.a\n"
                + "\n"
                + "org.example.b\tauto\tgroup:x\n"
                + "org.example.c\tinstalled\t group:odd \n"
                + "   \n"
                + "org.example.odd \t auto\n"
                + G + "\tondemand\tgroup:sandboxed-play\n"
                + F + "\tondemand\n"
                + V + "\tondemand\tgroup:sandboxed-play\n"
                + "org.example.d\tondemand\n";
        String want = "org.example.a\n"
                + "org.example.b\tauto\tgroup:x\n"
                + "org.example.c\tinstalled\t group:odd \n"
                + "org.example.odd \t auto\n"
                + G + "\tinstalled\tgroup:sandboxed-play\n"
                + F + "\n"
                + V + "\tauto\tgroup:sandboxed-play\n"
                + "org.example.d\tondemand\n";
        String out = PlayStackSignIn.rewrite(in, map(G, "installed", F, "installed", V, "auto"));
        check("c6", "rewrite keeps other lines byte for byte and each group token; installed is bare with no token",
              want.equals(out), out);

        System.out.println(runs + " checks, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
