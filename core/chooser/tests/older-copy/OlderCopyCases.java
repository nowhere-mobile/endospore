package com.nowhere.chooser;

/** NWP-20261126-07 / NWP-20261128-20 (h50 #3): the cases for OlderCopy and AppCodeManifest's installer line, run by
 *  core/vendor-common/bin/test-older-copy-java.sh. */
public final class OlderCopyCases {
    static int bad = 0;

    static void want(long fetched, long placeholder, boolean want) {
        boolean got = OlderCopy.older(fetched, placeholder);
        if (got == want) return;
        System.out.println("FAIL C0 older(" + fetched + ", " + placeholder + "): want " + want + ", got " + got);
        bad++;
    }

    static void eq(String id, String what, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        bad++;
    }

    static final String V = "com.android.vending";
    static final String OWN = "com.nowhere.chooser";

    public static void main(String[] a) {
        int b0 = bad;
        want(5, 7, true);                 // older: the install cannot succeed
        want(26091819, 26102651, true);   // frankel's numbers (version code 26091819 inconsistent with 26102651)
        want(7, 7, false);                // the same version installs
        want(9, 7, false);                // a newer copy installs
        want(-1, 7, false);               // the fetched version was not read: install as before
        want(0, 7, false);                // a zero version is unknown too
        want(7, -1, false);               // the placeholder's version was not read: install as before
        want(7, 0, false);
        want(-1, -1, false);
        if (bad == b0) System.out.println("ok C0 older() is true exactly when both versions are known and the fetched one is lower");

        b0 = bad;
        eq("C1", "an inst line", V, AppCodeManifest.installer("vc\t5\ninst\t" + V + "\ncert\tAA\n"));
        eq("C1", "no inst line", null, AppCodeManifest.installer("vc\t5\ncert\tAA\n"));
        eq("C1", "a second inst line is ignored", V, AppCodeManifest.installer("inst\t" + V + "\ninst\tcom.other.store\n"));
        eq("C1", "a space refuses it", null, AppCodeManifest.installer("inst\tcom.a b\n"));
        eq("C1", "a tab refuses it", null, AppCodeManifest.installer("inst\tcom.a\tb\n"));
        eq("C1", "one segment refuses it", null, AppCodeManifest.installer("inst\tvending\n"));
        eq("C1", "an empty value", null, AppCodeManifest.installer("inst\t\n"));
        eq("C1", "a digit-first segment", null, AppCodeManifest.installer("inst\tcom.9a\n"));
        eq("C1", "null text", null, AppCodeManifest.installer(null));
        StringBuilder lng = new StringBuilder("com.");
        while (lng.length() < 256) lng.append('a');
        eq("C1", "a 256-char name", null, AppCodeManifest.installer("inst\t" + lng + "\n"));
        eq("C1", "a 255-char name", lng.substring(0, 255), AppCodeManifest.installer("inst\t" + lng.substring(0, 255) + "\n"));
        if (bad == b0) System.out.println("ok C1 installer() reads the first inst line with a valid package name");

        b0 = bad;
        eq("C2", "Play now", V, AppCodeManifest.installerToRecord(V, OWN, "inst\tcom.other.store\n"));
        eq("C2", "the chooser now keeps the previous", V, AppCodeManifest.installerToRecord(OWN, OWN, "vc\t3\ninst\t" + V + "\n"));
        eq("C2", "unknown now keeps the previous", V, AppCodeManifest.installerToRecord(null, OWN, "inst\t" + V + "\n"));
        eq("C2", "the chooser with no previous", null, AppCodeManifest.installerToRecord(OWN, OWN, null));
        eq("C2", "an invalid name keeps the previous", V, AppCodeManifest.installerToRecord("a b", OWN, "inst\t" + V + "\n"));
        if (bad == b0) System.out.println("ok C2 installerToRecord() keeps the store an app came from, never the chooser");

        b0 = bad;
        String[] metas = {"vc\t1\ninst\t" + V + "\n", "inst\t" + V + "\n", "vc\t2\n", "inst\tcom.other.store\n", null};
        eq("C3", "Play on", 2, OlderCopy.playCount(metas, true));
        eq("C3", "Play off", 0, OlderCopy.playCount(metas, false));
        eq("C3", "no metas", 0, OlderCopy.playCount(null, true));
        if (bad == b0) System.out.println("ok C3 playCount() counts Play's apps only when Play Store is on the profile");

        b0 = bad;
        eq("C4", "one", "1 app needs Play Store to come back", OlderCopy.endLine(1));
        eq("C4", "three", "3 apps need Play Store to come back", OlderCopy.endLine(3));
        eq("C4", "zero", null, OlderCopy.endLine(0));
        eq("C4", "negative", null, OlderCopy.endLine(-1));
        if (bad == b0) System.out.println("ok C4 endLine() is singular for 1, plural above, null for none");

        b0 = bad;
        String plain = "vc\t42\ntsdk\t34\ncert\tAAA\ncert\tBBB\nact\tcom.x/.A\tA\nact\tcom.x/.B\tB\n";
        String withInst = "vc\t42\ntsdk\t34\ncert\tAAA\ninst\t" + V + "\ncert\tBBB\nact\tcom.x/.A\tA\nact\tcom.x/.B\tB\n";
        AppCodeManifest.Meta m0 = AppCodeManifest.parseMeta(plain), m1 = AppCodeManifest.parseMeta(withInst);
        eq("C5", "vc", m0.vc, m1.vc);
        eq("C5", "tsdk", m0.tsdk, m1.tsdk);
        eq("C5", "certs", m0.certs, m1.certs);
        eq("C5", "acts size", m0.acts.size(), m1.acts.size());
        for (int i = 0; i < Math.min(m0.acts.size(), m1.acts.size()); i++)
            eq("C5", "act " + i, java.util.Arrays.toString(m0.acts.get(i)), java.util.Arrays.toString(m1.acts.get(i)));
        eq("C5", "vc value", 42, m1.vc);
        if (bad == b0) System.out.println("ok C5 parseMeta() ignores the inst line");

        if (bad > 0) System.exit(1);
    }
}
