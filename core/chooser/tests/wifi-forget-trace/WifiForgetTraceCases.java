package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;

/** NWP-20261205-17: the cases for WifiForgetTrace, run by core/vendor-common/bin/test-wifi-forget-trace-java.sh. Each
 *  run is a fresh JVM, so the class's RAM state starts empty. The cases run in order. */
public class WifiForgetTraceCases {
    static int fails;

    static void check(String name, boolean ok) {
        System.out.println((ok ? "--- PASS: " : "--- FAIL: ") + name);
        if (!ok) fails++;
    }

    /** A fake radio: connectedNetId() returns each of {@code ids} in turn (the last one repeats), so the connection can
     *  change between two reads; the configured list maps id 1 to caseNetA and id 2 to caseNetB. */
    static final class Radio implements WifiForget.Ops {
        final int[] ids;
        final boolean removeOk;
        int reads;
        int removedId = -1;

        Radio(boolean removeOk, int... ids) { this.removeOk = removeOk; this.ids = ids; }

        @Override public int connectedNetId() { return ids[Math.min(reads++, ids.length - 1)]; }
        @Override public boolean remove(int netId) { removedId = netId; return removeOk; }
        @Override public void disconnect() {}

        String ssidOf(int netId) { return netId == 1 ? "caseNetA" : netId == 2 ? "caseNetB" : null; }
    }

    /** Runs one Forget the way forgetWifi does (WifiForget.run, its remove through removeAndLookup) and returns {reply, removed SSID}. */
    static String[] forget(Radio radio, WifiForgetTrace.SsidLookup lookup) {
        String[] removed = new String[1];
        String r = WifiForget.run(new WifiForget.Ops() {
            @Override public int connectedNetId() { return radio.connectedNetId(); }
            @Override public boolean remove(int netId) {
                return WifiForgetTrace.removeAndLookup(netId, radio::remove, lookup, removed);
            }
            @Override public void disconnect() { radio.disconnect(); }
        });
        if (r.startsWith("OK") && removed[0] != null) WifiForgetTrace.forgot(removed[0]);
        return new String[] {r, removed[0]};
    }

    static void bindCases() {
        // B1: the lookup sees the id the removal gets, even when the connection changes after the first read.
        Radio flip = new Radio(true, 2, 1);
        int[] asked = {-1};
        String[] got = forget(flip, id -> { flip.reads++; asked[0] = id; return flip.ssidOf(id); });
        check("B1 a connection change after the read: the reply is OK", "OK".equals(got[0]));
        check("B1 the lookup asks for the removed id (2)", flip.removedId == 2 && asked[0] == 2);
        check("B1 the removed SSID is the removed network's (caseNetB)", "caseNetB".equals(got[1]));
        check("B1 the trace holds the removed network", WifiForgetTrace.readdCount(Arrays.asList("caseNetB")) == 1);
        check("B1 the trace does not hold the network that became connected",
                WifiForgetTrace.readdCount(Arrays.asList("caseNetA")) == 0);

        // B2: a refused removal records nothing; a lookup that throws records nothing and leaves the reply OK.
        Radio refused = new Radio(false, 1);
        got = forget(refused, refused::ssidOf);
        check("B2 a refused removal answers ERR refused", "ERR refused".equals(got[0]));
        check("B2 a refused removal leaves no SSID", got[1] == null);
        check("B2 a refused removal is not in the trace", WifiForgetTrace.readdCount(Arrays.asList("caseNetA")) == 0);
        Radio thrown = new Radio(true, 1);
        got = forget(thrown, id -> { throw new SecurityException("no list"); });
        check("B3 a lookup that throws leaves the reply OK", "OK".equals(got[0]) && thrown.removedId == 1);
        check("B3 a lookup that throws leaves no SSID", got[1] == null);
        Radio none = new Radio(true, -1);
        got = forget(none, none::ssidOf);
        check("B4 not connected: ERR not connected and no SSID", "ERR not connected".equals(got[0]) && got[1] == null);
        check("B4 not connected: the trace is unchanged", WifiForgetTrace.readdCount(Arrays.asList("caseNetA")) == 0);
    }

