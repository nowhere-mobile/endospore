#!/usr/bin/env bash
# test-older-copy-java.sh [--mutate] -- NWP-20261126-07 (h50 #3, docs/product-decisions.md 2026-11-01): the Auto sweep
# recognises a stored copy older than its placeholder and does not retry it. A head sealed before NWP-20261119-02 can
# carry APK bytes older than the archived placeholder's version, and PackageInstaller refuses that unarchive (frankel:
# `version code 26091819 inconsistent with 26102651`); every later sweep of the session fetched it and was refused again.
# NWP-20261128-20 (slice 2): the sign-out records each kept app's installer (`inst` in its meta), and the Auto sweep's
# end says how many of its older copies Play Store would bring back.
# NWP-20261130-07 (slice 3): Your apps shows a refused app as "Not restored", with "Play Store has a newer version" and
# "Open in Play Store" only when Play Store is on the profile and Play is the app's store.
# Compiles the chooser's pure OlderCopy and AppCodeManifest with core/chooser/tests/older-copy ALONE and EXECUTES the
# cases (C0-C8), then checks the REAL UnarchiveService, ProfileActivity and AppInstallReceiver over their code with
# comments dropped (S1-S11):
#   C0  OlderCopy.older(fetched, placeholder) is true exactly when both are > 0 and fetched < placeholder.
#   C1  AppCodeManifest.installer reads the first `inst` line whose value is a valid package name, else null.
#   C2  installerToRecord records the current installer unless it is the chooser or invalid; else the previous meta's.
#   C3  OlderCopy.playCount counts metas Play installed, and only when Play Store is on the profile.
#   C4  OlderCopy.endLine: "1 app ...", "<n> apps ...", null for n <= 0.
#   C5  parseMeta of a meta with an inst line returns the same vc, tsdk, certs and acts.
#   C6  OlderCopy.rowState: PLAY only when refused, kept, not installed, Play on the profile and Play's app; NOT_RESTORED
#       for any other refused, kept, not installed app; NORMAL otherwise.
#   C7  OlderCopy.rowLine and rowButton: the decided words for each state, and the button on PLAY only.
#   C8  OlderCopy.playPageUri is market://details?id=<pkg>.
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
#   S7  appKeepRow's paintOlder asks OLDER_COPY first, then OlderCopy.rowState once, with the row's mode, the app's state,
#       its meta (readAppMeta reads nowhere-appmeta/<pkg>/meta) and isOnDevicePkg(OlderCopy.PLAY).
#   S8  the line's text is OlderCopy.rowLine's, the button's visibility is OlderCopy.rowButton's alone, and the button's
#       tap calls openPlayPage(pkg); both views are in the row's column.
#   S9  paintOlder runs in paint (so at a mode change), in a keepRowSizePaints repaint (the sweep's end) and in a window
#       focus listener (the return from Play Store), added on attach and removed on detach.
#   S10 openPlayPage starts playPageIntent(pkg) when Play Store is installed; when it is archived, it sets PLAY_PAGE_AFTER
#       and then starts UnarchiveService for OlderCopy.PLAY; a throw clears the field. playPageIntent is ACTION_VIEW on
#       OlderCopy.playPageUri(pkg), targeted at OlderCopy.PLAY.
#   S11 launchApp consumes PLAY_PAGE_AFTER only for OlderCopy.PLAY, the tap worker's finally clears it, and
#       AppInstallReceiver's ADDED branch removes pkg from OLDER_COPY before decide().
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against broken copies of OlderCopy, AppCodeManifest, UnarchiveService, ProfileActivity and
# AppInstallReceiver, each of which must FAIL a named check. A mutant that does not apply (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
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

