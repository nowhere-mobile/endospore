#!/usr/bin/env bash
# test-vpn-diag-note.sh [<nowhere_roamd.sh>] [--mutate | --baseline] -- every always-on VPN apply leaves one codes-only
# line in $STATE/.vpndiag.<uid> before its answer is printed (NWP-20261202-41).
#
# WHY THIS IS COMMITTED. The diagnostic day summary recorded nothing of the always-on VPN apply, so a VPN report could
# not be checked from it (NW-e39d98931a8f could show when the VPN was applied only from roam.log, which rolls). roamd
# now notes each apply's outcome and lockdown in $STATE/.vpndiag.<uid> (vpn_diag_note), and the agent turns each note
# into an `ev=vpn` day-summary line (daySummaryTakeVpn, core/agent/vpn_day_summary_test.go). The note is codes only:
# no app, tunnel, profile or path.
#
# vpn_choice, vpn_diag_note, vpn_apply, vpn_apply_choice, vpn_pick_consume, vpn_deferred_retry, qn and the
# VPN_APPLY_TRIES= line are extracted BY ANCHOR and run against a fake device: `cmd`, `settings`, `app_process` (the
# helper, which writes the live settings as the framework does), `timeout`, `am`, `sleep` and `print` are stubbed. A
# `printf` function defined after the extraction records, at each OK answer, whether the note already exists. Every
# case runs under each shell found (bash, dash, mksh, and sh when it is not one of them).
#
#   bash test-vpn-diag-note.sh              # the cases
#   bash test-vpn-diag-note.sh --mutate     # ... plus mutations that the named assertion must convict, each shell
#   bash test-vpn-diag-note.sh <old> --baseline   # a roamd with no vpn_diag_note: the cases must FAIL there
set -uo pipefail

MODE=plain; SUT=""
for a in "$@"; do case "$a" in --mutate) MODE=mutate ;; --baseline) MODE=baseline ;; *) SUT="$a" ;; esac; done
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
VC=$(func vpn_choice); VD=$(func vpn_diag_note); VA=$(func vpn_apply); C=$(func vpn_apply_choice)
K=$(func vpn_pick_consume); R=$(func vpn_deferred_retry); Q=$(func qn)
T=$(grep -m1 -E '^VPN_APPLY_TRIES=' "$SUT")
case "$VC" in *'nowhere-prefs'*|*'vpnlockdown='*) ;; *) echo "EXTRACTION FAILED: vpn_choice in $SUT" >&2; exit 2 ;; esac
case "$VA" in *'OK NONE'*) ;; *) echo "EXTRACTION FAILED: vpn_apply in $SUT" >&2; exit 2 ;; esac
case "$C" in *'np.VpnAlwaysOn'*) ;; *) echo "EXTRACTION FAILED: vpn_apply_choice in $SUT" >&2; exit 2 ;; esac
case "$K" in *'nowhere-vpn-pick'*) ;; *) echo "EXTRACTION FAILED: vpn_pick_consume in $SUT" >&2; exit 2 ;; esac
case "$R" in *'.vpndeferred'*) ;; *) echo "EXTRACTION FAILED: vpn_deferred_retry in $SUT" >&2; exit 2 ;; esac
case "$Q" in *'print -rn'*) ;; *) echo "EXTRACTION FAILED: qn in $SUT" >&2; exit 2 ;; esac
[ -n "$T" ] || { echo "EXTRACTION FAILED: VPN_APPLY_TRIES= not found in $SUT" >&2; exit 2; }
case "$VD" in
  *'.vpndiag.'*) ;;
  *) if [ "$MODE" = baseline ]; then VD='vpn_diag_note() { :; }'; echo "baseline: $SUT has no vpn_diag_note -- stubbed"
     else echo "EXTRACTION FAILED: vpn_diag_note in $SUT" >&2; exit 2; fi ;;
esac
TRIES=${T#VPN_APPLY_TRIES=}
case "$TRIES" in ''|*[!0-9]*) echo "EXTRACTION FAILED: VPN_APPLY_TRIES is not a number in $SUT" >&2; exit 2 ;; esac
# The cleanstorage rm list, the line tagged NWP-20261128-36.
CS=$(grep -F 'rm -f "$STATE/.declined.$uid"' "$SUT" | grep -F '# NWP-20261128-36')

