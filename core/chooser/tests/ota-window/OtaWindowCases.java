package com.nowhere.chooser;

/** Cases for OtaWindow.within (NWP-20261025-14), nextStartMillis and installAtAlarm (NWP-20261108-08). Prints "--- FAIL: <name>" per failed case and exits 1. */
public final class OtaWindowCases {
    private static int fails = 0;

    private static int m(int h, int min) { return h * 60 + min; }

    private static void check(String name, String set, int now, boolean want) {
        boolean got = OtaWindow.within(set, now);
        if (got == want) System.out.println("--- PASS: " + name);
        else { System.out.println("--- FAIL: " + name + " (within(" + set + ", " + now + ") = " + got + ")"); fails++; }
    }

    private static long at(String zone, String iso) {
        return java.time.LocalDateTime.parse(iso).atZone(java.time.ZoneId.of(zone)).toInstant().toEpochMilli();
    }

    private static void next(String name, String hhmm, long now, String zone, long want) {
        long got = OtaWindow.nextStartMillis(hhmm, now, java.util.TimeZone.getTimeZone(zone));
        if (got == want) System.out.println("--- PASS: nextStart " + name);
        else { System.out.println("--- FAIL: nextStart " + name + " (got " + got + ", want " + want + ")"); fails++; }
    }

    /** The answer lies after now, within 25 hours, and (when {@code localHhmm} is not null) reads that local time. */
    private static void nextBounded(String name, String hhmm, long now, String zone, String localHhmm) {
        long got = OtaWindow.nextStartMillis(hhmm, now, java.util.TimeZone.getTimeZone(zone));
        boolean ok = got > now && got < now + 25L * 3600 * 1000;
        if (ok && localHhmm != null) {
            java.time.ZonedDateTime z = java.time.Instant.ofEpochMilli(got).atZone(java.time.ZoneId.of(zone));
            ok = String.format("%02d:%02d", z.getHour(), z.getMinute()).equals(localHhmm) && z.getSecond() == 0;
        }
        if (ok) System.out.println("--- PASS: nextStart " + name);
        else { System.out.println("--- FAIL: nextStart " + name + " (got " + got + ", now " + now + ")"); fails++; }
    }

    private static void bad(String name, String hhmm, java.util.TimeZone tz) {
        long got = OtaWindow.nextStartMillis(hhmm, 0L, tz);
        if (got == -1) System.out.println("--- PASS: nextStart malformed " + name);
        else { System.out.println("--- FAIL: nextStart malformed " + name + " (got " + got + ")"); fails++; }
    }

    private static void inst(String name, boolean want, boolean live, String auto, java.util.List<String> t, int min,
                             boolean chg, String st, boolean held) {
        boolean got = OtaWindow.installAtAlarm(live, auto, t, min, chg, st, held);
        if (got == want) System.out.println("--- PASS: installAtAlarm " + name);
        else { System.out.println("--- FAIL: installAtAlarm " + name + " (got " + got + ")"); fails++; }
    }

