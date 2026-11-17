package com.nowhere.chooser;

/** NWP-20261203-24: the apps this sign-in restored installed from {@code #apps} (nowhere-installed-restored) that
 *  have no keep line at sign-out. ProfileActivity.recordUnkeptRestoredOff records each one Off, so roamd's code-side
 *  drop (nowhere-appoff.list INTERSECT nowhere-appdrop.list) names it and the agent's carry stops re-emitting its code
 *  from the head. Without that record nothing ever put such an app in the Off record, so a head that carried it once
 *  carried it at every later sign-out, though Your apps showed it Off.
 *
 *  This applies "2026-09-26 — DECIDED: an app switched Off leaves the store at the next roam, exactly like an app
 *  that was never kept" (docs/product-decisions.md). Pure: no Android type, so a javac suite runs it
 *  (core/chooser/test-unkept-restored-java.sh). */
final class UnkeptRestored {
    private UnkeptRestored() {}

    /** The same values as ProfileActivity.VENDING_PKG, GMS_PKG and GSF_PKG. DECIDED 2026-09-26 ("keep play store"):
     *  a Play-stack package keeps its code, and roamd's appcode_stage_play_dormant reads the RAW Off record for these
     *  lines, so an Off line here would change how roamd stages Play. roamd also subtracts them on the code side. */
    private static final java.util.Set<String> PLAY_STACK = new java.util.HashSet<>(java.util.Arrays.asList(
            "com.android.vending", "com.google.android.gms", "com.google.android.gsf"));

    /** Each trimmed, non-empty line of restoredLines that is not kept (in any mode), not an inferred orphan, not
     *  ownPkg, not a Play-stack package, not bundled and still installed. Input order; a duplicate once. The two
     *  predicates call PackageManager, so the cheap set checks run first. */
    static java.util.LinkedHashSet<String> select(java.util.Collection<String> restoredLines,
            java.util.Set<String> kept, java.util.Set<String> orphans, String ownPkg,
            java.util.function.Predicate<String> bundled, java.util.function.Predicate<String> installed) {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        for (String raw : restoredLines) {
            if (raw == null) continue;
            String p = raw.trim();
            if (p.isEmpty()) continue;
            if (kept.contains(p)) continue;        // kept in any mode: its code stays
            if (orphans.contains(p)) continue;     // an inferred orphan keeps its code (NWP-20260830-08)
            if (p.equals(ownPkg)) continue;
            if (PLAY_STACK.contains(p)) continue;  // DECIDED 2026-09-26: the Play stack keeps its code
            if (bundled.test(p)) continue;         // part of the OS, never in the keep-set
            if (!installed.test(p)) continue;      // gone already: the uninstall prune records it
            out.add(p);
        }
        return out;
    }
}
