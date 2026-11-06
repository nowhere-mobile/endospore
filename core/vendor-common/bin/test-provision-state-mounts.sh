#!/usr/bin/env bash
# test-provision-state-mounts.sh [<nowhere_provision.sh>] [--mutate] -- the state tmpfs mount count that
# nowhere_provision.sh logs once per run (NWP-20261128-28).
#
# WHY THIS IS COMMITTED. nowhere.rc's `on property:sys.boot_completed=1` action mounts the tmpfs on
# /data/nowhere/state and then starts nowhere_provision.sh, with no once-per-boot guard. AOSP init queues a property
# trigger on every set of the property, the same value included, and ActivityManagerService sets
# sys.boot_completed=1 at every system_server start (read from source, not measured). So a framework restart may
# stack a second, empty tmpfs over the live state dir and hide the departed session's files under it until
# power-off. provision.log rides every gate-filed report (report_issue.go `bases`), so the one line this block
# writes is the evidence that decides the premise on a handset. Every way the block breaks is silent: a dropped
# fstype test or a prefix match counts a fuse mount or /data/nowhere/state2, an unreadable table logged as 0 reads
# as "not a tmpfs", a block below the marker exit logs nothing after the first boot, and the table passed as one
# printf argument is E2BIG on the device (mksh has no printf builtin; one argument over 128 KiB fails) and logs 0.
#
# HOW. The block is extracted BY ANCHOR (# STATE-MOUNTS-BEGIN / # STATE-MOUNTS-END), never copied; if the anchors
# move or vanish, extraction fails loudly (exit 2). /proc/mounts is rewritten to a fixture per case, date is a stub,
# and the printf() stub of test-stop-mediad-verify.sh gives every shell the device's 128 KiB argument limit. The
# block runs under EACH shell found of bash, sh, dash, mksh, and the I check requires the recorded shell identity
# to match the shell launched. A whole-script case (W1) runs nowhere_provision.sh with `/data/` re-rooted, every
# cmd stubbed and the marker present: one start line, and the script still exits at the marker.
#
#   bash test-provision-state-mounts.sh            # the cases, under every shell found
#   bash test-provision-state-mounts.sh --mutate   # ... plus six mutations; each must FAIL under EVERY shell found
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SELF="$0"
SUT="${SUT:-$(dirname "$0")/nowhere_provision.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"
SH_ID=$(env -u KSH_VERSION -u BASH_VERSION sh -c '_i="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; echo "${_i:-posix}"')

# id_matches <shell> <recorded identity>
id_matches() {
  case "$1" in
    bash) case "$2" in bash:?*) return 0 ;; esac ;;
    mksh) case "$2" in ksh:?*) return 0 ;; esac ;;
    dash) [ "$2" = posix ] && return 0 ;;
    sh) [ "$2" = "$SH_ID" ] && return 0 ;;
  esac
  return 1
}

extract_block() { sed -n '/^# STATE-MOUNTS-BEGIN/,/^# STATE-MOUNTS-END/p' "$1"; }

# first_line <ERE> <file> -> the line number of the first match, empty if none
first_line() { local n; n=$(grep -nE -m1 -e "$1" "$2" | cut -d: -f1); echo "${n:-}"; }

# The printf() stub of test-stop-mediad-verify.sh: one argument over 128 KiB fails, as /system/bin/printf does on
# the device (mksh has no printf builtin, so every printf there is an exec).
PRINTF_STUB='printf(){
  local __pa
  for __pa in "$@"; do
    if [ "${#__pa}" -gt 131072 ]; then echo "printf: Argument list too long" >&2; return 126; fi
  done
  command printf "$@"
}'

START_ERE='^\[provision\] start: state tmpfs mounts=([0-9]+|unreadable) \(one per boot; .*\)$'

