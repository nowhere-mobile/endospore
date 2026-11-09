package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/**
 * NWP-20261128-08: SkipNoticeCopy's cases, run by core/vendor-common/bin/test-skip-notice-copy-java.sh. a[0] is a
 * UTF-8 file holding the h48 #5 sentence as docs/product-decisions.md states it, placeholders intact.
 */
public final class SkipNoticeCopyCases {
    static int checks = 0, fails = 0;

    static void ok(String id, boolean cond, String what) {
        checks++;
        if (!cond) { fails++; System.out.println("FAIL " + id + ": " + what); }
    }

    static void notice(String id, String reply, String phone, long time) {
        SkipNoticeCopy.Notice n = SkipNoticeCopy.parse(reply);
        ok(id, n != null && phone.equals(n.phone) && n.time == time,
                "parse(" + show(reply) + ") = " + (n == null ? "null" : "{" + show(n.phone) + ", " + n.time + "}"));
    }

    static void none(String id, String reply) {
        SkipNoticeCopy.Notice n = SkipNoticeCopy.parse(reply);
        ok(id, n == null, "parse(" + show(reply) + ") is not null");
    }

    static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\t", "\\t").replace("\n", "\\n") + "\"";
    }

    public static void main(String[] a) throws Exception {
        String doc = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8).trim();

        // P1: a notice with a label, with an empty label, and with a tab-free label holding spaces.
        notice("P1 label", "NOTICE Fairphone 3\t1762351380", "Fairphone 3", 1762351380L);
        notice("P1 empty label", "NOTICE \t1762351380", "", 1762351380L);
        notice("P1 spaces", "NOTICE My old phone\t60", "My old phone", 60L);

        // P2: everything that is not exactly a notice reads as none.
        none("P2 NONE", "NONE");
        none("P2 ERR", "ERR");
        none("P2 empty", "");
        none("P2 null", null);
        none("P2 no tab", "NOTICE x 1762351380");
        none("P2 non-numeric", "NOTICE x\tabc");
        none("P2 zero", "NOTICE x\t0");
        none("P2 negative", "NOTICE x\t-5");
        none("P2 two tabs", "NOTICE a\tb\t5");
        none("P2 no space", "NOTICEx\t5");
        none("P2 no time", "NOTICE x\t");
        none("P2 overflow", "NOTICE x\t99999999999999999999");
        none("P2 plus sign", "NOTICE x\t+5");

        // P3: the words are h48 #5 as the doc states it.
        ok("P3 sentence", SkipNoticeCopy.SENTENCE.equals(doc), "SENTENCE " + show(SkipNoticeCopy.SENTENCE)
                + " is not the doc's " + show(doc));
        String want = doc.replace("<phone>", "Fairphone 3").replace("<time>", "5 Nov 2026, 14:03");
        String got = SkipNoticeCopy.words("Fairphone 3", "5 Nov 2026, 14:03");
        ok("P3 words", want.equals(got), "words = " + show(got) + ", want " + show(want));

        // P4: an empty or missing label reads "another phone" (an inference, see SkipNoticeCopy).
        String fb = doc.replace("<phone>", "another phone").replace("<time>", "T");
        ok("P4 empty label", fb.equals(SkipNoticeCopy.words("", "T")), "words(\"\", T) = " + show(SkipNoticeCopy.words("", "T")));
        ok("P4 null label", fb.equals(SkipNoticeCopy.words(null, "T")), "words(null, T) = " + show(SkipNoticeCopy.words(null, "T")));

        // P5: the shown request's exact bytes.
        ok("P5 shownRequest", "SKIP-NOTICE-SHOWN\n1762351380\n".equals(SkipNoticeCopy.shownRequest(1762351380L)),
                "shownRequest = " + show(SkipNoticeCopy.shownRequest(1762351380L)));

        // P6: a label holding "<time>" stays as typed; the time goes in its own slot.
        String sp = SkipNoticeCopy.words("<time>", "T");
        ok("P6 splice", sp.contains("on <time> after T"), "words(\"<time>\", T) = " + show(sp));

        if (fails > 0) { System.out.println("FAIL " + fails + " of " + checks + " checks"); System.exit(1); }
        System.out.println("PASS " + checks + " checks");
    }
}
