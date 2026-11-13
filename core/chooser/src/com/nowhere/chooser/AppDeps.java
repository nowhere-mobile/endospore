package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collection;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Predicate;

/**
 * What an on-demand tap materialises BEFORE the app itself (group-materialise, DIA-20260802,
 * docs/ondemand-sandboxed-play-group.md), lifted out of ProfileActivity so a JDK can run it. java.* only.
 * ProfileActivity reads the keep-set's explicit {@code group:} tokens, DEFAULT_GROUPS, the deferred keep-set and
 * nowhere-playdeps; this decides. NWP-20261118-21. stackNeed answers the keep-set side of the same question: how
 * eagerly the kept clients need the sandboxed-Play stack. NWP-20261201-04.
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

    /**
     * The mode the sandboxed-Play stack must be held at: the strongest mode among the kept packages that demand it
     * (installed > auto > ondemand; any other non-null value counts as ondemand), or null when none does. For each
     * package in keep's iteration order:
     * gms and gsf never demand. vending demands ONLY when it is in playDeps, the USER kept it: never from playSeenYes
     * and never from being auto-pulled, because reconcile writes an auto-pulled vending at this answer and it would
     * self-latch. Any other package demands when appDeps over the whole stack is non-empty, with
     * recorded = playDeps + playSeenYes. A recorded answer is ARCHIVE-SAFE: it needs no manifest, so an archived
     * placeholder still demands, and a playseen yes counts at any version, as playDependent trusts it, which fails
     * toward KEEPING the stack (docs/product-decisions.md, 2026-11-09, #2). Failing that, an installed or auto package
     * demands if liveUses answers true (an installed package is not archived); liveUses is asked last, so a recorded
     * client costs no PackageManager read.
     */
    static String stackNeed(Map<String,String> keep, Map<String,String> explicit, Map<String,String> defaults,
            Set<String> playDeps, Set<String> playSeenYes, Predicate<String> liveUses,
            String gms, String gsf, String vending, String installed, String auto, String ondemand) {
        Set<String> recorded = new HashSet<>(playDeps);
        recorded.addAll(playSeenYes);
        List<String> stack = List.of(gms, gsf, vending);
        String need = null;
        for (Map.Entry<String,String> e : keep.entrySet()) {
            String p = e.getKey();
            if (gms.equals(p) || gsf.equals(p)) continue; // providers are never demand sources
            String mode = e.getValue();
            boolean demands = vending.equals(p)
                    ? playDeps.contains(p)
                    : !appDeps(p, explicit, defaults, stack, recorded, gms, gsf, vending).isEmpty()
                            || ((installed.equals(mode) || auto.equals(mode)) && liveUses.test(p));
            if (!demands) continue;
            if (modeRank(mode, installed, auto) > modeRank(need, installed, auto)) {
                need = installed.equals(mode) ? installed : auto.equals(mode) ? auto : ondemand;
            }
        }
        return need;
    }

    private static int modeRank(String m, String installed, String auto) {
        return installed.equals(m) ? 3 : auto.equals(m) ? 2 : m != null ? 1 : 0;
    }
}
