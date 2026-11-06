#!/usr/bin/env bash
# run.sh <SettingsSaveCopy.java> <ProfileActivity.java> -- compile SettingsSaveCopy with its cases and run them against
# the given ProfileActivity.java (NWP-20261124-23). Driven by core/vendor-common/bin/test-settings-save-java.sh, which
# exports JAVAC, JAVA and SS_ROOT (its temp root: every temp here is made inside it, and it removes it at exit).
# Exit: 0 every case passed, 1 a case failed or SettingsSaveCopy.java is missing, 3 did not compile.
set -uo pipefail
: "${JAVAC:?}" "${JAVA:?}" "${SS_ROOT:?}"
ss="$1"; pa="$2"
cases="$(cd "$(dirname "$0")" && pwd)/SettingsSaveCases.java"
[ -f "$ss" ] || { echo "FAIL SettingsSaveCopy.java does not exist (no control says a change was not saved)"; exit 1; }
[ -f "$pa" ] || { echo "FAIL no such file: $pa"; exit 1; }
d=$(mktemp -d -p "$SS_ROOT") || exit 3
mkdir -p "$d/src/com/nowhere/chooser"
cp "$ss" "$d/src/com/nowhere/chooser/SettingsSaveCopy.java"
cp "$cases" "$d/src/com/nowhere/chooser/SettingsSaveCases.java"
if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; exit 3; fi
"$JAVA" -Djava.io.tmpdir="$SS_ROOT" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SettingsSaveCases "$pa"
rc=$?
rm -rf "$d"
[ "$rc" -eq 0 ] && exit 0
exit 1
