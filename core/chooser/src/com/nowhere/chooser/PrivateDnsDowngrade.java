package com.nowhere.chooser;

/**
 * NWP-20261122-07: the rules of the blocked-encrypted-DNS prompt at the gate (Q028 2026-10-20; h49 #2 2026-10-31,
 * draft A and rule (ii); h50 #4 2026-11-01, A1 and B1 -- docs/product-decisions.md). NWP-20261127-07 (h50 #4 A1): the
 * same prompt in a signed-in session, as a notification there whose tap opens the same dialog. The prompt has ONE
 * surface at a time (the gate, the roamed user in front, or none); the choice applies phone-wide either way.
 *
 * WHY. Provision sets strict private DNS (hostname mode). A network that blocks DoT then fails every lookup, the
 * network never validates, and the gate and every session stay offline there with no way out. The gate now asks;
 * "Continue without encryption" sets private DNS Off (plain DNS, B1); "Stay private" leaves the phone offline there.
 *
 * Rule (ii): the downgrade writes ONE marker that holds no network name, BEFORE the mode, so a restart can never leave
 * the phone unencrypted with nothing to say so. At every start and every network change the gate turns strict mode
 * back on only if the marker is there, then removes it; with no marker nothing is written, so an owner's own
 * private-DNS setting survives.
 *
 * Pure java.* so a plain javac suite runs it (core/chooser/test-private-dns-downgrade-java.sh). The settings and the
 * marker come through {@link Io}; PrivateDnsWatch supplies the real one.
 */
final class PrivateDnsDowngrade {
    private PrivateDnsDowngrade() {}

    /** Settings.Global private_dns_mode and the user-0 marker file, as PrivateDnsWatch reaches them. */
    interface Io {
        /** The current private_dns_mode; null when unset. */
        String mode();
        /** Write private_dns_mode; true when the write landed. */
        boolean setMode(String mode);
        /** The marker exists. */
        boolean marked();
        /** Create the empty marker; true when it exists afterwards. */
        boolean mark();
        /** Delete the marker; true when it is gone afterwards. */
        boolean unmark();
    }

    /** Where the prompt shows; PrivateDnsWatch puts it on the resumed gate or in the roamed user in front. */
    interface Ui {
        /**
         * Show the prompt on this surface: the gate dialog for {@link #SURFACE_GATE}, a notification in that user for a
         * uid > 0. Its buttons and its dismissal come back with this token. False when it did not show.
         */
        boolean show(long token, int surface);
        /** Close the showing prompt, on whichever surface it went to. */
        void dismiss();
    }

    // The prompt's surface: nobody can see it, the resumed gate, or (a value > 0) the uid of the roamed user in front.
    static final int SURFACE_NONE = -1, SURFACE_GATE = 0;

    // The choice a session's dialog sends to user 0 (PrivateDnsChoiceReceiver); protocol words, never shown.
    static final String CHOICE_CONTINUE = "continue", CHOICE_STAY = "stay";

    static final String MODE_STRICT = "hostname";
    static final String MODE_OFF = "off";

    // The decided words, verbatim from h49 #2 (the suite compares them with the doc).
    static final String TITLE = "This network blocks encrypted DNS";
    static final String BODY = "Nothing can connect here while lookups stay private. If you continue, whoever runs this "
            + "network (at work, your employer) can see the name of every site and service this phone looks up while it "
            + "is on it. This covers the whole phone, including a profile that is signed in. Private lookups come back "
            + "when you leave this network.";
    static final String CONTINUE = "Continue without encryption";
    static final String STAY = "Stay private";

    /** Strict mode is on and the network says private DNS is broken. */
    static boolean blocked(String mode, boolean privateDnsBroken) {
        return MODE_STRICT.equals(mode) && privateDnsBroken;
    }

    /**
     * Show the prompt: blocked, a surface other than NONE, a network, and not the network the user chose "Stay private"
     * on. equals, not ==: ConnectivityManager parcels a fresh Network object into each callback for one network.
     */
    static boolean prompt(boolean blocked, int surface, Object network, Object declinedOn) {
        return blocked && surface != SURFACE_NONE && network != null && !network.equals(declinedOn);
    }

    /**
     * The surface from what user 0 sees: the resumed gate wins (ACTION_USER_SWITCHED and the gate's resume come in
     * either order on a switch back, and the resumed gate is the screen in front); else a roamed current user; else
     * NONE (a currentUser of -1, unread, is NONE too).
     */
    static int surface(boolean gateResumed, int currentUser) {
        if (gateResumed) return SURFACE_GATE;
        return currentUser > 0 ? currentUser : SURFACE_NONE;
    }

