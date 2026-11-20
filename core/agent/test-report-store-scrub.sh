#!/usr/bin/env bash
# test-report-store-scrub.sh [--mutate] -- runs report_store_scrub_test.go (NWP-20261205-13, h57 #5); --mutate re-runs
# it against a PACKAGE COPY per mutant with one rule of storeScrubPairs, scrubStoreStrings or their calls in
# redactIssueSecrets and statusValue broken in turn. Each mutant must be CONVICTED (a `--- FAIL`); one that fails to
# apply or to compile counts as a failure. The convicting assertion is in each label.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestSessionReportScrubsSelfHostedStore|TestManagedReportUnchangedByStoreScrub|TestFingerprintShapedStatusValueScrubsStore|TestStoreScrubPairsShapes' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <python-regex pattern> <replacement>
  local d res
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R ./*.go go.mod go.sum blindrsa testdata third_party "$d"/
  if ! python3 - "$d/report_issue.go" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,lambda m:m.expand(rep),s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  then echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d" && "${RUN[@]}" 2>&1)
  if grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $1"; else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  rm -rf "$d"
}
mut "S1 storeScrubPairs returns nil (no endpoint/host/bucket left; the Shapes table)" \
  '(func storeScrubPairs\(\) \[\]\[2\]string \{\n)' '\1	return nil
'
mut "S2 the bucket pair dropped (no nw-bucket-7 left; the Shapes table)" \
  '\tadd\(os\.Getenv\("S3_BUCKET"\), "<bucket>"\)\n' ''
mut "S3 only the full endpoint scrubbed (no store.example.test left; the Shapes table)" \
  '\t\t\tadd\(u\.Host, "<store-host>"\)\n\t\t\tadd\(u\.Hostname\(\), "<store-host>"\)\n' '			_ = u
'
mut "S4 case-sensitive store replace (no store.example.test:9443 left, any case)" \
  'regexp\.MustCompile\(`\(\?i\)`\+regexp\.QuoteMeta\(p\[0\]\)\)' 'regexp.MustCompile(regexp.QuoteMeta(p[0]))'
mut "S5 the mode gate inverted (the session report scrubs; the managed GUARD is unchanged)" \
  'if storeMode\(\) != "self-hosted" \{' 'if storeMode() == "self-hosted" {'
mut "S6 shortest first (no port 9443 left beside <store-host>; the Shapes order)" \
  'return len\(pairs\[i\]\[0\]\) > len\(pairs\[j\]\[0\]\)' 'return len(pairs[i][0]) < len(pairs[j][0])'
mut "S7 statusValue returns a matched fingerprint before the store pass (no store in a fingerprint-shaped value)" \
  'if s := scrubStoreStrings\(v\); reIssueBuildFp\.MatchString\(s\) \{\n\t\treturn s\n' 'if reIssueBuildFp.MatchString(v) {
		return v
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
