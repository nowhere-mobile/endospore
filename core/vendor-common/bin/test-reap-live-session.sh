#!/usr/bin/env bash
# test-reap-live-session.sh [<nowhere_roamd.sh>] [--mutate] [--baseline <old roamd>] -- a reap leaves another live
# session's Bluetooth and media daemon alone (NWP-20261129-06).
#
# WHY THIS IS COMMITTED. roamd's cleanstorage op runs two DEVICE-WIDE clears for the uid it reaps: stop_mediad detaches
# every media mount on the phone, and bt_reset cycles the adapter and empties /data/misc/bluedroid. That was safe while
# every caller ran with no session in front. ChooserActivity.reapSupersededColdLock does not: it reaps a parked cold-locked
# user while the NEW session is live. Without this gate that session loses its pairings and its media overlays, and its
# next bt_seal_capture removes its bt-bond-* artifacts, so every later sign-in of that profile starts with none.
# Nothing fails and nothing logs an error, so only the executed cases below can see it.
#
# stop_mediad, bt_reset, reap_live_other and reap_media_mounted are extracted from nowhere_roamd.sh BY NAME, never copied.
# $STATE and /data point into the suite's root, and /proc/mounts points at a case file. setprop, getprop, sleep, cmd,
# settings and find are stubs that record their argv in $T/argv; find still runs, so the wipe is real.
#
#   bash test-reap-live-session.sh                          # the cases, under each shell found
#   bash test-reap-live-session.sh --mutate                 # ... plus mutations that must each CONVICT the suite
#   bash test-reap-live-session.sh --baseline <old roamd>   # the cases must FAIL against a roamd without this change
#
# EVERY SHELL. Each of bash, sh, dash and mksh found runs each case by its own name, every case tagged `[<sh>]`. sh is run
# even as a link to bash, because bash named sh is in POSIX mode. A mutant is convicted only when EVERY shell found has
# its own `FAIL  [<sh>]` line. CI's runner has all four; a shell that is absent is named once with `skip`.
#
# ⚠ NO `cmd | grep -q` ANYWHERE IN THIS FILE: match against a file or a here-string (SIGPIPE under pipefail).
set -uo pipefail

MUTATE=no; SUT=""; BASELINE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --baseline) shift; BASELINE="${1:-}"; [ -f "$BASELINE" ] || { echo "no such baseline: $BASELINE" >&2; exit 2; } ;;
    *) SUT="$1" ;;
  esac
  shift
done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for cand in bash sh dash mksh; do
  if command -v "$cand" >/dev/null 2>&1; then SHELLS="$SHELLS $cand"; else echo "skip $cand (not found; CI's runner has it)"; fi
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }
# The same shim as test-stop-mediad-verify.sh: bash and dash have no `print`; mksh (the device's sh) does.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# Planted on marker lines 1-2 (L9). Neither is a real profile or passphrase.
PNAME='probe-profile-q7'
PPASS='probe-passphrase-q7'

# bt_state prints ON until the disable is recorded, then OFF: _bt_wait_off polls it, and a stub that stays ON times out.
STUBS=$(cat <<'EOS'
rec(){ printf '%s\n' "$*" >> "$T/argv"; }
setprop(){ rec setprop "$@"; }
getprop(){ rec getprop "$@"; case "${1:-}" in ro.product.model) printf 'Test Model 9\n' ;; *) printf 'stopped\n' ;; esac; }
sleep(){ rec sleep "$@"; }
cmd(){ rec cmd "$@"; }
settings(){ rec settings "$@"; }
find(){ rec find "$@"; command find "$@"; }
bt_state(){ rec bt_state; if grep -qF 'cmd bluetooth_manager disable' "$T/argv"; then echo OFF; else echo ON; fi; }
chown(){ :; }
restorecon(){ :; }
EOS
)

