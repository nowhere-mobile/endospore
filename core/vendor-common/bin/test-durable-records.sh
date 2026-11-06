#!/usr/bin/env bash
# test-durable-records.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's power-loss records survive the power loss they
# exist for (NWP-20261124-24).
#
# WHY THIS IS COMMITTED. md_base_put, dr_base_put and dt_base_put wrote mobiledata.base, dataroaming.base and
# devtoggles.base by temp file + rename, and synced nothing. Each record is written once (the recapture trap), so the
# ext4 rename heuristic never applies, and f2fs persists a rename only at its next checkpoint. A forced restart in
# that window left no record: md_boot answered `none` and the gate kept the SESSION's value (mobile data off,
# airplane mode on). ks_signin_reset rewrote /data/nowhere/keystore-map in place (`cat tmp > map`), so a rewrite cut
# by a power loss or ENOSPC dropped a parked session's ns->pkg rows, and its reap sealed none of its Keystore dumps.
# Each helper now syncs the file, renames it and syncs its directory; ks_signin_reset writes keystore-map.signin
# beside the map and renames it over the map.
#
# The four functions are extracted BY NAME from roamd (never copied) and run under every shell found (bash as
# `bash --posix`, sh, dash, mksh; de-duplicated by the file they resolve to). `sync` and `mv` are shell functions
# that log their operands to a call log; `mv` then runs the real mv.
#   C1-C3  each base helper, from no record: rc 0, the record holds the value, sync <base>.new BEFORE the mv and
#          sync <dir> AFTER it, no .new left.
#   C4     a failing sync: each helper still returns 0, the record is written, the "sync failed" line is logged.
#   C5     a failing mv: each helper returns 1 and leaves no .new.
#   C6     ks_signin_reset 10: only uid 11's rows remain, the map's inode changed (a rename), no temp left.
#   C7     a failing mv: the map is byte-identical, no temp left, the FAILED line and `0 map row(s)` are logged.
#   C8     a leftover keystore-map.signin and an EMPTY map (the block is skipped): the leftover is removed.
#   Mutants M1-M8 (--mutate) must each be CONVICTED under every shell, one run per shell.
#
#   bash test-durable-records.sh              # the cases
#   bash test-durable-records.sh --mutate     # ... plus mutants of roamd that must each CONVICT under every shell
#
# Pure logic -- no device. Exit 0 all pass, 1 a check failed, 2 the harness could not extract (never a pass).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every case root and mutant copy is made inside it

# Every shell found, de-duplicated by the file it resolves to (sh is often bash or dash).
SHELLS=""
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

FNS="md_base_put dr_base_put dt_base_put ks_signin_reset"
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }

SYNCFAIL_TAIL='baseline record written but its sync failed -- it may not survive a power loss (NWP-20261124-24)'
MVFAIL_LINE='[roamd] IN keystore-map rewrite FAILED -- the map is unchanged (NWP-20261124-24)'
PLANTED_MAP='1000001 com.ex.a
1000002 com.ex.b
1100003 com.ex.c'
DT_VAL='airplane=0
wifi=1'

