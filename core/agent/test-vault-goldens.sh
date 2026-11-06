#!/usr/bin/env bash
# test-vault-goldens.sh [--mutate] -- NWP-20261104-11: the vault head's bytes and Sig and the chunk manifest's json names
# are pinned (vault_golden_test.go). Runs the focused Go tests; --mutate applies each mutant in place to main.go
# (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, matches more than once, or does not
# compile is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='TestVaultGolden|TestManifestWireNames'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# judge <label>: run the tests against the mutated main.go and require a real --- FAIL
judge() {
  local lbl="$1" res
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $lbl"
  elif grep -q -E 'build failed|cannot|undefined|declared and not used|syntax error' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
# mutate <label> <old> <new>: <old> must occur exactly once in main.go
mutate() {
  local lbl="$1"
  cp "$W/main.go.orig" main.go
  if ! OLD="$2" NEW="$3" python3 -c "
import os
s = open('main.go').read()
if s.count(os.environ['OLD']) != 1: raise SystemExit('mutant anchor matches %d times' % s.count(os.environ['OLD']))
open('main.go','w').write(s.replace(os.environ['OLD'], os.environ['NEW']))"; then
    echo "  INERT     $lbl -- the mutation did not apply exactly once"; FAILS=$((FAILS+1)); return
  fi
  judge "$lbl"
}
# move <label> <line-substr> <above|below> <target-substr>: each substring matches exactly one line; the first line is
# removed and re-inserted directly above/below the second
move() {
  local lbl="$1"
  cp "$W/main.go.orig" main.go
  if ! SRC="$2" WHERE="$3" TGT="$4" python3 -c "
import os
L = open('main.go').read().split('\n')
src = [i for i, l in enumerate(L) if os.environ['SRC'] in l]
tgt = [i for i, l in enumerate(L) if os.environ['TGT'] in l]
if len(src) != 1 or len(tgt) != 1: raise SystemExit('anchors match %d and %d lines' % (len(src), len(tgt)))
line = L.pop(src[0])
t = tgt[0] - (1 if src[0] < tgt[0] else 0)
L.insert(t if os.environ['WHERE'] == 'above' else t + 1, line)
open('main.go','w').write('\n'.join(L))"; then
    echo "  INERT     $lbl -- the move did not apply"; FAILS=$((FAILS+1)); return
  fi
  judge "$lbl"
}

move "V1 vault RecoveryRef below Version" 'RecoveryRef string     `json:"recovery_ref"`' below 'Version     uint64     `json:"version"`'
mutate "V2 head-sig HMAC label" 'h.Write([]byte("nowhere-head-sig"))' 'h.Write([]byte("nowhere-head-sig2"))'
mutate "V3 vault magic" 'var vaultMagic = []byte("DSPRVLT1")' 'var vaultMagic = []byte("DSPRVLT2")'
move "V4 vault Scopes above Sig" 'Scopes      string     `json:"scopes,omitempty"`' above 'Sig         string     `json:"sig"`'
mutate "V5 deferredFile Sz tag" 'Sz     []int64  `json:"z,omitempty"`' 'Sz     []int64  `json:"sz,omitempty"`'
mutate "V6 essRegion E tag" '`json:"e"`' '`json:"end"`'
move "V7 vault TelPub above Sig" 'TelPub      string     `json:"tel_pub,omitempty"`' above 'Sig         string     `json:"sig"`'
mutate "V8 keyslot LabelSealed tag (NWP-20261114-24)" '`json:"label_sealed,omitempty"`' '`json:"label_seal,omitempty"`'

cp "$W/main.go.orig" main.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
