#!/usr/bin/env bash
# test-vpnstate-op.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's read-only vpnstate op (NWP-20261202-43), run for
# real rather than grepped.
#
# An in-session issue report asks roamd's RO lane for the always-on VPN state of the session's user. The op answers
# `VPNSTATE app=<c> lock=<c> pend=<c> net=<c>`, each code 1, 0 or -, and carries properties the Go tests cannot reach:
#   - net is the VPN app's INTERNET grant IN THIS USER: vpn_net_state reads the package's `User <uid>:` block of
#     `dumpsys package` (GrapheneOS: INTERNET is the runtime Network permission), else its `install permissions:`
#     block (Diaspore), else -. Another user's block must never be read.
#   - pend is 1 only when nowhere_vpn_lockdown_pending names the app that is set.
#   - app is 1 only for a package name; an `Error: ...` value is -, a null or empty one 0.
#   - a `settings` read that exits non-zero is - WHATEVER it printed (RF-001): a failed read never yields a 1 or a 0.
#   - PRIVACY: the package is compared inside roamd and never printed, logged or sent. Neither $RES nor $LOG may
#     ever hold it.
#   - the reply is published by rename and the log line is read from $RES.part before the mv.
#
# The arm and the helper are extracted from nowhere_roamd.sh BY ANCHOR, never copied, and run under EVERY shell
# present (bash, sh, dash, mksh -- mksh is the device's /system/bin/sh) with `settings` and `dumpsys` stubbed. The
# dumpsys fixtures follow AOSP's PackageManagerService dump layout, read from source, not from a device.
#
#   bash test-vpnstate-op.sh               # the behaviour cases under every shell found, and the static pin
#   bash test-vpnstate-op.sh --mutate      # ... plus mutations that must each CONVICT the suite under each shell
#   bash test-vpnstate-op.sh --shell mksh  # the behaviour cases under that one shell only
#   bash test-vpnstate-op.sh --no-pins     # skip the shell-independent allowlist pin (the per-shell mutant runs use it)
set -uo pipefail

MUTATE=no; SUT=""; ONLY=""; PINS=yes; _next=""
for a in "$@"; do
  if [ "$_next" = shell ]; then ONLY="$a"; _next=""; continue; fi
  case "$a" in --mutate) MUTATE=yes ;; --shell) _next=shell ;; --no-pins) PINS=no ;; *) SUT="$a" ;; esac
done
[ -z "$_next" ] || { echo "--shell needs a shell name" >&2; exit 2; }
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
if [ -n "$ONLY" ]; then
  command -v "$ONLY" >/dev/null 2>&1 || { echo "no such shell: $ONLY" >&2; exit 2; }
  SHELLS=" $ONLY"
fi

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT   # every temp below lives inside $W
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
FN=$(sed -n '/^vpn_net_state() {$/,/^}$/p' "$SUT")
OP=$(sed -n '/^  vpnstate)$/,/^    ;;$/p' "$SUT" | sed '1d;$d')
case "$FN" in *"dumpsys package"*) ;; *) echo "EXTRACTION FAILED: vpn_net_state" >&2; exit 2 ;; esac
case "$OP" in *VPNSTATE*) ;; *) echo "EXTRACTION FAILED: the vpnstate) op" >&2; exit 2 ;; esac

# --- harness --------------------------------------------------------------------------------------------
# Modes are asserted only where the filesystem keeps them (probed, never assumed).
P=$(mktemp -d -p "$W"); : > "$P/f"; chmod 600 "$P/f" 2>/dev/null
MODES=no; [ "$(stat -c %a "$P/f" 2>/dev/null)" = 600 ] && MODES=yes; rm -rf "$P"
mode600(){ [ "$MODES" = no ] || [ "$(stat -c %a "$1" 2>/dev/null)" = 600 ]; }

PKG=org.example.vpnfixture   # a fake package; no reply or log line may ever hold it
OTHER=org.example.othervpn

