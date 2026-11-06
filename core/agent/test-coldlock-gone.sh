#!/usr/bin/env bash
# test-coldlock-gone.sh [--mutate] -- runs coldlock_gone_test.go (NWP-20261123-29: GET-COLDLOCK answers NONE for a
# .coldlock marker whose user is gone (androidUserGone, the rule CREATE uses) and keeps the marker; GET-COLDLOCK names
# the marker exactly when CREATE refuses with ERR-COLDLOCK); --mutate re-runs it against copies of main.go with the
# guard broken in turn, injected with `go test -overlay`, so the source tree is never edited. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that does not apply, does not compile, or dies without a FAIL line counts as a
# failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestGetColdLock' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  local label="$1" src="$2" m="$W/mut.go" ov="$W/overlay.json" out
  python3 - "$src" "$m" "${@:3}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
src,dst=sys.argv[1:3]
rest=sys.argv[3:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(dst,'w').write(s)
PY
  printf '{"Replace":{"%s":"%s"}}\n' "$PWD/$src" "$m" >"$ov"
  if ! out=$(go vet -overlay "$ov" . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); return
  fi
  out=$("${RUN[@]:0:3}" -overlay "$ov" "${RUN[@]:3}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$out"; then
    echo "  convicted $label: $(grep -m1 -- '--- FAIL' <<<"$out")"
  elif [ -n "$out" ] && ! grep -q '^ok' <<<"$out"; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
}
# Every pattern anchors on the guard's own log line, so none can hit sessionInPlay or refuseCreateOverColdLock.
G='if uid != "" && androidUserGone\(uid\) \{\n\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] GET-COLDLOCK: \.coldlock names user '
mut "G1 the guard removed" main.go "$G" \
  $'if false {\n\t\tfmt.Fprintf(os.Stderr, "[logind] GET-COLDLOCK: .coldlock names user '
mut "G2 the guard's condition inverted" main.go "$G" \
  $'if uid != "" && !androidUserGone(uid) {\n\t\tfmt.Fprintf(os.Stderr, "[logind] GET-COLDLOCK: .coldlock names user '
mut "G3 the guard also removes the marker" main.go \
  '(answering NONE \(NWP-20261123-29\)\\n", uid\)\n)(\t\tfmt\.Fprint\(conn, "NONE\\n"\)\n)' \
  $'answering NONE (NWP-20261123-29)\\n", uid)\n\t\tos.Remove(filepath.Join(dest, ".coldlock"))\n\t\tfmt.Fprint(conn, "NONE\\n")\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
