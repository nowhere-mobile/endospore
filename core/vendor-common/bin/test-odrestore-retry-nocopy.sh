#!/usr/bin/env bash
# test-odrestore-retry-nocopy.sh [<nowhere_roamd.sh>] [--mutate] -- an odrestore retried after a stop in its hand-back
# copies only what the app's dir lacks (NWP-20261204-04).
#
# WHY THIS IS COMMITTED. The backlog row "An app with a large data hold never gets its data back: its odrestore goes
# silent for 150 s after the copy, the daemon gives up and stops it, the hold is kept, and every retry copies the whole
# hold again". The daemon stops an odrestore it gave up on (decision 2026-11-01). A stop in the label step (the copy
# returned 0, the hold not yet dropped) leaves the full hold beside a full, app-owned destination, and every retry ran
# `cp -a` over the whole hold again. The arm now writes a session record `<inode of $dst> <$dst>` to
# $STATE/.odcopied.<uid> after a plain copy returned 0 and before the label step; a retry that finds its own line with
# the destination's CURRENT inode copies with `cp -a -n`. This suite EXECUTES the real extracted arm under every shell
# found (the device's is mksh), with a `cp` shim first in PATH that does `-a` and `-n` itself and logs its argv, so the
# host's coreutils version does not matter:
#   R1 a first attempt stopped inside reown_restored: the hold is still there, the record is exactly `<inode> <dst>`
#   R2 the retry over R1's state: cp ran with -n, a file the destination holds keeps its bytes, a file only the hold
#      has lands, the hold is gone, the record line is gone, the reply is OK <pkg>, the new log line names (ce)
#   R3 the record names another inode: cp ran without -n and the hold's bytes overwrite the destination's
#   R4 no record: today's `cp -a <src>/. <dst>/`, the reply is OK, no record is left
#   R5 the copy fails: no record line, the hold is kept, the reply is ERR-NOTREADY; R5b a record line is present and
#      the -n copy fails: the line stays, the hold is kept
#   R6 the new log line names neither the package nor a path
#   R7 source: the `in` op and the cleanstorage per-uid record line each remove .odcopied.$uid
#
#   bash test-odrestore-retry-nocopy.sh              # the cases, under every shell found
#   bash test-odrestore-retry-nocopy.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. The arm is EXTRACTED by anchor and re-rooted to a temp tree. The handset's toybox
# `cp -a -n` is not exercised here: that is the merger's handset follow-up.
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
OWNED=$((UID_ * 100000 + APPID))

# The cp shim: logs its argv to $ROOT/sim/cpargv, fails when $ROOT/sim/cp-fail exists, else copies SRC/. into DST/
# with -a (required) and -n (never overwrite an existing file). It uses no host cp.
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
src=${1%/.}; dst=${2%/}
cd "$src" || exit 1
find . -type d | while IFS= read -r d; do mkdir -p "$dst/$d"; done
find . -type f | while IFS= read -r f; do
  if [ "$n" = 1 ] && [ -e "$dst/$f" ]; then continue; fi
  cat "$f" > "$dst/$f"
