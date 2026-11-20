#!/usr/bin/env bash
# test-no-daemon-wifi-capture.sh [--mutate] -- NWP-20261210-28: the daemon-side Wi-Fi capture is deleted and stays
# deleted. captureWifiMirror read the per-user store /data/misc_ce/<uid>/apexdata/com.android.wifi/WifiConfigStore.xml,
# which is empty on this Android (saved networks are device-wide), so it never captured a network (lynx: 616
# chooser-path mirrors against 0 from it). Pointing it at the device-wide store was not chosen: that store holds every
# user's networks. The chooser's WIFI-MIRROR capture (handleWifiMirror / handleGetWifiMirror) is the one path.
# Source-level checks over every non-test core/agent/*.go:
#   (a) no file names captureWifiMirror;
#   (b) no file names apexdata/com.android.wifi or WifiConfigStore.xml (the per-user AND the device-wide store);
#   (c) CONTROL: main.go declares `func handleWifiMirror(` and `func handleGetWifiMirror(` exactly once each, so an
#       unread or empty tree cannot pass.
# --mutate applies each mutant to a COPY of the package under the suite's one temp root. Each mutant must be
# CONVICTED by the check named for it; a mutant that does not apply is a failure. The control mutant (the store path
# in a _test.go file) must SURVIVE.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
. ./suite-report.sh

# scan <dir>: prints one `--- FAIL (x) ...` line per finding and returns 1 when any; returns 2 when the tree is unreadable.
scan() {
  local dir="$1" f n hits bad=0 files=()
  if [ ! -r "$dir/main.go" ]; then echo "BROKEN: $dir/main.go is missing or unreadable"; return 2; fi
  for f in "$dir"/*.go; do
    case "$f" in *_test.go) continue ;; esac
    if [ ! -r "$f" ]; then echo "BROKEN: $f is unreadable"; return 2; fi
    files+=("$f")
  done
  hits=$(grep -nF -e 'captureWifiMirror' -- "${files[@]}"); n=$?
  if [ "$n" -gt 1 ]; then echo "BROKEN: grep failed (status $n) on (a)"; return 2; fi
  if [ -n "$hits" ]; then
    echo "--- FAIL (a) an agent file names captureWifiMirror (the daemon Wi-Fi capture is back):"
    printf '    %s\n' "$hits"
    bad=1
  fi
  hits=$(grep -nF -e 'apexdata/com.android.wifi' -e 'WifiConfigStore.xml' -- "${files[@]}"); n=$?
  if [ "$n" -gt 1 ]; then echo "BROKEN: grep failed (status $n) on (b)"; return 2; fi
  if [ -n "$hits" ]; then
    echo "--- FAIL (b) an agent file names the Wi-Fi config store (apexdata/com.android.wifi or WifiConfigStore.xml):"
    printf '    %s\n' "$hits"
    bad=1
  fi
  for f in 'func handleWifiMirror(' 'func handleGetWifiMirror('; do
    n=$(grep -cF -e "$f" -- "$dir/main.go")
    if [ "$n" != 1 ]; then
      echo "--- FAIL (c) main.go declares '$f' $n time(s), want exactly 1 (the chooser WIFI-MIRROR path must stay)"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ] && echo "ok  (a) (b) (c): ${#files[@]} non-test agent files scanned; no daemon Wi-Fi capture, the chooser path stays"
  return "$bad"
}

out=$(scan .); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/agent"
fails=0
fresh() { rm -rf "$P" && mkdir -p "$P" && cp -p ./*.go "$P"/; }

# edit <file> <literal anchor> <replacement>: the anchor must match exactly once (\n and \t are escapes).
edit() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, anchor, rep = sys.argv[1:4]
anchor = anchor.encode().decode('unicode_escape')
rep = rep.encode().decode('unicode_escape')
s = open(p, encoding='utf-8').read()
if s.count(anchor) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(anchor, rep))
PY
}

# verdict <label> <want: a|b|c|survive>: scores one mutant already applied to $P.
verdict() {
  local label="$1" want="$2" res rc
  res=$(scan "$P"); rc=$?
  if [ "$rc" -eq 2 ]; then echo "  BROKEN    $label -- $res"; fails=$((fails+1)); return; fi
  if [ "$want" = survive ]; then
    if [ "$rc" -eq 0 ]; then echo "  survived  $label (control, as it must)"
    else echo "  CONVICTED $label -- the control must survive:"; printf '%s\n' "$res"; fails=$((fails+1)); fi
    return
  fi
  if [ "$rc" -eq 1 ] && [[ "$res" == *"--- FAIL ($want)"* ]]; then echo "  convicted $label by ($want)"
  else echo "  SURVIVED  $label -- no --- FAIL ($want); scan said:"; printf '%s\n' "$res"; fails=$((fails+1)); fi
}

# W1: the LOGOUT call back, with a stub so the package would still build.
if fresh && edit "$P/main.go" 'if name == "LOGOUT" {\n\t\thandleLogout(conn, dest)' 'if name == "LOGOUT" {\n\t\tcaptureWifiMirror(dest)\n\t\thandleLogout(conn, dest)' &&
  printf 'package main\n\nfunc captureWifiMirror(dest string) {}\n' >"$P/wifi_capture_stub.go"; then
  verdict "W1 captureWifiMirror(dest) back in the LOGOUT arm" a
else echo "  INERT     W1 -- the mutation did not apply"; fails=$((fails+1)); fi

# W2: the per-user store path in a new agent file.
if fresh && printf 'package main\n\nconst s = "/data/misc_ce/%%s/apexdata/com.android.wifi/WifiConfigStore.xml"\n' >"$P/wifi_peruser.go"; then
  verdict "W2 the per-user store path in a new file" b
else echo "  INERT     W2 -- the mutation did not apply"; fails=$((fails+1)); fi

# W3: the device-wide store (the fix not chosen: it holds every user's networks).
if fresh && printf 'package main\n\nimport "os"\n\nfunc readDeviceWifi() ([]os.DirEntry, error) {\n\treturn os.ReadDir("/data/misc/apexdata/com.android.wifi")\n}\n' >"$P/wifi_device.go"; then
  verdict "W3 a reader of the device-wide store" b
else echo "  INERT     W3 -- the mutation did not apply"; fails=$((fails+1)); fi

# W4: the chooser path's handler renamed.
if fresh && edit "$P/main.go" 'func handleWifiMirror(' 'func handleWifiMirrorX('; then
  verdict "W4 func handleWifiMirror( renamed" c
else echo "  INERT     W4 -- the mutation did not apply"; fails=$((fails+1)); fi

# CONTROL: the same path in a _test.go file is allowed.
if fresh && printf 'package main\n\nconst testStorePath = "/data/misc_ce/%%s/apexdata/com.android.wifi/WifiConfigStore.xml"\n' >"$P/wifi_fixture_test.go"; then
  verdict "C0 the store path in a _test.go file" survive
else echo "  INERT     C0 -- the mutation did not apply"; fails=$((fails+1)); fi

[ "$fails" -eq 0 ] && echo "== all 4 mutations convicted, the control survived" || { echo "== $fails mutation(s) not scored as required"; exit 1; }
