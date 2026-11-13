#!/usr/bin/env bash
# test-vpn-handopen.sh [<nowhere_roamd.sh>] [--mutate] -- a captured always-on VPN choice of OFF is never applied as ON,
# also when the VPN app is opened by hand before the sign-in's deferred apply lands (NWP-20261202-03).
#
# WHY THIS IS COMMITTED. The backlog row 'An always-on VPN app opened by hand before the sign-in's deferred apply comes
# up with "Block connections without VPN" on, although the captured choice is off'. A fresh user has no ACTIVATE_VPN
# appop for the profile's VPN app, so the hand-opened app asks for consent. GrapheneOS's setVpnPackageAuthorization
# hunk, deferred by vpn-lockdown-on-first-connect.sh, sets the app always-on and records nowhere_vpn_lockdown_pending;
# the first connection then arms the block, before vpn_deferred_retry applies the captured off. The phone had no
# network until the user found the switch. odrestore now calls vpn_preconsent_off before its reply.
#
# roamd's vpn_choice, vpn_preconsent_off, vpn_apply_choice, vpn_pick_consume, vpn_deferred_retry and VPN_APPLY_TRIES
# are extracted BY ANCHOR and run against a fake device: `settings`, `cmd` and `app_process` (the helper) are stubbed.
# The suite models the patched framework itself:
#   app_start P   the app asks for consent: when $T/appops/P does not hold `allow` and the live app is not P, the
#                 consent sets app=P, lockdown 0 and pending=P (vpn-lockdown-on-first-connect.sh step 3)
#   connect       the first connection: when pending = the live app and lockdown is 0, lockdown 1, pending cleared (step 5)
# The live lockdown is recorded after every step into a history. Every case runs under each shell found (bash, dash,
# mksh, and sh when it is not one of them). Case (h) reads the odrestore arm's source and runs in each shell's pass.
#
#   bash test-vpn-handopen.sh            # the cases
#   bash test-vpn-handopen.sh --mutate   # ... plus mutations that the named assertion must convict, each shell
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
CH=$(func vpn_choice)
P=$(func vpn_preconsent_off)
C=$(func vpn_apply_choice)
K=$(func vpn_pick_consume)
R=$(func vpn_deferred_retry)
TR=$(grep -m1 -E '^VPN_APPLY_TRIES=' "$SUT")
ARM=$(awk -v l="  odrestore)" '$0==l{on=1} on{print} on&&/^    ;;$/{exit}' "$SUT")
# A miss is a FAIL (exit 1), not a harness error: on a roamd with no vpn_preconsent_off the suite must fail.
case "$CH" in *'nowhere-prefs'*|*'vpnlockdown='*) ;; *) echo "FAIL  EXTRACTION FAILED: vpn_choice in $SUT"; exit 1 ;; esac
case "$P" in *'ACTIVATE_VPN'*) ;; *) echo "FAIL  EXTRACTION FAILED: vpn_preconsent_off in $SUT"; exit 1 ;; esac
case "$C" in *'np.VpnAlwaysOn'*) ;; *) echo "FAIL  EXTRACTION FAILED: vpn_apply_choice in $SUT"; exit 1 ;; esac
case "$K" in *'nowhere-vpn-pick'*) ;; *) echo "FAIL  EXTRACTION FAILED: vpn_pick_consume in $SUT"; exit 1 ;; esac
case "$R" in *'.vpndeferred'*) ;; *) echo "FAIL  EXTRACTION FAILED: vpn_deferred_retry in $SUT"; exit 1 ;; esac
[ -n "$TR" ] || { echo "FAIL  EXTRACTION FAILED: VPN_APPLY_TRIES= in $SUT"; exit 1; }
case "$ARM" in *'echo "OK NOSRC" > "$RES"'*) ;; *) echo "FAIL  EXTRACTION FAILED: the odrestore arm in $SUT"; exit 1 ;; esac

