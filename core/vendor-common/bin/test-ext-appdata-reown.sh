#!/usr/bin/env bash
# test-ext-appdata-reown.sh [<nowhere_roamd.sh>] [--mutate] -- remap_tree and reown_ext_appdata, the root-run
# ownership of the shared media tree and of an app's EXTERNAL app-private data, at every sign-in and every
# on-demand tap (NWP-20261021-16).
#
# WHY THIS IS COMMITTED. restore_media_tail calls both at every sign-in and the odrestore arm calls
# reown_ext_appdata at every on-demand tap, and every suite that reaches them stubs them
# (test-restore-tail-progress.sh, test-odrestore-ext-reown.sh, test-in-refused-noop.sh, test-userdir-orphan.sh).
# Their bodies were executed by nothing. The rules they carry:
#   remap_tree          the whole /data/media/<uid> tree is chowned -R to the owner `stat` reports for the dir
#                       (media_rw), and nothing happens when stat gives nothing numeric;
#   reown_ext_appdata   the per-package re-own that undoes remap_tree for Android/{data,obb}/<pkg>: -R to
#                       uid*100000+appId, group ext_data_rw for data and ext_obb_rw for obb, appId taken from the
#                       first line of packages.list whose FIRST FIELD is exactly <pkg> (an exact string, not a
#                       regex, since NWP-20261111-11: a look-alike listed earlier took the chown), rc 1 when it is
#                       unresolvable, locals scoped. Without it a Unity/il2cpp game reads files/il2cpp/unity.ver
#                       as EACCES and never starts after a roam (DIA-20260730);
#   S1 (source, once)   roamd holds no `grep -m1 "^$<var> " /data/system/packages.list` lookup left and exactly four
#                       exact awk lookups (reown_restored, reown_ext_appdata, odrestore's hold check, NWP-20261111-22;
#                       od_served_copy's owner, NWP-20261121-02).
#
#   bash test-ext-appdata-reown.sh              # the cases, under every shell present (bash, sh, dash, mksh)
#   bash test-ext-appdata-reown.sh --mutate     # ... plus mutants of roamd that must each CONVICT
#
# Pure logic -- no device, no root. Both functions are EXTRACTED by anchor, never copied, and re-rooted to a temp
# tree. The directories and packages.list are REAL; `stat` answers from a fake owner table and `chown` logs argv.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# The run's one temp root: every case tree and every mutant copy is made inside it.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