# dump <dir> <variant>: writes the fixture `dumpsys package` output to <dir>/dump.
dump(){
  local f="$1/dump"
  case "$2" in
    granted)   # another package listed first, its user-10 line false; ours true
      printf '%s\n' 'Packages:' "  Package [$OTHER] (9f9f9f):" '    userId=10200' \
        '    User 10: ceDataInode=7 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.INTERNET: granted=false' \
        "  Package [$PKG] (1a2b3c):" '    userId=10123' '    install permissions:' \
        '      android.permission.ACCESS_NETWORK_STATE: granted=true' \
        '    User 10: ceDataInode=2 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.INTERNET: granted=true' > "$f" ;;
    denied)
      printf '%s\n' 'Packages:' "  Package [$PKG] (1a2b3c):" '    userId=10123' \
        '    User 10: ceDataInode=2 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.INTERNET: granted=false' > "$f" ;;
    otheruser) # user 0's block first and granted; ours (user 10) not
      printf '%s\n' 'Packages:' "  Package [$PKG] (1a2b3c):" '    userId=10123' \
        '    User 0: ceDataInode=1 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.INTERNET: granted=true, flags=[ USER_SET ]' \
        '    User 10: ceDataInode=2 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.INTERNET: granted=false' > "$f" ;;
    flags)
      printf '%s\n' 'Packages:' "  Package [$PKG] (1a2b3c):" '    userId=10123' \
        '    User 10: ceDataInode=2 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.INTERNET: granted=true, flags=[ USER_SET|USER_SENSITIVE_WHEN_GRANTED ]' > "$f" ;;
    install1|install0)
      local g=true; [ "$2" = install0 ] && g=false
      printf '%s\n' 'Packages:' "  Package [$PKG] (1a2b3c):" '    userId=10123' '    install permissions:' \
        "      android.permission.INTERNET: granted=$g" '      android.permission.WAKE_LOCK: granted=true' \
        '    User 10: ceDataInode=2 installed=true hidden=false' '      runtime permissions:' \
        '        android.permission.POST_NOTIFICATIONS: granted=true' > "$f" ;;
    nointernet)
      printf '%s\n' 'Packages:' "  Package [$PKG] (1a2b3c):" '    userId=10123' '    install permissions:' \
        '      android.permission.WAKE_LOCK: granted=true' \
        '    User 10: ceDataInode=2 installed=true hidden=false' > "$f" ;;
    empty) : > "$f" ;;
  esac
}

# runcase <shell> <dir> [uid]: runs the extracted arm (with vpn_net_state) under <shell>. <dir> holds one file per
# secure setting and the dump. An absent setting file is a failed read: settings prints nothing and exits 1. A
# <key>.rc file sets the exit status of a read that does print (a failed read with recognizable output). Each stub
# records its call.
runcase(){
  local sh="$1" T="$2" u="${3:-10}"
  { printf 'FIX=%s\nLOG=%s\nRES=%s\nuid=%s\n' "$T" "$T/log" "$T/roamro.res" "$u"
    printf '%s\n' 'settings(){ echo "$*" >> "$FIX/settings.args"; [ -f "$FIX/$5" ] || return 1; cat "$FIX/$5"; [ -f "$FIX/$5.rc" ] && return "$(cat "$FIX/$5.rc")"; return 0; }' \
      'dumpsys(){ echo "$*" >> "$FIX/dumpsys.args"; [ -f "$FIX/dump" ] && cat "$FIX/dump"; return 0; }'
    printf '%s\n' "$FN" "$OP"; } > "$T/op.sh"
  "$sh" "$T/op.sh" >/dev/null 2>&1
}

# setv <dir> <key> <value>: the stubbed `settings get` prints <value> for <key>.
setv(){ printf '%s\n' "$3" > "$1/$2"; }

