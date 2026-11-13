#!/usr/bin/env bash
# test-seal-change-walk.sh [--mutate] -- the change mode of sealdeltawalk (NWP-20261202-06), the input of the h62 #4
# change test of "A profile saves almost continuously: 49 periodic saves in one day, each 8-10 minutes, one starting
# every 11-12 minutes". `sealdeltawalk <uid> "<since> change"` also counts changed directories, the state files of
# account, settings, Bluetooth, sync and package events, and /data/app, and skips only the files the save itself
# writes. Plain: the TestSealChangeWalk tests. --mutate applies each mutant to seal_change_walk.go or
# seal_delta_walk.go in place (pristine copies live in one temp root, restored after every mutant and on exit) and
# runs the same tests; each must be CONVICTED by a real `--- FAIL` of the named test. A mutant that fails to apply
# or to compile is a failure. The suite reads nowhere_roamd.sh as data only, so it runs under no other shell.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(seal_change_walk.go seal_delta_walk.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN='TestSealChangeWalk'

out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <old-literal> <new-literal> [<old-literal> <new-literal>]... -- <convicting test>...
# Every old literal must occur exactly once; all edits apply before the one test run.
mut() {
  local label="$1" file="$2" res want
  local -a edits=()
  shift 2
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do edits+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  python3 - "$file" "${edits[@]}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
import sys
p, pairs = sys.argv[1], sys.argv[2:]
if not pairs or len(pairs) % 2:
    sys.exit(1)
s = open(p).read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    if s.count(old) != 1:
        sys.exit(1)
    s = s.replace(old, new)
open(p, 'w').write(s)
PY
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want "* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
C2=TestSealChangeWalkC2SmallDeleteMovesDir
C3=TestSealChangeWalkC3SelfWritesOnly
C4=TestSealChangeWalkC4ChooserChoiceCounts
C5=TestSealChangeWalkC5StateFile
C6=TestSealChangeWalkC6AppDirChild
C8=TestSealChangeWalkC8PlainModeUnchanged
P1=TestSealChangeWalkP1SelfWrittenHaveWriters
P2=TestSealChangeWalkP2NoPropertyPath

mut "m1 the directory rule removed" seal_delta_walk.go \
  '				cc.ChangedDirs++' '				_ = cc' -- "$C2"
mut "m2 the self list ignored" seal_change_walk.go \
  '	if scope != "vault" {' '	if true {' -- "$C3"
mut "m3 the exclusion widened to the whole dir" seal_change_walk.go \
  '	if scope != "vault" {' '	if scope == "vault" && strings.HasPrefix(rel, sealChangeSelfDir+"/") {
		return true
	}
	if scope != "vault" {' -- "$C4"
mut "m4 the state rule removed" seal_change_walk.go \
  '		if fi.ModTime().Unix() >= since {
			changed++
		}
	}
	return changed, blind
}' '		_ = fi
	}
	return changed, blind
}' -- "$C5"
mut "m5 ENOENT counted as blind" seal_change_walk.go \
  '		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			blind++' '		if err != nil {
			blind++' -- "$C5"
mut "m6 the app rule removed" seal_change_walk.go \
  '		if ci.ModTime().Unix() >= since {' '		if ci == nil {' -- "$C6"
mut "m7 the change fields printed in plain mode" seal_change_walk.go \
  '		b, err = json.Marshal(sealDeltaWalk(roots, unders, idx, listed, since))' \
  '		b, err = json.Marshal(sealChangeWalkOut{sealDeltaWalkOut: sealDeltaWalk(roots, unders, idx, listed, since)})' -- "$C8"
mut "m8 a stray entry (nowhere-perms) added to the self list" seal_change_walk.go \
  '	sealChangeSelfDir + "/nowhere-mediascan.list", // the out arm'"'"'s _msdst' \
  '	sealChangeSelfDir + "/nowhere-mediascan.list", // the out arm'"'"'s _msdst
	sealChangeSelfDir + "/nowhere-perms",' -- "$P1"
mut "m9 nowhere-claims dropped from the self list" seal_change_walk.go \
  '	sealChangeSelfDir + "/nowhere-claims", // the vault push (CLAIMSOUT, writeClaimsToNamed)' '' -- "$C3"
mut "m10 persistent_properties added to the state list" seal_change_walk.go \
  '		"/data/system/packages.xml",      // appcode_seal (#apps): an install, update or uninstall' \
  '		"/data/system/packages.xml",      // appcode_seal (#apps): an install, update or uninstall
		"/data/property/persistent_properties",' -- "$P2"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
