#!/usr/bin/env bash
# test-appcode-stage-reuse.sh [--mutate] -- NWP-20261128-09: a periodic #apps seal reuses the previous seal's staged
# APKs (the pool, /data/nowhere/appcode-reuse) for every source with the same size and mtime, instead of copying it.
#
# WHY THIS IS COMMITTED. Backlog row "Every periodic seal spends 4-6 minutes staging `#apps` for an unchanged 743 KiB
# push, and holds the RW worker slot the whole time". appcode_seal started every seal with `rm -rf "$STAGE"` and copied
# every kept APK again (frankel: `apps=stage 213-370 s` for a 743 KiB push), while it held the RW worker slot. Now a
# periodic or manual seal renames its stage to the pool after the push, with its uid in .uid, and stage_apk_copy MOVES a
# pool entry into the next stage when the source has the same size and mtime. Nothing fails when this regresses: the
# seal only gets slow again. The pool holds package names and APK bytes, so this suite also pins who may use it (the
# same uid only, never a link) and when it goes (a sign-out's seal).
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, pkgname_ok, live_code_dir, live_code_ver,
# stage_apk_copy, stage_live_apks and stage_keep_mtimes), every /data/ path pointed into a scratch root. `dumpsys`
# reads $T/dumps/<pkg>; `$AGENT` records a `stat -c '%n %F %s %Y'` listing of the stage at push time and exits 0. A
# PATH shim around cp and mv logs every call to $T/calls; mv fails for a pool source when $T/mvfail exists.
#
#   bash test-appcode-stage-reuse.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-stage-reuse.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
#   ONLY="r1 r2" ROAMD=<file> bash test-appcode-stage-reuse.sh   # a subset, e.g. against an older roamd
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
ONLY="${ONLY:-r1 r2 r3 r4 r5 r6 r7 r8}"
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
want(){ case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

FUNCS=""
for fn in qn pw pkgname_ok live_code_dir live_code_ver stage_apk_copy stage_live_apks stage_keep_mtimes appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in
    "$fn() {"*'}') FUNCS="$FUNCS$body
" ;;
    *) # stage_apk_copy is this slice's helper: an older roamd has none, and must still run (and fail) the cases
       [ "$fn" = stage_apk_copy ] && continue
       echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;;
  esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }
