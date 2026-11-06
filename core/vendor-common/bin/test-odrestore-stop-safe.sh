#!/usr/bin/env bash
# test-odrestore-stop-safe.sh [<nowhere_roamd.sh>] [--mutate] -- the odrestore arm drops a hold only AFTER its copy is
# reowned and relabelled, and writes one progress line per held volume (NWP-20261119-09).
#
# WHY THIS IS COMMITTED. The 2026-11-01 decision has the login daemon stop a worker op it gave up on. The arm's
# success branch used to run cp, then `rm -rf` of the hold, and only then reown_restored and od_relabel. A stop
# during the rm, or between it and the reown, left the app's data dir owned by the hold's owner (root) with the hold
# gone or partial: the next odrestore found no full hold and never reowned it, so the app could not read its own
# data this session. The arm also wrote no progress, so the daemon's 150 s stall clock counted all four volumes as
# one silence. This suite EXECUTES the real extracted arm under every shell found (the device's is mksh), records
# the order of cp / reown_restored / od_relabel / rm through stubs, and runs the REAL cutoff_prog:
#   O1 a clean copy: the order is cp, reown, relabel, rm; the hold is gone; the reply is OK <pkg>
#   O2 a failed copy: cp, reown, relabel, no rm; the hold is kept; the reply is ERR-NOTREADY
#   P1 NOWHERE_PROGRESS set, holds on CE and DE: a NEW progress line before each copy, no package name, no .tmp left
#   P2 NOWHERE_PROGRESS set, a hold on CE only: exactly one progress line
#   P3 NOWHERE_PROGRESS unset: no progress file and no .tmp
#   S1 a stop inside reown_restored (the stub exits the driver): the hold is still in place, no rm ran
#
# ⚠ It does NOT pin the one window the reorder leaves (a stop after the copy and before reown_restored changes the
# destination's top-level owner): that is recorded at the reorder in roamd and in docs/backlog.md.
#
#   bash test-odrestore-stop-safe.sh              # the cases, under every shell found
#   bash test-odrestore-stop-safe.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. The arm and cutoff_prog are EXTRACTED by anchor and re-rooted to a temp tree.
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

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 ODH ARM ARMR PROG n sh L R HARN=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  nopkg() { ! grep -qF -- "$PKG" "$1" 2>/dev/null; }

  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  ARM=$(arm_of "$f" odrestore)
  PROG=$(anchor_of "$f" 'cutoff_prog() {')
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$ARM" in *'echo "ERR-PKG" > "$RES"'*'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  case "$PROG" in *'NOWHERE_PROGRESS.tmp'*'mv -f'*) ;; *) echo "EXTRACTION FAILED: cutoff_prog in $f" >&2; return 2 ;; esac
  ARMR=$(printf '%s\n' "$ARM" | sed -E 's#([" |])/data/#\1$ROOT/data/#g')
  n=$(printf '%s\n' "$ARMR" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 8 ] || { echo "RE-ROOT FAILED: the odrestore arm has $n rewritten paths, want >= 8" >&2; return 2; }
  n=$(nleft "$ARMR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: the odrestore arm keeps $n absolute /data path(s) in live code" >&2; return 2; }

  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/data/system" "$R/data/nowhere" "$R/data/user/$UID_" "$R/data/user_de/$UID_" \
             "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/trace"; : > "$R/seen"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
  }
  # plant <vol>: a hold for $PKG on that volume, with an app-owned (empty) destination
  plant() {
    mkdir -p "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files" "$R/data/$1/$PKG"
    echo payload > "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG/files/f.txt"
    echo "$R/data/$1/$PKG $OWNED" >> "$R/sim/owners"
  }
  # driver <root> <cp: ok|fail> <progress: set|unset>: stubs + the extracted text, written to a FILE for the shell
  driver() {
    {
      printf "ROOT='%s'\nLOG='%s'\nRES='%s'\nT='%s'\nuid=%s\n" "$1" "$1/roam.log" "$1/res" "$1/trace" "$UID_"
      printf "USERDIR='%s'\nop=odrestore\nsrcunit=%s\nSTATE='%s'\nACCT_AUTH_PKG=com.example.authenticator\nCPMODE=%s\n" \
             "$1/data/user/$UID_" "$PKG" "$1/state" "$2"
      if [ "$3" = set ]; then printf "NOWHERE_PROGRESS='%s'\n" "$1/prog"; else printf 'unset NOWHERE_PROGRESS\n'; fi
      cat <<'EOF'
date() { echo DATE; }
restorecon() { :; }
am() { return 0; }
pidof() { :; }
pkg_live_pids() { :; }
grant_perms_for() { :; }
keystore_register() { :; }
# pm: an app with code -- `list packages -U ... <pkg>` lists the package's own line (the arm's NWP-20261122-03 read)
pm() { case "$*" in "list packages -U "*) echo "package:$srcunit uid:1110234" ;; esac; return 0; }
reown_ext_appdata() { :; }
wait_acct_authenticator() { :; }
acct_reload() { :; }
sync_apply() { :; }
a11y_apply() { :; }
autofill_apply() { :; }
stat() { awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$ROOT/sim/owners"; }
# cp: record the call and the progress file's line at that instant ("-" when there is none), then copy or fail
cp() {
  echo cp >> "$T"
  if [ -f "$ROOT/prog" ]; then cat "$ROOT/prog" >> "$ROOT/seen"; else echo - >> "$ROOT/seen"; fi
  case "$CPMODE" in
    fail) echo "cp: x: Permission denied" >&2; return 1 ;;
    *) command cp -R "$2" "$3" ;;
  esac
}
# reown_restored: a stop here (the daemon's ctl.stop) is the driver exiting, as SIGKILL ends the op
reown_restored() {
  echo "reown $1" >> "$T"
  [ ! -f "$ROOT/sim/stop-at-reown" ] || exit 9
}
od_relabel() { echo "relabel $2" >> "$T"; }
od_watched() { shift; "$@" 2>&1; }
rm() {
  case "$1" in -rf) echo rm >> "$T" ;; esac
  command rm "$@"
}
EOF
      printf '%s\n%s\n' "$ODH" "$PROG"
      printf 'case "$op" in\n%s\nesac\n' "$ARMR"
    } > "$1/driver.sh"
  }
  run() {  # run <sh> <cp mode> <progress>
    local e
    driver "$R" "$2" "$3"
    "$1" "$R/driver.sh" >/dev/null 2>"$R/sim/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$R/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  order() { grep -E '^(cp|reown|relabel|rm)( |$)' "$R/trace"; }
  CE="user/$UID_"; DE="user_de/$UID_"
  hold() { echo "$R/data/$1/com.nowhere.chooser/.nowhere-odhold/$PKG"; }

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh O1: a clean copy -> cp, reown, relabel, then the hold is dropped =="
    mkroot; plant "$CE"
    run "$sh" ok unset
    chk "$L O1 the order is cp, reown, relabel, rm" eqv "$(order)" "cp
reown $R/data/$CE/$PKG
relabel $R/data/$CE/$PKG
rm"
    chk "$L O1 the hold is dropped" absent "$(hold "$CE")"
    chk "$L O1 the data landed" eqv "$(val "$R/data/$CE/$PKG/files/f.txt")" payload
    chk "$L O1 the reply is OK $PKG" eqv "$(val "$R/res")" "OK $PKG"

    say "== $sh O2: a failed copy -> reown and relabel still run, the hold is kept =="
    mkroot; plant "$CE"
    run "$sh" fail unset
    chk "$L O2 the order is cp, reown, relabel, no rm" eqv "$(order)" "cp
reown $R/data/$CE/$PKG
relabel $R/data/$CE/$PKG"
    chk "$L O2 the hold is kept" eqv "$(val "$(hold "$CE")/files/f.txt")" payload
    chk "$L O2 the reply is ERR-NOTREADY" eqv "$(val "$R/res")" ERR-NOTREADY

    say "== $sh P1: NOWHERE_PROGRESS set, holds on CE and DE -> a new line before each copy =="
    mkroot; plant "$CE"; plant "$DE"
    run "$sh" ok set
    chk "$L P1 the progress line changed before each of the two copies" eqv "$(cat "$R/seen")" "cutoff od 1
cutoff od 2"
    chk "$L P1 the progress file holds the last line only" eqv "$(val "$R/prog")" "cutoff od 2"
    chk "$L P1 no progress .tmp is left" absent "$R/prog.tmp"
    chk "$L P1 no progress line names the package" nopkg "$R/seen"
    chk "$L P1 both holds dropped" eqv "$([ -e "$(hold "$CE")" ] || [ -e "$(hold "$DE")" ] && echo kept || echo gone)" gone

    say "== $sh P2: NOWHERE_PROGRESS set, a hold on CE only -> exactly one line =="
    mkroot; plant "$CE"
    run "$sh" ok set
    chk "$L P2 one progress line, before the copy" eqv "$(cat "$R/seen")" "cutoff od 1"
    chk "$L P2 the progress file holds it" eqv "$(val "$R/prog")" "cutoff od 1"

    say "== $sh P3: NOWHERE_PROGRESS unset -> no progress file =="
    mkroot; plant "$CE"; plant "$DE"
    run "$sh" ok unset
    chk "$L P3 no progress file" absent "$R/prog"
    chk "$L P3 no progress .tmp" absent "$R/prog.tmp"

    say "== $sh S1: the op is stopped inside reown_restored -> the hold is still in place =="
    mkroot; plant "$CE"; : > "$R/sim/stop-at-reown"
    run "$sh" ok unset
    chk "$L S1 the hold's file is still there" eqv "$(val "$(hold "$CE")/files/f.txt")" payload
    chk "$L S1 no rm ran before the stop" eqv "$(grep -c '^rm$' "$R/trace")" 0
    chk "$L S1 no reply was written" absent "$R/res"
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
L_CP='        if [ "$_odsc" = 0 ]; then'
L_RM='          rm -rf "$src" 2>/dev/null'
L_WARN='          [ -e "$src" ] && echo "[roamd] WARN odrestore $pkg ($vol) could not remove all of the hold'
L_REOWN='          reown_restored "$dst"'
L_RELAB='          od_relabel "$vol" "$dst"'
L_PROG='      cutoff_prog od '
L_LOOP='    odn=0; odsrc=0; odkept=0'
# xform <order> <prog>: the arm with its success branch's reown (R), relabel (L), rm (D) and WARN (N) lines put back in
# <order> after the branch's comment lines; prog=keep|drop|hoist moves the cutoff_prog line. Outside the arm, nothing.
xform() {
  awk -v ORD="$1" -v PM="$2" -v CP="$L_CP" -v RM="$L_RM" -v WN="$L_WARN" -v RO="$L_REOWN" -v RL="$L_RELAB" \
      -v PG="$L_PROG" -v LP="$L_LOOP" '
    $0 == "  odrestore)" { arm = 1 }
    arm && /^    ;;$/ { arm = 0 }
    arm && index($0, PG) == 1 { if (PM != "keep") next }
    arm && blk && $0 == "        else" {
      for (i = 1; i <= nc; i++) print com[i]
      for (i = 1; i <= length(ORD); i++) { k = substr(ORD, i, 1); if (k in ln) print ln[k] }
      for (i = 1; i <= nt; i++) print tl[i]
      blk = 0; print; next
    }
    arm && blk {
      if ($0 ~ /^ *#/ && nt == 0 && !(("R") in ln)) { com[++nc] = $0; next }
      if ($0 == RO) { ln["R"] = $0; next }
      if ($0 == RL) { ln["L"] = $0; next }
      if ($0 == RM) { ln["D"] = $0; next }
      if (index($0, WN) == 1) { ln["N"] = $0; next }
      tl[++nt] = $0; next
    }
    { print }
    arm && $0 == CP { blk = 1 }
    arm && $0 == LP && PM == "hoist" { print "      cutoff_prog od" }
  ' "$SUT"
}
MF=0
mutate() {  # mutate <id> <label> <order> <prog>
  local id="$1" label="$2" m out mrc s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! xform "$3" "$4" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION BROKEN (awk): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; printf '%s\n' "$out" | sed 's/^/          /'; MF=$((MF+1)); return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] "*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted: $id $label"; fi
}
# The control: the transform with today's order and the progress line kept must reproduce roamd byte for byte.
c=$(mktemp -p "$W") || exit 2
xform RLDN keep > "$c"
cmp -s "$SUT" "$c" || { echo "  FAIL  the transform does not reproduce $SUT with today's order (the anchors moved)"; MF=$((MF+1)); }
mutate m1 "the hold is dropped before the reown again" DNRL keep
mutate m2 "the relabel runs after the hold is dropped" RDNL keep
mutate m3 "the progress call is removed" RLDN drop
mutate m4 "the progress call is moved out of the loop, above it" RLDN hoist

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
