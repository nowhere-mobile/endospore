package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** NWP-20261027-11: RestorePhase.label in both modes, plus the wiring pins in ChooserActivity.onRestoreProgress.
 *  NWP-20261208-30: the `finishing` and `keys` tags, the media label's "and", RestorePhase.hold (H1), a whole sign-in
 *  run through label + hold as onRestoreProgress does (H2), and the hold's wiring pins (d) and (e). */
public class RestorePhaseCases {
    static int fails = 0;

    static void eq(String what, String want, String got) {
        if (!want.equals(got)) { fails++; System.out.println("FAIL " + what + ": want [" + want + "] got [" + got + "]"); }
    }

    static void eqi(String what, int want, int got) {
        if (want != got) { fails++; System.out.println("FAIL " + what + ": want " + want + " got " + got); }
    }

    static void ok(String what, boolean c) {
        if (!c) { fails++; System.out.println("FAIL " + what); }
    }

    /** The body of the method that starts at sig, up to its closing brace at four spaces of indent. */
    static String body(String src, String sig) {
        int s = src.indexOf(sig);
        ok(sig + " found", s >= 0);
        int e = s >= 0 ? src.indexOf("\n    }\n", s) : -1;
        ok(sig + " end found", e > s);
        return s >= 0 && e > s ? src.substring(s, e) : "";
    }

    public static void main(String[] a) throws Exception {
        String[] phases = {"apps", "accounts", "appcode", "secure", "media", "finishing", "keys"};
        String[] restoring = {"Restoring app data", "Restoring your accounts", "Restoring your apps",
                "Restoring secure data", "Restoring photos and files", "Restoring photos and files",
                "Restoring your apps"};
        String[] setting = {"Setting up app data", "Setting up your accounts", "Setting up your apps",
                "Setting up secure data", "Setting up photos & files", "Setting up photos & files",
                "Setting up your apps"};
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < phases.length; i++) {
            eq("label case " + phases[i] + " restoring", restoring[i], RestorePhase.label(phases[i], false));
            eq("label case " + phases[i] + " creating", setting[i], RestorePhase.label(phases[i], true));
            seen.add(RestorePhase.label(phases[i], true));
            ok(phases[i] + " creating label has no Restor", !RestorePhase.label(phases[i], true).contains("Restor"));
            ok(phases[i] + " restoring label has no &", !RestorePhase.label(phases[i], false).contains("&"));
        }
        for (String p : new String[] {"bogus", null, ""}) {
            eq("default restoring [" + p + "]", "Restoring your profile", RestorePhase.label(p, false));
            eq("default creating [" + p + "]", "Setting up your profile", RestorePhase.label(p, true));
        }
        seen.add(RestorePhase.label("bogus", true));
        ok("six creating labels distinct", seen.size() == 6);
        ok("no creating label contains Restor", !RestorePhase.label("bogus", true).contains("Restor"));

        // H1: the hold table.
        eqi("H1 same label lower -> prev", 80, RestorePhase.hold("A", 80, "A", 10));
        eqi("H1 same label higher -> new", 70, RestorePhase.hold("A", 40, "A", 70));
        eqi("H1 different label lower -> new", 5, RestorePhase.hold("A", 100, "B", 5));
        eqi("H1 null prev -> new", 3, RestorePhase.hold(null, 90, "A", 3));
        eqi("H1 same label equal -> same", 50, RestorePhase.hold("A", 50, "A", 50));

        // H2: a whole sign-in, frame by frame, through label + hold as onRestoreProgress does.
        List<String[]> frames = new ArrayList<>();
        for (String ph : new String[] {"apps", "apps", "secure", "accounts", "media"}) {
            for (int d = 0; d <= 100; d += 25) frames.add(new String[] {ph, "" + d, "100"});
        }
        for (int d = 1; d <= 5; d++) frames.add(new String[] {"finishing", "" + d, "5"});
        for (String ph : new String[] {"appcode", "keys"}) {
            for (int d = 0; d <= 100; d += 25) frames.add(new String[] {ph, "" + d, "100"});
        }
        String prevL = null;
        int prevP = 0;
        List<String> runs = new ArrayList<>();
        boolean monotonic = true, sawProfile = false;
        for (String[] f : frames) {
            int d = Integer.parseInt(f[1]), t = Integer.parseInt(f[2]);
            int pct = t > 0 ? (int) (100L * d / t) : 0;
            String l = RestorePhase.label(f[0], false);
            int shown = RestorePhase.hold(prevL, prevP, l, pct);
            if (l.equals(prevL) && shown < prevP) {
                monotonic = false;
                System.out.println("  H2 " + l + " went back " + prevP + " -> " + shown);
            }
            if (!l.equals(prevL)) runs.add(l);
            if (l.equals("Restoring your profile")) sawProfile = true;
            prevL = l;
            prevP = shown;
        }
        List<String> approved = Arrays.asList("Restoring app data", "Restoring secure data", "Restoring your accounts",
                "Restoring photos and files", "Restoring your apps");
        ok("H2 (i) the labels run in the approved order " + runs, runs.equals(approved));
        ok("H2 (ii) no label comes back " + runs, new HashSet<>(runs).size() == runs.size());
        ok("H2 (iii) within a label the bar never goes back", monotonic);
        ok("H2 (iv) no frame reads Restoring your profile", !sawProfile);

        String src = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        String body = body(src, "private void onRestoreProgress(");
        ok("(a) mirror passes label(phase, true)",
                body.contains("mirrorCreate(RestorePhase.label(phase, true) + "));
        ok("(b) result line passes label(phase, false)",
                body.contains("result.setText(RestorePhase.label(phase, false) + "));
        ok("(c) no Restoring literal in onRestoreProgress", !body.contains("\"Restoring"));
        ok("(c) phaseLabel gone", !src.contains("phaseLabel("));
        ok("(d) onRestoreProgress calls RestorePhase.hold(", body.contains("RestorePhase.hold(restoreBarLabel, restoreBarPct, "));
        ok("(d) the bar shows the held value", body.contains("progressBar.setProgress(shown);"));
        ok("(d) the result line shows the held value",
                body.contains("result.setText(RestorePhase.label(phase, false) + \" — \" + shown + \"%\");"));
        ok("(d) the mirror shows the held value",
                body.contains("mirrorCreate(RestorePhase.label(phase, true) + \" — \" + shown + \"%\", shown);"));
        ok("(d) the held value is stored", body.contains("restoreBarPct = shown;") && body.contains("restoreBarLabel = "));
        ok("(d) nothing paints the raw pct", !body.contains("setProgress(pct)") && !body.contains("+ pct +"));
        String rib = body(src, "private String roamInStreaming(");
        int reset = rib.indexOf("runOnUiThread(() -> { restoreBarLabel = null; restoreBarPct = 0; });");
        int loop = rib.indexOf("while ((line = br.readLine()) != null)");
        ok("(e) roamInStreaming resets the restore bar before its read loop", reset >= 0 && loop > reset);
        if (fails > 0) { System.out.println(fails + " failure(s)"); System.exit(1); }
        System.out.println("restore-phase: all cases passed");
    }
}
