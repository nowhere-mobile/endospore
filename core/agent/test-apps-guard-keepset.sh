#!/usr/bin/env bash
# test-apps-guard-keepset.sh [--mutate] -- the #apps presence guard under a deliberate shrink-intent marker excuses
# only a package the live keep-set no longer names (NWP-20261029-01). Plain: the focused set. --mutate copies the
# package into the temp root for every mutant, applies the mutant to THAT copy and runs the same focused set there;
# each must be CONVICTED by the named `--- FAIL`. The working tree is never edited. A mutant that fails to apply or
# to compile counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
FOCUS='AppsGuardKeepset|AppsSeal|PresenceGuard|AppsEmptyStage|InferredIntent|PushGuard_AppsVanished|DropList'
SRC=$PWD

out=$(go test -count=1 -run "$FOCUS" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
# mut <label> <file> <old-literal> <new-literal> <convicting test>...
mut() {
  local label="$1" file="$2" old="$3" new="$4" res want d
  shift 4
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R "$SRC/." "$d/"
  python3 - "$d/$file" "$old" "$new" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  res=$(cd "$d" && go test -count=1 -run "$FOCUS" . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  rm -rf "$d"
}
P=TestAppsGuardKeepset_
mut "M1 every deliberate marker excuses the whole scope" apps_guard_keepset.go $'\t_, still := kept[p]\n\treturn !still' $'\treturn true' "${P}K1StillKeptPackageIsRefusedUnderADeliberateMarker" "${P}K6DropListCannotLaunderAKeptPackage"
mut "M2 an unreadable keep list excuses all" apps_guard_keepset.go $'\tif !keptOK {\n\t\treturn false\n\t}' $'\tif !keptOK {\n\t\treturn true\n\t}' "${P}K4UnreadableKeepSetExcusesNothing"
mut "M3 the keep list is read but never consulted" apps_guard_keepset.go 'return parseKeepModes(kb), true' $'_ = kb\n\treturn map[string]string{}, true' "${P}K1StillKeptPackageIsRefusedUnderADeliberateMarker" "${P}K6DropListCannotLaunderAKeptPackage"
mut "M4 the rule also binds an inferred marker" main.go 'case have[p], appsVanishedExcused(p, declaredOff, deliberate, kept, keptOK):' $'case have[p], appsVanishedExcused(p, map[string]bool{}, true, func() map[string]string { _, _ = kept, keptOK; k, _ := readAppsKeepSet(); return k }(), true):' "${P}KInferredMarkerStillExcusesWhatItNamed"
mut "M5 a keep list set to an empty path counts as unset" apps_guard_keepset.go $'kp, present := os.LookupEnv("NOWHERE_KEEP_LIST")\n\tif !present {' $'kp := os.Getenv("NOWHERE_KEEP_LIST")\n\tif kp == "" {' "${P}K5bEmptyKeepListPathExcusesNothing"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
