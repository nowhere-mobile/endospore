#!/usr/bin/env bash
# test-vpn-apply-on-install.sh [<nowhere_roamd.sh>] [--mutate] -- the deferred always-on VPN is applied in the bootwake
# op's per-package step, after the app's restore (NWP-20261130-04).
#
# WHY THIS IS COMMITTED. A profile's always-on VPN app can be an on-demand app whose data is still held at sign-in, so
# vpnup defers the VPN. The daemon holds periodic seals for the whole Auto sweep, and the seal was the only retry, so the
# app was installed and the VPN stayed off for most of the sign-in (frankel 0.5.53, 2026-11-06). Nothing reports that.
#
# roamd's cutoff functions, bootwake_list, the bootwake arm, vpn_apply_choice, vpn_pick_consume and vpn_deferred_retry
# are extracted BY ANCHOR and run against a fake device: `pm`, `am`, `settings`, `cmd` and `app_process` (the helper) are
# stubbed, every call is recorded in order, and the helper writes the live settings as the framework does. The arm's
# /data paths are re-rooted under the case's root. Every case runs under each shell found (bash, dash, mksh, and sh when
# it is not one of them). Each negative case ends with a control leg in which the apply lands, so it fails on code that
# never applies.
#
#   bash test-vpn-apply-on-install.sh            # the cases
#   bash test-vpn-apply-on-install.sh --mutate   # ... plus mutations that the named assertion must convict, each shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh run under their own names; sh only when it is not the same binary as one of them.
SHELLS=()
if [ -n "${ONLY_SHELL:-}" ]; then
  case "$ONLY_SHELL" in bash|sh|dash|mksh) ;; *) echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2 ;; esac
  command -v "$ONLY_SHELL" >/dev/null 2>&1 || { echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2; }
  SHELLS=("$ONLY_SHELL")
else
  for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done
  if p=$(command -v sh 2>/dev/null); then
    r=$(readlink -f "$p"); dup=""
    for s in "${SHELLS[@]}"; do [ "$(readlink -f "$(command -v "$s")")" = "$r" ] && { dup=$s; break; }; done
    if [ -n "$dup" ]; then echo "skip shell sh: same binary as $dup"; else SHELLS+=(sh); fi
  fi
