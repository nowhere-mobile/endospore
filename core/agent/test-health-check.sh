#!/usr/bin/env bash
# test-health-check.sh [--mutate] -- the login daemon's health checks, part 1 (NWP-20261201-08, backlog: The phone cannot
# tell its user about a known fault it could detect). Every 5 minutes of a session roamd's read-only `healthprobe` reads
# `dumpsys activity oom`, the agent reduces it to one line, and rule play-push-frozen fires when Play services' persistent
# process has been cached 15 minutes or more with no GmsCompat binding. GET-HEALTH serves the last results to the gate and
# a session's issue report carries them as health_* keys.
#
# Runs health_check_test.go, then the `healthprobe)` arm of nowhere_roamd.sh, extracted by anchor, under every shell found
# (bash sh dash mksh). --mutate breaks each guard in turn; each mutant must be CONVICTED. A Go mutant needs a real
# `--- FAIL`; one that fails to apply or compile is a failure. A shell mutant needs a failed assertion under EACH shell.
set -uo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
. ./suite-report.sh
TESTS='Health|GmsOom|PlayPushFrozen'
ROAMD=../vendor-common/bin/nowhere_roamd.sh

out=$(go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

extract_arm() { sed -n '/^  healthprobe)$/,/^    ;;$/p' "$1"; }
case "$(extract_arm "$ROAMD")" in *'exit 0'*) ;; *) echo "EXTRACTION FAILED: the healthprobe) arm of $ROAMD" >&2; exit 2 ;; esac

# probe <shell> <roamd copy> <uid> <agent mode> -- runs the arm in a new dir under $W and prints the dir. The stub agent
# records whether $RES already exists while the agent runs, its arguments and the dump it read.
probe() {
  local sh=$1 sut=$2 uid=$3 mode=$4 T arm
  T=$(mktemp -d -p "$W") || exit 2
  arm=$(extract_arm "$sut")
  cat > "$T/agent" <<STUB
#!/bin/sh
[ -e "$T/res" ] && echo seen > "$T/res-during"
echo ran >> "$T/agent-ran"
echo "\$*" > "$T/agent-args"
cat > "$T/agent-stdin"
case "$mode" in
  good) echo 'gms adj=920 state=CAC bound=0' ;;
  empty) : ;;
esac
exit 0
STUB
  chmod 700 "$T/agent"
  {
    printf 'T="$1"; uid="$2"; RES="$T/res"; LOG="$T/log"; AGENT="$T/agent"; op=healthprobe\n'
    printf 'dumpsys() { echo "$*" > "$T/dumpsys-args"; echo the-dump; echo dumpsys-stderr-noise >&2; }\n'
    printf 'case "$op" in\n%s\nesac\necho fell-through > "$T/fell"\n' "$arm"
  } > "$T/run.sh"
  "$sh" "$T/run.sh" "$T" "$uid" >/dev/null 2>&1
  printf '%s\n' "$T"
}

# cases <shell> <roamd copy> -- prints one `FAIL <assertion>` line per failed assertion, one `ok` line per pass.
cases() {
  local sh=$1 sut=$2 T u
  chk() { if [ "$1" = yes ]; then echo "ok   $2"; else echo "FAIL $2"; fi; }
  is() { if [ "$1" = "$2" ]; then echo yes; else echo no; fi; }

  T=$(probe "$sh" "$sut" 11 good)
  chk "$(is "$(cat "$T/res" 2>/dev/null)" 'gms adj=920 state=CAC bound=0')" "A1 the agent's line reaches \$RES"
  chk "$(is "$([ -e "$T/res.part" ] && echo left)" '')" "A2 \$RES.part is gone after the rename"
  chk "$(is "$([ -e "$T/res-during" ] && echo seen)" '')" "A3 published by rename: no \$RES while the agent writes"
  chk "$(is "$(stat -c %a "$T/res" 2>/dev/null)" 600)" "A4 \$RES is mode 600"
  chk "$(is "$(cat "$T/agent-args" 2>/dev/null)" 'healthoom 11')" "A5 the agent runs healthoom for this uid"
  chk "$(is "$(cat "$T/dumpsys-args" 2>/dev/null)" 'activity oom')" "A6 dumpsys reads activity oom"
  chk "$(is "$(cat "$T/agent-stdin" 2>/dev/null)" 'the-dump')" "A7 the agent reads the dump on stdin"
  chk "$(is "$(grep -c '^\[roamd\] healthprobe -> gms ' "$T/log")" 1)" "A8 one log line with the first word"
  chk "$(is "$(wc -l < "$T/log" | tr -d ' ')" 1)" "A9 the log holds only that line (no dumpsys stderr)"
  chk "$(is "$([ -e "$T/fell" ] && echo fell)" '')" "A10 the arm exits"

  for u in 0 "" 1a; do
    T=$(probe "$sh" "$sut" "$u" good)
    chk "$(is "$(cat "$T/res" 2>/dev/null)" ERR-NOSESSION)" "B1 uid '$u': ERR-NOSESSION"
    chk "$(is "$([ -e "$T/agent-ran" ] && echo ran)" '')" "B2 uid '$u': the agent does not run"
    chk "$(is "$(grep -c '^\[roamd\] healthprobe -> ERR-NOSESSION ' "$T/log")" 1)" "B3 uid '$u': the log names ERR-NOSESSION"
  done

  T=$(probe "$sh" "$sut" 11 empty)
  chk "$(is "$(cat "$T/res" 2>/dev/null)" 'ERR-READ the agent printed nothing')" "C1 an empty answer is ERR-READ"
  chk "$(is "$(grep -c '^\[roamd\] healthprobe -> ERR-READ ' "$T/log")" 1)" "C2 the log names ERR-READ"
}