# expect <shell> <dir> <label> <want reply>: the reply, the mode, no .part, one log line carrying it, no package.
expect(){
  local sh="$1" T="$2" label="$3" want="$4" got logtxt
  got=$(cat "$T/roamro.res" 2>/dev/null)
  [ "$got" = "$want" ] && ok "[$sh] $label: $want" || no "[$sh] $label: reply '$got', want '$want'"
  mode600 "$T/roamro.res" && ok "[$sh] $label: RES is 600 (modes checked: $MODES)" || no "[$sh] $label: RES mode $(stat -c %a "$T/roamro.res" 2>/dev/null)"
  [ ! -e "$T/roamro.res.part" ] && ok "[$sh] $label: X2 no .part left behind" || no "[$sh] $label: X2 .part left behind"
  logtxt=$(cat "$T/log" 2>/dev/null)
  case "$logtxt" in
    "[roamd] vpnstate user ${5:-10} -> $want "*) ok "[$sh] $label: X1 the log line carries the reply" ;;
    *) no "[$sh] $label: X1 log reads '$logtxt'" ;;
  esac
  [ "$(printf '%s\n' "$logtxt" | wc -l)" -eq 1 ] && ok "[$sh] $label: X1 one log line" || no "[$sh] $label: X1 log has $(printf '%s\n' "$logtxt" | wc -l) lines"
  case "$got$logtxt" in
    *vpnfixture*|*othervpn*) no "[$sh] $label: X1 the package reached RES or the log" ;;
    *) ok "[$sh] $label: X1 neither RES nor the log holds a package name" ;;
  esac
}

# called <dir>: whether dumpsys was asked.
called(){ [ -s "$1/dumpsys.args" ]; }

