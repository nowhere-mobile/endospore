#!/usr/bin/env bash
# run.sh <StorageDropCopy.java> <SettingsSaveCopy.java> -- NWP-20261128-15: compile StorageDropCopy and SettingsSaveCopy
# with KeepsetUnsavedCases and run the cases. $JAVAC / $JAVA / KEEPSET_UNSAVED_TMP come from
# core/chooser/test-keepset-unsaved-java.sh.
# StorageDropCopy is OPTIONAL: when the file does not exist (origin/main), a stub whose line(...) reproduces main's
# inline ternary in applyStorageDrop (it ignores `saved`) is compiled instead, so on origin/main only the not-saved
# case fails and this exits 1, not 2.
# Exit codes: 1 = a case failed; 2 = a source is missing; 3 = compile failure or the JVM died with anything but 0/1.
set -uo pipefail
SDC="${1:?usage: run.sh StorageDropCopy.java SettingsSaveCopy.java}"
SSC="${2:?}"
JAVAC="${JAVAC:-javac}"
JAVA="${JAVA:-java}"
here=$(cd "$(dirname "$0")" && pwd)
D=$(mktemp -d -p "${KEEPSET_UNSAVED_TMP:?KEEPSET_UNSAVED_TMP is not set}") || exit 2
trap 'rm -rf "$D"' EXIT
[ -f "$SSC" ] || { echo "MISSING: $SSC" >&2; exit 2; }
P="$D/src/com/nowhere/chooser"; mkdir -p "$P" "$D/out" || exit 2
cp "$SSC" "$P/SettingsSaveCopy.java" || exit 2
cp "$here/KeepsetUnsavedCases.java" "$P/KeepsetUnsavedCases.java" || exit 2
if [ -f "$SDC" ]; then
  cp "$SDC" "$P/StorageDropCopy.java" || exit 2
else
  echo "  StorageDropCopy.java absent: stubbed with origin/main's inline words"
  cat > "$P/StorageDropCopy.java" <<'JAVA'
package com.nowhere.chooser;
final class StorageDropCopy {
    static String line(boolean ok, boolean saved, String r, boolean failed, String reason, CharSequence label) {
        return ok ? "Stopped keeping " + label + ". It's still here until you log off."
             : r.startsWith("NONE") ? "No active session."
             : r.startsWith("BUSY") ? "The phone is busy saving or downloading. Nothing "
                     + "changed — tap it again in a moment."
             : failed ? "Nothing changed — " + reason + ". Tap it again in a moment."
             : "Couldn't prepare that change — try again.";
    }
}
JAVA
fi
"$JAVAC" -encoding UTF-8 -d "$D/out" "$P"/*.java || { echo "COMPILE FAILED" >&2; exit 3; }
"$JAVA" -Djava.io.tmpdir="$KEEPSET_UNSAVED_TMP" -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8 \
  -cp "$D/out" com.nowhere.chooser.KeepsetUnsavedCases
rc=$?
case "$rc" in 0|1) exit "$rc" ;; *) echo "JVM exited $rc" >&2; exit 3 ;; esac
