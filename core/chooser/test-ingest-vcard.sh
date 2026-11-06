#!/usr/bin/env bash
# test-ingest-vcard.sh [<Ingest.java>] [--mutate] -- Ingest.parseVCard, RUN rather than read (NWP-20261016-41).
#
# WHY THIS IS COMMITTED. parseVCard is the switch that turns one staged vCard block into the VCardEntry the
# provider insert and the identity key read. It carries two bounds whose comments say why they are load-bearing:
# TEL/EMAIL/ADR are capped at MAX_ROWS_PER_KIND per contact, and an inline PHOTO above MAX_PHOTO_BYTES is dropped
# because "a >1 MiB photo would fail the whole contact, forever" (the applyBatch parcel's binder limit). It also
# accepts three PHOTO spellings (a data: URI, a BASE64 param, ENCODING=B) and skips remote URIs. The helpers it
# calls are run by test-ingest-text.sh and the entry/key by test-ingest-key.sh (their cases are not repeated);
# parseVCard itself, the switch and the caps, was named by none of them.
#
# parseVCard, VCardEntry, the two constants and every helper it reaches are EXTRACTED verbatim by signature, so the
# tested code is the shipped code. ONE STUB: android.util.Base64.decode(String, int), backed by java.util's MIME
# decoder. The stub decides only the DECODE, not which values reach it -- the remote-URI skip, the data: strip,
# the whitespace removal and the size bound all live in the extracted code.
#
# It needs a JDK, and FAILS (exit 2) when there is none: a suite that skips would read green on a runner that never
# ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-ingest-vcard.sh              # the truth table
#   bash test-ingest-vcard.sh --mutate     # ... plus mutations that must each CONVICT the suite
set -uo pipefail

