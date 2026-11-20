#!/usr/bin/env bash
# test-vpn-refusal-why.sh [<nowhere_roamd.sh>] [--mutate] [--shell <sh>] -- a refused always-on VPN apply says why
# (NWP-20261208-10).
#
# WHY THIS IS COMMITTED. On 0.5.58 roam.log held 29 lines `setAlwaysOnVpnPackage(user=10, pkg=<vpn app>,
# lockdown=false) -> false` and then `vpnup: user 10 gave up after 45 tries`, with no word on why Android said false.
# Now vpn_apply_choice adds `; refused: <codes> lock=<l>` to such a line (vpn_refusal_codes), keeps the last refusal and
# a count in $STATE/.vpnwhy.<uid>, and the read-only vpnstate op carries it as its fifth field, `refused=...`. Codes
# only: the package never reaches the suffix, the record or the reply.
#
# vpn_refusal_codes, vpn_refusal_token (the whole-record check the writer's count and the reply both pass through),
# vpn_apply_choice, vpn_pick_consume, vpn_diag_note, vpn_net_state and the vpnstate arm are extracted from
# nowhere_roamd.sh BY ANCHOR, never copied, and run under every shell found (bash, dash, mksh, and sh when it is not
# one of them) with app_process, settings, pm, dumpsys, am, cmd and date stubbed as executables first
# in PATH (vpn_refusal_codes runs them through `timeout`, which cannot run a shell function). The fixtures follow AOSP
# source (Settings.dumpPackageLPr, PackageManagerShellCommand, UserState.toString), not a device.
#
#   bash test-vpn-refusal-why.sh                 # the cases under every shell found, and the source pins
#   bash test-vpn-refusal-why.sh --mutate        # ... plus mutations that the named case must convict, each shell
#   bash test-vpn-refusal-why.sh --shell dash    # the cases under that one shell only
set -uo pipefail

MUTATE=no; SUT=""; ONLY=""; PINS=yes; _next=""
for a in "$@"; do
  if [ "$_next" = shell ]; then ONLY="$a"; _next=""; continue; fi
  case "$a" in --mutate) MUTATE=yes ;; --shell) _next=shell ;; --no-pins) PINS=no ;; *) SUT="$a" ;; esac
done
[ -z "$_next" ] || { echo "--shell needs a shell name" >&2; exit 2; }
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT   # every temp below lives inside $W

SHELLS=""
if [ -n "$ONLY" ]; then
  command -v "$ONLY" >/dev/null 2>&1 || { echo "no such shell: $ONLY" >&2; exit 2; }
  SHELLS="$ONLY"
else
  for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
  if p=$(command -v sh 2>/dev/null); then
    r=$(readlink -f "$p"); dup=""
    for s in $SHELLS; do [ "$(readlink -f "$(command -v "$s")")" = "$r" ] && { dup=$s; break; }; done
    if [ -n "$dup" ]; then echo "skip shell sh: same binary as $dup"; else SHELLS="$SHELLS sh"; fi
  fi
fi
[ -n "$SHELLS" ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=static
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
func(){ awk -v l="$1() {" '$0==l{on=1} on{print} on&&/^}$/{exit}' "$SUT"; }
RC=$(func vpn_refusal_codes)
RT=$(func vpn_refusal_token)
AC=$(func vpn_apply_choice)
PC=$(func vpn_pick_consume)
DN=$(func vpn_diag_note)
NS=$(func vpn_net_state)
OP=$(sed -n '/^  vpnstate)$/,/^    ;;$/p' "$SUT" | sed '1d;$d')
# origin/main has no vpn_refusal_codes: run the cases against a no-op one, so they print FAIL lines, not exit 2.
case "$RC" in *'get-started-user-state'*) ;; *) echo "note: no vpn_refusal_codes in $SUT; a no-op stands in"; RC='vpn_refusal_codes(){ :; }' ;; esac
case "$RT" in *'vpn_refusal_token()'*) ;; *) echo "note: no vpn_refusal_token in $SUT; a failing one stands in"; RT='vpn_refusal_token(){ return 1; }' ;; esac
case "$AC" in *'np.VpnAlwaysOn'*) ;; *) echo "EXTRACTION FAILED: vpn_apply_choice in $SUT" >&2; exit 2 ;; esac
case "$PC" in *'nowhere-vpn-pick'*) ;; *) echo "EXTRACTION FAILED: vpn_pick_consume in $SUT" >&2; exit 2 ;; esac
case "$DN" in *'.vpndiag.'*) ;; *) echo "EXTRACTION FAILED: vpn_diag_note in $SUT" >&2; exit 2 ;; esac
case "$NS" in *'dumpsys package'*) ;; *) echo "EXTRACTION FAILED: vpn_net_state in $SUT" >&2; exit 2 ;; esac
case "$OP" in *VPNSTATE*) ;; *) echo "EXTRACTION FAILED: the vpnstate) op in $SUT" >&2; exit 2 ;; esac