# sources <root>: S1-S11 over <root>'s UnarchiveService.java, ProfileActivity.java and AppInstallReceiver.java.
sources() {
  local r=$1 f sweep mloc whole cap keep prof open svc launch recv bad=0
  f=$r/$CH/UnarchiveService.java
  sweep=$(code "$f" "    private void sweepAuto(boolean byHand) {")
  mloc=$(code "$f" "    private boolean materializeLocked(String pkg, boolean quiet) {")
  whole=$(code "$f")
  cap=$(code "$r/$CH/ProfileActivity.java" "    static void captureArchivedMeta(")
  if [ -z "$sweep" ] || [ -z "$mloc" ]; then echo "FAIL S1 sweepAuto or materializeLocked not found"; return 1; fi
  if [ -z "$cap" ]; then echo "FAIL S5 captureArchivedMeta not found"; return 1; fi
  keep=$(code "$r/$CH/ProfileActivity.java" "    private LinearLayout appKeepRow(")
  prof=$(code "$r/$CH/ProfileActivity.java" "    private String readAppMeta(String pkg) {")
  open=$(code "$r/$CH/ProfileActivity.java" "    private void openPlayPage(String pkg) {")
  svc=$(code "$f" "    static Intent playPageIntent(String pkg) {")
  launch=$(code "$f" "    private void launchApp(String pkg) {")
  recv=$(code "$r/$CH/AppInstallReceiver.java")
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
  pin S7 "paintOlder asks OLDER_COPY first, then rowState once, with the row's mode, state, meta and Play on the profile" '
    $c =~ /final Runnable paintOlder = \(\) -> \{(.*?)\n        \};/s or exit 1;
    my $b = $1;
    my $n = () = $b =~ /OlderCopy\.rowState\(/g; exit 1 unless $n == 1;
    exit($b =~ /if \(UnarchiveService\.OLDER_COPY\.contains\(pkg\)\)\s*s = OlderCopy\.rowState\(true, appMode\(pkg\) != null, isInstalledPkg\(pkg\),\s*readAppMeta\(pkg\), isOnDevicePkg\(OlderCopy\.PLAY\)\);/ ? 0 : 1);' <<<"$keep" || bad=1
  pin S7 "readAppMeta reads the meta the sign-out wrote" '
    exit($c =~ /new java\.io\.File\(new java\.io\.File\(new java\.io\.File\(getFilesDir\(\), "nowhere-appmeta"\), pkg\), "meta"\)/ ? 0 : 1);' <<<"$prof" || bad=1
  pin S8 "the line comes from rowLine, the button from rowButton alone, and its tap opens the Play page" '
    $c =~ /final Runnable paintOlder = \(\) -> \{(.*?)\n        \};/s or exit 1;
    my $b = $1;
    exit 1 unless $b =~ /String line = OlderCopy\.rowLine\(s\);\s*olderLine\.setText\(line\);\s*olderLine\.setVisibility\(line != null \? View\.VISIBLE : View\.GONE\);/;
    exit 1 unless $b =~ /olderPlay\.setVisibility\(OlderCopy\.rowButton\(s\) \? View\.VISIBLE : View\.GONE\);/;
    my $v = () = $c =~ /olderPlay\.setVisibility\(/g; exit 1 unless $v == 2;
    exit 1 unless $c =~ /olderPlay\.setVisibility\(View\.GONE\);/;
    exit 1 unless $c =~ /olderPlay\.setText\(OlderCopy\.BUTTON\);/;
    exit 1 unless $c =~ /olderPlay\.setOnClickListener\(v -> \{\s*openPlayPage\(pkg\);\s*paintOlder\.run\(\);\s*\}\);/;
    exit 1 unless $c =~ /col\.addView\(olderLine, kswp\);/;
    exit($c =~ /col\.addView\(olderPlay, kswp\);/ ? 0 : 1);' <<<"$keep" || bad=1
  pin S9 "paintOlder runs at a mode change, at the sweep's end and when the window gets the focus back" '
    $c =~ /final Runnable paint = \(\) -> \{(.*?)\n        \};/s or exit 1;
    exit 1 unless index($1, "paintOlder.run();") >= 0;
    exit 1 unless $c =~ /keepRowSizePaints\.add\(sizes -> \{ if \(olderLine\.isAttachedToWindow\(\)\) paintOlder\.run\(\); \}\);/;
    $c =~ /OnWindowFocusChangeListener (\w+) = has -> \{ if \(has\) paintOlder\.run\(\); \};/ or exit 1;
    my $l = $1;
    exit 1 unless $c =~ /onViewAttachedToWindow\(View v\) \{ v\.getViewTreeObserver\(\)\.addOnWindowFocusChangeListener\($l\); \}/;
    exit($c =~ /onViewDetachedFromWindow\(View v\) \{ v\.getViewTreeObserver\(\)\.removeOnWindowFocusChangeListener\($l\); \}/ ? 0 : 1);' <<<"$keep" || bad=1
  pin S10 "openPlayPage opens the page, or brings an archived Play Store back first, and a throw clears the field" '
    $c =~ /if \(isInstalledPkg\(OlderCopy\.PLAY\)\) \{\s*startActivity\(UnarchiveService\.playPageIntent\(pkg\)\);\s*\} else \{\s*UnarchiveService\.PLAY_PAGE_AFTER\.set\(pkg\);\s*startForegroundService\(new android\.content\.Intent\(this, UnarchiveService\.class\)\s*\.putExtra\(UnarchiveService\.EXTRA_PKG, OlderCopy\.PLAY\)\);\s*\}/s or exit 1;
    exit($c =~ /catch \(Throwable t\) \{\s*UnarchiveService\.PLAY_PAGE_AFTER\.set\(null\);/ ? 0 : 1);' <<<"$open" || bad=1
  pin S10 "playPageIntent is ACTION_VIEW on the Play page, targeted at Play Store" '
    exit($c =~ /new Intent\(Intent\.ACTION_VIEW, android\.net\.Uri\.parse\(OlderCopy\.playPageUri\(pkg\)\)\)\s*\.setPackage\(OlderCopy\.PLAY\)\s*\.addFlags\(Intent\.FLAG_ACTIVITY_NEW_TASK\);/ ? 0 : 1);' <<<"$svc" || bad=1
  pin S11 "launchApp opens the waiting Play page for Play Store alone" '
    exit($c =~ /if \(OlderCopy\.PLAY\.equals\(pkg\)\) \{\s*String page = PLAY_PAGE_AFTER\.getAndSet\(null\);\s*if \(page != null\) li = playPageIntent\(page\);\s*\}\s*if \(li == null\) li = getPackageManager\(\)\.getLaunchIntentForPackage\(pkg\);/ ? 0 : 1);' <<<"$launch" || bad=1
  pin S11 "the tap worker's finally clears a Play page no launch consumed" '
    my $n = () = $c =~ /if \(OlderCopy\.PLAY\.equals\(pkg\)\) PLAY_PAGE_AFTER\.set\(null\);/g; exit 1 unless $n == 1;
    exit($c =~ /finally \{[^\n]*\n(?:\s*if [^\n]*TapMemory\.remove[^\n]*\n)\s*if \(mine\) LIVE_TAPS\.remove\(pkg\);\s*if \(OlderCopy\.PLAY\.equals\(pkg\)\) PLAY_PAGE_AFTER\.set\(null\);/s ? 0 : 1);' <<<"$whole" || bad=1
  pin S11 "AppInstallReceiver's ADDED branch forgets the refusal before decide" '
    exit($c =~ /boolean replacing = intent\.getBooleanExtra\(Intent\.EXTRA_REPLACING, false\);\s*UnarchiveService\.OLDER_COPY\.remove\(pkg\);\s*(?:OdDataBarrierHost\.onPackageAdded\(context, pkg\);\s*)?decide\(context, pkg, replacing, "broadcast"\);/ ? 0 : 1);' <<<"$recv" || bad=1
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
  for n in "$CH/OlderCopy.java" "$CH/UnarchiveService.java" "$CH/AppCodeManifest.java" "$CH/ProfileActivity.java" "$CH/AppInstallReceiver.java"; do
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
R=$CH/AppInstallReceiver.java
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
mut "R1 the button without Play on the profile" "$O" 's/return playOnProfile && PLAY\.equals/return PLAY.equals/' C6 || fails=$((fails+1))
mut "R2 the button for another installer" "$O" 's/return playOnProfile && PLAY\.equals\(AppCodeManifest\.installer\(metaText\)\) \?/return playOnProfile ?/' C6 || fails=$((fails+1))
mut "R3 the Play line's text dropped" "$O" 's/if \(s == RowState\.PLAY\) return LINE_PLAY;/if (s == RowState.PLAY) return null;/' C7 || fails=$((fails+1))
mut "R4 the plain line's text dropped" "$O" 's/return s == RowState\.NOT_RESTORED \? LINE_PLAIN : null;/return null;/' C7 || fails=$((fails+1))
mut "R5 a row not refused still shows the state" "$O" 's/if \(!refused \|\| !kept/if (!kept/' C6 || fails=$((fails+1))
mut "R6 an installed app still shows the state" "$O" 's/ \|\| installedNow\) return/) return/' C6 || fails=$((fails+1))
mut "R7 an Off row still shows the state" "$O" 's/!refused \|\| !kept \|\|/!refused ||/' C6 || fails=$((fails+1))
mut "R8 the wrong Play URI" "$O" 's/details\?id=/details?pkg=/' C8 || fails=$((fails+1))
mut "R9 the button always visible" "$P" 's/olderPlay\.setVisibility\(OlderCopy\.rowButton\(s\) \? View\.VISIBLE : View\.GONE\);/olderPlay.setVisibility(View.VISIBLE);/' S8 || fails=$((fails+1))
mut "R10 the button does nothing" "$P" 's/olderPlay\.setOnClickListener\(v -> \{\s*openPlayPage\(pkg\);/olderPlay.setOnClickListener(v -> {/' S8 || fails=$((fails+1))
mut "R11 Play on the profile hard-coded" "$P" 's/readAppMeta\(pkg\), isOnDevicePkg\(OlderCopy\.PLAY\)\)/readAppMeta(pkg), true)/' S7 || fails=$((fails+1))
mut "R12 no repaint on the return from Play Store" "$P" 's/has -> \{ if \(has\) paintOlder\.run\(\); \};/has -> { };/' S9 || fails=$((fails+1))
mut "R13 no repaint at the sweep's end" "$P" 's/^[ \t]*keepRowSizePaints\.add\(sizes -> \{ if \(olderLine\.isAttachedToWindow\(\)\) paintOlder\.run\(\); \}\);\n//m' S9 || fails=$((fails+1))
mut "R14 the Play intent not targeted at Play Store" "$U" 's/\s*\.setPackage\(OlderCopy\.PLAY\)//' S10 || fails=$((fails+1))
mut "R15 an archived Play Store not brought back" "$P" 's/^[ \t]*startForegroundService\(new android\.content\.Intent\(this, UnarchiveService\.class\)\s*\.putExtra\(UnarchiveService\.EXTRA_PKG, OlderCopy\.PLAY\)\);\n//m' S10 || fails=$((fails+1))
mut "R16 launchApp ignores the waiting Play page" "$U" 's/if \(page != null\) li = playPageIntent\(page\);//' S11 || fails=$((fails+1))
mut "R17 a failed install leaves a stale Play page" "$U" 's/^[ \t]*if \(OlderCopy\.PLAY\.equals\(pkg\)\) PLAY_PAGE_AFTER\.set\(null\);[^\n]*\n//m' S11 || fails=$((fails+1))
mut "R18 a stale refusal after the install" "$R" 's/^[ \t]*UnarchiveService\.OLDER_COPY\.remove\(pkg\);[^\n]*\n//m' S11 || fails=$((fails+1))
mut "R19 no repaint at a mode change" "$P" 's/^[ \t]*paintOlder\.run\(\); \/\/ a mode change[^\n]*\n//m' S9 || fails=$((fails+1))
mut "R20 every row reads its meta, not only a refused one" "$P" 's/if \(UnarchiveService\.OLDER_COPY\.contains\(pkg\)\)\n\s*s = OlderCopy\.rowState\(true,/s = OlderCopy.rowState(true,/' S7 || fails=$((fails+1))
mut "R21 the line reads the wrong meta file" "$P" 's/"nowhere-appmeta"\), pkg\), "meta"\);(\s*return new String)/"nowhere-appmeta"), pkg), "manifest");$1/' S7 || fails=$((fails+1))
mut "R22 the line's text not set" "$P" 's/^[ \t]*olderLine\.setText\(line\);\n//m' S8 || fails=$((fails+1))
mut "R23 launchApp opens the Play page for any app" "$U" 's/if \(OlderCopy\.PLAY\.equals\(pkg\)\) \{([^\n]*\n\s*String page)/if (true) {$1/' S11 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
