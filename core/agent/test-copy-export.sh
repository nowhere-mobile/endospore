#!/usr/bin/env bash
# test-copy-export.sh [--mutate] -- runs the copy-export tests (NWP-20261205-07, backlog "Moving a profile to a store the
# user runs, way 2: a command-line verb that copies an export folder into a store under keys the user supplies"):
# `nowhere_agent copy-export s3 <export-folder>` makes restore-preflight's refusals first (a destination that holds the
# profile under a newer or an older head), checks the folder, writes the blobs, then the refs, then the manifest LAST,
# then runs verify-manifest against the destination, and exits 2 when it fails. It refuses our gateway and a key that
# leaves the folder, and never prints a store key or a store error (the store path's own retry lines are muted).
# --mutate re-runs the tests against a COPY of the package with each guard broken in turn. Each mutant must be
# CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestCopyExport' .)

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
# Convicted by TestCopyExportRefusesANewerDestination and TestCopyExportRefusesAnOlderDestination (a PUT is logged).
mut "M1 the preflight refusal is skipped" copy_export.go \
  'if !pf\.Safe\(\) \{' 'if false {'
# Convicted by TestCopyExportRefusesANewerDestination (no "ROLL THE PROFILE BACK by 5").
mut "M2 SrcVersion is not read from the folder" copy_export.go \
  '\tcopyExportSrcVersions\(folder, m, pf\)\n' ''
# Convicted by TestCopyExportWritesTheManifestLast (the manifest is not the last PUT).
mut "M3 the manifest PUT moves before the ref loop" copy_export.go \
  '(\t// step 6: [^\n]*\n\tfor .*?\n\t\}\n)(\t// step 7: [^\n]*\n.*?\twritten\+\+\n)' '\2\1'
# Convicted by TestCopyExportWritesTheManifestLast (a ref PUT comes before a blob PUT).
mut "M4 the ref loop moves before the blob loop" copy_export.go \
  '(\t// step 5: [^\n]*\n\tfor .*?\n\t\}\n)(\t// step 6: [^\n]*\n\tfor .*?\n\t\}\n)' '\2\1'
# Convicted by TestCopyExportFailsWhenVerifyFails (rc 0, no INCOMPLETE).
mut "M5 the verify verdict is ignored" copy_export.go \
  'if !rep\.ok\(\) \{' 'if false {'
# Convicted by TestCopyExportRefusesAShortFolder (a PUT is logged).
mut "M6 the folder check is skipped" copy_export.go \
  'if err := copyExportCheckFolder\(folder, m\); err != nil \{' 'if err := error(nil); err != nil {'
# Convicted by TestCopyExportRefusesWithoutTheUsersKeys (stderr does not name GATEWAY_URL).
mut "M7 the capMode refusal is removed" copy_export.go \
  'if capMode\(\) \{' 'if false {'
# Convicted by TestCopyExportReplacesATruncatedObject (the truncated blob is not written again).
mut "M8 the skip tests presence, not size" copy_export.go \
  'sz, ok := copyExportSize\(b\.Key\); ok && sz == int64\(len\(data\)\)' '_, ok := copyExportSize(b.Key); ok'
# Convicted by TestCopyExportRefusesAKeyOutsideTheFolder (the store gets a request).
mut "M9 the key and path check is removed" copy_export.go \
  'if err := copyExportCheckKeys\(folder, m\); err != nil \{' 'if err := error(nil); err != nil {'
# Convicted by TestCopyExportNeverPrintsTheStoreKeys (the access key is printed).
mut "M10 the write-failure line prints the access key" copy_export.go \
  're-run to resume\\n", kind, key\)' 're-run to resume %s\\n", kind, key, os.Getenv("S3_ACCESS_KEY"))'
# Convicted by TestCopyExportNeverPrintsAStoreDiagnostic (a retry line prints the endpoint and the access key).
mut "M11 the store calls print their own retry lines" copy_export.go \
  '\tos\.Stdout, os\.Stderr = null, null\n' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