# Modes are asserted only where the filesystem keeps them (probed, never assumed).
P=$(mktemp -d -p "$W"); : > "$P/f"; chmod 600 "$P/f" 2>/dev/null
MODES=no; [ "$(stat -c %a "$P/f" 2>/dev/null)" = 600 ] && MODES=yes; rm -rf "$P"
mode600(){ [ "$MODES" = no ] || [ "$(stat -c %a "$1" 2>/dev/null)" = 600 ]; }

PKG=org.example.vpnfixture   # a fake package; no suffix, record or reply may ever hold it
OTHER=org.example.othervpn
DATE='Mon Dec  8 10:00:00 UTC 2026'

# --- the fake device ------------------------------------------------------------------------------------
# fixture: one case root with executable stubs in $T/bin. Every stub records its argv in $T/calls.
#   app_process  prints $T/helper.out verbatim       settings get ... <key>  prints $T/set.<key>, else null
#   pm list ...  prints $T/pm.list (and $T/pm.list.a when an argument is exactly -a), exits $(cat $T/pm.rc), else 0
#   pm query-services ...  prints $T/svc.out          dumpsys package <p>  prints $T/dump
#   am get-started-user-state <u>  prints $T/am.out  cmd  records only      date  prints a fixed string
fixture(){
  local T b
  T=$(mktemp -d -p "$W")
  mkdir -p "$T/bin" "$T/state" "$T/data/user/10/$PKG" "$T/data/user/10/com.nowhere.chooser/files"
  : > "$T/vpnao.jar"; : > "$T/calls"; : > "$T/log"
  printf '%s\n' '#!/bin/sh' 'echo "app_process $*" >> "$FIX/calls"' 'cat "$FIX/helper.out" 2>/dev/null' 'exit 0' > "$T/bin/app_process"
  printf '%s\n' '#!/bin/sh' 'echo "settings $*" >> "$FIX/calls"' 'if [ -f "$FIX/set.$5" ]; then cat "$FIX/set.$5"; else echo null; fi' 'exit 0' > "$T/bin/settings"
  printf '%s\n' '#!/bin/sh' 'echo "pm $*" >> "$FIX/calls"' \
    'case "$1" in' \
    '  list) cat "$FIX/pm.list" 2>/dev/null; for a in "$@"; do [ "$a" = -a ] && cat "$FIX/pm.list.a" 2>/dev/null; done' \
    '        [ -f "$FIX/pm.rc" ] && exit "$(cat "$FIX/pm.rc")"; exit 0 ;;' \
    '  query-services) cat "$FIX/svc.out" 2>/dev/null; exit 0 ;;' \
    'esac' 'exit 0' > "$T/bin/pm"
  printf '%s\n' '#!/bin/sh' 'echo "dumpsys $*" >> "$FIX/calls"' 'cat "$FIX/dump" 2>/dev/null' 'exit 0' > "$T/bin/dumpsys"
  printf '%s\n' '#!/bin/sh' 'echo "am $*" >> "$FIX/calls"' 'cat "$FIX/am.out" 2>/dev/null' 'exit 0' > "$T/bin/am"
  printf '%s\n' '#!/bin/sh' 'echo "cmd $*" >> "$FIX/calls"' 'exit 0' > "$T/bin/cmd"
  printf '%s\n' '#!/bin/sh' "echo '$DATE'" > "$T/bin/date"
  for b in app_process settings pm dumpsys am cmd date; do chmod +x "$T/bin/$b"; done
  printf '%s\n' "$T"
}

