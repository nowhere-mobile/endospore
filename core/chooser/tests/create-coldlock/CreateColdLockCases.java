// NWP-20261010-16: the cases for the gate's create-over-cold-lock decision, its copy and its wiring, run against Lifted
// (the pure helpers run.sh lifts out of ChooserActivity.java). args[0] = ChooserActivity.java; args[1..] = the reply
// prefixes its create branch tests with startsWith, which run.sh extracts from that file.
public final class CreateColdLockCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static String show(String[] p) {
        return p == null ? "null" : String.join("|", p);
    }

    static final String TITLE = "Finish the open session first";
    static final String TEXT_NAMED = "alice's session is locked on this phone, waiting to be resumed. A new profile "
            + "can't be created while it's open — creating one would end that session, and anything it hasn't saved "
            + "yet would be lost.\n\nResume it and sign out, then come back here to create your profile."
            + "\n\nIf it isn't yours: signing in, to a profile or as a throwaway, ends that session once the "
            + "sign-in succeeds, and you'll be asked first if it holds credit that would be lost. Restarting the "
            + "phone also ends it, without asking, and so does the automatic wipe 12 hours after it locked. Either "
            + "way, anything it hasn't saved is lost.";
    static final String TEXT_NAMELESS = "A session is locked on this phone, waiting to be resumed. A new profile "
            + "can't be created while it's open — creating one would end that session, and anything it hasn't saved "
            + "yet would be lost.\n\nResume it and sign out, then come back here to create your profile."
            + "\n\nIf it isn't yours: signing in, to a profile or as a throwaway, ends that session once the "
            + "sign-in succeeds, and you'll be asked first if it holds credit that would be lost. Restarting the "
            + "phone also ends it, without asking, and so does the automatic wipe 12 hours after it locked. Either "
            + "way, anything it hasn't saved is lost.";

    // The dialog, the create/sign-in form switch and the head of resume mode, pinned byte for byte:
    // none is a pure helper the cases can run, and the ways they break silently (returning before the dialog, a
    // "Resume it" that opens nothing, a claim-code field left on the resume screen, the form
    // reset AFTER resume mode set its button and hint) each change the text. A deliberate edit updates the pin
    // with it; a failure names the first line that differs.
    static final String SHOW_DIALOG =
            "    private void showCreateOverColdLock(String coldLockReply) {\n"
            + "        final String[] p = parseColdLock(coldLockReply);\n"
            + "        runOnUiThread(() -> {\n"
            + "            if (isFinishing() || resumeMode) return;\n"
            + "            android.app.AlertDialog.Builder b = new android.app.AlertDialog.Builder(this)\n"
            + "                    .setTitle(createOverColdLockTitle())\n"
            + "                    .setMessage(createOverColdLockText(p));\n"
            + "            if (p != null) {\n"
            + "                b.setPositiveButton(\"Resume it\", (d, w) -> {\n"
            + "                    if (!resumeMode) enterResumeMode(p[3], p[0], \"fido2\".equals(p[1]), \"pin\".equals(p[2]));\n"
            + "                });\n"
            + "                b.setNegativeButton(\"Cancel\", null);\n"
            + "            } else {\n"
            + "                b.setPositiveButton(\"OK\", null);\n"
            + "            }\n"
            + "            b.show();\n"
            + "        });\n"
            + "    }";
    static final String SET_CREATE_MODE =
            "    private void setCreateMode(boolean on) {\n"
            + "        createMode = on;\n"
            + "        PassReveal.setFieldVisible(confirmField, createMode);   // #81: wrapper, not the bare EditText\n"
            + "        gateCodeField.setVisibility(createMode ? View.VISIBLE : View.GONE); // #57\n"
            + "        gateScanLink.setVisibility(createMode ? View.VISIBLE : View.GONE);  // #57\n"
            + "        genLink.setVisibility(createMode ? View.VISIBLE : View.GONE);       // #79\n"
            + "        playAtCreateSw.setVisibility(PlayAtCreate.offered(gateGosStore, createMode) ? View.VISIBLE : View.GONE); // NWP-20261124-09\n"
            + "        playAtCreateSw.setChecked(false);                                   // NWP-20261124-09: off by default, every time\n"
            + "        passStrength.setVisibility(View.GONE);                              // #79: reappears once they type\n"
            + "        setPassRevealed(false);                                            // re-mask (+ reset toggle) on mode switch\n"
            + "        unlockBtn.setText(createMode ? \"Create profile\" : \"Unlock\");\n"
            + "        toggle.setText(createMode ? \"Have a profile?  Sign in\" : \"New here?  Create a profile\");\n"
            + "        result.setText(\"\");\n"
            + "        addPhoneLink.setVisibility(View.GONE); // the offer belonged to the message just cleared\n"
            + "        confirmField.setText(\"\");\n"
            + "        gateCodeField.setText(\"\");\n"
            + "        passField.setText(\"\");\n"
            + "    }";
    static final String RESUME_HEAD =
            "    private void enterResumeMode(String name, String uid, boolean needsKey, boolean needsPin) {\n"
            + "        resumeName = name; resumeUid = uid; resumeNeedsKey = needsKey; resumeNeedsPin = needsPin;\n"
            + "        if (resumeMode) return; // already showing -> just keep name/uid fresh, don't re-toggle / refocus\n"
            + "        resumeMode = true;\n"
            + "        // NWP-20261010-16: leave the create form the way its toggle does, claim-code field and scan link included.\n"
            + "        // The create refusal's \"Resume it\" lands here from the create form, and the bare `createMode = false` this\n"
            + "        // replaces left those two showing on the resume screen.\n"
            + "        if (createMode) setCreateMode(false);";
    public static void main(String[] a) throws Exception {
        // ---- parseColdLock ----
        String[] p = Lifted.parseColdLock("COLDLOCK 12 nokey nopin alice");
        check("parse: plain", p != null && p.length == 4 && "12".equals(p[0]) && "nokey".equals(p[1])
                && "nopin".equals(p[2]) && "alice".equals(p[3]), show(p));
        p = Lifted.parseColdLock("COLDLOCK 13 fido2 pin Mary Ann Lee\n");
        check("parse: spaced name, flags, trailing newline", p != null && "13".equals(p[0]) && "fido2".equals(p[1])
                && "pin".equals(p[2]) && "Mary Ann Lee".equals(p[3]), show(p));
        check("parse: NONE", Lifted.parseColdLock("NONE") == null, show(Lifted.parseColdLock("NONE")));
        check("parse: empty", Lifted.parseColdLock("") == null, show(Lifted.parseColdLock("")));
        check("parse: null", Lifted.parseColdLock(null) == null, "not null");
        check("parse: too few fields", Lifted.parseColdLock("COLDLOCK 12 alice") == null,
                show(Lifted.parseColdLock("COLDLOCK 12 alice")));
        check("parse: bad uid", Lifted.parseColdLock("COLDLOCK x nokey nopin alice") == null,
                show(Lifted.parseColdLock("COLDLOCK x nokey nopin alice")));
        check("parse: negative uid", Lifted.parseColdLock("COLDLOCK -1 nokey nopin alice") == null,
                show(Lifted.parseColdLock("COLDLOCK -1 nokey nopin alice")));
        check("parse: no name", Lifted.parseColdLock("COLDLOCK 12 nokey nopin  ") == null,
                show(Lifted.parseColdLock("COLDLOCK 12 nokey nopin  ")));

        // ---- createRefusedForColdLock ----
        // NWP-20261123-29: the reply alone decides. The daemon's GET-COLDLOCK answers NONE for a marker whose user is
        // gone (androidUserGone), so the gate keeps no user list of its own.
        String parked = "COLDLOCK 12 nokey nopin alice";
        check("refuse: parked", Lifted.createRefusedForColdLock(parked), false);
        check("refuse: parked, spaced name and trailing newline",
                Lifted.createRefusedForColdLock("COLDLOCK 13 fido2 pin Mary Ann Lee\n"), false);
        check("refuse: COLDLOCK that does not parse", Lifted.createRefusedForColdLock("COLDLOCK garbled"), false);
        check("allow: NONE", !Lifted.createRefusedForColdLock("NONE"), true);
        check("allow: no answer", !Lifted.createRefusedForColdLock(""), true);
        check("allow: null", !Lifted.createRefusedForColdLock(null), true);
        check("allow: a PENDING reply", !Lifted.createRefusedForColdLock("PENDING 12"), true);

        // ---- createReplyColdLocked ----
        check("reply: ERR-COLDLOCK", Lifted.createReplyColdLocked("ERR-COLDLOCK"), false);
        for (String other : new String[]{"ERR-BUSY", "ERR-NOCODE", "ERR", "BLANK", "NOCREDIT", "EXISTS", "",
                "OK 0 RECOVERY abandon ability able"}) {
            check("reply: not " + other, !Lifted.createReplyColdLocked(other), true);
        }
        check("reply: null", !Lifted.createReplyColdLocked(null), true);

        // ---- copy ----
        check("title, exact", TITLE.equals(Lifted.createOverColdLockTitle()), Lifted.createOverColdLockTitle());
        String named = Lifted.createOverColdLockText(Lifted.parseColdLock(parked));
        check("text with the name, exact", TEXT_NAMED.equals(named), named);
        String nameless = Lifted.createOverColdLockText(null);
        check("text without a name, exact", TEXT_NAMELESS.equals(nameless), nameless);
        check("text offers both ways forward", named.contains("Resume it") && named.contains("sign out"), named);
        for (String t : new String[]{named, nameless}) {
            int signIn = t.indexOf("sign-in succeeds"), restart = t.indexOf("Restarting");
            check("text names signing in before a restart", signIn > 0 && restart > signIn, signIn + " " + restart);
            check("text promises the warning", t.contains("asked first"), t);
            check("text never tells anyone to restart", !t.toLowerCase().contains("restart your phone")
                    && !t.toLowerCase().contains("restart the phone to") && !t.contains("Restart the phone"), t);
        }
        check("text says why", named.contains("would end that session, and anything it hasn't saved yet would be lost"),
                named);


        // ---- an older chooser reads ERR-COLDLOCK as its blank failure ----
        // The create branch matches a reply with startsWith on a fixed set of prefixes and shows the blind "—" for
        // anything else that is not OK. OLD_PREFIXES is that set in chooser 4.59 (versionCode 224), the last one
        // without this slice, copied by hand from its source (it is fixed history, so it is not re-extracted). The
        // live set, which run.sh does extract, is checked too, so a prefix added later cannot catch ERR-COLDLOCK
        // ahead of createReplyColdLocked either. None may be a prefix of it.
        String[] OLD_PREFIXES = {"ERR-BUSY", "ERR-NOCODE", "EXISTS", "NOCREDIT", "NOSTORE", "OK", "RATELIMIT", "WEAK"};
        for (String pre : OLD_PREFIXES) {
            check("chooser 4.59: '" + pre + "' does not catch ERR-COLDLOCK", !"ERR-COLDLOCK".startsWith(pre), pre);
        }
        check("live create branch: prefixes were found", a.length > 3, a.length - 1);
        for (int i = 1; i < a.length; i++) {
            check("live create branch: '" + a[i] + "' does not catch ERR-COLDLOCK", !"ERR-COLDLOCK".startsWith(a[i]), a[i]);
        }

        // ---- wiring, in roamLogin itself ----
        // Every anchor must occur EXACTLY ONCE in the method, so no check can be satisfied (or defeated) by an earlier
        // mention of the same text: the first cut of this check found "hasInternetWithGrace(8000)" in the method's
        // opening comment, 220 characters in, and failed correct code.
        String src = new String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(a[0])), "UTF-8");
        int login = once(src, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        int end = login < 0 ? -1 : src.indexOf("\n    private ", login + 1);
        check("wiring: roamLogin found, and where it ends", login > 0 && end > login, login + " " + end);
        if (login > 0 && end > login) {
            String body = src.substring(login, end);
            int probe = once(body, "coldLock0 = cl0;");
            int refuse = once(body, "if (isCreate && createRefusedForColdLock(coldLock0)) {");
            int shown = once(body, "hideRestore();\n                showCreateOverColdLock(coldLock0);\n                return;\n            }");
            int net = once(body, "final boolean offline = !hasInternetWithGrace(8000);");
            int create = once(body, "createStreaming(\"CREATE\\n\"");
            int errc = once(body, "if (createReplyColdLocked(cr)) {");
            int errShown = once(body, "hideRestore();\n                    String cl1 = \"\";\n"
                    + "                    try { cl1 = sendDaemon(\"GET-COLDLOCK\\n\").trim(); } catch (Throwable ignore) {}\n"
                    + "                    showCreateOverColdLock(cl1);\n                    return;");
            int blank = once(body, "if (!cr.startsWith(\"OK\")) { hideRestore(); showBlank(); return; }");
            check("wiring: the create is refused after the GET-COLDLOCK probe and before the network wait",
                    probe > 0 && refuse > probe && net > refuse, probe + " " + refuse + " " + net);
            check("wiring: the refusal re-enables the form, shows the dialog and returns, inside its if, before the "
                    + "network wait",
                    refuse > 0 && shown > refuse && net > shown, refuse + " " + shown + " " + net);
            check("wiring: ERR-COLDLOCK is handled after the CREATE and before the blank failure, re-enables the form "
                    + "and returns",
                    create > 0 && errc > create && errShown > errc && blank > errShown,
                    create + " " + errc + " " + errShown + " " + blank);
        }
        check("wiring: the toggle uses setCreateMode",
                once(src, "toggle.setOnClickListener(v -> setCreateMode(!createMode));") > 0, "missing");
        pinned("showCreateOverColdLock", src, SHOW_DIALOG);
        check("wiring: the gate keeps no user list of its own", !src.contains("liveSecondaryUids"), "found");
        pinned("setCreateMode", src, SET_CREATE_MODE);
        pinned("enterResumeMode, through leaving the create form", src, RESUME_HEAD);

        System.out.println(fails == 0 ? "ALL " + runs + " PASS" : fails + " of " + runs + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
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
