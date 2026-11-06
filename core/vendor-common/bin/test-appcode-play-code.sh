#!/usr/bin/env bash
# test-appcode-play-code.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's #apps CODE-side drop list never names the
# Play stack (NWP-20261021-03).
#
# WHY THIS IS COMMITTED. DECIDED 2026-09-26 (docs/product-decisions.md, "Play Store keeps its code"): an app switched
# Off leaves the store at the next roam, but Play Store, Play services and GSF keep their carried code. The chooser's
# explicitlyTurnedOff skips those three as residue; roamd's appcode_seal read the Off record RAW, so a materialised
# On-demand or Auto Play Store switched Off sat in the record AND in nowhere-appdrop.list, was handed to the #apps push
# as NOWHERE_DROP_LIST, and the deferred carry dropped its stored APK. appcode_seal now subtracts the three from the code
# list, and a filter ERROR empties the list (dropping code cannot be undone). The DATA drop is unchanged.
#
# appcode_seal's code-side block is extracted BY ANCHOR (from `  APPDROP=""` to the line before `  # DIA-20260812-10
# (#118): a stage we cannot create`), /data/nowhere is rewritten to a scratch root and USERDIR points at a fixture
# chooser files dir. qn, print and LOG are stubs. Each case runs under every POSIX shell found (bash, sh, dash and mksh, the
# device shell, each where it is not the same binary as one already run). Cases: (1) vending in Off+drop -> only com.ex.a, KEPT counts 1; (2) the stale gms/gsf stamps -> empty;
# (3) vending alone -> empty, no path; (4) com.android.vending2 still drops (whole-line); (5) appkeepcode -> empty and the
# RETAINED line still logs; (6) no appdrop list -> empty; (7) the data list is byte-identical; (8) a grep that errors on the
# stack filter -> empty; (9) neither the stack list nor the filter's temp survives the block.
# NWP-20261121-14: (10) the drop list is a DIRECTORY (a target that cannot be written), so the stack filter errors and the
# 6-space `( : > "$DROPOFF" )` runs; (11) a `mv` stub fails the move onto the drop list and leaves a directory there, so
# the 8-space one runs. In both the block runs to its end (bash as `bash --posix`, where a bare `: >` that fails ends the
# shell), the code side is handed the directory's path (not a regular file, so no package is named), and no KEPT line
# is logged. Each of (10) and (11) also runs the WHOLE appcode_seal (lifted by name with the helpers it calls, /data/
# pointed into a scratch root, $AGENT a recording stub): the #apps push is handed that directory as NOWHERE_DROP_LIST
# (the agent's fileDropList cannot read it, so it drops nothing), the kept app and its manifest line are staged, the
# function returns 0 and logs `#apps sealed`. That is safe: a code drop list that cannot be built drops no code.
#
#   bash test-appcode-play-code.sh            # the cases
#   bash test-appcode-play-code.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

SHELLS=(); TAGS=""
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || { echo "  skip  shell $s not installed"; continue; }
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) echo "  skip  shell $s is the same binary as one already listed"; continue ;; esac
  seen="$seen$r "; SHELLS+=("$p"); TAGS="$TAGS ${p##*/}"
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell to run under" >&2; exit 2; }

PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { shift 2; printf "%s\n" "$*"; }'

extract_block() { # <script> -> the code-side block, or nothing
  awk '
    $0 == "  APPDROP=\"\"" { on = 1 }
    on && index($0, "  # DIA-20260812-10 (#118): a stage we cannot create") == 1 { exit }
    on { print }' "$1"
}

