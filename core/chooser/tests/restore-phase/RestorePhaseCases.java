package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashSet;
import java.util.Set;

/** NWP-20261027-11: RestorePhase.label in both modes, plus the wiring pins in ChooserActivity.onRestoreProgress. */
public class RestorePhaseCases {
    static int fails = 0;

    static void eq(String what, String want, String got) {
        if (!want.equals(got)) { fails++; System.out.println("FAIL " + what + ": want [" + want + "] got [" + got + "]"); }
    }

    static void ok(String what, boolean c) {
        if (!c) { fails++; System.out.println("FAIL " + what); }
    }

    public static void main(String[] a) throws Exception {
        String[] phases = {"apps", "accounts", "appcode", "secure", "media"};
        String[] restoring = {"Restoring app data", "Restoring your accounts", "Restoring your apps",
                "Restoring secure data", "Restoring photos & files"};
        String[] setting = {"Setting up app data", "Setting up your accounts", "Setting up your apps",
                "Setting up secure data", "Setting up photos & files"};
        Set<String> seen = new HashSet<>();
        for (int i = 0; i < phases.length; i++) {
            eq(phases[i] + " restoring", restoring[i], RestorePhase.label(phases[i], false));
            eq(phases[i] + " creating", setting[i], RestorePhase.label(phases[i], true));
            seen.add(RestorePhase.label(phases[i], true));
            ok(phases[i] + " creating label has no Restor", !RestorePhase.label(phases[i], true).contains("Restor"));
        }
        for (String p : new String[] {"bogus", null, ""}) {
            eq("default restoring [" + p + "]", "Restoring your profile", RestorePhase.label(p, false));
            eq("default creating [" + p + "]", "Setting up your profile", RestorePhase.label(p, true));
        }
        seen.add(RestorePhase.label("bogus", true));
        ok("six creating labels distinct", seen.size() == 6);
        ok("no creating label contains Restor", !RestorePhase.label("bogus", true).contains("Restor"));

        String src = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        int s = src.indexOf("private void onRestoreProgress(");
        ok("onRestoreProgress found", s >= 0);
        int e = src.indexOf("\n    }\n", s);
        ok("onRestoreProgress end found", e > s);
        String body = s >= 0 && e > s ? src.substring(s, e) : "";
        ok("(a) mirror passes label(phase, true)",
                body.contains("mirrorCreate(RestorePhase.label(phase, true) + "));
        ok("(b) result line passes label(phase, false)",
                body.contains("result.setText(RestorePhase.label(phase, false) + "));
        ok("(c) no Restoring literal in onRestoreProgress", !body.contains("\"Restoring"));
        ok("(c) phaseLabel gone", !src.contains("phaseLabel("));
        if (fails > 0) { System.out.println(fails + " failure(s)"); System.exit(1); }
        System.out.println("restore-phase: all cases passed");
    }
}
