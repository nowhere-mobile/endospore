#!/usr/bin/env bash
# test-gms-exits.sh [--mutate] -- the issue report's Play services exit records (NWP-20261201-02): the Go half
# (report_gms_exits_test.go) and roamd's `gmsexits)` arm, run for real under every shell found (bash sh dash mksh).
# --mutate re-runs each against a COPY with one part broken. Each mutant must be CONVICTED by the assertion it names; one
# that fails to apply, or fails to compile, counts as a failure.
#
#   bash test-gms-exits.sh                          # the Go tests and the arm, under every shell found
#   bash test-gms-exits.sh --mutate                 # ... plus the mutants
#   bash test-gms-exits.sh --arm <roamd> <shell>    # the arm alone, one roamd copy and one shell (the mutant runner)
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run '^TestGmsExits' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

MUTATE=no; SUT=../vendor-common/bin/nowhere_roamd.sh; ARM_ONLY=no; ONLY=""
case "${1:-}" in
  --mutate) MUTATE=yes ;;
  --arm)    ARM_ONLY=yes; SUT="$2"; ONLY="$3" ;;
esac
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
SELF="$PWD/$(basename "$0")"

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -z "$ONLY" ] || SHELLS=" $ONLY"
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- the arm ------------------------------------------------------------------------------------------------
# Extracted BY ANCHOR, never copied; if the anchors move, extraction fails loudly.
OP=$(sed -n '/^  gmsexits)$/,/^    ;;$/p' "$SUT" | sed '1d;$d')
case "$OP" in *'"$AGENT" gmsexits'*) ;; *) echo "EXTRACTION FAILED: the gmsexits) op" >&2; exit 2 ;; esac

# Modes are asserted only where the filesystem keeps them. Probed, never assumed.
P=$(mktemp -d -p "$W"); : > "$P/f"; chmod 600 "$P/f" 2>/dev/null
MODES=no; [ "$(stat -c %a "$P/f" 2>/dev/null)" = 600 ] && MODES=yes; rm -rf "$P"
mode600(){ [ "$MODES" = no ] || [ "$(stat -c %a "$1" 2>/dev/null)" = 600 ]; }

SENTINEL=dumpsys-stderr-sentinel

mkstubs(){   # mkstubs <dir> <dumpsys exit status> <ok|fail|silent>
  mkdir -p "$1/bin"
  cat > "$1/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  +%s) echo 1614904500 ;;
  '+%Y-%m-%d %H:%M:%S') echo '2021-03-05 00:35:00' ;;
  *) echo stub-date ;;
esac
STUB
  cat > "$1/bin/dumpsys" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$1/dumpsys.args"
readlink /proc/self/fd/0 > "$1/dumpsys.stdin"
echo framework-output
echo "$SENTINEL" >&2
exit $2
STUB
  cat > "$1/agent" <<STUB
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$#" "\$1" "\$2" > "$1/agent.args"
cat > "$1/agent.stdin"
[ "$3" = fail ] && exit 1
[ "$3" = silent ] && exit 0
echo "OK 2 0"
[ -e "$1/roamro.res" ] && : > "$1/partial"
echo "main reason=OTHER sub=OTHER imp=400 age_s=60"
echo "persistent reason=LOW_MEMORY sub=OTHER imp=400 age_s=299"
STUB
  chmod +x "$1/bin/date" "$1/bin/dumpsys" "$1/agent"
}

RACE=no
runop(){     # runop <shell> <dir> <dumpsys exit status> <ok|fail|silent>: the arm with uid 10 under <shell>
  local sh="$1" T="$2"; mkstubs "$T" "$3" "$4"
  { printf 'STATE=%s\nLOG=%s\nRES=%s\nAGENT=%s\nuid=10\n' "$T" "$T/log" "$T/roamro.res" "$T/agent"
    if [ "$RACE" = yes ]; then
      printf '%s\n' 'mv(){ for _a in "$@"; do _dst=$_a; done; command mv "$@" || return' '  rm -f "$_dst"; }'
    fi
    printf '%s\n' "$OP"; } > "$T/op.sh"
  PATH="$T/bin:$PATH" "$sh" "$T/op.sh" >/dev/null 2>&1
}

