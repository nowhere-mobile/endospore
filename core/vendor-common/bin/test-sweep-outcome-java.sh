#!/usr/bin/env bash
# test-sweep-outcome-java.sh [--mutate] -- NWP-20261113-17: every app the Auto sweep's materialise loop starts sends
# exactly one AUTO-SWEEP-APP (NWP-20261113-16), from a fixed token, with no package name, so login.log -- which an
# issue report carries -- says where each app's install ended.
# Compiles the chooser's pure SweepOutcome (java.* only, no Android SDK) with the cases below ALONE and EXECUTES them
# (O1), compares its token list with the agent's (O2), then checks the REAL UnarchiveService over its code with
# comments dropped, so a comment can neither satisfy nor trip a check (O3):
#   O1  request(i, n, tok, ms) is exactly "AUTO-SWEEP-APP\n<i>\n<n>\n<tok>\n<ms>\n" for each token, and null for
#       i=0, i>n, n>9999, ms<0, ms>86400000, a null token and an unknown token.
#   O2  SweepOutcome.TOKENS equals core/agent/auto_sweep.go autoSweepOutcomeTokens, literal for literal, in order.
#   O3a the materialise loop sends one SweepOutcome.request(i + 1, work.size(), <end>, ...) per app, after
#       materializeAndInstall(pkg, true), through DaemonSocket.roundTrip(<req>, 5000) behind a null check.
#   O3b no SweepOutcome.request call in sweepAuto takes pkg (or work.get) in its arguments.
#   O3c the catch after materializeAndInstall(pkg, true) sets the outcome the request reads to SweepOutcome.ERROR.
#   O3d the sign-out stop sends ONE `stopped` request for app i + 1, and has no loop.
#   O3e AUTO-SWEEP 0 is still sent from sweepAuto's finally, once.
#   O3f every exit records where it ended: materializeAndInstall resets matEnd to ERROR first and records ALREADY /
#       RESTORE_ONLY before its two fast-path returns; every `return false;` of materializeLocked follows its token
#       (ERROR at the unconfirmed Play-stack ask, which the sweep never reaches; then BUSY and FETCH_FAILED at the dep
#       abort, INSTALL_FAILED, BUSY and FETCH_FAILED at the MATERIALIZE-APP reply (NWP-20261118-05), FETCH_FAILED,
#       NEEDS_PLAY when a Play client with no Play stack keeps its placeholder (NWP-20261119-15), OLDER_COPY when the
#       sweep's fetched copy is older than its placeholder (NWP-20261126-07), ERROR), and `ok`
#       records INSTALLED or INSTALL_FAILED; the loop reads matEnd between MAT_LOCK.lock() and MAT_LOCK.unlock().
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of SweepOutcome.java, UnarchiveService.java and auto_sweep.go, each of
# which must FAIL a named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a
# failure, never a pass.
#
#   bash test-sweep-outcome-java.sh            # the cases and the source checks
#   bash test-sweep-outcome-java.sh --mutate   # ... plus the mutants
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
  echo "test-sweep-outcome-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-sweep-outcome-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
AG=core/agent/auto_sweep.go
mkdir -p "$W/cases"
CASES=$W/cases/SweepOutcomeCases.java
cat >"$CASES" <<'JAVA'
package com.nowhere.chooser;

