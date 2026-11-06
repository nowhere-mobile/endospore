#!/usr/bin/env bash
# test-appcode-manifest-java.sh [--mutate] -- NWP-20261121-05: the sign-in's app-code restore parse runs under javac.
# At every sign-in installRoamedAppCode reads files/.appcode/manifest.tsv (written by roamd's appcode_seal) and decides
# per row whether a kept app is installed from its APKs or raised as an archived placeholder; installArchivedPlaceholder
# reads the placeholder's _meta/meta (written by ProfileActivity.captureArchivedMeta). The seal side is pinned
# (test-appcode-pkg-guard.sh); no suite executed the restore side, so a one-character edit there shipped silently.
# Both parses now live in AppCodeManifest (java.* only). This suite compiles it ALONE with the cases below and EXECUTES
# them (R1-R9 parseRow, L1 hasLauncherLine, T1-T4 parseMeta/targetSdkFor), each case in its own try/catch, then checks
# the REAL ChooserActivity and ProfileActivity with comments dropped, so a comment can neither satisfy nor trip a check:
#   S1  installRoamedAppCode calls AppCodeManifest.parseRow(line, ProfileActivity::defaultGroupFor) and splits nothing.
#   S2  hasLauncherMeta calls AppCodeManifest.hasLauncherLine( and splits nothing.
#   S3  installArchivedPlaceholder calls AppCodeManifest.parseMeta( and AppCodeManifest.targetSdkFor(tsdk), splits
#       nothing and holds no floor of its own.
#   S4  AppCodeManifest's three MODE_* literals equal ProfileActivity's.
#   S5  ProfileActivity's DEFAULT_GROUPS maps com.google.android.gms to "sandboxed-play" (R7 feeds that map by hand).
#
# It needs a JDK and perl, and it FAILS when either is missing: a Java suite that skips without one would read green on
# a runner that never ran it. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs it against broken copies, each of which must FAIL a named check. A mutant that does not apply (INERT)
# or does not compile (BROKEN) counts as a failure, never a pass:
#   M1 "auto" dropped from the mode test (R2)       M2 the moded APK start 4 -> 3 (R1)
#   M3 a group token counted as an APK (R1)         M4 the pre-mode APK start 3 -> 4 (R3)
#   M5 the last group token wins (R5)               M6 the 4-field minimum relaxed to 3 (R4)
#   M7 hasLauncherLine accepts 2 fields (L1)        M8 targetSdkFor returns tsdk unfloored (T2)
#   M9 the default group never applied (R7)         M10 installRoamedAppCode keeps its own split (S1)
#
#   bash core/chooser/test-appcode-manifest-java.sh            # the cases and the source checks
#   bash core/chooser/test-appcode-manifest-java.sh --mutate   # ... plus the mutants
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
  echo "test-appcode-manifest-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
command -v perl >/dev/null 2>&1 || { echo "test-appcode-manifest-java: FAIL -- no perl; this suite did NOT run" >&2; exit 2; }
# ONE temp root: every class dir and mutant tree lives under it, and the trap removes it however this ends.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CH=core/chooser/src/com/nowhere/chooser
mkdir -p "$W/cases"
CASES=$W/cases/AppCodeManifestCases.java
cat >"$CASES" <<'JAVA'
package com.nowhere.chooser;

