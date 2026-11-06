#!/usr/bin/env bash
# test-odrestore-growth.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's copy writes a progress line while its
# destination still grows, so only a copy that stops growing reaches the daemon's 150 s stop (NWP-20261124-03).
#
# WHY THIS IS COMMITTED. The 2026-11-01 decision (h50 #1, docs/product-decisions.md) has the login daemon stop a
# worker op it gave up on, and has odrestore write a progress line while its copy is still growing: the worker reads
# the destination's size about every 10 seconds and writes a line only on growth. The stop was built first
# (NWP-20261120-01); the arm wrote one line per held volume and then ran its copy silent. The daemon resets its stall
# clock only when the progress line changes (core/agent main.go runWorkerHeld), so a held volume whose copy needs more
# than 150 s (a large CE hold on a busy f2fs) was stopped while it still worked, the hold was kept, and every retry
# this session repeated it. od_watched runs the copy in the background and reads `du -sk <dst>` between polls.
#
# This suite EXECUTES the real extracted od_watched, cutoff_prog and odrestore arm under every shell found (the
# device's is mksh). A PATH stub `du` prints the size held in a file and counts its calls; the copy stubs move in
# lockstep with that count (never with sleeps), so no assertion depends on how many polls land in a stretch of time:
#   G1 GROWTH: the copy raises the size after each of 3 du reads -> at least 3 progress lines after the volume's first
#   G2 NO GROWTH: the size stays the same for 3 du reads -> no line after the first
#   G3 FAILURE: the copy fails with one error line -> `cp FAILED -- hold KEPT` with the same error-count text
#   G4 SERVED: od_served_copy's `served=<k>` tail is still parsed after the watcher's output
#   G5 no output file is left in $STATE after any case; no progress line names the package
#   F1 $STATE unwritable: the copy runs in the foreground, its status is kept, no du runs
#   F2 $STATE unwritable and the copy fails: its stderr is still in _ce (the error-count text)
#
#   bash test-odrestore-growth.sh              # the cases, under every shell found
#   bash test-odrestore-growth.sh --mutate     # ... plus mutants of od_watched that must each CONVICT under each shell
#
# Pure logic -- no device. The functions and the arm are EXTRACTED by anchor and re-rooted to a temp tree.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, driver, stub and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=(); seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"

