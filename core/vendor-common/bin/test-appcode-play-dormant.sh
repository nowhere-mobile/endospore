#!/usr/bin/env bash
# test-appcode-play-dormant.sh [<nowhere_roamd.sh>] [--mutate] -- an unkept, still-installed Play stack member that
# the Off record or the inferred-orphan list names is staged DEFERRED by the #apps seal (NWP-20261024-07).
#
# WHY THIS IS COMMITTED. DECIDED 2026-09-26 (docs/product-decisions.md, "Play Store keeps its code"): an Off Play
# Store's data drops and its code stays in the account as a dormant carried copy. An On-demand one already had that
# shape; an INSTALLED-mode one was in neither input of appcode_seal's stage (its keep line goes with the Off), so its
# APKs were never staged and the account lost the Play stack. appcode_stage_play_dormant stages such a package
# DEFERRED: the APKs under the stage dir, one defer-list line each, NO manifest line (nothing installs it at login),
# and none of the counters that guard "keep the previous head when nothing installed staged".
#
# The helper and the real live_code_dir / stage_live_apks are extracted BY NAME; qn is a stub, print a shim, dumpsys
# reads fixtures, and only the `/data/app/*` case pattern is rewritten to a scratch root. Every case runs under every
# POSIX shell found (bash, sh, dash and mksh, the device shell). Cases: (1) vending live, Off, not kept -> two APKs staged, two defer lines, no manifest line,
# count 1; (2) gms in the inferred-orphan list; (3) already staged -> nothing, no duplicate; (4) kept -> nothing;
# (5) named nowhere -> nothing; (6) a non-stack package in the Off record -> nothing; (7) not installed, or SYSTEM
# -> nothing and no empty dir; (8) whole-line match; (9) source pins on appcode_seal and the helper.
#
#   bash test-appcode-play-dormant.sh            # the cases
#   bash test-appcode-play-dormant.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

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

strip() { sed 's/^[[:space:]]*#.*$//' | sed 's/[[:space:]]#[[:space:]].*$//'; }

