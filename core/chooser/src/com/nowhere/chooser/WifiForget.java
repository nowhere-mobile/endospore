package com.nowhere.chooser;

/** The gate's Forget network, decided apart from WifiManager (NWP-20261023-11). Pure java.lang so it runs under
 *  plain javac (core/vendor-common/bin/test-wifi-forget-java.sh). It answers OK only when the framework removed
 *  the network: a refused removal leaves the network saved, so it answers ERR and does NOT disconnect (that would
 *  only bounce a network the gate then rejoins). Once the removal landed the network is forgotten, so a failing
 *  disconnect does not change the verdict. There is no saveConfiguration step: for an app targeting Q+ it persists
 *  nothing removeNetwork has not. */
final class WifiForget {
    private WifiForget() {}

    interface Ops {
        /** The connected network's id, or -1 when not connected. */
        int connectedNetId();
        boolean remove(int netId);
        void disconnect();
    }

    static String run(Ops ops) {
        try {
            int netId = ops.connectedNetId();
            if (netId == -1) return "ERR not connected";
            if (!ops.remove(netId)) return "ERR refused";
            try {
                ops.disconnect();
            } catch (RuntimeException e) {
                // the removal landed: the network is forgotten whether or not the radio let go of it
            }
            return "OK";
        } catch (RuntimeException e) {
            return "ERR " + (e.getMessage() == null ? "failed" : e.getMessage());
        }
    }
}
