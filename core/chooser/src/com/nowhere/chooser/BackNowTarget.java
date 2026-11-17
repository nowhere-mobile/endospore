package com.nowhere.chooser;

/**
 * Which roamed user a "Back up now" tap may post NOTIF_BACKNOW_ID into (NWP-20261204-02).
 *
 * <p>WHY: the posting uid is part of a notification's key. The watcher posts the prompt from the user-0 chooser as its
 * own app uid; a tap's feedback posted from the roamed user's own process (another uid) became a SECOND notification,
 * the watcher's one cancel removed that one, and "Back online" never cleared (NWP-20261112-53).
 *
 * <p>RULE: only the user-0 process posts NOTIF_BACKNOW_ID, and only into the foreground roamed user. Anything else
 * gives -1: the tap still sends BACKUP and posts nothing.
 */
final class BackNowTarget {
    private BackNowTarget() {}

    /** extraUid: the user the tap's intent names; currentUser: the foreground user; myUser: the receiving process's user. */
    static int uid(int extraUid, int currentUser, int myUser) {
        return myUser == 0 && extraUid > 0 && extraUid == currentUser ? extraUid : -1;
    }
}
