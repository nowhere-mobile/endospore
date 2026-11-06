package com.nowhere.chooser;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

/**
 * NWP-20261011-05: what the chooser knows and says about an available OS update -- including a MANDATORY one
 * (docs/product-decisions.md, 2026-10-10: "a mandatory update is whatever we flag as one; the phone explains why and
 * nags harder after its deadline, and never installs without asking").
 *
 * Pure Java, no Android types, so core/chooser/tests/ota-update runs every decision and every line of copy under a
 * plain JDK (core/vendor-common/bin/test-ota-update-java.sh).
 *
 * WHERE IT COMES FROM. The daemon's OTA-STATUS reply: line 1 is {@code AVAIL <version>} exactly as before, and a
 * mandatory update adds three lines (core/agent/ota_mandatory.go, writeOtaMandatoryLines):
 * <pre>
 *   MANDATORY &lt;mandatory|critical&gt; &lt;deadline, unix seconds&gt; &lt;due|overdue&gt;
 *   REASON &lt;signed text&gt;
 *   CONSEQUENCE &lt;signed text&gt;
 * </pre>
 * The daemon writes them only from release metadata whose signature it verified. This parser is strict in the same
 * direction: anything malformed or missing reads as an ordinary update, so the phone never nags on text it cannot
 * account for.
 *
 * WHOSE WORDS. The reason and the consequence are shown exactly as signed; the phone never composes a reason of its
 * own. Every other word here -- titles, the deadline line, the instructions, the buttons -- is ours.
 */
final class OtaUpdate {
    private OtaUpdate() {}

    /** Re-alert an OVERDUE update at most this often, and only while the screen is on (see shouldAlert). */
    static final long REALERT_MS = 2L * 60 * 60 * 1000;

    static final class Status {
        final boolean avail;
        final String version;     // "" when the daemon gave none
        final String severity;    // "" (ordinary), "mandatory" or "critical"
        final long deadlineSec;   // 0 unless mandatory
        final boolean overdue;
        final String reason;      // signed; "" unless mandatory
        final String consequence; // signed; "" unless mandatory

        Status(boolean avail, String version, String severity, long deadlineSec, boolean overdue, String reason,
               String consequence) {
            this.avail = avail; this.version = version; this.severity = severity; this.deadlineSec = deadlineSec;
            this.overdue = overdue; this.reason = reason; this.consequence = consequence;
        }

        boolean mandatory() { return avail && !severity.isEmpty(); }
        boolean critical() { return mandatory() && "critical".equals(severity); }
    }

    static final Status NONE = new Status(false, "", "", 0, false, "", "");

    /** Parse an OTA-STATUS reply (all lines, as DaemonSocket.roundTripLines returns them). */
    static Status parse(List<String> lines) {
        if (lines == null || lines.isEmpty()) return NONE;
        String head = lines.get(0).trim();
        if (!head.equals("AVAIL") && !head.startsWith("AVAIL ")) return NONE;
        String ver = head.length() > 5 ? head.substring(6).trim() : "";
        String sev = "", reason = "", consequence = "";
        long deadline = 0;
        boolean overdue = false, sawMandatory = false;
        for (int i = 1; i < lines.size(); i++) {
            String l = lines.get(i).trim();
            if (l.startsWith("MANDATORY ")) {
                String[] f = l.substring(10).trim().split("\\s+");
                if (f.length != 3) continue;
                if (!"mandatory".equals(f[0]) && !"critical".equals(f[0])) continue;
                if (!"due".equals(f[2]) && !"overdue".equals(f[2])) continue;
                long d;
                try { d = Long.parseLong(f[1]); } catch (NumberFormatException e) { continue; }
                if (d <= 0) continue;
                sev = f[0]; deadline = d; overdue = "overdue".equals(f[2]); sawMandatory = true;
            } else if (l.startsWith("REASON ")) {
                reason = l.substring(7).trim();
            } else if (l.startsWith("CONSEQUENCE ")) {
                consequence = l.substring(12).trim();
            }
        }
        if (!sawMandatory || reason.isEmpty() || consequence.isEmpty()) {
            return new Status(true, ver, "", 0, false, "", "");
        }
        return new Status(true, ver, sev, deadline, overdue, reason, consequence);
    }

