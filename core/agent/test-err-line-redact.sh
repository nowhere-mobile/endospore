#!/usr/bin/env bash
# test-err-line-redact.sh [--mutate] -- runs err_line_redact_test.go and the tests that hold the lines it touches
# (NWP-20261117-26, backlog row "A sign-in whose chunk fetch fails for good writes the whole presigned store URL,
# credential and signature included, into roam.log"): main()'s ERR: line, untarFrom's copy skip line, restore-app's
# error line, the other store-error lines and errCode / healErrText print through logSafeErrText, so no line carries
# a presigned query or a head key, and the exit code still comes from the raw value. --mutate re-runs it against a
# COPY of the package with each guard broken in turn; the tree is never touched. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 600s -run 'TestLogSafeErrText|TestErrLine|TestUntarSkipLine|TestTheRestoreVerbExitsStoreUnreachableOnAChunkCut|TestNoLogPrintsAProfileNameOutsideQuotes|TestErrCodeUnwrapsPathErrors|TestMediaLogLinesQuotePaths' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <old text> <new text>: the old text must occur exactly once
  local label=$1 file=$2 old=$3 new=$4 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, 'w').write(s.replace(old, new))
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
mut "R1 main prints r raw" main.go \
  'fmt.Fprintln(os.Stderr, "ERR:", logSafeErrText(r))' 'fmt.Fprintln(os.Stderr, "ERR:", r)'
mut "R2 logSafeErrText skips the head-key rule" log_redact.go \
  $'\t}\n\treturn redactNameIn(s, "")\n}' $'\t}\n\treturn reURLQuery.ReplaceAllString(s, "${1}")\n}'
mut "R3 untarFrom's copy line prints err raw" main.go \
  'copy: %s\n", hdr.Name, logSafeErrText(err))' 'copy: %v\n", hdr.Name, err)'
mut "R4 restore-app's line prints err raw" main.go \
  '"restore-app: %s\n", logSafeErrText(err))' '"restore-app: %v\n", err)'
mut "R5 ota-notes-get's line prints err raw" main.go \
  '"ota-notes-get: %s\n", logSafeErrText(err))' '"ota-notes-get: %v\n", err)'
mut "R5b rekeyOnce's line prints err raw" scope_rekey_job.go \
  '"[logind] rekey %s: %s\n", suf, logSafeErrText(err))' '"[logind] rekey %s: %v\n", suf, err)'
mut "R6 errCode's fallback back to err.Error()" incremental_seal.go \
  $'\t\treturn errCode(se.Err)\n\t}\n\treturn logSafeErrText(err)\n}' $'\t\treturn errCode(se.Err)\n\t}\n\treturn err.Error()\n}'
mut "R7 healErrText's default back to err.Error()" media_heal.go \
  $'\tdefault:\n\t\treturn logSafeErrText(err)' $'\tdefault:\n\t\treturn err.Error()'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
