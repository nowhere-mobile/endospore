package com.nowhere.chooser;

/** NWP-20261124-10: what the Session PIN screen (ProfileActivity.showSessionPin) says for each SET-PIN reply, for Set
 *  PIN (setText) and Remove PIN (clearText). Each returns null for OK and the status line's text otherwise. It matches
 *  the whole trimmed reply, never a prefix. The SET-PIN arm in core/agent/main.go sends OK, ERR-FLOOR, ERR-NOTSTORED,
 *  ERR-NOSESSION or ERR; the daemon's dispatcher sends BUSY while sessionMu is held, before the arm runs, so nothing
 *  changed. No answer is not a failure: the change may still have landed, so that line says to look again. Pure
 *  java.lang, so a javac suite (test-pin-copy-java.sh) can pin it. */
final class PinCopy {
    private PinCopy() {}

    /** The text for a Set PIN reply, or null for OK. */
    static String setText(String reply) {
        if ("ERR-FLOOR".equals(trim(reply))) return "the PIN must be 4–16 digits";
        return text(reply, "couldn't save the PIN — try again");
    }

    /** The text for a Remove PIN reply, or null for OK. A clear sends no PIN, so ERR-FLOOR gets the default line. */
    static String clearText(String reply) {
        return text(reply, "couldn't remove the PIN — try again");
    }

    private static String trim(String reply) {
        return reply == null ? "" : reply.trim();
    }

    private static String text(String reply, String dflt) {
        String r = trim(reply);
        if ("OK".equals(r)) return null;
        if ("ERR-NOTSTORED".equals(r)) return "save this profile to your store first";
        if ("BUSY".equals(r)) return "a save is running — try again in a minute. Nothing changed.";
        if ("ERR-NOSESSION".equals(r)) return "this session isn't signed in to a saved profile";
        if (r.isEmpty()) return "The phone didn't answer, so the PIN may have changed. Open this screen again to see "
                + "whether a PIN is set.";
        return dflt;
    }
}