# S1's exact lookup, the tail every packages.list read in roamd shares.
LOOKUP=' awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 RT RE FNS n c sh T D HARN=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }

  RT=$(fn_of "$f" remap_tree)
  RE=$(fn_of "$f" reown_ext_appdata)
  [ -n "$RT" ] || { echo "EXTRACTION FAILED: function remap_tree not found in $f" >&2; return 2; }
  [ -n "$RE" ] || { echo "EXTRACTION FAILED: function reown_ext_appdata not found in $f" >&2; return 2; }
  case "$RE" in *'/data/system/packages.list'*'chown -R'*) ;; *) echo "EXTRACTION FAILED: reown_ext_appdata body in $f" >&2; return 2 ;; esac
  case "$RT" in *'stat -c'*'chown -R'*) ;; *) echo "EXTRACTION FAILED: remap_tree body in $f" >&2; return 2 ;; esac
  FNS=$(reroot "$RT"; reroot "$RE")
  n=$(printf '%s\n' "$FNS" | grep -o '\$ROOT/data/' | grep -c .)
  [ "$n" -ge 1 ] || { echo "RE-ROOT FAILED: $n rewritten paths, want >= 1" >&2; return 2; }
  n=$(nleft "$FNS")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) in live code" >&2; return 2; }

  # run_case <shell> <root> <call-snippet>: the REAL functions under <shell>, with stat/chown stubbed.
  run_case() {
    local s="$1" r="$2" drv="$2/driver.sh" e pat='command not found|unbound variable|syntax error|bad substitution|not found'
    {
      printf 'ROOT=%s; uid=11; LOG="$ROOT/roam.log"\n' "$r"
      cat <<'STUBS'
stat() {
  [ "$1" = -c ] && [ "$2" = '%u:%g' ] || return 1
  local tp to
  while read -r tp to; do
    if [ "$tp" = "$3" ]; then echo "$to"; break; fi
  done < "$ROOT/owners"
}
chown() { echo "chown $*" >> "$ROOT/chown.log"; }
STUBS
      printf '%s\n' "$FNS"
      printf '%s\n' "$3"
    } > "$drv"
    : > "$r/chown.log"
    "$s" "$drv" > "$r/out" 2> "$r/err"
    # In a mutant run a shell complaint (an arithmetic error on an empty appId) is the mutant's own effect.
    [ -z "$quiet" ] || return 0
    e=$(grep -m1 -E "$pat" "$r/err" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$s: $e]"
  }
  ok() { p=$((p+1)); say "  ok    [$sh] $1"; }
  bad() { x=$((x+1)); say "  FAIL  [$sh] $1 -- $2"; [ -z "$quiet" ] || echo "FAILED [$sh] $1 -- $2"; }
  norm() { sed "s#$T#R#g" "$1"; }
  expect() {  # expect <label> <want-chown-log> <want-out> <want-roam.log-lines-matching-reowned>
    local got out lg
    got=$(norm "$T/chown.log"); out=$(norm "$T/out"); lg=$(grep 'reowned' "$T/roam.log" 2>/dev/null)
    if [ "$got" = "$2" ] && [ "$out" = "$3" ] && [ "$lg" = "${4:-}" ]; then ok "$1"
    else bad "$1" "chown log [$got] out [$out] log [$lg]; wanted [$2] [$3] [${4:-}]; stderr [$(head -n 1 "$T/err" 2>/dev/null)]"; fi
  }
  fresh() { T=$(mktemp -d -p "$W"); mkdir -p "$T/data/system" "$T/data/media/11/Android/data" "$T/data/media/11/Android/obb"; : > "$T/owners"; : > "$T/data/system/packages.list"; D="$T/data/media/11"; }
  CALL='reown_ext_appdata com.app; echo "rc=$?"'
  LOG1='[roamd] reowned ext app-data com.app -> 1110456 (user 11)'

  for sh in $SHELLS; do
    # E1: both dirs -> the data chown to ext_data_rw, the obb chown to ext_obb_rw
    fresh; mkdir -p "$D/Android/data/com.app" "$D/Android/obb/com.app"
    printf 'com.app 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "E1 data and obb dirs: -R uid*100000+appId, ext_data_rw / ext_obb_rw, rc 0, one log line" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app
chown -R 1110456:ext_obb_rw R/data/media/11/Android/obb/com.app" "rc=0" "$LOG1"

    # E2: data dir only
    fresh; mkdir -p "$D/Android/data/com.app"
    printf 'com.app 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "E2 data dir only: only the data chown, rc 0" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app" "rc=0" "$LOG1"

    # E3: not listed
    fresh; mkdir -p "$D/Android/data/com.app" "$D/Android/obb/com.app"
    printf 'com.other 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "E3 not in packages.list: no chown, rc 1, no reowned line" "" "rc=1" ""

    # E4: non-numeric appId field
    fresh; mkdir -p "$D/Android/data/com.app" "$D/Android/obb/com.app"
    printf 'com.app abc 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "E4 non-numeric appId: no chown, rc 1, no reowned line" "" "rc=1" ""

    # E5: prefix decoys listed BEFORE the real line
    fresh; mkdir -p "$D/Android/data/com.app"
    printf 'com.app.other 10111 0 /x default 3003\nxcom.app 10333 0 /x default 3003\ncom.app 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "E5 decoys com.app.other and xcom.app listed first: the target comes from the exact line" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app" "rc=0" "$LOG1"

    # E6: the global uid drives the target and the paths
    fresh; mkdir -p "$D/Android/data/com.app" "$T/data/media/12/Android/data/com.app"
    printf 'com.app 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" 'reown_ext_appdata com.app; uid=12; reown_ext_appdata com.app; echo "rc=$?"'
    expect "E6 two values of uid: two different targets" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app
