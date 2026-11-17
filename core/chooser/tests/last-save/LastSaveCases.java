package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/**
 * NWP-20261205-02: LastSaveCopy's cases, run by core/chooser/test-last-save-java.sh. a[0] is a UTF-8 file holding the
 * h58 #1 sentence as docs/product-decisions.md states it.
 */
public final class LastSaveCases {
    static int checks = 0, fails = 0;

    static void ok(String id, boolean cond, String what) {
        checks++;
        if (!cond) { fails++; System.out.println("FAIL " + id + ": " + what); }
    }

    static void yes(String id, String reply) {
        ok(id, LastSaveCopy.unsaved(reply), "unsaved(" + show(reply) + ") is false, want true");
    }

    static void no(String id, String reply) {
        ok(id, !LastSaveCopy.unsaved(reply), "unsaved(" + show(reply) + ") is true, want false");
    }

    static String show(String s) {
        return s == null ? "null" : "\"" + s.replace("\n", "\\n") + "\"";
    }

    public static void main(String[] a) throws Exception {
        String doc = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8).trim();

        // C1: the line is the decided sentence, byte for byte.
        ok("C1 line", LastSaveCopy.LINE.equals(doc), "LINE " + show(LastSaveCopy.LINE) + " != the h58 #1 sentence " + show(doc));

        // C2: a well-formed LASTSAVE line reads as unsaved.
        yes("C2 fixture", "LASTSAVE v=1 unsaved=de=unreachable t=1763100000");
        yes("C2 five scopes", "LASTSAVE v=1 unsaved=vault=a,de=b,media=c,sys=d,apps=e t=1");
        yes("C2 32-char cause", "LASTSAVE v=1 unsaved=media=" + "a".repeat(32) + " t=1763100000");
        yes("C2 digits and dash", "LASTSAVE v=1 unsaved=sys=put-503,apps=x9 t=1763100000");
        yes("C2 19-digit t", "LASTSAVE v=1 unsaved=vault=refused t=1000000000000000000");

        // C3: anything else reads as nothing to show.
        no("C3 null", null);
        no("C3 empty", "");
        no("C3 NONE", "NONE");
        no("C3 ERR", "ERR");
        no("C3 BLANK", "BLANK");
        no("C3 v=2", "LASTSAVE v=2 unsaved=de=x t=1763100000");
        no("C3 no t", "LASTSAVE v=1 unsaved=de=x");
        no("C3 empty t", "LASTSAVE v=1 unsaved=de=x t=");
        no("C3 t=0", "LASTSAVE v=1 unsaved=de=x t=0");
        no("C3 t=-1", "LASTSAVE v=1 unsaved=de=x t=-1");
        no("C3 t non-digit", "LASTSAVE v=1 unsaved=de=x t=12a");
        no("C3 20-digit t", "LASTSAVE v=1 unsaved=de=x t=10000000000000000000");
        no("C3 empty list", "LASTSAVE v=1 unsaved= t=1763100000");
        no("C3 unknown scope", "LASTSAVE v=1 unsaved=foo=x t=1763100000");
        no("C3 unknown scope keys", "LASTSAVE v=1 unsaved=keys=x t=1763100000");
        no("C3 repeated scope", "LASTSAVE v=1 unsaved=de=x,de=y t=1763100000");
        no("C3 six items", "LASTSAVE v=1 unsaved=vault=a,de=b,media=c,sys=d,apps=e,de=f t=1763100000");
        no("C3 six items unknown", "LASTSAVE v=1 unsaved=vault=a,de=b,media=c,sys=d,apps=e,keys=f t=1763100000");
        no("C3 empty item", "LASTSAVE v=1 unsaved=de=x, t=1763100000");
        no("C3 no =", "LASTSAVE v=1 unsaved=de t=1763100000");
        no("C3 empty cause", "LASTSAVE v=1 unsaved=de= t=1763100000");
        no("C3 upper-case cause", "LASTSAVE v=1 unsaved=de=Unreachable t=1763100000");
        no("C3 digit-first cause", "LASTSAVE v=1 unsaved=de=1x t=1763100000");
        no("C3 33-char cause", "LASTSAVE v=1 unsaved=de=" + "a".repeat(33) + " t=1763100000");
        no("C3 = in cause", "LASTSAVE v=1 unsaved=de=a=b t=1763100000");
        no("C3 double space", "LASTSAVE  v=1 unsaved=de=x t=1763100000");
        no("C3 trailing space", "LASTSAVE v=1 unsaved=de=x t=1763100000 ");
        no("C3 leading space", " LASTSAVE v=1 unsaved=de=x t=1763100000");
        no("C3 extra field", "LASTSAVE v=1 unsaved=de=x t=1763100000 x");
        no("C3 LF kept", "LASTSAVE v=1 unsaved=de=x t=1763100000\n");

        // C4: show() is once per sign-in, keyed on the user serial.
        ok("C4 new serial", LastSaveCopy.show(true, "5", "6"), "show(true, 5, 6) is false");
        ok("C4 no stamp", LastSaveCopy.show(true, null, "6"), "show(true, null, 6) is false");
        ok("C4 same serial", !LastSaveCopy.show(true, "6", "6"), "show(true, 6, 6) is true");
        ok("C4 null serial", !LastSaveCopy.show(true, "6", null), "show(true, 6, null) is true");
        ok("C4 not unsaved", !LastSaveCopy.show(false, null, "6"), "show(false, null, 6) is true");

        System.out.println((fails == 0 ? "PASS" : "FAIL") + " " + (checks - fails) + "/" + checks + " LastSaveCopy cases");
        System.exit(fails == 0 ? 0 : 1);
    }
}
