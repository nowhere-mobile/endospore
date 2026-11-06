import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/** NWP-20261011-04: the SET-GATE-ALARM line both relays send, and that the logoff's relay names the alarm's owner.
 *  args: CredentialService.java ProfileActivity.java. Exits 1 on any failed case. */
public final class AlarmRelayCases {
    private static int fails = 0;

    private static void eq(String what, String got, String want) {
        if (want.equals(got)) {
            System.out.println("  ok    " + what);
        } else {
            System.out.println("  FAIL  " + what + ": got [" + got + "] want [" + want + "]");
            fails++;
        }
    }

    private static void has(String what, String body, String needle) {
        if (body.contains(needle)) {
            System.out.println("  ok    " + what);
        } else {
            System.out.println("  FAIL  " + what + ": no [" + needle + "]");
            fails++;
        }
    }

    /** The body of the method whose signature line contains sig, through its closing brace. */
    private static String body(String src, String sig) {
        int i = src.indexOf(sig);
        if (i < 0) return "";
        int depth = 0;
        for (int j = src.indexOf('{', i); j >= 0 && j < src.length(); j++) {
            char c = src.charAt(j);
            if (c == '{') depth++;
            if (c == '}' && --depth == 0) return src.substring(i, j + 1);
        }
        return "";
    }

    public static void main(String[] a) throws Exception {
        eq("C1 an alarm with its owner: time, user and package", Lifted.alarmRelayLine(1760000000000L, 11, "com.android.deskclock"),
                "1760000000000\t11\tcom.android.deskclock");
        eq("C2 no alarm: 0 alone (the daemon's clear)", Lifted.alarmRelayLine(0L, 11, "com.android.deskclock"), "0");
        eq("C3 no owner: the time alone", Lifted.alarmRelayLine(5L, 11, null), "5");
        eq("C4 an empty owner: the time alone", Lifted.alarmRelayLine(5L, 11, ""), "5");
        eq("C5 an unknown user: the time alone, never a wrong pair", Lifted.alarmRelayLine(5L, -1, "com.x"), "5");

        int[] n = {0};
        n[0] = 0;
        eq("R1 the first reply OK: true", String.valueOf(Lifted.relayLanded(() -> { n[0]++; return "OK"; }, 2)), "true");
        eq("R1 after one call", String.valueOf(n[0]), "1");
        n[0] = 0;
        eq("R2 \"\" then OK: true", String.valueOf(Lifted.relayLanded(() -> n[0]++ == 0 ? "" : "OK", 2)), "true");
        eq("R2 after two calls", String.valueOf(n[0]), "2");
        n[0] = 0;
        eq("R3 ERR twice: false", String.valueOf(Lifted.relayLanded(() -> { n[0]++; return "ERR"; }, 2)), "false");
        eq("R3 after two calls", String.valueOf(n[0]), "2");
        n[0] = 0;
        Lifted.relayLanded(() -> { n[0]++; return ""; }, 3);
        eq("R4 never more than tries calls", String.valueOf(n[0]), "3");
        String r5;
        try {
            r5 = String.valueOf(Lifted.relayLanded(() -> null, 2));
        } catch (RuntimeException e) {
            r5 = "threw " + e;
        }
        eq("R5 a null reply: false, no exception", r5, "false");

        String pa = new String(Files.readAllBytes(Paths.get(a[1])), StandardCharsets.UTF_8);
        String cap = body(pa, "private void captureNextAlarm()");
        has("C6 the logoff relay reads the alarm's owner", cap, "pkg = ac.getShowIntent().getCreatorPackage();");
        has("C7 the logoff relay sends the shared line, owner and user included", cap,
                "CredentialService.alarmRelayLine(when, CredentialService.myUserId(), pkg)");
        has("C8 the logoff relay sends that line", cap, "sendDaemon(\"SET-GATE-ALARM\\n\" + line + \"\\n\")");
        String cs = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        has("C9 the periodic relay sends the same line", body(cs, "private static void relayNextAlarm("),
                "String line = alarmRelayLine(when, myUserId(), pkg);");
        String rn = body(cs, "private static void relayNextAlarm(");
        has("C10 relayNextAlarm retries twice through relayLanded", rn,
                "relayLanded(() -> DaemonSocket.roundTrip(\"SET-GATE-ALARM\\n\" + line + \"\\n\", 8000), 2)");
        eq("C10 exactly one relayLanded call", String.valueOf(rn.split("relayLanded\\(\\(\\) ->", -1).length - 1), "1");
        eq("C10 exactly one roundTrip call", String.valueOf(rn.split("DaemonSocket\\.roundTrip\\(", -1).length - 1), "1");
        int li = rn.indexOf("\"#151 relayed next alarm");
        int ifi = rn.indexOf("if (landed) {");
        int el = rn.indexOf("} else {");
        eq("C10 the relayed log sits inside if (landed)", String.valueOf(ifi >= 0 && li > ifi && el > li), "true");
        if (fails > 0) {
            System.out.println("  -- " + fails + " failed");
            System.exit(1);
        }
        System.out.println("  -- all passed");
    }
}
