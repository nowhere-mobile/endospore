#!/usr/bin/env bash
# test-bt-reset.sh [<nowhere_roamd.sh>] [--mutate] -- bt_reset's whole truth table, on the host (NWP-20261011-56).
#
# WHY THIS IS COMMITTED. bt_reset is THE AMNESIA CONTROL for Bluetooth: it clears the previous session's bonds,
# its app stores and its device name, and its header promises "Returns 0 ONLY when the device is VERIFIED clear".
# Every way that promise breaks is SILENT on a healthy device:
#   - touching bluedroid's files before the adapter REACHES OFF lets the stack flush its in-memory config back over
#     the wipe, so an adapter stuck in TURNING_OFF must fail the reset, not proceed;
#   - an unreadable adapter state (a denied or absent dumpsys) must fail BEFORE anything is disabled -- reading it
#     as "up" is the bug the tolerant parse in bt_state exists to stop;
#   - a profile's bonds may be re-laid ONLY onto a verified-clean device, else they join somebody else's leftovers;
#   - the device name is SET to the model default, never deleted (NWP-20260902-06: a null name crashes apps).
# The device counterpart is core/vendor-common/prebuilts/test-bt-amnesia.sh (needs adb root and a real adapter);
# this suite runs every branch, including the ones no healthy device ever takes.
#
# The BT variables and functions are extracted from nowhere_roamd.sh BY NAME, never copied, so a stale copy cannot
# keep passing after the real code moves. dumpsys, cmd, settings, getprop, sleep, chown and restorecon are stubbed;
# find, ls, cp and chmod are real, so the wipe, the verify and the restore run against real files.
#
# ⚠ NO `cmd | grep -q` ANYWHERE IN THIS FILE: under pipefail an early-exiting grep -q makes the writer die of SIGPIPE
# and the pipeline FAIL although grep matched. Match against a here-string or a file instead.
#
#   bash test-bt-reset.sh                      # the cases
#   bash test-bt-reset.sh --mutate             # ... plus mutations that must each CONVICT the suite
#   MUTJOBS=4 bash test-bt-reset.sh --mutate   # the same, 4 mutants at a time; verdicts print in order
#
# EVERY SHELL (NWP-20261112-32). The device runs this block under mksh (/system/bin/sh), and the suite used to eval
# it in bash only. mksh evaluates a non-number in `[ $_bad -ge 3 ]` arithmetically, as 0 and silently, where bash
# and dash error, so a counter edit that broke on the device stayed green here. The extracted block, the stubs and
# each case's text are now written into a runner file and run by each of bash, dash, mksh and sh (when sh is not
# one of those) found, every case tagged `[<sh>]`; each shell parses the runner first (`"$sh" -n`). The suite's own
# bookkeeping stays bash. A mutant is convicted only when EVERY shell found has its own `FAIL  [<sh>]` line.
#
# A TIMED-OUT CLEAR AT A RESUME (NWP-20261116-19, decision #57 / dn-1109 #5). bt_reset takes an optional second
# argument, `resume`, which only the btresume arm passes. When the adapter never reaches OFF, a resume turns the
# radio back on and still returns 1; every other caller keeps the radio off. Case k pins the resume exit, case l the
# same timeout without resume, case m a resume whose adapter is already OFF, case n (the btpark/btresume arm,
# extracted by its anchor) that only btresume passes resume. M13-M16 drop the enable, enable on every timeout, and
# move the argument off btresume or onto btpark.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Shells, each run by its own name: bash, dash and mksh where found, then sh unless it is one of those (by realpath).
SHELLS=""; SEEN=" "
for cand in bash dash mksh sh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $cand"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }
# The same shim as test-log-name-scrub.sh's PRINT_SHIM: bash and dash have no `print`; mksh (the device's sh) does.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# The model getprop answers with, and a profile's own name. Neither is a real person's.
MODEL='Test Model 9'
PNAME='Probe Handset'

