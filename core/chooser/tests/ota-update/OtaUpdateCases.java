package com.nowhere.chooser;

import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

// NWP-20261011-05: the cases for OtaUpdate -- the OTA-STATUS parse (fail safe: nothing malformed is mandatory), the
// deadline date, the alert cadence, the banner's visibility, and every piece of copy (run.sh).
public final class OtaUpdateCases {
    static int fails = 0, runs = 0;

    static void check(String name, boolean ok, Object got) {
        runs++;
        if (!ok) {
            fails++;
            System.out.println("FAIL " + name + "\n     got: " + got);
        }
    }

    static List<String> L(String... s) { return Arrays.asList(s); }

    static final TimeZone UTC = TimeZone.getTimeZone("UTC");
    static final TimeZone NY = TimeZone.getTimeZone("America/New_York");
    static final TimeZone KIRITIMATI = TimeZone.getTimeZone("Pacific/Kiritimati"); // UTC+14
    static final Locale EN = Locale.US;
    // 2026-10-20T00:00:00Z: the deadline of a critical release published 2026-10-12 (core/agent TestOtaMandatoryLines).
    static final long DL = 1792454400L;
    static final String REASON = "Saves now go through a new check on our servers.";
    static final String CONSEQ = "Once the servers require it, this phone cannot save changes or sign out.";
    static final List<String> CRIT_DUE = L("AVAIL 0.5.45", "MANDATORY critical " + DL + " due", "REASON " + REASON,
            "CONSEQUENCE " + CONSEQ);
    static final List<String> MAND_OVERDUE = L("AVAIL 0.5.46", "MANDATORY mandatory " + DL + " overdue",
            "REASON " + REASON, "CONSEQUENCE " + CONSEQ);

