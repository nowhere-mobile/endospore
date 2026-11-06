package com.nowhere.chooser;

/**
 * NWP-20261109-03: the rows -> iCalendar rules of "Export a copy"'s calendar.ics.
 *
 * <p>A RECURRING Events row carries its length in DURATION and has DTEND null (Ingest.insertEvent says so), so a
 * series exported with DTSTART + RRULE alone is zero-length to RFC 5545 and one hour to our own importer. A moved or
 * cancelled occurrence is its own row (ORIGINAL_ID + ORIGINAL_INSTANCE_TIME); it must become an EXDATE on the series,
 * or the moved occurrence shows at BOTH times and a deleted one resurrects -- the cost NWP-20260827-25 recorded on the
 * import side (Ingest.insertEvent). This mirrors nowhere-cloud cmd/storefront/assets/importtext.mjs buildIcs (the USB
 * extractor), plus the series' own EXDATE column, which buildIcs does not carry. The exception map is built from EVERY
 * row, deleted ones included: a deleted exception row is how a cancelled occurrence is recorded.
 *
 * <p>A date-only EXDATE needs VALUE=DATE: RFC 5545 types EXDATE as DATE-TIME by default and the type must match
 * DTSTART's, so a bare yyyyMMdd on an all-day series is either rejected or excludes nothing. The series' own column is
 * written only when it is already in the series' form; a TZID-prefixed value, or one of the other form, is skipped
 * rather than guessed.
 *
 * <p>Pure java.* -- no Android -- so core/vendor-common/bin/test-ics-export-java.sh executes it.
 */
final class IcsExport {
    private IcsExport() {}

    /** One CalendarContract.Events row, as buildCalendarICal read it. null = the column was absent or NULL. */
    static final class Row {
        long id;
        String title;
        Long dtstart;
        Long dtend;
        String location;
        String description;
        boolean allDay;
        String rrule;
        String duration;
        String exdate;              // the provider's own EXDATE column
        Long originalId;            // null = not an exception
        Long originalInstanceTime;
        boolean deleted;
        int status;
    }

    static final class Result {
        final String text;          // null when no event was emitted
        final int events;

        Result(String text, int events) {
            this.text = text;
            this.events = events;
        }
    }

    static final int STATUS_CANCELED = 2; // CalendarContract.Events.STATUS_CANCELED
    private static final java.util.regex.Pattern EXDATE_DATES =
            java.util.regex.Pattern.compile("^[0-9]{8}(,[0-9]{8})*$");
    private static final java.util.regex.Pattern EXDATE_UTC =
            java.util.regex.Pattern.compile("^[0-9]{8}T[0-9]{6}Z(,[0-9]{8}T[0-9]{6}Z)*$");

    static Result build(java.util.List<Row> rows) {
        // From EVERY row, deleted ones included -- the buildIcs rule.
        java.util.Map<Long, java.util.List<Long>> slots = new java.util.HashMap<>();
        for (Row r : rows) {
            if (r.originalId != null && r.originalInstanceTime != null) {
                slots.computeIfAbsent(r.originalId, k -> new java.util.ArrayList<>()).add(r.originalInstanceTime);
            }
        }
        StringBuilder ics = new StringBuilder();
        ics.append("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//nowhere//export//EN\r\nCALSCALE:GREGORIAN\r\n");
        int n = 0;
        for (Row r : rows) {
            if (r.deleted || r.dtstart == null || r.status == STATUS_CANCELED) continue;
            boolean recurring = r.rrule != null && !r.rrule.isEmpty();
            ics.append("BEGIN:VEVENT\r\nUID:").append(r.id).append("@nowhere\r\n");
            ics.append("SUMMARY:").append(icalEscape(r.title)).append("\r\n");
            if (r.allDay) {
                ics.append("DTSTART;VALUE=DATE:").append(icalDate(r.dtstart)).append("\r\n");
                if (!recurring && r.dtend != null) {
                    ics.append("DTEND;VALUE=DATE:").append(icalDate(r.dtend)).append("\r\n");
                }
            } else {
                ics.append("DTSTART:").append(icalUtc(r.dtstart)).append("\r\n");
                if (!recurring && r.dtend != null) {
                    ics.append("DTEND:").append(icalUtc(r.dtend)).append("\r\n");
                }
            }
            if (r.location != null && !r.location.isEmpty()) {
                ics.append("LOCATION:").append(icalEscape(r.location)).append("\r\n");
            }
            if (r.description != null && !r.description.isEmpty()) {
                ics.append("DESCRIPTION:").append(icalEscape(r.description)).append("\r\n");
            }
            if (recurring) {
                ics.append("RRULE:").append(r.rrule).append("\r\n");
                if (r.duration != null && !r.duration.isEmpty()) {
                    ics.append("DURATION:").append(r.duration).append("\r\n");
                }
                java.util.List<Long> ex = slots.get(r.id);
                if (ex != null) {
                    for (long t : ex) {
                        ics.append(r.allDay ? "EXDATE;VALUE=DATE:" + icalDate(t) : "EXDATE:" + icalUtc(t))
                                .append("\r\n");
                    }
                }
                String own = r.exdate;
                if (own != null) {
                    if (r.allDay && EXDATE_DATES.matcher(own).matches()) {
                        ics.append("EXDATE;VALUE=DATE:").append(own).append("\r\n");
                    } else if (!r.allDay && EXDATE_UTC.matcher(own).matches()) {
                        ics.append("EXDATE:").append(own).append("\r\n");
                    }
                }
            }
            ics.append("END:VEVENT\r\n");
            n++;
        }
        ics.append("END:VCALENDAR\r\n");
        return n == 0 ? new Result(null, 0) : new Result(ics.toString(), n);
    }

    static String icalUtc(long millis) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", java.util.Locale.US);
        f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return f.format(new java.util.Date(millis));
    }

    static String icalDate(long millis) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyyMMdd", java.util.Locale.US);
        f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return f.format(new java.util.Date(millis));
    }

    /** RFC 5545 text escaping for SUMMARY/LOCATION/DESCRIPTION values. */
    static String icalEscape(String s) {
        if (s == null) return "";
        return s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,")
                .replace("\r\n", "\\n").replace("\n", "\\n").replace("\r", "\\n");
    }
}