# dumpfix <root> <user-10 fields> <targetSdk>: the AOSP Settings.dumpPackageLPr layout. Another package's block comes
# first and user 0's line comes before user 10's, each with other values, so a read of the wrong block shows.
dumpfix(){
  printf '%s\n' 'Packages:' \
    "  Package [$PKG.extra] (9f9f9f):" '    versionCode=1 minSdk=21 targetSdk=10' \
    '    User 10: ceDataInode=7 installed=true hidden=true suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=2 instant=false virtual=false' \
    "  Package [$PKG] (1a2b3c):" '    userId=10123' "    versionCode=1 minSdk=21 targetSdk=$3" \
    '    User 0: ceDataInode=1 installed=true hidden=true suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=4 instant=false virtual=false' \
    "    User 10: ceDataInode=2 installed=true $2 suspended=false distractionFlags=0 notLaunched=false instant=false virtual=false" \
    '      runtime permissions:' '        android.permission.INTERNET: granted=true' \
    "  Package [$OTHER] (4d5e6f):" '    versionCode=1 minSdk=21 targetSdk=30' > "$1/dump"
}

# run <shell> <root> <body>: the extracted functions and <body> under <shell>, PATH stubs first, roots re-rooted.
run(){
  local sh="$1" T="$2"
  { printf 'FIX=%s; export FIX\nPATH=%s/bin:$PATH; export PATH\n' "$T" "$T"
    printf 'LOG=%s/log\nSTATE=%s/state\nRES=%s/res\nVPN_USER_ROOT=%s/data/user\nNOWHERE_VPN_JAR=%s/vpnao.jar\nuid=10\n' "$T" "$T" "$T" "$T" "$T"
    printf '%s\n' "$RC" "$RT" "$NS" "$DN" "$PC" "$AC" "$3"; } > "$T/run.sh"
  "$sh" "$T/run.sh" > "$T/out" 2>"$T/err"
}

APPLY='vpn_apply_choice 10 capture '"$PKG"' 0 ""'
LINE0="[roamd] always-on VPN -> $PKG (lockdown=0 via 0, from capture) user 10 $DATE: "
falsehelper(){ printf 'setAlwaysOnVpnPackage(user=10, pkg=%s, lockdown=false) -> false\n' "$PKG" > "$1/helper.out"; }

# suffix <root>: what follows `refused: ` on the log's one line, or an empty string.
suffix(){ local l; l=$(cat "$1/log"); case "$l" in *'; refused: '*) printf '%s' "${l#*; refused: }" ;; esac; }

# closedset <label> <codes line>: every field in its closed set, nothing else on the line, no package name.
closedset(){
  local f bad=""
  case "$2" in *vpnfixture*|*othervpn*) no "$1: holds a package name: '$2'"; return ;; esac
  for f in $2; do
    case "$f" in
      n=[1-9]|n=[1-9][0-9]|n=[1-9][0-9][0-9]) ;;
      inst=[10-]|hid=[10-]|en=[10-]|stop=[10-]|svc=[10-]|tsdk=[10-]|lock=[01]) ;;
      usr=unlocked|usr=locked|usr=unlocking|usr=booting|usr=stopping|usr=shutdown|usr=notstarted|usr=-) ;;
      *) bad="$bad $f" ;;
    esac
  done
  [ -z "$bad" ] && [ -n "$2" ] && ok "$1: every field in its closed set, no package name" || no "$1: fields outside the closed sets:${bad:- (empty)}"
}

