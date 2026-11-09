#!/usr/bin/env bash
# test-telingest-sim-slot.sh [--mutate] -- runs telingest_simslot_test.go (NWP-20261130-01): every SMS and MMS row
# carries its SIM's tag in its own slot, a call row and an untagged row stay as they were, and a sealed copy goes only
# when an acknowledgement names its row. --mutate breaks each part in turn, restoring every file on exit. Each mutant
# must be CONVICTED by the named test's `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
ING=telephony_ingest.go
PEND=telephony_pending.go
TAG=simtag.go
RUN=(go test -count=1 -run '^(TestSimSlot|TestUntaggedRowParsesAsBefore|TestCallRowUnchangedBySlot|TestRestageKeepsTaggedSmsOnItsSim|TestOlderChooserRestageStaysOnItsSim|TestSimTagGoldenVector|TestUnacknowledgedRowStaysPending)' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

W=$(mktemp -d) || exit 2
cp "$ING" "$W/ing.orig"
cp "$PEND" "$W/pend.orig"
cp "$TAG" "$W/tag.orig"
trap 'cp -f "$W/ing.orig" "$ING" 2>/dev/null; cp -f "$W/pend.orig" "$PEND" 2>/dev/null; cp -f "$W/tag.orig" "$TAG" 2>/dev/null; rm -rf "$W"' EXIT
fails=0
restore() { cp "$W/ing.orig" "$ING"; cp "$W/pend.orig" "$PEND"; cp "$W/tag.orig" "$TAG"; }
# conv <label> <expected failing test>: run the suite against the mutated tree, then restore it.
conv() {
  local res
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $1 -- did not compile"; fails=$((fails+1))
  elif [[ "$res" == *"--- FAIL: $2"* ]]; then echo "  convicted $1"
  else echo "  SURVIVED  $1"; fails=$((fails+1)); fi
  restore
}
inert() { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); restore; }
mut() { # mut <label> <expected failing test> <file> <python-regex pattern> <replacement>
  python3 - "$3" "$4" "$5" <<'PY' || { inert "$1"; return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p,encoding='utf-8').read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w',encoding='utf-8').write(n)
PY
  conv "$1" "$2"
}
mut "m1 an sms row drops the slot" TestSimSlotRoundTrips "$ING" \
  'sb\.WriteString\(b64tok\(it\.Body\)\)\n\t+sb\.WriteString\(simSlot\(tag\)\)' 'sb.WriteString(b64tok(it.Body))'
mut "m2 an mms row drops the slot" TestSimSlotRoundTrips "$ING" \
  'EncodeToString\(j\)\)\n\t+sb\.WriteString\(simSlot\(tag\)\)' 'EncodeToString(j))'
mut "m3 a call row gets the slot" TestCallRowUnchangedBySlot "$ING" \
  'sb\.WriteString\(tag\)\n\t+\}' 'sb.WriteString(tag)\n\t\t\t\tsb.WriteString(simSlot(tag))\n\t\t\t}'
mut "m4 rowTag takes the sms slot anywhere" TestSimSlotOnlyAtItsPosition "$ING" \
  'case len\(f\) >= 7 && f\[0\] == "sms" && strings\.HasPrefix\(f\[6\], simSlotPrefix\):\n\t+t = f\[6\]\[len\(simSlotPrefix\):\]' \
  'case len(f) >= 6 && f[0] == "sms" && strings.HasPrefix(f[len(f)-1], simSlotPrefix):\n\t\tt = f[len(f)-1][len(simSlotPrefix):]'
mut "m5 rowTag takes the mms slot anywhere" TestSimSlotOnlyAtItsPosition "$ING" \
  'case len\(f\) >= 4 && f\[0\] == "mms" && strings\.HasPrefix\(f\[3\], simSlotPrefix\):\n\t+t = f\[3\]\[len\(simSlotPrefix\):\]' \
  'case len(f) >= 3 && f[0] == "mms" && strings.HasPrefix(f[len(f)-1], simSlotPrefix):\n\t\tt = f[len(f)-1][len(simSlotPrefix):]'
mut "m6 an empty tag writes a slot" TestUntaggedRowParsesAsBefore "$ING" \
  'if !isSimTag\(tag\) \{\n\t+return ""\n\t+\}\n\t+return " " \+ simSlotPrefix' 'return " " + simSlotPrefix'
mut "m7 a re-staged tagged row loses its SIM" TestRestageKeepsTaggedSmsOnItsSim "$ING" \
  'case len\(f\) >= 7 && f\[0\] == "sms" && strings\.HasPrefix\(f\[6\], simSlotPrefix\):\n\t+t = f\[6\]\[len\(simSlotPrefix\):\]' \
  'case len(f) >= 7 && f[0] == "sms" && strings.HasPrefix(f[6], simSlotPrefix) && len(f) == 7:\n\t\tt = f[6][len(simSlotPrefix):]'
mut "m8 the claim does not record a tagged sms row's SIM" TestOlderChooserRestageStaysOnItsSim "$ING" \
  'if strings\.HasPrefix\(line, "call "\) && rowTag\(line\) != "" \{' 'if rowTag(line) != "" {'
mut "m9 the tag hash changes" TestSimTagGoldenVector "$TAG" \
  '"nowhere-sim\|" \+ normICCID\(iccid\)' '"nowhere-sim|" + iccid'
mut "m10 an ack releases every pending copy" TestUnacknowledgedRowStaysPending "$PEND" \
  'if m == nil \|\| m\[3\] != uid \|\| !want\[m\[4\]\] \{' 'if m == nil || m[3] != uid {'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
