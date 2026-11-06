#!/usr/bin/env bash
# test-bindings-repair.sh [--mutate] -- runs bindings_repair_test.go and the owner-mode verb tests (NWP-20261110-02):
# REPAIR-BINDINGS keeps every good line and mine record of bindings.conf, drops the damaged lines, replaces an
# unreadable file and marks the file rebuilt; SET-SIM-MINE marks a SIM of a rebuilt file the phone's own line; both are
# gate-only and answer BUSY while sessionMu is held; GET-BINDINGS lists the marks. --mutate re-runs it against a COPY of
# core/agent under a temp root, bindings_repair.go, main.go and owner_key.go broken in turn; the checked-out tree is never
# touched. Each mutant must be CONVICTED by a `--- FAIL`; one that fails to apply, or fails to compile, counts as a
# failure. No mutant relies on the two tests that skip as root.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/gotmp" "$W/tmp"
export GOTMPDIR="$W/gotmp" TMPDIR="$W/tmp"
RUN=(go test -count=1 -run '^TestBindingsRepair|^TestOwnerMode' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp -a . "$W/agent"
fails=0
mut() { # mut <label> <file in the copy> <python-regex pattern> <replacement>
  local res rc f
  for f in bindings_repair.go bindings_check.go main.go owner_key.go; do cp -f "$f" "$W/agent/$f"; done
  python3 - "$W/agent/$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  res=$(cd "$W/agent" && "${RUN[@]}" 2>&1); rc=$?
  score_mutant "$1" "$rc" "$res" || fails=$((fails+1))
}
mut "M1 the repair writes no rebuilt mark" bindings_repair.go 'bindingsMarks\{rebuilt: true, mine: st\.mine\}' 'bindingsMarks{rebuilt: false, mine: st.mine}'
mut "M2 the repair keeps the damaged lines" bindings_repair.go 'writeBindingsMarked\(st\.lines, nil, bindingsMarks\{rebuilt: true, mine: st\.mine\}\)' 'writeBindingsMarked(st.lines, st.damaged, bindingsMarks{rebuilt: true, mine: st.mine})'
mut "M3 the repair drops the mine records" bindings_repair.go 'bindingsMarks\{rebuilt: true, mine: st\.mine\}' 'bindingsMarks{rebuilt: true}'
mut "M4 the CLEAN arm writes anyway" bindings_repair.go '(if !st\.flawed \{ // absent, or clean \(rebuilt or not\)\n)(\t+)(return "OK CLEAN\\n")' '\1\2writeBindingsMarked(st.lines, nil, marksAfter(st))\n\2\3'
mut "M5 SET-SIM-MINE accepted while flawed" bindings_repair.go '(func setSimMine.*?)if st\.flawed \{' '\1if false {'
mut "M6 GET-BINDINGS omits REBUILT" bindings_repair.go '(func bindingsMarksReply.*?)if st\.rebuilt \{' '\1if false {'
mut "M7 ownerModeCmd lacks REPAIR-BINDINGS" owner_key.go '"REPAIR-BINDINGS", "SET-SIM-MINE":' '"SET-SIM-MINE":'
mut "M8 the TryLock set lacks SET-SIM-MINE" main.go 'name == "REPAIR-BINDINGS" \|\| name == "SET-SIM-MINE" \|\| name == "DELETE-BINDING" \|\|' 'name == "REPAIR-BINDINGS" || name == "DELETE-BINDING" ||'
mut "M9 SET-SIM-MINE strips a trailing CR before validating" main.go 'iccid, flag := strings\.TrimSuffix\(ei, "\\n"\), strings\.TrimSuffix\(ef, "\\n"\)' 'iccid, flag := strings.TrimRight(ei, "\\r\\n"), strings.TrimRight(ef, "\\r\\n")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
