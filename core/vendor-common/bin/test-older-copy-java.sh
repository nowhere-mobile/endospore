#!/usr/bin/env bash
# test-older-copy-java.sh [--mutate] -- NWP-20261126-07 (h50 #3, docs/product-decisions.md 2026-11-01): the Auto sweep
# recognises a stored copy older than its placeholder and does not retry it. A head sealed before NWP-20261119-02 can
# carry APK bytes older than the archived placeholder's version, and PackageInstaller refuses that unarchive (frankel:
# `version code 26091819 inconsistent with 26102651`); every later sweep of the session fetched it and was refused again.
# NWP-20261128-20 (slice 2): the sign-out records each kept app's installer (`inst` in its meta), and the Auto sweep's
# end says how many of its older copies Play Store would bring back.
# Compiles the chooser's pure OlderCopy and AppCodeManifest with core/chooser/tests/older-copy ALONE and EXECUTES the
# cases (C0-C5), then checks the REAL UnarchiveService and ProfileActivity over their code with comments dropped (S1-S6):
#   C0  OlderCopy.older(fetched, placeholder) is true exactly when both are > 0 and fetched < placeholder.
#   C1  AppCodeManifest.installer reads the first `inst` line whose value is a valid package name, else null.
#   C2  installerToRecord records the current installer unless it is the chooser or invalid; else the previous meta's.
#   C3  OlderCopy.playCount counts metas Play installed, and only when Play Store is on the profile.
#   C4  OlderCopy.endLine: "1 app ...", "<n> apps ...", null for n <= 0.
#   C5  parseMeta of a meta with an inst line returns the same vc, tsdk, certs and acts.
#   S1  in materializeLocked, OlderCopy.older( is called once, inside an `if (quiet) {` block that opens after
#       PlayNeed.decide( and closes directly before `updateNoticePhase("Installing");` and `ok = installApks(pkg, apks);`;
#       the block reads base.apk's version (getPackageArchiveInfo) and the archived placeholder's (getPackageInfo with
#       MATCH_ARCHIVED_PACKAGES).
#   S2  its branch adds pkg to OLDER_COPY, calls rmTree(dir), sets matEnd = SweepOutcome.OLDER_COPY and returns false.
#   S3  sweepAuto removes the OLDER_COPY members from `work` right after pendingAutoApps(this, true, retry) and before
#       the AutoSweepNet gate, once, and never from `retry`.
#   S4  UnarchiveService declares OLDER_COPY once, as a concurrent in-RAM set.
#   S5  captureArchivedMeta reads the previous meta from `target` (the published dir), never the staging `dir`, before
#       the meta's writeAtomic and AppMetaDir.publish, records installerToRecord(..., ctx.getPackageName(), ...) and
#       appends `inst\t` once, before the write.
#   S6  sweepAuto's end, after ACTION_SWEEP_DONE: a loop over work that tests OLDER_COPY.contains, no loop over
#       OLDER_COPY, the count then the line, and the notice posted only when the line is not null.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies of OlderCopy, AppCodeManifest, UnarchiveService and ProfileActivity, each of which must FAIL a
# named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-older-copy-java.sh            # the cases and the source checks
#   bash test-older-copy-java.sh --mutate   # ... plus the mutants
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
  echo "test-older-copy-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-older-copy-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
CASES=$ROOT/core/chooser/tests/older-copy/OlderCopyCases.java

# cases <root>: compile <root>'s OlderCopy and AppCodeManifest with the cases into a fresh dir and run them.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/OlderCopy.java" "$1/$CH/AppCodeManifest.java" \
    "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.OlderCopyCases
}

