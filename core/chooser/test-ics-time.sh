#!/usr/bin/env bash
# test-ics-time.sh [<Ingest.java>] [--mutate] -- the .ics date/zone rules, RUN rather than grepped.
#
# WHY THIS IS COMMITTED. NWP-20260903-24 fixed two parser defects that are invisible at import time and
# permanent afterwards:
#
#   (a) TimeZone.getTimeZone NEVER throws, so an id it does not know silently becomes GMT. Outlook and
#       Exchange emit WINDOWS zone names (TZID="W. Europe Standard Time"), so a 10:00 Berlin meeting was
#       stored as 10:00Z, rendered at 12:00, and EVENT_TIMEZONE persisted as "GMT" -- the whole recurring
#       series then expanded at the wrong hour, forever.
#   (b) all-day was decided from VALUE=DATE alone while parseIcsTime independently treats ANY 8-character
#       value as a UTC-midnight date, so a bare DTSTART:20260901 became a TIMED event at 00:00Z: the
#       PREVIOUS DAY anywhere west of UTC.
#
# ⚠ THESE ARE RUN, NOT PINNED. A source-level grep cannot tell you what a parser DOES, and both defects are
# arithmetic. So this EXTRACTS the pure methods (icsZone, icsAllDay, parseIcsTime and, since NWP-20261020-14,
# icsVTimeZones, eventZoneId and the helpers they call) straight out of Ingest.java, wraps them in a harness and runs a truth table under a real JVM. They touch java.util/java.text
# only, EXCEPT that icsZone calls windowsZoneId (NWP-20261019-17), which reaches android.icu: the harness
# cannot load that, so it defines its own stub windowsZoneId and records every call. The production
# windowsZoneId is not run; a source pin below checks it calls getIDForWindowsID and catches. Extraction rather than a copy is what keeps the tested code identical to the
# shipped code.
#
# The harness pins TimeZone.setDefault, so every expectation holds regardless of the machine's own zone.
#
#   bash test-ics-time.sh            # the truth table
#   bash test-ics-time.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Needs javac+java (PATH, else the build host's prebuilts JDK); FAILS (exit 2) without one rather than skip.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/Ingest.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-ics-time: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

# --- extraction ------------------------------------------------------------------------------------------
# Pull the methods out by their signatures. awk from the signature to the closing brace at method
# indent (4 spaces + '}'), which is unambiguous for these.
extract(){ awk "/^    (private )?static .*$1\(/,/^    \}\$/" "$SUT"; }

Z=$(extract icsZone); A=$(extract icsAllDay); P=$(extract parseIcsTime)
# NWP-20261020-14: the VTIMEZONE reader reuses properties() and what it reaches, so those come along verbatim.
V=""
for m in icsVTimeZones vtzAdd vtzLatest vtzOffsetMs vtzTimeOfDayMs vtzRule eventZoneId zonesAgree \
         properties valueColon splitParams charsetOf decodeQP unescape; do
  b=$(extract $m)
  [ -n "$b" ] || { echo "EXTRACTION FAILED -- a method signature moved in $SUT ($m)" >&2; exit 2; }
  V+="$b"$'\n'
done
for n in Z A P; do
  eval "v=\$$n"
  [ -n "$v" ] || { echo "EXTRACTION FAILED -- a method signature moved in $SUT ($n)" >&2; exit 2; }
done

