#!/usr/bin/env bash
# test-appcode-stage-mtime.sh [--mutate] -- NWP-20261123-02: appcode_seal's #apps stage gives every staged entry its
# source's mtime (each APK, each _meta entry, each package dir last), and its "#apps staged" line splits copy time out.
#
# WHY THIS IS COMMITTED. Backlog rows "Every `#apps` seal spends 1.5-2.2 minutes of local work and reuses none of its
# small-file groups, although it uploads almost nothing" and "A periodic seal's `#apps` staging spends two to three
# minutes staging nothing". The #apps push runs with NOWHERE_CARRY_ESSENTIAL=1, so the agent walks it at threshold 0:
# every regular file is keyed by the scan cache on (rel, mtime, size, mode), and the small-file groups hold only the
# package and _meta directories, which groupCacheKey keys on their mtimes. appcode_seal starts every seal with
# `rm -rf "$STAGE"` and copied each APK with a plain cp and each _meta with a plain `cp -r`, so every staged entry had
# a new mtime at every seal: no group was ever reused (frankel 0.5.51: "0 of 45 group(s) reused") and every APK was
# read and hashed again. Nothing fails when this regresses: the seal only gets slow again.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, pkgname_ok, live_code_dir, live_code_ver,
# stage_live_apks and stage_keep_mtimes), every /data/ path pointed into a scratch root. `dumpsys` reads
# $T/dumps/<pkg>; `$AGENT` records a `stat -c '%n %f %s %y'` listing of the stage at push time.
#
#   bash test-appcode-stage-mtime.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-stage-mtime.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
#   ONLY="a b" ROAMD=<file> bash test-appcode-stage-mtime.sh   # a subset, e.g. against an older roamd
# Assertions feed grep -q from a here-string, never from a pipe: bash's printf writes line by line, so a grep -q that
# matches early leaves printf a closed pipe, and pipefail reads that as no match (the b case failed so, 2026-11-05).
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
ONLY="${ONLY:-a b c d e f}"
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
want(){ case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

FUNCS=""
for fn in qn pw pkgname_ok live_code_dir live_code_ver stage_apk_copy stage_live_apks stage_keep_mtimes appcode_inputs_fp appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in
    "$fn() {"*'}') FUNCS="$FUNCS$body
" ;;
    *) # stage_keep_mtimes is this slice's helper: an older roamd has none, and must still run (and fail) the cases
       [ "$fn" = stage_keep_mtimes ] && continue
       echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;;
  esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

OLD='2020-01-02 03:04:05.123456789'

# head_lines <shell> <T>: the shell prologue every run file shares (stubs, then the lifted functions).
head_lines(){
  printf '%s\n' "$PRINT_SHIM"
  printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=1\n' "$2"
  cat <<'STUBS'
cp(){
  case "$1" in -*) command cp "$@"; return ;; esac
  if grep -qxF "$1" "$T/cpshort" 2>/dev/null; then head -c $(( $(wc -c < "$1") / 2 )) "$1" > "$2"; return 0; fi
  command cp "$@"
}
dumpsys(){ [ "$1" = package ] && [ -f "$T/dumps/$2" ] && cat "$T/dumps/$2"; return 0; }
agent_stub(){
  local last a
  for a; do last=$a; done
  (cd "$last" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r e; do stat -c '%n %f %s %y' "$e"; done) > "$T/stat.txt"
  (cd "$last" && find . -name .mtime-kept-failed) > "$T/tf_at_push.txt"
  tr '\t' ':' < "$last/manifest.tsv" > "$T/man.txt"
  return 0
}
_ms(){ local _t; _t=$(date +%s%3N 2>/dev/null); case "$_t" in ''|*[!0-9]*) echo 0;; *) echo "$_t";; esac; }
STUBS
  printf 'AGENT=agent_stub\n'
  printf 'timeout(){ shift 3; "$@"; }\n'
  printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _apps_stage_prog(){ :; }; appcode_stage_play_dormant(){ :; }\n'
  printf '%s\n' "$FUNCS"
  [ -f "$2/touchfail" ] && printf 'touch(){ return 1; }\n'
  return 0
}

# run_seal <shell> <T> <n>: one appcode_seal over the tree in T. Leaves $T/stat<n>.txt, $T/man<n>.txt, $T/tf<n>.txt, $T/log.
run_seal(){
  local s=$1 T=$2 n=$3
  : > "$T/log"; : > "$T/stat.txt"; : > "$T/man.txt"; : > "$T/tf_at_push.txt"
  { head_lines "$s" "$T"; printf 'appcode_seal; echo "$?" > "$T/res"\n'; } > "$T/run.sh"
  timeout 60 "$s" "$T/run.sh" >/dev/null 2>&1
  mv "$T/stat.txt" "$T/stat$n.txt"; mv "$T/man.txt" "$T/man$n.txt"; mv "$T/tf_at_push.txt" "$T/tf$n.txt"
}

