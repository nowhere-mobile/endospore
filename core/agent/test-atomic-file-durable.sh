#!/usr/bin/env bash
# test-atomic-file-durable.sh [--mutate] -- runs the four TestWriteAtomicFile cases in atomic_file_durable_test.go
# (NWP-20261126-19): writeAtomicFile publishes the device flags, the sync interval and the signed catalog and index
# through the synced writeConfDurable. --mutate re-runs them against a PACKAGE COPY per mutant: (M1) writeAtomicFile
# restored to the old WriteFile + Rename body; (M2) writeConfDurable ignores a failed sync; (M3) writeConfDurable keeps
# the temp file on a failure before the rename. Each mutant must be CONVICTED by a `--- FAIL` from a TestWriteAtomicFile
# test; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
RUN=(go test -count=1 -run '^TestWriteAtomicFile' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <old> <new> -- byte-exact; old must occur exactly once in file
  local label=$1 file=$2 d res rc
  d=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -R ./*.go go.mod go.sum blindrsa testdata third_party "$d"/
  if ! python3 - "$d/$file" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, 'w').write(s.replace(old, new, 1))
PY
  then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$d"; return; fi
  res=$(cd "$d" && "${RUN[@]}" 2>&1); rc=$?
  if score_mutant "$label" "$rc" "$res"; then
    if [[ "$res" != *'--- FAIL: TestWriteAtomicFile'* ]]; then
      echo "  NOT CONVICTED by a TestWriteAtomicFile test: $label"; fails=$((fails+1))
    fi
  else
    fails=$((fails+1))
  fi
  rm -rf "$d"
}
mut "M1 writeAtomicFile restored to WriteFile + Rename with no sync" catalog.go \
  $'\treturn writeConfDurable(path, b)\n}' \
  $'\ttmp := path + ".tmp"\n\tif err := os.WriteFile(tmp, b, 0o600); err != nil {\n\t\treturn err\n\t}\n\treturn os.Rename(tmp, path)\n}'
mut "M2 writeConfDurable ignores a failed sync (renames and returns nil)" main.go \
  $'\tserr := confFileSync(fh)\n' \
  $'\t_ = confFileSync(fh)\n\tvar serr error\n'
mut "M3 writeConfDurable keeps the temp file on a failure before the rename" main.go \
  $'\tif err := errors.Join(werr, serr, cerr); err != nil {\n\t\tos.Remove(tmp)\n\t\treturn err\n\t}\n' \
  $'\tif err := errors.Join(werr, serr, cerr); err != nil {\n\t\treturn err\n\t}\n'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