SUT="$(dirname "$0")/src/com/nowhere/chooser/Ingest.java"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; else SUT="$a"; fi
done
[ -f "$SUT" ] || { echo "test-ingest-vcard: FAIL -- no such file: $SUT"; exit 2; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-ingest-vcard: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT


# The members under test, by signature. Brace-matched from each, so a body that grows a nested block still
# extracts whole. The two constants are single lines.
SIGS=(
  'private static final class VCardEntry'
  'private static VCardEntry parseVCard('
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

const() { # const <file> <name> -> the one declaration line
  grep -m1 "private static final int $2 " "$1"
}

lift() { # lift <Ingest.java> -> $WORK/Lifted.java, every member present or return 1
  local src="$1" sig body c
  {
    echo 'import java.util.*;'
    echo 'final class Lifted {'
    for c in MAX_PHOTO_BYTES MAX_ROWS_PER_KIND; do
      body=$(const "$src" "$c") || return 1
      [ -n "$body" ] || { echo "NOT FOUND: $c" >&2; return 1; }
      printf '%s\n' "${body#"${body%%[![:space:]]*}"}" | sed 's/^private //'
    done
    for sig in "${SIGS[@]}"; do
      body=$(extract "$src" "$sig") || return 1
      [ -n "$body" ] || return 1
      printf '%s\n\n' "${body#private }"
    done
    echo '}'
  } > "$WORK/Lifted.java"
  # android.util.Base64.decode(String, int) -> the stub below; the text of parseVCard is otherwise untouched.
  sed -i 's/android\.util\.Base64\.decode(/AndroidBase64.decode(/; s/android\.util\.Base64\.DEFAULT/0/' "$WORK/Lifted.java"
  cat > "$WORK/AndroidBase64.java" <<'STUB'
final class AndroidBase64 {
  // STUB: decides only the decode. Which values reach it is parseVCard's own business.
  static byte[] decode(String s, int flags) { return java.util.Base64.getMimeDecoder().decode(s); }
}
STUB
}

# The truth table. Expected values are what the parser is FOR (RFC 6350 / vCard 2.1), not a transcript.
cat > "$WORK/Cases.java" <<'JAVA'
import java.util.*;

public class Cases {
  static int fails = 0;
  static void ok(String what, boolean cond, String detail) {
    if (cond) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }
  static void eq(String what, Object got, Object want) {
    String g = got instanceof String[] ? Arrays.toString((String[]) got) : String.valueOf(got);
    String w = want instanceof String[] ? Arrays.toString((String[]) want) : String.valueOf(want);
    ok(what, g.equals(w), "got " + g + ", want " + w);
  }
  static String card(String... lines) { return String.join("\n", lines) + "\n"; }
  static String rep(String line, int n) {
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < n; i++) b.append(line.replace("#", String.valueOf(i))).append('\n');
    return b.toString();
  }
  static String b64(int n) { // n bytes of non-zero payload
    byte[] b = new byte[n]; Arrays.fill(b, (byte) 7);
    return Base64.getEncoder().encodeToString(b);
  }

  public static void main(String[] a) {
    Lifted.VCardEntry e;

    // ---- names
    e = Lifted.parseVCard(card("FN:Ada\\, Countess\\; of Lovelace"));
    eq("FN: escaped , and ; unescaped", e.fn, "Ada, Countess; of Lovelace");
    e = Lifted.parseVCard(card("N:Love\\,lace;Ada\\;A;Augusta;Lady;Countess"));
    eq("N: five components, escapes undone", e.n, new String[]{ "Love,lace", "Ada;A", "Augusta", "Lady", "Countess" });
    e = Lifted.parseVCard(card("N:Doe;Jo"));
    eq("N: short value padded to five", e.n, new String[]{ "Doe", "Jo", "", "", "" });

    // ---- row caps
    e = Lifted.parseVCard(rep("TEL;TYPE=CELL:+1 555 01#", 150));
    eq("TEL: 150 lines -> exactly 100", e.tels.size(), 100);
    eq("TEL: the FIRST 100 are kept", e.tels.get(99)[0], "+1 555 0199");
    eq("TEL: params carried", e.tels.get(0)[1], "TYPE=CELL");
    e = Lifted.parseVCard(rep("TEL:+1 555 01#", 100));
    eq("TEL: exactly 100 lines -> 100", e.tels.size(), 100);
    e = Lifted.parseVCard(rep("EMAIL:u#@example.test", 150));
    eq("EMAIL: 150 lines -> exactly 100", e.emails.size(), 100);
    e = Lifted.parseVCard(rep("ADR;TYPE=HOME:;;#  Main St;Town;;12345;Land", 150));
    eq("ADR: 150 lines -> exactly 100", e.adrs.size(), 100);
    e = Lifted.parseVCard(rep("TEL:1#", 150) + rep("EMAIL:u#@x.test", 3));
    eq("caps are per kind: EMAIL unaffected by a full TEL", e.emails.size(), 3);

    // ---- ADR / ORG / simple fields
    e = Lifted.parseVCard(card("ADR;TYPE=HOME:PO;Apt 4;1 Main\\, St;Town;Region;12345;Land"));
    eq("ADR: seven components + params", e.adrs.get(0),
       new String[]{ "PO", "Apt 4", "1 Main, St", "Town", "Region", "12345", "Land", "TYPE=HOME" });
    e = Lifted.parseVCard(card("ORG:Acme\\, Inc;Research;Lab"));
    eq("ORG: only the first component", e.org, "Acme, Inc");
    e = Lifted.parseVCard(card("TITLE:Engineer", "NOTE:line1\\nline2"));
    eq("TITLE", e.title, "Engineer");
    eq("NOTE: \\n becomes a newline", e.note, "line1\nline2");
    e = Lifted.parseVCard(card("BDAY:19871230"));
    eq("BDAY: normalized", e.bday, "1987-12-30");

    // ---- property name case / unknown
    // properties() upper-cases the name, so a lower-case property is the same property.
    e = Lifted.parseVCard(card("tel:12345", "fn:Lower Case", "item1.email:g@x.test"));
    eq("lower-case tel: is a TEL", e.tels.size(), 1);
    eq("lower-case fn: is the FN", e.fn, "Lower Case");
    eq("grouped lower-case email: is an EMAIL", e.emails.size(), 1);
    e = Lifted.parseVCard(card("X-FUTURE:whatever", "FN:Kept", "UID:abc"));
    eq("unknown properties are ignored; the rest survives", e.fn, "Kept");
    ok("unknown properties add no rows", e.tels.isEmpty() && e.emails.isEmpty() && e.adrs.isEmpty() && e.photo == null, "rows appeared");

    // ---- PHOTO spellings
    String p = b64(100);
    e = Lifted.parseVCard(card("PHOTO:data:image/jpeg;base64," + p));
    ok("PHOTO: data: URI -> set", e.photo != null && e.photo.length == 100, "photo=" + (e.photo == null ? "null" : e.photo.length));
    e = Lifted.parseVCard(card("PHOTO;ENCODING=b;TYPE=JPEG:" + p));
    ok("PHOTO: 3.0 ENCODING=b -> set", e.photo != null && e.photo.length == 100, "photo not set");
    e = Lifted.parseVCard(card("PHOTO;JPEG;ENCODING=BASE64:" + p));
    ok("PHOTO: 2.1 ENCODING=BASE64 -> set", e.photo != null && e.photo.length == 100, "photo not set");
    e = Lifted.parseVCard(card("PHOTO;JPEG;ENCODING=BASE64:" + p.substring(0, 40) + "\n " + p.substring(40)));
    ok("PHOTO: a folded base64 value is unfolded and decoded", e.photo != null && e.photo.length == 100, "photo not set");
    e = Lifted.parseVCard(card("PHOTO;VALUE=uri:https://example.test/a.jpg", "FN:Remote"));
    ok("PHOTO: remote VALUE=uri -> no photo", e.photo == null, "photo set");
    eq("PHOTO: a remote photo does not cost the contact", e.fn, "Remote");
    e = Lifted.parseVCard(card("PHOTO:https://example.test/a.jpg"));
    ok("PHOTO: a bare remote URL -> no photo", e.photo == null, "photo set");

    // ---- PHOTO bound
    int max = Lifted.MAX_PHOTO_BYTES;
    e = Lifted.parseVCard(card("PHOTO;ENCODING=b:" + b64(max), "FN:Edge"));
    ok("PHOTO: exactly MAX_PHOTO_BYTES is kept", e.photo != null && e.photo.length == max, "photo=" + (e.photo == null ? "null" : e.photo.length));
    e = Lifted.parseVCard(card("FN:Big", "TEL:555", "PHOTO;ENCODING=b:" + b64(max + 1), "EMAIL:a@x.test"));
    ok("PHOTO: MAX_PHOTO_BYTES+1 is dropped", e.photo == null, "photo kept");
    ok("PHOTO: ... and the rest of the contact survives",
       "Big".equals(e.fn) && e.tels.size() == 1 && e.emails.size() == 1, "fn=" + e.fn);
    e = Lifted.parseVCard(card("PHOTO;ENCODING=b:" + b64(0)));
    ok("PHOTO: an empty payload is no photo", e.photo == null, "photo set");

    // ---- undecodable photo
    try {
      e = Lifted.parseVCard(card("FN:Bad", "PHOTO;ENCODING=b:!!!not base64!!!", "TEL:555"));
      ok("PHOTO: undecodable base64 -> photo null, no throw", e.photo == null, "photo set");
      ok("PHOTO: ... and later properties still parse", "Bad".equals(e.fn) && e.tels.size() == 1, "fn=" + e.fn);
    } catch (Throwable t) {
      ok("PHOTO: undecodable base64 does not throw", false, t.toString());
    }

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
  if ! "$JAVAC" -nowarn -encoding UTF-8 -d "$WORK/classes" "$WORK/Lifted.java" "$WORK/AndroidBase64.java" "$WORK/Cases.java" 2>"$WORK/javac.err"; then
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
# Each sed expr anchors on the shipped text; a mutant that does not apply counts as a failure.
mutant "TEL cap < becomes <="                  's/if (e.tels.size() < MAX_ROWS_PER_KIND)/if (e.tels.size() <= MAX_ROWS_PER_KIND)/'
mutant "ADR cap check removed"                 '/if (e.adrs.size() >= MAX_ROWS_PER_KIND) break;/d'
mutant "photo bound <= becomes <"              's/ph.length <= MAX_PHOTO_BYTES/ph.length < MAX_PHOTO_BYTES/'
mutant "URI-photo skip removed"                's/else if (!up.contains("BASE64") \&\& !up.contains("ENCODING=B")) break;//'
mutant "ORG keeps the whole value"             's/e.org = unescape(splitStructured(value, 2)\[0\])/e.org = unescape(value)/'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
