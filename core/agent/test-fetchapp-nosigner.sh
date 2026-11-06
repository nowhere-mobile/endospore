#!/usr/bin/env bash
# test-fetchapp-nosigner.sh [--mutate] -- runs the FETCH-APP no-signer tests (NWP-20261030-04); --mutate re-runs them
# against catalog.go with each guard broken in turn, restoring the file on exit. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
CAT=catalog.go
trap '[ -f "$W/$CAT" ] && cp -f "$W/$CAT" "$CAT"; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN_RE='FetchAppNoSigner|FetchAppSigner|EntrySignerPin'

out=$(go test -count=1 -run "$RUN_RE" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$CAT" "$W/$CAT"
fails=0
mut() { # mut <label> <transform> <convicting test>...
  local label="$1" xf="$2" res want miss=""
  shift 2
  python3 - "$CAT" "$xf" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$CAT" "$CAT"; return; }
import re, sys
p, xf = sys.argv[1:3]
s = open(p).read()
BLOCK = re.compile(r'\tif _, ok := entrySignerPin\(e\); !ok \{\n.*?\n\t\}\n', re.S)
LOWER = 's := strings.ToLower(strings.TrimSpace(e.SigningCert))'
def once(a, b):
    if s.count(a) != 1:
        sys.exit(1)
    return s.replace(a, b)
if xf == 'delete':
    if len(BLOCK.findall(s)) != 1: sys.exit(1)
    s = BLOCK.sub('', s, count=1)
elif xf == 'move':
    m = BLOCK.search(s)
    if not m: sys.exit(1)
    blk = m.group(0)
    s = s.replace(blk, '', 1)
    s = once('\t// The manifest line the worker appends', blk + '\t// The manifest line the worker appends')
elif xf == 'nolen':
    s = once('if len(s) != 64 {', 'if false {')
elif xf == 'nohex':
    s = once("if (c < '0' || c > '9') && (c < 'a' || c > 'f') {", "if false && ((c < '0' || c > '9') && (c < 'a' || c > 'f')) {")
elif xf == 'nolower':
    s = once(LOWER, 's := strings.TrimSpace(e.SigningCert)')
else:
    sys.exit(1)
open(p, 'w').write(s)
PY
  res=$(go test -count=1 -run "$RUN_RE" -v . 2>&1)
  if [[ "$res" == *"[build failed]"* ]]; then
    echo "  BROKEN    $label -- the mutant did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      [[ "$res" == *"--- FAIL: $want"* ]] || miss="$miss $want"
    done
    if [ -z "$miss" ]; then echo "  convicted $label"
    else echo "  SURVIVED  $label -- not failed by:$miss"; fails=$((fails+1)); fi
  fi
  cp -f "$W/$CAT" "$CAT"
}
mut "N1 refusal deleted" delete TestFetchAppNoSigner_FdroidEntryRefused TestFetchAppNoSigner_MalformedCertsRefused
mut "N2 refusal moved after the download loop" move TestFetchAppNoSigner_FdroidEntryRefused TestFetchAppNoSigner_MalformedCertsRefused
mut "N3 length check dropped" nolen TestFetchAppNoSigner_MalformedCertsRefused TestEntrySignerPin
mut "N4 hex check dropped" nohex TestFetchAppNoSigner_MalformedCertsRefused TestEntrySignerPin
mut "N5 lower-casing dropped" nolower TestFetchAppNoSigner_UpperCaseCertPassesRefusal TestEntrySignerPin
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
