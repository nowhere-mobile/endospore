package com.nowhere.chooser;

/** NWP-20261201-29: the title of a session's text or MMS notice, and whether to look its sender up. Context-free, so
 *  tests/sms-notice executes both decisions. */
final class SenderName {
    private SenderName() {}

    /** The contact's name when there is one, else the number, else today's fallback. */
    static String senderTitle(String from, String contactName) {
        String name = contactName == null ? "" : contactName.trim();
        if (!name.isEmpty()) return name;
        return from == null || from.isEmpty() ? "New message" : from;
    }

    /** False for no number, and for user 0: the gate's user never reads contacts. */
    static boolean lookUpSender(String from, int userId) {
        return from != null && !from.trim().isEmpty() && userId != 0;
    }
}
