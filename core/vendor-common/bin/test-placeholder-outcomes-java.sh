#!/usr/bin/env bash
# test-placeholder-outcomes-java.sh [--mutate] -- NWP-20261127-08: a sign-in's archived-placeholder outcomes reach
# login.log as counts, so an issue report tells a missing _meta from a refused install; and Your apps no longer
# labels an app this user does not have as "sideloaded".
# Compiles the chooser's pure PlaceholderTally (java.lang only) and ProfileActivity.sideloadedVerdict (extracted,
# with GOS_STORE_PKG) with the cases ALONE and EXECUTES them (P1-P3), then checks the REAL methods over their code
# with comments dropped, so a comment can neither satisfy nor trip a check (S1, S2):
#   P1  line() is "<raised> <noMeta> <refused> <groupDep> <error>", decimal, each clamped to 0..99999.
#   P2  any() is false on a new tally and true when any one counter alone is 1.
#   P3  sideloadedVerdict: not found -> false; a null or empty installer -> true; a known store -> false; another
#       installer -> true.
#   S1  ChooserActivity.installRoamedAppCode counts each of raised, noMeta, refused, groupDep and error exactly once,
#       inside the manifest loop (error only for a deferred row), and sends ONE
#       sendDaemon("PLACEHOLDER-OUTCOMES\n" + <tally>.line() + "\n") behind <tally>.any(), after the loop, with
#       nothing but the tally in its argument. The deferred arms run in this order: a missing _meta dir -> noMeta
#       (FIRST, unguarded: hasLauncherMeta is false for a missing _meta too, so a grouped row with no _meta must not
#       read as a group dep), a launcher-less group member -> groupDep, installed -> raised, else refused.
#   S2  ProfileActivity.isSideloaded catches NameNotFoundException apart from, and before, Throwable, sets the
#       not-found flag there, and returns sideloadedVerdict(installer, notFound).
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies of PlaceholderTally.java, ChooserActivity.java and ProfileActivity.java,
# each of which must FAIL a named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as
# a failure, never a pass.
#
#   bash test-placeholder-outcomes-java.sh            # the cases and the source checks
#   bash test-placeholder-outcomes-java.sh --mutate   # ... plus the mutants
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
  echo "test-placeholder-outcomes-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-placeholder-outcomes-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/placeholder-outcomes/PlaceholderOutcomesCases.java
INSTALL_SIG='    private java.util.Set<String> installRoamedAppCode(int uid) {'
SIDE_SIG='    static boolean isSideloaded(android.content.pm.PackageManager pm, String pkg) {'
VERDICT_SIG='    static boolean sideloadedVerdict(String installer, boolean notFound) {'

# verdict <root> <out file>: SideloadedVerdict.java = GOS_STORE_PKG + sideloadedVerdict, verbatim, from <root>'s
# ProfileActivity.java. 1 when either is missing.
verdict() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or exit 1;
    my ($const, $body, $in) = ("", "", 0);
    while (my $l = <$h>) {
      $const = $l if $l =~ /^    static final String GOS_STORE_PKG\s*=\s*"[^"]*";\s*$/;
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      $body .= $l;
      if ($l =~ /^    \}$/) { $in = 2; last; }
    }
    exit 1 unless $const ne "" && $in == 2;
    print "package com.nowhere.chooser;\n\nfinal class SideloadedVerdict {\n$const\n$body}\n";' "$1/$CH/ProfileActivity.java" "$VERDICT_SIG" >"$2"
}

# cases <root>: compile <root>'s PlaceholderTally and extracted verdict with the cases into a fresh dir and run them.
# 3 when they do not compile or the verdict cannot be extracted.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  if ! verdict "$1" "$d/SideloadedVerdict.java"; then
    echo "FAIL P3 sideloadedVerdict or GOS_STORE_PKG not found in ProfileActivity.java"; return 3
  fi
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/PlaceholderTally.java" "$d/SideloadedVerdict.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.PlaceholderOutcomesCases
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