# --- the stubs, defined AFTER the extracted block in the runner ------------------------------------------------
# dumpsys: pops the next adapter state from $T/states (one per line; an empty line prints nothing = unreadable) and
#          repeats the last once the list runs out. Every call is counted in $T/polls.
# cmd:     appends its args to $T/cmds, and to $T/order with the number of entries left in BT_DIR at that moment.
# settings: appends `put <ns> <key> <val>` to $T/settings; returns 1 when $T/settings_fail exists.
STUBS=$(cat <<'EOS'
dumpsys(){
  local n total s
  n=$(cat "$T/polls" 2>/dev/null); n=$(( ${n:-0} + 1 )); echo "$n" > "$T/polls"
  total=$(wc -l < "$T/states"); [ "$n" -gt "$total" ] && n=$total
  s=$(sed -n "${n}p" "$T/states")
  [ -n "$s" ] && printf '  State: %s\n' "$s"
  return 0
}
cmd(){
  printf '%s\n' "$*" >> "$T/cmds"
  printf '%s left=%s\n' "$*" "$(ls -A "$BT_DIR" 2>/dev/null | wc -l)" >> "$T/order"
}
settings(){
  [ "${1:-}" = put ] || return 0
  shift; [ "${1:-}" = --user ] && shift 2
  printf 'put %s %s %s\n' "$1" "$2" "$3" >> "$T/settings"
  [ -e "$T/settings_fail" ] && return 1
  return 0
}
getprop(){ [ -f "$T/model" ] && cat "$T/model"; return 0; }
sleep(){ :; }
chown(){ :; }
restorecon(){ :; }
EOS
)

FN_NAMES="bt_default_name _bt_state_ok _bt_wait_off bt_reset"
extract_fns() {  # $1 = script -> the BT block, or failure
  local f="$1" out n prog="/^BT_DIR=/p; /^BT_APP_DIRS=/p; /^BT_FILES=/p; /^BT_NAME_KEYS=/p; /^bt_state() { .*; }\$/p;"
  for n in $FN_NAMES; do prog="$prog /^$n() {\$/,/^}\$/p;"; done
  out=$(sed -n "$prog" "$f")
  for n in BT_DIR= BT_APP_DIRS= BT_FILES= BT_NAME_KEYS= 'bt_state() {' $FN_NAMES; do
    case "$n" in *=|*'{') ;; *) n="$n() {" ;; esac
    case "$out" in *"$n"*) ;; *) return 1 ;; esac
  done
  printf '%s\n' "$out"
}
has() {  # has <fixed text> <haystack> -- no pipe, so no SIGPIPE under pipefail
  grep -qF -- "$1" <<<"$2"
}