# run_case <shell> <block> <off> <drop|-> <keepcode|-> <grepstub:yes|no> -> key=value lines
# off/drop/keepcode are space separated package lists; "-" means no such file
run_case() {
  local sh="$1" blk="$2" off="$3" drop="$4" kc="$5" gs="$6" root files l
  root=$(mktemp -d -p "$W")
  files="$root/user/12/com.nowhere.chooser/files"
  mkdir -p "$root/nowhere" "$files"
  printf 'x\n' > "$files/nowhere-appkeep"
  # shellcheck disable=SC2086
  printf '%s\n' $off > "$files/nowhere-appoff.list"
  # shellcheck disable=SC2086
  [ "$drop" = - ] || printf '%s\n' $drop > "$files/nowhere-appdrop.list"
  # shellcheck disable=SC2086
  [ "$kc" = - ] || printf '%s\n' $kc > "$files/nowhere-appkeepcode.list"
  [ -f "$files/nowhere-appdrop.list" ] && echo "before=$(cksum < "$files/nowhere-appdrop.list")" > "$root/before"
  blk=${blk//\/data\/nowhere\//$root/nowhere/}
  ROOT="$root" BLK="$blk" GS="$gs" SHIM="$PRINT_SHIM" "$sh" -c '
    eval "$SHIM"
    LOG="$ROOT/log"; USERDIR="$ROOT/user/12"; name=probe; : > "$LOG"
    qn() { printf "%s" "$1"; }
    if [ "$GS" = yes ]; then
      grep() { for a in "$@"; do case "$a" in */appcode-playstack) return 2 ;; esac; done; command grep "$@"; }
    fi
    eval "$BLK"
    printf "code=%s\n" "$APPDROP_CODE"
    if [ -n "$APPDROP_CODE" ] && [ -f "$APPDROP_CODE" ]; then
      while IFS= read -r l; do printf "line=%s\n" "$l"; done < "$APPDROP_CODE"
    fi
    ' </dev/null 2>/dev/null | sed "s#$root#ROOT#g"
  [ -f "$files/nowhere-appdrop.list" ] && [ "before=$(cksum < "$files/nowhere-appdrop.list")" = "$(cat "$root/before")" ] && echo DATA-SAME
  command grep -q 'com.android.vending' "$files/nowhere-appdrop.list" 2>/dev/null && echo DATA-HAS-VENDING
  [ -e "$root/nowhere/appcode-playstack" ] && echo LEFT-PLAYSTACK
  [ -e "$root/nowhere/appcode-playfilter" ] && echo LEFT-PLAYTMP
  command grep -q 'code KEPT for' "$root/log" 2>/dev/null && echo "kept=$(sed -n 's/.*code KEPT for \([0-9]*\) Play.*/\1/p' "$root/log")"
  command grep -q 'code RETAINED for 1 inferred-orphan' "$root/log" 2>/dev/null && echo RETAINED-LOGGED
  command rm -rf "$root"
  return 0
}

# run_dropoff <shell> <block> <filter|mv> -> key=value lines (NWP-20261121-14). The fixture is case (1)'s.
# filter: $ROOT/nowhere/appcode-dropoff is a directory (with one entry) before the run.
# mv:     nothing is planted; a mv stub, for the drop list only, removes it, makes a directory there and returns 1.
run_dropoff() {
  local sh="$1" blk="$2" how="$3" root files
  root=$(mktemp -d -p "$W")
  files="$root/user/12/com.nowhere.chooser/files"
  mkdir -p "$root/nowhere" "$files"
  printf 'x\n' > "$files/nowhere-appkeep"
  printf '%s\n' com.android.vending com.ex.a > "$files/nowhere-appoff.list"
  printf '%s\n' com.android.vending com.ex.a com.ex.b > "$files/nowhere-appdrop.list"
  [ "$how" = filter ] && { mkdir "$root/nowhere/appcode-dropoff"; : > "$root/nowhere/appcode-dropoff/x"; }
  blk=${blk//\/data\/nowhere\//$root/nowhere/}
  set -- "$sh"
  [ "${sh##*/}" = bash ] && set -- "$sh" --posix
  ROOT="$root" BLK="$blk" HOW="$how" SHIM="$PRINT_SHIM" "$@" -c '
    eval "$SHIM"
    LOG="$ROOT/log"; USERDIR="$ROOT/user/12"; name=probe; : > "$LOG"
    qn() { printf "%s" "$1"; }
    if [ "$HOW" = mv ]; then
      mv() { case "$3" in */appcode-dropoff) command rm -f "$3"; command mkdir "$3"; : > "$3/x"; return 1 ;; esac; command mv "$@"; }
    fi
    eval "$BLK"
    echo REACHED
    [ -s "$ROOT/nowhere/appcode-dropoff" ] && echo dirsize=yes
    printf "code=%s\n" "$APPDROP_CODE"
    if [ -f "$APPDROP_CODE" ]; then echo codefile=yes; else echo codefile=no; fi
    if [ -n "$APPDROP_CODE" ] && [ -f "$APPDROP_CODE" ]; then
      while IFS= read -r l; do printf "line=%s\n" "$l"; done < "$APPDROP_CODE"
    fi
    ' </dev/null 2>/dev/null | sed "s#$root#ROOT#g"
  [ -e "$root/nowhere/appcode-playstack" ] && echo LEFT-PLAYSTACK
  [ -e "$root/nowhere/appcode-playfilter" ] && echo LEFT-PLAYTMP
  command grep -q 'code KEPT for' "$root/log" 2>/dev/null && echo "kept=$(sed -n 's/.*code KEPT for \([0-9]*\) Play.*/\1/p' "$root/log")"
  command rm -rf "$root"
  return 0
}

