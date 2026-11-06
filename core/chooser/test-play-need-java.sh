#!/usr/bin/env bash
# test-play-need-java.sh [--mutate] -- NWP-20261119-15: on Endospore, a Play client with no Play stack on its profile
# keeps its placeholder and asks (Q055, 2026-10-20, and h49 #1, 2026-10-31, in docs/product-decisions.md). A tap shows
# "<App> needs Play Store" with "Install anyway" and "Not now"; the quiet Auto sweep never asks and records needs-play.
# Compiles the chooser's pure PlayNeed (java.* only, no Android SDK) with the cases below ALONE and EXECUTES them (N1,
# N2), then checks the REAL UnarchiveService, PlayNeedAskActivity and AndroidManifest.xml with comments dropped, so a
# comment can neither satisfy nor trip a check (N3-N5):
#   N1  decide(endospore, apkNeedsPlay, stackPresent, stackInGroup, quiet) for all 32 inputs: INSTALL unless
#       endospore && apkNeedsPlay && !stackPresent && !stackInGroup; then ASK for a tap and SKIP for the quiet sweep.
#       The rule and a hand list of the two non-INSTALL rows must both agree with it.
#   N2  title, body and the two buttons equal h49 #1's words, read from docs/product-decisions.md at run time, with
#       <App> = the label; a missing or blank label reads "This app" in the title and "this app" in the body.
#   N3  in materializeLocked, the check sits after `if (apks.isEmpty())` and before `ok = installApks(pkg, apks);`:
#       Endospore from app.grapheneos.gmscompat, the marker from base.apk's GET_META_DATA, Play Store present through
#       MATCH_ARCHIVED_PACKAGES, stackInGroup from deps, `quiet` passed; ASK calls PlayNeedAskActivity.ask and only YES
#       installs; the held exit is rmTree(dir), matEnd = SweepOutcome.NEEDS_PLAY, return false.
#   N4  the manifest's .PlayNeedAskActivity is android:exported="false".
#   N5  PlayNeedAskActivity shows PlayNeed.title/body, "Install anyway" answers yes, "Not now", Back and onDestroy answer
#       no, an outside tap decides nothing, and its answer holder is its own.
#
# It needs a JDK, and it FAILS when there is none: a Java suite that skips without one would read green on a runner
# that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass:
#   M1 the Endospore gate dropped (N1)        M2 the quiet sweep asks (N1)        M3 stackPresent ignored (N1)
#   M4 stackInGroup ignored (N1)              M5 a title word changed (N2)        M6 installApks before the check (N3)
#   M7 the activity exported (N4)             M8 the sweep passes quiet=false (N3)  M9 the held exit falls through (N3)
#   M10 onDestroy answers yes (N5)            M11 the Endospore probe reads another package (N3)
#
#   bash core/chooser/test-play-need-java.sh            # the cases and the source checks
#   bash core/chooser/test-play-need-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-play-need-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-play-need-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
MAN=core/chooser/AndroidManifest.xml
DEC=docs/product-decisions.md
mkdir -p "$W/cases"
CASES=$W/cases/PlayNeedCases.java
cat >"$CASES" <<'JAVA'
package com.nowhere.chooser;

