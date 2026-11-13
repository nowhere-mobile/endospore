#!/usr/bin/env bash
# test-playstack-signin-java.sh [--mutate] -- NWP-20261201-06: the Play-stack reconcile that runs once at every sign-in
# (ProfileActivity.reconcilePlayStackAtSignIn, called from UnarchiveService's switch-landing). Runs
# core/chooser/tests/playstack-signin: the chooser's pure PlayStackSignIn, compiled against its cases ALONE and EXECUTED,
# plus source checks on the call site, the lock and the logs, because ProfileActivity does not compile off the build host.
# The javac cases and the source checks report independently, so a tree missing the change prints every failure.
#
# It needs a JDK and perl, and it FAILS when either is missing: a suite that skips would read green on a runner that
# never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies of the three sources, each of which must FAIL a named check. A mutant
# that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-playstack-signin-java.sh            # the cases and the source checks
#   bash test-playstack-signin-java.sh --mutate   # ... plus the mutants
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
  echo "test-playstack-signin-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-playstack-signin-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the EXIT trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser

run() { JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/playstack-signin/run.sh" "$1" "$(mktemp -d -p "$W")"; }

# The source checks, over <root>/$CH. Comments never count. An extraction that finds nothing is a FAIL, never a skip.
read -r -d '' CHECKS <<'PERL'
use strict; use warnings;
my ($dir) = @ARGV; my $bad = 0;
sub res { my ($ok, $l, $w) = @_; print(($ok ? "ok   " : "FAIL "), "$l $w\n"); $bad = 1 unless $ok; }
sub src {
  my $p = shift; open(my $h, "<:encoding(UTF-8)", "$dir/$p") or return "";
  local $/; my $s = <$h>;
  $s =~ s{("(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}ges;
  return $s;
}
# The index just past the block whose { is at $open, skipping string and char literals. -1 when it never closes.
sub block_end {
  my ($s, $open) = @_; my $d = 0; pos($s) = $open;
  while ($s =~ /\G(?:"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|([{}])|.)/gs) {
    next unless defined $1;
    $d += $1 eq "{" ? 1 : -1;
    return pos($s) if $d == 0;
  }
  return -1;
}
sub method {
  my ($s, $sig) = @_; my $i = index($s, $sig); return "" if $i < 0;
  my $e = block_end($s, index($s, "{", $i)); return $e < 0 ? "" : substr($s, $i, $e - $i);
}
my $pa = src("ProfileActivity.java"); my $us = src("UnarchiveService.java");

my $rec = method($pa, "private void reconcilePlayStack(");
res($rec ne "" && index($rec, "playStackNeed(this, m, playClients)") >= 0 && index($rec, "boolean demands") < 0,
    "s1", "reconcilePlayStack calls playStackNeed and holds no demand loop of its own");

my $n = () = $us =~ /reconcilePlayStackAtSignIn\(/g;
my $call = $us =~ /if \(!byHand\) \{\s*try \{ ProfileActivity\.reconcilePlayStackAtSignIn\(this\); \}/ ? $-[0] : -1;
my ($land, $wake) = (index($us, 'LANDING.set(!byHand);'), index($us, 'try { wakeRestored(restoredOk); }'));
res($n == 1 && $call >= 0 && $land >= 0 && $wake >= 0 && $call > $land && $call < $wake,
    "s2", "UnarchiveService calls it once, inside if (!byHand), after LANDING.set and before wakeRestored");

my $m = method($pa, "static void reconcilePlayStackAtSignIn(");
my $lock = 'synchronized (StoreInstaller.APPKEEP_LOCK)';
my $li = index($m, $lock); my ($held, $before) = ("", "");
if ($li >= 0) {
  my $e = block_end($m, index($m, "{", $li));
  $held = $e < 0 ? "" : substr($m, $li, $e - $li); $before = substr($m, 0, $li);
}
res(index($held, "StoreInstaller.writeAtomic(") >= 0 && index($before, "playStackNeed(") >= 0
    && $held !~ /playStackNeed\(|gosStorePresent\(|getPackageManager\(/,
    "s3", "writeAtomic is inside the lock, and the PackageManager reads are before it");

my @logs = $m =~ /(Log\.\w+\((?:"(?:\\.|[^"\\\n])*"|[^;"])*\);)/g;
my $leak = 0;
for my $l (@logs) {
  (my $c = $l) =~ s/"(?:\\.|[^"\\\n])*"/""/g;
  for my $t ($c =~ /\+\s*([\w.]+)/g) { $leak = 1 unless $t eq "raised"; }
}
res(@logs >= 3 && !$leak, "s4", "its logs concatenate a count only, never a package name");

res($m =~ /boolean vendingHeld = playDeps\.contains\(VENDING_PKG\)\s*\|\|\s*PlayChoice\.blocksVendingReadd\(/ ? 1 : 0,
    "s5", "vendingHeld ORs a user-kept Play Store with Google Play turned Off");
exit($bad);
PERL
checks() { perl -e "$CHECKS" "$1/$CH"; }

bad=0
run "$ROOT" || { echo "FAIL javac cases -- the PlayStackSignIn cases did not pass"; bad=1; }
checks "$ROOT" || bad=1
[ "$bad" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "== all cases and source checks passed"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <file under $CH> <perl-expr> <check the mutant must fail>
  local d f out x
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for x in PlayStackSignIn ProfileActivity UnarchiveService; do cp "$ROOT/$CH/$x.java" "$d/$CH/"; done
  f="$d/$CH/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$CH/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(run "$d" 2>&1; checks "$d" 2>&1)
  rm -rf "$d"
  if grep -qF -- "error:" <<<"$out"; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4 " <<<"$out"; then echo "  SURVIVED  $1 -- '$4' did not fail"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
PS=PlayStackSignIn.java; PA=ProfileActivity.java; US=UnarchiveService.java
mut "S1 allow lowering" $PS 's/rank\(have\) < rank\(need\)/rank(have) != rank(need)/' c3 || fails=$((fails+1))
mut "S2 drop when need is null" $PS 's/if \(need == null\) return out;/if (need == null) { out.put(gms, null); return out; }/' c4 || fails=$((fails+1))
mut "S3 ignore vendingHeld" $PS 's/if \(!vendingHeld\) //' c2 || fails=$((fails+1))
mut "S3b drop the playOff term" $PA 's/playDeps\.contains\(VENDING_PKG\) \|\| PlayChoice\.blocksVendingReadd\(PlayChoice\.effective\(\n\s*PlayChoice\.parse\(cfgStatic\(ctx, PlayChoice\.CFG_KEY\)\), gosStorePresent\(ctx\)\)\);/playDeps.contains(VENDING_PKG);/' s5 || fails=$((fails+1))
mut "S4 add an absent member" $PS 's/if \(have == null\) return;/if (have == null) { out.put(p, need); return; }/' c5 || fails=$((fails+1))
mut "S5 drop the group token on rewrite" $PS 's/if \(token\) sb\.append\(\x27\\t\x27\)\.append\(f\[2\]\);\n\s*//' c6 || fails=$((fails+1))
mut "S6 move the call after the sweep" $US 's/\n\s*if \(!byHand\) \{\n\s*try \{ ProfileActivity\.reconcilePlayStackAtSignIn\(this\); \}\n[^\n]*\n\s*\}(?=\n\s*try \{ wakeRestored)//; s/try \{ sweepAutoJoined\(byHand\); \}/try { sweepAutoJoined(byHand); if (!byHand) { try { ProfileActivity.reconcilePlayStackAtSignIn(this); } catch (Throwable t2) { } } }/' s2 || fails=$((fails+1))
mut "S7 remove the !byHand guard" $US 's/if \(!byHand\) \{(\n\s*try \{ ProfileActivity\.reconcilePlayStackAtSignIn)/{$1/' s2 || fails=$((fails+1))
mut "S8 reconcilePlayStack keeps no playStackNeed call" $PA 's/String need = playStackNeed\(this, m, playClients\);/String need = null;/' s1 || fails=$((fails+1))
mut "S9 write outside the lock" $PA 's/int raised;\n\s*synchronized \(StoreInstaller\.APPKEEP_LOCK\) \{/int raised;\n            {/' s3 || fails=$((fails+1))
mut "S10 log a package name" $PA 's/"play stack sign-in: raised " \+ raised \+ " member\(s\)"/"play stack sign-in: raised " + raised + " member(s) " + VENDING_PKG/' s4 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