behaviour(){   # behaviour <shell>: every case that runs the arm, under that shell
  local sh="$1" T first last lg
  echo "== [$sh] the arm's clock line, dump and exit status reach the agent; the reply is published by rename =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 0 ok
  first=$(sed -n 1p "$T/agent.stdin" 2>/dev/null)
  [ "$first" = "nowhere-now=1614904500 2021-03-05 00:35:00" ] && ok "[$sh] the nowhere-now line reaches the agent first" \
    || no "[$sh] the agent's first stdin line was '$first'"
  last=$(sed '/^$/d' "$T/agent.stdin" 2>/dev/null | tail -n 1)
  [ "$last" = "nowhere-dump-rc=0" ] && ok "[$sh] nowhere-dump-rc=0 is the last line" || no "[$sh] the last stdin line was '$last'"
  [ "$(cat "$T/dumpsys.args" 2>/dev/null)" = "activity exit-info com.google.android.gms" ] && ok "[$sh] dumpsys gets the fixed arguments" \
    || no "[$sh] dumpsys got '$(cat "$T/dumpsys.args" 2>/dev/null)'"
  [ "$(cat "$T/dumpsys.stdin" 2>/dev/null)" = /dev/null ] && ok "[$sh] dumpsys reads /dev/null" \
    || no "[$sh] dumpsys stdin was '$(cat "$T/dumpsys.stdin" 2>/dev/null)'"
  [ "$(cat "$T/agent.args" 2>/dev/null)" = "2|gmsexits|10" ] && ok "[$sh] the agent gets gmsexits and the uid" \
    || no "[$sh] the agent's argv was '$(cat "$T/agent.args" 2>/dev/null)'"
  [ "$(head -n 1 "$T/roamro.res" 2>/dev/null)" = "OK 2 0" ] && [ "$(wc -l < "$T/roamro.res")" -eq 3 ] \
    && ok "[$sh] the whole reply lands in RES" || no "[$sh] RES holds '$(cat "$T/roamro.res" 2>/dev/null)'"
  [ ! -e "$T/partial" ] && ok "[$sh] RES did not exist while the agent was writing" || no "[$sh] RES existed mid-write"
  [ ! -e "$T/roamro.res.part" ] && ok "[$sh] no .part left behind" || no "[$sh] .part left behind"
  mode600 "$T/roamro.res" && ok "[$sh] RES is 600 (modes checked: $MODES)" || no "[$sh] RES mode is $(stat -c %a "$T/roamro.res" 2>/dev/null)"
  lg=$(cat "$T/log" 2>/dev/null)
  case "$lg" in *"[roamd] gmsexits -> OK 2 0 stub-date"*) ok "[$sh] the log line carries the reply's first line" ;;
    *) no "[$sh] the log was '$lg'" ;; esac
  case "$lg" in *reason=*) no "[$sh] the log carries a record line" ;; *) ok "[$sh] the log carries counts only" ;; esac
  case "$lg" in *"$SENTINEL"*) no "[$sh] dumpsys's stderr reached the log" ;; *) ok "[$sh] dumpsys's stderr stays out of the log" ;; esac
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 3 ok
  last=$(sed '/^$/d' "$T/agent.stdin" 2>/dev/null | tail -n 1)
  [ "$last" = "nowhere-dump-rc=3" ] && ok "[$sh] a failed dumpsys reaches the agent as nowhere-dump-rc=3" || no "[$sh] the last stdin line was '$last'"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); RACE=yes runop "$sh" "$T" 0 ok
  case "$(cat "$T/log" 2>/dev/null)" in *"[roamd] gmsexits -> OK 2 0"*) ok "[$sh] a poller that removes RES at once does not blank the log line" ;;
    *) no "[$sh] the raced log was '$(cat "$T/log" 2>/dev/null)'" ;; esac
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 0 fail
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "ERR-READ the agent exited non-zero" ] && ok "[$sh] a failing agent answers ERR-READ" \
    || no "[$sh] a failing agent left RES '$(cat "$T/roamro.res" 2>/dev/null)'"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 0 silent
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "ERR-READ the agent printed nothing" ] && ok "[$sh] a silent agent answers ERR-READ" \
    || no "[$sh] a silent agent left RES '$(cat "$T/roamro.res" 2>/dev/null)'"
  rm -rf "$T"
}

armcases(){
  local sh
  echo "shells:$SHELLS"
  for sh in $SHELLS; do behaviour "$sh"; done
  echo "arm: passed $PASS, failed $FAIL"
  [ "$FAIL" -eq 0 ]
}

if [ "$ARM_ONLY" = yes ]; then armcases; exit $?; fi

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
armcases || exit 1
[ "$MUTATE" = yes ] || exit 0

