#!/usr/bin/env bash
# run.sh <DozeAppsMirror.java> <ChooserActivity.java> <ProfileActivity.java> -- NWP-20261114-26: lift choiceEligible and
# GMSCOMPAT_PKG out of DozeAppsMirror.java by signature, ChooserActivity.PUSH_DOZE_PKGS and ProfileActivity.GMS_PKG
# (the array names it) VERBATIM, and run Cases against them under plain javac/java. The curated values are never
# retyped: the cases read the lifted array. None of these members uses an Android type, so no stubs. $JAVAC / $JAVA
# come from the caller (core/vendor-common/bin/test-doze-candidate-java.sh), which also sets $W, the one temp root.
#
# Exit codes: 1 = a case failed; 2 = a member did not extract; 3 = the lifted classes or the cases did not compile.
set -euo pipefail
DM="${1:?usage: run.sh DozeAppsMirror.java ChooserActivity.java ProfileActivity.java}"
ACT="${2:?usage: run.sh DozeAppsMirror.java ChooserActivity.java ProfileActivity.java}"
PROF="${3:?usage: run.sh DozeAppsMirror.java ChooserActivity.java ProfileActivity.java}"
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
# line_of <file> <prefix>: every line that starts with the prefix (the caller requires exactly one)
line_of() { awk -v p="$2" 'index($0, p) == 1' "$1"; }
SIG_ELIG="    static boolean choiceEligible(String pkg, int appId, boolean allowListed, java.util.Collection<String> curated) {"
SIG_GMSC="    static final String GMSCOMPAT_PKG = "
SIG_PUSH="    static final String[] PUSH_DOZE_PKGS = {"
SIG_GMS="    static final String GMS_PKG = "
[ "$(line_of "$DM" "$SIG_GMSC" | grep -c . || true)" = 1 ] || { echo "EXTRACTION FAILED: $SIG_GMSC (not once)" >&2; exit 2; }
[ "$(line_of "$PROF" "$SIG_GMS" | grep -c . || true)" = 1 ] || { echo "EXTRACTION FAILED: $SIG_GMS (not once)" >&2; exit 2; }
{
  echo "final class DozeAppsMirror {"
  line_of "$DM" "$SIG_GMSC"
  brace_block "$DM" "$SIG_ELIG"
  echo "}"
} > "$D/DozeAppsMirror.java"
{
  echo "final class ChooserActivity {"
  brace_block "$ACT" "$SIG_PUSH"
  echo "}"
} > "$D/ChooserActivity.java"
{
  echo "final class ProfileActivity {"
  line_of "$PROF" "$SIG_GMS"
  echo "}"
} > "$D/ProfileActivity.java"
[ "$(grep -cF -- "$SIG_ELIG" "$D/DozeAppsMirror.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $SIG_ELIG" >&2; exit 2; }
[ "$(grep -cF -- "$SIG_PUSH" "$D/ChooserActivity.java" || true)" = 1 ] || { echo "EXTRACTION FAILED: $SIG_PUSH" >&2; exit 2; }
# a lifted block that is only its signature line is an anchor that matched but never closed
[ "$(grep -c . "$D/DozeAppsMirror.java")" -ge 8 ] || { echo "EXTRACTION FAILED: choiceEligible is too short" >&2; exit 2; }
[ "$(grep -c . "$D/ChooserActivity.java")" -ge 4 ] || { echo "EXTRACTION FAILED: PUSH_DOZE_PKGS is too short" >&2; exit 2; }
cp "$here/Cases.java" "$D/"
"$JAVAC" -encoding UTF-8 -d "$D" "$D/DozeAppsMirror.java" "$D/ChooserActivity.java" "$D/ProfileActivity.java" \
  "$D/Cases.java" || exit 3
rc=0
"$JAVA" -Djava.io.tmpdir="$D" -Dfile.encoding=UTF-8 -cp "$D" Cases || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 1 ] || exit 3
exit "$rc"