# The production windowsZoneId is NOT extracted into the harness (it needs android.icu) -- only pinned.
W=$(extract windowsZoneId)
[ -n "$W" ] || { echo "EXTRACTION FAILED -- windowsZoneId moved in $SUT" >&2; exit 2; }
if [[ "$W" == *"android.icu.util.TimeZone.getIDForWindowsID("* ]]; then ok "windowsZoneId calls ICU getIDForWindowsID"
else no "windowsZoneId does not call android.icu.util.TimeZone.getIDForWindowsID("; fi
if [[ "$W" == *"catch (Throwable"* ]]; then ok "windowsZoneId catches Throwable (ICU failure degrades)"
else no "windowsZoneId does not catch Throwable"; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
{
  echo 'import java.util.*;'
  echo 'public class IcsT {'
  echo "$Z"
  echo "$A"
  echo "$P"
  echo "$V"
  cat <<'JAVA'
    // Stub for the production windowsZoneId (android.icu is not loadable here); records every call.
    static final java.util.List<String> calls = new java.util.ArrayList<>();
    static String windowsZoneId(String w) {
        calls.add(w);
        switch (w) {
            case "W. Europe Standard Time": return "Europe/Berlin";
            case "Eastern Standard Time": return "America/New_York";
            case "Bogus Zone": return "Not/AZone";
            default: return null;
        }
    }
    static final Map<String, TimeZone> NOVTZ = new HashMap<>();
    // The pre-VTIMEZONE two-argument shape, so the original truth table reads unchanged.
    static TimeZone icsZone2(String id) { return icsZone(id, NOVTZ); }
    static long utc(String z) { return parseIcsTime(new String[]{z, "", ""}, false, NOVTZ); }
    // A VTIMEZONE with one DAYLIGHT and one STANDARD component (offsets in iCalendar form).
    static String vtz(String id, String std, String dst, String dstStart, String dstRule, String stdStart, String stdRule) {
        return "BEGIN:VCALENDAR\nBEGIN:VTIMEZONE\nTZID:" + id + "\n"
             + "BEGIN:DAYLIGHT\nTZOFFSETFROM:" + std + "\nTZOFFSETTO:" + dst + "\nDTSTART:" + dstStart + "\nRRULE:" + dstRule + "\nEND:DAYLIGHT\n"
             + "BEGIN:STANDARD\nTZOFFSETFROM:" + dst + "\nTZOFFSETTO:" + std + "\nDTSTART:" + stdStart + "\nRRULE:" + stdRule + "\nEND:STANDARD\n"
             + "END:VTIMEZONE\nEND:VCALENDAR\n";
    }
    static int fails = 0;
    static void eq(String what, Object got, Object want) {
        if (!String.valueOf(got).equals(String.valueOf(want))) {
            System.out.println("FAIL " + what + ": got " + got + ", want " + want);
            fails++;
        } else System.out.println("ok   " + what);
    }
    public static void main(String[] a) {
        // Pin the "device" zone so every expectation below is machine-independent.
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"));

        // (a) an unknown TZID must NOT become GMT
        eq("a known Windows name resolves to its IANA zone",
           icsZone2("W. Europe Standard Time").getID(), "Europe/Berlin");
        eq("a Windows name is trimmed before the lookup",
           icsZone2("  Eastern Standard Time ").getID(), "America/New_York");
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Tokyo"));
        eq("an unknown name (neither IANA nor Windows) falls back to the device zone",
           icsZone2("Not A Zone").getID(), "Asia/Tokyo");
        eq("a resolver answer that does not itself resolve falls back to the device zone, not GMT",
           icsZone2("Bogus Zone").getID(), "Asia/Tokyo");
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"));
        calls.clear();
        eq("a real zone still resolves", icsZone2("Europe/Berlin").getID(), "Europe/Berlin");
        eq("an IANA id never reaches the Windows resolver", calls.toString(), "[]");
        eq("empty TZID is floating local time", icsZone2("").getID(), "America/New_York");
        // ... and a genuinely-GMT id must NOT be mistaken for a failure
        eq("literal GMT stays GMT", icsZone2("GMT").getID(), "GMT");
        eq("literal Z stays GMT", icsZone2("Z").getID(), "GMT");
        eq("GMT and Z never reach the Windows resolver", calls.toString(), "[]");
        eq("UTC is a real zone, not a failure", icsZone2("UTC").getID(), "UTC");
        eq("custom offset survives", icsZone2("GMT+05:00").getRawOffset(), 18000000);

        // (b) all-day is decided by the VALUE *or* the 8-char shape
        eq("VALUE=DATE is all-day", icsAllDay(new String[]{"20260901", "", "DATE"}), true);
        eq("a bare yyyyMMdd is all-day too", icsAllDay(new String[]{"20260901", "", ""}), true);
        eq("a timed value is not all-day", icsAllDay(new String[]{"20260901T100000", "", ""}), false);
        eq("a UTC timed value is not all-day", icsAllDay(new String[]{"20260901T100000Z", "", ""}), false);

        // the arithmetic that actually reaches the user
        long berlin = parseIcsTime(new String[]{"20260901T100000", "Europe/Berlin", ""}, false, NOVTZ);
        long windows = parseIcsTime(new String[]{"20260901T100000", "Not A Zone", ""}, false, NOVTZ);
        long utcTen = parseIcsTime(new String[]{"20260901T100000Z", "", ""}, false, NOVTZ);
        eq("an unknown TZID no longer parses as 10:00Z", windows == utcTen, false);
        long local = parseIcsTime(new String[]{"20260901T100000", "", ""}, false, NOVTZ);
        eq("an unknown TZID reads as the local wall-clock time the user typed", windows, local);
        eq("a known TZID is unaffected by the fallback", berlin == utcTen - 2 * 3600_000L, true);
        long winBerlin = parseIcsTime(new String[]{"20260901T100000", "W. Europe Standard Time", ""}, false, NOVTZ);
        eq("a Windows TZID parses at Berlin wall clock (10:00 CEST = 08:00Z)", winBerlin, utcTen - 2 * 3600_000L);

        // a bare date lands at UTC midnight AND is flagged all-day, so it cannot slip a day west of UTC
        String[] bare = new String[]{"20260901", "", ""};
        eq("a bare date parses as UTC midnight",
           parseIcsTime(bare, icsAllDay(bare), NOVTZ), 1788220800000L);

        // ---- NWP-20261020-14: a TZID defined only by the file's own VTIMEZONE
        final String NAME = "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna";
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"));
        String eu = vtz(NAME, "+0100", "+0200", "19700329T020000", "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU",
                              "19701025T030000", "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU");
        Map<String, TimeZone> m1 = icsVTimeZones(eu);
        calls.clear();
        long jul = parseIcsTime(new String[]{"20260715T100000", NAME, ""}, false, m1);
        long jan = parseIcsTime(new String[]{"20260115T100000", NAME, ""}, false, m1);
        eq("(1) a display-name TZID from the file's VTIMEZONE: July 10:00 is 08:00Z", jul, utc("20260715T080000Z"));
        eq("(1) ... and January 10:00 is 09:00Z", jan, utc("20260115T090000Z"));
        eq("(1) ... the Windows resolver was asked about the name and answered null", calls.toString(), "[" + NAME + ", " + NAME + "]");
        eq("(1) the 2026 spring transition is the last Sunday of March (29th, 01:00Z)",
           m1.get(NAME).getOffset(utc("20260329T005959Z")) + "/" + m1.get(NAME).getOffset(utc("20260329T010000Z")),
           "3600000/7200000");
        eq("(1b) INTERVAL=1 and any part order give the same answers",
           parseIcsTime(new String[]{"20260715T100000", NAME, ""}, false, icsVTimeZones(
               vtz(NAME, "+0100", "+0200", "19700329T020000", "FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3",
                         "19701025T030000", "FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10").replace("\n", "\r\n"))),
           utc("20260715T080000Z"));
        eq("(2) STANDARD only +0530 is a fixed offset: 10:00 is 04:30Z",
           parseIcsTime(new String[]{"20260715T100000", "Custom India", ""}, false, icsVTimeZones(
               "BEGIN:VTIMEZONE\nTZID:Custom India\nBEGIN:STANDARD\nDTSTART:19700101T000000\nTZOFFSETFROM:+0530\nTZOFFSETTO:+0530\nEND:STANDARD\nEND:VTIMEZONE\n")),
           utc("20260715T043000Z"));
        TimeZone.setDefault(TimeZone.getTimeZone("Europe/London"));
        Map<String, TimeZone> us = icsVTimeZones(vtz("Custom US", "-0500", "-0400", "19700308T020000", "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
                                                      "19701101T020000", "FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"));
        eq("(3) second-Sunday rule: 10:00 on 2026-03-07 (before the 8th) is 15:00Z",
           parseIcsTime(new String[]{"20260307T100000", "Custom US", ""}, false, us), utc("20260307T150000Z"));
        eq("(3) ... and on 2026-03-09 it is 14:00Z",
           parseIcsTime(new String[]{"20260309T100000", "Custom US", ""}, false, us), utc("20260309T140000Z"));
        eq("(3) ... the first-Sunday-of-November end: 10:00 on 2026-11-01 is 15:00Z",
           parseIcsTime(new String[]{"20261101T100000", "Custom US", ""}, false, us), utc("20261101T150000Z"));
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Tokyo"));
        String rdate = "BEGIN:VTIMEZONE\nTZID:Rdate Zone\nBEGIN:STANDARD\nDTSTART:19701025T030000\nTZOFFSETFROM:+0200\nTZOFFSETTO:+0100\nRDATE:20261025T030000\nEND:STANDARD\n"
                     + "BEGIN:DAYLIGHT\nDTSTART:19700329T020000\nTZOFFSETFROM:+0100\nTZOFFSETTO:+0200\nRDATE:20260329T020000\nEND:DAYLIGHT\nEND:VTIMEZONE\n";
        eq("(4) an RDATE-only VTIMEZONE yields no entry", icsVTimeZones(rdate).containsKey("Rdate Zone"), false);
        Map<String, TimeZone> until = icsVTimeZones(vtz("Until Zone", "+0100", "+0200", "19700329T020000",
                "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU;UNTIL=20060101T000000Z", "19701025T030000", "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"));
        eq("(4) a rule carrying UNTIL yields no entry", until.containsKey("Until Zone"), false);
        eq("(4) ... and the TZID falls back to the device zone", icsZone("Until Zone", until).getID(), "Asia/Tokyo");
        for (String bad : new String[]{"+0160", "+010060", "+2400", "+0100:"}) {
            Map<String, TimeZone> m = icsVTimeZones(vtz("Bad Off", bad, bad, "19700329T020000", "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU", "19701025T030000", "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"));
            eq("(4) a malformed offset " + bad + " yields no entry", m.containsKey("Bad Off"), false);
        }
        TimeZone.setDefault(TimeZone.getTimeZone("America/New_York"));
        Map<String, TimeZone> wrong = new HashMap<>();
        wrong.put("Europe/Berlin", new java.util.SimpleTimeZone(5 * 3600_000, "Europe/Berlin"));
        wrong.put("W. Europe Standard Time", new java.util.SimpleTimeZone(9 * 3600_000, "W. Europe Standard Time"));
        eq("(5) a map entry under an IANA id is ignored (IANA wins)", icsZone("Europe/Berlin", wrong).getRawOffset(), 3600_000);
        eq("(5) a map entry under a Windows name is ignored (the resolver wins)", icsZone("W. Europe Standard Time", wrong).getID(), "Europe/Berlin");
        String two = "BEGIN:VTIMEZONE\nTZID:Two Std\nBEGIN:STANDARD\nDTSTART:20000101T000000\nTZOFFSETFROM:+0100\nTZOFFSETTO:+0300\nEND:STANDARD\n"
                   + "BEGIN:STANDARD\nDTSTART:19700101T000000\nTZOFFSETFROM:+0100\nTZOFFSETTO:+0100\nEND:STANDARD\nEND:VTIMEZONE\n";
        eq("(6) of two STANDARD components the later DTSTART wins", icsVTimeZones(two).get("Two Std").getRawOffset(), 3 * 3600_000);
        // (7) the id stored as EVENT_TIMEZONE
        TimeZone cz = m1.get(NAME);
        long at = utc("20260715T080000Z");
        String id7 = eventZoneId(cz, at);
        eq("(7) eventZoneId is not the custom name", id7.equals(NAME), false);
        TimeZone r7 = TimeZone.getTimeZone(id7);
        boolean same = id7.indexOf('/') > 0;
        for (long t = at - 400L * 86400_000L; t <= at + 400L * 86400_000L; t += 3600_000L)
            if (r7.getOffset(t) != TimeZone.getTimeZone("Europe/Berlin").getOffset(t)) same = false;
        eq("(7) ... it is an id whose offsets equal Europe/Berlin's over the window (" + id7 + ")", same, true);
        TimeZone.setDefault(TimeZone.getTimeZone("Europe/Berlin"));
        eq("(7) ... the device default's id when the default itself matches", eventZoneId(cz, at), "Europe/Berlin");
        eq("(7) a zone the platform knows keeps its own id", eventZoneId(TimeZone.getTimeZone("Asia/Tokyo"), at), "Asia/Tokyo");
        eq("(8) a body with no VTIMEZONE gives an empty map",
           icsVTimeZones("BEGIN:VCALENDAR\nBEGIN:VEVENT\nDTSTART:20260901T100000\nEND:VEVENT\nEND:VCALENDAR\n").isEmpty(), true);

        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA
} > "$T/IcsT.java"

if ! "$JAVAC" -d "$T" "$T/IcsT.java" 2>"$T/javac.err"; then
  echo "  FAIL  the extracted methods do not compile:"; sed 's/^/        /' "$T/javac.err" | head -12
  echo; echo "passed $PASS, failed 1"; exit 1
fi

OUT=$("$JAVA" -cp "$T" IcsT 2>&1); RC=$?
while IFS= read -r line; do
  case "$line" in
    ok*)   ok "${line#ok   }" ;;
    FAIL*) no "${line#FAIL }" ;;
    *)     [ -n "$line" ] && echo "        $line" ;;
  esac