FN_REQUIRED="stop_mediad bt_reset reap_live_other reap_media_mounted bt_default_name _bt_state_ok _bt_wait_off qn"
# extract <script> <names> -> the variables and functions, re-rooted, or failure. A function cut short has no closing `}`.
extract() {
  local f="$1" names="$2" out n prog="/^BT_FILES=/p; /^BT_NAME_KEYS=/p;" one
  for n in $names; do
    one=$(sed -n "/^$n() {\$/,/^}\$/p" "$f")
    case "$one" in "$n() {"*) ;; *) return 1 ;; esac
    [ "$(tail -n 1 <<<"$one")" = "}" ] || return 1
    prog="$prog /^$n() {\$/,/^}\$/p;"
  done
  out=$(sed -n "$prog" "$f")
  case "$out" in *BT_FILES=*BT_NAME_KEYS=*|*BT_NAME_KEYS=*BT_FILES=*) ;; *) return 1 ;; esac
  # Unquoted in the replacement text: these sit inside double quotes or as a bare word, and $T holds no space.
  sed -e 's#/proc/mounts#$T/mounts#g' -e 's#/data/#$T/data/#g' <<<"$out"
}

# suite <script> <shell> [quiet] [names] -> 0 iff every case behaved. FAIL lines print in quiet mode too: they are a
# mutant's evidence, per shell.
suite() {
  local f="$1" sh="$2" quiet="${3:-}" names="${4:-$FN_REQUIRED}" p=0 x=0 BLOCK CLEAN OPBLOCK T rc s pf
  local c shape mnt stub want h ln
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }

  BLOCK=$(extract "$f" "$names") || { [ -n "$quiet" ] || echo "EXTRACTION FAILED -- a function moved or was cut in $f" >&2; return 2; }
  CLEAN=$(sed -n '/^if \[ "\$op" = "cleanstorage" \]; then$/,/^fi$/p' "$f")
  [ -n "$CLEAN" ] || { [ -n "$quiet" ] || echo "EXTRACTION FAILED -- the cleanstorage op moved in $f" >&2; return 2; }

  # runner <file> <shell text> -- a fresh shell as roamd runs it (no -u, no pipefail). The text's status lands in $T/rc.
  runner() {
    { printf "T='%s'\n" "$T"
      printf '%s\n' 'STATE="$T/state"; LOG="$T/log"; BT_DIR="$T/bluedroid"; BT_APP_DIRS="$T/de/bt $T/ce/bt"; BT_RESTORED=9'
      [ "$sh" = mksh ] || printf '%s\n' "$PRINT_SHIM"
      printf '%s\n' "$BLOCK"
      printf '%s\n' "$STUBS"
      printf '%s\n' "$2" 'echo $? > "$T/rc"' 'echo "${BT_RESTORED-unset}" > "$T/restored"'
    } > "$1"
  }
  pf=$(mktemp -p "$W") || return 2
  T="$W"; runner "$pf" ':'
  "$sh" -n "$pf" 2>/dev/null || { rm -f "$pf"; no "THE BLOCK DOES NOT PARSE under $sh in $f"; return 2; }
  rm -f "$pf"

  # fresh <marker shape> <mount point under /data/, or -> -- one root per case: a marker, a mounts file, a planted bond file.
  #   shape: none | empty | <line 3> | two-lines. Lines 1-2 always hold the planted name and passphrase.
  fresh() {
    T=$(mktemp -d -p "$W")
    mkdir -p "$T/state" "$T/bluedroid" "$T/data/user/11" "$T/prof/com.nowhere.chooser/files"
    : > "$T/argv"
    printf '[Adapter]\nLinkKey = planted\n' > "$T/bluedroid/bt_config.conf"
    case "$1" in
      none) ;;
      empty) : > "$T/state/.roamsession" ;;
      two-lines) printf '%s\n%s\n' "$PNAME" "$PPASS" > "$T/state/.roamsession" ;;
      *) printf '%s\n%s\n%s\n\n' "$PNAME" "$PPASS" "$1" > "$T/state/.roamsession" ;;
    esac
    { printf '/dev/block/dm-0 /data f2fs rw 0 0\n'
      printf 'tmpfs /data/nowhere/state tmpfs rw 0 0\n'
      # A live session's overlay, which must never read as the reaped user's own.
      printf 'nowhere_media %s/data/user/12/x/files fuse.nowheremedia rw 0 0\n' "$T"
      [ "$2" = - ] || printf 'nowhere_media %s/data/%s fuse.nowheremedia rw 0 0\n' "$T" "$2"
    } > "$T/mounts"
  }
  run() {
    runner "$T/run.sh" "$1"
    "$sh" "$T/run.sh" >>"$T/stdout" 2>&1
    rc=$(cat "$T/rc" 2>/dev/null)
  }
  recorded() { grep -qF -- "$1" "$T/argv" 2>/dev/null; }
  logged() { grep -qF -- "$1" "$T/log" 2>/dev/null; }
  bond_kept() { [ -s "$T/bluedroid/bt_config.conf" ]; }
  bt_empty() { [ -d "$T/bluedroid" ] && [ -z "$(ls -A "$T/bluedroid")" ]; }
  done_fx() { rm -rf "$T"; }

  # expect_left <label> <user> -- the reap of 11 leaves mediad and Bluetooth to the live session named <user>.
  expect_left() {
    local l="$1" u="$2"
    if recorded 'setprop ctl.stop'; then no "$l: stop_mediad reap 11 stopped the live session's mediad"; else ok "$l: stop_mediad reap 11 records no setprop ctl.stop"; fi
    if logged "reap of user 11: a live session (user $u) holds the media daemon"; then ok "$l: the mediad line names users 11 and $u"; else no "$l: no mediad line naming users 11 and $u"; fi
  }
  expect_bt_left() {
    local l="$1" u="$2"
    [ "$rc" = 2 ] && ok "$l: bt_reset reap returns 2" || no "$l: bt_reset reap returned '$rc' (want 2)"
    if recorded 'cmd bluetooth_manager disable'; then no "$l: the radio was disabled under the live session"; else ok "$l: no cmd bluetooth_manager disable"; fi
    if recorded 'bt_state'; then no "$l: bt_state was read before the arm returned"; else ok "$l: the arm returns before bt_state is read"; fi
    bond_kept && ok "$l: the bond file is kept" || no "$l: the live session's bond file is gone"
    if logged "a live session (user $u) holds the device" && logged "at the reap of user 11"; then ok "$l: the bt line names users 11 and $u"; else no "$l: no bt line naming users 11 and $u"; fi
    [ "$(cat "$T/restored" 2>/dev/null)" = 0 ] && ok "$l: BT_RESTORED is 0" || no "$l: BT_RESTORED is '$(cat "$T/restored" 2>/dev/null)' (want 0)"
  }
  # expect_as_today <label> <stop text> <reset text> -- the clears run.
  expect_as_today() {
    local l="$1"
    fresh "$2" -; run "$3"
    if recorded 'setprop ctl.stop nowhere_mediad'; then ok "$l: mediad stopped"; else no "$l: setprop ctl.stop nowhere_mediad not recorded"; fi
    done_fx
    fresh "$2" -; run "$4"
    [ "$rc" = 0 ] && ok "$l: bt_reset returns 0" || no "$l: bt_reset returned '$rc' (want 0)"
    if recorded 'cmd bluetooth_manager disable'; then ok "$l: the radio is cycled"; else no "$l: the radio was not cycled"; fi
    bt_empty && ok "$l: BT_DIR emptied" || no "$l: BT_DIR not emptied: $(ls -A "$T/bluedroid" 2>&1 | tr '\n' ' ')"
    done_fx
  }
  stop_reap='stop_mediad reap 11'; reset_reap='bt_reset "" reap 11'

  # ---- L1: another session is live, no mount in the reaped user's dirs ----------------------------------------------
  fresh 12 -; run "$stop_reap"; expect_left L1 12
  [ "$rc" = 0 ] && ok "L1: stop_mediad reap returns 0" || no "L1: stop_mediad reap returned '$rc'"
  done_fx
  fresh 12 -; run "$reset_reap"; expect_bt_left L1 12; done_fx

  # ---- L2, L3: no marker, a zero-byte marker, or the reaped session's own marker: as today ----------------------------
  expect_as_today L2 none "$stop_reap" "$reset_reap"
  expect_as_today L2b empty "$stop_reap" "$reset_reap"
  expect_as_today L3 11 "$stop_reap" "$reset_reap"

  # ---- L4: a marker whose line 3 is not a uid is a live session --------------------------------------------------------
  for shape in x1 012 two-lines; do
    fresh "$shape" -; run "$stop_reap"; expect_left "L4 ($shape)" '?'; done_fx
    fresh "$shape" -; run "$reset_reap"; expect_bt_left "L4 ($shape)" '?'; done_fx
  done

  # ---- L5: a mount in the reaped user's dirs still stops mediad; Bluetooth stays the live session's ---------------------
  for mnt in user/11/x/files user_de/11/x media/11/y user/11 user_de/11 media/11; do
    fresh 12 "$mnt"; run "$stop_reap"
    if recorded 'setprop ctl.stop nowhere_mediad'; then ok "L5 ($mnt): mediad stopped"; else no "L5 ($mnt): a mount in the removed user's dirs left mediad running"; fi
    done_fx
  done
  fresh 12 user/11/x/files; run "$reset_reap"
  expect_bt_left L5 12; done_fx

  # ---- L5b: user 110's mounts are not user 11's ----------------------------------------------------------------------
  for mnt in user/110/x user_de/110/x media/110/y user/110 user_de/110 media/110; do
    fresh 12 "$mnt"; run "$stop_reap"
    expect_left "L5b ($mnt)" 12; done_fx
  done
  # ---- L5c: only field 2 is a mount point; the device field of a line is not ------------------------------------------
  fresh 12 -; printf '%s/data/user/11/x /mnt/elsewhere ext4 rw 0 0\n' "$T" >> "$T/mounts"; run "$stop_reap"
  expect_left L5c 12; done_fx

  # ---- L6: an empty or unreadable table is never "no mount" ------------------------------------------------------------
  fresh 12 -; : > "$T/mounts"; run "$stop_reap"
  if recorded 'setprop ctl.stop nowhere_mediad'; then ok "L6: an empty table stops mediad"; else no "L6: an empty table read as no mount"; fi
  done_fx
  fresh 12 -; rm -f "$T/mounts"; run "$stop_reap"
  if recorded 'setprop ctl.stop nowhere_mediad'; then ok "L6: an unreadable table stops mediad"; else no "L6: an unreadable table read as no mount"; fi
  done_fx

  # ---- L7: every other caller ignores the marker -----------------------------------------------------------------------
  expect_as_today L7 12 'stop_mediad' 'bt_reset ""'
  fresh 12 -; printf 'mine\n' > "$T/prof/com.nowhere.chooser/files/bt-bond-bt_config"; run 'bt_reset "$T/prof" resume'
  [ "$rc" = 0 ] && [ "$(cat "$T/restored")" = 1 ] && [ "$(cat "$T/bluedroid/bt_config.conf" 2>/dev/null)" = mine ] \
    && ok "L7: a resume ignores the marker and lays its own pairings" || no "L7: a resume with a marker: rc '$rc', restored '$(cat "$T/restored" 2>/dev/null)'"
  done_fx

  # ---- L8: the op -------------------------------------------------------------------------------------------------------
  c=$(grep -c '^  stop_mediad reap "\$uid"   # #84 P3d: ' <<<"$CLEAN")
  [ "$c" = 1 ] && ok "L8: the op has one stop_mediad reap \"\$uid\"" || no "L8: stop_mediad reap \"\$uid\" appears $c time(s) in the op"
  c=$(grep -c '^  bt_reset "" reap "\$uid"; ' <<<"$CLEAN")
  [ "$c" = 1 ] && ok "L8: the op has one bt_reset \"\" reap \"\$uid\"" || no "L8: bt_reset \"\" reap \"\$uid\" appears $c time(s) in the op"
  c=$(grep -cE '^  (stop_mediad   #|if bt_reset ""; then)' <<<"$CLEAN")
  [ "$c" = 0 ] && ok "L8: neither old line stays in the op" || no "L8: $c old line(s) stay in the op"
  s=$(grep -n '^if \[ "\$op" = "cleanstorage" \]; then$' "$f" | cut -d: -f1)
  c=0; for h in reap_live_other reap_media_mounted; do
    ln=$(grep -n "^$h() {\$" "$f" | head -1 | cut -d: -f1)
    [ -n "$ln" ] && [ "$ln" -lt "${s:-0}" ] && c=$((c+1))
  done
  [ "$c" = 2 ] && ok "L8: both helpers are defined above the op" || no "L8: $c of 2 helpers are defined above the op"
  # The op's block, run with bt_reset stubbed for each status, stops at the settle that follows it.
  OPBLOCK=$(sed -n '/^  bt_reset "" reap "\$uid"; /,/^  # NWP-20261003-01: users\/<uid> is removed HERE/p' <<<"$CLEAN" | sed '$d')
  if [ -z "$OPBLOCK" ]; then
    no "L8: the op's Bluetooth block was not found, so its statuses were not run"
  else
    for c in 0 1 2; do
      T=$(mktemp -d -p "$W"); : > "$T/argv"
      stub="bt_reset() { printf '%s|%s|%s\n' \"\$1\" \"\$2\" \"\$3\" > \"\$T/btargs\"; return $c; }"
      { printf "T='%s'\nLOG=\"\$T/log\"; uid=11\n" "$T"; printf '%s\n%s\n' "$stub" "$OPBLOCK"; } > "$T/run.sh"
      "$sh" "$T/run.sh" >"$T/stdout" 2>&1
      [ "$(cat "$T/btargs" 2>/dev/null)" = '|reap|11' ] || no "L8: status $c: the block called bt_reset with '$(cat "$T/btargs" 2>/dev/null)'"
      s="$(logged 'bt: device cleared at reap (user 11)' && echo C)$(logged 'bt ERR: device NOT cleared at reap (user 11)' && echo N)"
      case "$c" in 0) want=C ;; 1) want=N ;; 2) want="" ;; esac
      [ "$s" = "$want" ] && ok "L8: status $c writes '${want:-neither line}'" || no "L8: status $c wrote '$s' (want '$want'; C cleared, N NOT cleared)"
      done_fx
    done
  fi

  # ---- L9: the marker's name and passphrase reach no log and no argv ---------------------------------------------------
  for shape in 12 11 x1; do
    fresh "$shape" -; run "$stop_reap"; run "$reset_reap"
    if grep -qF -e "$PNAME" -e "$PPASS" "$T/log" "$T/argv" "$T/stdout" 2>/dev/null; then no "L9 ($shape): a marker secret reached a log or an argv"
    else ok "L9 ($shape): neither marker secret reached a log, an argv or stdout"; fi
    done_fx
  done
  # A numeric passphrase passes the uid shape, so reading line 2 would print it.
  T=$(mktemp -d -p "$W"); mkdir -p "$T/state"; printf '%s\n778899\n12\n\n' "$PNAME" > "$T/state/.roamsession"; : > "$T/argv"
  run 'reap_live_other 11'
  [ "$rc" = 0 ] && [ "$(cat "$T/stdout")" = 12 ] && ok "L9: only line 3 is printed with a numeric passphrase" \
    || no "L9: reap_live_other printed '$(cat "$T/stdout")' (rc '$rc'; want 12, 0)"
  done_fx
  s=$(sed -n '/^reap_live_other() {$/,/^}$/p' "$f")
  c=$(grep -c 'roamsession' <<<"$s")
  if [ "$c" = 2 ] && grep -qF 'sed -n 3p "$STATE/.roamsession"' <<<"$s"; then ok "L9: reap_live_other opens the marker only through sed -n 3p"
  else no "L9: reap_live_other names the marker $c time(s), or not through sed -n 3p"; fi

  [ -n "$quiet" ] || printf '  -- [%s] %d ok, %d failed\n' "$sh" "$p" "$x"
  [ "$x" -eq 0 ]
}

