#!/usr/bin/env bash
# test-odrestore-overlay-dst.sh [<nowhere_roamd.sh>] [--mutate] -- an On-demand app's EXTERNAL hand-back copies the
# hold around the entries mediad's read-only overlay serves inside the destination (NWP-20261121-02).
#
# WHY THIS IS COMMITTED. hold_ondemand parks Android/data/<pkg> at sign-in. mediad then re-creates the app's deferred
# dir (a Unity game's files/ContentDownload) inside the canonical dir, binds it to a hidden path and mounts its
# read-only overlay over it. roamd's domain may only read `fuse` objects, so odrestore's `cp -a "$src"/. "$dst"/` was
# refused on every essential file of that dir, the hold was kept and every tap answered ERR-NOTREADY: the game's
# downloaded content never came back (frankel 0.5.50). #media keeps deferring Android/data (Q114), so odrestore copies
# around the overlay: an entry the overlay serves is skipped, every other entry under a live target goes into the
# hidden real dir, and every entry outside the targets is copied to $dst as before.
#
# So this suite EXECUTES the real extracted odrestore arm and od_served_copy, under every shell found (the device's is
# mksh), against a temp /data tree, a $STATE/media-unders file and a simulated mount table. A stub cp, mkdir, chown
# and chcon refuse every write under a listed overlay target, as the kernel does through the overlay -- not chmod,
# which refuses nothing for a root CI runner. The overlay's VIEW is a plain dir at the target; the hidden real dir is
# a separate dir.
#   C1 served + unserved files under the target, files outside it   C2 C1 with no media-unders: today's cp FAILED
#   C3 a refused copy outside every target keeps the hold   C4a a target of another package whose name extends this
#   one   C4b files/Content against files/ContentDownload2   C5 the CE volume with a served dir: cp FAILED, as today
#   C6 no line names a file inside the app   C7 a held file the overlay does not show lands in the hidden dir
#   C8 a media-unders pair whose mounts are gone (mediad SIGKILLed): today's cp FAILED
#
#   bash test-odrestore-overlay-dst.sh              # the cases, under every shell found
#   bash test-odrestore-overlay-dst.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. The functions are EXTRACTED by anchor and re-rooted to a temp tree; every other helper is
# a stub (wait_acct_authenticator whole: it is never extracted).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, driver and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
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
CTX='u:object_r:media_rw_data_file:s0'

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 ODH PKGOK MIP SC SCR ARM ARMR n sh HARN="" R L V D T H X
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  has() { grep -qxF -- "$2" "$1"; }                       # has <file> <whole line>
  hasnt() { ! grep -qF -- "$2" "$1" 2>/dev/null; }        # hasnt <file> <substring>
  # no file name inside the app, and no path inside it, in <file>
  nonames() { ! grep -qE 'served\.bin|real\.bin|pass\.bin|bundle|catalog|other\.dat|p\.xml|secret|/files/' "$1"; }
  absent() { [ ! -e "$1" ]; }

  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  MIP=$(anchor_of "$f" 'mi_path() {')
  SC=$(anchor_of "$f" 'od_served_copy() {')
  ARM=$(arm_of "$f" odrestore)
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  case "$MIP" in *'sed -e'*) ;; *) echo "EXTRACTION FAILED: mi_path in $f" >&2; return 2 ;; esac
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  # od_served_copy is absent before NWP-20261121-02: define nothing, so the cases RUN against that code and fail.
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
    : > "$R/sim/owners"; : > "$R/sim/targets"; : > "$R/sim/refuse"; : > "$R/sim/calls"; : > "$R/sim/mountinfo"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    V="$R/data/media/$UID_/Android/data"
    D="$V/$PKG"
    X="$V/com.nowhere.chooser/.nowhere-odhold/$PKG"
    T="$D/files/ContentDownload"
    H="$R/data/user/$UID_/com.nowhere.chooser/files/.nowhere-media-ext/.under/ContentDownload"
  }
  plant() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }
  # overlay <target> <hidden> [live|dead] [published|unpublished]: a mediad overlay -- the target listed as one the
  # kernel refuses writes under, the pair in media-unders, and both paths in the mount table when live.
  overlay() {
    mkdir -p "$1" "$2"
    printf '%s\n' "$1" >> "$R/sim/targets"
    [ "${4:-published}" = published ] && printf '%s\t%s\n' "$1" "$2" >> "$R/state/media-unders"
    if [ "${3:-live}" = live ]; then
      printf '91 30 0:61 / %s rw,nosuid,nodev,noatime - fuse /dev/fuse rw,user_id=0,group_id=0\n' "$1" >> "$R/sim/mountinfo"
      printf '92 30 253:5 /media/0/x %s rw,nosuid,nodev,noatime - f2fs /dev/block/dm-5 rw\n' "$2" >> "$R/sim/mountinfo"
    fi
  }
  # the C1 tree: the hold carries the target dir with three unserved real files (one in a subdir), one name the
  # overlay serves, one real file the overlay passes through from the hidden dir, and two files outside the target.
  c1tree() {
    mkdir -p "$D"
    overlay "$T" "$H"
    plant "$T/served.bin" STUB                  # the overlay's view: a stub mediad serves
    plant "$T/pass.bin" OLDPASS; plant "$H/pass.bin" OLDPASS   # a real file passed through from hidden
    plant "$X/files/ContentDownload/bundle1.bin" B1
    plant "$X/files/ContentDownload/bundle2.bin" B2
    plant "$X/files/ContentDownload/cat/catalog.json" CAT
    plant "$X/files/ContentDownload/served.bin" HELD
    plant "$X/files/ContentDownload/pass.bin" NEWPASS
    plant "$X/files/other.dat" OTHER
    plant "$X/shared_prefs/p.xml" PREFS
  }
  driver() {
    local d="$R/driver.sh"
    {
      printf "ROOT='%s'\nLOG='%s'\nRES='%s'\nuid=%s\n" "$R" "$R/roam.log" "$R/res" "$UID_"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\nCTX='%s'\n" \
             "$R/data/user/$UID_" "$PKG" "$R/state" "$CTX"
      cat <<'EOF'
case "${KSH_VERSION:-}" in *MIRBSD*) ;; *) print() { while [ $# -gt 0 ]; do case "$1" in -r) shift ;; --) shift; break ;; *) break ;; esac; done; printf '%s\n' "$*"; } ;; esac
date() { echo DATE; }
restorecon() { :; }
am() { return 0; }
pidof() { :; }
pkg_live_pids() { :; }
reown_restored() { echo "reown $1" >> "$ROOT/sim/calls"; }
od_relabel() { echo "relabel $1 $2" >> "$ROOT/sim/calls"; }
cutoff_prog() { :; }
od_watched() { shift; "$@" 2>&1; }
grant_perms_for() { :; }
keystore_register() { :; }
reown_ext_appdata() { :; }
wait_acct_authenticator() { :; }
acct_reload() { :; }
sync_apply() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
# _ref <path>: 0 when the kernel would refuse a write at <path> -- a listed overlay target or under one (the trailing
# slash: files/ContentDownload2 is not under files/Content), or a path the case lists as refused.
_ref() {
  while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    case "$1" in "$_t"|"$_t"/*) return 0 ;; esac
  done <<_EOT
$(cat "$ROOT/sim/targets" "$ROOT/sim/refuse")
_EOT
  return 1
}
stat() {
  case "$2" in
    %C) echo "$CTX" ;;
    *) awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners" ;;
  esac
}
cp() {
  _s=$2; _d=${3%/}
  if _ref "$_d"; then echo "cp: '$_d/secret.bin': Permission denied" >&2; return 1; fi
  # `cp -a X/. D/`: refused when X holds an entry at the relative path of a refused path under D
  case "$_s" in */.)
    while IFS= read -r _t; do
      [ -n "$_t" ] || continue
      case "$_t" in "$_d"/*)
        if [ -e "${_s%/.}/${_t#"$_d"/}" ]; then
          echo "cp: '$_t/secret one.bin': Permission denied" >&2
          echo "cp: '$_t/secret two.bin': Permission denied" >&2
          return 1
        fi ;;
      esac
    done <<_EOT
$(cat "$ROOT/sim/targets" "$ROOT/sim/refuse")
_EOT
  esac
  command cp "$@"
}
mkdir() {
  for _a in "$@"; do
    case "$_a" in -*) continue ;; esac
    if _ref "$_a"; then [ -d "$_a" ] && continue; echo "mkdir: '$_a/secret': Permission denied" >&2; return 1; fi
  done
  command mkdir "$@"
}
chown() {
  eval "_l=\${$#}"
  echo "chown $*" >> "$ROOT/sim/calls"
  if _ref "$_l"; then echo "chown: '$_l/secret.bin': Permission denied" >&2; return 1; fi
  return 0
}
chcon() {
  eval "_l=\${$#}"
  echo "chcon $*" >> "$ROOT/sim/calls"
  if _ref "$_l"; then echo "chcon: '$_l/secret.bin': Permission denied" >&2; return 1; fi
  return 0
}
EOF
      printf '%s\n%s\n%s\n%s\n' "$ODH" "$PKGOK" "$MIP" "$SCR"
      printf 'case "$op" in\n%s\nesac\necho "$odn" > "$ROOT/sim/odn"\n' "$ARMR"
    } > "$d"
  }
  run() {  # run <sh>
    driver
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    local e
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found|parameter not set' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  res() { val "$R/res"; }
  ls1() { (cd "$1" 2>/dev/null && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' '); }

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh C1: served + unserved files under the target, files outside it =="
    mkroot; c1tree; run "$sh"
    chk "$L C1 bundle1.bin landed in the hidden dir" eqv "$(val "$H/bundle1.bin")" B1
    chk "$L C1 bundle2.bin landed in the hidden dir" eqv "$(val "$H/bundle2.bin")" B2
    chk "$L C1 cat/catalog.json landed in the hidden dir" eqv "$(val "$H/cat/catalog.json")" CAT
    chk "$L C1 the passed-through file took the hold's bytes" eqv "$(val "$H/pass.bin")" NEWPASS
    chk "$L C1 the served name was not copied into the hidden dir" absent "$H/served.bin"
    chk "$L C1 the overlay's view was not written" eqv "$(ls1 "$T")" "./pass.bin ./served.bin "
    chk "$L C1 the hidden dir took the app's owner" has "$R/sim/calls" "chown -R $OWNED:ext_data_rw $H"
    chk "$L C1 the hidden dir took its own context" has "$R/sim/calls" "chcon -h -R $CTX $H"
    chk "$L C1 other.dat landed in \$dst" eqv "$(val "$D/files/other.dat")" OTHER
    chk "$L C1 p.xml landed in \$dst" eqv "$(val "$D/shared_prefs/p.xml")" PREFS
    chk "$L C1 restored+reowned with 1 entry left served" has "$R/roam.log" \
        "[roamd] odrestore $PKG ($V) restored+reowned (1 entr(y/ies) left served by mediad) DATE"
    chk "$L C1 no cp FAILED" hasnt "$R/roam.log" "cp FAILED"
    chk "$L C1 the hold is removed" absent "$X"
    chk "$L C1 odn counted the volume" eqv "$(val "$R/sim/odn")" 1
    chk "$L C1 the reply is OK $PKG" eqv "$(res)" "OK $PKG"
    chk "$L C1 reown_restored ran on \$dst" has "$R/sim/calls" "reown $D"
    chk "$L C1 od_relabel ran on \$dst" has "$R/sim/calls" "relabel $V $D"
    chk "$L C6 (C1) no file name inside the app in roam.log" nonames "$R/roam.log"

    say "== $sh C2: C1 with no media-unders -> today's cp FAILED, hold kept =="
    mkroot; c1tree; rm -f "$R/state/media-unders"; run "$sh"
    chk "$L C2 cp FAILED -- hold KEPT" has "$R/roam.log" \
        "[roamd] WARN odrestore $PKG ($V) cp FAILED -- hold KEPT, NOT counted as restored (NWP-20260922-09) DATE (2 error line(s), last: Permission denied)"
    chk "$L C2 the hold is intact" eqv "$(ls1 "$X")" "./files ./files/ContentDownload ./files/ContentDownload/bundle1.bin ./files/ContentDownload/bundle2.bin ./files/ContentDownload/cat ./files/ContentDownload/cat/catalog.json ./files/ContentDownload/pass.bin ./files/ContentDownload/served.bin ./files/other.dat ./shared_prefs ./shared_prefs/p.xml "
    chk "$L C2 the reply is ERR-NOTREADY" eqv "$(res)" ERR-NOTREADY
    chk "$L C2 nothing went into the hidden dir" eqv "$(ls1 "$H")" "./pass.bin "
    chk "$L C6 (C2) no file name inside the app in roam.log" nonames "$R/roam.log"

    say "== $sh C3: a refused copy outside every target -> hold kept, ERR-NOTREADY =="
    mkroot; c1tree; printf '%s\n' "$D/files/other.dat" > "$R/sim/refuse"; run "$sh"
    chk "$L C3 cp FAILED -- hold KEPT" has "$R/roam.log" \
        "[roamd] WARN odrestore $PKG ($V) cp FAILED -- hold KEPT, NOT counted as restored (NWP-20260922-09) DATE (1 error line(s), last: Permission denied)"
    chk "$L C3 no restored+reowned for the volume" hasnt "$R/roam.log" "restored+reowned"
    chk "$L C3 the hold is intact" eqv "$(val "$X/files/other.dat")$(val "$X/files/ContentDownload/bundle1.bin")" OTHERB1
    chk "$L C3 the reply is ERR-NOTREADY" eqv "$(res)" ERR-NOTREADY
    chk "$L C3 odn did not count the volume" eqv "$(val "$R/sim/odn")" 0
    chk "$L C6 (C3) no file name inside the app in roam.log" nonames "$R/roam.log"

    say "== $sh C4a: the only target is another package's, whose name extends this one =="
    mkroot; mkdir -p "$D"
    local H2="$R/data/user/$UID_/com.nowhere.chooser/files/.nowhere-media-ext/.under/other"
    overlay "$V/${PKG}2/files" "$H2"
    plant "$X/files/other.dat" OTHER; plant "$X/shared_prefs/p.xml" PREFS
    run "$sh"
    chk "$L C4a today's restored+reowned line, byte for byte" has "$R/roam.log" "[roamd] odrestore $PKG ($V) restored+reowned DATE"
    chk "$L C4a no served count" hasnt "$R/roam.log" "left served by mediad"
    chk "$L C4a the other package's hidden dir was not touched" hasnt "$R/sim/calls" "$H2"
    chk "$L C4a other.dat landed in \$dst" eqv "$(val "$D/files/other.dat")" OTHER
    chk "$L C4a the reply is OK $PKG" eqv "$(res)" "OK $PKG"

    say "== $sh C4b: target files/Content against an entry under files/ContentDownload2 =="
    mkroot; mkdir -p "$D"
    local H3="$R/data/user/$UID_/com.nowhere.chooser/files/.nowhere-media-ext/.under/Content"
    overlay "$D/files/Content" "$H3"
    plant "$X/files/ContentDownload2/x" XBYTES
    run "$sh"
    chk "$L C4b x landed in \$dst/files/ContentDownload2" eqv "$(val "$D/files/ContentDownload2/x")" XBYTES
    chk "$L C4b nothing went into the hidden dir" eqv "$(ls1 "$H3")" ""
    chk "$L C4b no cp FAILED" hasnt "$R/roam.log" "cp FAILED"
    chk "$L C4b the reply is OK $PKG" eqv "$(res)" "OK $PKG"
    chk "$L C6 (C4b) no file name inside the app in roam.log" nonames "$R/roam.log"

    say "== $sh C5: the CE volume with a served dir -> cp FAILED, as today =="
    mkroot
    local CD="$R/data/user/$UID_/$PKG" CX="$R/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG"
    local H4="$R/data/user/$UID_/com.nowhere.chooser/files/.nowhere-media-ce/.under/Logs"
    mkdir -p "$CD"; echo "$CD $OWNED" > "$R/sim/owners"
    overlay "$CD/files/Logs" "$H4"
    plant "$CX/files/Logs/a.log" LOGBYTES
    run "$sh"
    chk "$L C5 the CE volume logs cp FAILED" has "$R/roam.log" \
        "[roamd] WARN odrestore $PKG ($R/data/user/$UID_) cp FAILED -- hold KEPT, NOT counted as restored (NWP-20260922-09) DATE (2 error line(s), last: Permission denied)"
    chk "$L C5 the helper never ran for CE" hasnt "$R/sim/calls" "$H4"
    chk "$L C5 nothing went into the hidden dir" eqv "$(ls1 "$H4")" ""
    chk "$L C5 the CE hold is intact" eqv "$(val "$CX/files/Logs/a.log")" LOGBYTES
    chk "$L C5 the reply is ERR-NOTREADY" eqv "$(res)" ERR-NOTREADY

    say "== $sh C7: a held file the overlay does not show lands in the hidden dir, never dropped =="
    mkroot; mkdir -p "$D"
    overlay "$T" "$H"
    plant "$T/served.bin" STUB
    plant "$X/files/ContentDownload/served.bin" HELD
    plant "$X/files/ContentDownload/real.bin" REAL
    run "$sh"
    chk "$L C7 real.bin landed in the hidden dir" eqv "$(val "$H/real.bin")" REAL
    chk "$L C7 the hidden dir took the app's owner" has "$R/sim/calls" "chown -R $OWNED:ext_data_rw $H"
    chk "$L C7 restored+reowned with 1 entry left served" has "$R/roam.log" \
        "[roamd] odrestore $PKG ($V) restored+reowned (1 entr(y/ies) left served by mediad) DATE"
    chk "$L C7 the reply is OK $PKG" eqv "$(res)" "OK $PKG"
    chk "$L C6 (C7) no file name inside the app in roam.log" nonames "$R/roam.log"

    say "== $sh C8: media-unders lists a target whose mounts are gone -> today's cp FAILED =="
    mkroot; mkdir -p "$D"
    overlay "$T" "$H" dead
    plant "$X/files/ContentDownload/real.bin" REAL
    run "$sh"
    chk "$L C8 cp FAILED -- hold KEPT" has "$R/roam.log" \
        "[roamd] WARN odrestore $PKG ($V) cp FAILED -- hold KEPT, NOT counted as restored (NWP-20260922-09) DATE (2 error line(s), last: Permission denied)"
    chk "$L C8 the hold is intact" eqv "$(val "$X/files/ContentDownload/real.bin")" REAL
    chk "$L C8 nothing went into the hidden dir" eqv "$(ls1 "$H")" ""
    chk "$L C8 the reply is ERR-NOTREADY" eqv "$(res)" ERR-NOTREADY
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST be convicted under EACH shell's own line) =="
MF=0
mutate() {  # mutate <id> <label> <sed expr>
  local id="$1" label="$2" expr="$3" m out mrc nch s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! sed "$expr" "$SUT" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION BROKEN (sed): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  nch=$(diff "$SUT" "$m" | grep -c '^<')
  if [ "$nch" != 1 ]; then echo "  FAIL  MUTATION TOUCHES $nch lines, want 1: $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /'; MF=$((MF+1)); return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] "*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted: $id $label"; fi
}
mutate M1 "the served filter ignored: a served name is copied like any other (C1)" \
       's#^      elif { \[ -e "\$t/\$rt" \] || \[ -L "\$t/\$rt" \]; } && ! { \[ -e "\$h/\$rt" \] || \[ -L "\$h/\$rt" \]; }; then$#      elif false; then#'
mutate M2 "every refused copy counted restored (C3)" \
       '/^od_served_copy() {$/,/^}$/s#^  return "\$rc"$#  return 0#'
mutate M3 "media-unders read for CE too (C5)" \
       's#^          /data/media/\*)$#          *)#'
mutate M4a "the DST prefix matched without its trailing slash (C4a)" \
       's#case "\$t" in "\$dst"|"\$dst"/\*)#case "$t" in "$dst"|"$dst"*)#'
mutate M4b "the target prefix matched without its trailing slash (C4b)" \
       's#case "\$full" in "\$t"|"\$t"/\*)#case "$full" in "$t"|"$t"*)#'
mutate M5 "every entry under a target skipped as served (C7)" \
       's#^      elif { \[ -e "\$t/\$rt" \] || \[ -L "\$t/\$rt" \]; } && ! { \[ -e "\$h/\$rt" \] || \[ -L "\$h/\$rt" \]; }; then$#      elif true; then#'
mutate M6 "a media-unders pair taken without its live mounts (C8)" \
       's#^    \[ -n "\$ts" \] && \[ -n "\$hs" \] && pairs=#    pairs=#'

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
