#!/usr/bin/env bash
# test-odrestore-served-retry-nocopy.sh [<nowhere_roamd.sh>] [--mutate] -- an odrestore retried after a stop in the
# EXTERNAL served hand-back (od_served_copy) copies only what the destination lacks (NWP-20261208-12).
#
# WHY THIS IS COMMITTED. The backlog row "An app with a large data hold never gets its data back: its odrestore goes
# silent for 150 s after the copy, the daemon gives up and stops it, the hold is kept, and every retry copies the whole
# hold again". NWP-20261204-04 gave the arm's plain copy a session record `<inode of $dst> <$dst>` in
# $STATE/.odcopied.<uid> and a `cp -a -n` retry, but od_served_copy (Android/data/<pkg> with a live mediad overlay
# inside it) wrote no record and its three `cp -a` took no -n: every retry after a stop copied the whole hold again.
# od_served_copy now takes a MODE: `rec` writes the record after its copy loop and before its hidden-dir chown/chcon
# pass (where a stop on this path most likely lands), `nc` does the same and copies with `cp -a -n` at all three
# sites. This suite EXECUTES the real extracted odrestore arm and od_served_copy under every shell found (the
# device's is mksh), against a temp /data tree, a $STATE/media-unders file and a simulated mount table, with a `cp`
# shim first in PATH that does -a and -n itself, logs its argv and refuses a write under a live overlay target:
#   S1 a first served attempt stopped in the hidden-dir chown pass: the hold stays, the record is exactly
#      `<inode> <dst>`; the retry calls cp ONLY with -n at each of the three sites, keeps a file the destination
#      holds, fills a file it lacks, drops the hold, answers OK, logs the (ext) line once, and the record line goes
#   S2 a first attempt whose cp fails: no record; the retry copies with plain `cp -a`
#   S3 a record naming another inode (dst re-created): plain `cp -a`, the hold's bytes overwrite
#   S4 od_served_copy called with two arguments, or a bad MODE: no -n, no record; with `rec`: the record
#   S5 rc 2 (the mounts are gone): the served path records nothing and the plain path runs as before
#   S6 the record holds digits, a space and the path only; no NWP-20261208-12 line names the package or a path
#
#   bash test-odrestore-served-retry-nocopy.sh              # the cases, under every shell found
#   bash test-odrestore-served-retry-nocopy.sh --mutate     # ... plus mutants of roamd that must each CONVICT
#
# Pure logic -- no device. The functions are EXTRACTED by anchor and re-rooted to a temp tree. The handset's toybox
# `cp -a -n FILE DST` is not exercised here: that is the merger's handset follow-up.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, driver, shim and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
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
CTX='u:object_r:media_rw_data_file:s0'

# The cp shim: logs its argv to $ROOT/sim/cpargv; fails when $ROOT/sim/cp-fail exists; takes -a (required) and -n
# (never overwrite an existing file); `SRC/. DST/` copies the tree, `FILE DST` one file. A write under a path listed
# in $ROOT/sim/targets (a live overlay view) is refused, as the kernel refuses it. It uses no host cp.
mkdir -p "$W/bin"
cat > "$W/bin/cp" <<'EOF'
#!/bin/sh
echo "$*" >> "$ROOT/sim/cpargv"
[ ! -f "$ROOT/sim/cp-fail" ] || { echo "cp: x: Permission denied" >&2; exit 1; }
a=0; n=0
while [ $# -gt 2 ]; do
  case "$1" in -a) a=1 ;; -n) n=1 ;; *) echo "cp shim: unknown option $1" >&2; exit 64 ;; esac
  shift
done
[ "$a" = 1 ] || { echo "cp shim: no -a" >&2; exit 64; }
refused() {
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$1" in "$t"|"$t"/*) return 0 ;; esac
  done < "$ROOT/sim/targets"
  return 1
}
put() {  # put <file> <dst file>
  if [ "$n" = 1 ] && [ -e "$2" ]; then return 0; fi
  if refused "$2"; then echo "cp: x: Permission denied" >&2; return 1; fi
  cat "$1" > "$2"
}
case "$1" in
  */.)
    src=${1%/.}; dst=${2%/}
    (cd "$src" && find . -type d) | while IFS= read -r d; do mkdir -p "$dst/$d"; done
    (cd "$src" && find . -type f) | { rc=0; while IFS= read -r f; do put "$src/$f" "$dst/$f" || rc=1; done; exit "$rc"; } ;;
  *)
    [ -f "$1" ] || { echo "cp shim: not a file $1" >&2; exit 64; }
    put "$1" "$2" ;;
