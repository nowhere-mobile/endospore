#!/usr/bin/env bash
# test-ingest-text.sh [<Ingest.java>] [--mutate] -- Ingest's shared text plumbing, RUN rather than grepped.
#
# WHY THIS IS COMMITTED (NWP-20261011-69). Every contact and every calendar event the web import ingests passes
# through the same eleven pure text helpers in Ingest.java before it reaches a provider: splitBlocks cuts the
# file into VCARD/VEVENT blocks, properties unfolds and decodes them, valueColon/splitParams/charsetOf/decodeQP
# read one property line, splitStructured/unescape/normalizeDate read vCard values, and dateParam/
# parseIcsDuration read the iCalendar timing. Each is string plumbing where a defect looks like working code:
# a VALARM's DESCRIPTION overwriting the event's, a quoted TZID's ':' taken as the value separator, a QP soft
# break left as a literal '='. Nothing ran them off a device.
#
# Like test-ics-time.sh and test-ingest-key.sh (which lift OTHER members of the same file -- icsZone/icsAllDay/
# parseIcsTime, and VCardEntry/normalisePhone/the identity key -- and whose cases are not repeated here), the
# methods are EXTRACTED verbatim by signature, so the tested code is the shipped code; `private` is stripped,
# they are compiled under plain javac (none touches Android) and a truth table runs under a real JVM.
#
# It needs a JDK, and it FAILS (exit 2) when there is none: a suite that skips would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-ingest-text.sh              # the truth table
#   bash test-ingest-text.sh --mutate     # ... plus mutations that must each CONVICT the suite
set -uo pipefail

