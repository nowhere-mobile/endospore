#!/usr/bin/env bash
# test-evict-retry-java.sh [--mutate] -- the cold-lock eviction re-check keeps asking while the daemon answers
# "RETRY busy" (Q183, DECIDED 2026-10-20), run under javac (NWP-20261109-07).
#
# WHY THIS IS COMMITTED. An op the daemon abandoned can hold the RW lane busy for minutes after a cold lock. The
# re-check used to count a busy answer like any other non-answer, so five of them ended it and a CE that stayed
# readable after a landed save was left for the 12 h wipe. EvictRetry is pure java.lang and is compiled here with its
# cases; source pins over ChooserActivity.java hold the wiring (busy is not counted, the bound is read once, the
# generation check still precedes each ask).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
#
#   bash test-evict-retry-java.sh            # the cases and the pins
#   bash test-evict-retry-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/EvictRetry.java"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/evict-retry/EvictRetryCases.java"
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

# suite <EvictRetry.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  EvictRetry.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/EvictRetry.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/EvictRetryCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.EvictRetryCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# mbody <file> <regex>: a method's body, from its signature to the closing brace at four spaces.
mbody() { RE="$2" awk '$0 ~ ENVIRON["RE"] { on = 1 } on { print } on && /^    }$/ { exit }' "$1"; }
# count <body> <regex>: matching non-comment lines.
count() { printf '%s\n' "$1" | RE="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && $0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }
# first_line <body> <regex>: the first matching non-comment line number, empty when none.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 !~ /^[ \t]*(\/\/|\*|\/\*)/ && $0 ~ ENVIRON["RE"] { print NR; exit }'; }

# pins <ChooserActivity.java> -> 0 when the wiring holds, 1 otherwise.
pins() {
  local f="$1" bad=0 er b l g a inc busyline
  er=$(mbody "$f" 'private static void evictRecheck\(')
  [ -n "$er" ] || { echo "  FAIL  pins: evictRecheck body not found in $f" >&2; return 1; }
  # S1: noVerdict is incremented only on the path where EvictRetry.busy(reply) is false.
  [ "$(count "$er" 'noVerdict\+\+')" -eq 1 ] \
    || { echo "  FAIL  pins: evictRecheck must increment noVerdict exactly once" >&2; bad=1; }
  inc=$(first_line "$er" 'noVerdict\+\+')
  busyline=$(first_line "$er" 'if \(EvictRetry\.busy\(reply\)\) \{')
  if [ -z "$busyline" ] || [ -z "$inc" ] || [ "$busyline" -ge "$inc" ]; then
    echo "  FAIL  pins: evictRecheck does not test EvictRetry.busy(reply) before the count" >&2; bad=1
  elif ! printf '%s\n' "$er" | awk -v b="$busyline" -v i="$inc" \
      'NR > b && NR < i && /^            \} else \{$/ { ok = 1 } END { exit ok ? 0 : 1 }'; then
    echo "  FAIL  pins: noVerdict++ is not on the else branch of the busy test" >&2; bad=1
  fi
  # S2: the bound is read once, before the loop, and giveUp is called with that local.
  b=$(first_line "$er" 'final long boundMs = EvictRetry\.bound\(sWipeTimeoutMs, HARD_WIPE_MS\);')
  l=$(first_line "$er" 'for \(;;\) \{')
  w=$(first_line "$er" 'Thread\.sleep\(wait\)')
  [ -n "$w" ] && [ -n "$b" ] && [ "$b" -lt "$w" ] \
    || { echo "  FAIL  pins: evictRecheck must read the bound before its initial wait (a sign-in during it rewrites sWipeTimeoutMs)" >&2; bad=1; }
  [ "$(count "$er" 'EvictRetry\.bound\(')" -eq 1 ] && [ -n "$b" ] && [ -n "$l" ] && [ "$b" -lt "$l" ] \
    || { echo "  FAIL  pins: evictRecheck must read EvictRetry.bound(sWipeTimeoutMs, HARD_WIPE_MS) once before its wait and loop" >&2; bad=1; }
  [ "$(count "$er" 'EvictRetry\.giveUp\(noVerdict, .*, boundMs\)')" -eq 1 ] \
    || { echo "  FAIL  pins: evictRecheck must call EvictRetry.giveUp(noVerdict, ..., boundMs)" >&2; bad=1; }
  # S3: the generation check is still before each ask.
  g=$(first_line "$er" 'sColdLockGen\.get\(\) != gen')
  a=$(first_line "$er" 'DaemonSocket\.roundTrip\(')
  { [ -n "$g" ] && [ -n "$a" ] && [ "$g" -lt "$a" ] && [ -n "$l" ] && [ "$l" -lt "$g" ]; } \
    || { echo "  FAIL  pins: the sColdLockGen check is not inside the loop before the ask" >&2; bad=1; }
  # S4: no fixed five-attempt bound remains.
  [ "$(count "$er" 'attempt <= 5')" -eq 0 ] \
    || { echo "  FAIL  pins: evictRecheck still bounds its loop at 'attempt <= 5'" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
pins "$CHOOSER" || { echo "FAILED (pins)"; exit 1; }
echo "pins: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates EvictRetry.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/EvictRetry.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  CONVICTED $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutpin() { # mutpin <label> <perl-expr>   (mutates ChooserActivity.java; the pins must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  pins "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  CONVICTED $1"
}
fails=0
mutpin "M1 busy counted like any other answer" 's/if \(EvictRetry\.busy\(reply\)\) \{/if (false) {/' || fails=$((fails+1))
mutpin "M2 the bound argument replaced by Long.MAX_VALUE" 's/EvictRetry\.giveUp\(noVerdict, (.*?), boundMs\)/EvictRetry.giveUp(noVerdict, $1, Long.MAX_VALUE)/' || fails=$((fails+1))
mut "M3 giveUp uses > instead of >= for the tries" 's/noVerdict >= NO_VERDICT_TRIES/noVerdict > NO_VERDICT_TRIES/' || fails=$((fails+1))
mut "M4 busy() matches every RETRY" 's/startsWith\("RETRY busy"\)/startsWith("RETRY")/' || fails=$((fails+1))
mut "M5 bound() returns wipeMs unconditionally" 's/return wipeMs > 0 \? wipeMs : hardWipeMs;/return wipeMs;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "PASS: 5 of 5 mutants convicted" || { echo "== $fails mutant(s) not convicted"; exit 1; }
