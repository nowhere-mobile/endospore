#!/usr/bin/env bash
# test-build-warning-fetch.sh [--mutate] -- runs build_warning_fetch_test.go (NWP-20261113-23); --mutate re-runs it
# against build_warning_fetch.go with each guard broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED by a real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
SRC=build_warning_fetch.go
trap '[ -f "$W/orig" ] && cp -f "$W/orig" "$SRC"; rm -rf "$W"' EXIT
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestBuildWarningFetch|TestBuildWarningAccept|TestBuildWarningFloorDurable' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$SRC" "$W/orig"
cat >"$W/mut.py" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m: rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
mut() { # mut <label> <regex pattern> <repl>
  local res
  python3 "$W/mut.py" "$SRC" "$2" "$3" || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'--- FAIL'* ]]; then echo "  convicted $1"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $1 -- the mutant did not compile"; fails=$((fails+1))
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp -f "$W/orig" "$SRC"
}
mut "F1 the same-hash arm verifies above the floor seq (the same object refused)" \
  'verifyBuildWarning\(buildWarningKey, env, now, seq-1\)' 'verifyBuildWarning(buildWarningKey, env, now, seq)'
mut "F2 the new-object arm verifies above floor seq-1 (a different same-seq object accepted)" \
  'w, err := verifyBuildWarning\(buildWarningKey, env, now, seq\)' 'w, err := verifyBuildWarning(buildWarningKey, env, now, seq-1)'
mut "F3 the floor is not written after a new accept" \
  'if err := writeBuildWarningFloor\(path, w\.Seq, h\); err != nil \{' 'if err := error(nil); err != nil {'
mut "F4 the damaged arm refuses again (a damaged floor not read as absent)" \
  'damaged := errors\.Is\(err, errBuildWarningFloorDamaged\)' 'damaged := false'
mut "F5 the blob hash check removed" \
  'if sum := sha256\.Sum256\(b\); hex\.EncodeToString\(sum\[:\]\) != h \{' 'if false {'
mut "F6 the same-hash arm skips the verify (an expired stored object accepted)" \
  'w, err := verifyBuildWarning\(buildWarningKey, env, now, seq-1\)' 'w, err := &buildWarning{Schema: 1, Seq: seq}, error(nil)'
mut "F7 the floor is written without a sync" \
  'serr := buildWarningFloorSync\(fh\)' 'serr := error(nil)'
mut "F8 a damaged floor is not rewritten after an accept" \
  'if err := writeBuildWarningFloor\(path, w\.Seq, h\); err != nil \{' 'if err := func() error { if damaged { return errBuildWarningFloorDamaged }; return writeBuildWarningFloor(path, w.Seq, h) }(); err != nil {'
mut "F9 a read error treated as damage (an unreadable floor accepted)" \
  'damaged := errors\.Is\(err, errBuildWarningFloorDamaged\)' 'damaged := err != nil'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
