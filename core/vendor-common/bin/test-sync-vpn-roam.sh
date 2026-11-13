#!/usr/bin/env bash
# test-sync-vpn-roam.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's half of the account-sync roam and the always-on VPN
# choice roam (NWP-20261010-15; docs/product-decisions.md, 2026-10-10, both entries). The helpers' half is
# test-roam-helpers-java.sh.
#
# WHY THIS IS COMMITTED. Both carries are capture-at-seal, apply-at-sign-in, and every way they break is SILENT:
#   - an apply that runs BEFORE acct_reload sets switches on accounts that do not exist yet, which SyncManager's
#     stale-account sweep deletes -- the log says "applied" and Gmail still says sync is off;
#   - a capture that runs before this session's apply records the fresh user's EMPTY state over the profile's
#     record, and every later sign-in starts with sync off and no VPN -- one periodic seal is enough;
#   - a switch the framework cannot take yet (its app or authenticator absent) must be kept PENDING and retried, not
#     failed and not dropped;
#   - vpnup re-arming the block at once (lockdown=1) brings back the 2026-09-25 trap; applying a carried OFF as
#     anything but an explicit off lets the deferred block re-arm it;
#   - a capture and its pend lines hold ACCOUNT NAMES, and roam.log lives on plain /data where the next profile
#     reads it (#39).
# None of that is visible on a healthy device, so it is pinned here.
#
# The functions and op arms are extracted from nowhere_roamd.sh BY ANCHOR, never copied, so a stale copy cannot keep
# passing after the real code moves. app_process, timeout, settings, cmd and am are stubbed; the app_process stub plays
# the framework (it writes the settings the real call would) so the read-back paths run for real.
#
# ⚠ NO `cmd | grep -q` ANYWHERE IN THIS FILE: under pipefail an early-exiting grep -q makes the writer die of SIGPIPE
# (141) and the pipeline FAIL although grep matched -- the first cut of this suite failed 7 runs in 12 that way.
# Match against a here-string or a file instead.
#
# NWP-20261121-13: trunc_cases, under every shell found (bash, sh, dash, mksh; bash as bash --posix), each line tagged
# [<sh>]. vpn_apply's NONE, vpn_apply_choice's APPLIED and vpn_deferred_retry's user-choice .vpnapplied truncations
# (V1-V3), sync_apply_once's three .syncapplied truncations (S1-S3) and the grant arm's acct-deferred mark (G1) each run
# with their target planted as a DIRECTORY. Each must run past the site, log its outcome, and give the answer and the
# helper, cmd and settings calls of a control run with a writable target. G1 must also log GRANT acct_reload DEFERRED
# and then the sync deferral, and write its reply; the tap's odrestore then runs no acct_reload, because its -f reader
# sees no mark. The -e capture guards read a directory as present, so no case asserts on a capture. Each site's bare
# ': >' form is a mutant that must be convicted under every shell.
#
#   bash test-sync-vpn-roam.sh                      # the cases
#   bash test-sync-vpn-roam.sh --mutate             # ... plus mutations that must each CONVICT the suite
#   MUTJOBS=8 bash test-sync-vpn-roam.sh --mutate   # the same, 8 mutants at a time; verdicts print in order
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
NSH=$(echo $SHELLS | wc -w)
echo "shells:$SHELLS"

# Planted secrets: an account name in every capture, a profile name in $name. Neither may reach any log.
ACCT='alice.secret@example.com'
PROF='Zed Profile'

# --- the stubs, shared by every run -----------------------------------------------------------------------
# settings: `get` answers from $T/live/<key> (absent -> null, SETFAIL=1 -> prints nothing).
# timeout: TIMEOUTRC set -> returns it WITHOUT running the command (a helper that never answered); else runs it.
# app_process: records argv and stdin; plays np.VpnAlwaysOn (APMODE: ok = what the patched framework does,
# noop = nothing, unpatched = the block at once on `defer`, stuckon / stuckpend = an OFF that leaves the block on /
# pending; PICKWRITE=<text> = the user picks again while the call runs) and np.SyncRoam (prints $SYNCOUT, exits $SYNCRC).
STUBS=$(cat <<'EOS'
settings(){
  [ "${1:-}" = get ] || return 0
  [ "${SETFAIL:-0}" = 1 ] && return 1
  if [ -f "$T/live/$5" ]; then cat "$T/live/$5"; else echo null; fi
}
timeout(){ shift; [ -n "${TIMEOUTRC:-}" ] && return "$TIMEOUTRC"; "$@"; }
app_process(){
  local cls="$2"; shift 2
  printf '%s\n' "$*" >> "$T/apargs"
  case "$cls" in
    np.VpnAlwaysOn)
      local u="$1" p="$2" m="$3"
      mkdir -p "$T/live"
      [ -n "${PICKWRITE:-}" ] && printf "$PICKWRITE" > "$U/com.nowhere.chooser/files/nowhere-vpn-pick"
      case "${APMODE:-ok}" in
        ok)        if [ "$m" = defer ]; then echo "$p" > "$T/live/always_on_vpn_app"; echo 0 > "$T/live/always_on_vpn_lockdown"; echo "$p" > "$T/live/nowhere_vpn_lockdown_pending"
                   else echo "$p" > "$T/live/always_on_vpn_app"; echo "$m" > "$T/live/always_on_vpn_lockdown"; rm -f "$T/live/nowhere_vpn_lockdown_pending"; fi
                   echo "stub $m -> done" ;;
        unpatched) echo "$p" > "$T/live/always_on_vpn_app"; echo 1 > "$T/live/always_on_vpn_lockdown"; echo "stub -> done" ;;
        stuckon)   echo "$p" > "$T/live/always_on_vpn_app"; echo 1 > "$T/live/always_on_vpn_lockdown"; echo "stub -> true" ;;
        stuckpend) echo "$p" > "$T/live/always_on_vpn_app"; echo 0 > "$T/live/always_on_vpn_lockdown"; echo "$p" > "$T/live/nowhere_vpn_lockdown_pending"; echo "stub -> true" ;;
        noop)      echo "stub -> false" ;;
      esac ;;
    np.SyncRoam)
      cat > "$T/apstdin"
      [ -n "${SYNCOUT:-}" ] && cat "$SYNCOUT"
      return "${SYNCRC:-0}" ;;
  esac
}
cmd(){ echo "cmd $*" >> "$T/trace"; }
am(){ echo "am $*" >> "$T/trace"; }
# pm: an app with code -- `list packages -U ... <pkg>` lists the package's own line, so a case that runs the odrestore
# arm reads it as installed (its NWP-20261122-03 read); every other pm call answers nothing, as before.
pm(){ local _pa; case "$*" in "list packages -U "*) for _pa; do :; done; printf 'package:%s uid:1110234\n' "$_pa" ;; esac; return 0; }
sleep(){ :; }
# roamd runs under mksh, where print exists; qn and the WG raise line use `print -r --` and run under bash here.
print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }
EOS
)

FN_NAMES="vpn_seal_capture vpn_choice vpn_apply vpn_apply_choice vpn_pick_consume vpn_deferred_retry sync_capture_valid sync_answer sync_fp sync_run
  sync_take_pend sync_keep_lines sync_apply_once sync_apply sync_apply_retry sync_seal_capture qn"
extract_fns() {  # $1 = script -> the functions, or failure
  local f="$1" out n prog="/^VPN_APPLY_TRIES=/p; /^SYNC_TIMEOUT=/p; /^SYNC_APPLY_TRIES=/p;"
  for n in $FN_NAMES; do prog="$prog /^$n() {\$/,/^}\$/p;"; done
  out=$(sed -n "$prog" "$f")
  for n in $FN_NAMES; do
    case "$out" in *"$n() {"*) ;; *) return 1 ;; esac
  done
  case "$out" in *VPN_APPLY_TRIES=*SYNC_TIMEOUT=*SYNC_APPLY_TRIES=*) ;; *) return 1 ;; esac
  printf '%s\n' "$out"
}
arm() {  # $1 = script, $2 = op -> the op's body
  sed -n "/^  $2)\$/,/^    ;;\$/p" "$1" | sed '1d;$d'
}
has() {  # has <fixed text> <haystack> -- no pipe, so no SIGPIPE under pipefail
  grep -qF -- "$1" <<<"$2"
}