if [ -n "$BASELINE" ]; then
  echo "reap leaves a live session alone, BASELINE (old code, the cases must fail): $BASELINE"
  # The new helpers do not exist there, and the old stop_mediad and bt_reset ignore the reap arguments.
  bad=0
  for sh in $SHELLS; do
    out=$(suite "$BASELINE" "$sh" quiet "stop_mediad bt_reset bt_default_name _bt_state_ok _bt_wait_off qn"); rc=$?
    printf '%s\n' "$out" | grep -E '\bL1: ' | head -3
    if [ "$rc" = 1 ] && grep -qF 'L1: stop_mediad reap 11 stopped the live session' <<<"$out" && grep -qF 'L1: bt_reset reap returned' <<<"$out"; then
      echo "  baseline fails as it must [$sh]"
    else echo "  BASELINE DID NOT FAIL [$sh] (rc=$rc)"; bad=1; fi
  done
  exit "$bad"
fi

echo "reap leaves a live session alone: $SUT"
FAILED=0
for sh in $SHELLS; do
  suite "$SUT" "$sh"; rc=$?
  [ "$rc" = 2 ] && exit 2
  [ "$rc" = 0 ] || { FAILED=1; echo "  suite rc=$rc under $sh"; }
done
[ "$FAILED" = 0 ] || exit 1
[ "$MUTATE" = yes ] || { echo "== all cases passed"; exit 0; }

