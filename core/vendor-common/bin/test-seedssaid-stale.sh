#!/usr/bin/env bash
# test-seedssaid-stale.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's seedssaid arm refuses to stage the #210 seed
# when a recycled uid's stale settings_ssaid.xml survives its removal (NWP-20261127-10).
#
# WHY THIS IS COMMITTED. A settings_ssaid.xml that a REAPED user left at users/<uid> makes SettingsProvider load
# that user's userkey from disk, so the patched generateUserKeyLocked never runs and the seed is never consumed:
# every app in the new session derives the PREVIOUS profile's ANDROID_ID. The arm removes the file, but it used to
# stage the seed and answer OK without looking whether the rm worked. A directory at that name, a sepolicy that
# allows the seed's write but not the unlink, or an I/O error left the old key in place behind an OK reply. This
# suite plants each tree, drives the REAL extracted arm under every shell found, and checks what is on disk.
#
#   bash test-seedssaid-stale.sh              # the cases
#   bash test-seedssaid-stale.sh --mutate     # ... plus mutations that must each be CONVICTED under every shell
#   bash test-seedssaid-stale.sh <old roamd>  # the same cases against another copy (S2 must FAIL before the fix)
#
# Pure logic -- no device. The arm and userdir_has_record are EXTRACTED from nowhere_roamd.sh by anchor, never
# copied, and re-rooted to a temp tree; _ms, chown and restorecon are stubbed, and print gets a stand-in where the
# shell has no builtin (mksh, the device's sh, has one).
# Exit: 0 every case passes; 1 a case failed; 2 the harness could not run.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for everything this suite makes; nothing is left behind on a pass, a failed check or --mutate.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Mixed case, so a case-folding writer is caught too.
KEY64=9f3A0c7E5b21D84e6a0F3c9B17d2E58a4C0e6F1b3D97a2c5E08f4B6d1A3c7e90
[ "${#KEY64}" -eq 64 ] || { echo "KEY64 is not 64 chars" >&2; exit 2; }

# Shells: bash, plus sh/dash/mksh where they are a different interpreter (deduped by realpath).
SHELLS=""; SEEN=" "
for cand in bash sh dash mksh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }

# --- extraction (the shapes test-userdir-orphan.sh uses) ------------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
# Re-root every /data path and ASSERT it was complete: one absolute path left behind points at a real /data that
# is not here, its [ -e ] is false, and the case passes having tested nothing. Comments are stripped first.
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }
nrew() { printf '%s\n' "$1" | grep -o '\$ROOT/data/' | grep -c .; }

# build <roamd> <out>: the scenario-independent body (stubs + function + arm) into <out>; 2 when it cannot.
build() {
  local arm fn ra rf n
  arm=$(arm_of "$1" seedssaid); fn=$(fn_of "$1" userdir_has_record)
  case "$arm" in *nowhere-ssaid-seed*settings_ssaid.xml*|*settings_ssaid.xml*nowhere-ssaid-seed*) ;;
    *) echo "EXTRACTION FAILED: no '  seedssaid)' arm in $1"; return 2 ;; esac
  case "$fn" in 'userdir_has_record() {'*) ;; *) echo "EXTRACTION FAILED: no userdir_has_record in $1"; return 2 ;; esac
  ra=$(reroot "$arm"); rf=$(reroot "$fn")
  n=$(nleft "$ra"); [ "$n" = 0 ] || { echo "RE-ROOT FAILED: $n absolute /data path(s) left in the arm"; return 2; }
  n=$(nleft "$rf"); [ "$n" = 0 ] || { echo "RE-ROOT FAILED: $n absolute /data path(s) left in userdir_has_record"; return 2; }
  n=$(nrew "$ra"); [ "$n" -ge 3 ] || { echo "RE-ROOT FAILED: only $n path(s) rewritten in the arm"; return 2; }
  n=$(nrew "$rf"); [ "$n" -ge 3 ] || { echo "RE-ROOT FAILED: only $n path(s) rewritten in userdir_has_record"; return 2; }
  {
    printf 'op=seedssaid; name=x; uid=11; sesec=%s\n' "$KEY64"
    cat <<'EOF_STUBS'
LOG="$ROOT/roam.log"; RES="$ROOT/res"
_ms() { echo 0; }; chown() { :; }; restorecon() { :; }
if ! command -v print >/dev/null 2>&1; then
  print() {  # mksh's builtin, as the arm uses it: print -rn --
    local nl=1
    while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done
    if [ "$nl" = 1 ]; then printf '%s\n' "$*"; else printf '%s' "$*"; fi
  }
fi
EOF_STUBS
    printf '%s\n' "$rf" 'case "$op" in' "$ra" 'esac'
  } > "$2"
}