# suite <script> [quiet] -> 0 iff every case behaved. Own counters, never touches globals: every name it assigns is
# local, loop variables too -- a bare `for m` here once overwrote verdict's $m, and verdict then removed ./stuckpend
# instead of its mutant copy.
suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 FNS VPNUP GRANT ODRES INARM OUTARM DEFER GBLK T U FILES LOGS good RS m i \
    pline withpend stout okr errr errfix SCRUB scrubbed w1pl w1out w0rec w2b
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  FNS=$(extract_fns "$f") || { no "EXTRACTION FAILED -- a sync/vpn function moved in $f"; return 1; }
  VPNUP=$(arm "$f" vpnup); GRANT=$(arm "$f" grant); ODRES=$(arm "$f" odrestore); INARM=$(arm "$f" in); OUTARM=$(arm "$f" out)
  has vpn_apply "$VPNUP" || { no "EXTRACTION FAILED -- the vpnup arm"; return 1; }
  has acct_reload "$GRANT" || { no "EXTRACTION FAILED -- the grant arm"; return 1; }
  has acct-deferred- "$ODRES" || { no "EXTRACTION FAILED -- the odrestore arm"; return 1; }
  # Android's grep and sed (toybox over bionic's regex) have none of GNU's BRE extensions -- `\|`, `\+`, `\?` -- so
  # `grep 'a\|b'` there matches neither. GNU tools on a CI runner accept them, so a test run cannot see it -- hence a
  # lint over the extracted code (comments excluded). Use -E instead.
  local _gl; _gl=$(grep -E '(grep|sed) ' <<<"$FNS"); _gl=$(grep -v '^ *#' <<<"$_gl")
  if grep -qF -e '\|' -e '\+' -e '\?' <<<"$_gl"; then
    no "a grep or sed in the sync/vpn functions uses a GNU-only BRE escape (backslash-pipe, -plus or -question)"
  else
    ok "no grep or sed uses a GNU-only BRE escape"
  fi
  SCRUB=$(sed -n "s/^LOG_SCRUB_SED='\(.*\)'\$/\1/p" "$f")
  [ -n "$SCRUB" ] || { no "EXTRACTION FAILED -- LOG_SCRUB_SED"; return 1; }
  LOGS=$(mktemp -d -p "$W") || exit 2

  # fresh -- a clean fixture: $T, the roamed user's chooser files dir, the helper jars, state, the fingerprint files.
  fresh() {
    T=$(mktemp -d -p "$W") || exit 2; U="$T/data/user/10"; FILES="$U/com.nowhere.chooser/files"
    mkdir -p "$FILES" "$T/state" "$T/live" "$T/fw" "$T/data/system/sync" "$T/data/system_ce/10"
    : > "$T/fw/nowhere-vpnao.jar"; : > "$T/fw/nowhere-syncroam.jar"
    printf 'tz=\nlocale=en-US\n' > "$FILES/nowhere-prefs"
  }
  done_fx() { cat "$T/log" >> "$LOGS/all" 2>/dev/null; rm -rf "$T"; }
  # run <shell text> -- the stubs + the functions, in the fixture, with the session globals roamd has.
  run() {
    T="$T" U="$U" LOG="$T/log" STATE="$T/state" RES="$T/res" SYNC_USER_ROOT="$T/data/user" VPN_USER_ROOT="$T/data/user" \
      SYNC_FP_ROOT="$T/data" NOWHERE_VPN_JAR="$T/fw/nowhere-vpnao.jar" NOWHERE_SYNC_JAR="$T/fw/nowhere-syncroam.jar" \
      APMODE="${APMODE:-ok}" SETFAIL="${SETFAIL:-0}" SYNCOUT="${SYNCOUT:-}" SYNCRC="${SYNCRC:-0}" \
      TIMEOUTRC="${TIMEOUTRC:-}" PICKWRITE="${PICKWRITE:-}" \
      bash -c "name='$PROF'; uid=10; USERDIR='$U'
$STUBS
$FNS
$1" >/dev/null 2>&1
  }
  live() { printf '%s\n' "$2" > "$T/live/$1"; }
  logged() { grep -qF -- "$1" "$T/log" 2>/dev/null; }

  # ================================ the VPN capture ========================================================
  fresh; : > "$T/state/.vpnapplied.10"; live always_on_vpn_app com.x; live always_on_vpn_lockdown 1
  rm -f "$T/fw/nowhere-vpnao.jar"; run "vpn_seal_capture '$U' 10"
  [ ! -e "$FILES/nowhere-vpn" ] && ok "vpn capture: no helper on the image -> nothing captured" || no "vpn capture ran with no helper"
  done_fx

  fresh; printf 'app=com.keep\nlockdown=1\n' > "$FILES/nowhere-vpn"; live always_on_vpn_app com.x; live always_on_vpn_lockdown 0
  run "vpn_seal_capture '$U' 10"
  [ "$(cat "$FILES/nowhere-vpn")" = "$(printf 'app=com.keep\nlockdown=1')" ] && logged 'vpn: not applied yet' \
    && ok "vpn capture: BEFORE this session's apply the record is kept (and it says so)" || no "vpn capture overwrote the record before the apply"
  done_fx

  vcap() {  # vcap <app> <lockdown> <pending> <want file text>
    fresh; : > "$T/state/.vpnapplied.10"
    [ -n "$1" ] && live always_on_vpn_app "$1"; [ -n "$2" ] && live always_on_vpn_lockdown "$2"; [ -n "$3" ] && live nowhere_vpn_lockdown_pending "$3"
    run "vpn_seal_capture '$U' 10"
    [ "$(cat "$FILES/nowhere-vpn" 2>/dev/null)" = "$(printf "$4")" ]
  }
  vcap com.x 1 "" 'app=com.x\nlockdown=1' && ok "vpn capture: block on -> lockdown=1" || no "vpn capture: block on"; done_fx
  vcap com.x 0 com.x 'app=com.x\nlockdown=1' && ok "vpn capture: a block PENDING the first connection counts as on" || no "vpn capture: pending not counted as on"; done_fx
  vcap com.x 0 "" 'app=com.x\nlockdown=0' && ok "vpn capture: block off -> lockdown=0 (an explicit off roams)" || no "vpn capture: block off"; done_fx
  vcap com.x 0 com.other 'app=com.x\nlockdown=0' && ok "vpn capture: a pending block for ANOTHER app does not count" || no "vpn capture: foreign pending counted"; done_fx
  vcap "" "" "" 'app=\nlockdown=0' && ok "vpn capture: no always-on app -> app= lockdown=0" || no "vpn capture: none"; done_fx

  fresh; : > "$T/state/.vpnapplied.10"; printf 'app=com.keep\nlockdown=1\n' > "$FILES/nowhere-vpn"
  SETFAIL=1 run "vpn_seal_capture '$U' 10"
  [ "$(head -n 1 "$FILES/nowhere-vpn")" = app=com.keep ] && logged 'settings read failed' \
    && ok "vpn capture: a failed settings read keeps the record (and says so)" || no "vpn capture: failed read clobbered the record"
  done_fx
  fresh; : > "$T/state/.vpnapplied.10"; printf 'app=com.keep\nlockdown=1\n' > "$FILES/nowhere-vpn"; live always_on_vpn_app 'com.x;rm'; live always_on_vpn_lockdown 0
  run "vpn_seal_capture '$U' 10"
  [ "$(head -n 1 "$FILES/nowhere-vpn")" = app=com.keep ] && ok "vpn capture: a value that is not a package name keeps the record" || no "vpn capture: bad package written"
  done_fx
  fresh; : > "$T/state/.vpnapplied.10"; live always_on_vpn_app com.x; live always_on_vpn_lockdown 1
  run "vpn_seal_capture '$U' 10"; run "vpn_seal_capture '$U' 10"
  [ "$(grep -c 'vpn: captured' "$T/log")" = 1 ] && ok "vpn capture: an unchanged pair is not rewritten or re-logged" || no "vpn capture: unchanged pair logged $(grep -c 'vpn: captured' "$T/log") times"
  done_fx

  # ================================ vpn_choice ============================================================
  choice() {  # choice <pick text|-> <capture text|-> <prefs text> -> stdout
    fresh
    [ "$1" = - ] || printf "$1" > "$FILES/nowhere-vpn-pick"
    [ "$2" = - ] || printf "$2" > "$FILES/nowhere-vpn"
    printf "$3" > "$FILES/nowhere-prefs"
    T="$T" bash -c "$FNS
vpn_choice '$FILES/nowhere-vpn-pick' '$FILES/nowhere-vpn' '$FILES/nowhere-prefs'"
    rm -rf "$T"
  }
  [ "$(choice 'app=com.p\nlockdown=0\n' 'app=com.c\nlockdown=1\n' 'locale=x\nvpn=com.r\n')" = "pick com.p 0" ] \
    && ok "choice: the picker's pick beats the capture and the old pref" || no "choice: pick did not win"
  [ "$(choice - 'app=com.c\nlockdown=0\n' 'locale=x\nvpn=com.r\nvpnlockdown=1\n')" = "capture com.c 0" ] \
    && ok "choice: the capture beats the old pref (a carried OFF is not overridden by vpnlockdown=1)" || no "choice: capture did not beat prefs"
  [ "$(choice 'app=com.p\nlockdown=7\n' 'app=com.c\nlockdown=1\n' 'locale=x\n')" = "capture com.c 1" ] \
    && ok "choice: a malformed pick is passed over, never half-applied" || no "choice: malformed pick used"
  [ "$(choice 'app=\nlockdown=0\n' 'app=com.c\nlockdown=1\n' 'locale=x\n')" = "pick - 0" ] \
    && ok "choice: a pick of Off is a choice (none), not a missing pick" || no "choice: pick Off ignored"
  [ "$(choice - - 'locale=x\nvpn=com.r\n')" = "prefs com.r 1" ] \
    && ok "choice: first sign-in after this ships -> the old pref, block on as before" || no "choice: legacy pref not lockdown 1"
  [ "$(choice - - 'locale=x\nvpn=com.r\nvpnlockdown=0\n')" = "prefs com.r 0" ] && ok "choice: an old pref's explicit 0 is kept" || no "choice: legacy 0 lost"
  [ "$(choice - - 'locale=x\n')" = "none - 0" ] && ok "choice: nothing anywhere -> none" || no "choice: none"

  # ================================ the vpnup op (vpn_apply) ===============================================
  vpnup() { run "$VPNUP"; }
  appready() { mkdir -p "$U/$1"; }
  fresh; appready com.x; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/apargs" 2>/dev/null)" = "10 com.x defer" ] && ok "vpnup: a carried ON goes through the consent (defer), not lockdown=1" \
    || no "vpnup: carried ON called the helper with '$(cat "$T/apargs" 2>/dev/null)'"
  [ "$(cat "$T/res")" = "OK APPLIED" ] && [ -e "$T/state/.vpnapplied.10" ] && ok "vpnup: ON read back as pending -> OK APPLIED, and the capture may now run" \
    || no "vpnup: carried ON answered '$(cat "$T/res")'"
  logged 'always-on VPN -> com.x (lockdown=1 via defer, from capture)' && ok "vpnup: the log names the source and the mode" || no "vpnup: log line missing"
  done_fx

  fresh; appready com.x; printf 'app=com.x\nlockdown=0\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/apargs" 2>/dev/null)" = "10 com.x 0" ] && [ "$(cat "$T/res")" = "OK APPLIED" ] \
    && ok "vpnup: a carried OFF is an explicit lockdown=0 (it sticks)" || no "vpnup: carried OFF -> '$(cat "$T/apargs" 2>/dev/null)' / $(cat "$T/res")"
  done_fx
  for m in stuckon stuckpend; do
    fresh; appready com.x; printf 'app=com.x\nlockdown=0\n' > "$FILES/nowhere-vpn"; APMODE=$m vpnup
    [ "$(cat "$T/res")" = NOTREADY ] && [ ! -e "$T/state/.vpnapplied.10" ] \
      && ok "vpnup: an OFF that reads back with the block $m is NOT applied" || no "vpnup: OFF read back '$m' accepted"
    done_fx
  done

  fresh; appready com.x; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; APMODE=unpatched vpnup
  [ "$(cat "$T/res")" = "OK APPLIED" ] && ok "vpnup: an image without the first-connect patch arms at once -- still applied (the register's tell)" || no "vpnup: unpatched consent not accepted"
  done_fx

  fresh; appready com.x; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn-pick"; APMODE=noop vpnup
  [ "$(cat "$T/res")" = NOTREADY ] && [ ! -e "$T/state/.vpnapplied.10" ] && [ -e "$FILES/nowhere-vpn-pick" ] \
    && ok "vpnup: a call that did not take (read-back miss) -> NOTREADY, no marker, the pick kept" || no "vpnup: unread-back apply accepted"
  done_fx
  fresh; appready com.x; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; TIMEOUTRC=124 vpnup
  [ "$(cat "$T/res")" = NOTREADY ] && ok "vpnup: a helper that timed out -> NOTREADY (the daemon retries)" || no "vpnup: timed-out helper answered $(cat "$T/res")"
  done_fx

  fresh; appready com.y; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; printf 'app=com.y\nlockdown=0\n' > "$FILES/nowhere-vpn-pick"; vpnup
  [ "$(cat "$T/apargs" 2>/dev/null)" = "10 com.y 0" ] && [ ! -e "$FILES/nowhere-vpn-pick" ] \
    && ok "vpnup: the pick is applied over the capture and CONSUMED" || no "vpnup: pick -> '$(cat "$T/apargs" 2>/dev/null)'"
  done_fx
  fresh; appready com.y; printf 'app=com.y\nlockdown=0\n' > "$FILES/nowhere-vpn-pick"; PICKWRITE='app=com.z\nlockdown=1\n' vpnup
  [ "$(head -n 1 "$FILES/nowhere-vpn-pick" 2>/dev/null)" = app=com.z ] \
    && ok "vpnup: a pick made WHILE the apply ran survives (compare-and-remove)" || no "vpnup: a newer pick was deleted"
  done_fx

  fresh; printf 'app=\nlockdown=0\n' > "$FILES/nowhere-vpn-pick"; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/res")" = "OK NONE" ] && [ ! -e "$T/apargs" ] && [ ! -e "$FILES/nowhere-vpn-pick" ] && [ -e "$T/state/.vpnapplied.10" ] \
    && ok "vpnup: a pick of Off -> OK NONE, nothing called, the pick consumed, the capture may run" || no "vpnup: pick Off mishandled ($(cat "$T/res"))"
  done_fx

  fresh; appready com.x; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; rm -f "$T/fw/nowhere-vpnao.jar"; vpnup
  [ "$(cat "$T/res")" = "OK NOHELPER" ] && [ ! -e "$T/apargs" ] && [ ! -e "$T/state/.vpnapplied.10" ] && logged 'NOT applied' \
    && ok "vpnup: no helper (#122) -> OK NOHELPER, logged as NOT applied, no marker" || no "vpnup: no-helper answered '$(cat "$T/res")'"
  done_fx

  fresh; appready com.r; printf 'tz=\nlocale=en-US\nvpn=com.r\nvpnlockdown=1\n' > "$FILES/nowhere-prefs"; vpnup
  [ "$(cat "$T/apargs" 2>/dev/null)" = "10 com.r defer" ] && ok "vpnup: the first sign-in after this ships applies the old pref, armed at first connect" || no "vpnup: legacy pref -> '$(cat "$T/apargs" 2>/dev/null)'"
  done_fx

  fresh; rm -f "$FILES/nowhere-prefs"; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/res")" = NOTREADY ] && [ ! -e "$T/apargs" ] && ok "vpnup: CE dir not restored -> NOTREADY" || no "vpnup: ran before the restore"
  done_fx
  fresh; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/res")" = NOTREADY ] && [ ! -e "$T/apargs" ] && ok "vpnup: VPN app not provisioned -> NOTREADY" || no "vpnup: ran before the app existed"
  done_fx

  # W1/W2 (NWP-20261109-22): the WireGuard tunnel name is the user's own text and roam.log outlives the session, so it
  # is logged as ONE quoted token the scrub removes (Q001 (e)); WireGuard itself still gets the bare name.
  fresh; appready com.wireguard.android; mkdir -p "$U/com.wireguard.android/files"; : > "$U/com.wireguard.android/files/home-berlin.conf"
  printf 'app=com.wireguard.android\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/res")" = "OK APPLIED" ] && ok "W1: a WireGuard always-on apply is applied" || no "W1: answered '$(cat "$T/res")'"
  logged '"home-berlin"' && ok "W1: the tunnel name is logged as one quoted token" || no "W1: tunnel name not quoted in the log"
  scrubbed=$(sed -E "$SCRUB" "$T/log" 2>/dev/null)
  [ -n "$scrubbed" ] && ! has home-berlin "$scrubbed" && ok "W1: LOG_SCRUB_SED leaves no tunnel name in the log" \
    || no "W1: the tunnel name survives the scrub"
  has 'SET_TUNNEL_UP --es tunnel home-berlin' "$(cat "$T/trace" 2>/dev/null)" \
    && ok "W1: WireGuard is still told the bare tunnel name" || no "W1: SET_TUNNEL_UP lost the bare name"
  done_fx
  fresh; appready com.wireguard.android; mkdir -p "$U/com.wireguard.android/files"
  printf 'app=com.wireguard.android\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  ! has SET_TUNNEL_UP "$(cat "$T/trace" 2>/dev/null)" && ! logged 'WG raise' \
    && ok "W2: no WireGuard conf -> no tunnel raised, no WG line" || no "W2: no-conf apply misbehaved"
  done_fx

  # An on-demand VPN app: deferred at sign-in, applied at a later SEAL once it has materialised -- bounded, and never
  # inside odrestore, which the user is waiting on.
  has vpn_apply "$ODRES" && no "odrestore runs the VPN apply (it blocks a user-facing materialise)" \
    || ok "odrestore does not run the VPN apply"
  fresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; vpnup
  [ "$(cat "$T/res")" = "OK DEFERRED" ] && [ "$(cat "$T/state/.vpndeferred.10" 2>/dev/null)" = "com.x 1 capture" ] && [ ! -e "$T/apargs" ] \
    && [ ! -e "$T/state/.vpnapplied.10" ] && ok "vpnup: an on-demand VPN app -> OK DEFERRED, the choice kept for the seal retry, nothing called" \
    || no "vpnup: on-demand app answered '$(cat "$T/res" 2>/dev/null)' / '$(cat "$T/state/.vpndeferred.10" 2>/dev/null)'"
  run "vpn_deferred_retry 10"
  [ ! -e "$T/apargs" ] && [ -e "$T/state/.vpndeferred.10" ] && [ ! -e "$T/state/.vpnretry.10" ] \
    && ok "seal retry: still held -> no JVM, nothing counted" || no "seal retry: ran or counted while the app was still held"
  # F2: a pick made THIS session is for the next sign-in, deferral or not.
  printf 'app=com.y\nlockdown=0\n' > "$FILES/nowhere-vpn-pick"; appready com.y
  rm -rf "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; appready com.x
  run "vpn_deferred_retry 10"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "10 com.x defer" ] && [ -e "$T/state/.vpnapplied.10" ] && [ ! -e "$T/state/.vpndeferred.10" ] \
    && logged 'the deferred apply for user 10 answered OK APPLIED' \
    && ok "seal retry: once the app has materialised the DEFERRED choice is applied, and the capture may run" || no "seal retry: deferred VPN not applied ($(cat "$T/apargs" 2>/dev/null))"
  [ "$(head -n 1 "$FILES/nowhere-vpn-pick" 2>/dev/null)" = app=com.y ] \
    && ok "seal retry: a pick made this session is not applied and stays for the next sign-in" || no "seal retry: this session's pick was applied or consumed"
  rm -f "$T/apargs"; run "vpn_deferred_retry 10"
  [ ! -e "$T/apargs" ] && ok "seal retry: nothing left to do once applied" || no "seal retry: ran again after applying"
  done_fx
  # A deferral that came from the previous session's pick consumes that pick once applied.
  fresh; appready com.x; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn-pick"; printf 'com.x 1 pick\n' > "$T/state/.vpndeferred.10"
  run "vpn_deferred_retry 10"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "10 com.x defer" ] && [ ! -e "$FILES/nowhere-vpn-pick" ] \
    && ok "seal retry: a deferral that came from a pick consumes that pick once applied" || no "seal retry: the deferred pick was not consumed"
  done_fx
  # The user's choice wins over a deferral that came from a PICK: the pick is consumed too, or it would outrank this
  # session's capture at the next sign-in. A pick made since (different text) survives.
  fresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; printf 'com.x 1 pick\n' > "$T/state/.vpndeferred.10"
  printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn-pick"; live always_on_vpn_app com.b
  run "vpn_deferred_retry 10"
  [ ! -e "$FILES/nowhere-vpn-pick" ] && [ -e "$T/state/.vpnapplied.10" ] \
    && ok "seal retry: dropping a pick-sourced deferral for the user's choice consumes that pick" || no "seal retry: the stale pick survived the user's choice"
  done_fx
  fresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; printf 'com.x 1 pick\n' > "$T/state/.vpndeferred.10"
  printf 'app=com.z\nlockdown=0\n' > "$FILES/nowhere-vpn-pick"; live always_on_vpn_app com.b
  run "vpn_deferred_retry 10"
  [ "$(head -n 1 "$FILES/nowhere-vpn-pick" 2>/dev/null)" = app=com.z ] \
    && ok "seal retry: ... but a pick made since survives (compare-and-remove)" || no "seal retry: a newer pick was removed"
  done_fx
  # F4: only a PICK-sourced deferral consumes the pick. A capture-sourced one leaves even an identical new pick alone.
  fresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; printf 'com.x 1 capture\n' > "$T/state/.vpndeferred.10"
  printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn-pick"; live always_on_vpn_app com.b
  run "vpn_deferred_retry 10"
  [ "$(head -n 1 "$FILES/nowhere-vpn-pick" 2>/dev/null)" = app=com.x ] && [ -e "$T/state/.vpnapplied.10" ] \
    && ok "seal retry: dropping a capture-sourced deferral leaves this session's pick for the next sign-in" || no "seal retry: a capture-sourced drop consumed the pick"
  done_fx
  # F1: the user set ANOTHER always-on VPN in Settings this session -- it wins; the deferral is dropped.
  fresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; printf 'com.x 1 capture\n' > "$T/state/.vpndeferred.10"; live always_on_vpn_app com.b
  run "vpn_deferred_retry 10"
  [ ! -e "$T/apargs" ] && [ ! -e "$T/state/.vpndeferred.10" ] && [ -e "$T/state/.vpnapplied.10" ] && logged 'chose com.b in this session' \
    && ok "seal retry: a VPN the user chose this session wins -- deferral dropped, their choice to be captured" || no "seal retry: the user's live VPN was not respected"
  rm -rf "$U/com.nowhere.chooser/.nowhere-odhold/com.x"; appready com.x; run "vpn_deferred_retry 10"
  [ ! -e "$T/apargs" ] && ok "seal retry: ... and the old app materialising later changes nothing" || no "seal retry: the carry replaced the user's VPN"
  done_fx
  fresh; appready com.x; printf 'com.x 1 capture\n' > "$T/state/.vpndeferred.10"
  SETFAIL=1 run "vpn_deferred_retry 10"
  [ ! -e "$T/apargs" ] && [ -e "$T/state/.vpndeferred.10" ] && [ ! -e "$T/state/.vpnapplied.10" ] \
    && ok "seal retry: an unreadable live setting applies nothing and keeps the deferral" || no "seal retry: acted on an unreadable setting"
  done_fx
  fresh; printf 'app=com.x\nlockdown=1\n' > "$FILES/nowhere-vpn"; printf 'com.x 1 capture\n' > "$T/state/.vpndeferred.10"   # materialised, no app dir: NOTREADY
  for i in 1 2 3 4 5 6 7; do run "vpn_deferred_retry 10"; done
  [ ! -e "$T/state/.vpndeferred.10" ] && [ "$(grep -c 'is not ready yet, attempt' "$T/log")" = 4 ] && [ "$(grep -c 'given up for this session' "$T/log")" = 1 ] \
    && [ ! -e "$T/state/.vpnapplied.10" ] && ok "seal retry: NOTREADY 5 times in all, then ONE give-up line and nothing more; no capture" \
    || no "seal retry: bound wrong ($(grep -c 'not ready yet' "$T/log") attempts logged)"
  done_fx

  # ================================ the sync capture ======================================================
  good="$LOGS/good"; printf 'nowhere-sync 1\nmaster 1\nsync 1 com.google gmail-ls %s\nsync 0 com.google com.android.calendar %s\nend 2\n' "$ACCT" "$ACCT" > "$good"
  pline="pend 1 com.google gmail-ls $ACCT"
  withpend="$LOGS/withpend"; { cat "$good"; printf '%s\n' "$pline"; } > "$withpend"

  fresh; : > "$T/state/.syncapplied.10"; rm -f "$T/fw/nowhere-syncroam.jar"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ ! -e "$FILES/nowhere-sync" ] && [ ! -e "$T/apargs" ] && ok "sync capture: no helper (Diaspore) -> nothing captured" || no "sync capture ran with no helper"
  done_fx

  fresh; printf 'nowhere-sync 1\nmaster 0\nend 0\n' > "$FILES/nowhere-sync"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ "$(cat "$FILES/nowhere-sync")" = "$(printf 'nowhere-sync 1\nmaster 0\nend 0')" ] && [ ! -e "$T/apargs" ] && logged 'sync: not applied yet' \
    && ok "sync capture: BEFORE this session's apply the record is kept (and it says so)" || no "sync capture overwrote the record before the apply"
  done_fx

  fresh; : > "$T/state/.syncapplied.10"; printf 'nowhere-sync 1\nmaster 0\nend 0\n' > "$FILES/nowhere-sync"
  printf '%s\n' "$pline" > "$FILES/nowhere-sync-pending"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  cmp -s "$FILES/nowhere-sync" "$good" && ok "sync capture: the helper's capture is kept whole" || no "sync capture not written"
  [ "$(cat "$T/apstdin" 2>/dev/null)" = "$(printf 'nowhere-sync 1\nmaster 0\nend 0\n%s' "$pline")" ] \
    && ok "sync capture: the helper reads the previous capture AND this session's pend lines" || no "sync capture: helper stdin was '$(cat "$T/apstdin" 2>/dev/null)'"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "capture 10" ] && ok "sync capture: helper called as capture <uid>" || no "sync capture: helper args '$(cat "$T/apargs")'"
  [ ! -e "$FILES/nowhere-sync-pending" ] && ok "sync capture: a pend line the capture landed is no longer pending" || no "sync capture: landed pend line kept"
  logged 'sync: captured master=1 and 2 switch(es) for user 10' && ok "sync capture: logged as COUNTS" || no "sync capture: count line missing"
  [ ! -e "$FILES/nowhere-sync-in.tmp" ] && [ ! -e "$FILES/nowhere-sync.tmp" ] && [ ! -e "$FILES/nowhere-sync.raw" ] \
    && ok "sync capture: no temporary file left behind" || no "sync capture left a tmp"
  done_fx

  fresh; : > "$T/state/.syncapplied.10"; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$withpend" run "sync_seal_capture '$U' 10"
  cmp -s "$FILES/nowhere-sync" "$good" && [ "$(cat "$FILES/nowhere-sync-pending" 2>/dev/null)" = "$pline" ] \
    && ok "sync capture: the pend lines after the capture are split off and kept" || no "sync capture: pend lines not split"
  logged 'sync: 1 switch(es) still pending for user 10' && logged 'next retry in 1 seal(s)' \
    && ok "sync capture: what is still pending, and when it is next tried, is logged" || no "sync capture: pending not logged"
  done_fx

  stout="$LOGS/stout"; { cat "$good"; printf '%s\nstat landed=0 unstuck=1\n' "$pline"; } > "$stout"
  fresh; : > "$T/state/.syncapplied.10"; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$stout" run "sync_seal_capture '$U' 10"
  [ "$(cat "$FILES/nowhere-sync-pending" 2>/dev/null)" = "$pline" ] && cmp -s "$FILES/nowhere-sync" "$good" \
    && logged 'sync: carried switches for user 10: landed=0 unstuck=1' \
    && ok "sync capture: the stat line is split off and logged as counts" || no "sync capture: stat line not handled"
  done_fx

  # The gate: an unchanged fingerprint means no JVM; any change, or no file, means one.
  fp_files() { RS="$T/data/system/users/10/registered_services"; : > "$T/data/system/sync/accounts.xml"; : > "$T/data/system_ce/10/accounts_ce.db"; mkdir -p "$RS" "$T/data/system"
    : > "$RS/android.content.SyncAdapter.xml"; : > "$RS/android.accounts.AccountAuthenticator.xml"; : > "$T/data/system/packages.list"; }
  fresh; : > "$T/state/.syncapplied.10"; fp_files
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"; rm -f "$T/apargs"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ ! -e "$T/apargs" ] && ok "sync capture: an unchanged fingerprint starts no helper" || no "sync capture ran the helper with nothing changed"
  printf 'x' >> "$T/data/system/sync/accounts.xml"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: a changed accounts.xml runs the capture" || no "sync capture skipped after a switch changed"
  rm -f "$T/apargs"; printf 'w' > "$T/data/system_ce/10/accounts_ce.db-wal"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: an account change (the db's -wal appearing) runs the capture" || no "sync capture skipped after an account change"
  rm -f "$T/apargs"; printf 'p' >> "$T/data/system/packages.list"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ ! -e "$T/apargs" ] && ok "sync capture: a PackageManager settings write (packages.list) starts no capture" || no "sync capture ran for packages.list churn"
  printf 'a' >> "$RS/android.content.SyncAdapter.xml"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: the user's sync-adapter set changing runs the capture" || no "sync capture skipped after an adapter registered"
  rm -f "$T/apargs"; printf 'a' >> "$RS/android.accounts.AccountAuthenticator.xml"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: the user's authenticator set changing runs the capture" || no "sync capture skipped after an authenticator registered"
  done_fx
  fresh; : > "$T/state/.syncapplied.10"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"; rm -f "$T/apargs"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: no fingerprint files -> the capture always runs" || no "sync capture skipped with no fingerprint"
  done_fx
  # R1: a change that keeps the size (a switch flipped one way and another the other) still changes the mtime.
  fresh; : > "$T/state/.syncapplied.10"; fp_files; printf 'ab' > "$T/data/system/sync/accounts.xml"; touch -d @1700000000 "$T/data/system/sync/accounts.xml"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"; rm -f "$T/apargs"
  printf 'ba' > "$T/data/system/sync/accounts.xml"; touch -d @1700000100 "$T/data/system/sync/accounts.xml"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: a same-size change (new mtime) runs the capture" || no "sync capture: a same-size change was missed"
  done_fx
  # R2: a file that exists but cannot be stat'ed fails CLOSED -- no fingerprint, so every seal captures.
  fresh; : > "$T/state/.syncapplied.10"; fp_files
  SYNCOUT="$good" run "stat(){ return 1; }; sync_seal_capture '$U' 10"; rm -f "$T/apargs"
  SYNCOUT="$good" run "stat(){ return 1; }; sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: an unstatable fingerprint file means capture every seal" || no "sync capture: a failed stat was fingerprinted"
  done_fx
  # F4: the fingerprint is stored only after a capture that WORKED.
  fresh; : > "$T/state/.syncapplied.10"; fp_files; cp "$good" "$FILES/nowhere-sync"; printf 'ERR SecurityException\n' > "$LOGS/err1"
  SYNCOUT="$LOGS/err1" SYNCRC=1 run "sync_seal_capture '$U' 10"; rm -f "$T/apargs"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync capture: after a FAILED capture the next seal captures again (no fingerprint stored)" || no "sync capture: a failed capture stored the fingerprint"
  done_fx

  # F3: pending switches, nothing changed -> retried on a doubling schedule, not at every seal.
  fresh; : > "$T/state/.syncapplied.10"; fp_files; cp "$good" "$FILES/nowhere-sync"; printf '%s\n' "$pline" > "$FILES/nowhere-sync-pending"
  SYNCOUT="$withpend" run "sync_seal_capture '$U' 10"            # fingerprint new -> runs, still pending
  [ "$(cat "$T/state/.syncbo.10" 2>/dev/null)" = "1 1" ] && ok "pending: after a capture triggered by a change, wait 1 seal" || no "pending: backoff after a change is '$(cat "$T/state/.syncbo.10" 2>/dev/null)'"
  rm -f "$T/apargs"; SYNCOUT="$withpend" run "sync_seal_capture '$U' 10"
  [ ! -e "$T/apargs" ] && [ "$(cat "$T/state/.syncbo.10" 2>/dev/null)" = "0 1" ] && ok "pending: nothing changed -> the next seal waits, no JVM" || no "pending: retried during the wait"
  SYNCOUT="$withpend" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && [ "$(cat "$T/state/.syncbo.10" 2>/dev/null)" = "2 2" ] && logged 'retry after a backoff' \
    && ok "pending: the wait over -> retried, and the wait doubles" || no "pending: backoff retry wrong ($(cat "$T/state/.syncbo.10" 2>/dev/null))"
  printf '0 32\n' > "$T/state/.syncbo.10"; rm -f "$T/apargs"; SYNCOUT="$withpend" run "sync_seal_capture '$U' 10"
  [ "$(cat "$T/state/.syncbo.10" 2>/dev/null)" = "32 32" ] && ok "pending: the wait is capped at 32 seals" || no "pending: cap is '$(cat "$T/state/.syncbo.10" 2>/dev/null)'"
  printf '9 16\n' > "$T/state/.syncbo.10"; rm -f "$T/apargs"; printf 'a' >> "$RS/android.content.SyncAdapter.xml"; SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && [ ! -e "$FILES/nowhere-sync-pending" ] && [ ! -e "$T/state/.syncbo.10" ] \
    && ok "pending: an adapter registered -> retried at once, and once landed the schedule is dropped" || no "pending: a change did not cut the wait"
  done_fx

  scap_bad() {  # scap_bad <helper output text> <rc> <label> [timeout]
    fresh; : > "$T/state/.syncapplied.10"; cp "$good" "$FILES/nowhere-sync"; printf "$1" > "$LOGS/bad"
    SYNCOUT="$LOGS/bad" SYNCRC="$2" TIMEOUTRC="${4:-}" run "sync_seal_capture '$U' 10"
    if cmp -s "$FILES/nowhere-sync" "$good" && logged 'sync: capture FAILED' && [ ! -e "$FILES/nowhere-sync.tmp" ] && [ ! -e "$FILES/nowhere-sync.raw" ]; then
      ok "sync capture: $3 -> record kept, logged"
    else
      no "sync capture: $3 clobbered or silent"
    fi
  }
  scap_bad 'ERR SecurityException\n' 1 "helper ERR"; logged 'ERR SecurityException' && ok "sync capture: the ERR token is in the log" || no "sync capture: ERR token missing"; done_fx
  scap_bad "ERR $ACCT\n" 1 "an ERR line holding a name"; logged 'unrecognised answer' && ok "sync capture: an answer of no known shape is never printed" || no "sync capture: odd answer printed"; done_fx
  scap_bad "nowhere-sync 1\nmaster 1\nsync 1 com.google gmail-ls $ACCT\n" 1 "a half capture"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nsync 1 com.google gmail-ls x\nend 2\n' 0 "end count wrong"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nsync 1 com.google gmail-ls x\njunk\nend 1\n' 0 "an extra line"; done_fx
  scap_bad 'nowhere-sync 1\nend 0\n' 0 "no master line"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nend 0\npend 1 a b\n' 0 "a malformed pend line"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nend 0\n' 3 "a well-formed capture with a failing rc"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nend 0\nstat landed=1 unstuck=x\n' 0 "a malformed stat line"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nend 0\nstat landed=1 unstuck=0\nstat landed=1 unstuck=0\n' 0 "two stat lines"; done_fx
  scap_bad 'nowhere-sync 1\nmaster 1\nend 0\n' 0 "a helper that never answered" 124; logged 'timed out' && ok "sync capture: a timeout says so" || no "sync capture: timeout not named"; done_fx

  # NWP-20261119-13: a write that FAILS is not "no pend lines". A directory at the target path makes the open fail,
  # even for root. Each case keeps the record and the pending file byte for byte and stores no fingerprint.
  w1pl="$LOGS/w1pl"; printf 'pend 1 com.google com.android.contacts %s\npend 1 com.google gmail-ls %s\n' "$ACCT" "$ACCT" > "$w1pl"
  w1out="$LOGS/w1out"; { cat "$good"; cat "$w1pl"; } > "$w1out"
  w0rec="$LOGS/w0rec"; printf 'nowhere-sync 1\nmaster 0\nend 0\n' > "$w0rec"
  # S-W1: the pending record's temp file cannot be created.
  fresh; : > "$T/state/.syncapplied.10"; fp_files; cp "$w0rec" "$FILES/nowhere-sync"; cp "$w1pl" "$FILES/nowhere-sync-pending"
  mkdir "$FILES/nowhere-sync-pending.tmp"; SYNCOUT="$w1out" run "sync_seal_capture '$U' 10"
  cmp -s "$FILES/nowhere-sync-pending" "$w1pl" && cmp -s "$FILES/nowhere-sync" "$w0rec" && [ ! -e "$T/state/.syncfp.10" ] \
    && logged 'sync: capture FAILED for user 10' && logged "the profile's record is kept" && ! grep -qF -- "$ACCT" "$T/log" \
    && ok "S-W1: a pend-line write that fails keeps the record and the pending file, stores no fingerprint, logs no name" \
    || no "S-W1: a failed pend-line write deleted or replaced the record"
  done_fx
  # S-W1b: a SHORT write that reports success (one line of two) is not installed either.
  fresh; : > "$T/state/.syncapplied.10"; fp_files; cp "$w0rec" "$FILES/nowhere-sync"; cp "$w1pl" "$FILES/nowhere-sync-pending"
  SYNCOUT="$w1out" run "grep(){ if [ /dev/stdout -ef '$FILES/nowhere-sync-pending.tmp' ]; then command grep \"\$@\" | head -n 1; return 0; fi; command grep \"\$@\"; }