# run_case <shell> <sut.sh> <fixture root> <seen> <off> <keepcode> <ak> <pkg set label> -> key=value lines
# off / keepcode / ak are space separated package lists ("-" = no such file)
run_case() {
  local sh="$1" sut="$2" fx="$3" sn="$4" off="$5" kc="$6" ak="$7" root p l
  root=$(mktemp -d -p "$W")
  mkdir -p "$root/stage"
  : > "$root/man"; : > "$root/log"
  # shellcheck disable=SC2086
  [ "$off" = - ] || printf '%s\n' $off > "$root/off"
  # shellcheck disable=SC2086
  [ "$kc" = - ] || printf '%s\n' $kc > "$root/kc"
  if [ "$ak" = - ]; then : > "$root/ak"; else
    # shellcheck disable=SC2086
    for p in $ak; do printf '%s\tinstalled\n' "$p"; done > "$root/ak"
  fi
  ROOT="$root" SUTF="$sut" SN="$sn" SHIM="$PRINT_SHIM" "$sh" -c '
    eval "$SHIM"
    . "$SUTF"
    STAGE="$ROOT/stage"; DEFER="$ROOT/defer"; MAN="$ROOT/man"; LOG="$ROOT/log"; name=probe
    qn() { printf "%s" "$1"; }
    staged=0; n=0; want_installed=0; seen="$SN"
    appcode_stage_play_dormant "$seen" "$ROOT/off" "$ROOT/kc" "$ROOT/ak"
    [ "$staged$n$want_installed" = 000 ] || : > "$ROOT/moved"
    ' </dev/null >/dev/null 2>&1
  [ -s "$root/man" ] && echo "MAN-LINE"
  [ -f "$root/moved" ] && echo "COUNTERS-MOVED"   # a marker file: the case shell's own stdout goes to /dev/null
  [ -f "$root/defer" ] && while IFS= read -r l; do echo "defer=$l"; done < "$root/defer"
  ( cd "$root/stage" && for d in *; do [ -d "$d" ] || continue
      set -- "$d"/*; [ -e "$1" ] || { echo "empty-dir=$d"; continue; }
      for f in "$d"/*; do echo "staged=$f"; done; done )
  sed -n 's/.*#apps: \([0-9]*\) Play stack pkg(s) not kept this session staged DEFERRED.*/logcount=\1/p' "$root/log"
  command grep -q 'com\.android\|com\.google' "$root/log" 2>/dev/null && echo LOG-NAMES-A-PACKAGE
  rm -rf "$root"
  return 0
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 fns rew sut fx sh tag d
  out=""
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  expect() { # <label> <present...> -- <absent...>   (lines compared whole)
    local label="$1" w bad="" present=1; shift
    for w in "$@"; do
      if [ "$w" = -- ]; then present=0; continue; fi
      if [ "$present" = 1 ]; then case $'\n'"$out"$'\n' in *$'\n'"$w"$'\n'*) ;; *) bad="$bad missing[$w]" ;; esac
      else case $'\n'"$out"$'\n' in *$'\n'"$w"$'\n'*) bad="$bad unwanted[$w]" ;; esac; fi
    done
    case "$out" in *COUNTERS-MOVED*|*LOG-NAMES-A-PACKAGE*) bad="$bad $(tr '\n' ' ' <<<"$out")" ;; esac
    if [ -z "$bad" ]; then ok "$tag $label"; else no "$tag $label:$bad  got: $(tr '\n' ' ' <<<"$out")"; fi
  }
  fns=$(sed -n '/^live_code_dir() {$/,/^}$/p; /^stage_apk_copy() {$/,/^}$/p; /^stage_live_apks() {$/,/^}$/p; /^appcode_stage_play_dormant() {$/,/^}$/p' "$f")
  case "$fns" in
    *'live_code_dir() {'*'stage_apk_copy() {'*'stage_live_apks() {'*'appcode_stage_play_dormant() {'*) ;;
    *) echo "EXTRACTION FAILED -- live_code_dir, stage_apk_copy, stage_live_apks or appcode_stage_play_dormant missing in $f" >&2; return 2 ;;
  esac
  fx=$(mktemp -d -p "$W")
  rew=$(printf '%s\n' "$fns" | sed 's#in /data/app/\*)#in '"$fx"'/data/app/*)#')
  case "$rew" in *"in $fx/data/app/*)"*) ;; *) echo "EXTRACTION FAILED -- the /data/app case pattern moved in $f" >&2; return 2 ;; esac
  sut="$fx/sut.sh"
  {
    echo "dumpsys() { [ \"\$1\" = package ] || return 0; [ -f '$fx/dumps/'\"\$2\" ] && cat '$fx/dumps/'\"\$2\"; return 0; }"
    printf '%s\n' "$rew"
  } > "$sut"
  mkdir -p "$fx/dumps"
  local pk
  for pk in com.android.vending com.google.android.gms com.google.android.gsf com.example.off com.android.vending2; do
    d="$fx/data/app/~~x==/$pk-A=="; mkdir -p "$d"
    : > "$d/base.apk"; : > "$d/split_config.arm64.apk"
    printf 'Packages:\n  Package [%s] (1):\n    codePath=%s\n    flags=[ HAS_CODE ]\n' "$pk" "$d" > "$fx/dumps/$pk"
  done
  # a SYSTEM-flagged vending is a separate fixture dump
  mkdir -p "$fx/sysdumps"
  local V=com.android.vending G=com.google.android.gms
  for sh in "${SHELLS[@]}"; do
    tag="[${sh##*/}]"
    out=$(run_case "$sh" "$sut" "$fx" " " "$V" - -)
    expect "(1) vending live, Off, not kept -> two APKs staged, two defer lines, no manifest line, count 1" \
      "staged=$V/base.apk" "staged=$V/split_config.arm64.apk" "defer=$V/base.apk" "defer=$V/split_config.arm64.apk" logcount=1 -- MAN-LINE
    [ "$(grep -c '^defer=' <<<"$out")" = 2 ] && ok "$tag (1) exactly two defer lines" || no "$tag (1) exactly two defer lines: $(tr '\n' ' ' <<<"$out")"
    out=$(run_case "$sh" "$sut" "$fx" " " - "$G" -)
    expect "(2) gms in the inferred-orphan list -> staged deferred" "staged=$G/base.apk" "defer=$G/base.apk" logcount=1 -- MAN-LINE
    out=$(run_case "$sh" "$sut" "$fx" " $V " "$V" - -)
    expect "(3) already staged -> nothing staged, no duplicate defer line" -- "defer=$V/base.apk" "staged=$V/base.apk" logcount=1
    out=$(run_case "$sh" "$sut" "$fx" " " "$V" - "$V")
    expect "(4) kept (in the keep-set) -> nothing staged" -- "staged=$V/base.apk" "defer=$V/base.apk" logcount=1
    out=$(run_case "$sh" "$sut" "$fx" " " - - -)
    expect "(5) named in neither list -> nothing staged" -- "staged=$V/base.apk" "defer=$V/base.apk" logcount=1
    out=$(run_case "$sh" "$sut" "$fx" " " com.example.off - -)
    expect "(6) a non-stack package in the Off record -> nothing staged" -- "staged=com.example.off/base.apk" "defer=com.example.off/base.apk" logcount=1
    # (7) not installed (no dump) and a SYSTEM-flagged copy
    mv "$fx/dumps/$V" "$fx/dumps/$V.off"
    out=$(run_case "$sh" "$sut" "$fx" " " "$V" - -)
    expect "(7) named but not installed -> nothing staged, no empty dir" -- "staged=$V/base.apk" "empty-dir=$V" logcount=1
    printf 'Packages:\n  Package [%s] (1):\n    codePath=%s\n    flags=[ SYSTEM HAS_CODE ]\n' "$V" "$(dirname "$fx/data/app/~~x==/$V-A==/base.apk")" > "$fx/dumps/$V"
    out=$(run_case "$sh" "$sut" "$fx" " " "$V" - -)
    expect "(7) SYSTEM-flagged -> nothing staged, no empty dir" -- "staged=$V/base.apk" "empty-dir=$V" logcount=1
    mv "$fx/dumps/$V.off" "$fx/dumps/$V"
    out=$(run_case "$sh" "$sut" "$fx" " " com.android.vending2 - -)
    expect "(8) whole-line match: com.android.vending2 stages nothing" -- "staged=$V/base.apk" "defer=$V/base.apk" logcount=1
  done
  # (9) source pins, comments stripped
  local seal helper
  seal=$(sed -n '/^appcode_seal() {$/,/^}$/p' "$f" | strip)
  helper=$(sed -n '/^appcode_stage_play_dormant() {$/,/^}$/p' "$f" | strip)
  tag="[pins]"
  local calls
  calls=$(grep -c 'appcode_stage_play_dormant "\$seen" "\$APPOFF" "\$CODEKEEP" "\$AK"' <<<"$seal")
  if [ "$calls" = 1 ]; then ok "$tag (9) appcode_seal calls the helper exactly once"; else no "$tag (9) appcode_seal calls the helper $calls times"; fi
  if awk '/done < "\$AK"/ { a = NR } /appcode_stage_play_dormant "/ { c = NR } /#apps staged/ { t = NR } END { exit !(a && c && t && a < c && c < t) }' <<<"$seal"; then
    ok "$tag (9) the call sits after done < \"\$AK\" and before the #apps staged line"
  else no "$tag (9) the call is not between done < \"\$AK\" and the #apps staged line"; fi
  local w
  for w in '$MAN' 'staged=' 'n=$((' 'want_installed' 'seen=' 'echo' '_apps_stage_prog' '_stg_'; do
    case "$helper" in *"$w"*) no "$tag (9) the helper names $w" ;; *) ok "$tag (9) the helper does not name $w" ;; esac
  done
  if grep -q 'local ' <<<"$helper" && ! grep -E '^\s*for ([a-z]+) in' <<<"$helper" | grep -vq 'apd_'; then
    ok "$tag (9) its variables are declared local"
  else no "$tag (9) its variables are not declared local"; fi
  local lv
  for lv in $(grep -oE '\bapd_[a-z]+' <<<"$helper" | sort -u); do
    case "$(grep '^  local ' <<<"$helper")" in *" $lv"*) ;; *) no "$tag (9) $lv is not declared local" ;; esac
  done
  [ -n "$quiet" ] || printf 'shells: %s\n%d passed, %d failed\n' "${SHELLS[*]}" "$p" "$x"
  [ "$x" = 0 ]
}

