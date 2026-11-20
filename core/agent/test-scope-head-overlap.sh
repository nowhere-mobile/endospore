#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'cp "$W/scope_head_overlap.go" scope_head_overlap.go; cp "$W/main.go" main.go; rm -rf "$W"' EXIT
cp scope_head_overlap.go "$W/scope_head_overlap.go"
cp main.go "$W/main.go"
. ./suite-report.sh

out=$(go test -count=1 -run 'TestScopeHeadOverlap|TestBareHeadReads_RestoreCaseUsesOneMemo' . 2>&1) || rc=$?
rc=${rc:-0}
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

run_mutant() {
  local label="$1" file="$2" old="$3" new="$4" rc=0 out
  cp "$W/$file" "$file"
  python3 - "$file" "$old" "$new" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = bytes(sys.argv[2], "utf-8").decode("unicode_escape")
new = bytes(sys.argv[3], "utf-8").decode("unicode_escape")
if old not in s: raise SystemExit("mutant did not apply: " + sys.argv[1])
p.write_text(s.replace(old, new, 1))
PY
  out=$(go test -count=1 -run 'TestScopeHeadOverlap|TestBareHeadReads_RestoreCaseUsesOneMemo' . 2>&1) || rc=$?
  cp "$W/$file" "$file"
  if [[ "$label" == control* ]]; then
    if [ "$rc" -eq 0 ] && { [[ "$out" == ok* ]] || [[ "$out" == *$'\nok '* ]] || [[ "$out" == *$'\nok\t'* ]]; }; then
      echo "  survived $label"
      return 0
    fi
    echo "  BROKEN control mutant $label"
    tail -n 15 <<<"$out"
    return 1
  fi
  score_mutant "$label" "$rc" "$out"
}

run_late_join_mutant() {
  local rc=0 out
  cp "$W/main.go" main.go
  python3 - main.go <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
early = "joinScopeHead()\n\t\t// NWP-20260819-05:"
late = "key, manifestBlob, restoredHead, ok := resolveKeyHeadForLoginWith(base, profile, pass, memo)\n\t\tjoinScopeHead()"
if early not in s or late.split("\n")[0] not in s: raise SystemExit("late-join mutant did not apply")
s = s.replace(early, "// join moved after head resolution\n\t\t// NWP-20260819-05:", 1)
s = s.replace(late.split("\n")[0], late, 1)
p.write_text(s)
PY
  out=$(go test -count=1 -run 'TestScopeHeadOverlap|TestBareHeadReads_RestoreCaseUsesOneMemo' . 2>&1) || rc=$?
  cp "$W/main.go" main.go
  score_mutant 'O1/T0: join occurs after head resolution' "$rc" "$out"
}

run_mutant 'O1: batch contains exactly the two v2 refs' scope_head_overlap.go 'prefetchReadCaps([]string{"ref/" + bareRef, "ref/" + scopeRef})' 'prefetchReadCaps([]string{"ref/" + bareRef, "ref/" + scopeRef, "ref/" + profileRefLegacy(profile, pass)})'
run_mutant 'O1: one batched /caps request' scope_head_overlap.go 'prefetchReadCaps([]string{"ref/" + bareRef, "ref/" + scopeRef})' '_ = bareRef; prefetchReadCaps(nil)'
run_mutant 'O2: scope probe runs beside the bare read' scope_head_overlap.go 'goSafe("scope-head-overlap", func() {' 'scopeHeadOverlapInline("scope-head-overlap", func() {'
run_mutant 'O3: absent scope is not memoized' scope_head_overlap.go 'complete = result.exists && haveVal' 'complete = haveVal'
run_mutant 'O4: direct S3 does not start a worker' scope_head_overlap.go 'if !capMode() || !isS3(base) {' 'if !isS3(base) {'
run_mutant 'O4: bare vault does not start a scope worker' scope_head_overlap.go 'if i < 0 || (multiDeviceEnabled() && isPerUnitRef(profile)) {' 'if (i < 0 && false) || (multiDeviceEnabled() && isPerUnitRef(profile)) {'
run_late_join_mutant
run_mutant 'O5: failed speculative probe leaves resolution live' scope_head_overlap.go 'if complete && !panicked {' 'if complete || panicked {'
run_mutant 'control comment change survives' scope_head_overlap.go 'keeps Q036\x27s decisions' 'keeps Q036 decisions'
