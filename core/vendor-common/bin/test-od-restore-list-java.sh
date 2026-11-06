#!/usr/bin/env bash
# test-od-restore-list-java.sh [--mutate] -- NWP-20261128-16 (h53 #1): the Auto sweep's restore-only retries go to the
# daemon as RESTORE-ODDATA lists. sweepAuto used to send one RESTORE-ODDATA per app, and each request paid the daemon's
# shared reads (the `pm list packages -3` grant read) again: 71 restores held the worker for about 9 minutes. Now one
# request carries up to OdRestoreList.CHUNK apps (the daemon takes 16, NWP-20261125-08), and each app is marked only on
# its own OK line. A cut reply or STOPPED is no reply: no marker, the next sweep retries.
# This suite compiles OdRestoreList with core/chooser/tests/od-restore-list/OdRestoreListCases.java ALONE and runs the
# cases (L1-L12: the request text and the refusal of 1 or CHUNK+1 names; a full, a cut and a STOPPED reply; one-line
# NONE, OK LOCAL and ERR-PKG for every package; a line not sent, lines out of order, END alone, no lines, a duplicate
# line). Then it checks the REAL UnarchiveService with comments dropped:
#   P1  sweepAuto walks retry in chunks of OdRestoreList.CHUNK; each chunk checks SignOutGate.begun() first, takes
#       MAT_LOCK, re-reads autoAction(hasInstalledCode(pkg), odRestored(pkg), false) under it, sends one app through
#       restoreOnlyLocked and two or more through restoreOnlyListLocked, and unlocks in a finally.
#   P2  restoreOnlyListLocked sends OdRestoreList.request(keep) through DaemonSocket.roundTripLines at a 130 s read cap,
#       parses against keep, and hands each app its own reply through restoreOnlyReplied; it marks nothing itself.
#   P3  restoreOnlyLocked sends the one-name request and returns restoreOnlyReplied(pkg, rr); restoreOnlyReplied holds
#       the OK test, the marker and the wake (marker first), and it is the only member that logs the restore-only reply.
#   P4  OdRestoreList.CHUNK is 8, and request refuses fewer than 2 or more than CHUNK names.
#
# It needs a JDK and perl, and it FAILS when either is missing. javac/java come from PATH, then the build VM's JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass:
#   M1 a missing line read as OK (L4)            M2 STOPPED read as OK (L5)
#   M3 a one-line NONE applied to the first package only (L6)
#   M4 the SignOutGate check removed from the chunk loop (P1)
#   M5 the autoAction re-read under the lock removed (P1)
#   M6 the list path marks on its own, not through restoreOnlyReplied (P2)
#   M7 CHUNK raised to 16 (P4)
#
#   bash core/vendor-common/bin/test-od-restore-list-java.sh            # the cases and the source checks
#   bash core/vendor-common/bin/test-od-restore-list-java.sh --mutate   # ... plus the mutants
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
  echo "test-od-restore-list-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-od-restore-list-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir, case dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/od-restore-list/OdRestoreListCases.java
IDS="L1 L2 L3 L4 L5 L6 L7 L8 L9 L10 L11 L12"