done
exit 0
EOF
chmod +x "$W/bin/cp"

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
op_of() { sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"; }
live() { sed -E 's/(^|[[:space:]])#.*$//'; }
nleft() { printf '%s\n' "$1" | live | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 ODH PKGOK ARM ARMR INOP REAP n sh L R HARN="" ino dst got
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
  ARM=$(arm_of "$f" odrestore)
  INOP=$(arm_of "$f" in | live)
  REAP=$(op_of "$f" cleanstorage | grep -F '# NWP-20261128-36' | grep -F 'rm -f')
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  case "$INOP" in *'rm -f "$STATE/.declined.$uid"'*) ;; *) echo "EXTRACTION FAILED: the in op in $f" >&2; return 2 ;; esac
  case "$REAP" in *'"$STATE/.odbatch3.$uid".*'*) ;; *) echo "EXTRACTION FAILED: the cleanstorage per-uid record line in $f" >&2; return 2 ;; esac
  ARMR=$(printf '%s\n' "$ARM" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
  n=$(printf '%s\n' "$ARMR" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$ARMR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" "$R/data/user_de/$UID_" \
             "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/trace"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
  }
  # plant <vol>: a hold for $PKG on that volume (a.txt "hold-a", b.txt "hold-b"), with an app-owned (empty) destination
  plant() {
    mkdir -p "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files" "$R/data/$1/$PKG"
    echo hold-a > "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files/a.txt"
    echo hold-b > "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files/b.txt"
    echo "$R/data/$1/$PKG $OWNED" >> "$R/sim/owners"
  }
  # driver <root>: stubs + the extracted text, written to a FILE for the shell
  driver() {
    {
      printf "ROOT='%s'\nexport ROOT\nPATH='%s':\$PATH\nLOG='%s'\nRES='%s'\nT='%s'\nuid=%s\n" "$1" "$W/bin" "$1/roam.log" "$1/res" "$1/trace" "$UID_"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\n" \
             "$1/data/user/$UID_" "$PKG" "$1/state"
      printf 'unset NOWHERE_PROGRESS\n'
      cat <<'EOF'
date() { echo DATE; }
restorecon() { :; }
cutoff_prog() { :; }
od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }
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
# stat: -c %u answers the planted owner; -c %i the real inode (rc 1 when sim/inode-fail exists)
stat() {
  case "$2" in
    %i) [ ! -f "$ROOT/sim/inode-fail" ] || return 1; command stat -c %i "$3" ;;
    *) awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners" ;;
  esac
}
# reown_restored: a stop here (the daemon's ctl.stop) is the driver exiting, as SIGKILL ends the op
reown_restored() {
  echo "reown $1" >> "$T"
  [ ! -f "$ROOT/sim/stop-at-reown" ] || exit 9
}
od_relabel() { echo "relabel $2" >> "$T"; }
od_label_watched() { reown_restored "$2"; od_relabel "$1" "$2"; }   # NOWHERE-1782's spelling of the label pair
od_watched() { shift; "$@" 2>&1; }
EOF
      printf '%s\n%s\n' "$ODH" "$PKGOK"
      printf 'case "$op" in\n%s\nesac\n' "$ARMR"
    } > "$1/driver.sh"
  }
  run() {  # run <sh>
    local e
    rm -f "$R/res" "$R/sim/cpargv"
    driver "$R"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found|cp shim' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { if [ -f "$1" ]; then cat "$1"; else echo -; fi; }
  CE="user/$UID_"; DE="user_de/$UID_"
  hold() { echo "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG"; }
  rec() { echo "$R/state/.odcopied.$UID_"; }
  newline() { grep -F 'copy already finished this session' "$R/roam.log" 2>/dev/null || true; }

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh R1: a first attempt stopped inside reown_restored -> the hold stays, the record holds <inode> <dst> =="
    mkroot; plant "$CE"; : > "$R/sim/stop-at-reown"
    dst="$R/data/$CE/$PKG"; ino=$(command stat -c %i "$dst")
    run "$sh"
    chk "$L R1 the hold's file is still there" eqv "$(val "$(hold "$CE")/files/a.txt")" hold-a
    chk "$L R1 no reply was written" absent "$R/res"
    chk "$L R1 the record is exactly '<inode> <dst>'" eqv "$(val "$(rec)")" "$ino $dst"

    say "== $sh R2: the retry over R1's state -> cp -a -n, the destination's files kept, the rest filled, the line gone =="
    rm -f "$R/sim/stop-at-reown"
    echo app-new > "$dst/files/a.txt"; rm -f "$dst/files/b.txt"
    run "$sh"
    got=$(val "$R/sim/cpargv")
    chk "$L R2 cp ran once, with -n" eqv "$got" "-a -n $(hold "$CE")/. $dst/"
    chk "$L R2 a file the destination holds keeps its bytes" eqv "$(val "$dst/files/a.txt")" app-new
    chk "$L R2 a file only the hold has lands" eqv "$(val "$dst/files/b.txt")" hold-b
    chk "$L R2 the hold is gone" absent "$(hold "$CE")"
    chk "$L R2 the record line is gone (no record left)" absent "$(rec)"
    chk "$L R2 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    got=$(newline)
    chk "$L R2 roam.log holds the new line once, with (ce)" eqv "$got" "[roamd] odrestore: copy already finished this session on this volume (ce) -- copying only what the destination lacks (NWP-20261204-04) DATE"

    say "== $sh R6: the new log line names neither the package nor a path =="
    chk "$L R6 the new line was written" test -n "$got"
    chk "$L R6 the new line does not name the package" hasnt "$got" "$PKG"
    chk "$L R6 the new line does not name a path" hasnt "$got" /

    say "== $sh R3: the record names another inode -> the plain cp -a, the hold's bytes overwrite =="
    mkroot; plant "$CE"
    dst="$R/data/$CE/$PKG"; ino=$(command stat -c %i "$dst")
    mkdir -p "$dst/files"; echo app-new > "$dst/files/a.txt"
    echo "$((ino + 1)) $dst" > "$(rec)"
    run "$sh"
    got=$(val "$R/sim/cpargv")
    chk "$L R3 cp ran without -n" eqv "$got" "-a $(hold "$CE")/. $dst/"
    chk "$L R3 the hold's bytes overwrite the destination's" eqv "$(val "$dst/files/a.txt")" hold-a
    chk "$L R3 no new log line" eqv "$(newline)" ""
    chk "$L R3 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"

    say "== $sh R4: no record -> today's cp -a, no record left =="
    mkroot; plant "$CE"
    dst="$R/data/$CE/$PKG"
    run "$sh"
    chk "$L R4 cp ran as today" eqv "$(val "$R/sim/cpargv")" "-a $(hold "$CE")/. $dst/"
    chk "$L R4 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"
    chk "$L R4 no record is left" absent "$(rec)"
    chk "$L R4 the data landed" eqv "$(val "$dst/files/b.txt")" hold-b

    say "== $sh R5: the copy fails -> no record line, the hold is kept =="
    mkroot; plant "$CE"; : > "$R/sim/cp-fail"
    run "$sh"
    chk "$L R5 no record is written" absent "$(rec)"
    chk "$L R5 the hold is kept" eqv "$(val "$(hold "$CE")/files/a.txt")" hold-a
    chk "$L R5 the reply is ERR-NOTREADY" eqv "$(val "$R/res")" ERR-NOTREADY

    say "== $sh R5b: a record line is present and the -n copy fails -> the line stays, the hold is kept =="
    mkroot; plant "$CE"; : > "$R/sim/cp-fail"
    dst="$R/data/$CE/$PKG"; ino=$(command stat -c %i "$dst")
    echo "$ino $dst" > "$(rec)"
    run "$sh"
    chk "$L R5b cp ran with -n" eqv "$(val "$R/sim/cpargv")" "-a -n $(hold "$CE")/. $dst/"
    chk "$L R5b the record line stays" eqv "$(val "$(rec)")" "$ino $dst"
    chk "$L R5b the hold is kept" eqv "$(val "$(hold "$CE")/files/a.txt")" hold-a
    chk "$L R5b the reply is ERR-NOTREADY" eqv "$(val "$R/res")" ERR-NOTREADY

    say "== $sh R8: a DE retry -> the new line names (de); an unreadable inode -> the plain cp -a =="
    mkroot; plant "$DE"
    dst="$R/data/$DE/$PKG"; ino=$(command stat -c %i "$dst")
    echo "$ino $dst" > "$(rec)"
    run "$sh"
    chk "$L R8 the new line names (de)" has "$(newline)" "on this volume (de) --"
    mkroot; plant "$CE"; : > "$R/sim/inode-fail"
    dst="$R/data/$CE/$PKG"
    echo " $dst" > "$(rec)"
    run "$sh"
    chk "$L R8 an unreadable inode runs the plain cp -a" eqv "$(val "$R/sim/cpargv")" "-a $(hold "$CE")/. $dst/"

    say "== $sh R7: source -- the in op and the reap clear .odcopied.\$uid =="
    chk "$L R7 the in op removes .odcopied.\$uid" has "$INOP" 'rm -f "$STATE/.odcopied.$uid"'
    chk "$L R7 the cleanstorage per-uid record line removes .odcopied.\$uid" has "$REAP" '"$STATE/.odcopied.$uid"'
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
L_WRITE='        if [ "$_odpl:$_odsc" = 1:0 ] && [ -n "${STATE:-}" ]; then'
L_REMOVE='          if [ ! -e "$src" ] && [ -n "$_odin" ] && [ -f "$STATE/.odcopied.$uid" ]'
L_RELAB='          od_relabel "$vol" "$dst"'
L_LABW='          od_label_watched "$vol" "$dst"'
# move_write: the write block (its `if` to the next `        fi`) moved to after the success branch's label step
move_write() {
  awk -v W="$L_WRITE" -v A="$L_RELAB" -v B="$L_LABW" '
    $0 == "  odrestore)" { arm = 1 }
    arm && /^    ;;$/ { arm = 0 }
    arm && !done && $0 == W { inb = 1 }
    inb { blk[++nb] = $0; if ($0 == "        fi") { inb = 0; done = 1 }; next }
    { print }
    arm && done && !put && ($0 == A || $0 == B) { for (i = 1; i <= nb; i++) print blk[i]; put = 1 }
  ' "$SUT"
}
# drop_remove: the remove block (its `if` to the next `          fi`) deleted
drop_remove() {
  awk -v D="$L_REMOVE" '
    index($0, D) == 1 { inb = 1 }
    inb { if ($0 == "          fi") inb = 0; next }
    { print }
  ' "$SUT"
}
# sub1 <from> <to>: the first line holding <from> gets <to> in its place ("" with a whole-line <from> deletes it)
sub1() {
  awk -v a="$1" -v b="$2" '
    !done && (i = index($0, a)) { done = 1; if (b == "#line") next; $0 = substr($0, 1, i - 1) b substr($0, i + length(a)) }
    { print }
  ' "$SUT"
}
MF=0
mutate() {  # mutate <id> <convicting case> <label> <cmd...>
  local id="$1" by="$2" label="$3" m out mrc s miss=""
  shift 3
  m=$(mktemp -p "$W") || exit 2
  if ! "$@" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION BROKEN (awk): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /'; MF=$((MF+1)); return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] $by "*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED by $by under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted by $by under ${SHELLS[*]}: $id $label"; fi
}
mutate m1 R1 "the record is written after the label step" move_write
mutate m2 R2 "the retry drops -n" sub1 'cp -a -n "$src"' 'cp -a "$src"'
mutate m3 R3 "the retry ignores the inode" sub1 'grep -qxF -- "$_odin $dst" "$STATE/.odcopied.$uid" 2>/dev/null; then' 'grep -q -- " $dst\$" "$STATE/.odcopied.$uid" 2>/dev/null; then'
mutate m4 R5 "the record is written on a failed copy" sub1 'if [ "$_odpl:$_odsc" = 1:0 ]' 'if [ "$_odpl" = 1 ]'
mutate m5 R2 "the record line is not removed after the hold is dropped" drop_remove
mutate m6 R6 "the new log line names the package" sub1 'on this volume ($_odvn)' 'on this volume ($_odvn $pkg)'
mutate m7 R7 "the in op no longer clears the record" sub1 '      rm -f "$STATE/.odcopied.$uid" 2>>"$LOG"' '#line'

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
