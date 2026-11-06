package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashSet;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** NWP-20261028-13: the cases for GateAlarmVerbs. main(args[0]) = core/agent/gate_log.go. Exit 0 pass, 1 a case failed. */
public class GateAlarmVerbsCases {
    static int fails = 0;
    static final Set<String> seen = new HashSet<>();

    static void eq(String name, Object want, Object got) {
        if (got instanceof String) seen.add((String) got);
        if (want == null ? got == null : want.equals(got)) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + ": want " + want + " got " + got); fails++; }
    }

    public static void main(String[] args) throws Exception {
        final long now = 1_800_000_000_000L;
        for (String r : new String[]{"OK", "OK\n", " OK ", "OK\nmore"}) eq("silence(" + r.replace("\n", "\\n") + ")", "ui-silence-ok", GateAlarmVerbs.silence(r));
        for (String r : new String[]{"ERR-LIVE", "NONE", "ERR-STALE", "ERR-NOREPLY", "OKAY"}) eq("silence(" + r + ")", "ui-silence-refused", GateAlarmVerbs.silence(r));
        eq("silence(empty)", "ui-silence-empty", GateAlarmVerbs.silence(""));
        eq("silence(null)", "ui-silence-empty", GateAlarmVerbs.silence(null));

        eq("consume(0)", null, GateAlarmVerbs.consume("0", now));
        eq("consume(empty)", null, GateAlarmVerbs.consume("", now));
        eq("consume(null)", null, GateAlarmVerbs.consume(null, now));
        eq("consume(future)", "consume", GateAlarmVerbs.consume(Long.toString(now + 90_000), now));
        eq("consume(now)", "consume-past", GateAlarmVerbs.consume(Long.toString(now), now));
        eq("consume(past)", "consume-past", GateAlarmVerbs.consume(Long.toString(now - 30_000), now));
        eq("consume(abc)", "armed-err", GateAlarmVerbs.consume("abc", now));

        eq("inSeconds(+90s)", 90, GateAlarmVerbs.inSeconds(now + 90_000, now));
        eq("inSeconds(-30s)", -30, GateAlarmVerbs.inSeconds(now - 30_000, now));
        eq("inSeconds(clamp high)", Integer.MAX_VALUE, GateAlarmVerbs.inSeconds(now + 3_000_000_000_000L, now));
        eq("inSeconds(clamp low)", Integer.MIN_VALUE, GateAlarmVerbs.inSeconds(now - 3_000_000_000_000L, now));
        eq("inSeconds(overflow)", Integer.MAX_VALUE, GateAlarmVerbs.inSeconds(Long.MAX_VALUE, Long.MIN_VALUE));

        eq("arm(true,false)", "armed", GateAlarmVerbs.arm(true, false));
        eq("arm(true,true)", "armed", GateAlarmVerbs.arm(true, true));
        eq("arm(false,true)", "armed-inexact", GateAlarmVerbs.arm(false, true));
        eq("arm(false,false)", "armed-err", GateAlarmVerbs.arm(false, false));

        for (String s : seen) {
            boolean in = false;
            for (String v : GateAlarmVerbs.VERBS) in |= v.equals(s);
            if (in) System.out.println("--- PASS: VERBS lists " + s);
            else { System.out.println("--- FAIL: VERBS lacks " + s); fails++; }
        }

        // The daemon records a verb outside gateLogVerbs as trace-unknown: every verb we can send must be in the map.
        String go = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);
        int a = go.indexOf("var gateLogVerbs = map[string]bool{");
        if (a < 0) { System.out.println("--- FAIL: map: gateLogVerbs not found in " + args[0]); System.exit(1); }
        int b = go.indexOf("\n}", a);
        Set<String> map = new HashSet<>();
        Matcher m = Pattern.compile("\"([a-z-]+)\":\\s*true").matcher(go.substring(a, b));
        while (m.find()) map.add(m.group(1));
        Set<String> sent = new HashSet<>(java.util.Arrays.asList(GateAlarmVerbs.VERBS));
        sent.add("cancel-login"); sent.add("cancel-dismiss"); sent.add("ui-vibrate-err"); sent.add("ui-guard-err");
        for (String v : sent) {
            if (map.contains(v)) System.out.println("--- PASS: map: " + v);
            else { System.out.println("--- FAIL: map: " + v + " not in gateLogVerbs (the daemon would record trace-unknown)"); fails++; }
        }
        System.exit(fails == 0 ? 0 : 1);
    }
}
