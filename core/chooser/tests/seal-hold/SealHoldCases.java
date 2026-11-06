package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

// NWP-20261011-01: the cases for the Profile screen's "Backups while apps set up" choice (SealHold) -- its option
// mapping, its default, its copy, and that the chooser, roamd and the daemon agree on the four stored values.
// args: ProfileActivity.java, nowhere_roamd.sh, core/agent/seal_hold.go.
public final class SealHoldCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String read(String p) throws Exception {
        return new String(Files.readAllBytes(Paths.get(p)), StandardCharsets.UTF_8);
    }

    public static void main(String[] a) throws Exception {
        // The options, in order, and the default.
        check("four values in picker order", String.join(",", SealHold.VALUES).equals("2,10,30,run"),
                String.join(",", SealHold.VALUES));
        check("the default is 30 minutes", SealHold.DEFAULT.equals("30"), SealHold.DEFAULT);
        check("the stored file name", SealHold.FILE.equals("nowhere-seal-hold"), SealHold.FILE);

        // normalize: each choice is itself; anything else -- absent, unknown, damaged -- is the default.
        for (String v : SealHold.VALUES) check("normalize " + v, SealHold.normalize(v).equals(v), SealHold.normalize(v));
        check("normalize trims a newline", SealHold.normalize("10\n").equals("10"), SealHold.normalize("10\n"));
        for (String bad : new String[] { null, "", "45", "2 10", "RUN", "unlimited", "0" }) {
            check("normalize " + bad + " -> default", SealHold.normalize(bad).equals("30"), SealHold.normalize(bad));
        }

        // The copy, pinned: one name and one plain trade-off line per choice, no counts.
        String[][] copy = {
            { "2", "About 2 minutes", "Backups keep running during setup; a large app, or an Auto install, can take longer to set up" },
            { "10", "10 minutes", "Apps set up faster; if the phone crashes during setup you can lose up to 10 more minutes of changes" },
            { "30", "30 minutes", "Apps set up faster; if the phone crashes during setup you can lose up to 30 more minutes of changes" },
            { "run", "Until setup finishes", "Backups wait for all of setup, even a background Auto install that can take hours; a crash can lose everything since the last backup before it" },
        };
        for (String[] c : copy) {
            check("label " + c[0], SealHold.label(c[0]).equals(c[1]), SealHold.label(c[0]));
            check("tradeoff " + c[0], SealHold.tradeoff(c[0]).equals(c[2]), SealHold.tradeoff(c[0]));
            check("item " + c[0], SealHold.item(c[0]).equals(c[1] + "\n" + c[2]), SealHold.item(c[0]));
            check("tradeoff " + c[0] + " is one line", !SealHold.tradeoff(c[0]).contains("\n"), SealHold.tradeoff(c[0]));
        }
        check("an unknown value shows the default's copy", SealHold.label("45").equals("30 minutes")
                && SealHold.tradeoff("45").equals(copy[2][2]), SealHold.label("45"));

        // What the user is told after a choice: true in every outcome.
        check("not saved", SealHold.afterSave(false, "OK").equals("Couldn't save this choice. Try again."), SealHold.afterSave(false, "OK"));
        check("applied now -> nothing", SealHold.afterSave(true, "OK") == null, SealHold.afterSave(true, "OK"));
        check("refused -> next sign-in", "Saved. It applies from your next sign-in.".equals(SealHold.afterSave(true, "ERR")),
                SealHold.afterSave(true, "ERR"));
        for (String none : new String[] { "", null, "BUSY", "garbage" }) {
            check("no answer (" + none + ") -> maybe now, else next sign-in",
                    "Saved. If it doesn't apply now, it will from your next sign-in.".equals(SealHold.afterSave(true, none)),
                    SealHold.afterSave(true, none));
        }
        check("the 2-minute copy names the Auto install", SealHold.tradeoff("2").contains("an Auto install"),
                SealHold.tradeoff("2"));
        check("the run copy names the background Auto install", SealHold.tradeoff("run").contains("background Auto install"),
                SealHold.tradeoff("run"));

        // The three halves agree.
        String pa = read(a[0]), roamd = read(a[1]), agent = read(a[2]);
        check("the picker sends SET-SEAL-HOLD with its user", pa.contains(
                "sendDaemon(\"SET-SEAL-HOLD\\n\" + val + \"\\n\" + android.os.UserHandle.myUserId() + \"\\n\")"), "missing");
        check("the picker's sends are ordered on one thread", pa.contains("SEAL_HOLD_IO.execute(() -> {")
                && pa.contains("java.util.concurrent.Executors.newSingleThreadExecutor()"), "missing");
        check("the picker tells the user afterSave's words", pa.contains("SealHold.afterSave(true, reply)")
                && pa.contains("SealHold.afterSave(false, null)"), "missing");
        check("an unsaved choice leaves the row alone", pa.contains("if (!writeSealHold(SealHold.VALUES[which])) return;"), "missing");
        check("the picker writes SealHold.FILE", pa.contains("new java.io.File(getFilesDir(), SealHold.FILE)"), "missing");
        check("roamd surfaces the same file", roamd.contains("com.nowhere.chooser/files/" + SealHold.FILE), "missing");
        for (String v : SealHold.VALUES) {
            check("roamd surfaces " + v, roamd.contains("echo \"$uid " + v + "\" > \"$STATE/seal-hold.out\""), "missing");
        }
        check("the daemon accepts exactly these values", agent.contains("case \"2\", \"10\", \"30\", \"run\":"), "missing");

        System.out.println("seal-hold cases: " + runs + " run, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
