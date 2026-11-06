// NWP-20261116-09 (h46 #5): the cases for the gate's reading of the daemon's ERR-LIVE refusal of a create, the words it
// shows, and the wiring of its branch and its Restart, run against Lifted (the pure helpers run.sh lifts out of
// ChooserActivity.java). NWP-20261117-11 (#54): the N cases do the same for the daemon's ERR-NAME refusal of a name
// holding '#' (the agent's scope separator).
// args[0] = ChooserActivity.java, read for the wiring checks; args[1] = the repo root, for docs/product-decisions.md.
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

public final class CreateLiveCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    /** The decided words, byte for byte (docs/product-decisions.md, 2026-10-28, h46 #5). */
    /** The words of #54 (docs/product-decisions.md, 2026-10-22), byte for byte. */
    static final String NAME_WORDS = "Names can't contain #.";

    static final String WORDS = "A session is still open on this phone, so nothing was created or charged, and your code is still good. To create a profile, restart the phone. Anything that session hasn't saved will be lost.";

    public static void main(String[] args) throws Exception {
        String src = new String(Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8);
        String decisions = new String(Files.readAllBytes(Paths.get(args[1], "docs", "product-decisions.md")),
                StandardCharsets.UTF_8);

        // ---- L1: only the bare ERR-LIVE verb is the live-session refusal ----
        String[] yes = {"ERR-LIVE", "ERR-LIVE\n", " ERR-LIVE "};
        for (String r : yes) check("L1 createReplyLive: " + show(r) + " is ERR-LIVE", Lifted.createReplyLive(r), false);
        String[] no = {null, "", "ERR-LIVEX", "ERR-COLDLOCK", "ERR-BUSY", "ERR", "OK 0", "BLANK"};
        for (String r : no) check("L1 createReplyLive: " + show(r) + " is not ERR-LIVE", !Lifted.createReplyLive(r), true);

        // ---- L2: the words are the decided ones, and the decision still holds them ----
        String t = Lifted.createLiveText();
        check("L2 createLiveText is the decided h46 #5 words", WORDS.equals(t), t);
        check("L2 docs/product-decisions.md holds the words", decisions.contains(WORDS), "absent");

        // ---- L3: the branch in roamLogin's create reply chain ----
        int login = once(src, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        int end = login < 0 ? -1 : src.indexOf("\n    private ", login + 1);
        check("L3 roamLogin found, and where it ends", login > 0 && end > login, login + " " + end);
        if (login > 0 && end > login) {
            String body = src.substring(login, end);
            int live = once(body, "if (createReplyLive(cr)) {");
            int cold = once(body, "if (createReplyColdLocked(cr)) {");
            int nostore = once(body, "if (cr.startsWith(\"NOSTORE\"))");
            int blank = once(body, "if (!cr.startsWith(\"OK\")) { hideRestore(); showBlank(); return; }");
            check("L3 the ERR-LIVE branch is after the ERR-COLDLOCK one and before NOSTORE and the blank failure",
                    live > 0 && cold > 0 && live > cold && nostore > live && blank > live,
                    cold + " " + live + " " + nostore + " " + blank);
            if (live > 0) {
                int close = body.indexOf("\n                }", live);
                String block = close < 0 ? "" : body.substring(live, close);
                int hide = block.indexOf("hideRestore();");
                int shown = hide < 0 ? -1 : block.indexOf("showCreateOverLiveSession();", hide);
                int ret = shown < 0 ? -1 : block.indexOf("return;", shown);
                check("L3 the ERR-LIVE branch re-enables the form, shows the restart dialog and returns",
                        hide > 0 && shown > hide && ret > shown, block);
            }
        }

        // ---- L4: the dialog's Restart reboots, off the UI thread, after asking what it costs ----
        String dialog = body(src, "private void showCreateOverLiveSession() {");
        check("L4 showCreateOverLiveSession names Restart", dialog.contains("\"Restart\""), dialog);
        check("L4 showCreateOverLiveSession's Restart calls rebootForCreateOverLive",
                dialog.contains("setPositiveButton(\"Restart\", (d, w) -> rebootForCreateOverLive())"), dialog);
        String reboot = body(src, "private void rebootForCreateOverLive() {");
        check("L4 rebootForCreateOverLive runs on a new Thread", reboot.contains("new Thread"), reboot);
        check("L4 rebootForCreateOverLive asks TEL-PENDING", reboot.contains("TEL-PENDING"), reboot);
        check("L4 rebootForCreateOverLive reboots", reboot.contains(".reboot("), reboot);

        // ---- N1: only the bare ERR-NAME verb is the refusal of a name holding '#' (NWP-20261117-11, #54) ----
        String[] nyes = {"ERR-NAME", "ERR-NAME\n", " ERR-NAME "};
        for (String r : nyes) check("N1 createReplyBadName: " + show(r) + " is ERR-NAME", Lifted.createReplyBadName(r), false);
        String[] nno = {null, "", "ERR-NAMEX", "ERR-NAM", "ERR-LIVE", "ERR-NOCODE", "WEAK too short", "BLANK", "OK 0"};
        for (String r : nno) check("N1 createReplyBadName: " + show(r) + " is not ERR-NAME", !Lifted.createReplyBadName(r), true);

        // ---- N2: the branch in roamLogin's create reply chain, beside the other refusals and before WEAK ----
        int nlogin = once(src, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        int nend = nlogin < 0 ? -1 : src.indexOf("\n    private ", nlogin + 1);
        if (nlogin > 0 && nend > nlogin) {
            String body = src.substring(nlogin, nend);
            int live = once(body, "if (createReplyLive(cr)) {");
            int bad = once(body, "if (createReplyBadName(cr)) {");
            int nostore = once(body, "if (cr.startsWith(\"NOSTORE\"))");
            int weak = once(body, "if (cr.startsWith(\"WEAK\"))");
            int blank = once(body, "if (!cr.startsWith(\"OK\")) { hideRestore(); showBlank(); return; }");
            check("N2 the ERR-NAME branch is after the ERR-LIVE one and before NOSTORE, WEAK and the blank failure",
                    bad > 0 && live > 0 && bad > live && nostore > bad && weak > bad && blank > bad,
                    live + " " + bad + " " + nostore + " " + weak + " " + blank);
            if (bad > 0) {
                int close = body.indexOf("\n                }", bad);
                String block = close < 0 ? "" : body.substring(bad, close);
                int hide = block.indexOf("hideRestore();");
                int shown = hide < 0 ? -1 : block.indexOf("showMsg(\"" + NAME_WORDS + "\");", hide);
                int ret = shown < 0 ? -1 : block.indexOf("return;", shown);
                check("N2 the ERR-NAME branch re-enables the form, says the #54 words and returns",
                        hide > 0 && shown > hide && ret > shown, block);
            }
        }

        // ---- N3: the decision holds the words the branch shows ----
        check("N3 docs/product-decisions.md holds the #54 words", decisions.contains("\"" + NAME_WORDS + "\""), "absent");

        System.out.println(fails == 0 ? "ALL " + runs + " PASS" : fails + " of " + runs + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }

    static String show(String r) {
        return r == null ? "null" : "\"" + r.replace("\n", "\\n") + "\"";
    }

    /** The method that starts at sig (which must occur exactly once), through the brace that closes it, or "". */
    static String body(String src, String sig) {
        int at = once(src, sig);
        if (at < 0) return "";
        int depth = 0;
        for (int i = at; i < src.length(); i++) {
            char c = src.charAt(i);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return src.substring(at, i + 1);
        }
        return "";
    }

    /** Where key occurs in s, or -1 (reported) unless it occurs exactly once. */
    static int once(String s, String key) {
        int i = s.indexOf(key);
        if (i < 0 || s.indexOf(key, i + 1) >= 0) {
            check("anchor occurs exactly once: " + key.replace("\n", "\\n"), false, i < 0 ? "absent" : "repeated");
            return -1;
        }
        return i;
    }
}
