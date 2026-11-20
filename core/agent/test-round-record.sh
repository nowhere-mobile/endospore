#!/usr/bin/env bash
# test-round-record.sh [--mutate] -- the seal round record (NWP-20261204-01, h58 #1 in docs/product-decisions.md,
# 2026-11-04). A seal round that leaves a scope unsaved records its parts in the bare vault's scope index (!round),
# the next bare seal that lands clears it, and a bare restore says so in roam.log and leaves $STATE/lastsave.<uid>,
# which the login daemon logs to login.log.
#
# Plain: round_record_test.go; roamd's round_record helper under every shell found (bash, sh, dash, mksh) with a stub
# agent; source pins on roamd's out op (one call, after appcode_seal, guarded by stopped=0 and non-empty parts) and
# its in arm (the rm and the NOWHERE_LASTSAVE_OUT export). --mutate breaks COPIES of scope_index.go, main.go and
# nowhere_roamd.sh eleven ways (R1-R11) under a temp root; the checked-out tree is never touched. Each mutant must be
# CONVICTED: a Go mutant by a `--- FAIL` (one that fails to apply or to compile counts as a failure), a roamd mutant
# by the pin that names it.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
ROAMD=../vendor-common/bin/nowhere_roamd.sh
RUN=(go test -count=1 -run 'RoundRecord|LastSave' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

HELPER=$(sed -n '/^round_record() {$/,/^}$/p' "$ROAMD")
[ -n "$HELPER" ] || { echo "EXTRACTION FAILED: round_record() not found in $ROAMD" >&2; exit 2; }

# The stub agent records its argv and exits with $STUB_RC.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$STUB_ARGV"\nexit "$STUB_RC"\n' > "$W/agent-stub"
chmod 700 "$W/agent-stub"

fails=0
say() { if [ "$1" = 0 ]; then printf '  ok    %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi; }

# helper_case <shell> <stub rc>: runs round_record n p de=failed; asserts the argv, the log line and rc 0.
helper_case() {
  local sh="$1" src="$2" d argv log hrc
  d=$(mktemp -d -p "$W")
  { printf 'AGENT=%s; LOG=%s/log\n' "$W/agent-stub" "$d"
    printf 'pw() { echo "@file:x"; }\n'
    printf 'pwv() { :; }\n'   # NWP-20261205-18: the call stages the chip secret and the key hmac through pwv
    printf '%s\n' "$HELPER"
    printf 'round_record n p de=failed; echo "$?" > %s/hrc\n' "$d"
  } > "$d/run.sh"
  STUB_ARGV="$d/argv" STUB_RC="$src" "$sh" "$d/run.sh" > /dev/null 2>&1
  argv=$(cat "$d/argv" 2>/dev/null); log=$(cat "$d/log" 2>/dev/null); hrc=$(cat "$d/hrc" 2>/dev/null)
  [ "$argv" = "round-record s3 n @file:x de=failed" ]
  say $? "$sh: agent rc $src: argv is round-record s3 <name> <pw file> <parts> [$argv]"
  case "$log" in *"[roamd] OUT round record: rc=$src (h58 #1) "*) say 0 "$sh: agent rc $src: the log line carries rc=$src" ;;
    *) say 1 "$sh: agent rc $src: the log line is missing: [$log]" ;; esac
  [ "$hrc" = 0 ]
  say $? "$sh: agent rc $src: round_record returns 0 [$hrc]"
}
for s in $SHELLS; do
  helper_case "$s" 0
  helper_case "$s" 1
done

