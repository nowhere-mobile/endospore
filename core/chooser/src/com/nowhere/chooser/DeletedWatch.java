package com.nowhere.chooser;

/**
 * NWP-20261105-02 (Q117): the verdict for the "Profile deleted" screen's watchdog. Pure java.lang so a plain javac
 * suite runs it (core/vendor-common/bin/test-deleted-watch-java.sh). ProfileActivity.watchDeleted polls a lock-free
 * daemon status and asks this what to do: WAIT, REBOOT (ask PowerManager once) or POWER (tell the user to hold the
 * power button).
 */
final class DeletedWatch {
    private DeletedWatch() {}

    /** Seconds between status polls. */
    static final long POLL_MS = 2000;
    /** 60 s outlasts the daemon's own holds -- the 8+8 s switch check and the 3+30 s no-uid hold -- so the watchdog
     *  never reboots ahead of them and never destroys pending telephony records early (Q117). */
    static final long DEADLINE_MS = 60_000;
    /** Unanswered polls in a row. The verb is lock-free, so three misses mean the daemon is gone, and a gone daemon
     *  holds nothing. */
    static final int MISSES = 3;
    /** After the reboot request, how long to wait for the phone to go down before telling the user. */
    static final long REBOOT_GRACE_MS = 15_000;

    /** Claims nothing about saving: a delete seals nothing. */
    static final String POWER_MESSAGE =
            "Profile deleted. Your phone didn't restart on its own — hold the power button to restart it.";

    /** POWER is tested first and REBOOT needs !rebootAsked, so once asked the verdict is only WAIT or POWER. */
    static String action(long waitedMs, int missesInARow, boolean rebootAsked, long sinceAskMs, boolean rebootThrew) {
        if (rebootAsked && (rebootThrew || sinceAskMs >= REBOOT_GRACE_MS)) return "POWER";
        if (!rebootAsked && (missesInARow >= MISSES || waitedMs >= DEADLINE_MS)) return "REBOOT";
        return "WAIT";
    }
}
