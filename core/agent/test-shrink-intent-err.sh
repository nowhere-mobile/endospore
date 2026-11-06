#!/usr/bin/env bash
# test-shrink-intent-err.sh [--mutate] -- runs the EXPECT-SHRINK / EXPECT-SHRINK-INFERRED tests in
# shrink_intent_test.go (NWP-20261021-15); --mutate re-runs them against shrink_intent.go with each guard broken
# in turn (shrink_intent.go, and the three wiring lines of pushProfile in main.go), restoring both files on exit. Each mutant must be CONVICTED (a real test failure); one that fails to
# apply, or whose build fails, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
SRC=shrink_intent.go
RUN=(go test -count=1 -failfast -run 'ShrinkIntent|ExpectShrink|SealClear|SealProcess|Unlistable|PushVerbClears|RecoveryEnds|SealClearThenInferred|IncompleteMarker|TruncatingWrite|HoldsTheLock' .)
MAIN=main.go
W=$(mktemp -d); trap '[ -f "$W/src.orig" ] && cp -f "$W/src.orig" "$SRC"; [ -f "$W/main.orig" ] && cp -f "$W/main.orig" "$MAIN"; rm -rf "$W"' EXIT
export GOTMPDIR="$W"
out=$("${RUN[@]}" 2>&1); rc=$?
echo "$out" | tail -3
[ $rc -eq 0 ] || { echo FAILED; exit 1; }
[ "${1:-}" = --mutate ] || exit 0
cp "$SRC" "$W/src.orig"
cp "$MAIN" "$W/main.orig"
TARGET=$SRC
fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local o
  python3 - "$TARGET" "$2" "$3" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  o=$("${RUN[@]}" 2>&1)
  if [[ "$o" == *"--- FAIL"* ]]; then echo "  convicted $1"
  elif [[ "$o" == *"[build failed]"* ]]; then echo "  BUILD-FAIL $1"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/src.orig" "$SRC"; cp "$W/main.orig" "$MAIN"
}
mut "M1 handleExpectShrink ignores the error" 'if failed := markProfileShrinkIntent\(name, pass\); failed != nil \{' 'if failed := markProfileShrinkIntent(name, pass); failed != nil && false {'
mut "M2 no take-back of committed markers" 'for _, d := range st\[:n\] \{' 'for _, d := range st[:0] {'
mut "M3 take-back removes a pre-existing marker" 'if !existed \{' 'if true {'
mut "M4 inferred arm answers OK on failure" 'markShrinkIntentInferred\(profileRefV2\(nm\+"#apps", ps\), pkgs\); err != nil' 'markShrinkIntentInferred(profileRefV2(nm+"#apps", ps), pkgs); err != nil && false'
mut "M5 failed staging removes a pre-existing marker" 'if failed > 0 \{\n\t\tcleanup\(\)' 'if failed > 0 {
		cleanup()
		for _, s := range st {
			os.Remove(s.path)
		}'
mut "M6 no staged fallback when the restoring rename fails" ' \|\| shrinkStage\(path, prev\) == nil' ''
mut "M7 take-back is not retried" 'i < shrinkRestoreTries' 'i < 1'
mut "M8 a lost marker's staged snapshot is deleted" 'if !keep\[d.path\] \{' 'if true {'
mut "M9 the reader trusts a marker mid-transaction" 'if shrinkPending\(f\) \{\n\t\treturn shrinkIntent\{\}' 'if false {
		return shrinkIntent{}'
mut "M10 provenance of an unarmed marker reads as deliberate" 'if !in.armed \{\n\t\treturn "inferred", nil' 'if !in.armed {
		return "deliberate", nil'
mut "M11 no startup recovery pass" '\} else if !recoverShrinkMarker\(f\) \{' '} else if false {'
mut "M13 a committed seal leaves the recovery records" 'if neutralizeShrinkMarker\(f\) \{\n\t\tdropShrinkRecords\(f\)\n\t\}' 'if neutralizeShrinkMarker(f) {
		_ = f
	}'
mut "M14 the absent-marker record is not kept" 'rec, recBody := t.path\+shrinkAbsSuffix, \[\]byte\(nil\)' 'rec, recBody := t.path+".gone", []byte(nil)'
mut "M15 an unremovable transaction flag still answers OK" 'if err := shrinkDrop\(txn\); err != nil && !os.IsNotExist\(err\) \{\n\t\treturn' 'if false {\n\t\treturn'
mut "M16 the recovery record is written in place" 'shrinkWriteFile\(rec\+".new", recBody, 0o600\) != nil \|\| shrinkPublish\(rec\+".new", rec\) != nil' 'shrinkWriteFile(rec, recBody, 0o600) != nil'
mut "M17 the flag is dropped although a marker was not put back" 'if lost == 0 \{\n\t\t\tshrinkDrop\(txn\)' 'if true {
			shrinkDrop(txn)'