sync_seal_capture '$U' 10"
  cmp -s "$FILES/nowhere-sync-pending" "$w1pl" && cmp -s "$FILES/nowhere-sync" "$w0rec" && [ ! -e "$T/state/.syncfp.10" ] \
    && [ ! -e "$FILES/nowhere-sync-pending.tmp" ] && logged 'sync: capture FAILED for user 10' \
    && ok "S-W1b: a short pend-line write is not installed; the record and the pending file are kept" \
    || no "S-W1b: a short pend-line write was installed"
  done_fx
  # S-W3: the helper's input cannot be staged -> no helper, nothing changed, said so.
  fresh; : > "$T/state/.syncapplied.10"; fp_files; cp "$w0rec" "$FILES/nowhere-sync"; cp "$w1pl" "$FILES/nowhere-sync-pending"
  mkdir "$FILES/nowhere-sync-in.tmp"; SYNCOUT="$w1out" run "sync_seal_capture '$U' 10"
  [ ! -e "$T/apargs" ] && cmp -s "$FILES/nowhere-sync" "$w0rec" && cmp -s "$FILES/nowhere-sync-pending" "$w1pl" && [ ! -e "$T/state/.syncfp.10" ] \
    && logged 'sync: capture FAILED for user 10 (its input could not be staged) -> the profile' \
    && ok "S-W3: an input that cannot be staged runs no helper, keeps the record and the pending file, and says so" \
    || no "S-W3: the capture ran on an input it could not stage"
  done_fx
  # S-W4: no pend lines in the output -> the pending record is removed, as before.
  fresh; : > "$T/state/.syncapplied.10"; cp "$w0rec" "$FILES/nowhere-sync"; cp "$w1pl" "$FILES/nowhere-sync-pending"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ ! -e "$FILES/nowhere-sync-pending" ] && cmp -s "$FILES/nowhere-sync" "$good" \
    && ok "S-W4: an output with no pend lines removes the pending record" || no "S-W4: the pending record survived an output with no pend lines"
  done_fx

  # ================================ the sync apply ========================================================
  okr="$LOGS/okr"; printf 'OK master=1 rows=2 applied=2 pending=0 mismatch=0\n' > "$okr"
  errr="$LOGS/errr"; printf 'ERR master=1 rows=2 applied=2 pending=0 mismatch=1\n' > "$errr"
  fresh; cp "$good" "$FILES/nowhere-sync"; rm -f "$T/fw/nowhere-syncroam.jar"; run "sync_apply 10"
  [ ! -e "$T/apargs" ] && [ ! -e "$T/state/.syncapplied.10" ] && logged 'ships no sync helper' \
    && ok "sync apply: no helper (Diaspore) -> a stated no-op, no marker" || no "sync apply: no-helper path wrong"
  done_fx
  fresh; printf 'pend 1 a b c\n' > "$FILES/nowhere-sync-pending"; run "sync_apply 10"
  [ ! -e "$T/apargs" ] && [ -e "$T/state/.syncapplied.10" ] && logged 'sync: no capture for user 10' && [ ! -e "$FILES/nowhere-sync-pending" ] \
    && ok "sync apply: first sign-in after this ships -> nothing applied; a stale pend file is dropped" || no "sync apply: no-capture path wrong"
  done_fx
  fresh; printf 'nowhere-sync 1\nmaster 1\nend 3\n' > "$FILES/nowhere-sync"; run "sync_apply 10"
  [ ! -e "$T/apargs" ] && [ -e "$T/state/.syncapplied.10" ] && logged 'is malformed' \
    && ok "sync apply: a malformed capture is not applied, and this session's seal may replace it" || no "sync apply: malformed capture applied or stuck"
  done_fx
  fresh; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$okr" run "sync_apply 10"
  cmp -s "$T/apstdin" "$good" && ok "sync apply: the capture is the helper's stdin" || no "sync apply: helper stdin was not the capture"
  [ -e "$T/state/.syncapplied.10" ] && logged 'sync: applied for user 10: OK master=1 rows=2 applied=2 pending=0 mismatch=0' && [ ! -e "$FILES/nowhere-sync-pending" ] \
    && ok "sync apply: OK -> marker set, counts logged, nothing pending" || no "sync apply: OK path wrong"
  done_fx
  fresh; cp "$good" "$FILES/nowhere-sync"
  printf 'OK master=1 rows=2 applied=1 pending=1 mismatch=0\n%s\n' "$pline" > "$LOGS/pendr"
  SYNCOUT="$LOGS/pendr" run "sync_apply 10"
  [ -e "$T/state/.syncapplied.10" ] && [ "$(cat "$FILES/nowhere-sync-pending" 2>/dev/null)" = "$pline" ] && [ ! -e "$FILES/nowhere-sync-apply.tmp" ] \
    && ok "sync apply: a switch the framework cannot take yet is KEPT pending, and the sign-in still succeeds" || no "sync apply: pending not kept"
  done_fx
  # S8: a new sign-in drops this uid's stale fingerprint, so its first seal captures even if no file changed.
  fresh; fp_files; : > "$T/state/.syncapplied.10"; cp "$good" "$FILES/nowhere-sync"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  SYNCOUT="$okr" run "sync_apply 10"; rm -f "$T/apargs"
  SYNCOUT="$good" run "sync_seal_capture '$U' 10"
  [ -e "$T/apargs" ] && ok "sync apply: sign-in drops the stale fingerprint, so the first seal captures" || no "sync apply: a stale fingerprint survived sign-in"
  done_fx

  # F2: a sign-in apply that failed is retried at the next seals, bounded, then given up -- never left frozen. The retry
  # touches only what the failed apply handed back (round 7), so a switch the user changed since is left alone.
  errfix="$LOGS/errfix"; printf 'ERR master=1 rows=2 applied=2 pending=0 mismatch=1\nfix 1 0 com.google gmail-ls %s\n' "$ACCT" > "$errfix"
  fresh; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$errfix" SYNCRC=1 run "sync_apply 10"
  [ ! -e "$T/state/.syncapplied.10" ] && [ "$(cat "$T/state/.syncretry.10")" = 1 ] && logged 'sync: applied FAILED for user 10 (ERR master=1 rows=2 applied=2 pending=0 mismatch=1), attempt 1 of 5' \
    && ok "sync apply: a read-back mismatch -> NO marker (the record survives), counted for a retry, logged" || no "sync apply: failure path wrong: $(cat "$T/log")"
  [ "$(cat "$FILES/nowhere-sync-retry" 2>/dev/null)" = "fix 1 0 com.google gmail-ls $ACCT" ] \
    && ok "sync apply: what did not land is handed back and kept for the retry" || no "sync apply: the fix lines were not kept"
  rm -f "$T/apargs"; SYNCOUT="$okr" run "sync_apply_retry 10"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "retry 10" ] && [ "$(cat "$T/apstdin" 2>/dev/null)" = "fix 1 0 com.google gmail-ls $ACCT" ] \
    && ok "retry: the next seal runs the RETRY mode on the handed-back switches only" || no "retry: ran '$(cat "$T/apargs" 2>/dev/null)' on '$(cat "$T/apstdin" 2>/dev/null)'"
  [ -e "$T/state/.syncapplied.10" ] && [ ! -e "$T/state/.syncretry.10" ] && [ ! -e "$FILES/nowhere-sync-retry" ] && logged 'sync: apply retried for user 10: OK' \
    && ok "retry: an OK unblocks the session's capture and drops the hand-back" || no "retry: did not recover"
  rm -f "$T/apargs"; SYNCOUT="$okr" run "sync_apply_retry 10"
  [ ! -e "$T/apargs" ] && ok "retry: nothing to retry once applied" || no "retry: ran after the apply succeeded"
  done_fx
  # A failed apply that never answered hands nothing back: the retry works from the whole record.
  fresh; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$okr" TIMEOUTRC=124 run "sync_apply 10"
  [ ! -e "$T/state/.syncapplied.10" ] && logged 'applied FAILED' && [ ! -e "$FILES/nowhere-sync-retry" ] \
    && ok "sync apply: a helper that never answered -> no marker, nothing handed back, logged" || no "sync apply: timeout treated as applied"
  SYNCOUT="$okr" run "sync_apply_retry 10"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "retry 10" ] && cmp -s "$T/apstdin" "$good" \
    && ok "retry: with nothing handed back it retries from the whole record (under the clobber rule)" || no "retry: fallback input wrong"
  done_fx
  fresh; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$errfix" SYNCRC=1 run "sync_apply 10"
  for i in 1 2 3 4 5 6 7; do SYNCOUT="$errfix" SYNCRC=1 run "sync_apply_retry 10"; done
  [ "$(wc -l < "$T/apargs" | tr -d ' ')" = 5 ] && [ "$(cat "$T/state/.syncretry.10")" = gave-up ] && [ ! -e "$T/state/.syncapplied.10" ] \
    && [ "$(grep -c 'given up for this session' "$T/log")" = 1 ] && cmp -s "$FILES/nowhere-sync" "$good" \
    && ok "retry: 5 attempts in all, then ONE give-up line and no more JVMs; the record kept" || no "retry: bound wrong ($(wc -l < "$T/apargs") attempts)"
  done_fx
  # A hand-back the helper would not parse (an older format, a torn write) is no hand-back: dropped, whole record.
  fresh; cp "$good" "$FILES/nowhere-sync"; printf '1\n' > "$T/state/.syncretry.10"
  printf 'fix 1 com.google gmail-ls %s\n' "$ACCT" > "$FILES/nowhere-sync-retry"
  SYNCOUT="$okr" run "sync_apply_retry 10"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "retry 10" ] && cmp -s "$T/apstdin" "$good" && logged 'hand-back for user 10 is malformed' \
    && ok "retry: a malformed hand-back is dropped and the retry works from the whole record" || no "retry: a malformed hand-back was fed to the helper"
  done_fx
  # A previous session's hand-back must not survive into this one: a sign-in apply that then never answers would
  # otherwise be retried from the OLD session's fix lines.
  fresh; printf 'fix 1 a b c\n' > "$FILES/nowhere-sync-retry"; cp "$good" "$FILES/nowhere-sync"; SYNCOUT="$okr" TIMEOUTRC=124 run "sync_apply 10"
  [ "$(cat "$T/apargs" 2>/dev/null)" = "" ] && [ ! -e "$FILES/nowhere-sync-retry" ] \
    && ok "sync apply: a previous session's hand-back is dropped at sign-in" || no "sync apply: a stale hand-back survived sign-in"
  done_fx
  fresh; SYNCOUT="$okr" run "sync_apply_retry 10"
  [ ! -e "$T/apargs" ] && ok "retry: no apply has run yet (deferred to odrestore) -> nothing retried" || no "retry: ran before any apply"
  done_fx

  # NWP-20261119-13: the apply's writes, failed the same way (a directory at the target path).
  # S-W2: at sign-in (the record reset to absent) the merged pending file cannot be written.
  fresh; cp "$good" "$FILES/nowhere-sync"; mkdir "$FILES/nowhere-sync-pending.new"
  SYNCOUT="$LOGS/pendr" run "sync_apply 10"
  [ ! -e "$FILES/nowhere-sync-pending" ] && [ ! -e "$T/state/.syncapplied.10" ] && [ "$(cat "$T/state/.syncretry.10" 2>/dev/null)" = 1 ] \
    && logged 'pend lines malformed or not written' \
    && ok "S-W2: a pend-line merge that fails is not an applied sign-in; counted for a retry, logged" \
    || no "S-W2: a failed pend-line merge was taken as applied"
  done_fx
  # S-W2c: the same, over an existing pending record: it is kept byte for byte.
  fresh; cp "$good" "$FILES/nowhere-sync"; printf 'pend 1 a b c\n' > "$FILES/nowhere-sync-pending"; cp "$FILES/nowhere-sync-pending" "$LOGS/w2cpend"
  mkdir "$FILES/nowhere-sync-pending.new"; SYNCOUT="$LOGS/pendr" run "sync_apply_once 10 applied"
  cmp -s "$FILES/nowhere-sync-pending" "$LOGS/w2cpend" && [ ! -e "$T/state/.syncapplied.10" ] && [ "$(cat "$T/state/.syncretry.10" 2>/dev/null)" = 1 ] \
    && logged 'pend lines malformed or not written' \
    && ok "S-W2c: a pend-line merge that fails keeps the existing pending record" || no "S-W2c: a failed pend-line merge changed the pending record"
  done_fx
  # S-W2b: a failed apply's hand-back cannot be written -> the existing hand-back is kept.
  w2b="$LOGS/w2b"; printf 'ERR master=1 rows=2 applied=2 pending=0 mismatch=1\nfix 1 1 com.google gmail-ls %s\n' "$ACCT" > "$w2b"
  fresh; cp "$good" "$FILES/nowhere-sync"; printf '1\n' > "$T/state/.syncretry.10"
  printf 'fix 1 0 com.google gmail-ls %s\n' "$ACCT" > "$FILES/nowhere-sync-retry"; cp "$FILES/nowhere-sync-retry" "$LOGS/w2bhb"
  mkdir "$FILES/nowhere-sync-retry.tmp"; SYNCOUT="$w2b" SYNCRC=1 run "sync_apply_retry 10"
  cmp -s "$FILES/nowhere-sync-retry" "$LOGS/w2bhb" && [ "$(cat "$T/state/.syncretry.10" 2>/dev/null)" = 2 ] && [ ! -e "$T/state/.syncapplied.10" ] \
    && logged ', fix lines malformed or not written' \
    && ok "S-W2b: a hand-back write that fails keeps the existing hand-back, and says so" || no "S-W2b: a failed hand-back write removed or changed the hand-back"
  done_fx
  # S-W5: the merge itself still works: old and new pend lines, sorted, no temp left.
  fresh; cp "$good" "$FILES/nowhere-sync"; printf 'pend 1 a b c\n' > "$FILES/nowhere-sync-pending"
  SYNCOUT="$LOGS/pendr" run "sync_apply_once 10 applied"
  [ "$(cat "$FILES/nowhere-sync-pending" 2>/dev/null)" = "$(printf 'pend 1 a b c\n%s\n' "$pline" | sort -u)" ] && [ -e "$T/state/.syncapplied.10" ] \
    && [ ! -e "$FILES/nowhere-sync-pending.tmp" ] && [ ! -e "$FILES/nowhere-sync-pending.new" ] \
    && ok "S-W5: the pend lines merge into the existing record, sorted, with no temp left" || no "S-W5: the pend-line merge is wrong"
  done_fx

  # ================================ ordering: strictly after acct_reload, both paths =======================
  grant_run() {  # grant_run <deferred y|n> -> trace in $T/trace
    local body; body=$(printf '%s\n' "$GRANT" | sed "s#/data/#$T/data/#g")
    mkdir -p "$T/data/nowhere"
    [ "$1" = y ] && mkdir -p "$T/data/user/10/com.nowhere.chooser/.nowhere-odhold/com.google.android.gms"
    run "ACCT_AUTH_PKG=com.google.android.gms; PLAY_STORE_PKG=com.android.vending
nav_apply(){ echo nav_apply >> \"\$T/trace\"; }; aod_apply(){ echo aod_apply >> \"\$T/trace\"; }; home_pin(){ echo home_pin >> \"\$T/trace\"; }; a11y_apply(){ :; }; autofill_apply(){ :; }; shortcut_apply(){ :; }; keystore_register_all(){ :; }; ks_in_dir(){ return 1; }
grant_perms_for(){ :; }; _ms(){ echo 0; }; _tlog(){ :; }
acct_reload(){ echo acct_reload >> \"\$T/trace\"; }; sync_apply(){ echo sync_apply >> \"\$T/trace\"; }
$body"
  }
  order() { grep -E '^(acct_reload|sync_apply)$' "$T/trace" 2>/dev/null | tr '\n' ' '; }
  fresh; grant_run n
  [ "$(order)" = "acct_reload sync_apply " ] && ok "grant (installed path): sync_apply runs once, STRICTLY after acct_reload" || no "grant order: $(order)"
  done_fx
  fresh; grant_run y
  [ -z "$(order)" ] && logged 'sync: apply for user 10 deferred' \
    && ok "grant (deferred path): neither the reload nor the apply runs, and the deferral is logged" || no "grant deferred path ran an apply"
  done_fx

  GBLK=$(printf '%s\n' "$ODRES" | sed -n '/^    if \[ "\$pkg" = "\$ACCT_AUTH_PKG" \]; then$/,/^    fi$/p')
  if has acct_reload "$GBLK"; then
    gms_run() {
      SYNCOUT="$okr" run "pkg=com.google.android.gms; ACCT_AUTH_PKG=com.google.android.gms
wait_acct_authenticator(){ :; }
acct_reload(){ [ -e \"\$T/apargs\" ] && echo apply-before-reload >> \"\$T/trace\"; echo acct_reload >> \"\$T/trace\"; }
$(printf '%s\n' "$GBLK" | sed "s#/data/#$T/data/#g")"
    }
    # The REAL sync_apply, right after the reload, with a previous session's leftovers in place: it must run on this
    # path (a seal later would overwrite changes made since the reload) and reset what belongs to the old session.
    fresh; mkdir -p "$T/data/nowhere"; : > "$T/data/nowhere/acct-deferred-10"; cp "$good" "$FILES/nowhere-sync"
    printf 'pend 1 a b c\n' > "$FILES/nowhere-sync-pending"; printf 'old' > "$T/state/.syncfp.10"; printf '4 8\n' > "$T/state/.syncbo.10"
    gms_run
    [ "$(grep -v '^cmd \|^am ' "$T/trace" 2>/dev/null)" = acct_reload ] && [ "$(cat "$T/apargs" 2>/dev/null)" = "apply 10" ] && [ -e "$T/state/.syncapplied.10" ] \
      && ok "odrestore (deferred reload): the sync apply runs right there, STRICTLY after acct_reload" \
      || no "odrestore: trace '$(cat "$T/trace" 2>/dev/null | tr '\n' ' ')' apply '$(cat "$T/apargs" 2>/dev/null)'"
    [ ! -e "$FILES/nowhere-sync-pending" ] && [ ! -e "$T/state/.syncfp.10" ] && [ ! -e "$T/state/.syncbo.10" ] \
      && ok "odrestore: it is the full sign-in apply -- the previous session's pend file, fingerprint and backoff are reset" \
      || no "odrestore: a previous session's sync state survived the deferred apply"
    rm -f "$T/apargs"; SYNCOUT="$okr" run "sync_apply_retry 10"
    [ ! -e "$T/apargs" ] && ok "odrestore: once applied, the next seal applies nothing -- a change made since the reload is never overwritten" \
      || no "odrestore: the seal re-applied the record over the session's changes"
    done_fx
    # F3: a gms materialise with NO deferred reload (gms was installed at sign-in, its reload already ran) applies nothing.
    fresh; mkdir -p "$T/data/nowhere"; cp "$good" "$FILES/nowhere-sync"
    gms_run
    [ ! -e "$T/apargs" ] && ! grep -q acct_reload "$T/trace" 2>/dev/null \
      && ok "odrestore: without the acct-deferred marker there is no reload and no sync apply" || no "odrestore: applied sync outside the deferred-reload guard"
    done_fx
  else
    no "EXTRACTION FAILED -- odrestore's gms block"
  fi

  # The `in` op clears this uid's markers; the `out` op retries a failed sign-in apply, then captures.
  if has 'rm -f "$STATE/.vpnapplied.$uid" "$STATE/.syncapplied.$uid" "$STATE/.syncfp.$uid" "$STATE/.syncbo.$uid"' "$INARM" \
     && has '"$STATE/.syncretry.$uid" "$STATE/.vpndeferred.$uid" "$STATE/.vpnretry.$uid" 2>/dev/null' "$INARM"; then
    ok "in: a new session clears its uid's markers, fingerprint, backoff and retry count"
  else
    no "in: markers not cleared at session start"
  fi
  local outseq; outseq=$(grep -oE '^    (vpn_deferred_retry|vpn_seal_capture|sync_apply_retry|sync_seal_capture) ' <<<"$OUTARM" | tr -d ' ' | tr '\n' ' ')
  [ "$outseq" = "vpn_deferred_retry vpn_seal_capture sync_apply_retry sync_seal_capture " ] \
    && ok "out: every seal retries a deferred VPN, captures it, retries a failed sync apply, THEN captures sync" || no "out: sequence is '$outseq'"

  # ================================ #39: no account or profile name in any log line ========================
  if [ -s "$LOGS/all" ]; then
    if grep -qF -e "$ACCT" -e alice -e "$PROF" -e Zed "$LOGS/all"; then
      no "a log line carries an account or profile name: $(grep -nF -e alice -e Zed "$LOGS/all" | head -3)"
    else
      ok "no account or profile name in any of $(wc -l < "$LOGS/all" | tr -d ' ') log lines"
    fi
  else
    no "no log lines were collected -- the name check would be vacuous"
  fi
  rm -rf "$LOGS"
  [ -n "$quiet" ] || printf '  (%d ok, %d failed)\n' "$p" "$x"
  [ "$x" = 0 ]
}

# trunc_cases <script> <shell> [quiet] -> 0 iff each truncation failure branch behaved under that shell
# (NWP-20261121-13). Each site runs once with a writable target (the control) and once with the target planted as a
# DIRECTORY, which no shell and no uid can truncate. bash runs as bash --posix: plain bash survives a failed
# redirection on ':', which ends mksh, dash and sh. The -e capture guards read a directory as present, so nothing here
# asserts on a capture. Every name it assigns is local, as in suite.
trunc_cases() {
  local f="$1" sh="$2" quiet="${3:-}" psh p=0 x=0 FNS GRANT ODRES GBLK T U FILES TSO CTL good okr
  psh="$sh"; [ "$sh" = bash ] && psh="bash --posix"
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh" "$1"; }

  FNS=$(extract_fns "$f") || { no "EXTRACTION FAILED -- a sync/vpn function moved in $f"; return 1; }
  GRANT=$(arm "$f" grant); ODRES=$(arm "$f" odrestore)
  GBLK=$(printf '%s\n' "$ODRES" | sed -n '/^    if \[ "\$pkg" = "\$ACCT_AUTH_PKG" \]; then$/,/^    fi$/p')
  # The grant arm's acct_reload DEFERRED block comes with the arm (arm's anchor); this pins that it is in it.
  has 'GRANT acct_reload DEFERRED' "$GRANT" || { no "EXTRACTION FAILED -- the grant arm's acct_reload DEFERRED block"; return 1; }
  has acct-deferred- "$GBLK" || { no "EXTRACTION FAILED -- odrestore's gms block"; return 1; }
  CTL=$(mktemp -d -p "$W") || exit 2
  good="$CTL/good"; printf 'nowhere-sync 1\nmaster 1\nsync 1 com.google gmail-ls %s\nsync 0 com.google com.android.calendar %s\nend 2\n' "$ACCT" "$ACCT" > "$good"
  okr="$CTL/okr"; printf 'OK master=1 rows=2 applied=2 pending=0 mismatch=0\n' > "$okr"

  tfresh() {
    T=$(mktemp -d -p "$W") || exit 2; U="$T/data/user/10"; FILES="$U/com.nowhere.chooser/files"; TSO=""
    mkdir -p "$FILES" "$T/state" "$T/live" "$T/fw" "$T/data/nowhere"
    : > "$T/fw/nowhere-vpnao.jar"; : > "$T/fw/nowhere-syncroam.jar"
    printf 'tz=\nlocale=en-US\n' > "$FILES/nowhere-prefs"
  }
  tdone() { chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"; }
  # trun <shell text>: as suite's run, under $psh, with REACHED echoed after the text and stdout kept in $T/out.
  # $psh is unquoted on purpose: for bash it is two words, "bash --posix".
  trun() {
    T="$T" U="$U" LOG="$T/log" STATE="$T/state" RES="$T/res" SYNC_USER_ROOT="$T/data/user" VPN_USER_ROOT="$T/data/user" \
      SYNC_FP_ROOT="$T/data" NOWHERE_VPN_JAR="$T/fw/nowhere-vpnao.jar" NOWHERE_SYNC_JAR="$T/fw/nowhere-syncroam.jar" \
      APMODE=ok SETFAIL=0 SYNCOUT="$TSO" SYNCRC=0 TIMEOUTRC="" PICKWRITE="" \
      $psh -c "name='$PROF'; uid=10; USERDIR='$U'
$STUBS
$FNS
$1
echo REACHED" > "$T/out" 2>/dev/null
  }
  same() { if [ -e "$1" ] || [ -e "$2" ]; then cmp -s "$1" "$2"; else return 0; fi; }   # absent on both sides = equal
  # tsite <id> <marker> <setup> <call> <outcome text> <control stdout>
  tsite() {
    local id="$1" mk="$2" setup="$3" call="$4" want="$5" cout="$6" k
    tfresh; $setup; trun "$call"
    if [ "$(cat "$T/out")" = "${cout}REACHED" ] && [ -f "$T/state/$mk" ]; then ok "$id control writes $mk and answers '${cout:-nothing}'"
    else no "$id control: out '$(cat "$T/out")', $mk $([ -f "$T/state/$mk" ] && echo written || echo NOT written)"; fi
    rm -rf "$CTL/c"; mkdir "$CTL/c"
    for k in out apargs apstdin trace live/always_on_vpn_app; do [ -e "$T/$k" ] && cp "$T/$k" "$CTL/c/${k#live/}"; done
    tdone
    tfresh; $setup; mkdir "$T/state/$mk"; trun "$call"
    if case "$(cat "$T/out")" in *REACHED) true ;; *) false ;; esac; then ok "$id runs past the site ($mk a directory)"
    else no "$id did not run past the site ($mk a directory): '$(cat "$T/out")'"; fi
    if grep -qF -- "$want" "$T/log" 2>/dev/null; then ok "$id outcome logged ($mk a directory)"; else no "$id outcome not logged ($mk a directory): $(cat "$T/log" 2>/dev/null)"; fi
    if same "$T/out" "$CTL/c/out" && same "$T/apargs" "$CTL/c/apargs" && same "$T/apstdin" "$CTL/c/apstdin" && same "$T/trace" "$CTL/c/trace" \
       && same "$T/live/always_on_vpn_app" "$CTL/c/always_on_vpn_app"; then ok "$id answer and helper, cmd and settings calls match the control ($mk a directory)"
    else no "$id answer or calls differ from the control ($mk a directory): out '$(cat "$T/out")' apargs '$(cat "$T/apargs" 2>/dev/null)'"; fi
    tdone
  }
  sv1() { printf 'app=\nlockdown=0\n' > "$FILES/nowhere-vpn"; }
  sv2() { printf 'app=com.x\nlockdown=0\n' > "$FILES/nowhere-vpn"; mkdir -p "$U/com.x"; }
  sv3() { printf 'com.x 0 capture\n' > "$T/state/.vpndeferred.10"; printf 'com.other\n' > "$T/live/always_on_vpn_app"; }
  ss1() { :; }
  ss2() { printf 'garbage\n' > "$FILES/nowhere-sync"; }
  ss3() { cp "$good" "$FILES/nowhere-sync"; TSO="$okr"; }
  tsite V1 .vpnapplied.10 sv1 "vpn_apply 10" 'always-on VPN: none for user 10' 'OK NONE'
  tsite V2 .vpnapplied.10 sv2 "vpn_apply 10" 'always-on VPN -> com.x (lockdown=0' 'OK APPLIED'
  tsite V3 .vpnapplied.10 sv3 "vpn_deferred_retry 10" 'user 10 chose com.other in this session' ''
  tsite S1 .syncapplied.10 ss1 "sync_apply_once 10 apply" 'sync: no capture for user 10' ''
  tsite S2 .syncapplied.10 ss2 "sync_apply_once 10 apply" 'sync: capture for user 10 is malformed' ''
  tsite S3 .syncapplied.10 ss3 "sync_apply_once 10 apply" 'sync: apply for user 10: OK master=1' ''
  # S3's control must have run the helper, or two failed runs would compare equal
  if [ "$(cat "$CTL/c/apargs" 2>/dev/null)" = "apply 10" ]; then ok "S3 control ran the helper as apply 10"; else no "S3 control helper args '$(cat "$CTL/c/apargs" 2>/dev/null)'"; fi

  # G1: the grant arm's acct-deferred mark (the authenticator held on-demand), then the tap's odrestore
  tgrant() {
    trun "ACCT_AUTH_PKG=com.google.android.gms; PLAY_STORE_PKG=com.android.vending
nav_apply(){ :; }; aod_apply(){ :; }; home_pin(){ :; }; a11y_apply(){ :; }; autofill_apply(){ :; }; shortcut_apply(){ :; }; keystore_register_all(){ :; }; ks_in_dir(){ return 1; }
grant_perms_for(){ :; }; _ms(){ echo 0; }; _tlog(){ :; }
acct_reload(){ echo acct_reload >> \"\$T/trace\"; }; sync_apply(){ echo sync_apply >> \"\$T/trace\"; }
$(printf '%s\n' "$GRANT" | sed "s#/data/#$T/data/#g")"
  }
  tfresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.google.android.gms"; tgrant
  if [ -f "$T/data/nowhere/acct-deferred-10" ] && [ "$(cat "$T/res" 2>/dev/null)" = OK ]; then ok "G1 control writes acct-deferred-10 and replies OK"
  else no "G1 control: mark $([ -f "$T/data/nowhere/acct-deferred-10" ] && echo written || echo NOT written), reply '$(cat "$T/res" 2>/dev/null)'"; fi
  tdone
  tfresh; mkdir -p "$U/com.nowhere.chooser/.nowhere-odhold/com.google.android.gms" "$T/data/nowhere/acct-deferred-10"; tgrant
  if [ "$(tail -n 1 "$T/out")" = REACHED ]; then ok "G1 the grant arm runs past the site (acct-deferred-10 a directory)"
  else no "G1 the grant arm did not run past the site (acct-deferred-10 a directory): '$(cat "$T/out")'"; fi
  local la lb
  la=$(grep -n 'GRANT acct_reload DEFERRED' "$T/log" 2>/dev/null | head -n 1 | cut -d: -f1)
  lb=$(grep -n 'sync: apply for user 10 deferred' "$T/log" 2>/dev/null | head -n 1 | cut -d: -f1)
  if [ -n "$la" ] && [ -n "$lb" ] && [ "$lb" -gt "$la" ]; then ok "G1 GRANT acct_reload DEFERRED, then the sync deferral, logged (acct-deferred-10 a directory)"
  else no "G1 deferral lines missing or out of order (acct-deferred-10 a directory): $(cat "$T/log" 2>/dev/null)"; fi
  if [ "$(cat "$T/res" 2>/dev/null)" = OK ]; then ok "G1 the grant reply is written (acct-deferred-10 a directory)"; else no "G1 no grant reply (acct-deferred-10 a directory): '$(cat "$T/res" 2>/dev/null)'"; fi
  if [ ! -e "$T/trace" ] || ! grep -qE '^(acct_reload|sync_apply)$' "$T/trace"; then ok "G1 the grant runs neither acct_reload nor sync_apply (acct-deferred-10 a directory)"
  else no "G1 the grant ran: $(tr '\n' ' ' < "$T/trace")"; fi
  # the tap's odrestore, the directory still in place: its -f reader sees no mark
  rm -f "$T/trace" "$T/apargs"; cp "$good" "$FILES/nowhere-sync"; TSO="$okr"
  trun "pkg=com.google.android.gms; ACCT_AUTH_PKG=com.google.android.gms
wait_acct_authenticator(){ :; }
acct_reload(){ echo acct_reload >> \"\$T/trace\"; }
$(printf '%s\n' "$GBLK" | sed "s#/data/#$T/data/#g")"
  if [ "$(tail -n 1 "$T/out")" = REACHED ] && [ ! -e "$T/apargs" ] && ! grep -q acct_reload "$T/trace" 2>/dev/null; then
    ok "G1 odrestore: with the mark a directory, the -f reader sees no mark -> no reload and no sync apply"
  else no "G1 odrestore with the mark a directory: out '$(cat "$T/out")' trace '$(tr '\n' ' ' < "$T/trace" 2>/dev/null)' apply '$(cat "$T/apargs" 2>/dev/null)'"; fi
  tdone

  rm -rf "$CTL"
  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh" "$p" "$x"
  [ "$x" = 0 ]
}

echo "== as committed =="
suite "$SUT"; RC=$?
for s in $SHELLS; do
  echo "== truncation failure branches as committed [$s] =="
  trunc_cases "$SUT" "$s" || RC=1
done
[ "$MUTATE" = no ] && { echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; }
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo; echo "== mutations (each MUST be convicted) =="
MRC=0
# A mutant that did not apply is not evidence (test-aod-roam.sh): each is verified non-empty and DIFFERENT first.
apply_mut() {  # $1 dest, $2.. sed args
  local d="$1"; shift
  sed "$@" "$SUT" > "$d" 2>/dev/null || return 1
  [ -s "$d" ] || return 1
  ! cmp -s "$d" "$SUT"
}
# verdict <mutant|control|trunc> <label> <sed args...> -> one line, or one line per shell for trunc (judged by
# trunc_cases). A mutant or a trunc mutant must be CONVICTED; a control must SURVIVE.
verdict() {
  local kind="$1" l="$2" m tag="" sh; shift 2; m=$(mktemp -p "$W") || exit 2
  [ "$kind" = control ] && tag="CONTROL: "
  if ! apply_mut "$m" "$@"; then
    printf '  ⚠ NOT APPLIED  %s%s -- sed failed or changed nothing; NOT a conviction\n' "$tag" "$l"; rm -f "$m"; return
  fi
  if [ "$kind" = trunc ]; then
    for sh in $SHELLS; do
      if trunc_cases "$m" "$sh" quiet >/dev/null; then printf '  ⚠ SURVIVED  %s [%s]\n' "$l" "$sh"; else printf '  convicted   %s [%s]\n' "$l" "$sh"; fi
    done
    rm -f "$m"; return
  fi
  if suite "$m" quiet; then
    if [ "$kind" = mutant ]; then printf '  ⚠ SURVIVED  %s\n' "$l"; else printf '  ok (survived) CONTROL: %s\n' "$l"; fi
  else
    if [ "$kind" = mutant ]; then printf '  convicted   %s\n' "$l"; else printf '  ⚠ CONVICTED  CONTROL: %s\n' "$l"; fi
  fi
  rm -f "$m"
}
# Sequentially (the default) each verdict prints as it lands; with MUTJOBS > 1 that many run at once and the verdicts
# print in order at the end. EXP counts the pass lines expected: one per mutant or control, one per shell per trunc.
MN=0; EXP=0; MTMP=$(mktemp -d -p "$W") || exit 2
queue() {
  MN=$((MN + 1))
  if [ "$1" = trunc ]; then EXP=$((EXP + NSH)); else EXP=$((EXP + 1)); fi
  if [ "${MUTJOBS:-1}" -gt 1 ]; then
    while [ "$(jobs -rp | wc -l)" -ge "$MUTJOBS" ]; do command sleep 0.2; done
    verdict "$@" > "$MTMP/$MN.res" &
  else
    verdict "$@" | tee "$MTMP/$MN.res"
  fi
}
mutant() { queue mutant "$@"; }
control() { queue control "$@"; }
truncmut() { queue trunc "$@"; }
mutant "grant applies sync BEFORE acct_reload" \
  -e '/^      sync_apply "\$uid"   # NWP-20261010-15: STRICTLY after acct_reload/d' \
  -e 's/^      acct_reload "\$uid"$/      sync_apply "$uid"\n      acct_reload "$uid"/'
mutant "grant's deferred branch applies sync anyway (before the accounts exist)" \
  -e 's/^      echo "\[roamd\] sync: apply for user \$uid deferred.*$/      sync_apply "$uid"/'
mutant "sync capture runs before this session's apply" \
  -e 's/^  if \[ ! -e "\$STATE\/.syncapplied.\$_uid" \]; then$/  if false; then/'
mutant "vpn capture runs before this session's apply" \
  -e 's/^  if \[ ! -e "\$STATE\/.vpnapplied.\$_uid" \]; then$/  if false; then/'
mutant "vpnup re-arms the block at once (lockdown=1, the 2026-09-25 trap)" \
  -e 's/^  _mode=0; \[ "\$_lock" = 1 \] && _mode=defer$/  _mode=0; [ "$_lock" = 1 ] \&\& _mode=1/'
mutant "vpnup applies a carried OFF through the deferring consent" \
  -e 's/^  _mode=0; \[ "\$_lock" = 1 \] && _mode=defer$/  _mode=defer/'
mutant "vpnup trusts the call instead of the read-back" \
  -e 's/local _ok=no$/local _ok=yes/' -e 's/^  \[ "\$_ok" = yes \] || { printf .NOTREADY.; return 0; }$/  :/'
mutant "an OFF read back with the block on is accepted (L1)" \
  -e 's/^      \[ "\$_ld" != 1 \] && \[ "\$_pd" != "\$_pkg" \] && _ok=yes$/      [ "$_pd" != "$_pkg" ] \&\& _ok=yes/'
mutant "an OFF read back with the block pending is accepted (L1)" \
  -e 's/^      \[ "\$_ld" != 1 \] && \[ "\$_pd" != "\$_pkg" \] && _ok=yes$/      [ "$_ld" != 1 ] \&\& _ok=yes/'
mutant "a pending block is not captured as on" \
  -e '/^    \[ -n "\$_pend" \] && \[ "\$_pend" = "\$_app" \] && _eff=1$/d'
mutant "the capture outranks the picker's pick" \
  -e 's/^  for _f in "\$1" "\$2"; do$/  for _f in "$2" "$1"; do/'
mutant "the pick is never consumed" \
  -e 's/^  \[ "\$_src" = pick \] && vpn_pick_consume "\$_vf" "\$_pick"   # the pick is now the live state$/  :/'
mutant "the pick is removed whatever it now says (L4)" \
  -e 's/^  \[ "\$(cat "\$1\/nowhere-vpn-pick" 2>\/dev\/null)" = "\$2" \] && rm -f/  rm -f/'
mutant "no helper answers a bare OK again (#122)" \
  -e "s/^    printf 'OK NOHELPER'; return 0$/    printf 'OK'; return 0/"
mutant "an on-demand VPN app is no longer deferred (M3)" \
  -e 's/^  if \[ -d "\$_ud\/com.nowhere.chooser\/.nowhere-odhold\/\$_pkg" \]; then$/  if false; then/'
mutant "vpnup's helper runs unbounded (M2)" \
  -e 's/timeout "\${NOWHERE_VPN_TIMEOUT:-20}" app_process/app_process/'
mutant "the sync helper runs unbounded (M2)" \
  -e 's/^    timeout "\$SYNC_TIMEOUT" app_process/    app_process/'
mutant "sync apply marks applied whatever the helper said" \
  -e 's/^    "OK "\*)$/    *)/'
mutant "pend lines are dropped instead of kept (H2)" \
  -e '/^sync_take_pend() {$/,/^}$/s/^  if \[ "\$_k" = 0 \]; then$/  if :; then/'
mutant "a malformed pend line is accepted" \
  -e 's/^  \[ "\$(grep -c .^pend . "\$_o" 2>\/dev\/null)" = .*|| return 1$/  :/'
mutant "a stale pend file survives into the next sign-in" \
  -e 's/^  rm -f "\$_bd\/nowhere-sync-pending" "\$_bd\/nowhere-sync-retry" /  rm -f "$_bd\/nowhere-sync-retry" /'
mutant "sign-in keeps the stale fingerprint (S8)" \
  -e 's/ "\$_bd\/nowhere-sync-retry" "\$STATE\/.syncfp.\$_uid" / "$_bd\/nowhere-sync-retry" /'
mutant "the capture is not given the pend lines (they would be re-read as 0)" \
  -e '/^sync_seal_capture() {$/,/^}$/{/^  if \[ -e "\$_bd\/nowhere-sync-pending" \]; then set -- "\$@" "\$_bd\/nowhere-sync-pending"; fi$/d}'
mutant "the capture ignores the helper's rc (S10)" \
  -e 's/^  if \[ "\$_rc" = 0 \] && sync_capture_valid "\$_out.tmp"/  if sync_capture_valid "$_out.tmp"/'
mutant "the fingerprint is stored even when the capture failed (S4)" \
  -e '/^sync_seal_capture() {$/,/^}$/s/^  set --$/  [ -n "$_fp" ] \&\& printf "%s" "$_fp" > "$STATE\/.syncfp.$_uid"; &/' \
  -e '/^    \[ -n "\$_fp" \] && printf .%s. "\$_fp" > "\$STATE\/.syncfp.\$_uid" 2>\/dev\/null$/d'
mutant "the fingerprint gate skips whatever changed (L7)" \
  -e 's/^  if \[ -n "\$_fp" \] && \[ -f "\$_out" \] && \[ "\$_fp" = "\$(cat "\$STATE\/.syncfp.\$_uid" 2>\/dev\/null)" \]; then$/  if [ -f "$STATE\/.syncfp.$_uid" ]; then/'
mutant "the fingerprint ignores the account db's -wal" \
  -e 's/ "\$_r\/system_ce\/\$_uid\/accounts_ce.db-wal" \\$/ \\/'
mutant "pending switches are retried at every seal (no backoff, F3)" \
  -e 's/^    if \[ "\$_w" -gt 0 \]; then$/    if false; then/'
mutant "pending switches are never retried without a change (F3)" \
  -e 's/^    _why=backoff$/    return 0/'
mutant "the backoff does not grow (F3)" \
  -e 's/_nx=\$((_nx \* 2))/_nx=$((_nx * 1))/'
mutant "the backoff is not capped (F3)" \
  -e 's/\[ "\$_nx" -gt 32 \] && _nx=32/:/'
mutant "a failed sign-in apply is never retried (F2)" \
  -e '/^    sync_apply_retry "\$uid"              # NWP-20261010-15/d'
mutant "the apply retry is unbounded (F2)" \
  -e 's/^  if \[ "\$_n" -ge "\$SYNC_APPLY_TRIES" \]; then$/  if false; then/'
mutant "the sync capture validation drops its line count" \
  -e 's/^  \[ "\$(wc -l < "\$_f" 2>\/dev\/null | tr -cd .0-9.)" = "\$((_n + 3))" \] || return 1$/  :/'
mutant "the helper's answer is printed whatever its shape (L2)" \
  -e "s/^    printf 'unrecognised answer'$/    printf '%s' \"\$_l\"/"
mutant "the sync capture is logged whole (account names in roam.log)" \
  -e 's/^    echo "\[roamd\] sync: captured master=\$_m and/    cat "$_out" >> "$LOG"; echo "[roamd] sync: captured master=$_m and/'
mutant "the in op stops clearing the markers" \
  -e 's/^    rm -f "\$STATE\/.vpnapplied.\$uid" "\$STATE\/.syncapplied.\$uid" .*$/    :/'
mutant "out captures sync BEFORE retrying a failed apply" \
  -e '/^    sync_apply_retry "\$uid"              # NWP-20261010-15/d' \
  -e 's/^    sync_seal_capture "\$USERDIR" "\$uid"  # NWP-20261010-15: account sync switches, same dir, same seal$/&\n    sync_apply_retry "$uid"/'
mutant "the deferred VPN is never retried at a seal (M3/round 4)" \
  -e '/^    vpn_deferred_retry "\$uid"            # NWP-20261010-15/d'
mutant "the deferred VPN retry is unbounded" \
  -e 's/^  if \[ "\$_n" -ge "\$VPN_APPLY_TRIES" \]; then$/  if false; then/'
mutant "odrestore blocks on the VPN apply again" \
  -e 's/^    # ⚠⚠ NWP-20260922-09: THREE OUTCOMES, NOT TWO\. /    _odvpn=$(vpn_apply "$uid")\n&/'
mutant "the fingerprint ignores the sync-adapter set (round 4)" \
  -e 's/ "\$_rs\/android.content.SyncAdapter.xml" / /'
mutant "the fingerprint ignores the authenticator set (round 4)" \
  -e 's/ "\$_rs\/android.accounts.AccountAuthenticator.xml"; do$/; do/'
mutant "the fingerprint watches packages.list again (churn)" \
  -e 's/ "\$_rs\/android.accounts.AccountAuthenticator.xml"; do$/ "$_rs\/android.accounts.AccountAuthenticator.xml" "$_r\/system\/packages.list"; do/'
mutant "the stat line is not logged" \
  -e 's/^    \[ -n "\$_st" \] && echo/    [ -z "$_st" ] \&\& echo/'
mutant "a malformed stat line is accepted" \
  -e 's/^     && \[ "\$(grep -c .^stat . "\$_out.raw" 2>\/dev\/null)" = "\$(printf .*\\$/     \\/'
mutant "F1: the deferred carry replaces a VPN the user chose this session" \
  -e 's/^  if \[ "\$_live" != null \] && \[ "\$_live" != "\$_pkg" \]; then$/  if false; then/'
mutant "F1: an unreadable live setting is taken as a different choice" \
  -e 's/^  \[ -n "\$_live" \] || return 0$/  :/'
mutant "F2: the seal retry re-chooses (and applies this session's pick)" \
  -e 's/^  _r=\$(vpn_apply_choice "\$_uid" "\$_src" "\$_pkg" "\$_lock" .*$/  _r=$(vpn_apply "$_uid")/'
mutant "F2: the retry consumes whatever pick is there" \
  -e 's/^  \[ "\$(cat "\$1\/nowhere-vpn-pick" 2>\/dev\/null)" = "\$2" \] && rm -f/  rm -f/'
mutant "the seal retry runs while the app is still held" \
  -e 's/^  \[ -d "\${VPN_USER_ROOT:-\/data\/user}\/\$_uid\/com.nowhere.chooser\/.nowhere-odhold\/\$_pkg" \] && return 0   # still held$/  :/'
mutant "R1: the fingerprint keeps the size only" \
  -e "s/stat -c '%Y:%s' \"\$_f\"/stat -c '%s' \"\$_f\"/"
mutant "R2: a failed stat on an existing file is fingerprinted as -" \
  -e "s/^      _s=\$(stat -c '%Y:%s' \"\$_f\" 2>\/dev\/null) || return 0$/      _s=\$(stat -c '%Y:%s' \"\$_f\" 2>\/dev\/null) || _s=-/" \
  -e 's/^      \[ -n "\$_s" \] || return 0$/      [ -n "$_s" ] || _s=-/'
mutant "round 6: the user's choice leaves a pick-sourced deferral's pick in place" \
  -e '/^    \[ "\$_src" = pick \] && vpn_pick_consume "\${VPN_USER_ROOT:-\/data\/user}\/\$_uid\/com.nowhere.chooser\/files"/d'
mutant "round 6: odrestore no longer applies sync after the deferred reload" \
  -e '/^        sync_apply "\$uid"$/d'
mutant "round 6 / M-c: odrestore runs the bare apply, skipping the per-session reset" \
  -e 's/^        sync_apply "\$uid"$/        sync_apply_once "$uid" applied/'
mutant "round 6: odrestore applies sync BEFORE the deferred reload" \
  -e '/^        sync_apply "\$uid"$/d' \
  -e 's/^        acct_reload "\$uid"; rm -f "\/data\/nowhere\/acct-deferred-\$uid" 2>>"\$LOG"$/        sync_apply "$uid"\n&/'
mutant "round 7: the retry re-runs the full apply (overwrites the session's changes)" \
  -e 's/^  sync_apply_once "\$_uid" "apply retried" retry$/  sync_apply_once "$_uid" "apply retried"/'
mutant "round 7: the retry ignores the hand-back and works from the whole record" \
  -e 's/^      _in="\$_bd\/nowhere-sync-retry"$/      :/'
mutant "round 7: a failed apply's hand-back is not kept" \
  -e 's/^      sync_keep_lines "\$_o" "\$_bd" || _a="\$_a, fix lines malformed or not written" ;;$/      : ;;/'
mutant "round 7: sign-in keeps a previous session's hand-back" \
  -e 's/^  rm -f "\$_bd\/nowhere-sync-pending" "\$_bd\/nowhere-sync-retry" /  rm -f "$_bd\/nowhere-sync-pending" /'
mutant "round 7 / F3: odrestore applies sync outside the deferred-reload guard" \
  -e '/^        sync_apply "\$uid"$/d' \
  -e '/^        echo "\[roamd\] odrestore \$pkg -> deferred acct_reload fired/{n;s/^      fi$/      fi\n      sync_apply "$uid"/}'
mutant "round 7 / F4: the drop branch consumes the pick whatever the deferral's source" \
  -e 's/^    \[ "\$_src" = pick \] && vpn_pick_consume "\${VPN_USER_ROOT/    vpn_pick_consume "${VPN_USER_ROOT/'
mutant "round 7: BRE alternation (no-op on Android's grep) in the capture split" \
  -e "s/^  grep -Ev '^(pend|stat) ' /  grep -v '^pend \\\\|^stat ' /"
mutant "round 8: a GNU-only BRE plus in a sed (no-op on Android)" \
  -e "s/^  _src=\${_c%% \*}; _r=\${_c#\* }; _pkg=\${_r%% \*}; _lock=\${_r#\* }$/&; _x=\$(echo a | sed 's\/a\\\\+\/b\/')/"
mutant "round 9: a malformed hand-back is fed to the helper" \
  -e 's/^    if grep -Evq .^(fix \[01\] \[01-\] .*nowhere-sync-retry" 2>\/dev\/null; then$/    if false; then/'
mutant "W1: the WireGuard raise line logs the bare tunnel name" \
  -e 's/\[roamd\] WG raise tunnel \$(qn "\$_wg")/[roamd] WG raise tunnel $_wg/'
# NWP-20261119-13: a write that fails is not "no pend lines" (S-W1..S-W4, S-W2b).
mutant "sync_take_pend goes back to the if-grep/else-rm shape (S-W1)" \
  -e '/^sync_take_pend() {$/,/^}$/s/^  rm -f "\$_bd\/nowhere-sync-pending.tmp" 2>\/dev\/null$/  rm -f "$_bd\/nowhere-sync-pending.tmp" "$_bd\/nowhere-sync-pending" 2>\/dev\/null; return 0/'
mutant "sync_take_pend's count comparison on the tmp is removed (S-W1b)" \
  -e '/^sync_take_pend() {$/,/^}$/{/^     && \[ "\$(grep -c .^pend . "\$_bd\/nowhere-sync-pending.tmp" 2>\/dev\/null)" = "\$_k" \] \\$/d}'
mutant "sync_keep_lines installs .new without checking sort (S-W2)" \
  -e '/^sync_keep_lines() {$/,/^}$/s/^    if \[ "\$_rc" = 0 \] && \[ -s "\$_bd\/nowhere-sync-pending.new" \] \\$/    if : \\/'
mutant "the fix-line write failure removes the hand-back (S-W2b)" \
  -e '/^sync_keep_lines() {$/,/^}$/s/^  rm -f "\$_bd\/nowhere-sync-retry.tmp" 2>\/dev\/null$/  rm -f "$_bd\/nowhere-sync-retry.tmp" "$_bd\/nowhere-sync-retry" 2>\/dev\/null/'
mutant "the staging status is ignored (S-W3: the helper runs)" \
  -e '/^sync_seal_capture() {$/,/^}$/s/^  if \[ "\$_rc" != 0 \]; then$/  if false; then/'
mutant "a count of 0 keeps the record (S-W4)" \
  -e '/^sync_take_pend() {$/,/^}$/s/^    rm -f "\$_bd\/nowhere-sync-pending.tmp" "\$_bd\/nowhere-sync-pending" 2>\/dev\/null$/    rm -f "$_bd\/nowhere-sync-pending.tmp" 2>\/dev\/null/'
# NWP-20261121-13: one site's subshell reverted to the bare ': >', scoped to its function or arm and to that line.
truncmut "V1 vpn_apply's NONE .vpnapplied truncation is bare again" \
  -e '/^vpn_apply() {$/,/^}$/{/^  if \[ -z "\$_pkg" \]; then$/,/printf .OK NONE./s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
truncmut "V2 vpn_apply_choice's APPLIED .vpnapplied truncation is bare again" \
  -e '/^vpn_apply_choice() {$/,/^}$/{/# the pick is now the live state/,/printf .OK APPLIED./s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
truncmut "V3 vpn_deferred_retry's user-choice .vpnapplied truncation is bare again" \
  -e '/^vpn_deferred_retry() {$/,/^}$/{/^  if \[ "\$_live" != null \]/,/chose \$_live in this session/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
truncmut "S1 sync_apply_once's no-capture .syncapplied truncation is bare again" \
  -e '/^sync_apply_once() {$/,/^}$/{/^  if \[ ! -f "\$_f" \]; then$/,/no capture for user/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
truncmut "S2 sync_apply_once's malformed .syncapplied truncation is bare again" \
  -e '/^sync_apply_once() {$/,/^}$/{/^  if ! sync_capture_valid "\$_f"; then$/,/is malformed -> nothing applied/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
truncmut "S3 sync_apply_once's OK .syncapplied truncation is bare again" \
  -e '/^sync_apply_once() {$/,/^}$/{/^      if sync_keep_lines "\$_o" "\$_bd"; then$/,/sync: \$_what for user/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
truncmut "G1 the grant arm's acct-deferred mark is bare again" \
  -e '/^  grant)$/,/^    ;;$/{/^    if \[ -d "\/data\/user\/\$uid\/com.nowhere.chooser\/.nowhere-odhold\/\$ACCT_AUTH_PKG" \]; then$/,/GRANT acct_reload DEFERRED/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
# CONTROL: the suite pins behaviour, not wording it does not assert.
control "the WireGuard raise line reworded" \
  -e 's/\[roamd\] WG raise tunnel \$(qn "\$_wg")/[roamd] WireGuard tunnel $(qn "$_wg") raised/'
wait
if [ "${MUTJOBS:-1}" -gt 1 ]; then i=1; while [ "$i" -le "$MN" ]; do cat "$MTMP/$i.res"; i=$((i + 1)); done; fi
[ "$(cat "$MTMP"/*.res | grep -c 'convicted   \|ok (survived) CONTROL')" = "$EXP" ] || MRC=1
rm -rf "$MTMP"
echo; [ "$MRC" = 0 ] && echo "all mutations convicted, control survived" || echo "⚠ a mutation survived or the control was convicted"
exit $MRC
