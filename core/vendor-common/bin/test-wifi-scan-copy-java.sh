#!/usr/bin/env bash
# test-wifi-scan-copy-java.sh [--mutate] -- the setup Wi-Fi screen's status line, run under javac (NWP-20261020-29).
#
# WHY THIS IS COMMITTED. When the chooser is not yet device owner the Wi-Fi scan cannot run (no fine location,
# location off) and getScanResults returns [] silently. The screen used to call that "no networks found"; it now
# says it cannot scan yet and the status line re-runs the scan (and the grant). WifiScanCopy.wifiListStatus is a
# pure class with no android.* import, compiled here with the cases; the PINS check that ChooserActivity renders
# its status through it and wires the re-scan only when the scan could not run.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-wifi-scan-copy-java.sh            # the cases + pins
#   bash test-wifi-scan-copy-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
COPY="$root/core/chooser/src/com/nowhere/chooser/WifiScanCopy.java"
ACT="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/wifi-scan-copy/WifiScanCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

# suite <WifiScanCopy.java> <ChooserActivity.java> -> 0 pass, 1 a case or pin failed (the only code that convicts a
# mutant), 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out
  local bad=0
  # PIN 1: the screen's status line comes from wifiListStatus, fed whether the scan could run.
  perl -0ne 'exit(/netStatus\.setText\(WifiScanCopy\.wifiListStatus\(nets\.size\(\), connected != null, canScan\[0\]\)\);/ ? 0 : 1)' "$act" || {
    echo "  PIN   buildWifiScreen no longer renders its status through wifiListStatus(nets.size(), connected, canScan[0])" >&2; bad=1; }
  # PIN 2: the re-scan is wired on the status line only inside `if (!canScan[0])`.
  perl -0ne 'exit(/if \(!canScan\[0\]\) \{\s*netStatus\.setOnClickListener\(v -> startScan\[0\]\.run\(\)\);\s*\}/ ? 0 : 1)' "$act" || {
    echo "  PIN   the status-line re-scan is no longer wired only when !canScan[0]" >&2; bad=1; }
  # PIN 3: scanWifi reports canScan from fine location, location enabled and Wi-Fi enabled, read AFTER the
  # Wi-Fi-enable wait so it reflects the state at scan time.
  perl -0ne 'exit(/canScanOut\[0\] = checkSelfPermission\(android\.Manifest\.permission\.ACCESS_FINE_LOCATION\)\s*==\s*android\.content\.pm\.PackageManager\.PERMISSION_GRANTED\s*&& lms != null && lms\.isLocationEnabled\(\) && wm\.isWifiEnabled\(\);/ ? 0 : 1)' "$act" || {
    echo "  PIN   scanWifi no longer sets canScan from fine && location && wifi enabled at scan time" >&2; bad=1; }
  # The helper itself: missing (origin/main) is a failure reported AFTER the pins, so all failures show.
  [ -f "$copy" ] || { echo "  FAIL  WifiScanCopy.java does not exist (wifiListStatus is missing)" >&2; return 1; }
  [ "$bad" -eq 0 ] || return 1
  d=$(mktemp -d)
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/WifiScanCopy.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/WifiScanCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.WifiScanCases 2>&1); local rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

echo "== $COPY"
suite "$COPY" "$ACT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local d c a rc; d=$(mktemp -d); c="$d/WifiScanCopy.java"; a="$d/ChooserActivity.java"
  cp "$COPY" "$c"; cp "$ACT" "$a"
  local target="$c"; [ "$2" = act ] && target="$a"
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$COPY" "$c" && cmp -s "$ACT" "$a"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" "$a" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the helper ignores canScan"                  copy 's/if \(!canScan && networks == 0\)/if (false)/' || fails=$((fails+1))
mut "M2 the screen passes canScan as always true"    act  's/connected != null, canScan\[0\]\)\);/connected != null, true));/' || fails=$((fails+1))
mut "M3 the re-scan is wired unconditionally"        act  's/if \(!canScan\[0\]\) \{(\s*netStatus\.setOnClickListener\(v -> startScan\[0\]\.run\(\)\);\s*)\}/if (true) {$1}/' || fails=$((fails+1))
mut "M4 connected and not-connected strings swapped" copy 's/return connected \? "no other networks found" : "no networks found — type the name below";/return connected ? "no networks found — type the name below" : "no other networks found";/' || fails=$((fails+1))
mut "M5 canScan drops the Wi-Fi-enabled term"        act  's/ && lms != null && lms\.isLocationEnabled\(\) && wm\.isWifiEnabled\(\);/ \&\& lms != null \&\& lms.isLocationEnabled();/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