# --- mutants ------------------------------------------------------------------------------------------------
P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
apply(){   # apply <file> <python-regex> <replacement>: exactly one match, or a non-zero exit
  python3 - "$1" "$2" "$3" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
}
# mut <label> <the test that must convict it> <file> <python-regex> <replacement>
mut(){
  local label="$1" want="$2" f="$3" res rc
  cp "$P/$f" "$W/orig.go"
  if apply "$P/$f" "$4" "$5"; then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    if ! score_mutant "$label" "$rc" "$res"; then fails=$((fails+1))
    elif [[ "$res" != *"--- FAIL: $want"* ]]; then echo "  WRONG     $label -- $want did not fail"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
G=report_gms_exits.go
mut "M1 user filter removed" TestGmsExitsOtherUserAndProcessDropped $G 'if b\.user != uid \{' 'if false && b.user != uid {'
mut "M2 process filter removed" TestGmsExitsOtherUserAndProcessDropped $G 'if !ok \{\n\t\t\tdropped\+\+' 'if !ok && label == "x" {\n\t\t\tdropped++'
mut "M3 session-age filter removed" TestGmsExitsOlderThanSessionDropped $G 'if perr != nil \|\| age >= sessionAge \{' 'if perr != nil || (age >= sessionAge && false) {'
mut "M4 age from time.Now()" TestGmsExitsLocalClock $G 'age := int64\(now\.Sub\(ts\) / time\.Second\)' 'age := int64(time.Now().Add(0*now.Sub(ts)).Sub(ts) / time.Second)'
mut "M5 WORD validation removed" TestGmsExitsBadWordIsUnparsed $G 'if !gmsExitWordRe\.MatchString\(w\) \{' 'if false && !gmsExitWordRe.MatchString(w) {'
mut "M6 deviceScope guard removed" TestGmsExitsDeviceScope $G 'if deviceScope \|\| status == nil \{' 'if status == nil {'
mut "M7 rc check removed" TestGmsExitsFailedDump $G 'if rc\[1\] != "0" \{' 'if false && rc[1] != "0" {'
mut "M8 laneFor drops gmsexits" TestGmsExitsLaneAndCap main.go '(case "storagebreakdown"[^\n]*?), "gmsexits"' '\1'
mut "M10 framework header check removed" TestGmsExitsFailedDump $G 'if !sawHeader \{' 'if false && !sawHeader {'
mut "M11 word normalization removed" TestGmsExitsRealFrameworkWords $G 'w := strings\.Trim\(gmsExitSepRe\.ReplaceAllString\(s, "_"\), "_"\)' 'w := s'
mut "M12 failed-parse check removed" TestGmsExitsFormatDriftIsNotCollected $G 'if blocks > 0 && parsed == 0 \{' 'if blocks < 0 && parsed == 0 {'
mut "M13 header pattern narrowed" TestGmsExitsChangedHeaderOpensABlock $G 'regexp\.MustCompile\(`\^\\s\*ApplicationExitInfo\\b`\)' 'regexp.MustCompile(`^\\s*ApplicationExitInfo #\\d+:\\s*$`)'
mut "M14 failed-parse check over-eager" TestGmsExitsHonestReplies $G 'if blocks > 0 && parsed == 0 \{' 'if blocks > 0 && (parsed == 0 || len(kept) == 0) {'
mut "M15 handleReportIssue no longer merges the records" TestGmsExitsReportHandlerIsWired report_issue.go 'mergeGmsExits\(rep\.Status, func\(\) string \{ return fetchGmsExits\(dest, name, uid\) \}, dest, deviceScope\)\n' ''
mut "M16 caller-sent keys kept" TestGmsExitsCallerKeysDeletedAtSessionScope $G 'if strings\.HasPrefix\(k, "gms_exit"\) \{' 'if false && strings.HasPrefix(k, "gms_exit") {'

# M9 runs the arm against a copy of roamd, once per shell, and each shell must convict it on its own line.
M="$W/roamd.sh"
if cp "$SUT" "$M" && apply "$M" 'dumpsys activity exit-info com\.google\.android\.gms </dev/null 2>/dev/null' 'dumpsys activity exit-info com.google.android.gms </dev/null 2>>"$LOG"'; then
  for sh in $SHELLS; do
    res=$(bash "$SELF" --arm "$M" "$sh" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [[ "$res" == *"FAIL  [$sh] dumpsys's stderr reached the log"* ]]; then echo "  convicted M9 the arm's dumpsys stderr sent to \$LOG [$sh]"
    else echo "  SURVIVED  M9 the arm's dumpsys stderr sent to \$LOG [$sh] (rc $rc)"; fails=$((fails+1)); fi
  done
else
  echo "  INERT     M9 the mutation did not apply"; fails=$((fails+1))
fi
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
