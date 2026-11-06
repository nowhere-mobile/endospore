package com.nowhere.chooser;

/**
 * The preferred-time OTA install window: the hour starting at the chosen "HH:MM", crossing midnight (set 23:50 admits
 * 23:50-00:49). Pure -- no android imports -- so core/chooser/test-ota-window-java.sh compiles it unchanged under javac and
 * runs it. {@code ChooserActivity.nowWithinWindow} reads the clock and delegates here.
 *
 * This is the window's ARITHMETIC. When the poll that asks it runs (a Handler.postDelayed loop that does not count deep
 * sleep) was a separate defect, recorded in docs/backlog.md under the preferred-time OTA auto-install poll; since
 * NWP-20261108-08 OtaTimeReceiver's RTC_WAKEUP alarm backs that poll and asks {@link #installAtAlarm}.
 */
final class OtaWindow {
    private static final int DAY = 24 * 60;
    private static final int WINDOW = 60;

    private OtaWindow() {}

    /** True when {@code nowMinuteOfDay} (0..1439) lies in [hhmm, hhmm + 60 min) modulo a day. Malformed input is false. */
    static boolean within(String hhmm, int nowMinuteOfDay) {
        if (hhmm == null || hhmm.length() != 5 || hhmm.charAt(2) != ':') return false;
        if (nowMinuteOfDay < 0 || nowMinuteOfDay >= DAY) return false;
        for (int i = 0; i < 5; i++) {
            if (i != 2 && (hhmm.charAt(i) < '0' || hhmm.charAt(i) > '9')) return false;
        }
        int h = (hhmm.charAt(0) - '0') * 10 + (hhmm.charAt(1) - '0');
        int m = (hhmm.charAt(3) - '0') * 10 + (hhmm.charAt(4) - '0');
        if (h > 23 || m > 59) return false;
        int diff = ((nowMinuteOfDay - (h * 60 + m)) % DAY + DAY) % DAY;
        return diff < WINDOW;
    }

    /** NWP-20261108-08: the first instant strictly after {@code nowMs} whose local time in {@code tz} is hhmm:00.000,
     *  for OtaTimeReceiver's RTC_WAKEUP alarm. -1 for anything {@link #within} treats as malformed, and for a null tz.
     *  A local time a spring-forward skips resolves leniently (01:30 becomes 02:30); either way the answer is after
     *  now and within 25 hours. */
    static long nextStartMillis(String hhmm, long nowMs, java.util.TimeZone tz) {
        if (hhmm == null || hhmm.length() != 5 || tz == null) return -1;
        int h, m;
        try {
            h = Integer.parseInt(hhmm.substring(0, 2));
            m = Integer.parseInt(hhmm.substring(3, 5));
        } catch (NumberFormatException e) {
            return -1;
        }
        if (h < 0 || h > 23 || m < 0 || m > 59 || !within(hhmm, h * 60 + m)) return -1;
        java.util.Calendar c = java.util.Calendar.getInstance(tz);
        c.setTimeInMillis(nowMs);
        c.set(java.util.Calendar.HOUR_OF_DAY, h); c.set(java.util.Calendar.MINUTE, m);
        c.set(java.util.Calendar.SECOND, 0); c.set(java.util.Calendar.MILLISECOND, 0);
        if (c.getTimeInMillis() <= nowMs) {
            c.add(java.util.Calendar.DAY_OF_MONTH, 1);
            c.set(java.util.Calendar.HOUR_OF_DAY, h); c.set(java.util.Calendar.MINUTE, m);
            c.set(java.util.Calendar.SECOND, 0); c.set(java.util.Calendar.MILLISECOND, 0);
        }
        return c.getTimeInMillis();
    }

    /** NWP-20261108-08: whether OtaTimeReceiver's alarm fire installs. Every term must hold: no live session, automatic
     *  install on ("1"), a set time whose window holds nowMinute, charging, an update AVAIL (a second trigger in the
     *  same window finds STAGING, seeded by the daemon's OTA-APPLY), and no parked session (Q063, held). Null is false. */
    static boolean installAtAlarm(boolean sessionLive, String autoReply, java.util.List<String> timeLines, int nowMinute,
                                  boolean charging, String statusLine, boolean held) {
        if (sessionLive) return false;
        if (!charging) return false;
        if (held) return false;
        if (autoReply == null || !"1".equals(autoReply.trim())) return false;
        if (timeLines == null || timeLines.isEmpty() || timeLines.get(0) == null) return false;
        if (!within(timeLines.get(0).trim(), nowMinute)) return false;
        return statusLine != null && statusLine.startsWith("AVAIL");
    }
}