# suite <script> <shell> [quiet] -> 0 iff every case behaved under <shell>. Own counters, never touches globals.
# FAIL lines print in quiet mode too: they are a mutant's evidence, per shell.
suite() {
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 BLOCK ARM T rc rs n s d pf op
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }

  BLOCK=$(extract_fns "$f") || { [ -n "$quiet" ] || echo "EXTRACTION FAILED -- a BT variable or function moved in $f" >&2; return 2; }
  # The btpark/btresume arm, by its anchor (case n). It must exist and call bt_reset, or the case proves nothing.
  ARM=$(sed -n '/^if \[ "\$op" = "btpark" \] || \[ "\$op" = "btresume" \]; then$/,/^fi$/p' "$f")
  case "$ARM" in *bt_reset*) ;; *) [ -n "$quiet" ] || echo "EXTRACTION FAILED -- the btpark/btresume arm moved in $f" >&2; return 2 ;; esac

  # runner <file> <shell text> [<pre-hook>] -- the file "$sh" runs: the shim, the block, the case's assignments, the
  # stubs, the pre-hook and the text. The text's status lands in $T/rc, BT_RESTORED in $T/restored.
  runner() {
    { printf "T='%s'\n" "$T"
      [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
      printf '%s\n' "$BLOCK"
      printf '%s\n' 'BT_DIR="$T/bluedroid"; BT_APP_DIRS="$T/de/bt $T/ce/bt"; LOG="$T/log"'
      printf '%s\n' "$STUBS"
      printf '%s\n' "${3:-}"
      printf '%s\n' "$2" 'echo $? > "$T/rc"' 'echo "${BT_RESTORED-unset}" > "$T/restored"'
    } > "$1"
  }
  # armrunner <file> <op> -- the btpark/btresume arm with uid 12, bt_seal_capture and bt_reset stubbed; the stub
  # records its arguments as `<$1>|<$2>` in $T/btargs. The arm ends in `exit 0`.
  armrunner() {
    { printf "T='%s'\n" "$T"
      [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
      printf "op='%s'\n" "$2"
      printf '%s\n' 'uid=12; RES="$T/res"; LOG="$T/log"; KS_CREDS="$T/ks"'
      printf '%s\n' 'bt_seal_capture(){ return 0; }'
      printf '%s\n' 'bt_reset(){ printf "%s|%s\n" "${1-}" "${2-}" >> "$T/btargs"; BT_RESTORED=0; return 0; }'
      printf '%s\n' "$ARM"
    } > "$1"
  }
  # The block must PARSE under the shell that runs it, or a mutant would be failed for its syntax. So must the arm.
  pf=$(mktemp -p "$W") || return 2
  T="$W"; runner "$pf" ':'
  "$sh" -n "$pf" 2>/dev/null || { rm -f "$pf"; no "THE BLOCK DOES NOT PARSE under $sh in $f"; return 2; }
  armrunner "$pf" btresume
  "$sh" -n "$pf" 2>/dev/null || { rm -f "$pf"; no "THE BTPARK/BTRESUME ARM DOES NOT PARSE under $sh in $f"; return 2; }
  rm -f "$pf"

  # fresh <state>... -- one temp dir per case: the adapter script, a populated bluedroid, both app dirs, a model.
  fresh() {
    local d
    T=$(mktemp -d -p "$W")
    printf '%s\n' "$@" > "$T/states"
    mkdir -p "$T/bluedroid" "$T/prof/com.nowhere.chooser/files"
    printf '[Adapter]\nAddress = 00:11:22:33:44:55\n[aa:bb:cc:dd:ee:ff]\nLinkKey = stale\n' > "$T/bluedroid/bt_config.conf"
    printf '[aa:bb:cc:dd:ee:ff]\nName = stale\n' > "$T/bluedroid/bt_remote_dev_info.conf"
    printf 'not in BT_FILES\n' > "$T/bluedroid/bt_unenumerated.bin"
    for d in "$T/de/bt" "$T/ce/bt"; do
      mkdir -p "$d/databases" "$d/shared_prefs" "$d/cache" "$d/code_cache"
      : > "$d/databases/bluetooth_opp.db"; : > "$d/shared_prefs/prefs.xml"
    done
    printf '%s' "$MODEL" > "$T/model"
    cp "$T/bluedroid/bt_config.conf" "$T/before.config"
    cp "$T/bluedroid/bt_remote_dev_info.conf" "$T/before.remote"
  }
  # run <shell text> [<pre-hook>] -- the runner under "$sh", a fresh shell as roamd runs it (no -u, no pipefail).
  run() {
    runner "$T/run.sh" "$1" "${2:-}"
    "$sh" "$T/run.sh" >"$T/stdout" 2>&1
    rc=$(cat "$T/rc" 2>/dev/null); rs=$(cat "$T/restored" 2>/dev/null)
  }
  logged() { grep -qF -- "$1" "$T/log" 2>/dev/null; }
  untouched() { cmp -s "$T/before.config" "$T/bluedroid/bt_config.conf" && cmp -s "$T/before.remote" "$T/bluedroid/bt_remote_dev_info.conf"; }
  ncmds() { if [ -f "$T/cmds" ]; then wc -l < "$T/cmds"; else echo 0; fi; }
  done_fx() { rm -rf "$T"; }

  # ---- a. adapter OFF throughout: wipe everything, touch no radio, stamp the model name -------------------
  fresh OFF; run 'bt_reset ""'
  [ "$rc" = 0 ] && ok "a: OFF throughout -> rc 0" || no "a: OFF throughout returned rc $rc"
  if [ -d "$T/bluedroid" ] && [ -z "$(ls -A "$T/bluedroid")" ]; then ok "a: BT_DIR emptied, unenumerated file too, the dir itself kept"
  else no "a: BT_DIR not emptied or removed: $(ls -A "$T/bluedroid" 2>&1 | tr '\n' ' ')"; fi
  has bluetooth_manager "$(cat "$T/cmds" 2>/dev/null)" && no "a: an adapter already OFF was toggled: $(cat "$T/cmds")" \
    || ok "a: an adapter already OFF is never disabled or enabled"
  s=$(cat "$T/settings" 2>/dev/null)
  has "put secure bluetooth_name $MODEL" "$s" && has "put global device_name $MODEL" "$s" \
    && ok "a: both BT_NAME_KEYS set to the model from getprop" || no "a: name keys not set to the model: $s"
  n=0; for d in de ce; do for s in databases shared_prefs cache code_cache; do [ -e "$T/$d/bt/$s" ] && n=$((n+1)); done; done
  [ "$n" = 0 ] && ok "a: databases/shared_prefs/cache/code_cache gone from BOTH app dirs" || no "a: $n app-store dirs survived the wipe"
  done_fx

  # ---- b. ON -> TURNING_OFF -> OFF: one disable before the wipe, one enable after -----------------------
  fresh ON TURNING_OFF OFF; run 'bt_reset ""'
  [ "$rc" = 0 ] && ok "b: ON then OFF reached -> rc 0" || no "b: ON then OFF reached returned rc $rc"
  [ "$(cat "$T/cmds" 2>/dev/null)" = "$(printf 'bluetooth_manager disable\nbluetooth_manager enable')" ] \
    && ok "b: exactly one disable, then exactly one enable" || no "b: radio commands were: $(tr '\n' ';' < "$T/cmds" 2>/dev/null)"
  [ "$(head -n 1 "$T/order" 2>/dev/null)" = "bluetooth_manager disable left=3" ] && [ "$(tail -n 1 "$T/order" 2>/dev/null)" = "bluetooth_manager enable left=0" ] \
    && ok "b: the disable came before the wipe, the enable after it" || no "b: radio/wipe order wrong: $(tr '\n' ';' < "$T/order" 2>/dev/null)"
  done_fx

  # ---- c. ON -> TURNING_OFF forever: never touch the files the stack still owns -------------------------
  fresh ON TURNING_OFF; run 'bt_reset ""'
  [ "$rc" = 1 ] && ok "c: stuck in TURNING_OFF -> rc 1" || no "c: stuck in TURNING_OFF returned rc $rc (files edited under a live stack)"
  [ "$(cat "$T/polls")" = 61 ] && ok "c: gave up after the full 60 polls" || no "c: polled the adapter $(cat "$T/polls") times, want 1 + 60"
  untouched && [ -e "$T/bluedroid/bt_unenumerated.bin" ] && ok "c: config files untouched" || no "c: config files touched before the adapter reached OFF"
  logged 'never reached OFF' && ok "c: the log names 'never reached OFF'" || no "c: no 'never reached OFF' in the log"
  [ "$(cat "$T/cmds" 2>/dev/null)" = "bluetooth_manager disable" ] && ok "c: no resume -> the radio stays off (one disable, no enable)" \
    || no "c: radio commands were: $(tr '\n' ';' < "$T/cmds" 2>/dev/null) (want the disable only)"
  done_fx

  # ---- d. unreadable state at the start: fail BEFORE disabling anything ---------------------------------
  fresh ''; run 'bt_reset ""'
  [ "$rc" = 1 ] && ok "d: unreadable state -> rc 1" || no "d: unreadable state returned rc $rc"
  [ "$(ncmds)" = 0 ] && ok "d: nothing disabled on an unreadable state" || no "d: radio commanded on an unreadable state: $(tr '\n' ';' < "$T/cmds")"
  untouched && ok "d: files untouched" || no "d: files edited although the adapter state was unreadable"
  done_fx

  # ---- e. _bt_wait_off directly ----------------------------------------------------------------------------
  fresh garbage '' 'State?'; run '_bt_wait_off'
  n=$(cat "$T/polls")
  [ "$rc" = 1 ] && [ "$n" -le 3 ] && ok "e: three unreadable states in a row -> 1 after $n polls" \
    || no "e: three unreadable states -> rc $rc after $n polls (want 1 after <= 3)"
  done_fx
  fresh garbage ON garbage garbage OFF; run '_bt_wait_off'
  [ "$rc" = 0 ] && ok "e: a valid state resets the unreadable count (garbage ON garbage garbage OFF -> 0)" \
    || no "e: garbage ON garbage garbage OFF -> rc $rc after $(cat "$T/polls") polls (the count was not reset)"
  done_fx

  # ---- f. bt_default_name ---------------------------------------------------------------------------------
  fresh OFF; rm -f "$T/model"; run 'bt_default_name'
  [ "$(cat "$T/stdout")" = Android ] && ok "f: no model -> exactly 'Android'" || no "f: no model -> '$(cat "$T/stdout")'"
  done_fx
  fresh OFF; run 'bt_default_name'
  [ "$(cat "$T/stdout")" = "$MODEL" ] && ok "f: a model -> the model" || no "f: model -> '$(cat "$T/stdout")'"
  done_fx

  # ---- g. restore onto a verified-clean device ------------------------------------------------------------
  fresh OFF
  printf '[Adapter]\nAddress = 66:77:88:99:aa:bb\n[01:02:03:04:05:06]\nLinkKey = mine\n\001\377' > "$T/prof/com.nowhere.chooser/files/bt-bond-bt_config"
  printf '%s' "$PNAME" > "$T/prof/com.nowhere.chooser/files/bt-name-secure-bluetooth_name"
  run "bt_reset '$T/prof'"
  [ "$rc" = 0 ] && [ "$rs" = 1 ] && ok "g: restore -> rc 0, BT_RESTORED=1" || no "g: restore -> rc $rc, BT_RESTORED=$rs (want 0, 1)"
  cmp -s "$T/prof/com.nowhere.chooser/files/bt-bond-bt_config" "$T/bluedroid/bt_config.conf" \
    && ok "g: restored bt_config.conf is byte-identical" || no "g: restored bt_config.conf differs or is missing"
  [ ! -e "$T/bluedroid/bt_remote_dev_info.conf" ] && ok "g: no artifact -> nothing laid for bt_remote_dev_info.conf" \
    || no "g: bt_remote_dev_info.conf exists with no artifact (the stale one survived?)"
  s=$(cat "$T/settings" 2>/dev/null)
  if [ "$(head -n 1 <<<"$s")" = "put secure bluetooth_name $MODEL" ] \
     && [ "$(tail -n 1 <<<"$s")" = "put secure bluetooth_name $PNAME" ]; then
    ok "g: the profile's name is put AFTER the model default"
  else no "g: the profile's name is missing or not put after the model default: $(tr '\n' ';' <<<"$s")"; fi
  done_fx

  # ---- h. a failed name put: the device is NOT verified clean, so nothing is restored ---------------------
  fresh OFF; : > "$T/settings_fail"
  printf 'mine\n' > "$T/prof/com.nowhere.chooser/files/bt-bond-bt_config"
  printf '%s' "$PNAME" > "$T/prof/com.nowhere.chooser/files/bt-name-secure-bluetooth_name"
  run "bt_reset '$T/prof'"
  [ "$rc" = 1 ] && ok "h: a failed settings put -> rc 1" || no "h: a failed settings put returned rc $rc"
  [ "$rs" = 0 ] && [ ! -e "$T/bluedroid/bt_config.conf" ] && ! has "$PNAME" "$(cat "$T/settings" 2>/dev/null)" \
    && ok "h: nothing restored onto an unverified device" || no "h: restored onto an unverified device (BT_RESTORED=$rs)"
  logged 'could not reset' && ok "h: the log says the name could not be reset" || no "h: no 'could not reset' in the log"
  done_fx

  # ---- i. BT_DIR absent: an unreadable directory is a FAILURE, never a pass -------------------------------
  fresh OFF; run 'bt_reset ""' 'BT_DIR="$T/absent"'
  [ "$rc" = 1 ] && ok "i: absent BT_DIR -> rc 1" || no "i: absent BT_DIR returned rc $rc (an unreadable dir passed as clean)"
  logged 'cannot read' && ok "i: the log says it cannot read the dir" || no "i: no 'cannot read' in the log"
  done_fx

  # ---- j. a leftover survives the wipe -----------------------------------------------------------------------
  fresh OFF
  printf 'mine\n' > "$T/prof/com.nowhere.chooser/files/bt-bond-bt_config"
  run "bt_reset '$T/prof'" 'find(){ :; }'
  [ "$rc" = 1 ] && ok "j: a survivor of the wipe -> rc 1" || no "j: a survivor of the wipe returned rc $rc"
  logged 'survived the wipe' && ok "j: the log says 'survived the wipe'" || no "j: no 'survived the wipe' in the log"
  [ "$rs" = 0 ] && cmp -s "$T/before.config" "$T/bluedroid/bt_config.conf" \
    && ok "j: nothing restored over the leftovers" || no "j: restored over the leftovers (BT_RESTORED=$rs)"
  done_fx

  # ---- k. a resume whose adapter never reaches OFF: the radio is turned back on, the reset still fails ------
  # #57 (dn-1109 #5, NWP-20261116-19): at a resume the device holds only this session's bonds, so the radio the
  # session had on comes back on. The device is NOT cleared, so rc stays 1 and btresume still answers ERR-BT.
  fresh ON TURNING_OFF; run "bt_reset '$T/prof' resume"
  [ "$rc" = 1 ] && ok "k: resume, stuck in TURNING_OFF -> rc 1" || no "k: resume, stuck in TURNING_OFF returned rc $rc"
  [ "$(cat "$T/cmds" 2>/dev/null)" = "$(printf 'bluetooth_manager disable\nbluetooth_manager enable')" ] \
    && ok "k: resume -> one disable, then the radio turned back on" || no "k: resume radio commands were: $(tr '\n' ';' < "$T/cmds" 2>/dev/null) (want disable;enable)"
  logged 'never reached OFF' && logged 'radio turned back on (resume)' \
    && ok "k: the log names 'never reached OFF' and the re-enable" || no "k: the log does not name the timeout and the re-enable: $(cat "$T/log" 2>/dev/null)"
  untouched && [ "$rs" = 0 ] && ok "k: config files untouched, nothing restored" || no "k: files touched or restored (BT_RESTORED=$rs) under a live stack"
  done_fx

  # ---- l. the same timeout without resume (the login and reap shape): the radio stays off ------------------
  fresh ON TURNING_OFF; run "bt_reset '$T/prof'"
  [ "$rc" = 1 ] && ok "l: no resume, stuck in TURNING_OFF -> rc 1" || no "l: no resume, stuck in TURNING_OFF returned rc $rc"
  [ "$(cat "$T/cmds" 2>/dev/null)" = "bluetooth_manager disable" ] && ok "l: no resume -> one disable, no enable" \
    || no "l: no-resume radio commands were: $(tr '\n' ';' < "$T/cmds" 2>/dev/null) (want the disable only)"
  if logged 'turned back on'; then no "l: the log claims a re-enable without resume"; else ok "l: the log claims no re-enable"; fi
  done_fx

  # ---- m. a resume whose adapter is already OFF: the wait is not reached, no radio command ---------------
  fresh OFF; run "bt_reset '$T/prof' resume"
  [ "$rc" = 0 ] && ok "m: resume, adapter OFF -> rc 0" || no "m: resume, adapter OFF returned rc $rc"
  has bluetooth_manager "$(cat "$T/cmds" 2>/dev/null)" && no "m: an adapter already OFF was toggled at resume: $(tr '\n' ';' < "$T/cmds")" \
    || ok "m: resume, adapter OFF -> never disabled or enabled"
  [ "$(cat "$T/polls")" = 1 ] && ok "m: one state read, the wait never reached" || no "m: polled the adapter $(cat "$T/polls") times, want 1"
  done_fx

  # ---- n. the btpark/btresume arm: only btresume passes resume ------------------------------------------------
  for op in btresume btpark; do
    T=$(mktemp -d -p "$W")
    armrunner "$T/arm.sh" "$op"
    "$sh" "$T/arm.sh" >"$T/stdout" 2>&1
    if [ "$op" = btresume ]; then d="/data/user/12|resume"; else d="|"; fi
    [ "$(cat "$T/btargs" 2>/dev/null)" = "$d" ] && ok "n: $op calls bt_reset with exactly '$d'" \
      || no "n: $op called bt_reset with '$(tr '\n' ';' < "$T/btargs" 2>/dev/null)', want '$d'"
    [ "$(cat "$T/res" 2>/dev/null)" = OK ] && ok "n: $op answers OK" || no "n: $op answered '$(cat "$T/res" 2>/dev/null)'"
    done_fx
  done

  [ -n "$quiet" ] || { echo; echo "passed $p, failed $x [$sh]"; }
  [ "$x" = 0 ]
}

echo "== $SUT (shells:$SHELLS)"
SRC=0
for sh in $SHELLS; do suite "$SUT" "$sh"; r=$?; [ "$r" -gt "$SRC" ] && SRC=$r; done
[ "$MUTATE" = yes ] || exit "$SRC"
[ "$SRC" = 0 ] || { echo "the suite fails on the unmutated script -- mutations are meaningless"; exit "$SRC"; }

echo; echo "== mutations (each MUST be convicted) =="
# A mutant that did not apply is not evidence: each is verified non-empty and DIFFERENT first.
apply_mut() {  # $1 dest, $2.. sed args
  local d="$1"; shift
  sed "$@" "$SUT" > "$d" 2>/dev/null || return 1
  [ -s "$d" ] || return 1
  ! cmp -s "$d" "$SUT"
}
# verdict <label> <sed args...> -> one verdict line, then one evidence line per shell. CONVICTED only when every
# shell found failed the mutant on behaviour, with its own `FAIL  [<sh>]` line: rc 0 is SURVIVED, rc 2 (no extract,
# no parse) BROKEN, rc 1 with no line of that shell's UNPROVEN.
verdict() {
  local l="$1" m sh out rc ev all=1 det=""; shift; m=$(mktemp -p "$W")
  if ! apply_mut "$m" "$@"; then
    printf '  NOT APPLIED  %s -- sed failed or changed nothing; NOT a conviction\n' "$l"; rm -f "$m"; return
  fi
  for sh in $SHELLS; do
    out=$(suite "$m" "$sh" quiet 2>&1); rc=$?
    ev=$(grep -F -m 1 -- "  FAIL  [$sh] " <<<"$out")
    if [ "$rc" = 1 ] && [ -n "$ev" ]; then det="$det    [$sh] convicted by:$ev"$'\n'
    else all=0
      case "$rc" in 0) ev=SURVIVED ;; 1) ev="UNPROVEN -- rc 1 with no FAIL line of its own" ;; *) ev="BROKEN (rc=$rc) -- no extract or no parse" ;; esac
      det="$det    [$sh] $ev"$'\n'
    fi
  done
  if [ "$all" = 1 ]; then printf '  CONVICTED  %s\n' "$l"; else printf '  SURVIVED   %s -- not convicted under every shell\n' "$l"; fi
  printf '%s' "$det"
  rm -f "$m"
}
# Sequentially (the default) each verdict prints as it lands; with MUTJOBS > 1 that many run at once and the
# verdicts print in order at the end.
MN=0; MTMP=$(mktemp -d -p "$W")
mutant() {
  MN=$((MN + 1))
  if [ "${MUTJOBS:-1}" -gt 1 ]; then
    while [ "$(jobs -rp | wc -l)" -ge "$MUTJOBS" ]; do command sleep 0.2; done
    verdict "$@" > "$MTMP/$MN.res" &
  else
    verdict "$@" | tee "$MTMP/$MN.res"
  fi
}
mutant "M1: the wipe proceeds although the adapter never reached OFF" \
  -e '/never reached OFF -- device NOT cleared/s/; return 1$//'
