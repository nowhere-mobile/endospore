#!/usr/bin/env bash
# test-appcode-gone-list.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's #apps push names only UNINSTALLED apps as
# NOWHERE_GONE_LIST, the one list that may mint an account tombstone (NWP-20261023-07).
#
# WHY THIS IS COMMITTED. DECIDED 2026-09-26 (docs/product-decisions.md, "an app switched Off leaves the store at the next
# roam"): an Off never mints the account tombstone. nowhere-appoff.list holds Offs and uninstalls alike, so the code drop
# list (APPDROP_CODE) cannot tell them apart; with NOWHERE_CARRY_ESSENTIAL on, an Off made on one handset would delete the
# app from every other signed-in handset. appcode_seal now intersects APPDROP_CODE with the chooser's uninstall record
# (nowhere-appgone.list) into /data/nowhere/appcode-dropgone and hands only that to the #apps push, as NOWHERE_GONE_LIST.
# A grep error mints nothing. No package name goes in roam.log. The data pushes never see the variable.
#
# appcode_seal's code-side block is extracted BY ANCHOR exactly as test-appcode-play-code.sh does (from `  APPDROP=""` to
# the line before `  # DIA-20260812-10 (#118): a stage we cannot create`), /data/nowhere is rewritten to a scratch root and
# USERDIR points at a fixture chooser files dir. Each case runs under every POSIX shell found (bash, sh, dash and mksh, the device shell). Cases: (1) off={a,b},
# drop={a,b,c}, gone={b} -> code list a,b and gone list b; (2) no appgone list -> empty; (3) the Play stack is never named;
# (4) an appkeepcode package is never named; (5) a grep that writes a line and exits 2 -> empty, no file left; (6) whole-line
# matching; (7) the code list is byte-identical with and without the gone list; (8) source pins on the whole script.
#
#   bash test-appcode-gone-list.sh            # the cases
#   bash test-appcode-gone-list.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
BIN=$(dirname "$(readlink -f "$SUT")")   # the real bin dir: a mutant copy lives in $W, its sibling daemons do not

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

extract_block() { # <script> -> the code-side block, or nothing
  awk '
    $0 == "  APPDROP=\"\"" { on = 1 }
    on && index($0, "  # DIA-20260812-10 (#118): a stage we cannot create") == 1 { exit }
    on { print }' "$1"
}

# run_case <shell> <block> <off> <drop> <gone|-> <keepcode|-> <grepstub:yes|no> -> key=value lines
# off/drop/gone/keepcode are space separated package lists; "-" means no such file
run_case() {
  local sh="$1" blk="$2" off="$3" drop="$4" gone="$5" kc="$6" gs="$7" root files
  root=$(mktemp -d -p "$W")
  files="$root/user/12/com.nowhere.chooser/files"
  mkdir -p "$root/nowhere" "$files"
  printf 'x\n' > "$files/nowhere-appkeep"
  # shellcheck disable=SC2086
  printf '%s\n' $off > "$files/nowhere-appoff.list"
  # shellcheck disable=SC2086
  printf '%s\n' $drop > "$files/nowhere-appdrop.list"
  # shellcheck disable=SC2086
  [ "$gone" = - ] || printf '%s\n' $gone > "$files/nowhere-appgone.list"
  # shellcheck disable=SC2086
  [ "$kc" = - ] || printf '%s\n' $kc > "$files/nowhere-appkeepcode.list"
  blk=${blk//\/data\/nowhere\//$root/nowhere/}
  ROOT="$root" BLK="$blk" GS="$gs" SHIM="$PRINT_SHIM" "$sh" -c '
    eval "$SHIM"
    LOG="$ROOT/log"; USERDIR="$ROOT/user/12"; name=probe; : > "$LOG"
    qn() { printf "%s" "$1"; }
    if [ "$GS" = yes ]; then
      grep() { for a in "$@"; do case "$a" in */nowhere-appgone.list) printf "com.ex.b\n"; return 2 ;; esac; done; command grep "$@"; }
    fi
    eval "$BLK"
    printf "code=%s\n" "$APPDROP_CODE"
    if [ -n "$APPDROP_CODE" ] && [ -f "$APPDROP_CODE" ]; then
      while IFS= read -r l; do printf "cl=%s\n" "$l"; done < "$APPDROP_CODE"
      printf "codesum=%s\n" "$(cksum < "$APPDROP_CODE")"
    fi
    printf "gone=%s\n" "$APPGONE_CODE"
    if [ -n "$APPGONE_CODE" ] && [ -f "$APPGONE_CODE" ]; then
      while IFS= read -r l; do printf "gl=%s\n" "$l"; done < "$APPGONE_CODE"
    fi
    ' </dev/null 2>/dev/null | sed "s#$root#ROOT#g"
  command grep -qE 'com\.ex\.|com\.android\.vending' "$root/log" 2>/dev/null && echo LOG-NAMES
  command rm -rf "$root"
  return 0
}