fi
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=all; SHP=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
# func <name>: one function, from its label to the first closing brace in column 0.
func() { awk -v l="$1() {" '$0==l{on=1} on{print} on&&/^}$/{exit}' "$SUT"; }
F=$(awk '/^CUTOFF_BUDGET=/{on=1} on{print} on&&/^cutoff_run\(\) \{/{last=1} last&&/^}$/{exit}' "$SUT")
L=$(func bootwake_list)
A=$(awk -v l="  bootwake)" '$0==l{on=1} on{print} on&&/^    ;;$/{exit}' "$SUT")
C=$(func vpn_apply_choice)
K=$(func vpn_pick_consume)
R=$(func vpn_deferred_retry)
T=$(grep -m1 -E '^VPN_APPLY_TRIES=' "$SUT")
ODH=$(grep -m1 -E '^ODHOLD=' "$SUT")
case "$F" in *'cutoff_run()'*) ;; *) echo "EXTRACTION FAILED: the cutoff functions in $SUT" >&2; exit 2 ;; esac
case "$L" in *'query-receivers'*) ;; *) echo "EXTRACTION FAILED: bootwake_list in $SUT" >&2; exit 2 ;; esac
case "$A" in *'cutoff_run boot'*) ;; *) echo "EXTRACTION FAILED: the bootwake arm in $SUT" >&2; exit 2 ;; esac
case "$C" in *'np.VpnAlwaysOn'*) ;; *) echo "EXTRACTION FAILED: vpn_apply_choice in $SUT" >&2; exit 2 ;; esac
case "$K" in *'nowhere-vpn-pick'*) ;; *) echo "EXTRACTION FAILED: vpn_pick_consume in $SUT" >&2; exit 2 ;; esac
case "$R" in *'.vpndeferred'*) ;; *) echo "EXTRACTION FAILED: vpn_deferred_retry in $SUT" >&2; exit 2 ;; esac
[ -n "$T" ] || { echo "EXTRACTION FAILED: VPN_APPLY_TRIES= not found in $SUT" >&2; exit 2; }
[ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $SUT" >&2; exit 2; }
RA=$(printf '%s\n' "$A" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
n=$(printf '%s\n' "$RA" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/')
[ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the bootwake arm keeps $n absolute /data path(s) in live code" >&2; exit 2; }

# --- the fake device ------------------------------------------------------------------------------------
# POSIX stubs, run inside each case's run file under each shell. `_st_*` names never meet roamd's.
#   pm list packages                     -> one line per $ROOT/pk/<name>; nothing if $ROOT/listfail
#   pm query-receivers ... -a <ACTION>   -> $ROOT/rcv.BOOT for BOOT_COMPLETED, nothing else declares
#   am broadcast -p <pkg> ...            -> recorded as `broadcast <pkg>`; `pm unstop` as `unstop <pkg>`
#   settings get --user U secure <key>   -> $ROOT/live/<key>, else null; prints nothing if $ROOT/setfail; counted
#   app_process ... np.VpnAlwaysOn U P M -> recorded as `helper U P M`; writes the live settings as the framework does,
#                                           unless $ROOT/helperfail; records in $ROOT/atreply whether $RES already exists
STUBS=$(cat <<'EOF'
timeout(){ if [ "$1" = -k ]; then shift 3; else shift 1; fi; "$@"; }
pm(){
  case "$1" in
    list)
      [ -e "$ROOT/listfail" ] && return 0
      for _st_q in "$ROOT"/pk/*; do printf 'package:%s stopped=%s uid:%s\n' "${_st_q##*/}" "$(cat "$_st_q")" 1010123; done ;;
    query-receivers)
      case "$*" in *android.intent.action.BOOT_COMPLETED*) cat "$ROOT/rcv.BOOT" ;; *) echo 'No receivers found' ;; esac ;;
    unstop) echo "unstop $4" >> "$ROOT/calls" ;;
    *) echo "unexpected pm $*" >> "$ROOT/calls" ;;
  esac
  return 0
}
am(){
  case "$1" in
    broadcast)
      shift; _st_p=""
      while [ $# -gt 0 ]; do case "$1" in -p) _st_p=$2; shift ;; esac; shift; done
      echo "broadcast $_st_p" >> "$ROOT/calls" ;;
    *) echo "unexpected am $*" >> "$ROOT/calls" ;;
  esac
  return 0
}
settings(){
  echo "settings $5" >> "$ROOT/setcalls"
  [ -e "$ROOT/setfail" ] && return 0
  if [ -s "$ROOT/live/$5" ]; then cat "$ROOT/live/$5"; else echo null; fi
  return 0
}
cmd(){ echo "cmd $*" >> "$ROOT/cmdcalls"; return 0; }
app_process(){
  echo "helper $3 $4 $5" >> "$ROOT/calls"
  if [ -e "$RES" ]; then echo present >> "$ROOT/atreply"; else echo absent >> "$ROOT/atreply"; fi
  [ -e "$ROOT/helperfail" ] && return 0
  echo "$4" > "$ROOT/live/always_on_vpn_app"
  if [ "$5" = defer ]; then echo "$4" > "$ROOT/live/nowhere_vpn_lockdown_pending"; else echo 0 > "$ROOT/live/always_on_vpn_lockdown"; fi
  return 0
}
EOF
)
BODY=$(printf '%s\n' "$ODH" "$F" "$L" "$K" "$C" "$T" "$R" 'umask 022' 'case "$op" in' "$RA" '  seal)' '    vpn_deferred_retry "$uid"' '    ;;' 'esac')

