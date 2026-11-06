#!/usr/bin/env bash
# test-gosafe-track.sh [--mutate] -- a tracked goSafe job reports its end only after runSafe has written its
# recovered line (NWP-20261128-14), so a test that waits for the job may restore os.Stderr. G1
# (TestGoSafeTrackedDoneAfterRecoveredLine) reads the log at the moment the tracker's done runs. --mutate injects
# each mutant of goSafe's tracked branch with `go test -overlay`, so the source tree is never edited. Each mutant must
# be CONVICTED by G1's own `--- FAIL` line. A mutant that does not apply or does not compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
G1=TestGoSafeTrackedDoneAfterRecoveredLine

out=$(go test -count=1 -v -run "^($G1|TestGoroutineWait_PanickingJobEnds|TestGoroutineWait_HookBeforeGoStatement|TestGoroutineWait_TracksAtStart|TestEveryGoroutineGoesThroughGoSafe)\$" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
hit=$(grep -E "^--- PASS: $G1 \(" <<<"$out" || true)
[ -n "$hit" ] || { echo "FAIL: $G1 has no --- PASS line"; exit 1; }
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python regex> <replacement text>
  local label="$1" pat="$2" rep="$3" m ov res mrc
  m=$(mktemp -p "$W" --suffix=.go) || exit 2
  ov=$(mktemp -p "$W") || exit 2
  if ! python3 - go_safe.go "$m" "$pat" "$rep" <<'PY'; then
import re, sys
src, dst, pat, rep = sys.argv[1:5]
s = open(src).read()
n, c = re.subn(pat, lambda _: rep, s, count=1)
if c != 1:
    sys.exit(1)
open(dst, "w").write(n)
PY
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return
  fi
  printf '{"Replace":{"%s":"%s"}}' "$PWD/go_safe.go" "$m" >"$ov"
  res=$(go test -count=1 -overlay "$ov" -v -run "^$G1\$" . 2>&1); mrc=$?
  if [[ "$res" == *'build failed'* ]] || [[ "$res" == *'[setup failed]'* ]]; then
    echo "  BROKEN    $label -- the mutant did not compile"; tail -n 15 <<<"$res"; fails=$((fails+1))
  elif [ "$mrc" -ne 0 ] && [[ $'\n'"$res" == *$'\n'"--- FAIL: $G1 ("* ]]; then
    echo "  convicted $label by $G1"
  else
    echo "  SURVIVED  $label -- no --- FAIL: $G1 (rc=$mrc)"; tail -n 15 <<<"$res"; fails=$((fails+1))
  fi
}
mut "M1 done deferred inside fn again (it runs mid-unwind)" \
  'fn = func\(\) \{ defer done\(\); runSafe\(job, inner\) \}' 'fn = func() { defer done(); inner() }'
mut "M2 done called before runSafe" \
  'fn = func\(\) \{ defer done\(\); runSafe\(job, inner\) \}' 'fn = func() { done(); runSafe(job, inner) }'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
