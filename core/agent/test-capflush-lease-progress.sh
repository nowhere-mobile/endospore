#!/usr/bin/env bash
# test-capflush-lease-progress.sh [--mutate] -- runs the TestCapFlushLeaseProgress tests in
# capflush_lease_progress_test.go (NWP-20261115-06): a flush whose refs need more than one lease batch writes a
# "sizes <done> <total>" line before each /lease request (the free batches, the entitled batch 0, each re-fold retry
# and each later entitled batch), so runWorkerHeld's stall rule sees the gateway leg; done advances per request, the
# phase is restored to "save" for the upload, and a flush that fits one batch writes no "sizes" line.
# NWP-20261117-10: while a /lease request is in flight, a heartbeat re-writes the line every leaseBeat as
# "sizes <d*m> <t*m>" (the line changes, the fraction does not; (1, 1) for a one-batch flush), and stops before the
# request's caller goes on; every /lease request with a line before it runs inside lprog.during.
# --mutate re-runs them against main.go and lease_progress.go with each rule broken in turn, restoring both files on
# exit (the pristine copies live in one scratch root, never beside the source). Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
. ./suite-report.sh
trap '[ -f "$W/main.go.orig" ] && cp -f "$W/main.go.orig" main.go; [ -f "$W/lease_progress.go.orig" ] && cp -f "$W/lease_progress.go.orig" lease_progress.go; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestCapFlushLeaseProgress' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp lease_progress.go "$W/lease_progress.go.orig"
fails=0
# mut <label> <file> <mode> <pattern> <arg>
#   mode sub:  replace the first match of pattern with arg; exactly one match must exist.
#   mode tail: in the text after the first `lprog.before()` line, remove every match of pattern; exactly arg must
#              be removed.
mut() {
  local label=$1 file=$2 res
  python3 - "$file" "$3" "$4" "$5" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,mode,pat,arg=sys.argv[1:5]
s=open(p).read()
if mode=='sub':
    n,c=re.subn(pat,lambda m: arg,s,count=1)
    if c!=1: sys.exit(1)
elif mode=='tail':
    i=s.find('lprog.before()\n')
    if i<0: sys.exit(1)
    i+=len('lprog.before()\n')
    t,c=re.subn(pat,'',s[i:])
    if c!=int(arg): sys.exit(1)
    n=s[:i]+t
else:
    sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $label"
  elif [[ "$res" == *'build failed'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp "$W/main.go.orig" main.go
  cp "$W/lease_progress.go.orig" lease_progress.go
}
mut "P1 no line before the free arm's requests" main.go sub \
  '\t+lprog\.before\(\)\n' ''
mut "P2 no line before the entitled arm's requests" main.go tail \
  '\t+lprog\.before\(\)\n' 4
mut "P3 done does not advance" lease_progress.go sub \
  '\t+p\.done\+\+\n' ''
mut "P4 the phase is not restored" lease_progress.go sub \
  'setProgPhase\(prev\)' '_ = prev'
mut "P5 the ON gate is dropped" lease_progress.go sub \
  'len\(leaseBatches\(refs, leaseBatchRefs\)\) > 1' 'true'
mut "H1 no heartbeat" lease_progress.go sub \
  '\t+stop := p\.heartbeat\(\)\n\t+defer stop\(\)\n' ''
mut "H2 the beat rewrites the same string" lease_progress.go sub \
  'writeProg\(d\*m, t\*m\)' 'writeProg(d, t)'
mut "H3 the beat changes the fraction" lease_progress.go sub \
  'writeProg\(d\*m, t\*m\)' 'writeProg(d*m, t*m+1)'
mut "H4 the heartbeat is not stopped after the reply" lease_progress.go sub \
  'defer stop\(\)' '_ = stop'
mut "H5 beats only when leaseProg is ON" lease_progress.go sub \
  'stop := p\.heartbeat\(\)' $'if !p.on {\n\t\treq()\n\t\treturn\n\t}\n\tstop := p.heartbeat()'
mut "H6 one entitled request is not wrapped" main.go sub \
  'lprog\.during\(func\(\) \{(?=\n\t+info, pcode, err = gw\.leaseEntitledExpire\(profile, plain, blind)' 'func(f func()) { f() }(func() {'
mut "H7 the beat does not restore the phase" lease_progress.go sub \
  'writeProg\(d\*m, t\*m\)\n\t+setProgPhase\(prev\)' $'writeProg(d*m, t*m)\n\t\t\t_ = prev'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
