package com.nowhere.chooser;

/**
 * NWP-20261118-16: the one group the roamed session's message notices go in, and its summary. The backlog row
 * "Tapping a text notification in a session sometimes opens the Profile screen instead of the message": TelIngest
 * posted every SMS/MMS notice with a tap of its own and no group. AOSP's NotificationManagerService autogroups an
 * app's ungrouped notices once several are showing, under a summary of its own whose tap is the package's launch
 * intent -- for the chooser, ProfileActivity, its only LAUNCHER activity, labelled "Profile". So a tap on the
 * collapsed bundle opened Profile. That is an inference from AOSP, not reproduced.
 *
 * The fix removes the autogroup path whatever its threshold: every message notice carries KEY, and the group carries
 * its own summary from the first notice on. A reading of AOSP, not reproduced: newer releases also force-group a
 * group child that has no summary under the app's own summary, so a group alone is not enough; and a group of one
 * child renders as that child, so a summary for one notice costs nothing. The summary carries its own tap, the SMS
 * app (TelIngest.messageTapIntent with no sender), because a summary with no tap of ours leaves the system's default,
 * the launch activity, which is the defect. TelIngest.syncMessageSummary posts and cancels it. Pure java.lang.
 */
final class MessageGroup {
    private MessageGroup() {}

    /** The group key of every message notice and of their summary. */
    static final String KEY = "com.nowhere.chooser.messages";

    /** The summary's tag. It has no ':', so TelIngest.noticeRow never reads it as a message notice: the read clear never
     *  queries a row for it, and its own post or removal never starts a sweep or a re-sync. */
    static final String SUMMARY_TAG = "nowhere_msg_summary";

    /** The summary's notification id, under SUMMARY_TAG. */
    static final int SUMMARY_ID = 1;

    /** The request code of the summary's PendingIntent. A message notice's request code is its arrival time. */
    static final int SUMMARY_REQUEST = 0x4E4D5347;

    /** Whether the group wants its summary, from the number of message notices showing: from the first one on. */
    static boolean wantSummary(int activeMessageNotices) {
        return activeMessageNotices >= 1;
    }

    /** The summary's title. It holds a count only, never a sender, a number or a text. */
    static String summaryText(int n) {
        return n >= 2 ? n + " new messages" : "New message";
    }
}