UID_=15
PKG=com.example.game
APPID=10234
OWNED=$((UID_ * 100000 + APPID))

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 ODH ARM ARMR PROG OW n sh L R HARN=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  atleast() { [ "$1" -ge "$2" ]; }
  has() { grep -qF -- "$2" "$1" 2>/dev/null; }
  nopkg() { ! grep -qF -- "$PKG" "$1" 2>/dev/null; }

  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  ARM=$(arm_of "$f" odrestore)
  PROG=$(anchor_of "$f" 'cutoff_prog() {')
  # od_watched is absent before NWP-20261124-03: define nothing, so the cases RUN against that code and fail.
  OW=$(anchor_of "$f" 'od_watched() {')
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  case "$PROG" in *'NOWHERE_PROGRESS.tmp'*'mv -f'*) ;; *) echo "EXTRACTION FAILED: cutoff_prog in $f" >&2; return 2 ;; esac
  case "$OW" in ''|*'du -sk "$dst"'*) ;; *) echo "EXTRACTION FAILED: od_watched in $f" >&2; return 2 ;; esac
  n=$(nleft "$OW")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: od_watched holds $n absolute /data path(s)" >&2; return 2; }
  ARMR=$(printf '%s\n' "$ARM" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
  n=$(printf '%s\n' "$ARMR" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$ARMR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/bin" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" \
             "$R/data/user_de/$UID_" "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/sim/ducalls"; echo 100 > "$R/sim/size"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    # du: print the size first, THEN count the call, so a copy stub that waits on the count changes the size only
    # after this read is done.
    printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "$(cat "%s")" "$2"\necho x >> "%s"\n' "$R/sim/size" "$R/sim/ducalls" > "$R/bin/du"
    chmod +x "$R/bin/du"
  }
  # plant <vol> [owned]: a hold for $PKG on that volume; `owned` adds an app-owned (empty) destination (CE/DE)
  plant() {
    mkdir -p "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files"
    echo payload > "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files/f.txt"
    [ "${2:-}" = owned ] || return 0
    mkdir -p "$R/data/$1/$PKG"
    echo "$R/data/$1/$PKG $OWNED" >> "$R/sim/owners"
  }
  # driver <root> <copy mode> <state dir or file>: stubs + the extracted text, written to a FILE for the shell
  driver() {
    {
      printf "ROOT='%s'\nLOG='%s'\nRES='%s'\nuid=%s\nPATH='%s':\"\$PATH\"\nexport PATH\n" \
             "$1" "$1/roam.log" "$1/res" "$UID_" "$1/bin"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\nCPMODE=%s\n" \
             "$1/data/user/$UID_" "$PKG" "$3" "$2"
      printf "NOWHERE_PROGRESS='%s'\nOD_GROW_EVERY=1\n" "$1/prog"
      cat <<'EOF'
date() { echo DATE; }
restorecon() { :; }
am() { return 0; }
pidof() { :; }
pkg_live_pids() { :; }
grant_perms_for() { :; }
keystore_register() { :; }
pm() { case "$*" in "list packages -U "*) echo "package:$srcunit uid:1110234" ;; esac; return 0; }
reown_ext_appdata() { :; }
wait_acct_authenticator() { :; }
acct_reload() { :; }
sync_apply() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
reown_restored() { :; }
od_relabel() { :; }
stat() { awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners"; }
# wait_du <n>: wait until du has been called n times; 60 s safety exit marks the case and fails the copy
wait_du() {
  local i=0 c
  while :; do
    c=$(grep -c . "$ROOT/sim/ducalls")
    [ "$c" -ge "$1" ] && return 0
    i=$((i+1))
    [ "$i" -le 600 ] || { : > "$ROOT/sim/timeout"; return 1; }
    sleep 0.1
  done
}
raise() { echo $(( $(cat "$ROOT/sim/size") + 100 )) > "$ROOT/sim/size"; }
cp() {
  local k
  case "$CPMODE" in
    fail) echo "cp: x: Permission denied" >&2; return 1 ;;
    grow)
      command cp -R "$2" "$3" || return 1
      for k in 1 2 3; do wait_du "$k" || return 1; raise; done
      wait_du 4 || return 1 ;;
    flat)
      command cp -R "$2" "$3" || return 1
      wait_du 3 || return 1 ;;
    *) command cp -R "$2" "$3" ;;
  esac
}
# od_served_copy: copy, grow once, then the `served=` tail last on stdout
od_served_copy() {
  command cp -R "$1"/. "$2"/ || return 1
  wait_du 1 || return 1
  raise
  wait_du 2 || return 1
  echo "served=3"
  return 0
}
EOF
      printf '%s\n%s\n%s\n' "$ODH" "$PROG" "$OW"
      printf 'case "$op" in\n%s\nesac\n' "$ARMR"
    } > "$1/driver.sh"
  }
  run() {  # run <sh> <copy mode> [state file]
    local e st="$R/state"
    [ -z "${3:-}" ] || { st="$R/statefile"; : > "$st"; }
    driver "$R" "$2" "$st"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  ticks() { local l; l=$(val "$R/prog"); case "$l" in "cutoff od "*) echo $(( ${l#cutoff od } - 1 )) ;; *) echo -1 ;; esac; }
  dus() { grep -c . "$R/sim/ducalls"; }
  left() { ls -A "$R/state" | grep -vx media-unders | tr '\n' ' '; }
  CE="user/$UID_"; EXT="media/$UID_/Android/data"
  hold() { echo "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG"; }
  ERRTXT="(1 error line(s), last: Permission denied)"

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh G1: the destination grows after each of 3 du reads -> a progress line per growth =="
    mkroot; plant "$CE" owned
    run "$sh" grow
    chk "$L G1 at least 3 progress lines after the volume's first" atleast "$(ticks)" 3
    chk "$L G1 the copy never hit its safety exit" absent "$R/sim/timeout"
    chk "$L G1 the restore is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) restored+reowned"
    chk "$L G1 the hold is dropped" absent "$(hold "$CE")"
    chk "$L G1 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L G1 no progress line names the package" nopkg "$R/prog"
    chk "$L G5 no output file is left in \$STATE (G1)" eqv "$(left)" ""

    say "== $sh G2: the destination does not grow over 3 du reads -> no line after the first =="
    mkroot; plant "$CE" owned
    run "$sh" flat
    chk "$L G2 the progress line is still the volume's first" eqv "$(val "$R/prog")" "cutoff od 1"
    chk "$L G2 du ran at least 3 times" atleast "$(dus)" 3
    chk "$L G2 the copy never hit its safety exit" absent "$R/sim/timeout"
    chk "$L G2 the restore is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) restored+reowned"
    chk "$L G5 no output file is left in \$STATE (G2)" eqv "$(left)" ""

    say "== $sh G3: the copy fails with one error line -> the hold is kept, the error text as before =="
    mkroot; plant "$CE" owned
    run "$sh" fail
    chk "$L G3 cp FAILED -- hold KEPT is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) cp FAILED -- hold KEPT"
    chk "$L G3 the error-count text is unchanged" has "$R/roam.log" "$ERRTXT"
    chk "$L G3 the hold is kept" eqv "$(val "$(hold "$CE")/files/f.txt")" payload
    chk "$L G3 the reply is ERR-NOTREADY" eqv "$(val "$R/res")" ERR-NOTREADY
    chk "$L G5 no output file is left in \$STATE (G3)" eqv "$(left)" ""

    say "== $sh G4: od_served_copy under the watcher -> the served= tail is still parsed =="
    mkroot; plant "$EXT"
    printf '%s\t%s\n' "$R/data/$EXT/$PKG/files/x" "$R/hidden" > "$R/state/media-unders"
    run "$sh" grow
    chk "$L G4 the served count is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$EXT) restored+reowned (3 entr(y/ies) left served by mediad)"
    chk "$L G4 the growth wrote a progress line" atleast "$(ticks)" 1
    chk "$L G4 the copy never hit its safety exit" absent "$R/sim/timeout"
    chk "$L G4 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L G5 no output file is left in \$STATE (G4)" eqv "$(left)" ""

    say "== $sh F1: \$STATE unwritable -> the copy runs in the foreground, its status kept =="
    mkroot; plant "$CE" owned
    run "$sh" ok statefile
    chk "$L F1 the restore is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) restored+reowned"
    chk "$L F1 the data landed" eqv "$(val "$R/data/$CE/$PKG/files/f.txt")" payload
    chk "$L F1 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L F1 no du ran" eqv "$(dus)" 0

    say "== $sh F2: \$STATE unwritable and the copy fails -> its stderr is still in _ce =="
    mkroot; plant "$CE" owned
    run "$sh" fail statefile
    chk "$L F2 cp FAILED -- hold KEPT is logged" has "$R/roam.log" "odrestore $PKG ($R/data/$CE) cp FAILED -- hold KEPT"
    chk "$L F2 the error-count text is unchanged" has "$R/roam.log" "$ERRTXT"
    chk "$L F2 the reply is ERR-NOTREADY" eqv "$(val "$R/res")" ERR-NOTREADY
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations of od_watched (each MUST be convicted under EACH shell's own line) =="
# xform <from> <to>: inside od_watched only, the line exactly <from> becomes <to> (the token DEL drops it).
xform() {
  awk -v FR="$1" -v TO="$2" '
    $0 == "od_watched() {" { fn = 1 }
    fn && $0 == FR { hit = 1; if (TO != "DEL") print TO; next }
    { print }
    fn && $0 == "}" { fn = 0 }
    END { exit !hit }
  ' "$SUT"
}
MF=0
mutate() {  # mutate <id> <label> <from> <to>
  local id="$1" label="$2" m out mrc s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! xform "$3" "$4" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (nothing changed): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /'; MF=$((MF+1)); return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] "*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted: $id $label"; fi
}
L_TICK='    if [ -n "$last" ] && [ "$sz" -gt "$last" ]; then cutoff_prog od; fi'
L_RET='  return "$rc"'
L_RM='  rm -f "$out"'
L_FB='  [ -n "$out" ] || { "$@" 2>&1; return $?; }'
# The control: replacing a line with itself must reproduce roamd byte for byte.
c=$(mktemp -p "$W") || exit 2
if ! xform "$L_TICK" "$L_TICK" > "$c" || ! cmp -s "$SUT" "$c"; then
  echo "  FAIL  the transform does not reproduce $SUT (the anchors moved)"; MF=$((MF+1))
fi
mutate m1 "a tick on every poll instead of on growth" "$L_TICK" '    cutoff_prog od'
mutate m2 "growth compared with -ge" "$L_TICK" '    if [ -n "$last" ] && [ "$sz" -ge "$last" ]; then cutoff_prog od; fi'
mutate m3 "the command's status replaced by the watcher's own" "$L_RET" '  return 0'
mutate m4 "the output file is not removed" "$L_RM" DEL
mutate m5 "the foreground fallback is dropped" "$L_FB" DEL
mutate m6 "2>&1 dropped from the fallback" "$L_FB" '  [ -n "$out" ] || { "$@"; return $?; }'

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