mutant "M2: unreadable states tolerated far past 3" \
  -e 's/\$_bad -ge 3/$_bad -ge 99/'
mutant "M3: the restore runs onto an unverified device" \
  -e 's/if \[ "\$_rc" = 0 \] && \[ -n "\$_bd" \]; then/if [ -n "$_bd" ]; then/'
mutant "M4: no model -> an empty name instead of 'Android'" \
  -e 's/_m="Android"/_m=""/'
mutant "M5: no unreadable-state precheck at the top of bt_reset" \
  -e '/^  if ! _bt_state_ok "\$_s"; then$/,/^  fi$/d'
mutant "M6: the wipe deletes BT_DIR itself (no -mindepth 1)" \
  -e 's/find "\$BT_DIR" -mindepth 1 /find "$BT_DIR" /'
mutant "M7: a valid state no longer resets the unreadable count" \
  -e 's/then _bad=0; else/then :; else/'
mutant "M8: a failed name put does not fail the reset" \
  -e '/could not reset \${_f#\*:}/{n;s/_rc=1/:/;}'
mutant "M9: the app stores are not wiped" \
  -e 's/rm -rf "\$_f\/databases" "\$_f\/shared_prefs" "\$_f\/cache" "\$_f\/code_cache"/:/'
mutant "M10: the profile's own name is never restored" \
  -e '/settings put --user 0 "\${_f%%:\*}" "\${_f#\*:}" "\$(cat /s/^ */&: #/'