    /** The deadline as a date in the phone's zone: the local date of the last instant BEFORE it, so "install by
     *  October 19" is never a day the update is already overdue on. */
    static String dueDate(long deadlineSec, TimeZone tz, Locale loc) {
        SimpleDateFormat f = new SimpleDateFormat("MMMM d", loc);
        f.setTimeZone(tz);
        return f.format(new Date(deadlineSec * 1000L - 1));
    }

    /** The first day the update is overdue, in the phone's zone: the local date of the deadline instant itself, so
     *  "overdue since October 20" names a day it really was overdue on (dueDate names the last day it was not). */
    static String overdueDate(long deadlineSec, TimeZone tz, Locale loc) {
        SimpleDateFormat f = new SimpleDateFormat("MMMM d", loc);
        f.setTimeZone(tz);
        return f.format(new Date(deadlineSec * 1000L));
    }

    private static String what(Status s) {
        return s.version.isEmpty() ? "A new version of the system is ready." : "Version " + s.version + " is ready.";
    }

    private static final String SLOW = " It takes a while, and the phone restarts when it's done.";

    // --- the in-session notification (the signed-in user's shade) ---

    static String noticeTitle(Status s, TimeZone tz, Locale loc) {
        if (!s.mandatory()) return "Software update available";
        String kind = s.critical() ? "Critical update" : "Required update";
        return s.overdue ? kind + " is overdue" : kind + ": install by " + dueDate(s.deadlineSec, tz, loc);
    }

    /** The collapsed line: the signed reason for a mandatory update, else what is ready. */
    static String noticeText(Status s) {
        return s.mandatory() ? s.reason : what(s);
    }

    /** The expanded text. {@code auto} is the device's install-while-charging setting.
     *
     *  ⚠ THE AUTO WORDING USED TO BE FALSE: "It will install on its own while the phone is charging with the screen
     *  off." This notice is only ever shown INSIDE a session, and the auto-install triggers on the gate refuse to run
     *  while a session is live (the !sessionLive guard, NWP-20260901-07). What they really do, every case:
     *    - only while charging, no session is live AND no session is parked: a cold lock sets sessionLive false, so
     *      the triggers also ask autoInstallHeld, and a parked session holds the install until it is signed out;
     *    - with an install time set, around that time (otaTimeCheck; the screen state does not matter);
     *    - with no time set, when the screen turns off (screenOffRx).
     *  The copy says exactly that. The parked hold is Q063 (docs/product-decisions.md, 2026-10-20, NWP-20261101-13),
     *  built at both trigger sites in ChooserActivity and in the
     *  preferred-time alarm, OtaTimeReceiver (NWP-20261108-08). */
    static String noticeBig(Status s, boolean auto, TimeZone tz, Locale loc) {
        String act = " Tap Sign out & install in Profile, or sign out and install it from the sign-in screen.";
        if (!s.mandatory()) {
            if (auto) {
                return what(s) + " Automatic install is on: it installs while the phone is charging and you're signed"
                        + " out. While this session is locked (with Lock, or on its own after the phone sits idle) it waits"
                        + " until you sign out."
                        + " If you set an install time it waits for that time; otherwise it starts when the screen turns"
                        + " off. To install it now, tap Sign out & install in Profile." + SLOW;
            }
            return what(s) + act + SLOW;
        }
        String due = dueDate(s.deadlineSec, tz, loc);
        return s.reason
                + "\n\nIf it isn't installed: " + s.consequence
                + "\n\n" + (s.overdue ? "It was due " + due + "." : "Install it by " + due + ".")
                + act + SLOW + (auto ? AUTO_LOCKED : "");
    }

