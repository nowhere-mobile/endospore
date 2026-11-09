#!/usr/bin/env bash
# test-od-unparked-java.sh [--mutate] -- NWP-20261129-13 (h55 #4): the gate raises no placeholder for a package the
# sign-in could not park. A raise would re-create the package record, and installd can wipe the root-owned data it
# finds in the canonical dir (#204). test-reap-stale-ondemand.sh pins the writer; this suite pins the reader.
# Compiles the chooser's pure OdUnparked (java.util only) with the cases ALONE and EXECUTES them (C1-C6), then checks
# the REAL installRoamedAppCode with comments dropped, so a comment can neither satisfy nor trip a check (S1-S4):
#   S1  it reads new java.io.File(dir, "od-unparked") from the .appcode dir and calls OdUnparked.parse( once each,
#       before the manifest loop.
#   S2  the deferred branch adds the package to od, then tests the set and continues, before the _meta check and
#       before installArchivedPlaceholder, with no tally in the arm.
#   S3  a missing file is an empty catch, an unreadable file is a warning and nothing else, and the set is assigned only
#       at its empty start and from the parse.
#   S4  neither it nor OdUnparked.java reads roamd's state dir.
#
# It needs a JDK and perl, and it FAILS when either is missing: a Java suite that skips without one would read green on
# a runner that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-od-unparked-java.sh            # the cases and the source checks
#   bash test-od-unparked-java.sh --mutate   # ... plus the mutants
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
  echo "test-od-unparked-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-od-unparked-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -J-Djava.io.tmpdir="$W" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/od-unparked/OdUnparkedCases.java
INSTALL_SIG='    private java.util.Set<String> installRoamedAppCode(int uid) {'

# cases <root>: compile <root>'s OdUnparked with the cases into a fresh dir and run them. 3 when they do not compile.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/OdUnparked.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.OdUnparkedCases
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

