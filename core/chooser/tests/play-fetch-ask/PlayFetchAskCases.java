package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.function.Predicate;

/** Cases for PlayFetchAsk (NWP-20261114-14; WHERE, NWP-20261119-27), run by core/vendor-common/bin/test-play-fetch-ask-java.sh. */
public class PlayFetchAskCases {
    static int failed;

    static void check(String what, Object got, Object want) {
        if (want == null ? got == null : want.equals(got)) {
            System.out.println("  ok    " + what);
        } else {
            failed++;
            System.out.println("  FAIL  " + what + ": got <" + got + ">, want <" + want + ">");
        }
    }

    /** How many times n occurs in s; -1 for an empty needle. */
    static int count(String s, String n) {
        if (n == null || n.isEmpty()) return -1;
        int c = 0;
        for (int i = s.indexOf(n); i >= 0; i = s.indexOf(n, i + n.length())) c++;
        return c;
    }

    public static void main(String[] a) throws Exception {
        final String gms = "com.google.android.gms", vending = "com.android.vending";
        Predicate<String> isStack = d -> d.equals(gms) || d.equals(vending);
        List<String> none = Collections.emptyList();

        // needsAsk: only a tap that fetches a Play-stack member asks.
        check("needsAsk quiet + stack dep -> false (the Auto sweep never asks)",
                PlayFetchAsk.needsAsk(true, Arrays.asList(gms), isStack), false);
        check("needsAsk quiet + no deps -> false", PlayFetchAsk.needsAsk(true, none, isStack), false);
        check("needsAsk tap + no deps -> false", PlayFetchAsk.needsAsk(false, none, isStack), false);
        check("needsAsk tap + null deps -> false", PlayFetchAsk.needsAsk(false, null, isStack), false);
        check("needsAsk tap + a non-stack dep -> false",
                PlayFetchAsk.needsAsk(false, Arrays.asList("org.example.lib"), isStack), false);
        check("needsAsk tap + gms -> true", PlayFetchAsk.needsAsk(false, Arrays.asList(gms), isStack), true);
        check("needsAsk tap + a non-stack dep and vending -> true",
                PlayFetchAsk.needsAsk(false, Arrays.asList("org.example.lib", vending), isStack), true);

        // message: the size and the minutes, or the size-unknown line; h49 #9's WHERE sentence sits between the size
        // and the question on both.
        final String where = "You can keep using the phone; progress shows in your notifications.";
        final String unknown = "This app needs Google Play services first, a large download. You can keep using the phone; progress shows in your notifications. Download now?";
        check("WHERE is the h49 #9 example", PlayFetchAsk.WHERE, where);
        check("message(136314880)", PlayFetchAsk.message(136314880L),
                "About 130 MB, 2–3 minutes. " + where + " Download now?");
        check("message(0) is the size-unknown line", PlayFetchAsk.message(0), unknown);
        check("message(-1) is the size-unknown line", PlayFetchAsk.message(-1), unknown);
        check("message(1) says at least 1 MB and 1–2 minutes", PlayFetchAsk.message(1),
                "About 1 MB, 1–2 minutes. " + where + " Download now?");
        check("message(600 MB)", PlayFetchAsk.message(600L * 1048576),
                "About 600 MB, 10–11 minutes. " + where + " Download now?");
        for (long b : new long[] {136314880L, 0, -1, 1, 600L * 1048576}) {
            String m = PlayFetchAsk.message(b);
            check("message(" + b + ") holds WHERE exactly once", count(m, where), 1);
            check("message(" + b + ") ends with the question", m.endsWith("Download now?"), true);
        }

        // parseSize: only "OK <bytes> <files>" gives a size.
        check("parseSize OK 123 4", PlayFetchAsk.parseSize("OK 123 4"), 123L);
        for (String r : new String[] {"NONE", "LOCAL", "ERR", "ERR-PKG", "", "OK x 4", "OK -5 1", "OK 1"})
            check("parseSize \"" + r + "\" -> -1", PlayFetchAsk.parseSize(r), -1L);
        check("parseSize null -> -1", PlayFetchAsk.parseSize(null), -1L);

        // Asker: a one-shot answer; a stale token never answers a newer ask.
        PlayFetchAsk.Asker k = new PlayFetchAsk.Asker();
        long t1 = k.open(), t2 = k.open();
        check("an answer for an old token is ignored", k.answer(t1, true), false);
        check("... and the newer ask times out", k.await(t2, 50), PlayFetchAsk.Reply.TIMEOUT);

        k = new PlayFetchAsk.Asker();
        long t = k.open();
        check("no answer -> TIMEOUT", k.await(t, 50), PlayFetchAsk.Reply.TIMEOUT);

        k = new PlayFetchAsk.Asker();
        t = k.open();
        check("Not now is taken", k.answer(t, false), true);
        check("Not now -> NO", k.await(t, 1000), PlayFetchAsk.Reply.NO);

        k = new PlayFetchAsk.Asker();
        t = k.open();
        check("Download is taken", k.answer(t, true), true);
        check("a second answer is ignored", k.answer(t, false), false);
        check("Download -> YES", k.await(t, 1000), PlayFetchAsk.Reply.YES);

        k = new PlayFetchAsk.Asker();
        t1 = k.open();
        t2 = k.open();
        k.answer(t2, true);
        check("a stale token never reads a newer answer", k.await(t1, 50), PlayFetchAsk.Reply.TIMEOUT);

        final PlayFetchAsk.Asker k2 = new PlayFetchAsk.Asker();
        final long t3 = k2.open();
        Thread th = new Thread(() -> {
            try { Thread.sleep(50); } catch (InterruptedException ignore) {}
            k2.answer(t3, true);
        });
        th.start();
        check("an answer from another thread -> YES", k2.await(t3, 5000), PlayFetchAsk.Reply.YES);
        th.join();

        check("the static ASKER exists", PlayFetchAsk.ASKER != null, true);

        if (failed > 0) {
            System.out.println(failed + " case(s) FAILED");
            System.exit(1);
        }
        System.out.println("all cases passed");
    }
}