W1CODES='inst=1 hid=0 en=1 stop=1 svc=1 tsdk=1 usr=unlocked'
behaviour(){
  local sh="$1" T got want rec
  SH=$sh
  echo "== [$sh] W1 a refused apply logs why, and the record counts it =="
  T=$(fixture); falsehelper "$T"
  printf '%s\n' "package:$OTHER" "package:$PKG" > "$T/pm.list"
  dumpfix "$T" 'hidden=false stopped=true enabled=0' 34
  printf '%s\n' '2 services found:' "  $PKG/.Svc" "  $OTHER/.S" > "$T/svc.out"
  echo '[UserState: id=10, state=RUNNING_UNLOCKED, lastState=RUNNING_UNLOCKING, switching=false]' > "$T/am.out"
  run "$sh" "$T" "$APPLY"
  [ "$(cat "$T/out")" = NOTREADY ] && ok "W1 the answer stays NOTREADY" || no "W1 the answer is '$(cat "$T/out")'"
  got=$(cat "$T/log")
  want="${LINE0}setAlwaysOnVpnPackage(user=10, pkg=$PKG, lockdown=false) -> false ; read back app=null lockdown=null pending=null -> no; refused: $W1CODES lock=0"
  [ "$got" = "$want" ] && ok "W1 the log line ends '; refused: $W1CODES lock=0'" || no "W1 the log line reads '$got'"
  rec=$(cat "$T/state/.vpnwhy.10" 2>/dev/null)
  [ "$rec" = "n=1 $W1CODES lock=0" ] && ok "W1 the record is 'n=1 ... lock=0'" || no "W1 the record reads '$rec'"
  mode600 "$T/state/.vpnwhy.10" && ok "W1 the record is 600 (modes checked: $MODES)" || no "W1 the record mode is $(stat -c %a "$T/state/.vpnwhy.10" 2>/dev/null)"
  [ ! -e "$T/state/.vpnwhy.10.tmp" ] && ok "W1 no .tmp left" || no "W1 a .tmp is left"
  closedset "W5 (W1 suffix)" "$(suffix "$T")"; closedset "W5 (W1 record)" "$rec"
  : > "$T/log"; run "$sh" "$T" "$APPLY"
  rec=$(cat "$T/state/.vpnwhy.10" 2>/dev/null)
  [ "$rec" = "n=2 $W1CODES lock=0" ] && ok "W1 a second refusal counts n=2" || no "W1 after a second refusal the record reads '$rec'"
  for got in 'n=8 malformed-record' "n=8 $W1CODES lock=0
" "n=8 $W1CODES lock=0
$PKG" "n=8 $W1CODES lock=0 x=1"; do
    printf '%s\n' "$got" > "$T/state/.vpnwhy.10"; : > "$T/log"; run "$sh" "$T" "$APPLY"
    rec=$(cat "$T/state/.vpnwhy.10" 2>/dev/null)
    [ "$rec" = "n=1 $W1CODES lock=0" ] && ok "W1 a malformed stored record ($(printf '%s' "$got" | head -n 1)...) counts again from n=1" \
      || no "W1 after a malformed stored record the record reads '$rec'"
  done
  run "$sh" "$T" "vpn_refusal_codes 10 $PKG; echo rc=\$?"
  [ "$(cat "$T/out")" = "$W1CODES
rc=0" ] && ok "W1 vpn_refusal_codes prints one line and returns 0" || no "W1 vpn_refusal_codes printed '$(cat "$T/out")'"
  rm -rf "$T"

  echo "== [$sh] W2 not installed, no VpnService of its own, user not started, disabled =="
  T=$(fixture); falsehelper "$T"
  echo "package:$PKG.extra" > "$T/pm.list"; echo "package:$PKG" > "$T/pm.list.a"
  dumpfix "$T" 'hidden=true stopped=false enabled=3' 23
  printf '%s\n' "  prefix.$PKG/.Svc" > "$T/svc.out"
  echo 'User is not started: 10' > "$T/am.out"
  run "$sh" "$T" "$APPLY"
  want='inst=0 hid=1 en=0 stop=0 svc=0 tsdk=0 usr=notstarted lock=0'
  got=$(suffix "$T")
  [ "$got" = "$want" ] && ok "W2 the suffix is '$want'" || no "W2 the suffix reads '$got'"
  closedset "W5 (W2 suffix)" "$got"
  case "$(cat "$T/calls")" in *'pm list packages --user 10'*) ok "W2 inst asked the user's listing" ;; *) no "W2 no listing call in '$(cat "$T/calls")'" ;; esac
  rm -rf "$T"
  T=$(fixture); falsehelper "$T"; echo "package:$PKG" > "$T/pm.list"
  dumpfix "$T" 'hidden=false stopped=false enabled=1' 24; echo 'No services found' > "$T/svc.out"
  echo '[UserState: id=10, state=RUNNING_LOCKED, lastState=BOOTING, switching=false]' > "$T/am.out"
  run "$sh" "$T" "$APPLY"
  want='inst=1 hid=0 en=1 stop=0 svc=0 tsdk=1 usr=locked lock=0'; got=$(suffix "$T")
  [ "$got" = "$want" ] && ok "W2 'No services found' is svc=0, targetSdk 24 is tsdk=1" || no "W2 the suffix reads '$got', want '$want'"
  rm -rf "$T"

  echo "== [$sh] W3 every read fails or says nothing =="
  T=$(fixture); falsehelper "$T"; echo 1 > "$T/pm.rc"; : > "$T/pm.list"; : > "$T/dump"; : > "$T/svc.out"
  echo 'junk words' > "$T/am.out"
  run "$sh" "$T" "$APPLY"
  want='inst=- hid=- en=- stop=- svc=- tsdk=- usr=- lock=0'; got=$(suffix "$T")
  [ "$got" = "$want" ] && ok "W3 every code is -" || no "W3 the suffix reads '$got'"
  closedset "W5 (W3 suffix)" "$got"
  rm -rf "$T"
  for a in "1x $PKG" "10 nodot" "10 a/b.c" "'' $PKG"; do
    T=$(fixture); echo "package:$PKG" > "$T/pm.list"
    run "$sh" "$T" "vpn_refusal_codes $a"
    [ "$(cat "$T/out")" = 'inst=- hid=- en=- stop=- svc=- tsdk=- usr=-' ] && ok "W3 bad input ($a): every code -" || no "W3 bad input ($a) printed '$(cat "$T/out")'"
    case "$(cat "$T/calls")" in *pm*|*dumpsys*|*am*) no "W3 bad input ($a) ran a read: $(cat "$T/calls")" ;; *) ok "W3 bad input ($a) ran nothing" ;; esac
    rm -rf "$T"
  done

  echo "== [$sh] W4 true and ERR answers keep main's line, with no record =="
  for got in "setAlwaysOnVpnPackage(user=10, pkg=$PKG, lockdown=false) -> true" 'ERR SecurityException' \
             "setAlwaysOnVpnPackage(user=10, pkg=$PKG, lockdown=false) -> false.x"; do
    T=$(fixture); printf '%s\n' "$got" > "$T/helper.out"; echo "package:$PKG" > "$T/pm.list"
    run "$sh" "$T" "$APPLY"
    want="${LINE0}$got ; read back app=null lockdown=null pending=null -> no"
    [ "$(cat "$T/log")" = "$want" ] && ok "W4 '$got': main's line, no refused:" || no "W4 '$got': the log line reads '$(cat "$T/log")'"
    [ ! -e "$T/state/.vpnwhy.10" ] && ok "W4 '$got': no record" || no "W4 '$got': a record was written"
    case "$(cat "$T/calls")" in *'get-started-user-state'*|*'query-services'*) no "W4 '$got': a refusal read ran" ;; *) ok "W4 '$got': no refusal read ran" ;; esac
    rm -rf "$T"
  done

  echo "== [$sh] W6 the vpnstate reply's fifth field =="
  vs(){   # vs <label> <record content, or - for none> <want field> [uid]
    local T2 r
    T2=$(fixture); echo "$PKG" > "$T2/set.always_on_vpn_app"; echo 0 > "$T2/set.always_on_vpn_lockdown"
    dumpfix "$T2" 'hidden=false stopped=false enabled=0' 34
    [ "$2" = - ] || printf '%s\n' "$2" > "$T2/state/.vpnwhy.${4:-10}"
    run "$sh" "$T2" "uid=${4:-10}
$OP"
    r=$(cat "$T2/res" 2>/dev/null)
    case "$r" in "VPNSTATE "*" refused=$3") ok "W6 $1: refused=$3" ;; *) no "W6 $1: the reply reads '$r', want refused=$3" ;; esac
    case "$(cat "$T2/log")" in *"-> $r "*) ok "W6 $1: the log line carries the reply" ;; *) no "W6 $1: the log reads '$(cat "$T2/log")'" ;; esac
    case "$r$(cat "$T2/log")" in *vpnfixture*) no "W5 (W6 $1): the reply or the log holds the package" ;; *) ok "W5 (W6 $1): no package in the reply or the log" ;; esac
    rm -rf "$T2"
  }
  vs "a valid record" "n=2 $W1CODES lock=0" 'n2.inst1.hid0.en1.stop1.svc1.tsdk1.usrunlocked.lock0'
  vs "a record with dashes" 'n=999 inst=- hid=- en=- stop=- svc=- tsdk=- usr=- lock=1' 'n999.inst-.hid-.en-.stop-.svc-.tsdk-.usr-.lock1'
  vs "no record" - none
  vs "a record holding a package" "n=2 $W1CODES lock=0 $PKG" -
  vs "a package in a field" "n=2 inst=$PKG hid=0 en=1 stop=1 svc=1 tsdk=1 usr=unlocked lock=0" -
  vs "n=0" "n=0 $W1CODES lock=0" -
  vs "n=1000" "n=1000 $W1CODES lock=0" -
  vs "n=01" "n=01 $W1CODES lock=0" -
  vs "an extra field" "n=2 $W1CODES lock=0 x=1" -
  vs "a second line" "n=2 $W1CODES lock=0
