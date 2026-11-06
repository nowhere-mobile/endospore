package com.nowhere.chooser;

import java.util.function.BooleanSupplier;
import java.util.function.Supplier;

/** NWP-20261021-02: executes IdleLockGate.decide, the idle cold lock's whole pre-commit decision. */
public class IdleLockGateCases {
    static int runs = 0, fails = 0;

    static final long MIN = 60_000L;
    static final long NOW = 10 * 60 * MIN;
    static final long CAP = 3_600_000L;

    static void check(String name, boolean ok, String got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final class Claim implements BooleanSupplier {
        final boolean answer;
        int calls = 0;
        Claim(boolean answer) { this.answer = answer; }
        public boolean getAsBoolean() { calls++; return answer; }
    }

    static class Sweep implements Supplier<String> {
        final String reply;
        int calls = 0;
        Sweep(String reply) { this.reply = reply; }
        public String get() { calls++; return reply; }
    }

    /** One call's inputs; the defaults are the base case: live, locked, screen off, on time, no call info. */
    static final class In {
        boolean live = true, locked = true, screenOn = false, hold = false;
        long lateBy = 0, heldSince = 0;
        Boolean inCall = null;
        Claim claim = new Claim(true);
        Sweep sweep = new Sweep("LIVE 3");
        java.util.function.LongSupplier clock = () -> NOW;
        // NWP-20261120-02: the audio hold's real default: on, nothing playing, the 2 h cap, the 15 min standby.
        boolean holdAudio = true, audioHolding = false;
        Boolean audio = Boolean.FALSE;
        long audioCap = 120 * MIN, standby = 15 * MIN;
        IdleLockGate.Verdict run() {
            return IdleLockGate.decide(live, locked, screenOn, lateBy, claim, inCall, hold, sweep, heldSince, clock, CAP,
                    holdAudio, audio, audioHolding, audioCap, standby);
        }
    }

    static String show(IdleLockGate.Verdict v) {
        return v.kind + "/" + v.reason + " delay=" + v.delayMs + " trace=" + v.trace + " heldSince=" + v.heldSinceMs
                + " audioHolding=" + v.audioHolding;
    }

    static void expect(String name, IdleLockGate.Verdict v, IdleLockGate.Kind kind, long delay, String trace) {
        check(name, v.kind == kind && v.delayMs == delay && (trace == null ? v.trace == null : trace.equals(v.trace)),
                show(v));
    }

    static final long[] slowClock = new long[1];

    public static void main(String[] a) {
        In i;
        IdleLockGate.Verdict v;

        i = new In(); i.live = false; i.hold = true; i.lateBy = 10 * MIN;
        v = i.run();
        expect("not live -> NONE, nothing called", v, IdleLockGate.Kind.NONE, 0, null);
        check("not live -> NONE, nothing called", i.claim.calls == 0 && i.sweep.calls == 0,
                "claim=" + i.claim.calls + " sweep=" + i.sweep.calls);

        i = new In(); i.locked = false; i.hold = true; i.lateBy = 10 * MIN;
        v = i.run();
        expect("not locked -> NONE, nothing called", v, IdleLockGate.Kind.NONE, 0, null);
        check("not locked -> NONE, nothing called", i.claim.calls == 0 && i.sweep.calls == 0,
                "claim=" + i.claim.calls + " sweep=" + i.sweep.calls);

        i = new In(); i.screenOn = true; i.lateBy = 10 * MIN;
        v = i.run();
        expect("screen on -> defer 60s, claim not called", v, IdleLockGate.Kind.DEFER, 60_000, "defer screenon");
        check("screen on -> defer 60s, claim not called", i.claim.calls == 0, "claim=" + i.claim.calls);

        i = new In(); i.lateBy = 2001;
        v = i.run();
        expect("late 2001 + claim -> regrace 3s", v, IdleLockGate.Kind.DEFER, 3_000, "defer latefire s=2");
        check("late 2001 + claim -> regrace 3s", i.claim.calls == 1, "claim=" + i.claim.calls);

        i = new In(); i.lateBy = 2000;
        v = i.run();
        expect("lateBy 2000 is on time: no claim, LOCK", v, IdleLockGate.Kind.LOCK, 0, null);
        check("lateBy 2000 is on time: no claim, LOCK", i.claim.calls == 0, "claim=" + i.claim.calls);

        i = new In(); i.lateBy = 10 * MIN; i.claim = new Claim(false); i.inCall = Boolean.TRUE;
        v = i.run();
        expect("claim false falls through", v, IdleLockGate.Kind.DEFER, 120_000, "defer call");
        check("claim false falls through", i.claim.calls == 1, "claim=" + i.claim.calls);

        i = new In(); i.lateBy = 10 * MIN; i.claim = new Claim(false);
        v = i.run();
        expect("claim false and nothing else -> LOCK", v, IdleLockGate.Kind.LOCK, 0, null);

        i = new In(); i.inCall = Boolean.TRUE;
        expect("in call -> defer 2 min", i.run(), IdleLockGate.Kind.DEFER, 120_000, "defer call");

        i = new In(); i.inCall = Boolean.TRUE;
        i.run();
        check("on-time fire in call never claims", i.claim.calls == 0, "claim=" + i.claim.calls);

        i = new In(); i.inCall = null;
        v = i.run();
        expect("inCall null proceeds -> LOCK", v, IdleLockGate.Kind.LOCK, 0, null);
        check("inCall null proceeds -> LOCK", v.heldSinceMs == 0, show(v));

        i = new In(); i.inCall = Boolean.FALSE;
        expect("inCall false -> LOCK", i.run(), IdleLockGate.Kind.LOCK, 0, null);

        i = new In(); i.screenOn = true; i.inCall = Boolean.TRUE;
        expect("screen on and in call -> screen-on defer", i.run(), IdleLockGate.Kind.DEFER, 60_000, "defer screenon");

        i = new In(); i.hold = true; i.heldSince = 0;
        v = i.run();
        expect("LIVE, first hold -> defer 5 min, stamped now", v, IdleLockGate.Kind.DEFER, 300_000, "defer installs held=0");
        check("LIVE, first hold -> defer 5 min, stamped now", v.heldSinceMs == NOW && i.sweep.calls == 1,
                show(v) + " sweep=" + i.sweep.calls);

        i = new In(); i.hold = true; i.heldSince = NOW - 59 * MIN;
        v = i.run();
        expect("held 59 min -> defer", v, IdleLockGate.Kind.DEFER, 300_000, "defer installs held=59");
        check("held 59 min -> defer", v.heldSinceMs == NOW - 59 * MIN, show(v));

        i = new In(); i.hold = true; i.heldSince = NOW - 60 * MIN;
        v = i.run();
        expect("held 60 min -> LOCK cap reached", v, IdleLockGate.Kind.LOCK, 0, "installs cap reached");
        check("held 60 min -> LOCK cap reached", v.reason == IdleLockGate.Reason.INSTALLS_CAP && v.heldSinceMs == NOW - 60 * MIN,
                show(v));

        i = new In(); i.hold = true; i.heldSince = NOW - 61 * MIN;
        expect("held 61 min -> LOCK cap reached", i.run(), IdleLockGate.Kind.LOCK, 0, "installs cap reached");

        String[] bad = { "ERR", "IDLE", "", null };
        for (String r : bad) {
            String n = "sweep " + (r == null ? "null" : "\"" + r + "\"") + " -> LOCK";
            i = new In(); i.hold = true; i.heldSince = 12345; i.sweep = new Sweep(r);
            v = i.run();
            expect(n, v, IdleLockGate.Kind.LOCK, 0, null);
            check(n, v.heldSinceMs == 12345 && i.sweep.calls == 1, show(v) + " sweep=" + i.sweep.calls);
        }

        i = new In(); i.hold = false; i.sweep = new Sweep("LIVE 3");
        v = i.run();
        expect("hold off -> LOCK, sweep never called", v, IdleLockGate.Kind.LOCK, 0, null);
        check("hold off -> LOCK, sweep never called", i.sweep.calls == 0, "sweep=" + i.sweep.calls);

        // RF-001: the clock is read AFTER the sweep reply, so a slow reply that crosses the cap locks.
        i = new In(); i.hold = true; i.heldSince = NOW - 59 * MIN - 59_000;
        final In slow = i;
        slow.sweep = new Sweep("LIVE 3") {
            public String get() { slowClock[0] = NOW + 2_000; return super.get(); }
        };
        slow.clock = () -> slowClock[0];
        slowClock[0] = NOW;
        v = i.run();
        expect("clock crosses the cap during the sweep -> LOCK", v, IdleLockGate.Kind.LOCK, 0, "installs cap reached");

        // NWP-20261120-02: the audio hold (decision 2026-11-01). One start for both holds; a failed check locks.
        i = new In(); i.audio = Boolean.TRUE; i.heldSince = 0;
        v = i.run();
        expect("audio playing, first fire -> defer 60s, stamped now, holding", v, IdleLockGate.Kind.DEFER, 60_000,
                "defer audio held=0");
        check("audio playing, first fire -> defer 60s, stamped now, holding",
                v.reason == IdleLockGate.Reason.AUDIO_HELD && v.heldSinceMs == NOW && v.audioHolding, show(v));

        i = new In(); i.audio = Boolean.TRUE; i.heldSince = NOW - 119 * MIN;
        v = i.run();
        expect("audio playing 119 min -> defer", v, IdleLockGate.Kind.DEFER, 60_000, "defer audio held=119");
        check("audio playing 119 min -> defer", v.heldSinceMs == NOW - 119 * MIN && v.audioHolding, show(v));

        i = new In(); i.audio = Boolean.TRUE; i.audioHolding = true; i.heldSince = NOW - 120 * MIN; i.hold = true;
        i.sweep = new Sweep("IDLE");
        v = i.run();
        expect("audio at the 120 min cap, sweep not LIVE -> AUDIO_CAP", v, IdleLockGate.Kind.LOCK, 0, "audio cap reached");
        check("audio at the 120 min cap, sweep not LIVE -> AUDIO_CAP",
                v.reason == IdleLockGate.Reason.AUDIO_CAP && !v.audioHolding && v.heldSinceMs == NOW - 120 * MIN, show(v));

        i = new In(); i.audio = Boolean.TRUE; i.heldSince = NOW - 121 * MIN; i.hold = false;
        v = i.run();
        expect("audio past the cap, installs off -> AUDIO_CAP", v, IdleLockGate.Kind.LOCK, 0, "audio cap reached");
        check("audio past the cap, installs off -> AUDIO_CAP", v.reason == IdleLockGate.Reason.AUDIO_CAP, show(v));

        i = new In(); i.audio = Boolean.TRUE; i.heldSince = NOW - 120 * MIN; i.hold = true;
        v = i.run();
        expect("audio at the cap, sweep LIVE -> INSTALLS_CAP", v, IdleLockGate.Kind.LOCK, 0, "installs cap reached");
        check("audio at the cap, sweep LIVE -> INSTALLS_CAP", v.reason == IdleLockGate.Reason.INSTALLS_CAP, show(v));

        // The start an installs hold stamped is the one audio counts from: 120 min since it -> the audio cap.
        i = new In(); i.audio = Boolean.TRUE; i.heldSince = NOW - 120 * MIN; i.hold = false;
        v = i.run();
        expect("audio counts from an earlier installs hold's start", v, IdleLockGate.Kind.LOCK, 0, "audio cap reached");
        check("audio counts from an earlier installs hold's start", v.reason == IdleLockGate.Reason.AUDIO_CAP, show(v));

        i = new In(); i.audio = Boolean.FALSE; i.heldSince = NOW - 60 * MIN; i.hold = true;
        v = i.run();
        expect("installs counts from an earlier audio hold's start", v, IdleLockGate.Kind.LOCK, 0, "installs cap reached");
        check("installs counts from an earlier audio hold's start",
                v.reason == IdleLockGate.Reason.INSTALLS_CAP && v.heldSinceMs == NOW - 60 * MIN, show(v));

        i = new In(); i.audio = Boolean.TRUE; i.heldSince = 0; i.hold = true;
        v = i.run();
        check("audio defers before installs, sweep not called",
                v.reason == IdleLockGate.Reason.AUDIO_HELD && i.sweep.calls == 0, show(v) + " sweep=" + i.sweep.calls);

        i = new In(); i.audio = Boolean.FALSE; i.audioHolding = true; i.heldSince = NOW - 30 * MIN;
        v = i.run();
        expect("audio stopped after a hold -> restart standby", v, IdleLockGate.Kind.DEFER, 15 * MIN, "audio stopped");
        check("audio stopped after a hold -> restart standby", v.reason == IdleLockGate.Reason.AUDIO_STOPPED
                && v.heldSinceMs == NOW - 30 * MIN && !v.audioHolding, show(v));

        i = new In(); i.audio = Boolean.FALSE; i.audioHolding = false;
        v = i.run();
        expect("audio false, not holding -> LOCK", v, IdleLockGate.Kind.LOCK, 0, null);
        check("audio false, not holding -> LOCK", v.reason == IdleLockGate.Reason.LOCK && !v.audioHolding, show(v));

        i = new In(); i.audio = null; i.audioHolding = true;
        v = i.run();
        expect("audio check failed (null) -> LOCK", v, IdleLockGate.Kind.LOCK, 0, null);
        check("audio check failed (null) -> LOCK", v.reason == IdleLockGate.Reason.LOCK && !v.audioHolding, show(v));

        i = new In(); i.holdAudio = false; i.audio = Boolean.TRUE;
        v = i.run();
        expect("audio hold off ignores playing", v, IdleLockGate.Kind.LOCK, 0, null);
        check("audio hold off ignores playing", v.reason == IdleLockGate.Reason.LOCK && v.heldSinceMs == 0, show(v));

        i = new In(); i.screenOn = true; i.audio = Boolean.TRUE; i.audioHolding = true;
        v = i.run();
        expect("screen on beats audio, keeps holding", v, IdleLockGate.Kind.DEFER, 60_000, "defer screenon");
        check("screen on beats audio, keeps holding", v.reason == IdleLockGate.Reason.SCREEN_ON && v.audioHolding, show(v));

        i = new In(); i.inCall = Boolean.TRUE; i.audio = Boolean.TRUE; i.audioHolding = true;
        v = i.run();
        expect("in call beats audio, keeps holding", v, IdleLockGate.Kind.DEFER, 120_000, "defer call");
        check("in call beats audio, keeps holding", v.reason == IdleLockGate.Reason.IN_CALL && v.audioHolding, show(v));

        i = new In(); i.inCall = Boolean.TRUE; i.audioHolding = false;
        v = i.run();
        check("in call keeps a false audioHolding", !v.audioHolding, show(v));

        // countsAsAudio: true only for a started player with a media-like usage that is not user 0's.
        boolean[] tf = { true, false };
        int[] uids = { -1, 10123, 1010123 };
        for (boolean started : tf) {
            for (boolean media : tf) {
                for (int uid : uids) {
                    boolean want = started && media && uid != 10123;
                    String n = "countsAsAudio " + (started ? "started" : "paused") + " " + (media ? "media" : "other")
                            + " uid " + uid + (uid == 10123 ? " (user 0)" : uid == 1010123 ? " (user 10)" : "")
                            + " -> " + want;
                    boolean got = IdleLockGate.countsAsAudio(started, media, uid);
                    check(n, got == want, String.valueOf(got));
                }
            }
        }

        // The worker's reply verdict: rearm = not exactly "OK LOCKING"; releaseWake = exactly "OK NOSESSION".
        String[][] replies = {
            { "OK LOCKING", "false", "false" }, { " OK LOCKING ", "false", "false" },
            { "OK NOSESSION", "true", "true" }, { "OK LOGOFF", "true", "false" },
            { "OK", "true", "false" }, { null, "true", "false" }, { "", "true", "false" },
            { "ERR-NOSESSION", "true", "false" }, { "DENIED", "true", "false" },
            { "OK NOSESSION LOCKING", "true", "false" },
        };
        for (String[] c : replies) {
            IdleLockGate.AfterReply ar = IdleLockGate.afterReply(c[0]);
            String n = "afterReply " + (c[0] == null ? "null" : "\"" + c[0] + "\"")
                    + " -> rearm=" + c[1] + " release=" + c[2];
            check(n, ar.rearm == Boolean.parseBoolean(c[1]) && ar.releaseWake == Boolean.parseBoolean(c[2]),
                    "rearm=" + ar.rearm + " release=" + ar.releaseWake);
        }

        System.out.println("idle-lock-gate: " + runs + " checks, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