# sources <root>: S1-S4 over <root>'s ChooserActivity.java and OdUnparked.java.
sources() {
  local r=$1 inst parser msg bad=0
  inst=$(code "$r/$CH/ChooserActivity.java" "$INSTALL_SIG")
  [ -n "$inst" ] || { echo "FAIL S0 installRoamedAppCode not found"; return 1; }
  parser=""
  [ -f "$r/$CH/OdUnparked.java" ] && parser=$(perl -ne 'print unless m{^\s*(//|\*|/\*)}' "$r/$CH/OdUnparked.java")
  if msg=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      my $w = index($c, "while ((line = br.readLine()) != null) {");
      $w >= 0 or do { print "no manifest loop"; exit 1 };
      my @e;
      $c =~ /java\.io\.File dir = new java\.io\.File\(getFilesDir\(\), "\.appcode"\);/ or push @e, "dir is not the .appcode dir";
      for my $k (q{new java.io.File(dir, "od-unparked")}, q{OdUnparked.parse(}) {
        my @at; push @at, $-[0] while $c =~ /\Q$k\E/g;
        @at == 1 or do { push @e, "$k appears " . scalar(@at) . " times"; next };
        $at[0] < $w or push @e, "$k is not before the manifest loop";
      }
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$inst"); then
    echo "ok S1 installRoamedAppCode reads .appcode/od-unparked once, before the manifest loop"
  else
    echo "FAIL S1 $msg"; bad=1
  fi
  if msg=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      my @e;
      my @t; push @t, $-[0] while $c =~ /\bunparked\.contains\(/g;
      @t == 1 or push @e, "unparked.contains( appears " . scalar(@t) . " times";
      if ($c =~ /if \(r\.deferred\) \{\s*od\.add\(pkg\);\s*if \(unparked\.contains\(pkg\)\) \{([^{}]*)continue;\s*\}\s*java\.io\.File metaDir/) {
        my $arm = $1;
        $arm =~ /tally/ and push @e, "the skip arm touches the tally";
        $arm =~ /Log\.i\(/ or push @e, "the skip arm logs no logcat line";
      } else {
        push @e, "the deferred branch is not: od.add(pkg), then if (unparked.contains(pkg)) { ... continue; }, then the _meta dir";
      }
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$inst"); then
    echo "ok S2 a listed package goes into od and skips the raise, before the _meta check and installArchivedPlaceholder"
  else
    echo "FAIL S2 $msg"; bad=1
  fi
  if msg=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      my @e;
      $c =~ /catch \(java\.nio\.file\.NoSuchFileException \w+\) \{\s*\}\s*catch \(Throwable \w+\) \{\s*android\.util\.Log\.w\("NowhereChooser", "od-unparked [^;]*;\s*\}/
        or push @e, "the read is not: an empty NoSuchFileException catch, then a Throwable catch holding one warning";
      $c =~ /java\.util\.Set<String> unparked = java\.util\.Collections\.emptySet\(\);/ or push @e, "the set does not start empty";
      my @as; push @as, $-[0] while $c =~ /\bunparked = /g;
      @as == 2 or push @e, "unparked is assigned " . scalar(@as) . " times, want 2";
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$inst"); then
    echo "ok S3 absent reads as an empty set, unreadable as an empty set and one warning"
  else
    echo "FAIL S3 $msg"; bad=1
  fi
  if [ -z "$parser" ]; then
    echo "FAIL S4 OdUnparked.java not found"; bad=1
  elif msg=$(perl -0e '
      my $c = do { local $/; <STDIN> };
      if ($c =~ m{/data/nowhere/state|od-unparked\.}) { print "it reads roamd state: $&"; exit 1 }' <<<"$inst
$parser"); then
    echo "ok S4 neither installRoamedAppCode nor OdUnparked reads roamd's state dir"
  else
    echo "FAIL S4 $msg"; bad=1
  fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile. The source checks run first, so a tree with no
# OdUnparked.java still reports them.
check() {
  local rc=0 crc
  sources "$1" || rc=1
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && return 3
  [ "$crc" -eq 0 ] || rc=1
  return "$rc"
}

check "$ROOT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <path under the root> <perl-expr> <check the mutant must fail>
  local d f out rc n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/$CH"
  for n in OdUnparked.java ChooserActivity.java; do cp "$ROOT/$CH/$n" "$d/$CH/$n"; done
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
# SKIP matches the skip block with its comment, for the mutants that move or remove it.
SKIP='(\n {24}// NWP-20261129-13[^\n]*(?:\n {24}//[^\n]*)*\n {24}if \(unparked\.contains\(pkg\)\) \{.*?\n {24}\})'
C=$CH/ChooserActivity.java
fails=0
mut "U1 the skip removed" "$C" "s#$SKIP##s or die" S2 || fails=$((fails+1))
mut "U2 the skip without od.add (the block above it)" "$C" "s#$SKIP##s or die; my \$b = \$1; s/(\n {24}od\.add\(pkg\);)/\$b\$1/ or die" S2 || fails=$((fails+1))
mut "U3 an unreadable list skips every deferred row" "$C" 's/(java\.util\.Set<String> unparked = [^\n]*\n)/$1        boolean unparkedAll = false;\n/ or die; s/("od-unparked unreadable[^\n]*\n)/$1            unparkedAll = true;\n/ or die; s/if \(unparked\.contains\(pkg\)\) \{/if (unparkedAll || unparked.contains(pkg)) {/ or die' S3 || fails=$((fails+1))
mut "U4 the check placed after installArchivedPlaceholder" "$C" "s#$SKIP##s or die; my \$b = \$1; s/(tally\.refused\+\+;\n[^\n]*\n {24}\})/\$1\$b/ or die" S2 || fails=$((fails+1))
mut "U5 parse keeps a junk line" "$CH/OdUnparked.java" 's/if \(isPackageName\(name\)\) out\.add\(name\);/if (!name.isEmpty()) out.add(name);/ or die' C4 || fails=$((fails+1))
mut "U6 the list read again for each row" "$C" 's/(String pkg = r\.pkg;\n)/$1                unparked = OdUnparked.parse(new String(java.nio.file.Files.readAllBytes(new java.io.File(dir, "od-unparked").toPath())));\n/ or die' S1 || fails=$((fails+1))
mut "U7 the list read from roamd's state dir" "$C" 's/new java\.io\.File\(dir, "od-unparked"\)\.toPath\(\)/new java.io.File("\/data\/nowhere\/state\/od-unparked." + uid).toPath()/ or die' S4 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
