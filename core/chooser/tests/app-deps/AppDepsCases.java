package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** NWP-20261118-21: what an on-demand tap fetches first (ProfileActivity's groupFor, groupDeps, appDeps and
 *  isStackMember), compiled with AppDeps ALONE (java.* only). DEFAULTS mirrors ProfileActivity.DEFAULT_GROUPS. */
public class AppDepsCases {
    static final String V = "com.android.vending", G = "com.google.android.gms", F = "com.google.android.gsf";
    static final String YT = "com.google.android.youtube", APP = "org.example.app";
    static final Map<String,String> DEFAULTS = map(V, "sandboxed-play", G, "sandboxed-play", F, "sandboxed-play");
    static final Map<String,String> NONE = Collections.emptyMap();
    static int runs = 0, fails = 0;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static Map<String,String> map(String... kv) {
        HashMap<String,String> m = new HashMap<>();
        for (int i = 0; i < kv.length; i += 2) m.put(kv[i], kv[i + 1]);
        return m;
    }

    static Set<String> set(String... p) { return new LinkedHashSet<>(Arrays.asList(p)); }

    static List<String> list(String... p) { return Arrays.asList(p); }

    static List<String> deps(String entry, Map<String,String> explicit, Set<String> deferred, Set<String> playDeps) {
        return AppDeps.appDeps(entry, explicit, DEFAULTS, deferred, playDeps, G, F, V);
    }

    static boolean member(String pkg, Map<String,String> explicit) {
        return AppDeps.isStackMember(pkg, explicit, DEFAULTS, G);
    }

    public static void main(String[] args) {
        List<String> got;

        got = deps(APP, NONE, set(APP, G, F, V), set());
        check("a plain app in no group has no deps", got.equals(list()), "" + got);

        got = deps(V, NONE, set(F, V, G), set());
        check("Play Store pulls gms and gsf in deferred order", got.equals(list(F, G)), "" + got);

        got = deps(V, NONE, set(G, V), set());
        check("Play Store with gsf not deferred pulls gms only", got.equals(list(G)), "" + got);

        got = deps(YT, NONE, set(V, F, G, YT), set(YT));
        check("a Play client pulls gms, gsf, vending in that order", got.equals(list(G, F, V)), "" + got);

        got = deps(YT, NONE, set(F, G, YT), set(YT));
        check("a Play client with vending not deferred pulls gms and gsf", got.equals(list(G, F)), "" + got);

        got = deps(YT, NONE, set(V, F, G, YT), set());
        check("a client not in playDeps pulls no stack", got.equals(list()), "" + got);

        // gsf is moved out of the group, so only the fixed-order stack loop could add it.
        String x = "org.example.playclient";
        Map<String,String> ex = map(x, "sandboxed-play", F, "elsewhere");
        got = deps(x, ex, set(V, x, F, G), set(x));
        check("an explicit sandboxed-play client is a stack member",
                member(x, ex) && got.equals(list(V, G)), "member=" + member(x, ex) + " deps=" + got);

        Map<String,String> mine = map(V, "mine");
        got = deps(V, mine, set(G, F, V), set());
        check("an explicit token beats the default",
                "mine".equals(AppDeps.groupOf(V, mine, DEFAULTS)) && !member(V, mine) && got.equals(list()),
                "group=" + AppDeps.groupOf(V, mine, DEFAULTS) + " member=" + member(V, mine) + " deps=" + got);

        Map<String,String> blank = map(V, "");
        got = deps(V, blank, set(G, F), set());
        check("an explicit empty token falls back to the default",
                "sandboxed-play".equals(AppDeps.groupOf(V, blank, DEFAULTS)) && got.equals(list(G, F)),
                "group=" + AppDeps.groupOf(V, blank, DEFAULTS) + " deps=" + got);

        Map<String,String> pair = map("org.a", "pair", "org.b", "pair");
        List<String> da = deps("org.a", pair, set("org.a", "org.b"), set());
        List<String> db = deps("org.b", pair, set("org.a", "org.b"), set());
        check("two apps in one explicit group are each other's dep",
                da.equals(list("org.b")) && db.equals(list("org.a")), "a=" + da + " b=" + db);

        // (ii) gms outside the group and a Play client reaches the stack loop's own exclusion.
        List<String> self1 = deps(V, NONE, set(V, G, F), set());
        Map<String,String> other = map(G, "other");
        List<String> self2 = deps(G, other, set(G, F, V), set(G));
        check("the entry never appears in its own list",
                self1.equals(list(G, F)) && self2.equals(list(F, V)), "vending=" + self1 + " gms=" + self2);

        String c = "org.example.client";
        got = deps(c, map(c, "cg", G, "cg"), set(G, c, F, V), set(c));
        check("no duplicates when a stack member shares the client's group", got.equals(list(G, F, V)), "" + got);

        got = AppDeps.groupDeps(APP, NONE, DEFAULTS, set(APP, G, F, V));
        check("a pkg in no group is not a stack member",
                !member(APP, NONE) && AppDeps.groupOf(APP, NONE, DEFAULTS) == null && got.equals(list()),
                "member=" + member(APP, NONE) + " group=" + AppDeps.groupOf(APP, NONE, DEFAULTS) + " deps=" + got);

        got = AppDeps.groupDeps(V, NONE, DEFAULTS, set(G));
        check("groupDeps keeps a deferred member and drops a non-deferred one", got.equals(list(G)), "" + got);

        check("every stack member is a stack member", member(V, NONE) && member(G, NONE) && member(F, NONE),
                "vending=" + member(V, NONE) + " gms=" + member(G, NONE) + " gsf=" + member(F, NONE));

        if (fails == 0) System.out.println("PASS " + runs + " cases");
        else { System.out.println("FAILED " + fails + " of " + runs + " cases"); System.exit(1); }
    }
}