    /**
     * "Continue without encryption": the marker FIRST, then Off. Nothing is written when the mode is no longer strict
     * (the owner changed it while the dialog was up) or when the marker cannot be written. The specifier is left alone.
     */
    static boolean downgrade(Io io) {
        if (!MODE_STRICT.equals(io.mode())) return false;
        if (!io.mark()) return false;
        return io.setMode(MODE_OFF);
    }

    /** At every start and network change: only with the marker, strict mode back on, THEN the marker removed. */
    static boolean restoreIfMarked(Io io) {
        if (!io.marked()) return false;
        if (!io.setMode(MODE_STRICT)) return false;
        io.unmark();
        return true;
    }

    /**
     * The dialog belongs to ONE default network (the consent is per network, Q028). Any event that makes {@link #prompt}
     * false closes it: a new default network, the loss of this one, the broken signal clearing, the surface going to
     * NONE. A change of surface (gate and session, session A and session B) closes it too, and the new surface is asked
     * with a new token, so an old notification's token does nothing. Tokens start at a random value per Gate, so a
     * dialog that outlived a restart of this process carries no token the new Gate accepts. A button of a closed dialog
     * does nothing, and Continue writes only while the dialog's network is still the default network and still blocked.
     * PrivateDnsWatch feeds it the callbacks; the javac suite feeds it sequences. Main thread only, like the callbacks.
     */
    static final class Gate {
        private final Io io;
        private final Ui ui;
        private Object current;             // the default network, or null
        private boolean broken;             // the current network says private DNS is broken
        private int surface = SURFACE_NONE; // where the prompt can show (SURFACE_GATE, a session uid, or NONE)
        private Object declinedOn;          // "Stay private" was chosen on this network (RAM only)
        private Object askedOn;             // the network of the showing prompt
        private long asked;                 // the showing prompt's token; 0 = none
        private long lastToken;             // random at construction: no token of an earlier Gate is reused

        Gate(Io io, Ui ui) {
            this.io = io;
            this.ui = ui;
            // A session's dialog lives in another user's process and can outlive this one: a Gate born after a restart
            // must never issue a token an earlier Gate gave out, or that old dialog would consent for a new network.
            // Random per Gate, in RAM only: no durable state.
            this.lastToken = new java.security.SecureRandom().nextLong();
        }

        /** A default network came up. True when it is a new one: the caller then restores (rule (ii)). */
        boolean onAvailable(Object n) {
            if (n.equals(current)) return false;
            current = n;
            broken = false;
            close(); // the old network's dialog is no consent for this one
            return true;
        }

        void onLost(Object n) {
            if (!n.equals(current)) return;
            current = null;
            broken = false;
            close();
        }

        void onBroken(Object n, boolean b) {
            if (!n.equals(current)) return;
            broken = b;
            evaluate();
        }

        /** The surface changed or was read again: a new surface closes the open prompt, then it is evaluated. */
        void onSurface(int s) {
            if (s != surface) {
                surface = s;
                close(); // the old surface's prompt is closed; a new token goes to the new one
            }
            evaluate();
        }

        /** "Continue without encryption" on the dialog with this token. True when it downgraded. */
        boolean onContinue(long token) {
            if (token == 0 || token != asked) return false; // a closed dialog's button
            Object on = askedOn;
            asked = 0;
            askedOn = null;
            if (current == null || !current.equals(on)) return false; // the default network changed under it
            if (!blocked(io.mode(), broken)) return false;            // no longer blocked
            return downgrade(io);
        }

        /** "Stay private" on the dialog with this token: not asked again on that network. */
        void onStay(long token) {
            if (token == 0 || token != asked) return;
            declinedOn = askedOn;
            asked = 0;
            askedOn = null;
        }

        /** The dialog with this token went away without a choice. */
        void onDismissed(long token) {
            if (token == 0 || token != asked) return;
            asked = 0;
            askedOn = null;
        }

        private void evaluate() {
            if (!prompt(blocked(io.mode(), broken), surface, current, declinedOn)) {
                close();
                return;
            }
            if (asked != 0) return;
            long t = ++lastToken;
            if (t == 0) t = ++lastToken; // 0 means none
            asked = t;
            askedOn = current;
            if (!ui.show(t, surface)) {
                asked = 0;
                askedOn = null;
            }
        }

        private void close() {
            if (asked == 0) return;
            asked = 0;
            askedOn = null;
            ui.dismiss();
        }
    }
}
