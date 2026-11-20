#!/usr/bin/env bash
# test-in-scope-lanes.sh [<nowhere_roamd.sh>] [--mutate] -- the sign-in's #media, #apps code and #keys restores run as
# background lanes beside the #de and #sys restores, and are joined before the verdict (NWP-20261210-03; backlog §B 'A
# nearly empty profile takes about 85 s from submit to home; target under 60 s', cause 1).
#
# WHY THIS IS COMMITTED. The `in)` arm restored the parts one after another: the vault (CE), #de, #sys, #media, #apps code,
# #keys, each its own agent process. Only the vault restore has to run first and alone (the login gate; the #139/#734
# heal). #media writes /data/media/<uid>, #apps user 0's .appcode and #keys keystore-in/<uid>.pre, so none of them waits
# for the CE reown, #de or #sys. The arm now starts them as three lanes (M, A, K) once the vault landed, gives every
# concurrent agent restore a quarter of NOWHERE_DOWNLOAD_WORKERS (one budget), relays each lane's progress file in the old
# order once the foreground chain ends, reads each lane's status back from a file, and decides the verdict in the decided
# precedence de, sys, media, apps, keys. A regression here is silent on a device: a lane that runs serially again costs the
# sign-in its time back; a lane before the vault lands restores for a profile the gate never admitted; a lane writing the
# foreground's progress file makes the bar jump between labels; a status read as 0 lands a sign-in whose scope failed.
#
# The arm is EXTRACTED by anchor, never copied, and re-rooted to a temp tree, with the REAL qn, in_scope_tokens,
# ks_in_dir, acct_restore, keystore_fetch, restore_media_tail and _restore_tail_prog (so the tail's "finishing" lines
# are real). $AGENT is an executable stub, so every agent restore is a real process and
# sees its real environment. Per store ref it appends `start <scope> <ms> W=<NOWHERE_DOWNLOAD_WORKERS> P=<NOWHERE_PROGRESS>`
# and later `end <scope> <ms>` to one event file, writes a progress line `<phase> <n> 2 <scope>`, sleeps and exits per case.
# The helpers the arm calls record `call <name>` in the same file, so the file is in real-time order. The arm's `sleep`
# is 0.05 s, except in the L7 cases, where it is real and an INDEPENDENT reader samples the shared progress file (only
# that file, never a lane's) every 500 ms, as the login daemon does. Cases run under every shell found among bash, sh,
# dash and mksh (the device's /system/bin/sh), each in a CHILD of that shell, which records its identity.
#   L1  all 0: the vault ends before any other start; the #media, #apps and #keys starts precede the #de end, and the #de
#       start precedes their ends (they overlap); reown-de after the #de end; restore_media_tail after the #media end;
#       OK 11; the IN line's tokens are origin/main's `(+de +media)`; one TIMING in-lanes line; no lane file left.
#   L2  every concurrent call's W is 6 with no NOWHERE_DOWNLOAD_WORKERS and 2 with 8; the vault's is the whole budget
#       (empty: the agent's own 24; 8 with 8); a lane's P ends in .<lane>, the foreground's is NOWHERE_PROGRESS.
#   L3  #de 5 and #apps 5: BLANK NET naming de; no .appcode, acct hold, .pre or lane dir left; no landing step; no rescan.
#   L3b #de 5 and #apps 0: as L3, and lane A's restored set is removed by the BLANK NET arm.
#   L4  #keys 5 only: BLANK NET naming keys.
#   L5  #media 1: lands, `!media(rc=1)` as today, no rescan.     L5b no media dir: the media token is `-media`.
#   L6  lane M dies before it writes its status: the missing status file reads as 1 (`!media(rc=1)`), never 0.
#   L7  the labels the shared progress file shows to a 500 ms reader: the foreground's, then media, finishing (the real
#       media tail), appcode, keys; each shows, and never an earlier one after a later one. Three timings: L7 the lanes
#       still run when the foreground ends; L7b every lane ended before the foreground (RF-001: a lane that ended early
#       flashed past unseen); L7c #media still runs while #apps and #keys have ended.
#   L8  the lane dir cannot be made (RF-002): no lane runs; a stale .appcode set and keystore-in/11.pre planted from a
#       previous sign-in are both removed; the sign-in lands with `!media(rc=1)` and logs that no lane started.
#
#   bash test-in-scope-lanes.sh              # the cases
#   bash test-in-scope-lanes.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#   bash test-in-scope-lanes.sh <old roamd>  # L1 fails against origin/main's serial arm
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract or run (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<nowhere_roamd.sh>] [--mutate]" >&2; exit 2 ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
APPCODE_REL=data/user/0/com.nowhere.chooser/files/.appcode
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