# The session of the cases, for user 10. com.vpn.tail (the VPN app, declares a boot receiver), com.vpn.quiet (a VPN app
# with no boot receiver) and com.other (any other restored app, declares one) are installed with their data dirs.
DECL=2
session() {
  local d n
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/pk" "$d/state" "$d/live" "$d/data/user/10/com.nowhere.chooser/files" "$d/data/user/10/com.vpn.tail" \
    "$d/data/user/10/com.vpn.quiet" "$d/data/user/10/com.other" "$d/data/user_de/10" "$d/data/media/10/Android/data" \
    "$d/data/media/10/Android/obb"
  for n in calls setcalls cmdcalls atreply log stderr vpn.jar; do ( : > "$d/$n" ); done
  for n in com.nowhere.chooser com.vpn.tail com.vpn.quiet com.other; do echo true > "$d/pk/$n"; done
  printf '%s\n' '  com.vpn.tail/.Boot' '  com.other/.Boot' > "$d/rcv.BOOT"
  printf '%s\n' "$d"
}
# script <root> <op> <srcunit>: one op over the device under "$SHP". RES lands in <root>/res, fresh for each op.
script() {
  local d="$1" o="$2" s="$3"
  rm -f "$d/res"
  {
    printf "ROOT='%s'; uid=10; STATE=\"\$ROOT/state\"; RES=\"\$ROOT/res\"; LOG=\"\$ROOT/log\"; srcunit='%s'; op=%s\n" "$d" "$s" "$o"
    printf "NOWHERE_CUTOFF_BUDGET=45; NOWHERE_CUTOFF_PAR=8; VPN_USER_ROOT=\"\$ROOT/data/user\"; NOWHERE_VPN_JAR=\"\$ROOT/vpn.jar\"\n"
    printf '%s\n' "$STUBS" "$BODY"
  } > "$d/run.sh" || return 2
  "$SHP" "$d/run.sh" >/dev/null 2>>"$d/stderr"
}
install() { script "$1" bootwake "$2"; }   # the bootwake op's per-package step for <pkg>; "" is the all-package pass
seal() { script "$1" seal ""; }            # what the `out` arm runs at the top of a seal
defer() { printf '%s %s %s\n' "$2" "$3" "$4" > "$1/state/.vpndeferred.10"; }
res() { cat "$1/res" 2>/dev/null; }
helpers() { grep -c '^helper ' "$1/calls"; }
helper1() { grep -m1 '^helper ' "$1/calls"; }
setn() { grep -c . "$1/setcalls"; }
nlog() { grep -c 'always-on VPN' "$1/log"; }
has() { grep -qF -- "$2" "$1/log"; }
deferred() { [ -e "$1/state/.vpndeferred.10" ]; }
applied() { [ -e "$1/state/.vpnapplied.10" ]; }
landed() { [ "$(helpers "$1")" = 1 ] && has "$1" "applied on install of $2 for user 10" && ! deferred "$1"; }
ONLINE='applied on install of'
herr() { local e; e=$(grep -m1 -E 'not found|unbound variable|syntax error|bad substitution' "$1/stderr" 2>/dev/null); printf '%s' "$e"; }

