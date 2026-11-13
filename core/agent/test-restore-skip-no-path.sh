#!/usr/bin/env bash
# test-restore-skip-no-path.sh [--mutate] -- NWP-20261201-24 (h60 #9): untarFrom's `[restore] skip` lines carry a package
# or scope word and an error CODE, never a path. Runs the focused Go tests; --mutate applies each mutant to pristine
# copies of restore_skip_line.go and main.go (swapped in for the run, restored on exit) and requires a real `--- FAIL`:
# a mutant that does not apply, or that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp restore_skip_line.go "$W/restore_skip_line.go.orig" || exit 2
cp main.go "$W/main.go.orig" || exit 2
trap 'cp "$W/restore_skip_line.go.orig" restore_skip_line.go; cp "$W/main.go.orig" main.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="RestoreSkip|UntarSkipLine|ErrLineSourcePins"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <old> <new> <convicting test>: replace the first <old> in a pristine copy, require that test's --- FAIL
mutate() {
  local lbl="$1" file="$2" old="$3" new="$4" want="$5" res
  cp "$W/restore_skip_line.go.orig" restore_skip_line.go
  cp "$W/main.go.orig" main.go
  if ! FILE="$file" OLD="$old" NEW="$new" python3 -c "
import os
f = os.environ['FILE']
s = open(f).read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return
  fi
  res=$(go test -count=1 -run "$RUN" . 2>&1)
  if grep -q -- "--- FAIL: $want" <<<"$res"; then echo "  convicted $lbl (by $want)"
  elif grep -q -- '--- FAIL' <<<"$res"; then
    echo "  WRONG     $lbl -- failed, but not in $want"; FAILS=$((FAILS+1))
  elif grep -q -E 'build failed|\[build failed\]|cannot|undefined|declared and not used' <<<"$res"; then
    echo "  BROKEN    $lbl -- the mutant did not compile"; FAILS=$((FAILS+1))
  else echo "  SURVIVED  $lbl"; FAILS=$((FAILS+1)); fi
}
H=restore_skip_line.go
mutate "R1 the helper prints the quoted name, not the subject" "$H" \
  'code := errCode(err)' $'code := errCode(err)\n\tsubject = fmt.Sprintf("%q", name)' TestRestoreSkipLineSubject
mutate "R1b the same mutant, through untarFrom" "$H" \
  'code := errCode(err)' $'code := errCode(err)\n\tsubject = fmt.Sprintf("%q", name)' TestRestoreSkipLinesCarryNoPath
mutate "R2 the helper prints err.Error(), not the code" "$H" \
  'code := errCode(err)' 'code := err.Error()' TestRestoreSkipLinesCarryNoPath
mutate "R2b the same mutant, against the source pin" "$H" \
  'code := errCode(err)' 'code := err.Error()' TestErrLineSourcePins
mutate "R3 the validPkgName guard is dropped" "$H" \
  'p != "" && validPkgName(p)' 'p != ""' TestRestoreSkipLineSubject
mutate "R4 the pkg arm is dropped, always the scope" "$H" \
  'subject = "pkg=" + p' '_ = p' TestRestoreSkipLineSubject
mutate "R5 the mkdir-parent call is reverted" main.go \
  'fmt.Fprint(os.Stderr, restoreSkipLine(dir, hdr.Name, "mkdir parent", err))' \
  'fmt.Fprintf(os.Stderr, "[restore] skip %q: mkdir parent: %v\n", hdr.Name, err)' TestRestoreSkipLinesCarryNoPath
mutate "R6 the OpenFile call is reverted" main.go \
  'fmt.Fprint(os.Stderr, restoreSkipLine(dir, hdr.Name, "", err))' \
  'fmt.Fprintf(os.Stderr, "[restore] skip %q: %v\n", hdr.Name, err)' TestRestoreSkipLinesCarryNoPath
mutate "R7 the copy call goes back to the quoted name" main.go \
  'fmt.Fprint(os.Stderr, restoreSkipLine(dir, hdr.Name, "copy", err))' \
  'fmt.Fprintf(os.Stderr, "[restore] skip %q: copy: %s\n", hdr.Name, logSafeErrText(err))' TestUntarSkipLineCarriesNoPresignedQuery
mutate "R7b the same mutant, against the source pin" main.go \
  'fmt.Fprint(os.Stderr, restoreSkipLine(dir, hdr.Name, "copy", err))' \
  'fmt.Fprintf(os.Stderr, "[restore] skip %q: copy: %s\n", hdr.Name, logSafeErrText(err))' TestErrLineSourcePins
mutate "R8 the dir-entry call is reverted" main.go \
  'fmt.Fprint(os.Stderr, restoreSkipLine(dir, hdr.Name, "dir", err))' \
  'fmt.Fprintf(os.Stderr, "[restore] skip dir %q: %v\n", hdr.Name, err)' TestRestoreSkipLinesCarryNoPath
cp "$W/restore_skip_line.go.orig" restore_skip_line.go
cp "$W/main.go.orig" main.go
[ "$FAILS" -eq 0 ] && echo "== all mutations convicted" || { echo "== $FAILS mutation(s) not convicted"; exit 1; }
