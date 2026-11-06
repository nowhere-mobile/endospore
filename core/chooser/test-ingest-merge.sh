#!/usr/bin/env bash
# test-ingest-merge.sh [<Ingest.java>] [--mutate] -- what a second source adds to a contact it matches, RUN not grepped.
#
# WHY THIS IS COMMITTED. The identity key (test-ingest-key.sh) decides that two blocks are ONE person; before
# NWP-20261020-19 the second block was then skipped whole, so file B's ORG/TITLE (device-observed 2026-09-20)
# never reached the contact. mergePlan decides, as a pure function, which data rows the matched contact lacks:
# additive only, deduplicated at the data-row level so that a repeated import plans nothing.
#
# ⚠ THESE ARE RUN, NOT PINNED, as in test-ingest-key.sh and test-ingest-vcard.sh: VCardEntry, parseVCard and
# the helpers it reaches, plus normValue, formatAddress and mergePlan, are EXTRACTED verbatim by signature from
# Ingest.java and run under a real JVM. Only android.util.Base64 is stubbed. `have` is built from a parsed block
# the way mergeContact maps provider rows, so the test reads real vCard text end to end.
#
# It needs a JDK and FAILS (exit 2) when there is none: a suite that skips would read green on a runner that never
# ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
#   bash test-ingest-merge.sh              # the cases
#   bash test-ingest-merge.sh --mutate     # ... plus mutations that must each CONVICT the suite
set -uo pipefail

SUT="${1:-$(dirname "$0")/src/com/nowhere/chooser/Ingest.java}"
[ "${1:-}" = "--mutate" ] && SUT="$(dirname "$0")/src/com/nowhere/chooser/Ingest.java"
MUTATE=0
for a in "$@"; do [ "$a" = "--mutate" ] && MUTATE=1; done
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-ingest-merge: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

WORK="$(mktemp -d)"; MUT="$(mktemp -d)"; trap 'rm -rf "$WORK" "$MUT"' EXIT

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
  'static String normValue('
  'private static String formatAddress('
  'static List<String> mergePlan('
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

const() { grep -m1 "private static final int $2 " "$1"; }

build() { # build <Ingest.java> -> compiled into $WORK, or return non-zero
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
  } > "$WORK/Lifted.java" || return 1
  sed -i 's/android\.util\.Base64\.decode(/AndroidBase64.decode(/; s/android\.util\.Base64\.DEFAULT/0/' "$WORK/Lifted.java"
  cat > "$WORK/AndroidBase64.java" <<'STUB'
final class AndroidBase64 {
  // STUB: decides only the decode. Which values reach it is parseVCard's own business.
  static byte[] decode(String s, int flags) { return java.util.Base64.getMimeDecoder().decode(s); }
}
STUB
  cat > "$WORK/Cases.java" <<'JAVA'
import java.util.*;

