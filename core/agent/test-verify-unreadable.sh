#!/usr/bin/env bash
# test-verify-unreadable.sh [--mutate] -- runs the verify-manifest and restore-preflight tests (NWP-20261120-20, backlog
# "verify-manifest and restore-preflight lost their whole report ... at the first store read that failed in transport"):
# verifyExportManifest reads each ref and each deep blob under recovered and lists a failed read UNREADABLE, and
# headVersionOf reads under recovered and leaves the version unknown; both refuse. The summary names every unreadable
# key, with no twelve-line cap. --mutate re-runs the tests against a COPY of the package with each guard broken in turn.
# Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestVerifyManifest|TestPreflight|TestOnlyADifferingHeadBlocksARestore|TestTheReportNamesTheRollbackDirection|TestAnUnreadableHeadIsNotTreatedAsAgreement|TestASafeDestinationStillReportsWhatItSaw|TestRestoringOverADeleteIsAllowedButNamed|TestThePassPrintsWhatItChecked|TestEveryFailureClassSinksTheVerdictOnItsOwn' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party testdata "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the tests there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the ref read's recover is removed" export_manifest.go \
  'if err := recovered\(func\(\) \{ got = strings\.TrimSpace\(getRef\(base, name\)\) \}\); err != nil \{' \
  'if got = strings.TrimSpace(getRef(base, name)); false {'
mut "M2 the deep blob read's recover is removed" export_manifest.go \
  'if err := recovered\(func\(\) \{ data, found = getBlobSoft\(base, hash\) \}\); err != nil \{' \
  'if data, found = getBlobSoft(base, hash); false {'
mut "M3 ok() ignores Unreadable" export_manifest.go \
  ' && len\(r\.Unreadable\) == 0' ''
mut "M4 headVersionOf's recover is removed" restore_preflight.go \
  'if err := recovered\(func\(\) \{ b, ok = getBlobSoft\(base, blobHash\) \}\); err != nil \|\| !ok \{' \
  'if b, ok = getBlobSoft(base, blobHash); !ok {'
mut "M5 the UNREADABLE section stops at twelve keys" export_manifest.go \
  'for _, k := range r\.Unreadable \{\n' \
  'for i, k := range r.Unreadable {\n\t\t\tif i == 12 {\n\t\t\t\tbreak\n\t\t\t}\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
