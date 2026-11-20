#!/usr/bin/env bash
# test-media-exits.sh [--mutate] -- the issue report's media service exit records (NWP-20261208-06): the Go half
# (report_media_exits_test.go) and roamd's `mediaexits)` arm, run for real under every shell found (bash sh dash mksh).
# --mutate re-runs each against a COPY with one part broken. Each mutant must be CONVICTED by the assertion it names; one
# that fails to apply, or fails to compile, counts as a failure. The control C1 must SURVIVE.
#
#   bash test-media-exits.sh                          # the Go tests and the arm, under every shell found
#   bash test-media-exits.sh --mutate                 # ... plus the mutants
#   bash test-media-exits.sh --arm <roamd> <shell>    # the arm alone, one roamd copy and one shell (the mutant runner)
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run '^TestMediaExits' .)

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
OP=$(sed -n '/^  mediaexits)$/,/^    ;;$/p' "$SUT" | sed '1d;$d')
case "$OP" in *'"$AGENT" mediaexits'*) ;; *) echo "EXTRACTION FAILED: the mediaexits) op" >&2; exit 2 ;; esac

# Modes are asserted only where the filesystem keeps them. Probed, never assumed.
P=$(mktemp -d -p "$W"); : > "$P/f"; chmod 600 "$P/f" 2>/dev/null
MODES=no; [ "$(stat -c %a "$P/f" 2>/dev/null)" = 600 ] && MODES=yes; rm -rf "$P"
mode600(){ [ "$MODES" = no ] || [ "$(stat -c %a "$1" 2>/dev/null)" = 600 ]; }

SENTINEL=dumpsys-stderr-sentinel
AOSP=com.android.providers.media.module
GOOGLE=com.google.android.providers.media.module
SECRET=odtest-secret-profile

mkstubs(){   # mkstubs <dir> <AOSP dumpsys exit status> <Google dumpsys exit status> <ok|fail|silent>
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
printf '%s\n' "\$*" >> "$1/dumpsys.args"
readlink /proc/self/fd/0 >> "$1/dumpsys.stdin"
echo "ACTIVITY MANAGER PROCESS EXIT INFO (dumpsys activity exit-info)"
echo "  package: \$3"
echo "      ApplicationExitInfo #0:"
echo "        process=\$3 reason=3 (OTHER) subreason=0 (OTHER) status=0"
echo "$SENTINEL" >&2
[ "\$3" = "$AOSP" ] && exit $2
exit $3
STUB
  cat > "$1/agent" <<STUB
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$#" "\$1" "\$2" > "$1/agent.args"
cat > "$1/agent.stdin"
[ "$4" = fail ] && exit 1
[ "$4" = silent ] && exit 0
echo "OK 2 0"
[ -e "$1/roamro.res" ] && : > "$1/partial"
echo "media reason=USER_REQUESTED sub=FORCE_STOP imp=400 age_s=60"
echo "media reason=APP_CRASH_EXCEPTION sub=UNKNOWN imp=400 age_s=299"
STUB
  chmod +x "$1/bin/date" "$1/bin/dumpsys" "$1/agent"
}

RACE=no
runop(){     # runop <shell> <dir> <AOSP rc> <Google rc> <ok|fail|silent>: the arm with uid 10 under <shell>
  local sh="$1" T="$2"; mkstubs "$T" "$3" "$4" "$5"
  { printf 'STATE=%s\nLOG=%s\nRES=%s\nAGENT=%s\nuid=10\nname=%s\nprofile=%s\n' "$T" "$T/log" "$T/roamro.res" "$T/agent" "$SECRET" "$SECRET"
    if [ "$RACE" = yes ]; then
      printf '%s\n' 'mv(){ for _a in "$@"; do _dst=$_a; done; command mv "$@" || return' '  rm -f "$_dst"; }'
    fi
    printf '%s\n' "$OP"; } > "$T/op.sh"
  PATH="$T/bin:$PATH" "$sh" "$T/op.sh" >/dev/null 2>&1
}

lastrc(){ sed '/^$/d' "$1/agent.stdin" 2>/dev/null | tail -n 1; }

