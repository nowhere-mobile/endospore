#!/usr/bin/env bash
# test-sweepmedia-verify.sh [<nowhere_roamd.sh>] [--mutate] -- the logoff's media sweep VERIFIES (NWP-20261010-10).
#
# WHY THIS IS COMMITTED. sweepmedia answered OK without looking, and the daemon ignored the answer: a media mount
# stop_mediad could not detach let the logoff seal walk an overlay's .under (a false shrink) and the reap try to
# delete through it. It now reads /proc/mounts back as coldsweep does, answers ERR-MEDIA-SWEEP <n> when anything is
# left, and writes the #154 .btlogoff marker ONLY on a verified sweep -- a logoff that stops here keeps its session,
# and the next periodic seal would otherwise wipe a live user's Bluetooth. Silent when it regresses, so it is pinned.
#
# NWP-20261024-15: and it must READ the table. A grep that cannot read /proc/mounts exits 2 with nothing on stdout, which
# counted as "no mount left": both arms answered OK over an unread table (and sweepmedia armed the Bluetooth wipe).
# Both now answer ERR-MEDIA-SWEEP UNREAD when the read fails or the table is empty.
#
# The sweepmedia and coldsweep arms are extracted BY ANCHOR and run against temp files: stop_mediad is stubbed and
# /proc/mounts is rewritten to a fixture file, a path that does not exist, or an empty file.
#
# NWP-20261111-23: and under every shell. The arms ran only under bash (an `eval` in a bash subshell, a `bash -n`
# here-string), while the device runs roamd under mksh, where `[ "$_left" -lt 0 ]` / `-gt 0` on a value that is not
# a number reads as 0, silently -- the comparisons that decide whether a logoff seals over a live overlay and whether
# the next seal wipes the user's Bluetooth. Each arm is now written into a runner file and run under each of bash,
# sh, dash and mksh found, parsed by that shell first, and a mutant convicts only when every shell has its own
# failing assertion line -- the very case(s) named for that mutant, printed as the evidence.
#
# NWP-20261115-11: the count passed the table to grep as a `printf '%s\n' "$_mt"` argument. On the device printf is
# /system/bin/printf (mksh has no printf builtin), the kernel refuses one argument over 128 KiB (E2BIG), grep counted
# an empty stream, and both arms answered OK over live mounts. Each runner now carries a printf stub with the device's
# limit, and `--big <n>` makes a table over 140000 bytes with n media lines. C7 and K6 convict the old form; C8 and K7
# are CONTROLS (a big table with no media line is read and counted, not UNREAD).
#
#   bash test-sweepmedia-verify.sh            # the cases
#   bash test-sweepmedia-verify.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'command rm -rf "$W"' EXIT

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

# --big <n>: n media lines plus non-media pad lines, over 140000 bytes (MAX_ARG_STRLEN is 131072). A fixture under
# the limit proves nothing, so a short one fails the whole suite, not a case.
mkbig() {
  local n="$1" out="$W/big.$1"
  awk -v n="$n" 'BEGIN{ s=0
    for(k=1;k<=n;k++){ l=sprintf("nowheremedia /data/user/10/app%d/files fuse.nowheremedia rw 0 0", k); print l; s+=length(l)+1 }
    pad="rw"; for(i=0;i<20;i++) pad=pad ",seclabel,nosuid,nodev,noatime"
    for(k=1;s<=150000;k++){ l=sprintf("/dev/block/dm-%d /mnt/pad%d ext4 %s 0 0", k, k, pad); print l; s+=length(l)+1 } }' > "$out" || return 1
  [ "$(wc -c < "$out")" -gt 140000 ]
}
for b in 0 3; do
  mkbig "$b" || { echo "the --big $b fixture is not over 140000 bytes: it would prove nothing" >&2; exit 2; }
done

# An arm runs from its `<name>)` label to the first `;;` after it.
extract() { awk -v lab="  $2)" 'index($0,lab)==1{on=1;next} on&&/^    ;;$/{exit} on{print}' "$1"; }

