package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Locale;
import java.util.regex.Pattern;

/** NWP-20261210-11: CallRelaySpike (R0) under javac, alone. Exit 0 all pass, 1 a case failed. */
public final class CallRelaySpikeCases {
    private static int failed = 0;

    private static void check(String id, boolean ok, String what) {
        if (ok) {
            System.out.println("ok " + id + " " + what);
        } else {
            System.out.println("FAIL " + id + " " + what);
            failed++;
        }
    }

    private static String show(String s) {
        return s == null ? "null" : "\"" + s + "\"";
    }

    private static void modes(String id, String in, int[] want) {
        int[] got = CallRelaySpike.parseModes(in);
        check(id, Arrays.equals(got, want), "parseModes(" + show(in) + ") = " + Arrays.toString(got)
                + ", want " + Arrays.toString(want));
    }

    private static void near(String id, double got, double want, double tol, String what) {
        check(id, Math.abs(got - want) <= tol, what + " = " + got + ", want " + want + " +-" + tol);
    }

    private static void line(String id, String got, String regex) {
        check(id, Pattern.matches(regex, got), "line \"" + got + "\" matches " + regex);
    }

    public static void main(String[] args) {
        // A1/A2: only exactly "1" is debuggable.
        check("A1", CallRelaySpike.allowed("1"), "allowed(\"1\")");
        for (String d : new String[] {"0", "", null, "true", " 1", "1 "}) {
            check("A2", !CallRelaySpike.allowed(d), "allowed(" + show(d) + ") is refused");
        }

        // M1/M2: only 4 and 5, first occurrence, at most two; nothing valid gives {5, 4}.
        int[] dflt = {5, 4};
        modes("M1", null, dflt);
        modes("M1", "", dflt);
        modes("M1", "2,3,x", dflt);
        modes("M2", "4", new int[] {4});
        modes("M2", "5,4,5", new int[] {5, 4});
        modes("M2", "4,5", new int[] {4, 5});

        // C1: 0 is unset (20); everything else bounded to 5..60.
        check("C1", CallRelaySpike.clampSecs(0) == 20, "clampSecs(0) = 20");
        check("C1", CallRelaySpike.clampSecs(1) == 5, "clampSecs(1) = 5");
        check("C1", CallRelaySpike.clampSecs(999) == 60, "clampSecs(999) = 60");

        // D1: silence is the floor; a full-scale square is ~0 dBFS; an amp-0.5 sine is ~-9.0 dBFS.
        check("D1", CallRelaySpike.dbfs(new short[4800], 4800) == -120.0, "dbfs(zeros) = -120.0");
        check("D1", CallRelaySpike.dbfs(new short[16], 0) == -120.0, "dbfs(n = 0) = -120.0");
        short[] sq = new short[4800];
        for (int i = 0; i < sq.length; i++) sq[i] = (short) ((i / 24) % 2 == 0 ? 32767 : -32768);
        near("D1", CallRelaySpike.dbfs(sq, sq.length), 0.0, 0.1, "dbfs(full-scale square)");
        short[] half = CallRelaySpike.tone(48000, 1, 1000, 4800, 0.5);
        near("D1", CallRelaySpike.dbfs(half, half.length), -9.0, 0.2, "dbfs(amp-0.5 sine)");

        // T1: interleaved stereo, every channel equal, peak within amp * 32767.
        double amp = 0.25;
        short[] t = CallRelaySpike.tone(48000, 2, 1000, 4800, amp);
        boolean eq = t.length == 9600;
        int peak = 0;
        for (int i = 0; i + 1 < t.length; i += 2) {
            if (t[i] != t[i + 1]) eq = false;
            peak = Math.max(peak, Math.abs(t[i]));
        }
        check("T1", eq, "tone(48000, 2, 1000 Hz) has 9600 samples and equal channels");
        check("T1", peak > 0 && peak <= amp * 32767, "tone peak " + peak + " <= " + (amp * 32767));

        // L1: every line is digits, '-', '.' and fixed tokens, in any default locale.
        for (Locale loc : new Locale[] {Locale.ROOT, Locale.GERMANY, Locale.forLanguageTag("ar-EG")}) {
            Locale.setDefault(loc);
            line("L1", CallRelaySpike.startLine(true, false, 1, false, true),
                    "spike: start interceptable=[01] screening=[01] mode=-?[0-9]+ recGranted=[01] ringing=[01]");
            line("L1", CallRelaySpike.modeLine(5, 2), "spike: setMode asked=[0-9]+ got=-?[0-9]+");
            line("L1", CallRelaySpike.modeErrLine(5, "SecurityException"),
                    "spike: setMode asked=[0-9]+ threw=[A-Za-z0-9_]+");
            line("L1", CallRelaySpike.modeErrLine(4, "Bad: +15551234567 text"),
                    "spike: setMode asked=[0-9]+ threw=[A-Za-z0-9_]+");
            line("L1", CallRelaySpike.errLine("downlink", null), "spike: downlink failed [A-Za-z0-9_]+");
            String sec = "spike: s=[0-9]+ mode=-?[0-9]+ mute=[01] silenced=(0|1|-1) downlink_dbfs=-?[0-9]+\\.[0-9]"
                    + " uplink_head=-?[0-9]+ underruns=-?[0-9]+";
            line("L1", CallRelaySpike.secondLine(3, 5, true, 0, -28.456, 48000, 0), sec);
            line("L1", CallRelaySpike.secondLine(0, 4, false, 1, -0.04, 0, 2), sec);
            line("L1", CallRelaySpike.secondLine(29, 2, true, -1, Double.NaN, -1, -1), sec);
            line("L1", CallRelaySpike.secondLine(1, 2, true, 7, -500.0, 1, 1), sec);
            line("L1", CallRelaySpike.endLine(0, false), "spike: end mode=-?[0-9]+ mute=[01]");
            check("L1", CallRelaySpike.secondLine(3, 5, true, 0, -28.456, 48000, 0).equals(
                    "spike: s=3 mode=5 mute=1 silenced=0 downlink_dbfs=-28.5 uplink_head=48000 underruns=0"),
                    "secondLine's exact text under locale " + loc.toLanguageTag());
        }
        Locale.setDefault(Locale.ROOT);
        check("L1", CallRelaySpike.REFUSED.equals("spike: refused (ro.debuggable is not 1)"), "REFUSED text");
        check("L1", CallRelaySpike.TAG.equals("NowhereRelaySpike"), "TAG");
        check("L1", CallRelaySpike.MODE_CALL_SCREENING == 4 && CallRelaySpike.MODE_CALL_REDIRECT == 5,
                "MODE_CALL_SCREENING = 4, MODE_CALL_REDIRECT = 5");
        System.exit(failed == 0 ? 0 : 1);
    }
}
