#!/usr/bin/env bash
# test-restore-bare-head-reads.sh [--mutate] -- NWP-20261113-12 (Q036): one restore invocation reads the bare head from
# the store once. profileDeleted's live read is handed to scopeOwnerLocked and the vault head lookup through a
# per-invocation, hits-only refProbeMemo, and vaultHeadLocked fetches the vault blob through headBlobGet. Runs the
# focused Go tests; --mutate applies each mutant to a pristine copy of main.go or locked_head.go (both restored on exit)
# and requires a real `--- FAIL`: a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp locked_head.go "$W/locked_head.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/locked_head.go.orig" locked_head.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='BareHeadReads|LockedHead'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
restore_pristine() {
  cp "$W/main.go.orig" main.go
  cp "$W/locked_head.go.orig" locked_head.go
}
# mutate <label> <file> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o r
  restore_pristine
  if ! python3 -c "
s = open('$f').read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open('$f','w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1)); restore_pristine; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1); r=$?
  score_mutant "$lbl" "$r" "$o" || FAILS=$((FAILS+1))
  restore_pristine
}
echo "== mutations =="
mutate "M1: scopeOwnerLockedWith bypasses the memo" locked_head.go "
t = s.replace('headRefWith(base, bare, pass, memo.probeStrict)', 'headRefWith(base, bare, pass, refProbeStrict)', 1)"
mutate "M2: vaultHeadLocked fetches the vault blob with getHeadBlob" locked_head.go "
t = s.replace('parseVault(headBlobGet(base, head))', 'parseVault(getHeadBlob(base, head))', 1)"
mutate "M3: the memo records absent refs" main.go "
t = s.replace('\t\treturn false, v, have // Q036', '\t\tm[ref] = refProbeRead{}\n\t\treturn false, v, have // Q036', 1)"
mutate "M4: the memo answers a rung it never probed (a unit head)" main.go "
t = s.replace('\tex, v, have := refProbe(base, ref)\n\tif !ex {', '\tfor _, r := range m {\n\t\tif r.exists {\n\t\t\treturn true, r.val, true\n\t\t}\n\t}\n\tex, v, have := refProbe(base, ref)\n\tif !ex {', 1)"
mutate "M5: the restore case gives profileDeleted a memo of its own" main.go "
t = s.replace('if profileDeletedWith(base, profile, pass, memo) {', 'if profileDeletedWith(base, profile, pass, refProbeMemo{}) {', 1)"
mutate "M6: the vault head lookup bypasses the memo" main.go "
t = s.replace('href, hval, have := headRefWith(base, name, pass, memo.probe)', 'href, hval, have := headRefWith(base, name, pass, refProbe)', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
echo "6 mutants convicted"
