package com.nowhere.chooser;

import java.util.Arrays;

/** NWP-20261203-05: CredSvcWatch.Rule, run by core/vendor-common/bin/test-credsvc-watch-java.sh. Every case runs; main
 *  exits 1 when any failed, and each failure prints "FAIL <case> ...". */
public final class CredSvcWatchCases {
    private static int fails = 0;
    private static int passes = 0;

    private static void check(String c, boolean ok, String what) {
        if (ok) { passes++; return; }
        fails++;
        System.out.println("FAIL " + c + " " + what);
    }

    private static void list(String c, String[] got, String[] want, String what) {
        check(c, Arrays.equals(got, want), what + ": got " + Arrays.toString(got) + ", want " + Arrays.toString(want));
    }

    public static void main(String[] a) {
        // C1 the stuck truth table.
        check("C1", !CredSvcWatch.Rule.stuck(false, 0, 5), "not found is not stuck");
        check("C1", !CredSvcWatch.Rule.stuck(true, 123, 5), "a service with a pid is not stuck");
        check("C1", !CredSvcWatch.Rule.stuck(true, 0, 0), "no scheduled restart is not stuck");
        check("C1", CredSvcWatch.Rule.stuck(true, 0, 5), "found, no pid, a restart scheduled is stuck");

        // C2 recover needs both reads.
        check("C2", CredSvcWatch.Rule.recover(true, true), "both reads stuck recovers");
        check("C2", !CredSvcWatch.Rule.recover(true, false), "the second read not stuck does not recover");
        check("C2", !CredSvcWatch.Rule.recover(false, true), "the first read not stuck does not recover");
        check("C2", !CredSvcWatch.Rule.recover(false, false), "neither read stuck does not recover");

        // C3 order: the literal is CredentialService.onStartCommand's branch order, never Rule.ORDER.
        CredSvcWatch.Rule.Sent s = new CredSvcWatch.Rule.Sent();
        for (String k : new String[]{CredSvcWatch.TELINGEST, CredSvcWatch.INGEST, CredSvcWatch.CLAIMS_LOGIN,
                CredSvcWatch.SMSROLE, CredSvcWatch.GOSSTATE, CredSvcWatch.RELAYPREFS}) {
            check("C3", s.sent(10, 7, k), "sent(" + k + ") is accepted");
        }
        list("C3", s.resendList(10, 7),
                new String[]{"claimsLogin", "relayprefs", "gosstate", "ingest", "smsrole", "telingest"},
                "resendList in onStartCommand's branch order");

        // C4 dedupe.
        s = new CredSvcWatch.Rule.Sent();
        s.sent(10, 7, CredSvcWatch.INGEST);
        s.sent(10, 7, CredSvcWatch.INGEST);
        list("C4", s.resendList(10, 7), new String[]{"ingest"}, "a kind sent twice is re-sent once");

        // C5 a new serial on the same uid starts the set again.
        s = new CredSvcWatch.Rule.Sent();
        s.sent(10, 7, CredSvcWatch.INGEST);
        s.sent(10, 8, CredSvcWatch.TELINGEST);
        list("C5", s.resendList(10, 8), new String[]{"telingest"}, "the earlier session's kinds are dropped");

        // C6 an unknown word is refused.
        s = new CredSvcWatch.Rule.Sent();
        for (String k : new String[]{"claims", "pw", "smsretry", "alarm", null}) {
            check("C6", !s.sent(10, 7, k), "sent(" + k + ") is refused");
        }
        list("C6", s.resendList(10, 7), new String[0], "nothing refused is re-sent");
        check("C6", !CredSvcWatch.Rule.accepted("Ingest"), "accepted is case-sensitive");
        check("C6", CredSvcWatch.Rule.accepted("ingest"), "accepted takes a word of the list");

        // C7 empty for a stale or unknown serial or uid.
        s = new CredSvcWatch.Rule.Sent();
        s.sent(10, 7, CredSvcWatch.INGEST);
        list("C7", s.resendList(10, 8), new String[0], "a different serial");
        list("C7", s.resendList(11, 7), new String[0], "an unknown uid");
        list("C7", s.resendList(10, -1), new String[0], "an unreadable serial");

        // C8 per uid.
        s = new CredSvcWatch.Rule.Sent();
        s.sent(10, 7, CredSvcWatch.INGEST);
        s.sent(11, 9, CredSvcWatch.SMSROLE);
        list("C8", s.resendList(10, 7), new String[]{"ingest"}, "uid 10 holds its own kind only");
        list("C8", s.resendList(11, 9), new String[]{"smsrole"}, "uid 11 holds its own kind only");

        // C9 single flight per uid.
        s = new CredSvcWatch.Rule.Sent();
        check("C9", s.begin(10), "the first watch of uid 10 begins");
        check("C9", !s.begin(10), "a second watch of uid 10 does not");
        check("C9", s.begin(11), "a watch of uid 11 is independent");
        s.end(10);
        check("C9", s.begin(10), "after end, uid 10 can be watched again");

        // C10 nextSeconds.
        check("C10", CredSvcWatch.Rule.nextSeconds(0, 12_345) == -1, "no restart scheduled is -1");
        check("C10", CredSvcWatch.Rule.nextSeconds(30_000, 10_000) == 20, "20 s ahead is 20");
        check("C10", CredSvcWatch.Rule.nextSeconds(5_000, 10_000) == 0, "a past restart is 0");

        // C11 the constants (C3 owns the order).
        check("C11", CredSvcWatch.Rule.FIRST_MS == 20_000L, "FIRST_MS is 20 s");
        check("C11", CredSvcWatch.Rule.CONFIRM_MS == 15_000L, "CONFIRM_MS is 15 s");
        check("C11", "claimsLogin".equals(CredSvcWatch.CLAIMS_LOGIN) && "relayprefs".equals(CredSvcWatch.RELAYPREFS)
                && "gosstate".equals(CredSvcWatch.GOSSTATE) && "ingest".equals(CredSvcWatch.INGEST)
                && "smsrole".equals(CredSvcWatch.SMSROLE) && "telingest".equals(CredSvcWatch.TELINGEST),
                "the six constants are CredentialService's extra names");

        // C12 a record listed twice: the service map's entry (restarting 0) then the restart list's (RF-001).
        CredSvcWatch.Rule.Seen v = new CredSvcWatch.Rule.Seen();
        v.add(0, 0);
        v.add(0, 60_000);
        check("C12", v.found && v.pid == 0 && v.restartingAt == 60_000, "map then restart list keeps the restart time");
        check("C12", CredSvcWatch.Rule.stuck(v.found, v.pid, v.restartingAt), "map then restart list is stuck");
        v = new CredSvcWatch.Rule.Seen();
        v.add(0, 60_000);
        v.add(0, 0);
        check("C12", CredSvcWatch.Rule.stuck(v.found, v.pid, v.restartingAt), "restart list then map is stuck");
        v = new CredSvcWatch.Rule.Seen();
        v.add(123, 0);
        v.add(0, 60_000);
        check("C12", v.pid == 123 && !CredSvcWatch.Rule.stuck(v.found, v.pid, v.restartingAt),
                "a pid in any entry is running work, never stuck");
        v = new CredSvcWatch.Rule.Seen();
        check("C12", !v.found && !CredSvcWatch.Rule.stuck(v.found, v.pid, v.restartingAt), "no entry is not found");

        // C13 one run of a kind at a time in a process: a re-sent ingest that overlaps a first run skips (RF-002).
        final CredSvcWatch.Rule.Flight fl = new CredSvcWatch.Rule.Flight();
        final int[] runs = {0};
        final boolean[] inner = {true};
        boolean outer = fl.runOnce(CredSvcWatch.INGEST, () -> {
            runs[0]++;
            inner[0] = fl.runOnce(CredSvcWatch.INGEST, () -> runs[0]++);
        });
        check("C13", outer, "the first run runs");
        check("C13", !inner[0], "a run that starts while the first works does not run");
        check("C13", runs[0] == 1, "one worker ran, not two: got " + runs[0]);
        check("C13", fl.runOnce(CredSvcWatch.INGEST, () -> runs[0]++) && runs[0] == 2, "a later run runs again");
        try {
            fl.runOnce(CredSvcWatch.INGEST, () -> { throw new IllegalStateException("x"); });
        } catch (IllegalStateException expected) {
            // the run's throw passes through
        }
        check("C13", fl.runOnce(CredSvcWatch.INGEST, () -> runs[0]++) && runs[0] == 3, "a run that threw frees the kind");
        final boolean[] other = {false};
        fl.runOnce(CredSvcWatch.INGEST, () -> other[0] = fl.runOnce(CredSvcWatch.TELINGEST, () -> { }));
        check("C13", other[0], "another kind is not held by an ingest run");

        // C14 the session check before the stop (RF-003).
        check("C14", CredSvcWatch.Rule.sameSession(7, 7), "the same readable serial is the same session");
        check("C14", !CredSvcWatch.Rule.sameSession(7, 8), "a new serial is a new session");
        check("C14", !CredSvcWatch.Rule.sameSession(-1, -1), "two unreadable serials are not a match");
        check("C14", !CredSvcWatch.Rule.sameSession(-1, 7), "an unreadable first serial is not a match");
        check("C14", !CredSvcWatch.Rule.sameSession(7, -1), "an unreadable second serial is not a match");

        // C15 a recovery that throws still counts what it did and marks the trace (RF-004).
        final java.util.List<String> started = new java.util.ArrayList<>();
        CredSvcWatch.Rule.Trace tr = new CredSvcWatch.Rule.Trace();
        Throwable bad = CredSvcWatch.Rule.resend(new CredSvcWatch.Rule.Ops() {
            @Override public void stop() { }
            @Override public boolean start(String kind) {
                if (CredSvcWatch.INGEST.equals(kind)) throw new IllegalStateException("x");
                started.add(kind);
                return true;
            }
        }, new String[]{"claimsLogin", "gosstate", "ingest", "telingest"}, tr);
        check("C15", bad != null && tr.resent == 2 && " err".equals(tr.tail),
                "a start that throws: two counted, err: resent=" + tr.resent + " tail=[" + tr.tail + "]");
        tr = new CredSvcWatch.Rule.Trace();
        started.clear();
        bad = CredSvcWatch.Rule.resend(new CredSvcWatch.Rule.Ops() {
            @Override public void stop() { throw new SecurityException("x"); }
            @Override public boolean start(String kind) { started.add(kind); return true; }
        }, new String[]{"ingest"}, tr);
        check("C15", bad != null && tr.resent == 0 && started.isEmpty() && " err".equals(tr.tail),
                "a stop that throws starts nothing and says err");
        tr = new CredSvcWatch.Rule.Trace();
        bad = CredSvcWatch.Rule.resend(new CredSvcWatch.Rule.Ops() {
            @Override public void stop() { }
            @Override public boolean start(String kind) { return !CredSvcWatch.SMSROLE.equals(kind); }
        }, new String[]{"ingest", "smsrole", "telingest"}, tr);
        check("C15", bad == null && tr.resent == 2 && "".equals(tr.tail), "a refused start is not counted and is no err");
        tr.saw(v, false, 0);
        check("C15", "credsvc-watch u=10 found=0 stuck=0 next=-1 resent=2".equals(tr.line(10)),
                "the trace line: " + tr.line(10));
        CredSvcWatch.Rule.Seen w = new CredSvcWatch.Rule.Seen();
        w.add(0, 30_000);
        tr.saw(w, true, 10_000);
        tr.tail = " err";
        check("C15", "credsvc-watch u=11 found=1 stuck=1 next=20 resent=2 err".equals(tr.line(11)),
                "the trace line after a failed recovery: " + tr.line(11));
        tr.saw(null, false, 10_000);
        check("C15", "credsvc-watch u=11 found=0 stuck=0 next=-1 resent=2 err".equals(tr.line(11)),
                "a read that threw: " + tr.line(11));

        if (fails > 0) {
            System.out.println("FAILED " + fails + " check(s), " + passes + " passed");
            System.exit(1);
        }
        System.out.println("PASS " + passes);
    }
}
