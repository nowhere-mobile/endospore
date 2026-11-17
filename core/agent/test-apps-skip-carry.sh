#!/usr/bin/env bash
# test-apps-skip-carry.sh [--mutate] -- runs the #apps skip excuse cases (apps_skip_carry_test.go; NWP-20261207-08, h47
# #2): an #apps restore whose only skips lie inside kept packages removes those packages' cut sets, lists them and still
# earns its receipt, so the session's #apps seals carry them by hash instead of refusing. It also runs the carry's own
# cases (TestCarry*) and the restore-roster pin. --mutate re-runs them against main.go and media_server.go with one rule
# broken in turn, restoring both files on exit. Each mutant must be CONVICTED by a real `--- FAIL` of the test it names;
# one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'for f in main.go media_server.go; do if [ -f "$W/$f.orig" ]; then cp -f "$W/$f.orig" "$f"; fi; done; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run 'TestAppsSkips|TestUntarRecordsSkip|TestAppsRestoreSkip|TestSkippedAppCarried|TestRestoreCaseExcuses|TestCarry|TestMediaCarry_TheLoginRestoreWritesTheRoster' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp main.go "$W/main.go.orig"
cp media_server.go "$W/media_server.go.orig"
fails=0
mut() { # mut <label> <test that must fail> <file> <old> <new>: old and new are Python string literals; old must match once
  local label=$1 want=$2 file=$3 res mrc
  if ! python3 - "$file" "$4" "$5" <<'PY'
import ast, sys
p, old, new = sys.argv[1], ast.literal_eval(sys.argv[2]), ast.literal_eval(sys.argv[3])
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp -f "$W/$file.orig" "$file"; return; fi
  res=$("${RUN[@]}" 2>&1); mrc=$?
  if score_mutant "$label" "$mrc" "$res"; then
    if [[ "$res" != *"--- FAIL: $want "* ]]; then
      echo "    but not by $want"; fails=$((fails+1))
    fi
  else
    fails=$((fails+1))
  fi
  cp -f "$W/$file.orig" "$file"
}
mut "A1 the root-file rule dropped (TestAppsSkipsExcusable: manifest.tsv)" TestAppsSkipsExcusable media_server.go \
  '"if !hasSlash || !validPkgName(pkg) {"' '"if _ = hasSlash; !validPkgName(pkg) {"'
mut "A2 carryEssential() not required (TestAppsSkipsExcusable: the carry off)" TestAppsSkipsExcusable media_server.go \
  '"!carryEssential() || "' '""'
mut "A3 the mkdir-parent site records no name (TestUntarRecordsSkipNames)" TestUntarRecordsSkipNames main.go \
  '"\"mkdir parent\", err))\n\t\t\tskipped++\n\t\t\tnoteUntarSkip(filepath.ToSlash(hdr.Name))\n"' \
  '"\"mkdir parent\", err))\n\t\t\tskipped++\n"'
mut "A4 a link rejection records hdr.Name (TestUntarRecordsSkipNames)" TestUntarRecordsSkipNames main.go \
  '"hdr.Name, hdr.Linkname)\n\t\t\tskipped++\n\t\t\tnoteUntarSkip(\"\")\n"' \
  '"hdr.Name, hdr.Linkname)\n\t\t\tskipped++\n\t\t\tnoteUntarSkip(filepath.ToSlash(hdr.Name))\n"'
mut "A8 recording on without the reset (TestUntarRecordsSkipNames)" TestUntarRecordsSkipNames main.go \
  '"\tif untarSkip.on {\n"' '"\tif true {\n"'
mut "A5 excuseAppsSkips keeps the package dir (TestAppsRestoreSkipEarnsReceipt)" TestAppsRestoreSkipEarnsReceipt media_server.go \
  '"os.RemoveAll(filepath.Join(dest, p))"' '"os.RemoveAll(filepath.Join(dest, p, \"absent\"))"'
mut "A6 the restore case's excuse call removed (TestRestoreCaseExcusesBeforeFinish)" TestRestoreCaseExcusesBeforeFinish main.go \
  '"\t\tskipped = excuseAppsSkips(profile, dest, skipped)\n"' '""'
mut "A7 the push count line removed (TestSkippedAppCarriedNotRefused)" TestSkippedAppCarriedNotRefused main.go \
  '"\t\t\t\tfmt.Printf(\"push: profile %s %d carried package(s) were not restored at this sign-in: kept from the last save (h47 #2)\\n\", logProfile(profile), n)\n"' \
  '"\t\t\t\t_ = n\n"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