chown -R 1210456:ext_data_rw R/data/media/12/Android/data/com.app" "rc=0" \
"$LOG1
[roamd] reowned ext app-data com.app -> 1210456 (user 12)"

    # E7 LOCALS: the caller's pkg, appid and target survive a resolved and an unresolved call
    fresh; mkdir -p "$D/Android/data/com.app"
    printf 'com.app 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" 'pkg=P appid=A target=T
reown_ext_appdata com.app; reown_ext_appdata com.gone
echo "$pkg $appid $target"'
    expect "E7 locals: pkg appid target unchanged after the call" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app" "P A T" "$LOG1"

    # E8 (NWP-20261111-11): a look-alike listed BEFORE the real line. The old grep read the name as a regex, so
    # `^com.app.name ` matched `com.appxname` and both chowns went to that app's uid.
    fresh; mkdir -p "$D/Android/data/com.app.name" "$D/Android/obb/com.app.name"
    printf 'com.appxname 10999 0 /x default 3003\ncom.app.name 10456 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" 'reown_ext_appdata com.app.name; echo "rc=$?"'
    expect "E8 look-alike com.appxname listed before com.app.name: both chowns to com.app.name's appId" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app.name
chown -R 1110456:ext_obb_rw R/data/media/11/Android/obb/com.app.name" "rc=0" "[roamd] reowned ext app-data com.app.name -> 1110456 (user 11)"

    # E9: only the look-alike is listed -> unresolved: rc 1, no chown, no reowned line
    fresh; mkdir -p "$D/Android/data/com.app.name" "$D/Android/obb/com.app.name"
    printf 'com.appxname 10999 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" 'reown_ext_appdata com.app.name; echo "rc=$?"'
    expect "E9 only the look-alike listed: no chown, rc 1, no reowned line" "" "rc=1" ""

    # E10: a second line for the same package after the first -> ONE answer, the first exact line (the -m1 the grep
    # had); without the awk's exit both appIds come back and the guard refuses them
    fresh; mkdir -p "$D/Android/data/com.app"
    printf 'com.app 10456 0 /x default 3003\ncom.app 10999 0 /x default 3003\n' > "$T/data/system/packages.list"
    run_case "$sh" "$T" "$CALL"
    expect "E10 two lines for com.app: the first one's appId" \
"chown -R 1110456:ext_data_rw R/data/media/11/Android/data/com.app" "rc=0" "$LOG1"

    # R1/R1b: the whole tree goes to the owner stat reports for the dir
    fresh; mkdir -p "$D/DCIM"
    printf '%s 1023:1023\n' "$D" > "$T/owners"
    run_case "$sh" "$T" 'remap_tree "$ROOT/data/media/11"'
    expect "R1 stat 1023:1023: exactly -R 1023:1023 <dir>" "chown -R 1023:1023 R/data/media/11" ""
    fresh; printf '%s 2000:2001\n' "$D" > "$T/owners"
    run_case "$sh" "$T" 'remap_tree "$ROOT/data/media/11"'
    expect "R1b stat 2000:2001: exactly -R 2000:2001 <dir>" "chown -R 2000:2001 R/data/media/11" ""

    # R2: stat gives nothing
    fresh
    run_case "$sh" "$T" 'remap_tree "$ROOT/data/media/11"'
    expect "R2 stat gives nothing: no chown" "" ""

    # R3: non-numeric owner
    fresh; printf '%s a:b\n' "$D" > "$T/owners"
    run_case "$sh" "$T" 'remap_tree "$ROOT/data/media/11"'
    expect "R3 stat gives a:b: no chown" "" ""

    # R4 LOCALS
    fresh; printf '%s 1023:1023\n' "$D" > "$T/owners"
    run_case "$sh" "$T" 'own=O
