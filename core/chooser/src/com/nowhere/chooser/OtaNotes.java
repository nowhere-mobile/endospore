package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/**
 * NWP-20261012-03: the two OTA notes dialogs on the gate's Software update screen, as a title and a body.
 *
 * Pure Java, no Android types, so core/chooser/tests/ota-notes runs every case under a plain JDK
 * (core/vendor-common/bin/test-ota-notes-java.sh).
 *
 * WHY TWO MODES. The version line ("Current version: X · what's in it") and the update line ("Update available (Y) ·
 * what's new") used to open the same dialog, titled "What's new", holding both the offered versions and this phone's
 * own. Chester, on that: "is the topic for "what's new" and "what's in it" also "what's new"? ... not sure whether its
 * with the wrong subject or showing the same thing for both". Each line now opens its own answer:
 * <ul>
 *   <li>{@link Mode#IN_IT}: what the installed version is -- its own notes, nothing else.</li>
 *   <li>{@link Mode#NEW}: what installing the update changes -- the offered versions only, never the installed one's
 *       notes. One version: that version's points. Several: one section per version, newest first.</li>
 * </ul>
 *
 * PROFILE'S UPDATE CARD (NWP-20261124-14). A signed-in session's Update card shows the {@link Mode#NEW} body under
 * {@link #CARD_HEADING}, through {@link #cardNotes}: the same words as the gate's "what's new", never a second wording.
 *
 * WHERE IT COMES FROM. The daemon's OTA-NOTES reply (core/agent/ota_notes.go, writeOtaNotesReply):
 * <pre>
 *   RUNNING &lt;version&gt;   then its NOTE lines
 *   OFFERED &lt;version&gt;   then its NOTE lines -- one block per version from the offered one back towards the running
 *                        one (exclusive), newest first; present only while an update is available and its walk has run
 *   MORE                 there are earlier changes these notes do not describe
 *   END
 * </pre>
 *
 * WHOSE WORDS. The points are the published notes, shown as published (the agent refuses a point that makes a privacy
 * or security claim). Every other word here is ours, and keeps to the same rule: it says what changed, never what
 * anything protects.
 */
final class OtaNotes {
    private OtaNotes() {}

    /** Which line was tapped. */
    enum Mode { IN_IT, NEW }

    static final String BULLET = "•  ";
    static final String NOT_LOADED = "Couldn't load the notes right now. Try again in a moment.";
    static final String NO_NOTES = "No notes for this version.";
    static final String NOT_READY = "Notes for this update aren't ready yet. Try again in a moment.";
    static final String NOT_AVAILABLE = "No notes are available for this update yet.";
    static final String MORE_LINE = "…and earlier changes not listed.";
    /** NWP-20261124-14: the heading of Profile's Update card's notes (ProfileActivity.addUpdateCard). */
    static final String CARD_HEADING = "What's in this update";

    /** One version's notes. */
    static final class Version {
        final String version;
        final List<String> points = new ArrayList<>();
        Version(String version) { this.version = version; }
    }

    /** A parsed OTA-NOTES reply. {@code ended} is false when the reply was cut short or never came. */
    static final class Reply {
        boolean ended;
        boolean more;
        Version running = new Version("");
        final List<Version> offered = new ArrayList<>();
    }

    /** What the dialog shows. */
    static final class View {
        final String title, body;
        View(String title, String body) { this.title = title; this.body = body; }
        @Override public String toString() { return title + " | " + body; }
    }

    static Reply parse(List<String> lines) {
        Reply r = new Reply();
        if (lines == null) return r;
        Version cur = null;
        for (String raw : lines) {
            String l = raw == null ? "" : raw.trim();
            if (l.startsWith("RUNNING ")) { r.running = new Version(l.substring(8).trim()); cur = r.running; }
            else if (l.startsWith("OFFERED ")) { cur = new Version(l.substring(8).trim()); r.offered.add(cur); }
            else if (l.startsWith("NOTE ")) { if (cur != null) cur.points.add(l.substring(5).trim()); }
            else if (l.equals("MORE")) r.more = true;
            else if (l.equals("END")) { r.ended = true; break; }
        }
        return r;
    }

    static View render(List<String> lines, Mode mode) {
        Reply r = parse(lines);
        String running = r.running.version;
        if (mode == Mode.IN_IT) {
            String title = running.isEmpty() ? "What's in this version" : "What's in " + running;
            if (!r.ended) return new View(title, NOT_LOADED);
            return new View(title, r.running.points.isEmpty() ? NO_NOTES : bullets(r.running.points));
        }
        if (!r.ended) return new View("What's new", NOT_LOADED);
        // No OFFERED block. With MORE, the walk ran and stopped at the offered version: either its notes were never
        // published, or reading them failed (a store error, a missing or mismatched blob, a refused file), which the
        // agent retries in a later OTA refresh (core/agent/ota_notes.go, walkOtaNotes / refreshOtaNotes). The two
        // look the same here, so the copy must be true of both: no notes are available yet, with no promise either
        // way. Without MORE, the walk has not run yet -- or no update is offered at all, when this view should not be
        // reachable -- so it should fill in shortly.
        if (r.offered.isEmpty()) return new View("What's new", r.more ? NOT_AVAILABLE : NOT_READY);
        Version top = r.offered.get(0);
        // One step: the offered version is the only one between this phone and the update, and the walk reached this
        // phone's version (no MORE). Anything else is "several": a MORE means versions the notes do not name.
        if (r.offered.size() == 1 && !r.more) {
            return new View("What's new in " + top.version, top.points.isEmpty() ? NO_NOTES : bullets(top.points));
        }
        StringBuilder b = new StringBuilder();
        b.append("Your phone: ").append(running.isEmpty() ? "unknown" : running)
         .append(" · Update: ").append(top.version);
        for (Version v : r.offered) {
            b.append("\n\n").append("Version ").append(v.version).append('\n')
             .append(v.points.isEmpty() ? NO_NOTES : bullets(v.points));
        }
        if (r.more) b.append("\n\n").append(MORE_LINE);
        return new View("Changes since your version", b.toString());
    }

    /**
     * NWP-20261124-14: the notes on Profile's Update card -- the gate's "what's new" body, word for word, so the two
     * never say different things about one update. Null when the reply did not end (cut short, or no daemon): the card
     * then draws nothing more than it did before, rather than a "couldn't load" line under an update the user can
     * still install. The card has its own title (OtaUpdate.profileRowTitle names the update), so only the body is used.
     */
    static String cardNotes(List<String> lines) {
        if (!parse(lines).ended) return null;
        return render(lines, Mode.NEW).body;
    }

    private static String bullets(List<String> points) {
        StringBuilder b = new StringBuilder();
        for (String p : points) b.append(b.length() > 0 ? "\n" : "").append(BULLET).append(p);
        return b.toString();
    }
}
