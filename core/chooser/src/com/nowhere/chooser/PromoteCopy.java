package com.nowhere.chooser;

/**
 * What the Save to your store ceremony does with a PROMOTE2 reply (NWP-20261116-15). Lifted out of
 * {@code ProfileActivity.handlePromoteReply} -- pure, java.lang only -- because the chooser has no test surface and
 * that reader had three defects no suite could see: a failed save left the ceremony up with a dead "Saving…" button,
 * and ERR-SESSION and a lost reply both said "Couldn't save — try again", which is false for each.
 * {@code test-promote-copy-java.sh} compiles this with its cases and pins every code the agent's handlePromote2,
 * promoteGuards and promoteToStore send to a kind.
 *
 * <p>⚠ EQUALITY, NOT startsWith, for every code. Two forms are matched by PREFIX, because they carry a payload:
 * "OK RECOVERY &lt;words&gt;" (the 12-word recovery code) and "WEAK &lt;reason&gt;" (the passphrase floor's text;
 * "WEAK" exactly or "WEAK " with a space, so "WEAKER" still falls to the default). No other code is a prefix of
 * another, and the suite's prefix check keeps it so.
 */
final class PromoteCopy {
    private PromoteCopy() {}

    /** What the screen does next. SAVED shows the recovery code; CEREMONY re-opens a fresh ceremony (Save live
     *  again) under a toast; BACK returns to the Profile hub under a toast; EXISTS is the dialog that re-opens the
     *  ceremony; ALREADY refreshes the hub as STORED; CREDIT folds into Add-credits; SPLIT is the dialog that says
     *  the screen lock moved but nothing was saved. */
    enum Kind { SAVED, CEREMONY, BACK, EXISTS, ALREADY, CREDIT, SPLIT }

    private static final String RECOVERY = "OK RECOVERY ";

    /** The default: BUSY (a RESTART-UNSAVED mark keeps this session local until the phone reboots), ERR-VAULT,
     *  ERR-NOSESSION, ERR-NOPASS, and any code this class does not know. For each of these nothing was saved and a
     *  retry from the ceremony is the right next step, so "try again" is true. */
    private static final String DEFAULT = "Couldn't save — try again";

    /** The 12 words of an "OK RECOVERY &lt;words&gt;" reply, trimmed, or null when the reply carries none. */
    static String recovery(String r) {
        if (r == null || !r.startsWith(RECOVERY)) return null;
        String w = r.substring(RECOVERY.length()).trim();
        return w.isEmpty() ? null : w;
    }

    private static boolean isWeak(String r) {
        return "WEAK".equals(r) || r.startsWith("WEAK ");
    }

    static Kind kind(String r) {
        if (r == null) r = "";
        if (recovery(r) != null) return Kind.SAVED;
        if (isWeak(r) || "ERR-REKEY".equals(r) || r.isEmpty()) return Kind.CEREMONY;
        if ("ERR-EXISTS".equals(r)) return Kind.EXISTS;
        if ("ERR-ALREADY".equals(r)) return Kind.ALREADY;
        if ("NOCREDIT".equals(r)) return Kind.CREDIT;
        if ("NOSTORE".equals(r) || "ERR-OFFLINE".equals(r) || "ERR-NAME".equals(r)) return Kind.BACK;
        if ("ERR-SESSION".equals(r)) return Kind.SPLIT;
        return Kind.CEREMONY;
    }

    /** The text the screen shows for a reply; "" for SAVED, ALREADY and CREDIT, which show no text of their own.
     *  null reads as "" (no answer). */
    static String text(String r) {
        if (r == null) r = "";
        if (recovery(r) != null || "ERR-ALREADY".equals(r) || "NOCREDIT".equals(r)) return "";
        if (isWeak(r)) {
            String why = r.length() > 5 ? r.substring(5).trim() : "";
            return "Choose a stronger passphrase — " + (why.isEmpty() ? "too weak" : why);
        }
        if ("ERR-REKEY".equals(r)) return "Couldn't update the session lock — nothing was saved. Try again.";
        if ("NOSTORE".equals(r)) return "Set up a store first (Settings → Store) to save this profile";
        if ("ERR-EXISTS".equals(r)) return "A profile with that name and passphrase already exists in your store. "
                + "To save this session, choose a different passphrase. To use that profile, sign in to "
                + "it instead. If you just restored it on the website, wait for the verify message.";
        if ("ERR-OFFLINE".equals(r)) return "You signed in offline — your saved profile already exists. "
                + "It loads when you reconnect.";
        // ERR-NAME: the daemon refuses a name holding '#', its scope separator (NWP-20261117-11, #54). A throwaway's
        // name cannot be changed in the ceremony, so a retry gets the same answer: BACK, not CEREMONY.
        if ("ERR-NAME".equals(r)) return "Names can't contain #.";
        // ERR-SESSION: the keyguard took the NEW passphrase, then the session-marker write and its rollback both
        // failed; nothing was saved. "Try again" would be false: a retry re-keys from the old passphrase, which the
        // lock no longer takes, and answers ERR-REKEY for ever.
        if ("ERR-SESSION".equals(r)) return "Nothing was saved, and this phone's screen lock now takes the passphrase "
                + "you just typed. Use it to unlock.";
        // No reply: the chooser reads 90 s and the PROMOTE2 arm gives the daemon 120 s, so a save that lands late
        // reads "" here. A tap on Save then tells the user which it was (a landed save answers ERR-ALREADY).
        if (r.isEmpty()) return "The phone didn't answer, so this session may or may not have been saved. "
                + "Tap Save again to find out.";
        return DEFAULT;
    }
}
