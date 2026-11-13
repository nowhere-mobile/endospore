package com.nowhere.chooser;

import java.util.LinkedHashMap;
import java.util.Map;

/** NWP-20261201-06: what the once-per-sign-in Play-stack reconcile may change
 *  (ProfileActivity.reconcilePlayStackAtSignIn). java.* only, so a javac suite can execute it off the build host.
 *
 *  It only RAISES a kept member's mode (docs/product-decisions.md, 2026-11-09, "eight answers to harvest 62 ...", #2
 *  (2)). It never adds a member, because adds go through the plan gate that the keep-set edit path owns. It never
 *  lowers or drops one, because a need computed while an installed client is still being restored would archive the
 *  stack under a client that needs it. Lowering and drops stay on the keep-set edit.
 *
 *  The mode words are the on-disk format of nowhere-appkeep, the same words as ProfileActivity.MODE_*. */
final class PlayStackSignIn {
    private PlayStackSignIn() {}

    private static final String INSTALLED = "installed";
    private static final String AUTO = "auto";
    private static final String ONDEMAND = "ondemand";

    /** Package to new mode for each of gms, gsf and (only when !vendingHeld) vending that is in {@code keep} and whose
     *  mode ranks below {@code need}. {@code vendingHeld} is true when reconcile does not own Play Store's mode: the
     *  user kept it, or Google Play is turned Off. A null {@code need} raises nothing. */
    static Map<String,String> raises(Map<String,String> keep, String need, boolean vendingHeld,
                                     String gms, String gsf, String vending) {
        LinkedHashMap<String,String> out = new LinkedHashMap<>();
        if (need == null) return out;
        raiseOne(out, keep, gms, need);
        raiseOne(out, keep, gsf, need);
        if (!vendingHeld) raiseOne(out, keep, vending, need);
        return out;
    }

    private static void raiseOne(Map<String,String> out, Map<String,String> keep, String p, String need) {
        String have = keep.get(p);
        if (have == null) return;
        if (rank(have) < rank(need)) out.put(p, need);
    }

    private static int rank(String mode) {
        return INSTALLED.equals(mode) ? 3 : AUTO.equals(mode) ? 2 : ONDEMAND.equals(mode) ? 1 : 0;
    }

    /** The keep-set text with each package in {@code raises} at its new mode. Line format:
     *  {@code pkg[\tmode[\tgroup:<name>]]}. Every line it does not name is re-emitted byte for byte, and blank lines are
     *  dropped, as removeKeepLines does. A named line keeps everything after field 2. Installed with no token is the
     *  bare pkg; field 2 must exist to reach field 3, so installed before a token is written out (writeAppModes' rule).
     *  A named line is split after a trim, which is how parseAppModes reads it. */
    static String rewrite(String text, Map<String,String> raises) {
        StringBuilder sb = new StringBuilder();
        for (String ln : text.split("\n", -1)) {
            if (ln.trim().isEmpty()) continue;
            String[] f = ln.trim().split("\t", 3);
            String mode = raises.get(f[0].trim());
            if (mode == null) { sb.append(ln).append('\n'); continue; }
            boolean token = f.length == 3 && !f[2].trim().isEmpty();
            sb.append(f[0].trim());
            if (token || !INSTALLED.equals(mode)) sb.append('\t').append(mode);
            if (token) sb.append('\t').append(f[2]);
            sb.append('\n');
        }
        return sb.toString();
    }
}