cases() {
  local d e before lb lh

  echo "== [$SH] the deferred app is installed =="
  d=$(session); defer "$d" com.vpn.tail 1 capture; install "$d" com.vpn.tail
  [ -z "$(herr "$d")" ] || no "harness: $(herr "$d")"
  { [ "$(helpers "$d")" = 1 ] && [ "$(helper1 "$d")" = "helper 10 com.vpn.tail defer" ]; } \
    && ok "(A1) the deferred app's install calls the helper once, through the app's consent (defer)" \
    || no "(A1) helper calls [$(grep '^helper ' "$d/calls" | tr '\n' ' ')]"
  { has "$d" "[roamd] always-on VPN: applied on install of com.vpn.tail for user 10 " && has "$d" "read back app=com.vpn.tail"; } \
    && ok "(A1) the log says applied on install, after the read-back line" || no "(A1) log [$(cat "$d/log")]"
  { ! deferred "$d" && applied "$d"; } && ok "(A1) the deferral is cleared and the session is marked applied" \
    || no "(A1) state [$(ls -A "$d/state" | tr '\n' ' ')]"
  { [ "$(res "$d")" = "BOOTWAKE 1 $DECL" ] && [ "$(helpers "$d")" = 1 ]; } && ok "(A1) the op's reply does not change with the apply: BOOTWAKE 1 $DECL" \
    || no "(A1) the reply was [$(res "$d")], helper calls $(helpers "$d")"
  lb=$(grep -n '^broadcast com.vpn.tail$' "$d/calls" | tail -1 | cut -d: -f1); lh=$(grep -n '^helper ' "$d/calls" | head -1 | cut -d: -f1)
  { [ -n "$lb" ] && [ -n "$lh" ] && [ "$lb" -lt "$lh" ] && [ "$(cat "$d/atreply")" = absent ]; } \
    && ok "(A8) the apply comes after the boot pass and before the reply" \
    || no "(A8) broadcast at [$lb], helper at [$lh], reply at the helper [$(cat "$d/atreply")]"

  before=$(helpers "$d"); e=$(setn "$d"); seal "$d"
  { [ "$before" = 1 ] && [ "$(helpers "$d")" = 1 ] && [ "$(setn "$d")" = "$e" ]; } \
    && ok "(A7) the seal retry after the apply adds no helper call and no settings read" \
    || no "(A7) helper calls $before then $(helpers "$d"), settings reads $e then $(setn "$d")"

  d=$(session); defer "$d" com.vpn.tail 0 capture; install "$d" com.vpn.tail
  [ "$(helper1 "$d")" = "helper 10 com.vpn.tail 0" ] && ok "(A2) a carried OFF applies with no block (mode 0)" \
    || no "(A2) helper [$(helper1 "$d")]"

  d=$(session); defer "$d" com.vpn.quiet 1 capture; install "$d" com.vpn.quiet
  { landed "$d" com.vpn.quiet && ! grep -q '^broadcast com.vpn.quiet$' "$d/calls"; } \
    && ok "(A3) a VPN app with no boot receiver gets its VPN and no broadcast" \
    || no "(A3) calls [$(tr '\n' ' ' < "$d/calls")], log [$(cat "$d/log")]"

  echo "== [$SH] nothing to apply =="
  d=$(session); defer "$d" com.vpn.tail 1 capture; cp "$d/state/.vpndeferred.10" "$d/record"; install "$d" com.other
  { [ "$(helpers "$d")" = 0 ] && [ "$(setn "$d")" = 0 ] && cmp -s "$d/record" "$d/state/.vpndeferred.10" && [ "$(nlog "$d")" = 0 ] \
    && grep -q '^broadcast com.other$' "$d/calls"; } && e=yes || e=no
  install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A4) another app's install: no helper, no settings read, no line, the deferral kept; its own install then applies" \
    || no "(A4) first leg clean=$e; calls [$(tr '\n' ' ' < "$d/calls")], log [$(cat "$d/log")]"

  d=$(session); install "$d" com.vpn.tail
  { [ "$(helpers "$d")" = 0 ] && [ "$(nlog "$d")" = 0 ] && ! applied "$d"; } && e=yes || e=no
  defer "$d" com.vpn.tail 1 capture; install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A5) no deferral: no helper, no line; once a deferral exists the install applies" \
    || no "(A5) first leg clean=$e; calls [$(tr '\n' ' ' < "$d/calls")], log [$(cat "$d/log")]"

  d=$(session); defer "$d" com.vpn.tail 1 capture; echo com.user.vpn > "$d/live/always_on_vpn_app"; install "$d" com.vpn.tail
  { ! deferred "$d" && applied "$d" && has "$d" "user 10 chose com.user.vpn in this session -> the deferred com.vpn.tail is dropped" \
    && ! has "$d" "$ONLINE"; } && e=yes || e=no
  seal "$d"
  { [ "$e" = yes ] && [ "$(helpers "$d")" = 0 ] && [ "$(cat "$d/live/always_on_vpn_app")" = com.user.vpn ]; } \
    && ok "(A6) a VPN the user set this session is not overridden: no helper at the install or the next seal, the deferral dropped, their choice is captured" \
    || no "(A6) first leg clean=$e; helpers $(helpers "$d"), live [$(cat "$d/live/always_on_vpn_app")], log [$(cat "$d/log")]"

  d=$(session); defer "$d" com.vpn.tail 1 capture; install "$d" ""
  { [ "$(helpers "$d")" = 0 ] && deferred "$d" && [ "$(res "$d")" = "BOOTWAKE 2 $DECL" ]; } && e=yes || e=no
  install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A9) the all-package pass applies nothing and keeps the deferral; the package's own install applies" \
    || no "(A9) first leg clean=$e; calls [$(tr '\n' ' ' < "$d/calls")]"

  d=$(session); defer "$d" com.vpn.tail 1 capture; mkdir -p "$d/data/user/10/com.nowhere.chooser/.nowhere-odhold/com.vpn.tail"
  install "$d" com.vpn.tail
  { [ "$(helpers "$d")" = 0 ] && deferred "$d"; } && e=yes || e=no
  rmdir "$d/data/user/10/com.nowhere.chooser/.nowhere-odhold/com.vpn.tail"; install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A10) data still held in CE: no helper, the deferral kept; it applies once the hold is gone" \
    || no "(A10) first leg clean=$e; calls [$(tr '\n' ' ' < "$d/calls")]"

  d=$(session); defer "$d" com.vpn.tail 1 capture; ( : > "$d/setfail" ); install "$d" com.vpn.tail
  { [ "$(helpers "$d")" = 0 ] && deferred "$d" && [ "$(res "$d")" = "BOOTWAKE 1 $DECL" ]; } && e=yes || e=no
  rm -f "$d/setfail"; install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A11) an unreadable setting applies nothing and keeps the deferral; a readable one applies" \
    || no "(A11) first leg clean=$e; calls [$(tr '\n' ' ' < "$d/calls")]"

  echo "== [$SH] an apply that does not land =="
  d=$(session); defer "$d" com.vpn.tail 1 capture; ( : > "$d/helperfail" ); install "$d" com.vpn.tail
  { [ "$(res "$d")" = "BOOTWAKE 1 $DECL" ] && deferred "$d" && [ "$(cat "$d/state/.vpnretry.10" 2>/dev/null)" = 1 ] \
    && has "$d" "is not ready yet, attempt 1 of 5" && ! has "$d" "$ONLINE" && ! applied "$d"; } && e=yes || e=no
  rm -f "$d/helperfail"; seal "$d"
  { [ "$e" = yes ] && has "$d" "the deferred apply for user 10 answered OK APPLIED" && ! has "$d" "$ONLINE" && ! deferred "$d" && applied "$d" \
    && [ ! -e "$d/state/.vpnretry.10" ]; } \
    && ok "(A12) a read-back miss: the reply stands, attempt 1 of 5, no applied line; the seal stays the fallback and logs its own line" \
    || no "(A12) first leg clean=$e; reply [$(res "$d")], log [$(cat "$d/log")]"

  d=$(session); defer "$d" com.vpn.tail 1 capture; rm -f "$d/vpn.jar"; install "$d" com.vpn.tail
  { has "$d" "com.vpn.tail NOT applied for user 10" && has "$d" "the deferred apply for user 10 answered OK NOHELPER" \
    && ! has "$d" "$ONLINE" && ! deferred "$d" && [ "$(helpers "$d")" = 0 ]; } && e=yes || e=no
  before=$(nlog "$d"); seal "$d"
  { [ "$e" = yes ] && [ "$(nlog "$d")" = "$before" ]; } \
    && ok "(A13) no helper in the image: the NOT applied lines and no applied line; the next seal adds no line" \
    || no "(A13) first leg clean=$e; log [$(cat "$d/log")]"

  echo "== [$SH] the op's refusals =="
  d=$(session); defer "$d" com.vpn.tail 1 capture; ( : > "$d/listfail" ); install "$d" com.vpn.tail
  { [ "$(res "$d")" = ERR-LIST ] && [ "$(helpers "$d")" = 0 ] && deferred "$d"; } && e=yes || e=no
  rm -f "$d/listfail"; install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A14) ERR-LIST applies nothing and keeps the deferral; the list back, the install applies" \
    || no "(A14) first leg clean=$e; reply [$(res "$d")]"

  d=$(session); defer "$d" com.vpn.tail 1 capture; install "$d" -evil
  { [ "$(res "$d")" = ERR-PKG ] && [ "$(helpers "$d")" = 0 ] && deferred "$d"; } && e=yes || e=no
  install "$d" com.vpn.tail
  { [ "$e" = yes ] && landed "$d" com.vpn.tail; } \
    && ok "(A15) ERR-PKG applies nothing and keeps the deferral; a plain package then applies" \
    || no "(A15) first leg clean=$e; reply [$(res "$d")]"

  echo "== [$SH] a pick as the deferral's source =="
  d=$(session); defer "$d" com.vpn.tail 1 pick; printf 'app=com.vpn.tail\nlockdown=1\n' > "$d/data/user/10/com.nowhere.chooser/files/nowhere-vpn-pick"
  install "$d" com.vpn.tail
  { landed "$d" com.vpn.tail && [ ! -e "$d/data/user/10/com.nowhere.chooser/files/nowhere-vpn-pick" ]; } \
    && ok "(A16) the pick the deferral came from is consumed by the apply" || no "(A16) the pick was left, log [$(cat "$d/log")]"
  d=$(session); defer "$d" com.vpn.tail 1 pick; printf 'app=com.other\nlockdown=0\n' > "$d/data/user/10/com.nowhere.chooser/files/nowhere-vpn-pick"
  install "$d" com.vpn.tail
  { landed "$d" com.vpn.tail && [ -e "$d/data/user/10/com.nowhere.chooser/files/nowhere-vpn-pick" ]; } \
    && ok "(A16) a pick made since survives for the next sign-in" || no "(A16) the newer pick was removed, log [$(cat "$d/log")]"
}