# extract <nowhere_provision.sh> -> BLK = the extracted block file (under $W); returns 2 when it cannot be extracted
# or when any shell found refuses to parse it
extract() {
  local f="$1" b e bl el s
  b=$(grep -c '^# STATE-MOUNTS-BEGIN' "$f"); e=$(grep -c '^# STATE-MOUNTS-END' "$f")
  if [ "$b" != 1 ] || [ "$e" != 1 ]; then
    echo "EXTRACTION FAILED: want exactly one # STATE-MOUNTS-BEGIN and one # STATE-MOUNTS-END in $f (got $b / $e)"
    return 2
  fi
  bl=$(first_line '^# STATE-MOUNTS-BEGIN' "$f"); el=$(first_line '^# STATE-MOUNTS-END' "$f")
  if [ "$bl" -ge "$el" ]; then echo "EXTRACTION FAILED: # STATE-MOUNTS-END (line $el) is not after BEGIN (line $bl) in $f"; return 2; fi
  BLK=$(mktemp -p "$W"); extract_block "$f" > "$BLK"
  if [ ! -s "$BLK" ]; then echo "EXTRACTION FAILED: the block between the anchors is empty in $f"; return 2; fi
  for s in $SHELLS; do
    "$s" -n "$BLK" 2>/dev/null || { echo "EXTRACTION FAILED: $s -n refuses the block between the anchors in $f"; return 2; }
  done
}

# run_block <shell> <blockfile> <dir> -- run the block under that shell, /proc/mounts read from <dir>/mounts
run_block() {
  local sh="$1" blk="$2" d="$3"
  {
    printf 'D=%s; LOG="$D/provision.log"\n' "$d"
    cat <<'RUN'
_nw_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; echo "${_nw_id:-posix}" >> "$D/shell"
date() { echo DATESTUB; }
RUN
    printf '%s\n' "$PRINTF_STUB"
    sed "s#/proc/mounts#$d/mounts#g" "$blk"
  } > "$d/run.sh"
  env -u KSH_VERSION -u BASH_VERSION "$sh" "$d/run.sh" >/dev/null 2>&1
}

# run_whole <shell> <nowhere_provision.sh> <dir> -- the whole script, /data/ re-rooted to <dir>/, the marker present
run_whole() {
  local sh="$1" sut="$2" d="$3"
  mkdir -p "$d/nowhere"
  echo done > "$d/nowhere/.provisioned"
  echo "tmpfs $d/nowhere/state tmpfs rw,seclabel,nosuid,nodev,noexec,relatime,size=262144k,mode=700 0 0" > "$d/mounts"
  sed -e "s#/proc/mounts#$d/mounts#g" -e "s#/data/#$d/#g" "$sut" > "$d/script.sh"
  {
    printf 'D=%s\n' "$d"
    cat <<'PRE'
_nw_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; echo "${_nw_id:-posix}" >> "$D/shell"
getprop() {
  case "${1:-}" in
    ro.build.type) echo user ;;
    ro.debuggable) echo 0 ;;
    *) echo "getprop $*" >> "$D/unexpected"; echo "" ;;
  esac
}
date() { echo DATESTUB; }
pm() { echo "pm $*" >> "$D/calls"; }
dpm() { echo "dpm $*" >> "$D/calls"; }
am() { echo "am $*" >> "$D/calls"; }
settings() { echo "settings $*" >> "$D/calls"; }
cmd() { echo "cmd $*" >> "$D/calls"; }
locksettings() { echo "locksettings $*" >> "$D/calls"; }
device_config() { echo "device_config $*" >> "$D/calls"; }
setprop() { echo "setprop $*" >> "$D/calls"; }
restorecon() { echo "restorecon $*" >> "$D/calls"; }
sleep() { echo "sleep $*" >> "$D/calls"; }
PRE
    printf '%s\n' "$PRINTF_STUB"
    printf '. "$D/script.sh"\n'
  } > "$d/prelude.sh"
  env -u KSH_VERSION -u BASH_VERSION "$sh" "$d/prelude.sh" </dev/null >/dev/null 2>&1
  WRC=$?
}

