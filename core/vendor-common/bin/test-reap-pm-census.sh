#!/usr/bin/env bash
# test-reap-pm-census.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's reap_pm_census, the end of the cleanstorage op
# (the second start-count read, the census, the two roam.log lines, the reap-ledger row) and the boot sweep's pmleft
# block (NWP-20261203-01).
#
# WHY. Backlog row "Sign-out can restart the phone's system server: when the Auto sweep installed an app that declares a
# shared user id, ...". On lynx 2026111001 five sign-outs restarted system_server, and the fifth died while PM removed a
# package with no shared user id, so the shared uid may not be the only trigger. Nothing durable recorded a restart
# under a reap, or what PM left installed for no user: roam.log is scrubbed to a tail. Now every reap logs a census
# (counts only, never a name) and whether the start count moved, the reap-ledger row carries fw= and pm: (and is also
# written on a restart or a package left), and the boot sweep logs pmleft=.
#
# WHAT. reap_pm_census and loc_why are EXTRACTED by their anchors (exit 2 when one moves) and run under every shell the
# runner has (bash, sh, dash, mksh; REAPPMC_SHELLS=<paths> restricts the list) against a stubbed dumpsys:
#   C1 a planted dump: an ownerless shared-uid app that declares a permission, an ownerless plain app, a /data/app app
#      installed for user 0, a /system app and a hidden /system package installed for no user -> ownerless=2 shared=1
#      declperm=1.  C2 an empty capture -> unread.  C3 a failing dumpsys (with a dump on stdout) -> unread.
#   C4 no planted name reaches stdout, stderr, $LOG or RPC_LINE.  C5 nothing ownerless -> ownerless=0 shared=0
#      declperm=0 (zero is reachable and is not unread).  C6 a dump cut inside a last /data/app block before its User
#      lines -> that block is not counted.  C7 the same dump with dumpsys's DUMP TIMEOUT line -> unread.
#   P4 the fw lines lifted from the cleanstorage op, run with a stubbed getprop: (5,5) same, (5,6) restart,
#      ('',5) unknown, (5,x) unknown.
# Pins (once): P1 the order in the cleanstorage op (husk guard read < _rp_ssc2 read < census < ledger if), P2 the
# ledger row's tail, P3 the ledger condition's two new terms, P5 the bootsweep pmleft block, P6 the two roam.log lines.
# --mutate applies each mutant to a copy of roamd and requires the NAMED assertion to FAIL under each shell.
#
#   bash test-reap-pm-census.sh            # the checks
#   bash test-reap-pm-census.sh --mutate   # ... plus mutants that must each be CONVICTED by their named assertion
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
if [ -n "${REAPPMC_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$REAPPMC_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || { echo "skip $s: not found"; continue; }
    r="$(readlink -f "$p"):$s"   # sh stays apart from bash: bash run as sh is its POSIX mode
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

# --- extraction ----------------------------------------------------------------------------------------------------
FN=$(awk '$0 == "reap_pm_census() {" {f=1} f{print} f&&/^\}$/{exit}' "$SUT")
case "$FN" in *'dumpsys package packages'*'RPC_LINE='*) ;; *) echo "EXTRACTION FAILED: reap_pm_census in $SUT" >&2; exit 2 ;; esac
LW=$(grep -m1 '^loc_why() {' "$SUT")
[ -n "$LW" ] || { echo "EXTRACTION FAILED: loc_why in $SUT" >&2; exit 2; }
CLEAN=$(sed -n '/^if \[ "\$op" = "cleanstorage" \]; then$/,/^fi$/p' "$SUT")
[ -n "$CLEAN" ] || { echo "EXTRACTION FAILED: the cleanstorage op in $SUT" >&2; exit 2; }
BOOT=$(sed -n '/^if \[ "\$op" = "bootsweep" \]; then$/,/^fi$/p' "$SUT")
[ -n "$BOOT" ] || { echo "EXTRACTION FAILED: the bootsweep op in $SUT" >&2; exit 2; }
FW_A='  _rp_ssc2=$(getprop sys.system_server.start_count 2>/dev/null); case "$_rp_ssc2" in '"''"'|*[!0-9]*) _rp_ssc2="" ;; esac'
FW_B='  else _rp_fw=same; fi'
na=$(printf '%s\n' "$CLEAN" | grep -nxF -e "$FW_A" | cut -d: -f1)
nb=$(printf '%s\n' "$CLEAN" | grep -nxF -e "$FW_B" | cut -d: -f1)
case "$na:$nb" in *[!0-9:]*|:*|*:) echo "EXTRACTION FAILED: the fw lines of the cleanstorage op (at '$na' and '$nb')" >&2; exit 2 ;; esac
[ "$na" -lt "$nb" ] || { echo "EXTRACTION FAILED: the fw lines are out of order" >&2; exit 2; }
FWB=$(printf '%s\n' "$CLEAN" | sed -n "${na},${nb}p")