remap_tree "$ROOT/data/media/11"
echo "$own"'
    expect "R4 locals: the caller's own unchanged after the call" "chown -R 1023:1023 R/data/media/11" "O"
  done
  # S1 (NWP-20261111-22), once, not per shell: no package lookup in roamd reads its name as a regex. The control
  # count of the exact form keeps the check from passing on an empty or wrong read.
  sh=source
  n=$(grep -cE 'grep -m1 "\^\$[A-Za-z_]* " /data/system/packages\.list' "$f")
  c=$(grep -cF -- "$LOOKUP" "$f")
  if [ "$n" = 0 ] && [ "$c" = 4 ]; then ok "S1 no grep-regex packages.list lookup left, four exact lookups"
  else bad "S1 no grep-regex packages.list lookup left, four exact lookups" "old-form lines $n (want 0), exact lookups $c (want 4)"; fi
  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "passed $p, failed $x (shells:$SHELLS)"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT"; rc=$?
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of one function's text, by exact line; a mutant that changes nothing is a failure, and only a
# run in which the named case FAILS (rc 1) under EVERY shell convicts -- a harness error (rc 2) is not a conviction.
L_DATA='  [ -d "/data/media/$uid/Android/data/$pkg" ] && chown -R "$target:ext_data_rw" "/data/media/$uid/Android/data/$pkg" 2>> "$LOG"'
L_OBB='  [ -d "/data/media/$uid/Android/obb/$pkg" ]  && chown -R "$target:ext_obb_rw"  "/data/media/$uid/Android/obb/$pkg"  2>> "$LOG"'
L_TGT='  target=$((uid * 100000 + appid))'
L_GUARD='  case "$appid" in '"''"'|*[!0-9]*) return 1;; esac'
L_LOC='  local pkg="$1" appid target'
L_AWK='  appid=$(NW_PKG="$pkg" awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'
# The replacements are spelled out, not built with ${L_AWK/pat/rep}: the [ ] in the line is a bracket expression there.
L_AWK_PREFIX='  appid=$(NW_PKG="$pkg" awk '"'"'index($0, ENVIRON["NW_PKG"]) == 1 { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'
L_AWK_NOEXIT='  appid=$(NW_PKG="$pkg" awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2 }'"'"' /data/system/packages.list 2>/dev/null)'
L_OLDGREP='  appid=$(grep -m1 "^$pkg " /data/system/packages.list 2>/dev/null | cut -d'"' '"' -f2)'
L_RGUARD='  case "$own" in '"''"'|*[!0-9:]*) return;; esac'
L_RCHOWN='  chown -R "$own" "$1" 2>> "$LOG"'
L_RLOC='  local own'
# S1's mutants: the other two exact lookups, each against the grep it replaced.
L_RR_AWK='  appid=$(NW_PKG="$name" awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'
L_RR_OLD='  appid=$(grep -m1 "^$name " /data/system/packages.list 2>/dev/null | cut -d'"' '"' -f2)'
L_OD_AWK='            _odappid=$(NW_PKG="$pkg" awk '"'"'$1 == ENVIRON["NW_PKG"] { print $2; exit }'"'"' /data/system/packages.list 2>/dev/null)'
L_OD_OLD='            _odappid=$(grep -m1 "^$pkg " /data/system/packages.list 2>/dev/null | cut -d" " -f2)'
for pair in "reown_ext_appdata:$L_DATA" "reown_ext_appdata:$L_OBB" "reown_ext_appdata:$L_TGT" "reown_ext_appdata:$L_GUARD" \
            "reown_ext_appdata:$L_LOC" "reown_ext_appdata:$L_AWK" "remap_tree:$L_RGUARD" "remap_tree:$L_RCHOWN" "remap_tree:$L_RLOC"; do
  [ "$(fn_of "$SUT" "${pair%%:*}" | grep -cxF -- "${pair#*:}")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in ${pair%%:*} of $SUT: ${pair#*:}" >&2; exit 2; }
done
for l in "$L_RR_AWK" "$L_OD_AWK"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
# conv <name> <mutant-file>: run the suite on the mutant
conv() {
  local name="$1" t="$2" out r s m conv=1
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  out=$(suite "$t" quiet 2>&1); r=$?
  command rm -f "$t"
  # Per shell: one shell's conviction cannot vouch for another's (mksh reads a non-number in [ -lt ] as 0).
  for s in $SHELLS; do m=$(printf '%s\n' "$out" | grep -E -- "FAILED \[$s\] $3"); [ -n "$m" ] || conv=0; done
  if [ "$r" = 1 ] && [ "$conv" = 1 ]; then echo "  ok    CONVICTED: $name"
  else echo "  FAIL  NOT CONVICTED (rc=$r): $name"; MFAIL=1; fi
}
# mut <name> <function> <anchor> <replacement> <case-label-regex>: replace (or, empty, drop) the anchor line in <function>
mut() {
  local t; t=$(mktemp -p "$W")
  awk -v F="$2" -v A="$3" -v B="$4" '$0==F "() {" {inf=1} inf && $0==A && !done { done=1; if (B != "") print B; next } inf && /^\}$/ {inf=0} {print}' "$SUT" > "$t"
  conv "$1" "$t" "$5"
}
# mut_src <name> <anchor> <replacement>: replace the first whole-line match anywhere in roamd; only S1 failing convicts
mut_src() {
  local name="$1" t out r m
  t=$(mktemp -p "$W")
  awk -v A="$2" -v B="$3" '$0==A && !done { done=1; print B; next } {print}' "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  out=$(suite "$t" quiet 2>&1); r=$?
  command rm -f "$t"
  m=$(printf '%s\n' "$out" | grep -F -- 'FAILED [source] S1')
  if [ "$r" = 1 ] && [ -n "$m" ]; then echo "  ok    CONVICTED: $name"
  else echo "  FAIL  NOT CONVICTED (rc=$r): $name"; MFAIL=1; fi
}
MFAIL=0
echo "== mutants =="
t=$(mktemp -p "$W")
awk '$0=="reown_ext_appdata() {" {inf=1} inf && /^\}$/ {inf=0} inf { gsub(/ext_data_rw/, "@@"); gsub(/ext_obb_rw/, "ext_data_rw"); gsub(/@@/, "ext_obb_rw") } {print}' "$SUT" > "$t"
conv "M1 the two groups swapped (E1)" "$t" 'E1'
mut "M2 target is the bare appId (E1, E6)" reown_ext_appdata "$L_TGT" '  target=$appid' 'E[16]'
mut "M3 -R dropped from the data chown (E1)" reown_ext_appdata "$L_DATA" "${L_DATA/chown -R/chown}" 'E1'
mut "M4 the appId guard deleted (E3, E4)" reown_ext_appdata "$L_GUARD" "" 'E[34]'
mut "M5 reown_ext_appdata locals dropped (E7)" reown_ext_appdata "$L_LOC" '  pkg="$1"' 'E7'
mut "M6 the exact match loosened to a prefix (E5)" reown_ext_appdata "$L_AWK" "$L_AWK_PREFIX" 'E5'
mut "M7 the exit dropped: a second line for the package gives two answers (E10)" reown_ext_appdata "$L_AWK" "$L_AWK_NOEXIT" 'E10'
mut "M8 remap_tree chowns a fixed 1023:1023 (R1b)" remap_tree "$L_RCHOWN" '  chown -R 1023:1023 "$1" 2>> "$LOG"' 'R1b'
mut "M9 remap_tree's owner guard deleted (R3)" remap_tree "$L_RGUARD" "" 'R3'
mut "M10 remap_tree's local own removed (R4)" remap_tree "$L_RLOC" "" 'R4'
mut "M11 the exact lookup reverted to the old grep regex (E8)" reown_ext_appdata "$L_AWK" "$L_OLDGREP" 'E8'
mut_src "M12 reown_restored's lookup reverted to the grep regex (S1)" "$L_RR_AWK" "$L_RR_OLD"
mut_src "M13 reown_ext_appdata's lookup reverted to the grep regex (S1)" "$L_AWK" "$L_OLDGREP"
mut_src "M14 odrestore's lookup reverted to the grep regex (S1)" "$L_OD_AWK" "$L_OD_OLD"
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
