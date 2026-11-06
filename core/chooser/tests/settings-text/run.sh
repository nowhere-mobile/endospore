#!/usr/bin/env bash
# run.sh <SettingsText.java> <ProfileActivity.java> -- compile SettingsText with its cases and run them against the
# given ProfileActivity.java (NWP-20261111-17). Driven by core/vendor-common/bin/test-settings-text-java.sh, which
# exports JAVAC, JAVA and ST_ROOT (its temp root: every temp here is made inside it, and it removes it at exit).
# Exit: 0 every case passed, 1 a case failed or SettingsText.java is missing, 3 did not compile.
set -uo pipefail
: "${JAVAC:?}" "${JAVA:?}" "${ST_ROOT:?}"
st="$1"; pa="$2"
cases="$(cd "$(dirname "$0")" && pwd)/SettingsTextCases.java"
[ -f "$st" ] || { echo "FAIL SettingsText.java does not exist (the strict read is not there)"; exit 1; }
[ -f "$pa" ] || { echo "FAIL no such file: $pa"; exit 1; }
d=$(mktemp -d -p "$ST_ROOT") || exit 3
mkdir -p "$d/src/com/nowhere/chooser"
cp "$st" "$d/src/com/nowhere/chooser/SettingsText.java"
cp "$cases" "$d/src/com/nowhere/chooser/SettingsTextCases.java"
if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; exit 3; fi
"$JAVA" -Djava.io.tmpdir="$ST_ROOT" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SettingsTextCases "$pa" "$d"
rc=$?
rm -rf "$d"
[ "$rc" -eq 0 ] && exit 0
exit 1