# extract_funcs <script> -> appcode_seal and the helpers it calls, WHOLE and by name, /data/ pointed at $T/data/ (for
# run_dropoff_seal), or nothing when one is not found.
extract_funcs() {
  local fn body all=""
  for fn in qn pw pkgname_ok live_code_dir live_code_ver stage_apk_copy stage_live_apks stage_keep_mtimes appcode_stage_play_dormant appcode_seal; do
    body=$(awk -v h="$fn() {" '$0 == h {f=1} f{print} f&&/^\}$/{exit}' "$1")
    case "$body" in "$fn() {"*'}') all="$all$body
" ;; *) return 0 ;; esac
  done
  printf '%s\n' "$all" | sed 's#/data/#$T/data/#g'
}

# run_dropoff_seal <shell> <funcs> <filter|mv> -> key=value lines (NWP-20261121-14). Cases (10) and (11), run through the
# WHOLE appcode_seal to its return: one kept installed app (com.a, one APK), the Off record and drop list of case (1).
# The drop list is a directory exactly as in run_dropoff. $AGENT is a stub that records, at push time, what
# NOWHERE_DROP_LIST names (its kind, and its lines when it is a file), the stage listing and the manifest.
SEAL_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
run_dropoff_seal() {
  local sh="$1" fns="$2" how="$3" T files A
  T=$(mktemp -d -p "$W")
  files="$T/user/com.nowhere.chooser/files"; A="$T/data/app/~~a==/com.a-1=="
  mkdir -p "$T/data/nowhere" "$files" "$A"
  printf 'a-base-apk-bytes\n' > "$A/base.apk"
  printf 'com.a\t1\t0\tinstalled\t%s\n' "$A/base.apk" > "$files/nowhere-appcode.list"
  printf 'com.a\tinstalled\n' > "$files/nowhere-appkeep"
  printf '%s\n' com.android.vending com.ex.a > "$files/nowhere-appoff.list"
  printf '%s\n' com.android.vending com.ex.a com.ex.b > "$files/nowhere-appdrop.list"
  [ "$how" = filter ] && { mkdir "$T/data/nowhere/appcode-dropoff"; : > "$T/data/nowhere/appcode-dropoff/x"; }
  {
    printf '%s\n' "$SEAL_SHIM"
    printf 'T=%s; HOW=%s; LOG=$T/log; USERDIR=$T/user; name=probe; pass=x; NOWHERE_CARRY_ESSENTIAL=0; : > "$LOG"\n' "$T" "$how"
    cat <<'STUBS'
if [ "$HOW" = mv ]; then
  mv() { case "$3" in */appcode-dropoff) command rm -f "$3"; command mkdir "$3"; : > "$3/x"; return 1 ;; esac; command mv "$@"; }
fi
dumpsys() { return 0; }
agent_stub() {
  local last a l
  for a; do last=$a; done
  {
    echo pushed=yes
    if [ -z "${NOWHERE_DROP_LIST:-}" ]; then echo dropkind=unset; elif [ -f "$NOWHERE_DROP_LIST" ]; then echo dropkind=file
    elif [ -d "$NOWHERE_DROP_LIST" ]; then echo dropkind=dir; else echo dropkind=other; fi
    printf 'drop=%s\n' "${NOWHERE_DROP_LIST:-}"
    if [ -f "${NOWHERE_DROP_LIST:-/nonexistent}" ]; then while IFS= read -r l; do printf 'dropline=%s\n' "$l"; done < "$NOWHERE_DROP_LIST"; fi
    printf 'stage=%s\n' "$(cd "$last" && find . -type f | LC_ALL=C sort | tr '\n' ',')"
    printf 'man=%s\n' "$(tr '\t\n' ':,' < "$last/manifest.tsv")"
  } >> "$T/calls"
  return 0
}
AGENT=agent_stub
timeout() { shift 3; "$@"; }
keystore_register_all() { :; }; _ms() { echo 0; }; _apps_stage_prog() { :; }
STUBS
    printf '%s\n' "$fns"
    printf 'appcode_seal; echo "res=$?" >> "$T/calls"\n'
  } > "$T/run.sh"
  set -- "$sh"
  [ "${sh##*/}" = bash ] && set -- "$sh" --posix
  "$@" "$T/run.sh" </dev/null >/dev/null 2>&1
  sed "s#$T#ROOT#g" "$T/calls" 2>/dev/null
  command grep -q '#apps sealed (1 pkg)' "$T/log" 2>/dev/null && echo sealed-logged
  command grep -q 'NOT SEALED' "$T/log" 2>/dev/null && echo notsealed-logged
  command grep -q 'code KEPT for' "$T/log" 2>/dev/null && echo kept-logged
  command rm -rf "$T"
  return 0
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 blk fns sh tag
  out=""
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  has() { case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
  expect() { # <label> <present...> -- <absent...>
    local label="$1" w bad="" present=1; shift
    for w in "$@"; do
      if [ "$w" = -- ]; then present=0; continue; fi
      if [ "$present" = 1 ]; then has "$w" || bad="$bad missing[$w]"; else has "$w" && bad="$bad unwanted[$w]"; fi
    done
    # no case may ever hand the code side a Play stack line, nor leave the stack list or its temp behind
    for w in line=com.android.vending$'\n' line=com.google.android.gms$'\n' line=com.google.android.gsf$'\n'; do
      case "$out"$'\n' in *"$w"*) bad="$bad stack-line[${w%$'\n'}]" ;; esac
    done
    if [ -z "$bad" ]; then ok "$tag $label"; else no "$tag $label:$bad  got: $(tr '\n' ' ' <<<"$out")"; fi
  }
  blk=$(extract_block "$f")
  case "$blk" in *'APPOFF='*'APPDROP_CODE='*'CODEKEEP'*) ;; *) echo "EXTRACTION FAILED -- appcode_seal's code-side block moved in $f" >&2; return 2 ;; esac
  case "$blk" in *'DIA-20260812-10'*) echo "EXTRACTION FAILED -- the end anchor moved in $f" >&2; return 2 ;; esac
  if printf '%s\n' "${blk//\/data\/nowhere\//}" | command grep -v '^ *#' | command grep -q '/data/'; then
    echo "EXTRACTION FAILED -- a /data path other than /data/nowhere in $f" >&2; return 2
  fi
  fns=$(extract_funcs "$f")
  [ -n "$fns" ] || { echo "EXTRACTION FAILED -- appcode_seal or a helper it calls is not found by name in $f" >&2; return 2; }
  if printf '%s\n' "$fns" | command grep -v '^[[:space:]]*#' | command grep -qE '(^|[^T])/data/'; then
    echo "EXTRACTION FAILED -- a /data/ path escaped the rewrite in $f" >&2; return 2
  fi
  local V=com.android.vending G=com.google.android.gms S=com.google.android.gsf
  for sh in "${SHELLS[@]}"; do
    tag="[${sh##*/}]"
    out=$(run_case "$sh" "$blk" "$V com.ex.a" "$V com.ex.a com.ex.b" - no)
    expect "(1) vending in Off+drop -> code list is exactly com.ex.a, KEPT counts 1" "line=com.ex.a" kept=1 -- "line=com.ex.b"
    expect "(7) the data list is byte-identical and still names vending" DATA-SAME DATA-HAS-VENDING
    expect "(9) no stack list or filter temp left" -- LEFT-PLAYSTACK LEFT-PLAYTMP
    out=$(run_case "$sh" "$blk" "$G $S" "$G $S com.ex.b" - no)
    expect "(2) stale gms/gsf stamps -> empty code list, KEPT counts 2" "code=" kept=2 -- "code=ROOT" line=
    out=$(run_case "$sh" "$blk" "$V" "$V com.ex.b" - no)
    expect "(3) vending alone -> empty, no path to an empty file" "code=" -- "code=ROOT" LEFT-PLAYSTACK LEFT-PLAYTMP
    out=$(run_case "$sh" "$blk" "com.android.vending2" "com.android.vending2" - no)
    expect "(4) com.android.vending2 still drops (whole-line match)" "line=com.android.vending2" -- kept=
    out=$(run_case "$sh" "$blk" "$V com.ex.a" "$V com.ex.a com.ex.b" com.ex.a no)
    expect "(5) with appkeepcode {com.ex.a} -> empty, RETAINED still logs" "code=" RETAINED-LOGGED -- "code=ROOT"
    out=$(run_case "$sh" "$blk" "$V com.ex.a" - - no)
    expect "(6) no appdrop list -> empty" "code=" -- "code=ROOT"
    out=$(run_case "$sh" "$blk" "$V com.ex.a" "$V com.ex.a com.ex.b" - yes)
    expect "(8) the stack filter errors -> NO code dropped" "code=" -- "code=ROOT" kept= line=
    expect "(9) no stack list or filter temp left after an error" -- LEFT-PLAYSTACK LEFT-PLAYTMP
    out=$(run_dropoff "$sh" "$blk" filter)
    expect "(10) a drop list that cannot be written: the filter errors, the block runs on (bash --posix), no code named" \
      REACHED dirsize=yes "code=ROOT/nowhere/appcode-dropoff" codefile=no -- line= kept= LEFT-PLAYSTACK LEFT-PLAYTMP
    out=$(run_dropoff "$sh" "$blk" mv)
    expect "(11) the move onto the drop list fails and it cannot be written: the block runs on (bash --posix), no code named" \
      REACHED dirsize=yes "code=ROOT/nowhere/appcode-dropoff" codefile=no -- line= kept= LEFT-PLAYSTACK LEFT-PLAYTMP
    out=$(run_dropoff_seal "$sh" "$fns" filter)
    expect "(10) the whole appcode_seal: the push is handed the drop list's directory (no package to drop), stages com.a, returns 0 and logs sealed" \
      pushed=yes dropkind=dir "drop=ROOT/data/nowhere/appcode-dropoff" "stage=./com.a/base.apk,./manifest.tsv," "man=com.a:1:0:installed:base.apk," \
      res=0 sealed-logged -- dropline= appdrop.list notsealed-logged kept-logged
    out=$(run_dropoff_seal "$sh" "$fns" mv)
    expect "(11) the whole appcode_seal: the push is handed the drop list's directory (no package to drop), stages com.a, returns 0 and logs sealed" \
      pushed=yes dropkind=dir "drop=ROOT/data/nowhere/appcode-dropoff" "stage=./com.a/base.apk,./manifest.tsv," "man=com.a:1:0:installed:base.apk," \
      res=0 sealed-logged -- dropline= appdrop.list notsealed-logged kept-logged
  done
  [ -n "$quiet" ] || printf 'shells: %s\n%d passed, %d failed\n' "${SHELLS[*]}" "$p" "$x"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" || { echo "baseline suite fails; fix it before mutating" >&2; exit 1; }