behaviour(){   # behaviour <shell>: every case that runs the arm, under that shell
  local sh="$1" T first last lg want rcs a b r
  echo "== [$sh] both media modules are asked; the clock line, the dumps and the exit status reach the agent =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 0 0 ok
  want=$(printf 'activity exit-info %s\nactivity exit-info %s' "$AOSP" "$GOOGLE")
  [ "$(cat "$T/dumpsys.args" 2>/dev/null)" = "$want" ] && ok "[$sh] both media modules were asked" \
    || no "[$sh] both media modules were asked -- dumpsys got '$(cat "$T/dumpsys.args" 2>/dev/null)'"
  [ "$(sort -u "$T/dumpsys.stdin" 2>/dev/null)" = /dev/null ] && ok "[$sh] dumpsys reads /dev/null" \
    || no "[$sh] dumpsys stdin was '$(cat "$T/dumpsys.stdin" 2>/dev/null)'"
  first=$(sed -n 1p "$T/agent.stdin" 2>/dev/null)
  [ "$first" = "nowhere-now=1614904500 2021-03-05 00:35:00" ] && ok "[$sh] the nowhere-now line reaches the agent first" \
    || no "[$sh] the agent's first stdin line was '$first'"
  last=$(lastrc "$T")
  [ "$last" = "nowhere-dump-rc=0" ] && ok "[$sh] nowhere-dump-rc=0 is the last line" || no "[$sh] the last stdin line was '$last'"
  a=$(grep -c "process=$AOSP " "$T/agent.stdin" 2>/dev/null); b=$(grep -c "process=$GOOGLE " "$T/agent.stdin" 2>/dev/null)
  [ "$a" = 1 ] && [ "$b" = 1 ] && ok "[$sh] one block of each module reaches the agent" \
    || no "[$sh] the agent got $a AOSP and $b Google block(s)"
  [ "$(cat "$T/agent.args" 2>/dev/null)" = "2|mediaexits|10" ] && ok "[$sh] the agent gets mediaexits and the uid" \
    || no "[$sh] the agent's argv was '$(cat "$T/agent.args" 2>/dev/null)'"
  [ "$(head -n 1 "$T/roamro.res" 2>/dev/null)" = "OK 2 0" ] && [ "$(wc -l < "$T/roamro.res")" = 3 ] \
    && ok "[$sh] the whole reply lands in RES" || no "[$sh] RES holds '$(cat "$T/roamro.res" 2>/dev/null)'"
  [ ! -e "$T/partial" ] && ok "[$sh] RES did not exist while the agent was writing" || no "[$sh] RES existed mid-write"
  [ ! -e "$T/roamro.res.part" ] && ok "[$sh] no .part left behind" || no "[$sh] .part left behind"
  mode600 "$T/roamro.res" && ok "[$sh] RES is 600 (modes checked: $MODES)" || no "[$sh] RES mode is $(stat -c %a "$T/roamro.res" 2>/dev/null)"
  lg=$(cat "$T/log" 2>/dev/null)
  case "$lg" in *"[roamd] mediaexits -> OK 2 0 stub-date"*) ok "[$sh] the log line carries the reply's first line" ;;
    *) no "[$sh] the log was '$lg'" ;; esac
  case "$lg" in *reason=*) no "[$sh] the log carries a record line" ;; *) ok "[$sh] the log carries counts only" ;; esac
  case "$lg" in *"$SENTINEL"*) no "[$sh] dumpsys's stderr reached the log" ;; *) ok "[$sh] dumpsys's stderr stays out of the log" ;; esac
  case "$lg$(cat "$T/roamro.res" 2>/dev/null)" in *"$SECRET"*) no "[$sh] a line of RES or the log names the profile" ;;
    *) ok "[$sh] no line of RES or the log names the profile" ;; esac
  rm -rf "$T"

  for rcs in "0 4 4" "3 0 3" "3 5 3"; do
    set -- $rcs; a=$1; b=$2; r=$3
    T=$(mktemp -d -p "$W"); runop "$sh" "$T" "$a" "$b" ok
    last=$(lastrc "$T")
    [ "$last" = "nowhere-dump-rc=$r" ] && ok "[$sh] dumpsys rc $a then $b reaches the agent as nowhere-dump-rc=$r" \
      || no "[$sh] dumpsys rc $a then $b reaches the agent as nowhere-dump-rc=$r -- the last stdin line was '$last'"
    [ "$(wc -l < "$T/dumpsys.args" 2>/dev/null)" = 2 ] && ok "[$sh] dumpsys rc $a then $b: both modules still asked" \
      || no "[$sh] dumpsys rc $a then $b: dumpsys ran $(wc -l < "$T/dumpsys.args" 2>/dev/null) time(s)"
    rm -rf "$T"
  done

  T=$(mktemp -d -p "$W"); RACE=yes runop "$sh" "$T" 0 0 ok
  case "$(cat "$T/log" 2>/dev/null)" in *"[roamd] mediaexits -> OK 2 0"*) ok "[$sh] a poller that removes RES at once does not blank the log line" ;;
    *) no "[$sh] the raced log was '$(cat "$T/log" 2>/dev/null)'" ;; esac
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 0 0 fail
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "ERR-READ the agent exited non-zero" ] && ok "[$sh] a failing agent answers ERR-READ" \
    || no "[$sh] a failing agent left RES '$(cat "$T/roamro.res" 2>/dev/null)'"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); runop "$sh" "$T" 0 0 silent
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
mut "X1 one module name dropped from mediaExitLabels" TestMediaExitsTwoRecordsExactLines report_media_exits.go '\n\t"com\.google\.android\.providers\.media\.module": "media",' ''
mut "X2 user filter removed" TestMediaExitsOtherUserAndGmsDropped $G 'if b\.user != uid \{' 'if false && b.user != uid {'
mut "X3 session-age filter removed" TestMediaExitsOlderThanSessionDropped $G 'if perr != nil \|\| age >= sessionAge \{' 'if perr != nil || (age >= sessionAge && false) {'
mut "X6 handleReportIssue no longer merges the records" TestMediaExitsReportHandlerIsWired report_issue.go '\t// NWP-20261208-06: session scope only[^\n]*\n\tmergeMediaExits\([^\n]*\n' ''
mut "X7 laneFor drops mediaexits" TestMediaExitsLaneAndCap main.go '(case "storagebreakdown"[^\n]*?), "mediaexits"' '\1'