# Parse first, then every case, under each shell.
printf '%s\n' "ROOT=/x; STATE=/x; RES=/x; LOG=/x; uid=10; srcunit=; op=x" "$STUBS" "$BODY" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "THE BLOCKS DO NOT PARSE under $SH"; exit 2; }
  cases
done
SH=all

if [ "$MUTATE" = yes ]; then
  command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
  echo
  echo "== mutations (each must be CONVICTED by its named assertion under every shell) =="
  M=$(mktemp -d -p "$W")
  # mutate <assertion> <label> <old> <new> [<old> <new>]...: replace each literal <old>, which must occur EXACTLY once
  # in the script, by its <new>. A mutant convicts only when its re-run under EACH shell exits 1 with a FAIL line for
  # that shell that carries <assertion>.
  mutate(){
    local id="$1" label="$2" s out rc ev
    shift 2
    cp "$SUT" "$M/m.sh" || { no "MUTATION BROKEN: $label: no copy"; return; }
    while [ $# -gt 0 ]; do
      if ! MO="$1" MN="$2" perl -0pi -e 'BEGIN { $o = $ENV{MO}; $n = $ENV{MN} } $c = () = /\Q$o\E/g;
          die "matches $c times\n" unless $c == 1; s/\Q$o\E/$n/' "$M/m.sh" 2>"$M/err"; then
        no "MUTATION BROKEN: $label: $(cat "$M/err")"; return
      fi
      shift 2
    done
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $label"; return; fi
    for s in "${SHELLS[@]}"; do
      SH=$s
      out=$(ONLY_SHELL="$s" TMPDIR="$W" bash "$0" "$M/m.sh" 2>&1); rc=$?
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] ($id)" || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $label -- the suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $label (rc=$rc): $(printf '%s\n' "$out" | tail -1)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $label -- rc 1 with no ($id) FAIL line under $s"
      else ok "convicted by ($id): $label"; fi
    done
    SH=all
  }
  CALL='          [ -z "$srcunit" ] || vpn_deferred_retry "$uid" "$srcunit"
