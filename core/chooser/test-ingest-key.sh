#!/usr/bin/env bash
# test-ingest-key.sh [<Ingest.java>] [--mutate] -- the contact dedup key, RUN rather than grepped.
#
# WHY THIS IS COMMITTED. NWP-20260920-01 changed the contact dedup key from sha256(raw vCard block) to the
# contact's IDENTITY, because the import page can stage the same person from TWO sources at once -- a .vcf
# the user picked and the phone's own export over USB -- and those never agree byte for byte. The old key
# therefore deduplicated nothing across sources: one person, two raw contacts, which Android's aggregation
# usually hides and never removes.
#
# ⚠⚠ THE DANGEROUS DIRECTION IS THE OTHER ONE. A key that is too LOOSE merges two different people, and
# dropping somebody's contact is far worse than leaving a duplicate. The safety rule is that a merge
# requires a shared contact point: an entry with no phone and no e-mail falls back to the raw-byte key and
# is never merged with anything. A name alone is not an identity.
#
# ⚠ THESE ARE RUN, NOT PINNED, for the same reason test-ics-time.sh gives: a source-level grep cannot tell
# you what a function DOES, and this is string normalisation where every defect looks like working code. So
# the four pure members are EXTRACTED straight out of Ingest.java -- VCardEntry, sha256Hex, normalisePhone,
# normaliseName, contactIdentityKey, none of which touch Android -- wrapped in a harness, and run under a
# real JVM. Extraction rather than a copy is what keeps the tested code identical to the shipped code.
#
#   bash test-ingest-key.sh              # the truth table
#   bash test-ingest-key.sh --mutate     # ... plus mutations that must each CONVICT the suite
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
  echo "test-ingest-key: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Pull the members out of the source verbatim. Brace-matched from each signature, so a body that grows a
# nested class or a lambda still extracts whole.
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

build() { # build <Ingest.java> -> harness compiled into $WORK
  local src="$1"
  rm -rf "$WORK/K.java" "$WORK"/*.class
  {
    echo 'import java.util.*;'
    echo 'public class K {'
    extract "$src" 'private static final class VCardEntry'  || return 1
    extract "$src" 'private static String sha256Hex'        || return 1
    extract "$src" 'private static String normalisePhone'   || return 1
    extract "$src" 'private static String normaliseName'    || return 1
    extract "$src" 'private static String contactIdentityKey' || return 1
    cat <<'JAVA'
  static int fails = 0;
  static void eq(String what, String a, String b) {
    if (a.equals(b)) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + ": " + a + " != " + b); fails++; }
  }
  static void ne(String what, String a, String b) {
    if (!a.equals(b)) System.out.println("  PASS  " + what);
    else { System.out.println("  FAIL  " + what + " (both " + a + ")"); fails++; }
  }
  static VCardEntry vc(String fn, String[] tels, String[] mails) {
    VCardEntry e = new VCardEntry(); e.fn = fn;
    if (tels != null) for (String t : tels) e.tels.add(new String[]{t, ""});
    if (mails != null) for (String m : mails) e.emails.add(new String[]{m, ""});
    return e;
  }
  public static void main(String[] a) throws Exception {
    // One subscriber, three ways of writing it.
    eq("phone: +44 form",      normalisePhone("+44 7700 900123"), normalisePhone("07700 900123"));
    eq("phone: 00 form",       normalisePhone("00447700900123"),  normalisePhone("07700 900123"));
    eq("phone: punctuation",   normalisePhone("(07700) 900-123"), normalisePhone("07700900123"));
    ne("phone: different numbers", normalisePhone("07700900123"), normalisePhone("07700900999"));
    eq("phone: short kept whole",  normalisePhone("12345"), "12345");

    // The two orders N and FN disagree about.
    eq("name: order",   normaliseName(vc("John Smith", null, null)), normaliseName(vc("Smith, John", null, null)));
    eq("name: case",    normaliseName(vc("  JOHN  smith ", null, null)), normaliseName(vc("John Smith", null, null)));
    ne("name: different people", normaliseName(vc("John Smith", null, null)), normaliseName(vc("Jane Smith", null, null)));

    // THE POINT: the same person, exported by two different tools.
    VCardEntry fromPhone = vc("John Smith", new String[]{"+44 7700 900123"}, new String[]{"j@x.test"});
    VCardEntry fromFile  = vc("Smith, John", new String[]{"07700 900123"},  new String[]{"J@X.test"});
    eq("same person, two exporters -> ONE key",
       contactIdentityKey(fromPhone, "LEGACY"), contactIdentityKey(fromFile, "LEGACY"));

    // Fields two exporters routinely disagree about must not split the identity.
    VCardEntry withExtras = vc("John Smith", new String[]{"+44 7700 900123"}, new String[]{"j@x.test"});
    withExtras.org = "Acme Ltd"; withExtras.note = "met at a conference"; withExtras.title = "CTO";
    eq("ORG/NOTE/TITLE do not change identity",
       contactIdentityKey(fromPhone, "LEGACY"), contactIdentityKey(withExtras, "LEGACY"));

    ne("different contact points -> different keys",
       contactIdentityKey(vc("John Smith", new String[]{"07700900123"}, null), "L"),
       contactIdentityKey(vc("John Smith", new String[]{"07700900999"}, null), "L"));

    // A person reachable only by e-mail still merges on it.
    eq("e-mail alone is a contact point",
       contactIdentityKey(vc("Ada L", null, new String[]{"ada@x.test"}), "L1"),
       contactIdentityKey(vc("L, Ada", null, new String[]{"ADA@x.test"}), "L2"));

    // THE SAFETY RULE. A name with no phone and no e-mail is NOT an identity: two different people called
    // "J Smith" must never collapse into one, because that DROPS one of them.
    eq("name-only falls back to the raw key", contactIdentityKey(vc("J Smith", null, null), "LEGACY-A"), "LEGACY-A");
    ne("two name-only people stay separate",
       contactIdentityKey(vc("J Smith", null, null), "LEGACY-A"),
       contactIdentityKey(vc("J Smith", null, null), "LEGACY-B"));

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$WORK/K.java"
  "$JAVAC" -nowarn -d "$WORK" "$WORK/K.java" 2>"$WORK/javac.err"
}

suite() { # suite <Ingest.java> [quiet]
  build "$1" || { [ "${2:-}" = quiet ] || { echo "extract/compile failed:"; head -5 "$WORK/javac.err"; }; return 2; }
  if [ "${2:-}" = quiet ]; then "$JAVA" -cp "$WORK" K >/dev/null 2>&1; else "$JAVA" -cp "$WORK" K; fi
}

suite "$SUT"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <sed expr>
  local m="$WORK/mut.java"; sed "$2" "$SUT" > "$m"
  if suite "$m" quiet; then printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1
  else printf '  convicted   %s\n' "$1"; fi
}
# The change itself: keying on bytes again deduplicates nothing across sources.
mutant "identity key reverts to raw bytes" 's|if (points.isEmpty()) return legacyKey;|if (true) return legacyKey;|'
# ⚠ The safety rule: without the fallback, two different name-only people share a key and one is DROPPED.
mutant "name-only safety fallback removed"  's|if (points.isEmpty()) return legacyKey;||'
# Normalisation that stops normalising.
mutant "phone digits no longer trimmed"     's|return v.length() > 9 ? v.substring(v.length() - 9) : v;|return v;|'
mutant "name words no longer sorted"        's|java.util.TreeSet<String> words|java.util.LinkedHashSet<String> words|'

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
