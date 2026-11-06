#!/usr/bin/env bash
# test-remove-retry-java.sh [--mutate] -- the gate reap's reboot decision, run under javac (NWP-20261026-20).
#
# WHY THIS IS COMMITTED. ChooserActivity.doRemove retries removeUser every 1.5 s and, when the user will not go, reboots
# the device. A reboot destroys every profile's sealed telephony records (RAM, under /data/nowhere/state/tel), so
# before it the gate asks the daemon's TEL-PENDING and, unless the answer is exactly "OK 0", retries one more grace
# (docs/product-decisions.md 2026-09-27, answer 4). RemoveRetry holds that rule (pure, java.lang only) and is compiled
# here with its cases; an ORDER check over doRemove's body pins WHERE it sits: the ask runs on its own thread (a
# roundTrip on the main looper would stall the gate for up to its 5 s cap) and dpm.reboot is reached only from a
# RemoveRetry REBOOT decision. With --mutate the daemon arm's own mutants run under go test.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-remove-retry-java.sh            # the cases and the order check
#   bash test-remove-retry-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/RemoveRetry.java"
CHOOSER="$SRC/ChooserActivity.java"
CASES="$root/core/chooser/tests/remove-retry/RemoveRetryCases.java"
AGENT="$root/core/agent"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: the order check strips comments with perl, and there is none" >&2; exit 2; }

# suite <RemoveRetry.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  RemoveRetry.java does not exist (the decision is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/RemoveRetry.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/RemoveRetryCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.RemoveRetryCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# first_line <body> <regex> -> the first matching line number, empty when none. Captured, never piped into grep -q.
first_line() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { print NR; exit }'; }
# count_lines <body> <regex> -> how many lines match.
count_lines() { printf '%s\n' "$1" | RE="$2" awk '$0 ~ ENVIRON["RE"] { n++ } END { print n + 0 }'; }

