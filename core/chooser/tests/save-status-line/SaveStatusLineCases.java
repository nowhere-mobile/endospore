// Cases for SaveStatusLine (NWP-20261104-09). run.sh prepends the package line.
public class SaveStatusLineCases {
    static int failed = 0;

    static void eq(String what, String got, String want) {
        if (want.equals(got)) return;
        failed++;
        System.out.println("--- FAIL " + what + ": got <" + got + ">, want <" + want + ">");
    }

    static void is(String what, boolean got, boolean want) {
        if (got == want) return;
        failed++;
        System.out.println("--- FAIL " + what + ": got " + got + ", want " + want);
    }

    public static void main(String[] a) {
        final String ago = "12 min ago";
        final String saving = "Signed in · saving now…";
        final String none = "Signed in · not saved yet this session";
        final String nocredit = "Signed in · last save failed: plan out of credit";
        final String held = "Signed in · last save held back";
        final String failedNoAgo = "Signed in · last save failed";
        final String failedAgo = "Signed in · saved 12 min ago · last try failed";
        final String savedAgo = "Signed in · saved 12 min ago";
        for (String v : new String[] {"", "ok", "fail", "nocredit", "refused", "weird", null}) {
            eq("run beats verdict <" + v + ">", SaveStatusLine.text("periodic", ago, v), saving);
            eq("run beats verdict <" + v + "> without savedAgo", SaveStatusLine.text("periodic", null, v), saving);
        }
        eq("nocredit with savedAgo", SaveStatusLine.text("", ago, "nocredit"), nocredit);
        eq("nocredit without savedAgo", SaveStatusLine.text("", null, "nocredit"), nocredit);
        eq("fail with savedAgo", SaveStatusLine.text("", ago, "fail"), failedAgo);
        eq("fail without savedAgo", SaveStatusLine.text("", null, "fail"), failedNoAgo);
        eq("fail with empty savedAgo", SaveStatusLine.text("", "", "fail"), failedNoAgo);
        eq("refused with savedAgo", SaveStatusLine.text("", ago, "refused"), held);
        eq("refused without savedAgo", SaveStatusLine.text("", null, "refused"), held);
        eq("ok with savedAgo", SaveStatusLine.text("", ago, "ok"), savedAgo);
        eq("empty verdict with savedAgo", SaveStatusLine.text("", ago, ""), savedAgo);
        eq("ok without savedAgo", SaveStatusLine.text("", null, "ok"), none);
        eq("empty verdict without savedAgo", SaveStatusLine.text("", null, ""), none);
        eq("unknown verdict with savedAgo", SaveStatusLine.text("", ago, "weird"), savedAgo);
        eq("unknown verdict without savedAgo", SaveStatusLine.text("", null, "weird"), none);
        eq("null run and verdict with savedAgo", SaveStatusLine.text(null, ago, null), savedAgo);
        eq("null run and verdict without savedAgo", SaveStatusLine.text(null, null, null), none);

        is("isError fail", SaveStatusLine.isError("fail"), true);
        is("isError nocredit", SaveStatusLine.isError("nocredit"), true);
        is("isError ok", SaveStatusLine.isError("ok"), false);
        is("isError refused", SaveStatusLine.isError("refused"), false);
        is("isError empty", SaveStatusLine.isError(""), false);
        is("isError unknown", SaveStatusLine.isError("weird"), false);
        is("isError null", SaveStatusLine.isError(null), false);

        if (failed > 0) {
            System.out.println(failed + " case(s) failed");
            System.exit(1);
        }
        System.out.println("save-status-line: all cases pass");
    }
}
