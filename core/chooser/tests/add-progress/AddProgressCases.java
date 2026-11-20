package com.nowhere.chooser;

import java.util.concurrent.atomic.AtomicReference;

/**
 * NWP-20261209-05: AddProgress, compiled as-is by core/vendor-common/bin/test-add-progress-java.sh. Each case prints
 * "ok   C<n> <name>" or "FAIL C<n> <name>: <why>"; the run exits 1 when any case fails.
 */
public final class AddProgressCases {
    private static int failed;

    private static void check(String id, boolean ok, String why) {
        if (ok) System.out.println("ok   " + id);
        else {
            System.out.println("FAIL " + id + ": " + why);
            failed++;
        }
    }

    private static void eq(String id, String got, String want) {
        check(id, want.equals(got), "got \"" + got + "\", want \"" + want + "\"");
    }

    private static void reset() {
        String s = AddProgress.inFlight();
        if (s.isEmpty()) return;
        for (String p : s.split(" ")) AddProgress.end(p);
    }

    public static void main(String[] args) throws Exception {
        reset();
        eq("C1 an unknown pkg gives \"\"", AddProgress.get("org.example.none"), "");
        eq("C1 a null pkg gives \"\"", AddProgress.get(null), "");
        eq("C1 an empty pkg gives \"\"", AddProgress.get(""), "");

        reset();
        AddProgress.begin("org.example.a");
        eq("C2 begin then get gives \"0 0\"", AddProgress.get("org.example.a"), "0 0");

        reset();
        AddProgress.begin("org.example.a");
        AddProgress.update("org.example.a", 5, 10);
        eq("C3 update(5, 10) then get gives \"5 10\"", AddProgress.get("org.example.a"), "5 10");
        AddProgress.update("org.example.a", 7, 0);
        eq("C3 update(7, 0) (total unknown) gives \"7 0\"", AddProgress.get("org.example.a"), "7 0");
        AddProgress.update("org.example.a", 3000000000L, 4000000000L);
        eq("C3 byte counts over 2^31 stay whole", AddProgress.get("org.example.a"), "3000000000 4000000000");

        reset();
        AddProgress.begin("org.example.a");
        try {
            AddProgress.update("org.example.a", -3, 10);
            eq("C4 got < 0 is clamped to 0", AddProgress.get("org.example.a"), "0 10");
            AddProgress.update("org.example.a", 15, 10);
            eq("C4 got > total is clamped to total", AddProgress.get("org.example.a"), "10 10");
            AddProgress.update("org.example.a", 4, -1);
            eq("C4 total < 0 reads as unknown (0)", AddProgress.get("org.example.a"), "4 0");
            AddProgress.update("org.example.a", Long.MAX_VALUE, 0);
            eq("C4 got with an unknown total is kept", AddProgress.get("org.example.a"), Long.MAX_VALUE + " 0");
            AddProgress.update(null, 1, 2);
            AddProgress.update("", 1, 2);
            AddProgress.begin(null);
            AddProgress.end(null);
            check("C4 null and empty pkgs never throw", true, "");
        } catch (Throwable t) {
            check("C4 clamping never throws", false, String.valueOf(t));
        }

        reset();
        AddProgress.begin("org.example.a");
        AddProgress.update("org.example.a", 5, 10);
        AddProgress.end("org.example.a");
        eq("C5 end removes the add", AddProgress.get("org.example.a"), "");
        AddProgress.update("org.example.a", 6, 10);
        eq("C5 an update after end makes no entry", AddProgress.get("org.example.a"), "");
        eq("C5 an update after end leaves nothing in flight", AddProgress.inFlight(), "");

        reset();
        AddProgress.begin("org.example.b");
        AddProgress.begin("org.example.a");
        eq("C6 two adds are in flight in start order", AddProgress.inFlight(), "org.example.b org.example.a");

        reset();
        AddProgress.begin("org.example.a");
        AddProgress.begin("org.example.b");
        AddProgress.update("org.example.b", 2, 9);
        AddProgress.end("org.example.a");
        eq("C7 ending one leaves the other in flight", AddProgress.inFlight(), "org.example.b");
        eq("C7 ending one leaves the other's progress", AddProgress.get("org.example.b"), "2 9");

        reset();
        eq("C8 none in flight gives \"\"", AddProgress.inFlight(), "");

        reset();
        final AtomicReference<Throwable> err = new AtomicReference<>();
        final String p = "org.example.race";
        Thread up = new Thread(() -> {
            try {
                for (int i = 0; i < 200000; i++) {
                    AddProgress.update(p, i, 100000);
                    AddProgress.get(p);
                }
            } catch (Throwable t) { err.compareAndSet(null, t); }
        });
        Thread be = new Thread(() -> {
            try {
                for (int i = 0; i < 200000; i++) {
                    AddProgress.begin(p);
                    AddProgress.inFlight();
                    AddProgress.end(p);
                }
            } catch (Throwable t) { err.compareAndSet(null, t); }
        });
        up.start();
        be.start();
        up.join(60000);
        be.join(60000);
        check("C9 concurrent update and end from two threads finish", !up.isAlive() && !be.isAlive(), "a thread did not finish in 60 s");
        check("C9 concurrent update and end from two threads do not throw", err.get() == null, String.valueOf(err.get()));
        eq("C9 nothing is left in flight after the race", AddProgress.inFlight(), "");

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("AddProgressCases: all cases pass");
    }
}