# --- the fake device ------------------------------------------------------------------------------------
# POSIX stubs, run inside each case's run file under each shell. `_st_*` names never meet roamd's.
#   settings get --user U secure <key>   -> $T/live/<key>, else null
#   cmd appops set --user U P ACTIVATE_VPN <mode> -> $T/appops/P holds <mode>; every cmd call goes to $T/cmdcalls
#   app_process ... np.VpnAlwaysOn U P M -> the helper as the patched framework runs it (test-sync-vpn-roam.sh APMODE ok):
#                                           defer = app P, lockdown 0, pending P; 0 = app P, lockdown 0, pending cleared
STUBS=$(cat <<'EOF'
timeout(){ shift; "$@"; }
sleep(){ :; }
am(){ echo "am $*" >> "$T/cmdcalls"; return 0; }
settings(){
  [ "$1" = get ] || return 0
  if [ -s "$T/live/$5" ]; then cat "$T/live/$5"; else echo null; fi
  return 0
}
cmd(){
  echo "cmd $*" >> "$T/cmdcalls"
  if [ "$1" = appops ] && [ "$2" = set ] && [ "$6" = ACTIVATE_VPN ]; then echo "$7" > "$T/appops/$5"; fi
  return 0
}
app_process(){
  echo "helper $3 $4 $5" >> "$T/cmdcalls"
  echo "$4" > "$T/live/always_on_vpn_app"
  if [ "$5" = defer ]; then
    echo 0 > "$T/live/always_on_vpn_lockdown"; echo "$4" > "$T/live/nowhere_vpn_lockdown_pending"
  else
    echo "$5" > "$T/live/always_on_vpn_lockdown"; rm -f "$T/live/nowhere_vpn_lockdown_pending"
  fi
  echo "stub $5 -> done"
  return 0
}
_st_get(){ if [ -s "$T/live/$1" ]; then cat "$T/live/$1"; else echo none; fi; }
rec(){ _st_get always_on_vpn_lockdown >> "$T/hist"; }
app_start(){
  if [ "$(cat "$T/appops/$1" 2>/dev/null)" != allow ] && [ "$(_st_get always_on_vpn_app)" != "$1" ]; then
    echo "$1" > "$T/live/always_on_vpn_app"; echo 0 > "$T/live/always_on_vpn_lockdown"
    echo "$1" > "$T/live/nowhere_vpn_lockdown_pending"
    echo consent >> "$T/model"
  fi
  rec
}
connect(){
  if [ "$(_st_get nowhere_vpn_lockdown_pending)" = "$(_st_get always_on_vpn_app)" ] && [ "$(_st_get always_on_vpn_lockdown)" = 0 ]; then
    echo 1 > "$T/live/always_on_vpn_lockdown"; rm -f "$T/live/nowhere_vpn_lockdown_pending"
    echo armed >> "$T/model"
  fi
  rec
}
pre(){ vpn_preconsent_off 10 "$1" >> "$T/stdout"; echo "$?" >> "$T/rcs"; rec; }
retry(){ vpn_deferred_retry 10 "$1" >> "$T/stdout"; rec; }
EOF
)
BODY=$(printf '%s\n' "$CH" "$P" "$C" "$K" "$TR" "$R")

# session: a case root. User 10 has the chooser files dir (nowhere-prefs restored), and com.x and com.y installed.
session() {
  local d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/state" "$d/live" "$d/appops" "$d/data/user/10/com.nowhere.chooser/files" "$d/data/user/10/com.x" \
    "$d/data/user/10/com.y"
  ( : > "$d/vpnao.jar" ); ( : > "$d/hist" ); ( : > "$d/stdout" ); ( : > "$d/rcs" ); ( : > "$d/log" ); ( : > "$d/stderr" )
  ( : > "$d/cmdcalls" )
  echo locale=en > "$d/data/user/10/com.nowhere.chooser/files/nowhere-prefs"
  printf '%s\n' "$d"
}
# steps <root> <step>...: run the steps (pre P, app_start P, connect, retry P) under "$SHP" against the device.
steps() {
  local d="$1"
  shift
  {
    printf "T='%s'; STATE=\"\$T/state\"; LOG=\"\$T/log\"; VPN_USER_ROOT=\"\$T/data/user\"\n" "$d"
    [ -e "$d/nojar" ] && printf "NOWHERE_VPN_JAR=\"\$T/absent.jar\"\n" || printf "NOWHERE_VPN_JAR=\"\$T/vpnao.jar\"\n"
    printf '%s\n' "$STUBS" "$BODY" "$@"
  } > "$d/run.sh" || return 2
  "$SHP" "$d/run.sh" >/dev/null 2>>"$d/stderr"
}
FILES=data/user/10/com.nowhere.chooser/files
defer() { printf '%s\n' "$2" > "$1/state/.vpndeferred.10"; }
capture() { printf 'app=%s\nlockdown=%s\n' "$2" "$3" > "$1/$FILES/nowhere-vpn"; }
live() { echo "$3" > "$1/live/$2"; }
get() { if [ -s "$1/live/$2" ]; then cat "$1/live/$2"; else echo none; fi; }
appops() { cat "$1/appops/$2" 2>/dev/null; }
hist() { tr '\n' ' ' < "$1/hist"; }
never_on() { ! grep -qx 1 "$1/hist"; }
mine() { grep -F 'NWP-20261202-03' "$1/log"; }
# quiet <root>: the helper returned 0 every time and wrote nothing to stdout; no shell error
quiet() {
  local e
  e=$(grep -m1 -E 'not found|unbound variable|syntax error|bad substitution' "$1/stderr" 2>/dev/null)
  [ -z "$e" ] && [ ! -s "$1/stdout" ] && ! grep -qvx 0 "$1/rcs"
}
HAND='pre com.x
app_start com.x
connect'