# code <file> [<signature line>]: the method from its signature to its closing `    }` (the whole file with no
# signature), with whole-line comments dropped and trailing `//` comments stripped (a `//` inside a string is kept).
code() {
  perl -e '
    my ($f, $sig) = @ARGV; open(my $h, "<", $f) or die "$f: $!";
    my $in = defined($sig) ? 0 : 1;
    while (my $l = <$h>) {
      if (!$in) { next unless index($l, $sig) == 0; $in = 1; }
      last if defined($sig) && $l =~ /^    \}$/;
      next if $l =~ m{^\s*(//|\*|/\*)};
      $l =~ s{^((?:[^"/\n]|"(?:[^"\\\n]|\\.)*"|/(?![/*]))*)//.*$}{$1};
      print $l;
    }' "$@"
}

# pin <id> <what> <perl body over $c, exit 0 on pass> <<<"$code": one source check.
pin() {
  if perl -0e 'my $c = do { local $/; <STDIN> }; '"$3"; then echo "ok $1 $2"; else echo "FAIL $1 $2"; return 1; fi
}

# sources <root>: S1-S6 over <root>'s UnarchiveService.java and ProfileActivity.java.
sources() {
  local r=$1 f sweep mloc whole cap bad=0
  f=$r/$CH/UnarchiveService.java
  sweep=$(code "$f" "    private void sweepAuto(boolean byHand) {")
  mloc=$(code "$f" "    private boolean materializeLocked(String pkg, boolean quiet) {")
  whole=$(code "$f")
  cap=$(code "$r/$CH/ProfileActivity.java" "    static void captureArchivedMeta(")
  if [ -z "$sweep" ] || [ -z "$mloc" ]; then echo "FAIL S1 sweepAuto or materializeLocked not found"; return 1; fi
  if [ -z "$cap" ]; then echo "FAIL S5 captureArchivedMeta not found"; return 1; fi
  pin S1 "the version check runs on the quiet path only, after the Play-need check and right before installApks" '
    my $n = () = $c =~ /OlderCopy\.older\(/g; exit 1 unless $n == 1;
    my $d = index($c, "PlayNeed.decide("); exit 1 if $d < 0;
    $c =~ /\n([ \t]*)if \(quiet\) \{\n(.*?)\n\1\}\n\s*updateNoticePhase\("Installing"\);\s*\n\s*ok = installApks\(pkg, apks\);/s
      or exit 1;
    my ($open, $body) = ($-[0], $2);
    exit 1 if $open < $d;
    exit 1 unless index($body, "OlderCopy.older(") >= 0;
    exit 1 unless $body =~ /(\w+) = getPackageManager\(\)\.getPackageArchiveInfo\(\s*new File\(dir, "base\.apk"\)\.getPath\(\), 0\);\s*if \(\1 != null\) fetchedVc = \1\.getLongVersionCode\(\);/s;
    exit 1 unless $body =~ /(\w+) = getPackageManager\(\)\.getPackageInfo\(pkg,\s*PackageManager\.PackageInfoFlags\.of\(PackageManager\.MATCH_ARCHIVED_PACKAGES\)\);\s*if \(\1 != null\) placeholderVc = \1\.getLongVersionCode\(\);/s;
    exit 1 unless $body =~ /long fetchedVc = -1, placeholderVc = -1;/;
    exit 0;' <<<"$mloc" || bad=1
  pin S2 "an older copy is remembered, its files removed, and the call ends older-copy" '
    $c =~ /if \(OlderCopy\.older\(fetchedVc, placeholderVc\)\) \{([^{}]*)\}/s or exit 1;
    my $b = $1;
    exit($b =~ /\n\s*OLDER_COPY\.add\(pkg\);\s*rmTree\(dir\);\s*matEnd = SweepOutcome\.OLDER_COPY;\s*return false;\s*\z/ ? 0 : 1);' <<<"$mloc" || bad=1
  pin S3 "sweepAuto drops this session's older copies from work, before the network gate, never from retry" '
    my $n = () = $c =~ /removeAll\(OLDER_COPY\)/g; exit 1 unless $n == 1;
    exit 1 if $c =~ /retry\.removeAll\(/;
    $c =~ /java\.util\.List<String> work = pendingAutoApps\(this, true, retry\);\s*int pending = work\.size\(\);\s*if \(work\.removeAll\(OLDER_COPY\)\)/s
      or exit 1;
    my ($rm, $gate) = (index($c, "work.removeAll(OLDER_COPY)"), index($c, "AutoSweepNet.mayFetch(byHand,"));
    exit(($gate > $rm) ? 0 : 1);' <<<"$sweep" || bad=1
  pin S4 "UnarchiveService declares OLDER_COPY once, as a concurrent in-RAM set" '
    my $n = () = $c =~ /\bOLDER_COPY = /g; exit 1 unless $n == 1;
    exit($c =~ /\n    static final java\.util\.Set<String> OLDER_COPY = java\.util\.concurrent\.ConcurrentHashMap\.newKeySet\(\);\n/ ? 0 : 1);' <<<"$whole" || bad=1
  pin S5 "captureArchivedMeta reads the previous meta from the published dir before the write and records inst" '
    my $prev = index($c, "new java.io.File(target, \"meta\")"); exit 1 if $prev < 0;
    my $wr = index($c, "StoreInstaller.writeAtomic(new java.io.File(dir, \"meta\"), meta.toString());"); exit 1 if $wr < 0;
    my $pub = index($c, "AppMetaDir.publish("); exit 1 if $pub < 0;
    exit 1 unless $prev < $wr && $wr < $pub;
    my $nd = () = $c =~ /new java\.io\.File\(dir, "meta"\)/g; exit 1 unless $nd == 1;
    exit 1 unless $c =~ /AppCodeManifest\.installerToRecord\(\w+, ctx\.getPackageName\(\), (\w+)\)/;
    my $pv = $1; exit 1 unless $c =~ /\b$pv = new String\(java\.nio\.file\.Files\.readAllBytes\(pf\.toPath\(\)\)/;
    my $ni = () = $c =~ /meta\.append\("inst\\t"\)/g; exit 1 unless $ni == 1;
    exit((index($c, "meta.append(\"inst\\t\")") < $wr) ? 0 : 1);' <<<"$cap" || bad=1
  pin S6 "the sweep end counts this sweep's older copies and posts the line only when it is not null" '
    my $nb = () = $c =~ /OlderCopy\.endLine\(/g; exit 1 unless $nb == 1;
    my $np = () = $c =~ /OlderCopy\.playCount\(/g; exit 1 unless $np == 1;
    my $b = index($c, "sendBroadcast(new Intent(ACTION_SWEEP_DONE)"); exit 1 if $b < 0;
    my $e = substr($c, $b);
    exit 1 if $e =~ /MAT_LOCK/;
    exit 1 if $e =~ /for \(String \w+ : OLDER_COPY\)/;
    $e =~ /for \(String (\w+) : work\) \{\s*if \(!OLDER_COPY\.contains\(\1\)\) continue;/ or exit 1;
    my $o = $e; $o =~ s/OLDER_COPY\.contains\(//g; exit 1 if $o =~ /OLDER_COPY/;
    $e =~ /int (\w+) = OlderCopy\.playCount\([\s\S]*?String (\w+) = OlderCopy\.endLine\(\1\);[\s\S]*?if \(\2 != null\) \{([\s\S]*)\z/
      or exit 1;
    exit((index($3, "nm.notify(OlderCopy.NOTICE_ID") >= 0) ? 0 : 1);' <<<"$sweep" || bad=1
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
  for n in "$CH/OlderCopy.java" "$CH/UnarchiveService.java" "$CH/AppCodeManifest.java" "$CH/ProfileActivity.java"; do
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
O=$CH/OlderCopy.java
U=$CH/UnarchiveService.java
A=$CH/AppCodeManifest.java
P=$CH/ProfileActivity.java
fails=0
mut "K1 < turned <=" "$O" 's/fetchedVc < placeholderVc;/fetchedVc <= placeholderVc;/' C0 || fails=$((fails+1))
mut "K2 the > 0 guard dropped" "$O" 's/return fetchedVc > 0 && /return /' C0 || fails=$((fails+1))
mut "K3 the quiet guard dropped" "$U" 's/\n(\s*)if \(quiet\) \{(\n\s*long fetchedVc)/\n$1if (true) {$2/' S1 || fails=$((fails+1))
mut "K4 the OLDER_COPY add removed" "$U" 's/^[ \t]*OLDER_COPY\.add\(pkg\);\n//m' S2 || fails=$((fails+1))
mut "K5 the sweepAuto filter removed" "$U" 's/^[ \t]*if \(work\.removeAll\(OLDER_COPY\)\)[^;]*;\n//m' S3 || fails=$((fails+1))
mut "K6 matEnd set to INSTALL_FAILED instead" "$U" 's/matEnd = SweepOutcome\.OLDER_COPY;/matEnd = SweepOutcome.INSTALL_FAILED;/' S2 || fails=$((fails+1))
mut "K7 the check moved after installApks" "$U" 's/(\n[ \t]*if \(quiet\) \{\n[ \t]*long fetchedVc.*?\n(\s*)\}\n)(\s*updateNoticePhase\("Installing"\);[^\n]*\n\s*ok = installApks\(pkg, apks\);\n)/\n$3$1/s' S1 || fails=$((fails+1))
mut "K8 the filter applied to retry instead" "$U" 's/if \(work\.removeAll\(OLDER_COPY\)\)/if (retry.removeAll(OLDER_COPY))/' S3 || fails=$((fails+1))
mut "M1 installerToRecord records the chooser's own package" "$A" 's/ && !current\.equals\(own\)\) return current;/) return current;/' C2 || fails=$((fails+1))
mut "M2 playCount ignores playOnProfile" "$O" 's/if \(!playOnProfile \|\| metaTexts == null\)/if (metaTexts == null)/' C3 || fails=$((fails+1))
mut "M3 endLine is singular for every n" "$O" 's/return n \+ " apps need Play Store to come back";/return "1 app needs Play Store to come back";/' C4 || fails=$((fails+1))
mut "M4 installer() accepts an invalid name" "$A" 's/if \(isPackageName\(v\)\) return v;/if (!v.isEmpty()) return v;/' C1 || fails=$((fails+1))
mut "M5 the previous meta read from the staging dir" "$P" 's/new java\.io\.File\(target, "meta"\)/new java.io.File(dir, "meta")/' S5 || fails=$((fails+1))
mut "M6 the end counts every OLDER_COPY member of the session" "$U" 's/for \(String p : work\) \{\n(\s*)if \(!OLDER_COPY\.contains\(p\)\) continue;/for (String p : OLDER_COPY) {\n$1if (false) continue;/' S6 || fails=$((fails+1))
mut "M7 the null guard dropped" "$U" 's/if \(line != null\) \{/if (true) {/' S6 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