public final class PlayNeedCases {
    static int bad = 0;
    static void eq(String id, String what, Object want, Object got) {
        if (want == null ? got == null : want.equals(got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        bad++;
    }
    static String row(boolean... b) {
        StringBuilder s = new StringBuilder();
        for (boolean x : b) s.append(x ? 'T' : 'F');
        return s.toString();
    }
    // args: the decision's title, body, first button, second button, each with <App> as written.
    public static void main(String[] a) {
        int n1 = bad;
        // The two rows that do not install, by hand (endospore, apkNeedsPlay, stackPresent, stackInGroup, quiet).
        java.util.Map<String, PlayNeed.Verdict> hand = new java.util.HashMap<>();
        hand.put("TTFFF", PlayNeed.Verdict.ASK);
        hand.put("TTFFT", PlayNeed.Verdict.SKIP);
        int rows = 0;
        for (int m = 0; m < 32; m++) {
            boolean e = (m & 16) != 0, n = (m & 8) != 0, p = (m & 4) != 0, g = (m & 2) != 0, q = (m & 1) != 0;
            PlayNeed.Verdict rule = !(e && n && !p && !g) ? PlayNeed.Verdict.INSTALL
                    : (q ? PlayNeed.Verdict.SKIP : PlayNeed.Verdict.ASK);
            String r = row(e, n, p, g, q);
            PlayNeed.Verdict byHand = hand.getOrDefault(r, PlayNeed.Verdict.INSTALL);
            if (rule != byHand) { System.out.println("FAIL N1 the cases disagree with themselves at " + r); bad++; }
            eq("N1", "decide(" + r + ")", byHand, PlayNeed.decide(e, n, p, g, q));
            rows++;
        }
        if (bad == n1) System.out.println("ok N1 decide() over all " + rows + " inputs: ASK only at TTFFF, SKIP only at TTFFT");

        int n2 = bad;
        if (a.length != 4) { System.out.println("FAIL N2 want 4 decision strings, got " + a.length); System.exit(1); }
        String title = a[0], body = a[1], b1 = a[2], b2 = a[3];
        eq("N2", "title(YouTube)", title.replace("<App>", "YouTube"), PlayNeed.title("YouTube"));
        eq("N2", "body(YouTube)", body.replace("<App>", "YouTube"), PlayNeed.body("YouTube"));
        eq("N2", "title(null)", title.replace("<App>", "This app"), PlayNeed.title(null));
        eq("N2", "title(\"\")", title.replace("<App>", "This app"), PlayNeed.title(""));
        eq("N2", "title(\"  \")", title.replace("<App>", "This app"), PlayNeed.title("  "));
        eq("N2", "body(null)", body.replace("<App>", "this app"), PlayNeed.body(null));
        eq("N2", "INSTALL_ANYWAY", b1, PlayNeed.INSTALL_ANYWAY);
        eq("N2", "NOT_NOW", b2, PlayNeed.NOT_NOW);
        eq("N2", "MARKER", "com.google.android.gms.version", PlayNeed.MARKER);
        if (bad == n2) System.out.println("ok N2 title, body and buttons are h49 #1's words; a missing label reads \"This app\"");
        if (bad > 0) System.exit(1);
    }
}
JAVA

# words <root>: h49 #1's title, body and two buttons, one per line, from <root>'s decision record.
words() {
  perl -e '
    my $f = shift; open(my $h, "<", $f) or die "$f: $!";
    my $in = 0;
    while (my $l = <$h>) {
      if ($l =~ /^## 2026-10-31 \x{e2}\x{80}\x{94} DECIDED: thirteen answers to harvest 49/) { $in = 1; next }
      next unless $in;
      last if $l =~ /^## /;
      next unless $l =~ /^1\. \*\*The three app messages use the drafts as written\.\*\*/;
      my $i = index($l, "The Play refusal"); last if $i < 0;
      my @w = (substr($l, $i) =~ /\*"(.*?)"\*/g);
      print join("\n", @w[0..3]), "\n" if @w >= 4;
      last;
    }' "$1/$DEC"
}

# cases <root>: compile <root>'s PlayNeed with the cases into a fresh dir and run them. 3 = it did not compile.
cases() {
  local d w
  local -a args
  w=$(words "$1")
  mapfile -t args <<<"$w"
  if [ -z "$w" ] || [ "${#args[@]}" -ne 4 ]; then
    echo "FAIL N2 h49 #1's four strings not found in $DEC"; return 1
  fi
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/PlayNeed.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.PlayNeedCases "${args[@]}"
}

# code <file> <signature line>: the member from its signature to its closing `    }` (or the whole file for an empty
# signature), with whole-line comments dropped and trailing `//` comments stripped (a `//` in a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = $sig eq "" ? 1 : 0;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if $sig ne "" && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$1" "$2"
}

# sources <root>: N3-N5.
sources() {
  local r=$1 mloc act bad=0 msg
  mloc=$(code "$r/$CH/UnarchiveService.java" "    private boolean materializeLocked(String pkg, boolean quiet) {")
  act=$(code "$r/$CH/PlayNeedAskActivity.java" "" 2>/dev/null)
  if [ -z "$mloc" ]; then echo "FAIL N3 materializeLocked not found"; bad=1
  elif msg=$(perl -0e '
      my $c = do { local $/; <STDIN> }; my @e;
      my $l = index($c, "if (apks.isEmpty())");
      my $d = index($c, "PlayNeed.decide(");
      my $i = index($c, "ok = installApks(pkg, apks);");
      ($l >= 0 && $d > $l && $i > $d) or push @e, "PlayNeed.decide( is not between if (apks.isEmpty()) and ok = installApks(pkg, apks);";
      my $n = () = $c =~ /PlayNeed\.decide\(/g; $n == 1 or push @e, "PlayNeed.decide( appears $n times";
      my $n2 = () = $c =~ /ok = installApks\(pkg, apks\);/g; $n2 == 1 or push @e, "ok = installApks(pkg, apks); appears $n2 times";
      my $blk = ($d > $l && $i > $d) ? substr($c, $l, $i - $l) : "";
      $blk =~ /PlayNeed\.decide\(endospore, apkNeedsPlay, stackPresent,\s*deps\.contains\(ProfileActivity\.VENDING_PKG\), quiet\);/
        or push @e, "decide is not called as (endospore, apkNeedsPlay, stackPresent, deps.contains(VENDING_PKG), quiet)";
      $blk =~ /getApplicationInfo\("app\.grapheneos\.gmscompat", 0\); endospore = true;/
        or push @e, "endospore is not set from app.grapheneos.gmscompat";
      $blk =~ /if \(endospore\) \{/ or push @e, "the APK and PM reads are not behind if (endospore)";
      $blk =~ /new File\(dir, "base\.apk"\)/ or push @e, "the marker is not read from base.apk";
      $blk =~ /getPackageArchiveInfo\(\s*base\.getPath\(\), PackageManager\.GET_META_DATA\)/
        or push @e, "the marker is not read with getPackageArchiveInfo(..., GET_META_DATA)";
      $blk =~ /metaData\.containsKey\(PlayNeed\.MARKER\)/ or push @e, "the marker key is not PlayNeed.MARKER";
      $blk =~ /getPackageInfo\(ProfileActivity\.VENDING_PKG,\s*PackageManager\.PackageInfoFlags\.of\(PackageManager\.MATCH_ARCHIVED_PACKAGES\)\)/
        or push @e, "Play Store presence is not getPackageInfo(VENDING_PKG, PackageInfoFlags.of(MATCH_ARCHIVED_PACKAGES))";
      $blk =~ /need == PlayNeed\.Verdict\.ASK\s*\?\s*PlayNeedAskActivity\.ask\(this, label, PlayNeed\.WAIT_MS\) : null;/
        or push @e, "ASK does not call PlayNeedAskActivity.ask(this, label, PlayNeed.WAIT_MS)";
      $blk =~ /if \(a != PlayFetchAsk\.Reply\.YES\) \{[^{}]*rmTree\(dir\);\s*matEnd = SweepOutcome\.NEEDS_PLAY;\s*return false;\s*\}/s
        or push @e, "the held exit is not rmTree(dir); matEnd = SweepOutcome.NEEDS_PLAY; return false; for every reply but YES";
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$mloc"); then
    echo "ok N3 materializeLocked checks the Play marker after the APK list and before installApks, and holds on no stack"
  else
    echo "FAIL N3 $msg"; bad=1
  fi
  if perl -0e '
      my $c = do { local $/; <STDIN> }; $c =~ s/<!--.*?-->//gs;
      $c =~ /<activity\s+android:name="\.PlayNeedAskActivity"([^>]*)>/s or exit 1;
      exit($1 =~ /android:exported="false"/ ? 0 : 1);' <"$r/$MAN"; then
    echo "ok N4 .PlayNeedAskActivity is not exported"
  else
    echo "FAIL N4 the manifest has no .PlayNeedAskActivity with android:exported=\"false\""; bad=1
  fi
  if [ -z "$act" ]; then echo "FAIL N5 PlayNeedAskActivity.java not found"; bad=1
  elif msg=$(perl -0e '
      my $c = do { local $/; <STDIN> }; my @e;
      $c =~ /\.setText\(PlayNeed\.title\(label\)\);/ or push @e, "the title is not PlayNeed.title(label)";
      $c =~ /\.setText\(PlayNeed\.body\(label\)\);/ or push @e, "the body is not PlayNeed.body(label)";
      $c =~ /(\w+)\.setText\(PlayNeed\.INSTALL_ANYWAY\);\s*\1\.setOnClickListener\(v -> answer\(true\)\);/
        or push @e, "Install anyway does not answer yes";
      $c =~ /(\w+)\.setText\(PlayNeed\.NOT_NOW\);\s*\1\.setOnClickListener\(v -> answer\(false\)\);/
        or push @e, "Not now does not answer no";
      $c =~ /public void onBackPressed\(\) \{\s*answer\(false\);\s*\}/ or push @e, "Back does not answer no";
      $c =~ /protected void onDestroy\(\) \{\s*super\.onDestroy\(\);\s*ASKER\.answer\(token, false\);/
        or push @e, "onDestroy does not answer no";
      $c =~ /setFinishOnTouchOutside\(false\);/ or push @e, "an outside tap can close it";
      $c =~ /static final PlayFetchAsk\.Asker ASKER = new PlayFetchAsk\.Asker\(\);/ or push @e, "the answer holder is not its own";
      $c =~ /PlayFetchAsk\.ASKER/ and push @e, "it touches PlayFetchAsk.ASKER, the download ask holder";
      print join("; ", @e); exit(@e ? 1 : 0);' <<<"$act"); then
    echo "ok N5 PlayNeedAskActivity shows h49 #1's words; only Install anyway answers yes"
  else
    echo "FAIL N5 $msg"; bad=1
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
  mkdir -p "$d/$CH" "$d/docs"
  for n in "$CH/PlayNeed.java" "$CH/PlayNeedAskActivity.java" "$CH/UnarchiveService.java" "$MAN" "$DEC"; do
    cp "$ROOT/$n" "$d/$n"
  done
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
P=$CH/PlayNeed.java
U=$CH/UnarchiveService.java
A=$CH/PlayNeedAskActivity.java
fails=0
mut "M1 the Endospore gate dropped" "$P" 's/if \(!\(endospore && apkNeedsPlay/if (!(apkNeedsPlay/' N1 || fails=$((fails+1))
mut "M2 the quiet sweep asks" "$P" 's/return quiet \? Verdict\.SKIP : Verdict\.ASK;/return Verdict.ASK;/' N1 || fails=$((fails+1))
mut "M3 stackPresent ignored" "$P" 's/ && !stackPresent && / && /' N1 || fails=$((fails+1))
mut "M4 stackInGroup ignored" "$P" 's/ && !stackInGroup\)\)/))/' N1 || fails=$((fails+1))
mut "M5 a title word changed" "$P" 's/" needs Play Store"/" needs Google Play"/' N2 || fails=$((fails+1))
mut "M6 installApks before the check" "$U" 's/(\n[ \t]*boolean endospore = false;)/\n                ok = installApks(pkg, apks);$1/; s/(updateNoticePhase\("Installing"\);[^\n]*\n\s*)ok = installApks\(pkg, apks\);/$1/' N3 || fails=$((fails+1))
mut "M7 the activity exported" "$MAN" 's/(android:name="\.PlayNeedAskActivity" android:exported=)"false"/$1"true"/' N4 || fails=$((fails+1))
mut "M8 the sweep passes quiet=false" "$U" 's/deps\.contains\(ProfileActivity\.VENDING_PKG\), quiet\);/deps.contains(ProfileActivity.VENDING_PKG), false);/' N3 || fails=$((fails+1))
mut "M9 the held exit falls through" "$U" 's/(matEnd = SweepOutcome\.NEEDS_PLAY;)\n\s*return false;/$1/' N3 || fails=$((fails+1))
mut "M10 onDestroy answers yes" "$A" 's/ASKER\.answer\(token, false\); \/\/ a no-op/ASKER.answer(token, true); \/\/ a no-op/' N5 || fails=$((fails+1))
mut "M11 the Endospore probe reads another package" "$U" 's/getApplicationInfo\("app\.grapheneos\.gmscompat", 0\); endospore = true;/getApplicationInfo("com.android.vending", 0); endospore = true;/' N3 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
