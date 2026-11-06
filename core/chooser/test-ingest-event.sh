#!/usr/bin/env bash
# test-ingest-event.sh [<Ingest.java>] [--mutate] -- Ingest.insertEvent's EXDATE carry, RUN rather than compiled.
#
# WHY THIS IS COMMITTED. Deleted occurrences of a recurring series were resurrecting because insertEvent
# discarded the EXDATE the extractor deliberately emits (the extractor emits an EXDATE on the parent for every
# exception row and SKIPS the cancelled row itself). The fix -- `case "EXDATE":` accumulating each property's
# comma list, and Events.EXDATE put, comma-joined, inside the RRULE branch only -- was verified by compiling
# Ingest.java against the system API jar. Compiling proves the symbols resolve; delete the case or the put and
# it still compiles, and nothing off-device noticed.
#
# So insertEvent is LIFTED verbatim out of Ingest.java together with every helper it calls (`private`
# stripped, brace-matched like test-ingest-key.sh), compiled against small stubs of the Android classes it
# touches (android.content / provider / net / text / util / icu.util), and RUN. The stub ContentResolver.insert
# records the ContentValues it is handed, so the assertions are on what the provider would have received.
# icsZone calls windowsZoneId (NWP-20261019-17), which reaches android.icu.util.TimeZone.getIDForWindowsID; the
# stub answers null (no Windows zone), so every TZID here takes the direct-lookup or device-zone path. The
# Windows mapping itself is test-ics-time.sh's.
#
# What this does NOT prove: that CalendarProvider2 expands the series without the deleted slot. That is the
# device step left on the backlog row ("The EXDATE fix is built and compiled, never run").
#
#   bash test-ingest-event.sh              # the cases
#   bash test-ingest-event.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/src/com/nowhere/chooser/Ingest.java"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; else SUT="$a"; fi
done
[ -f "$SUT" ] || { echo "test-ingest-event: FAIL -- no such file: $SUT"; exit 2; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-ingest-event: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

SIGS=(
  'private static boolean insertEvent('
  'private static String[] dateParam('
  'private static java.util.TimeZone icsZone('
  'static java.util.Map<String, java.util.TimeZone> icsVTimeZones('
  'private static void vtzAdd('
  'private static String[] vtzLatest('
  'private static Integer vtzOffsetMs('
  'private static int vtzTimeOfDayMs('
  'private static int[] vtzRule('
  'static String eventZoneId('
  'private static boolean zonesAgree('
  'private static String windowsZoneId('
  'private static boolean icsAllDay('
  'private static long parseIcsTime('
  'private static long parseIcsDuration('
  'private static List<String[]> properties('
  'private static int valueColon('
  'private static List<String> splitParams('
  'private static String charsetOf('
  'private static String decodeQP('
  'private static String unescape('
  'private static Uri syncAdapterAccount('
)

extract() { # extract <file> <signature-fragment>
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('UNBALANCED: ' + sys.argv[2] + '\n'); sys.exit(1)
PY
}

lift() { # lift <Ingest.java> -> $WORK/Lifted.java, every member present or return 1
  local src="$1" sig body
  {
    echo 'import android.content.ContentValues;'
    echo 'import android.content.Context;'
    echo 'import android.net.Uri;'
    echo 'import android.provider.CalendarContract;'
    echo 'import java.util.*;'
    echo 'final class Lifted {'
    for sig in "${SIGS[@]}"; do
      body=$(extract "$src" "$sig") || return 1
      [ -n "$body" ] || return 1
      printf '%s\n\n' "${body#private }"
    done
    echo '}'
  } > "$WORK/Lifted.java"
}

# ---- the Android stubs: only what the lifted members touch.
mkdir -p "$WORK/stubs/android/content" "$WORK/stubs/android/provider" "$WORK/stubs/android/net" \
         "$WORK/stubs/android/text" "$WORK/stubs/android/util" "$WORK/stubs/android/icu/util"
cat > "$WORK/stubs/android/icu/util/TimeZone.java" <<'JAVA'
package android.icu.util;
public class TimeZone {
  public static String getIDForWindowsID(String winid, String region) { return null; }
}
JAVA
cat > "$WORK/stubs/android/content/ContentValues.java" <<'JAVA'
package android.content;
import java.util.LinkedHashMap;
import java.util.Map;
public class ContentValues {
  public final Map<String, Object> m = new LinkedHashMap<>();
  public void put(String k, String v) { m.put(k, v); }
  public void put(String k, Long v) { m.put(k, v); }
  public void put(String k, Integer v) { m.put(k, v); }
  public boolean containsKey(String k) { return m.containsKey(k); }
  public Object get(String k) { return m.get(k); }
}
JAVA
cat > "$WORK/stubs/android/content/ContentResolver.java" <<'JAVA'
package android.content;
import android.net.Uri;
import java.util.ArrayList;
import java.util.List;
public class ContentResolver {
  public final List<ContentValues> inserted = new ArrayList<>();
  public Uri insert(Uri u, ContentValues v) { inserted.add(v); return Uri.parse("content://stub/events/1"); }
}
JAVA
cat > "$WORK/stubs/android/content/Context.java" <<'JAVA'
package android.content;
public class Context {
  private final ContentResolver r = new ContentResolver();
  public ContentResolver getContentResolver() { return r; }
}
JAVA
cat > "$WORK/stubs/android/net/Uri.java" <<'JAVA'
package android.net;
public class Uri {
  private final String s;
  private Uri(String s) { this.s = s; }
  public static Uri parse(String s) { return new Uri(s); }
  public Builder buildUpon() { return new Builder(s); }
  public String toString() { return s; }
  public static class Builder {
    private final StringBuilder b;
    private boolean q;
    Builder(String s) { b = new StringBuilder(s); q = s.indexOf('?') >= 0; }
    public Builder appendQueryParameter(String k, String v) { b.append(q ? '&' : '?').append(k).append('=').append(v); q = true; return this; }
    public Uri build() { return new Uri(b.toString()); }
  }
}
JAVA
cat > "$WORK/stubs/android/provider/CalendarContract.java" <<'JAVA'
package android.provider;
import android.net.Uri;
public class CalendarContract {
  public static final String CALLER_IS_SYNCADAPTER = "caller_is_syncadapter";
  public static final String ACCOUNT_TYPE_LOCAL = "LOCAL";
  public static class Calendars {
    public static final String ACCOUNT_NAME = "account_name";
    public static final String ACCOUNT_TYPE = "account_type";
    public static final Uri CONTENT_URI = Uri.parse("content://stub/calendars");
  }
  public static class Events {
    public static final Uri CONTENT_URI = Uri.parse("content://stub/events");
    public static final String CALENDAR_ID = "calendar_id", TITLE = "title", EVENT_LOCATION = "eventLocation",
        DESCRIPTION = "description", DTSTART = "dtstart", DTEND = "dtend", ALL_DAY = "allDay",
        EVENT_TIMEZONE = "eventTimezone", UID_2445 = "uid2445", RRULE = "rrule", DURATION = "duration",
        EXDATE = "exdate";
  }
}
JAVA
cat > "$WORK/stubs/android/text/TextUtils.java" <<'JAVA'
package android.text;
public class TextUtils {
  public static String join(CharSequence d, Iterable<?> parts) {
    StringBuilder b = new StringBuilder();
    for (Object p : parts) { if (b.length() > 0) b.append(d); b.append(p); }
    return b.toString();
  }
}
JAVA
cat > "$WORK/stubs/android/util/Log.java" <<'JAVA'
package android.util;
public class Log {
  public static int w(String tag, String msg, Throwable t) { return 0; }
}
JAVA

cat > "$WORK/Cases.java" <<'JAVA'
import android.content.ContentValues;
import android.content.Context;

public class Cases {
  static int fails = 0;
  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }
  static ContentValues run(String raw) { return run(raw, new java.util.HashMap<String, java.util.TimeZone>()); }
  static ContentValues run(String raw, java.util.Map<String, java.util.TimeZone> vtz) {
    Context ctx = new Context();
    boolean ok = Lifted.insertEvent(ctx, 7L, raw, "key", vtz);
    if (!ok || ctx.getContentResolver().inserted.size() != 1) return null;
    return ctx.getContentResolver().inserted.get(0);
  }
  static void exdate(String what, String raw, String want) { // want == null: the key must be absent
    ContentValues v = run(raw);
    if (v == null) { check(what, false, "insertEvent did not insert exactly one row"); return; }
    Object got = v.get("exdate");
    check(what, want == null ? !v.containsKey("exdate") : want.equals(got),
          "got " + (v.containsKey("exdate") ? "\"" + got + "\"" : "no EXDATE key") + ", want "
              + (want == null ? "no EXDATE key" : "\"" + want + "\""));
  }
  static final String HEAD = "SUMMARY:Standup\nDTSTART:20261001T100000Z\nDTEND:20261001T103000Z\n";

  public static void main(String[] a) {
    exdate("two EXDATE properties, one a comma list -> joined in order",
        HEAD + "RRULE:FREQ=DAILY;COUNT=5\nEXDATE:20261002T100000Z\nEXDATE:20261003T100000Z,20261004T100000Z\n",
        "20261002T100000Z,20261003T100000Z,20261004T100000Z");
    exdate("all-day EXDATE;VALUE=DATE passes through",
        "SUMMARY:Holiday\nDTSTART;VALUE=DATE:20261001\nDTEND;VALUE=DATE:20261002\nRRULE:FREQ=DAILY;COUNT=5\n"
            + "EXDATE;VALUE=DATE:20261003\n",
        "20261003");
    exdate("empty comma items are dropped",
        HEAD + "RRULE:FREQ=DAILY;COUNT=5\nEXDATE:20261002T100000Z,, 20261003T100000Z ,\n",
        "20261002T100000Z,20261003T100000Z");
    exdate("an EXDATE of only empty items sets no key",
        HEAD + "RRULE:FREQ=DAILY;COUNT=5\nEXDATE:,\n", null);
    exdate("recurring without EXDATE -> no key",
        HEAD + "RRULE:FREQ=DAILY;COUNT=5\n", null);

    ContentValues single = run(HEAD + "EXDATE:20261002T100000Z\n");
    check("non-recurring with EXDATE -> no EXDATE key",
        single != null && !single.containsKey("exdate"), "single event carried EXDATE");
    check("non-recurring with EXDATE -> DTEND set, no RRULE/DURATION",
        single != null && single.containsKey("dtend") && !single.containsKey("rrule")
            && !single.containsKey("duration"), "single event shape wrong");
    ContentValues rec = run(HEAD + "RRULE:FREQ=DAILY;COUNT=5\nEXDATE:20261002T100000Z\n");
    check("recurring carries RRULE and DURATION, not DTEND",
        rec != null && rec.containsKey("rrule") && rec.containsKey("duration") && !rec.containsKey("dtend"),
        "recurring shape wrong");

    // NWP-20261020-14: a TZID defined only by the file's own VTIMEZONE. 10:00 in a +0100/+0200 zone named by a
    // display string is 08:00Z in July, and the stored EVENT_TIMEZONE must be an id CalendarProvider resolves.
    java.util.TimeZone.setDefault(java.util.TimeZone.getTimeZone("America/New_York"));
    String name = "(UTC+01:00) Amsterdam, Berlin, Bern, Rome, Stockholm, Vienna";
    String file = "BEGIN:VCALENDAR\nBEGIN:VTIMEZONE\nTZID:" + name + "\n"
        + "BEGIN:DAYLIGHT\nTZOFFSETFROM:+0100\nTZOFFSETTO:+0200\nDTSTART:19700329T020000\nRRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU\nEND:DAYLIGHT\n"
        + "BEGIN:STANDARD\nTZOFFSETFROM:+0200\nTZOFFSETTO:+0100\nDTSTART:19701025T030000\nRRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU\nEND:STANDARD\n"
        + "END:VTIMEZONE\nEND:VCALENDAR\n";
    ContentValues custom = run("SUMMARY:Sync\nDTSTART;TZID=\"" + name + "\":20260715T100000\nDTEND;TZID=\"" + name
        + "\":20260715T110000\n", Lifted.icsVTimeZones(file));
    check("a VTIMEZONE-defined TZID records DTSTART at its own instant (08:00Z)",
        custom != null && Long.valueOf(1784102400000L).equals(custom.get("dtstart")),
        "got " + (custom == null ? "no row" : String.valueOf(custom.get("dtstart"))));
    check("... and DTEND an hour later",
        custom != null && Long.valueOf(1784106000000L).equals(custom.get("dtend")),
        "got " + (custom == null ? "no row" : String.valueOf(custom.get("dtend"))));
    check("... and an EVENT_TIMEZONE that is not the file's custom name",
        custom != null && custom.get("eventTimezone") != null && !name.equals(custom.get("eventTimezone"))
            && java.util.TimeZone.getTimeZone((String) custom.get("eventTimezone")).getID().equals(custom.get("eventTimezone")),
        "got " + (custom == null ? "no row" : String.valueOf(custom.get("eventTimezone"))));

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA

suite() { # suite <Ingest.java> [quiet]  -> 0 pass, 1 cases failed, 2 would not lift/compile
  rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  lift "$1" || { [ "${2:-}" = quiet ] || echo "extract failed"; return 2; }
  "$JAVAC" -nowarn -d "$WORK/out" $(find "$WORK/stubs" -name '*.java') "$WORK/Lifted.java" "$WORK/Cases.java" \
      2>"$WORK/javac.err" \
    || { [ "${2:-}" = quiet ] || { echo "compile failed:"; head -8 "$WORK/javac.err"; }; return 2; }
  if [ "${2:-}" = quiet ]; then "$JAVA" -cp "$WORK/out" Cases >/dev/null 2>&1; else "$JAVA" -cp "$WORK/out" Cases; fi
}

suite "$SUT"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <sed expr>... -- a mutant that does not change the file counts as a failure
  local label="$1" m="$WORK/mut.java"; shift
  local args=(); for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then printf '  ⚠ NOT APPLIED  %s\n' "$label"; MRC=1; return; fi
  if suite "$m" quiet; then printf '  ⚠ SURVIVED  %s\n' "$label"; MRC=1
  else printf '  convicted   %s\n' "$label"; fi
}
mutant 'case "EXDATE" arm deleted (falls to default)'  's|case "EXDATE":|case "EXDATE_GONE":|'
mutant 'empty-item filter dropped'                      's|if (!t.isEmpty()) exDates.add(t);|exDates.add(t);|'
mutant 'EXDATE put moved outside the rrule branch' \
  's|if (!exDates.isEmpty()) {|if (false) {|' \
  's|if (rrule != null \&\& !rrule.isEmpty()) {|if (!exDates.isEmpty()) v.put(CalendarContract.Events.EXDATE, android.text.TextUtils.join(",", exDates)); if (rrule != null \&\& !rrule.isEmpty()) {|'
mutant "EXDATE joined with ';'"                         's|TextUtils.join(",", exDates)|TextUtils.join(";", exDates)|'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