'
  REPLY='          echo "BOOTWAKE $_bsent $_bdecl" > "$RES"
'
  UNSTOP='          cutoff_run unstop "$uid" "$_bf.u" "$(( $(date +%s) + CUTOFF_BUDGET ))"; _bun=${CUTOFF_RAN:-0}
'
  FILTER='  [ -z "$_inst" ] || [ "$_inst" = "$_pkg" ] || return 0
'
  LIVE='  _live=$(settings get --user "$_uid" secure always_on_vpn_app </dev/null 2>/dev/null)
  [ -n "$_live" ] || return 0
'
  # The two places that clear the deferral on an OK: either one alone still clears it, so the mutant removes both.
  CLEAR1='  rm -f "$STATE/.vpndeferred.$_uid" 2>/dev/null
  ( : > "$STATE/.vpnapplied.$_uid" ) 2>>"$LOG"
  printf '"'"'OK APPLIED'"'"'; return 0'
  CLEAR1N='  ( : > "$STATE/.vpnapplied.$_uid" ) 2>>"$LOG"
  printf '"'"'OK APPLIED'"'"'; return 0'
  CLEAR2='    "OK "*)
      rm -f "$STATE/.vpndeferred.$_uid" "$STATE/.vpnretry.$_uid" 2>/dev/null