# --- planted dumps (the `dumpsys package packages` shape: 2-space Package lines, 4-space fields) --------------------
cat > "$W/dump" <<'EOF'
Packages:
  Package [org.planted.sharedzz] (a1b2c3):
    appId=10234
    pkg=Package{d4 org.planted.sharedzz}
    codePath=/data/app/~~xQ==/org.planted.sharedzz-1Ab==
    sharedUser=SharedUserSetting{e5 org.planted.shareduid/10234}
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
    declared permissions:
      org.planted.sharedzz.permission.C2D: prot=signature, INSTALLED
    User 0: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false
    User 10: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false

  Package [org.planted.plainzz] (a2):
    appId=10235
    codePath=/data/app/~~yQ==/org.planted.plainzz-2Bc==
    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]
    User 0: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false

  Package [org.planted.ownedzz] (a3):
    appId=10236
    codePath=/data/app/~~zQ==/org.planted.ownedzz-3Cd==
    sharedUser=SharedUserSetting{f6 org.planted.owneduid/10236}
    declared permissions:
      org.planted.ownedzz.permission.X: prot=signature, INSTALLED
    User 0: ceDataInode=0 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false
    User 10: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false

  Package [org.planted.systemzz] (a4):
    appId=1000
    codePath=/system/app/PlantedSystem
    sharedUser=SharedUserSetting{a7 android.uid.system/1000}
    declared permissions:
      org.planted.systemzz.permission.Y: prot=signature, INSTALLED
    User 0: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false

Hidden system packages:
  Package [org.planted.hiddenzz] (a5):
    appId=10240
    codePath=/system/priv-app/PlantedHidden
    User 0: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false
EOF
# Nothing ownerless: an owned /data/app block and a /system block with no installed user.
cat > "$W/none" <<'EOF'
Packages:
  Package [org.planted.ownedzz] (a3):
    codePath=/data/app/~~zQ==/org.planted.ownedzz-3Cd==
    sharedUser=SharedUserSetting{f6 org.planted.owneduid/10236}
    declared permissions:
      org.planted.ownedzz.permission.X: prot=signature, INSTALLED
    User 0: ceDataInode=0 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false
  Package [org.planted.systemzz] (a4):
    codePath=/system/app/PlantedSystem
    User 0: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=0 instant=false virtual=false
EOF
# Cut: the planted Packages section without the hidden section, then a last /data/app block cut before its User lines.
sed '/^Hidden system packages:$/,$d' "$W/dump" > "$W/cut"
cat >> "$W/cut" <<'EOF'
  Package [org.planted.cutzz] (a6):
    appId=10241
    codePath=/data/app/~~wQ==/org.planted.cutzz-6Fg==
    sharedUser=SharedUserSetting{b8 org.planted.cutuid/10241}
    declared permissions:
      org.planted.cutzz.permission.Z: prot=signature, INSTALLED
EOF
{ cat "$W/cut"; echo "*** SERVICE 'package' DUMP TIMEOUT (10000ms) EXPIRED ***"; } > "$W/tmo"