# Realistic mount table lines that never count.
base_lines() {
  echo "/dev/block/dm-6 / ext4 ro,seclabel,relatime 0 0"
  echo "tmpfs /dev tmpfs rw,seclabel,nosuid,relatime,size=3804436k,nr_inodes=951109,mode=755 0 0"
  echo "proc /proc proc rw,relatime,gid=3009,hidepid=invisible 0 0"
  echo "/dev/block/dm-48 /data f2fs rw,lazytime,seclabel,nosuid,nodev,noatime,background_gc=on,discard,fsync_mode=nobarrier,inlinecrypt 0 0"
  echo "tmpfs /mnt tmpfs rw,seclabel,nosuid,nodev,noexec,relatime,size=3804436k,mode=755,gid=1000 0 0"
  echo "/dev/fuse /storage/emulated fuse rw,lazytime,nosuid,nodev,noexec,noatime,user_id=0,group_id=0,allow_other 0 0"
}
STATE_LINE="tmpfs /data/nowhere/state tmpfs rw,seclabel,nosuid,nodev,noexec,relatime,size=262144k,mode=700 0 0"

# fixture <case> <dir> -> writes <dir>/mounts (or not, for S5); echoes the expected mounts= value
fixture() {
  local c="$1" d="$2" i
  case "$c" in
    S1) { base_lines; echo "$STATE_LINE"; } > "$d/mounts"; echo 1 ;;
    S2) { base_lines; echo "$STATE_LINE"; echo "$STATE_LINE"; } > "$d/mounts"; echo 2 ;;
    S3) base_lines > "$d/mounts"; echo 0 ;;
    S4) { base_lines
          echo "/dev/fuse /data/nowhere/state fuse rw,lazytime,nosuid,nodev,noexec,noatime,user_id=0,group_id=0 0 0"
          echo "tmpfs /data/nowhere/state2 tmpfs rw,seclabel,nosuid,nodev,noexec,relatime,size=262144k,mode=700 0 0"
        } > "$d/mounts"; echo 0 ;;
    S5) echo unreadable ;;
    S6) printf '' > "$d/mounts"; echo unreadable ;;
    S7) { base_lines
          i=0
          while [ "$i" -lt 1300 ]; do
            echo "/dev/block/loop$i /apex/com.android.example.module@$i ext4 ro,dirsync,seclabel,nodev,noatime 0 0"
            i=$((i + 1))
          done
          echo "$STATE_LINE"
          while [ "$i" -lt 2600 ]; do
            echo "/dev/block/loop$i /apex/com.android.example.module@$i ext4 ro,dirsync,seclabel,nodev,noatime 0 0"
            i=$((i + 1))
          done
          echo "$STATE_LINE"
        } > "$d/mounts"; echo 2 ;;
  esac
}

lines() { if [ -f "$1" ]; then grep -c '' "$1"; else echo 0; fi; }