n=3 $W1CODES lock=0" -
  vs "a blank line, then a package" "n=2 $W1CODES lock=0

$PKG" -
  vs "a trailing blank line" "n=2 $W1CODES lock=0
" -
  vs "a leading blank" " n=2 $W1CODES lock=0" -
  vs "two blanks between fields" "n=2  $W1CODES lock=0" -
  vs "usr=bogus" 'n=2 inst=1 hid=0 en=1 stop=1 svc=1 tsdk=1 usr=bogus lock=0' -
  vs "a uid that is not a number" "n=2 $W1CODES lock=0" - 1x
}
for s in $SHELLS; do behaviour "$s"; done

# --- source pins (shell-independent) --------------------------------------------------------------------
if [ "$PINS" = yes ]; then
  SH=static
  echo "== [static] W7 the per-uid clean-ups remove .vpnwhy =="
  l=$(grep -F 'rm -f "$STATE/.vpnapplied.$uid" "$STATE/.syncapplied.$uid"' "$SUT")
  case "$l" in *'"$STATE/.vpnwhy.$uid"'*) ok "W7 the in op's rm list names .vpnwhy.\$uid" ;; *) no "W7 the in op's rm list does not name .vpnwhy.\$uid" ;; esac
  l=$(grep -F 'rm -f "$STATE/.declined.$uid"' "$SUT")
  case "$l" in *'"$STATE/.vpnwhy.$uid"'*) ok "W7 the reap's rm list names .vpnwhy.\$uid" ;; *) no "W7 the reap's rm list does not name .vpnwhy.\$uid" ;; esac
