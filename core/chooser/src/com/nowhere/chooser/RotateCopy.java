package com.nowhere.chooser;

/**
 * What the Change passphrase screen says about a ROTATE reply (NWP-20261108-13). Lifted out of
 * {@code ProfileActivity.showChangePass} -- pure, java.lang only -- because the chooser had no test surface and the
 * equality chain below was caught wrong once by reading a diff. {@code test-rotate-copy-java.sh} compiles this with
 * its cases and pins every code the daemon's handleRotate can send to a copy of its own. WEAK is the one code matched
 * by prefix, because it carries its reason (NWP-20261115-04; see failText); no other code starts with "WEAK".
 */
final class RotateCopy {
    private RotateCopy() {}

    /** NWP-20260915-10: pull the retired-keyslot count out of an "OK &lt;n&gt;" ROTATE reply, or -1 when the
     *  reply does not carry one -- a bare "OK" from an agent that predates this slice. -1 means "say the
     *  conditional thing", which is true whatever the real number is; a wrong number would not be. */
    static int retired(String reply) {
        if (reply == null) return -1;
        String[] p = reply.trim().split("\\s+");
        if (p.length < 2) return -1;
        try {
            int n = Integer.parseInt(p[1]);
            return n < 0 ? -1 : n;
        } catch (NumberFormatException e) {
            return -1;
        }
    }

    /** What to say after a successful change. n = other handsets whose keyslot was retired; -1 = unknown.
     *
     *  <p>The quoted link text is byte-identical to the gate's own ("Passphrase works on your other
     *  phone?"), and it IS reachable: after the change that phone's sign-in fails, and showBlank reveals
     *  that link on every failed sign-in. Naming it is the difference between a user who knows the next
     *  step and one who concludes their profile is gone. */
    static String changed(int n) {
        String base = "passphrase changed — use it next time you sign in";
        if (n == 0) return base;
        String which = n == 1 ? "Your other phone can't open this profile until you add it again there"
                : n > 1 ? "Your other phones can't open this profile until you add each of them again there"
                : "If another phone is locked to its own secure chip, add it again there";
        return base + ". " + which + ": tap “Passphrase works on your other phone?”, then enter your new "
                + "passphrase and your 12-word recovery code.";
    }

    /** The text for a non-OK ROTATE reply; null reads as "" (no answer).
     *
     *  <p>⚠ EQUALITY, NOT startsWith: "ERR-SESTRAND" and "ERR-SESSION" both START
     *  WITH "ERR-SE", so a prefix chain silently routed two distinct outcomes to one
     *  message. Caught reading this diff, not by a test -- the chooser had no test
     *  surface at all then; the trap is now pinned by test-rotate-copy-java.sh (the
     *  prefix-trap cases in RotateCopyCases and check (a)). The codes were renamed so
     *  that none is a prefix of another,
     *  and this chain matches exactly; keep both properties or the trap returns.
     *  NWP-20260915-10, the #140 treatment showDelete already got: every non-OK reply used
     *  to render as "check your current passphrase" -- a credential accusation the code had
     *  never established, and on a hardened profile it was the ONLY thing this screen could
     *  ever say, about a passphrase that was correct. Every branch restates the fact that
     *  decides what the user does next: YOUR PASSPHRASE HAS NOT CHANGED.
     *
     *  <p>NWP-20261115-04: WEAK is the one code matched by PREFIX, because it carries its reason
     *  ("WEAK &lt;reason&gt;", the passphrase floor's user-facing text, as CHECK-PASSPHRASE sends it). The match is
     *  "WEAK" exactly or "WEAK " with a space, so "WEAKER" still falls to the default. No other code starts with
     *  "WEAK", and test-rotate-copy-java.sh's prefix check keeps it so. Every other code stays matched by
     *  equality. WEAK is an error: the floor refused the new passphrase before anything changed. */
    static String failText(String r) {
        if (r == null) r = "";
        if ("WEAK".equals(r) || r.startsWith("WEAK ")) {
            String why = r.length() > 5 ? r.substring(5).trim() : "";
            return why.isEmpty() ? "Choose a stronger passphrase. Your passphrase has not changed."
                    : "Choose a stronger passphrase — " + why + ". Your passphrase has not changed.";
        }
        if ("ERR-SECRET".equals(r)) return "couldn't change — this phone's secure chip didn't answer for this "
                + "session. Sign out and sign in again, then try once more. Your passphrase "
                + "has not changed.";
        if ("ERR-STRAND".equals(r)) return "couldn't change — this would have locked this phone out of the "
                + "profile. Your passphrase has not changed.";
        if ("ERR-MULTI".equals(r)) return "couldn't change — this profile is signed in on more than one phone, "
                + "and a change here reaches only this one. Change it there first. Your "
                + "passphrase has not changed.";
        if ("ERR-REKEY".equals(r)) return "couldn't change — your screen lock could not follow the new "
                + "passphrase, so nothing was changed. Sign out and sign in again, then try "
                + "once more.";
        if ("ERR-SESSION".equals(r)) return "your passphrase HAS changed, but this session didn't pick it up. Sign "
                + "out and sign back in with the new passphrase.";
        if ("ERR-STORE".equals(r)) return "couldn't reach your storage — your passphrase has not changed. Check "
                + "your connection and try again.";
        if ("BUSY".equals(r)) return "couldn't change — a save is running right now. Try again in a minute. Your "
                + "passphrase has not changed.";
        // sendDaemon collapses a 90s read timeout and a dead socket to "". The daemon gives
        // up at 75s so a reply normally always arrives -- but on an empty one we do NOT
        // know which side stopped, so this is the one branch that must not claim the
        // invariant. Telling them to try the new passphrase first is safe either way.
        if (r.isEmpty()) return "the phone didn't answer, so this may or may not have gone through. "
                + "Sign out, then sign in with your NEW passphrase — if that doesn't work, "
                + "use the old one.";
        if ("BLANK".equals(r)) return "that passphrase doesn't match this profile — your passphrase has not "
                + "changed.";
        return "couldn't change — something went wrong saving the new passphrase. "
                + "Your passphrase has not changed.";
    }

    /** False only for ERR-SESSION: the change DID commit, so it is shown plainly, not as an error. */
    static boolean failIsError(String r) {
        return !"ERR-SESSION".equals(r);
    }
}
