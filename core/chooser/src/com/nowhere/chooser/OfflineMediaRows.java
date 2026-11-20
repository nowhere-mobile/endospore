package com.nowhere.chooser;

/** NWP-20261203-26: the Offline media rows the daemon's listing does not name. Pure Java, no android.* import. */
final class OfflineMediaRows {
    private OfflineMediaRows() {}

    /** The listing is deferred-only, so a pinned folder whose every file had materialised vanished from the screen
     *  while its pin stood, and could not be switched back (finding M, device-proof S7). */
    static java.util.List<String> keptWithoutListing(java.util.Set<String> listed, java.util.Set<String> pins,
                                                     java.util.Map<String,String> overrides, String ownPkg) {
        java.util.Set<String> seen = listed == null ? java.util.Collections.<String>emptySet() : listed;
        java.util.Set<String> pinned = pins == null ? java.util.Collections.<String>emptySet() : pins;
        java.util.Map<String,String> tiers = overrides == null ? java.util.Collections.<String,String>emptyMap() : overrides;
        java.util.LinkedHashSet<String> candidates = new java.util.LinkedHashSet<>(pinned);
        candidates.addAll(tiers.keySet());
        java.util.ArrayList<String> out = new java.util.ArrayList<>();
        for (String seg : candidates) {
            if (seg == null || seg.trim().isEmpty() || seg.equals(ownPkg) || seen.contains(seg)) continue;
            String o = tiers.get(seg);
            if ("essential".equals(o) || (pinned.contains(seg) && !"prefetch".equals(o) && !"ondemand".equals(o))) {
                out.add(seg);
            }
        }
        java.util.Collections.sort(out);
        return out;
    }
}