# --- the census cases, per shell -----------------------------------------------------------------------------------
# census <shell> <mode> <dump file> -- one fresh root $T; RPC_LINE lands in $T/rpc. mode: ok | empty | fail.
census() {
  local sh="$1"
  T=$(mktemp -d -p "$W")
  printf '%s\n' "$2" > "$T/mode"; cp "$3" "$T/dump" 2>/dev/null || : > "$T/dump"
  { printf "T='%s'\n" "$T"
    printf '%s\n' 'LOG="$T/log"' 'RPC_LINE=never-set'
    printf '%s\n' 'timeout() { shift 3; "$@"; }'
    printf '%s\n' 'dumpsys() { case "$(cat "$T/mode")" in ok) cat "$T/dump" ;; empty) : ;; fail) cat "$T/dump"; echo "org.planted.failzz: dump failed" >&2; return 1 ;; esac; }'
    printf '%s\n' "$LW" "$FN"
    printf '%s\n' 'reap_pm_census reap' 'printf "%s\n" "$RPC_LINE" > "$T/rpc"'
  } > "$T/run.sh"
  "$sh" "$T/run.sh" > "$T/stdout" 2> "$T/stderr"
}
rpc() { cat "$T/rpc" 2>/dev/null; }
noname() {  # noname <label>: no planted name in stdout, stderr, $LOG or RPC_LINE
  local f all=""
  for f in stdout stderr log rpc; do all="$all$(cat "$T/$f" 2>/dev/null)"; done
  case "$all" in *planted*) return 1 ;; esac
  return 0
}

