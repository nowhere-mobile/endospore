#!/usr/bin/env bash
# run.sh <ProfileActivity.java> <StoreInstaller.java> -- NWP-20261022-18: lift the Play-stack orphan oracle verbatim
# out of ProfileActivity.java by signature (brace-matched, `private` stripped; the two Strict record readers since
# NWP-20261111-06), plus StoreInstaller's AtomicIo seam,
# FILE_IO and both writeAtomic overloads, into a harness class com.nowhere.chooser.ProfileActivity, and run
# PlayOracleCases against it under plain javac/java with the Android stubs in stubs/. The harness supplies
# versionCodeOf (a per-case map, -1 when unset), getPackageName and getFilesDir. $JAVAC / $JAVA / $W come from the
# caller (core/chooser/test-play-oracle-java.sh).
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted classes or the cases did not compile.
set -euo pipefail
PA="${1:?usage: run.sh ProfileActivity.java StoreInstaller.java}"
SI="${2:?usage: run.sh ProfileActivity.java StoreInstaller.java}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${W:-${TMPDIR:-/tmp}}")
trap 'rm -rf "$D"' EXIT
# brace_block <file> <signature prefix>: from the line that starts with it to the brace that closes it
brace_block() {
  awk -v sig="$2" '
    !on && index($0, sig) == 1 { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
one_line() { awk -v sig="$2" 'index($0, sig) == 1 { print; exit }' "$1"; }
PAS=(
  "    private boolean playDependent("
  "    static java.util.Set<String> readPlayDeps("
  "    static java.util.Set<String> readPlayDepsStrict("
  "    static java.util.Map<String,String[]> readPlaySeen("
  "    static java.util.Map<String,String[]> readPlaySeenStrict("
  "    static void notePlaySeen("
  "    private boolean playStackOrphanKnown("
  "    private void logNotOrphaned("
  "    static Boolean readsPlayServices("
)
ONE=(
  "    static final String GMS_PKG = "
  "    static final String GSF_PKG = "
  "    static final String VENDING_PKG = "
  "    static final Object PLAYDEP_LOCK = "
)
mkdir "$D/src" "$D/src/com" "$D/src/com/nowhere" "$D/src/com/nowhere/chooser"
P="$D/src/com/nowhere/chooser"
{
  echo "package com.nowhere.chooser;"
  echo "final class ProfileActivity extends android.content.Context {"
  echo "  static final java.util.Map<String, Long> VC = new java.util.HashMap<>();"
  echo "  static String OWN = \"com.nowhere.chooser\";"
  echo "  final java.io.File dir; final android.content.pm.PackageManager pm;"
  echo "  ProfileActivity(java.io.File dir, android.content.pm.PackageManager pm) { this.dir = dir; this.pm = pm; }"
  echo "  @Override public java.io.File getFilesDir() { return dir; }"
  echo "  @Override public android.content.pm.PackageManager getPackageManager() { return pm; }"
  echo "  @Override public String getPackageName() { return OWN; }"
  echo "  static long versionCodeOf(android.content.Context ctx, String pkg) { Long v = VC.get(pkg); return v == null ? -1L : v; }"
  for s in "${ONE[@]}"; do one_line "$PA" "$s"; done
  for s in "${PAS[@]}"; do brace_block "$PA" "$s" | sed 's/^    private /    /'; echo; done
  echo "}"
} > "$P/ProfileActivity.java"
{
  echo "package com.nowhere.chooser;"
  echo "import java.io.File;"
  echo "final class StoreInstaller {"
  brace_block "$SI" "    interface AtomicIo {"
  awk '!on && index($0, "    static final AtomicIo FILE_IO = ") == 1 { on=1 } on { print } on && $0 == "    };" { exit }' "$SI"
  brace_block "$SI" "    static void writeAtomic(File f, String content) throws "
  brace_block "$SI" "    static void writeAtomic(File f, String content, AtomicIo io) throws "
  echo "}"
} > "$P/StoreInstaller.java"
for piece in "${ONE[@]}" "${PAS[@]}"; do
  piece="${piece/    private /    }"   # the lift strips `private`
  [ "$(grep -cF -- "$piece" "$P/ProfileActivity.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
# every lifted body must be more than its signature line (a brace_block that matched nothing is empty)
for piece in "${PAS[@]}"; do
  [ "$(brace_block "$PA" "$piece" | wc -l)" -gt 2 ] || { echo "EXTRACTION FAILED: $piece has no body" >&2; exit 2; }
done
for piece in "    interface AtomicIo {" "    static final AtomicIo FILE_IO = " \
             "    static void writeAtomic(File f, String content) throws " \
             "    static void writeAtomic(File f, String content, AtomicIo io) throws "; do
  [ "$(grep -cF -- "$piece" "$P/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
[ "$(grep -c '^    };$' "$P/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: FILE_IO's end" >&2; exit 2; }
cp "$here/PlayOracleCases.java" "$P/"
mkdir "$D/out" "$D/cases"
"$JAVAC" -encoding UTF-8 -nowarn -d "$D/out" $(find "$here/stubs" -name '*.java') "$P/ProfileActivity.java" \
    "$P/StoreInstaller.java" "$P/PlayOracleCases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D/out" com.nowhere.chooser.PlayOracleCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