# run_left <shell> <block> -- case 5's fixture again, reporting whether the scratch file survives the block
run_left() {
  local sh="$1" blk="$2" root files
  root=$(mktemp -d -p "$W")
  files="$root/user/12/com.nowhere.chooser/files"
  mkdir -p "$root/nowhere" "$files"
  printf 'x\n' > "$files/nowhere-appkeep"
  printf 'com.ex.a\ncom.ex.b\n' > "$files/nowhere-appoff.list"
  printf 'com.ex.a\ncom.ex.b\ncom.ex.c\n' > "$files/nowhere-appdrop.list"
  printf 'com.ex.b\n' > "$files/nowhere-appgone.list"
  blk=${blk//\/data\/nowhere\//$root/nowhere/}
  ROOT="$root" BLK="$blk" SHIM="$PRINT_SHIM" "$sh" -c '
    eval "$SHIM"
    LOG="$ROOT/log"; USERDIR="$ROOT/user/12"; name=probe; : > "$LOG"
    qn() { printf "%s" "$1"; }
    grep() { for a in "$@"; do case "$a" in */nowhere-appgone.list) printf "com.ex.b\n"; return 2 ;; esac; done; command grep "$@"; }
    eval "$BLK"
    ' </dev/null >/dev/null 2>&1
  [ -e "$root/nowhere/appcode-dropgone" ] && echo LEFT-DROPGONE
  command rm -rf "$root"
  return 0
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 blk sh tag out out2 nc
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  has() { case $'\n'"$out"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; *) return 1 ;; esac; }  # an exact output line
  expect() { # <label> <present lines...> -- <absent lines...>
    local label="$1" w bad="" present=1; shift
    for w in "$@"; do
      if [ "$w" = -- ]; then present=0; continue; fi
      if [ "$present" = 1 ]; then has "$w" || bad="$bad missing[$w]"; else has "$w" && bad="$bad unwanted[$w]"; fi
    done
    if [ -z "$bad" ]; then ok "$tag $label"; else no "$tag $label:$bad  got: $(tr '\n' ' ' <<<"$out")"; fi
  }
  blk=$(extract_block "$f")
  case "$blk" in *'APPOFF='*'APPDROP_CODE='*'CODEKEEP'*) ;; *) echo "EXTRACTION FAILED -- appcode_seal's code-side block moved in $f" >&2; return 2 ;; esac
  case "$blk" in *'DIA-20260812-10'*) echo "EXTRACTION FAILED -- the end anchor moved in $f" >&2; return 2 ;; esac
  if printf '%s\n' "${blk//\/data\/nowhere\//}" | command grep -v '^ *#' | command grep -q '/data/'; then
    echo "EXTRACTION FAILED -- a /data path other than /data/nowhere in $f" >&2; return 2
  fi
  local V=com.android.vending G=ROOT/nowhere/appcode-dropgone
  for sh in "${SHELLS[@]}"; do
    tag="[${sh##*/}]"
    out=$(run_case "$sh" "$blk" "com.ex.a com.ex.b" "com.ex.a com.ex.b com.ex.c" com.ex.b - no)
    expect "(1) off={a,b} drop={a,b,c} gone={b} -> code list a,b; gone list exactly b; no name in the log" \
      cl=com.ex.a cl=com.ex.b "gone=$G" gl=com.ex.b -- cl=com.ex.c gl=com.ex.a gl=com.ex.c LOG-NAMES
    out=$(run_case "$sh" "$blk" "com.ex.a com.ex.b" "com.ex.a com.ex.b com.ex.c" - - no)
    expect "(2) no nowhere-appgone.list -> empty gone list" "gone=" -- "gone=$G"
    out=$(run_case "$sh" "$blk" "$V com.ex.a" "$V com.ex.a" "$V" - no)
    expect "(3) the Play stack is never named, even when the record says uninstalled" "gone=" -- "gone=$G" "gl=$V"
    out=$(run_case "$sh" "$blk" "com.ex.x com.ex.a" "com.ex.x com.ex.a" com.ex.x com.ex.x no)
    expect "(4) an appkeepcode package is never named" "gone=" -- "gone=$G" gl=com.ex.x
    out=$(run_case "$sh" "$blk" "com.ex.a com.ex.b" "com.ex.a com.ex.b com.ex.c" com.ex.b - yes)
    expect "(5) a grep that writes a line then exits 2 -> empty gone list" "gone=" -- "gone=$G" gl=com.ex.b
    out=$(run_left "$sh" "$blk")
    expect "(5) ... and no appcode-dropgone left behind" -- LEFT-DROPGONE
    out=$(run_case "$sh" "$blk" "com.ex.a com.ex.ab" "com.ex.a com.ex.ab" com.ex.a - no)
    expect "(6) gone={com.ex.a} does not match com.ex.ab (whole line)" "gone=$G" gl=com.ex.a -- gl=com.ex.ab
    out=$(run_case "$sh" "$blk" "com.ex.a com.ex.b" "com.ex.a com.ex.b com.ex.c" com.ex.b - no)
    out2=$(run_case "$sh" "$blk" "com.ex.a com.ex.b" "com.ex.a com.ex.b com.ex.c" - - no)
    nc=$(printf '%s\n' "$out" | command grep '^codesum=')
    if [ -n "$nc" ] && [ "$nc" = "$(printf '%s\n' "$out2" | command grep '^codesum=')" ]; then
      ok "$tag (7) the code list is byte-identical with and without the gone list"
    else no "$tag (7) the code list differs with the gone list: [$nc] vs [$(printf '%s\n' "$out2" | command grep '^codesum=')]"; fi
  done
  # (8) source pins over the WHOLE script, comments stripped
  local code gonelines dflt other
  code=$(command grep -v '^[[:space:]]*#' "$f")
  gonelines=$(printf '%s\n' "$code" | command grep 'NOWHERE_GONE_LIST')
  tag="[src]"
  if [ "$(printf '%s\n' "$gonelines" | command grep -c .)" = 1 ] \
     && case "$gonelines" in *'NOWHERE_DROP_LIST="$APPDROP_CODE"'*'NOWHERE_GONE_LIST="$APPGONE_CODE"'*) true ;; *) false ;; esac; then
    ok "$tag (8) NOWHERE_GONE_LIST is on exactly one line: the #apps push, beside NOWHERE_DROP_LIST=\"\$APPDROP_CODE\""
  else no "$tag (8) NOWHERE_GONE_LIST must be on exactly one non-comment line, the #apps push; got: $gonelines"; fi
  other=""
  for dflt in "$BIN"/nowhere_*.sh; do
    [ "$(basename "$dflt")" = nowhere_roamd.sh ] && continue
    if command grep -v '^[[:space:]]*#' "$dflt" | command grep -q 'NOWHERE_GONE_LIST'; then other="$other $(basename "$dflt")"; fi
  done
  if [ -z "$other" ]; then ok "$tag (8) no other daemon script names NOWHERE_GONE_LIST"; else no "$tag (8) NOWHERE_GONE_LIST in:$other"; fi
  if printf '%s\n' "$code" | command grep 'rm -f /data/nowhere/appcode-defer' | command grep -q '/data/nowhere/appcode-dropgone'; then
    ok "$tag (8) the post-push rm names appcode-dropgone"
  else no "$tag (8) the post-push rm does not name appcode-dropgone"; fi
  local logrefs
  logrefs=$(printf '%s\n' "$blk" | command grep -v '^[[:space:]]*#' | command grep '\$LOG' | sed 's/wc -l < "\$DROPGONE"//g' | command grep -E 'APPGONE|DROPGONE' || true)
  if [ -z "$logrefs" ]; then ok "$tag (8) no log line prints the contents of the gone lists"; else no "$tag (8) a log line names the gone list: $logrefs"; fi
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
# R1, convicted by (1)
mut "the intersect reads the Off record, not the uninstall record" \
  'grep -xF -f "$APPGONE" "$APPDROP_CODE"' 'grep -xF -f "$APPOFF" "$APPDROP_CODE"'
