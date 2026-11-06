#!/usr/bin/env bash
# test-device-settings.sh [--mutate] -- runs device_settings_test.go and the concurrentSafeCmd / owner-mode tests
# (NWP-20261021-07); --mutate re-runs them against main.go with each guard broken in turn, restoring the file on exit.
# Each mutant must be CONVICTED (a `--- FAIL`); one that fails to apply or to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
SRC=main.go
RUN=(go test -count=1 -run 'TestDeviceSetting|TestNoticeNumberStillDenied|TestConcurrentSafeCmd|TestOwnerMode' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | grep -E '^(--- |ok|FAIL|PASS)' | tail -12
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d)
cp "$SRC" "$W/main.go.orig"
trap 'cp -f "$W/main.go.orig" "$SRC"; rm -rf "$W"' EXIT
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local res
  python3 - "$SRC" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$SRC"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$SRC"
}
mut "G1 SET-OTA-AUTO ignores its write error" 'if err := otaAutoSet\(strings\.TrimSpace\(v\) == "1"\); err != nil \{' 'if err := otaAutoSet(strings.TrimSpace(v) == "1"); false && err != nil {'
mut "G2 SET-OTA-TIME dropped from concurrentSafeCmd" '"GET-OTA-TIME", "SET-OTA-AUTO", "SET-OTA-TIME", ' '"GET-OTA-TIME", "SET-OTA-AUTO", '
# G3 (NWP-20261105-13): since NWP-20261126-19 writeAtomicFile is writeConfDurable, which removes its own .tmp when the
# rename fails, so publishDeviceFlag's Remove is a second cleanup and deleting either alone changes nothing. G3
# deletes both, which is what "a failed SET leaves no .tmp" depends on.
mut "G3 the .tmp not removed after a failed write (publishDeviceFlag's and writeConfDurable's rename cleanup)" '(func publishDeviceFlag.*?)\t\tos\.Remove\(path \+ "\.tmp"\)\n(.*?func writeConfDurable.*?if err := os\.Rename\(tmp, path\); err != nil \{\n)\t\tos\.Remove\(tmp\)\n' '\1\2'
mut "G4 SET-NOTICE-NUMBER ignores its write error" 'if err := noticeNumberSet\(strings\.TrimSpace\(v\) == "1"\); err != nil \{' 'if err := noticeNumberSet(strings.TrimSpace(v) == "1"); false && err != nil {'
mut "G5 clearDeviceFlag swallows every error" '(func clearDeviceFlag.*?)!os\.IsNotExist\(err\)' '\1false'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