behaviour(){   # behaviour <shell>: every case that runs roamd code, under that shell
  local sh="$1" T v
  echo "== [$sh] net: the VPN app's INTERNET grant in THIS user =="
  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 0
  setv "$T" nowhere_vpn_lockdown_pending null; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "N1 granted" "VPNSTATE app=1 lock=0 pend=0 net=1"
  [ "$(cat "$T/dumpsys.args" 2>/dev/null)" = "package $PKG" ] && ok "[$sh] N1 dumpsys asked for that one package" \
    || no "[$sh] N1 dumpsys args '$(cat "$T/dumpsys.args" 2>/dev/null)'"
  rm -rf "$T"

  for v in "N2 not granted:denied:0" "N3 another user's block granted, ours not:otheruser:0" \
           "N4 a flags suffix:flags:1" "N5 install-permission form, granted:install1:1" \
           "N5 install-permission form, not granted:install0:0" "N6 no INTERNET line:nointernet:-" \
           "N7 dumpsys prints nothing:empty:-"; do
    T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 0
    setv "$T" nowhere_vpn_lockdown_pending null; dump "$T" "$(echo "$v" | cut -d: -f2)"; runcase "$sh" "$T"
    expect "$sh" "$T" "$(echo "$v" | cut -d: -f1)" "VPNSTATE app=1 lock=0 pend=0 net=$(echo "$v" | cut -d: -f3)"
    rm -rf "$T"
  done

  echo "== [$sh] app, lock and pend =="
  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app null; setv "$T" always_on_vpn_lockdown 0
  setv "$T" nowhere_vpn_lockdown_pending null; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "A1 no app set" "VPNSTATE app=0 lock=0 pend=0 net=-"
  called "$T" && no "[$sh] A1 dumpsys was asked with no app set" || ok "[$sh] A1 dumpsys not asked"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "Error: x"; setv "$T" always_on_vpn_lockdown 1
  setv "$T" nowhere_vpn_lockdown_pending "Error: x"; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "A2 an app value that is not a package name" "VPNSTATE app=- lock=1 pend=0 net=-"
  called "$T" && no "[$sh] A2 dumpsys was asked for a non-package value" || ok "[$sh] A2 dumpsys not asked"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app nopackage; setv "$T" always_on_vpn_lockdown null
  setv "$T" nowhere_vpn_lockdown_pending null; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "A3 a value with no dot" "VPNSTATE app=- lock=0 pend=0 net=-"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 1
  setv "$T" nowhere_vpn_lockdown_pending "$PKG"; dump "$T" denied; runcase "$sh" "$T"
  expect "$sh" "$T" "L1 lockdown on, pend names the app" "VPNSTATE app=1 lock=1 pend=1 net=0"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 0
  setv "$T" nowhere_vpn_lockdown_pending "$OTHER"; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "P1 pend names another app" "VPNSTATE app=1 lock=0 pend=0 net=1"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "U1 every settings read fails and prints nothing" "VPNSTATE app=- lock=- pend=- net=-"
  called "$T" && no "[$sh] U1 dumpsys was asked with no app read" || ok "[$sh] U1 dumpsys not asked"
  rm -rf "$T"

  # RF-001: a read that succeeds with an empty value is a value (none set), not a failure.
  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app ""; setv "$T" always_on_vpn_lockdown ""
  setv "$T" nowhere_vpn_lockdown_pending ""; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "E1 every settings read succeeds empty" "VPNSTATE app=0 lock=0 pend=0 net=-"
  called "$T" && no "[$sh] E1 dumpsys was asked with no app set" || ok "[$sh] E1 dumpsys not asked"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 1
  setv "$T" nowhere_vpn_lockdown_pending ""; dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "E2 pend succeeds empty while an app is set" "VPNSTATE app=1 lock=1 pend=0 net=1"
  rm -rf "$T"

  # RF-001: a read that exits non-zero is unreadable, even when what it printed looks like a valid value.
  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 1
  setv "$T" nowhere_vpn_lockdown_pending "$PKG"; dump "$T" granted
  for v in always_on_vpn_app always_on_vpn_lockdown nowhere_vpn_lockdown_pending; do echo 1 > "$T/$v.rc"; done
  runcase "$sh" "$T"
  expect "$sh" "$T" "F1 every settings read exits 1 with a valid-looking value" "VPNSTATE app=- lock=- pend=- net=-"
  called "$T" && no "[$sh] F1 dumpsys was asked after a failed app read" || ok "[$sh] F1 dumpsys not asked"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 0
  setv "$T" nowhere_vpn_lockdown_pending "$PKG"; echo 2 > "$T/nowhere_vpn_lockdown_pending.rc"
  dump "$T" granted; runcase "$sh" "$T"
  expect "$sh" "$T" "F2 only the pend read exits 2, printing the app" "VPNSTATE app=1 lock=0 pend=- net=1"
  rm -rf "$T"

  T=$(mktemp -d -p "$W"); setv "$T" always_on_vpn_app "$PKG"; setv "$T" always_on_vpn_lockdown 1
  setv "$T" nowhere_vpn_lockdown_pending "$PKG"; dump "$T" granted; runcase "$sh" "$T" "1x"
  expect "$sh" "$T" "U2 a uid that is not a number" "VPNSTATE app=- lock=- pend=- net=-" "1x"
  [ ! -e "$T/settings.args" ] && ok "[$sh] U2 settings not asked for a bad uid" || no "[$sh] U2 settings asked: $(cat "$T/settings.args")"
  rm -rf "$T"
}
for sh in $SHELLS; do behaviour "$sh"; done