# R2, convicted by (3) and (4)
mut "the intersect reads the raw data list, not the code list" \
  'grep -xF -f "$APPGONE" "$APPDROP_CODE" > "$DROPGONE"' 'grep -xF -f "$APPGONE" "$APPDROP" > "$DROPGONE"'
# R3, convicted by (5)
mut "a grep status above 1 keeps the partial file" \
  'if [ "$_gnr" = 0 ] && [ -s "$DROPGONE" ]; then' 'if [ -s "$DROPGONE" ]; then'
# R4, convicted by (6)
mut "the intersect drops -x" 'grep -xF -f "$APPGONE"' 'grep -F -f "$APPGONE"'
# R5, convicted by (8), a pin: no shell runs the push site
m5=$(mktemp -p "$W")
awk '{ print } $0 == "      export NOWHERE_DROP_LIST=\"$DROPLIST\"" { print "      export NOWHERE_GONE_LIST=\"$DROPLIST\"" }' "$SUT" > "$m5"
convict "the data pushes export NOWHERE_GONE_LIST" "$m5" src; rm -f "$m5"
# R6, convicted by (8), a pin: no shell runs the push site
mut "the post-push rm loses appcode-dropgone" ' /data/nowhere/appcode-dropoff /data/nowhere/appcode-dropgone' ' /data/nowhere/appcode-dropoff' src
[ "$fail" = 0 ] && echo "all mutants convicted" || { echo "SOME MUTANTS SURVIVED OR FAILED"; exit 1; }
