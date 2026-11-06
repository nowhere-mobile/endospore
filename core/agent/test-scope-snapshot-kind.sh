#!/usr/bin/env bash
# test-scope-snapshot-kind.sh [--mutate] -- a manual save ("Back up now") pins no #media or #apps snapshot, while the
# bare vault and the other scopes keep their manual pins (Q141, NWP-20261103-07). Plain: the ScopeSnapshotKind tests plus
# the Snapshot tests. --mutate applies each mutant to main.go in place (a pristine copy lives in one temp root, restored
# after every mutant and on exit) and runs the ScopeSnapshotKind tests; each must be CONVICTED by the named `--- FAIL`.
# A mutant that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
FILES=(main.go)
restore() { local f; for f in "${FILES[@]}"; do [ -f "$W/$f" ] && cp -f "$W/$f" "$f"; done; return 0; }
trap 'restore; rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$(go test -count=1 -run 'ScopeSnapshotKind|Snapshot' . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

for f in "${FILES[@]}"; do cp "$f" "$W/$f"; done
fails=0
# mut <label> <file> <mutator> <convicting test>... -- <mutator> is a python3 program run with the file's text in `s`,
# leaving the mutated text in `s`; it exits 1 when its anchor is not found exactly once.
mut() {
  local label="$1" file="$2" prog="$3" res want
  shift 3
  python3 -c "
import sys
p = sys.argv[1]
s = open(p).read()
$prog
open(p, 'w').write(s)
" "$file" || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); restore; return; }
  res=$(go test -count=1 -run 'ScopeSnapshotKind' . 2>&1)
  if [[ "$res" == *'[build failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
  else
    for want in "$@"; do
      if [[ "$res" == *"--- FAIL: $want"* ]]; then echo "  convicted $label by $want"
      else echo "  SURVIVED  $label -- no --- FAIL: $want"; fails=$((fails+1)); fi
    done
  fi
  restore
}
# K1: a #apps head still takes sealKind() as its kind.
K1='
old = "\t\toutgoing, kind = \"\", \"\"\n"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "\t\toutgoing = \"\"\n")
'
# K2: manual entries a scope vault already holds are not demoted.
K2='
old = "\t\t\tv.History = demoteManualSnaps(v.History)\n"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "")
'
# K3: #media is treated as keeping manual pins.
K3='
old = "!isSharedMediaScope(profile) && !strings.HasSuffix(profile, \"#apps\")"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "!strings.HasSuffix(profile, \"#apps\")")
'
# K4: the bare vault loses its pin.
K4='
old = "\treturn !isSharedMediaScope(profile) && !strings.HasSuffix(profile, \"#apps\")\n"
if s.count(old) != 1:
    sys.exit(1)
s = s.replace(old, "\treturn strings.Contains(profile, \"#\") && !isSharedMediaScope(profile) && !strings.HasSuffix(profile, \"#apps\")\n")
'
mut "K1 #apps head keeps sealKind() as its kind" main.go "$K1" TestScopeSnapshotKind_AppsManualSaveIsNotPinned
mut "K2 existing manual entries are not demoted" main.go "$K2" TestScopeSnapshotKind_AppsManualSaveIsNotPinned
mut "K3 #media keeps manual pins" main.go "$K3" TestScopeSnapshotKind_MediaManualSaveIsNotPinned TestScopeSnapshotKind_Helper
mut "K4 the bare vault loses its pin" main.go "$K4" TestScopeSnapshotKind_BareVaultKeepsItsManualPin
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
