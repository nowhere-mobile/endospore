#!/usr/bin/env bash
# test-heal-retry-java.sh [--mutate] -- NWP-20261128-05: the install heal retries a restore that could not get the slot.
# AppInstallReceiver.heal sent RESTORE-ODDATA once with a 130 s round trip, while a seal can hold the RW worker slot for
# 7-9 minutes, and nothing in the session retried it for an On-demand app: a hand install during a long seal ran on
# fresh data. It also fired for an archived placeholder, whose restore can only keep the hold and answer ERR-NOTREADY.
# Now heal skips a package with no code, and its thread retries an empty reply, ERR-WORKER-BUSY, ERR-TIMEOUT and
# ERR-NOTREADY six times over about an hour (HealRetry.delayMs), stopping at a sign-out.
# This suite compiles HealRetry with core/chooser/tests/heal-retry/HealRetryCases.java ALONE and runs the cases R1-R9.
# Then it checks the REAL heal with comments dropped:
#   S1  heal returns on !UnarchiveService.hasInstalledCode(context, pkg) BEFORE the line holding `new Thread(`.
#   S2  the thread consults HealRetry.delayMs(.
#   S3  the thread checks SignOutGate.begun() after its Thread.sleep(.
#   S4  the thread checks UnarchiveService.odRestored(context, pkg) and hasInstalledCode(context, pkg) again.
#   S5  heal holds exactly one DaemonSocket.roundTrip("RESTORE-ODDATA\n" + pkg + "\n", 130000): the 130 s round trip
#       and the single send site test-daemon-verb-readers.sh pins as a one-line reader.
# test-install-heal.sh keeps pinning heal's call in onReceive, its signature and its marker line.
# Against origin/main before NWP-20261128-05 it FAILS: there is no HealRetry.java (the cases do not compile) and heal
# has no no-code skip (S1).
#
# It needs a JDK and perl, and it FAILS when either is missing. javac/java come from PATH, then the build VM's JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass:
#   M1 NONE retried (R2)                 M2 an empty reply stops (R4)       M3 the MAX_TRIES bound removed (R8)
#   M4 the no-code skip removed (S1)     M5 the SignOutGate check removed (S3)
#
#   bash core/vendor-common/bin/test-heal-retry-java.sh            # the cases and the source checks
#   bash core/vendor-common/bin/test-heal-retry-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-heal-retry-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-heal-retry-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/heal-retry/HealRetryCases.java
IDS="R1 R2 R3 R4 R5 R6 R7 R8 R9"

# cases <root>: compile <root>'s HealRetry with the cases ALONE and run them. 3 = no compile.
cases() {
  local d t out rc id bad=0
  d=$(mktemp -d -p "$W"); t=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/HealRetry.java" "$CASES" || return 3
  out=$("$JAVA" -Djava.io.tmpdir="$t" -cp "$d" com.nowhere.chooser.HealRetryCases 2>&1); rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || bad=1
  if grep -q '^FAIL ' <<<"$out"; then bad=1; fi
  for id in $IDS; do
    if ! grep -q "^ok $id " <<<"$out"; then echo "FAIL $id no ok line"; bad=1; fi
  done
  if [ -n "$(ls -A "$t")" ]; then echo "FAIL CT the cases left files in java.io.tmpdir"; bad=1; fi
  return "$bad"
}

# code <file> <signature line>: the member from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` in a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# has <text> <fixed string>: 0 when the text holds it (a here-string, never a pipe into grep -q).
has() { grep -qF -- "$2" <<<"$1"; }
# count <text> <fixed string>: how many lines hold it.
count() { grep -cF -- "$2" <<<"$1"; }
# lineno <text> <fixed string>: the first line that holds it, empty when none.
lineno() { grep -nF -- "$2" <<<"$1" | head -1 | cut -d: -f1; }

SIG='    private static void heal(Context context, String pkg, boolean replacing) {'
SKIP='if (!UnarchiveService.hasInstalledCode(context, pkg)) {'
SEND='DaemonSocket.roundTrip("RESTORE-ODDATA\n" + pkg + "\n", 130000)'