esac
EOF
chmod +x "$W/bin/cp"

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 ODH PKGOK MIP SC SCR ARM ARMR n sh HARN="" R L V D T H X want got ino all
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
  hasnt() { ! has "$1" "$2"; }

  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  MIP=$(anchor_of "$f" 'mi_path() {')
  SC=$(anchor_of "$f" 'od_served_copy() {')
  ARM=$(arm_of "$f" odrestore)
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  case "$MIP" in *'sed -e'*) ;; *) echo "EXTRACTION FAILED: mi_path in $f" >&2; return 2 ;; esac
  case "$SC" in *'served=$k'*'return "$rc"'*) ;; *) echo "EXTRACTION FAILED: od_served_copy in $f" >&2; return 2 ;; esac
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  SCR=$(printf '%s\n' "$SC" | sed -E -e 's#([" |])/data/#\1$ROOT/data/#g' -e 's#/proc/self/mountinfo#$ROOT/sim/mountinfo#g')
  n=$(nleft "$SCR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: od_served_copy keeps $n absolute /data path(s) in live code" >&2; return 2; }
  case "$SCR" in *'/proc/'*) echo "RE-ROOT INCOMPLETE: od_served_copy still reads /proc" >&2; return 2 ;; esac
  ARMR=$(printf '%s\n' "$ARM" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
  n=$(printf '%s\n' "$ARMR" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$ARMR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" "$R/data/user_de/$UID_" \
             "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/sim/targets"; : > "$R/sim/mountinfo"; : > "$R/trace"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    V="$R/data/media/$UID_/Android/data"
    D="$V/$PKG"
    X="$V/com.nowhere.chooser/.nowhere-odhold/$PKG"
    T="$D/files/ContentDownload"
    H="$R/data/user/$UID_/com.nowhere.chooser/files/.nowhere-media-ext/.under/ContentDownload"
  }
  plant() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
  # overlay [live|dead]: the mediad overlay at T over the hidden dir H, published in media-unders; when live, both
  # paths are in the mount table and the cp shim refuses a write under T.
  overlay() {
    mkdir -p "$T" "$H"
    printf '%s\t%s\n' "$T" "$H" >> "$R/state/media-unders"
    if [ "${1:-live}" = live ]; then
      printf '%s\n' "$T" >> "$R/sim/targets"
      printf '91 30 0:61 / %s rw,nosuid,nodev,noatime - fuse /dev/fuse rw,user_id=0,group_id=0\n' "$T" >> "$R/sim/mountinfo"
      printf '92 30 253:5 /media/0/x %s rw,nosuid,nodev,noatime - f2fs /dev/block/dm-5 rw\n' "$H" >> "$R/sim/mountinfo"
    fi
  }
  # tree [live|dead]: an app-owned destination, the overlay, and a hold with entries for each of od_served_copy's
  # three cp sites: A a file under the target (into H), B a dir outside every target, C a file outside every target.
  tree() {
    mkdir -p "$D"
    overlay "${1:-live}"
    plant "$T/served.bin" STUB                         # the overlay's view: a stub mediad serves
    plant "$X/files/ContentDownload/served.bin" HELD-served
    plant "$X/files/ContentDownload/a1.bin" HELD-a1
    plant "$X/files/ContentDownload/a2.bin" HELD-a2
    plant "$X/files/cache2/b1.dat" HELD-b1
    plant "$X/files/cache2/b2.dat" HELD-b2
    plant "$X/files/c1.dat" HELD-c1
    plant "$X/files/c2.dat" HELD-c2
  }
  driver() {  # driver [direct-mode]: stubs + the extracted text, written to a FILE for the shell
    local d="$R/driver.sh"
    {
      printf "ROOT='%s'\nexport ROOT\nPATH='%s':\$PATH\nLOG='%s'\nRES='%s'\nT='%s'\nuid=%s\n" "$R" "$W/bin" "$R/roam.log" "$R/res" "$R/trace" "$UID_"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\nCTX='%s'\n" \
             "$R/data/user/$UID_" "$PKG" "$R/state" "$CTX"
      printf 'unset NOWHERE_PROGRESS\nOPPID=$$\n'
      cat <<'EOF'
case "${KSH_VERSION:-}" in *MIRBSD*) ;; *) print() { while [ $# -gt 0 ]; do case "$1" in -r) shift ;; --) shift; break ;; *) break ;; esac; done; printf '%s\n' "$*"; } ;; esac
date() { echo DATE; }
restorecon() { :; }
cutoff_prog() { :; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }
am() { return 0; }
pm() { return 0; }
pidof() { :; }
pkg_live_pids() { :; }
grant_perms_for() { :; }
keystore_register() { :; }
reown_ext_appdata() { :; }
wait_acct_authenticator() { :; }
acct_reload() { :; }
sync_apply() { :; }
vpn_preconsent_off() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
reown_restored() { echo "reown $1" >> "$T"; }
od_relabel() { echo "relabel $2" >> "$T"; }
od_label_watched() { echo "label $2" >> "$T"; }
od_watched() { shift; "$@" 2>&1; }
od_extdata_watched() { reown_ext_appdata "$1"; restorecon -R -D "$1"; }   # NWP-20261208-13: the arm now calls it; the pair it runs is stubbed above
# chown: a stop in the hidden-dir pass ends the whole op (the daemon's ctl.stop), not just the $(...) subshell
chown() {
  echo "chown $*" >> "$T"
  [ ! -f "$ROOT/sim/stop-at-chown" ] || { kill -9 "$OPPID" 2>/dev/null; exit 9; }
  return 0
}
chcon() { echo "chcon $*" >> "$T"; return 0; }
# stat: -c %i the real inode (rc 1 when sim/inode-fail exists), -c %C the context, -c %u the planted owner
stat() {
  case "$2" in
    %i) [ ! -f "$ROOT/sim/inode-fail" ] || return 1; command stat -c %i "$3" ;;
    %C) echo "$CTX" ;;
    *) awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners" ;;
  esac
}
EOF
      printf '%s\n%s\n%s\n%s\n' "$ODH" "$PKGOK" "$MIP" "$SCR"
      if [ "$#" -gt 0 ]; then
        # a direct call: $1 is the argument list after SRC DST ("" = two arguments)
        printf "od_served_copy '%s' '%s' %s > \"\$ROOT/sim/out\" 2>&1\necho \$? > \"\$ROOT/sim/rc\"\nexit 0\n" "$X" "$D" "$1"
      fi
      printf 'case "$op" in\n%s\nesac\n' "$ARMR"
    } > "$d"
  }
  run() {  # run <sh> [direct-mode]
    local e s="$1"
    shift
    rm -f "$R/res" "$R/sim/cpargv" "$R/sim/out" "$R/sim/rc"
    driver "$@"
    # the subshell takes the invoking shell's own "Killed" report when S1 stops the op
    ( "$s" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"; : ) 2>/dev/null
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found|parameter not set|cp shim' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$s: $e]"
  }
  val() { if [ -f "$1" ]; then cat "$1"; else echo -; fi; }
  rec() { echo "$R/state/.odcopied.$UID_"; }
  cpargv() { val "$R/sim/cpargv"; }
  # alln: every cp argv line starts `-a -n `; non: no cp argv line holds -n
  alln() { local l; [ -s "$R/sim/cpargv" ] || return 1; while IFS= read -r l; do case "$l" in "-a -n "*) ;; *) return 1 ;; esac; done < "$R/sim/cpargv"; }
  non() { local l; [ -s "$R/sim/cpargv" ] || return 1; while IFS= read -r l; do case "$l" in *" -n "*) return 1 ;; esac; done < "$R/sim/cpargv"; }
  line12() { grep -F 'NWP-20261208-12' "$R/roam.log" 2>/dev/null || true; }
  recdst() { grep -F " $D" "$(rec)" 2>/dev/null || true; }
  digits() { local l; [ -s "$1" ] || return 1; while IFS= read -r l; do case "$l" in [0-9]*" /"*) ;; *) return 1 ;; esac; case "${l%% *}" in *[!0-9]*) return 1 ;; esac; done < "$1"; }
  clean12() { case "$1" in *"$PKG"*|*a1.bin*|*c1.dat*|*cache2*|*/files/*|*/data/*) return 1 ;; esac; return 0; }
  NL='[roamd] odrestore: copy already finished this session on this volume (ext) -- copying only what the destination lacks (NWP-20261208-12) DATE'
  all=

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh S1: a first served attempt stopped in the hidden-dir chown pass, then the retry =="
    mkroot; tree; : > "$R/sim/stop-at-chown"
    want="$(command stat -c %i "$D") $D"
    run "$sh"
    chk "$L S1 the stopped attempt wrote no reply" absent "$R/res"
    chk "$L S1 the hold is still there after the stop" eqv "$(val "$X/files/c1.dat")" HELD-c1
    chk "$L S1 the record is exactly '<inode> <dst>'" eqv "$(val "$(rec)")" "$want"
    chk "$L S1 the stopped first attempt copied without -n" non
    chk "$L S6 (S1) the record holds digits, a space and the path only" digits "$(rec)"
    # between the attempts the app wrote newer copies of one file at each site and lost another
    printf NEWER > "$H/a1.bin"; printf NEWER > "$D/files/cache2/b1.dat"; printf NEWER > "$D/files/c1.dat"
    rm -f "$H/a2.bin" "$D/files/cache2/b2.dat" "$D/files/c2.dat" "$R/sim/stop-at-chown"
    run "$sh"
    got=$(cpargv)
    chk "$L S1 the retry called cp only with -n" alln
    chk "$L S1 the retry copied at site A (a file under the target)" has "$got" "-a -n $X/files/ContentDownload/a1.bin $H/a1.bin"
    chk "$L S1 the retry copied at site B (a dir outside every target)" has "$got" "-a -n $X/files/cache2/. $D/files/cache2/"
    chk "$L S1 the retry copied at site C (a file outside every target)" has "$got" "-a -n $X/files/c1.dat $D/files/c1.dat"
    chk "$L S1 site A kept the newer file the hidden dir holds" eqv "$(val "$H/a1.bin")" NEWER
    chk "$L S1 site B kept the newer file the destination holds" eqv "$(val "$D/files/cache2/b1.dat")" NEWER
    chk "$L S1 site C kept the newer file the destination holds" eqv "$(val "$D/files/c1.dat")" NEWER
    chk "$L S1 site A copied the file the hidden dir lacks" eqv "$(val "$H/a2.bin")" HELD-a2
    chk "$L S1 site B copied the file the destination lacks" eqv "$(val "$D/files/cache2/b2.dat")" HELD-b2
    chk "$L S1 site C copied the file the destination lacks" eqv "$(val "$D/files/c2.dat")" HELD-c2
    chk "$L S1 the served name was not copied into the hidden dir" absent "$H/served.bin"
    chk "$L S1 the hold is gone" absent "$X"
    chk "$L S1 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L S1 restored+reowned with 1 entry left served" has "$(val "$R/roam.log")" \
        "[roamd] odrestore $PKG ($V) restored+reowned (1 entr(y/ies) left served by mediad) DATE"
    got=$(line12)
    chk "$L S1 roam.log holds the (ext) line exactly once" eqv "$got" "$NL"
    chk "$L S1 the record line is gone" eqv "$(recdst)" ""
    all="$all$got
"

    say "== $sh S2: a first attempt whose cp fails -> no record; the retry copies with plain cp -a =="
    mkroot; tree; : > "$R/sim/cp-fail"
    run "$sh"
    chk "$L S2 a failed copy wrote no record" eqv "$(recdst)" ""
    chk "$L S2 the hold is kept" eqv "$(val "$X/files/c1.dat")" HELD-c1
    chk "$L S2 the reply is ERR-NOTREADY" eqv "$(val "$R/res")" ERR-NOTREADY
    rm -f "$R/sim/cp-fail"
    run "$sh"
    chk "$L S2 the retry copied with plain cp -a" non
    chk "$L S2 the retry dropped the hold" absent "$X"
    chk "$L S2 the retry's reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L S2 no NWP-20261208-12 line" eqv "$(line12)" ""

    say "== $sh S3: a record naming another inode -> plain cp -a, the hold's bytes overwrite =="
    mkroot; tree
    ino=$(command stat -c %i "$D")
    echo "$((ino + 1)) $D" > "$(rec)"
    printf NEWER > "$D/files/c1.dat"
    run "$sh"
    chk "$L S3 cp ran without -n" non
    chk "$L S3 the hold's bytes overwrite the destination's" eqv "$(val "$D/files/c1.dat")" HELD-c1
    chk "$L S3 no NWP-20261208-12 line" eqv "$(line12)" ""
    chk "$L S3 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"

    say "== $sh S4: od_served_copy called directly: two arguments, a bad MODE, rec =="
    mkroot; tree
    run "$sh" ""
    chk "$L S4 two arguments: cp has no -n" non
    chk "$L S4 two arguments: no record" absent "$(rec)"
    chk "$L S4 two arguments: served=1 last" eqv "$(val "$R/sim/out" | sed -n '$p')" served=1
    chk "$L S4 two arguments: rc 0" eqv "$(val "$R/sim/rc")" 0
    mkroot; tree
    run "$sh" bogus
    chk "$L S4 a bad MODE: cp has no -n" non
    chk "$L S4 a bad MODE: no record" absent "$(rec)"
    mkroot; tree
    want="$(command stat -c %i "$D") $D"
    run "$sh" rec
    chk "$L S4 MODE rec: cp has no -n" non
    chk "$L S4 MODE rec: the record is exactly '<inode> <dst>'" eqv "$(val "$(rec)")" "$want"
    chk "$L S4 MODE rec: no log line" absent "$R/roam.log"

    say "== $sh S5: rc 2 (the mounts are gone) -> nothing recorded by the served path, the plain path as before =="
    mkroot; tree dead
    run "$sh"
    chk "$L S5 no record: the plain cp -a, once" eqv "$(cpargv)" "-a $X/. $D/"
    chk "$L S5 no record: the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L S5 no record: no NWP-20261208-12 line" eqv "$(line12)" ""
    chk "$L S5 no record: no record is left" eqv "$(recdst)" ""
    mkroot; tree dead
    echo "$(command stat -c %i "$D") $D" > "$(rec)"
    run "$sh"
    chk "$L S5 a record: the plain path's own cp -a -n, once" eqv "$(cpargv)" "-a -n $X/. $D/"
    chk "$L S5 a record: the plain path's (ext) line" has "$(val "$R/roam.log")" \
        "on this volume (ext) -- copying only what the destination lacks (NWP-20261204-04) DATE"
    chk "$L S5 a record: no NWP-20261208-12 line" eqv "$(line12)" ""
    chk "$L S5 a record: the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"

    say "== $sh S6: no NWP-20261208-12 line names the package or a path =="
    chk "$L S6 the NWP-20261208-12 lines were written" test -n "$all"
    chk "$L S6 no NWP-20261208-12 line names the package or a path" clean12 "$all"
    all=
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST be convicted under EACH shell's own line, by the named case) =="
REC_IF='  if [ "$rc" = 0 ] && [ -n "$mode" ] && [ -n "${STATE:-}" ]; then'
# move_rec <anchor line> <before|after>: od_served_copy's record block (REC_IF to its `  fi`) moved to <anchor line>
move_rec() {
  awk -v S="$REC_IF" -v A="$1" -v pos="$2" '
    { l[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (l[i] == "od_served_copy() {") { fs = i; break }
      for (i = fs; i <= NR; i++) if (l[i] == "}") { fe = i; break }
      for (i = fs; i <= fe; i++) if (l[i] == S) { bs = i; break }
      for (i = bs; i <= fe; i++) if (l[i] == "  fi") { be = i; break }
      for (i = fs; i <= fe; i++) if (l[i] == A) { at = i; break }
      if (!fs || !bs || !be || !at) exit 3
      for (i = 1; i <= NR; i++) {
        if (i >= bs && i <= be) continue
        if (i == at && pos == "before") for (j = bs; j <= be; j++) print l[j]
        print l[i]
        if (i == at && pos == "after") for (j = bs; j <= be; j++) print l[j]
      }
    }
  ' "$SUT"
}
# sub1 <from> <to>: the ONE line holding <from> gets <to> in its place (exit 3 when <from> is on no line or on two)
sub1() {
  awk -v a="$1" -v b="$2" '
    { l[NR] = $0; if (index($0, a)) c++ }
    END {
      if (c != 1) exit 3
      for (i = 1; i <= NR; i++) {
        if (!done && (k = index(l[i], a))) { done = 1; l[i] = substr(l[i], 1, k - 1) b substr(l[i], k + length(a)) }
        print l[i]
      }
    }
  ' "$SUT"
}
MF=0
mutate() {  # mutate <id> <convicting case|SURVIVE> <label> <cmd...>
  local id="$1" by="$2" label="$3" m out mrc s miss=""
  shift 3
  m=$(mktemp -p "$W") || exit 2
  if ! "$@" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION BROKEN or AMBIGUOUS (anchor not on exactly one line): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (the copy is unchanged): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /'; MF=$((MF+1)); return; fi
  if [ "$by" = SURVIVE ]; then
    if [ "$mrc" = 0 ]; then echo "  ok    survived (control): $id $label"; else echo "  FAIL  the CONTROL was convicted: $id $label"; MF=$((MF+1)); fi
    return
  fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] $by"*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED by $by under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted by $by under ${SHELLS[*]}: $id $label"; fi
}
mutate N1 "S1 site A kept" "-n dropped at site A (a file under the target)" sub1 'cp -a $nf "$p" "$h/$rt"' 'cp -a "$p" "$h/$rt"'
mutate N2 "S1 site B kept" "-n dropped at site B (a dir outside every target)" sub1 'cp -a $nf "$p"/. "$full"/' 'cp -a "$p"/. "$full"/'
mutate N3 "S1 site C kept" "-n dropped at site C (a file outside every target)" sub1 'cp -a $nf "$p" "$full"' 'cp -a "$p" "$full"'
mutate N4 "S2 a failed copy wrote no record" "the record written whatever rc" sub1 'if [ "$rc" = 0 ] && [ -n "$mode" ]' 'if [ -n "$mode" ]'
mutate N4b "S2 a failed copy wrote no record" "the record written before the copy loop" move_rec '  while IFS= read -r p; do' before
mutate N5 "S3 cp ran without -n" "the arm does not compare the inode" sub1 'grep -qxF -- "$_odin $dst" "$STATE/.odcopied.$uid" 2>/dev/null && _odmd=nc' 'grep -q -- " $dst\$" "$STATE/.odcopied.$uid" 2>/dev/null && _odmd=nc'
mutate N6 "S1 the retry called cp only with -n" "the arm always passes rec" sub1 '2>/dev/null && _odmd=nc' '2>/dev/null && :'
mutate N7 "S4 two arguments: no record" "MODE empty also records" sub1 '*) mode= ;; esac' '*) mode=rec ;; esac'
mutate N8 "S1 the record is exactly" "the record written after the hidden-dir pass" move_rec '  echo "served=$k"' before
mutate N9 "S1 the record line is gone" "the arm clears _odin after the served path" sub1 '        _odpl=; [ "$_odsc" = 2 ] && _odpl=1' '        _odpl=; _odin=; [ "$_odsc" = 2 ] && _odpl=1'
mutate N10 "S6 no NWP-20261208-12 line names" "the (ext) line names the package" sub1 'on this volume (ext) --' 'on this volume (ext $pkg) --'
mutate N11 "S5 a record: no NWP-20261208-12 line" "the (ext) line written when the served path returned 2" sub1 'if [ "$_odmd" = nc ] && [ "$_odsc" != 2 ]; then' 'if [ "$_odmd" = nc ]; then'
mutate C SURVIVE "a word of od_served_copy's MODE comment" sub1 'Not a skip, so' 'Never a skip, so'

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
