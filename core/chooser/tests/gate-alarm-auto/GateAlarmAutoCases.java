package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * NWP-20261116-12: the cases for GateAlarmAuto. main(args) = gate_log.go, then the chooser sources whose
 * GateTrace.ev("...") literals must all be gateLogVerbs keys. Exit 0 pass, 1 a case failed.
 */
public class GateAlarmAutoCases {
    static int fails = 0;

    static void eq(String name, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + ": want " + want + " got " + got); fails++; }
    }

    public static void main(String[] args) throws Exception {
        eq("RING_MS is 10 minutes", 600_000L, GateAlarmAuto.RING_MS);
        eq("MAX_AUTO_SNOOZES", 3, GateAlarmAuto.MAX_AUTO_SNOOZES);
        eq("EXTRA", "com.nowhere.chooser.extra.AUTO_SNOOZES", GateAlarmAuto.EXTRA);

        // A run of unattended rings from a fresh alarm: each ring that snoozes re-arms with next(n).
        List<Integer> armed = new ArrayList<>();
        int n = 0, steps = 0;
        while (GateAlarmAuto.snoozes(n) && steps++ < 10) { n = GateAlarmAuto.next(n); armed.add(n); }
        eq("unattended run: three automatic snoozes carry 1, 2, 3", Arrays.asList(1, 2, 3), armed);
        eq("unattended run: the fourth unattended ring dismisses", false, GateAlarmAuto.snoozes(n));

        eq("snoozes(0)", true, GateAlarmAuto.snoozes(0));
        eq("snoozes(2)", true, GateAlarmAuto.snoozes(2));
        eq("snoozes(3)", false, GateAlarmAuto.snoozes(3));
        eq("sane(-5)", 0, GateAlarmAuto.sane(-5));
        eq("sane(0)", 0, GateAlarmAuto.sane(0));
        eq("sane(2)", 2, GateAlarmAuto.sane(2));
        eq("sane(99)", 3, GateAlarmAuto.sane(99));
        eq("snoozes(99) dismisses", false, GateAlarmAuto.snoozes(99));
        eq("next(-5)", 1, GateAlarmAuto.next(-5));

        // The daemon records a verb outside gateLogVerbs as trace-unknown.
        String go = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);
        int a = go.indexOf("var gateLogVerbs = map[string]bool{");
        if (a < 0) { System.out.println("--- FAIL: map: gateLogVerbs not found in " + args[0]); System.exit(1); }
        int b = go.indexOf("\n}", a);
        Set<String> map = new HashSet<>();
        Matcher m = Pattern.compile("\"([a-z-]+)\":\\s*true").matcher(go.substring(a, b));
        while (m.find()) map.add(m.group(1));
        for (String v : new String[]{"ui-auto-snooze", "ui-auto-dismiss"}) {
            if (map.contains(v)) System.out.println("--- PASS: map: " + v);
            else { System.out.println("--- FAIL: map: " + v + " not in gateLogVerbs (the daemon would record trace-unknown)"); fails++; }
        }
        for (int i = 1; i < args.length; i++) {
            String src = new String(Files.readAllBytes(Paths.get(args[i])), StandardCharsets.UTF_8)
                    .replaceAll("(?s)/\\*.*?\\*/", "").replaceAll("//[^\\n]*", "");
            Matcher e = Pattern.compile("GateTrace\\.ev\\(\"([^\"]*)\"").matcher(src);
            int found = 0;
            while (e.find()) {
                found++;
                String v = e.group(1);
                if (map.contains(v)) System.out.println("--- PASS: map: " + Paths.get(args[i]).getFileName() + " sends " + v);
                else { System.out.println("--- FAIL: map: " + Paths.get(args[i]).getFileName() + " sends " + v + ", not in gateLogVerbs"); fails++; }
            }
            if (found == 0) { System.out.println("--- FAIL: map: no GateTrace.ev literal in " + args[i]); fails++; }
        }
        System.exit(fails == 0 ? 0 : 1);
    }
}
