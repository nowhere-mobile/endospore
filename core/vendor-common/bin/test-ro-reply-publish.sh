#!/usr/bin/env bash
# test-ro-reply-publish.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's RO-lane `sealdelta` and `storagebreakdown`
# arms publish their reply only by rename (NWP-20261024-17).
#
# WHY. runWorkerHeld's poll returns the FIRST non-empty content it sees and removes $RES the moment it has read
# it; the next RO op on the lane then takes the slot at once. An arm that wrote $RES in place and re-tested it
# (`[ -s "$RES" ] || echo ERR-WALK > "$RES"`) could find $RES already consumed and write a stale ERR-WALK that
# the queued op read as its own reply. The uiderrors arm renames $RES.part onto $RES; these two must too.
#
# Each arm is extracted from nowhere_roamd.sh BY ANCHOR (its label to the first `    ;;`), never copied, and run
# under every shell present (bash, sh, dash, mksh) against a stub $AGENT.
#
#   bash test-ro-reply-publish.sh            # the behaviour cases
#   bash test-ro-reply-publish.sh --mutate   # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

ARMS="sealdelta storagebreakdown"

# --- extraction -----------------------------------------------------------------------------------------
# extract <script> <label> <out>: the arm's body (label line and closing `;;` excluded) into <out>.
extract(){
  awk -v lab="  $2)" '
    $0 == lab { on = 1; next }
    on && $0 == "    ;;" { done = 1; exit }
    on { print }
    END { exit done ? 0 : 1 }' "$1" > "$3"
}
for arm in $ARMS; do
  extract "$SUT" "$arm" "$W/arm.$arm" || { echo "EXTRACTION FAILED: arm $arm not found" >&2; exit 2; }
  [ -s "$W/arm.$arm" ] || { echo "EXTRACTION FAILED: arm $arm is empty" >&2; exit 2; }
  bash -n "$W/arm.$arm" 2>/dev/null || { echo "EXTRACTION FAILED: arm $arm does not parse" >&2; exit 2; }
  case "$(cat "$W/arm.$arm")" in *'"$AGENT"'*) ;; *) echo "EXTRACTION FAILED: arm $arm has no agent call" >&2; exit 2 ;; esac
done

# --- harness --------------------------------------------------------------------------------------------
# The stub agent: behaviour chosen by $AGENT_MODE.
cat > "$W/agent" <<'STUB'
#!/bin/sh
case "$AGENT_MODE" in
  ok)      printf '%s\n' '{"x":1}' ;;
  partial) printf '%s' '{"x"'; exit 1 ;;
  empty)   : ;;
  race)    printf '%s\n' '{"x":1}'; rm -f "$RES" ;;   # what the daemon's poll does after reading
esac
exit 0
STUB
chmod +x "$W/agent"

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# runarm <shell> <armfile> <mode>: runs the arm; leaves the reply in $W/res.
runarm(){
  rm -f "$W/res" "$W/res.part"; : > "$W/log"
  { printf 'AGENT=%s\nLOG=%s\nRES=%s\nuid=10\nsrcunit=0\n%s RES\n' "$W/agent" "$W/log" "$W/res" "ex""port"
    cat "$2"; } > "$W/run.sh"
  AGENT_MODE="$3" "$1" "$W/run.sh" >/dev/null 2>&1
}
reply(){ if [ -e "$W/res" ]; then cat "$W/res"; else echo "<absent>"; fi; }
want(){   # want <label> <expected reply>
  local got; got=$(reply)
  if [ "$got" = "$2" ]; then ok "$1"; else no "$1 -- got [$got], want [$2]"; fi
}

# cases <armname> <armfile> <shell>
cases(){
  local arm="$1" f="$2" sh="$3" part
  runarm "$sh" "$f" ok;      want "$arm/$sh (1) agent JSON is the reply" '{"x":1}'
  part=no; [ -e "$W/res.part" ] && part=yes
  [ "$part" = no ] && ok "$arm/$sh (1) no .part left" || no "$arm/$sh (1) .part left behind"
  runarm "$sh" "$f" partial; want "$arm/$sh (2) failed agent -> ERR-WALK, never the partial JSON" 'ERR-WALK'
  runarm "$sh" "$f" empty;   want "$arm/$sh (3) silent agent -> ERR-WALK" 'ERR-WALK'
  runarm "$sh" "$f" race;    want "$arm/$sh (4) reply taken mid-arm is never followed by a stale ERR-WALK" '{"x":1}'
}

# pin <armname> <armfile>: (5) the source pin.
pin(){
  local arm="$1" f="$2" inplace mvs
  inplace=$(grep -cE '>>? *"\$RES"' "$f")
  [ "$inplace" = 0 ] && ok "$arm (5) no in-place write of \$RES" || no "$arm (5) $inplace in-place write(s) of \$RES"
  mvs=$(grep -cF 'mv -f "$RES.part" "$RES"' "$f")
  [ "$mvs" = 1 ] && ok "$arm (5) exactly one rename onto \$RES" || no "$arm (5) $mvs rename(s) onto \$RES"
}

for arm in $ARMS; do
  echo "== $arm =="
  for sh in $SHELLS; do cases "$arm" "$W/arm.$arm" "$sh"; done
  pin "$arm" "$W/arm.$arm"
done

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ] || exit 1

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo; echo "== mutants (each must be CONVICTED) =="
  SEALW='sealdeltawalk "$uid" "$srcunit" > "$RES.part"'
  STORW='storagebreakdown "$uid" > "$RES.part"'
  EMPTYFB='[ -s "$RES.part" ] || echo "ERR-WALK" > "$RES.part"'
  NZ=' || echo "ERR-WALK" > "$RES.part"'
  conv=0; bad=0
  # mutant <name> <arm> <from> <to> [<to>]: apply to a copy of the arm; INERT or unparseable is a failure.
  mutant(){
    local name="$1" arm="$2" from="$3" to="$4" body mf="$W/mut.$1" before sh
    body=$(cat "$W/arm.$arm")
    case "$body" in *"$from"*) ;; *) echo "  FAIL  $name -- anchor not found"; bad=$((bad+1)); return ;; esac
    printf '%s\n' "${body/"$from"/"$to"}" > "$mf"
    if cmp -s "$mf" "$W/arm.$arm"; then echo "  FAIL  $name -- INERT"; bad=$((bad+1)); return; fi
    bash -n "$mf" 2>/dev/null || { echo "  FAIL  $name -- mutant does not parse"; bad=$((bad+1)); return; }
    before=$FAIL
    for sh in $SHELLS; do cases "$arm" "$mf" "$sh" >/dev/null; done
    pin "$arm" "$mf" >/dev/null
    if [ "$FAIL" -gt "$before" ]; then echo "  ok    $name convicted ($((FAIL-before)) failing checks)"; conv=$((conv+1))
    else echo "  FAIL  $name SURVIVED"; bad=$((bad+1)); fi
  }
  mutant R1 sealdelta "$SEALW" 'sealdeltawalk "$uid" "$srcunit" > "$RES"'
  mutant R2 storagebreakdown "$EMPTYFB" '[ -s "$RES" ] || echo "ERR-WALK" > "$RES"'
  mutant R3a sealdelta "${SEALW} 2>>\"\$LOG\"${NZ}" "${SEALW} 2>>\"\$LOG\""
  mutant R3b storagebreakdown "${STORW} 2>>\"\$LOG\"${NZ}" "${STORW} 2>>\"\$LOG\""
  echo "mutants convicted: $conv, not convicted: $bad"
  [ "$bad" = 0 ] && [ "$conv" = 4 ] || exit 1
fi
exit 0