    public static void main(String[] a) {
        check("F1 forgetVerb(false, 0) is wifi-forget-err", "wifi-forget-err".equals(WifiForgetTrace.forgetVerb(false, 0)));
        check("F1 forgetVerb(false, 2) is wifi-forget-err", "wifi-forget-err".equals(WifiForgetTrace.forgetVerb(false, 2)));
        check("F2 forgetVerb(true, 1) is wifi-forget-midadopt", "wifi-forget-midadopt".equals(WifiForgetTrace.forgetVerb(true, 1)));
        check("F2 forgetVerb(true, 3) is wifi-forget-midadopt", "wifi-forget-midadopt".equals(WifiForgetTrace.forgetVerb(true, 3)));
        check("F3 forgetVerb(true, 0) is wifi-forget", "wifi-forget".equals(WifiForgetTrace.forgetVerb(true, 0)));

        check("C1 collectVerb(true) is wifi-collect-parked", "wifi-collect-parked".equals(WifiForgetTrace.collectVerb(true)));
        check("C2 collectVerb(false) is wifi-collect", "wifi-collect".equals(WifiForgetTrace.collectVerb(false)));

        check("R1 readdVerb(0) is wifi-readd", "wifi-readd".equals(WifiForgetTrace.readdVerb(0)));
        check("R2 readdVerb(1) is wifi-readd-late", "wifi-readd-late".equals(WifiForgetTrace.readdVerb(1)));
        check("R2 readdVerb(2) is wifi-readd-late", "wifi-readd-late".equals(WifiForgetTrace.readdVerb(2)));

        check("D1 nothing forgotten: readdCount([caseA, caseB]) is 0",
                WifiForgetTrace.readdCount(Arrays.asList("caseA", "caseB")) == 0);
        WifiForgetTrace.forgot("caseA");
        check("D2 caseA forgotten: readdCount([caseA, caseB]) is 1",
                WifiForgetTrace.readdCount(Arrays.asList("caseA", "caseB")) == 1);
        check("D2 an unforgotten SSID alone counts 0", WifiForgetTrace.readdCount(Arrays.asList("caseB")) == 0);
        check("D3 a duplicate counts once: readdCount([caseA, caseA]) is 1",
                WifiForgetTrace.readdCount(Arrays.asList("caseA", "caseA")) == 1);
        check("D4 a null list counts 0", WifiForgetTrace.readdCount(null) == 0);
        check("D4 a null entry is ignored: readdCount([null, caseA]) is 1",
                WifiForgetTrace.readdCount(Arrays.asList(null, "caseA")) == 1);
        WifiForgetTrace.forgot(null);
        WifiForgetTrace.forgot("");
        check("D5 forgot(\"\") adds nothing: readdCount([\"\"]) is 0",
                WifiForgetTrace.readdCount(Collections.singletonList("")) == 0);
        check("D5 forgot(null) does not throw and adds nothing",
                WifiForgetTrace.readdCount(Arrays.asList("caseA", "caseC")) == 1);

        check("I1 inFlight() is 0 at start", WifiForgetTrace.inFlight() == 0);
        WifiForgetTrace.adoptStarted();
        WifiForgetTrace.adoptStarted();
        check("I2 two starts give 2", WifiForgetTrace.inFlight() == 2);
        WifiForgetTrace.adoptFinished();
        check("I2 a finish gives 1", WifiForgetTrace.inFlight() == 1);
        WifiForgetTrace.adoptFinished();
        check("I2 a second finish gives 0", WifiForgetTrace.inFlight() == 0);
        WifiForgetTrace.adoptFinished();
        check("I3 a finish without a start stays 0", WifiForgetTrace.inFlight() == 0);
        WifiForgetTrace.adoptStarted();
        check("I3 a start after it gives 1, not 0", WifiForgetTrace.inFlight() == 1);
        WifiForgetTrace.adoptFinished();

        check("K1 clampCount(-1) is 0", WifiForgetTrace.clampCount(-1) == 0);
        check("K2 clampCount(0) is 0", WifiForgetTrace.clampCount(0) == 0);
        check("K3 clampCount(32) is 32", WifiForgetTrace.clampCount(32) == 32);
        check("K4 clampCount(33) is 32", WifiForgetTrace.clampCount(33) == 32);

        bindCases();

        System.exit(fails == 0 ? 0 : 1);
    }
}
