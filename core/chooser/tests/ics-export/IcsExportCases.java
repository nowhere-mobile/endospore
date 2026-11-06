package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/** NWP-20261109-03: the rows -> iCalendar rules of IcsExport.build. Exit 1 when any check fails. */
public final class IcsExportCases {
    private static int failed = 0;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "  ok   " : "  FAIL ") + what);
        if (!ok) failed++;
    }

    private static final String H =
            "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//nowhere//export//EN\r\nCALSCALE:GREGORIAN\r\n";
    static final long SEP1_10 = 1788256800000L, SEP1_1030 = 1788258600000L, SEP8_10 = 1788861600000L,
            SEP15_10 = 1789466400000L, SEP16_14 = 1789567200000L, SEP16_1430 = 1789569000000L,
            SEP1_00 = 1788220800000L, SEP8_00 = 1788825600000L;

    private static IcsExport.Row row(long id, String title, Long start, Long end) {
        IcsExport.Row r = new IcsExport.Row();
        r.id = id;
        r.title = title;
        r.dtstart = start;
        r.dtend = end;
        return r;
    }

    private static IcsExport.Row series(long id, boolean allDay) {
        IcsExport.Row r = row(id, "Weekly", allDay ? SEP1_00 : SEP1_10, null);
        r.allDay = allDay;
        r.rrule = "FREQ=WEEKLY";
        r.duration = allDay ? "P1D" : "P1800S";
        return r;
    }

    private static IcsExport.Row exception(long id, long of, long slot, int status, boolean deleted) {
        IcsExport.Row r = row(id, "Weekly", SEP16_14, SEP16_1430);
        r.originalId = of;
        r.originalInstanceTime = slot;
        r.status = status;
        r.deleted = deleted;
        return r;
    }

    private static IcsExport.Result build(IcsExport.Row... rs) {
        List<IcsExport.Row> l = new ArrayList<>();
        for (IcsExport.Row r : rs) l.add(r);
        return IcsExport.build(l);
    }

    private static int count(String text, String needle) {
        int n = 0;
        for (int i = text.indexOf(needle); i >= 0; i = text.indexOf(needle, i + 1)) n++;
        return n;
    }

    public static void main(String[] args) {
        // 1
        IcsExport.Row single = row(7, "Dentist", SEP1_10, SEP1_1030);
        single.location = "Main St";
        single.description = "bring card";
        IcsExport.Result r = build(single);
        check(r.events == 1 && H.concat("BEGIN:VEVENT\r\nUID:7@nowhere\r\nSUMMARY:Dentist\r\nDTSTART:20260901T100000Z\r\n"
                + "DTEND:20260901T103000Z\r\nLOCATION:Main St\r\nDESCRIPTION:bring card\r\nEND:VEVENT\r\n"
                + "END:VCALENDAR\r\n").equals(r.text), "single timed event: the pre-change text byte for byte");
        // 2
        IcsExport.Row ad = row(8, "Holiday", SEP1_00, SEP8_00);
        ad.allDay = true;
        r = build(ad);
        check(r.text.contains("DTSTART;VALUE=DATE:20260901\r\nDTEND;VALUE=DATE:20260908\r\n"),
                "single all-day event keeps the DATE form with DTEND");
        // 3
        r = build(series(10, false));
        check(r.text.contains("RRULE:FREQ=WEEKLY\r\nDURATION:P1800S\r\n") && !r.text.contains("DTEND"),
                "timed series: RRULE then DURATION, no DTEND");
        // 4
        IcsExport.Row both = series(10, false);
        both.dtend = SEP1_1030;
        r = build(both);
        check(!r.text.contains("DTEND") && r.text.contains("DURATION:P1800S"),
                "timed series with a DTEND also set: no DTEND");
        // 5
        r = build(series(10, true));
        check(r.text.contains("DTSTART;VALUE=DATE:20260901\r\n") && r.text.contains("DURATION:P1D\r\n")
                && !r.text.contains("DTEND"), "all-day series: DTSTART;VALUE=DATE and DURATION P1D");
        // 6
        r = build(series(10, false), exception(11, 10, SEP8_10, 0, false));
        check(r.events == 2 && r.text.contains("EXDATE:20260908T100000Z\r\n")
                && r.text.contains("UID:11@nowhere\r\nSUMMARY:Weekly\r\nDTSTART:20260916T140000Z\r\n"
                + "DTEND:20260916T143000Z\r\n"), "moved exception: EXDATE on the series, the row at its own time");
        // 7
        r = build(series(10, false), exception(12, 10, SEP15_10, 2, false));
        check(r.events == 1 && r.text.contains("EXDATE:20260915T100000Z\r\n") && !r.text.contains("UID:12@nowhere"),
                "cancelled exception (status 2): EXDATE on the series, the row absent");
        // 8
        r = build(series(10, false), exception(13, 10, SEP15_10, 0, true));
        check(r.events == 1 && r.text.contains("EXDATE:20260915T100000Z\r\n") && !r.text.contains("UID:13@nowhere"),
                "DELETED exception: EXDATE on the series, the row absent");
        // 9
        IcsExport.Row noStart = exception(14, 10, SEP15_10, 0, true);
        noStart.dtstart = null;
        noStart.dtend = null;
        r = build(series(10, false), noStart);
        check(r.events == 1 && r.text.contains("EXDATE:20260915T100000Z\r\n"),
                "a deleted exception with no DTSTART still maps its slot");
        // 10
        IcsExport.Row del = row(15, "Gone", SEP1_10, SEP1_1030);
        del.deleted = true;
        r = build(del);
        check(r.text == null && r.events == 0, "deleted plain event: absent, nothing emitted");
        // 11
        r = build(series(10, true), exception(16, 10, SEP8_00, 0, false));
        check(r.text.contains("EXDATE;VALUE=DATE:20260908\r\n") && !r.text.contains("EXDATE:2026"),
                "all-day series' exception: EXDATE;VALUE=DATE:");
        // 12
        IcsExport.Row own = series(10, false);
        own.exdate = "20260901T100000Z,20260908T100000Z";
        r = build(own);
        check(count(r.text, "EXDATE") == 1 && r.text.contains("EXDATE:20260901T100000Z,20260908T100000Z\r\n"),
                "timed series' own exdate column: one EXDATE line");
        // 13
        own = series(10, true);
        own.exdate = "20260901,20260908";
        r = build(own);
        check(count(r.text, "EXDATE") == 1 && r.text.contains("EXDATE;VALUE=DATE:20260901,20260908\r\n")
                && !r.text.contains("EXDATE:2026"), "all-day series' own column: EXDATE;VALUE=DATE: line");
        // 14
        own = series(10, false);
        own.exdate = "20260901";
        check(!build(own).text.contains("EXDATE"), "timed series, date-only own column: skipped");
        // 15
        own = series(10, false);
        own.exdate = "TZID=Europe/Berlin;20260901T100000";
        check(!build(own).text.contains("EXDATE"), "TZID-prefixed own column: skipped");
        // 16
        own = series(10, true);
        own.exdate = "20260901T100000Z";
        check(!build(own).text.contains("EXDATE"), "all-day series, UTC-form own column: skipped");
        // 17
        r = build(row(17, "No start", null, null));
        check(r.text == null && r.events == 0, "a row with no DTSTART is skipped");
        // 18
        r = build();
        check(r.text == null && r.events == 0, "nothing emitted: text null, events 0");
        // 19
        IcsExport.Row esc = row(18, "a;b,c\\d\ne", SEP1_10, SEP1_1030);
        esc.location = "a;b,c\\d\ne";
        esc.description = "a;b,c\\d\ne";
        r = build(esc);
        String e = "a\\;b\\,c\\\\d\\ne";
        check(r.text.contains("SUMMARY:" + e + "\r\n") && r.text.contains("LOCATION:" + e + "\r\n")
                && r.text.contains("DESCRIPTION:" + e + "\r\n"), "escaping of ; , \\ and newline unchanged");
        r = build(row(19, null, SEP1_10, SEP1_1030));
        check(r.text.contains("SUMMARY:\r\n"), "a null title is an empty SUMMARY");
        // 20
        IcsExport.Row sg = row(20, "Once", SEP1_10, SEP1_1030);
        sg.exdate = "20260901T100000Z";
        sg.duration = "P1800S";
        r = build(sg);
        check(!r.text.contains("EXDATE") && !r.text.contains("DURATION"),
                "a single row writes neither DURATION nor EXDATE");
        System.out.println(failed == 0 ? "PASS" : failed + " FAILED");
        System.exit(failed == 0 ? 0 : 1);
    }
}