mutant "M11: the radio is not re-enabled after the reset" \
  -e '/cmd bluetooth_manager enable/s/^ */&: #/'
# M12 (NWP-20261112-32): the count is compared by `[ $_bad -ge 3 ]`; mksh reads `x<n>` there as 0, silently, where
# bash and dash error. Case e's first check must convict it under EVERY shell, mksh included.
mutant "M12: the unreadable-state count is not a number" \
  -e 's/_bad=\$((_bad+1))/_bad=x$((_bad+1))/'
# M13-M16 (NWP-20261116-19, #57 / dn-1109 #5): a resume whose adapter never reaches OFF turns the radio back on;
# every other caller keeps it off, and only the btresume arm passes resume.
mutant "M13: the resume exit no longer turns the radio back on" \
  -e '/#57: at a resume, turn the radio back on/d'
mutant "M14: every timeout turns the radio back on (the resume test removed)" \
  -e 's/if \[ "\${2:-}" = resume \]; then/if :; then/'
mutant "M15: btresume no longer passes resume" \
  -e 's/bt_reset "\/data\/user\/\$uid" resume || _btrc=1/bt_reset "\/data\/user\/$uid" || _btrc=1/'
mutant "M16: btpark passes resume" \
  -e 's/^    bt_reset "" || _btrc=1$/    bt_reset "" resume || _btrc=1/'
wait
if [ "${MUTJOBS:-1}" -gt 1 ]; then i=1; while [ "$i" -le "$MN" ]; do cat "$MTMP/$i.res"; i=$((i + 1)); done; fi
MRC=0
[ "$(cat "$MTMP"/*.res | grep -c '^  CONVICTED  ')" = "$MN" ] || MRC=1
rm -rf "$MTMP"
echo; [ "$MRC" = 0 ] && echo "all $MN mutations convicted" || echo "a mutation SURVIVED or did not apply"
exit $MRC