# The allowlist pin: shell-independent, so it runs once.
if [ "$PINS" = yes ]; then
  echo "== [static] vpnstate is on the read-only lane's allowlist =="
  # Every `    <ops>) ;;` line of the RO gate, joined into one `|op|op|...|` list.
  ALLOW=$(sed -n '/^if \[ "\$LANE" = "ro" \]; then$/,/^  esac$/p' "$SUT" | sed -n 's/^    \([a-z|]*\)) ;;$/\1/p' | tr '\n' '|')
  case "|$ALLOW" in
    *"|vpnstate|"*) ok "[static] S1 the RO allowlist names vpnstate" ;;
    *) no "[static] S1 the RO allowlist '$ALLOW' does not name vpnstate (every report would say unavailable)" ;;
  esac
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  # mutate <run|pin> <name> <sed>: a `run` mutant must be convicted by a run restricted to EACH shell on its own,
  # pins off, with rc 1 and a FAIL line for that shell; a `pin` mutant once, by a [static] FAIL line.
  mutate(){
    local kind="$1" name="$2" sh rc out
    if ! sed "$3" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $name"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $name"; return; fi
    bash -n "$M/m.sh" 2>/dev/null || { no "MUTATION BROKEN (does not parse): $name"; return; }
    if [ "$kind" = pin ]; then
      out=$(bash "$0" --shell bash "$M/m.sh" 2>&1); rc=$?
      case "$out" in *"FAIL  [static]"*) [ "$rc" = 1 ] && { ok "convicted (static): $name"; return; } ;; esac
      no "NOT CONVICTED (rc $rc, no [static] FAIL line): $name"
      return
    fi
    for sh in $SHELLS; do
      out=$(bash "$0" --no-pins --shell "$sh" "$M/m.sh" 2>&1); rc=$?
      case "$out" in
        *"FAIL  [$sh]"*) [ "$rc" = 1 ] && ok "convicted under $sh: $name" || no "NOT CONVICTED under $sh (rc $rc): $name" ;;
        *) no "NOT CONVICTED under $sh (rc $rc, no FAIL line): $name" ;;
      esac
    done
  }
  mutate run "V1 granted=false read as 1 (N2, N3)" 's@g = (s ~ /^android.*) ? 1 : 0@g = 1@'
  mutate run "V2 the user block ignored: first match in any user block (N3)" 's@if (ub \&\& ours) {@if (ub) {@'
  mutate run "V3 pend 1 for any value (P1)" 's@if \[ "\$_vsa" = 1 \] \&\& \[ "\$_vsv" = "\$_vsapp" \]; then _vsp=1@if true; then _vsp=1@'
  mutate run "V4 app=1 for a non-package value (A2)" 's@\*\[!A-Za-z0-9._\]\*) _vsa=- ;;@*[!A-Za-z0-9._]*) _vsa=1 ;;@'
  mutate run "V5 the package added to the log line (X1)" 's@-> \$_vsh \$(date)@-> $_vsh $_vsapp $(date)@'
  mutate run "V7 the install-permission block ignored (N5)" 's@} else if (ib \&\& !ub) {@} else if (0) {@'
  mutate run "V9 a failed app read interpreted (F1)" \
    's@if _vsapp=\$(settings get --user "\$uid" secure always_on_vpn_app </dev/null 2>/dev/null); then@_vsapp=$(settings get --user "$uid" secure always_on_vpn_app </dev/null 2>/dev/null); if true; then@'
  mutate run "V10 a failed lockdown read interpreted (F1)" \
    's@if _vsv=\$(settings get --user "\$uid" secure always_on_vpn_lockdown </dev/null 2>/dev/null); then@_vsv=$(settings get --user "$uid" secure always_on_vpn_lockdown </dev/null 2>/dev/null); if true; then@'
  mutate run "V11 a failed pend read interpreted (F2)" \
    's@if _vsv=\$(settings get --user "\$uid" secure nowhere_vpn_lockdown_pending </dev/null 2>/dev/null); then@_vsv=$(settings get --user "$uid" secure nowhere_vpn_lockdown_pending </dev/null 2>/dev/null); if true; then@'
  mutate run "V12 a successful empty app read read as unreadable (E1)" "s@''|null) _vsa=0 ;;@'') _vsa=- ;; null) _vsa=0 ;;@"
  mutate run "V13 a successful empty pend read read as unreadable (E2)" \
    's@if \[ "\$_vsa" = 1 \] \&\& \[ "\$_vsv" = "\$_vsapp" \]; then _vsp=1; else _vsp=0; fi@if [ -z "$_vsv" ]; then _vsp=-; elif [ "$_vsa" = 1 ] \&\& [ "$_vsv" = "$_vsapp" ]; then _vsp=1; else _vsp=0; fi@'
  mutate run "V8 the reply never renamed into RES (X2)" '/^  vpnstate)$/,/^    ;;$/{/^    mv -f "\$RES.part" "\$RES"/d}'
  mutate pin "V6 vpnstate removed from the RO allowlist (S1)" 's@|gmsstate|vpnstate) ;;@|gmsstate) ;;@'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
