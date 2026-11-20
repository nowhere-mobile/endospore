#!/usr/bin/env bash
# NWP-20261210-10: resume failed on-demand APK fetches from sealed chunks in the user's .appcode staging.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp app_code.go "$W/app_code.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/app_code.go.orig" app_code.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"
RUN='AppFetchResume'
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0
FAILS=0
mutate() {
  local label="$1" file="$2" test="$3" code="$4" output
  cp "$W/$file.orig" "$file"
  if ! python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); t=s; $code; (open(p,'w').write(t) if t != s else sys.exit('mutant did not apply'))" "$file"; then
    echo "  FAIL  mutation did not apply: $label"; FAILS=$((FAILS+1)); return
  fi
  output=$(go test -count=1 -run "$test" . 2>&1)
  case "$output" in *"--- FAIL: $test"*) echo "  ok    convicted by $test: $label";; *) echo "  FAIL  no assertion failure from $test: $label"; FAILS=$((FAILS+1));; esac
  cp "$W/$file.orig" "$file"
}
mutate 'Y1 verb omits default dir' main.go TestAppFetchResumeVerbSetsTheDir "t=t.replace('if chunkCacheDir == \"\" {\\n\\t\\t\\tchunkCacheDir = appFetchResumeDir(dest)\\n\\t\\t}', '// removed')"
mutate 'Y2 success cleanup removed' app_code.go TestAppFetchResumeKeepsLandedChunks "t=t.replace('if resumeDir {\\n\\t\\tfor _, h := range chunks {\\n\\t\\t\\t_ = os.Remove(filepath.Join(chunkCacheDir, h))\\n\\t\\t}\\n\\t\\t_ = os.Remove(chunkCacheDir)\\n\\t}', '// removed')"
mutate 'Y2 success cleanup removed' app_code.go TestAppFetchResumeClearsOnSuccess "t=t.replace('if resumeDir {\\n\\t\\tfor _, h := range chunks {\\n\\t\\t\\t_ = os.Remove(filepath.Join(chunkCacheDir, h))\\n\\t\\t}\\n\\t\\t_ = os.Remove(chunkCacheDir)\\n\\t}', '// removed')"
mutate 'Y3 pruning removed' app_code.go TestAppFetchResumePrunes "t=t.replace('if resumeDir {\\n\\t\\tkeep := make(map[string]bool)\\n\\t\\tfor _, d := range m.Deferred {\\n\\t\\t\\tfor _, h := range d.Chunks {\\n\\t\\t\\t\\tkeep[h] = true\\n\\t\\t\\t}\\n\\t\\t}\\n\\t\\t_, _ = pruneChunkCache(chunkCacheDir, keep)\\n\\t}', '// removed')"
mutate 'Y4 prune keeps only current package' app_code.go TestAppFetchResumePrunes "t=t.replace('for _, d := range m.Deferred {\\n\\t\\t\\tfor _, h := range d.Chunks {', 'for _, rel := range rels {\\n\\t\\t\\td := m.Deferred[rel]\\n\\t\\t\\tfor _, h := range d.Chunks {', 1)"
mutate 'Y5 cleanup runs on failure' app_code.go TestAppFetchResumeKeepsLandedChunks "t=t.replace('if err != nil {\\n\\t\\treturn w.done, fmt.Errorf(\"materialise %s: %w\", pkg, err)\\n\\t}', 'if err != nil {\\n\\t\\tif resumeDir { _ = os.RemoveAll(chunkCacheDir) }\\n\\t\\treturn w.done, fmt.Errorf(\"materialise %s: %w\", pkg, err)\\n\\t}')"
mutate 'Y6 resume dir is beside .appcode' app_code.go TestAppFetchResumeNeverSealed "t=t.replace('return filepath.Join(destDir, appFetchResumeDirName)', 'return filepath.Join(destDir, \"..\", appFetchResumeDirName)')"
mutate 'Y6 misplaced dir fails landed-chunk test' app_code.go TestAppFetchResumeKeepsLandedChunks "t=t.replace('return filepath.Join(destDir, appFetchResumeDirName)', 'return filepath.Join(destDir, \"..\", appFetchResumeDirName)')"
mutate 'Y7 explicit cache overridden' main.go TestAppFetchResumeVerbSetsTheDir "t=t.replace('if chunkCacheDir == \"\" {\\n\\t\\t\\tchunkCacheDir = appFetchResumeDir(dest)\\n\\t\\t}', 'chunkCacheDir = appFetchResumeDir(dest)')"
cp "$W/app_code.go.orig" app_code.go
if python3 -c 'import sys;p="app_code.go";s=open(p).read();a="It is in the roamed user\x27s CE";t=s.replace(a,"Control: it is in the roamed user\x27s CE",1);open(p,"w").write(t) if t!=s else sys.exit("control did not apply")'; then
  output=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo '  ok    control: a comment edit survives'; else echo '  FAIL  control: a comment edit failed the suite'; FAILS=$((FAILS+1)); fi
else
  echo '  FAIL  control did not apply'; FAILS=$((FAILS+1))
fi
cp "$W/app_code.go.orig" app_code.go
[ "$FAILS" = 0 ] || exit 1
echo 'all 9 mutant runs convicted; control survived'