# --- the fake device ------------------------------------------------------------------------------------
# POSIX stubs, run inside each case's run file under each shell. `_st_*` names never meet roamd's.
#   settings get --user U secure <key>   -> $ROOT/live/<key>, else null
#   app_process ... np.VpnAlwaysOn U P M -> writes the live settings as the framework does, unless $ROOT/helperfail
#   printf                               -> at each OK token printed, `yes` or `no` in $ROOT/order: does the note exist
STUBS=$(cat <<'EOF'
timeout(){ shift 1; "$@"; }
cmd(){ return 0; }
am(){ return 0; }
sleep(){ return 0; }
print() { _st_nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _st_nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_st_nl" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }
settings(){
  if [ -s "$ROOT/live/$5" ]; then cat "$ROOT/live/$5"; else echo null; fi
  return 0
}
app_process(){
  [ -e "$ROOT/helperfail" ] && return 0
  echo "$4" > "$ROOT/live/always_on_vpn_app"
  if [ "$5" = defer ]; then echo "$4" > "$ROOT/live/nowhere_vpn_lockdown_pending"; else echo 0 > "$ROOT/live/always_on_vpn_lockdown"; fi
  return 0
}
EOF
)
PROBE=$(cat <<'EOF'
printf(){
  case "$1" in
    "OK "*) if [ -e "$STATE/.vpndiag.10" ]; then echo yes >> "$ROOT/order"; else echo no >> "$ROOT/order"; fi ;;
    %s) case "${2:-}" in "OK "*) if [ -e "$STATE/.vpndiag.10" ]; then echo yes >> "$ROOT/order"; else echo no >> "$ROOT/order"; fi ;; esac ;;
  esac
  command printf "$@"
}
EOF
)
BODY=$(printf '%s\n' "$Q" "$VC" "$VD" "$VA" "$C" "$K" "$T" "$R" "$PROBE")

PKG=com.example.secretvpn
TUN=secret-tunnel
# session: a fresh device for user 10: nowhere-prefs restored, the VPN app's data dir present, the helper in place.
session() {
  local d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/state" "$d/live" "$d/user/10/com.nowhere.chooser/files" "$d/user/10/$PKG" \
    "$d/user/10/com.wireguard.android/files"
  printf 'locale=en-US\n' > "$d/user/10/com.nowhere.chooser/files/nowhere-prefs"
  ( : > "$d/jar" ); ( : > "$d/log" ); ( : > "$d/stderr" ); ( : > "$d/order" )
  printf '%s\n' "$d"
}
choose() { printf 'app=%s\nlockdown=%s\n' "$2" "$3" > "$1/user/10/com.nowhere.chooser/files/nowhere-vpn"; }
defer() { printf '%s %s %s\n' "$2" "$3" capture > "$1/state/.vpndeferred.10"; }
hold() { mkdir -p "$1/user/10/com.nowhere.chooser/.nowhere-odhold/$2"; }
# run <root> <shell code>: the code after the extracted functions, under "$SHP"; its stdout lands in <root>/res.
run() {
  local d="$1"
  {
    printf "ROOT='%s'; STATE=\"\$ROOT/state\"; LOG=\"\$ROOT/log\"; VPN_USER_ROOT=\"\$ROOT/user\"; NOWHERE_VPN_JAR=\"\$ROOT/jar\"\n" "$d"
    printf '%s\n' "$STUBS" "$BODY" "$2"
  } > "$d/run.sh" || return 2
  "$SHP" "$d/run.sh" > "$d/res" 2>>"$d/stderr"
}
signin() { run "$1" 'vpn_apply 10'; }
retry() { run "$1" "vpn_deferred_retry 10 $2"; }
rec() { cat "$1/state/.vpndiag.10" 2>/dev/null; }
res() { cat "$1/res" 2>/dev/null; }
lastorder() { tail -n 1 "$1/order"; }
herr() { local e; e=$(grep -m1 -E 'not found|unbound variable|syntax error|bad substitution' "$1/stderr" 2>/dev/null); printf '%s' "$e"; }
ALL="$W/allrecords"