'
  CLEAR2N='    "OK "*)
'
  mutate A1 "the arm's call is removed" "$CALL" ''
  mutate A3 "the call moves into the receiver loop, for declaring apps only" "$CALL" '' \
    '              echo "$_p"
            done; } > "$_bf"' \
    '              echo "$_p"
              [ -z "$srcunit" ] || vpn_deferred_retry "$uid" "$srcunit"
            done; } > "$_bf"'
  mutate A8 "the call moves after the reply" "$CALL$REPLY" "$REPLY$CALL"
  mutate A8 "the call moves before the boot pass" "$CALL" '' "$UNSTOP" "$CALL$UNSTOP"
  mutate A9 "the srcunit guard is removed from the arm's call" '[ -z "$srcunit" ] || vpn_deferred_retry "$uid" "$srcunit"' \
    'vpn_deferred_retry "$uid" "$srcunit"'
  mutate A4 "the arm does not pass the package" '[ -z "$srcunit" ] || vpn_deferred_retry "$uid" "$srcunit"' \
    '[ -z "$srcunit" ] || vpn_deferred_retry "$uid"'
  mutate A4 "the package filter is removed" "$FILTER" ''
  mutate A4 "the filter moves after the settings read" "$FILTER$LIVE" "$LIVE$FILTER"
  mutate A5 "the arm applies the installed package with no deferral" '[ -z "$srcunit" ] || vpn_deferred_retry "$uid" "$srcunit"' \
    '[ -z "$srcunit" ] || vpn_apply_choice "$uid" capture "$srcunit" 1 "" >/dev/null'
  mutate A6 "the user's-choice branch is removed" 'if [ "$_live" != null ] && [ "$_live" != "$_pkg" ]; then' 'if false; then'
  mutate A10 "the check for a held app is removed" \
    '/com.nowhere.chooser/.nowhere-odhold/$_pkg" ] && return 0   # still held' \
    '/com.nowhere.chooser/.nowhere-odhold/$_pkg" ] && :   # still held'
  mutate A7 "the apply does not clear the deferral" "$CLEAR1" "$CLEAR1N" "$CLEAR2" "$CLEAR2N"
  mutate A13 "the applied line is logged for every OK" '[ -n "$_inst" ] && [ "$_r" = "OK APPLIED" ]' '[ -n "$_inst" ]'
  mutate A12 "the seal logs the applied line too" '[ -n "$_inst" ] && [ "$_r" = "OK APPLIED" ]' '[ "$_r" = "OK APPLIED" ]'
  mutate A1 "the applied line is removed" '[ -n "$_inst" ] && [ "$_r" = "OK APPLIED" ]' 'false'
  mutate A11 "the empty-read return is removed" '  [ -n "$_live" ] || return 0
' ''
  mutate A12 "the apply is done without the read-back" '  [ "$_ok" = yes ] || { printf '"'"'NOTREADY'"'"'; return 0; }
' ''
  mutate A16 "the apply does not consume the pick" \
    '  [ "$_src" = pick ] && vpn_pick_consume "$_vf" "$_pick"   # the pick is now the live state
' ''
  mutate A16 "the apply removes a pick made since" \
    '[ "$(cat "$1/nowhere-vpn-pick" 2>/dev/null)" = "$2" ] && rm -f "$1/nowhere-vpn-pick" 2>>"$LOG"' \
    'rm -f "$1/nowhere-vpn-pick" 2>>"$LOG"'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