# cases <root>: compile <root>'s OdRestoreList with the cases ALONE and run them. 3 = no compile.
cases() {
  local d t out rc id bad=0
  d=$(mktemp -d -p "$W"); t=$(mktemp -d -p "$W")
  [ -f "$1/$CH/OdRestoreList.java" ] || { echo "FAIL L0 no $CH/OdRestoreList.java"; return 3; }
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/OdRestoreList.java" "$CASES" || return 3
  out=$("$JAVA" -Djava.io.tmpdir="$t" -cp "$d" com.nowhere.chooser.OdRestoreListCases 2>&1); rc=$?
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

# sources <root>: P1-P4. 2 = a member was not found.
sources() {
  local r=$1 bad=0 u sweep ronly rtail rlist odl mk wk out
  u="$r/$CH/UnarchiveService.java"
  [ -f "$r/$CH/OdRestoreList.java" ] || { echo "EXTRACTION FAILED: no OdRestoreList.java"; return 2; }
  sweep=$(code "$u" '    private void sweepAuto(boolean byHand) {')
  ronly=$(code "$u" '    private boolean restoreOnlyLocked(String pkg) {')
  rtail=$(code "$u" '    private boolean restoreOnlyReplied(String pkg, String rr) {')
  rlist=$(code "$u" '    private void restoreOnlyListLocked(java.util.List<String> keep) {')
  odl=$(grep -v '^[[:space:]]*\(//\|\*\|/\*\)' "$r/$CH/OdRestoreList.java")
  if [ -z "$sweep" ] || [ -z "$ronly" ] || [ -z "$rtail" ] || [ -z "$rlist" ] || [ -z "$odl" ]; then
    echo "EXTRACTION FAILED: sweepAuto=${#sweep} restoreOnlyLocked=${#ronly} restoreOnlyReplied=${#rtail}" \
         "restoreOnlyListLocked=${#rlist} OdRestoreList=${#odl}"
    return 2
  fi
  # P1: the chunk loop, line by line in order (whitespace between lines is free).
  out=$(perl -0777 -ne '
    my $s = $_; my @f;
    my $loop = q(for (int c = 0; c < retry.size(); c += OdRestoreList.CHUNK) {);
    my $i = index($s, $loop);
    if ($i < 0) { push @f, "sweepAuto does not walk retry in chunks of OdRestoreList.CHUNK"; }
    else {
      my $b = substr($s, $i + length($loop));
      push @f, "the chunk loop does not check SignOutGate.begun() before anything else"
        unless $b =~ /\A\s*if \(SignOutGate\.begun\(\)\) break;\s*java\.util\.List<String> chunk = retry\.subList\(c, Math\.min\(c \+ OdRestoreList\.CHUNK, retry\.size\(\)\)\);\s*MAT_LOCK\.lock\(\);/;
      push @f, "the chunk loop does not re-read autoAction(hasInstalledCode(pkg), odRestored(pkg), false) under MAT_LOCK"
        unless $b =~ /\A[^}]*?MAT_LOCK\.lock\(\);\s*try \{\s*java\.util\.List<String> keep = new ArrayList<>\(\);\s*for \(String pkg : chunk\) \{\s*if \(autoAction\(hasInstalledCode\(pkg\), odRestored\(pkg\), false\)\s*== AUTO_RESTORE_ONLY\) keep\.add\(pkg\);\s*\}/;
      push @f, "the chunk loop does not send one app through restoreOnlyLocked and two or more through restoreOnlyListLocked"
        unless $b =~ /keep\.add\(pkg\);\s*\}\s*if \(keep\.size\(\) == 1\) restoreOnlyLocked\(keep\.get\(0\)\);\s*else if \(keep\.size\(\) > 1\) restoreOnlyListLocked\(keep\);\s*\} catch \(Throwable t\) \{[^}]*\} finally \{\s*MAT_LOCK\.unlock\(\);\s*\}\s*\}/;
    }
    my $n1 = () = $s =~ /\brestoreOnlyLocked\(/g; my $n2 = () = $s =~ /\brestoreOnlyListLocked\(/g;
    push @f, "sweepAuto holds $n1 restoreOnlyLocked( and $n2 restoreOnlyListLocked( calls, want 1 each" unless $n1 == 1 && $n2 == 1;
    print "FAIL P1 $_\n" for @f;
  ' <<<"$sweep") || out="$out
FAIL P1 the perl check did not run"
  if [ -n "$out" ]; then printf '%s\n' "$out"; bad=1
  else echo "ok P1 sweepAuto sends the restore-only retries in chunks, each re-read under MAT_LOCK after the sign-out check"; fi
  # P2: the list path.
  if ! has "$rlist" 'OdRestoreList.parse(DaemonSocket.roundTripLines(OdRestoreList.request(keep), 130000), keep);'; then
    echo "FAIL P2 restoreOnlyListLocked does not send OdRestoreList.request(keep) through roundTripLines and parse it"; bad=1
  elif ! perl -0777 -ne 'exit(/for \(String pkg : keep\) \{\s*try \{\s*restoreOnlyReplied\(pkg, replies\.get\(pkg\)\);/ ? 0 : 1)' <<<"$rlist"; then
    echo "FAIL P2 restoreOnlyListLocked does not hand each app its own reply through restoreOnlyReplied"; bad=1
  elif has "$rlist" 'markOdRestored(' || has "$rlist" 'wakeOnRestore('; then
    echo "FAIL P2 restoreOnlyListLocked marks or wakes on its own, not through the shared tail"; bad=1
  else echo "ok P2 restoreOnlyListLocked sends one list and hands each app its own reply"; fi
  # P3: the one-name path and the shared tail.
  mk=$(lineno "$rtail" 'if (ok) markOdRestored(pkg);'); wk=$(lineno "$rtail" 'if (ok && wakeOnRestore(this, pkg)) unstop(this, pkg);')
  if ! has "$ronly" 'String rr = daemon("RESTORE-ODDATA\n" + pkg + "\n");' || ! has "$ronly" 'return restoreOnlyReplied(pkg, rr);'; then
    echo "FAIL P3 restoreOnlyLocked does not send the one-name request and return restoreOnlyReplied(pkg, rr)"; bad=1
  elif has "$ronly" 'markOdRestored('; then
    echo "FAIL P3 restoreOnlyLocked marks on its own, not through the shared tail"; bad=1
  elif ! has "$rtail" 'boolean ok = rr != null && rr.startsWith("OK");' || [ -z "$mk" ] || [ -z "$wk" ] || [ "$mk" -ge "$wk" ]; then
    echo "FAIL P3 restoreOnlyReplied does not mark on OK and then wake (ok/mark=$mk/wake=$wk)"; bad=1
  elif [ "$(grep -cF '"RESTORE-ODDATA(restore-only) "' "$u")" -ne 1 ] || ! has "$rtail" '"RESTORE-ODDATA(restore-only) "'; then
    echo "FAIL P3 the restore-only reply is not logged in restoreOnlyReplied alone"; bad=1
  else echo "ok P3 restoreOnlyLocked and restoreOnlyListLocked share restoreOnlyReplied"; fi
  # P4: the chunk size and the request's bounds.
  if ! has "$odl" 'static final int CHUNK = 8;'; then echo "FAIL P4 OdRestoreList.CHUNK is not 8"; bad=1
  elif ! has "$odl" 'if (pkgs.size() < 2 || pkgs.size() > CHUNK)'; then
    echo "FAIL P4 OdRestoreList.request does not refuse fewer than 2 or more than CHUNK names"; bad=1
  else echo "ok P4 OdRestoreList.CHUNK is 8 and request takes 2..CHUNK names"; fi
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
[ "$MUTATE" = yes ] || { echo "PASS test-od-restore-list-java"; exit 0; }

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in OdRestoreList.java UnarchiveService.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
O=$CH/OdRestoreList.java
U=$CH/UnarchiveService.java
fails=0 conv=0
tally() { if "$@"; then conv=$((conv+1)); else fails=$((fails+1)); fi; }
tally mut "M1 a missing line read as OK" "$O" \
  's/for \(String p : sent\) m\.put\(p, null\);/for (String p : sent) m.put(p, "OK");/' L4
tally mut "M2 STOPPED read as OK" "$O" \
  's/if \(rest\.equals\(STOPPED\)\) continue;/if (rest.equals(STOPPED)) rest = "OK";/' L5
tally mut "M3 a one-line NONE applied to the first package only" "$O" \
  's/for \(String p : sent\) m\.put\(p, lines\.get\(0\)\.trim\(\)\);/m.put(sent.get(0), lines.get(0).trim());/' L6
tally mut "M4 the SignOutGate check removed from the chunk loop" "$U" \
  's/(c \+= OdRestoreList\.CHUNK\) \{\n)[ \t]*if \(SignOutGate\.begun\(\)\) break;[^\n]*\n/$1/' P1
tally mut "M5 the autoAction re-read under the lock removed" "$U" \
  's/if \(autoAction\(hasInstalledCode\(pkg\), odRestored\(pkg\), false\)/if (autoAction(true, false, false)/' P1
tally mut "M6 the list path marks on its own, not through restoreOnlyReplied" "$U" \
  's/restoreOnlyReplied\(pkg, replies\.get\(pkg\)\);/if (replies.get(pkg) != null) markOdRestored(pkg);/' P2
tally mut "M7 CHUNK raised to 16" "$O" \
  's/static final int CHUNK = 8;/static final int CHUNK = 16;/' P4
echo "== $conv convicted, $fails failed"
[ "$fails" -eq 0 ] && [ "$conv" -eq 7 ] || exit 1
echo "PASS test-od-restore-list-java --mutate"