echo
echo "== mutations (each must be convicted under each shell)"
mut() {
  local label="$1" prog="$2" m rc sh bad=0
  m=$(mktemp -p "$W")
  if ! perl -0pe "$prog" "$SUT" > "$m"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -f "$m"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $label -- the mutant is empty"; rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $label -- the mutation changed nothing"; rm -f "$m"; return 1; fi
  for sh in $SHELLS; do
    suite "$m" "$sh" quiet >"$m.out" 2>&1; rc=$?
    case "$rc" in
      1) if grep -qF "FAIL  [$sh]" "$m.out"; then echo "  convicted $label [$sh]"; else echo "  SURVIVED  $label [$sh] -- no FAIL line of its own"; bad=1; fi ;;
      0) echo "  SURVIVED  $label [$sh]"; bad=1 ;;
      *) echo "  BROKEN    $label [$sh] -- the mutant no longer extracts or parses (rc=$rc)"; bad=1 ;;
    esac
  done
  rm -f "$m" "$m.out"
  return $bad
}
fails=0
mut 'M1 bt_reset reap arm removed' 's/  if \[ "\$\{2:-\}" = reap \] && _brl=\$\(reap_live_other "\$3"\); then\n.*?\n  fi\n//s' || fails=$((fails+1))
mut 'M2 stop_mediad reap arm removed' 's/  if \[ "\$\{1:-\}" = reap \] && _rlo=\$\(reap_live_other "\$2"\) && ! reap_media_mounted "\$2"; then\n.*?\n  fi\n//s' || fails=$((fails+1))
mut 'M3 reap_live_other comparison inverted' 's/\[ "\$_rlou" = "\$1" \] && return 1/[ "\$_rlou" != "\$1" ] \&\& return 1/' || fails=$((fails+1))
mut 'M4 reap_media_mounted always 1' 's/(reap_media_mounted\(\) \{\n)/$1  return 1\n/' || fails=$((fails+1))
mut 'M5 an unreadable table read as no mount' 's/(\{ \[ "\$_rmrc" -eq 0 \] && \[ -n "\$_rmt" \]; \}) \|\| return 0/$1 || return 1/' || fails=$((fails+1))
mut 'M5b an empty table read as no mount' 's/\{ \[ "\$_rmrc" -eq 0 \] && \[ -n "\$_rmt" \]; \} \|\| return 0/[ "\$_rmrc" -eq 0 ] || return 0/' || fails=$((fails+1))
mut 'M6 line 2 read instead of 3' 's/_rlou=\$\(sed -n 3p /_rlou=\$(sed -n 2p /' || fails=$((fails+1))
mut 'M7a the op stop_mediad loses reap' 's/^  stop_mediad reap "\$uid"   # #84/  stop_mediad   # #84/m' || fails=$((fails+1))
mut 'M7b the op bt_reset loses reap' 's/^  bt_reset "" reap "\$uid"; _rbrc/  bt_reset ""; _rbrc/m' || fails=$((fails+1))
mut 'M8 status 2 logged as cleared' 's/if \[ "\$_rbrc" = 0 \]; then echo/if [ "\$_rbrc" != 1 ]; then echo/' || fails=$((fails+1))
mut 'M9 the / after the uid dropped from the mount match' 's#"/data/user/\$1"/\*\|"/data/user_de/\$1"\|"/data/user_de/\$1"/\*\|"/data/media/\$1"\|"/data/media/\$1"/\*#"/data/user/\$1"*|"/data/user_de/\$1"|"/data/user_de/\$1"*|"/data/media/\$1"|"/data/media/\$1"*#' || fails=$((fails+1))
mut 'M10 status 1 no longer logs NOT cleared' 's/elif \[ "\$_rbrc" != 2 \]; then echo/elif false; then echo/' || fails=$((fails+1))
mut 'M11 bt_reset arm moved after the state read' 's/(  local _brl\n)(  if \[ "\$\{2:-\}" = reap \].*?\n  fi\n)/$1  _s=\$(bt_state)\n$2/s' || fails=$((fails+1))
mut 'M12 a helper line prints the marker secrets' 's/(  _rlou=\$\(sed -n 3p [^\n]*\n)/$1  echo "marker: \$(sed -n 1,2p "\$STATE\/.roamsession")" >> "\$LOG"\n/' || fails=$((fails+1))
mut 'M13 the field-1 mount device compared too' 's/    case "\$_rmp" in\n      "\/data\/user/    case "\$_rmd" in "\/data\/"*) return 0 ;; esac\n    case "\$_rmp" in\n      "\/data\/user/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
