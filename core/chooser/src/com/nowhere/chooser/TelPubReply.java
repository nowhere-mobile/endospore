package com.nowhere.chooser;

/**
 * GET-TELPUB's reply, classified for the Bind profile form (NWP-20261120-13). Pure Java, no android import, so
 * test-telpub-reply-java.sh compiles it with javac.
 */
final class TelPubReply {
    private TelPubReply() {}

    /**
     * "OK", "NOKEY", "NET" or "NONE". NONE covers NONE, NOSTORE, BLANK, wrong credentials, no reply and anything
     * unknown: blind, it does not say which. NET is only a reply equal to ERR-NET after trim: the daemon's store
     * read failed in transport, which does not depend on the name or passphrase, so naming it leaks nothing.
     */
    static String classify(String reply) {
        if (reply == null) return "NONE";
        if (reply.startsWith("OK ")) return "OK";
        if (reply.startsWith("NOKEY")) return "NOKEY";
        if ("ERR-NET".equals(reply.trim())) return "NET";
        return "NONE";
    }
}
