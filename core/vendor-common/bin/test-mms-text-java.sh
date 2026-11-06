#!/usr/bin/env bash
# test-mms-text-java.sh [--mutate] -- MMS text parts reach SEAL-MMS as UTF-8, run under javac (NWP-20261117-24).
#
# WHY THIS IS COMMITTED. The SEAL-MMS wire carries a part's content type, name and bytes, not its charset, and every
# reader (TelIngest.insertMmsPart, TelIngest.deliverMms's notice preview, the owner inbox) decodes a text part as
# UTF-8. The gate dropped PduPart.getCharset, so a UTF-16 or Latin-1 text part was stored as mojibake. The gate now
# transcodes there, in MmsText.toUtf8 (java.* and the vendored CharacterSets only), and MmsText.storedAsText is the
# one text-part rule the gate and TelIngest.insertMmsPart share. MmsText is compiled here with its cases; source
# checks on the real MmsDownloadedReceiver.java and TelIngest.java (comments stripped) pin both call sites.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-mms-text-java.sh            # the cases and the source checks
#   bash test-mms-text-java.sh --mutate  # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${MMS_TEXT_SRC:-$SRC/MmsText.java}"
MD="$SRC/MmsDownloadedReceiver.java"
TI="$SRC/TelIngest.java"
CS="$root/core/chooser/mms/com/google/android/mms/pdu/CharacterSets.java"
STUB="$root/core/chooser/tests/mms-text/stubs/android/compat/annotation/UnsupportedAppUsage.java"
CASES="$root/core/chooser/tests/mms-text/MmsTextCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$CASES" "$CS" "$STUB" "$MD" "$TI"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# suite <MmsText.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  MmsText.java does not exist (the gate does not transcode)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/src/com/google/android/mms/pdu" "$d/src/android/compat/annotation"
  cp "$src" "$d/src/com/nowhere/chooser/MmsText.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/MmsTextCases.java"
  cp "$CS" "$d/src/com/google/android/mms/pdu/CharacterSets.java"
  cp "$STUB" "$d/src/android/compat/annotation/UnsupportedAppUsage.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java \
       "$d/src/com/google/android/mms/pdu/CharacterSets.java" \
       "$d/src/android/compat/annotation/UnsupportedAppUsage.java"; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.MmsTextCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip_comments <file> -> the Java source on stdout with // and /* */ comments removed (string and char literals kept).
strip_comments() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse' "$1"
}

# method <code> <fixed signature text> -> the method from its signature line to its first 4-space closing brace.
method() {
  local code="$1" sig="$2"
  printf '%s\n' "$code" | awk -v s="$sig" 'index($0, s) { on = 1 } on { print } on && /^    }$/ { exit }'
}

# source_check <MmsDownloadedReceiver.java> <TelIngest.java> -> 0 when both call sites hold, 1 otherwise.
source_check() {
  local md="$1" ti="$2" code body x bad=0
  command -v perl >/dev/null 2>&1 || { echo "  FAIL  no perl: the comment-stripped source checks cannot run" >&2; return 1; }
  code=$(strip_comments "$md") || { echo "  FAIL  could not strip comments from $md" >&2; return 1; }
  body=$(method "$code" 'private static boolean sealDownloaded(Context app,')
  if [ -z "$body" ]; then echo "  FAIL  S0 sealDownloaded not found in $md" >&2; return 1; fi
  x='SmsDeliverReceiver.sealMmsAndNotify('
  grep -qF -e "$x" <<<"$body" || { echo "  FAIL  S0 control: sealDownloaded no longer calls $x" >&2; bad=1; }
  x='String ct = bytesToStr(p.getContentType());'
  grep -qF -e "$x" <<<"$body" || { echo "  FAIL  S1 sealDownloaded lost: $x" >&2; bad=1; }
  x='parts.add(new SmsDeliverReceiver.MmsPart(ct, nm, MmsText.toUtf8(ct, p.getCharset(), d)));'
  grep -qF -e "$x" <<<"$body" \
    || { echo "  FAIL  S1 sealDownloaded does not pass MmsText.toUtf8(ct, p.getCharset(), d) to the part" >&2; bad=1; }

  code=$(strip_comments "$ti") || { echo "  FAIL  could not strip comments from $ti" >&2; return 1; }
  body=$(method "$code" 'private static void insertMmsPart(Context ctx, long mid, int seq, String ct, String name, byte[] data) {')
  if [ -z "$body" ]; then echo "  FAIL  S2 insertMmsPart not found in $ti" >&2; return 1; fi
  x='v.put("chset", 106);'
  grep -qF -e "$x" <<<"$body" || { echo "  FAIL  S2 control: insertMmsPart no longer writes $x" >&2; bad=1; }
  x='boolean isText = MmsText.storedAsText(ct);'
  grep -qF -e "$x" <<<"$body" || { echo "  FAIL  S3 insertMmsPart does not take its text rule from MmsText.storedAsText" >&2; bad=1; }
  x='ct.startsWith("text/")'
  if grep -qF -e "$x" <<<"$body"; then echo "  FAIL  S3 insertMmsPart holds an inline $x rule again" >&2; bad=1; fi
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$MD" "$TI" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates MmsText.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/MmsText.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <MD|TI> <perl-expr>   (mutates that source file; the source check must fail)
  local d c rc orig md="$MD" ti="$TI"; d=$(mktemp -d -p "$W") || return 1
  case "$2" in MD) orig="$MD" ;; TI) orig="$TI" ;; *) echo "  ERROR     $1 -- unknown file $2"; rm -rf "$d"; return 1 ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = MD ]; then md="$c"; else ti="$c"; fi
  source_check "$md" "$ti" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "X1 toUtf8 always returns data" \
  's/(static byte\[\] toUtf8\(String ct, int mib, byte\[\] data\) \{)/$1\n        if (true) return data;/' || fails=$((fails+1))
mut "X2 toUtf8 transcodes image parts too" \
  's/if \(data == null \|\| !storedAsText\(ct\)\) return data;/if (data == null) return data;/' || fails=$((fails+1))
mut "X3 an unset charset (0) is decoded as ISO-8859-1" \
  's/mib == CharacterSets\.ANY_CHARSET \|\| //; s/String name = CharacterSets\.getMimeName\(mib\);/String name = mib == CharacterSets.ANY_CHARSET ? "iso-8859-1" : CharacterSets.getMimeName(mib);/' \
  || fails=$((fails+1))
mutsrc "X4 sealDownloaded passes the raw d again" MD \
  's/MmsText\.toUtf8\(ct, p\.getCharset\(\), d\)/d/' || fails=$((fails+1))
mut "X5 storedAsText drops application/smil" \
  's/ \|\| "application\/smil"\.equals\(ct\)//' || fails=$((fails+1))
mut "X6 US-ASCII (3) is transcoded (the pass-through dropped)" \
  's/\s*\|\| mib == CharacterSets\.US_ASCII//' || fails=$((fails+1))
mutsrc "X7 insertMmsPart has its own inline text rule again" TI \
  's/boolean isText = MmsText\.storedAsText\(ct\);/boolean isText = ct.startsWith("text\/") || "application\/smil".equals(ct);/' \
  || fails=$((fails+1))
mutsrc "X8 the toUtf8 call only inside a line comment" MD \
  's/(parts\.add\(new SmsDeliverReceiver\.MmsPart\(ct, nm, )MmsText\.toUtf8\(ct, p\.getCharset\(\), d\)(\)\);)/$1d$2 \/\/ $1MmsText.toUtf8(ct, p.getCharset(), d)$2/' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
