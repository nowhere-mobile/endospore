// NWP-20261010-10: the cases for the chooser's pure sign-out-refusal helpers, run against Lifted (run.sh).
public final class EndUnsavedCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static final String OLD_REFUSED = "Couldn't save this session — but your last saved copy is safe and unchanged. "
            + "You're still signed in. This profile changed while the save was running; signing out "
            + "again usually works. If it keeps happening, please report it.";
    static final String OLD_NOCREDIT = "Couldn't save your data — your storage plan is out. You're still signed in. "
            + "Add storage, then sign out again.";
    // NWP-20261101-08 (Q070): the generic failure is what an ERR-PUSH sign-out shows; it names Lock first.
    static final String NEW_OTHER = "Couldn't save your data — Nowhere couldn't reach your storage, and you're still signed in.\n\n"
            + "Tap Lock to keep this session safe: it locks with no connection needed and stays on this phone, "
            + "encrypted, until you come back, or until it's wiped 12 hours after locking. Nothing is lost. "
            + "Or sign out again once you're online.";
    // NWP-20261113-18: the generic arm's Lock sentence, which the stalled-save text must carry word for word.
    static final String LOCK_SENTENCE = "Tap Lock to keep this session safe: it locks with no connection needed and stays on this phone, "
            + "encrypted, until you come back, or until it's wiped 12 hours after locking. Nothing is lost. ";

    // NWP-20261117-32: the generic answer to a bare BUSY or a BUSY token this chooser does not know.
    static final String END_BUSY = "The phone is busy, so the session wasn't ended. You're still signed in. Try again in a minute.";
    static final String RESTART_BUSY = "The phone is busy, so the phone wasn't restarted. You're still signed in. Try again in a minute.";

    static String busyMessage(boolean restart, String r) {
        return restart ? Lifted.restartUnsavedReplyMessage(r) : Lifted.endUnsavedReplyMessage(r);
    }

    // busyCases: every BUSY that is not a seal says no save is running, says what it did not do (outcome), that the
    // user is still signed in and to try again; each named cause says its own sentence; a bare or unknown BUSY is the
    // generic text.
    static void busyCases(String what, String outcome, String generic, boolean restart) {
        for (String r : new String[]{"BUSY teardown", "BUSY rent", "BUSY slot", "BUSY", " BUSY ", "BUSY other",
                "BUSY seal extra", "BUSY  rent"}) {
            String m = busyMessage(restart, r);
            check(what + ": no save text for " + r, m != null && !m.contains("A save is running") && m.contains(outcome)
                    && m.contains("You're still signed in.") && m.contains("Try again"), m);
        }
        String td = busyMessage(restart, "BUSY teardown");
        check(what + ": teardown", td.startsWith("This session is already being signed out or locked"), td);
        String rent = busyMessage(restart, "BUSY rent");
        check(what + ": rent", rent.startsWith("The phone is paying for your storage right now"), rent);
        check(what + ": rent, two spaces", rent.equals(busyMessage(restart, "BUSY  rent")), busyMessage(restart, "BUSY  rent"));
        String slot = busyMessage(restart, "BUSY slot");
        check(what + ": slot", slot.startsWith("The phone is busy with another task"), slot);
        for (String r : new String[]{"BUSY", " BUSY ", "BUSY other", "BUSY seal extra"}) {
            check(what + ": generic for " + r, generic.equals(busyMessage(restart, r)), busyMessage(restart, r));
        }
        check(what + ": the generic is not the seal text", !generic.equals(busyMessage(restart, "BUSY seal")), "");
    }

    // NW-db441ee766cb's shape: #de refused by the shrink guard, everything else saved.
    static final String FINAL_DE = "REFUSED FINAL 1728551000\nSCOPE de refused:shrink 1728550000\nSAVED 1728551000\n";
    static final String RETRY_STALE = "REFUSED RETRY 1728551000\nSCOPE media refused:stale 1728550000\nSAVED 1728551000\n";
    static final String RETRY_UNREADABLE = "REFUSED RETRY 1728551000\nSCOPE vault refused:unreadable-head 0\nSAVED 0\n";

    /** The pre-NWP-20261017-16 two-argument call: no gateway reason, and the cases' own time formatter. */
    static String lfm(String why, String refusal) { return Lifted.logoffFailMessage(why, refusal, null, t -> "T" + t); }

    public static void main(String[] a) {
        java.util.function.LongFunction<String> at = t -> "T" + t;

        // ---- offerEndUnsaved: the control appears ONLY for a FINAL guard refusal ----
        check("offer: final refusal", Lifted.offerEndUnsaved("REFUSED", FINAL_DE), false);
        check("offer: retry refusal", !Lifted.offerEndUnsaved("REFUSED", RETRY_STALE), true);
        check("offer: older daemon (null)", !Lifted.offerEndUnsaved("REFUSED", null), true);
        check("offer: empty reply", !Lifted.offerEndUnsaved("REFUSED", ""), true);
        check("offer: NONE", !Lifted.offerEndUnsaved("REFUSED", "NONE\n"), true);
        check("offer: garbage", !Lifted.offerEndUnsaved("REFUSED", "REFUSED FINALLY 1\n"), true);
        check("offer: NOCREDIT never", !Lifted.offerEndUnsaved("NOCREDIT", FINAL_DE), true);
        check("offer: MEDIA keeps an earlier FINAL licence (round 3)", Lifted.offerEndUnsaved("MEDIA", FINAL_DE), "");
        check("offer: MEDIA without a licence", !Lifted.offerEndUnsaved("MEDIA", "SAVED 5\nMEDIA 1\n"), "");
        check("offer: network failure never", !Lifted.offerEndUnsaved("", FINAL_DE), true);
        check("offer: null why", !Lifted.offerEndUnsaved(null, FINAL_DE), true);

        // ---- logoffFailMessage ----
        check("msg: older daemon is byte-identical", OLD_REFUSED.equals(lfm("REFUSED", null)),
                lfm("REFUSED", null));
        check("msg: stale retry keeps the old advice", OLD_REFUSED.equals(lfm("REFUSED", RETRY_STALE)),
                lfm("REFUSED", RETRY_STALE));
        String unr = lfm("REFUSED", RETRY_UNREADABLE);
        check("msg: unreadable head says so", unr.contains("couldn't read your stored copy") && !unr.contains("changed while"), unr);
        check("msg: unreadable head still offers a retry", unr.contains("Signing out again may work"), unr);
        check("msg: unreadable head says intact, not unchanged", unr.contains("stored copy is intact") && !unr.contains("unchanged"), unr);
        check("msg: NOCREDIT unchanged", OLD_NOCREDIT.equals(lfm("NOCREDIT", FINAL_DE)),
                lfm("NOCREDIT", FINAL_DE));
        // NWP-20261017-16: the gateway's own reason, quoted; null/blank leaves the sentence byte-identical.
        String reasoned = Lifted.logoffFailMessage("NOCREDIT", null, "free quota exceeded", at);
        check("msg: NOCREDIT quotes the gateway's reason", reasoned.contains("The storage service said: \"free quota exceeded\"."), reasoned);
        check("msg: NOCREDIT with a reason keeps the signed-in line and the old sentence",
                reasoned.startsWith(OLD_NOCREDIT) && reasoned.contains("You're still signed in."), reasoned);
        check("msg: NOCREDIT with no reason is byte-identical", OLD_NOCREDIT.equals(Lifted.logoffFailMessage("NOCREDIT", null, null, at)),
                Lifted.logoffFailMessage("NOCREDIT", null, null, at));
        check("msg: NOCREDIT with a blank reason is byte-identical", OLD_NOCREDIT.equals(Lifted.logoffFailMessage("NOCREDIT", null, "  ", at)),
                Lifted.logoffFailMessage("NOCREDIT", null, "  ", at));
        check("msg: REFUSED ignores a reason", OLD_REFUSED.equals(Lifted.logoffFailMessage("REFUSED", null, "free quota exceeded", at)),
                Lifted.logoffFailMessage("REFUSED", null, "free quota exceeded", at));
        check("msg: MEDIA ignores a reason", lfm("MEDIA", null).equals(Lifted.logoffFailMessage("MEDIA", null, "free quota exceeded", at)), "");
        check("reason line: parsed", "free quota exceeded".equals(Lifted.sealReasonOf("REASON free quota exceeded")), Lifted.sealReasonOf("REASON free quota exceeded"));
        check("reason line: null, empty and foreign lines read as none", Lifted.sealReasonOf(null) == null
                && Lifted.sealReasonOf("REASON ") == null && Lifted.sealReasonOf("KIND logoff") == null, "");
        check("msg: generic failure is the Lock-first text", NEW_OTHER.equals(lfm("", null)), lfm("", null));
        String gen = lfm("", null);
        check("msg: generic failure names Lock before 'sign out again'",
                gen.indexOf("Tap Lock") >= 0 && gen.indexOf("Tap Lock") < gen.indexOf("sign out again"), gen);
        String media = lfm("MEDIA", null);
        check("msg: MEDIA, exact", ("Couldn't finish signing out — this phone couldn't close your photos and media safely, so "
                + "nothing was saved over your stored copy. You're still signed in. Try again in a minute.\n\n"
                + "Restarting your phone is safe for your stored copy: it only discards what this phone hasn't "
                + "saved yet. Texts and calls this phone is still holding for delivery are lost.").equals(media), media);
        // NWP-20261117-03: from MEDIA 2 the daemon already retried the sweep; below it the text is the old one, exact.
        check("msg: MEDIA once is the old exact text", media.equals(lfm("MEDIA", "SAVED 5\nMEDIA 1\n")),
                lfm("MEDIA", "SAVED 5\nMEDIA 1\n"));
        String retried = "Couldn't finish signing out — this phone tried several times but couldn't close your photos "
                + "and media safely, so nothing was saved over your stored copy. You're still signed in.\n\n"
                + "Restarting your phone ends this session and loses whatever this phone hasn't saved since its "
                + "last good save. Your stored copy stays safe. "
                + "Texts and calls this phone is still holding for delivery are lost.";
        check("msg: MEDIA retried, exact", retried.equals(lfm("MEDIA", "SAVED 5\nMEDIA 2\n")), lfm("MEDIA", "SAVED 5\nMEDIA 2\n"));
        for (String r : new String[]{"SAVED 5\nMEDIA 2\n", "SAVED 5\nMEDIA 4\n"}) {
            String m = lfm("MEDIA", r);
            for (String bad : new String[]{"Try again", "try again", "in a minute"}) {
                check("msg: MEDIA retried never says '" + bad + "'", !m.contains(bad), m);
            }
            check("msg: MEDIA retried says signed in, the last good save and the telephony loss",
                    m.contains("You're still signed in.") && m.contains("last good save")
                    && m.contains("Texts and calls this phone is still holding for delivery are lost."), m);
        }
        check("msg: MEDIA retried with a FINAL licence", retried.equals(lfm("MEDIA", FINAL_DE + "MEDIA 2\n")),
                lfm("MEDIA", FINAL_DE + "MEDIA 2\n"));

        String fin = lfm("REFUSED", FINAL_DE);
        String wantFin = "Couldn't save this session, and signing out again will most likely fail the same way.\n\n"
                + "This phone's copy of your settings is missing data that your stored copy has, so Nowhere won't save "
                + "it over the stored copy.\n\n"
                + "Your stored copy is intact, and you're still signed in. You can keep using this session, "
                + "or end it without saving.";
        check("msg: final shrink, exact", wantFin.equals(fin), fin);
        for (String bad : new String[]{"usually works", "try again", "Try again", "another device", "sign out there",
                "other device", "may work", "unchanged", "won't change that"}) {
            check("msg: final never says '" + bad + "'", !fin.contains(bad), fin);
        }
        String two = lfm("REFUSED",
                "REFUSED FINAL 1\nSCOPE de refused:shrink 0\nSCOPE media refused:shrink 0\nSCOPE apps refused:apps-vanished 0\nSAVED 0\n");
        check("msg: two shrunk scopes, one sentence, apps not named",
                two.contains("This phone's copy of your settings and your photos & media is missing data")
                        && !two.contains("your apps"), two);
        String vault = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:shrink 0\nSAVED 0\n");
        check("msg: the CE scope is named for what it holds",
                vault.contains("This phone's copy of your app data, texts and call history is missing data"), vault);
        String nr = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE de refused:no-receipt 0\nSAVED 0\n");
        check("msg: no-receipt covers both causes", nr.contains("can't be matched to your stored copy")
                && nr.contains("didn't finish loading when you signed in") && nr.contains("your passphrase changed during this session"), nr);
        check("msg: stale-base names no other device", lfm("REFUSED",
                "REFUSED FINAL 1\nSCOPE de refused:stale-base 0\nSAVED 0\n")
                .contains("Your stored copy of your settings changed after this phone loaded it"), "stale-base");
        String delTok = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:deleted 0\nSAVED 0\n");
        check("msg: a deleted TOKEN alone never says deleted", !delTok.contains("deleted")
                && delTok.contains("A safety check stopped Nowhere from saving your app data, texts and call history."), delTok);
        String del = lfm("REFUSED",
                "REFUSED FINAL 1\nSCOPE vault refused:deleted 0\nSCOPE de refused:fence 0\nSAVED 0\nDELETED\n");
        check("msg: deleted (store-confirmed) said once", del.indexOf("This profile was deleted") >= 0
                && del.indexOf("This profile was deleted") == del.lastIndexOf("This profile was deleted"), del);
        String mixed = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE de refused:shrink 0\nSCOPE media refused:stale 0\nSAVED 0\n");
        check("msg: a retryable scope beside a final one is still named, without a cause",
                mixed.contains("A safety check stopped Nowhere from saving your photos & media."), mixed);

        // ---- NWP-20261111-02 (Q016): the stranded phone's cause lines (the four NWP-20261111-01 reasons) ----
        String[] stranded = {"locks-changed", "locks-changed-key", "unlock-lost", "unlock-lost-key"};
        String lck = "REFUSED FINAL 1\nSCOPE vault refused:locks-changed-key 1700000000\nSAVED 1700000000\n";
        String e1 = lfm("REFUSED", lck);
        check("E1 locks-changed-key names the sign-in change", e1.contains("sign-in was changed after this phone signed in"), e1);
        check("E1 locks-changed-key states the vault's last save", e1.contains("Changes made here since T1700000000 aren't saved."), e1);
        check("E1 locks-changed-key is not the safety-check fallback", !e1.contains("safety check"), e1);
        check("E1 locks-changed-key keeps the FINAL frame", e1.contains("Your stored copy is intact, and you're still signed in."), e1);
        String e1b = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:locks-changed 1700000000\nSAVED 1700000500\n");
        check("E1 locks-changed: the time is the vault SCOPE line's, not SAVED's",
                e1b.contains("sign-in was changed") && e1b.contains("T1700000000") && !e1b.contains("T1700000500"), e1b);
        String e2 = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:unlock-lost 1700000000\nSAVED 1700000500\n");
        check("E2 unlock-lost has its own line", e2.contains("can no longer unlock this profile")
                && !e2.contains("sign-in was changed"), e2);
        check("E2 unlock-lost states the vault's last save", e2.contains("Changes made here since T1700000000 aren't saved.")
                && !e2.contains("T1700000500"), e2);
        String e2z = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:unlock-lost-key 0\nSAVED 1700000500\n");
        check("E2 no save on record: 'since it was last saved'", e2z.contains("can no longer unlock this profile")
                && e2z.contains("Changes made here since it was last saved aren't saved.")
                && !e2z.contains("T1700000500") && !e2z.contains("T0"), e2z);
        for (String r : stranded) {
            String m = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:" + r + " 1700000000\nSAVED 1700000000\n");
            check("E3 " + r + " states its cause", (m.contains("this phone can't save to it")
                    || m.contains("can no longer unlock this profile")) && !m.contains("safety check"), m);
            for (String bad : new String[]{"another", "other phone", "sign out there", "handset"}) {
                check("E3 " + r + " never says '" + bad + "'", !m.contains(bad), m);
            }
            check("E4 guardFinal " + r, Lifted.guardFinal(r), r);
        }
        check("E4 a stranded vault never gets the blind dialog", !Lifted.useBlindDialog(1, lck), lck);
        check("E4 unlock-lost-key beside a blind app -> the end-capable dialog", !Lifted.useBlindDialog(1,
                "REFUSED FINAL 1\nSCOPE de refused:blind 0\nSCOPE vault refused:unlock-lost-key 5\nSAVED 5\n"), "");
        String e5 = lfm("REFUSED", "REFUSED FINAL 1\nSCOPE vault refused:locks-changed 1700000000\n"
                + "SCOPE de refused:locks-changed-key 0\nSAVED 0\n");
        check("E5 two scopes, one sign-in-changed sentence", e5.indexOf("sign-in was changed") >= 0
                && e5.indexOf("sign-in was changed") == e5.lastIndexOf("sign-in was changed"), e5);

        // ---- useBlindDialog / blindRestSaved ----
        String blindOnly = "REFUSED FINAL 1\nSCOPE de refused:blind 0\nSAVED 5\n";
        String blindAndShrink = "REFUSED FINAL 1\nSCOPE vault refused:blind 0\nSCOPE de refused:shrink 0\nSAVED 5\n";
        String blindAndNet = "REFUSED FINAL 1\nSCOPE de refused:blind 0\nSCOPE media failed 0\nSAVED 5\n";
        String blindAndApps = "REFUSED FINAL 1\nSCOPE de refused:blind 0\nSCOPE apps refused:apps-vanished 0\nSAVED 5\n";
        check("blind: only blind -> the blind dialog", Lifted.useBlindDialog(1, blindOnly), "");
        check("blind: blind + shrink -> the end-capable dialog", !Lifted.useBlindDialog(1, blindAndShrink), "");
        check("blind: blind + a network failure -> still the blind dialog", Lifted.useBlindDialog(2, blindAndNet), "");
        check("blind: blind + #apps (never blocks) -> still the blind dialog", Lifted.useBlindDialog(1, blindAndApps), "");
        check("blind: no packages -> never", !Lifted.useBlindDialog(0, blindOnly), "");
        check("blind: older daemon -> as before", Lifted.useBlindDialog(1, null), "");
        check("blind: rest saved only when blind is all", Lifted.blindRestSaved(blindOnly), "");
        check("blind: a network failure beside it -> rest NOT saved", !Lifted.blindRestSaved(blindAndNet), "");
        check("blind: #apps beside it -> rest NOT saved", !Lifted.blindRestSaved(blindAndApps), "");
        check("blind: older daemon keeps its claim", Lifted.blindRestSaved(null), "");
        check("blind/end: blind + shrink offers the end", Lifted.offerEndUnsaved("REFUSED", blindAndShrink), "");

        // ---- endUnsavedConfirmText ----
        String conf = Lifted.endUnsavedConfirmText(FINAL_DE, at);
        String wantConf = "This can't be undone. Ending the session now throws away everything this phone hasn't saved:\n"
                + "\n• Your settings — not saved since T1728550000"
                + "\n• Anything else you changed after T1728551000"
                + "\n• Sign-ins your apps made during this session — those apps may ask you to sign in again"
                + "\n\nKept: your stored copy, exactly as it was last saved. Your storage credit is saved before the session ends.";
        check("confirm: exact (NW-db441ee766cb)", wantConf.equals(conf), conf);
        String cv = Lifted.endUnsavedConfirmText("REFUSED FINAL 1\nSCOPE vault refused:shrink 7\nSAVED 8\n", at);
        check("confirm: the CE scope is named", cv.contains("• Your app data, texts and call history — not saved since T7"), cv);
        String unk = Lifted.endUnsavedConfirmText("REFUSED FINAL 1\nSCOPE de refused:shrink 0\nSAVED 0\n", at);
        check("confirm: unknown times state no time",
                unk.contains("• Your settings — any changes since it was last saved")
                        && unk.contains("• Anything else you changed since it was last saved") && !unk.contains("T0"), unk);
        String old = Lifted.endUnsavedConfirmText("REFUSED FINAL 1\nSCOPE de refused:shrink 5\n", at); // no SAVED line
        check("confirm: no SAVED line reads as unknown", old.contains("Anything else you changed since it was last saved"), old);
        String tok = Lifted.endUnsavedConfirmText("REFUSED FINAL 1\nSCOPE vault refused:deleted 0\nSAVED 0\n", at);
        check("confirm: a deleted TOKEN keeps the ordinary ending", tok.contains("Kept: your stored copy") && tok.contains("credit")
                && !tok.contains("deleted"), tok);
        String gone = Lifted.endUnsavedConfirmText("REFUSED FINAL 1\nSCOPE vault refused:deleted 0\nSAVED 0\nDELETED\n", at);
        check("confirm: store-confirmed delete keeps nothing and promises no credit",
                gone.endsWith("nothing from this session can be kept.") && !gone.contains("credit") && !gone.contains("Kept:"), gone);
        String many = Lifted.endUnsavedConfirmText(
                "REFUSED FINAL 1\nSCOPE de refused:shrink 10\nSCOPE apps refused:apps-vanished 20\nSAVED 30\n", at);
        check("confirm: every named scope is listed", many.contains("• Your settings — not saved since T10")
                && many.contains("• Your apps — not saved since T20") && many.contains("after T30"), many);

        // ---- endUnsavedReplyMessage / endUnsavedMayRetry ----
        check("reply: OK ends", Lifted.endUnsavedReplyMessage("OK") == null, Lifted.endUnsavedReplyMessage("OK"));
        check("reply: OK trimmed", Lifted.endUnsavedReplyMessage(" OK ") == null, "");
        // NWP-20261117-32: only BUSY seal is a save; every other BUSY says its own cause, or plain "busy".
        check("reply: BUSY seal", Lifted.endUnsavedReplyMessage("BUSY seal").startsWith("A save is running right now"),
                Lifted.endUnsavedReplyMessage("BUSY seal"));
        busyCases("reply", "wasn't ended", END_BUSY, false);
        check("reply: wallet", Lifted.endUnsavedReplyMessage("ERR-WALLET").startsWith("Your storage credit couldn't be saved first"), "");
        check("reply: media", Lifted.endUnsavedReplyMessage("ERR-MEDIA").startsWith("This phone couldn't close your photos and media"), "");
        check("reply: slow", Lifted.endUnsavedReplyMessage("ERR-SLOW").startsWith("Ending the session took too long"), "");
        check("reply: not refused", Lifted.endUnsavedReplyMessage("ERR-NOTREFUSED").contains("no longer current"), "");
        for (String r : new String[]{"", null, "NONE", "ERR-LOCAL", "ERR-KEYS", "ERR-STATE", "BLANK", "DENIED"}) {
            check("reply: generic for " + r, "Couldn't end the session. You're still signed in.".equals(Lifted.endUnsavedReplyMessage(r)),
                    Lifted.endUnsavedReplyMessage(r));
        }
        for (String r : new String[]{"BUSY", "BUSY seal", "BUSY teardown", "BUSY rent", "BUSY slot", "BUSY other",
                " BUSY rent ", "ERR-WALLET", "ERR-MEDIA", "ERR-SLOW"}) {
            check("retry: " + r, Lifted.endUnsavedMayRetry(r), "");
        }
        for (String r : new String[]{"OK", "ERR-NOTREFUSED", "", null, "ERR-LOCAL", "ERR-KEYS", "ERR-STATE", "BUSYX",
                "ERR-BUSY"}) {
            check("retry: not for " + r, !Lifted.endUnsavedMayRetry(r), "");
        }

        // ---- NWP-20261013-20: an end that went ahead without saving the credit (decided 2026-10-15) ----
        check("credit lost: END ends", Lifted.endUnsavedReplyMessage("OK-CREDIT-LOST") == null, "");
        check("credit lost: RESTART restarts", Lifted.restartUnsavedReplyMessage("OK-CREDIT-LOST") == null, "");
        check("credit lost: not a retry", !Lifted.endUnsavedMayRetry("OK-CREDIT-LOST"), "");
        String lost = Lifted.creditLostWarning(" OK-CREDIT-LOST ");
        check("credit lost: warns that this session's credit is lost and the earlier credit is safe",
                lost != null && lost.contains("added during this session") && lost.contains("is lost")
                        && lost.contains("before this session is safe"), lost);
        for (String r : new String[]{"OK", "", null, "ERR-WALLET", "BUSY", "OK-CREDIT", "OK 3 UNSAVED"}) {
            check("credit lost: no warning for " + r, Lifted.creditLostWarning(r) == null, Lifted.creditLostWarning(r));
        }

        // ---- round 3: the media-sweep run and RESTART-UNSAVED ----
        String media1 = "SAVED 5\nMEDIA 1\n";
        String media2 = "SAVED 5\nMEDIA 2\n";
        String finalMedia2 = "REFUSED FINAL 1\nSCOPE de refused:shrink 4\nSAVED 5\nMEDIA 2\n";
        check("media: count parsed", Lifted.mediaStuckCount(finalMedia2) == 2, Lifted.mediaStuckCount(finalMedia2));
        check("media: absent is 0", Lifted.mediaStuckCount(FINAL_DE) == 0 && Lifted.mediaStuckCount(null) == 0, "");
        check("exit: MEDIA once -> nothing", "".equals(Lifted.failedDialogExit("MEDIA", media1)), Lifted.failedDialogExit("MEDIA", media1));
        check("exit: MEDIA twice -> RESTART", "RESTART".equals(Lifted.failedDialogExit("MEDIA", media2)), "");
        check("exit: MEDIA twice beats an END licence", "RESTART".equals(Lifted.failedDialogExit("MEDIA", finalMedia2)), "");
        check("exit: REFUSED twice-stuck -> RESTART", "RESTART".equals(Lifted.failedDialogExit("REFUSED", finalMedia2)), "");
        check("exit: FINAL refusal -> END", "END".equals(Lifted.failedDialogExit("REFUSED", FINAL_DE)), "");
        check("exit: MEDIA with an earlier licence -> END", "END".equals(Lifted.failedDialogExit("MEDIA", FINAL_DE + "MEDIA 1\n")), "");
        check("exit: retry refusal -> nothing", "".equals(Lifted.failedDialogExit("REFUSED", RETRY_STALE)), "");
        check("exit: network failure never offers END or RESTART, even stuck on media (Q070: Lock)", "LOCK".equals(Lifted.failedDialogExit("", media2)), Lifted.failedDialogExit("", media2));
        check("exit: NOCREDIT never", "".equals(Lifted.failedDialogExit("NOCREDIT", finalMedia2)), "");
        check("exit: older daemon -> nothing", "".equals(Lifted.failedDialogExit("REFUSED", null)), "");
        String rc = Lifted.restartUnsavedConfirmText(media2, at);
        String wantRc = "This can't be undone. Your phone restarts, and everything it hasn't saved is thrown away:\n"
                + "\n• Anything you changed after T5"
                + "\n• Sign-ins your apps made during this session — those apps may ask you to sign in again"
                + "\n• Texts and calls this phone is still holding for delivery"
                + "\n\nKept: your stored copy, exactly as it was last saved. Your storage credit is saved before the phone restarts.";
        check("restart confirm: exact (media only)", wantRc.equals(rc), rc);
        String rcf = Lifted.restartUnsavedConfirmText(finalMedia2, at);
        check("restart confirm: lists the refused scope too", rcf.contains("• Your settings — not saved since T4"), rcf);
        check("restart confirm: the telephony line, in every reply shape (static, never a count)",
                rcf.contains("\n• Texts and calls this phone is still holding for delivery\n")
                        && Lifted.restartUnsavedConfirmText(null, at).contains("\n• Texts and calls this phone is still holding for delivery\n"),
                rcf);
        check("end confirm never says the texts are lost (the reap keeps them)",
                !Lifted.endUnsavedConfirmText(finalMedia2, at).contains("Texts and calls"), "");
        check("end confirm unchanged by the refactor", wantConf.equals(Lifted.endUnsavedConfirmText(FINAL_DE, at)), "");
        check("restart reply: OK", Lifted.restartUnsavedReplyMessage("OK") == null, "");
        check("restart reply: not stuck", Lifted.restartUnsavedReplyMessage("ERR-NOTSTUCK").startsWith("The phone wasn't restarted"), "");
        check("restart reply: wallet", Lifted.restartUnsavedReplyMessage("ERR-WALLET").startsWith("Your storage credit couldn't be saved first"), "");
        check("restart reply: BUSY seal", Lifted.restartUnsavedReplyMessage("BUSY seal").startsWith("A save is running right now"),
                Lifted.restartUnsavedReplyMessage("BUSY seal"));
        busyCases("restart reply", "wasn't restarted", RESTART_BUSY, true);
        check("restart reply: slow", Lifted.restartUnsavedReplyMessage("ERR-SLOW").startsWith("Saving your storage credit took too long"), "");
        for (String r : new String[]{"", null, "NONE", "ERR-LOCAL", "ERR-KEYS", "ERR-STATE"}) {
            check("restart reply: generic for " + r,
                    "Couldn't restart without saving. You're still signed in.".equals(Lifted.restartUnsavedReplyMessage(r)), "");
        }

        // ---- round 5 ----
        // The replies are whitespace-split: a double space or a tab must parse (split("\\s+"), not split(" ")).
        check("split: MEDIA with a double space", Lifted.mediaStuckCount("SAVED 5\nMEDIA  2\n") == 2,
                Lifted.mediaStuckCount("SAVED 5\nMEDIA  2\n"));
        check("split: MEDIA with a tab", Lifted.mediaStuckCount("SAVED 5\nMEDIA\t2\n") == 2,
                Lifted.mediaStuckCount("SAVED 5\nMEDIA\t2\n"));
        check("split: REFUSED  FINAL with a double space", Lifted.refusalFinal("REFUSED  FINAL 1\nSAVED 0\n"), "");
        check("split: SAVED with a tab", Lifted.refusalRestSaved("SAVED\t7\n") == 7, Lifted.refusalRestSaved("SAVED\t7\n"));
        check("split: SCOPE with a tab", Lifted.refusalScopes("SCOPE\tde refused:shrink 4\n").size() == 1, "");
        // restartWatchAction: the "Restarting…" screen never waits silently.
        check("watch: pending, early -> wait", "WAIT".equals(Lifted.restartWatchAction("PENDING", 2000, false)), "");
        check("watch: pending at 15 s -> reboot ourselves", "REBOOT".equals(Lifted.restartWatchAction("PENDING", 15000, false)), "");
        check("watch: only once", "WAIT".equals(Lifted.restartWatchAction("PENDING", 30000, true)), "");
        check("watch: the daemon gave up -> say so", "FAILED".equals(Lifted.restartWatchAction("FAILED", 4000, false)), "");
        check("watch: FAILED with whitespace", "FAILED".equals(Lifted.restartWatchAction(" FAILED\n", 4000, true)), "");
        // Round 6: our own timeout is never the daemon's FAILED -- it may still be PENDING (local, unsaved).
        check("watch: still PENDING at 90 s -> UNKNOWN, not FAILED", "UNKNOWN".equals(Lifted.restartWatchAction("PENDING", 90000, true)), "");
        check("watch: daemon unreachable at 90 s -> UNKNOWN", "UNKNOWN".equals(Lifted.restartWatchAction("", 90000, true)), "");
        check("watch: NONE at 90 s -> UNKNOWN", "UNKNOWN".equals(Lifted.restartWatchAction("NONE", 120000, false)), "");
        check("watch: FAILED after 90 s is still FAILED", "FAILED".equals(Lifted.restartWatchAction("FAILED", 120000, true)), "");
        String ru = Lifted.restartUnknownMessage();
        check("restart unknown: exact", ("Your phone hasn't restarted, and Nowhere couldn't confirm what happened. "
                + "Restarting the phone yourself discards everything this phone hasn't saved.").equals(ru), ru);
        check("restart unknown: never claims the session is saved",
                !ru.contains("being saved") && !ru.contains("nothing was discarded") && !ru.contains("signed in"), ru);
        check("watch: daemon unreachable early -> wait", "WAIT".equals(Lifted.restartWatchAction(null, 4000, true)), "");
        String rf = Lifted.restartFailedMessage();
        check("restart failed: exact", ("Your phone didn't restart. You're still signed in, and this session is being saved "
                + "again as usual — nothing was discarded. To discard it, restart the phone yourself.").equals(rf), rf);

        // ---- round 9: Add-credits while a restart without saving is pending ----
        String cr = Lifted.claimFailMessage("ERR-RESTARTING\n");
        check("claim restarting: exact", ("The phone is restarting without saving, so the code wasn't redeemed. Nothing "
                + "was charged and your code is still good — redeem it after the phone restarts and you sign in.").equals(cr), cr);
        check("claim restarting: never 'try again in a minute' -- the session is about to end",
                !cr.contains("try again") && !cr.contains("in a minute"), cr);
        String cb = Lifted.claimFailMessage("ERR-BUSY\n");
        check("claim busy: unchanged",
                "The phone is busy saving. Nothing was charged and your code is still good — try again in a minute.".equals(cb), cb);
        check("claim restarting is not the busy copy", !cr.equals(cb), cr);
        check("claim no answer: outcome unknown", Lifted.claimFailMessage("").startsWith("The phone didn't answer"), "");
        check("claim null: same as no answer", Lifted.claimFailMessage(null).startsWith("The phone didn't answer"), "");
        check("claim used code", Lifted.claimFailMessage("ERR-NOCODE\n").startsWith("That code isn't valid"), "");
        check("claim no session", "No active session to redeem a code into.".equals(Lifted.claimFailMessage("NONE\n")), "");
        check("claim other", "Couldn't redeem that code — check your connection and try again.".equals(Lifted.claimFailMessage("ERR\n")), "");

        // ---- NWP-20261013-20: the gate's lost-credit notice (decided 2026-10-15, "Retry, then warn") ----
        check("gate notice: the recorded time", GateLifted.creditLostNoticeStamp("NOTICE 1728551000\n") == 1728551000L,
                GateLifted.creditLostNoticeStamp("NOTICE 1728551000\n"));
        for (String r : new String[]{"NONE", "NONE\n", "", null, "ERR", "NOTICE", "NOTICE x", "NOTICE 0", "NOTICE -5",
                "OK", "NOTICES 5", "BLANK"}) {
            check("gate notice: none for " + r, GateLifted.creditLostNoticeStamp(r) == 0, GateLifted.creditLostNoticeStamp(r));
        }
        check("gate notice: shown when recorded and not on screen", GateLifted.creditLostNoticeDue(7L, false, false), "");
        check("gate notice: ONCE -- not raised again while it is on screen", !GateLifted.creditLostNoticeDue(7L, true, false), "");
        check("gate notice: not on a gate that is going away", !GateLifted.creditLostNoticeDue(7L, false, true), "");
        check("gate notice: nothing recorded, nothing shown", !GateLifted.creditLostNoticeDue(0L, false, false), "");
        check("gate notice: the clear names the notice it acknowledges",
                "CLEAR-CREDIT-LOST\n1728551000\n".equals(GateLifted.creditLostClearCommand(1728551000L)),
                GateLifted.creditLostClearCommand(1728551000L));
        String gn = GateLifted.creditLostNoticeText();
        check("gate notice: says the session's credit is lost and the earlier credit is safe",
                gn.contains("added during the last session") && gn.contains("is lost")
                        && gn.contains("saved before that session is safe"), gn);

        // ---- NWP-20261101-08 (Q070): no network -- Lock first, the confirmed end after the second failure ----
        check("push: PUSH 2 parsed", Lifted.pushStuckCount("SAVED 5\nPUSH 2\n") == 2, Lifted.pushStuckCount("SAVED 5\nPUSH 2\n"));
        check("push: PUSH 0 is 0", Lifted.pushStuckCount("SAVED 5\nPUSH 0\n") == 0, "");
        check("push: absent is 0", Lifted.pushStuckCount(FINAL_DE) == 0, "");
        check("push: garbage is 0", Lifted.pushStuckCount("PUSH x\nPUSH 1 2\nPUSHY 3\n") == 0, "");
        check("push: null is 0", Lifted.pushStuckCount(null) == 0, "");
        check("push: a MEDIA line is not a PUSH line", Lifted.pushStuckCount("MEDIA 2\n") == 0, "");
        check("exit: no network, once -> LOCK", "LOCK".equals(Lifted.failedDialogExit("", "SAVED 5\nPUSH 1\n")), Lifted.failedDialogExit("", "SAVED 5\nPUSH 1\n"));
        check("exit: no network, twice -> LOCK-END", "LOCK-END".equals(Lifted.failedDialogExit("", "SAVED 5\nPUSH 2\n")), Lifted.failedDialogExit("", "SAVED 5\nPUSH 2\n"));
        check("exit: no network, no reply -> LOCK", "LOCK".equals(Lifted.failedDialogExit("", null)), Lifted.failedDialogExit("", null));
        check("exit: NOCREDIT never offers the end", "".equals(Lifted.failedDialogExit("NOCREDIT", "SAVED 5\nPUSH 2\n")), "");
        check("exit: REFUSED stays END with a PUSH line", "END".equals(Lifted.failedDialogExit("REFUSED", FINAL_DE + "PUSH 2\n")), "");
        check("exit: MEDIA stays RESTART with a PUSH line", "RESTART".equals(Lifted.failedDialogExit("MEDIA", media2 + "PUSH 2\n")), "");
        String off0 = Lifted.endUnsavedOfflineText(0, at), off1 = Lifted.endUnsavedOfflineText(1728551000L, at);
        check("offline confirm: no save on record", off0.equals("Ending without saving discards everything this session changed since you signed in. "
                + "Storage credit added in this session that wasn't saved to your store is lost."), off0);
        check("offline confirm: names the last save and the credit at risk", off1.equals("Ending without saving discards everything this session changed since T1728551000. "
                + "Storage credit added in this session that wasn't saved to your store is lost."), off1);

        // ---- NWP-20261111-07 (Q016): the key exit ----
        String keyLc = "REFUSED FINAL 1\nSCOPE vault refused:locks-changed-key 5\nSAVED 5\n";
        String keyUl = "REFUSED FINAL 1\nSCOPE vault refused:unlock-lost-key 5\nSAVED 5\n";
        String noKeyLc = "REFUSED FINAL 1\nSCOPE vault refused:locks-changed 5\nSAVED 5\n";
        String noKeyUl = "REFUSED FINAL 1\nSCOPE vault refused:unlock-lost 5\nSAVED 5\n";
        check("K1 key: locks-changed-key -> KEY-END", "KEY-END".equals(Lifted.failedDialogExit("REFUSED", keyLc)), Lifted.failedDialogExit("REFUSED", keyLc));
        check("K1 key: unlock-lost-key -> KEY-END", "KEY-END".equals(Lifted.failedDialogExit("REFUSED", keyUl)), Lifted.failedDialogExit("REFUSED", keyUl));
        check("K1 key: a FAILED MEDIA keeps the key exit", "KEY-END".equals(Lifted.failedDialogExit("MEDIA", keyLc + "MEDIA 1\n")), Lifted.failedDialogExit("MEDIA", keyLc + "MEDIA 1\n"));
        check("K1 key: locks-changed (no key) -> END", "END".equals(Lifted.failedDialogExit("REFUSED", noKeyLc)), Lifted.failedDialogExit("REFUSED", noKeyLc));
        check("K1 key: unlock-lost (no key) -> END", "END".equals(Lifted.failedDialogExit("REFUSED", noKeyUl)), Lifted.failedDialogExit("REFUSED", noKeyUl));
        check("K1 key: MEDIA 2 still RESTART", "RESTART".equals(Lifted.failedDialogExit("MEDIA", keyLc + "MEDIA 2\n")), Lifted.failedDialogExit("MEDIA", keyLc + "MEDIA 2\n"));
        check("K1 key: a RETRY refusal offers neither", "".equals(Lifted.failedDialogExit("REFUSED", keyLc.replace("FINAL", "RETRY"))), Lifted.failedDialogExit("REFUSED", keyLc.replace("FINAL", "RETRY")));
        check("K1 key: NOCREDIT never", "".equals(Lifted.failedDialogExit("NOCREDIT", keyLc)), Lifted.failedDialogExit("NOCREDIT", keyLc));
        // K2: only a blocking scope's refusal; each paired with a vault case so the check fails where KEY-END is absent.
        String appsKey = "REFUSED FINAL 1\nSCOPE apps refused:locks-changed-key 5\nSAVED 5\n";
        String sysKey = "REFUSED FINAL 1\nSCOPE sys refused:unlock-lost-key 5\nSAVED 5\n";
        check("K2 key: a -key guard on #apps or #sys is not the key exit, on #vault it is",
                "END".equals(Lifted.failedDialogExit("REFUSED", appsKey)) && "END".equals(Lifted.failedDialogExit("REFUSED", sysKey))
                && "KEY-END".equals(Lifted.failedDialogExit("REFUSED", keyLc)),
                Lifted.failedDialogExit("REFUSED", appsKey) + "/" + Lifted.failedDialogExit("REFUSED", sysKey));
        String savedKey = "REFUSED FINAL 1\nSCOPE de refused:shrink 5\nSCOPE vault saved:locks-changed-key 5\nSAVED 5\n";
        check("K2 key: a -key line that is not 'refused' is not the key exit",
                "END".equals(Lifted.failedDialogExit("REFUSED", savedKey)) && "KEY-END".equals(Lifted.failedDialogExit("REFUSED", keyUl)),
                Lifted.failedDialogExit("REFUSED", savedKey));
        String deKey = "REFUSED FINAL 1\nSCOPE de refused:locks-changed-key 5\nSAVED 5\n";
        String mediaKey = "REFUSED FINAL 1\nSCOPE media refused:unlock-lost-key 5\nSAVED 5\n";
        check("K2 key: #de and #media carry it too",
                "KEY-END".equals(Lifted.failedDialogExit("REFUSED", deKey)) && "KEY-END".equals(Lifted.failedDialogExit("REFUSED", mediaKey)),
                Lifted.failedDialogExit("REFUSED", deKey) + "/" + Lifted.failedDialogExit("REFUSED", mediaKey));
        // K3: the adopt failure's sentence.
        String adoptNoKey = "That key didn't unlock this profile. Try the key you added, or end the session without saving.";
        String adoptGeneric = "Couldn't use a security key here. You can end the session without saving.";
        check("K3 adopt: ERR-NOKEY", adoptNoKey.equals(Lifted.adoptFailMessage("ERR-NOKEY")), Lifted.adoptFailMessage("ERR-NOKEY"));
        check("K3 adopt: ERR-NOKEY with a newline", adoptNoKey.equals(Lifted.adoptFailMessage("ERR-NOKEY\n")), Lifted.adoptFailMessage("ERR-NOKEY\n"));
        for (String r : new String[]{"ERR-NOSESSION", "ERR-NOTSTORED", "ERR-DENIED", "ERR", "", null})
            check("K3 adopt: generic for " + r, adoptGeneric.equals(Lifted.adoptFailMessage(r)), Lifted.adoptFailMessage(r));
        for (String r : new String[]{"ERR-NOKEY", "ERR-NOSESSION", "ERR-NOTSTORED", "ERR-DENIED", "ERR", "", null}) {
            String m = Lifted.adoptFailMessage(r).toLowerCase();
            check("K3 adopt: no other handset named for " + r, !m.contains("another") && !m.contains("other phone"), m);
        }

        // ---- NWP-20261113-18: a stalled save (SEAL-STATUS "FAILED TIMEOUT": ERR-TIMEOUT or ERR-STALLED) ----
        String to = Lifted.logoffFailMessage("TIMEOUT", null, null, at);
        check("T1 timeout: names a stalled save", to.contains("stopped making progress"), to);
        check("T1 timeout: does not name the store", !to.contains("reach your storage"), to);
        check("T1 timeout: does not send the user online", !to.contains("online"), to);
        check("T1 timeout: says the stored copy is intact", to.contains("Your stored copy is intact"), to);
        check("T1 timeout: keeps the generic arm's Lock sentence", to.contains(LOCK_SENTENCE), to);
        check("T1 timeout: offers to sign out again", to.endsWith("Or sign out again in a moment."), to);
        check("T2 timeout: the exit is LOCK", "LOCK".equals(Lifted.failedDialogExit("TIMEOUT", null)),
                Lifted.failedDialogExit("TIMEOUT", null));
        check("T2 timeout: a PUSH run does not escalate it", "LOCK".equals(Lifted.failedDialogExit("TIMEOUT", "PUSH 3\n")),
                Lifted.failedDialogExit("TIMEOUT", "PUSH 3\n"));
        check("T3 timeout: the generic text is unchanged", NEW_OTHER.equals(lfm("", null)), lfm("", null));
        check("T3 timeout: the generic text carries the Lock sentence", lfm("", null).contains(LOCK_SENTENCE), lfm("", null));
        check("T3 timeout: the REFUSED text is unchanged", OLD_REFUSED.equals(lfm("REFUSED", null)), lfm("REFUSED", null));

        // ---- NWP-20261113-11 (case 2): the words for a refused last save, from SEAL-DELTA's scope lines ----
        String held = Lifted.lastSaveHeldText("refused", "SCOPE vault refused:shrink 0", at);
        check("H1 held: a shrink-refused vault has words", held != null, held);
        check("H1 held: names the shrink guard", held != null && held.contains("is missing data that your stored copy has"), held);
        check("H1 held: names the app-data scope", held != null && held.contains("your app data, texts and call history"), held);
        check("H1 held: not the race sentence", held != null && !held.contains("changed while the save was running"), held);
        check("H1 held: names no other device", held != null && !held.contains("another") && !held.contains("other phone"), held);
        check("H1 held: never says nothing is lost", held != null && !held.toLowerCase().contains("nothing has been lost"), held);
        String stale = Lifted.lastSaveHeldText("refused", "SCOPE vault refused:stale-base 0", at);
        check("H2 held: stale-base gives its own sentence", stale != null && stale.contains("changed after this phone loaded it"), stale);
        String heldMixed = Lifted.lastSaveHeldText("refused", "SCOPE de refused:no-receipt 0\nSCOPE apps refused 0", at);
        check("H3 held: a data scope beside #apps", heldMixed != null && heldMixed.contains("can't be matched"), heldMixed);
        check("H4 held: #apps alone blocks nothing", Lifted.lastSaveHeldText("refused", "SCOPE apps refused 0", at) == null,
                Lifted.lastSaveHeldText("refused", "SCOPE apps refused 0", at));
        check("H4 held: #sys alone blocks nothing", Lifted.lastSaveHeldText("refused", "SCOPE sys refused:shrink 0", at) == null,
                Lifted.lastSaveHeldText("refused", "SCOPE sys refused:shrink 0", at));
        check("H5 held: an older daemon (null scopes)", Lifted.lastSaveHeldText("refused", null, at) == null,
                Lifted.lastSaveHeldText("refused", null, at));
        check("H5 held: an older daemon (empty scopes)", Lifted.lastSaveHeldText("refused", "", at) == null,
                Lifted.lastSaveHeldText("refused", "", at));
        check("H6 held: a failed save is not a refusal", Lifted.lastSaveHeldText("fail", "SCOPE vault refused:shrink 0", at) == null,
                Lifted.lastSaveHeldText("fail", "SCOPE vault refused:shrink 0", at));
        check("H6 held: a saved scope is not a refusal", Lifted.lastSaveHeldText("refused", "SCOPE vault ok 0", at) == null,
                Lifted.lastSaveHeldText("refused", "SCOPE vault ok 0", at));

        System.out.println(runs + " checks, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}