SUT="$(dirname "$0")/src/com/nowhere/chooser/Ingest.java"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; else SUT="$a"; fi
done
[ -f "$SUT" ] || { echo "test-ingest-text: FAIL -- no such file: $SUT"; exit 2; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-ingest-text: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# The members under test, by signature. Brace-matched from each, so a body that grows a nested block still
# extracts whole.
SIGS=(
  'private static String[] dateParam('
  'private static long parseIcsDuration('
  'private static List<String> splitBlocks('
  'private static List<String[]> properties('
  'private static int valueColon('
  'private static List<String> splitParams('
  'private static String charsetOf('
  'private static String decodeQP('
  'private static String[] splitStructured('
  'private static String unescape('
  'private static String normalizeDate('
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

# The truth table. Expected values are what the parser is FOR (RFC 6350 / RFC 5545 / vCard 2.1), not a
# transcript of what it happens to print.
cat > "$WORK/Cases.java" <<'JAVA'
import java.util.*;

public class Cases {
  static int fails = 0;
  static String show(Object o) {
    if (o == null) return "null";
    if (o instanceof String[]) {
      StringBuilder b = new StringBuilder("[");
      for (String s : (String[]) o) b.append(b.length() > 1 ? ", " : "").append(show(s));
      return b.append(']').toString();
    }
    if (o instanceof List) {
      StringBuilder b = new StringBuilder("[");
      for (Object e : (List<?>) o) b.append(b.length() > 1 ? ", " : "").append(show(e));
      return b.append(']').toString();
    }
    if (o instanceof String) return "\"" + ((String) o).replace("\n", "\\n").replace("\r", "\\r") + "\"";
    return String.valueOf(o);
  }
  static void eq(String what, Object got, Object want) {
    String g = show(got), w = show(want);
    if (g.equals(w)) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": got " + g + ", want " + w); fails++; }
  }
  static String[] prop(String n, String p, String v) { return new String[]{ n, p, v }; }
  static List<String[]> props(String[]... ps) { return Arrays.asList(ps); }

  public static void main(String[] a) {
    // ---- properties: unfold, split, decode
    eq("properties: space fold is unfolded",
       Lifted.properties("NOTE:hello\n world"), props(prop("NOTE", "", "helloworld")));
    eq("properties: TAB fold is unfolded",
       Lifted.properties("NOTE:hello\r\n\tworld"), props(prop("NOTE", "", "helloworld")));
    eq("properties: only the ONE fold character is dropped",
       Lifted.properties("NOTE:ab\n  cd"), props(prop("NOTE", "", "ab cd")));
    eq("properties: item1. group stripped, params kept",
       Lifted.properties("item1.TEL;TYPE=CELL:123"), props(prop("TEL", "TYPE=CELL", "123")));
    eq("properties: name upper-cased",
       Lifted.properties("email:x@y.z"), props(prop("EMAIL", "", "x@y.z")));
    eq("properties: a quoted TZID's ':' is not the value colon",
       Lifted.properties("DTSTART;TZID=\"(UTC+01:00) Amsterdam\":20260901T100000"),
       props(prop("DTSTART", "TZID=\"(UTC+01:00) Amsterdam\"", "20260901T100000")));
    eq("properties: QP soft break joins the next line and decodes",
       Lifted.properties("NOTE;ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8:caf=C3=\n=A9\nFN:x"),
       props(prop("NOTE", "ENCODING=QUOTED-PRINTABLE;CHARSET=UTF-8", "caf\u00e9"), prop("FN", "", "x")));
    eq("properties: a non-QP value ending in '=' is left alone",
       Lifted.properties("NOTE:a=\nFN:x"), props(prop("NOTE", "", "a="), prop("FN", "", "x")));
    eq("properties: no colon / leading colon are skipped",
       Lifted.properties("NOCOLON\n:orphan\nFN:kept"), props(prop("FN", "", "kept")));
    eq("properties: blank lines are skipped",
       Lifted.properties("FN:a\n\nN:b"), props(prop("FN", "", "a"), prop("N", "", "b")));

    // ---- valueColon
    eq("valueColon: first unquoted colon", Lifted.valueColon("A;X=\"1:2\":v:w"), 9);
    eq("valueColon: -1 with no colon", Lifted.valueColon("NOCOLON"), -1);
    eq("valueColon: -1 when every colon is quoted", Lifted.valueColon("A;X=\"1:2\""), -1);

    // ---- splitParams
    eq("splitParams: quoted ';' kept, quotes kept",
       Lifted.splitParams("TZID=\"a;b\";VALUE=DATE"), List.of("TZID=\"a;b\"", "VALUE=DATE"));
    eq("splitParams: empty list", Lifted.splitParams(""), List.of());

    // ---- charsetOf (called with the upper-cased params)
    eq("charsetOf: default UTF-8", Lifted.charsetOf("ENCODING=QUOTED-PRINTABLE"), "UTF-8");
    eq("charsetOf: CHARSET param", Lifted.charsetOf("X;CHARSET=ISO-8859-1"), "ISO-8859-1");

    // ---- decodeQP
    eq("decodeQP: =41=42", Lifted.decodeQP("=41=42", "UTF-8"), "AB");
    eq("decodeQP: '=' not followed by hex is kept", Lifted.decodeQP("a=zz", "UTF-8"), "a=zz");
    eq("decodeQP: trailing '=' is kept", Lifted.decodeQP("ab=", "UTF-8"), "ab=");
    eq("decodeQP: trailing '=X' is kept", Lifted.decodeQP("ab=4", "UTF-8"), "ab=4");
    eq("decodeQP: ISO-8859-1 =E9", Lifted.decodeQP("caf=E9", "ISO-8859-1"), "caf\u00e9");
    eq("decodeQP: UTF-8 multibyte", Lifted.decodeQP("caf=C3=A9", "UTF-8"), "caf\u00e9");
    eq("decodeQP: non-ASCII literal survives", Lifted.decodeQP("\u00e9=41", "UTF-8"), "\u00e9A");
    eq("decodeQP: unknown charset returns the input", Lifted.decodeQP("caf=E9", "X-NO-SUCH-CHARSET"), "caf=E9");

    // ---- splitStructured
    eq("splitStructured: padded to n", Lifted.splitStructured("a;b", 5), new String[]{ "a", "b", "", "", "" });
    eq("splitStructured: extras beyond n dropped", Lifted.splitStructured("a;b;c;d", 2), new String[]{ "a", "b" });
    eq("splitStructured: escaped ';' stays in component 0, still escaped",
       Lifted.splitStructured("a\\;b;c", 3), new String[]{ "a\\;b", "c", "" });

    // ---- unescape
    eq("unescape: null stays null", Lifted.unescape(null), null);
    eq("unescape: \\n and \\N become newlines", Lifted.unescape("a\\nb\\Nc"), "a\nb\nc");
    eq("unescape: \\, \\; \\\\ lose the backslash", Lifted.unescape("a\\,b\\;c\\\\d"), "a,b;c\\d");
    eq("unescape: trimmed (escapes present)", Lifted.unescape("  x\\,y  "), "x,y");
    eq("unescape: trimmed (no escapes)", Lifted.unescape("  plain  "), "plain");

    // ---- normalizeDate
    eq("normalizeDate: yyyyMMdd", Lifted.normalizeDate("19871230"), "1987-12-30");
    eq("normalizeDate: --MMdd (no year)", Lifted.normalizeDate("--1230"), "--12-30");
    eq("normalizeDate: already dashed", Lifted.normalizeDate("1987-12-30"), "1987-12-30");
    eq("normalizeDate: trimmed", Lifted.normalizeDate(" 19871230 "), "1987-12-30");

    // ---- splitBlocks
    String ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"
        + "BEGIN:VEVENT\r\nSUMMARY:One\r\nBEGIN:VALARM\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\n"
        + "DTSTART:20260901\r\nEND:VEVENT\r\n"
        + "begin:vevent\r\nSUMMARY:Two\r\n  END:VEVENT  \r\n"
        + "END:VCALENDAR\r\n";
    eq("splitBlocks: two VEVENTs, VALARM excluded, preamble ignored, CRLF, marker case ignored",
       Lifted.splitBlocks(ics, "BEGIN:VEVENT", "END:VEVENT"),
       List.of("SUMMARY:One\nDTSTART:20260901\n", "SUMMARY:Two\n"));
    eq("splitBlocks: an empty block yields nothing",
       Lifted.splitBlocks("BEGIN:VCARD\nEND:VCARD\n", "BEGIN:VCARD", "END:VCARD"), List.of());

    // ---- parseIcsDuration
    eq("parseIcsDuration: P1W", Lifted.parseIcsDuration("P1W"), 604800L);
    eq("parseIcsDuration: P1DT2H3M4S", Lifted.parseIcsDuration("P1DT2H3M4S"), 93784L);
    eq("parseIcsDuration: PT15M", Lifted.parseIcsDuration("PT15M"), 900L);
    eq("parseIcsDuration: +PT15M", Lifted.parseIcsDuration("+PT15M"), 900L);
    eq("parseIcsDuration: P2D", Lifted.parseIcsDuration("P2D"), 172800L);
    eq("parseIcsDuration: -PT15M is -1", Lifted.parseIcsDuration("-PT15M"), -1L);
    eq("parseIcsDuration: P1D", Lifted.parseIcsDuration("P1D"), 86400L);
    eq("parseIcsDuration: bare P is -1", Lifted.parseIcsDuration("P"), -1L);
    eq("parseIcsDuration: bare PT is -1", Lifted.parseIcsDuration("PT"), -1L);
    eq("parseIcsDuration: P1DT (dangling T) is -1", Lifted.parseIcsDuration("P1DT"), -1L);
    eq("parseIcsDuration: +P is -1", Lifted.parseIcsDuration("+P"), -1L);
    eq("parseIcsDuration: garbage is -1", Lifted.parseIcsDuration("garbage"), -1L);
    eq("parseIcsDuration: 1H (no P) is -1", Lifted.parseIcsDuration("1H"), -1L);

    // ---- dateParam
    eq("dateParam: quoted TZID unquoted, value trimmed",
       Lifted.dateParam(prop("DTSTART", "TZID=\"Europe/Paris\"", " 20260901T100000 ")),
       new String[]{ "20260901T100000", "Europe/Paris", "" });
    eq("dateParam: VALUE=DATE gives kind DATE (any case)",
       Lifted.dateParam(prop("DTSTART", "value=date", "20260901")), new String[]{ "20260901", "", "DATE" });
    eq("dateParam: quoted TZID holding ';' and ':'",
       Lifted.dateParam(prop("DTSTART", "TZID=\"(UTC+01:00) A;B\";VALUE=DATE-TIME", "20260901T100000")),
       new String[]{ "20260901T100000", "(UTC+01:00) A;B", "" });

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA

suite() { # suite <Ingest.java> [quiet] -> 0 pass, 1 a case failed, 2 extract/compile failed
  rm -rf "$WORK/classes"; mkdir -p "$WORK/classes"
  if ! lift "$1" 2>"$WORK/extract.err"; then
    [ "${2:-}" = quiet ] || { echo "EXTRACTION FAILED:"; sed 's/^/        /' "$WORK/extract.err"; }
    return 2
  fi
  if ! "$JAVAC" -nowarn -encoding UTF-8 -d "$WORK/classes" "$WORK/Lifted.java" "$WORK/Cases.java" 2>"$WORK/javac.err"; then
    [ "${2:-}" = quiet ] || { echo "  FAIL  the extracted methods do not compile:"; sed 's/^/        /' "$WORK/javac.err" | head -12; }
    return 2
  fi
  if [ "${2:-}" = quiet ]; then "$JAVA" -cp "$WORK/classes" Cases >/dev/null 2>&1; else "$JAVA" -cp "$WORK/classes" Cases; fi
}

suite "$SUT"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <sed expr>
  local m="$WORK/mut.java" rc
  sed "$2" "$SUT" > "$m"
  if cmp -s "$m" "$SUT"; then printf '  ⚠ NOT APPLIED  %s (the source moved -- re-anchor it)\n' "$1"; MRC=1; return; fi
  suite "$m" quiet; rc=$?
  case $rc in
    0) printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1 ;;
    1) printf '  convicted   %s\n' "$1" ;;
    *) printf '  ⚠ DID NOT BUILD  %s (a mutation must compile to prove anything)\n' "$1"; MRC=1 ;;
  esac
}
mutant "valueColon ignores quotes"            's/else if (c == '"':'"' \&\& !quoted) return i;/else if (c == '"':'"') return i;/'
mutant "unfold keeps the fold character"      's/unfolded.get(unfolded.size() - 1) + line.substring(1))/unfolded.get(unfolded.size() - 1) + line)/'
mutant "QP soft break not joined"             's/while (value.endsWith("=") \&\& i + 1/while (false \&\& i + 1/'
mutant "group prefix not stripped"            's/if (dot >= 0) pname = pname.substring(dot + 1);/;/'
mutant "splitBlocks keeps nested lines"       's/if (nested == 0) cur.append(line)/cur.append(line)/'
mutant "splitBlocks markers case-sensitive"   's/if (t.equalsIgnoreCase(begin))/if (t.equals(begin))/'
mutant "splitParams ignores quotes"           's/if (c == '"';'"' \&\& !quoted) { out.add/if (c == '"';'"') { out.add/'
mutant "charsetOf defaults to ISO-8859-1"     's/return "UTF-8";/return "ISO-8859-1";/'
mutant "decodeQP ignores the charset"         's/return new String(bo.toByteArray(), charset);/return new String(bo.toByteArray(), java.nio.charset.StandardCharsets.UTF_8);/'
mutant "splitStructured ignores escapes"      '/cur.append(c).append(value.charAt(++i))/s/if (c == /if (false \&\& c == /'
mutant "unescape stops mapping N"             "s/if (nx == 'n' || nx == 'N')/if (nx == 'n')/"
mutant "unescape stops trimming"              's/return b.toString().trim();/return b.toString();/'
mutant "normalizeDate drops the dash form"    '/s.matches("--/s/if (s.matches/if (false \&\& s.matches/'
mutant "parseIcsDuration W is 86400"          's/\* 604_800L/* 86_400L/'
mutant "parseIcsDuration accepts negatives"   's/return s.startsWith("-") ? -1 : sec;/return sec;/'
mutant "parseIcsDuration accepts no component" 's/if (m.group(1) == null \&\& m.group(2) == null/if (false \&\& m.group(2) == null/'
mutant "parseIcsDuration accepts a dangling T" 's/if (s.indexOf('"'T'"') >= 0 \&\&/if (false \&\&/'
mutant "dateParam keeps TZID quotes"          's/tzid = tzid.substring(1, tzid.length() - 1);/;/'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