public final class SweepOutcomeCases {
    static int bad = 0;
    static void eq(String what, String want, String got) {
        if (want == null ? got == null : want.equals(got)) return;
        System.out.println("FAIL O1 " + what + ": want " + show(want) + ", got " + show(got));
        bad++;
    }
    static String show(String s) { return s == null ? "null" : "\"" + s.replace("\n", "\\n") + "\""; }
    public static void main(String[] a) {
        String[] toks = { "installed", "already", "restore-only", "fetch-failed", "install-failed", "stopped", "error", "busy", "needs-play", "older-copy" };
        for (String t : toks) eq("request(2, 7, " + t + ", 1234)", "AUTO-SWEEP-APP\n2\n7\n" + t + "\n1234\n",
                SweepOutcome.request(2, 7, t, 1234));
        eq("request(1, 1, installed, 0)", "AUTO-SWEEP-APP\n1\n1\ninstalled\n0\n", SweepOutcome.request(1, 1, "installed", 0));
        eq("request(9999, 9999, error, 86400000)", "AUTO-SWEEP-APP\n9999\n9999\nerror\n86400000\n",
                SweepOutcome.request(9999, 9999, "error", 86400000L));
        eq("request(0, 3, ...) (i=0)", null, SweepOutcome.request(0, 3, "installed", 5));
        eq("request(-1, 3, ...) (i<0)", null, SweepOutcome.request(-1, 3, "installed", 5));
        eq("request(3, 2, ...) (i>n)", null, SweepOutcome.request(3, 2, "installed", 5));
        eq("request(1, 10000, ...) (n>9999)", null, SweepOutcome.request(1, 10000, "installed", 5));
        eq("request(1, 0, ...) (n=0)", null, SweepOutcome.request(1, 0, "installed", 5));
        eq("request(1, 3, installed, -1) (ms<0)", null, SweepOutcome.request(1, 3, "installed", -1));
        eq("request(1, 3, installed, 86400001) (ms>max)", null, SweepOutcome.request(1, 3, "installed", 86400001L));
        eq("request(1, 3, null, 5)", null, SweepOutcome.request(1, 3, null, 5));
        for (String u : new String[] { "Installed", "ok", "installed ", "", "installed\nx", "com.example.app" })
            eq("request(1, 3, " + show(u) + ", 5) (unknown token)", null, SweepOutcome.request(1, 3, u, 5));
        if (bad > 0) System.exit(1);
        System.out.println("ok O1 request() builds the exact wire for each token and null for every out-of-range input");
    }
}
JAVA

# cases <root>: compile <root>'s SweepOutcome with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/SweepOutcome.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.SweepOutcomeCases
}

# code <file> <signature line>: the method from its signature to its closing `    }`, with whole-line comments dropped
# and trailing `//` comments stripped (a `//` inside a string literal is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $in && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# tokens <root>: O2 over <root>'s auto_sweep.go and SweepOutcome.java.
tokens() {
  local r=$1 msg
  if msg=$(perl -e '
      my ($go, $jv) = @ARGV;
      open(my $g, "<", $go) or do { print "cannot read $go"; exit 1 };
      my @agent;
      while (my $l = <$g>) {
        next unless $l =~ /^var autoSweepOutcomeTokens = \[\.\.\.\]string\{(.*)\}\s*$/;
        my $body = $1; @agent = ($body =~ /"([^"]*)"/g); last;
      }
      @agent or do { print "no autoSweepOutcomeTokens literal list in $go"; exit 1 };
      open(my $j, "<", $jv) or do { print "cannot read $jv"; exit 1 };
      my $src = do { local $/; <$j> };
      $src =~ s{/\*.*?\*/}{}gs; $src =~ s{//[^\n]*}{}g;
      my %val; $val{$1} = $2 while $src =~ /static final String (\w+) = "([^"]*)";/g;
      $src =~ /static final String\[\] TOKENS = \{([^}]*)\};/ or do { print "no TOKENS initializer in $jv"; exit 1 };
      my @chooser;
      for my $n (split /,/, $1) {
        $n =~ s/^\s+|\s+$//g;
        if ($n =~ /^"([^"]*)"$/) { push @chooser, $1; next }
        exists $val{$n} or do { print "TOKENS names $n, which is not a String constant"; exit 1 };
        push @chooser, $val{$n};
      }
      my %seen; for (@chooser) { $seen{$_}++ and do { print "TOKENS holds $_ twice"; exit 1 } }
      my ($ag, $ch) = (join(" ", @agent), join(" ", @chooser));
      $ag eq $ch or do { print "agent [$ag] != chooser [$ch]"; exit 1 };
      print scalar(@agent); exit 0;' "$r/$AG" "$r/$CH/SweepOutcome.java"); then
    echo "ok O2 SweepOutcome.TOKENS equals the agent's autoSweepOutcomeTokens ($msg tokens, same order)"
  else
    echo "FAIL O2 the chooser's and the agent's token lists differ: $msg"; return 1
  fi
}

