package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;

/** NWP-20261118-21: what an on-demand tap fetches first (ProfileActivity's groupFor, groupDeps, appDeps and
 *  isStackMember), compiled with AppDeps ALONE (java.* only). DEFAULTS mirrors ProfileActivity.DEFAULT_GROUPS.
 *  NWP-20261201-04: the mode the Play stack is held at (AppDeps.stackNeed, cases c1-c9). */
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

    static final Predicate<String> LIVE_NO = p -> false, LIVE_YES = p -> true;

    static String need(Map<String,String> keep, Map<String,String> explicit, Set<String> playDeps,
            Set<String> playSeenYes, Predicate<String> live) {
        return AppDeps.stackNeed(keep, explicit, DEFAULTS, playDeps, playSeenYes, live, G, F, V,
                "installed", "auto", "ondemand");
    }

    /** CONTROL: reconcilePlayStack's need loop as it stood before NWP-20261201-04, with stronger() inlined. */
    static String mainLoop(Map<String,String> m, Set<String> playClients, Predicate<String> usesPlayServices) {
        String need = null;
        for (Map.Entry<String,String> e : m.entrySet()) {
            String p = e.getKey();
            if (G.equals(p) || F.equals(p)) continue;
            String cmode = e.getValue();
            boolean present = "installed".equals(cmode) || "auto".equals(cmode);
            boolean demands = V.equals(p)
                    ? playClients.contains(p)
                    : playClients.contains(p) || (present && usesPlayServices.test(p));
            if (!demands) continue;
            if ("installed".equals(cmode)) need = "installed";
            else if ("auto".equals(cmode) && !"installed".equals(need)) need = "auto";
            else if (need == null) need = "ondemand";
        }
        return need;
    }

    static boolean same(String want, String have) { return want == null ? have == null : want.equals(have); }

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

        // NWP-20261201-04: the row's bug. An archived Auto client has no manifest (live false) and no playdeps line.
        String client = "org.example.client";
        Map<String,String> archived = map(client, "auto", V, "ondemand", G, "ondemand");
        String have = need(archived, NONE, set(), set(client), LIVE_NO);
        check("c1 an archived Auto client with only a playseen yes holds the stack at auto", same("auto", have), have);
        have = mainLoop(archived, set(), LIVE_NO);
        check("c1-control main's loop lost that client: the row's bug", have == null, have);

        have = need(archived, NONE, set(), set(), LIVE_NO);
        check("c2 no record and no group token demands nothing", have == null, have);

        have = need(map(client, "auto", V, "ondemand"), NONE, set(client), set(), LIVE_NO);
        check("c3 a client in playDeps demands at its own mode", same("auto", have), have);

        have = need(map(client, "installed"), NONE, set(), set(), LIVE_YES);
        check("c4 an installed client with a live yes and no record demands", same("installed", have), have);

        have = need(map(V, "auto"), NONE, set(), set(V), LIVE_YES);
        check("c5 an auto-pulled Play Store never demands, so it cannot self-latch", have == null, have);

        LinkedHashMap<String,String> vendingFirst = new LinkedHashMap<>();
        vendingFirst.put(V, "ondemand");
        vendingFirst.put(client, "auto");
        have = need(vendingFirst, NONE, set(V), set(client), LIVE_NO);
        check("c6 the strongest demander wins over an earlier weaker one", same("auto", have), have);

        have = need(map(client, "ondemand"), NONE, set(), set(), LIVE_YES);
        check("c7 an on-demand client gets no live read", have == null, have);

        have = need(map(G, "auto", F, "auto", V, "auto"), NONE, set(), set(G, F), LIVE_YES);
        check("c8 the stack alone demands nothing", have == null, have);

        have = need(map(client, "auto"), map(client, "sandboxed-play"), set(), set(), LIVE_NO);
        check("c9 an explicit sandboxed-play token demands with no record", same("auto", have), have);

        if (fails == 0) System.out.println("PASS " + runs + " cases");
        else { System.out.println("FAILED " + fails + " of " + runs + " cases"); System.exit(1); }
    }
}