echo "-- mutations (each must be CONVICTED) --"
fail=0
# A mutant is convicted only when the suite fails AND every shell found prints its own FAIL line (mksh's included).
convict() { # <label> <mutant script>
  local res rc bad="" t
  if cmp -s "$2" "$SUT"; then echo "  MUTANT FAILED TO APPLY: $1" >&2; fail=1; return; fi
  res=$(suite "$2" 2>&1); rc=$?
  for t in $TAGS; do
    case "$res" in *"  FAIL  [$t]"*) ;; *) bad="$bad $t" ;; esac
  done
  if [ "$rc" = 0 ]; then echo "  SURVIVED  $1"; fail=1
  elif [ "$rc" = 1 ] && [ -z "$bad" ]; then echo "  convicted $1"
  else echo "  NOT CONVICTED (rc $rc, no FAIL line under:${bad:- none}) $1"; fail=1; fi
}
# mut <label> <from> <to> [all]: replace the first (or every) whole-line-prefix literal <from> with <to>
mut() {
  local m
  m=$(mktemp -p "$W")
  awk -v from="$2" -v to="$3" -v all="${4:-}" '
    (all != "" || !done) && index($0, from) {
      done = 1
      i = index($0, from); $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
    }
    { print }' "$SUT" > "$m"
  convict "$1" "$m"
  rm -f "$m"
}
# convicted by case (1)
mut "the stack filter is removed" \
  'grep -vxF -f "$PLAYSTACK" "$DROPOFF" > "$PLAYTMP" 2>/dev/null; _psr=$?' 'cp "$DROPOFF" "$PLAYTMP"; _psr=0'