suite() {  # suite <roamd.sh> [quiet] [shells] -> 0 all ok, 1 a check failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" shells="${3:-$SHELLS}" p=0 x=0 fn sh tag R D B n cn a b c v rc out inode0 inode1 FX
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {  # chk <label> <got> <want>
    if [ "$2" = "$3" ]; then p=$((p + 1)); say "  ok    $1"
    else x=$((x + 1)); say "  FAIL  $1 (got '$2', want '$3')"; fi
  }
  FX=$(mktemp -p "$W") || return 2
  for fn in $FNS; do
    out=$(fn_of "$f" "$fn")
    [ -n "$out" ] || { echo "EXTRACTION FAILED: $fn() not found in $f" >&2; rm -f "$FX"; return 2; }
    printf '%s\n' "$out" >> "$FX"
  done

  # run <shell> <root> <body>: the body runs in <shell> with the extracted functions, every path inside <root>.
  run() {
    local sh="$1" R="$2"
    cat > "$R/run.sh" <<EOF
R='$R'
MD_BASE="\$R/data/nowhere/mobiledata.base"; DR_BASE="\$R/data/nowhere/dataroaming.base"
DT_BASE="\$R/data/nowhere/devtoggles.base"; KS_MAP="\$R/data/nowhere/keystore-map"
KS_IN="\$R/data/nowhere/keystore-in"; KS_IMPORT="\$R/data/nowhere/nowhere-import"
KS_EXPORT="\$R/data/nowhere/keystore-export"; STATE="\$R/state"; LOG="\$R/roam.log"; CALLS="\$R/calls"
sync() { echo "sync \$*" >> "\$CALLS"; [ -z "\${SYNC_FAIL:-}" ] || return 1; :; }
mv() { echo "mv \$*" >> "\$CALLS"; [ -z "\${MV_FAIL:-}" ] || return 1; command mv "\$@"; }
userdir_has_record() { return 1; }
. '$FX'
$3
EOF
    case "${sh##*/}" in bash) "$sh" --posix "$R/run.sh" ;; *) "$sh" "$R/run.sh" ;; esac >/dev/null 2>&1
  }
  newroot() {
    R=$(mktemp -d -p "$W") || return 2
    mkdir -p "$R/data/nowhere/keystore-in" "$R/data/nowhere/nowhere-import" "$R/data/nowhere/keystore-export" "$R/state"
    : > "$R/calls"; : > "$R/roam.log"
  }
  # lno <file> <line>: the line number of the exact line, or "none" (several -> the numbers, which never compare).
  lno() { local o; o=$(grep -nxF -- "$2" "$1" 2>/dev/null | cut -d: -f1 | tr '\n' ' '); echo "${o% }" | sed 's/^$/none/'; }

  for sh in $shells; do
    tag="[${sh##*/}]"
    # C1-C3
    for a in C1:md:1 C2:dr:3:1 C3:dt:-; do
      cn=${a%%:*}; b=${a#*:}; n=${b%%:*}; v=${b#*:}
      [ "$n" = dt ] && v="$DT_VAL"
      newroot || return 2
      D="$R/data/nowhere"
      case "$n" in md) B="$D/mobiledata.base" ;; dr) B="$D/dataroaming.base" ;; dt) B="$D/devtoggles.base" ;; esac
      printf '%s' "$v" > "$R/val"
      run "$sh" "$R" "${n}_base_put \"\$(cat '$R/val')\"; echo \$? > '$R/rc'"
      chk "$cn ${n} $tag returns 0 from no record" "$(cat "$R/rc" 2>/dev/null)" 0
      if cmp -s "$R/val" "$B"; then c=same; else c=differs; fi
      chk "$cn ${n} $tag the record holds exactly the value" "$c" same
      chk "$cn ${n} $tag the stubs ran (the call log is not empty)" "$([ -s "$R/calls" ] && echo yes || echo no)" yes
      a=$(lno "$R/calls" "sync $B.new"); b=$(lno "$R/calls" "mv -f $B.new $B"); c=$(lno "$R/calls" "sync $D")
      case "$a$b$c" in *[!0-9]*|'') rc=no ;; *) if [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]; then rc=yes; else rc=no; fi ;; esac
      chk "$cn ${n} $tag sync <base>.new, then mv, then sync <dir> (lines $a, $b, $c)" "$rc" yes
      chk "$cn ${n} $tag no .new is left" "$([ -e "$B.new" ] && echo left || echo none)" none
      # C4: a failing sync
      newroot || return 2
      D="$R/data/nowhere"
      case "$n" in md) B="$D/mobiledata.base" ;; dr) B="$D/dataroaming.base" ;; dt) B="$D/devtoggles.base" ;; esac
      printf '%s' "$v" > "$R/val"
      run "$sh" "$R" "SYNC_FAIL=1; ${n}_base_put \"\$(cat '$R/val')\"; echo \$? > '$R/rc'"
      chk "C4 ${n} $tag a failed sync still returns 0" "$(cat "$R/rc" 2>/dev/null)" 0
      if cmp -s "$R/val" "$B"; then c=same; else c=differs; fi
      chk "C4 ${n} $tag a failed sync still writes the record" "$c" same
      chk "C4 ${n} $tag the sync-failed line is logged once" "$(grep -cF "[roamd] $n $SYNCFAIL_TAIL" "$R/roam.log")" 1
      # C5: a failing mv
      newroot || return 2
      D="$R/data/nowhere"
      case "$n" in md) B="$D/mobiledata.base" ;; dr) B="$D/dataroaming.base" ;; dt) B="$D/devtoggles.base" ;; esac
      printf '%s' "$v" > "$R/val"
      run "$sh" "$R" "MV_FAIL=1; ${n}_base_put \"\$(cat '$R/val')\"; echo \$? > '$R/rc'"
      chk "C5 ${n} $tag a failed mv returns 1" "$(cat "$R/rc" 2>/dev/null)" 1
      chk "C5 ${n} $tag a failed mv leaves no .new" "$([ -e "$B.new" ] && echo left || echo none)" none
    done

    # C6: the map is renamed, not rewritten in place
    newroot || return 2
    D="$R/data/nowhere"
    printf '%s\n' "$PLANTED_MAP" > "$D/keystore-map"
    inode0=$(ls -i "$D/keystore-map" | awk '{print $1}')
    run "$sh" "$R" "ks_signin_reset 10; echo \$? > '$R/rc'"
    chk "C6 $tag ks_signin_reset returns 0" "$(cat "$R/rc" 2>/dev/null)" 0
    chk "C6 $tag only uid 11's rows remain" "$(cat "$D/keystore-map")" "1100003 com.ex.c"
    inode1=$(ls -i "$D/keystore-map" 2>/dev/null | awk '{print $1}')
    chk "C6 $tag the map's inode changed (a rename, not an in-place rewrite)" "$([ -n "$inode1" ] && [ "$inode0" != "$inode1" ] && echo changed || echo same)" changed
    chk "C6 $tag no keystore-map.signin is left" "$([ -e "$D/keystore-map.signin" ] && echo left || echo none)" none
    chk "C6 $tag the log counts 2 map rows" "$(grep -cF ', 2 map row(s) of an earlier user 10' "$R/roam.log")" 1

    # C7: a failed rename leaves the map as it was
    newroot || return 2
    D="$R/data/nowhere"
    printf '%s\n' "$PLANTED_MAP" > "$D/keystore-map"
    cp "$D/keystore-map" "$R/map.before"
    run "$sh" "$R" "MV_FAIL=1; ks_signin_reset 10; echo \$? > '$R/rc'"
    chk "C7 $tag ks_signin_reset returns 0" "$(cat "$R/rc" 2>/dev/null)" 0
    if cmp -s "$R/map.before" "$D/keystore-map"; then c=same; else c=differs; fi
    chk "C7 $tag a failed mv leaves the map byte for byte" "$c" same
    chk "C7 $tag a failed mv leaves no keystore-map.signin" "$([ -e "$D/keystore-map.signin" ] && echo left || echo none)" none
    chk "C7 $tag the FAILED line is logged once" "$(grep -cxF "$MVFAIL_LINE" "$R/roam.log")" 1
    chk "C7 $tag the log counts 0 map rows" "$(grep -cF ', 0 map row(s) of an earlier user 10' "$R/roam.log")" 1

    # C8: a leftover temp goes even when the block is skipped (an empty map)
    newroot || return 2
    D="$R/data/nowhere"
    : > "$D/keystore-map"
    printf '%s\n' "1000001 com.ex.a" > "$D/keystore-map.signin"
    run "$sh" "$R" "ks_signin_reset 10; echo \$? > '$R/rc'"
    chk "C8 $tag ks_signin_reset returns 0" "$(cat "$R/rc" 2>/dev/null)" 0
    chk "C8 $tag a leftover keystore-map.signin is removed" "$([ -e "$D/keystore-map.signin" ] && echo left || echo none)" none
    chk "C8 $tag the empty map stays empty" "$([ -f "$D/keystore-map" ] && [ ! -s "$D/keystore-map" ] && echo empty || echo other)" empty
  done
  rm -f "$FX"
  say "  -- $p passed, $x failed (shells:$shells)"
  [ "$x" = 0 ] || return 1
  return 0
}