# sources <root>: O3a-f over <root>'s UnarchiveService.java.
sources() {
  local r=$1 sweep mai mloc bad=0
  sweep=$(code "$r/$CH/UnarchiveService.java" "    private void sweepAuto(boolean byHand) {")
  mai=$(code "$r/$CH/UnarchiveService.java" "    private boolean materializeAndInstall(String pkg, boolean quiet) {")
  mloc=$(code "$r/$CH/UnarchiveService.java" "    private boolean materializeLocked(String pkg, boolean quiet) {")
  if [ -z "$sweep" ] || [ -z "$mai" ] || [ -z "$mloc" ]; then
    echo "FAIL O3 sweepAuto, materializeAndInstall or materializeLocked not found"; return 1
  fi
  # The materialise loop: from its for to the sweep's outer finally. The stop block is cut out of it for O3a/O3c.
  local loop
  loop=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ /(for \(int i = 0; i < work\.size\(\); i\+\+\) \{.*?)\}\s*finally\s*\{\s*DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n"/s
        or exit 1;
      print $1;' <<<"$sweep")
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ s/if \(SignOutGate\.begun\(\)\) \{.*?\bbreak;\s*\}//s;
      $c =~ s/if \(SweepHold\.held\(\)\) \{.*?\bbreak;\s*\}//s;
      my $n = () = $c =~ /SweepOutcome\.request\(/g; exit 1 unless $n == 1;
      my $m = index($c, "materializeAndInstall(pkg, true)"); exit 1 if $m < 0;
      $c =~ /String (\w+) = SweepOutcome\.request\(i \+ 1, work\.size\(\), \w+, [^;]*\);\s*if \(\1 != null\) DaemonSocket\.roundTrip\(\1, 5000\);/s
        or exit 1;
      exit 1 if $-[0] < $m;
      exit 0;' <<<"$loop"; then
    echo "ok O3a the materialise loop sends one SweepOutcome.request(i + 1, work.size(), ...) per app, after materializeAndInstall"
  else
    echo "FAIL O3a the materialise loop does not send exactly one SweepOutcome.request(i + 1, work.size(), <end>, ...) after materializeAndInstall(pkg, true) through DaemonSocket.roundTrip(<req>, 5000) behind a null check"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      my $found = 0;
      while ($c =~ /SweepOutcome\.request\(/g) {
        my ($p, $d, $args) = (pos($c), 1, "");
        while ($p < length($c) && $d > 0) {
          my $ch = substr($c, $p++, 1);
          $d++ if $ch eq "("; $d-- if $ch eq ")";
          $args .= $ch if $d > 0;
        }
        $found++;
        exit 1 if $args =~ /\bpkg\b/ || $args =~ /work\.get\(/;
      }
      exit($found > 0 ? 0 : 1);' <<<"$sweep"; then
    echo "ok O3b no SweepOutcome.request in sweepAuto takes the package"
  else
    echo "FAIL O3b a SweepOutcome.request call in sweepAuto takes pkg (or work.get) in its arguments, or there is none"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ s/if \(SignOutGate\.begun\(\)\) \{.*?\bbreak;\s*\}//s;
      $c =~ /SweepOutcome\.request\(i \+ 1, work\.size\(\), (\w+),/ or exit 1;
      my $v = $1;
      $c =~ /materializeAndInstall\(pkg, true\);[^}]*\}\s*catch \(Throwable t\) \{([^}]*)\}/s or exit 1;
      exit($1 =~ /\b\Q$v\E = SweepOutcome\.ERROR;/ ? 0 : 1);' <<<"$loop"; then
    echo "ok O3c the catch after materializeAndInstall reports SweepOutcome.ERROR"
  else
    echo "FAIL O3c the catch after materializeAndInstall(pkg, true) does not set the outcome the request reads to SweepOutcome.ERROR"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      $c =~ /if \(SignOutGate\.begun\(\)\) \{(.*?)\bbreak;\s*\}/s or exit 1;
      my $b = $1;
      exit 1 if $b =~ /\b(?:for|while)\s*\(|\bdo\s*\{/;
      my $n = () = $b =~ /SweepOutcome\.request\(/g; exit 1 unless $n == 1;
      my $s = () = $b =~ /DaemonSocket\.roundTrip\(/g; exit 1 unless $s == 1;
      $b =~ /String (\w+) = SweepOutcome\.request\(i \+ 1, work\.size\(\), SweepOutcome\.STOPPED, 0\);\s*if \(\1 != null\) DaemonSocket\.roundTrip\(\1, 5000\);/
        or exit 1;
      exit 0;' <<<"$loop"; then
    echo "ok O3d the sign-out stop sends one stopped request, for app i + 1, with no loop"
  else
    echo "FAIL O3d the sign-out stop does not send exactly one SweepOutcome.request(i + 1, work.size(), SweepOutcome.STOPPED, 0) (or it loops)"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> };
      my $n = () = $c =~ /DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n", 30000\);/g; exit 1 unless $n == 1;
      exit 1 unless $c =~ /\}\s*finally\s*\{\s*DaemonSocket\.roundTrip\("AUTO-SWEEP\\n0\\n", 30000\);\s*\}/;
      exit 0;' <<<"$sweep"; then
    echo "ok O3e AUTO-SWEEP 0 is still sent from sweepAuto's finally"
  else
    echo "FAIL O3e sweepAuto no longer sends AUTO-SWEEP\\n0\\n once from a finally"; bad=1
  fi
  local exits
  exits=$(perl -0e '
      my ($mai, $mloc, $loop) = split /\n<<<SPLIT>>>\n/, do { local $/; <STDIN> };
      my @e;
      $mai =~ /MAT_LOCK\.lock\(\);\s*try \{\s*matEnd = SweepOutcome\.ERROR;/ or push @e, "materializeAndInstall does not reset matEnd to ERROR first";
      $mai =~ /if \(action == AUTO_WHOLE\) \{[^}]*matEnd = SweepOutcome\.ALREADY;\s*return true;\s*\}/s
        or push @e, "the AUTO_WHOLE return does not record ALREADY";
      $mai =~ /if \(action == AUTO_RESTORE_ONLY\) \{[^}]*matEnd = SweepOutcome\.RESTORE_ONLY;\s*return true;\s*\}/s
        or push @e, "the AUTO_RESTORE_ONLY return does not record RESTORE_ONLY";
      my @got;
      while ($mloc =~ /return false;/g) {
        my $pre = substr($mloc, 0, $-[0]);
        push @got, ($pre =~ /matEnd = SweepOutcome\.(\w+);\s*\z/ ? $1 : "NONE");
      }
      my $want = "ERROR BUSY FETCH_FAILED INSTALL_FAILED BUSY FETCH_FAILED FETCH_FAILED NEEDS_PLAY OLDER_COPY ERROR";
      join(" ", @got) eq $want or push @e, "materializeLocked return false exits record [@got], want [$want]";
      my $t = () = $mloc =~ /matEnd = ok \? SweepOutcome\.INSTALLED : SweepOutcome\.INSTALL_FAILED;/g;
      $t == 1 or push @e, "materializeLocked does not record ok ? INSTALLED : INSTALL_FAILED once";
      my ($q, $o) = (index($mloc, "matEnd = ok ?"), index($mloc, "if (ok) {"));
      ($q >= 0 && $o > $q) or push @e, "the ok record is not before if (ok) {";
      $loop =~ /MAT_LOCK\.lock\(\);\s*try \{[^}]*materializeAndInstall\(pkg, true\);\s*\w+ = matEnd;\s*\}.*?finally \{\s*MAT_LOCK\.unlock\(\);\s*\}/s
        or push @e, "the loop does not read matEnd between MAT_LOCK.lock() and MAT_LOCK.unlock()";
      print join("; ", @e);' <<<"$mai
<<<SPLIT>>>
$mloc
<<<SPLIT>>>
$loop")
  if [ -z "$exits" ]; then
    echo "ok O3f every materialise exit records its outcome, and the loop reads it under MAT_LOCK"
  else
    echo "FAIL O3f $exits"; bad=1
  fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  tokens "$1" || rc=1
  sources "$1" || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH" "$d/core/agent"
  for n in "$CH/SweepOutcome.java" "$CH/UnarchiveService.java" "$AG"; do cp "$ROOT/$n" "$d/$n"; done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
U=$CH/UnarchiveService.java
fails=0
mut "M1 the package passed into the per-app request" "$U" 's/SweepOutcome\.request\(i \+ 1, work\.size\(\), end,/SweepOutcome.request(i + 1, work.size(), end + ":" + pkg,/' O3b || fails=$((fails+1))
mut "M2 a token renamed on the chooser side only" "$CH/SweepOutcome.java" 's/= "fetch-failed";/= "fetch-fail";/' O2 || fails=$((fails+1))
mut "M2b a token renamed on the agent side only" "$AG" 's/("restore-only", )"fetch-failed"/$1"fetch-fail"/' O2 || fails=$((fails+1))
mut "M3 the per-app send removed" "$U" 's/^[ \t]*if \(req != null\) DaemonSocket\.roundTrip\(req, 5000\);\n//m' O3a || fails=$((fails+1))
mut "M4 the error branch removed from the catch" "$U" 's/catch \(Throwable t\) \{ end = SweepOutcome\.ERROR; /catch (Throwable t) { /' O3c || fails=$((fails+1))
mut "M5 the stopped send moved into a per-remaining-app loop" "$U" 's/String stop = SweepOutcome\.request\(i \+ 1, work\.size\(\), SweepOutcome\.STOPPED, 0\);\n(\s*)if \(stop != null\) DaemonSocket\.roundTrip\(stop, 5000\);/for (int k = i; k < work.size(); k++) { String stop = SweepOutcome.request(k + 1, work.size(), SweepOutcome.STOPPED, 0);\n$1if (stop != null) DaemonSocket.roundTrip(stop, 5000); }/' O3d || fails=$((fails+1))
mut "M6 the i > n bound removed from request()" "$CH/SweepOutcome.java" 's/ \|\| i > n \|\|/ ||/' "O1 request(3, 2, ...) (i>n)" || fails=$((fails+1))
mut "M7 the no-APK exit records nothing" "$U" 's/("no materialised apk for " \+ pkg\);\n)\s*matEnd = SweepOutcome\.FETCH_FAILED;\n/$1/' O3f || fails=$((fails+1))
mut "M8 the loop no longer reads matEnd under the lock" "$U" 's/ end = matEnd; \}/ }/; s/(finally \{ MAT_LOCK\.unlock\(\); \})/$1 end = matEnd;/' O3f || fails=$((fails+1))
mut "M9 the stopped send removed" "$U" 's/^[ \t]*if \(stop != null\) DaemonSocket\.roundTrip\(stop, 5000\);\n//m' O3d || fails=$((fails+1))
mut "M10 \"busy\" dropped from the agent's list only" "$AG" 's/, "busy", "needs-play", "older-copy"\}/, "needs-play", "older-copy"}/' O2 || fails=$((fails+1))
mut "M11 BUSY dropped from the chooser's TOKENS only" "$CH/SweepOutcome.java" 's/, BUSY, NEEDS_PLAY, OLDER_COPY \}/, NEEDS_PLAY, OLDER_COPY }/' O2 || fails=$((fails+1))
mut "M12 a busy MATERIALIZE-APP reply read as fetch-failed again" "$U" 's{if \(SweepBusy\.isBusy\(reply\)\) \{(?:\s*//[^\n]*)*\s*qDrop\(group\);\s*matEnd = SweepOutcome\.BUSY;\s*return false;\s*\}\s*}{}' O3f || fails=$((fails+1))
mut "M13 \"needs-play\" dropped from the agent's list only" "$AG" 's/, "needs-play", "older-copy"\}/, "older-copy"}/' O2 || fails=$((fails+1))
mut "M14 NEEDS_PLAY dropped from the chooser's TOKENS only" "$CH/SweepOutcome.java" 's/, NEEDS_PLAY, OLDER_COPY \}/, OLDER_COPY }/' O2 || fails=$((fails+1))
mut "M15 the needs-play exit records nothing" "$U" 's/^[ \t]*matEnd = SweepOutcome\.NEEDS_PLAY;\n//m' O3f || fails=$((fails+1))
mut "M16 \"older-copy\" dropped from the agent's list only" "$AG" 's/, "older-copy"\}/}/' O2 || fails=$((fails+1))
mut "M17 OLDER_COPY dropped from the chooser's TOKENS only" "$CH/SweepOutcome.java" 's/, OLDER_COPY \}/ }/' O2 || fails=$((fails+1))
mut "M18 the older-copy exit records nothing" "$U" 's/^[ \t]*matEnd = SweepOutcome\.OLDER_COPY;\n//m' O3f || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
