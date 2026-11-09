package com.nowhere.chooser;

/** NWP-20261128-33: the login.log line for a session text notice that TelIngest read back from NotificationManager
 *  about 1 s after posting it. The backlog row 'On the lock screen an SMS notice shows as "Profile" with a legacy
 *  glyph and no public text': NotificationManagerService strips android.substName from an app that does not hold
 *  SUBSTITUTE_NOTIFICATION_APP_NAME, which would give "Profile", so the line says what Android kept. subst=1 is the
 *  posted name kept, subst=0 is the name stripped or changed, subst=-1 is the notice not found (and then no other
 *  field). Integers only: never the name, sender, preview, tag or package. Pure Java, so a javac suite runs it. */
final class MsgNoticeTrace {
    private MsgNoticeTrace() {}

    static String line(boolean found, boolean summary, String substName, String expected,
                       boolean hasPublic, boolean iconOurs) {
        String head = "smsnotice sum=" + (summary ? 1 : 0);
        if (!found) return head + " subst=-1";
        boolean kept = expected != null && expected.equals(substName);
        return head + " subst=" + (kept ? 1 : 0) + " pub=" + (hasPublic ? 1 : 0) + " icon=" + (iconOurs ? 1 : 0);
    }
}