# suite <shell> <nowhere_provision.sh> <blockfile|""> -> 0 all ok, 1 a case failed, 2 harness error
suite() {
  local sh="$1" f="$2" blk="$3" d c want got n line bl ml rec cnt p=0 x=0 idbad="" first="" herr="" sz
  ok() { p=$((p+1)); printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no() { x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }
  idchk() {  # idchk <case> -- the child must have recorded exactly one line, the launched shell's identity
    rec=$(cat "$d/shell" 2>/dev/null); cnt=$(lines "$d/shell")
    if [ "$cnt" != 1 ]; then herr="$herr $1=${cnt}lines"; return; fi
    [ -n "$first" ] || first="$rec"
    id_matches "$sh" "$rec" || idbad="$idbad $1=${rec:-none}"
  }

  # --- P1: the block sits above the marker exit (the marker exists on every boot after the first) ---
  bl=$(first_line '^# STATE-MOUNTS-BEGIN' "$f"); ml=$(first_line '^\[ -f "\$MARK" \] && exit 0$' "$f")
  if [ -n "$bl" ] && [ -n "$ml" ] && [ "$bl" -lt "$ml" ]; then ok "P1 the BEGIN anchor is above the first marker exit"
  else no "P1 BEGIN line '${bl}', marker exit line '${ml}'"; fi

  # --- S1-S8: the block alone, per fixture ---
  if [ -z "$blk" ]; then
    no "S1-S8 the block could not be extracted"
  else
    for c in S1 S2 S3 S4 S5 S6 S7; do
      d=$(mktemp -d -p "$W"); want=$(fixture "$c" "$d")
      if [ "$c" = S7 ]; then
        sz=$(wc -c < "$d/mounts" | tr -d ' ')
        if [ "$sz" -le 204800 ]; then no "S7 fixture is only $sz bytes (want over 200 KiB)"; fi
      fi
      run_block "$sh" "$blk" "$d"
      n=0; [ -f "$d/provision.log" ] && n=$(grep -c '^\[provision\] start:' "$d/provision.log")
      line=""; [ -f "$d/provision.log" ] && line=$(grep -m1 '^\[provision\] start:' "$d/provision.log")
      got=${line#*mounts=}; got=${got%% *}
      if [ "$n" = 1 ] && [ "$got" = "$want" ]; then ok "$c mounts=$want"
      else no "$c want one start line with mounts=$want, got $n line(s), mounts='${got}'"; fi
      line=${line% DATESTUB}
      if [ "$n" = 1 ] && [ "$(lines "$d/provision.log")" = 1 ] && [[ $line =~ $START_ERE ]]; then
        ok "S8($c) exactly one log line, of the fixed shape, ending in \$(date)"
      else no "S8($c) log lines=$(lines "$d/provision.log"), start='${line}'"; fi
      idchk "$c"; command rm -rf "$d"
    done
  fi

  # --- W1: the whole script with the marker present ---
  d=$(mktemp -d -p "$W"); run_whole "$sh" "$f" "$d"
  n=0; [ -f "$d/nowhere/provision.log" ] && n=$(grep -c '^\[provision\] start: state tmpfs mounts=1 ' "$d/nowhere/provision.log")
  if [ "$WRC" = 0 ] && [ "$n" = 1 ] && [ "$(lines "$d/nowhere/provision.log")" = 1 ]; then
    ok "W1 whole script, marker present -> exactly one line, the start line with mounts=1, exit 0"
  else no "W1 rc=$WRC start(mounts=1)=$n log lines=$(lines "$d/nowhere/provision.log")"; fi
  if [ ! -s "$d/calls" ] && [ ! -e "$d/unexpected" ]; then ok "W1 the script exits at the marker: no cmd ran, no unexpected getprop"
  else no "W1 calls='$(cat "$d/calls" 2>/dev/null)' unexpected='$(cat "$d/unexpected" 2>/dev/null)'"; fi
  idchk W1; command rm -rf "$d"

  if [ -z "$idbad" ]; then ok "I every executed case recorded the $sh identity ($first)"
  else no "I a case recorded another shell than $sh:$idbad"; fi

  printf '  -- [%s] %d ok, %d failed\n' "$sh" "$p" "$x"
  if [ -n "$herr" ]; then printf '  HARNESS ERROR [%s] no single identity record (child did not run):%s\n' "$sh" "$herr"; return 2; fi
  [ "$x" -eq 0 ] && return 0 || return 1
}

all_shells() {  # all_shells <script> -> 0 all shells pass, 1 a case failed, 2 the block could not be extracted
  local sh r rc=0 blk=""
  BLK=""
  if extract "$1"; then blk="$BLK"; else rc=2; fi
  for sh in $SHELLS; do
    suite "$sh" "$1" "$blk"; r=$?
    if [ "$r" = 2 ]; then rc=2; elif [ "$r" != 0 ] && [ "$rc" = 0 ]; then rc=1; fi
  done
  return $rc
}

echo "state tmpfs mount count: $SUT"
all_shells "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=$rc

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must FAIL under every shell found:$SHELLS):"
  MT=$(mktemp -d -p "$W")
  # judge <label> <outfile> <rc> <required shells...>: convicted only on rc 1 and a FAIL line under EACH shell
  judge() {
    local label="$1" out="$2" rc="$3" s bad=""; shift 3
    for s in "$@"; do grep -q -e "FAIL  \[$s\]" "$out" || bad="$bad $s"; done
    if [ "$rc" = 1 ] && [ -z "$bad" ]; then printf '  CONVICTED %-62s under:%s\n' "$label" " $*"
    elif [ "$rc" != 0 ] && [ "$rc" != 1 ]; then printf '  ERR       %-62s harness error (rc=%s), not a conviction\n' "$label" "$rc"; MFAIL=1
    else printf '  SURVIVED  %-62s rc %s, no FAIL line under:%s\n' "$label" "$rc" "$bad"; MFAIL=1; fi
  }
  # try <label> <mutant file>: a mutant that did not change the script is a failure
  try() {
    local label="$1" mf="$2" r
    if [ ! -s "$mf" ]; then printf '  NOAPPLY   %-62s the mutant command produced no script\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  NOAPPLY   %-62s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    bash "$SELF" "$mf" > "$MT/out" 2>&1; r=$?
    judge "$label" "$MT/out" "$r" $SHELLS
  }
  R='/^# STATE-MOUNTS-BEGIN/,/^# STATE-MOUNTS-END/ '   # the sed mutants are confined to the block
  sed "${R}s#/data/nowhere/state tmpfs '#/data/nowhere/state '#" "$SUT" > "$MT/m1.sh"
  try 'M1 the fstype test is dropped (S4)' "$MT/m1.sh"
  sed "${R}s#/data/nowhere/state tmpfs '#/data/nowhere/state[^ ]* tmpfs '#" "$SUT" > "$MT/m2.sh"
  try 'M2 the path match is a prefix (S4)' "$MT/m2.sh"
  sed "${R}s#^_sm_n=unreadable\$#_sm_n=0#" "$SUT" > "$MT/m3.sh"
  try 'M3 an unreadable table counts 0 (S5, S6)' "$MT/m3.sh"
  awk '
    /^# STATE-MOUNTS-BEGIN/ { inb = 1 }
    inb { blk = blk $0 "\n"; if ($0 ~ /^# STATE-MOUNTS-END/) inb = 0; next }
    { print }
    !moved && $0 == "[ -f \"$MARK\" ] && exit 0" { printf "%s", blk; moved = 1 }
  ' "$SUT" > "$MT/m4.sh"
  try 'M4 the block is moved below the marker exit (P1, W1)' "$MT/m4.sh"
  awk '
    /^# STATE-MOUNTS-BEGIN/ { inb = 1 }
    /^# STATE-MOUNTS-END/ { inb = 0 }
    inb && /^  _sm_n=\$\(grep -c / { print "  _sm_n=$(printf '\''%s\\n'\'' \"$_sm_t\" | grep -c '\''^[^ ]* /data/nowhere/state tmpfs '\'')"; skip = 1; next }
    skip { if ($0 == ")") skip = 0; next }
    { print }
  ' "$SUT" > "$MT/m5.sh"
  try 'M5 the table is a printf argument, not a here-document (S7)' "$MT/m5.sh"
  sed "${R}"'{/^echo "\[provision\] start:/d;}' "$SUT" > "$MT/m6.sh"
  try 'M6 the log line is removed' "$MT/m6.sh"
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS CONVICTED" || { echo "PROBLEM: a mutation survived or did not apply"; [ "${FAILED:-0}" = 2 ] || FAILED=1; }
fi

[ "${FAILED:-0}" = 0 ] && echo "PASS: state tmpfs mount count under$SHELLS"
exit "${FAILED:-0}"
