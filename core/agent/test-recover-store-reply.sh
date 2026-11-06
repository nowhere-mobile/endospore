#!/usr/bin/env bash
# test-recover-store-reply.sh [--mutate] -- runs recover_store_reply_test.go (NWP-20261013-23); --mutate re-runs it
# against main.go / RecoverCopy.java / ChooserActivity.java with each guard broken in turn, restoring the files on exit
# (the chooser's RECOVER copy moved to RecoverCopy.java in NWP-20261115-10). Each mutant
# must be CONVICTED; one that fails to apply counts as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
MAIN=main.go; CA=../chooser/src/com/nowhere/chooser/ChooserActivity.java; RC=../chooser/src/com/nowhere/chooser/RecoverCopy.java
RUN=(go test -count=1 -run 'TestRecoverReply_|TestCapModeRecover' .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$MAIN" "$MAIN.orig"; cp "$CA" "$CA.orig"; cp "$RC" "$RC.orig"
trap 'mv -f "$MAIN.orig" "$MAIN"; mv -f "$CA.orig" "$CA"; mv -f "$RC.orig" "$RC"' EXIT
fails=0
mut() { # mut <label> <file> <python-regex pattern> <replacement>
  python3 - "$2" "$3" "$4" <<'PY' || { echo "  INERT     $1 -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1: sys.exit(1)
open(p,'w').write(n)
PY
  if "${RUN[@]}" >/dev/null 2>&1; then echo "  SURVIVED  $1"; fails=$((fails+1)); else echo "  convicted $1"; fi
  cp "$MAIN.orig" "$MAIN"; cp "$CA.orig" "$CA"; cp "$RC.orig" "$RC"
}
mut "M1 reply collapses to OK/BLANK (daemonVaultOp)" "$MAIN" 'case errors\.Is\(err, errRecoverAfterUnwrap\):\n\t\treturn "ERR-STORE"' 'case false:
		return "ERR-STORE"'
mut "M2 sentinel set before the unwrap" "$MAIN" 'func recoverVault\(base, name, mnemonic, newpass string\) \(err error\) \{\n\tunwrapped := false' 'func recoverVault(base, name, mnemonic, newpass string) (err error) {
	unwrapped := true'
mut "M3 panic conversion dropped" "$MAIN" 'err = fmt\.Errorf\("%w: panic: %v", errRecoverAfterUnwrap, r\)' 'panic(r)'
mut "M4 error wrap dropped" "$MAIN" '\} else if unwrapped && err != nil' '} else if false && err != nil'
mut "M5 chooser ERR-STORE arm moved behind the generic text" "$RC" '"ERR-STORE"\.equals\(r\)' '"ERR-STOREX".equals(r)'
mut "M6 the Reset screen stops rendering through RecoverCopy" "$CA" 'RecoverCopy\.failText\(r\)' '"reset failed"'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