echo "== test-durable-records.sh (NWP-20261124-24) against $SUT"
suite "$SUT"; RC=$?
[ "$RC" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$RC"

# The anchors: each must be exactly one line of roamd, or the mutants mean nothing.
L_MDS1='  sync "$MD_BASE.new" 2>/dev/null || _mbs=1'
L_DRS1='  sync "$DR_BASE.new" 2>/dev/null || _dbs=1'
L_DTS1='  sync "$DT_BASE.new" 2>/dev/null || _tbs=1'
L_MDS2='  sync "${MD_BASE%/*}" 2>/dev/null || _mbs=1'
L_MDLOG='  [ "$_mbs" = 0 ] || echo "[roamd] md baseline record written but its sync failed -- it may not survive a power loss (NWP-20261124-24) $(date)" >> "$LOG"'
L_WB='    if [ "$_ksr" = 0 ] || [ "$_ksr" = 1 ]; then mv -f "$_kst" "$KS_MAP" 2>>"$LOG" || { _ksd=0; echo "[roamd] IN keystore-map rewrite FAILED -- the map is unchanged (NWP-20261124-24)" >> "$LOG"; }; else _ksd=0; fi'
L_RMT='  rm -f "$KS_MAP.signin" 2>/dev/null'
for l in "$L_MDS1" "$L_DRS1" "$L_DTS1" "$L_MDS2" "$L_MDLOG" "$L_WB" "$L_RMT"; do
  n=$(grep -cxF -- "$l" "$SUT")
  [ "$n" = 1 ] || { echo "anchor is not one line of roamd ($n): $l" >&2; exit 2; }
done
export L_MDS1 L_DRS1 L_DTS1 L_MDS2 L_MDLOG L_WB L_RMT

echo "== mutants (each must be CONVICTED)"
MFAIL=0
# mut <name> <awk-program>: awk reads the anchors from the environment
mut() {
  local name="$1" prog="$2" t r s
  t=$(mktemp -p "$W")
  awk "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; rm -f "$t"; return; fi
  for s in $SHELLS; do
    suite "$t" quiet "$s"; r=$?
    if [ "$r" = 1 ]; then echo "  ok    CONVICTED [${s##*/}]: $name"
    else echo "  FAIL  NOT CONVICTED [${s##*/}] (rc=$r): $name"; MFAIL=1; fi
  done
  rm -f "$t"
}
mut "M1 md_base_put drops the sync before the rename" '$0 == ENVIRON["L_MDS1"] {next} {print}'
mut "M2 dr_base_put drops the sync before the rename" '$0 == ENVIRON["L_DRS1"] {next} {print}'
mut "M3 dt_base_put drops the sync before the rename" '$0 == ENVIRON["L_DTS1"] {next} {print}'
mut "M4 md_base_put drops the directory sync" '$0 == ENVIRON["L_MDS2"] {next} {print}'
mut "M5 md_base_put returns 1 on a sync failure" '$0 == ENVIRON["L_MDLOG"] {print "  [ \"$_mbs\" = 0 ] || return 1"; next} {print}'
mut "M6 the in-place map rewrite is restored" '$0 == ENVIRON["L_WB"] {print "    if [ \"$_ksr\" = 0 ] || [ \"$_ksr\" = 1 ]; then cat \"$_kst\" > \"$KS_MAP\" 2>>\"$LOG\"; else _ksd=0; fi"; next} {print}'
mut "M7 a failed mv leaves the temp" '$0 == ENVIRON["L_RMT"] {print "  [ -n \"$_kst\" ] || rm -f \"$KS_MAP.signin\" 2>/dev/null"; next} {print}'
mut "M8 the unconditional temp removal is dropped" '$0 == ENVIRON["L_RMT"] {next} {print}'
[ "$RC" = 0 ] && [ "$MFAIL" = 0 ] || exit 1
exit 0
