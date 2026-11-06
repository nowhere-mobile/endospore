// SealProgressCases -- NWP-20261108-23: executes the Profile screen's seal-progress and partial-save readers (the ten
// helpers test-seal-progress-java.sh lifts from ProfileActivity.java into SealLifted) against made-up frames shaped
// like the agent's "SEALING <phase> <done> <total>[ <scope>]" and "DONE PARTIAL:<list>". Each argument is a scope token
// the agent's progScopeOf can emit; every one must label as something other than "your data". Prints `ok   <name>` or
// `FAIL <name>: got ... want ...`; exits 1 on any failure (and on no arguments: a dead extraction is not "nothing to
// check").
import java.util.Arrays;

public final class SealProgressCases {
    private static int cases = 0, fails = 0;

    private static void eq(String name, Object got, Object want) {
        cases++;
        if (got == null ? want == null : got.equals(want)) { System.out.println("ok   " + name); return; }
        fails++;
        System.out.println("FAIL " + name + ": got " + (got == null ? "null" : "\"" + got + "\"")
                + " want " + (want == null ? "null" : "\"" + want + "\""));
    }

    private static void eqArr(String name, long[] got, long[] want) {
        cases++;
        if (Arrays.equals(got, want)) { System.out.println("ok   " + name); return; }
        fails++;
        System.out.println("FAIL " + name + ": got " + Arrays.toString(got) + " want " + Arrays.toString(want));
    }

    public static void main(String[] args) {
        eq("sealPhase-save-scoped", SealLifted.sealPhase("SEALING save 5 10 media"), "save");
        eq("sealPhase-prepare-old", SealLifted.sealPhase("SEALING prepare 1 2"), "prepare");
        eq("sealPhase-sizes", SealLifted.sealPhase("SEALING sizes 3 10 vault"), "sizes");
        eq("sealPhase-empty", SealLifted.sealPhase("SEALING "), "");

        eqArr("sealBytes-scoped", SealLifted.sealBytes("SEALING save 5 10 media"), new long[]{5, 10});
        eqArr("sealBytes-old", SealLifted.sealBytes("SEALING prepare 1 2"), new long[]{1, 2});
        eqArr("sealBytes-trailing-pair", SealLifted.sealBytes("SEALING save 1 2 3 4"), new long[]{3, 4});
        eqArr("sealBytes-empty", SealLifted.sealBytes("SEALING "), null);
        eqArr("sealBytes-no-numbers", SealLifted.sealBytes("SEALING save x y apps"), null);

        eq("sealScope-scoped", SealLifted.sealScope("SEALING save 5 10 media"), "media");
        eq("sealScope-old", SealLifted.sealScope("SEALING prepare 1 2"), "");
        eq("sealScope-empty", SealLifted.sealScope("SEALING "), "");
        eq("sealScope-short", SealLifted.sealScope("SEALING save 5 media"), "");

        String[] legs = {"vault", "de", "media", "sys", "apps"};
        for (int i = 0; i < legs.length; i++) eq("sealScopeIndex-" + legs[i], SealLifted.sealScopeIndex(legs[i]), i);
        for (String t : new String[]{"keys", "wallet", "files", ""})
            eq("sealScopeIndex-" + (t.isEmpty() ? "empty" : t), SealLifted.sealScopeIndex(t), -1);

        String[][] labels = {
            {"vault", "your files"}, {"de", "your settings"}, {"media", "your photos & media"},
            {"sys", "your account"}, {"account", "your account"}, {"apps", "your apps"},
            {"keys", "your sign-ins"}, {"wallet", "your wallet"}, {"files", "your files"}};
        for (String[] l : labels) eq("sealScopeLabel-" + l[0], SealLifted.sealScopeLabel(l[0]), l[1]);
        eq("sealScopeLabel-unknown", SealLifted.sealScopeLabel("notes"), "your data");

        eq("sealPct-half", SealLifted.sealPct("SEALING save 5 10"), 50);
        eq("sealPct-zero-total", SealLifted.sealPct("SEALING save 0 0"), 0);
        eq("sealPct-clamp", SealLifted.sealPct("SEALING save 15 10"), 100);

        eq("fmtBytes-1KiB", SealLifted.fmtBytes(1024L), "1 KB");
        eq("fmtBytes-under-1MiB", SealLifted.fmtBytes(1048575L), "1023 KB");
        eq("fmtBytes-1MiB", SealLifted.fmtBytes(1048576L), "1.0 MB");
        eq("fmtBytes-10MiB", SealLifted.fmtBytes(10485760L), "10 MB");
        eq("fmtBytes-1GiB", SealLifted.fmtBytes(1073741824L), "1.0 GB");

        eq("partialOf-list", SealLifted.partialOf("DONE PARTIAL:apps=refused,sys=timeout"), "apps=refused,sys=timeout");
        eq("partialOf-none", SealLifted.partialOf("DONE"), "");
        eq("partialOf-null", SealLifted.partialOf(null), "");

        eq("partialWhat-apps", SealLifted.partialWhat("apps=refused"), "your apps");
        eq("partialWhat-sys", SealLifted.partialWhat("sys=timeout"), "your Google account");
        eq("partialWhat-keys", SealLifted.partialWhat("keys=refused"), "your saved sign-ins");
        eq("partialWhat-all", SealLifted.partialWhat("apps=refused,sys=timeout,keys=refused"),
                "your apps and your Google account and your saved sign-ins");
        eq("partialWhat-unknown", SealLifted.partialWhat("reap=husk"), "part of your profile");
        eq("partialMessage", SealLifted.partialMessage("apps=refused"),
                "Signed out, and your files are saved — but your apps couldn't be saved this time, "
                + "so they may be missing when you next sign in. Please report this.");

        if (args.length == 0) { cases++; fails++; System.out.println("FAIL agent-scope-labelled: no agent scope tokens passed"); }
        for (String tok : args)
            eq("agent-scope-labelled-" + tok, !"your data".equals(SealLifted.sealScopeLabel(tok)), true);

        System.out.println(cases + " cases, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
