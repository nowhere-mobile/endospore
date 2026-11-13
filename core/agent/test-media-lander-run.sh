#!/usr/bin/env bash
# test-media-lander-run.sh [--mutate] -- runs media_lander_run_test.go (NWP-20261201-14, backlog "A 179-second login, 95% of
# it bulk media restored INLINE before the gate opens", Q106 slice S4b: mediad runs the lander, docs/media-after-gate.md §8).
# --mutate re-runs it against a COPY of the package with one rule broken in turn. Each mutant must be CONVICTED by a
# `--- FAIL`; one that fails to apply, or fails to compile, counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestMediaBgRun' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
R=media_lander_run.go
S=media_server.go
mut "M1 mediadServe returns on no mounts (R1)" $R \
  'if landerDone == nil \{' 'if true {'
mut "M2 writeProg's empty test ignores left (R2)" $S \
  ' && s\.restoring\.left == 0' ''
mut "M3 RESTORING is printed first (R2)" $S \
  'lines \+= (fmt\.Sprintf\("RESTORING[^\n]*\))' 'lines = \1 + lines'
mut "M4 the list is written in place (R3 fd)" $R \
  'tmp := f \+ "\.tmp"' 'tmp := f'
mut "M5 the list takes the target (R3)" $R \
  'p := filepath\.Join\(l\.dest, filepath\.FromSlash\(rel\)\)' 'p, _ := landerTarget(l.dest, rel, l.unders)'
mut "M6 commit ignores stopped (R4)" $R \
  'if l\.stopped\.Load\(\) (\{\n\t\treturn errLanderStopped)' 'if false \1'
mut "M7 Stop skips mu (R4)" $R \
  '(func \(l \*bgLander\) Stop\(\) \{.*?)\tl\.mu\.Lock\(\)\n\tdefer l\.mu\.Unlock\(\)\n' '\1'
mut "M8 aftergateActive is dropped (R5)" $R \
  'if !aftergateActive\(ref, rh\) \{' 'if false {'
mut "M9 the flag check is dropped (R5)" $R \
  'if !mediaAfterGateOn\(\) \{' 'if false {'
mut "M10 Stop runs after the teardown (R6)" mediafs.go \
  '\tlander\.Stop\(\)\n(.*?\n\tfor _, mt := range allMounts \{.*?\n\t\}\n)' '\1\tlander.Stop()\n'
mut "M11 onSettled is skipped for a present rel (R2 end to end)" media_lander.go \
  '(err == nil \{\n\t+c\.skipped\+\+\n\t+record\(rel\))\n\t+in\.onSettled\(rel, false\)' '\1'
mut "M12 media-bg.list is dropped from isSessionFileList (R3)" reap_lists.go \
  '"media-bg\.list", ' ''
mut "M13 a store panic is not recovered (R5)" $R \
  'if err := recovered\(func\(\) \{ key, _, ok = bgResolveKey\(base, scope, pass\) \}\); err != nil \|\| !ok \{' 'key, _, ok = bgResolveKey(base, scope, pass)
	if !ok {'
mut "M14 a publish after Stop is not refused (R2 after Stop)" $R \
  '(func \(l \*bgLander\) unlessStopped.*?)if l\.stopped\.Load\(\) \{' '\1if false {'
mut "M15 a landed path is listed after the commit (R4 Stop right after a write)" media_lander.go \
  'if err == nil \{\n\t+in\.onWritten\(rel\)\n\t+\}\n(.*?record\(rel\)\n)(\t+in\.onSettled\(rel, true\))' '\1\t\t\tin.onWritten(rel)\n\2'
mut "M16 the runner does not wire onWritten (R4 Stop right after a write)" $R \
  '\tin\.onWritten = l\.onWritten\n' ''
mut "M17 a write that dropped its copy is listed (R3 dropped copy)" media_lander.go \
  'if err == nil (\{\n\t+in\.onWritten)' 'if true \1'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