    public static void main(String[] a) {
        // ---- parse: the fail-safe direction -- anything short of a complete, well-formed block is ORDINARY ----
        OtaUpdate.Status s = OtaUpdate.parse(CRIT_DUE);
        check("parse: a complete critical block", s.avail && s.mandatory() && s.critical() && !s.overdue
                && s.deadlineSec == DL && "0.5.45".equals(s.version) && REASON.equals(s.reason)
                && CONSEQ.equals(s.consequence), s.severity + " " + s.deadlineSec);
        s = OtaUpdate.parse(MAND_OVERDUE);
        check("parse: mandatory, overdue", s.mandatory() && !s.critical() && s.overdue, s.severity);
        s = OtaUpdate.parse(L("AVAIL 0.5.45"));
        check("parse: plain AVAIL is ordinary", s.avail && !s.mandatory() && "0.5.45".equals(s.version), s.version);
        s = OtaUpdate.parse(L("AVAIL"));
        check("parse: bare AVAIL", s.avail && "".equals(s.version), s.version);
        for (String head : new String[]{"NONE", "UNKNOWN checking", "DOWNLOADING 0.5.45", "FAILED x", "NOSTORE", ""}) {
            s = OtaUpdate.parse(L(head, "MANDATORY critical " + DL + " due", "REASON r", "CONSEQUENCE c"));
            check("parse: " + head + " is not an available update, mandatory lines or not", !s.avail && !s.mandatory(), head);
        }
        check("parse: null", !OtaUpdate.parse(null).avail, "");
        check("parse: empty", !OtaUpdate.parse(L()).avail, "");
        String[][] broken = {
                {"no reason", "AVAIL 0.5.45", "MANDATORY critical " + DL + " due", "CONSEQUENCE c"},
                {"no consequence", "AVAIL 0.5.45", "MANDATORY critical " + DL + " due", "REASON r"},
                {"empty reason", "AVAIL 0.5.45", "MANDATORY critical " + DL + " due", "REASON ", "CONSEQUENCE c"},
                {"no MANDATORY line", "AVAIL 0.5.45", "REASON r", "CONSEQUENCE c"},
                {"unknown severity", "AVAIL 0.5.45", "MANDATORY urgent " + DL + " due", "REASON r", "CONSEQUENCE c"},
                {"severity none", "AVAIL 0.5.45", "MANDATORY none " + DL + " due", "REASON r", "CONSEQUENCE c"},
                {"deadline not a number", "AVAIL 0.5.45", "MANDATORY critical soon due", "REASON r", "CONSEQUENCE c"},
                {"deadline zero", "AVAIL 0.5.45", "MANDATORY critical 0 due", "REASON r", "CONSEQUENCE c"},
                {"deadline negative", "AVAIL 0.5.45", "MANDATORY critical -5 due", "REASON r", "CONSEQUENCE c"},
                {"unknown state", "AVAIL 0.5.45", "MANDATORY critical " + DL + " late", "REASON r", "CONSEQUENCE c"},
                {"missing state", "AVAIL 0.5.45", "MANDATORY critical " + DL, "REASON r", "CONSEQUENCE c"},
                {"extra field", "AVAIL 0.5.45", "MANDATORY critical " + DL + " due x", "REASON r", "CONSEQUENCE c"},
        };
        for (String[] b : broken) {
            s = OtaUpdate.parse(Arrays.asList(b).subList(1, b.length));
            check("parse fail-safe: " + b[0] + " -> ordinary", s.avail && !s.mandatory() && s.reason.isEmpty(), s.severity);
        }
        s = OtaUpdate.parse(L("AVAIL 0.5.45", "PROG osdownload 1 2", "MANDATORY critical " + DL + " due", "REASON r", "CONSEQUENCE c"));
        check("parse: order of the extra lines does not matter", s.critical(), s.severity);

        // ---- dueDate: the local date of the last instant before the deadline ----
        check("due: UTC", "October 19".equals(OtaUpdate.dueDate(DL, UTC, EN)), OtaUpdate.dueDate(DL, UTC, EN));
        check("due: New York (deadline is 20:00 on the 19th)", "October 19".equals(OtaUpdate.dueDate(DL, NY, EN)),
                OtaUpdate.dueDate(DL, NY, EN));
        check("due: UTC+14 (deadline is 14:00 on the 20th)", "October 20".equals(OtaUpdate.dueDate(DL, KIRITIMATI, EN)),
                OtaUpdate.dueDate(DL, KIRITIMATI, EN));

        // ---- the in-session notice ----
        OtaUpdate.Status ord = OtaUpdate.parse(L("AVAIL 0.5.45"));
        OtaUpdate.Status crit = OtaUpdate.parse(CRIT_DUE);
        OtaUpdate.Status late = OtaUpdate.parse(MAND_OVERDUE);
        check("title: ordinary", "Software update available".equals(OtaUpdate.noticeTitle(ord, UTC, EN)), OtaUpdate.noticeTitle(ord, UTC, EN));
        check("title: critical", "Critical update: install by October 19".equals(OtaUpdate.noticeTitle(crit, UTC, EN)),
                OtaUpdate.noticeTitle(crit, UTC, EN));
        check("title: mandatory overdue", "Required update is overdue".equals(OtaUpdate.noticeTitle(late, UTC, EN)),
                OtaUpdate.noticeTitle(late, UTC, EN));
        check("text: ordinary", "Version 0.5.45 is ready.".equals(OtaUpdate.noticeText(ord)), OtaUpdate.noticeText(ord));
        check("text: mandatory is the SIGNED reason, verbatim", REASON.equals(OtaUpdate.noticeText(crit)), OtaUpdate.noticeText(crit));
        String autoOn = OtaUpdate.noticeBig(ord, true, UTC, EN);
        check("big: auto-on no longer promises an in-session install",
                !autoOn.contains("It will install on its own while the phone is charging"), autoOn);
        check("big: auto-on, exact -- signed out installs, a locked session waits (Q063)", ("Version 0.5.45 is"
                + " ready. Automatic install is on: it installs while the phone is charging and you're signed out."
                + " While this session is locked (with Lock, or on its own after the phone sits idle) it waits until you"
                + " sign out. If you set an install time"
                + " it waits for that time; otherwise it starts when the screen turns off. To install it now, tap Sign out"
                + " & install in Profile. It takes a while, and the phone restarts when it's done.").equals(autoOn), autoOn);
        check("big: auto-on never says only after sign-out", !autoOn.contains("after you sign out"), autoOn);
        check("big: auto-on never says the restart ends the locked session",
                !autoOn.contains("ends the locked session") && !autoOn.contains(", While"), autoOn);
        String autoOff = OtaUpdate.noticeBig(ord, false, UTC, EN);
        check("big: auto-off, exact", ("Version 0.5.45 is ready. Tap Sign out & install in Profile, or sign out and"
                + " install it from the sign-in screen. It takes a while, and the phone restarts when it's done.").equals(autoOff), autoOff);
        String bigCrit = OtaUpdate.noticeBig(crit, false, UTC, EN);
        check("big: critical, exact", (REASON + "\n\nIf it isn't installed: " + CONSEQ + "\n\nInstall it by October 19."
                + " Tap Sign out & install in Profile, or sign out and install it from the sign-in screen. It takes a"
                + " while, and the phone restarts when it's done.").equals(bigCrit), bigCrit);
        String bigLate = OtaUpdate.noticeBig(late, false, UTC, EN);
        check("big: overdue says when it was due", bigLate.contains("It was due October 19.") && !bigLate.contains("Install it by"), bigLate);
        check("big: mandatory with auto off never mentions auto-install", !bigCrit.contains("on its own"), bigCrit);
        OtaUpdate.Status nover = OtaUpdate.parse(L("AVAIL"));
        check("big: no version", OtaUpdate.noticeBig(nover, false, UTC, EN).startsWith("A new version of the system is ready."),
                OtaUpdate.noticeBig(nover, false, UTC, EN));

        // ---- shouldAlert: once per session with the screen on; past the deadline, every 2 h of screen-on ----
        long H = 3600_000L, now = 100 * H;
        check("alert: ordinary never", !OtaUpdate.shouldAlert(ord, now, -1, true), "");
        check("alert: mandatory, first time, screen on", OtaUpdate.shouldAlert(crit, now, -1, true), "");
        check("alert: never with the screen off", !OtaUpdate.shouldAlert(crit, now, -1, false), "");
        check("alert: not overdue -> once only", !OtaUpdate.shouldAlert(crit, now, now - 50 * H, true), "");
        check("alert: overdue, first time", OtaUpdate.shouldAlert(late, now, -1, true), "");
        check("alert: overdue, 1h59 after the last", !OtaUpdate.shouldAlert(late, now, now - 2 * H + 60_000, true), "");
        check("alert: overdue, 2h after the last", OtaUpdate.shouldAlert(late, now, now - 2 * H, true), "");
        check("alert: overdue, 2h after but screen off", !OtaUpdate.shouldAlert(late, now, now - 2 * H, false), "");

        // ---- overdueDate: the first day it IS overdue (dueDate is the last day it is not) ----
        check("overdue: UTC", "October 20".equals(OtaUpdate.overdueDate(DL, UTC, EN)), OtaUpdate.overdueDate(DL, UTC, EN));
        check("overdue: New York (overdue from 20:00 on the 19th)", "October 19".equals(OtaUpdate.overdueDate(DL, NY, EN)),
                OtaUpdate.overdueDate(DL, NY, EN));

        // ---- noticeChannel: only an alert, or an update of a notice already on HIGH, may use the HIGH channel ----
        check("channel: ordinary", OtaUpdate.CH_UPDATE.equals(OtaUpdate.noticeChannel(ord, true, null)), "");
        check("channel: ordinary never HIGH", OtaUpdate.CH_UPDATE.equals(OtaUpdate.noticeChannel(ord, false, OtaUpdate.CH_REQUIRED)), "");
        check("channel: alert -> HIGH", OtaUpdate.CH_REQUIRED.equals(OtaUpdate.noticeChannel(crit, true, null)), "");
        check("channel: alert from quiet -> HIGH", OtaUpdate.CH_REQUIRED.equals(OtaUpdate.noticeChannel(crit, true, OtaUpdate.CH_REQUIRED_QUIET)), "");
        check("channel: silent update of a shown HIGH notice stays HIGH (setOnlyAlertOnce keeps it quiet)",
                OtaUpdate.CH_REQUIRED.equals(OtaUpdate.noticeChannel(crit, false, OtaUpdate.CH_REQUIRED)), "");
        check("channel: silent re-post after a dismissal -> quiet",
                OtaUpdate.CH_REQUIRED_QUIET.equals(OtaUpdate.noticeChannel(crit, false, null)), "");
        check("channel: silent while on quiet stays quiet",
                OtaUpdate.CH_REQUIRED_QUIET.equals(OtaUpdate.noticeChannel(crit, false, OtaUpdate.CH_REQUIRED_QUIET)), "");
        check("channel: silent while an ORDINARY notice is shown -> quiet (it could sound on HIGH)",
                OtaUpdate.CH_REQUIRED_QUIET.equals(OtaUpdate.noticeChannel(crit, false, OtaUpdate.CH_UPDATE)), "");
        check("channel ids are distinct", !OtaUpdate.CH_REQUIRED.equals(OtaUpdate.CH_REQUIRED_QUIET)
                && !OtaUpdate.CH_UPDATE.equals(OtaUpdate.CH_REQUIRED_QUIET) && "nowhere.update".equals(OtaUpdate.CH_UPDATE), "");

        // ---- the gate banner ----
        check("banner: ordinary on the gate", OtaUpdate.bannerVisible(ord, false, false, false), "");
        check("banner: ordinary hidden on resume", !OtaUpdate.bannerVisible(ord, false, true, false), "");
        check("banner: MANDATORY shown on resume", OtaUpdate.bannerVisible(crit, false, true, false), "");
        check("banner: never on the switch cover", !OtaUpdate.bannerVisible(crit, true, false, false), "");
        check("banner: never in owner mode", !OtaUpdate.bannerVisible(crit, false, false, true), "");
        check("banner: nothing offered", !OtaUpdate.bannerVisible(OtaUpdate.NONE, false, false, false), "");
        check("banner: ordinary text is unchanged",
                "⬆️   Software update available (0.5.45)   ·   tap to install".equals(OtaUpdate.bannerText(ord, false, true, UTC, EN)),
                OtaUpdate.bannerText(ord, false, true, UTC, EN));
        check("banner: critical on the gate", "⬆️   Critical update (0.5.45), install by October 19   ·   tap to install"
                .equals(OtaUpdate.bannerText(crit, false, true, UTC, EN)), OtaUpdate.bannerText(crit, false, true, UTC, EN));
        String br = OtaUpdate.bannerText(late, true, false, UTC, EN);
        check("banner: on resume it says where the install is, and offers no tap",
                ("⬆️   Required update (0.5.46) is overdue. After you unlock, tap Sign out & install in Profile.").equals(br), br);

        // ---- auto-install over a LOCKED session: said wherever a mandatory update is, when auto is on ----
        String brAuto = OtaUpdate.bannerText(late, true, true, UTC, EN);
        check("banner: on resume with auto on, it says the install waits for the sign-out",
                (br + " Automatic install is on: it waits while this session is locked and installs after you sign out,"
                        + " while the phone is charging.").equals(brAuto), brAuto);
        check("banner: off the resume screen, auto adds nothing", OtaUpdate.bannerText(crit, false, true, UTC, EN)
                .equals(OtaUpdate.bannerText(crit, false, false, UTC, EN)), "");
        String bigCritAuto = OtaUpdate.noticeBig(crit, true, UTC, EN);
        check("big: mandatory with auto on: signed out, a locked session waits, and the time rule",
                bigCritAuto.equals(bigCrit + "\n\nAutomatic install is on: it installs on its own while the phone is"
                        + " charging and you're signed out. While this session is locked (with Lock, or on its own after"
                        + " the phone sits idle) it waits until you sign out. If you set an install time it"
                        + " waits for that time; otherwise it starts when the screen turns off."), bigCritAuto);
        check("AUTO_LOCKED is the mandatory auto paragraph, byte for byte", ("\n\nAutomatic install is on: it installs on"
                + " its own while the phone is charging and you're signed out. While this session is locked (with Lock, or"
                + " on its own after the phone sits idle) it waits until you sign out. If you set an install time it waits"
                + " for that time; otherwise it starts when the screen turns off.").equals(OtaUpdate.AUTO_LOCKED),
                OtaUpdate.AUTO_LOCKED);
        check("AUTO_LOCKED never says the restart ends the locked session",
                !OtaUpdate.AUTO_LOCKED.contains("ends the locked session") && !OtaUpdate.AUTO_LOCKED.contains(", While"), "");
        // ---- Q063: a parked session holds automatic install ----
        check("held: a parked session", OtaUpdate.autoInstallHeld("COLDLOCK 12 nokey nopin bob", "NONE"), "");
        check("held: a lock being taken down", OtaUpdate.autoInstallHeld("NONE", "PENDING 12"), "");
        check("not held: nothing parked, nothing pending", !OtaUpdate.autoInstallHeld("NONE", "NONE"), "");
        check("held: no answer to GET-COLDLOCK (cannot tell)", OtaUpdate.autoInstallHeld("", "NONE"), "");
        check("held: no answers at all", OtaUpdate.autoInstallHeld(null, null), "");
        check("relogin verdict: NONE after a timeout proves nothing", "UNKNOWN".equals(OtaUpdate.reloginVerdict("NONE", true)), "");
        check("relogin verdict: NONE with no timeout is NONE", "NONE".equals(OtaUpdate.reloginVerdict("NONE", false)), "");
        check("relogin verdict: QUEUED stands after a timeout", "QUEUED".equals(OtaUpdate.reloginVerdict("QUEUED", true)), "");
        check("relogin verdict: UNKNOWN stays UNKNOWN", "UNKNOWN".equals(OtaUpdate.reloginVerdict("UNKNOWN", false)), "");
        check("big: mandatory with auto off says nothing about it", !OtaUpdate.noticeBig(crit, false, UTC, EN).contains("Automatic"),
                OtaUpdate.noticeBig(crit, false, UTC, EN));

        // ---- after the reap: nothing transient is ever read as final ----
        check("relogin: no answer is UNKNOWN", "UNKNOWN".equals(OtaUpdate.reloginAnswer(null)), "");
        check("relogin: an empty reply is UNKNOWN", "UNKNOWN".equals(OtaUpdate.reloginAnswer(L())), "");
        check("relogin: NONE", "NONE".equals(OtaUpdate.reloginAnswer(L("NONE"))), "");
        check("relogin: queued", "QUEUED".equals(OtaUpdate.reloginAnswer(L("OK", "name", "pass"))), "");
        check("relogin: OK without creds is UNKNOWN", "UNKNOWN".equals(OtaUpdate.reloginAnswer(L("OK", "name"))), "");
        check("relogin: garbage is UNKNOWN", "UNKNOWN".equals(OtaUpdate.reloginAnswer(L("ERR"))), "");
        String[][] next = {{"OK", "STARTED"}, {"BUSY", "STARTED"}, {"NONE", "NONE"}, {"REFUSED none", "GONE"},
                {"REFUSED session", "REFUSED"}, {"REFUSED coldlock", "REFUSED"}, {"RETRY busy", "RETRY"},
                {"", "RETRY"}, {null, "RETRY"}, {"DROPPED", "RETRY"}};
        for (String[] n : next) {
            check("after-logoff reply " + n[0] + " -> " + n[1], n[1].equals(OtaUpdate.afterLogoffNext(n[0])),
                    OtaUpdate.afterLogoffNext(n[0]));
        }
        String still = "Couldn't start the update — it's still offered in Settings → Software update.";
        for (String o : new String[]{"REFUSED", "TIMEOUT", "UNDECIDED"}) {
            check("message: " + o, still.equals(OtaUpdate.afterLogoffMessage(o)), OtaUpdate.afterLogoffMessage(o));
        }
        check("message: GONE", "There's no update to install any more.".equals(OtaUpdate.afterLogoffMessage("GONE")), "");
        check("message: STARTED and NONE say nothing", "".equals(OtaUpdate.afterLogoffMessage("STARTED"))
                && "".equals(OtaUpdate.afterLogoffMessage("NONE")) && "".equals(OtaUpdate.afterLogoffMessage(null)), "");
        // NWP-20261113-22: the gate says the update is preparing only while the daemon keeps the request (RETRY)
        check("preparing: RETRY shows it", OtaUpdate.showsPreparing("RETRY"), "");
        for (String o : new String[]{"STARTED", "NONE", "REFUSED", "TIMEOUT", "UNDECIDED", "GONE", null}) {
            check("preparing: " + o + " shows nothing", !OtaUpdate.showsPreparing(o), "");
        }
        check("preparing: the line says it", OtaUpdate.PREPARING.startsWith("Preparing the update"), OtaUpdate.PREPARING);
        check("preparing: mentions the restart", OtaUpdate.PREPARING.contains("restarts"), OtaUpdate.PREPARING);
        check("preparing: promises no time", !OtaUpdate.PREPARING.contains("will be ready in"), OtaUpdate.PREPARING);
        long[] want = {2000, 4000, 8000, 15000, 15000, 15000};
        for (int i = 0; i < want.length; i++) {
            check("retry delay " + i, OtaUpdate.retryDelayMs(i) == want[i], OtaUpdate.retryDelayMs(i));
        }
        long total = 0;
        int tries = 0;
        while (total < OtaUpdate.AFTER_LOGOFF_WAIT_MS) total += OtaUpdate.retryDelayMs(tries++);
        check("the wait is 2 minutes and covers a 35 s clean-up several times over",
                OtaUpdate.AFTER_LOGOFF_WAIT_MS == 120000L && tries >= 6, tries);

        // ---- Profile ----
        check("row: titles", "Software update".equals(OtaUpdate.profileRowTitle(ord))
                && "Critical update".equals(OtaUpdate.profileRowTitle(crit))
                && "Required update".equals(OtaUpdate.profileRowTitle(late)), "");
        check("row: ordinary detail", "Version 0.5.45 is ready. Installing signs you out first."
                .equals(OtaUpdate.profileRowDetail(ord, UTC, EN)), OtaUpdate.profileRowDetail(ord, UTC, EN));
        check("row: mandatory detail carries the signed text",
                ("Install by October 19. " + REASON + "\n\nIf it isn't installed: " + CONSEQ)
                        .equals(OtaUpdate.profileRowDetail(crit, UTC, EN)), OtaUpdate.profileRowDetail(crit, UTC, EN));
        check("row: overdue detail", OtaUpdate.profileRowDetail(late, UTC, EN).startsWith("Overdue since October 20. "),
                OtaUpdate.profileRowDetail(late, UTC, EN));
        String cs = OtaUpdate.installConfirm(false), cl = OtaUpdate.installConfirm(true);
        check("confirm: stored session is saved", cs.startsWith("You'll be signed out first, and this session is saved as usual.")
                && cs.endsWith("the phone restarts when it's done."), cs);
        check("confirm: an unsaved session is told it is erased", cl.contains("it's erased when you sign out")
                && !cl.contains("saved as usual"), cl);

        // ---- the Software update screen ----
        check("settings: ordinary adds nothing", "".equals(OtaUpdate.settingsDetail(ord, UTC, EN)), OtaUpdate.settingsDetail(ord, UTC, EN));
        check("settings: critical", ("\nCritical, install by October 19. " + REASON + "\nIf it isn't installed: " + CONSEQ)
                .equals(OtaUpdate.settingsDetail(crit, UTC, EN)), OtaUpdate.settingsDetail(crit, UTC, EN));
        check("settings: overdue", OtaUpdate.settingsDetail(late, UTC, EN).startsWith("\nRequired, overdue since October 20. "),
                OtaUpdate.settingsDetail(late, UTC, EN));

        System.out.println((fails == 0 ? "PASS " : "FAILED ") + (runs - fails) + "/" + runs);
        System.exit(fails == 0 ? 0 : 1);
    }
}
