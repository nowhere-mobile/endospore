#!/usr/bin/env bash
# test-gms-state.sh [--mutate] -- the issue report's Play services evidence (NWP-20261201-01): report_gms_test.go, and
# roamd's `gmsstate)` arm run for real under every shell found (bash, sh, dash, mksh; mksh is the device's /system/bin/sh).
# --mutate re-runs against a COPY with each part broken in turn. Each mutant names the assertion that must convict it:
# a Go mutant needs that test's `--- FAIL`, an arm mutant needs that FAIL line under EACH shell on its own. A mutant that
# fails to apply, or to compile, counts as a failure.
#
#   bash test-gms-state.sh                                    # the Go tests, then the arm under every shell
#   bash test-gms-state.sh --mutate                           # ... plus the mutations
#   bash test-gms-state.sh --arm-only --shell <s> --roamd <f> # the arm cases only (the mutant runner's per-shell runs)
set -uo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
cd "$(dirname "$0")"
. ./suite-report.sh

MUTATE=no; ARM_ONLY=no; ONLY=""; SUT=../vendor-common/bin/nowhere_roamd.sh; _next=""
for a in "$@"; do
  case "$_next" in
    shell) ONLY="$a"; _next=""; continue ;;
    roamd) SUT="$a"; _next=""; continue ;;
  esac
  case "$a" in
    --mutate) MUTATE=yes ;;
    --arm-only) ARM_ONLY=yes ;;
    --shell) _next=shell ;;
    --roamd) _next=roamd ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
[ -z "$_next" ] || { echo "--$_next needs a value" >&2; exit 2; }
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
if [ -n "$ONLY" ]; then
  command -v "$ONLY" >/dev/null 2>&1 || { echo "no such shell: $ONLY" >&2; exit 2; }
  SHELLS=" $ONLY"
fi

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

RUN=(go test -count=1 -run '^TestGmsState|TrimOrder|Lane' .)
if [ "$ARM_ONLY" = no ]; then
  out=$("${RUN[@]}" 2>&1); rc=$?
  report_plain_run "$rc" "$out" || exit 1
fi

# --- the arm, extracted BY ANCHOR, never copied ---------------------------------------------------------------
OP=$(sed -n '/^  gmsstate)$/,/^    ;;$/p' "$SUT" | sed '1d;$d')
case "$OP" in *'"$AGENT" gmsstate "$uid"'*) ;; *) echo "EXTRACTION FAILED: the gmsstate) op" >&2; exit 2 ;; esac

# Modes are asserted only where the filesystem keeps them (the same probe as test-uiderrors-op.sh).
P=$(mktemp -d -p "$W"); : > "$P/f"; chmod 600 "$P/f" 2>/dev/null
MODES=no; [ "$(stat -c %a "$P/f" 2>/dev/null)" = 600 ] && MODES=yes; rm -rf "$P"
mode600(){ [ "$MODES" = no ] || [ "$(stat -c %a "$1" 2>/dev/null)" = 600 ]; }

LONGHEAD=$(printf 'ERR-READ %0200d' 7)
# stubs <dir> <agent ok|fail|empty|long> <dump rc>: a fake dumpsys with a stderr marker, and a fake agent that records
# its argv and stdin, and notes whether $RES already existed while it was still writing.
stubs(){
  mkdir -p "$1/bin"
  cat > "$1/bin/dumpsys" <<EOF
#!/usr/bin/env bash
echo "DUMPSYS-STDERR-MARKER" >&2
echo "dump of \$*"
exit $3
EOF
  chmod +x "$1/bin/dumpsys"
  cat > "$1/agent" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$#" "\$1" "\$2" > "$1/args"
cat > "$1/stdin"
[ -e "$1/roamro.res" ] && : > "$1/partial"
case "$2" in
  fail) exit 1 ;;
  empty) exit 0 ;;
  long) echo "$LONGHEAD" ;;
  *) printf 'OK 2\ngms_main_adj=1\n--\nexcerpt line\n' ;;
esac
EOF
  chmod +x "$1/agent"
}
# RACE=yes makes every mv remove its destination the moment it lands: the daemon's poller winning the race. POSIX sh only.
RACE=no
runop(){ # runop <shell> <dir> <agent> <dump rc>
  local sh="$1" T="$2"
  stubs "$T" "$3" "$4"
  { printf 'STATE=%s\nLOG=%s\nRES=%s\nAGENT=%s\nuid=10\nPATH=%s:$PATH\nexport PATH\n' "$T" "$T/log" "$T/roamro.res" "$T/agent" "$T/bin"
    if [ "$RACE" = yes ]; then
      printf '%s\n' 'mv(){ for _a in "$@"; do _dst=$_a; done; command mv "$@" || return' \
        "  cp -f \"\$_dst\" '$T/polled' 2>/dev/null; rm -f \"\$_dst\"; }"
    fi
    printf '%s\n' "$OP"; } > "$T/op.sh"
  "$sh" "$T/op.sh" >/dev/null 2>&1
}

