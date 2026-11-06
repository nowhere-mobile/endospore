package com.nowhere.chooser;

/**
 * The gate's Wi-Fi join offers three MAC choices (Q139, docs/product-decisions.md, NWP-20261106-05): a new private
 * address on each connection (the default), the same private address for this network, or the phone's real MAC.
 * Pure java.lang so a javac suite compiles it off the build host.
 *
 * <p>The index into {@link #LABELS} is the {@code sel} {@link #setting} takes; the two are one contract.
 */
final class GateMacMode {
    private GateMacMode() {}

    /** AOSP WifiConfiguration.RANDOMIZATION_NONE: the phone's real hardware address. */
    static final int NONE = 0;
    /** AOSP WifiConfiguration.RANDOMIZATION_PERSISTENT: one random address per network, stable across connections. */
    static final int PERSISTENT = 1;
    /** AOSP WifiConfiguration.RANDOMIZATION_NON_PERSISTENT (RANDOMIZATION_ENHANCED before Android 12): a new
     *  address on each connection. The explicit fallback where the platform has no RANDOMIZATION_ALWAYS. */
    static final int NON_PERSISTENT = 2;

    static final String[] LABELS = {
        "New private address each connection (default)",
        "Same private address for this network",
        "This phone's real MAC",
    };

    /** The index of the default choice in {@link #LABELS}. */
    static final int DEFAULT = 0;

    /** docs/wifi-retention-spec.md section 6.3, verbatim. */
    static final String HINT =
            "Randomized hides this phone's hardware address. The network can still recognise this phone.";

    /**
     * The WifiConfiguration.macRandomizationSetting a choice writes.
     *
     * @param sel    index into {@link #LABELS}; anything out of range is the default choice
     * @param always the platform's RANDOMIZATION_ALWAYS (GrapheneOS), or -1 where it has none (LineageOS)
     */
    static int setting(int sel, int always) {
        switch (sel) {
            case 0: return always >= 0 ? always : NON_PERSISTENT;
            case 1: return PERSISTENT;
            case 2: return NONE;
            default: return setting(DEFAULT, always);
        }
    }
}
