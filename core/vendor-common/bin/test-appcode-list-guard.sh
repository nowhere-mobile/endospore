#!/usr/bin/env bash
# test-appcode-list-guard.sh [--mutate] -- NWP-20261118-01: appcode_seal validates the roamed code list before it
# builds a stage path from it.
#
# WHY THIS IS COMMITTED. appcode_seal reads nowhere-appcode.list from the chooser's CE dir. That file seals and roams
# with the profile, so whoever holds the passphrase can rewrite it. The code-list loop took field 1 as the package and
# built "$STAGE/$pkg" from it with no name check, so `../../x` made directories off the stage. It copied each APK field
# into the stage after only `[ -f "$ap" ]`, so a line could name any root-readable file (`/data/nowhere/<file>`, or
# `/data/app/../nowhere/<file>`): appcode_seal runs as su:s0 and the #apps push carried that file to a scope the
# profile holder can decrypt. captureAppCode writes only non-system apps, so every legitimate APK field is under
# /data/app. Now the loop skips a line whose package fails pkgname_ok (the log line holds no name, #39), and refuses
# an APK field that is not under /data/app or that holds a `.` or `..` segment. A refused field marks the set cut, as
# a missing one does, so an installed app falls into the live re-resolve and an on-demand one keeps its stored set.
#
# appcode_seal is lifted WHOLE, by name, from nowhere_roamd.sh (with qn, pw, pkgname_ok, appcode_stage_play_dormant,
# live_code_dir and stage_live_apks), every /data/ path pointed into a scratch root. `$AGENT` is a stub that copies
# the stage to $T/pushed at push time and records the stage listing and the manifest.
#
#   G1 a package field `../../x`: no dir made off the stage, nothing of it pushed, the valid line beside it whole
#   G2 an APK field outside /data/app (a sentinel under /data/nowhere): its bytes are not pushed
#   G3 an APK field `/data/app/../nowhere/<sentinel>`: its bytes are not pushed
#   G4 a well-formed line (base + split under /data/app): staged byte for byte and in the manifest, as before
#   G5 a trailing `group:` token still reaches the manifest
#
# NWP-20261128-38: the KEEP-SET sweep had the same hole. It took nowhere-appkeep's field 1 (the chooser's file in the
# same roamed CE dir) and passed it to live_code_dir (`dumpsys package <name>`), "$STAGE/<name>" and a manifest line
# with no name check. PackageManagerService reads an argument with no dot as a section command (or dumps everything),
# so live_code_dir took the FIRST codePath of the whole dump: a line `p` staged another app's APKs under the name `p`,
# and counted toward want_installed, so a keep-set whose only installed line was bogus turned every seal into the
# "staged 0 apk" refusal. Now the sweep skips a line whose field 1 fails pkgname_ok, after its progress line and
# before want_installed++. The K cases plant no code list, and dumpsys answers the X dir for ANY name (the full-dump
# shape), so only the guard stands between a bogus name and the stage.
#
#   K1 a bare keep-set line `p` beside a kept com.k: no stage dir or manifest line `p`, com.k as before, a nameless skip
#   K2 a keep-set line `../../x<TAB>installed`: no dir made off the stage, nothing of it pushed
#   K3 a keep-set holding only a bogus installed line: rc 0, the empty stage sealed, no "staged 0 apk" refusal
#   K4 a well-formed on-demand line with live code and placeholder metadata: staged deferred with _meta, as before
#
#   bash test-appcode-list-guard.sh            # the cases, under every shell found (bash sh dash mksh)
#   bash test-appcode-list-guard.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROAMD="${ROAMD:-$(dirname "$0")/nowhere_roamd.sh}"
[ ! -e /system/bin/nowhere_db_fix ] || { echo "refusing to run: /system/bin/nowhere_db_fix exists on this host" >&2; exit 2; }
[ ! -e /data/nowhere ] || { echo "refusing to run: /data/nowhere exists on this host" >&2; exit 2; }
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

# The run's `date` stub prints this fixed stamp. It holds a `p`, as April and September dates do, so a check that
# refused a name byte anywhere after the fixed text would fail on a correct line.
FIXED_DATE='Wed Apr 01 12:00:00 UTC 2026'

FUNCS=""
for fn in qn pw pkgname_ok appcode_stage_play_dormant live_code_dir stage_apk_copy stage_live_apks stage_keep_mtimes appcode_inputs_fp appcode_seal; do
  body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$ROAMD")
  case "$body" in "$fn() {"*'}') FUNCS="$FUNCS$body