# run_sla <shell> <T> <src> <dst>: stage_live_apks alone. Sets SLA_OUT and SLA_RC.
run_sla(){
  local s=$1 T=$2
  { head_lines "$s" "$T"; printf 'o=$(stage_live_apks %s %s); r=$?; printf "%%s" "$o" > "$T/sla.out"; echo "$r" > "$T/sla.rc"\n' "'$3'" "'$4'"; } > "$T/run.sh"
  : > "$T/sla.out"; echo 9 > "$T/sla.rc"
  timeout 60 "$s" "$T/run.sh" >/dev/null 2>&1
  SLA_OUT=$(tr '\t' ':' < "$T/sla.out"); SLA_RC=$(cat "$T/sla.rc")
}

# mk_tree: a fresh scratch root in T; F = the chooser's files dir, M = its nowhere-appmeta.
mk_tree(){
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  F="$T/user/com.nowhere.chooser/files"; M="$F/nowhere-appmeta"
  mkdir -p "$T/data/nowhere" "$T/data/app" "$M" "$T/dumps" || exit 2
}
# mk_code <pkg> <dir>: a code dir with base + split, every entry given the OLD mtime (the dir last).
mk_code(){
  mkdir -p "$2" || exit 2
  printf '%s-base-0123456789' "$1" > "$2/base.apk"; printf '%s-split-0123456789-0123456789' "$1" > "$2/split.apk"
  touch -d "$OLD" "$2/base.apk" "$2/split.apk" "$2" || exit 2
}
# mk_dump <pkg> <dir>: dumpsys answers that the package is installed from <dir>.
mk_dump(){ printf 'Packages:\n  Package [%s] (1):\n    codePath=%s\n    versionCode=7 minSdk=26 targetSdk=34\n    flags=[ HAS_CODE ]\n' "$1" "$2" > "$T/dumps/$1"; }
# mk_meta <pkg>: the chooser's placeholder snapshot, with one nested dir, every entry OLD (depth first).
mk_meta(){
  mkdir -p "$M/$1/sub" || exit 2
  printf 'vc\t7\nlabel\tx\n' > "$M/$1/meta"; printf 'png' > "$M/$1/0.png"; printf 'x' > "$M/$1/sub/x"
  touch -d "$OLD" "$M/$1/meta" "$M/$1/0.png" "$M/$1/sub/x" "$M/$1/sub" "$M/$1" || exit 2
}
# fixture: com.l (code list, valid paths), com.r (code list, stale paths -> stage_live_apks from its live dir),
# com.o (on-demand, valid paths, with _meta), com.k (keep-set only, installed -> the keep loop), com.q (keep-set
# only, on-demand, live, with _meta -> the keep loop's on-demand arm), com.z (code list, on-demand, no APK and no _meta:
# an empty package dir with no source, which gets the fixed reference mtime).
fixture(){
  local L="$T/data/app/~~l==/com.l-1==" R="$T/data/app/~~r==/com.r-2==" O="$T/data/app/~~o==/com.o-1==" \
        K="$T/data/app/~~k==/com.k-1==" Q="$T/data/app/~~q==/com.q-1=="
  mk_code com.l "$L"; mk_code com.r "$R"; mk_code com.o "$O"; mk_code com.k "$K"; mk_code com.q "$Q"
  mk_dump com.r "$R"; mk_dump com.k "$K"; mk_dump com.q "$Q"
  mk_meta com.o; mk_meta com.q
  {
    printf 'com.l\t7\t0\tinstalled\t%s\t%s\n' "$L/base.apk" "$L/split.apk"
    printf 'com.r\t7\t0\tinstalled\t%s\n' "$T/data/app/~~old==/com.r-1==/base.apk"
    printf 'com.o\t7\t0\tondemand\t%s\t%s\n' "$O/base.apk" "$O/split.apk"
    printf 'com.z\t7\t0\tondemand\n'
  } > "$F/nowhere-appcode.list"
  printf 'com.l\tinstalled\ncom.r\tinstalled\ncom.o\tondemand\ncom.k\tinstalled\ncom.q\tondemand\ncom.z\tondemand\n' > "$F/nowhere-appkeep"
  LDIR=$L; RDIR=$R
}
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
STAGED_RE='#apps staged [0-9]* pkg(s), [0-9]* KiB, in [0-9]*ms (copy [0-9]*ms, [0-9]* mtime kept-failed, [0-9]* reused) (NWP-20261005-04, NWP-20261123-02, NWP-20261128-09)'

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"
  if want a; then
    mk_tree; fixture
    mkdir -p "$T/dst" || exit 2
    run_sla "$s" "$T" "$RDIR" "$T/dst"
    if [ "$SLA_RC" = 0 ] && [ "$SLA_OUT" = ":base.apk:split.apk" ]; then ok "$t a stage_live_apks staged both APKs (status 0)"
    else no "$t a stage_live_apks -> rc $SLA_RC out [$SLA_OUT]"; fi
    good=y
    for f in base.apk split.apk; do
      [ "$(stat -c %y "$RDIR/$f")" = "$(stat -c %y "$T/dst/$f" 2>/dev/null)" ] || good=n
    done
    [ "$good" = y ] && ok "$t a each staged APK's mtime equals its source's, ns included ($(stat -c %y "$T/dst/base.apk"))" \
      || no "$t a staged mtimes differ: src $(stat -c %y "$RDIR/base.apk") dst $(stat -c %y "$T/dst/base.apk" 2>/dev/null)"
  fi
  if want b || want e || want f; then
    mk_tree; fixture
    run_seal "$s" "$T" 1; sleep 1; run_seal "$s" "$T" 2
    LOGTXT=$(cat "$T/log")
    if want b; then
      P1=$(grep -E '^\./com\.[a-z]+(/|$| )' "$T/stat1.txt"); P2=$(grep -E '^\./com\.[a-z]+(/|$| )' "$T/stat2.txt")
      good=y
      for e in ./com.l ./com.l/base.apk ./com.r ./com.r/split.apk ./com.o ./com.o/_meta ./com.o/_meta/meta ./com.o/_meta/sub \
               ./com.o/_meta/sub/x ./com.k ./com.k/base.apk ./com.q ./com.q/_meta ./com.q/_meta/0.png ./com.z; do
        grep -q "^$e " <<<"$P1" || good=n
      done
      [ "$good" = y ] && ok "$t b the staged set holds every package dir, its APKs, _meta and its nested entries" \
        || no "$t b the staged set is missing entries: [$P1]"
      zt=$(sed -n 's/^\.\/com\.z \([0-9a-f]*\) [0-9]* //p' "$T/stat1.txt")
      [ -n "$zt" ] && [ "$(date -u -d "$zt" +%s 2>/dev/null)" = 946684800 ] \
        && ok "$t b a package dir with no source gets the fixed reference mtime (2000-01-01 00:00:00 UTC)" \
        || no "$t b the source-less package dir's mtime is [$zt]"
      if [ -n "$P1" ] && [ "$P1" = "$P2" ]; then ok "$t b two stagings of unchanged sources give identical (name, mode, size, mtime) entries"
      else no "$t b the two stagings differ: $(diff <(printf '%s\n' "$P1") <(printf '%s\n' "$P2") | grep '^[<>]' | head -6 | tr '\n' '|')"; fi
    fi
    if want e; then
      has "$LOGTXT" "] #apps staged 5 pkg(s), " && grep -q "$STAGED_RE" <<<"$LOGTXT" \
        && ok "$t e the staging line carries 'copy <n>ms' and the kept-failed count" || no "$t e staging line: [$(printf '%s\n' "$LOGTXT" | grep '#apps staged')]"
      grep -q 'com\.' <<<"$(grep '#apps staged' <<<"$LOGTXT")" && no "$t e the staging line names a package" || ok "$t e the staging line names no package"
    fi
    if want f; then
      [ ! -s "$T/tf1.txt" ] && [ ! -s "$T/tf2.txt" ] && grep -q . "$T/stat1.txt" \
        && ok "$t f no kept-failed counter file in the stage at push time" || no "$t f the counter file reached the push: [$(cat "$T/tf1.txt")]"
    fi
  fi
  if want c || want f; then
    mk_tree; fixture; : > "$T/touchfail"
    run_seal "$s" "$T" 1
    LOGTXT=$(cat "$T/log"); MANTXT=$(cat "$T/man1.txt")
    if want c; then
      if grep -qx 'com.l:7:0:installed:base.apk:split.apk' <<<"$MANTXT" && grep -qx 'com.r:7:0:installed:base.apk:split.apk' <<<"$MANTXT" \
         && grep -qx 'com.k:0:0:installed:base.apk:split.apk' <<<"$MANTXT" && grep -qx 'com.o:7:0:ondemand:base.apk:split.apk' <<<"$MANTXT" \
         && [ "$(cat "$T/res")" = 0 ] && ! has "$LOGTXT" 'did not copy whole'; then
        ok "$t c every touch failing: every package is still STAGED whole (manifest names its APKs, status 0)"
      else no "$t c a failed touch cut a package: man [$MANTXT] log [$LOGTXT]"; fi
      kf=$(printf '%s\n' "$LOGTXT" | sed -n 's/.*#apps staged .*, \([0-9]*\) mtime kept-failed,.*/\1/p')
      [ -n "$kf" ] && [ "$kf" -gt 0 ] && ok "$t c the staging line counts $kf mtime kept-failed" || no "$t c kept-failed count [$kf]: [$LOGTXT]"
      mkdir -p "$T/dst2" || exit 2
      run_sla "$s" "$T" "$LDIR" "$T/dst2"
      [ "$SLA_RC" = 0 ] && [ "$SLA_OUT" = ":base.apk:split.apk" ] && ok "$t c stage_live_apks with every touch failing: names printed, status 0" \
        || no "$t c stage_live_apks with a failing touch -> rc $SLA_RC out [$SLA_OUT]"
    fi
    if want f; then
      [ ! -s "$T/tf1.txt" ] && grep -q . "$T/stat1.txt" && ok "$t f touches failing: no kept-failed counter file in the stage at push time" \
        || no "$t f touches failing: the counter file reached the push: [$(cat "$T/tf1.txt")]"
    fi
  fi
  if want d; then
    mk_tree; fixture
    mkdir -p "$T/dst" || exit 2
    printf '%s\n' "$RDIR/split.apk" > "$T/cpshort"
    run_sla "$s" "$T" "$RDIR" "$T/dst"
    left=$(ls "$T/dst")
    [ "$SLA_RC" = 1 ] && [ -z "$SLA_OUT" ] && [ -z "$left" ] && ok "$t d a short copy still drops the whole set (NWP-20261108-04): no names, status 1, no .apk left" \
      || no "$t d short copy -> rc $SLA_RC out [$SLA_OUT] left [$left]"
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
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted by $2 under every shell: $1"
    else no "NOT CONVICTED by $2 (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  # NWP-20261128-09: the code-list loop and stage_live_apks copy through stage_apk_copy, so their touch is its one line.
  mut "M1 stage_live_apks (stage_apk_copy): the touch dropped" a \
    '/^stage_apk_copy() {$/,/^}$/{/^    touch -r "\$1" "\$2" /d}'
  mut "M1b stage_live_apks (stage_apk_copy): the touch dropped (two stagings differ)" b \
    '/^stage_apk_copy() {$/,/^}$/{/^    touch -r "\$1" "\$2" /d}'
  mut "M2 the code-list loop (stage_apk_copy): the touch dropped" b \
    '/^stage_apk_copy() {$/,/^}$/{/^    touch -r "\$1" "\$2" /d}'
  mut "M3 the code-list package-dir touch dropped" b \
    '/^    if \[ -n "\$_acw_src" \]; then touch -r "\$_acw_src" "\$d" /d'
  mut "M3c the fixed reference for a package dir with no source dropped" b \
    '/^    \[ -n "\$_acw_src" \] || TZ=UTC0 touch -t /d'
  mut "M3b the keep-loop package-dir touches dropped" b \
    '/^ *touch -r "\$kdir" "\$kd" /d'
  mut "M4 stage_keep_mtimes: the _meta touch dropped" b \
    '/^  touch -r "\$1" "\$2" 2>>"\$LOG" /d'
  mut "M5 stage_live_apks (stage_apk_copy): a failed touch cuts the set" c \
    '/^stage_apk_copy() {$/,/^}$/s/^\(    touch -r "\$1" "\$2" 2>>"\$LOG"\) || .*$/\1 || { rm -f "$2"; return 1; }/'
  mut "M5b the code-list loop (stage_apk_copy): a failed touch cuts the set" c \
    '/^stage_apk_copy() {$/,/^}$/s/^\(    touch -r "\$1" "\$2" 2>>"\$LOG"\) || .*$/\1 || return 1/'
  mut "M6 stage_live_apks (stage_apk_copy): touch -r against the destination" a \
    '/^stage_apk_copy() {$/,/^}$/s/^    touch -r "\$1" "\$2" /    touch -r "$2" "$2" /'
  mut "M7 the keep loop: the dir touch before the APK copies" b \
    '/^      touch -r "\$kdir" "\$kd" /d; s/^\(      knames=\$(stage_live_apks "\$kdir" "\$kd") || _acw_left=\$((_acw_left+1))\)$/      touch -r "$kdir" "$kd"\n\1/'
  mut "M7b the code-list loop: the dir touch before the _meta copy" b \
    '/^    if \[ -n "\$_acw_src" \]; then touch -r "\$_acw_src" "\$d" /d; s/^\(    if { \[ "\$mode" = ondemand \] || \[ "\$mode" = auto \]; } && \[ -d "\$META_SRC\/\$pkg" \]; then .*\)$/    [ -z "$_acw_src" ] || touch -r "$_acw_src" "$d"\n\1/'
  mut "M8 the counter file is left in the stage" f \
    '/^    rm -f "\$SLA_TF"$/d'
  mut "M9 the copy field dropped from the staging line" e \
    's/ (copy \${_acw_cms}ms, \$_acw_tf mtime kept-failed, \$_acw_ru reused)//'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
