// NWP-20261101-10 (Q122): the cases for the gate's reading of a failed create that left its claim staged, and the
// copy it shows, run against Lifted (the pure helpers run.sh lifts out of ChooserActivity.java).
// args[0] = ChooserActivity.java, read for the wiring check.
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

public final class StagedClaimCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final String TEXT = "Your profile wasn't created, and your code's credit is held on this phone for this "
            + "exact name and passphrase until the phone restarts. Tap Create again with the same name and passphrase "
            + "to use it. After a restart, or with a different name or passphrase, it's lost.";

    public static void main(String[] args) throws Exception {
        String src = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);

        check("staged: BLANK STAGED", Lifted.createReplyStaged("BLANK STAGED"), true);
        check("staged: NOCREDIT STAGED", Lifted.createReplyStaged("NOCREDIT STAGED"), true);
        check("staged: BLANK STAGED with trailing newline", Lifted.createReplyStaged("BLANK STAGED\n"), true);
        check("not staged: BLANK", !Lifted.createReplyStaged("BLANK"), true);
        check("not staged: NOCREDIT", !Lifted.createReplyStaged("NOCREDIT"), true);
        check("not staged: OK 0 RECOVERY x", !Lifted.createReplyStaged("OK 0 RECOVERY x"), true);
        check("not staged: STAGED alone", !Lifted.createReplyStaged("STAGED"), true);
        check("not staged: EXISTS STAGED", !Lifted.createReplyStaged("EXISTS STAGED"), true);
        check("not staged: BLANK STAGEDX", !Lifted.createReplyStaged("BLANK STAGEDX"), true);
        check("not staged: null", !Lifted.createReplyStaged(null), true);

        String t = Lifted.createHeldCreditText();
        check("text, exact", TEXT.equals(t), t);
        check("text says until the phone restarts", t.contains("until the phone restarts"), t);
        check("text says the same name and passphrase", t.contains("same name and passphrase"), t);

        // Wiring: the staged branch shows the held-credit text and comes before the NOCREDIT branch, which would
        // otherwise swallow "NOCREDIT STAGED" with the generic storage-credit message.
        int staged = src.indexOf("if (createReplyStaged(cr)) {");
        int nocredit = src.indexOf("if (cr.startsWith(\"NOCREDIT\")) {");
        check("wiring: the staged branch exists in roamLogin", staged > 0, staged);
        check("wiring: the NOCREDIT branch exists", nocredit > 0, nocredit);
        check("wiring: the staged branch precedes the NOCREDIT one", staged > 0 && nocredit > 0 && staged < nocredit,
                staged + " vs " + nocredit);
        if (staged > 0) {
            int end = src.indexOf("return;", staged);
            String body = end > 0 ? src.substring(staged, end) : "";
            check("wiring: the staged branch shows createHeldCreditText()",
                    body.contains("showMsg(createHeldCreditText());"), body);
        }

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails != 0) System.exit(1);
    }
}