" ;; *) echo "EXTRACTION FAILED: $fn -- not found by name" >&2; exit 2 ;; esac
done
FUNCS=$(printf '%s\n' "$FUNCS" | sed 's#/data/#$T/data/#g')
[ -z "$(printf '%s\n' "$FUNCS" | grep -v '^[[:space:]]*#' | grep -E '(^|[^T])/data/')" ] || { echo "EXTRACTION FAILED: a /data/ path escaped the rewrite" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }

# seal_case <shell> <case: G1..G5, K1..K4>
# Sets RES (appcode_seal's status), CALLS (the stub's push line), NCALLS, LOGTXT, DATALS (the entries of $T/data after
# the seal), XDIR (y when $T/data/x exists), SENTHITS (pushed files that hold the sentinel's bytes), BYTES_A /
# BYTES_D / BYTES_E / BYTES_K (y when the pushed stage holds that package's listed APKs byte for byte), and DEFERTXT
# (the defer list the push was given, one `,` after each line).
seal_case(){
  local T F A D E X S SENT t
  T=$(mktemp -d -p "$W") && [ -n "$T" ] && [ -d "$T" ] || exit 2
  # The rewritten guard reads `$T/data/app/*` unquoted in a case pattern, so $T must hold no pattern byte or dot segment.
  case "$T" in *'*'*|*'?'*|*'['*|*/./*|*/../*) echo "refusing to run: scratch root $T holds a pattern byte or a dot segment" >&2; exit 2 ;; esac
  F="$T/user/com.nowhere.chooser/files"
  A="$T/data/app/~~a==/com.a-1=="; D="$T/data/app/~~d==/com.d-1=="; E="$T/data/app/~~e==/com.e-1=="
  X="$T/data/app/~~x==/x-1=="
  mkdir -p "$T/data/nowhere" "$F" "$T/dumps" "$A" "$D" "$E" "$X"
  printf 'a-base-apk-bytes-0123456789' > "$A/base.apk"; printf 'a-split-apk-bytes-0123456789' > "$A/split.apk"
  printf 'd-base-apk-bytes-0123456789' > "$D/base.apk"; printf 'd-split-apk-bytes-0123456789' > "$D/split.apk"
  printf 'e-base-apk-bytes-0123456789' > "$E/base.apk"
  printf 'x-base-apk-bytes-0123456789' > "$X/base.apk"
  S=$(mktemp -p "$T/data/nowhere" secret-XXXXXX) || exit 2
  SENT="root-only-sentinel-${S##*/}-bytes"
  printf '%s' "$SENT" > "$S"
  t=$(printf '\t')
  case "$2" in
    G1)
      printf '../../x\t1\t0\tinstalled\t%s\ncom.a\t1\t0\tinstalled\t%s\t%s\n' "$X/base.apk" "$A/base.apk" "$A/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.a\tinstalled\n' > "$F/nowhere-appkeep" ;;
    G2)
      printf 'com.b\t1\t0\tinstalled\t%s\ncom.a\t1\t0\tinstalled\t%s\t%s\n' "$S" "$A/base.apk" "$A/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.b\tinstalled\ncom.a\tinstalled\n' > "$F/nowhere-appkeep" ;;
    G3)
      printf 'com.b\t1\t0\tinstalled\t%s\ncom.a\t1\t0\tinstalled\t%s\t%s\n' "$T/data/app/../nowhere/${S##*/}" "$A/base.apk" "$A/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.b\tinstalled\ncom.a\tinstalled\n' > "$F/nowhere-appkeep" ;;
    G4)
      printf 'com.d\t1\t0\tinstalled\t%s\t%s\n' "$D/base.apk" "$D/split.apk" > "$F/nowhere-appcode.list"
      printf 'com.d\tinstalled\n' > "$F/nowhere-appkeep" ;;
    G5)
      printf 'com.e\t1\t0\tinstalled\t%s\tgroup:grp1\n' "$E/base.apk" > "$F/nowhere-appcode.list"
      printf 'com.e\tinstalled\n' > "$F/nowhere-appkeep" ;;
    K1|K2|K3|K4)
      # The full-dump shape: dumpsys answers the X dir for any argument, as PackageManagerService does for `p`.
      printf '    codePath=%s\n    flags=[ HAS_CODE ALLOW_CLEAR_USER_DATA ]\n' "$X" > "$T/dumps/_any" ;;
  esac
  case "$2" in
    K1) printf 'p\ncom.k\tinstalled\n' > "$F/nowhere-appkeep" ;;
    K2) printf '../../x\tinstalled\ncom.k\tinstalled\n' > "$F/nowhere-appkeep" ;;
    K3) printf 'p\tinstalled\n' > "$F/nowhere-appkeep" ;;
    K4) printf 'com.o\tondemand\n' > "$F/nowhere-appkeep"
        mkdir -p "$F/nowhere-appmeta/com.o"; printf 'o-meta-bytes' > "$F/nowhere-appmeta/com.o/meta.bin" ;;
  esac
  : > "$T/calls"
  {
    printf '%s\n' "$PRINT_SHIM"
    printf 'T=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=0\n' "$T"
    cat <<'STUBS'
dumpsys(){ [ "$1" = package ] || return 0; if [ -f "$T/dumps/_any" ]; then cat "$T/dumps/_any"; elif [ -f "$T/dumps/$2" ]; then cat "$T/dumps/$2"; fi; return 0; }
agent_stub(){
  local last a
  for a; do last=$a; done
  rm -rf "$T/pushed"; command cp -r "$last" "$T/pushed"
  cat "${NOWHERE_DEFER_LIST:-/dev/null}" > "$T/deferred" 2>/dev/null
  echo "STAGE=$(cd "$last" && find . | LC_ALL=C sort | tr '\n' ',') | MAN=$(tr '\t\n' ':,' < "$last/manifest.tsv")" >> "$T/calls"
  return 0
}
STUBS
    printf 'AGENT=agent_stub\n'
    printf 'timeout(){ shift 3; "$@"; }\n'
    printf 'date(){ printf "%%s\\n" "%s"; }\n' "$FIXED_DATE"
    printf 'keystore_register_all(){ :; }; appcode_pm_snapshot(){ :; }; _ms(){ echo 0; }; _apps_stage_prog(){ :; }\n'
    printf '%s\n' "$FUNCS"
    printf 'appcode_seal; echo "$?" > "$T/res"\n'
  } > "$T/run.sh"
  "$1" "$T/run.sh" >/dev/null 2>&1
  RES=$(cat "$T/res" 2>/dev/null)
  NCALLS=$(grep -c . "$T/calls"); CALLS=$(cat "$T/calls"); LOGTXT=$(cat "$T/log" 2>/dev/null)
  DATALS=$(cd "$T/data" && ls -A | LC_ALL=C sort | tr '\n' ' ')
  XDIR=$([ -e "$T/data/x" ] && echo y)
  SENTHITS=""
  [ -d "$T/pushed" ] && SENTHITS=$(grep -rlF "$SENT" "$T/pushed" 2>/dev/null)
  BYTES_A=$(cmp -s "$T/pushed/com.a/base.apk" "$A/base.apk" && cmp -s "$T/pushed/com.a/split.apk" "$A/split.apk" && echo y)
  BYTES_D=$(cmp -s "$T/pushed/com.d/base.apk" "$D/base.apk" && cmp -s "$T/pushed/com.d/split.apk" "$D/split.apk" && echo y)
  BYTES_E=$(cmp -s "$T/pushed/com.e/base.apk" "$E/base.apk" && echo y)
  BYTES_K=$(cmp -s "$T/pushed/com.k/base.apk" "$X/base.apk" && echo y)
  DEFERTXT=$(tr '\n' ',' < "$T/deferred" 2>/dev/null)
  rm -rf "$T"
}

