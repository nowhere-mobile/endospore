// NWP-20261101-12: the cases for the gate's reason when an OS update holds a sign-in (Q062) -- the two pure decisions,
// the text, and the order of roamLogin's checks. args[0] = ChooserActivity.java. Every failure prints "FAIL <case>",
// which test-signin-ota-java.sh --mutate reads.
// NWP-20261117-12 (#30): the ERR-NOTMPFS predicate, its text, and its three branches (the create chain, the ROAM-IN
// reply, resume()'s failure arm). Those pins read the source with its comments stripped, so a comment cannot pass them.
public final class SigninOtaCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String show(String s) { return s == null ? "null" : "'" + s.replace("\n", "\\n") + "'"; }

    /** The body of the method whose signature line is sig, to its closing brace; null when absent. */
    static String method(String src, String sig) {
        int at = src.indexOf(sig);
        if (at < 0 || src.indexOf(sig, at + 1) >= 0) return null;
        int depth = 0;
        for (int i = src.indexOf('{', at); i < src.length(); i++) {
            char c = src.charAt(i);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return src.substring(at, i + 1);
        }
        return null;
    }

    /** src with every // and block comment removed (outside string and char literals); newlines are kept. */
    static String strip(String src) {
        StringBuilder o = new StringBuilder(src.length());
        int n = src.length();
        for (int i = 0; i < n; i++) {
            char c = src.charAt(i);
            char d = i + 1 < n ? src.charAt(i + 1) : 0;
            if (c == '/' && d == '/') {
                while (i < n && src.charAt(i) != '\n') i++;
                if (i < n) o.append('\n');
            } else if (c == '/' && d == '*') {
                i += 2;
                while (i < n && !(src.charAt(i) == '*' && i + 1 < n && src.charAt(i + 1) == '/')) {
                    if (src.charAt(i) == '\n') o.append('\n');
                    i++;
                }
                i++;
            } else if (c == '"' || c == '\'') {
                o.append(c);
                for (i++; i < n; i++) {
                    char e = src.charAt(i);
                    o.append(e);
                    if (e == '\\' && i + 1 < n) { o.append(src.charAt(++i)); continue; }
                    if (e == c || e == '\n') break;
                }
            } else {
                o.append(c);
            }
        }
        return o.toString();
    }

    static int once(String body, String anchor) {
        int i = body.indexOf(anchor);
        return i >= 0 && body.indexOf(anchor, i + 1) < 0 ? i : -1;
    }

    public static void main(String[] a) throws Exception {
        // ---- which OTA-STATUS lines hold a sign-in ----
        for (String s : new String[]{"DOWNLOADING", "DOWNLOADING 0.6.0", "APPLYING 0.6.0", "APPLYING"}) {
            check("held: '" + s + "' holds a sign-in", Lifted.signInHeldForUpdate(s), "not held");
        }
        for (String s : new String[]{"FAILED ERR-STALE", "AVAIL 0.6.0", "NONE", ""}) {
            check("held: '" + s + "' holds nothing", !Lifted.signInHeldForUpdate(s), "held");
        }
        check("held: no answer (null) holds nothing", !Lifted.signInHeldForUpdate(null), "held");

        // ---- which replies are the daemon's refusal ----
        for (String r : new String[]{"ERR-OTA", "ERR-OTA\n", "  ERR-OTA  "}) {
            check("refusal: " + show(r) + " is the refusal", Lifted.replyIsOtaRefusal(r), "not recognised");
        }
        for (String r : new String[]{"ERR-OTHER", "BLANK", "OK 10", "ERR-COLDLOCK", ""}) {
            check("refusal: " + show(r) + " is not the refusal", !Lifted.replyIsOtaRefusal(r), "recognised");
        }
        check("refusal: null is not the refusal", !Lifted.replyIsOtaRefusal(null), "recognised");

        // ---- which replies are the daemon's refusal when its state dir is not a tmpfs (#30) ----
        for (String r : new String[]{"ERR-NOTMPFS", "ERR-NOTMPFS\n", "  ERR-NOTMPFS  "}) {
            check("notmpfs: " + show(r) + " is the refusal", Lifted.replyIsNoTmpfs(r), "not recognised");
        }
        for (String r : new String[]{"ERR-NOTMPFSX", "", "ERR-OTA", "BLANK", "OK 10"}) {
            check("notmpfs: " + show(r) + " is not the refusal", !Lifted.replyIsNoTmpfs(r), "recognised");
        }
        check("notmpfs: null is not the refusal", !Lifted.replyIsNoTmpfs(null), "recognised");
        check("notmpfs text: byte for byte", Lifted.NO_TMPFS_TEXT.equals("This phone can't sign in safely. Restart it."),
                Lifted.NO_TMPFS_TEXT);

        // ---- the text, byte for byte ----
        check("text: byte for byte", Lifted.UPDATE_INSTALLING_TEXT.equals(
                "An update is installing. The phone will restart when it's done. Sign in after that."),
                Lifted.UPDATE_INSTALLING_TEXT);

        // ---- wiring, in roamLogin ----
        String src = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(a[0])), "UTF-8");
        String body = method(src, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        if (body == null) {
            check("wiring: roamLogin found", false, "missing");
        } else {
            String pre = "if (signInHeldForUpdate(otaStatusAndProg()[0])) {\n                hideRestore();\n                showMsg(UPDATE_INSTALLING_TEXT);\n                return;\n            }";
            int refuse = once(body, "if (isCreate && createRefusedForColdLock(coldLock0)) {");
            int hold = once(body, pre);
            int credit = once(body, "try { pc = sendDaemon(\"GET-PARKED-CREDIT\\n\"); } catch (Throwable ignore) {}");
            int net = once(body, "final boolean offline = !hasInternetWithGrace(8000);");
            check("wiring: the update check comes after the create refusal and before GET-PARKED-CREDIT",
                    refuse > 0 && hold > refuse && credit > hold, refuse + " " + hold + " " + credit);
            check("wiring: the update check comes before the network wait", hold > 0 && net > hold, hold + " " + net);
            int send = once(body, "? createStreaming(\"CREATE\\n\"");
            int cArm = once(body, "if (replyIsOtaRefusal(cr)) {");
            int cEnd = cArm < 0 ? -1 : body.indexOf("return;", cArm);
            check("wiring: a create answered ERR-OTA says why and returns (no user exists yet)",
                    send > 0 && cArm > send && cEnd > cArm && body.substring(cArm, cEnd).contains("hideRestore();")
                            && body.substring(cArm, cEnd).contains("showMsg(UPDATE_INSTALLING_TEXT);")
                            && !body.substring(cArm, cEnd).contains("stopRoamUser"), cArm + " " + cEnd);
            int mk = once(body, "int uid = createRoamUser(name, pw);");
            int rArm = once(body, "if (replyIsOtaRefusal(reply)) {");
            int rEnd = rArm < 0 ? -1 : body.indexOf("return;", rArm);
            int stop = rArm < 0 || rEnd < 0 ? -1 : body.indexOf("if (uid >= 0) stopRoamUser(uid);", rArm);
            int allowed = once(body, "if (loginResultAllowed()) {");
            int okAt = once(body, "final boolean ok = reply.startsWith(\"OK\");");
            check("wiring: a ROAM-IN answered ERR-OTA stops the user, says why and returns before the verdict",
                    mk > 0 && rArm > mk && stop > rArm && stop < rEnd && body.substring(rArm, rEnd).contains("hideRestore();")
                            && body.substring(rArm, rEnd).contains("showMsg(UPDATE_INSTALLING_TEXT);")
                            && okAt > rEnd && allowed > rEnd, rArm + " " + stop + " " + rEnd + " " + allowed);
        }

        // ---- wiring of ERR-NOTMPFS (#30), on the source without comments ----
        String bare = strip(src);
        String sb = method(bare, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        if (sb == null) {
            check("wiring: roamLogin found (comments stripped)", false, "missing");
        } else {
            int oArm = once(sb, "if (replyIsOtaRefusal(cr)) {");
            int nArm = once(sb, "if (replyIsNoTmpfs(cr)) {");
            int exists = once(sb, "if (cr.startsWith(\"EXISTS\")) {");
            int nEnd = nArm < 0 ? -1 : sb.indexOf("return;", nArm);
            String nSpan = nArm < 0 || nEnd < 0 ? "" : sb.substring(nArm, nEnd);
            check("wiring: a create answered ERR-NOTMPFS says the restart text and returns (no user exists yet)",
                    oArm > 0 && nArm > oArm && exists > nEnd && nEnd > nArm && nSpan.contains("hideRestore();")
                            && nSpan.contains("showMsg(NO_TMPFS_TEXT);") && !nSpan.contains("stopRoamUser"),
                    oArm + " " + nArm + " " + nEnd + " " + exists);
            int mk = once(sb, "int uid = createRoamUser(name, pw);");
            int oR = once(sb, "if (replyIsOtaRefusal(reply)) {");
            int tR = once(sb, "if (replyIsNoTmpfs(reply)) {");
            int tEnd = tR < 0 ? -1 : sb.indexOf("return;", tR);
            String tSpan = tR < 0 || tEnd < 0 ? "" : sb.substring(tR, tEnd);
            int tStop = tSpan.indexOf("if (uid >= 0) stopRoamUser(uid);");
            int tMsg = tSpan.indexOf("showMsg(NO_TMPFS_TEXT);");
            int okAt = once(sb, "final boolean ok = reply.startsWith(\"OK\");");
            int allowed = once(sb, "if (loginResultAllowed()) {");
            check("wiring: a ROAM-IN answered ERR-NOTMPFS stops the user, says the restart text and returns before the verdict",
                    mk > 0 && oR > mk && tR > oR && tStop >= 0 && tMsg > tStop && tSpan.contains("hideRestore();")
                            && okAt > tEnd && allowed > tEnd, tR + " " + tStop + " " + tMsg + " " + tEnd + " " + okAt);
        }
        String rb = method(bare, "private void resume(final String pass, final boolean keyAlreadyAsserted) {");
        if (rb == null) {
            check("wiring: resume() found (comments stripped)", false, "missing");
        } else {
            String armAt = "else if (v.kind == ResumeReply.NOTMPFS) {";
            int arm = once(rb, armAt);
            int armEnd = arm < 0 ? -1 : rb.indexOf("else", arm + armAt.length());
            String aSpan = arm < 0 || armEnd < 0 ? "" : rb.substring(arm, armEnd);
            check("wiring: resume()'s NOTMPFS arm shows the restart text",
                    arm > 0 && aSpan.contains("result.setText(NO_TMPFS_TEXT);") && !aSpan.contains("passField.setText(\"\")"),
                    arm + " " + armEnd);
        }
        System.out.println(fails == 0 ? "ALL " + runs + " PASS" : fails + " of " + runs + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
