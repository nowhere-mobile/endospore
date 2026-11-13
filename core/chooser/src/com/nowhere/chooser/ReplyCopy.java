package com.nowhere.chooser;

/**
 * The words the chooser puts on screen for a daemon reply, decided here so that a daemon that does not answer is
 * never rendered as an answer (NWP-20261020-11). {@code sendDaemon} and {@code daemonCmd} return "" on any failure
 * (a restarting daemon, a wedged one, a connect that times out), so an empty reply has to read as "we do not know",
 * not as "too weak" or as "every 2 minutes".
 *
 * Pure Java, no android.* import: core/vendor-common/bin/test-reply-copy-java.sh compiles this file directly.
 */
final class ReplyCopy {
    private ReplyCopy() {}

    enum State { STRONG, WEAK, UNKNOWN }

    /** A strength verdict and the line to show beside it. */
    static final class Strength {
        final State state;
        final String text;

        Strength(State state, String text) {
            this.state = state;
            this.text = text;
        }
    }

    /** CHECK-PASSPHRASE answers "OK" or "WEAK <reason>"; anything else is the daemon not answering. */
    static Strength strength(String reply) {
        if (reply != null) {
            String first = reply.split("\n", 2)[0].trim();
            if (first.equals("OK")) return new Strength(State.STRONG, "strong");
            if (first.equals("WEAK")) return new Strength(State.WEAK, "too weak");
            if (first.startsWith("WEAK ")) {
                String why = first.substring(5).trim();
                return new Strength(State.WEAK, why.isEmpty() ? "too weak" : why);
            }
        }
        return new Strength(State.UNKNOWN, "couldn't check the passphrase — the phone isn't answering");
    }

    /** The gate Settings backup row for a GET-SYNC-INTERVAL reply: the cadence only when the daemon gave one. */
    static String backupRow(String reply) {
        int sec = -1;
        try { sec = Integer.parseInt(reply == null ? "" : reply.trim()); } catch (NumberFormatException e) { /* no cadence */ }
        if (sec <= 0) return "Backup frequency couldn't be read right now  ·  tap to change";
        return "Your data is backed up " + prettyInterval(sec) + "  ·  tap to change";
    }

    /** SET-SYNC-INTERVAL answers OK only when the cadence was saved (ERR otherwise; "" when nothing answered). */
    static boolean cadenceSaved(String reply) {
        return reply != null && reply.split("\n", 2)[0].trim().equals("OK");
    }

    /** A device-setting SET (SET-OTA-AUTO, SET-OTA-TIME, SET-NOTICE-NUMBER) answers OK only when the setting was saved
     *  (ERR otherwise; "" when nothing answered). NWP-20261021-07. */
    static boolean settingSaved(String reply) {
        return reply != null && reply.split("\n", 2)[0].trim().equals("OK");
    }

    /** A device-setting GET answers "1" or "0"; anything else, "" and null included, is the daemon not answering, and
     *  the switch must not show a state for it. */
    static Boolean flagOf(String reply) {
        if (reply == null) return null;
        String v = reply.trim();
        if (v.equals("1")) return Boolean.TRUE;
        if (v.equals("0")) return Boolean.FALSE;
        return null;
    }

    /** The words for a BACKUP reply that starts with BUSY: the daemon appends the reason it refused ("BUSY login"), a bare
     *  "BUSY" is the dispatcher's lock refusal. Every line says only what the code did -- it did NOT start a save. */
    static String backupBusy(String reply) {
        String first = reply == null ? "" : reply.split("\n", 2)[0].trim();
        String why = first.startsWith("BUSY ") ? first.substring(5).trim() : "";
        if (why.equals("seal-in-flight") || why.startsWith("seal-run:"))
            return "A save is already running, and this tap joined it.";
        if (why.equals("login"))
            return "Your sign-in or unlock is still finishing, so the save wasn't started. Try again in a moment.";
        if (why.equals("user-op-waiting"))
            return "The phone is busy with something you asked for, such as setting up an app, so the save wasn't started. Try again in a moment.";
        return "The phone is busy, so the save wasn't started. Try again in a moment.";
    }

    /** "every 30 seconds" / "every minute" / "every 2 minutes" for the backup-frequency row. */
    static String prettyInterval(int sec) {
        if (sec % 60 == 0) {
            int m = sec / 60;
            return m == 1 ? "every minute" : "every " + m + " minutes";
        }
        return "every " + sec + " seconds";
    }

    /** The "Your data" apps line and whether it is the warning (NWP-20261026-18). */
    static final class AppsLine {
        final String text;
        final boolean warn;

        AppsLine(String text, boolean warn) {
            this.text = text;
            this.warn = warn;
        }
    }

    /** The "Your data" apps line (NWP-20261026-18). keptKnown is false when the keep-set could not be read; keptCount
     *  is its size before the stored apps are taken out; measured is SEAL-DELTA's storedMeasured; unsavedLabels are the
     *  labels of the kept apps the store does not hold (null when not computed). A profile that keeps no apps never
     *  seals #apps, so storedMeasured stays false for it for ever (superseded by NWP-20261027-09: a definitely absent
     *  #apps head now reads measured and empty; the keep-set still decides first): an EMPTY keep-set answers the
     *  question without the store. A keep-set or a store that could not be read is "unknown", never "none" (NWP-20260903-01).
     *  lastSaveLeftApps is true when the last verdict's parts name {@code apps=} (NWP-20261113-11): the store holds every
     *  kept app, but from an earlier save, so "All your kept apps are saved." would be false. */
    static AppsLine storedAppsLine(boolean keptKnown, int keptCount, boolean measured, java.util.List<String> unsavedLabels,
                                   boolean lastSaveLeftApps) {
        if (keptKnown && keptCount == 0) return new AppsLine("This profile keeps no apps, so there are none to save.", false);
        if (!keptKnown || !measured || unsavedLabels == null) return new AppsLine("Apps in your store: unknown right now.", false);
        if (unsavedLabels.isEmpty()) return lastSaveLeftApps
                ? new AppsLine("Your last save didn't store your apps' latest changes — your stored copy has them from an earlier save.", false)
                : new AppsLine("All your kept apps are saved.", false);
        // NWP-20260903-01: "saved", not "in your store" -- the screen already says "what's saved -- and what isn't yet",
        // so a third noun read as "this app is MISSING" rather than "this app's data is not backed up yet".
        StringBuilder b = new StringBuilder("Not saved yet: ");
        for (int i = 0; i < unsavedLabels.size(); i++) {
            if (i == 3) { b.append(" +").append(unsavedLabels.size() - 3).append(" more"); break; }
            if (i > 0) b.append(", ");
            b.append(unsavedLabels.get(i));
        }
        b.append(" — back up before powering off.");
        return new AppsLine(b.toString(), true);   // the warning case -- the only place warn is true
    }
}
