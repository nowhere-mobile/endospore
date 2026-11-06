// NWP-20261016-47: the cases for the gate's warning before a sign-in ends a parked session's unsaved credit -- the
// decision, its copy and its wiring -- run against Lifted (the pure helpers run.sh lifts out of ChooserActivity.java).
// NWP-20261124-08: the question is asked over EVERY parked session (the gate cannot learn whether that session has
// unsaved changes), and GET-PARKED-CREDIT's LOST adds only the credit sentence.
// args[0] = ChooserActivity.java. Every failure prints "FAIL <case>", which test-supersede-credit-java.sh --mutate reads.
public final class SupersedeCreditCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    // The dialog's wait and the Cancel path are Android code no case can run, so they are pinned byte for byte. The
    // ways they break silently -- a dialog the back key dismisses with no answer, Continue that never counts down, a
    // gate that goes away read as Continue, a wait with no limit or one that stops while the phone sleeps, Cancel
    // landing anywhere but the parked session -- each change the text. A deliberate edit updates the pin with it; a
    // failure names the first line that differs.
    static final String CONFIRM =
            "    private boolean confirmSupersedeLoss(final boolean creditLost) {\n"
            + "        final java.util.concurrent.CountDownLatch answered = new java.util.concurrent.CountDownLatch(1);\n"
            + "        final boolean[] go = {false};\n"
            + "        final android.app.AlertDialog[] shown = {null};\n"
            + "        final long since = android.os.SystemClock.elapsedRealtime();\n"
            + "        runOnUiThread(() -> {\n"
            + "            if (isFinishing() || isDestroyed()) { answered.countDown(); return; }\n"
            + "            shown[0] = new android.app.AlertDialog.Builder(this)\n"
            + "                    .setTitle(supersedeLossTitle())\n"
            + "                    .setMessage(supersedeLossText(creditLost))\n"
            + "                    .setCancelable(false)\n"
            + "                    .setPositiveButton(\"Continue\", (d, w) -> { go[0] = true; answered.countDown(); })\n"
            + "                    .setNegativeButton(\"Cancel\", (d, w) -> answered.countDown())\n"
            + "                    .show();\n"
            + "        });\n"
            + "        try {\n"
            + "            while (!answered.await(500, java.util.concurrent.TimeUnit.MILLISECONDS)) {\n"
            + "                if (isFinishing() || isDestroyed()\n"
            + "                        || supersedeWarnExpired(android.os.SystemClock.elapsedRealtime() - since)) {\n"
            + "                    runOnUiThread(() -> { if (shown[0] != null && shown[0].isShowing()) shown[0].dismiss(); });\n"
            + "                    return false;\n"
            + "                }\n"
            + "            }\n"
            + "        } catch (InterruptedException e) {\n"
            + "            Thread.currentThread().interrupt();\n"
            + "            return false;\n"
            + "        }\n"
            + "        return go[0];\n"
            + "    }";
    static final String BACK =
            "    private void backToParkedSession(String coldLockReply, int parkedUid) {\n"
            + "        final String[] p = parkedSessionStill(coldLockReply, parkedUid);\n"
            + "        if (p == null) return;\n"
            + "        runOnUiThread(() -> {\n"
            + "            if (isFinishing() || resumeMode) return;\n"
            + "            enterResumeMode(p[3], p[0], \"fido2\".equals(p[1]), \"pin\".equals(p[2]));\n"
            + "        });\n"
            + "    }";
    // The question's code in roamLogin: asked whatever GET-PARKED-CREDIT answers, its answer only picks the credit
    // sentence, Cancel goes back to the parked session, Continue records it. The comment above it is not pinned.
    static final String QUESTION =
            "            if (parkedCreditProbeDue(isCreate, supersedeColdUid, supersedeLossAcceptedUid)) {\n"
            + "                String pc = \"\";\n"
            + "                try { pc = sendDaemon(\"GET-PARKED-CREDIT\\n\"); } catch (Throwable ignore) {}\n"
            + "                if (!confirmSupersedeLoss(parkedCreditLost(pc))) {\n"
            + "                    hideRestore();\n"
            + "                    // asked again: the warning may have stood for minutes, and the parked session can\n"
            + "                    // have been wiped meanwhile (the 12 h wipe, the failed-eviction one)\n"
            + "                    String clNow = \"\";\n"
            + "                    try { clNow = sendDaemon(\"GET-COLDLOCK\\n\"); } catch (Throwable ignore) {}\n"
            + "                    backToParkedSession(clNow, supersedeColdUid);\n"
            + "                    return;\n"
            + "                }\n"
            + "                supersedeLossAcceptedUid = supersedeColdUid; // its NEEDKEY key-wait retry does not ask again\n"
            + "            }\n";
    static final String CREDIT = " That includes storage credit it hasn't saved. Credit saved before that session is safe.";

    public static void main(String[] a) throws Exception {
        // ---- the decision: when a sign-in asks ----
        check("probe: a sign-in over a parked session asks", Lifted.parkedCreditProbeDue(false, 15, -1), "false");
        check("probe: a create never asks (it is refused while a session is parked)",
                !Lifted.parkedCreditProbeDue(true, 15, -1), "true");
        check("probe: no parked session, no question", !Lifted.parkedCreditProbeDue(false, -1, 15), "true");
        check("probe: uid 0 is never a parked session", !Lifted.parkedCreditProbeDue(false, 0, -1), "true");
        check("probe: the sign-in that accepted this session's loss does not ask again",
                !Lifted.parkedCreditProbeDue(false, 15, 15), "true");
        check("probe: an accepted loss is for that parked session only", Lifted.parkedCreditProbeDue(false, 16, 15),
                "false");

        // ---- the decision: which replies add the credit sentence ----
        check("reply: LOST adds the credit sentence", Lifted.parkedCreditLost("LOST"), "false");
        check("reply: LOST with its newline adds the credit sentence", Lifted.parkedCreditLost("LOST\n"), "false");
        check("reply: LOST padded adds the credit sentence", Lifted.parkedCreditLost("  LOST "), "false");
        for (String r : new String[]{"NONE", "NONE\n", "", "ERR", "lost", "LOST 2", "LOSTX", "OK"}) {
            check("reply: '" + r.replace("\n", "\\n") + "' adds no credit sentence", !Lifted.parkedCreditLost(r),
                    "true");
        }
        check("reply: no answer (null) adds no credit sentence", !Lifted.parkedCreditLost(null), "true");

        // ---- the copy ----
        // The gate cannot learn whether the parked session has unsaved changes, so the words must be true either way,
        // of a stored session and a throwaway alike: they say what ends and what is lost IF unsaved, never whether.
        String title = Lifted.supersedeLossTitle(), t0 = Lifted.supersedeLossText(false), t1 = Lifted.supersedeLossText(true);
        check("copy: the title names no credit", !title.isEmpty() && !title.toLowerCase().contains("credit"), title);
        check("copy: says signing in ends a locked session on this phone",
                t0.contains("Signing in now ends a locked session on this phone.")
                        && t1.contains("Signing in now ends a locked session on this phone."), t0 + "\n--\n" + t1);
        check("copy: says anything the session hasn't saved is lost",
                t0.contains("Anything that session hasn't saved is lost.")
                        && t1.contains("Anything that session hasn't saved is lost."), t0 + "\n--\n" + t1);
        check("copy: says what Cancel keeps", t0.endsWith("\n\nCancel keeps that session.")
                && t1.endsWith("\n\nCancel keeps that session."), t0 + "\n--\n" + t1);
        check("copy: without LOST it names no credit", !t0.toLowerCase().contains("credit"), t0);
        check("copy: with LOST it carries the credit sentence",
                t1.contains(" That includes storage credit it hasn't saved.")
                        && t1.contains("Credit saved before that session is safe."), t1);
        check("copy: the credit sentence is the only difference", t1.replace(CREDIT, "").equals(t0), t0 + "\n--\n" + t1);
        String all = title + "\n" + t0 + "\n" + t1, lower = all.toLowerCase();
        check("copy: names no amount (no digit anywhere)", !all.matches("(?s).*[0-9].*"), all);
        check("copy: names no profile (no placeholder)", !all.contains("%") && !all.contains("{") && !all.contains("<")
                && !lower.contains("odtest"), all);
        check("copy: speaks to nobody in particular (no 'your')", !lower.contains("your"), all);
        // The gate cannot say what to do next without saying which kind is parked: a stored session's sign-out retries
        // its wallet read, a throwaway's sign-out destroys it, and the warning shows for both (blind login).
        check("copy: makes no promise that holds for one kind of session only",
                !lower.contains("signing out") && !lower.contains("sign out") && !lower.contains("again")
                        && !lower.contains("save to"), all);
        check("copy: promises nothing about what is unsaved", !lower.contains("unsaved") && !lower.contains("never")
                && !lower.contains("nothing") && !lower.contains("no changes"), all);

        // ---- the wait's limit ----
        check("limit: an answer within two minutes is waited for", !Lifted.supersedeWarnExpired(0)
                && !Lifted.supersedeWarnExpired(119_999L), "expired early");
        check("limit: two minutes unanswered counts as Cancel", Lifted.supersedeWarnExpired(120_000L)
                && Lifted.supersedeWarnExpired(Long.MAX_VALUE), "never expires");

        // ---- Cancel's way back ----
        String[] still = Lifted.parkedSessionStill("COLDLOCK 15 fido2 pin odtest a b\n", 15);
        check("way back: a reply that still names the parked uid is gone back to",
                still != null && "15".equals(still[0]) && "fido2".equals(still[1]) && "pin".equals(still[2])
                        && "odtest a b".equals(still[3]), still == null ? "null" : String.join("|", still));
        check("way back: a reply naming another uid is not gone back to",
                Lifted.parkedSessionStill("COLDLOCK 16 nokey nopin odtest\n", 15) == null, "gone back");
        for (String r : new String[]{"NONE", "NONE\n", "", "COLDLOCK 15", "COLDLOCK x nokey nopin odtest", "ERR"}) {
            check("way back: '" + r.replace("\n", "\\n") + "' is not gone back to",
                    Lifted.parkedSessionStill(r, 15) == null, "gone back");
        }
        check("way back: no answer (null) is not gone back to", Lifted.parkedSessionStill(null, 15) == null, "gone back");

        // ---- wiring, in the chooser itself ----
        // Every anchor must occur EXACTLY ONCE where it is searched, so no check is satisfied (or defeated) by another
        // mention of the same text.
        String src = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(a[0])), "UTF-8");
        String body = method(src, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        if (body != null) {
            int probe = once(body, "coldLock0 = cl0;");
            int refuse = once(body, "if (isCreate && createRefusedForColdLock(coldLock0)) {");
            int due = once(body, "if (parkedCreditProbeDue(isCreate, supersedeColdUid, supersedeLossAcceptedUid)) {");
            int send = once(body, "try { pc = sendDaemon(\"GET-PARKED-CREDIT\\n\"); } catch (Throwable ignore) {}");
            int ask = once(body, "if (!confirmSupersedeLoss(parkedCreditLost(pc))) {\n                    hideRestore();\n");
            int cEnd = ask < 0 ? -1 : body.indexOf("\n                }\n", ask);
            int dueEnd = due < 0 ? -1 : body.indexOf("\n            }\n", due);
            String cb = ask < 0 || cEnd < 0 ? "" : body.substring(ask, cEnd);
            int reask = cb.indexOf("try { clNow = sendDaemon(\"GET-COLDLOCK\\n\"); } catch (Throwable ignore) {}");
            int back = cb.indexOf("backToParkedSession(clNow, supersedeColdUid);\n                    return;");
            check("wiring: Cancel hands the form back, asks GET-COLDLOCK again, goes back only to that reply and ends "
                    + "the sign-in", reask > 0 && back > reask && cb.endsWith("return;")
                    && !cb.contains("coldLock0") && count(cb, "backToParkedSession(") == 1, cb);
            int accept = once(body, "supersedeLossAcceptedUid = supersedeColdUid;");
            int net = once(body, "final boolean offline = !hasInternetWithGrace(8000);");
            int create = once(body, "int uid = createRoamUser(name, pw);");
            check("wiring: the question comes after the GET-COLDLOCK probe and the create refusal",
                    probe > 0 && refuse > probe && due > refuse, probe + " " + refuse + " " + due);
            check("wiring: it asks GET-PARKED-CREDIT, then the question", due > 0 && send > due && ask > send,
                    due + " " + send + " " + ask);
            // NWP-20261124-08: the reply picks the credit sentence and nothing else -- no gate between it and the
            // question, and parkedCreditLost read once, as the question's argument.
            check("wiring: the dialog is reached whatever GET-PARKED-CREDIT answers",
                    send > 0 && ask > send && !body.substring(send, ask).contains("if (")
                            && count(body, "parkedCreditLost(") == 1, send + " " + ask);
            int flag = once(body, "confirmSupersedeLoss(parkedCreditLost(pc))");
            check("wiring: the credit flag is parkedCreditLost(pc)",
                    flag > 0 && count(src, "confirmSupersedeLoss(") == 2, flag + " " + count(src, "confirmSupersedeLoss("));
            check("wiring: a create never reaches the question", due > 0 && dueEnd > due && flag > due && flag < dueEnd,
                    due + " " + flag + " " + dueEnd);
            check("wiring: Continue records the accepted session, past the Cancel branch",
                    ask > 0 && accept > ask, ask + " " + accept);
            check("wiring: the question comes before the network wait and before any user is created",
                    accept > 0 && net > accept && create > net, accept + " " + net + " " + create);
            int ok = once(body, "            if (ok) {\n                supersedeLossAcceptedUid = -1;");
            check("wiring: a sign-in that commits forgets the accepted session", ok > create, ok);
            int nk = once(body, "if (reply.startsWith(\"NEEDKEY\")) {");
            int nkEnd = nk < 0 ? -1 : body.indexOf("return; // finally", nk);
            check("wiring: a NEEDKEY key-wait keeps the accepted session (it is the same sign-in)",
                    nk > 0 && nkEnd > nk && !body.substring(nk, nkEnd).contains("supersedeLossAcceptedUid"),
                    nk + " " + nkEnd);
        } else {
            check("wiring: roamLogin found", false, "missing");
        }
        String hide = method(src, "private void hideRestore() {");
        check("wiring: hideRestore forgets the accepted session before anything else",
                hide != null && hide.startsWith("private void hideRestore() {\n        supersedeLossAcceptedUid = -1;"),
                hide == null ? "missing" : hide.substring(0, Math.min(120, hide.length())));
        check("wiring: the accepted session starts unset",
                once(src, "private volatile int supersedeLossAcceptedUid = -1;") > 0, "missing");
        // the declaration, hideRestore, the committed sign-in and the accepting Continue: four, and no fifth
        check("wiring: nothing else sets the accepted session",
                count(src, "supersedeLossAcceptedUid = ") == 4, count(src, "supersedeLossAcceptedUid = "));
        pinned("confirmSupersedeLoss", src, CONFIRM);
        pinned("backToParkedSession", src, BACK);
        pinned("the parked-session question in roamLogin", src, QUESTION);

        System.out.println(fails == 0 ? "ALL " + runs + " PASS" : fails + " of " + runs + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }

    /** The text of the method whose signature line is sig, from the signature to the next member at its indentation,
     *  or null (reported). */
    static String method(String src, String sig) {
        int at = once(src, sig);
        if (at < 0) return null;
        int end = src.indexOf("\n    private ", at + 1);
        int end2 = src.indexOf("\n    /**", at + 1);
        if (end2 >= 0 && (end < 0 || end2 < end)) end = end2;
        return end < 0 ? src.substring(at) : src.substring(at, end);
    }

    static int count(String s, String key) {
        int n = 0;
        for (int i = s.indexOf(key); i >= 0; i = s.indexOf(key, i + 1)) n++;
        return n;
    }

    /** pin must occur exactly once in src. When it does not, report the first line that differs from the source
     *  text that starts with the pin's own first line (its signature), so a reformat is found without a diff. */
    static void pinned(String name, String src, String pin) {
        int at = src.indexOf(pin);
        if (at >= 0 && src.indexOf(pin, at + 1) < 0) {
            check("pinned: " + name, true, "");
            return;
        }
        if (at >= 0) {
            check("pinned: " + name, false, "occurs more than once");
            return;
        }
        String[] want = pin.split("\n", -1);
        int sig = src.indexOf(want[0]);
        if (sig < 0) {
            check("pinned: " + name, false, "its first line is gone: " + want[0].trim());
            return;
        }
        String[] got = src.substring(sig).split("\n", -1);
        for (int i = 0; i < want.length; i++) {
            String g = i < got.length ? got[i] : "<end of file>";
            if (!want[i].equals(g)) {
                check("pinned: " + name, false, "line " + (i + 1) + " differs\n     want: " + want[i]
                        + "\n     have: " + g);
                return;
            }
        }
        check("pinned: " + name, false, "no line differs, yet the text does not match");
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
