package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * What an on-demand tap materialises BEFORE the app itself (group-materialise, DIA-20260802,
 * docs/ondemand-sandboxed-play-group.md), lifted out of ProfileActivity so a JDK can run it. java.* only.
 * ProfileActivity reads the keep-set's explicit {@code group:} tokens, DEFAULT_GROUPS, the deferred keep-set and
 * nowhere-playdeps; this decides. NWP-20261118-21.
 */
final class AppDeps {
    private AppDeps() {}

    /** pkg's group name -- a non-empty explicit keep-set token wins, else the built-in default, else null. */
    static String groupOf(String pkg, Map<String,String> explicit, Map<String,String> defaults) {
        String e = explicit.get(pkg);
        if (e != null && !e.isEmpty()) return e;
        return defaults.get(pkg);
    }

    /** True if pkg is a sandboxed-Play stack member: its group is the DEFAULT group of gms ("sandboxed-play"). */
    static boolean isStackMember(String pkg, Map<String,String> explicit, Map<String,String> defaults, String gms) {
        String g = defaults.get(gms); // "sandboxed-play"
        return g != null && g.equals(groupOf(pkg, explicit, defaults));
    }

    /**
     * The OTHER deferred members of entry's group, in the iteration order of deferred: entry excluded, deduped.
     * Empty when entry is in no group. deferred is the on-demand AND auto keep-set (#130: an auto-mode dep is as
     * fetchable as an on-demand one), so MATERIALIZE-APP never fetches an unsealed package.
     */
    static List<String> groupDeps(String entry, Map<String,String> explicit, Map<String,String> defaults,
            Collection<String> deferred) {
        LinkedHashSet<String> deps = new LinkedHashSet<>();
        String grp = groupOf(entry, explicit, defaults);
        if (grp != null && !grp.isEmpty()) {
            for (String p : deferred) {
                if (!p.equals(entry) && grp.equals(groupOf(p, explicit, defaults))) deps.add(p);
            }
        }
        return new ArrayList<>(deps);
    }

    /**
     * groupDeps, then -- for a Play-Services client outside the stack (in playDeps, e.g. YouTube) -- the WHOLE stack
     * in the order gms, gsf, vending, each only if it is not entry and is deferred. Google apps check for the Play
     * Store APP, not just Services (DIA-20260803-01: YouTube "device not compatible" when vending was absent); gms and
     * gsf come before vending so the Store finds Services on first launch. Deduped. A superset of groupDeps.
     */
    static List<String> appDeps(String entry, Map<String,String> explicit, Map<String,String> defaults,
            Collection<String> deferred, Set<String> playDeps, String gms, String gsf, String vending) {
        LinkedHashSet<String> deps = new LinkedHashSet<>(groupDeps(entry, explicit, defaults, deferred));
        if (!isStackMember(entry, explicit, defaults, gms) && playDeps.contains(entry)) {
            for (String s : new String[]{ gms, gsf, vending })
                if (!s.equals(entry) && deferred.contains(s)) deps.add(s); // #130: auto deps too
        }
        return new ArrayList<>(deps);
    }
}
