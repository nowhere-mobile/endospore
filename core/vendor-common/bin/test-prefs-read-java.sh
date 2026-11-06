#!/usr/bin/env bash
# test-prefs-read-java.sh [--mutate] -- NWP-20261118-11: the sign-in's GET-PREFS read is retried when it fails, and
# the daemon answers it outside sessionMu.
#
# WHY THIS IS COMMITTED. On frankel 0.5.49 the gate's GET-PREFS read waited on sessionMu behind GRANT-PERMS, whose grant
# op ran 122.55 s. The 30 s read timed out, sendDaemonLines gave an empty list (the same as "no saved prefs"), and the
# session ran on the defaults: the idle cold lock armed at 15 minutes on a profile set to Never, and nothing reached
# login.log. Now the agent lists GET-PREFS in concurrentSafeCmd, and ChooserActivity.applyRoamedPrefs reads it through
# PrefsRead over DaemonSocket.roundTripLinesOrNull (null for a failed read), retried 1 s apart for 10 s after the
# first read ends. A read that still fails keeps the defaults and logs `[gate] TIMING prefs-unread <n>ms`.
#
# Two halves: the cases run PrefsRead.java as is under javac on a fake clock (core/chooser/tests/prefs-read/), and
# source pins check applyRoamedPrefs's read, its prefs-unread arm, gatePhaseOK's set holding that phase and the agent's
# allowlist entry. The java run has a hang guard (timeout 20), so a removed bound fails in seconds.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below.
# --mutate also needs perl and go (one mutant runs TestConcurrentSafeCmd on a copy of core/agent).
#
#   bash test-prefs-read-java.sh            # the cases and the pins
#   bash test-prefs-read-java.sh --mutate   # ... plus broken copies that must each be CONVICTED
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SRC="$ROOT/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/PrefsRead.java"
CHOOSER="$SRC/ChooserActivity.java"
AGENT="$ROOT/core/agent"
CASES="$ROOT/core/chooser/tests/prefs-read/PrefsReadCases.java"
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
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }

# cases <PrefsRead.java> -> 0 every case passes, 1 a case failed, the class is missing or the run hung, 3 no compile.
cases() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  PrefsRead.java does not exist (the read is not retried)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser" "$d/out"
  cp "$src" "$d/src/com/nowhere/chooser/PrefsRead.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/PrefsReadCases.java"
  if ! out=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d/out" \
      "$d/src/com/nowhere/chooser/PrefsRead.java" "$d/src/com/nowhere/chooser/PrefsReadCases.java" 2>&1); then
    printf '%s\n' "$out" >&2; rm -rf "$d"; return 3
  fi
  out=$(timeout 20 "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.PrefsReadCases 2>&1); rc=$?
  rm -rf "$d"
  printf '%s\n' "$out" | sed 's/^/  /'
  [ "$rc" = 124 ] && echo "  HUNG: the run did not end inside 20 s"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# body_of <ChooserActivity.java>: applyRoamedPrefs's lines, cut as test-tz-seed-java.sh cuts them, // comments and
# blank lines dropped (no // sits in a literal of its code).
body_of() {
  awk '/private void applyRoamedPrefs\(\)/ { on = 1 } on { l = $0; sub(/\/\/.*$/, "", l); if (l !~ /^[ \t]*$/) print l }
       on && /^    }$/ { exit }' "$1"
}