# sources <root>: S1 and S2 over <root>'s ChooserActivity.java and ProfileActivity.java.
sources() {
  local r=$1 inst side msg bad=0
  inst=$(code "$r/$CH/ChooserActivity.java" "$INSTALL_SIG")
  side=$(code "$r/$CH/ProfileActivity.java" "$SIDE_SIG")
  if [ -z "$inst" ] || [ -z "$side" ]; then
    echo "FAIL S0 installRoamedAppCode or isSideloaded not found"; return 1
  fi
  if msg=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      my $w = index($c, "while ((line = br.readLine()) != null) {");
      $w >= 0 or do { print "no manifest loop"; exit 1 };
      my ($p, $d) = ($w + length("while ((line = br.readLine()) != null) {"), 1);
      while ($p < length($c) && $d > 0) {
        my $ch = substr($c, $p, 1);
        if ($ch eq "\"") { $p++; while ($p < length($c) && substr($c, $p, 1) ne "\"") { $p++ if substr($c, $p, 1) eq "\\"; $p++ } }
        elsif ($ch eq "\x27") { $p++; while ($p < length($c) && substr($c, $p, 1) ne "\x27") { $p++ if substr($c, $p, 1) eq "\\"; $p++ } }
        elsif ($ch eq "{") { $d++ } elsif ($ch eq "}") { $d-- }
        $p++;
      }
      $d == 0 or do { print "the manifest loop does not close"; exit 1 };
      my $end = $p;
      my @e;
      for my $k (qw(raised noMeta refused groupDep error)) {
        my @at; push @at, $-[0] while $c =~ /\b\w+\.\Q$k\E\+\+/g;
        @at == 1 or do { push @e, "$k++ appears " . scalar(@at) . " times"; next };
        ($at[0] > $w && $at[0] < $end) or push @e, "$k++ is outside the manifest loop";
      }
      $c =~ /catch \(Throwable t\) \{\s*if \(r\.deferred\) \w+\.error\+\+;/ or push @e, "error++ is not counted for a deferred row only, in the per-row catch";
      $c =~ /\n(\s*)if \(!(\w+)\.isDirectory\(\)\) \{\s*\w+\.noMeta\+\+;[^{}]*\}\s*else if \(group != null && !hasLauncherMeta\(\2\)\) \{\s*\w+\.groupDep\+\+;[^{}]*\}\s*else if \(installArchivedPlaceholder\(pkg, \2, uid\)\) \{\s*\w+\.raised\+\+;[^{}]*\}\s*else \{\s*\w+\.refused\+\+;/
        or push @e, "the deferred arms are not, in order: no _meta dir -> noMeta, a launcher-less group member -> groupDep, installed -> raised, else refused (a grouped row with no _meta must count as noMeta)";
      my @s; push @s, $-[0] while $c =~ /sendDaemon\("PLACEHOLDER-OUTCOMES\\n" \+ /g;
      if (@s != 1) { push @e, "sendDaemon(\"PLACEHOLDER-OUTCOMES\\n\" + ...) appears " . scalar(@s) . " times" }
      else {
        $s[0] > $end or push @e, "the send is inside the manifest loop";
        $c =~ /if \((\w+)\.any\(\)\) \{\s*try \{\s*sendDaemon\("PLACEHOLDER-OUTCOMES\\n" \+ \1\.line\(\) \+ "\\n"\);/
          or push @e, "the send is not sendDaemon(\"PLACEHOLDER-OUTCOMES\\n\" + <tally>.line() + \"\\n\") behind <tally>.any() in a try";
        $c =~ /sendDaemon\("PLACEHOLDER-OUTCOMES\\n"([^;]*)\);/;
        my $args = $1 // "";
        (my $rest = $args) =~ s/\b\w+\.line\(\)//g;
        $rest =~ s/"(?:[^"\\]|\\.)*"//g;
        $rest =~ /^[\s+]*$/ or push @e, "the send carries more than the tally and string literals: $args";
      }
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$inst"); then
    echo "ok S1 installRoamedAppCode counts each outcome once in the loop and sends one PLACEHOLDER-OUTCOMES after it"
  else
    echo "FAIL S1 $msg"; bad=1
  fi
  if msg=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      my @e;
      $c =~ /catch \((?:android\.content\.pm\.PackageManager\.)?NameNotFoundException (\w+)\) \{\s*(\w+) = true;\s*\}\s*catch \(Throwable \w+\)/
        or push @e, "no NameNotFoundException catch setting a flag before catch (Throwable";
      my $flag = $2 // "notFound";
      $c =~ /return sideloadedVerdict\(installer, \Q$flag\E\);/ or push @e, "no return sideloadedVerdict(installer, $flag)";
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$side"); then
    echo "ok S2 isSideloaded catches NameNotFoundException apart from Throwable and returns sideloadedVerdict"
  else
    echo "FAIL S2 $msg"; bad=1
  fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  sources "$1" || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in PlaceholderTally.java ChooserActivity.java ProfileActivity.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
fails=0
mut "M1 a package this user does not have is sideloaded again" "$CH/ProfileActivity.java" 's/if \(notFound\) return false;/if (notFound) return true;/' P3 || fails=$((fails+1))
mut "M2 a refused install counted as a missing _meta" "$CH/ChooserActivity.java" 's/tally\.refused\+\+;/tally.noMeta++;/' S1 || fails=$((fails+1))
mut "M3 the send moved inside the manifest loop" "$CH/ChooserActivity.java" 'my $b; if (s/(\n        if \(tally\.any\(\)\) \{.*?\n        \})(?=\n        return od;)//s) { $b = $1; s/(\n            \}\n        \} catch \(Throwable t\) \{\n            android\.util\.Log\.w\("NowhereChooser", "installRoamedAppCode")/$b$1/s }' S1 || fails=$((fails+1))
mut "M5 a grouped row with no _meta counted as a group dep (the group test first again)" "$CH/ChooserActivity.java" 's/(\n {24}if )\(!metaDir\.isDirectory\(\)\)( \{\n.*?tally\.noMeta\+\+;.*?\n {24}\} else if )\(group != null && !hasLauncherMeta\(metaDir\)\)( \{\n.*?tally\.groupDep\+\+;.*?\n {24}\} else if \(installArchivedPlaceholder)/$1(group != null \&\& !hasLauncherMeta(metaDir))$2(!metaDir.isDirectory())$3/s' S1 || fails=$((fails+1))
mut "M6 the no-_meta arm skips a grouped row" "$CH/ChooserActivity.java" 's/if \(!metaDir\.isDirectory\(\)\) \{/if (group == null \&\& !metaDir.isDirectory()) {/' S1 || fails=$((fails+1))
mut "M4 no clamp" "$CH/PlaceholderTally.java" 's/return v < 0 \? 0 : v > 99999 \? 99999 : v;/return v;/' P1 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
