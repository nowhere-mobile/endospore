package com.nowhere.chooser;

/**
 * NWP-20261103-06 (Q153, decided 2026-10-20): Profile > Storage's offer of REPAIR-WALLET -- the reply classifier and
 * the dialog copy. The reply grammar is the agent's handleRepairWallet (core/agent/wallet_restore.go). Pure, java.lang
 * only, so core/vendor-common/bin/test-wallet-repair-java.sh runs it under plain javac.
 *
 * Only a proven DAMAGED offers the repair. UNKNOWN must never offer it, or accuse: the Storage screen's first paint
 * may not accuse, and "could not check" is not "damaged". A CONFIRM nobody answered drops the button rather than
 * keeping it: re-opening Storage re-runs CHECK, which is truthful whichever way the lost CONFIRM went.
 */
final class WalletRepairCopy {
    private WalletRepairCopy() {}

    /** The read-only question; the agent answers NONE, OK, DAMAGED or UNKNOWN. */
    static final String CHECK_REQUEST = "REPAIR-WALLET\nCHECK\n";
    /** The repair itself; sent only from the dialog's Repair button. */
    static final String CONFIRM_REQUEST = "REPAIR-WALLET\nCONFIRM\n";
    static final String BUTTON_LABEL = "Repair stored credit";
    static final String TITLE = "Repair stored credit?";
    static final String MESSAGE =
        "The stored copy of this profile's credit is damaged and nobody can read it, so the credit in it can't be recovered. "
      + "Repairing gives that credit up, so credit you buy from now on is saved again. "
      + "Credit this phone holds now is kept.";
    static final String POSITIVE = "Repair";
    static final String NEGATIVE = "Cancel";

    private static String norm(String r) { return r == null ? "" : r.trim(); }

    /** Only DAMAGED offers the repair; OK, UNKNOWN, NONE, ERR, no reply and anything else show nothing. */
    static boolean offerRepair(String checkReply) { return "DAMAGED".equals(norm(checkReply)); }

    /** True when the CONFIRM landed. */
    static boolean repaired(String confirmReply) { return "OK REPAIRED".equals(norm(confirmReply)); }

    /** The button stays only where trying again can help: REFUSED UNKNOWN and REFUSED BUSY. */
    static boolean keepButton(String confirmReply) {
        String r = norm(confirmReply);
        return "REFUSED UNKNOWN".equals(r) || "REFUSED BUSY".equals(r);
    }

    /** The one short line shown under the summary after a CONFIRM; empty when it landed. */
    static String reasonLine(String confirmReply) {
        switch (norm(confirmReply)) {
            case "OK REPAIRED":     return "";
            case "REFUSED OK":      return "Nothing to repair: the stored credit reads fine now.";
            case "REFUSED UNKNOWN": return "Couldn't check the stored credit right now. Try again.";
            case "REFUSED BUSY":    return "The phone is busy saving. Try again in a moment.";
            case "REFUSED GEN":     return "Your credit changed while this ran. Open Storage again to check.";
            default:                return "The phone didn't answer. Open Storage again to check.";
        }
    }
}