# pins <roamd file>: prints one ok/FAIL line per pin; returns the number of failed pins.
pins() {
  local f="$1" arm inarm n bad=0 call guard ap st
  arm=$(awk '$0 == "  out)" {f=1} f{print} f&&$0=="    ;;"{exit}' "$f")
  inarm=$(awk '$0 == "  in)" {f=1} f{print} f&&$0=="    ;;"{exit}' "$f")
  call='      round_record "$name" "$pass" "$parts"'
  guard='    if [ "$stopped" = 0 ] && [ -n "$parts" ]; then'
  n=$(printf '%s\n' "$arm" | grep -cxF -- "$call")
  if [ "$n" = 1 ]; then echo "  ok    R9 pin: one round_record call in the out op"; else echo "  FAIL  R9 pin: $n round_record call(s) in the out op, want 1"; bad=$((bad+1)); fi
  # The call's guard is the line right above it, and both sit between appcode_seal and the stopped verdict.
  ap=$(printf '%s\n' "$arm" | grep -nxF -- '      appcode_seal; _ar=$?' | cut -d: -f1)
  st=$(printf '%s\n' "$arm" | grep -nxF -- '    if [ "$stopped" = 1 ]; then' | cut -d: -f1)
  n=$(printf '%s\n' "$arm" | grep -nxF -- "$call" | cut -d: -f1)
  if [ -n "$ap" ] && [ -n "$st" ] && [ -n "$n" ] && [ "$ap" -lt "$n" ] && [ "$n" -lt "$st" ] \
     && [ "$(printf '%s\n' "$arm" | sed -n "$((n-1))p")" = "$guard" ]; then
    echo "  ok    R10 pin: the call is guarded by stopped=0 and non-empty parts, after appcode_seal, before the verdict"
  else
    echo "  FAIL  R10 pin: the call is not right under [$guard] between appcode_seal and the verdict"; bad=$((bad+1))
  fi
  n=$(printf '%s\n' "$inarm" | grep -cxF -- '      export NOWHERE_LASTSAVE_OUT="$STATE/lastsave.$uid" ;; esac')
  if [ "$n" = 1 ]; then echo "  ok    R11 pin: the in arm exports NOWHERE_LASTSAVE_OUT"; else echo "  FAIL  R11 pin: the in arm exports NOWHERE_LASTSAVE_OUT $n time(s), want 1"; bad=$((bad+1)); fi
  case "$inarm" in *'rm -f "$STATE/lastsave.$uid" 2>/dev/null'*)
    echo "  ok    the in arm removes a recycled uid's lastsave note" ;;
    *) echo "  FAIL  the in arm does not remove a recycled uid's lastsave note"; bad=$((bad+1)) ;; esac
  return "$bad"
}
pout=$(pins "$ROAMD"); prc=$?
printf '%s\n' "$pout"
fails=$((fails+prc))
if [ "$fails" -ne 0 ]; then echo "== $fails check(s) FAILED"; exit 1; fi
echo "== round_record under$SHELLS and the roamd pins: all passed"
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
mfails=0
mut() { # mut <label> <file in the copy> <python-regex pattern> <replacement>
  local res rc f
  for f in main.go scope_index.go; do cp -f "$f" "$W/agent/$f"; done
  python3 - "$W/agent/$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; mfails=$((mfails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || mfails=$((mfails+1))
}
# rmut <label> <pin that must convict> <python-regex pattern> <replacement>: on a copy of roamd.
rmut() {
  local res f="$W/roamd.sh"
  cp -f "$ROAMD" "$f"
  python3 - "$f" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; mfails=$((mfails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.M)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(pins "$f")
  case "$res" in *"FAIL  $2 pin:"*) echo "  convicted $1 (by the $2 pin)" ;;
    *) echo "  SURVIVED  $1"; printf '%s\n' "$res"; mfails=$((mfails+1)) ;; esac
}
mut "R1 isScopeSuffix drops the !round exclusion (TestRoundRecordRecShapeRoundTrips)" scope_index.go \
  ' && k != scopeRoundKey &&\n' ' &&\n'
mut "R2 the bare seal no longer deletes !round (TestRoundRecordClearedByABareSealNotByAScopeSeal)" main.go \
  'if _, had := idx\[scopeRoundKey\]; had \{' 'if _, had := idx[scopeRoundKey]; false && had {'
mut "R3 roundRecord records the benign part too (TestRoundRecordWritesTheRealPartsOnly)" main.go \
  'p := sealPartsOf\(" PARTIAL:" \+ parts\)\n(\tif p == "" \{\n\t\treturn nil\n\t\}\n\tif !roundPartsOK)' 'p := strings.TrimSpace(parts)\n\1'
mut "R4 roundRecord does not stop when nothing is left (TestRoundRecordBenignOnlyWritesNothing: the call must return nil)" main.go \
  '(p := sealPartsOf\(" PARTIAL:" \+ parts\)\n)\tif p == "" \{\n\t\treturn nil\n\t\}\n(\tif !roundPartsOK)' '\1\2'
mut "R5 roundRecord writes the head ref without putHead's receipt re-anchor (TestRoundRecordKeepsTheReceiptAnchored)" main.go \
  '(idx\[scopeRoundKey\] = roundRec\(time\.Now\(\)\.Unix\(\), p\)\n.*?)putHead\(base, name, pass, vh\)' '\1putRef(base, headKey(base, name, pass), vh)'
mut "R6 roundOf accepts any scope word (TestRoundRecordRecShapeRoundTrips: an unknown scope)" scope_index.go \
  '!found \|\| !roundScopes\[sc\] \|\|' '!found ||'
mut "R7 the restore never writes the last-save note (TestRoundRecordRestoreSaysSo)" main.go \
  'if err := os\.WriteFile\(out, (\[\]byte\(fmt\.Sprintf\("v=1 unsaved=%s t=%d\\n", parts, t\)\)), 0o600\); err != nil \{' 'if _, err := out, \1; err != nil {'
mut "R8 handleRoamIn no longer logs the note (TestLastSaveLoggedAtSignIn)" main.go \
  '\t\tif parts := lastSaveLine\(loginStateDir\(\), uid\); parts != "" \{\n[^\n]*\n\t\t\}\n' ''
rmut "R9 the out op's round_record call removed" R9 '^      round_record "\$name" "\$pass" "\$parts"\n' ''
rmut "R10 the stopped guard removed" R10 '^    if \[ "\$stopped" = 0 \] && \[ -n "\$parts" \]; then\n(      round_record )' '    if [ -n "$parts" ]; then\n\1'
rmut "R11 the in arm's NOWHERE_LASTSAVE_OUT export removed" R11 '^      export NOWHERE_LASTSAVE_OUT="\$STATE/lastsave\.\$uid" ;; esac$' '      ;; esac'
[ "$mfails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $mfails mutation(s) not convicted"; exit 1; }