arm_cases(){ # arm_cases <shell>
  local sh="$1" T LOGTXT IN
  echo "== [$sh] the arm pipes both dumps to the agent and publishes by rename =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" ok 0
  [ "$(cat "$T/args" 2>/dev/null)" = "2|gmsstate|10" ] && ok "[$sh] A1 the agent gets gmsstate and the uid" \
    || no "[$sh] A1 agent argv was '$(cat "$T/args" 2>/dev/null)'"
  IN=$(cat "$T/stdin" 2>/dev/null)
  case "$IN" in
    "== processes"*"dump of activity processes com.google.android.gms"*"nowhere-dump-rc=0"*"== oom"*"dump of activity oom"*"nowhere-dump-rc=0"*)
      ok "[$sh] A2 stdin holds both dumps, each with its rc line, in order" ;;
    *) no "[$sh] A2 stdin was '$IN'" ;;
  esac
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "$(printf 'OK 2\ngms_main_adj=1\n--\nexcerpt line')" ] && ok "[$sh] A3 the whole reply lands in RES" \
    || no "[$sh] A3 RES holds '$(cat "$T/roamro.res" 2>/dev/null)'"
  [ ! -e "$T/partial" ] && ok "[$sh] A4 RES did not exist while the agent was writing" || no "[$sh] A4 RES existed mid-write"
  [ ! -e "$T/roamro.res.part" ] && ok "[$sh] A5 no .part left behind" || no "[$sh] A5 .part left behind"
  mode600 "$T/roamro.res" && ok "[$sh] A6 RES is 600 (modes checked: $MODES)" || no "[$sh] A6 RES mode is $(stat -c %a "$T/roamro.res" 2>/dev/null)"
  LOGTXT=$(cat "$T/log" 2>/dev/null)
  case "$LOGTXT" in
    *DUMPSYS-STDERR-MARKER*) no "[$sh] A7 a dumpsys stderr reached \$LOG (a binder dump redirected to \$LOG fails on the device)" ;;
    *) ok "[$sh] A7 no dumpsys stderr in \$LOG" ;;
  esac
  case "$LOGTXT" in "[roamd] gmsstate -> OK 2 "*) ok "[$sh] A8 the log line carries the reply's first line" ;;
    *) no "[$sh] A8 log reads '$LOGTXT'" ;; esac
  rm -rf "$T"

  echo "== [$sh] a failed dump is visible to the agent =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" ok 3
  IN=$(cat "$T/stdin" 2>/dev/null)
  case "$IN" in *"nowhere-dump-rc=3"*"== oom"*"nowhere-dump-rc=3"*) ok "[$sh] B1 each dump's exit status follows it" ;;
    *) no "[$sh] B1 stdin was '$IN'" ;; esac
  rm -rf "$T"

  echo "== [$sh] an agent that fails or prints nothing still answers, as an error =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" fail 0
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "ERR-READ the agent exited non-zero" ] && ok "[$sh] C1 a failing agent answers ERR-READ" \
    || no "[$sh] C1 RES holds '$(cat "$T/roamro.res" 2>/dev/null)'"
  rm -rf "$T"
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" empty 0
  [ "$(cat "$T/roamro.res" 2>/dev/null)" = "ERR-READ the agent printed nothing" ] && ok "[$sh] C2 an empty agent answers ERR-READ" \
    || no "[$sh] C2 RES holds '$(cat "$T/roamro.res" 2>/dev/null)'"
  rm -rf "$T"

  echo "== [$sh] the log line =="
  T=$(mktemp -d -p "$W"); runop "$sh" "$T" long 0
  LOGTXT=$(cat "$T/log" 2>/dev/null)
  case "$LOGTXT" in "[roamd] gmsstate -> ${LONGHEAD:0:160} "*) ok "[$sh] D1 the log line's reply is cut to 160 characters" ;;
    *) no "[$sh] D1 log reads '$LOGTXT'" ;; esac
  rm -rf "$T"
  T=$(mktemp -d -p "$W"); RACE=yes; runop "$sh" "$T" ok 0; RACE=no
  [ -e "$T/polled" ] && [ ! -e "$T/roamro.res" ] && ok "[$sh] D2 the poller got the reply and removed RES (the race happened)" \
    || no "[$sh] D2 race harness did not fire"
  LOGTXT=$(cat "$T/log" 2>/dev/null)
  case "$LOGTXT" in *"[roamd] gmsstate -> OK 2 "*) ok "[$sh] D3 the log carries the reply though RES is gone" ;;
    *) no "[$sh] D3 race: log reads '$LOGTXT'" ;; esac
  rm -rf "$T"
}