# pins <ChooserActivity.java> <main.go> -> 0 when every pin holds, 1 otherwise.
pins() {
  local chooser="$1" main="$2" body n arm next gpo cs bad=0
  body=$(body_of "$chooser")
  if [ -z "$body" ]; then echo "  FAIL  applyRoamedPrefs not found in $chooser" >&2; return 1; fi
  # P1: the read goes through PrefsRead over roundTripLinesOrNull, once each.
  n=$(printf '%s\n' "$body" | grep -cF 'PrefsRead.read(')
  [ "$n" -eq 1 ] || { echo "  FAIL  P1 applyRoamedPrefs calls PrefsRead.read( $n times, want 1" >&2; bad=1; }
  n=$(printf '%s\n' "$body" | grep -cF 'DaemonSocket.roundTripLinesOrNull("GET-PREFS\n", cap)')
  [ "$n" -eq 1 ] || { echo "  FAIL  P1 applyRoamedPrefs reads roundTripLinesOrNull(\"GET-PREFS\\n\", cap) $n times, want 1" >&2; bad=1; }
  # P2: no read that turns a timeout into an empty list.
  n=$(printf '%s\n' "$body" | grep -cF 'sendDaemonLines(')
  [ "$n" -eq 0 ] || { echo "  FAIL  P2 applyRoamedPrefs still reads through sendDaemonLines (a timeout reads as no prefs)" >&2; bad=1; }
  # P3: the null arm's first statement is the prefs-unread timing line.
  arm=$(printf '%s\n' "$body" | grep -nE '^ *if \(lines == null\) \{$' | cut -d: -f1)
  if [ "$(printf '%s\n' "$arm" | grep -c .)" != 1 ]; then
    echo "  FAIL  P3 applyRoamedPrefs has no single 'if (lines == null) {' arm" >&2; bad=1
  else
    next=$(printf '%s\n' "$body" | sed -n "$((arm + 1))p")
    case "$next" in
      *'gateTiming("prefs-unread", android.os.SystemClock.elapsedRealtime() - readT0);'*) ;;
      *) echo "  FAIL  P3 the null arm does not call gateTiming(\"prefs-unread\", ...) first: $next" >&2; bad=1 ;;
    esac
  fi
  # P3b: no pref value reaches a log, and no raw dump of every line.
  n=$(printf '%s\n' "$body" | grep -cF 'TextUtils.join("|", lines)')
  [ "$n" -eq 0 ] || { echo "  FAIL  P3b the raw GET-PREFS dump (lasttz= included) is logged" >&2; bad=1; }
  # P4: "prefs-unread" is in gateTimingPhases, the closed set gatePhaseOK checks (NWP-20261118-19). Both are pinned
  # as text: gatePhaseOK is the set lookup, and the set's literal holds the phase.
  gpo=$(awk '/^func gatePhaseOK\(s string\) bool \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$main")
  case "$gpo" in
    *'return gateTimingPhases[s]'*) ;;
    *) echo "  FAIL  P4 gatePhaseOK is not the gateTimingPhases lookup: re-pin prefs-unread against the new rule" >&2; bad=1 ;;
  esac
  gtp=$(awk '/^var gateTimingPhases = map\[string\]bool\{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$main")
  case "$gtp" in
    *'"prefs-unread": true,'*) ;;
    *) echo "  FAIL  P4 gateTimingPhases does not hold prefs-unread: the agent would answer ERR and log nothing" >&2; bad=1 ;;
  esac
  # P5: the agent's allowlist names GET-PREFS (the real proof is TestConcurrentSafeCmd, run by the Go mutant).
  cs=$(awk '/^func concurrentSafeCmd\(name string\) bool \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$main")
  n=$(printf '%s\n' "$cs" | grep -cE '^[[:space:]]*"GET-PREFS",$')
  [ "$n" -eq 1 ] || { echo "  FAIL  P5 concurrentSafeCmd lists \"GET-PREFS\", $n times, want 1" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== the cases"
cases "$SUT" || { echo "FAILED (cases)"; exit 1; }
echo "== the pins"
pins "$CHOOSER" "$AGENT/main.go" || { echo "FAILED (pins)"; exit 1; }
echo "  ok    every pin holds"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "FAIL: --mutate runs one mutant under go test, and there is no go" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates PrefsRead.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/PrefsRead.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  cases "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <perl-expr>   (mutates ChooserActivity.java; the pins must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  pins "$c" "$AGENT/main.go" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
gomut() { # gomut <label> <perl-expr>   (mutates main.go on a copy of core/agent; go test must print --- FAIL)
  local d c out; d=$(mktemp -d -p "$W") || return 1
  cp -r "$AGENT" "$d/agent"; c="$d/agent/main.go"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$AGENT/main.go" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(cd "$d/agent" && GOTMPDIR="$W" go test -count=1 -run 'TestConcurrentSafeCmd|TestGetPrefsAnswersWhileSessionMuHeld' . 2>&1)
  rm -rf "$d"
  case "$out" in
    *"--- FAIL"*) echo "  convicted $1"; return 0 ;;
    *) echo "  NOT CONVICTED  $1 -- no --- FAIL (a build failure is not a conviction)"; return 1 ;;
  esac
}
fails=0
mut "no retry (one attempt)" 's/while \(lines == null\) \{/while (lines == null && false) {/' || fails=$((fails+1))
mut "an empty list retried as a failure" 's/while \(lines == null\) \{/while (lines == null || lines.isEmpty()) {/' || fails=$((fails+1))
mut "the budget removed (a failing reader is read for ever; the hang guard convicts)" 's/\n *if \(left <= 0\) break;//' || fails=$((fails+1))
mut "a later read capped at 30 s" 's/return \(int\) Math\.max\(MIN_READ_MS, BUDGET_MS - \(nowMs - firstEndedMs\)\);/return FIRST_READ_MS;/' || fails=$((fails+1))
mut "the first read not capped at 30 s" 's/reader\.apply\(FIRST_READ_MS\)/reader.apply(MIN_READ_MS)/' || fails=$((fails+1))
mut "the last wait not cut to what is left" 's/Math\.min\(BACKOFF_MS, left\)/BACKOFF_MS/' || fails=$((fails+1))
mut "the budget runs from the start, not from the first read's end" 's/final long start = nowMs\.getAsLong\(\);/final long start = 0;/' || fails=$((fails+1))
mutsrc "the gateTiming call removed" 's/\n *gateTiming\("prefs-unread", [^\n]*//' || fails=$((fails+1))
mutsrc "back to sendDaemonLines" 's/java\.util\.List<String> lines = PrefsRead\.read\(\n.*?android\.os\.SystemClock::sleep\);/java.util.List<String> lines = sendDaemonLines("GET-PREFS\\n");/s' || fails=$((fails+1))
mutsrc "a raw dump of every line logged" 's/(raw = android\.text\.TextUtils\.join\("\|", )shown\);/${1}lines);/' || fails=$((fails+1))
gomut "GET-PREFS removed from concurrentSafeCmd" 's/\n\t\t"GET-PREFS",//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
