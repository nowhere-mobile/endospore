#!/usr/bin/env bash
# test-keyed-resume-preproof.sh [--mutate] -- runs cold_resume_preproof_test.go (NWP-20261017-03): a keyed cold-lock
# resume hands nothing of the typed entry to the worker, the store or the KDF cache before coldResumeProof, and the
# marker's slot spec it relies on is kept in step by every enrol and removal. --mutate re-runs it against main.go /
# fido2.go / fido2_nfc_verb.go with each guard removed in turn, restoring the files on exit. Each mutant must be
# CONVICTED by a `--- FAIL` line (a mutant that fails to apply or to compile is a failure, never a pass).
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; FIDO=fido2.go; VERB=fido2_nfc_verb.go
RUN=(go test -count=1 -run 'TestKeyedResume|TestNFCResumeWithout|TestEnrolAndRemoveKeep|TestSyncFido2SlotsStash' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"; cp "$FIDO" "$FIDO.orig"; cp "$VERB" "$VERB.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"; mv -f "$FIDO.orig" "$FIDO"; mv -f "$VERB.orig" "$VERB"' EXIT
fails=0
mut() { # mut <label> <file> <python regex> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  mout=$("${RUN[@]}" 2>&1) || true
  case "$mout" in
    *"--- FAIL"*) echo "  convicted $1" ;;
    *) echo "  SURVIVED  $1 (no --- FAIL line; a compile error does not count)"; fails=$((fails+1)) ;;
  esac
  cp "$MAIN.orig" "$MAIN"; cp "$FIDO.orig" "$FIDO"; cp "$VERB.orig" "$VERB"
}
mut "M1 the typed entry goes to the worker again" "$MAIN" '"fido2hmac", name, resumeMarkerOnlyPass,' '"fido2hmac", name, entry,'
mut "M2 the empty-spec refusal removed" "$MAIN" 'if len\(parseSlotSpec\(coldLockSlots\(dest\)\)\) == 0 \{\n(\t+)refuse\("keyed marker' 'if false {\n\1refuse("keyed marker'
mut "M3 the NFC-resume store lookup restored" "$VERB" '(\t\tslots = parseSlotSpec\(coldLockSlots\(dest\)\)\n)(\t\tif len\(slots\) == 0 \{\n\t\t\tfmt\.Fprintf\(os\.Stderr, "\[logind\] nfc-resume)' '\1\t\tfunc() {\n\t\t\tdefer func() { recover() }()\n\t\t\tif v, isV := parseVault(getHeadBlob(base, getRef(base, headKey(base, nm, ps)))); isV {\n\t\t\t\tslots = listFido2Slots(v)\n\t\t\t}\n\t\t}()\n\2'
mut "M4 an enrol or removal no longer writes the spec" "$FIDO" 'syncFido2SlotsStash\(stashDir, final\)' 'func() error { _ = final; return nil }()'
mut "M5 the last removal leaves the spec behind" "$FIDO" '\tif len\(slots\) == 0 \{\n\t\tif err := os\.Remove\(p\)' '\tif len(slots) == 0 {\n\t\treturn nil\n\t\tif err := os.Remove(p)'
mut "M6 a failed spec write is swallowed (RF-001)" "$FIDO" 'return fmt\.Errorf\("cold-resume slot spec not saved: %w", err\)' 'return nil'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