public class Cases {
  static int fails = 0;
  static void eq(String what, Object got, Object want) {
    String g = String.valueOf(got), w = String.valueOf(want);
    if (g.equals(w)) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": got " + g + ", want " + w); fails++; }
  }
  static String card(String... lines) { return "BEGIN:VCARD\n" + String.join("\n", lines) + "\nEND:VCARD\n"; }

  // Rows -> have, the way mergeContact maps the provider's data rows.
  static Map<String, Set<String>> haveFrom(Lifted.VCardEntry e) {
    Map<String, Set<String>> have = new HashMap<>();
    for (String[] a : e.adrs)
      have.computeIfAbsent("adr", k -> new HashSet<>()).add(Lifted.normValue(Lifted.formatAddress(a)));
    if (e.org != null || e.title != null)
      have.computeIfAbsent("org", k -> new HashSet<>()).add(Lifted.normValue(e.org) + "\n" + Lifted.normValue(e.title));
    if (e.note != null) have.computeIfAbsent("note", k -> new HashSet<>()).add(Lifted.normValue(e.note));
    if (e.bday != null) have.computeIfAbsent("bday", k -> new HashSet<>()).add(e.bday);
    if (e.photo != null) have.computeIfAbsent("photo", k -> new HashSet<>()).add("present");
    return have;
  }
  static List<String> plan(String incoming, String existing) {
    return Lifted.mergePlan(Lifted.parseVCard(incoming), haveFrom(Lifted.parseVCard(existing)));
  }

  static final String NAME = "FN:John Smith", TEL = "TEL;TYPE=CELL:+44 7700 900123", MAIL = "EMAIL:j@x.com";

  public static void main(String[] a) {
    String A = card("VERSION:3.0", NAME, TEL, MAIL);
    String B = card("VERSION:3.0", NAME, TEL, MAIL, "ORG:Acme Ltd", "TITLE:CTO");

    // (a) the device-observed case: A had no org, B adds ORG/TITLE.
    eq("a: B over A adds exactly the organization", plan(B, A), "[org]");
    // (b) the same block merged into its own contact plans nothing.
    String RICH = card(NAME, TEL, MAIL, "ORG:Acme Ltd", "TITLE:CTO", "NOTE:met at a conference", "BDAY:1980-02-03",
        "ADR;TYPE=HOME:;;1 High St;London;;N1 1AA;UK", "PHOTO;ENCODING=b;TYPE=JPEG:AAECAw==");
    eq("b: a block merged into itself plans nothing", plan(RICH, RICH), "[]");
    eq("b: a repeated import of B plans nothing", plan(B, B), "[]");

    // (c) address: case and spacing do not make a new address; a different address does.
    String ADR1 = card(NAME, TEL, "ADR;TYPE=HOME:;;1 High St;London;;N1 1AA;UK");
    eq("c: ADR differing in case and spacing is not planned",
       plan(card(NAME, TEL, "ADR;TYPE=HOME:;;1  HIGH st;london;;n1 1aa;uk"), ADR1), "[]");
    eq("c: a different ADR is planned", plan(card(NAME, TEL, "ADR;TYPE=WORK:;;2 Low Rd;Leeds;;LS1 1AA;UK"), ADR1), "[adr:0]");
    eq("c: only the new one of two ADRs is planned",
       plan(card(NAME, TEL, "ADR:;;1 High St;London;;N1 1AA;UK", "ADR:;;2 Low Rd;Leeds;;LS1 1AA;UK"), ADR1), "[adr:1]");
    eq("c: an empty ADR is never planned", plan(card(NAME, TEL, "ADR:;;;;;;"), A), "[]");

    // (d) organization/title pair.
    String ORG = card(NAME, TEL, "ORG:Acme Ltd", "TITLE:CTO");
    eq("d: org differing only in case and spacing is not planned", plan(card(NAME, TEL, "ORG:acme  ltd", "TITLE:cto"), ORG), "[]");
    eq("d: a different company is planned", plan(card(NAME, TEL, "ORG:Other Co", "TITLE:CTO"), ORG), "[org]");
    eq("d: a different title is planned", plan(card(NAME, TEL, "ORG:Acme Ltd", "TITLE:CEO"), ORG), "[org]");

    // (e) note, birthday, photo.
    String NOTE = card(NAME, TEL, "NOTE:met at a conference", "BDAY:1980-02-03");
    eq("e: note and bday are planned when absent", plan(NOTE, A), "[note, bday]");
    eq("e: a different note is planned", plan(card(NAME, TEL, "NOTE:other", "BDAY:1980-02-03"), NOTE), "[note]");
    eq("e: a different birthday is planned", plan(card(NAME, TEL, "NOTE:met at a conference", "BDAY:1981-02-03"), NOTE), "[bday]");
    eq("e: a note equal after normalisation is not planned",
       plan(card(NAME, TEL, "NOTE:  MET  at a   Conference ", "BDAY:1980-02-03"), NOTE), "[]");
    String P1 = card(NAME, TEL, "PHOTO;ENCODING=b;TYPE=JPEG:AAECAw==");
    String P2 = card(NAME, TEL, "PHOTO;ENCODING=b;TYPE=JPEG:BAUGBw==");
    eq("e: a photo is planned when the contact has none", plan(P1, A), "[photo]");
    eq("e: the same photo is not planned", plan(P1, P1), "[]");
    eq("e: a DIFFERENT photo is not planned when one is present", plan(P2, P1), "[]");

    // (f) never a name, phone or e-mail, whatever the contact holds.
    List<String> all = Lifted.mergePlan(Lifted.parseVCard(RICH), new HashMap<>());
    eq("f: everything absent plans in the stated order", all, "[adr:0, org, note, bday, photo]");
    boolean clean = true;
    for (String p : all) if (!p.matches("adr:\\d+|org|note|bday|photo")) clean = false;
    eq("f: no entry names a name, phone or e-mail", clean, true);
    eq("f: a block of only name, phone and e-mail plans nothing", plan(A, card(NAME)), "[]");
    eq("f: a phone written another way plans nothing", plan(card(NAME, "TEL:07700 900123", MAIL), A), "[]");

    eq("normValue null", Lifted.normValue(null), "");
    eq("normValue collapses", Lifted.normValue("  A \t b\n C "), "a b c");

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  "$JAVAC" -nowarn -d "$WORK" "$WORK"/*.java 2>"$WORK/javac.err"
}

suite() { # suite <Ingest.java> [quiet]
  build "$1" || { [ "${2:-}" = quiet ] || { echo "extract/compile failed:"; head -5 "$WORK/javac.err"; }; return 2; }
  if [ "${2:-}" = quiet ]; then "$JAVA" -cp "$WORK" Cases >/dev/null 2>&1; else "$JAVA" -cp "$WORK" Cases; fi
}

suite "$SUT"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted: the suite must RUN and FAIL, not merely fail to build) =="
MRC=0
mutant() { # mutant <label> <sed expr>
  local m="$MUT/mut.java"; sed "$2" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then printf '  ⚠ DID NOT APPLY  %s\n' "$1"; MRC=1; return; fi
  suite "$m" quiet; local r=$?
  if [ "$r" = 1 ]; then printf '  convicted   %s\n' "$1"
  else printf '  ⚠ SURVIVED/BROKEN (rc %s)  %s\n' "$r" "$1"; MRC=1; fi
}
mutant "adr normalisation removed"             's|String v = normValue(formatAddress(in.adrs.get(i)));|String v = formatAddress(in.adrs.get(i));|'
mutant "org planned regardless of have"        's|if (haveOrg == null .*$|if (true)|'
mutant "every incoming kind planned"           's|List<String> plan = new ArrayList<>();|have = new java.util.HashMap<>(); List<String> plan = new ArrayList<>();|'
mutant "note rule inverted"                    's|if (haveNote == null .*$|if (haveNote == null \|\| haveNote.contains(normValue(in.note))) plan.add("note");|'
mutant "photo planned when another is present" 's|if (havePhoto == null .*$|if (true) plan.add("photo");|'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