cases() {
  local d i e want
  ( : > "$ALL" )

  echo "== [$SH] the sign-in's vpnup =="
  d=$(session); signin "$d"
  [ -z "$(herr "$d")" ] || no "harness: $(herr "$d")"
  { [ "$(res "$d")" = "OK NONE" ] && [ "$(rec "$d")" = "at=signin rc=none lock=-" ]; } \
    && ok "(D1) no choice: OK NONE, one note at=signin rc=none lock=-" || no "(D1) answer [$(res "$d")], record [$(rec "$d")]"
  [ "$(lastorder "$d")" = yes ] && ok "(D1) the NONE note is written before the answer" \
    || no "(D1) the note did not exist when OK NONE was printed [$(tr '\n' ' ' < "$d/order")]"
  rec "$d" >> "$ALL"

  d=$(session); choose "$d" "$PKG" 1; hold "$d" "$PKG"; signin "$d"
  { [ "$(res "$d")" = "OK DEFERRED" ] && [ "$(rec "$d")" = "at=signin rc=deferred lock=1" ] && [ "$(lastorder "$d")" = yes ]; } \
    && ok "(D2) an on-demand app still held: OK DEFERRED, note at=signin rc=deferred lock=1, before the answer" \
    || no "(D2) answer [$(res "$d")], record [$(rec "$d")], order [$(tr '\n' ' ' < "$d/order")]"
  rec "$d" >> "$ALL"

  d=$(session); choose "$d" "$PKG" 1; signin "$d"
  { [ "$(res "$d")" = "OK APPLIED" ] && [ "$(rec "$d")" = "at=signin rc=applied lock=1" ]; } \
    && ok "(D3) applied with lockdown: OK APPLIED, note at=signin rc=applied lock=1" || no "(D3) answer [$(res "$d")], record [$(rec "$d")]"
  [ "$(lastorder "$d")" = yes ] && ok "(D3) the APPLIED note is written before the answer" \
    || no "(D3) the note did not exist when OK APPLIED was printed [$(tr '\n' ' ' < "$d/order")]"
  rec "$d" >> "$ALL"

  d=$(session); choose "$d" "$PKG" 0; signin "$d"
  { [ "$(res "$d")" = "OK APPLIED" ] && [ "$(rec "$d")" = "at=signin rc=applied lock=0" ]; } \
    && ok "(D4) applied without lockdown: note at=signin rc=applied lock=0" || no "(D4) answer [$(res "$d")], record [$(rec "$d")]"
  rec "$d" >> "$ALL"

  d=$(session); choose "$d" "$PKG" 1; rm -f "$d/jar"; signin "$d"
  { [ "$(res "$d")" = "OK NOHELPER" ] && [ "$(rec "$d")" = "at=signin rc=nohelper lock=1" ] && [ "$(lastorder "$d")" = yes ]; } \
    && ok "(D5) no helper in the image: OK NOHELPER, note at=signin rc=nohelper lock=1, before the answer" \
    || no "(D5) answer [$(res "$d")], record [$(rec "$d")], order [$(tr '\n' ' ' < "$d/order")]"
  rec "$d" >> "$ALL"

  d=$(session); choose "$d" "$PKG" 1; rmdir "$d/user/10/$PKG"; signin "$d"
  { [ "$(res "$d")" = NOTREADY ] && [ ! -e "$d/state/.vpndiag.10" ]; } \
    && ok "(D6) NOTREADY at sign-in writes no note (the agent's give-up covers it)" || no "(D6) answer [$(res "$d")], record [$(rec "$d")]"

  d=$(session); choose "$d" com.wireguard.android 1; ( : > "$d/user/10/com.wireguard.android/files/$TUN.conf" )
  signin "$d"
  { [ "$(res "$d")" = "OK APPLIED" ] && [ "$(rec "$d")" = "at=signin rc=applied lock=1" ]; } \
    && ok "(D3) a WireGuard tunnel applied: the same codes-only note" || no "(D3) WG answer [$(res "$d")], record [$(rec "$d")]"
  rec "$d" >> "$ALL"

  echo "== [$SH] the deferred apply =="
  d=$(session); defer "$d" "$PKG" 1; retry "$d" ""
  { [ "$(rec "$d")" = "at=seal rc=applied lock=1" ] && [ ! -e "$d/state/.vpndeferred.10" ]; } \
    && ok "(D7) the seal's retry applies: note at=seal rc=applied lock=1" || no "(D7) record [$(rec "$d")]"
  rec "$d" >> "$ALL"

  d=$(session); defer "$d" "$PKG" 0; retry "$d" "$PKG"
  [ "$(rec "$d")" = "at=install rc=applied lock=0" ] && ok "(D8) the install's retry applies: note at=install rc=applied lock=0" \
    || no "(D8) record [$(rec "$d")]"
  rec "$d" >> "$ALL"

  d=$(session); defer "$d" "$PKG" 1; rm -f "$d/jar"; retry "$d" "$PKG"
  [ "$(rec "$d")" = "at=install rc=nohelper lock=1" ] && ok "(D8) no helper at the install: note at=install rc=nohelper lock=1" \
    || no "(D8) nohelper record [$(rec "$d")]"
  rec "$d" >> "$ALL"

  d=$(session); defer "$d" "$PKG" 1; echo com.example.othervpn > "$d/live/always_on_vpn_app"; retry "$d" ""
  [ "$(rec "$d")" = "at=seal rc=dropped lock=-" ] && ok "(D9) the user's own choice drops the deferral: note at=seal rc=dropped lock=-" \
    || no "(D9) record [$(rec "$d")]"
  rec "$d" >> "$ALL"

  d=$(session); defer "$d" "$PKG" 1; ( : > "$d/helperfail" ); i=1
  while [ "$i" -le "$TRIES" ]; do retry "$d" ""; i=$((i + 1)); done
  want=$(i=1; while [ "$i" -lt "$TRIES" ]; do echo "at=seal rc=notready lock=1"; i=$((i + 1)); done; echo "at=seal rc=gaveup lock=1")
  { [ "$(rec "$d")" = "$want" ] && [ ! -e "$d/state/.vpndeferred.10" ]; } \
    && ok "(D10) a read-back miss: notready at each of the first $((TRIES - 1)) attempts, then gaveup, lock 1" \
    || no "(D10) record [$(rec "$d" | tr '\n' ';')], want [$(printf '%s' "$want" | tr '\n' ';')]"
  rec "$d" >> "$ALL"

  d=$(session); retry "$d" ""; e=$( [ -e "$d/state/.vpndiag.10" ] && echo note)
  defer "$d" "$PKG" 1; retry "$d" com.example.another; e="$e$( [ -e "$d/state/.vpndiag.10" ] && echo note)"
  hold "$d" "$PKG"; retry "$d" ""; e="$e$( [ -e "$d/state/.vpndiag.10" ] && echo note)"
  printf 'garbage\n' > "$d/state/.vpndeferred.10"; retry "$d" ""; e="$e$( [ -e "$d/state/.vpndiag.10" ] && echo note)"
  [ -z "$e" ] && ok "(D11) no apply attempt (no deferral, another package, the app held, a bad deferral): no note" \
    || no "(D11) a note without an apply attempt [$(rec "$d")]"

  echo "== [$SH] the note itself =="
  if [ -s "$ALL" ] && ! grep -qF -e "$PKG" -e "$TUN" -e "$W" -e com.example -e wireguard "$ALL" \
    && ! grep -qvE '^at=(signin|seal|install) rc=(applied|none|nohelper|deferred|notready|gaveup|dropped|other) lock=(0|1|-)$' "$ALL"; then
    ok "(D12) every note of D1-D10 is codes only: no package, no tunnel, no path"
  else
    no "(D12) a note holds more than codes [$(tr '\n' ';' < "$ALL")]"
  fi

  d=$(session)
  run "$d" 'vpn_diag_note 10 boot applied 1; vpn_diag_note 10 seal com.example.vpn 1; vpn_diag_note 10 seal applied 2
vpn_diag_note x1 seal applied 1; vpn_diag_note "" seal applied 1; STATE=""; vpn_diag_note 10 seal applied 1
STATE="$ROOT/nostate"; vpn_diag_note 10 seal applied 1; echo "rc=$?"'
  { [ ! -e "$d/state/.vpndiag.10" ] && [ ! -e "$d/nostate" ] && [ "$(res "$d")" = "rc=0" ]; } \
    && ok "(D13) a field outside its set, a bad uid or no state dir: no note, nothing printed, rc 0" \
    || no "(D13) record [$(rec "$d")], stdout [$(res "$d")]"

  d=$(session)
  run "$d" 'i=1; while [ "$i" -le 12 ]; do if [ $((i % 2)) = 0 ]; then vpn_diag_note 10 seal notready 1; else vpn_diag_note 10 install applied 0; fi; i=$((i + 1)); done'
  want=$(i=5; while [ "$i" -le 12 ]; do if [ $((i % 2)) = 0 ]; then echo "at=seal rc=notready lock=1"; else echo "at=install rc=applied lock=0"; fi; i=$((i + 1)); done)
  e=$(ls -l "$d/state/.vpndiag.10" 2>/dev/null | cut -c1-10)
  { [ "$(rec "$d")" = "$want" ] && [ "$e" = "-rw-------" ] && [ -z "$(res "$d")" ]; } \
    && ok "(D14) twelve notes keep the last 8, mode 600, nothing printed" \
    || no "(D14) record [$(rec "$d" | tr '\n' ';')], mode [$e], stdout [$(res "$d")]"
}