mut "M18 the seal's clear does not take the lock" 'unlock, err := lockShrinkDir\(filepath.Dir\(f\), false\)\n\tif err != nil \{\n\t\treturn\n\t\}\n\tdefer unlock\(\)\n\tif match' 'if match'
mut "M19 a seal's clear consumes a newer marker" 'if b, err := os.ReadFile\(f\); err != nil \|\| string\(b\) != token' 'if b, err := os.ReadFile(f); err != nil || string(b) != string(b)'
mut "M20 every write carries the same generation" 'hex.EncodeToString\(n\[:\]\)' 'hex.EncodeToString(n[:0])'
mut "M21 a call over an unrecovered transaction goes ahead" 'if n := recoverShrinkDir\(dir\); n > 0 \{' 'if n := recoverShrinkDir(dir); n > 0 && false {'
mut "M23 an unreadable marker reads as authority" 'b, err := os.ReadFile\(f\)\n\tif err != nil \{\n\t\treturn shrinkIntent\{\}' 'b, err := os.ReadFile(f)
	if err != nil {
		b = []byte("deliberate\\n")'
mut "M24 the reader does not take the lock" 'unlock, err := lockShrinkDir\(filepath.Dir\(f\), false\)\n\tif err != nil \{\n\t\treturn shrinkIntent\{\}\n\t\}\n\tdefer unlock\(\)' '_ = f'
mut "M25 the transaction releases the lock at once" 'defer unlock\(\)\n\ttxn :=' 'unlock()
	txn :='
mut "M26 a stale record that cannot be dropped does not stop recovery" 'if !dropShrinkRecords\(f\) \{\n\t\t\t\t\tleft\+\+' 'dropShrinkRecords(f)
				if false {
					left++'
mut "M27 the clear drops the record before the marker is neutralised" 'if neutralizeShrinkMarker\(f\) \{\n\t\tdropShrinkRecords\(f\)\n\t\}' 'dropShrinkRecords(f)
	neutralizeShrinkMarker(f)'
mut "M28 a marker that cannot be removed is not tombstoned" 'return shrinkStage\(f, \[\]byte\(consumedMarker\)\) == nil' 'return false'
mut "M29 the clear ignores whether the marker was neutralised" 'if neutralizeShrinkMarker\(f\) \{\n\t\tdropShrinkRecords\(f\)\n\t\}' 'neutralizeShrinkMarker(f)
	dropShrinkRecords(f)'
mut "M30 an unlistable directory reads as clean" 'if os.IsNotExist\(err\) \{\n\t\t\treturn 0\n\t\t\}\n\t\treturn 1' 'return 0'
mut "M31 an unreadable transaction flag reads as no transaction" 'return !os.IsNotExist\(err\)' 'return false'
mut "M32 an unreadable record reads as no record" 'err == nil \|\| !os.IsNotExist\(err\)' 'err == nil'
mut "M36 the tombstone is written in place" 'shrinkStage\(f, \[\]byte\(consumedMarker\)\) == nil' 'shrinkRewrite(f, []byte(consumedMarker), 0o600) == nil'
mut "M37 recovery restores a previous body as authority" 'if !neutralizeShrinkMarker\(f\) \{\n\t\treturn false\n\t\}' 'if b, err := os.ReadFile(f + shrinkOldSuffix); err == nil {
		restoreShrinkMarker(f, true, b)
	} else if !neutralizeShrinkMarker(f) {
		return false
	}'
mut "M38 the reader arms an unrecognised body" 'default:\n\t\treturn shrinkIntent\{\}' 'default:'
mut "M39 the reader arms a body without its newline" 'if !strings.HasSuffix\(string\(b\), "\\n"\) \{' 'if false {'
mut "M40 a staged write goes straight to its target" 'side := path \+ ".new"' 'side := path'
mut "M41 recovery drops the records although the marker was not neutralised" 'if !neutralizeShrinkMarker\(f\) \{\n\t\treturn false\n\t\}\n\treturn dropShrinkRecords' 'neutralizeShrinkMarker(f)
	return dropShrinkRecords'
TARGET=$MAIN
mut "M33 pushProfile drops the generation it authorized against" 'shrinkIntentGenSeen = in.token' 'shrinkIntentGenSeen = ""'
mut "M34 the vault seal clears the marker unconditionally" 'clearShrinkIntentGen\(rcptRef, shrinkIntentGenSeen, true\)( // the deletion[^\n]*\n\t\t\}\n\t\t// Rendered)' 'clearShrinkIntent(rcptRef)\1'
mut "M35 the plain seal clears the marker unconditionally" 'clearShrinkIntentGen\(rcptRef, shrinkIntentGenSeen, true\)( // the deletion[^\n]*\n\t\t\}\n\t\tsummary)' 'clearShrinkIntent(rcptRef)\1'
TARGET=$SRC
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
