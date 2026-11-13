#!/usr/bin/env bash
# test-unfetched-fetch.sh [--mutate] -- runs unfetched_fetch_test.go (NWP-20261130-03: the sign-in skips the spans of
# parked On-demand and Auto packages and lists them per scope; fetch-oddata places one package's data into its hold by
# those spans; the seal walk leaves out a listed package's directories whatever they hold, so the carry keeps its stored
# span; only the done marker proves a placement; the plan entry and the marker stay until the list line is off; a sign-out
# stops a download between chunks; the #72 receipt the skip restore earns admits a seal while packages are listed; OD-DATA-PENDING answers the chooser's launch barrier without a worker lane). --mutate breaks a COPY of the package in the
# suite's temp root, one guard at a time, so the source tree is never edited. Each mutant must be CONVICTED by a
# `--- FAIL` line of the test named for it; one that does not apply, does not compile, or fails without that line counts
# as a failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PAT='TestUnfetchedCarry_U3_|TestUnfetchedRestore|TestFetchOdData|TestUnfetchedReceipt|TestUnfetchedWalk|TestSealSkipsOdFetch|TestOdListNames|TestOdBarrier|TestFetchApp_FailedStageIsNotOK|TestOdDataPending|TestOdPendingName'

out=$(go test -count=1 -run "$PAT" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

mkdir "$W/pkg" "$W/tmp" || exit 2
cp -a . "$W/pkg/" || exit 2
export TMPDIR="$W/tmp" GOTMPDIR="$W/tmp"
SRC=$PWD
cd "$W/pkg" || exit 2

fails=0
mut() { # mut <label> <file> <required --- FAIL test> <python-regex pattern> <replacement> [<pattern> <replacement>]...
  local label="$1" src="$2" want="$3" out nl=$'\n'
  python3 - "$src" "${@:4}" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); cp "$SRC/$src" "$src"; return; }
import re,sys
src=sys.argv[1]
rest=sys.argv[2:]
s=open(src).read()
for pat,rep in zip(rest[0::2],rest[1::2]):
    s,c=re.subn(pat,lambda _m:rep,s,count=1,flags=re.S)
    if c!=1: sys.exit(1)
open(src,'w').write(s)
PY
  if ! out=$(go vet . 2>&1); then
    echo "  NOCOMPILE $label"; head -5 <<<"$out"; fails=$((fails+1)); cp "$SRC/$src" "$src"; return
  fi
  out=$(go test -count=1 -run "$PAT" . 2>&1)
  if [[ "$nl$out" == *"$nl"*"--- FAIL: $want "* ]]; then
    echo "  convicted $label: --- FAIL: $want"
  elif [[ "$nl$out" == *"$nl"*'--- FAIL'* ]]; then
    echo "  WRONG-FAIL $label -- failed, but not in $want:"; grep -- '--- FAIL' <<<"$out"; fails=$((fails+1))
  elif [[ "$nl$out" != *"${nl}ok"* ]]; then
    echo "  NOFAIL-LINE $label -- failed without a --- FAIL line"; tail -15 <<<"$out"; fails=$((fails+1))
  else
    echo "  SURVIVED  $label"; fails=$((fails+1))
  fi
  cp "$SRC/$src" "$src"
}
mut "F1 the skip ignores the park set" unfetched_fetch.go TestUnfetchedRestore_SkipsParkedSpans \
  'if parked\[p\] \{' 'if parked[p] && false {'
mut "F2 the fetch does not take the package off its list" unfetched_fetch.go TestFetchOdData_ListAndPlanBookkeeping \
  'if err := removeUnfetched\(list, pkg\); err != nil \{' 'if err := error(nil); err != nil {'
mut "F3 the receipt rejects: a skip counts as a skipped entry, so finishRestore withholds the receipt" unfetched_fetch.go TestUnfetchedReceipt_AdmitsSealAfterSkip \
  'skipped := cdcRestoreProg\(base, key, p1, dest, 0, ladder, nil\)' 'skipped := cdcRestoreProg(base, key, p1, dest, 0, ladder, nil) + len(cands)'