    /** What automatic install means for a session that is LOCKED rather than signed out -- by Lock, or by the idle
     *  lock, which is the same cold lock: the gate's auto-install triggers hold while a session is parked
     *  (autoInstallHeld, Q063), so the install waits until it is signed out. Said wherever a mandatory update is
     *  described with auto on. */
    static final String AUTO_LOCKED = "\n\nAutomatic install is on: it installs on its own while the phone is charging and"
            + " you're signed out. While this session is locked (with Lock, or on its own after the phone sits idle) it"
            + " waits until you sign out. If you set an install time it waits for that time;"
            + " otherwise it starts when the screen turns off.";

    /** Q063 (docs/product-decisions.md, 2026-10-20): whether a parked cold-locked session holds automatic install.
     *  The inputs are the first reply lines of GET-COLDLOCK ("COLDLOCK <uid> ..." or "NONE") and
     *  GET-COLDLOCK-PENDING ("PENDING <uid>" or "NONE"). Held when either names a session, and when there is no
     *  answer at all: an install is a reboot, so not being able to tell reads as parked. */
    static boolean autoInstallHeld(String coldLockReply, String pendingReply) {
        String cl = coldLockReply == null ? "" : coldLockReply.trim();
        if (cl.isEmpty() || cl.startsWith("COLDLOCK ")) return true;
        return pendingReply != null && pendingReply.trim().startsWith("PENDING ");
    }

    /** Whether this post of a MANDATORY notice should alert (sound, heads-up) rather than update silently.
     *  {@code lastAlertMs} is -1 when it has not alerted in this session; times are elapsedRealtime.
     *
     *  The cadence: once per session, at the first check (every ~30 s) that finds the screen on; then, ONLY once the
     *  deadline has passed, again at the first screen-on check after at least REALERT_MS (2 hours) have elapsed since
     *  the last alert -- elapsed time, not screen-on time: a phone left dark for 5 hours alerts at its first check
     *  after the screen comes on. Never with the screen off -- a buzz in a pocket or on a nightstand is noise, not a
     *  reminder. Two hours bounds it at a handful a day for someone who uses the phone all day, and the notice itself
     *  never goes away in between (it is ongoing and re-posted, silently, on every check). "Session" is the signed-in
     *  user, not a resume: a cold lock and its resume do not reset it (ChooserActivity keeps the latch per uid). The
     *  decision is "nag harder, never block". */
    static boolean shouldAlert(Status s, long nowMs, long lastAlertMs, boolean interactive) {
        if (!s.mandatory() || !interactive) return false;
        if (lastAlertMs < 0) return true;
        if (!s.overdue) return false;
        return nowMs - lastAlertMs >= REALERT_MS;
    }

    static final String CH_UPDATE = "nowhere.update";                         // ordinary: LOW, dismissible
    static final String CH_REQUIRED = "nowhere.update.required";              // mandatory: HIGH, may sound and peek
    static final String CH_REQUIRED_QUIET = "nowhere.update.required.quiet";  // mandatory between reminders: LOW

    /** The channel for one post of the update notice. {@code activeChannel} is the channel of the notice currently
     *  shown (null = none: never posted, or dismissed). A mandatory post that may alert goes on the HIGH channel. One
     *  that may not stays on HIGH only to update a notice already shown there (with setOnlyAlertOnce, which keeps an
     *  update silent); otherwise -- a re-post after a dismissal, or a first post with the screen off -- it goes on the
     *  quiet LOW channel, so it cannot sound. Public API only: Notification.Builder.setSilent is hidden. */
    static String noticeChannel(Status s, boolean alert, String activeChannel) {
        if (!s.mandatory()) return CH_UPDATE;
        if (alert) return CH_REQUIRED;
        return CH_REQUIRED.equals(activeChannel) ? CH_REQUIRED : CH_REQUIRED_QUIET;
    }