# order <ChooserActivity.java> -> 0 when the shipped order holds, 1 otherwise. Comments are stripped first (their line
# breaks kept), so a comment that names roundTrip or dpm.reboot proves nothing either way.
order() {
  local chooser="$1" body bad=0 raw
  local present_t next_n rt nt nm ret_first o3
  raw=$(awk '/private static void doRemove\(/ { on = 1 } on { print } on && /^    }$/ { exit }' "$chooser")
  [ -n "$raw" ] || { echo "  FAIL  doRemove not found in $chooser" >&2; return 1; }
  body=$(printf '%s\n' "$raw" | perl -0pe 's{/\*.*?\*/}{ (my $x = $&) =~ s/[^\n]//g; $x }gse; s{//[^\n]*}{}g')

  next_n=$(count_lines "$body" 'RemoveRetry\.next\(')
  [ "$next_n" -ge 2 ] || { echo "  FAIL  order: $next_n RemoveRetry.next( calls in doRemove, want the tick's and the answer's" >&2; bad=1; }

  # The ask: exactly one TEL-PENDING round trip, inside the new Thread( block named nowhere-reap-telpending.
  [ "$(count_lines "$body" 'roundTrip\("TEL-PENDING')" -eq 1 ] \
    || { echo "  FAIL  order: want exactly one roundTrip(\"TEL-PENDING\" in doRemove" >&2; bad=1; }
  rt=$(first_line "$body" 'roundTrip\("TEL-PENDING')
  if [ -n "$rt" ]; then
    nt=$(printf '%s\n' "$body" | awk -v r="$rt" 'NR < r && /new Thread\(/ { n = NR } END { print n + 0 }')
    nm=$(printf '%s\n' "$body" | awk -v s="$nt" 'NR > s && /, "nowhere-[a-z-]*"/ { print NR; exit }')
    if [ "$nt" -eq 0 ] || [ -z "$nm" ] || [ "$nm" -le "$rt" ] \
       || ! printf '%s\n' "$body" | awk -v n="$nm" 'NR == n && /"nowhere-reap-telpending"/ { f = 1 } END { exit f ? 0 : 1 }'; then
      echo "  FAIL  order: the TEL-PENDING round trip is not inside the nowhere-reap-telpending thread (it would run on the main looper)" >&2
      bad=1
    fi
  fi

  [ -z "$(first_line "$body" '\+\+tries >= ')" ] \
    || { echo "  FAIL  order: a ++tries >= threshold is back in doRemove (the grace lives in RemoveRetry)" >&2; bad=1; }

  # The presence check stays at the top of the tick.
  present_t=$(first_line "$body" 'if \(!userPresent\(dpm, admin, uid\)\)')
  if [ -z "$present_t" ]; then
    echo "  FAIL  order: doRemove has no userPresent test" >&2; bad=1
  else
    ret_first=$(printf '%s\n' "$body" | awk '/RemoveRetry\.next\(|roundTrip\(|dpm\.reboot\(/ { print NR; exit }')
    [ -z "$ret_first" ] || [ "$present_t" -lt "$ret_first" ] \
      || { echo "  FAIL  order: the userPresent test is not before the first next/roundTrip/reboot" >&2; bad=1; }
  fi

  # dpm.reboot(admin) is reached only inside a RemoveRetry.REBOOT test, which follows the decision.
  o3=$(printf '%s\n' "$body" | awk '
    { line[NR] = $0; start[NR] = depth; s = $0; instr = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (instr) { if (c == "\\") i++; else if (c == "\"") instr = 0; continue }
        if (c == "\"") { instr = 1; continue }
        if (c == "{") depth++; else if (c == "}") depth--
      } }
    END {
      asg = 0; rb = 0; nrb = 0
      for (i = 1; i <= NR; i++) {
        if (!asg && line[i] ~ /=[ ]*RemoveRetry\.next\(/) asg = i
        if (line[i] ~ /dpm\.reboot\(admin\)/) { nrb++; rb = i }
      }
      if (nrb != 1) { print "want exactly one dpm.reboot(admin) in doRemove, found " nrb; exit }
      gi = 0
      for (i = rb - 1; i >= 1; i--) if (line[i] ~ /RemoveRetry\.REBOOT\.equals\(/) { gi = i; break }
      if (!gi) { print "no RemoveRetry.REBOOT test before dpm.reboot(admin)"; exit }
      if (!asg || gi < asg) { print "the REBOOT test does not follow a RemoveRetry.next decision"; exit }
      for (i = gi + 1; i <= rb; i++) {
        if (start[i] <= start[gi]) { print "dpm.reboot(admin) is outside the REBOOT test'"'"'s block"; exit }
        if (start[i] == start[gi] + 1 && line[i] ~ /^[ \t]*\}/) { print "the REBOOT test'"'"'s block closes before dpm.reboot(admin)"; exit }
      }
    }')
  [ -z "$o3" ] || { echo "  FAIL  order: $o3" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
order "$CHOOSER" || { echo "FAILED (order)"; exit 1; }
echo "order: ok"
[ "$MUTATE" = yes ] || exit 0

command -v go >/dev/null 2>&1 || { echo "FAIL: --mutate runs the daemon arm's mutants under go test, and there is no go" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates RemoveRetry.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/RemoveRetry.java"
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
mutord() { # mutord <label> <perl-expr>   (mutates ChooserActivity.java; the order check must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/ChooserActivity.java"
  cp "$CHOOSER" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$CHOOSER" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  order "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
gomut() { # gomut <label> <perl-expr>   (mutates the daemon's main.go on a copy; TestTelPendingVerb must print --- FAIL)
  local d c out; d=$(mktemp -d -p "$W") || return 1
  cp -r "$AGENT" "$d/agent"; c="$d/agent/main.go"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$AGENT/main.go" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(cd "$d/agent" && GOTMPDIR="$W" go test -count=1 -run 'TestTelPendingVerb' . 2>&1)
  rm -rf "$d"
  case "$out" in
    *"--- FAIL"*) echo "  convicted $1"; return 0 ;;
    *) echo "  NOT CONVICTED  $1 -- no --- FAIL (a build failure is not a conviction)"; return 1 ;;
  esac
}
fails=0
mut "OK 0 treated as EXTEND" 's/"OK 0"\.equals\(pendingReply\.trim\(\)\) \? REBOOT : EXTEND/"OK 0".equals(pendingReply.trim()) ? EXTEND : EXTEND/' || fails=$((fails+1))
mut "an empty reply treated as REBOOT" 's/pendingReply != null && "OK 0"\.equals\(pendingReply\.trim\(\)\)/(pendingReply == null || pendingReply.trim().isEmpty() || "OK 0".equals(pendingReply.trim()))/' || fails=$((fails+1))
mut "the extension allowed twice" 's/        if \(extended\) return REBOOT;\n//' || fails=$((fails+1))
mut "countWords leaks the reply" 's/return "an unknown number of";/return r;/' || fails=$((fails+1))
mutord "the TEL-PENDING round trip moved onto the Runnable's run()" 's/(                    try \{ dpm\.removeUser\(admin, android\.os\.UserHandle\.of\(uid\)\); \} catch \(Throwable ignore\) \{\}\n)/$1                    String early = DaemonSocket.roundTrip("TEL-PENDING\\n", 5000);\n/; s/got = DaemonSocket\.roundTrip\("TEL-PENDING\\n", 5000\);/got = "";/' || fails=$((fails+1))
mutord "the reboot not gated by a REBOOT decision (the old ++tries shape)" 's/(                    try \{ dpm\.removeUser\(admin, android\.os\.UserHandle\.of\(uid\)\); \} catch \(Throwable ignore\) \{\}\n)/$1                    if (++tries >= 16) { try { dpm.reboot(admin); } catch (Throwable t) {} return; }\n/; s/\n[ ]*try \{ dpm\.reboot\(admin\); \} catch \(Throwable t\) \{ android\.util\.Log\.w\("NowhereChooser", "dpm\.reboot", t\); \}//' || fails=$((fails+1))
gomut "TEL-PENDING out of concurrentSafeCmd" 's/\t\t"TEL-PENDING",\n//' || fails=$((fails+1))
gomut "the TEL-PENDING arm's gateCallerOK check removed" 's/(if name == "TEL-PENDING" \{.*?)if !gateCallerOK\(ownerPeerUID\(conn\)\) \{/$1if false {/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
