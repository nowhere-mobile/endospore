package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** NWP-20261113-06: the Profile screen's session probe -- throwaway or stored, offline, the profile's name, and the OS
 *  update offer. The screen used to send these four requests with a 90 s read each BEFORE drawing anything, so with
 *  the login daemon wedged it stayed black for minutes (4 min 48 s on lynx 2026102201, daemon kill -STOP'd), and
 *  Lock, Log off and Report an issue were all out of reach. The rule now: the menu is on screen before the first
 *  daemon read (Ui.drawChecking runs first), each read is capped by the Sender, and the probe stops at the first
 *  request with no answer -- the daemon is not answering, and every request after it would wait out its own cap too.
 *  Pure Java, no android.* import: core/vendor-common/bin/test-profile-probe-java.sh compiles this file directly. */
final class ProfileProbe {
    private ProfileProbe() {}

    /** One daemon round trip: the reply (all its lines, joined by \n, for a multi-line verb), "" for no answer. */
    interface Sender {
        String ask(String request);
    }

    /** drawChecking() runs before the first request; apply(Result) runs once, after the last one sent. */
    interface Ui {
        void drawChecking();
        void apply(Result r);
    }

    static final class Result {
        /** NONE / LOCAL / STORED, or UNKNOWN when the daemon did not answer (ProfileReplies.sessionType). */
        final String sessionType;
        final boolean offline;
        /** The profile's name, or null: no answer, or "NONE" (no live session, or a caller the daemon cannot place). */
        final String name;
        /** The OTA-STATUS reply's non-blank lines; empty when it was not answered or not sent. */
        final List<String> otaLines;

        Result(String sessionType, boolean offline, String name, List<String> otaLines) {
            this.sessionType = sessionType;
            this.offline = offline;
            this.name = name;
            this.otaLines = Collections.unmodifiableList(otaLines);
        }
    }

    static void run(Sender s, Ui ui) {
        ui.drawChecking();
        String off = "", nm = "", wd = "", ota = "";
        // NWP-20261006-23: no reply is UNKNOWN, never STORED. An empty reply used to fall through to the stored
        // branch: a throwaway read "Signed in · roams to your store" and its Save offer was hidden, so the user
        // could sign out believing their data was saved.
        final String type = reply(s, "GET-SESSION-TYPE\n");
        if (!type.isEmpty()) off = reply(s, "GET-OFFLINE\n"); // #49: offline != throwaway
        // NWP-20260922-05: "who am I" comes from the daemon, because the Android user is no longer named after the
        // profile. Fetched HERE, on the probe thread, so the UI-thread callers of profileName() read a field instead
        // of opening a socket.
        if (!off.isEmpty()) nm = reply(s, "GET-SESSION-NAME\n");
        // NWP-20261011-05: a fresh Profile screen withdraws any "Sign out & install" request still pending. One left by
        // an earlier screen of this session is stale by definition: the session it asked to end is still here.
        if (!nm.isEmpty()) wd = reply(s, "OTA-AFTER-LOGOFF\n0\n");
        // NWP-20261011-05: is an OS update waiting, and is it mandatory? OTA-STATUS answers from the daemon's cache (no
        // network). ⚠ It is sent only AFTER the withdraw above has been answered: the Update row, and so "Sign out &
        // install", appears only once OTA-STATUS answers, so a new install request cannot be made before the withdraw.
        if (!wd.isEmpty()) ota = reply(s, "OTA-STATUS\n");
        // NWP-20261025-09: an offline sign-in reports LOCAL too, so a LOCAL with no GET-OFFLINE answer is UNKNOWN,
        // not "Throwaway": a stored profile was painted as one, with a Save offer, when the offline read timed out.
        ui.apply(new Result(ProfileReplies.sessionType(type, off), ProfileReplies.offline(off),
                nm.isEmpty() || "NONE".equals(nm) ? null : nm, lines(ota)));
    }

    private static String reply(Sender s, String request) {
        String r = s.ask(request);
        return r == null ? "" : r.trim();
    }

    private static List<String> lines(String reply) {
        ArrayList<String> out = new ArrayList<>();
        for (String l : reply.split("\n")) {
            String t = l.trim();
            if (!t.isEmpty()) out.add(t);
        }
        return out;
    }
}