    // --- the gate's banner ---

    /** Whether the gate shows its update banner. The switch cover and the owner hand-off never (transient, or not the
     *  user's surface). The cold-lock resume screen only for a MANDATORY update: it is the one gate surface someone who
     *  only ever locks (never signs out) sees, and an ordinary update can wait for the session notice. */
    static boolean bannerVisible(Status s, boolean coverShown, boolean resumeMode, boolean ownerSession) {
        if (!s.avail || coverShown || ownerSession) return false;
        return !resumeMode || s.mandatory();
    }

    /** The banner's words. On the resume screen it is not tappable (it would leave the prompt), so it says where the
     *  install is: in the session, after unlocking. */
    static String bannerText(Status s, boolean resumeMode, boolean auto, TimeZone tz, Locale loc) {
        String ver = s.version.isEmpty() ? "" : " (" + s.version + ")";
        if (!s.mandatory()) return "⬆️   Software update available" + ver + "   ·   tap to install";
        String kind = s.critical() ? "Critical update" : "Required update";
        String when = s.overdue ? " is overdue" : ", install by " + dueDate(s.deadlineSec, tz, loc);
        if (resumeMode) {
            // The resume screen IS a locked session: with auto on, the install can happen right here, over it.
            return "⬆️   " + kind + ver + when + ". After you unlock, tap Sign out & install in Profile."
                    + (auto ? " Automatic install is on: it waits while this session is locked"
                              + " and installs after you sign out, while the phone is charging." : "");
        }
        return "⬆️   " + kind + ver + when + "   ·   tap to install";
    }

    // --- Profile (in the session) ---

    static String profileRowTitle(Status s) {
        if (!s.mandatory()) return "Software update";
        return s.critical() ? "Critical update" : "Required update";
    }

    static String profileRowDetail(Status s, TimeZone tz, Locale loc) {
        if (!s.mandatory()) return what(s) + " Installing signs you out first.";
        return (s.overdue ? "Overdue since " + overdueDate(s.deadlineSec, tz, loc) + ". "
                           : "Install by " + dueDate(s.deadlineSec, tz, loc) + ". ") + s.reason
                + "\n\nIf it isn't installed: " + s.consequence;
    }

    /** The confirmation before "Sign out &amp; install". {@code local} = a session that is not saved to the store (a
     *  throwaway, or one signed in offline), which a sign-out erases. */
    static String installConfirm(boolean local) {
        String first = local
                ? "You'll be signed out first. This session isn't saved to your store, so it's erased when you sign out."
                : "You'll be signed out first, and this session is saved as usual.";
        return first + " Then the update downloads and installs." + SLOW;
    }

    // --- "Sign out & install" on the gate, after the reap ---
    //
    // The reap's own storage clean-up holds the daemon's session lock for half a minute or more, so the two questions
    // the gate asks right after it -- "is a relogin queued?" and "start the install" -- can both be held up. Neither a
    // timeout nor a busy answer may be read as a final one: a timed-out GET-RELOGIN is UNKNOWN (never "none"), and a
    // busy install answer is RETRY (the daemon keeps the request). Both are retried within a window W =
    // AFTER_LOGOFF_WAIT_MS, and the user is told how it ended. Worst cases, each daemon read also able to spend up to
    // DaemonSocket.CONNECT_CAP_MS (8 s) connecting:
    //   - GET-RELOGIN: one 30 s read before the window starts, then W + one 15 s back-off + one 30 s read;
    //   - the install: W + one 15 s back-off + one 8 s read, then the 8 s drop read.

    /** How long the gate keeps asking before it gives up and says so. */
    static final long AFTER_LOGOFF_WAIT_MS = 2L * 60 * 1000;

    /** The wait before retry number {@code attempt} (0-based): 2 s, 4 s, 8 s, then every 15 s. */
    static long retryDelayMs(int attempt) {
        long d = 2000L << Math.min(Math.max(attempt, 0), 3);
        return Math.min(d, 15000L);
    }