echo; echo "== the healthprobe) arm =="
for s in $SHELLS; do
  r=$(cases "$s" "$ROAMD")
  f=$(grep '^FAIL' <<<"$r" || true)
  if [ -n "$f" ]; then printf '[%s]\n%s\n' "$s" "$f"; echo FAILED; exit 1; fi
  echo "  ok [$s] $(grep -c '^ok' <<<"$r") assertions"
done
[ "${1:-}" = --mutate ] || exit 0

echo; echo "== Go mutants (each MUST be convicted) =="
fails=0
VC=$(cd ../vendor-common && pwd) || exit 2
# mut <label> <file> <regex> <replacement>: exactly one substitution in a package copy; needs a real `--- FAIL`, and the
# tests that failed are printed. The copy is <R>/agent beside a link to the real ../vendor-common, which
# TestHealthProbeIsWired reads.
mut() {
  local label=$1 file=$2 R P res mrc
  R=$(mktemp -d -p "$W") || { fails=$((fails+1)); return; }
  P="$R/agent"
  { cp -a . "$P" && ln -s "$VC" "$R/vendor-common"; } || { fails=$((fails+1)); rm -rf "$R"; return; }
  python3 - "$P/$file" "$3" "$4" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); rm -rf "$R"; return; }
import re, sys
p, pat, repl = sys.argv[1:4]
s = open(p).read()
n, k = re.subn(pat, lambda m: m.expand(repl), s, count=1)
if k != 1 or n == s: sys.exit(1)
open(p, 'w').write(n)
PY
  res=$(cd "$P" && go test -count=1 -timeout 180s -run "$TESTS" -v . 2>&1); mrc=$?
  if score_mutant "$label" "$mrc" "$res"; then
    sed -n 's/^--- FAIL: \([^ ]*\).*/      by \1/p' <<<"$res"
  else
    fails=$((fails+1))
  fi
  rm -rf "$R"
}

mut "G1 15 minutes becomes 1 minute" health_check.go \
  'const healthPlayFrozenAfter = 15 \* time\.Minute' 'const healthPlayFrozenAfter = 1 * time.Minute'
mut "G2 >= 900 becomes > 920" health_check.go 'p\.adj >= 900 && !p\.bound' 'p.adj > 920 && !p.bound'
mut "G3 the binding is ignored" health_check.go 'p\.adj >= 900 && !p\.bound' 'p.adj >= 900'
mut "G4 an unmeasured check counts as bad" health_check.go \
  'if !p\.measured \{\n\t\treturn\n\t\}' 'if !p.measured {\n\t\tp = healthProbe{measured: true, adj: 920}\n\t}'
mut "G5 the uid filter is dropped" health_check.go \
  'persistent/u` \+ uid \+ `a\[0-9\]\+\$`' 'persistent/u[0-9]+a[0-9]+$`'
mut "G6 adj is read from curRaw=" health_check.go 'const gmsOomAdjField = "cur="' 'const gmsOomAdjField = "curRaw="'
mut "G7 mergeHealth ignores deviceScope" health_check.go 'if deviceScope \|\| status == nil' 'if status == nil'
mut "G8 GET-HEALTH's caller check is removed" health_check.go \
  'if !gateCallerOK\(ownerPeerUID\(conn\)\) \{' 'if false {'
mut "G9 the report does not merge the results" report_issue.go '\n\tmergeHealth\(rep\.Status, uid, deviceScope\)[^\n]*' ''
mut "G10 the clock keeps its monotonic reading" health_check.go \
  'var healthNow = func\(\) time\.Time \{ return time\.Now\(\)\.Round\(0\) \}' 'var healthNow = func() time.Time { return time.Now() }'

echo; echo "== shell mutants (each MUST be convicted under each shell) =="
# smut <label> <sed script>: a mutant of a copy of roamd must fail an assertion under every shell.
smut() {
  local label=$1 m="$W/m.sh" s r f
  if ! sed "$2" "$ROAMD" > "$m"; then echo "  BROKEN    $label -- sed failed"; fails=$((fails+1)); return; fi
  if cmp -s "$ROAMD" "$m"; then echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; fi
  for s in $SHELLS; do
    r=$(cases "$s" "$m")
    f=$(grep '^FAIL' <<<"$r" | head -n 1 || true)
    if [ -n "$f" ]; then echo "  convicted $label [$s] by ${f#FAIL }"
    else echo "  SURVIVED  $label [$s]"; fails=$((fails+1)); fi
  done
  rm -f "$m"
}
smut "S1 the arm writes \$RES in place" 's@"\$AGENT" healthoom "\$uid" > "\$RES.part"@"$AGENT" healthoom "$uid" > "$RES"@'
smut "S2 the uid guard is dropped" "s@^      ''|0|\*\[!0-9\]\*) echo \"ERR-NOSESSION\"@      never-a-uid) echo \"ERR-NOSESSION\"@"
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