public final class AppCodeManifestCases {
    interface Case { void run() throws Throwable; }
    static int bad = 0;
    static int caseBad;
    // run: one case id, in its own try/catch, so a case that throws prints "FAIL <id> threw ..." and the rest still run.
    static void run(String id, String what, Case c) {
        caseBad = 0;
        try { c.run(); }
        catch (Throwable t) { System.out.println("FAIL " + id + " threw " + t); caseBad++; }
        if (caseBad == 0) System.out.println("ok " + id + " " + what);
        bad += caseBad;
    }
    static void eq(String id, String what, Object want, Object got) {
        if (java.util.Objects.equals(want, got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        caseBad++;
    }
    static final java.util.Map<String, String> GROUPS = new java.util.HashMap<>();
    static { GROUPS.put("com.google.android.gms", "sandboxed-play"); }
    static AppCodeManifest.Row row(String line) { return AppCodeManifest.parseRow(line, GROUPS::get); }
    static java.util.List<String> l(String... s) { return java.util.Arrays.asList(s); }

    public static void main(String[] a) {
        run("R1", "an installed row with base, two splits and group:x -> 3 APKs in order, group x", () -> {
            AppCodeManifest.Row r = row("com.a\t7\t0\tinstalled\tbase.apk\tsplit_a.apk\tsplit_b.apk\tgroup:x");
            eq("R1", "pkg", "com.a", r.pkg);
            eq("R1", "mode", "installed", r.mode);
            eq("R1", "deferred", false, r.deferred);
            eq("R1", "apks", l("base.apk", "split_a.apk", "split_b.apk"), r.apks);
            eq("R1", "group", "x", r.group);
        });
        run("R2", "an ondemand row and an auto row -> deferred, no APK needed", () -> {
            AppCodeManifest.Row o = row("com.o\t3\t0\tondemand");
            AppCodeManifest.Row u = row("com.u\t3\t0\tauto");
            eq("R2", "ondemand non-null", true, o != null);
            eq("R2", "auto non-null", true, u != null);
            eq("R2", "ondemand mode", "ondemand", o.mode);
            eq("R2", "ondemand deferred", true, o.deferred);
            eq("R2", "auto mode", "auto", u.mode);
            eq("R2", "auto deferred", true, u.deferred);
            eq("R2", "auto apks", l(), u.apks);
        });
        run("R3", "a pre-mode row -> installed, base and split from column 4", () -> {
            AppCodeManifest.Row r = row("com.p\t0\t0\tbase.apk\tsplit.apk");
            eq("R3", "mode", "installed", r.mode);
            eq("R3", "deferred", false, r.deferred);
            eq("R3", "apks", l("base.apk", "split.apk"), r.apks);
        });
        run("R4", "a 3-field row and an empty line -> null", () -> {
            eq("R4", "3 fields", null, row("com.s\t1\t0"));
            eq("R4", "empty line", null, row(""));
        });
        run("R5", "two group tokens -> the first wins", () -> {
            eq("R5", "group", "first", row("com.g\t1\t0\tinstalled\tbase.apk\tgroup:first\tgroup:second").group);
        });
        run("R6", "an empty group: token -> \"\" (today's rule)", () -> {
            AppCodeManifest.Row r = row("com.google.android.gms\t1\t0\tondemand\tgroup:");
            eq("R6", "group", "", r.group);
        });
        run("R7", "no group token -> the default-group function's answer", () -> {
            eq("R7", "gms", "sandboxed-play", row("com.google.android.gms\t1\t0\tondemand").group);
            eq("R7", "other", null, row("com.x\t1\t0\tinstalled\tbase.apk").group);
        });
        run("R8", "an empty APK field is skipped", () -> {
            eq("R8", "apks", l("base.apk", "split.apk"), row("com.e\t1\t0\tinstalled\tbase.apk\t\tsplit.apk").apks);
        });
        run("R9", "an unknown mode word (off) -> installed, APKs from column 4", () -> {
            AppCodeManifest.Row r = row("com.f\t1\t0\toff\tbase.apk");
            eq("R9", "mode", "installed", r.mode);
            eq("R9", "deferred", false, r.deferred);
            eq("R9", "apks", l("off", "base.apk"), r.apks);
        });
        run("L1", "hasLauncherLine: true only for an act line with 3+ fields", () -> {
            eq("L1", "3-field act", true, AppCodeManifest.hasLauncherLine("vc\t5\nact\tc/.A\tLabel\n"));
            eq("L1", "2-field act", false, AppCodeManifest.hasLauncherLine("vc\t5\nact\tc/.A\n"));
            eq("L1", "no act", false, AppCodeManifest.hasLauncherLine("vc\t5\ncert\tAAAA\n"));
            eq("L1", "null", false, AppCodeManifest.hasLauncherLine(null));
        });
        run("T1", "vc 5000000000 -> the (int) cast, a junk vc -> 0", () -> {
            eq("T1", "vc 5000000000", (int) 5000000000L, AppCodeManifest.parseMeta("vc\t5000000000\n").vc);
            eq("T1", "vc junk", 0, AppCodeManifest.parseMeta("vc\tjunk\n").vc);
        });
        run("T2", "tsdk 33 -> 33; tsdk absent or 21 -> 24", () -> {
            AppCodeManifest.Meta m33 = AppCodeManifest.parseMeta("vc\t1\ntsdk\t33\n");
            eq("T2", "tsdk 33", 33, m33.tsdk);
            eq("T2", "targetSdkFor(33)", 33, AppCodeManifest.targetSdkFor(m33.tsdk));
            AppCodeManifest.Meta none = AppCodeManifest.parseMeta("vc\t1\n");
            eq("T2", "tsdk absent", 0, none.tsdk);
            eq("T2", "targetSdkFor(absent)", 24, AppCodeManifest.targetSdkFor(none.tsdk));
            eq("T2", "targetSdkFor(21)", 24, AppCodeManifest.targetSdkFor(AppCodeManifest.parseMeta("tsdk\t21\n").tsdk));
        });
        run("T3", "two cert lines -> both, in order, as written", () -> {
            eq("T3", "certs", l("QUFB", "QkJC"), AppCodeManifest.parseMeta("cert\tQUFB\nvc\t2\ncert\tQkJC\n").certs);
        });
        run("T4", "a 2-field act and a 1-field line are skipped; a 3-field act is {flat, label}", () -> {
            AppCodeManifest.Meta m = AppCodeManifest.parseMeta("act\tc/.Short\nvc\nact\tc/.A\tLabel\n");
            eq("T4", "acts", 1, m.acts.size());
            eq("T4", "act", "c/.A|Label", m.acts.get(0)[0] + "|" + m.acts.get(0)[1]);
            eq("T4", "vc", 0, m.vc);
        });
        if (bad > 0) System.exit(1);
    }
}
JAVA

# cases <root>: compile <root>'s AppCodeManifest with the cases ALONE into a fresh dir and run them. 3 = no compile.
cases() {
  local d
  d=$(mktemp -d -p "$W")
  "$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$d" "$1/$CH/AppCodeManifest.java" "$CASES" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d" com.nowhere.chooser.AppCodeManifestCases
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

# has <text> <fixed string>: 0 when the text holds it (a here-string, never a pipe into grep -q).
has() { grep -qF -- "$2" <<<"$1"; }

# modes <file>: the three MODE_* literals of the file, one "NAME=word" per line, sorted.
modes() {
  perl -ne 'print "$1=$2\n" if /^\s*static final String (MODE_(?:INSTALLED|ONDEMAND|AUTO))\s*=\s*"([^"]*)";/' "$1" | sort
}

# sources <root>: S1-S5.
sources() {
  local r=$1 bad=0 irac hlm iap pa am want
  irac=$(code "$r/$CH/ChooserActivity.java" "    private java.util.Set<String> installRoamedAppCode(int uid) {")
  hlm=$(code "$r/$CH/ChooserActivity.java" "    private boolean hasLauncherMeta(java.io.File metaDir) {")
  iap=$(code "$r/$CH/ChooserActivity.java" "    private boolean installArchivedPlaceholder(String pkg, java.io.File metaDir, int uid) throws Exception {")
  pa=$(code "$r/$CH/ProfileActivity.java" "")
  if [ -z "$irac" ]; then echo "FAIL S1 installRoamedAppCode not found"; bad=1
  elif ! has "$irac" 'AppCodeManifest.parseRow(line, ProfileActivity::defaultGroupFor)'; then
    echo "FAIL S1 installRoamedAppCode does not call AppCodeManifest.parseRow(line, ProfileActivity::defaultGroupFor)"; bad=1
  elif has "$irac" 'split("\t"'; then echo "FAIL S1 installRoamedAppCode still splits a row itself"; bad=1
  else echo "ok S1 installRoamedAppCode parses each row only through AppCodeManifest.parseRow"; fi
  if [ -z "$hlm" ]; then echo "FAIL S2 hasLauncherMeta not found"; bad=1
  elif ! has "$hlm" 'AppCodeManifest.hasLauncherLine('; then echo "FAIL S2 hasLauncherMeta does not call AppCodeManifest.hasLauncherLine"; bad=1
  elif has "$hlm" 'split("\t"'; then echo "FAIL S2 hasLauncherMeta still splits a line itself"; bad=1
  else echo "ok S2 hasLauncherMeta tests the meta only through AppCodeManifest.hasLauncherLine"; fi
  if [ -z "$iap" ]; then echo "FAIL S3 installArchivedPlaceholder not found"; bad=1
  elif ! has "$iap" 'AppCodeManifest.parseMeta('; then echo "FAIL S3 installArchivedPlaceholder does not call AppCodeManifest.parseMeta"; bad=1
  elif ! has "$iap" 'api.setTargetSdkVersion(AppCodeManifest.targetSdkFor(tsdk));'; then
    echo "FAIL S3 installArchivedPlaceholder does not set AppCodeManifest.targetSdkFor(tsdk)"; bad=1
  elif has "$iap" 'tsdk >= 24 ? tsdk : 24'; then echo "FAIL S3 installArchivedPlaceholder still floors tsdk itself"; bad=1
  elif has "$iap" 'split("\t"'; then echo "FAIL S3 installArchivedPlaceholder still splits a line itself"; bad=1
  else echo "ok S3 installArchivedPlaceholder reads the meta through parseMeta and floors through targetSdkFor"; fi
  am=$(modes "$r/$CH/AppCodeManifest.java" 2>/dev/null)
  want=$(modes "$r/$CH/ProfileActivity.java")
  if [ "$(grep -c . <<<"$want")" -ne 3 ]; then echo "FAIL S4 ProfileActivity's three MODE_* literals not found"; bad=1
  elif [ "$am" != "$want" ]; then echo "FAIL S4 AppCodeManifest's MODE_* literals [${am//$'\n'/ }] differ from ProfileActivity's [${want//$'\n'/ }]"; bad=1
  else echo "ok S4 the mode words equal ProfileActivity's: ${want//$'\n'/ }"; fi
  if ! perl -ne '$n++ if /DEFAULT_GROUPS\.put\("com\.google\.android\.gms",\s*"sandboxed-play"\);/; END { exit($n ? 0 : 1) }' <<<"$pa"; then
    echo "FAIL S5 ProfileActivity's DEFAULT_GROUPS does not map com.google.android.gms to sandboxed-play"; bad=1
  else echo "ok S5 ProfileActivity's DEFAULT_GROUPS maps com.google.android.gms to sandboxed-play"; fi
  return "$bad"
}

# check <root>: 0 pass, 1 a failed check, 3 the cases did not compile.
check() {
  local rc=0 crc
  cases "$1"; crc=$?
  [ "$crc" -eq 3 ] && { sources "$1"; return 3; }
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
  for n in "$CH/AppCodeManifest.java" "$CH/ChooserActivity.java" "$CH/ProfileActivity.java"; do
    cp "$ROOT/$n" "$d/$n"
  done
  f="$d/$2"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; rm -rf "$d"; return 1; fi
  if cmp -s "$ROOT/$2" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  out=$(check "$d" 2>&1); rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -eq 3 ]; then echo "  BROKEN    $1 -- it did not compile"; return 1; fi
  if ! grep -qF -- "FAIL $4 " <<<"$out"; then echo "  BROKEN    $1 -- it failed, but not '$4' (rc=$rc)"; return 1; fi
  echo "  convicted $1 (fails '$4')"
}
M=$CH/AppCodeManifest.java
C=$CH/ChooserActivity.java
fails=0
mut "M1 auto dropped from the mode test" "$M" 's/ \|\| MODE_AUTO\.equals\(w\); \/\/ #130/; \/\/ #130/' R2 || fails=$((fails+1))
mut "M2 the moded APK start 4 -> 3" "$M" 's/int apkStart = hasMode \? 4 : 3;/int apkStart = hasMode ? 3 : 3;/' R1 || fails=$((fails+1))
mut "M3 a group token counted as an APK" "$M" 's/if \(f\[i\]\.isEmpty\(\) \|\| f\[i\]\.startsWith\("group:"\)\) continue;/if (f[i].isEmpty()) continue;/' R1 || fails=$((fails+1))
mut "M4 the pre-mode APK start 3 -> 4" "$M" 's/int apkStart = hasMode \? 4 : 3;/int apkStart = hasMode ? 4 : 4;/' R3 || fails=$((fails+1))
mut "M5 the last group token wins" "$M" 's/\{ group = f\[i\]\.substring\(6\)\.trim\(\); break; \}/{ group = f[i].substring(6).trim(); }/' R5 || fails=$((fails+1))
mut "M6 the 4-field minimum relaxed to 3" "$M" 's/if \(f\.length < 4\) return null;/if (f.length < 3) return null;/' R4 || fails=$((fails+1))
mut "M7 hasLauncherLine accepts 2 fields" "$M" 's/if \(f\.length >= 3 && "act"\.equals\(f\[0\]\)\) return true;/if (f.length >= 2 \&\& "act".equals(f[0])) return true;/' L1 || fails=$((fails+1))
mut "M8 targetSdkFor returns tsdk unfloored" "$M" 's/return tsdk >= 24 \? tsdk : 24;/return tsdk;/' T2 || fails=$((fails+1))
mut "M9 the default group never applied" "$M" 's/\n\s*if \(group == null\) group = defaultGroup\.apply\(pkg\);//' R7 || fails=$((fails+1))
mut "M10 installRoamedAppCode keeps its own split" "$C" 's/(AppCodeManifest\.Row r = AppCodeManifest\.parseRow\(line, ProfileActivity::defaultGroupFor\);)/$1\n                String[] f = line.split("\\t", -1);/' S1 || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
