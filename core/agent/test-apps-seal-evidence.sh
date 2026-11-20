#!/usr/bin/env bash
# test-apps-seal-evidence.sh [--mutate] -- runs apps_seal_evidence_test.go (NWP-20261208-01, backlog: "P1: On-demand apps
# that are not on the phone at a sign-out are dropped from the `#apps` code list, ..."): an #apps seal records its carry
# counts in the state dir under a hash of the scope's store ref, and the next #apps restore of the same profile moves
# them, with the restored head's app-index count, into that sign-in's summary file, which a session issue report reads
# as signin_apps_index_pkgs and lastseal_apps_* keys. --mutate breaks apps_seal_evidence.go / main.go /
# signin_summary.go one part at a time and restores all three on exit. Each mutant must be CONVICTED by the named
# test's `--- FAIL`; one that fails to apply, or to compile, is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
EV=apps_seal_evidence.go
MAIN=main.go
SUM=signin_summary.go
trap 'for f in "$EV" "$MAIN" "$SUM"; do [ -f "$W/$f.orig" ] && cp -f "$W/$f.orig" "$f"; done; rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" || exit 2
export TMPDIR="$W" GOTMPDIR="$W/gotmp"
RUN=(go test -count=1 -timeout 600s -run 'TestAppsSealRoundTrip|TestAppsSealOtherProfile|TestAppsSealOverIndexlessHead|TestAppsSealGuardRefused|TestAppsSealStaleRemoved|TestAppsSealRestoreAppends|TestSigninSummaryAppsKeys' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$EV" "$W/$EV.orig"; cp "$MAIN" "$W/$MAIN.orig"; cp "$SUM" "$W/$SUM.orig"
fails=0
# mut <label> <file> <python-regex> <replacement> <convicting test>...
mut() {
  local label="$1" file="$2" pat="$3" rep="$4" res want
  shift 4
  python3 - "$file" "$pat" "$rep" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  cp -f "$W/$EV.orig" "$EV"; cp -f "$W/$MAIN.orig" "$MAIN"; cp -f "$W/$SUM.orig" "$SUM"
}
mut "G1 the presence guard's write deleted" "$MAIN" '(appsEv\.guard = "refused"\n\t+\}\n)\t+writeAppsSeal\(os\.Getenv\("NOWHERE_STATE"\), profile, pass, appsEv\)\n' '\1' TestAppsSealGuardRefused
mut "G2 adopted taken as 0" "$MAIN" 'appsEv\.adopted = len\(ad\)' 'appsEv.adopted = 0' TestAppsSealOverIndexlessHead
mut "G3 the file name hashed from the profile without the passphrase" "$EV" 'sha256\.Sum256\(\[\]byte\(profileRefV2\(profile, pass\)\)\)' 'sha256.Sum256([]byte(profile))' TestAppsSealOtherProfile
mut "G4 take does not remove the record" "$EV" '(_ = f\.Close\(\)\n)\t_ = os\.Remove\(p\)\n' '\1' TestAppsSealRoundTrip
mut "G5 the stale record's removal deleted" "$MAIN" 'removeAppsSeal\(os\.Getenv\("NOWHERE_STATE"\), profile, pass\)' '_ = pass' TestAppsSealStaleRemoved
mut "G6 the restore append's phase check dropped" "$EV" '\tif os\.Getenv\("NOWHERE_PHASE"\) != "appcode" \{\n\t\treturn\n\t\}\n' '' TestAppsSealRestoreAppends
mut "G7 the appsseal regex loses its \$ anchor" "$SUM" 'guard=\(none\|passed\|refused\)\$' 'guard=(none|passed|refused)' TestSigninSummaryAppsKeys
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