has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
SKIP_LINE='appcode: code-list line skipped -- not a package name'
KSKIP_LINE='appcode: keep-set line skipped -- not a package name'
# The keep-set guard, byte for byte as roamd holds it: mutant M5 moves exactly this line.
KGUARD='      pkgname_ok "$kpkg" || { echo "[roamd] appcode: keep-set line skipped -- not a package name $(date)" >> "$LOG"; continue; }'
# kskips_nameless <log>: true when the log has a keep-set skip line and every one is exactly the fixed text and stamp.
kskips_nameless(){
  local l k=0
  while IFS= read -r l; do
    case "$l" in *"$KSKIP_LINE"*) ;; *) continue ;; esac
    [ "$l" = "[roamd] $KSKIP_LINE $FIXED_DATE" ] || return 1
    k=$((k+1))
  done <<EOF_LOG
$1
EOF_LOG
  [ "$k" -gt 0 ]
}

echo "shells:$SHELLS"
for s in $SHELLS; do
  t="[$s]"

  seal_case "$s" G1
  stage=${CALLS%% | MAN=*}; man=${CALLS#* | MAN=}
  if [ -z "$XDIR" ] && [ "$DATALS" = "app nowhere " ]; then ok "$t G1 a package field ../../x makes no dir off the stage"
  else no "$t G1 ../../x -> \$T/data/x exists=[$XDIR], \$T/data holds [$DATALS]"; fi
  if [ "$NCALLS" = 1 ] && [ "$stage" = 'STAGE=.,./com.a,./com.a/base.apk,./com.a/split.apk,./manifest.tsv,' ] \
     && [ "$man" = 'com.a:1:0:installed:base.apk:split.apk,' ] && [ "$BYTES_A" = y ]; then
    ok "$t G1 nothing of the ../../x line is pushed; the valid com.a line beside it stages whole and byte for byte"
  else no "$t G1 push -> $NCALLS call(s) [$CALLS] bytes A=[$BYTES_A]"; fi
  if has "$LOGTXT" "$SKIP_LINE" && ! has "$LOGTXT" '../../x'; then ok "$t G1 the log counts the skip and holds no refused name"
  else no "$t G1 log -> [$LOGTXT]"; fi

  for gc in G2 G3; do
    seal_case "$s" $gc
    stage=${CALLS%% | MAN=*}; man=${CALLS#* | MAN=}
    [ $gc = G2 ] && what='outside /data/app' || what='/data/app/../nowhere/<sentinel>'
    if [ "$NCALLS" = 1 ] && [ -z "$SENTHITS" ] && ! has "$stage" 'secret-'; then
      ok "$t $gc an APK field $what: the sentinel's bytes are not pushed"
    else no "$t $gc $what -> $NCALLS call(s), pushed files with the sentinel [$SENTHITS], stage [$stage]"; fi
    if has "$man" 'com.b:1:0:installed,' && has "$man" 'com.a:1:0:installed:base.apk:split.apk,' && [ "$BYTES_A" = y ]; then
      ok "$t $gc the refused field names nothing in the manifest; the valid com.a line still stages whole"
    else no "$t $gc manifest [$man] bytes A=[$BYTES_A]"; fi
  done

  seal_case "$s" G4
  if [ "$RES" = 0 ] && [ "$NCALLS" = 1 ] && has "$CALLS" 'STAGE=.,./com.d,./com.d/base.apk,./com.d/split.apk,./manifest.tsv, |' \
     && has "$CALLS" 'MAN=com.d:1:0:installed:base.apk:split.apk,' && [ "$BYTES_D" = y ] \
     && ! has "$LOGTXT" 'skipped' && ! has "$LOGTXT" 'did not copy whole'; then
    ok "$t G4 a well-formed line (base + split under /data/app) stages byte for byte and is named in the manifest"
  else no "$t G4 valid line -> rc [$RES] $NCALLS call(s) [$CALLS] bytes D=[$BYTES_D] log [$LOGTXT]"; fi

  seal_case "$s" G5
  if [ "$NCALLS" = 1 ] && has "$CALLS" 'MAN=com.e:1:0:installed:base.apk:group:grp1,' && ! has "$CALLS" './com.e/group' && [ "$BYTES_E" = y ]; then
    ok "$t G5 a trailing group: token reaches the manifest and is not staged as a file"
  else no "$t G5 group token -> $NCALLS call(s) [$CALLS] bytes E=[$BYTES_E]"; fi

  seal_case "$s" K1
  if [ "$RES" = 0 ] && [ "$NCALLS" = 1 ] && [ "$CALLS" = 'STAGE=.,./com.k,./com.k/base.apk,./manifest.tsv, | MAN=com.k:0:0:installed:base.apk,' ] \
     && [ "$BYTES_K" = y ]; then
    ok "$t K1 a bare keep-set line p stages nothing and takes no manifest line; com.k beside it stages as before"
  else no "$t K1 bare p -> rc [$RES] $NCALLS call(s) [$CALLS] bytes K=[$BYTES_K]"; fi
  if kskips_nameless "$LOGTXT" && ! has "$LOGTXT" 'recovered p '; then ok "$t K1 the log counts the keep-set skip and holds no refused name"
  else no "$t K1 log -> [$LOGTXT]"; fi

  seal_case "$s" K2
  if [ -z "$XDIR" ] && [ "$DATALS" = "app nowhere " ]; then ok "$t K2 a keep-set line ../../x makes no dir off the stage"
  else no "$t K2 ../../x -> \$T/data/x exists=[$XDIR], \$T/data holds [$DATALS]"; fi
  if [ "$NCALLS" = 1 ] && [ "$CALLS" = 'STAGE=.,./com.k,./com.k/base.apk,./manifest.tsv, | MAN=com.k:0:0:installed:base.apk,' ] \
     && kskips_nameless "$LOGTXT" && ! has "$LOGTXT" '../../x'; then
    ok "$t K2 nothing of the ../../x keep-set line is pushed, and the log holds no refused name"
  else no "$t K2 push -> $NCALLS call(s) [$CALLS] log [$LOGTXT]"; fi

  seal_case "$s" K3
  if [ "$RES" = 0 ] && [ "$NCALLS" = 1 ] && [ "$CALLS" = 'STAGE=.,./manifest.tsv, | MAN=' ] \
     && ! has "$LOGTXT" 'staged 0 apk' && has "$LOGTXT" '#apps sealed (0 pkg)'; then
    ok "$t K3 a keep-set holding only a bogus installed line seals the empty stage: it is no wanted installed app"
  else no "$t K3 bogus-only -> rc [$RES] $NCALLS call(s) [$CALLS] log [$LOGTXT]"; fi

  seal_case "$s" K4
  if [ "$RES" = 0 ] && [ "$NCALLS" = 1 ] && [ "$CALLS" = 'STAGE=.,./com.o,./com.o/_meta,./com.o/_meta/meta.bin,./com.o/base.apk,./manifest.tsv, | MAN=com.o:0:0:ondemand:base.apk,' ] \
     && [ "$DEFERTXT" = 'com.o/base.apk,' ] && ! has "$LOGTXT" 'skipped'; then
    ok "$t K4 a well-formed on-demand keep-set line stages deferred with its _meta, as before"
  else no "$t K4 on-demand -> rc [$RES] $NCALLS call(s) [$CALLS] defer [$DEFERTXT] log [$LOGTXT]"; fi
done

if [ "$MUTATE" = yes ]; then
  echo "mutants (each must FAIL a line under EACH shell):"
  MT=$(mktemp -d -p "$W")
  mut_file(){ # mut_file <label>: the conviction check, on a prepared $MT/roamd.sh
    local rc s bad=""
    if cmp -s "$ROAMD" "$MT/roamd.sh"; then no "MUTANT DID NOT APPLY: $1"; return; fi
    ROAMD="$MT/roamd.sh" bash "$0" > "$MT/out" 2>&1; rc=$?
    for s in $SHELLS; do grep -q "FAIL  \[$s\]" "$MT/out" || bad="$bad $s"; done
    if grep -q 'EXTRACTION FAILED' "$MT/out"; then no "MUTANT BROKE EXTRACTION: $1"
    elif [ "$rc" = 1 ] && [ -z "$bad" ]; then ok "convicted under every shell: $1"
    else no "NOT CONVICTED (rc $rc, shells with no FAIL line:$bad): $1"; fi
  }
  mut(){ # mut <label> <sed script>
    sed -e "$2" "$ROAMD" > "$MT/roamd.sh"
    mut_file "$1"
  }
  mut "M1 the pkgname_ok line deleted (G1)" '/^    pkgname_ok "\$pkg" || { echo "\[roamd\] appcode: code-list line skipped/d'
  mut "M2 the APK path case line deleted (G2)" '/^      case "\$ap" in \*\/\.\.\/\*|/d'
  mut "M3 the */../* alternative removed (G3)" 's#^\(      case "\$ap" in \)\*/\.\./\*|#\1#'
  mut "M4 (task M1) the keep-set guard deleted (K1)" '/^      pkgname_ok "\$kpkg" || {/d'
  # M5 (task M2): the guard moved after want_installed++. awk, not sed, so the moved text is KGUARD byte for byte.
  # A guard or anchor that is not there exactly once leaves roamd unchanged, so mut_file reports DID NOT APPLY.
  KG="$KGUARD" awk '
    $0 == ENVIRON["KG"] { g++; next }
    { print }
    $0 == "      want_installed=$((want_installed+1))" { print ENVIRON["KG"]; w++ }
    END { exit !(g == 1 && w == 1) }' "$ROAMD" > "$MT/roamd.sh" || cp "$ROAMD" "$MT/roamd.sh"
  mut_file "M5 (task M2) the keep-set guard moved after want_installed++ (K3)"
  mut "M6 (task M3) pkgname_ok replaced by a bare */* case (K1)" 's#^      pkgname_ok "\$kpkg" || {.*#      case "$kpkg" in */*) continue;; esac#'
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
