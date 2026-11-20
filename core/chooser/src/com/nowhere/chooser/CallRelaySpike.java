package com.nowhere.chooser;

import java.util.Locale;

/**
 * NWP-20261210-11: slice R0 of docs/call-relay.md section 14, the pure half of the call-relay spike.
 *
 * WHAT IT ANSWERS. The 2026-11-17 lynx spike (call-relay.md section 2) answered a SIM call, captured its downlink and
 * injected its uplink as root through app_process. It could not test MODE_CALL_REDIRECT (5) or MODE_CALL_SCREENING (4),
 * which keep phone A's earpiece out of the call: setMode threw in a context with no package. R0 runs the same steps from
 * the chooser, a real platform-signed app that holds CALL_AUDIO_INTERCEPTION. Its run answers the "Not tested" rows of
 * section 2 and the first three inferences of section 15.
 *
 * WHY DEBUG-ONLY. The verb answers a call and takes its audio. CallRelaySpikeReceiver refuses it unless ro.debuggable is
 * exactly "1" (allowed below), and the receiver is not exported and has no intent-filter. A user build therefore carries
 * no new behaviour. The receiver answers through TelecomManager.acceptRingingCall, never through the control service.
 *
 * WHAT IT LOGS. Modes, counts and dBFS levels only, through the fixed line builders below. No line carries a number, a
 * caller, a profile or an app. An exception is logged by its simple class name, never by its message.
 *
 * THE RUN (step 4; a human does it, the farm does not):
 *   1. lynx userdebug with two SIMs; `adb root`.
 *   2. Call SIM A from the far end (or from the other SIM). While it rings:
 *      `adb shell am broadcast --user 0 -n com.nowhere.chooser/.CallRelaySpikeReceiver --es modes 5,4 --ei secs 30`
 *   3. Read `adb logcat -s NowhereRelaySpike`. If recGranted=0 and the record fails, run
 *      `adb shell pm grant com.nowhere.chooser android.permission.RECORD_AUDIO` and do the run again.
 *   4. The far end listens for the tone and for room sound. At phone A a human checks that the earpiece is silent, then
 *      toggles the speaker, then connects a wired headset. The per-second mode shows whether it holds through each route.
 *   5. Do it again with `--es modes 4`. Do both at the gate and with a roamed session in front.
 *   6. The human ends each call: the spike never hangs up. The human writes the findings in docs/call-relay.md.
 *
 * Pure: java.* only, so tests/call-relay-spike/CallRelaySpikeCases.java compiles it alone under javac.
 */
final class CallRelaySpike {

    private CallRelaySpike() {}

    static final String TAG = "NowhereRelaySpike";

    /** AudioManager.MODE_CALL_SCREENING and AudioManager.MODE_CALL_REDIRECT: the same values, copied so this stays pure. */
    static final int MODE_CALL_SCREENING = 4, MODE_CALL_REDIRECT = 5;

    static final String REFUSED = "spike: refused (ro.debuggable is not 1)";
    static final String BUSY = "spike: busy";
    static final String ANSWERED = "spike: answered";
    static final String NO_CALL = "spike: no call";

    /** Full scale of PCM16, and the floor that stands for silence. */
    static final double FULL_SCALE = 32768.0, FLOOR_DBFS = -120.0;

    /** True only for exactly "1". A denied or empty read is "0" (the receiver's default): fail closed. */
    static boolean allowed(String debuggable) {
        return "1".equals(debuggable);
    }

    /** A comma list of modes. Keeps only 4 and 5, in order, each once, at most two. Nothing valid gives {5, 4}. */
    static int[] parseModes(String s) {
        int[] out = new int[2];
        int n = 0;
        if (s != null) {
            for (String part : s.split(",", -1)) {
                if (n == 2) break;
                int m;
                try {
                    m = Integer.parseInt(part.trim());
                } catch (NumberFormatException e) {
                    continue;
                }
                if (m != MODE_CALL_SCREENING && m != MODE_CALL_REDIRECT) continue;
                if (n == 1 && out[0] == m) continue;
                out[n++] = m;
            }
        }
        if (n == 0) return new int[] {MODE_CALL_REDIRECT, MODE_CALL_SCREENING};
        if (n == 1) return new int[] {out[0]};
        return out;
    }