    /** GET-RELOGIN's answer: "QUEUED" (OK + name + passphrase), "NONE" (the daemon said so), or "UNKNOWN" (no answer,
     *  a timeout -- {@code lines} null -- or anything else). Only NONE lets the after-logoff install go ahead. */
    static String reloginAnswer(List<String> lines) {
        if (lines == null || lines.isEmpty()) return "UNKNOWN";
        String h = lines.get(0).trim();
        if ("NONE".equals(h)) return "NONE";
        if ("OK".equals(h) && lines.size() >= 3 && !lines.get(1).trim().isEmpty() && !lines.get(2).trim().isEmpty()) {
            return "QUEUED";
        }
        return "UNKNOWN";
    }

    /** The relogin answer to act on, given whether ANY attempt in this reap failed or timed out. A read that timed out
     *  may still have run on the daemon and taken the queued credentials -- so after one, a later NONE proves nothing
     *  (the creds may be the ones that read took), and it is UNKNOWN: the after-logoff install does not run. */
    static String reloginVerdict(String answer, boolean anyTimedOut) {
        if (anyTimedOut && "NONE".equals(answer)) return "UNKNOWN";
        return answer;
    }

    /** One OTA-APPLY-AFTER-LOGOFF reply -> STARTED (OK, or BUSY: an install is already running), NONE (no request from
     *  this user), GONE (refused: no update is offered any more), REFUSED (refused for good: someone signed in, or a
     *  cold lock is parked), or RETRY (busy, or no answer at all -- transient). */
    static String afterLogoffNext(String reply) {
        String r = reply == null ? "" : reply.trim();
        if (r.equals("OK") || r.startsWith("OK ") || r.equals("BUSY") || r.startsWith("BUSY ")) return "STARTED";
        if (r.equals("NONE")) return "NONE";
        if (r.equals("REFUSED none")) return "GONE";
        if (r.startsWith("REFUSED")) return "REFUSED";
        return "RETRY";
    }

    /** What the gate says when it is over. STARTED shows the Software update screen instead; NONE says nothing (the
     *  user never asked). REFUSED, TIMEOUT (still busy after the wait) and UNDECIDED (the relogin question never got an
     *  answer, so installing could have cut a queued sign-in short) all leave the update on offer. */
    static String afterLogoffMessage(String outcome) {
        switch (outcome == null ? "" : outcome) {
            case "REFUSED":
            case "TIMEOUT":
            case "UNDECIDED":
                return "Couldn't start the update — it's still offered in Settings → Software update.";
            case "GONE":
                return "There's no update to install any more.";
            default:
                return "";
        }
    }

    /** The gate's line while a "Sign out & install" waits for the daemon to take it (NWP-20261113-22). It promises no
     *  time beyond "a minute": the wait is the reap's storage clean-up, which the gate cannot see the end of. */
    static final String PREPARING = "Preparing the update… This can take a minute. Your phone restarts when it's ready.";

    /** Whether an after-logoff outcome means the install is still coming, so the gate says it is preparing: only RETRY
     *  (the daemon kept the request and is busy). STARTED hands over to the Software update screen; every other outcome
     *  is final and says its own line (afterLogoffMessage) or nothing. */
    static boolean showsPreparing(String outcome) {
        return "RETRY".equals(outcome);
    }

    // --- the gate's Software update screen ---

    /** The line under "Update available" for a mandatory update; "" for an ordinary one. */
    static String settingsDetail(Status s, TimeZone tz, Locale loc) {
        if (!s.mandatory()) return "";
        String when = s.overdue ? ", overdue since " + overdueDate(s.deadlineSec, tz, loc)
                                : ", install by " + dueDate(s.deadlineSec, tz, loc);
        return "\n" + (s.critical() ? "Critical" : "Required") + when
                + ". " + s.reason + "\nIf it isn't installed: " + s.consequence;
    }
}
