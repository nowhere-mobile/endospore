#!/usr/bin/env bash
# test-tel-notice-clear-java.sh [--mutate] -- the gate's notice-label decoding, run under javac (NWP-20261110-22).
#
# WHY THIS IS COMMITTED. "Unbind all" and "Clear notices" clear exactly the gate notices of the lines a DELETE-BINDING
# reply names (TelNoticeClear.unboundLabels, never null: null would clear EVERY notice), matched against the line label
# recovered from a notice's title (TelNoticeClear.labelOf, after the FIRST "  -  "). test-tel-seal.sh pins
# cancelTelNotices byte for byte but nothing ran these two parsers. They are lifted into a pure class, compiled here with
# their cases, and a source check pins that ChooserActivity delegates to them and that cancelTelNotices is untouched.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-tel-notice-clear-java.sh            # the cases and the source checks
#   bash test-tel-notice-clear-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${TEL_NOTICE_CLEAR_SRC:-$SRC/TelNoticeClear.java}"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/tel-notice-clear/TelNoticeClearCases.java"
SEAL="$root/core/chooser/test-tel-seal.sh"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# suite <TelNoticeClear.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  TelNoticeClear.java does not exist (the parsers are not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/TelNoticeClear.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/TelNoticeClearCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.TelNoticeClearCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

strip_comments() { perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1"; }

# body <text> <signature> -> from the signature line to the first line equal to "    }"; empty unless it occurs once.
# Every reader below reads its input TO THE END: under pipefail a reader that stops early (awk's exit, grep -q) can
# leave printf writing into a closed pipe, and the pipeline then fails -- a false FAIL on a busy host, and in the
# `if` below a check that passes without having read (docs/backlog.md, "A shell check that pipes into `grep -q`
# under `pipefail` can pass on the code it exists to reject").
body() {
  local n
  n=$(printf '%s\n' "$1" | grep -cF -- "$2")
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$1" | awk -v sig="$2" '!done && index($0, sig) { on = 1 } on { print } on && $0 == "    }" { on = 0; done = 1 }'
}

# source_check <ChooserActivity.java> -> 0 when ChooserActivity delegates to TelNoticeClear, 1 otherwise.
source_check() {
  local text ub nl bad=0
  text=$(strip_comments "$1") || return 1
  ub=$(body "$text" 'static java.util.Set<String> unboundLabels(String reply) {') \
    || { echo "  FAIL  unboundLabels signature not found exactly once" >&2; return 1; }
  nl=$(body "$text" 'private static String noticeLabel(android.service.notification.StatusBarNotification sbn) {') \
    || { echo "  FAIL  noticeLabel signature not found exactly once" >&2; return 1; }
  printf '%s\n' "$ub" | grep -cF 'return TelNoticeClear.unboundLabels(' >/dev/null \
    || { echo "  FAIL  unboundLabels does not return TelNoticeClear.unboundLabels(" >&2; bad=1; }
  printf '%s\n' "$nl" | grep -cF 'return TelNoticeClear.labelOf(' >/dev/null \
    || { echo "  FAIL  noticeLabel does not return TelNoticeClear.labelOf(" >&2; bad=1; }
  if printf '%s\n%s\n' "$ub" "$nl" | grep -cF -e 'indexOf("  -  ")' -e 'android.util.Base64' >/dev/null; then
    echo "  FAIL  a body still parses by itself (indexOf or android.util.Base64)" >&2; bad=1
  fi
  [ "$bad" -eq 0 ]
}

# seal_check -> 0 when test-tel-seal.sh still pins cancelTelNotices unchanged.
seal_check() {
  local out n
  out=$(bash "$SEAL" 2>&1)
  n=$(printf '%s\n' "$out" | grep -cF 'ok    ChooserActivity.cancelTelNotices is the pinned block')
  [ "$n" -ge 1 ] || { echo "  FAIL  cancelTelNotices is not the pinned block:" >&2; printf '%s\n' "$out" | tail -8 >&2; return 1; }
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$CHOOSER" || { echo "FAILED (source)"; exit 1; }
seal_check || { echo "FAILED (cancelTelNotices)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates TelNoticeClear.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/TelNoticeClear.java"
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
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ChooserActivity.java; the source check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  source_check "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 unboundLabels returns null when nothing decoded" 's/return out;/return out.isEmpty() ? null : out;/' || fails=$((fails+1))
mut "M2 labelOf returns the whole title" 's/return i >= 0 \? s\.substring\(i \+ 5\) : "";/return s;/' || fails=$((fails+1))
mut "M3 labelOf splits on the last separator" 's/s\.indexOf\("  -  "\)/s.lastIndexOf("  -  ")/' || fails=$((fails+1))
mut "M4 labelOf drops one character too many" 's/substring\(i \+ 5\)/substring(i + 6)/' || fails=$((fails+1))
mut "M5 unboundLabels starts at token 0" 's/int i = 1; i < t\.length/int i = 0; i < t.length/' || fails=$((fails+1))
mut "M6 an undecodable token throws out" 's/try \{\s*(out\.add\(.*?\);)\s*\} catch \(Throwable ignore\) \{\}/$1/s' || fails=$((fails+1))
mutsrc "M7 noticeLabel keeps its own parse" 's/return TelNoticeClear\.labelOf\(t\);/if (t == null) return ""; String s = t.toString(); int i = s.indexOf("  -  "); return i >= 0 ? s.substring(i + 5) : "";/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