    /** The run length in seconds: 0 (unset) is 20; every other value is bounded to 5..60. */
    static int clampSecs(int s) {
        if (s == 0) return 20;
        return Math.max(5, Math.min(60, s));
    }

    /** RMS of the first n samples of b in dBFS (full scale 32768), floored at -120.0. Silence and n <= 0 give -120.0. */
    static double dbfs(short[] b, int n) {
        if (b == null) return FLOOR_DBFS;
        int k = Math.min(n, b.length);
        if (k <= 0) return FLOOR_DBFS;
        double sum = 0;
        for (int i = 0; i < k; i++) {
            double v = b[i];
            sum += v * v;
        }
        double rms = Math.sqrt(sum / k);
        if (rms <= 0) return FLOOR_DBFS;
        double db = 20.0 * Math.log10(rms / FULL_SCALE);
        return db < FLOOR_DBFS ? FLOOR_DBFS : db;
    }

    /** An interleaved PCM16 sine of `frames` frames, every channel equal, peak amp * 32767 (amp bounded to 0..1). */
    static short[] tone(int rate, int channels, int hz, int frames, double amp) {
        int ch = Math.max(1, channels);
        int fr = Math.max(0, frames);
        double a = Math.max(0.0, Math.min(1.0, amp)) * 32767.0;
        short[] out = new short[fr * ch];
        if (rate <= 0) return out;
        for (int i = 0; i < fr; i++) {
            short v = (short) (a * Math.sin(2.0 * Math.PI * hz * i / rate)); // truncates toward 0: |v| <= a
            for (int c = 0; c < ch; c++) out[i * ch + c] = v;
        }
        return out;
    }

    private static int bit(boolean b) {
        return b ? 1 : 0;
    }

    /** A simple class name kept to [A-Za-z0-9_], at most 64 characters, so no exception text reaches a log. */
    static String className(String simpleName) {
        StringBuilder sb = new StringBuilder();
        if (simpleName != null) {
            for (int i = 0; i < simpleName.length() && sb.length() < 64; i++) {
                char c = simpleName.charAt(i);
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') sb.append(c);
            }
        }
        return sb.length() == 0 ? "Throwable" : sb.toString();
    }

    static String startLine(boolean interceptable, boolean screeningSupported, int mode, boolean recGranted,
            boolean ringing) {
        return String.format(Locale.ROOT, "spike: start interceptable=%d screening=%d mode=%d recGranted=%d ringing=%d",
                bit(interceptable), bit(screeningSupported), mode, bit(recGranted), bit(ringing));
    }

    static String modeLine(int asked, int got) {
        return String.format(Locale.ROOT, "spike: setMode asked=%d got=%d", asked, got);
    }

    static String modeErrLine(int asked, String exClass) {
        return String.format(Locale.ROOT, "spike: setMode asked=%d threw=%s", asked, className(exClass));
    }

    /** A step that failed: what is one of the fixed words the receiver passes (setup, thread, downlink, uplink). */
    static String errLine(String what, String exClass) {
        return String.format(Locale.ROOT, "spike: %s failed %s", className(what), className(exClass));
    }

    /** silenced is 1 or 0 from the record's active configuration, -1 when there is none (not a quiet caller). */
    static String secondLine(int s, int mode, boolean mute, int silenced, double dbfs, int head, int underruns) {
        int sil = silenced == 0 || silenced == 1 ? silenced : -1;
        double d = Double.isNaN(dbfs) || dbfs < FLOOR_DBFS ? FLOOR_DBFS : dbfs;
        return String.format(Locale.ROOT,
                "spike: s=%d mode=%d mute=%d silenced=%d downlink_dbfs=%.1f uplink_head=%d underruns=%d",
                s, mode, bit(mute), sil, d, head, underruns);
    }

    static String endLine(int mode, boolean mute) {
        return String.format(Locale.ROOT, "spike: end mode=%d mute=%d", mode, bit(mute));
    }
}