# --- the cases ----------------------------------------------------------------------------------------------
# suite <roamd> <quiet> <shell>: 0 every case passes, 1 a case failed, 2 the harness could not run.
suite() {
  local sut="$1" quiet="$2" sh="$3" body bad=0 R S U out rc s
  body=$(mktemp -p "$W") || return 2
  build "$sut" "$body" || return 2
  "$sh" -n "$body" 2>/dev/null || { echo "EXTRACTION FAILED: the extracted arm does not parse under $sh"; return 2; }
  KEYF=$(mktemp -p "$W") || return 2; printf '%s' "$KEY64" > "$KEYF"
  local cbad
  # say: the case's ok line, printed only when none of its checks failed.
  say() { [ -n "$cbad" ] || [ -n "$quiet" ] || echo "$@"; cbad=""; }
  fail() { echo "  FAIL [${sh##*/}] $*"; bad=1; cbad=1; }
  # scen <setup>: a fresh tree with users/11, its record and user 0's record; <setup> plants the stale name.
  scen() {
    cbad=""
    R=$(mktemp -d -p "$W") || return 2
    U="$R/data/system/users"
    mkdir -p "$U/0" "$U/11"; : > "$U/0.xml"; : > "$U/11.xml"
    eval "$1"
    S=$(mktemp -p "$W") || return 2
    printf "ROOT='%s'\n" "$R" > "$S"; cat "$body" >> "$S"
    "$sh" "$S" >/dev/null 2>"$R/stderr"; rc=$?
    out=$(cat "$R/res" 2>/dev/null)
    [ "$rc" = 0 ] || fail "$CASE: the arm exited $rc"
    s=$(cat "$R/stderr")
    case "$s" in *"not found"*|*"parameter not set"*|*"syntax error"*|*unbound*|*"bad substitution"*)
      fail "$CASE: the shell complained: $s" ;; esac
    return 0
  }
  seeded() { [ -f "$U/11/nowhere-ssaid-seed" ] && cmp -s "$KEYF" "$U/11/nowhere-ssaid-seed"; }

  CASE="S1 a plain stale file"; scen ': > "$U/11/settings_ssaid.xml"' || return 2
  [ ! -e "$U/11/settings_ssaid.xml" ] || fail "$CASE: the stale settings_ssaid.xml was not removed"
  seeded || fail "$CASE: the seed is not the 64 hex byte for byte"
  [ "$out" = OK ] || fail "$CASE: reply '$out', want OK"
  say "  ok [${sh##*/}] $CASE"

  CASE="S2 a stale DIRECTORY that rm -f cannot remove"
  scen 'mkdir -p "$U/11/settings_ssaid.xml"; : > "$U/11/settings_ssaid.xml/x"' || return 2
  [ "$out" = ERR-STALE ] || fail "$CASE: reply '$out', want ERR-STALE"
  [ ! -e "$U/11/nowhere-ssaid-seed" ] || fail "$CASE: a seed was staged over the surviving stale file"
  [ ! -e "$U/11/nowhere-ssaid-seed.tmp" ] || fail "$CASE: a .tmp was left"
  s=$(cat "$R/roam.log" 2>/dev/null)
  case "$s" in *"seedssaid user 11: the stale settings_ssaid.xml could NOT be removed -- NOT staging"*) ;;
    *) fail "$CASE: the log has no 'could NOT be removed -- NOT staging' line" ;; esac
  # Every 12-char window of the key, not a generic hex regex: rm's own stderr carries the temp path, which can.
  local i
  for i in $(seq 0 52); do
    case "$s" in *"${KEY64:$i:12}"*) fail "$CASE: the log holds key material at offset $i"; break ;; esac
  done
  say "  ok [${sh##*/}] $CASE"

  CASE="S3 no stale file"; scen ':' || return 2
  [ "$out" = OK ] || fail "$CASE: reply '$out', want OK"
  seeded || fail "$CASE: the seed is not the 64 hex byte for byte"
  say "  ok [${sh##*/}] $CASE"

  CASE="S4 a dangling link at the stale name"; scen 'ln -s "$R/nowhere" "$U/11/settings_ssaid.xml"' || return 2
  [ ! -L "$U/11/settings_ssaid.xml" ] || fail "$CASE: the dangling link was not removed"
  [ "$out" = OK ] || fail "$CASE: reply '$out', want OK"
  seeded || fail "$CASE: the seed is not the 64 hex byte for byte"
  say "  ok [${sh##*/}] $CASE"
  return $bad
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "" "$sh"; r=$?; [ "$r" -gt "$rc" ] && rc=$r; done
[ "$rc" = 0 ] || { echo "FAILED"; exit "$rc"; }
echo "== all cases pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED)"
# mut <label> <sed|awk> <program>: convicted under EACH shell's own line; inert, empty or failed is a failure.
mut() {
  local m r sh bad=0
  m=$(mktemp -p "$W")
  "$2" -e "$3" "$SUT" > "$m" || { echo "  ERROR     $1 -- the $2 program failed"; return 1; }
  [ -s "$m" ] || { echo "  ERROR     $1 -- the mutant is empty"; return 1; }
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  for sh in $SHELLS; do
    suite "$m" quiet "$sh" >/dev/null 2>&1; r=$?
    case "$r" in
      1) echo "  convicted $1 [${sh##*/}]" ;;
      0) echo "  SURVIVED  $1 [${sh##*/}]"; bad=1 ;;
      *) echo "  BROKEN    $1 [${sh##*/}] (rc=$r), not a conviction"; bad=1 ;;
    esac
  done
  return $bad
}
fails=0
mut "M1 the read-back deleted" sed \
  '/^    # NWP-20261127-10: read it back/,/^    fi$/d' || fails=$((fails+1))
mut "M2 ERR-STALE answers OK" sed \
  's/^      echo "ERR-STALE" > "\$RES"/      echo "OK" > "$RES"/' || fails=$((fails+1))
mut "M3 the refusal moved after the staging" awk '
  /^    # NWP-20261127-10: read it back/ { hold = 1 }
  hold { blk = blk $0 "\n"; if ($0 == "    fi") hold = 0; next }
  /^    echo "\[roamd\] seedssaid took / && blk != "" { printf "%s", blk; blk = "" }
  { print }' || fails=$((fails+1))
mut "M4 the read-back test inverted" sed \
  '/^    # NWP-20261127-10: read it back/,/^    fi$/s/^    if \[ -e "\$_stale" \] || \[ -L "\$_stale" \]; then$/    if ! { [ -e "$_stale" ] || [ -L "$_stale" ]; }; then/' || fails=$((fails+1))
mut "M5 the removal guard back to -e only" sed \
  '/^    _stale="\/data\/system\/users\/\$uid\/settings_ssaid.xml"$/,/rm -f "\$_stale"/s/^    if \[ -e "\$_stale" \] || \[ -L "\$_stale" \]; then$/    if [ -e "$_stale" ]; then/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
