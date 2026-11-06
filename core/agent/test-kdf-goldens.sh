#!/usr/bin/env bash
# test-kdf-goldens.sh [--mutate] -- runs kdf_golden_test.go (NWP-20261104-04); --mutate applies each mutant as a literal
# in-place replacement (it must match exactly once) and requires a real `--- FAIL`; an inert or non-compiling mutant is
# a failure. Every edited file is restored on exit; everything temporary lives under one root.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
export TMPDIR="$W" GOTMPDIR="$W"
restore() {
  local f
  for f in main.go ../vendor-common/bin/nowhere_otad.sh; do
    [ -f "$W/$(basename "$f").orig" ] && cp -f "$W/$(basename "$f").orig" "$f"
  done
  rm -rf "$W"
}
trap restore EXIT
RUN=(go test -count=1 -run 'TestKDFGoldens' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp ../vendor-common/bin/nowhere_otad.sh "$W/nowhere_otad.sh.orig"
fails=0
mut() { # mut <label> <file> <old> <new>
  local label="$1" f="$2" res rc
  python3 - "$f" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply exactly once"; fails=$((fails+1)); return; }
import sys
p,old,new=sys.argv[1:4]
s=open(p).read()
if s.count(old)!=1: sys.exit(1)
open(p,'w').write(s.replace(old,new))
PY
  res=$("${RUN[@]}" 2>&1); rc=$?
  if [ $rc -ne 0 ] && grep -q -- '--- FAIL' <<<"$res"; then echo "  convicted $label"; else echo "  SURVIVED  $label (rc=$rc, no --- FAIL)"; fails=$((fails+1)); fi
  cp -f "$W/$(basename "$f").orig" "$f"
}
mut "K1 argon2 time cost"         main.go 'argon2.IDKey([]byte(secret), salt[:], 1,' 'argon2.IDKey([]byte(secret), salt[:], 2,'
mut "K2 profile salt label"       main.go '"nowhere-salt:" + name' '"nowhere-salt" + name'
mut "K3 v2 HMAC label"            main.go '"nowhere-ref-v2"' '"nowhere-ref-v3"'
mut "K4 legacy separator"         main.go '"nowhere-ref:" + name + "\x00"' '"nowhere-ref:" + name + ":"'
mut "K5 recovery salt label"      main.go '"nowhere-recovery-salt:"' '"nowhere-recovery-salt"'
mut "K6 scope list loses #wallet" main.go '"#keys", "#wallet"}' '"#keys"}'
mut "K7 otad OSPASS"              ../vendor-common/bin/nowhere_otad.sh 'OSPASS=nowhere-os' 'OSPASS=nowhere-os2'
mut "K8 recovery ref label"       main.go '"nowhere-recovery-ref:"' '"nowhere-recovery-ref"'
[ $fails -eq 0 ] || { echo "$fails mutant(s) not convicted"; exit 1; }
echo "all mutants convicted"