fi

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted by its named case under each shell) =="
  M=$(mktemp -d -p "$W")
  # mutate <case> <name> <sed>: the mutant must change the file, parse, and draw a `FAIL  [<sh>] <case>` line and rc 1
  # from a run restricted to each shell on its own.
  mutate(){
    local id="$1" name="$2" sh rc out
    if ! sed "$3" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $name"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $name"; return; fi
    bash -n "$M/m.sh" 2>/dev/null || { no "MUTATION BROKEN (does not parse): $name"; return; }
    for sh in $SHELLS; do
      out=$(bash "$0" --no-pins --shell "$sh" "$M/m.sh" 2>&1); rc=$?
      case "$out" in
        *"FAIL  [$sh] $id"*) [ "$rc" = 1 ] && ok "convicted by $id under $sh: $name" || no "NOT CONVICTED under $sh (rc $rc): $name" ;;
        *) no "NOT CONVICTED by $id under $sh (rc $rc): $name" ;;
      esac
    done
  }
  SH=mutate
  mutate W4 "M1 the suffix written on a true answer" "s/case \"\\\$_t\" in \\*'-> false')/case \"\$_t\" in *'-> '*)/"
  mutate W2 "M2 inst read with -a" 's/timeout -k 2 20 pm list packages --user "\$_u"/timeout -k 2 20 pm list packages -a --user "$_u"/'
  mutate W2 "M3 inst by substring" 's/\$0 == "package:" P { f = 1 }/index($0, "package:" P) { f = 1 }/'
  mutate W2 "M4 svc by substring" 's@if (index(s, P "/") == 1) f = 1@if (index(s, P "/")) f = 1@'
  mutate W1 "M5 n not incremented" 's/_vwn=\$((_vwn + 1))/_vwn=$((_vwn))/'
  mutate W6 "M6 the reply copies the record raw" 's/^\(          _vsr=\)\$(vpn_refusal_token "\$STATE\/.vpnwhy.\$uid") || _vsr=-$/\1$(cat "$STATE\/.vpnwhy.$uid")/'
  mutate W5 "M7 the record carries the package" "s/printf 'n=%s %s lock=%s\\\\n' \"\\\$_vwn\" \"\\\$_why\" \"\\\$_lock\"/printf 'n=%s %s lock=%s %s\\\\n' \"\$_vwn\" \"\$_why\" \"\$_lock\" \"\$_pkg\"/"
  mutate W3 "M8 usr's unknown becomes a word" 's/\*) _us=- ;; esac/*) _us=unknown ;; esac/'
  mutate W1 "M9 usr read from lastState=" '/^vpn_refusal_codes() {$/,/^}$/s/, state=/lastState=/g'
  mutate W1 "M10 the false test without stripping trailing blanks" "s/case \"\\\$_t\" in \\*'-> false')/case \"\$_out\" in *'-> false')/"
  mutate W6 "M11 the record's whole-file check dropped (a blank line, then a package)" '/^vpn_refusal_token() {$/,/^}$/{/^\." \] || return 1$/s/return 1/:/}'
  mutate W1 "M12 the count taken from the first line, unchecked" 's/^\(    _vwn=\)\$(vpn_refusal_token "\$_vwf") || _vwn=""\(.*\)$/\1$(sed -n "1s\/^n=\\([0-9]*\\) .*\/n\\1\/p" "$_vwf")\2/'
  # C1, the control: a word of vpn_refusal_codes's header comment. It must change the file and SURVIVE everywhere.
  sed 's/^# returns 0 (NWP-20261208-10). vpn_apply_choice calls it only/# returns 0 (NWP-20261208-10). vpn_apply_choice runs it only/' "$SUT" > "$M/c.sh"
  if cmp -s "$SUT" "$M/c.sh"; then no "C1 control INERT: the comment line was not found"
  else
    for sh in $SHELLS; do
      out=$(bash "$0" --no-pins --shell "$sh" "$M/c.sh" 2>&1); rc=$?
      [ "$rc" = 0 ] && ok "C1 control survives under $sh (a comment's wording)" || no "C1 control CONVICTED under $sh (rc $rc): the suite reads comments"
    done
  fi
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