done <<< "$OUT"
[ "$RC" = 0 ] || true

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d); trap 'rm -rf "$T" "$M"' EXIT
  mutate(){
    sed "$2" "$SUT" > "$M/Ingest.java" 2>/dev/null
    if cmp -s "$SUT" "$M/Ingest.java"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/Ingest.java" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "the filed bug (a): an unresolved TZID becomes GMT again" \
         's#^        return java.util.TimeZone.getDefault();$#        return z;#'
  mutate "the filed bug (b): all-day is VALUE=DATE only again" \
         's#return "DATE".equals(d\[2\]) || d\[0\].length() == 8;#return "DATE".equals(d[2]);#'
  mutate "a genuinely-GMT id is misread as a failure (GMT events shift to the device zone)" \
         's#if ("GMT".equalsIgnoreCase(u) || "Z".equalsIgnoreCase(u)) return z;##'
  mutate "icsZone never consults windowsZoneId (Windows names float again)" \
         's#String win = windowsZoneId(u);#String win = null;#'
  mutate "windowsZoneId is consulted before the direct lookup (IANA ids reach the resolver)" \
         's#java.util.TimeZone z = java.util.TimeZone.getTimeZone(id);#String pre = windowsZoneId(id.trim()); java.util.TimeZone z = java.util.TimeZone.getTimeZone(pre != null ? pre : id);#'
  mutate "a resolver answer is accepted without resolving it (Bogus answer becomes GMT)" \
         's#if (!"GMT".equals(w.getID())) return w;#return w;#'
  mutate "the production windowsZoneId stops calling ICU getIDForWindowsID" \
         's#getIDForWindowsID(#getIDForWindowsIDX(#'
  mutate "icsZone skips the VTIMEZONE lookup (a custom TZID floats again)" \
         's#java.util.TimeZone c = vtz == null ? null : vtz.get(u);#java.util.TimeZone c = null;#'
  mutate "BYDAY=-1 is read as day 1 (the first Sunday, not the last)" \
         's#"-1".equals(m.group(1)) ? -1 :#"-1".equals(m.group(1)) ? 1 :#'
  mutate "dstSavings sign flipped" \
         's#int saving = dstOff - stdOff;#int saving = stdOff - dstOff;#'
  mutate "the EARLIEST component is kept instead of the latest" \
         's#dt.compareTo(best\[0\]) > 0#dt.compareTo(best[0]) < 0#'
  mutate "the VTIMEZONE map is consulted BEFORE the IANA lookup (a file redefines Europe/Berlin)" \
         's#java.util.TimeZone z = java.util.TimeZone.getTimeZone(id);#java.util.TimeZone vz = vtz == null ? null : vtz.get(id.trim()); if (vz != null) return vz; java.util.TimeZone z = java.util.TimeZone.getTimeZone(id);#'
  mutate "INTERVAL=1 is refused (Outlook's own rule shape floats)" \
         's#k.equals("INTERVAL") \&\& v.equals("1")#k.equals("INTERVAL") \&\& false#'
  mutate "eventZoneId returns the zone's own id unconditionally (CalendarProvider gets the custom name)" \
         's#if (java.util.TimeZone.getTimeZone(id).getID().equals(id)) return id;#if (true) return id;#'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
