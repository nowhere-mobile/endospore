#!/usr/bin/env bash
# test-race.sh [--mutate] -- runs the agent's concurrency tests under the race detector (NWP-20261102-08). The
# agent is the concurrent half of the phone (worker lanes, cap brackets, seal fences, goSafe jobs) and a plain
# `go test` passes an unsynchronised read on amd64, so these twenty files run with -race: since NWP-20261113-38
# also the wallet lock, the on-demand window under pendingReapMu, telMu, the seal hold, the cold-lock teardown's
# RW-slot queue and the gate-only verbs' wait group; since NWP-20261125-24 also the sign-in's late-work job and
# its abandon flag, the logoff cutoff's wake goroutine, RESTART-UNSAVED's watchdog on the RW slot and the owner
# key's concurrent ensure; since NWP-20261128-02 also the store client's lazy setup against concurrent store
# switches; since NWP-20261128-32 also LOGOUT raising the sign-out signal while it waits for the session lock, and
# FETCH-APP's reader and its sign-out watcher. logout_wait_test.go stays out: its W1/W2 bound wall time with 300 ms and
# 150 ms margins that a -race stall on a one-CPU quota'd lane can eat. A CONTROL then runs
# race_canary_test.go (build tag racecanary), which races on purpose: the detector must report it, or it did not run.
# --mutate re-runs copies of this script with one edit each (M1 -race removed everywhere, M2 an empty FILES list,
# M3 the -run regex drops a name, M4 the control's DATA RACE assertion inverted); each must exit non-zero with the
# expected FAIL text. A mutant whose edit does not apply is a failure, never a pass.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "${RACE_AGENT_DIR:-$HERE}"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export GOTMPDIR="$W"

FILES=(
  concurrency_test.go
  cap_bracket_lock_test.go
  direct_bracket_test.go
  lane_cred_test.go
  media_overlay_race_test.go
  seal_fence_race_test.go
  worker_abandoned_test.go
  wallet_lock_test.go
  od_window_test.go
  telephony_lock_test.go
  seal_hold_test.go
  coldlock_wait_order_test.go
  gate_only_verbs_test.go
  late_work_test.go
  logoff_cutoff_test.go
  end_unsaved_test.go
  owner_key_test.go
  s3_init_race_test.go
  signout_signal_test.go
  fetchapp_signout_test.go
)
# EXCLUDE names one test per line that fails raced (a reported race, or a timeout only -race's slowdown causes),
# with the reason and its backlog section B row title. All other tests of FILES pass under -race on main.
EXCLUDE=()

[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no test files listed"; exit 1; }
NAMES=()
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; exit 1; }
  found=$(grep -oE '^func (Test[A-Za-z0-9_]+)\(' "$f" | sed -E 's/^func (.*)\($/\1/')
  [ -n "$found" ] || { echo "FAIL: $f declares no test"; exit 1; }
  while IFS= read -r n; do
    skip=0
    for x in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do [ "$x" = "$n" ] && skip=1; done
    [ "$skip" -eq 1 ] || NAMES+=("$n")
  done <<<"$found"
done
for x in ${EXCLUDE[@]+"${EXCLUDE[@]}"}; do
  hit=$(grep -hE "^func $x\(" "${FILES[@]}" || true)
  [ -n "$hit" ] || { echo "FAIL: EXCLUDE names $x, which no listed file declares"; exit 1; }
done
[ "${#NAMES[@]}" -gt 0 ] || { echo "FAIL: no test left to run"; exit 1; }

build_re() { (IFS='|'; echo "^(${NAMES[*]})\$"); }
RE=$(build_re)
alts=$(tr -cd '|' <<<"$RE" | wc -c)
[ "$((alts + 1))" -eq "${#NAMES[@]}" ] || { echo "FAIL: the -run regex omits a name ($((alts + 1)) of ${#NAMES[@]})"; exit 1; }
for n in "${NAMES[@]}"; do
  [[ $n =~ $RE ]] || { echo "FAIL: the -run regex omits $n"; exit 1; }
done

go version
gcc_v=$(gcc --version 2>&1) || { echo "FAIL: gcc is required for -race (cgo)"; exit 1; }
head -1 <<<"$gcc_v"

out=$(CGO_ENABLED=1 go test -race -count=1 -timeout 15m -v -run "$RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
passed=$(grep -cE '^--- PASS: ' <<<"$out" || true)
for n in "${NAMES[@]}"; do
  hit=$(grep -E "^--- PASS: $n \(" <<<"$out" || true)
  [ -n "$hit" ] || { echo "FAIL: $n has no --- PASS line"; exit 1; }
done
[ "$passed" -eq "${#NAMES[@]}" ] || { echo "FAIL: $passed --- PASS lines for ${#NAMES[@]} tests"; exit 1; }
skips=$(grep -E -- '--- SKIP' <<<"$out" || true)
[ -z "$skips" ] || { echo "FAIL: a test skipped under -race:"; echo "$skips"; exit 1; }
races=$(grep -F 'WARNING: DATA RACE' <<<"$out" || true)
[ -z "$races" ] || { echo "FAIL: the race detector reported a race"; exit 1; }
echo "ok: ${#NAMES[@]} tests passed under -race"

# CONTROL: a test that races on purpose must be reported, or the detector did not run.
cout=$(CGO_ENABLED=1 go test -race -tags racecanary -count=1 -run '^TestRaceCanary$' . 2>&1); crc=$?
creport=$(grep -F 'WARNING: DATA RACE' <<<"$cout" || true)
if [ "$crc" -eq 0 ] || [ -z "$creport" ]; then
  echo "FAIL: the race detector did not run (canary rc=$crc)"
  echo "$cout"
  exit 1
fi
echo "ok: the canary's race was reported (the detector is live)"

[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <expected FAIL text> <python: s=source text; set s to the mutated text>
  local label="$1" want="$2" code="$3" copy mout mrc
  copy=$(mktemp -p "$W") || exit 2
  cp "$HERE/test-race.sh" "$copy"
  python3 - "$copy" "$code" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re, sys
p, code = sys.argv[1:3]
s = open(p).read()
ns = {"re": re, "s": s}
exec(code, ns)
if ns["s"] == s:
    sys.exit(1)
open(p, "w").write(ns["s"])
PY
  mout=$(RACE_AGENT_DIR="$HERE" TMPDIR="$W" bash "$copy" 2>&1); mrc=$?
  if [ "$mrc" -ne 0 ] && [[ "$mout" == *"$want"* ]]; then echo "  convicted $label"
  else echo "  SURVIVED  $label (rc=$mrc, no '$want')"; fails=$((fails+1)); fi
  rm -f "$copy"
}
mut "M1 -race removed from every go test line" 'the race detector did not run' \
'n = len(re.findall(r"(go test) -race\b", s))
assert n >= 2
s = re.sub(r"(go test) -race\b", r"\1", s)'
mut "M2 an empty FILES list" 'no test files listed' \
's = re.sub(r"FILES=\(\n.*?\n\)\n", "FILES=()\n", s, count=1, flags=re.S)'
mut "M3 the regex builder drops the last name" 'the -run regex omits' \
's = s.replace("${NAMES[*]}", "${NAMES[*]:0:${#NAMES[@]}-1}", 1)'
mut "M4 the control's DATA RACE assertion inverted" 'the race detector did not run' \
's = s.replace("[ -z \"$creport\" ]", "[ -n \"$creport\" ]", 1)'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