for s in $SHELLS; do arm_cases "$s"; done
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$MUTATE" = yes ] || exit 0

# --- mutations ------------------------------------------------------------------------------------------------
echo "== mutations (each MUST be convicted by the assertion it names) =="
P="$W/pkg"; mkdir -p "$P" "$W/vendor-common/bin" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ && cp ../vendor-common/bin/nowhere_roamd.sh "$W/vendor-common/bin/" || exit 2
SUB=$(mktemp -p "$W") || exit 2
cat > "$SUB" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
fails=0
# mut <label> <file> <python-regex> <replacement> <the Go test that must fail>
mut(){
  local label="$1" f="$2" pat="$3" rep="$4" test="$5" res
  cp "$P/$f" "$W/orig.go"
  if python3 "$SUB" "$P/$f" "$pat" "$rep"; then
    res=$(cd "$P" && "${RUN[@]}" 2>&1)
    if [[ "$res" == *'[build failed]'* || "$res" == *'[setup failed]'* ]]; then echo "  BROKEN    $label -- did not compile"; fails=$((fails+1))
    elif [[ "$res" == *"--- FAIL: $test"* ]]; then echo "  convicted $label by $test"
    else echo "  SURVIVED  $label (no --- FAIL: $test)"; fails=$((fails+1)); fi
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
mut "M1 the user filter is removed" report_gms.go 'if user != uid \{\n\t\treturn ""\n\t\}\n' '' TestGmsStateOtherUsersAndAppsIgnored
mut "M2 frozen is forced to no" report_gms.go 'if m\[1\] == "true" \{\n\t\t\t\treturn "yes", true' 'if m[1] == "true" {\n\t\t\t\treturn "no", true' TestGmsStateFrozenSession
mut "M3 held_by is always gmscompat" report_gms.go 'func gmsHeldBy\(block \[\]string\) \(string, bool\) \{\n' 'func gmsHeldBy(block []string) (string, bool) {\n\treturn "gmscompat", true\n' TestGmsStateFrozenSession
mut "M4 unparsed becomes 0" report_gms.go 'gmsWordUnparsed = "unparsed"' 'gmsWordUnparsed = "0"' TestGmsStateMissingOrMalformedFieldIsUnparsed
mut "M5 the deviceScope guard is removed" report_gms.go 'if deviceScope \{\n\t\treturn\n\t\}\n' '' TestGmsStateDeviceScopeCarriesNothing
mut "M6 the <app> rewrite is removed" report_gms.go 'return "<app>"' 'return side' TestGmsStateAdjSourceRewritten
mut "M7 the rc check is removed" report_gms.go 'return rc == "0"' 'return rc == "0" || true' TestGmsStateUnreadDump
mut "M8 laneFor drops gmsstate" main.go 'case "gmsstate":\n\t\t// NWP-20261201-01: two read-only activity-manager dumps for an issue report\. Its own arm.*?return laneRO\n\t' '' TestGmsStateRidesTheReadOnlyLane

ROAMD_COPY="$W/mutant_roamd.sh"
# mutarm <label> <python-regex> <replacement> <the assertion's id>: convicted only by that FAIL line, under EACH shell
mutarm(){
  local label="$1" pat="$2" rep="$3" id="$4" sh res rc bad=""
  cp "$SUT" "$ROAMD_COPY"
  if ! python3 "$SUB" "$ROAMD_COPY" "$pat" "$rep"; then
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return
  fi
  for sh in $SHELLS; do
    res=$(bash "$SELF" --arm-only --shell "$sh" --roamd "$ROAMD_COPY" 2>&1); rc=$?
    if [ "$rc" -ne 1 ] || [[ "$res" != *"FAIL  [$sh] $id"* ]]; then bad="$bad $sh"; fi
  done
  if [ -z "$bad" ]; then echo "  convicted $label by $id under$SHELLS"
  else echo "  SURVIVED  $label (no FAIL $id under:$bad)"; fails=$((fails+1)); fi
}
mutarm "M9 the arm's dumpsys stderr goes to \$LOG" \
  'dumpsys activity oom </dev/null 2>/dev/null;' 'dumpsys activity oom </dev/null 2>>"$LOG";' A7
mutarm "M10 the arm reads \$RES after the mv" \
  '_gmh=\$\(head -n 1 "\$RES\.part" 2>/dev/null \| cut -c1-160\)\n    mv -f "\$RES\.part" "\$RES" 2>>"\$LOG"\n' \
  'mv -f "$RES.part" "$RES" 2>>"$LOG"\n    _gmh=$(head -n 1 "$RES" 2>/dev/null | cut -c1-160)\n' D3
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
