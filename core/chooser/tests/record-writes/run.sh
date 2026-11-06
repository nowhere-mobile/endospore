#!/usr/bin/env bash
# run.sh <ProfileActivity.java> <StoreInstaller.java> -- NWP-20261022-04: lift readPlayDeps, setPlayDep(Context, String,
# boolean), readPlaySeen, notePlaySeen and PLAYDEP_LOCK (and, since NWP-20261111-06, readPlayDepsStrict and
# readPlaySeenStrict, which the other four read through) verbatim out of ProfileActivity.java, and the AtomicIo seam,
# FILE_IO and both writeAtomic overloads out of StoreInstaller.java, by signature, and run RecordWritesCases against
# them under plain javac/java with a Context, a Log and a versionCodeOf stub. $JAVAC / $JAVA come from the caller
# (core/chooser/test-record-writes-java.sh), which also sets $W, the one temp root.
# NWP-20261112-03: also the keep-set readers -- parseAppModes, readAppModesStrictIn, readAppModesIn, parseAppGroups,
# readAppGroupsStrict, readAppGroups, KEEPSET_UNREADABLE and the MODE_* constants they read. TEST SEAM (none in the
# product): readAppModesStrictIn and readAppGroupsStrict are emitted a second time, renamed ...Seam, with their one
# `new java.io.FileReader(f)` replaced by RecordWritesCases.failingReader(), so K2 drives a read that fails mid-file
# through the real strict reader's body.
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted classes or the cases did not compile.
set -euo pipefail
PA="${1:?usage: run.sh path/to/ProfileActivity.java path/to/StoreInstaller.java}"
SI="${2:?usage: run.sh path/to/ProfileActivity.java path/to/StoreInstaller.java}"
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
SIG_RPD="    static java.util.Set<String> readPlayDeps("
SIG_RPDS="    static java.util.Set<String> readPlayDepsStrict("
SIG_SPD="    static void setPlayDep(android.content.Context ctx, String pkg, boolean on) {"
SIG_RPS="    static java.util.Map<String,String[]> readPlaySeen("
SIG_RPSS="    static java.util.Map<String,String[]> readPlaySeenStrict("
SIG_NPS="    static void notePlaySeen(android.content.Context ctx, String pkg, boolean needsPlay) {"
SIG_LOCK="    static final Object PLAYDEP_LOCK = "
SIG_MI="    static final String MODE_INSTALLED = "
SIG_MO="    static final String MODE_ONDEMAND  = "
SIG_MA="    static final String MODE_AUTO      = "
SIG_PAG="    static java.util.Map<String,String> parseAppGroups("
SIG_RAGS="    static java.util.Map<String,String> readAppGroupsStrict("
SIG_RAG="    static java.util.Map<String,String> readAppGroups("
SIG_PAM="    static java.util.LinkedHashMap<String,String> parseAppModes("
SIG_RAMS="    static java.util.LinkedHashMap<String,String> readAppModesStrictIn("
SIG_RAMI="    static java.util.LinkedHashMap<String,String> readAppModesIn("
SIG_KU="    static final java.util.Set<String> KEEPSET_UNREADABLE = "
# seam <signature> <name>: the block again, renamed <name>Seam, its one FileReader replaced by the failing reader
seam() {
  local blk
  blk=$(brace_block "$PA" "$1")
  [ "$(grep -cF 'new java.io.FileReader(f)' <<<"$blk" || true)" = 1 ] || { echo "EXTRACTION FAILED: seam $2" >&2; return 2; }
  blk=${blk/" $2("/" $2Seam("}
  printf '%s\n' "${blk/new java.io.FileReader(f)/RecordWritesCases.failingReader()}"
}
{
  echo "final class ProfileActivity {"
  echo "    static long versionCodeOf(android.content.Context ctx, String pkg) { return RecordWritesCases.versionCodeOf(pkg); }"
  brace_block "$PA" "$SIG_RPD"
  brace_block "$PA" "$SIG_RPDS"
  brace_block "$PA" "$SIG_SPD"
  brace_block "$PA" "$SIG_RPS"
  brace_block "$PA" "$SIG_RPSS"
  brace_block "$PA" "$SIG_NPS"
  one_line "$PA" "$SIG_LOCK"
  one_line "$PA" "$SIG_MI"
  one_line "$PA" "$SIG_MO"
  one_line "$PA" "$SIG_MA"
  brace_block "$PA" "$SIG_PAG"
  brace_block "$PA" "$SIG_RAGS"
  brace_block "$PA" "$SIG_RAG"
  brace_block "$PA" "$SIG_PAM"
  brace_block "$PA" "$SIG_RAMS"
  brace_block "$PA" "$SIG_RAMI"
  one_line "$PA" "$SIG_KU"
  seam "$SIG_RAMS" readAppModesStrictIn || exit 2
  seam "$SIG_RAGS" readAppGroupsStrict || exit 2
  echo "}"
} > "$D/ProfileActivity.java"
{
  echo "import java.io.File;"
  echo "final class StoreInstaller {"
  brace_block "$SI" "    interface AtomicIo {"
  awk '!on && index($0, "    static final AtomicIo FILE_IO = ") == 1 { on=1 } on { print } on && $0 == "    };" { exit }' "$SI"
  brace_block "$SI" "    static void writeAtomic(File f, String content) throws "
  brace_block "$SI" "    static void writeAtomic(File f, String content, AtomicIo io) throws "
  echo "}"
} > "$D/StoreInstaller.java"
for piece in "$SIG_RPD" "$SIG_RPDS" "$SIG_SPD" "$SIG_RPS" "$SIG_RPSS" "$SIG_NPS" "$SIG_LOCK" "$SIG_MI" "$SIG_MO" \
             "$SIG_MA" "$SIG_PAG" "$SIG_RAGS" "$SIG_RAG" "$SIG_PAM" "$SIG_RAMS" "$SIG_RAMI" "$SIG_KU" \
             "    static java.util.LinkedHashMap<String,String> readAppModesStrictInSeam(" \
             "    static java.util.Map<String,String> readAppGroupsStrictSeam("; do
  [ "$(grep -cF -- "$piece" "$D/ProfileActivity.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
for piece in "    interface AtomicIo {" "    static final AtomicIo FILE_IO = " \
             "    static void writeAtomic(File f, String content) throws " \
             "    static void writeAtomic(File f, String content, AtomicIo io) throws "; do
  [ "$(grep -cF -- "$piece" "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $piece" >&2; exit 2; }
done
[ "$(grep -c '^    };$' "$D/StoreInstaller.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: FILE_IO's end" >&2; exit 2; }
# a lifted block that is only its signature line is an anchor that matched but never closed
for f in ProfileActivity StoreInstaller; do
  [ "$(grep -c . "$D/$f.java")" -gt 12 ] || { echo "EXTRACTION FAILED: $f is too short" >&2; exit 2; }
done
cp "$here/RecordWritesCases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/ProfileActivity.java" "$D/StoreInstaller.java" "$D/RecordWritesCases.java" \
  $(find "$here/stubs" -name '*.java') || exit 3
mkdir "$D/cases"
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" RecordWritesCases "$D/cases" || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
