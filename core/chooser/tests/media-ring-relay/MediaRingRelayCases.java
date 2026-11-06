package com.nowhere.chooser;

/**
 * Cases for MediaRingRelay (NWP-20261128-19), run by core/vendor-common/bin/test-media-ring-relay-java.sh.
 * The launcher listens only while it is resumed, so a value the relay sent while an app was in front can be lost;
 * the relay must send it again after RESEND_MS, the empty clear included.
 */
public final class MediaRingRelayCases {
    private static int failed = 0;

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  PASS  " : "  FAIL  ") + name);
        if (!ok) failed++;
    }

    public static void main(String[] a) {
        final long r = MediaRingRelay.RESEND_MS;
        final String v = "app.a 5 10 RUN";
        final long t = 1000;

        check("RESEND_MS is 10 s", r == 10_000);

        MediaRingRelay m = new MediaRingRelay();
        check("the first value is due", m.due(v, 10, t));
        check("the first empty value is due", new MediaRingRelay().due("", 10, t));

        m = new MediaRingRelay();
        m.sent(v, 10, t);
        check("the same value 1 s later is not due", !m.due(v, 10, t + 1000));
        check("the same value RESEND_MS - 1 later is not due", !m.due(v, 10, t + r - 1));
        check("the same value RESEND_MS later is due again", m.due(v, 10, t + r));
        check("a changed value is due", m.due("app.a 6 10 RUN", 10, t + 1000));
        check("a uid change is due", m.due(v, 11, t + 1000));

        // The paused-launcher case: the clear is sent while no receiver listens, so it must be repeated.
        m = new MediaRingRelay();
        m.sent(v, 10, t);
        check("an empty value after a non-empty one is due", m.due("", 10, t + 1000));
        m.sent("", 10, t + 1000);
        check("the same empty value 1 s later is not due", !m.due("", 10, t + 2000));
        check("the empty value RESEND_MS after its send is due again", m.due("", 10, t + 1000 + r));
        check("a null value reads as the empty one", !m.due(null, 10, t + 2000));

        m = new MediaRingRelay();
        m.sent(v, 10, t);
        m.reset();
        check("reset() makes the next value due", m.due(v, 10, t + 1000));
        m.sent(v, 10, t + 1000);
        m.reset();
        check("reset() makes the next empty value due", m.due("", 10, t + 2000));

        m = new MediaRingRelay();
        m.sent(v, 10, t);
        check("due() does not record a send", !m.due(v, 10, t + 1000) && !m.due(v, 10, t + 1000));
        m.due(v, 11, t + 2000);
        check("a due() that answered true records nothing", !m.due(v, 10, t + 3000));

        if (failed > 0) { System.out.println(failed + " case(s) failed"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