    public static void main(String[] a) {
        check("03:00 at 03:00", "03:00", m(3, 0), true);
        check("03:00 at 03:59", "03:00", m(3, 59), true);
        check("03:00 at 04:00", "03:00", m(4, 0), false);
        check("03:00 at 02:59", "03:00", m(2, 59), false);
        check("23:30 at 23:30", "23:30", m(23, 30), true);
        check("23:30 at 23:59", "23:30", m(23, 59), true);
        check("23:30 at 00:00", "23:30", m(0, 0), true);
        check("23:30 at 00:29", "23:30", m(0, 29), true);
        check("23:30 at 00:30", "23:30", m(0, 30), false);
        check("23:30 at 23:29", "23:30", m(23, 29), false);
        check("23:59 at 00:58", "23:59", m(0, 58), true);
        check("23:59 at 00:59", "23:59", m(0, 59), false);
        check("00:00 at 00:00", "00:00", m(0, 0), true);
        check("00:00 at 00:59", "00:00", m(0, 59), true);
        check("00:00 at 23:59", "00:00", m(23, 59), false);
        check("empty", "", m(0, 0), false);
        check("3:00", "3:00", m(3, 0), false);
        check("03:0", "03:0", m(3, 0), false);
        check("24:00 at 00:00", "24:00", m(0, 0), false);
        check("24:00 at 23:30", "24:00", m(23, 30), false);
        check("12:60", "12:60", m(12, 0), false);
        check("ab:cd", "ab:cd", m(0, 0), false);
        check("03-00", "03-00", m(3, 0), false);
        check("null", null, m(3, 0), false);
        check("now -1", "03:00", -1, false);
        check("now 1440", "03:00", 1440, false);

        String ny = "America/New_York", ldn = "Europe/London";
        next("15:30 later today", "15:30", at(ny, "2026-07-01T10:00:00"), ny, at(ny, "2026-07-01T15:30:00"));
        next("15:30 already past -> tomorrow", "15:30", at(ny, "2026-07-01T16:00:00"), ny, at(ny, "2026-07-02T15:30:00"));
        next("15:30 exactly now -> tomorrow", "15:30", at(ny, "2026-07-01T15:30:00"), ny, at(ny, "2026-07-02T15:30:00"));
        next("23:50 at 23:55 -> the next day", "23:50", at(ny, "2026-07-01T23:55:00"), ny, at(ny, "2026-07-02T23:50:00"));
        next("London spring-forward 03:00", "03:00", at(ldn, "2026-03-29T00:30:00"), ldn, at(ldn, "2026-03-29T03:00:00"));
        nextBounded("London spring-forward 01:30 (skipped that day)", "01:30", at(ldn, "2026-03-29T00:30:00"), ldn, null);
        next("London spring-forward 01:30 after it", "01:30", at(ldn, "2026-03-29T05:00:00"), ldn, at(ldn, "2026-03-30T01:30:00"));
        next("London fall-back 03:00", "03:00", at(ldn, "2026-10-25T00:30:00"), ldn, at(ldn, "2026-10-25T03:00:00"));
        nextBounded("London fall-back 01:30 (twice that day)", "01:30", at(ldn, "2026-10-25T00:30:00"), ldn, "01:30");
        java.util.TimeZone utc = java.util.TimeZone.getTimeZone("UTC");
        for (String b : new String[] {null, "", "3:00", "03:0", "24:00", "12:60", "ab:cd", "+3:00", "03-00"})
            bad(String.valueOf(b), b, utc);
        bad("null tz", "03:00", null);

        java.util.List<String> t3 = java.util.Arrays.asList("03:00");
        inst("all terms true", true, false, "1", t3, 3 * 60, true, "AVAIL 0.6.0", false);
        inst("trimmed reply and time", true, false, " 1 ", java.util.Arrays.asList(" 03:00 "), 3 * 60, true, "AVAIL 0.6.0", false);
        inst("last minute of the window", true, false, "1", t3, 3 * 60 + 59, true, "AVAIL 0.6.0", false);
        inst("session live", false, true, "1", t3, 3 * 60, true, "AVAIL 0.6.0", false);
        inst("auto 0", false, false, "0", t3, 3 * 60, true, "AVAIL 0.6.0", false);
        inst("auto empty", false, false, "", t3, 3 * 60, true, "AVAIL 0.6.0", false);
        inst("no time set", false, false, "1", new java.util.ArrayList<String>(), 3 * 60, true, "AVAIL 0.6.0", false);
        inst("outside the window", false, false, "1", t3, 4 * 60, true, "AVAIL 0.6.0", false);
        inst("not charging", false, false, "1", t3, 3 * 60, false, "AVAIL 0.6.0", false);
        inst("status STAGING", false, false, "1", t3, 3 * 60, true, "STAGING", false);
        inst("status empty", false, false, "1", t3, 3 * 60, true, "", false);
        inst("held (Q063)", false, false, "1", t3, 3 * 60, true, "AVAIL 0.6.0", true);
        inst("null auto", false, false, null, t3, 3 * 60, true, "AVAIL 0.6.0", false);
        inst("null time list", false, false, "1", null, 3 * 60, true, "AVAIL 0.6.0", false);
        inst("null time line", false, false, "1", java.util.Arrays.asList((String) null), 3 * 60, true, "AVAIL 0.6.0", false);
        inst("null status", false, false, "1", t3, 3 * 60, true, null, false);
        System.exit(fails == 0 ? 0 : 1);
    }
}