suite() {
  local f="$1" sh="$2" p=0 x=0 blk kblk pf
  ok(){ p=$((p+1)); printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$1"; }

  blk=$(extract "$f" sweepmedia)
  case "$blk" in *'stop_mediad'*) ;; *) no "EXTRACTION FAILED -- the sweepmedia arm moved in $f"; return 2 ;; esac
  # Round 6: the block must still PARSE, or the suite would fail it for its syntax and call that a conviction.
  # NWP-20261111-23: parsed by the shell that runs it, from a file.
  pf=$(mktemp -p "$W") || return 2
  printf '%s\n' "$blk" > "$pf"
  "$sh" -n "$pf" 2>/dev/null || { command rm -f "$pf"; no "THE BLOCK DOES NOT PARSE under $sh in $f"; return 2; }
  kblk=$(extract "$f" coldsweep)
  case "$kblk" in *'stop_mediad'*) ;; *) command rm -f "$pf"; no "EXTRACTION FAILED -- the coldsweep arm moved in $f"; return 2 ;; esac
  printf '%s\n' "$kblk" > "$pf"
  "$sh" -n "$pf" 2>/dev/null || { command rm -f "$pf"; no "THE COLDSWEEP BLOCK DOES NOT PARSE under $sh in $f"; return 2; }
  command rm -f "$pf"

  # _run <block> <mode> [lines...] -> "<RES>|<marker MARKED or NONE>"
  # mode: lines (the lines are the table), --missing (a path that does not exist), --empty (an empty file),
  # --big <n> (the --big fixture with n media lines, over 128 KiB)
  # The arm runs from a runner file under "$sh", as roamd would run it: the uid/STATE/RES/LOG it reads, a
  # stop_mediad stub and the device's printf limit first, then the arm.
  _run() {
    local blkx="$1" mode="$2" d b m; shift 2
    d=$(mktemp -d -p "$W" run.XXXXXX)
    case "$mode" in
      --missing) : ;;
      --empty)   : > "$d/mounts" ;;
      --big)     cp "$W/big.$1" "$d/mounts" ;;
      *)         printf '%s\n' "$mode" "$@" > "$d/mounts" ;;
    esac
    b=$(printf '%s\n' "$blkx" | sed "s#/proc/mounts#$d/mounts#g")
    {
      printf "uid=10\nSTATE='%s'\nRES='%s/res'\nLOG='%s/log'\n" "$d" "$d" "$d"
      printf 'stop_mediad() { return 0; }\n'
      cat <<'STUB'
# The device's mksh has no printf builtin: printf goes through exec(2), and one argument over MAX_ARG_STRLEN (128 KB)
# fails with E2BIG. bash and dash run a builtin that has no limit, so every shell gets the device's limit here.
printf(){
  local __pa
  for __pa in "$@"; do
    if [ "${#__pa}" -gt 131072 ]; then echo "printf: Argument list too long" >&2; return 126; fi
  done
  command printf "$@"
}
STUB
      printf '%s\n' "$b"
    } > "$d/run.sh"
    "$sh" "$d/run.sh" >/dev/null 2>&1
    m=NONE; [ -e "$d/.btlogoff" ] && m=MARKED
    printf '%s|%s\n' "$(cat "$d/res" 2>/dev/null)" "$m"
    command rm -rf "$d"
  }
  run()  { _run "$blk" "$@"; }
  krun() { _run "$kblk" "$@"; }

  [ "$(run '/dev/block/dm-48 /data ext4 rw 0 0')" = "OK|MARKED" ] \
    && ok "C1 nothing left: OK, and the logoff is marked for the BT wipe" || no "C1 a clean sweep did not answer OK+marker"
  [ "$(run 'nowheremedia /data/user/10/com.x/files fuse.nowheremedia rw 0 0')" = "ERR-MEDIA-SWEEP 1|NONE" ] \
    && ok "C2 a FUSE overlay left: ERR-MEDIA-SWEEP 1, no marker" || no "C2 a left FUSE overlay was not refused"
  [ "$(run '/dev/block/dm-48 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/com.x ext4 rw 0 0' \
          'nowheremedia /data/media/10/Android fuse.nowheremedia rw 0 0')" = "ERR-MEDIA-SWEEP 2|NONE" ] \
    && ok "C3 a .under bind and an overlay left: ERR-MEDIA-SWEEP 2, no marker" || no "C3 a left .under bind was not counted"
  [ "$(run '/dev/fuse /storage/emulated fuse rw 0 0')" = "OK|MARKED" ] \
    && ok "C4 the system's own /storage FUSE is not ours: OK" || no "C4 an unrelated fuse mount was counted"

  [ "$(run --missing)" = "ERR-MEDIA-SWEEP UNREAD|NONE" ] \
    && ok "C5 an unreadable table: ERR-MEDIA-SWEEP UNREAD, no marker" || no "C5 an unread table did not refuse (or marked)"
  [ "$(run --empty)" = "ERR-MEDIA-SWEEP UNREAD|NONE" ] \
    && ok "C6 an empty table: ERR-MEDIA-SWEEP UNREAD, no marker" || no "C6 an empty table did not refuse (or marked)"
  [ "$(run --big 3)" = "ERR-MEDIA-SWEEP 3|NONE" ] \
    && ok "C7 a table over 128 KiB with 3 overlays left: ERR-MEDIA-SWEEP 3, no marker" \
    || no "C7 a table over 128 KiB with 3 overlays left was not refused (or marked)"
  [ "$(run --big 0)" = "OK|MARKED" ] \
    && ok "C8 control: a table over 128 KiB with nothing left is read: OK, marked" \
    || no "C8 a table over 128 KiB with nothing left did not answer OK+marker"

  [ "$(krun '/dev/block/dm-48 /data ext4 rw 0 0')" = "OK|NONE" ] \
    && ok "K1 coldsweep, nothing left: OK" || no "K1 a clean coldsweep did not answer OK"
  [ "$(krun 'nowheremedia /data/user/10/com.x/files fuse.nowheremedia rw 0 0')" = "ERR-MEDIA-SWEEP 1|NONE" ] \
    && ok "K2 coldsweep, a FUSE overlay left: ERR-MEDIA-SWEEP 1" || no "K2 coldsweep did not refuse a left overlay"
  [ "$(krun '/dev/block/dm-48 /data/user/10/com.nowhere.chooser/files/.nowhere-media/.under/com.x ext4 rw 0 0' \
            'nowheremedia /data/media/10/Android fuse.nowheremedia rw 0 0')" = "ERR-MEDIA-SWEEP 2|NONE" ] \
    && ok "K3 coldsweep, a .under bind and an overlay left: ERR-MEDIA-SWEEP 2" || no "K3 coldsweep did not count a .under bind"
  [ "$(krun --missing)" = "ERR-MEDIA-SWEEP UNREAD|NONE" ] \
    && ok "K4 coldsweep, an unreadable table: ERR-MEDIA-SWEEP UNREAD" || no "K4 coldsweep answered over an unread table"
  [ "$(krun '/dev/block/dm-48 /data ext4 rw 0 0')" = "OK|NONE" ] && [ "$(krun --empty)" = "ERR-MEDIA-SWEEP UNREAD|NONE" ] \
    && ok "K5 coldsweep never writes .btlogoff" || no "K5 coldsweep wrote the logoff marker"
  [ "$(krun --big 3)" = "ERR-MEDIA-SWEEP 3|NONE" ] \
    && ok "K6 coldsweep, a table over 128 KiB with 3 overlays left: ERR-MEDIA-SWEEP 3" \
    || no "K6 coldsweep did not refuse a table over 128 KiB with 3 overlays left"
  [ "$(krun --big 0)" = "OK|NONE" ] \
    && ok "K7 control: coldsweep, a table over 128 KiB with nothing left is read: OK" \
    || no "K7 coldsweep did not answer OK for a table over 128 KiB with nothing left"

  printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "$sh" || rc=1; done
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED under each shell's own line -- by behaviour: a mutant that no longer extracts proves nothing)"
mut() { # mut <label> <perl-expr> <case ids that must FAIL under every shell>
  local m rc sh out c hit miss bad=0; m=$(mktemp -p "$W")
  # FAIL CLOSED (NWP-20261010-10, round 5): a perl error or an empty mutant used to read as "convicted", because the
  # suite fails on it -- for the wrong reason. Each is now its own failure, and so is a mutant whose block no longer
  # extracts (suite rc 2): a conviction must come from behaviour.
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; command rm -f "$m"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; command rm -f "$m"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; command rm -f "$m"; return 1; fi
  # NWP-20261111-23: per shell, and by that shell's own assertion lines. A mutant one shell convicts and another
  # runs clean is not convicted, and neither is a bare rc 1: every case named for the mutant must print its own
  # `FAIL  [<sh>] <id> ...` line under each shell, and those lines are shown as the evidence.
  for sh in $SHELLS; do
    out=$(suite "$m" "$sh"); rc=$?
    case "$rc" in
      0) echo "  SURVIVED  $1 [$sh]"; bad=1; continue ;;
      1) ;;
      *) echo "  BROKEN    $1 [$sh] -- the mutant's block no longer extracts or parses (rc=$rc)"; bad=1; continue ;;
    esac
    hit=""; miss=""
    for c in $3; do
      case "$out" in
        *"  FAIL  [$sh] $c "*) hit="$hit $c" ;;
        *) miss="$miss $c" ;;
      esac
    done
    if [ -n "$miss" ] || [ -z "$hit" ]; then
      echo "  UNPROVEN  $1 [$sh] -- failed, but not on its own case(s):${miss:- none named}"; bad=1
    else
      echo "  convicted $1 [$sh] by$hit"
    fi
    printf '%s\n' "$out" | grep -F "  FAIL  [$sh] " | sed 's/^/      /'
  done
  command rm -f "$m"
  return "$bad"
}
fails=0
mut "M1 never refuses (the old arm)"      's/(  sweepmedia\)\n(?:.*\n)*?    )elif \[ "\$_left" -gt 0 \]; then/$1elif false; then/' "C2 C3" || fails=$((fails+1))
mut "M2 the marker before the check"      's/(  sweepmedia\)\n(?:.*\n)*?    stop_mediad\n)/$1    : > "\$STATE\/.btlogoff"\n/' "C2 C3 C5 C6" || fails=$((fails+1))
mut "M3 the .under binds not counted"     's/(  sweepmedia\)\n(?:.*\n)*?      _left=\$\(grep -c -e " fuse\.nowheremedia ") -e "[^"]*"/$1/' "C3" || fails=$((fails+1))
mut "U1 sweepmedia reads no status"       's/(  sweepmedia\)\n(?:.*\n)*?    )if \[ "\$_mtrc" -eq 0 \] && \[ -n "\$_mt" \]; then/$1if true; then/' "C5 C6" || fails=$((fails+1))
mut "U2 coldsweep reads no status"        's/(  coldsweep\)\n(?:.*\n)*?    if )\[ "\$_mtrc" -ne 0 \] \|\| \[ -z "\$_mt" \]; then/$1false; then/' "K4 K5" || fails=$((fails+1))
mut "U3 the marker before the read check" 's/(  sweepmedia\)\n(?:.*\n)*?    _mt=\$\(cat [^\n]*\n)/$1    : > "\$STATE\/.btlogoff"\n/' "C2 C3 C5 C6" || fails=$((fails+1))
mut "U4 sweepmedia no empty-table check"  's/(  sweepmedia\)\n(?:.*\n)*?    if \[ "\$_mtrc" -eq 0 \]) && \[ -n "\$_mt" \]; then/$1; then/' "C6" || fails=$((fails+1))
# NWP-20261111-23: a count that is not a number. mksh reads `x<n>` as 0 in `[ -lt ]` / `[ -gt ]`, silently; bash and
# dash error and the test is false. Either way the arm lands on OK (and sweepmedia arms the Bluetooth wipe) over a
# table with overlays in it, so C2/C3 (K2/K3) must convict it under every shell, mksh included.
mut "N1 sweepmedia counts a non-number"   's/(  sweepmedia\)\n(?:.*\n)*?      _left=)(\$\(grep )/$1x$2/' "C2 C3" || fails=$((fails+1))
mut "N2 coldsweep counts a non-number"    's/(  coldsweep\)\n(?:.*\n)*?      _left=)(\$\(grep )/$1x$2/' "K2 K3" || fails=$((fails+1))
# NWP-20261115-11: the count back to a printf argument. Under the device's printf limit a table over 128 KiB reads 0.
mut "P1 sweepmedia counts through printf" 's/(  sweepmedia\)\n(?:.*\n)*?      _left=\$\()(grep -c -e [^\n]*") <<EOF_MT\n\$_mt\nEOF_MT\n\)/$1printf \x27%s\\n\x27 "\$_mt" | $2)/' "C7" || fails=$((fails+1))
mut "P2 coldsweep counts through printf"  's/(  coldsweep\)\n(?:.*\n)*?      _left=\$\()(grep -c -e [^\n]*") <<EOF_MT\n\$_mt\nEOF_MT\n\)/$1printf \x27%s\\n\x27 "\$_mt" | $2)/' "K6" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