cases() {
  local d d2 m e n

  echo "== [$SH] a carried OFF: the hand-opened app cannot arm the block =="
  d=$(session); defer "$d" 'com.x 0 capture'; steps "$d" "$HAND" 'retry com.x'
  m=$(mine "$d")
  { never_on "$d" && [ "$(get "$d" always_on_vpn_lockdown)" = 0 ] && [ "$(get "$d" nowhere_vpn_lockdown_pending)" = none ] \
    && [ "$(get "$d" always_on_vpn_app)" = com.x ] && [ "$(appops "$d" com.x)" = allow ] && quiet "$d"; } \
    && ok "(a) deferral off, hand open, first connection, then the deferred apply: the block is never on; ends off, nothing pending" \
    || no "(a) history [$(hist "$d")], lockdown $(get "$d" always_on_vpn_lockdown), pending $(get "$d" nowhere_vpn_lockdown_pending), appops [$(appops "$d" com.x)], stdout [$(cat "$d/stdout")], stderr [$(cat "$d/stderr")]"
  { [ "$(printf '%s\n' "$m" | grep -c .)" = 1 ] \
    && case "$m" in *"pre-consented at its restore for user 10, block off (from deferred), so its own consent cannot arm the block"*) true ;; *) false ;; esac \
    && case "$m" in *com.x*) false ;; *) true ;; esac; } \
    && ok "(a) one log line, block off (from deferred), and it names no package" || no "(a) log [$m]"

  d=$(session); defer "$d" 'com.x 0 capture'; capture "$d" com.x 1; steps "$d" "$HAND"
  { [ "$(appops "$d" com.x)" = allow ] && never_on "$d" && quiet "$d"; } \
    && ok "(a2) the deferral says off and the capture says on: the deferral wins, the app is pre-consented" \
    || no "(a2) appops [$(appops "$d" com.x)], history [$(hist "$d")], log [$(cat "$d/log")]"

  d=$(session); capture "$d" com.x 0; steps "$d" "$HAND" 'retry com.x'
  { [ "$(appops "$d" com.x)" = allow ] && never_on "$d" && [ "$(get "$d" nowhere_vpn_lockdown_pending)" = none ] && quiet "$d" \
    && [ -n "$(mine "$d" | grep -F '(from capture)')" ]; } \
    && ok "(b) no deferral, the capture says off: pre-consented (from capture); the block is never on" \
    || no "(b) appops [$(appops "$d" com.x)], history [$(hist "$d")], log [$(cat "$d/log")]"

  echo "== [$SH] a carried ON is left to the consent =="
  d=$(session); defer "$d" 'com.x 1 capture'; steps "$d" "$HAND"
  { [ -z "$(appops "$d" com.x)" ] && [ "$(get "$d" always_on_vpn_lockdown)" = 1 ] && grep -qx armed "$d/model" 2>/dev/null && quiet "$d" \
    && [ -n "$(mine "$d" | grep -F 'not pre-consented at its restore for user 10, block on (from deferred): its consent arms the block at the first connection')" ]; } \
    && ok "(c) deferral on: no pre-consent; the consent arms the block at the first connection (the model's control)" \
    || no "(c) appops [$(appops "$d" com.x)], lockdown $(get "$d" always_on_vpn_lockdown), model [$(cat "$d/model" 2>/dev/null)], log [$(cat "$d/log")]"

  echo "== [$SH] another app's restore =="
  d=$(session); defer "$d" 'com.y 0 capture'; capture "$d" com.y 0; steps "$d" 'pre com.x'
  { [ -z "$(ls -A "$d/appops")" ] && [ -z "$(mine "$d")" ] && ! grep -q '^cmd ' "$d/cmdcalls" && quiet "$d"; } \
    && ok "(d) the deferral and the capture name another app: no appops call, no log line" \
    || no "(d) appops [$(ls -A "$d/appops" | tr '\n' ' ')], calls [$(tr '\n' ' ' < "$d/cmdcalls")], log [$(cat "$d/log")]"

  echo "== [$SH] the consent already armed: the deferred apply puts the choice back =="
  d=$(session); defer "$d" 'com.x 0 capture'; live "$d" always_on_vpn_app com.x; live "$d" always_on_vpn_lockdown 1
  steps "$d" 'retry com.x'
  d2=$(session); defer "$d2" 'com.x 0 capture'; live "$d2" always_on_vpn_app com.x; live "$d2" always_on_vpn_lockdown 0
  live "$d2" nowhere_vpn_lockdown_pending com.x; steps "$d2" 'retry com.x'
  { [ "$(get "$d" always_on_vpn_lockdown)" = 0 ] && [ "$(get "$d" nowhere_vpn_lockdown_pending)" = none ] \
    && [ "$(get "$d2" always_on_vpn_lockdown)" = 0 ] && [ "$(get "$d2" nowhere_vpn_lockdown_pending)" = none ] \
    && [ ! -e "$d/state/.vpndeferred.10" ] && [ ! -e "$d2/state/.vpndeferred.10" ]; } \
    && ok "(e) live com.x armed, or pending: the deferred apply of the off ends lockdown 0, nothing pending" \
    || no "(e) armed: lockdown $(get "$d" always_on_vpn_lockdown) pending $(get "$d" nowhere_vpn_lockdown_pending); pending: lockdown $(get "$d2" always_on_vpn_lockdown) pending $(get "$d2" nowhere_vpn_lockdown_pending); log [$(cat "$d/log")]"

  echo "== [$SH] the prefs fallback =="
  d=$(session); echo vpn=com.x >> "$d/$FILES/nowhere-prefs"; steps "$d" 'pre com.x'
  d2=$(session); printf '%s\n' vpn=com.x vpnlockdown=0 >> "$d2/$FILES/nowhere-prefs"; steps "$d2" "$HAND"
  { [ -z "$(appops "$d" com.x)" ] && [ -n "$(mine "$d" | grep -F 'block on (from prefs)')" ] \
    && [ "$(appops "$d2" com.x)" = allow ] && never_on "$d2" && [ -n "$(mine "$d2" | grep -F 'block off (from prefs)')" ]; } \
    && ok "(f) prefs vpn= alone (lockdown 1): no pre-consent; with vpnlockdown=0: pre-consented" \
    || no "(f) prefs on: appops [$(appops "$d" com.x)] log [$(cat "$d/log")]; prefs off: appops [$(appops "$d2" com.x)] log [$(cat "$d2/log")]"

  echo "== [$SH] a malformed deferral, no helper =="
  e=yes
  for m in 'com.x 7 capture' 'bad/x 0 capture'; do
    d=$(session); defer "$d" "$m"; capture "$d" com.x 0; steps "$d" 'pre com.x'
    { [ "$(appops "$d" com.x)" = allow ] && [ -n "$(mine "$d" | grep -F '(from capture)')" ] && quiet "$d"; } || { e="no: [$m] appops [$(appops "$d" com.x)] log [$(cat "$d/log")]"; }
  done
  [ "$e" = yes ] && ok "(g) a malformed deferral is passed over: vpn_choice decides (from capture)" || no "(g) $e"
  d=$(session); defer "$d" 'com.x 0 capture'; capture "$d" com.x 0; ( : > "$d/nojar" ); steps "$d" 'pre com.x'
  { [ -z "$(ls -A "$d/appops")" ] && [ ! -s "$d/log" ] && quiet "$d"; } \
    && ok "(g) an image with no helper jar: no appops call, no log line" \
    || no "(g) no jar: appops [$(ls -A "$d/appops" | tr '\n' ' ')], log [$(cat "$d/log")]"

  echo "== [$SH] the odrestore arm's source =="
  n=$(printf '%s\n' "$ARM" | grep -nxF '    vpn_preconsent_off "$uid" "$pkg"')
  e=$(printf '%s\n' "$ARM" | grep -nF 'vpn_preconsent_off' | grep -vE '^[0-9]+:[[:space:]]*#')
  { [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] && [ "$(printf '%s\n' "$e" | grep -c .)" = 1 ]; } \
    && ok "(h) the arm holds exactly one call, vpn_preconsent_off \"\$uid\" \"\$pkg\"" || no "(h) the calls [$(printf '%s' "$e" | tr '\n' ' ')]"
  n=${n%%:*}
  # The reply may sit inside an if (NWP-20261130-03: `if od_unblock_app ...; then ...; echo "OK $pkg" > "$RES"; ...`),
  # so the first line that writes each OK reply is matched as a substring, comments excluded.
  m=$(printf '%s\n' "$ARM" | grep -nF 'echo "OK NOSRC" > "$RES"' | grep -vE '^[0-9]+:[[:space:]]*#' | head -1); m=${m%%:*}
  e=$(printf '%s\n' "$ARM" | grep -nF 'echo "OK $pkg" > "$RES"' | grep -vE '^[0-9]+:[[:space:]]*#' | head -1); e=${e%%:*}
  { [ -n "$n" ] && [ -n "$m" ] && [ -n "$e" ] && [ "$n" -lt "$m" ] && [ "$n" -lt "$e" ]; } \
    && ok "(h) the call comes before the reply: the chooser opens the app only after it" \
    || no "(h) call at [$n], OK NOSRC at [$m], OK \$pkg at [$e]"
  e=$(printf '%s\n' "$P" | grep -vE '^[[:space:]]*#' | grep -nE 'settings|app_process|vpn_apply')
  [ -z "$e" ] && ok "(h) the helper's body runs no settings, no app_process and no vpn_apply*" || no "(h) the helper's body holds [$e]"
}