mut "F4 the walk does not exclude a listed package" incremental_seal.go TestUnfetchedWalk_ExcludesListed \
  'if info\.IsDir\(\) && dropPkgForRel\(rel, excl\) \{' 'if false {'
mut "F5 the restore creates a missing list" unfetched_fetch.go TestUnfetchedRestore_OffRestoresAll \
  'return nil, "", "", false // only roamd creates a list' 'os.WriteFile(list, nil, 0o600) // only roamd creates a list'
mut "F6 the merge keeps the held copy over the canonical" unfetched_fetch.go TestFetchOdData_RoundTripByteEqual \
  'if err := overlayTree\(canon, held\); err != nil \{' 'if err := error(nil); err != nil {'
mut "F7 the fetch stage is sealed" incremental_seal.go TestSealSkipsOdFetchStage \
  'if isOdFetchStagePath\(rel\) \{' 'if false {'
mut "F8 the walk exclusion walks a listed package that holds files (RF-002)" incremental_seal.go TestUnfetchedWalk_ExcludesListed \
  'if info\.IsDir\(\) && dropPkgForRel\(rel, excl\) \{' 'if info.IsDir() && dropPkgForRel(rel, excl) && func() bool { n := 0; filepath.Walk(p, func(_ string, i os.FileInfo, _ error) error { if i != nil && !i.IsDir() { n++ }; return nil }); return n == 0 }() {'
mut "F9 the guard admits a listed package not carried by its span" unfetched_guard.go TestUnfetchedCarry_U3_WalkedIsNotCarriedAndIsRefused \
  'if _, ok := carried\[p\]; oldPkg\[p\] > 0 && !ok \{' 'if false {'
mut "B1 the barrier is never set (RF-011)" app_code.go TestOdBarrier_DelayedWorkerAndFailedFetch \
  'stopBarrier := odLaunchBarrier\(dest, name, uid, pkg\)' 'stopBarrier := func() {}'
mut "B2 the barrier runs after the delayed odrestore (RF-011)" app_code.go TestOdBarrier_DelayedWorkerAndFailedFetch \
  'stopBarrier := odLaunchBarrier\(dest, name, uid, pkg\)' '' \
  'out := odRestoreWorker\(dest, "odrestore", name, pass, uid, seSecret, kind, pkg, "", nil\)' 'out := odRestoreWorker(dest, "odrestore", name, pass, uid, seSecret, kind, pkg, "", nil); stopBarrier := odLaunchBarrier(dest, name, uid, pkg)'
mut "B3 the barrier ignores the lists (RF-011)" unfetched_fetch.go TestOdBarrier_NotListed \
  'func odBarrierNeeded\(dest, uid, pkg string\) bool \{' 'func odBarrierNeeded(dest, uid, pkg string) bool { if true { return true }'