# sources <root>: S1-S5.
sources() {
  local r=$1 bad=0 body tl sl thread pre sleepl gl
  body=$(code "$r/$CH/AppInstallReceiver.java" "$SIG")
  if [ -z "$body" ]; then echo "EXTRACTION FAILED: heal's signature line not found"; return 2; fi
  tl=$(lineno "$body" 'new Thread(')
  if [ -z "$tl" ]; then echo "EXTRACTION FAILED: heal holds no new Thread("; return 2; fi
  thread=$(sed -n "$tl,\$p" <<<"$body")
  sl=$(lineno "$body" "$SKIP")
  if [ -z "$sl" ] || [ "$sl" -ge "$tl" ]; then
    echo "FAIL S1 heal does not check !UnarchiveService.hasInstalledCode(context, pkg) before new Thread("; bad=1
  else
    pre=$(sed -n "$sl,$((tl - 1))p" <<<"$body")
    if grep -q '^ *return; *$' <<<"$pre"; then echo "ok S1 heal skips a package with no code before its thread"
    else echo "FAIL S1 the no-code check before new Thread( does not return"; bad=1; fi
  fi
  if has "$thread" 'HealRetry.delayMs('; then echo "ok S2 the thread consults HealRetry.delayMs"
  else echo "FAIL S2 the thread does not consult HealRetry.delayMs"; bad=1; fi
  sleepl=$(lineno "$thread" 'Thread.sleep('); gl=$(lineno "$thread" 'SignOutGate.begun()')
  if [ -z "$sleepl" ]; then echo "FAIL S3 the thread never sleeps between tries"; bad=1
  elif [ -z "$gl" ] || [ "$gl" -le "$sleepl" ]; then
    echo "FAIL S3 the thread does not check SignOutGate.begun() after its Thread.sleep"; bad=1
  else echo "ok S3 the thread stops at a sign-out before the next try"; fi
  if ! has "$thread" 'UnarchiveService.odRestored(context, pkg)'; then
    echo "FAIL S4 the thread does not check UnarchiveService.odRestored(context, pkg)"; bad=1
  elif ! has "$thread" 'UnarchiveService.hasInstalledCode(context, pkg)'; then
    echo "FAIL S4 the thread does not check UnarchiveService.hasInstalledCode(context, pkg) again"; bad=1
  else echo "ok S4 the thread stops when the code is gone or the marker is written"; fi
  if [ "$(count "$body" "$SEND")" -ne 1 ]; then
    echo "FAIL S5 heal does not hold exactly one $SEND"; bad=1
  else echo "ok S5 heal sends RESTORE-ODDATA from one site with the 130 s round trip"; fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 2 extraction failed, 3 the cases did not compile.
check() {
  local rc=0 crc src
  cases "$1"; crc=$?
  sources "$1"; src=$?
  [ "$src" -eq 2 ] && return 2
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  [ "$src" -eq 0 ] || rc=1
  return "$rc"
}

check "$ROOT"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED (rc=$rc)"; exit 1; }
[ "$MUTATE" = yes ] || { echo "PASS test-heal-retry-java"; exit 0; }

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in HealRetry.java AppInstallReceiver.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $1 -- extraction failed"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4 " <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
H=$CH/HealRetry.java
R=$CH/AppInstallReceiver.java
fails=0 conv=0
tally() { if "$@"; then conv=$((conv+1)); else fails=$((fails+1)); fi; }
tally mut "M1 NONE retried" "$H" \
  's/if \(r\.equals\("NONE"\)\) return -1;/if (r.equals("NONE")) return FIRST_DELAY_MS;/' R2
tally mut "M2 an empty reply stops" "$H" \
  's/if \(r\.isEmpty\(\)/if (false/' R4
tally mut "M3 the MAX_TRIES bound removed" "$H" \
  's/attempt >= MAX_TRIES/false/' R8
tally mut "M4 the no-code skip removed" "$R" \
  's/\n[ \t]*if \(!UnarchiveService\.hasInstalledCode\(context, pkg\)\) \{.*?return;\s*\}//s' S1
tally mut "M5 the SignOutGate check removed" "$R" \
  's/SignOutGate\.begun\(\) \? "sign-out begun"\s*: //' S3
echo "== $conv convicted, $fails failed"
[ "$fails" -eq 0 ] && [ "$conv" -eq 5 ] || exit 1
echo "PASS test-heal-retry-java --mutate"