# Parse first, then every case, under each shell.
printf '%s\n' "T=/x; STATE=/x; LOG=/x" "$STUBS" "$BODY" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "THE BLOCKS DO NOT PARSE under $SH"; exit 1; }
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
  CALL='    vpn_preconsent_off "$uid" "$pkg"
'
  LAST='echo "OK $pkg" > "$RES"; else echo "ERR-NOTREADY" > "$RES"; fi
    fi
'
  mutate h "the odrestore arm's call is removed" "$CALL" ''
  mutate h "the call moves after the reply block" "$CALL" '' "$LAST" "$LAST$CALL"
  mutate c "the lockdown test is always true" 'if [ "$_l" = 0 ]; then
    cmd appops' 'if true; then
    cmd appops'
  mutate d "the package match is dropped" '[ -n "$_p" ] && [ "$_p" = "$_pkg" ] && _s=deferred' '[ -n "$_p" ] && _s=deferred' \
    '    [ "$_p" = "$_pkg" ] || return 0
' ''
  mutate a2 "the deferral read is skipped" '  if [ -s "$STATE/.vpndeferred.$_uid" ]; then
    read -r _p _l _r' '  if false; then
    read -r _p _l _r'
  mutate a "the pre-consent sets deny" '    cmd appops set --user "$_uid" "$_pkg" ACTIVATE_VPN allow </dev/null >/dev/null 2>&1
    echo "[roamd] always-on VPN: the profile'"'"'s VPN app is pre-consented' '    cmd appops set --user "$_uid" "$_pkg" ACTIVATE_VPN deny </dev/null >/dev/null 2>&1
    echo "[roamd] always-on VPN: the profile'"'"'s VPN app is pre-consented'
  mutate e "vpn_deferred_retry drops the deferral when the live app is the deferred one" \
    'if [ "$_live" != null ] && [ "$_live" != "$_pkg" ]; then' 'if [ "$_live" != null ]; then'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