mut "B4 an unreadable list counts as not listing the package (RF-011)" unfetched_fetch.go TestOdBarrier_UnreadableList \
  'b, err := os\.ReadFile\(list\)\n\t\tif err != nil \{\n\t\t\treturn true' 'b, err := os.ReadFile(list)
		if err != nil {
			return false'
mut "B5 odblock rides the RW lane (RF-011)" main.go TestOdBarrier_Lane \
  'case "odblock":\n\t\t// NWP-20261130-03: the launch barrier of a just-installed unfetched app must not wait behind a seal\.\n\t\treturn laneRO' 'case "odblock":
		return laneRW'
mut "B6 the barrier carries the passphrase onto the RO lane (RF-011)" unfetched_fetch.go TestOdBarrier_DelayedWorkerAndFailedFetch \
  'try\(dest, "odblock", name, "", uid' 'try(dest, "odblock", name, name, uid'
mut "B7 a busy barrier stops the restore (RF-011)" app_code.go TestOdBarrier_BusyStillRestores \
  'stopBarrier := odLaunchBarrier\(dest, name, uid, pkg\)' 'stopBarrier := odLaunchBarrier(dest, name, uid, pkg); if odBarrierNeeded(dest, uid, pkg) { stopBarrier(); return }'
mut "B8 a busy barrier is tried only once (RF-011)" unfetched_fetch.go TestOdBarrier_BusyRetriesWhileRestoreWaits \
  'if out != workerBusy \{\n\t\treturn func\(\) \{\}\n\t\}' 'if out != "" { return func() {} }'
mut "B9 the tries outlive the restore (RF-011)" unfetched_fetch.go TestOdBarrier_TriesEndWithTheRestore \
  'return func\(\) \{ close\(stopped\) \}' 'return func() {}'
mut "B10 a refused block is tried again (RF-011)" unfetched_fetch.go TestOdBarrier_RefusalIsNotRetried \
  'if out != workerBusy \{\n\t\treturn func\(\) \{\}\n\t\}' 'if out == "OK BLOCKED" { return func() {} }'
mut "B11 a store Get installs when its stageapp failed (RF-011)" catalog.go TestFetchApp_FailedStageIsNotOK \
  'if !strings.HasPrefix\(strings.TrimSpace\(out\), "OK"\) \{' 'if false {'
mut "F10 an existing hold counts as a placement (RF-003)" unfetched_fetch.go TestFetchOdData_ExistingHoldIsNotAReceipt \
  'b, err := os\.ReadFile\(done\)\n\tif err != nil \{\n\t\treturn false\n\t\}' 'b, err := os.ReadFile(done); if _, serr := os.Lstat(target); serr == nil { return true }; if err != nil { return false }'
mut "F11 the stored copy is not laid over an existing hold" unfetched_fetch.go TestFetchOdData_ExistingHoldIsNotAReceipt \
  'return overlayTree\(src, target\)' 'return nil'
mut "F12 the done marker is left after the bookkeeping" unfetched_fetch.go TestFetchOdData_ExistingHoldIsNotAReceipt \
  '\tos\.Remove\(done\)\n\tif had \{' $'\tif had {'
mut "F13 the plan entry goes before the list line (RF-004)" unfetched_fetch.go TestFetchOdData_RetryAfterListWriteFailure \
  'func odFinish\(plan odPlan, planPath, list, done, pkg string, had bool\) error \{\n' $'func odFinish(plan odPlan, planPath, list, done, pkg string, had bool) error {\n\tif had { delete(plan.Pkgs, pkg); writeOdPlan(planPath, plan); os.Remove(done) }\n'
mut "F14 the download ignores a sign-out between chunks (RF-005)" main.go TestFetchOdData_SignOutStopsTheDownload \
  'if cancelled != nil && cancelled\(\) \{' 'if false {'
mut "F15 a leftover marker of an unlisted package is kept" unfetched_fetch.go TestFetchOdData_RetryAfterListWriteFailure \
  '\t\t\tos\.Remove\(done\) // a marker a crash left' $'\t\t\t// a marker a crash left'
mut "F16 a missing list counts as nothing to fetch (RF-009)" unfetched_fetch.go TestFetchOdData_UncertainListIsRefused \
  'lb, rerr := os\.ReadFile\(list\)\n\t\tif rerr != nil \{' $'lb, rerr := os.ReadFile(list)\n\t\tif rerr != nil && !errors.Is(rerr, fs.ErrNotExist) {'
mut "F17 an unreadable list counts as nothing to fetch (RF-009)" unfetched_fetch.go TestFetchOdData_UncertainListIsRefused \
  'lb, rerr := os\.ReadFile\(list\)\n\t\tif rerr != nil \{' $'lb, rerr := os.ReadFile(list)\n\t\tif rerr != nil && errors.Is(rerr, fs.ErrNotExist) {'
mut "F18 the DE list is read only after the CE placement (RF-009)" unfetched_fetch.go TestFetchOdData_LostDEListStopsTheCEPlacement \
  'scopes\[i\]\.lines = lb\n\t\}\n\tfor _, sc := range scopes \{\n' $'scopes[i].lines = lb\n\t\tif i == 0 { break }\n\t}\n\tfor _, sc := range scopes {\n\t\tif sc.scope == "de" { l, _ := odScopeFiles(dir, "de"); b, rerr := os.ReadFile(l); if rerr != nil { return ceB, deB, fetched, rerr }; sc.lines = b }\n'
mut "F19 a lost DE list after the CE recovery is ignored (RF-009)" unfetched_fetch.go TestFetchOdData_LostDEListAfterCERecovery \
  'lb, rerr := os\.ReadFile\(list\)\n\t\tif rerr != nil \{' $'lb, rerr := os.ReadFile(list)\n\t\tif rerr != nil && !(i == 1 && errors.Is(rerr, fs.ErrNotExist)) {'
mut "F20 the scope's error text keeps the paths (RF-010)" unfetched_fetch.go TestFetchOdData_FailureLineHasNoPath \
  'return e\.scope \+ ": " \+ errCode\(e\.err\)' 'return e.scope + ": " + e.err.Error()'
mut "F21 the placement failure is wrapped with its paths (RF-010)" unfetched_fetch.go TestFetchOdData_FailureLineHasNoPath \
  '&odScopedErr\{scope: sc\.scope, err: ferr\}' 'fmt.Errorf("%s: %w", sc.scope, ferr)'
mut "F22 the list failure is wrapped with its path (RF-010)" unfetched_fetch.go TestFetchOdData_FailureLineHasNoPath \
  '&odScopedErr\{scope: scopes\[i\]\.scope \+ " list unreadable", err: rerr\}' 'fmt.Errorf("%s list unreadable: %w", scopes[i].scope, rerr)'
mut "F23 the plan failure is wrapped with its path (RF-010)" unfetched_fetch.go TestFetchOdData_FailureLineHasNoPath \
  'fmt\.Errorf\("plan unreadable: %s", errCode\(perr\)\)' 'fmt.Errorf("plan unreadable: %w", perr)'
mut "P1 the verb answers NO for a listed package (2b)" unfetched_fetch.go TestOdDataPending_Reply \
  'if parseUnfetched\(b\)\[pkg\] \{\n\t\t\treturn odPendingYes' 'if parseUnfetched(b)[pkg] {
			return odPendingNo'
mut "P2 the verb ignores the fetch marker (2b)" unfetched_fetch.go TestOdDataPending_Reply \
  'if _, err := os\.Lstat\(filepath\.Join\(dir, odPendingName\(pkg\)\)\); err == nil \{\n\t\treturn odPendingYes' 'if _, err := os.Lstat(filepath.Join(dir, odPendingName(pkg))); err == nil {
		return odPendingNo'
mut "P3 a lost list answers NO (2b)" unfetched_fetch.go TestOdDataPending_Reply \
  'reply = odPendingUnknown\n\t\t\tcontinue' 'continue'
mut "P4 a bad name reaches the session read (2b)" unfetched_fetch.go TestOdDataPending_NoSessionAndBadName \
  'func handleOdDataPending\(conn net\.Conn, dest, pkg string\) \{\n\tif !validPkgName\(pkg\) \{' 'func handleOdDataPending(conn net.Conn, dest, pkg string) {
	if false {'
mut "P5 OD-DATA-PENDING is serialized (2b)" main.go TestOdDataPending_TakesNoLane \
  '\t\t"OD-DATA-PENDING",\n' $'\n'
mut "P6 the verb queues a worker op (2b)" unfetched_fetch.go TestOdDataPending_TakesNoLane \
  'fmt\.Fprint\(conn, odDataPending\(dest, uid, pkg\)\+"\\n"\)' 'odBarrierWorker(dest, "odblock", name, "", uid, "", "", pkg, "", nil); fmt.Fprint(conn, odDataPending(dest, uid, pkg)+"\n")'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