# The PATH shim must be what the lifted code reaches: none of it may define its own cp or mv.
[ -z "$(printf '%s\n' "$FUNCS" | grep -E '^[[:space:]]*(cp|mv)[[:space:]]*\(\)')" ] || { echo "EXTRACTION FAILED: the lifted code defines cp or mv" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# The PATH shim: cp and mv log their arguments to $SHIM_LOG, then run the real binary.
REALCP=$(command -v cp); REALMV=$(command -v mv)
[ -n "$REALCP" ] && [ -n "$REALMV" ] || { echo "no cp or mv on this host" >&2; exit 2; }
SHIM=$(mktemp -d -p "$W") || exit 2
cat > "$SHIM/cp" <<EOF
#!/bin/sh
printf 'cp %s\n' "\$*" >> "\$SHIM_LOG"
exec $REALCP "\$@"
EOF
cat > "$SHIM/mv" <<EOF
#!/bin/sh
printf 'mv %s\n' "\$*" >> "\$SHIM_LOG"
case "\$1" in *appcode-reuse/*) [ -e "\$SHIM_MVFAIL" ] && exit 1 ;; esac
exec $REALMV "\$@"
EOF
chmod +x "$SHIM/cp" "$SHIM/mv" || exit 2

OLD='2020-01-02 03:04:05'
NEW='2021-06-07 08:09:10'

# head_lines <T> <uid> <skind>: the shell prologue every run file shares (stubs, then the lifted functions).
head_lines(){
  printf '%s\n' "$PRINT_SHIM"
  printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=1\n' "$1"
  printf 'uid=%s; skind=%s\n' "$2" "$3"
  printf 'SHIM_LOG=$T/calls; SHIM_MVFAIL=$T/mvfail; export SHIM_LOG SHIM_MVFAIL; PATH=%s:$PATH\n' "$SHIM"
  cat <<'STUBS'
dumpsys(){ [ "$1" = package ] && [ -f "$T/dumps/$2" ] && cat "$T/dumps/$2"; return 0; }
agent_stub(){
  local last a
  for a; do last=$a; done
  (cd "$last" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r e; do stat -c '%n|%F|%s|%Y' "$e"; done) > "$T/stat.txt"
  return 0
}
_ms(){ local _t; _t=$(date +%s%3N 2>/dev/null); case "$_t" in ''|*[!0-9]*) echo 0;; *) echo "$_t";; esac; }
STUBS
  printf 'AGENT=agent_stub\n'
  printf 'timeout(){ shift 3; "$@"; }\n'
  printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _apps_stage_prog(){ :; }; appcode_stage_play_dormant(){ :; }\n'
  printf '%s\n' "$FUNCS"
}

# run_seal <shell> <T> <n> <skind>: one appcode_seal (uid 12) over the tree in T. Leaves $T/stat<n>.txt (the stage at
# push time), $T/calls<n> (cp/mv calls), $T/log<n> and $T/res<n>.
run_seal(){
  local s=$1 T=$2 n=$3
  : > "$T/log"; : > "$T/stat.txt"; : > "$T/calls"; echo 9 > "$T/res"
  { head_lines "$T" 12 "$4"; printf 'appcode_seal; echo "$?" > "$T/res"\n'; } > "$T/run.sh"
  timeout 60 "$s" "$T/run.sh" >/dev/null 2>&1
  mv "$T/stat.txt" "$T/stat$n.txt"; mv "$T/calls" "$T/calls$n"; mv "$T/log" "$T/log$n"; mv "$T/res" "$T/res$n"
}

mk_tree(){
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  F="$T/user/com.nowhere.chooser/files"; P="$T/data/nowhere/appcode-reuse"
  mkdir -p "$T/data/nowhere" "$T/data/app" "$F" "$T/dumps" || exit 2
}
mk_code(){
  mkdir -p "$2" || exit 2
  printf '%s-base-0123456789' "$1" > "$2/base.apk"; printf '%s-split-0123456789-0123456789' "$1" > "$2/split.apk"
  touch -d "$OLD" "$2/base.apk" "$2/split.apk" "$2" || exit 2
}
mk_dump(){ printf 'Packages:\n  Package [%s] (1):\n    codePath=%s\n    versionCode=7 minSdk=26 targetSdk=34\n    flags=[ HAS_CODE ]\n' "$1" "$2" > "$T/dumps/$1"; }
# fixture: com.l (code list, valid paths: the code-list loop's own copy), com.r (code list, stale paths: stage_live_apks
# from its live dir), com.k (keep-set only: the keep-set sweep, stage_live_apks). Six APKs.
fixture(){
  L="$T/data/app/~~l==/com.l-1=="; R="$T/data/app/~~r==/com.r-2=="; K="$T/data/app/~~k==/com.k-1=="
  mk_code com.l "$L"; mk_code com.r "$R"; mk_code com.k "$K"
  mk_dump com.r "$R"; mk_dump com.k "$K"
  {
    printf 'com.l\t7\t0\tinstalled\t%s\t%s\n' "$L/base.apk" "$L/split.apk"
    printf 'com.r\t7\t0\tinstalled\t%s\n' "$T/data/app/~~old==/com.r-1==/base.apk"
  } > "$F/nowhere-appcode.list"
  printf 'com.l\tinstalled\ncom.r\tinstalled\ncom.k\tinstalled\n' > "$F/nowhere-appkeep"
}
# apks <stat file>: the stage's APK entries, "name|type|size|mtime".
apks(){ grep '\.apk|' "$1"; }
# src_apks: the sources' entries in the same shape, keyed by their stage names.
src_apks(){
  local p d f
  for p in com.k:"$K" com.l:"$L" com.r:"$R"; do
    d=${p#*:}
    for f in base.apk split.apk; do printf './%s/%s|regular file|%s|%s\n' "${p%%:*}" "$f" "$(stat -c %s "$d/$f")" "$(stat -c %Y "$d/$f")"; done
  done
}
apk_cps(){ grep -c '^cp .*\.apk$' "$1"; }
reused(){ sed -n 's/.*#apps staged .* mtime kept-failed, \([0-9]*\) reused).*/\1/p' "$1"; }
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"
  if want r1; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 ""
    [ -d "$P" ] && [ "$(cat "$P/.uid" 2>/dev/null)" = 12 ] && [ ! -e "$T/data/nowhere/appcode-stage" ] && [ "$(cat "$T/res1")" = 0 ] \
      && ok "$t r1 a periodic seal leaves the pool with .uid 12 and no stage" \
      || no "$t r1 after seal 1: pool [$(ls -A "$P" 2>&1 | tr '\n' ' ')] uid [$(cat "$P/.uid" 2>&1)] res [$(cat "$T/res1")]"
    sleep 1
    run_seal "$s" "$T" 2 ""
    c=$(apk_cps "$T/calls2"); r=$(reused "$T/log2")
    [ "$c" = 0 ] && ok "$t r1 a second periodic seal of unchanged sources makes no cp of an APK" \
      || no "$t r1 seal 2 copied $c APK(s): [$(grep '^cp' "$T/calls2" | tr '\n' '|')]"
    A1=$(apks "$T/stat1.txt"); A2=$(apks "$T/stat2.txt"); S=$(src_apks)
    [ -n "$A2" ] && [ "$A2" = "$A1" ] && [ "$A2" = "$S" ] \
      && ok "$t r1 the second stage holds the same APKs, each regular, with its source's size and mtime" \
      || no "$t r1 stages differ: [$A1] [$A2] sources [$S]"
    [ "$r" = 6 ] && [ "$(reused "$T/log1")" = 0 ] && ok "$t r1 the staging line reads '6 reused' (seal 1: '0 reused')" \
      || no "$t r1 staging lines: [$(grep '#apps staged' "$T/log1" "$T/log2" | tr '\n' '|')]"
    has "$(cat "$T/stat1.txt" "$T/stat2.txt")" '.apk-reused' && no "$t r1 the reuse-count file reached the push" \
      || ok "$t r1 the reuse-count file is not in the push"
    grep '#apps staged' "$T/log2" | grep -q 'com\.' && no "$t r1 the staging line names a package" || ok "$t r1 the staging line names no package"
    [ -d "$P" ] && [ "$(cat "$P/.uid" 2>/dev/null)" = 12 ] && [ "$(cat "$T/res2")" = 0 ] \
      && ok "$t r1 seal 2 returns 0 and leaves the pool again" || no "$t r1 after seal 2: res [$(cat "$T/res2")] uid [$(cat "$P/.uid" 2>&1)]"
  fi
  if want r2; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 ""
    cp -p "$L/base.apk" "$T/ref"; printf 'grown' >> "$L/base.apk"; touch -r "$T/ref" "$L/base.apk"
    run_seal "$s" "$T" 2 ""
    c=$(apk_cps "$T/calls2"); r=$(reused "$T/log2")
    sz=$(grep '^\./com\.l/base\.apk|' "$T/stat2.txt" | cut -d'|' -f3)
    [ "$c" = 1 ] && grep -q '^cp .*/com\.l/base\.apk$' "$T/calls2" && [ "$r" = 5 ] && [ "$sz" = "$(stat -c %s "$L/base.apk")" ] \
      && ok "$t r2 a source whose size changed (same mtime) is copied; the other five are reused" \
      || no "$t r2 size changed: $c cp, $r reused, staged size [$sz] source $(stat -c %s "$L/base.apk")"
  fi
  if want r3; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 ""
    touch -d "$NEW" "$R/split.apk"
    run_seal "$s" "$T" 2 ""
    c=$(apk_cps "$T/calls2"); r=$(reused "$T/log2")
    mt=$(grep '^\./com\.r/split\.apk|' "$T/stat2.txt" | cut -d'|' -f4)
    [ "$c" = 1 ] && grep -q '^cp .*/com\.r/split\.apk$' "$T/calls2" && [ "$r" = 5 ] && [ "$mt" = "$(stat -c %Y "$R/split.apk")" ] \
      && ok "$t r3 a source whose mtime changed (same size) is copied; the other five are reused" \
      || no "$t r3 mtime changed: $c cp, $r reused, staged mtime [$mt] source $(stat -c %Y "$R/split.apk")"
  fi
  if want r4; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 ""
    echo 13 > "$P/.uid"; : > "$P/marker"
    run_seal "$s" "$T" 2 ""
    c=$(apk_cps "$T/calls2"); r=$(reused "$T/log2")
    [ "$c" = 6 ] && [ "$r" = 0 ] && [ ! -e "$P/marker" ] && [ "$(cat "$P/.uid" 2>/dev/null)" = 12 ] \
      && ok "$t r4 a pool whose .uid names another uid is removed and nothing is reused" \
      || no "$t r4 other uid's pool: $c cp, $r reused, marker $( [ -e "$P/marker" ] && echo kept || echo gone), uid [$(cat "$P/.uid" 2>&1)]"
  fi
  if want r5; then
    for k in logoff logoff-pinned; do
      mk_tree; fixture
      run_seal "$s" "$T" 1 ""
      [ -d "$P" ] || no "$t r5 $k: no pool after seal 1, so nothing to purge"
      run_seal "$s" "$T" 2 "$k"
      [ "$(reused "$T/log2")" = 6 ] || no "$t r5 $k: the sign-out's seal did not reuse the pool"
      [ ! -e "$P" ] && [ ! -L "$P" ] && [ ! -e "$T/data/nowhere/appcode-stage" ] && [ "$(cat "$T/res2")" = 0 ] \
        && ok "$t r5 a $k seal leaves no pool and no stage" \
        || no "$t r5 $k seal left: [$(ls -A "$T/data/nowhere" | tr '\n' ' ')] res [$(cat "$T/res2")]"
    done
  fi
  if want r6; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 ""
    TGT=$(mktemp -p "$W") || exit 2
    cp "$L/base.apk" "$TGT"; touch -r "$L/base.apk" "$TGT"
    rm -f "$P/com.l/base.apk"; ln -s "$TGT" "$P/com.l/base.apk"
    run_seal "$s" "$T" 2 ""
    c=$(apk_cps "$T/calls2"); r=$(reused "$T/log2")
    ty=$(grep '^\./com\.l/base\.apk|' "$T/stat2.txt" | cut -d'|' -f2)
    if [ "$ty" = "regular file" ]; then ok "$t r6 the stage entry is a regular file"; else no "$t r6 stage entry is a link: type [$ty]"; fi
    [ "$c" = 1 ] && grep -q '^cp .*/com\.l/base\.apk$' "$T/calls2" && [ "$r" = 5 ] && [ -f "$TGT" ] \
      && ok "$t r6 a pool entry that is a symlink is not used: that APK is copied, its target is untouched" \
      || no "$t r6 link in the pool: $c cp, $r reused, target $( [ -f "$TGT" ] && echo kept || echo gone)"
  fi
  if want r7; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 ""
    : > "$T/mvfail"
    run_seal "$s" "$T" 2 ""
    c=$(apk_cps "$T/calls2"); r=$(reused "$T/log2"); A2=$(apks "$T/stat2.txt")
    [ "$c" = 6 ] && [ "$r" = 0 ] && [ "$A2" = "$(src_apks)" ] && [ "$(cat "$T/res2")" = 0 ] \
      && ok "$t r7 a failed mv falls back to the copy: the stage is whole, status 0" \
      || no "$t r7 mv failing: $c cp, $r reused, res [$(cat "$T/res2")], stage [$A2]"
  fi
  if want r8; then
    mk_tree; fixture
    run_seal "$s" "$T" 1 manual
    [ -d "$P" ] && [ "$(cat "$P/.uid" 2>/dev/null)" = 12 ] && ok "$t r8 a manual seal leaves the pool" || no "$t r8 no pool after a manual seal"
    run_seal "$s" "$T" 2 manual
    [ "$(apk_cps "$T/calls2")" = 0 ] && [ "$(reused "$T/log2")" = 6 ] && ok "$t r8 the next manual seal reuses every APK" \
      || no "$t r8 manual seal 2: $(apk_cps "$T/calls2") cp, $(reused "$T/log2") reused"
  fi
done

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL its target case under EACH shell):"
  MT=$(mktemp -d -p "$W")
  mut(){ # mut <label> <target case> <sed script>
    local rc s bad=""
    sed -e "$3" "$ROAMD" > "$MT/roamd.sh"
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    ROAMD="$MT/roamd.sh" ONLY="$2" bash "$0" > "$MT/out" 2>&1; rc=$?
    for s in $SHELLS; do grep -q "FAIL  \[$s\] $2 " "$MT/out" || bad="$bad $s"; done
    if grep -q 'EXTRACTION FAILED' "$MT/out"; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted by $2 under every shell ($(printf '%s' "$SHELLS" | sed 's/^ //')): $1"
    else no "NOT CONVICTED by $2 (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  mut "M1 stage_apk_copy: the size comparison dropped" r2 \
    '/^stage_apk_copy() {$/,/^}$/{/^     && \[ "\$sac_sz" = "\$(stat -L -c %s "\$sac_c" 2>\/dev\/null)" \] \\$/d}'
  mut "M2 stage_apk_copy: the mtime comparison dropped" r3 \
    '/^stage_apk_copy() {$/,/^}$/{/^     && \[ "\$sac_mt" = "\$(stat -L -c %Y "\$sac_c" 2>\/dev\/null)" \] \\$/d}'
  mut "M3 appcode_seal: the pool's uid check dropped" r4 \
    's/^    && \[ "\$_acw_pu" = "\$uid" \] || rm -rf "\$POOL" /    || rm -rf "$POOL" /'
  mut "M4 appcode_seal: the pool kept on a sign-out's seal" r5 \
    's/^    logoff|logoff-pinned) rm -rf "\$STAGE" "\$POOL" ;;$/    logoff|logoff-pinned) rm -rf "$POOL"; mv "$STAGE" "$POOL" ;;/'
  mut "M5 stage_apk_copy: the link check dropped" r6 \
    '/^stage_apk_copy() {$/,/^}$/{/^     && \[ ! -L "\$sac_c" \] \\$/d}'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