# Parse first, then every case, under each shell.
printf '%s\n' "ROOT=/x; STATE=/x; LOG=/x" "$STUBS" "$BODY" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "THE BLOCKS DO NOT PARSE under $SH"; exit 2; }
  cases
done
SH=all
# shellcheck disable=SC2016
case "$CS" in
  *' "$STATE/.vpndiag.$uid" '*) ok '(D15) cleanstorage removes $STATE/.vpndiag.$uid with the departed session' ;;
  *) no "(D15) the cleanstorage rm list (# NWP-20261128-36) does not name .vpndiag.\$uid [$CS]" ;;
esac

if [ "$MODE" = mutate ]; then
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
      [ -n "$ev" ] || ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [all] ($id)" || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $label -- the suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $label (rc=$rc): $(printf '%s\n' "$out" | tail -1)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $label -- rc 1 with no ($id) FAIL line under $s"
      else ok "convicted by ($id): $label"; fi
    done
    SH=all
  }
  NONE_NOTE='    vpn_diag_note "$_uid" signin none -
'
  NONE_ANSWER="    printf 'OK NONE'; return 0
"
  mutate D1 "S1 vpn_apply's NONE is not noted" "$NONE_NOTE$NONE_ANSWER" "$NONE_ANSWER"
  mutate D8 "S2 an install is noted as a seal" '_at=seal; [ -n "$_inst" ] && _at=install' '_at=seal; [ -n "$_inst" ] && _at=seal'
  mutate D10 "S3 the give-up is not noted" '    vpn_diag_note "$_uid" "$_at" gaveup "$_lock"
