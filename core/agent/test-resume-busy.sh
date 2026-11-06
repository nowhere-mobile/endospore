#!/usr/bin/env bash
# test-resume-busy.sh [--mutate] -- runs resume_busy_test.go (NWP-20261023-03); --mutate re-runs it against main.go
# with each part of handleResume's busy handling broken in turn, restoring the file on exit. Each mutant must be
# CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go
RUN=(go test -count=1 -run '^TestResumeBusy_' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
# The backup is verified byte-for-byte BEFORE the restoring trap exists: a failed or partial copy (full disk, quota)
# must never be copied back over main.go. Until then the trap only removes the root.
trap 'rm -rf "$W"' EXIT
if ! cp "$MAIN" "$W/main.go.orig" || ! cmp -s "$MAIN" "$W/main.go.orig"; then
  echo "  BROKEN    could not back up $MAIN -- nothing mutated" >&2
  exit 2
fi
trap 'cp -f "$W/main.go.orig" "$MAIN"; rm -rf "$W"' EXIT
fails=0
# conv <label> <expected failing test>: run the suite against the mutated main.go, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" "$MAIN"
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); cp "$W/main.go.orig" "$MAIN"; }
mut() { # mut <label> <expected failing test> <python-regex pattern> <replacement>
  python3 - "$MAIN" "$3" "$4" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  conv "$1" "$2"
}
mut "R1 the verify busy check removed" TestResumeBusy_AnswersBusyForProvenAndUnprovenAlike \
  '(cred, uid, se, nil\)\n[^\n]*\n[^\n]*\n)\tif out == workerBusy \{\n\t\tbusy\(\)\n\t\treturn\n\t\}\n' '\1'
mut "R2 the verify busy check made proof-dependent" TestResumeBusy_AnswersBusyForProvenAndUnprovenAlike \
  '\tif out == workerBusy \{\n\t\tbusy\(\)\n\t\treturn\n\t\}\n\tif !proven' '\tif proven && out == workerBusy {\n\t\tbusy()\n\t\treturn\n\t}\n\tif !proven'
mut "R3 busy no longer drops the key material" TestResumeBusy_NFCStashIsConsumedAndNoKeyMaterialRemains \
  '(busy := func\(\) \{\n)\t\tdropKeyMaterial\(\)\n' '\1'
mut "R4 the fido2hmac busy check removed" TestResumeBusy_KeyStepOnTheUSBPathIsBusyNotNeedKey \
  '(resumeMarkerOnlyPass, uid, se, nil\)\n)\t\t\tif out == workerBusy \{\n\t\t\t\tbusy\(\)\n\t\t\t\treturn\n\t\t\t\}\n' '\1'
mut "R5 busy answers WRONGPASS" TestResumeBusy_AnswersBusyForProvenAndUnprovenAlike \
  'fmt\.Fprint\(conn, workerBusy\+"\\n"\)\n\t\}\n(?=(?:[^\n]*\n){0,12}?\tif entry == "")' 'fmt.Fprint(conn, "WRONGPASS\\n")\n\t}\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
