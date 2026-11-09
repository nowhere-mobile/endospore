package com.nowhere.chooser;

/** NWP-20261128-43: the file rules of the app-label cache (NWP-20260902-07, ProfileActivity.rememberLabel), pure so
 *  test-label-cache-java.sh compiles it alone. The map keeps insertion order: a new or changed label moves to the
 *  end, and the file holds the LAST {@link #CAP} entries. So a write keeps the most recently learned labels, never
 *  the arbitrary subset a HashMap's iteration order gave. */
final class LabelCache {
    /** The number of labels the file keeps. */
    static final int CAP = 200;

    private LabelCache() {}

    /** The file's lines in order. A line counts only with a tab that is neither its first nor its last character; a
     *  later line for the same package wins and moves to the end. {@code null} gives an empty map. */
    static java.util.LinkedHashMap<String,String> parse(String text) {
        java.util.LinkedHashMap<String,String> m = new java.util.LinkedHashMap<>();
        if (text == null) return m;
        for (String line : text.split("\n", -1)) {
            int t = line.indexOf((char) 9);
            if (t <= 0 || t == line.length() - 1) continue;
            String k = line.substring(0, t);
            m.remove(k);
            m.put(k, line.substring(t + 1));
        }
        return m;
    }

    /** Record {@code label} for {@code pkg} as the newest entry. False, and no change, when m already holds it. */
    static boolean put(java.util.LinkedHashMap<String,String> m, String pkg, String label) {
        if (label.equals(m.get(pkg))) return false;
        m.remove(pkg);
        m.put(pkg, label);
        return true;
    }

    /** {@code pkg\tlabel\n} for the last {@code cap} entries of m (the most recently learned), in order. */
    static String render(java.util.Map<String,String> m, int cap) {
        StringBuilder sb = new StringBuilder();
        int skip = Math.max(0, m.size() - cap);
        for (java.util.Map.Entry<String,String> e : m.entrySet()) {
            if (skip > 0) { skip--; continue; }
            sb.append(e.getKey()).append((char) 9).append(e.getValue()).append((char) 10);
        }
        return sb.toString();
    }
}
