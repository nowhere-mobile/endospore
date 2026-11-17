#!/usr/bin/env bash
# test-od-restore-once-java.sh [--mutate] -- NWP-20261202-38: one restore per install of a package.
# After installApks, UnarchiveService.materializeLocked sent RESTORE-ODDATA, and the same install's PACKAGE_ADDED made
# AppInstallReceiver.heal send another one at the same time. Only the first did any work; each later one answered
# `OK NOSRC` but still made roamd run grant_perms_for, keystore_register and the reown. Now every single-package sender
# in the session chooser goes through OdRestoreOnce: one restore per install (PackageInfo.lastUpdateTime) per chooser
# process; a later sender finds it landed or in flight, sends nothing and takes its reply; a non-OK reply records
# nothing, so every retry still sends.
# This suite compiles OdRestoreOnce with core/chooser/tests/od-restore-once/OdRestoreOnceCases.java ALONE and runs:
#   C1  a second send of one install after an OK does not call its sender and returns the first reply
#   C2  a follower of an in-flight send of the same install waits, sends nothing and returns the leader's reply
#   C3  after ERR-NOTREADY, "", ERR-WORKER-BUSY or no reply the next send calls its sender
#   C4  a new stamp sends again          C5  stamp -1 always sends
#   C6  a throwing sender releases its claim; the next send calls its sender
#   C7  with waitMs=200 a follower of a leader that never answers returns "" without sending
#   C8  record() keeps an OK only, never for stamp -1     C9  two packages never share a reply
#   C10 sendShared sends after a landed OK, but shares an in-flight send
#   CL  every log line is an od-restore-once line, and none names a package
# Every wait in a case is a 30 s hang guard that FAILS, never a timing assertion.
# Then it checks the REAL chooser sources with comments dropped:
#   S1  every statement in core/chooser/src building a single-name request ("RESTORE-ODDATA\n" + pkg) is an
#       OdRestoreOnce.send( statement, except ChooserActivity.installRoamedAppCode (the user-0 gate's sign-in
#       restore, another process). In OdDataBarrierHost.java it must be OdRestoreOnce.sendShared(, never send(: the
#       barrier's retry runs while the data is out, so a landed OK must not stop it.
#       Control: at least 4 wrapped sites.
#   S2  restoreOnlyListLocked calls OdRestoreOnce.record( before restoreOnlyReplied(.
# Against origin/main before NWP-20261202-38 it FAILS: there is no OdRestoreOnce.java (the cases do not compile), S1
# finds four unwrapped sends and S2 finds no record call.
#
# It needs a JDK and perl, and it FAILS when either is missing. javac/java come from PATH, then the build VM's JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass:
#   M1 the landed check removed (C1)          M2 the follower sends instead of waiting (C2)
#   M3 a non-OK reply recorded (C3)           M4 LANDED matched without the stamp (C4)
#   M5 the stamp -1 bypass removed (C5)       M6 the leader's claim release removed (C6)
#   M7 the follower's wait unbounded (C7)     M8 heal unwrapped (S1)
#   M9 materializeLocked unwrapped (S1)       M10 the list path's record call dropped (S2)
#   M11 sendShared takes the landed check (C10)  M12 the barrier retry uses send, not sendShared (S1)
# M7 costs one 30 s hang guard: that is how an unbounded wait is convicted.
#
#   bash core/vendor-common/bin/test-od-restore-once-java.sh            # the cases and the source checks
#   bash core/vendor-common/bin/test-od-restore-once-java.sh --mutate   # ... plus the mutants
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
  echo "test-od-restore-once-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-od-restore-once-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/od-restore-once/OdRestoreOnceCases.java
IDS="C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 CL"