# The agent: one process per call. sim/case sets RC_<scope>, SL_<scope> (seconds) and KILL_<scope> (1: kill the caller,
# the lane's subshell, before exiting). Events go to sim/events, in real-time order.
AGENT_SRC='#!/bin/sh
R=$(dirname "$0")
case "$1" in restore) ;; *) exit 1 ;; esac
case "$3" in *"#"*) sc=${3#*#} ;; *) sc=vault ;; esac
. "$R/sim/case"
eval "rc=\${RC_$sc:-0}; sl=\${SL_$sc:-0}; kl=\${KILL_$sc:-}"
ms() { date +%s%3N; }
prog() {
  [ -n "${NOWHERE_PROGRESS:-}" ] || return 0
  printf "%s %s 2 %s\n" "${NOWHERE_PHASE:-data}" "$1" "$sc" > "$NOWHERE_PROGRESS.tmp" && mv -f "$NOWHERE_PROGRESS.tmp" "$NOWHERE_PROGRESS"
}
echo "start $sc $(ms) W=${NOWHERE_DOWNLOAD_WORKERS-} P=${NOWHERE_PROGRESS-}" >> "$R/sim/events"
prog 1
case "$sc" in
  vault) printf "org.example.held\n" > "$R/state/claims.seed" ;;
  apps) mkdir -p "$5/x.app"; : > "$5/x.app/base.apk"; : > "$5/manifest.tsv" ;;
  sys) mkdir -p "$5/ce"; echo rows > "$5/ce/accounts_ce.db" ;;
  keys) : > "$5/x.keys" ;;
esac
sleep "$sl"
prog 2
echo "end $sc $(ms)" >> "$R/sim/events"
[ -n "$kl" ] && kill -9 "$PPID"
exit "$rc"
'