' ''
  mutate D3 "S4 the lockdown is forced to - on an applied sign-in" \
    '[ -z "$_vd" ] || vpn_diag_note "$_uid" signin "$_vd" "$_lock"' '[ -z "$_vd" ] || vpn_diag_note "$_uid" signin "$_vd" -'
  mutate D12 "S5 the note carries \$_pkg" \
    '[ -z "$_vd" ] || vpn_diag_note "$_uid" signin "$_vd" "$_lock"' '[ -z "$_vd" ] || vpn_diag_note "$_uid" signin "$_vd" "$_lock" "$_pkg"' \
    "printf 'at=%s rc=%s lock=%s\\n' \"\$2\" \"\$3\" \"\$4\"" "printf 'at=%s rc=%s lock=%s%s\\n' \"\$2\" \"\$3\" \"\$4\" \"\${5:+ app=\$5}\""
  mutate D1 "S6 the NONE note is moved after its printf" "$NONE_NOTE$NONE_ANSWER" \
    "    printf 'OK NONE'; vpn_diag_note \"\$_uid\" signin none -; return 0
"
  mutate D15 "S7 cleanstorage no longer removes the note" '"$STATE/.odbatch3.$uid".* "$STATE/.vpndiag.$uid" 2>/dev/null' \
    '"$STATE/.odbatch3.$uid".* 2>/dev/null'
  mutate D9 "S8 the user's-choice drop is not noted" '    vpn_diag_note "$_uid" "$_at" dropped -
' ''
  mutate D10 "S9 the not-ready attempts are not noted" '  vpn_diag_note "$_uid" "$_at" notready "$_lock"
' ''
  mutate D7 "S10 the deferred apply's OK is not noted" '      vpn_diag_note "$_uid" "$_at" "$_vd" "$_lock"
' ''
  mutate D14 "S11 the note keeps every line" '_vdk=$(tail -n 7 "$_vdf" 2>/dev/null)' '_vdk=$(cat "$_vdf" 2>/dev/null)'
  mutate D13 "S12 the note takes any rc" \
    'case "$3" in applied|none|nohelper|deferred|notready|gaveup|dropped|other) ;; *) return 0 ;; esac' 'case "$3" in *) ;; esac'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