# cases <root>: compile <root>'s OdRestoreOnce with the cases ALONE and run them. 3 = no compile.
cases() {
  local d t out rc id bad=0
  d=$(mktemp -d -p "$W"); t=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/OdRestoreOnce.java" "$CASES" || return 3
  out=$("$JAVA" -Djava.io.tmpdir="$t" -cp "$d" com.nowhere.chooser.OdRestoreOnceCases 2>&1); rc=$?
  printf '%s\n' "$out"
  [ "$rc" -eq 0 ] || bad=1
  if grep -q '^FAIL ' <<<"$out"; then bad=1; fi
  for id in $IDS; do
    if ! grep -q "^ok $id " <<<"$out"; then echo "FAIL $id no ok line"; bad=1; fi
  done
  if [ -n "$(ls -A "$t")" ]; then echo "FAIL CT the cases left files in java.io.tmpdir"; bad=1; fi
  return "$bad"
}

# sources <root>: S1-S2. The perl drops comments (a `//` or `/*` inside a string is kept).
sources() {
  local r=$1 out
  out=$(perl -e '
    my ($dir) = @ARGV;
    sub strip { my $s = shift;
      $s =~ s{("(?:[^"\\\n]|\\.)*")|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gse; return $s; }
    sub slurp { my $f = shift; open(my $h, "<", $f) or die "$f: $!"; local $/; my $s = <$h>; return $s; }
    opendir(my $dh, $dir) or die "$dir: $!";
    my ($wrapped, @bad, $exempt) = (0);
    for my $n (sort grep { /\.java$/ } readdir $dh) {
      my $s = slurp("$dir/$n");
      if ($n eq "ChooserActivity.java") {
        $exempt = ($s =~ s/^    private java\.util\.Set<String> installRoamedAppCode\(int uid\) \{\n.*?^    \}\n//ms) ? 1 : 0;
      }
      $s = strip($s);
      for my $st (split /[;{}]/, $s) {
        next unless index($st, q{"RESTORE-ODDATA\n" + pkg}) >= 0;
        (my $one = $st) =~ s/\s+/ /g; $one =~ s/^ //;
        if ($n eq "OdDataBarrierHost.java") {
          if (index($st, "OdRestoreOnce.sendShared(") >= 0) { $wrapped++; }
          else { push @bad, "$n (the barrier retry must use sendShared, never send): $one"; } }
        elsif (index($st, "OdRestoreOnce.send(") >= 0) { $wrapped++; }
        else { push @bad, "$n: $one"; }
      }
    }
    if (!$exempt) { print "EXTRACTION FAILED: ChooserActivity.installRoamedAppCode not found\n"; exit 2; }
    print "FAIL S1 a single-name RESTORE-ODDATA send outside OdRestoreOnce -- $_\n" for @bad;
    if ($wrapped < 4) { print "FAIL S1 control: $wrapped wrapped sites, want >= 4\n"; }
    elsif (!@bad) { print "ok S1 every single-name RESTORE-ODDATA send in the session chooser goes through OdRestoreOnce ($wrapped sites)\n"; }
    my $u = strip(slurp("$dir/UnarchiveService.java"));
    if ($u !~ /private void restoreOnlyListLocked\(java\.util\.List<String> keep\) \{(.*?)\n    \}\n/s) {
      print "EXTRACTION FAILED: restoreOnlyListLocked not found\n"; exit 2; }
    my $b = $1; my $ri = index($b, "OdRestoreOnce.record("); my $ti = index($b, "restoreOnlyReplied(");
    if ($ri < 0) { print "FAIL S2 restoreOnlyListLocked never calls OdRestoreOnce.record(\n"; }
    elsif ($ti < 0 || $ri > $ti) { print "FAIL S2 restoreOnlyListLocked does not call OdRestoreOnce.record( before restoreOnlyReplied(\n"; }
    else { print "ok S2 restoreOnlyListLocked records each OK before restoreOnlyReplied\n"; }
  ' "$r/$CH" 2>&1)
  local prc=$?
  printf '%s\n' "$out"
  if [ "$prc" -eq 2 ] || grep -q '^EXTRACTION FAILED' <<<"$out"; then return 2; fi
  [ "$prc" -eq 0 ] || { echo "FAIL S0 the perl check did not run (rc=$prc)"; return 1; }
  if grep -q '^FAIL ' <<<"$out"; then return 1; fi
  if ! grep -q '^ok S1 ' <<<"$out" || ! grep -q '^ok S2 ' <<<"$out"; then echo "FAIL S0 a source check printed no verdict"; return 1; fi
  return 0
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
[ "$MUTATE" = yes ] || { echo "PASS test-od-restore-once-java"; exit 0; }

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in "$ROOT/$CH"/*.java; do cp "$n" "$d/$CH/"; done
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
O=$CH/OdRestoreOnce.java
U=$CH/UnarchiveService.java
R=$CH/AppInstallReceiver.java
B=$CH/OdDataBarrierHost.java
fails=0 conv=0
tally() { if "$@"; then conv=$((conv+1)); else fails=$((fails+1)); fi; }
tally mut "M1 the landed check removed" "$O" \
  's/if \(landedHolds && l != null && l\.stamp == stamp\)/if (false \&\& landedHolds \&\& l != null \&\& l.stamp == stamp)/' C1
tally mut "M2 the follower sends instead of waiting" "$O" \
  's/if \(landedReply == null && other == null\) \{/if (landedReply == null) {/' C2
tally mut "M3 a non-OK reply recorded" "$O" \
  's/return r\.startsWith\("OK"\);/return true;/' C3
tally mut "M4 LANDED matched without the stamp" "$O" \
  's/ && l\.stamp == stamp\)/)/' C4
tally mut "M5 the stamp -1 bypass removed" "$O" \
  's/\n[ \t]*if \(stamp < 0\) return trim\(sender\.get\(\)\);[^\n]*//' C5
tally mut "M6 the leader's claim release removed" "$O" \
  's/\n[ \t]*if \(FLIGHT\.get\(pkg\) == mine\) FLIGHT\.remove\(pkg\);//' C6
tally mut "M7 the follower's wait unbounded" "$O" \
  's/other\.done\.get\(waitMs, TimeUnit\.MILLISECONDS\)/other.done.get()/' C7
tally mut "M8 heal unwrapped" "$R" \
  's/r = OdRestoreOnce\.send\(pkg, UnarchiveService\.installStamp\(context, pkg\), \(\) -> (DaemonSocket\.roundTrip\("RESTORE-ODDATA\\n" \+ pkg \+ "\\n", 130000\)), m -> android\.util\.Log\.i\("NowhereChooser", m\)\);/r = $1.trim();/' S1
tally mut "M9 materializeLocked unwrapped" "$U" \
  's/String rr = OdRestoreOnce\.send\(pkg, installStamp\(this, pkg\), \(\) -> (daemon\("RESTORE-ODDATA\\n" \+ pkg \+ "\\n"\)), m -> android\.util\.Log\.i\("NowhereChooser", m\)\);(\n[ \t]*android\.util\.Log\.i\("NowhereChooser", "RESTORE-ODDATA " \+ pkg \+ " -> ")/String rr = $1;$2/' S1
tally mut "M10 the list path's record call dropped" "$U" \
  's/\n[ \t]*OdRestoreOnce\.record\(pkg, installStamp\(this, pkg\), replies\.get\(pkg\)\);[^\n]*//' S2
tally mut "M11 sendShared takes the landed check" "$O" \
  's/return run\(pkg, stamp, sender, log, false\);/return run(pkg, stamp, sender, log, true);/' C10
tally mut "M12 the barrier retry uses send, not sendShared" "$B" \
  's/r = OdRestoreOnce\.sendShared\(pkg, /r = OdRestoreOnce.send(pkg, /' S1
echo "== $conv convicted, $fails failed"
[ "$fails" -eq 0 ] && [ "$conv" -eq 12 ] || exit 1
echo "PASS test-od-restore-once-java --mutate"