suite() {  # suite <roamd.sh> <shell> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" SH="$2" quiet="${3:-}" p=0 x=0 QN IST KID ACR KSF RTP RMT IN RI R S n PF want vw sc RK _l2w NOID=0 WRONGSH=0 HARN="" HARNN=0 HARN1=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$SH] $l"; else x=$((x+1)); say "  FAIL  [$SH] $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  holds() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
  has_log() { local c; c=$(cat "$1" 2>/dev/null); case "$c" in *"$2"*) return 0 ;; esac; return 1; }
  nolog() { ! has_log "$1" "$2"; }
  # ln_of <regex>: the first line number in sim/events matching it, or 0
  ln_of() { local c; c=$(grep -nE -- "$1" "$R/sim/events" 2>/dev/null | head -n 1 | cut -d: -f1); printf '%s' "${c:-0}"; }
  # before <regex a> <regex b>: both present, a's first line before b's
  before() { local a b; a=$(ln_of "$1"); b=$(ln_of "$2"); [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; }
  ncall() { local c; c=$(grep -cxF -- "call $1" "$R/sim/events" 2>/dev/null); printf '%s' "${c:-0}"; }
  # wof <scope>: the W= value of that scope's start line
  wof() { sed -n "s/^start $1 [0-9]* W=\([^ ]*\) P=.*/\1/p" "$R/sim/events" | head -n 1; }
  pof() { sed -n "s/^start $1 [0-9]* W=[^ ]* P=\(.*\)$/\1/p" "$R/sim/events" | head -n 1; }

  QN=$(fn_of "$f" qn); IST=$(fn_of "$f" in_scope_tokens); KID=$(fn_of "$f" ks_in_dir)
  ACR=$(fn_of "$f" acct_restore); KSF=$(fn_of "$f" keystore_fetch)
  RTP=$(fn_of "$f" _restore_tail_prog); RMT=$(fn_of "$f" restore_media_tail)
  IN=$(arm_of "$f" in)
  for n in QN IST KID ACR KSF RTP RMT; do
    eval "[ -n \"\$$n\" ]" || { echo "EXTRACTION FAILED: a function ($n) not found in $f" >&2; return 2; }
  done
  case "$IN" in *'echo "NEEDKEY" > "$RES"'*'"${name}#de"'*'echo "OK $uid" > "$RES"'*) ;;
    *) echo "EXTRACTION FAILED: the in arm in $f" >&2; return 2 ;; esac
  case "$IN" in *'"${name}#media"'*'"${name}#apps"'*) ;; *) echo "EXTRACTION FAILED: the #media or #apps restore in the in arm of $f" >&2; return 2 ;; esac
  RI=$(reroot "$IN"); ACR=$(reroot "$ACR")
  n=$(printf '%s\n' "$RI" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 5 ] || { echo "RE-ROOT FAILED: the in arm has $n rewritten paths, want >= 5" >&2; return 2; }
  RMT=$(printf '%s\n' "$RMT" | sed '1s/^restore_media_tail() {$/_rmt_real() {/')
  n=$(nleft "$RI$ACR$KSF$RMT$RTP")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) left in live code" >&2; return 2; }

  harness_check() {
    local e
    e=$(grep -m1 -E 'not found|unbound variable|parameter not set|syntax error|Syntax error|bad substitution|Bad substitution' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || { HARN="$HARN [$e]"; HARNN=$((HARNN+1)); [ -n "$HARN1" ] || HARN1="$e"; }
  }
  idcheck() {
    if [ ! -s "$1/sim/shell.id" ]; then NOID=1
    elif ! idok "$SH" "$1/sim/shell.id"; then WRONGSH=1; fi
  }
  # mkrunner <file> <root> <NOWHERE_DOWNLOAD_WORKERS or "-" for unset>
  mkrunner() {
    {
      printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$2/sim/shell.id")"
      printf '%s\n' "$PRINT_SHIM"
      printf 'set -u\n'
      printf 'ROOT=%s; uid=11; op=in; name=prof; pass=pw; keymode=""; srcunit=""; sesec=""\n' "$(sq "$2")"
      if [ "$3" = - ]; then printf 'unset NOWHERE_DOWNLOAD_WORKERS\n'; else printf 'export NOWHERE_DOWNLOAD_WORKERS=%s\n' "$(sq "$3")"; fi
      cat <<'STUB'
LOG="$ROOT/roam.log"; RES="$ROOT/res"; STATE="$ROOT/state"; USERDIR="$ROOT/data/user/$uid"; AGENT="$ROOT/agent"
KS_IN="$ROOT/data/nowhere/keystore-in"
export NOWHERE_PROGRESS="$STATE/roam.progress"   # exported at the head of the script
rec() { printf 'call %s\n' "$*" >> "$ROOT/sim/events"; }
pw() { printf '%s\n' "$ROOT/sim/pw"; }
pwv() { [ -z "$1" ] || pw "$1"; }
_ms() { date +%s%3N; }
_tlog() { printf 'TIMING %s\n' "$1" >> "$ROOT/sim/tlog"; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }
_sum0=0; _sumt=0; _se_v=""; _fh_v=""   # set above the `in` arm in the script
acct_mark_file() { return 1; }
sleep() { if [ -e "$ROOT/sim/realsleep" ]; then command sleep "$1"; else command sleep 0.05; fi; }
for t in usb_host remap_media_db insert_deferred_media remap_tree reown_ext_appdata keystore_push uiderrors_floor_take _ssum; do
  eval "$t() { :; }"
done
for t in relabel_launcher rescan_media ks_signin_reset keystore_restore tz_surface sroam_surface \
         hold_ondemand od_parked_report reap_stale_ondemand reap_orphan_provisioned uiderrors_floor_commit stop_mediad; do
  eval "$t() { rec $t; }"
done
restore_media_tail() { rec restore_media_tail; _rmt_real "$@"; }
remap_per_pkg() { case "$1" in *user_de*) rec remap_per_pkg de ;; *) rec remap_per_pkg ce ;; esac; }
bt_reset() { rec bt_reset; BT_RESTORED=0; return 0; }
restorecon() { :; }
mkdir() { case "$*" in *in-lanes.*) [ -e "$ROOT/sim/nolanedir" ] && return 1 ;; esac; command mkdir "$@"; }
STUB
      printf '%s\n' "$QN" "$IST" "$KID" "$ACR" "$KSF" "$RTP" "$RMT"
      printf 'case "$op" in\n%s\nesac\n' "$RI"
    } > "$1"
  }
  # mkroot <media dir 0|1> <case lines>: the case root; user 11's DE dir, its media dir (1), both chooser files dirs
  mkroot() {
    R=$(mktemp -d -p "$W"); S="$R/state"
    mkdir -p "$R/sim" "$S" "$R/data/nowhere" "$R/data/user/11/com.nowhere.chooser/files" \
      "$R/data/user/0/com.nowhere.chooser/files" "$R/data/system/users/11" "$R/data/user_de/11"
    [ "$1" = 1 ] && mkdir -p "$R/data/media/11"
    : > "$R/sim/events"; : > "$R/sim/seen"
    printf '%s\n' "$2" > "$R/sim/case"
    printf '%s' "$AGENT_SRC" > "$R/agent"; chmod +x "$R/agent"
    return 0
  }
  run_in() {  # run_in [<NOWHERE_DOWNLOAD_WORKERS>]
    mkrunner "$R/sim/run.sh" "$R" "${1:--}"
    "$SH" "$R/sim/run.sh" >/dev/null 2>>"$R/sim/stderr"
    harness_check "$R"
    idcheck "$R"
  }
  lanes_gone() {
    [ -z "$(ls -A "$S" | grep -E '^in-lanes|^roam\.progress\.')" ]
  }
  landed() {
    chk "$1 the reply is OK 11" holds "$R/res" "OK 11"
    chk "$1 the IN line names ($2)" has_log "$R/roam.log" "IN \"prof\" -> user 11 ($2)"
  }
  blank() {
    chk "$1 the reply is exactly BLANK NET" holds "$R/res" "BLANK NET"
    chk "$1 the BLANK NET line names $2" has_log "$R/roam.log" "IN \"prof\" BLANK NET (the $2 restore could not reach the store)"
    chk "$1 no landing step (ks_signin_reset, keystore_restore, stop_mediad)" \
      eval '[ "$(ncall ks_signin_reset)$(ncall keystore_restore)$(ncall stop_mediad)" = 000 ]'
    chk "$1 no rescan" eqv "$(ncall rescan_media)" 0
    chk "$1 no .appcode left" absent "$R/$APPCODE_REL"
    chk "$1 no account hold left" absent "$R/data/nowhere/acct-hold-11"
    chk "$1 no keystore-in/11.pre left" absent "$R/data/nowhere/keystore-in/11.pre"
    chk "$1 no lane dir and no lane progress file left" lanes_gone
  }

  PF=$(mktemp -p "$W") || return 2
  mkrunner "$PF" "$W" -
  if ! "$SH" -n "$PF" 2>/dev/null; then
    command rm -f "$PF"; chk "THE ARM DOES NOT PARSE under $SH" false; return 1
  fi
  command rm -f "$PF"

  say "== L1: all 0 -> the lanes start once the vault landed and overlap #de =="
  mkroot 1 'SL_vault=0.2; SL_de=0.6; SL_sys=0.1; SL_media=0.2; SL_apps=0.2; SL_keys=0.2'; run_in
  chk "L1 the vault ends before any other start" \
    eval '_v=$(ln_of "^end vault "); _o=$(grep -nE "^start (de|sys|media|apps|keys) " "$R/sim/events" | head -n 1 | cut -d: -f1); [ "$_v" -gt 0 ] && [ -n "$_o" ] && [ "$_v" -lt "$_o" ]'
  chk "L1 the #media, #apps and #keys starts precede the #de end" \
    eval 'before "^start media " "^end de " && before "^start apps " "^end de " && before "^start keys " "^end de "'
  chk "L1 the #de start precedes the #media, #apps and #keys ends (they overlap)" \
    eval 'before "^start de " "^end media " && before "^start de " "^end apps " && before "^start de " "^end keys "'
  chk "L1 reown-de after the #de end" before "^end de " "^call remap_per_pkg de$"
  chk "L1 restore_media_tail after the #media end" before "^end media " "^call restore_media_tail$"
  chk "L1 the #sys restore after the #de end" before "^end de " "^start sys "
  landed L1 '+de +media'
  chk "L1 one rescan, after the lanes' join" eqv "$(ncall rescan_media)" 1
  chk "L1 one TIMING in-lanes line" eqv "$(grep -cx 'TIMING in-lanes' "$R/sim/tlog" 2>/dev/null)" 1
  chk "L1 the #apps set stays for the gate" eval '[ -f "$R/$APPCODE_REL/manifest.tsv" ]'
  chk "L1 no lane dir and no lane progress file left" lanes_gone
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"

  say ""
  say "== L2: one download budget; each lane its own progress file =="
  for _l2w in - 8; do
    mkroot 1 'SL_de=0.2; SL_media=0.1'; run_in "$_l2w"
    if [ "$_l2w" = - ]; then want=6; vw=""; else want=2; vw=8; fi
    chk "L2 ($_l2w) the vault's W is the whole budget ('$vw', got '$(wof vault)')" eqv "$(wof vault)" "$vw"
    for sc in de sys media apps keys; do
      chk "L2 ($_l2w) the #$sc restore's W is $want (got '$(wof $sc)')" eqv "$(wof $sc)" "$want"
    done
    chk "L2 ($_l2w) the vault's, #de's and #sys's P is NOWHERE_PROGRESS" \
      eval '[ "$(pof vault)" = "$S/roam.progress" ] && [ "$(pof de)" = "$S/roam.progress" ] && [ "$(pof sys)" = "$S/roam.progress" ]'
    chk "L2 ($_l2w) lane M's P ends in .M, A's in .A, K's in .K" \
      eval '[ "$(pof media)" = "$S/roam.progress.M" ] && [ "$(pof apps)" = "$S/roam.progress.A" ] && [ "$(pof keys)" = "$S/roam.progress.K" ]'
    command rm -rf "$R"
  done
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1

  say ""
  say "== L3: #de 5 and #apps 5 -> BLANK NET (de) =="
  mkroot 1 'RC_de=5; RC_apps=5'; run_in
  blank L3 de
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"
  say "== L3b: #de 5 and #apps 0 -> BLANK NET (de), and lane A's set is removed =="
  mkroot 1 'RC_de=5'; run_in
  blank L3b de
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"

  say ""
  say "== L4: #keys 5 only -> BLANK NET (keys) =="
  mkroot 1 'RC_keys=5'; run_in
  blank L4 keys
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"

  say ""
  say "== L5: #media 1 lands as today, no rescan =="
  mkroot 1 'RC_media=1; SL_de=0.3'; run_in
  landed L5 '+de !media(rc=1)'
  chk "L5 no rescan" eqv "$(ncall rescan_media)" 0
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"
  say "== L5b: no media dir -> the media token is -media =="
  mkroot 0 ''; run_in
  landed L5b '+de -media'
  chk "L5b no #media restore ran" eqv "$(ln_of '^start media ')" 0
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"

  say ""
  say "== L6: lane M dies before its status file: read as 1, never 0 =="
  mkroot 1 'KILL_media=1'; run_in
  landed L6 '+de !media(rc=1)'
  chk "L6 no rescan" eqv "$(ncall rescan_media)" 0
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"

  say ""
  # L7: the labels a 500 ms reader of the SHARED file sees. Rank: vault, de, sys 0; media 1; finishing 2; apps 3; keys 4.
  # l7 <case id> <case lines>
  l7() {
    local id="$1" rp
    mkroot 1 "$2"; : > "$R/sim/realsleep"
    ( while [ ! -e "$R/sim/stop" ]; do
        [ -s "$S/roam.progress" ] && cat "$S/roam.progress" >> "$R/sim/seen" 2>/dev/null
        command sleep 0.5
      done ) &
    rp=$!
    run_in
    : > "$R/sim/stop"; wait "$rp"
    RK=$(awk '{r=0; if ($1=="finishing") r=2; else if ($4=="media") r=1; else if ($4=="apps") r=3; else if ($4=="keys") r=4; printf "%d", r}' "$R/sim/seen")
    chk "$id the reader saw the foreground, then media, finishing, appcode and keys (ranks '$RK')" \
      eval 'case "$RK" in 0*1*2*3*4*) true ;; *) false ;; esac'
    chk "$id never an earlier label after a later one (ranks '$RK')" \
      eval 'printf "%s\n" "$RK" | awk "{for(i=2;i<=length(\$0);i++) if (substr(\$0,i,1) < substr(\$0,i-1,1)) exit 1}"'
    chk "$id each lane's label is its own phase (media, appcode)" \
      eval '[ "$(grep -c "^appcode .* apps$" "$R/sim/seen")" -gt 0 ] && [ "$(grep -c "^media .* media$" "$R/sim/seen")" -gt 0 ]'
    landed "$id" '+de +media'
    chk "$id no lane dir and no lane progress file left" lanes_gone
    command rm -rf "$R"
  }
  say ""
  say "== L7: the lanes still run when the foreground ends; a 500 ms reader sees each label once, in order =="
  l7 L7 'SL_vault=0.6; SL_de=0.1; SL_media=1.0; SL_apps=1.5; SL_keys=2.0'
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  say "== L7b: every lane ended before the foreground; each label still shows =="
  l7 L7b 'SL_vault=0.6; SL_de=1.5; SL_media=0.1; SL_apps=0.1; SL_keys=0.1'
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  say "== L7c: #apps and #keys ended while #media is relayed; each label still shows =="
  l7 L7c 'SL_vault=0.6; SL_de=0.1; SL_media=1.2; SL_apps=0.1; SL_keys=0.1'
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1

  say ""
  say "== L8: the lane dir cannot be made: no lane runs, and a previous sign-in's staging is removed =="
  mkroot 1 ''; : > "$R/sim/nolanedir"
  mkdir -p "$R/$APPCODE_REL/x.app" "$R/data/nowhere/keystore-in/11.pre"
  echo stale > "$R/$APPCODE_REL/manifest.tsv"; : > "$R/data/nowhere/keystore-in/11.pre/x.keys"
  run_in
  landed L8 '+de !media(rc=1)'
  chk "L8 the log says no lane started" has_log "$R/roam.log" "IN restore lanes NOT started: no lane dir (user 11)"
  chk "L8 no lane restore ran (#media, #apps, #keys)" \
    eval '[ "$(ln_of "^start media ")$(ln_of "^start apps ")$(ln_of "^start keys ")" = 000 ]'
  chk "L8 the stale .appcode set is removed" absent "$R/$APPCODE_REL"
  chk "L8 the stale keystore-in/11.pre is removed" absent "$R/data/nowhere/keystore-in/11.pre"
  chk "L8 no lane dir and no lane progress file left" lanes_gone
  [ -n "$quiet" ] && [ "$x" != 0 ] && return 1
  command rm -rf "$R"

  say ""
  chk "the harness ran clean (no undefined function, unbound variable or parse error)" eqv "$HARN" ""
  if [ "$NOID" = 1 ]; then echo "HARNESS ERROR: a runner left no identity: $SH did not launch it" >&2; return 2; fi
  if [ -n "$HARN" ]; then echo "HARNESS ERROR: a runner under $SH failed at run time, in $HARNN case(s); the first: $HARN1" >&2; return 2; fi
  chk "identity: every case ran under $SH" eqv "$WRONGSH" 0
  say "  -- [$SH] $p passed, $x failed"
  [ "$x" = 0 ]
}