if [ "$MUTATE" = no ]; then suite "$SUT"; exit $?; fi

suite "$SUT" || { echo "baseline suite fails; fix it before mutating" >&2; exit 1; }
echo "-- mutations (each must be CONVICTED) --"
fail=0
# convict <label> <mutant script> [<tags that must each print a FAIL line>]: a mutant is convicted only when the suite
# fails AND every expected tag has its own FAIL line (default: every shell found, so mksh's own line counts). A
# pin-only mutant names its pin tag: it changes a line no shell ever runs.
convict() {
  local res rc bad="" t
  if cmp -s "$2" "$SUT"; then echo "  MUTANT FAILED TO APPLY: $1" >&2; fail=1; return; fi
  res=$(suite "$2" 2>&1); rc=$?
  for t in ${3:-$TAGS}; do
    case "$res" in *"  FAIL  [$t]"*) ;; *) bad="$bad $t" ;; esac
  done
  if [ "$rc" = 0 ]; then echo "  SURVIVED  $1"; fail=1
  elif [ "$rc" = 1 ] && [ -z "$bad" ]; then echo "  convicted ${3:+($3 only) }$1"
  else echo "  NOT CONVICTED (rc $rc, no FAIL line under:${bad:- none}) $1"; fail=1; fi
}
# mut <label> <from> <to> [<want tags>]: replace the first literal <from> with <to>
mut() {
  local m
  m=$(mktemp -p "$W")
  awk -v from="$2" -v to="$3" '
    !done && index($0, from) {
      done = 1
      i = index($0, from); $0 = substr($0, 1, i - 1) to substr($0, i + length(from))
    }
    { print }' "$SUT" > "$m"
  convict "$1" "$m" "${4:-}"
  rm -f "$m"
}
mut "P1 the defer write is removed (the code would ride essential)" '"$apd_bn" >> "$DEFER"' '"$apd_bn" >> /dev/null'
mut "P2 a manifest line is written" 'apd_k=$((apd_k+1))' 'apd_k=$((apd_k+1)); printf "%s\n" "$apd_pkg" >> "$MAN"'
mut "P3 the SEEN check is removed" 'case "$1" in *" $apd_pkg "*) continue ;; esac' ':'
mut "P4 the keep-set check is removed" "'\$1 == p { f = 1 }" "'\$1 == \"never\" { f = 1 }"
mut "P5 the stack filter is widened" 'for apd_pkg in com.android.vending com.google.android.gms com.google.android.gsf; do' 'for apd_pkg in com.android.vending com.google.android.gms com.google.android.gsf com.example.off; do'
mut "P6 -x is dropped from the match" 'grep -qxF "$apd_pkg"' 'grep -qF "$apd_pkg"'
# P7 changes the call site in appcode_seal, which no shell runs: only pin (9) convicts it
mut "P7 the call is removed from appcode_seal" 'appcode_stage_play_dormant "$seen" "$APPOFF" "$CODEKEEP" "$AK"' ':' pins
# P8 is convicted by cases (1) and (2) under each shell (the counters marker), and by pin (9)
mut "P8 the helper increments staged" 'apd_k=$((apd_k+1))' 'apd_k=$((apd_k+1)); staged=$((staged+1))'
[ "$fail" = 0 ] && echo "all mutants convicted" || { echo "SOME MUTANTS SURVIVED OR FAILED"; exit 1; }