# C1, the control: a comment-only change must SURVIVE (a suite that fails it convicts on noise, not behaviour).
cp "$P/report_media_exits.go" "$W/orig.go"
if apply "$P/report_media_exits.go" '// NWP-20261208-06: why this session' '// NWP-20261208-06 (control): why this session'; then
  res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  survived  C1 a comment-only change (the control)"
  else echo "  FAILED    C1 a comment-only change failed the suite (rc $rc)"; fails=$((fails+1)); fi
else
  echo "  INERT     C1 the control did not apply"; fails=$((fails+1))
fi
cp "$W/orig.go" "$P/report_media_exits.go"

# X4 and X5 run the arm against a copy of roamd, once per shell, and each shell must convict it on its own line.
armmut(){   # armmut <label> <the FAIL line's text after "[<shell>] "> <python-regex> <replacement>
  local label="$1" want="$2" M="$W/roamd.sh" sh res rc
  if cp "$SUT" "$M" && apply "$M" "$3" "$4"; then
    for sh in $SHELLS; do
      res=$(bash "$SELF" --arm "$M" "$sh" 2>&1); rc=$?
      if [ "$rc" -ne 0 ] && [[ "$res" == *"FAIL  [$sh] $want"* ]]; then echo "  convicted $label [$sh]"
      else echo "  SURVIVED  $label [$sh] (rc $rc)"; fails=$((fails+1)); fi
    done
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  rm -f "$M"
}
armmut "X4 the arm asks only the first module" "both media modules were asked" \
  'dumpsys activity exit-info com\.google\.android\.providers\.media\.module </dev/null 2>/dev/null\n(\s*)_mxb=\$\?' '\1_mxb=0'
armmut "X5 the arm's rc ignores the second dumpsys" "dumpsys rc 0 then 4 reaches the agent as nowhere-dump-rc=4" \
  '\n\s*\[ "\$_mxa" != 0 \] \|\| _mxa=\$_mxb' ''
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
