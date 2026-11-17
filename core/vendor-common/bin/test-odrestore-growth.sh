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
# NWP-20261202-34 (h50 #1: the handset measurement of what the size walk costs): od_watched times each du read with
# `_ms` and merges one line into $STATE/od-grow-timing. A PATH stub `clock` (behind the `date` stub) makes time
# deterministic: read 1 of a root costs 900 ms, every later read 100 ms, from a 13-digit base. These cases call
# od_watched directly:
#   T1 two calls -> one line, vols=2, reads and du_ms summed, max_ms and kib the larger; the first call (no stored
#      file) prints no error naming the file; no .tmp left
#   T2 a garbled stored line (an expression, a sixth field, ten digits, a leading zero) -> restarts from zero; so does a
#      valid first line followed by junk and another valid line, a trailing blank line, a leading or a doubled space;
#      a valid line with no newline is merged
#   T3 $STATE a regular file, or the temp path blocked -> no file, the command's status and output kept
#   T4 the file holds digits and the fixed field names only (no package, no path)
#   T5 od_watched's stdout is byte-identical to the command's output; its status is the command's
#   T6 a du call that fails (exit 1, a larger size printed) is still timed: reads, du_ms and max_ms count it; kib keeps
#      the last good size (0 when none was good); no growth line; stdout and status are the command's
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
  local f="$1" quiet="${2:-}" p=0 x=0 ODH PKGOK ARM ARMR PROG OW MS n sh L R HARN="" k v GT RE
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
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  # od_watched is absent before NWP-20261124-03: define nothing, so the cases RUN against that code and fail.
  OW=$(anchor_of "$f" 'od_watched() {')
  # _ms (NWP-20261202-34): od_watched times each du read with it, so it is extracted with it.
  MS=$(sed -n '/^_ms() /p' "$f")
  case "$OW" in *'_ms)'*) [ -n "$MS" ] || { echo "EXTRACTION FAILED: _ms not found in $f" >&2; return 2; } ;; esac
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
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
    # With sim/dufail holding N, every call after the N-th prints 999 and exits 1 (a failed walk).
    printf '#!/bin/sh\nc=$(grep -c . "%s")\nif [ -f "%s" ] && [ "$c" -ge "$(cat "%s")" ]; then\n  printf "999\\t%%s\\n" "$2"; echo x >> "%s"; exit 1\nfi\nprintf "%%s\\t%%s\\n" "$(cat "%s")" "$2"\necho x >> "%s"\n' \
      "$R/sim/ducalls" "$R/sim/dufail" "$R/sim/dufail" "$R/sim/ducalls" "$R/sim/size" "$R/sim/ducalls" > "$R/bin/du"
    chmod +x "$R/bin/du"
    # clock (NWP-20261202-34): call k of this root prints BASE + k*1000 when k is odd and, when k is even, the odd
    # call's time plus 900 ms for the first read and 100 ms for every later one. It runs under /bin/sh with awk's
    # arithmetic, so the shell under test sees 13-digit times, as on a device.
    : > "$R/sim/clock"
    printf '#!/bin/sh\necho x >> "%s"\nk=$(grep -c . "%s")\nawk -v k="$k" %s\n' "$R/sim/clock" "$R/sim/clock" \
      "'BEGIN { b = 1767225600000; if (k % 2) printf \"%.0f\\n\", b + k * 1000; else printf \"%.0f\\n\", b + (k - 1) * 1000 + (k == 2 ? 900 : 100) }'" \
      > "$R/bin/clock"
    chmod +x "$R/bin/clock"
  }
  # plant <vol> [owned]: a hold for $PKG on that volume; `owned` adds an app-owned (empty) destination (CE/DE)
  plant() {
    mkdir -p "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files"
    echo payload > "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files/f.txt"
    [ "${2:-}" = owned ] || return 0
    mkdir -p "$R/data/$1/$PKG"
    echo "$R/data/$1/$PKG $OWNED" >> "$R/sim/owners"
  }
  # driver <root> <copy mode> <state dir or file> [body]: stubs + the extracted text, written to a FILE for the shell;
  # with a body, the body runs instead of the odrestore arm (the T cases call od_watched directly)
  driver() {
    {
      printf "ROOT='%s'\nLOG='%s'\nRES='%s'\nuid=%s\nPATH='%s':\"\$PATH\"\nexport PATH\n" \
             "$1" "$1/roam.log" "$1/res" "$UID_" "$1/bin"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\nCPMODE=%s\n" \
             "$1/data/user/$UID_" "$PKG" "$3" "$2"
      printf "NOWHERE_PROGRESS='%s'\nOD_GROW_EVERY=1\n" "$1/prog"
      cat <<'EOF'
date() { case "${1:-}" in +%s%3N) "$ROOT/bin/clock" ;; *) echo DATE ;; esac; }
restorecon() { :; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03
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
vpn_preconsent_off() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
reown_restored() { :; }
od_relabel() { :; }
od_label_watched() { reown_restored "$2"; od_relabel "$1" "$2"; }
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
# The T cases' commands (NWP-20261202-34), each in lockstep with du's call count from its own start.
# ogrow: raise the size after each of 3 reads, end after the 4th; oflat: end after 2 reads, no growth;
# oprint <rc> <tail>: print `alpha` and the tail around 2 reads, then return rc; ofixed: the same output at once, rc 3
# (the foreground fallback runs no du, so a command there must not wait on one).
ogrow() {
  local k b
  b=$(grep -c . "$ROOT/sim/ducalls")
  for k in 1 2 3; do wait_du $((b + k)) || return 1; raise; done
  wait_du $((b + 4))
}
oflat() { local b; b=$(grep -c . "$ROOT/sim/ducalls"); wait_du $((b + 2)); }
oprint() {
  local b
  b=$(grep -c . "$ROOT/sim/ducalls")
  printf 'alpha\n'
  wait_du $((b + 1)) || return 1
  printf '%s' "$2"
  wait_du $((b + 2)) || return 1
  return "$1"
}
ofixed() { printf 'alpha\nserved=3'; return 3; }
EOF
      printf '%s\n%s\n%s\n%s\n%s\n' "$ODH" "$PKGOK" "$PROG" "$MS" "$OW"
      if [ -n "${4:-}" ]; then
        printf '%s\n' "$4"
      else
        printf 'case "$op" in\n%s\nesac\n' "$ARMR"
      fi
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
  # runow <sh> <state dir or file> <body>: od_watched called directly; its stdout and status land in sim/out, sim/rc
  runow() {
    local e
    driver "$R" none "$2" "$3"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  OWCALL='mkdir -p "$ROOT/dst"; od_watched "$ROOT/dst"'
  OWOUT='> "$ROOT/sim/out"; echo "$?" > "$ROOT/sim/rc"'
  gt() { val "$R/state/od-grow-timing"; }
  # want_line <reads> <kib>: the line a fresh file holds after <reads> clock-timed reads (900 + 100 per later read)
  want_line() { echo "v=1 vols=$3 reads=$1 du_ms=$((900 + 100 * ($1 - 1))) max_ms=900 kib=$2"; }
  nostderr() { local c; c=$(grep -c -- od-grow-timing "$R/sim/stderr" 2>/dev/null); [ "${c:-0}" = 0 ]; }
  shape() { [[ "$1" =~ ^v=1\ vols=[0-9]+\ reads=[0-9]+\ du_ms=[0-9]+\ max_ms=[0-9]+\ kib=[0-9]+$ ]]; }
  nolines() { [ "$(awk 'END { print NR }' "$1" 2>/dev/null)" = "$2" ]; }
  noslash() { case "$1" in */*) return 1 ;; esac; }
  samefile() { cmp -s "$1" "$2"; }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  ticks() { local l; l=$(val "$R/prog"); case "$l" in "cutoff od "*) echo $(( ${l#cutoff od } - 1 )) ;; *) echo -1 ;; esac; }
  dus() { grep -c . "$R/sim/ducalls"; }
  left() { ls -A "$R/state" | grep -vx -e media-unders -e od-grow-timing | tr '\n' ' '; }
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

    say "== $sh T1: two watched copies -> one merged line (NWP-20261202-34) =="
    mkroot
    runow "$sh" "$R/state" "$OWCALL ogrow $OWOUT"
    chk "$L T1 the first call prints no error naming the state file" nostderr
    k=$(dus)
    chk "$L T1 the first call alone: $(gt)" eqv "$(gt)" "$(want_line "$k" 400 1)"
    echo 150 > "$R/sim/size"
    runow "$sh" "$R/state" "$OWCALL oflat $OWOUT"
    k=$(dus)
    chk "$L T1 vols=2, reads and du_ms summed, max_ms and kib the larger: $(gt)" eqv "$(gt)" "$(want_line "$k" 400 2)"
    chk "$L T1 the file is one line" nolines "$R/state/od-grow-timing" 1
    chk "$L T1 no od-grow-timing.tmp left" absent "$R/state/od-grow-timing.tmp"
    chk "$L T1 the copies never hit their safety exit" absent "$R/sim/timeout"
    GT=$(gt)
    chk "$L T4 the line has the fixed shape: $GT" shape "$GT"
    chk "$L T4 the line names no package" nopkg "$R/state/od-grow-timing"
    chk "$L T4 the line holds no path" noslash "$GT"

    say "== $sh T2: a garbled stored line -> the merge restarts from zero =="
    for v in 'v=1 vols=4+4 reads=1 du_ms=1 max_ms=1 kib=1' 'v=1 vols=1 reads=1 du_ms=1 max_ms=1 kib=1 x=1' \
             'v=1 vols=1 reads=1 du_ms=1 max_ms=1 kib=1234567890' 'v=1 vols=08 reads=1 du_ms=1 max_ms=1 kib=1'; do
      mkroot
      printf '%s\n' "$v" > "$R/state/od-grow-timing"
      runow "$sh" "$R/state" "$OWCALL oflat $OWOUT"
      k=$(dus)
      chk "$L T2 over '$v': $(gt)" eqv "$(gt)" "$(want_line "$k" 100 1)"
      chk "$L T2 over '$v': no shell error" eqv "$(grep -c -i -e arith -e 'illegal number' -e 'bad number' -e 'value too great' "$R/sim/stderr")" 0
    done

    # RF-002: the whole stored file must be the one line, byte for byte; labels name each shape without its newlines.
    V1='v=1 vols=99 reads=99 du_ms=99 max_ms=99 kib=999'
    for v in multi blank lead double; do
      mkroot
      case "$v" in
        multi) printf '%s\njunk\n%s\n' "$V1" "$V1" ;;
        blank) printf '%s\n\n' "$V1" ;;
        lead) printf ' %s\n' "$V1" ;;
        double) printf '%s\n' "${V1/ vols/  vols}" ;;
      esac > "$R/state/od-grow-timing"
      runow "$sh" "$R/state" "$OWCALL oflat $OWOUT"
      k=$(dus)
      chk "$L T2 over a $v stored file: $(gt)" eqv "$(gt)" "$(want_line "$k" 100 1)"
    done
    mkroot
    printf 'v=1 vols=1 reads=1 du_ms=1 max_ms=1 kib=1' > "$R/state/od-grow-timing"
    runow "$sh" "$R/state" "$OWCALL oflat $OWOUT"
    k=$(dus)
    chk "$L T2 a valid line with no newline is merged: $(gt)" eqv "$(gt)" \
      "v=1 vols=2 reads=$((k + 1)) du_ms=$((1 + 900 + 100 * (k - 1))) max_ms=900 kib=100"

    say "== $sh T3: no file can be written -> no file, the command's status and output kept =="
    mkroot
    : > "$R/statefile"
    runow "$sh" "$R/statefile" "$OWCALL ofixed $OWOUT"
    chk "$L T3 \$STATE a regular file: no od-grow-timing anywhere" eqv "$(find "$R" -name 'od-grow-timing*' | grep -c .)" 0
    chk "$L T3 \$STATE a regular file: the status is the command's" eqv "$(val "$R/sim/rc")" 3
    chk "$L T3 \$STATE a regular file: the output is kept" eqv "$(val "$R/sim/out")" "$(printf 'alpha\nserved=3')"
    mkroot
    mkdir "$R/state/od-grow-timing.tmp"
    runow "$sh" "$R/state" "$OWCALL oprint 3 'served=3' $OWOUT"
    chk "$L T3 the temp path blocked: no od-grow-timing" absent "$R/state/od-grow-timing"
    chk "$L T3 the temp path blocked: the status is the command's" eqv "$(val "$R/sim/rc")" 3
    chk "$L T3 the temp path blocked: the output is kept" eqv "$(val "$R/sim/out")" "$(printf 'alpha\nserved=3')"
    chk "$L T3 the temp path blocked: no error names the file" nostderr

    say "== $sh T5: od_watched's stdout is the command's, byte for byte =="
    for v in 0 3; do
      mkroot
      runow "$sh" "$R/state" "$OWCALL oprint $v 'served=3' $OWOUT"
      printf 'alpha\nserved=3' > "$R/sim/want"
      chk "$L T5 rc $v, no trailing newline: stdout byte-identical" samefile "$R/sim/out" "$R/sim/want"
      chk "$L T5 rc $v: the status is the command's" eqv "$(val "$R/sim/rc")" "$v"
      chk "$L T5 rc $v: the merge ran" shape "$(gt)"
    done
    mkroot
    runow "$sh" "$R/state" "$OWCALL oprint 0 'served=3
' $OWOUT"
    printf 'alpha\nserved=3\n' > "$R/sim/want"
    chk "$L T5 a trailing newline: stdout byte-identical" samefile "$R/sim/out" "$R/sim/want"

    say "== $sh T6: a failed du call is still timed; kib keeps the last good size =="
    for v in 1 0; do
      mkroot
      echo "$v" > "$R/sim/dufail"
      runow "$sh" "$R/state" "$OWCALL oprint 3 'served=3' $OWOUT"
      k=$(dus)
      chk "$L T6 good reads $v: every du call timed, kib $((v * 100)): $(gt)" eqv "$(gt)" "$(want_line "$k" $((v * 100)) 1)"
      printf 'alpha\nserved=3' > "$R/sim/want"
      chk "$L T6 good reads $v: stdout byte-identical" samefile "$R/sim/out" "$R/sim/want"
      chk "$L T6 good reads $v: the status is the command's" eqv "$(val "$R/sim/rc")" 3
      chk "$L T6 good reads $v: no growth line" absent "$R/prog"
      chk "$L T6 good reads $v: the copy never hit its safety exit" absent "$R/sim/timeout"
    done
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
# NWP-20261202-34: the du-cost summary.
mutate m7 "no merge: the stored sums overwritten (T1)" '    sv=$((sv + 1)); sr=$((sr + reads)); sd=$((sd + du_ms))' \
  '    sv=1; sr=$reads; sd=$du_ms'
mutate m8 "max_ms taken as the last call's (T1)" '    if [ "$max_ms" -gt "$sm" ]; then sm=$max_ms; fi' '    sm=$max_ms'
mutate m9 "the stored digit check removed (T2)" "      case \"\$v\" in ''|*[!0-9]*|0?*|??????????*) bad=1 ;; esac" '      :'
mutate m10 "the summary also printed to stdout (T5, G4)" "$L_RET" "  cat \"\$STATE/od-grow-timing\" 2>/dev/null
$L_RET"
# m11 drops the [ -f ] guard. The reads put 2>/dev/null after their input redirection, so a missing file's error is
# not dropped: the guard is what keeps stderr clean.
mutate m11 "the stored line read with 2>/dev/null after the input (T1 stderr)" \
  '    if [ -f "$STATE/od-grow-timing" ]; then' '    if :; then'
mutate m12 "a field's shape pattern quoted (T1)" '    case "$b" in vols=*) ;; *) bad=1 ;; esac' \
  '    case "$b" in "vols=*") ;; *) bad=1 ;; esac'
# RF-001 and RF-002 (NWP-20261202-34 review): a failed du call, and a stored file of more than its one line.
mutate m13 "a failed du call skips its timing (T6)" '    sz=$(du -sk "$dst" 2>/dev/null) || sz=' \
  '    sz=$(du -sk "$dst" 2>/dev/null) || continue'
mutate m14 "a failed du call's size kept (T6)" '    sz=$(du -sk "$dst" 2>/dev/null) || sz=' \
  '    sz=$(du -sk "$dst" 2>/dev/null) || :'
mutate m15 "the line count check removed (T2 multi, blank)" '    [ "$nl" -le 1 ] || bad=1' DEL
mutate m16 "the exact-line check removed (T2 lead, double)" \
  '    [ "$l1" = "v=1 vols=$sv reads=$sr du_ms=$sd max_ms=$sm kib=$sk" ] || bad=1' DEL

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
