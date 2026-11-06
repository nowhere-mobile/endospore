#!/usr/bin/env bash
# test-late-work.sh [--mutate] -- runs late_work_test.go (NWP-20261116-01, h46 #1 of docs/product-decisions.md
# 2026-10-28): autoPublish and enrollUnitAtLogin run after the ROAM-IN reply as the session's late job; LOGOUT, DELETE,
# the cold locks, BACKUP and syncLoop wait for it up to lateWorkBound, then mark it abandoned; every write re-checks the
# mark and .roamsession, at each store write boundary (the directory writer, capFlush) and before every retry of a
# PUT (retryStoreWithinGuarded, lateWriteHook). Part 2 (NWP-20261116-03) moves roamInWallet and telHandoffRoamIn into
# the same job, first: the wallet landing re-checks under the wallet lock (and refuses a lock it did not get, merges a
# claim, and does nothing over a standing proof), the telephony staging under telMu, and the chooser's claim releases
# the held bring-up only once the hand-off is done. L15-L20 are the task's L8-L13. L26-L28 guard the plan carry
# after the landing (its head reads can block past the bound); L29-L30 its head publication. --mutate re-runs it
# against a COPY of the package with each guard broken in turn; the tree is never touched. Each mutant must be CONVICTED by a
# real `--- FAIL`; one that fails to apply or to compile is a failure.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
RUN=(go test -count=1 -timeout 300s -run 'TestLateWork' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

fails=0
mut() { # mut <label> <file> <python expression over s that returns the mutated text, or None when it does not apply>
  local label=$1 file=$2 expr=$3 P res mrc
  P=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  cp -a . "$P/agent" && rm -f "$P"/agent/*.orig
  if ! (cd "$P/agent" && python3 - "$file" "$expr" <<'PY'
import re, sys
p, expr = sys.argv[1:3]
s = open(p).read()
n = eval(expr)
if n is None or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  ); then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$P"; return; fi
  res=$(cd "$P/agent" && "${RUN[@]}" 2>&1); mrc=$?
  score_mutant "$label" "$mrc" "$res" || fails=$((fails+1))
  rm -rf "$P"
}
one() { echo "(lambda r: r[0] if r[1] == 1 else None)(re.subn($1, $2, s, count=1))"; }
mut "L1 handleLogout without the wait" main.go \
  "$(one "r'\twaitLateWorkConn\(conn, loginConnDeadline, true, \"logout\"\)\n'" "''")"
mut "L2 handleDelete without the wait" main.go \
  "$(one "r'\twaitLateWorkConn\(conn, 120\*time\.Second, false, \"delete\"\)\n'" "''")"
mut "L3 mayWrite ignores abandoned" late_work.go \
  "$(one "r'if lw\.abandoned\.Load\(\) \{\n\t\treturn false'" "'if false {\n\t\treturn false'")"
mut "L4 mayWrite skips the marker re-read" late_work.go \
  "$(one "r'\t_, _, mu, st := readRoamSessionState\(lw\.dest\)\n\treturn st != roamSessionAbsent && \(mu == \"\" \|\| mu == lw\.uid\)\n'" "'\treturn true\n'")"
mut "L5 the job started before the reply" main.go \
  "$(one "r'(\t\tholdTelStagingUntilClaim\(uid\)[^\n]*\n)(\t\tif recovery != \"\" \{\n(?:.*\n)*?\t\t\}\n)((?:\t\t//[^\n]*\n)*\t\tlateName, latePass, lateSE := name, pass, seKey\n(?:\t\tlate[^\n]*\n)*\t\tstartLateWork\((?:.*\n)*?\t\t\)\n)'" "lambda m: m.group(1) + m.group(3) + m.group(2)")"
mut "L6 waitLateWork never times out" late_work.go \
  "$(one "r'time\.NewTimer\(lateWorkBound\)'" "'time.NewTimer(time.Duration(1 << 62))'")"
mut "L7 mayWrite reads readRoamSession, not readRoamSessionState" late_work.go \
  "$(one "r'\t_, _, mu, st := readRoamSessionState\(lw\.dest\)\n'" "'\t_, _, mu := readRoamSession(lw.dest)\n\tst := roamSessionComplete\n\tif mu == \"\" {\n\t\tst = roamSessionAbsent\n\t}\n'")"
mut "L8 the LOGOUT wait writes no WAIT line and does not re-arm the deadline" main.go \
  "$(one "r'waitLateWorkConn\(conn, loginConnDeadline, true, \"logout\"\)'" "'waitLateWork(\"logout\")'")"
# RF-001: the guard at each write boundary, asked again after a store request that can block.
mut "L9 the pointer writer skips the check after the stale-publish read, before the ref PUT" main.go \
  "$(one "r'\tif !lateMayWrite\(mayWrite\) \{\n\t\treturn false\n\t\}\n\tif base == \"disco\" \{'" "'\tif base == \"disco\" {'")"
mut "L10 capFlush skips the check before the lease" main.go \
  "$(one "r'(// h46 #1: the last point before any money can move[^\n]*\n)\tif !flushMayWrite\(\) \{'" "r'\1\tif false {'")"
mut "L11 the enrolment does not carry its guard into the cap bracket" multidevice.go \
  "$(one "r'\t\tcapSetSessionMayWrite\(mayWrite\)[^\n]*\n'" "''")"
# RF-001 (review of cc550c0dd): the guard before every RETRY of a PUT, not only before the first request.
mut "L12 retryStoreWithinGuarded does not ask the guard before each attempt" main.go \
  "$(one "r'\t\tif !lateMayWrite\(mayWrite\) \{\n\t\t\treturn errLateWriteDenied\n\t\t\}\n'" "''")"
mut "L13 lateWriteHook lets every minio attempt through" late_work.go \
  "$(one "r'if !h\.mayWrite\(\) \{'" "'if false {'")"
mut "L14 capFlush's PUT carries no guard into its retries" main.go \
  "$(one "r'\}, flushMayWrite\)'" "'}, nil)'")"
# NWP-20261116-03 (h46 #1, Part 2): roamInWallet and telHandoffRoamIn in the late job.
mut "L15 [task L8] roamInWallet back before the reply" main.go \
  "$(one "r'(\t\tbeginTelHandoff\(uid\)\n)'" "r'\t\troamInWallet(\"s3\", name, pass, seKey, walletPathFor(dest))\n\1'")"
mut "L16 [task L9] the wallet landing skips its mayWrite check" wallet_restore.go \
  "$(one "r'(\t\treturn errWalletNotRestored\n\t\}\n)\tif !lateMayWrite\(mayWrite\) \{\n\t\treturn errLateWriteDenied\n\t\}\n'" "r'\1'")"
mut "L17 [task L10] the telephony staging skips its check under telMu" telephony_lock.go \
  "$(one "r'if !lateMayWrite\(mayWrite\) \{\n(\t\t\tskipped = true)'" "r'if false {\n\1'")"
mut "L18 [task L11] the claim releases before the staging" telephony_lock.go \
  "$(one "r' && !telHandoffPending\[u\]'" "''")"
mut "L19 [task L12] roamInWallet after telHandoffRoamIn" main.go \
  "$(one "r'(\t\t\tfunc\(lw \*lateWork\) \{ roamInWalletGuarded[^\n]*\n)(\t\t\tfunc\(lw \*lateWork\) \{\n\t\t\t\ttelHandoffRoamInGuarded[^\n]*\n\t\t\t\},\n)'" "r'\2\1'")"
mut "L20 [task L13] the job end no longer marks the hand-off done" late_work.go \
  "$(one "r'\t\tdefer markTelHandoffDone\(lw\.uid\)[^\n]*\n'" "''")"
mut "L21 the late landing proceeds without the wallet lock" wallet_restore.go \
  "$(one "r'\tif mayWrite != nil && state != walletLocked \{\n\t\treturn errWalletNotRestored\n\t\}\n'" "''")"
mut "L22 the plan carry runs after the late work ended" wallet_restore.go \
  "$(one "r'\tif !lateMayWrite\(mayWrite\) \{\n\t\tfmt\.Fprintf\(os\.Stderr, \"\[logind\] roam-in: the plan carry was not run[^\n]*\n[^\n]*\n\t\treturn\n\t\}\n'" "''")"
mut "L23 the late landing asks the lock before the standing proof" wallet_restore.go \
  "$(one "r'(\tif walletRestoreLanded\(walletPath, gen\) \{\n\t\treturn nil\n\t\}\n)((?:\t//[^\n]*\n)*\tif mayWrite != nil && state != walletLocked \{\n\t\treturn errWalletNotRestored\n\t\}\n)'" "r'\2\1'")"
mut "L24 the proven absence asks the guard before the standing proof" wallet_restore.go \
  "$(one "r'(\t// A standing proof needs[^\n]*\n\tif walletRestoreLanded\(walletPath, gen\) \{\n\t\treturn nil\n\t\}\n)(\tif !lateMayWrite\(mayWrite\) \{\n\t\treturn errLateWriteDenied\n\t\}\n)(\treturn markWalletRestoreLanded)'" "r'\2\1\3'")"
mut "L25 the late landing asks the guard before the standing proof" wallet_restore.go \
  "$(one "r'(\tif walletRestoreLanded\(walletPath, gen\) \{\n\t\treturn nil\n\t\}\n)((?:\t//[^\n]*\n)*\tif mayWrite != nil && state != walletLocked \{\n\t\treturn errWalletNotRestored\n\t\}\n)(\tif !lateMayWrite\(mayWrite\) \{\n\t\treturn errLateWriteDenied\n\t\}\n)'" "r'\3\1\2'")"
# RF-001 (second review): the plan carry asks the guard after its head reads, which can block past the bound.
mut "L26 the plan carry's write boundaries never ask the guard" main.go \
  "$(one "r'\t\tif lateMayWrite\(mayWrite\) \{\n\t\t\treturn false\n\t\t\}\n\t\tfmt\.Fprintf\(os\.Stderr, \"\[agent\] plan carry retry: stopped'" "'\t\tif true {\n\t\t\treturn false\n\t\t}\n\t\tfmt.Fprintf(os.Stderr, \"[agent] plan carry retry: stopped'")"
mut "L27 the carry-record edit skips its re-check after the head read inside its bracket" main.go \
  "$(one "r'\t\tif err == nil && !lateMayWrite\(mayWrite\) \{\n\t\t\terr = errLateWriteDenied\n\t\t\}\n'" "''")"
mut "L28 the plan carry clears the record without the guard" main.go \
  "$(one "r'\tdropBillPrevGuarded\(base, name, pass, dk, mayWrite\)\n'" "'\tdropBillPrev(base, name, pass, dk)\n'")"
# RF-001 (third review): the carry-record edit's head publication asks the guard after its store reads.
mut "L29 the carry-record edit publishes its head through the unguarded putHead" main.go \
  "$(one "r'\t\tif !putHeadGuarded\(base, name, pass, vh, mayWrite\) \{\n'" "'\t\tif putHead(base, name, pass, vh); false {\n'")"
mut "L30 the legacy retirement writes its tombstone without the guard" main.go \
  "$(one "r'\t\treturn putRefBytesGuarded\(base, lg, \[\]byte\{\}, mayWrite\)\n'" "'\t\treturn putRefBytesGuarded(base, lg, []byte{}, nil)\n'")"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