for s in "${SHELLS[@]}"; do
  sn=${s##*/}
  echo "== [$sn] reap_pm_census =="
  c4=0
  census "$s" ok "$W/dump"
  [ "$(rpc)" = "ownerless=2 shared=1 declperm=1" ] && ok "C1 [$sn] the planted dump counts ownerless=2 shared=1 declperm=1" \
    || no "C1 [$sn] the planted dump read '$(rpc)', want 'ownerless=2 shared=1 declperm=1'"
  noname || c4=1
  census "$s" empty "$W/dump"
  [ "$(rpc)" = unread ] && ok "C2 [$sn] an empty capture is unread" || no "C2 [$sn] an empty capture read '$(rpc)', want 'unread'"
  noname || c4=1
  census "$s" fail "$W/dump"
  [ "$(rpc)" = unread ] && ok "C3 [$sn] a failing dumpsys is unread" || no "C3 [$sn] a failing dumpsys read '$(rpc)', want 'unread'"
  noname || c4=1
  census "$s" ok "$W/none"
  [ "$(rpc)" = "ownerless=0 shared=0 declperm=0" ] && ok "C5 [$sn] nothing ownerless counts zero, not unread" \
    || no "C5 [$sn] nothing ownerless read '$(rpc)', want 'ownerless=0 shared=0 declperm=0'"
  noname || c4=1
  census "$s" ok "$W/cut"
  [ "$(rpc)" = "ownerless=2 shared=1 declperm=1" ] && ok "C6 [$sn] a block cut before its User lines is not counted" \
    || no "C6 [$sn] the cut dump read '$(rpc)', want 'ownerless=2 shared=1 declperm=1'"
  noname || c4=1
  census "$s" ok "$W/tmo"
  [ "$(rpc)" = unread ] && ok "C7 [$sn] a dump with dumpsys's DUMP TIMEOUT line is unread" \
    || no "C7 [$sn] the timed-out dump read '$(rpc)', want 'unread'"
  noname || c4=1
  [ "$c4" = 0 ] && ok "C4 [$sn] no planted name reaches stdout, stderr, \$LOG or RPC_LINE" \
    || no "C4 [$sn] a planted name reached stdout, stderr, \$LOG or RPC_LINE"

  echo "== [$sn] the fw lines of the cleanstorage op =="
  for cs in "P4a:5:5:same" "P4b:5:6:restart" "P4c::5:unknown" "P4d:5:x:unknown"; do
    IFS=: read -r id a0 gp want <<< "$cs"
    T=$(mktemp -d -p "$W")
    printf '%s\n' "$gp" > "$T/gp"
    { printf "T='%s'\n" "$T"
      printf '%s\n' 'getprop() { cat "$T/gp"; }' "_ud_ssc0='$a0'" "$FWB" 'printf "%s\n" "$_rp_fw" > "$T/fw"'
    } > "$T/run.sh"
    "$s" "$T/run.sh" > /dev/null 2>&1
    got=$(cat "$T/fw" 2>/dev/null)
    [ "$got" = "$want" ] && ok "$id [$sn] start counts ('$a0', '$gp') give fw=$want" \
      || no "$id [$sn] start counts ('$a0', '$gp') gave fw='$got', want '$want'"
  done
done

# --- pins (shell-independent) --------------------------------------------------------------------------------------
echo "== pins =="
lno() { local n; n=$(printf '%s\n' "$1" | grep -nF -e "$2" | cut -d: -f1); [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] && echo "$n"; }
h=$(lno "$CLEAN" '_ud_ssc1=$(getprop')
r=$(lno "$CLEAN" '  _rp_ssc2=$(getprop')
c=$(lno "$CLEAN" '  reap_pm_census reap')
l=$(lno "$CLEAN" '  if [ "$_reapclass" != clean ]')
if [ -n "$h" ] && [ -n "$r" ] && [ -n "$c" ] && [ -n "$l" ] && [ "$h" -lt "$r" ] && [ "$r" -lt "$c" ] && [ "$c" -lt "$l" ]; then
  ok "P1 the husk guard's read, then the _rp_ssc2 read, then the census, then the ledger if, each once"
else no "P1 the order in the cleanstorage op is husk '$h', _rp_ssc2 '$r', census '$c', ledger if '$l'"; fi
row=$(printf '%s\n' "$CLEAN" | grep -F 'reap-ledger 2>/dev/null' | grep -F 'uid=$uid class=' || true)
# NWP-20261203-22 appends $_kswf (` kwhy=<class>`, on a notsealed reap only) after pm:
case "$row" in *' census:$_udc fw=$_rp_fw pm:$_rp_pm$_kswf"'*) ok "P2 the reap-ledger row ends census:\$_udc fw=\$_rp_fw pm:\$_rp_pm\$_kswf" ;;
  *) no "P2 the reap-ledger row does not end census:\$_udc fw=\$_rp_fw pm:\$_rp_pm\$_kswf" ;; esac
cond=$(printf '%s\n' "$CLEAN" | grep -F '  if [ "$_reapclass" != clean ]' || true)
case "$cond" in *'|| [ "$_rp_fw" = restart ] ||'*'[ -n "$_rp_own" ] && [ "$_rp_own" -gt 0 ]'*'; then') ok "P3 the ledger row is also written on fw=restart and on ownerless above 0" ;;
  *) no "P3 the ledger condition lacks the restart term or the ownerless term" ;; esac
b1=$(lno "$BOOT" '  _swept="$_swept locglobals=$LOC_BOOT"')
b2=$(lno "$BOOT" '  # --- pmleft (NWP-20261203-01) ---')
b3=$(lno "$BOOT" '  reap_pm_census boot')
b4=$(lno "$BOOT" '  _swept="$_swept pmleft=$_rp_bl"')
b5=$(lno "$BOOT" '  echo "[roamd] bootsweep result:$_swept')
if [ -n "$b1" ] && [ -n "$b2" ] && [ -n "$b3" ] && [ -n "$b4" ] && [ -n "$b5" ] && [ "$b1" -lt "$b2" ] && [ "$b2" -lt "$b3" ] \
   && [ "$b3" -lt "$b4" ] && [ "$b4" -lt "$b5" ]; then
  ok "P5 bootsweep: its own pmleft block after locglobals= and before the result line"