# convicted by case (4)
mut "the filter drops -x" 'grep -vxF -f "$PLAYSTACK"' 'grep -vF -f "$PLAYSTACK"'
# convicted by case (8)
m8=$(mktemp -p "$W")
awk '$0 == "      ( : > \"$DROPOFF\" )" { print "      :"; next } { print }' "$SUT" > "$m8"
convict "the unfiltered list is kept on a filter error" "$m8"; rm -f "$m8"
# convicted by cases (10) and (11): each drop-list truncation put back to the bare form, by its indentation
m10=$(mktemp -p "$W")
awk '$0 == "      ( : > \"$DROPOFF\" )" { print "      : > \"$DROPOFF\""; next } { print }' "$SUT" > "$m10"
convict "the filter-error truncation of the drop list is bare again (6 spaces)" "$m10"; rm -f "$m10"
m11=$(mktemp -p "$W")
awk '$0 == "        ( : > \"$DROPOFF\" )" { print "        : > \"$DROPOFF\""; next } { print }' "$SUT" > "$m11"
convict "the failed-move truncation of the drop list is bare again (8 spaces)" "$m11"; rm -f "$m11"
# convicted by the whole-function cases (10) and (11): the push is handed the data drop list instead of the code one
mut "the #apps push is handed the data drop list" 'NOWHERE_DROP_LIST="$APPDROP_CODE"' 'NOWHERE_DROP_LIST="$APPDROP"'
# convicted by case (9)
mut "the stack list is left behind" '    rm -f "$PLAYSTACK" "$PLAYTMP"' '    rm -f "$PLAYTMP"'
# convicted by case (7)
mut "the filter rewrites the data list" 'grep -vxF -f "$PLAYSTACK" "$DROPOFF" > "$PLAYTMP"' 'grep -vxF -f "$PLAYSTACK" "$APPDROP" > "$PLAYTMP"; cp "$PLAYTMP" "$APPDROP"'
[ "$fail" = 0 ] && echo "all mutants convicted" || { echo "SOME MUTANTS SURVIVED OR FAILED"; exit 1; }
