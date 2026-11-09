#!/usr/bin/env bash
# test-roamd-cause-vocab.sh [--mutate] -- NWP-20261014-67: an agent exit code can never render as a benign seal
# part, and acct_seal's own wait cannot collide with an agent exit code.
#
# WHY THIS IS COMMITTED. roamd's _cause turns an exit code into the per-scope token of a seal verdict
# (" PARTIAL:sys=<cause>"), and it is the ONE vocabulary for two layers: the agent's exit codes and roamd's own
# guards. acct_seal and appcode_seal hand the agent push's exit code straight to it. Since NWP-20261006-21 the
# agent exits 5 (exitStoreUnreachable) when the store cannot be reached -- and 5 was also acct_seal's own
# "restored account not placed yet" wait, mapped to `pending-placement`. The daemon drops that token as benign
# (benignSealParts, decided 2026-10-08), so a #sys or #apps push that lost the network counted as SAVED, and the
# cold-lock re-check wiped a session whose account head was never stored. Nothing failed: the collision is
# between two files in two languages, and no test read both.
#
# So this suite reads both. _cause and acct_seal's pending branch are extracted from nowhere_roamd.sh BY ANCHOR,
# never copied (an anchor that moves stops the suite with EXTRACTION FAILED, exit 2); the agent's exit codes and
# benignSealParts are read out of core/agent's Go source. exit_vocab_test.go pins the same table from the Go side.
# The PATH is run too: acct_seal and appcode_seal whole (by name), under the `out` op's own _note, #sys/#apps call
# sites and OK/PARTIAL emission (by anchor), with a stub agent exiting 5 -- so a re-map of the code anywhere between
# the push and the verdict fails here, not only a wrong table.
#
#   bash test-roamd-cause-vocab.sh            # under bash, sh, and dash and mksh where present (the build VM has both)
#   bash test-roamd-cause-vocab.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure shell: no device, no build. The rewrites: acct_seal's /data/nowhere/ marker path in the pending branch, and
# every /data/ path in the lifted acct_seal / appcode_seal, pointed into a temp root; `$AGENT`, `timeout` and the
# helpers appcode_seal calls are stubs. `print` (a ksh builtin) is shimmed only where the shell has none.
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(dirname "$0")
ROAMD="${ROAMD:-$HERE/nowhere_roamd.sh}"
AGENT_DIR="${AGENT_DIR:-$HERE/../../agent}"
# Temp-root safety FIRST: the lifted seal functions write under a rewritten /data/, and a host that has the real
# device paths is one rewrite slip from touching them. Refuse before anything is extracted or run.
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
for f in "$ROAMD" "$AGENT_DIR/main.go"; do [ -f "$f" ] || { echo "EXTRACTION FAILED: no such file: $f" >&2; exit 2; }; done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction ------------------------------------------------------------------------------------------
CAUSE=$(awk '$0 == "_cause() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
case "$CAUSE" in '_cause() {'*'case "$1" in'*'esac'*'}') ;; *) echo "EXTRACTION FAILED: _cause -- anchors moved" >&2; exit 2 ;; esac
# acct_seal's pending-placement branch: from its `if` on the deferred/hold markers to the `fi` that closes it.
PEND=$(awk '$0 == "acct_seal() {" {a=1} a && /^  if \[ -e "\/data\/nowhere\/acct-deferred-\$uid" \]/ {f=1} f{print} f&&/^  fi$/{exit}' "$ROAMD")
case "$PEND" in *'PENDING-PLACEMENT'*'return '*'  fi') ;; *) echo "EXTRACTION FAILED: acct_seal pending branch -- anchors moved" >&2; exit 2 ;; esac
QN=$(awk '$0 == "qn() {" {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
case "$QN" in 'qn() {'*'}') ;; *) echo "EXTRACTION FAILED: qn -- anchors moved" >&2; exit 2 ;; esac
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# The agent's exit codes, from the Go source: every `const exit<Name> = <n>`, every `os.Exit(<literal>)`.
AGENT_SRC=$(ls "$AGENT_DIR"/*.go 2>/dev/null | grep -v '_test\.go$')
[ -n "$AGENT_SRC" ] || { echo "EXTRACTION FAILED: no agent sources in $AGENT_DIR" >&2; exit 2; }
# shellcheck disable=SC2086
AGENT_CONSTS=$(grep -hoE '^const exit[A-Za-z]+ = [0-9]+$' $AGENT_SRC | awk '{print $4}' | sort -un | tr '\n' ' ')
# shellcheck disable=SC2086
AGENT_LITS=$(grep -hoE 'os\.Exit\([0-9]+\)' $AGENT_SRC | grep -oE '[0-9]+' | sort -un | tr '\n' ' ')
UNREACH=$(grep -hoE '^const exitStoreUnreachable = [0-9]+$' "$AGENT_DIR/main.go" | awk '{print $4}')
NOCREDIT=$(grep -hoE '^const exitNoCredit = [0-9]+$' "$AGENT_DIR/main.go" | awk '{print $4}')
REFUSED=$(grep -hoE '^const exitSealRefused = [0-9]+$' "$AGENT_DIR/main.go" | awk '{print $4}')
STOPPED=$(grep -hoE '^const exitSealStopped = [0-9]+$' "$AGENT_DIR/main.go" | awk '{print $4}')   # NWP-20261117-01 (h47 #1)
[ -n "$UNREACH" ] && [ -n "$NOCREDIT" ] && [ -n "$REFUSED" ] && [ -n "$STOPPED" ] || { echo "EXTRACTION FAILED: agent exit constants -- anchors moved" >&2; exit 2; }
BENIGN_LINE=$(grep -E '^var benignSealParts = map\[string\]bool\{' "$AGENT_DIR/main.go")
[ -n "$BENIGN_LINE" ] || { echo "EXTRACTION FAILED: benignSealParts -- anchor moved" >&2; exit 2; }
BENIGN=$(printf '%s\n' "$BENIGN_LINE" | grep -oE '"[^"]+": true' | sed 's/": true$//; s/^"//' | tr '\n' ' ')
case " $BENIGN " in *" sys=pending-placement "*) ;; *) echo "EXTRACTION FAILED: benignSealParts no longer names sys=pending-placement" >&2; exit 2 ;; esac

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# --- harness ---------------------------------------------------------------------------------------------
# cause_of <shell> <code>: the real _cause, run by that shell.
cause_of(){
  local T; T=$(mktemp -d) && [ -n "$T" ] && [ -d "$T" ] || exit 2
  printf '%s\n_cause "%s"\n' "$CAUSE" "$2" > "$T/run.sh"
  "$1" "$T/run.sh" 2>&1
  rm -rf "$T"
}
# pend_rc <shell> <deferred|hold|none>: run the pending branch with that marker present -> "<rc>|<log line?>".
# The branch is the body of a function that returns 0 if it falls through, which is its real position: acct_seal
# goes on to stage and push when neither marker exists.
pend_rc(){
  local T rc logged=nolog; T=$(mktemp -d) && [ -n "$T" ] && [ -d "$T" ] || exit 2
  case "$2" in deferred) : > "$T/acct-deferred-7" ;; hold) mkdir "$T/acct-hold-7" ;; esac
  {
    printf '%s\n%s\n' "$PRINT_SHIM" "$QN"
    printf 'LOG=%s/log; name=probe\n' "$T"
    printf 'pend() {\n  uid=7\n'
    printf '%s\n' "$PEND" | sed "s#/data/nowhere/#$T/#g"
    printf '  return 0\n}\npend; exit $?\n'
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1; rc=$?
  grep -q 'PENDING-PLACEMENT' "$T/log" 2>/dev/null && logged=logged
  rm -rf "$T"
  echo "$rc|$logged"
}

echo "shells:$SHELLS"
echo "agent exit consts: $AGENT_CONSTS; os.Exit literals: $AGENT_LITS; benign parts: $BENIGN"

echo "== _cause: the table, every shell =="
for s in $SHELLS; do
  bad=0
  for pair in 0:ok 1:failed 2:failed "$NOCREDIT":nocredit "$REFUSED":refused "$UNREACH":unreachable "$STOPPED":stopped \
              6:pending-placement 124:timeout 126:failed 127:failed 137:failed 99:failed; do
    code=${pair%%:*}; want=${pair#*:}
    got=$(cause_of "$s" "$code")
    [ "$got" = "$want" ] || { bad=$((bad+1)); no "$s: _cause $code -> [$got], want [$want]"; }
  done
  [ "$bad" = 0 ] && ok "$s: _cause maps every code as the table says"
done

echo "== acct_seal's pending branch: its own code, mapped to pending-placement, outside the agent's =="
PEND_CODE=""
for s in $SHELLS; do
  d=$(pend_rc "$s" deferred); h=$(pend_rc "$s" hold); n=$(pend_rc "$s" none)
  if [ "${d#*|}" = logged ] && [ "${h#*|}" = logged ] && [ "${d%%|*}" = "${h%%|*}" ]; then
    ok "$s: the deferred and the hold marker each log PENDING-PLACEMENT and return ${d%%|*}"
  else no "$s: deferred -> [$d], hold -> [$h]: want both logged with one code"; fi
  [ "$n" = "0|nolog" ] && ok "$s: with neither marker the branch falls through" || no "$s: with neither marker -> [$n], want 0|nolog"
  c=${d%%|*}
  [ -z "$PEND_CODE" ] && PEND_CODE=$c
  [ "$c" = "$PEND_CODE" ] || no "$s: the pending code is $c here, $PEND_CODE under another shell"
  got=$(cause_of "$s" "$c")
  [ "$got" = pending-placement ] && ok "$s: the pending code ($c) maps to pending-placement" \
    || no "$s: the pending code ($c) maps to [$got], want pending-placement"
done
case " $AGENT_CONSTS $AGENT_LITS 0 124 126 127 137 " in
  *" $PEND_CODE "*) no "the pending code $PEND_CODE is one the agent, timeout or the shell exits with -- an agent failure would read as pending-placement" ;;
  *) ok "the pending code $PEND_CODE is not an agent, timeout or shell exit code" ;;
esac

echo "== no agent exit code renders as a benign seal part =="
for s in $SHELLS; do
  bad=0
  for code in $AGENT_CONSTS $AGENT_LITS 124 137; do
    [ "$code" = 0 ] && continue   # 0 is not a part: the call sites note only a non-zero code
    tok=$(cause_of "$s" "$code")
    for scope in sys apps; do
      case " $BENIGN " in *" $scope=$tok "*) bad=$((bad+1)); no "$s: agent exit $code -> $scope=$tok, which benignSealParts drops (counted as saved)" ;; esac
    done
  done
  [ "$bad" = 0 ] && ok "$s: every agent failure code (consts ${AGENT_CONSTS}literals ${AGENT_LITS}124 137) maps to a part the daemon keeps"
done

echo "== the exit-code PATH: a push that exits 5 reaches the verdict as unreachable, every shell =="
# The table above is only half: acct_seal, appcode_seal and the `out` op's call sites carry the push's code to
# _cause, and any of them could re-map a 5 on the way (`[ "$r" = 5 ] && r=6`) with the table still passing. So
# acct_seal and appcode_seal run WHOLE, lifted by name (with pw and pkgname_ok), with /data/ pointed at a temp root
# and `$AGENT` a stub that exits a chosen code; the `out` op's _note, its #sys/#apps call sites and its OK/PARTIAL
# emission are lifted by anchor and run on top of them. `timeout` is a stub that drops its three arguments
# (`-k 5 <limit>`).
SEALFUNCS=""
for fn in pw pkgname_ok acct_seal stage_apk_copy appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in "$fn() {"*'}') SEALFUNCS="$SEALFUNCS$body
" ;; *) echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;; esac
done
SEALFUNCS=$(printf '%s\n' "$SEALFUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$SEALFUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }
NOTE=$(awk '/^    _note\(\) \{/ {f=1} f{print} f&&/^    \}$/{exit}' "$ROAMD")
case "$NOTE" in '    _note() {'*'    }') ;; *) echo "EXTRACTION FAILED: the out op's _note -- anchors moved" >&2; exit 2 ;; esac
# ONE contiguous block, from the #sys call site through the `fi` that closes the verdict -- the bt arm, the
# OK/PARTIAL emission and the failure verbs included -- so nothing between the call sites and $RES escapes the run.
# NWP-20261117-01 (h47 #1): the block starts at the `_sr=0; _ar=0` before the two call sites, which now sit inside
# `if [ "$stopped" = 0 ]`, and it ends at the line before the arm's `;;`, since its first `    fi` closes the first of
# those. The start is a prefix match, not the whole line: a change appended to it must still extract.
OUTBLK=$(awk 'index($0, "    _sr=0; _ar=0") == 1 {f=1} f&&$0=="    ;;"{exit} f{print}' "$ROAMD")
case "$OUTBLK" in
  '    _sr=0; _ar=0'*'acct_seal "$uid"; _sr=$?'*'appcode_seal; _ar=$?'*'SKIP-STOPPED'*'    elif [ "$rc" = 0 ]; then'*'OK PARTIAL:$parts'*'ERR-PUSH$_sfx'*'    fi') ;;
  *) echo "EXTRACTION FAILED: the out op's block from the #sys call site to its verdict -- anchors moved" >&2; exit 2 ;;
esac

# seal_run <shell> <agent rc> <what: sys|apps|out> [pending|-] [out rc] [skind] -> "<rc or RES>|<agent calls>"
# For `out`, rc is the data scopes' verdict the block branches on (0 = they landed) and skind the seal kind; a
# .btlogoff marker is planted so both bt arms run (bt_reset is a stub).
seal_run(){
  local T; T=$(mktemp -d) && [ -n "$T" ] && [ -d "$T" ] || exit 2
  mkdir -p "$T/data/nowhere" "$T/data/system_ce/7" "$T/data/system_de/7" "$T/state" "$T/user/com.nowhere.chooser/files"
  printf 'CE' > "$T/data/system_ce/7/accounts_ce.db"; printf 'DE' > "$T/data/system_de/7/accounts_de.db"
  printf 'com.example.app\t1\t0\tinstalled\n' > "$T/user/com.nowhere.chooser/files/nowhere-appcode.list"
  [ "${4:-}" = pending ] && : > "$T/data/nowhere/acct-deferred-7"
  : > "$T/calls"
  {
    printf '%s\n%s\n%s\n' "$PRINT_SHIM" "$QN" "$CAUSE"
    printf 'T=%s; STATE=$T/state; LANE=rw; LOG=$T/log; RES=$T/res; USERDIR=$T/user; name=probe; pass=x; uid=7; parts=""\n' "$T"
    printf 'agent_stub(){ echo "$*" >> "$T/calls"; return %s; }; AGENT=agent_stub\n' "$2"
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }; live_code_dir(){ :; }; stage_live_apks(){ :; }; stage_keep_mtimes(){ :; }\n'
    printf 'bt_reset(){ return 0; }; rc=%s; nc=0; refused=0; stopped=0; skind=%s; : > "$STATE/.btlogoff"\n' "${5:-0}" "${6:-periodic}"
    printf '%s\n' "$SEALFUNCS"
    case "$3" in
      sys)  printf 'acct_seal "$uid"; echo "$?" > "$T/res"\n' ;;
      apps) printf 'appcode_seal; echo "$?" > "$T/res"\n' ;;
      out)  printf '%s\n%s\n' "$NOTE" "$OUTBLK" ;;
    esac
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1
  echo "$(cat "$T/res" 2>/dev/null)|$(grep -c . "$T/calls")"
  rm -rf "$T"
}
for s in $SHELLS; do
  got=$(seal_run "$s" "$UNREACH" sys);  c=$(cause_of "$s" "${got%%|*}")
  [ "$got" = "$UNREACH|1" ] && [ "$c" = unreachable ] && ok "$s: acct_seal hands back the #sys push's $UNREACH, which _cause reads as unreachable" \
    || no "$s: acct_seal with the push exiting $UNREACH -> [$got] ($c), want $UNREACH|1 (unreachable)"
  got=$(seal_run "$s" "$UNREACH" apps); c=$(cause_of "$s" "${got%%|*}")
  [ "$got" = "$UNREACH|3" ] && [ "$c" = unreachable ] && ok "$s: appcode_seal hands back the #apps push's $UNREACH after its three tries, read as unreachable" \
    || no "$s: appcode_seal with the push exiting $UNREACH on every try -> [$got] ($c), want $UNREACH|3 (unreachable)"
  for k in logoff periodic; do
    got=$(seal_run "$s" "$UNREACH" out - 0 "$k")
    [ "$got" = "OK PARTIAL:sys=unreachable,apps=unreachable|4" ] && ok "$s: the out op's verdict on a $k seal is OK PARTIAL:sys=unreachable,apps=unreachable" \
      || no "$s: the out op ($k) with both pushes exiting $UNREACH -> [$got], want OK PARTIAL:sys=unreachable,apps=unreachable|4"
  done
  got=$(seal_run "$s" "$UNREACH" out - 1 logoff)
  [ "$got" = "ERR-PUSH PARTIAL:sys=unreachable,apps=unreachable|4" ] && ok "$s: with the data scopes failed too, ERR-PUSH PARTIAL:sys=unreachable,apps=unreachable" \
    || no "$s: the out op (rc=1) with both pushes exiting $UNREACH -> [$got], want ERR-PUSH PARTIAL:sys=unreachable,apps=unreachable|4"
  # Controls: the path passes other codes through as well, and the wait still reads pending-placement.
  got=$(seal_run "$s" 0 out)
  [ "$got" = "OK|2" ] && ok "$s: control: both pushes clean -> a bare OK" || no "$s: control: both pushes exiting 0 -> [$got], want OK|2"
  got=$(seal_run "$s" 1 out)
  [ "$got" = "OK PARTIAL:sys=failed,apps=failed|4" ] && ok "$s: control: exit 1 -> failed on both scopes" || no "$s: control: both pushes exiting 1 -> [$got], want OK PARTIAL:sys=failed,apps=failed|4"
  got=$(seal_run "$s" "$UNREACH" out pending)
  [ "$got" = "OK PARTIAL:sys=pending-placement,apps=unreachable|3" ] && ok "$s: control: an unplaced account still reads pending-placement, and #sys never pushes" \
    || no "$s: control: pending placement, #apps exiting $UNREACH -> [$got], want OK PARTIAL:sys=pending-placement,apps=unreachable|3"
done

if [ "$MUTATE" = yes ]; then
  echo "mutations (each must be convicted -- exit 1, never an extraction failure):"
  MT=$(mktemp -d); trap 'rm -rf "$MT"' EXIT
  mut(){ # mut <label> <roamd|main> <sed script>
    local tr="$ROAMD" ad="$AGENT_DIR" rc
    rm -rf "$MT/agent"; mkdir -p "$MT/agent"; cp "$AGENT_DIR"/*.go "$MT/agent/"
    if [ "$2" = roamd ]; then sed -e "$3" "$ROAMD" > "$MT/roamd.sh"; tr="$MT/roamd.sh"; cmp -s "$ROAMD" "$tr" && { no "MUTANT DID NOT APPLY: $1"; return; }
    else sed -e "$3" "$AGENT_DIR/main.go" > "$MT/agent/main.go"; cmp -s "$AGENT_DIR/main.go" "$MT/agent/main.go" && { no "MUTANT DID NOT APPLY: $1"; return; }; fi
    ad="$MT/agent"
    ROAMD="$tr" AGENT_DIR="$ad" bash "$0" > "$MT/out" 2>&1; rc=$?
    case $rc in 1) ok "convicted: $1" ;; 0) no "SURVIVED: $1" ;; *) no "NOT CONVICTED (rc $rc, extraction?): $1"; sed 's/^/      /' "$MT/out" | tail -3 ;; esac
  }
  mut "_cause maps 5 to pending-placement again"   roamd 's/^    5)   echo unreachable ;;.*/    5)   echo pending-placement ;;/'
  mut "acct_seal's wait returns 5 again"           roamd 's/^    return 6$/    return 5/'
  mut "the pending code mapped to failed"          roamd 's/^    6)   echo pending-placement ;;/    6)   echo failed ;;/'
  mut "unreachable added to benignSealParts"       main  's/^var benignSealParts = map\[string\]bool{"sys=pending-placement": true}$/var benignSealParts = map[string]bool{"sys=pending-placement": true, "sys=unreachable": true}/'
  mut "the agent takes 6 for exitStoreUnreachable" main  's/^const exitStoreUnreachable = 5$/const exitStoreUnreachable = 6/'
  mut "the #sys call site drops _cause"            roamd 's/_note sys "\$(_cause "\$_sr")"/_note sys failed/'
  mut "acct_seal re-maps the push's 5 to 6"        roamd 's/^  return "\$r"$/  [ "$r" = 5 ] \&\& r=6; return "$r"/'
  mut "the #sys call site re-maps 5 to 6"          roamd 's/^      acct_seal "\$uid"; _sr=\$?$/      acct_seal "$uid"; _sr=$?; [ "$_sr" = 5 ] \&\& _sr=6/'
  mut "appcode_seal re-maps the push's 5 to 6"     roamd 's/^  return "\$ret"$/  [ "$ret" = 5 ] \&\& ret=6; return "$ret"/'
  mut "parts re-mapped after the #apps call site"  roamd 's/^\(      \[ "\$_ar" = 0 \] || _note apps "\$(_cause "\$_ar")"\)$/\1\n      parts=$(printf "%s" "$parts" | sed "s|=unreachable|=pending-placement|g")/'
  mut "_cause maps 7 to failed (no stopped arm)"   roamd '/^    7)   echo stopped ;;/d'
  mut "a logoff-only re-map in the emission"       roamd 's/^        echo "OK PARTIAL:\$parts" > "\$RES"$/        [ "$skind" = logoff ] \&\& parts=$(printf "%s" "$parts" | sed "s|=unreachable|=pending-placement|g")\n&/'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