else no "P5 bootsweep: locglobals '$b1', header '$b2', census '$b3', pmleft '$b4', result '$b5'"; fi
p6a=$(lno "$CLEAN" '  echo "[roamd] reap user $uid pm census: $RPC_LINE $(date)" >> "$LOG"')
p6b=$(lno "$CLEAN" '  [ "$_rp_fw" = same ] || echo "[roamd] reap user $uid framework: $_rp_fw (start count ${_ud_ssc0:-?} -> ${_rp_ssc2:-?}) $(date)" >> "$LOG"')
[ -n "$p6a" ] && [ -n "$p6b" ] && ok "P6 the op logs the pm census line and the framework line" \
  || no "P6 the pm census line ('$p6a') or the framework line ('$p6b') is missing"

# --- mutants -------------------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutants (each must be CONVICTED by its named assertion under each shell) =="
  NMUT=0
  # mutant <id> <assertion id> <old text> <new text> -- the old text must occur exactly once in roamd.
  mutant() {
    local id="$1" want="$2" old="$3" new="$4" src m s out rest
    NMUT=$((NMUT + 1))
    src=$(cat "$SUT"; printf x); src=${src%x}
    rest=${src//"$old"/}
    if [ $(( (${#src} - ${#rest}) / ${#old} )) != 1 ]; then no "MUTANT DID NOT APPLY: $id (its text is not in roamd exactly once)"; return; fi
    m=$(mktemp -p "$W")
    printf '%s' "${src/"$old"/"$new"}" > "$m"
    if cmp -s "$SUT" "$m"; then no "MUTANT INERT: $id"; rm -f "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      out=$(REAPPMC_SHELLS="$s" bash "$0" "$m" 2>&1)
      case "$out" in
        *"  FAIL  $want "*) ok "convicted $id by $want under ${s##*/}" ;;
        *) no "NOT CONVICTED: $id by $want under ${s##*/}" ;;
      esac
    done
    rm -f "$m"
  }
  mutant "M1 the /data/app test dropped" C1 '      *"codePath=/data/app/"*) _rpd=1 ;;' '      *"codePath="*) _rpd=1 ;;'
  mutant "M2 installed=false counts as ownership" C1 '*" installed=true"*) _rpo=1' '*" installed="*) _rpo=1'
  mutant "M3 an empty capture counts as 0" C2 '{ [ "$_rprc" -eq 0 ] && [ -n "$_rpt" ]; } || { RPC_LINE=unread' '{ [ "$_rprc" -eq 0 ]; } || { RPC_LINE=unread'
  mutant "M4 the sharedUser match dropped" C1 $'      *"sharedUser=SharedUserSetting{"*) _rps=1 ;;\n' ''
  mutant "M5 the declared-permissions match dropped" C1 $'      *"declared permissions:"*) _rpp=1 ;;\n' ''
  mutant "M6 the restart term removed from the ledger condition" P3 ' || [ "$_rp_fw" = restart ]' ''
  mutant "M7 the restart arm compares with =" P4b 'elif [ "$_ud_ssc0" != "$_rp_ssc2" ]; then _rp_fw=restart' 'elif [ "$_ud_ssc0" = "$_rp_ssc2" ]; then _rp_fw=restart'
  mutant "M8 the User-line requirement dropped" C6 ' && [ "$_rpd" = 1 ] && [ "$_rpu" = 1 ] && [ "$_rpo" = 0 ]; then' ' && [ "$_rpd" = 1 ] && [ "$_rpo" = 0 ]; then'
  mutant "M9 the DUMP TIMEOUT test dropped" C7 $'  case "$_rpt" in *"DUMP TIMEOUT"*) RPC_LINE=unread; return 0 ;; esac\n' ''
  echo "-- $NMUT mutants"
fi

echo
echo "shells: ${SHELLS[*]}; $PASS ok, $FAIL failed"
if [ "$FAIL" = 0 ]; then
  [ "$MUTATE" = yes ] && echo "== all $NMUT mutants convicted"
  echo "PASS: test-reap-pm-census.sh"; exit 0
fi
echo "FAILED: test-reap-pm-census.sh"; exit 1