echo "the sign-in's restore lanes: $SUT"
echo "shells:$SHELLS"
echo "sh identity: $REF_SH"
rc=0
for s in $SHELLS; do
  suite "$SUT" "$s"; r=$?
  if [ "$r" = 2 ]; then rc=2; elif [ "$r" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
done
if [ "$MUTATE" = no ]; then exit "$rc"; fi
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is one exact-text transform of roamd (python, bytes); one that changes nothing, or matches other than once, is a
# failure of the suite. A mutant is CONVICTED only by a failing check under EACH shell; a harness error never convicts.
mutate_to() {
  python3 - "$1" "$SUT" "$2" <<'PY'
import sys
m, src, dst = sys.argv[1:]
s = open(src).read()
LM = '        } &\n        _mpid=$!\n'
LA = '        } &\n        _apid=$!\n'
LK = '        } &\n        _kpid=$!\n'
VERDICT = ('      if [ "$_derc" = 5 ]; then _innet=de\n'
           '      elif [ "${_acrc:-}" = 5 ]; then _innet=sys\n'
           '      elif [ "$_mdrc" = 5 ]; then _innet=media\n'
           '      elif [ "$_aprc" = 5 ]; then _innet=apps\n'
           '      elif [ "$_ksrc" = 5 ]; then _innet=keys\n')
REVERSED = ('      if [ "$_ksrc" = 5 ]; then _innet=keys\n'
            '      elif [ "$_aprc" = 5 ]; then _innet=apps\n'
            '      elif [ "$_mdrc" = 5 ]; then _innet=media\n'
            '      elif [ "${_acrc:-}" = 5 ]; then _innet=sys\n'
            '      elif [ "$_derc" = 5 ]; then _innet=de\n')
RESCAN = ('      if [ -z "$_innet" ] && [ "$_mdrc" = 0 ]; then\n'
          '        rescan_media "$uid"   # NWP-20261113-45: the provider scanned before this restore; ask it to index what landed\n'
          '      fi\n')
R = {
  'N1': [(LM, '        }\n        _mpid=""\n'), (LA, '        }\n        _apid=""\n'), (LK, '        }\n        _kpid=""\n')],
  'N2': [('    _ceok=""; _innet=""; _cerp=""\n', '    _ceok=""; _innet=""; _cerp=""\n    { keystore_fetch; } >/dev/null 2>&1 &\n')],
  'N3': [('      _inshare=$(( _inw / 4 ))\n', '      _inshare=$_inw\n')],
  'N4': [('          NOWHERE_PROGRESS="${NOWHERE_PROGRESS:+$NOWHERE_PROGRESS.M}"\n', '          :\n')],
  'N5': [(VERDICT, REVERSED)],
  'N6': [('      rm -rf "$APPCODE" "$_inlanes" 2>> "$LOG"\n', '      rm -rf "$_inlanes" 2>> "$LOG"\n')],
  'N7': [('      _mdrc=1; _aprc=1; _ksrc=1\n', '      _mdrc=0; _aprc=0; _ksrc=0\n')],
  'N8': [('      if [ -f "$_inlanes/M" ]; then read -r _mdrc < "$_inlanes/M" || _mdrc=1; fi\n', '')],
  'N9': [(RESCAN, ''), (LM, LM + '        rescan_media "$uid"\n')],
  'N10': [('      for _ln in M T A K; do\n', '      for _ln in M T A K M; do\n')],
  'N11': [('            [ "$_lk" -ge 3 ] && break   # shown for 0.6 s: the daemon has read it\n', '            break\n')],
  'N12': [('          NOWHERE_PROGRESS="${_inpb:+$_inpb.T}"   # the tail\'s "finishing" lines: its own file, read by the join as T\n', '')],
  'N13': [('        rm -rf "$APPCODE" 2>> "$LOG"\n        if _inksd=$(ks_in_dir); then rm -rf "$_inksd.pre" 2>> "$LOG"; fi\n', '')],
  'C1': [('      _inshare=$(( _inw / 4 ))\n', '      # a comment the cases cannot see\n      _inshare=$(( _inw / 4 ))\n')],
}
for a, b in R[m]:
    if s.count(a) != 1:
        sys.exit('%s: an anchor matched %d times (want 1): %r' % (m, s.count(a), a[:80]))
    s = s.replace(a, b, 1)
open(dst, 'w').write(s)
PY
}
MFAIL=0
# mut <id> <want: convict|survive> <description>
mut() {
  local id="$1" want="$2" desc="$3" t s r
  t=$(mktemp -p "$W") || exit 2
  if ! mutate_to "$id" "$t" || cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $id $desc"; MFAIL=1; command rm -f "$t"; return; fi
  for s in $SHELLS; do
    suite "$t" "$s" quiet >/dev/null 2>&1; r=$?
    if [ "$want" = convict ]; then
      if [ "$r" = 1 ]; then echo "  ok    CONVICTED [$s]: $id $desc"
      else echo "  FAIL  NOT CONVICTED [$s] (rc=$r): $id $desc"; MFAIL=1; fi
    else
      if [ "$r" = 0 ]; then echo "  ok    SURVIVED as it must [$s]: $id $desc"
      else echo "  FAIL  the control mutant did not survive [$s] (rc=$r): $id $desc"; MFAIL=1; fi
    fi
  done
  command rm -f "$t"
}
command -v python3 >/dev/null 2>&1 || { echo "FAIL: no python3 on this host -- the mutants did NOT run" >&2; exit 2; }
echo "== mutants (each must CONVICT under every shell found) =="
mut N1 convict "the lanes run in the foreground (L1: no overlap with #de)"
mut N2 convict "a lane starts before the vault lands (L1: the vault does not end before every other start)"
mut N3 convict "the download share is not divided (L2: W is 24, not 6)"
mut N4 convict "lane M writes NOWHERE_PROGRESS (L2: its P is the foreground's)"
mut N5 convict "the verdict's precedence reversed (L3: BLANK NET names apps, not de)"
mut N6 convict "the BLANK NET arm keeps APPCODE (L3b: lane A's set is left)"
mut N7 convict "a missing status file read as 0 (L6: +media for a lane that died)"
mut N8 convict "_mdrc not read back from lane M (L5b: !media(rc=1) for a skip)"
mut N9 convict "the rescan before the join (L5: a rescan after a #media 1)"
mut N10 convict "the relay goes back to lane M after K (L7: media after keys)"
mut N11 convict "the relay does not hold a lane's frame for the daemon's poll (L7b: media, finishing, appcode unseen)"
mut N12 convict "the media tail writes lane M's progress file (L7b: its finishing lines replace the media label)"
mut N13 convict "no lane dir, and the stale staging is kept (L8: the planted .appcode set and .pre are left)"
mut C1 survive "control: a comment line added (must SURVIVE)"
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted, the control survived"
