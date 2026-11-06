#!/usr/bin/env bash
# test-extra-user-paths.sh [<nowhere_roamd.sh>] [--mutate] -- the reap's extra per-user paths by edition
# (NWP-20261124-20; #9 of "twenty-four answers to the open-decisions list ...", 2026-11-02, option B).
#
# WHY THIS IS COMMITTED. On Endospore every worker runs in an endospore_* domain, and endospore_priv is denied
# search on /data/misc/gatekeeper, /data/misc/profiles/cur and /data/misc/user (the SB run, lynx 2026102201,
# enforcing, 2026-10-24). Each reap logged three `rm: ... Permission denied` lines and three avc denials, and the
# framework removed those directories with the user anyway. Decision #9: on Endospore extra_user_paths emits only
# /data/system/adservices/<uid> and /data/backup/<uid>; Diaspore (su:s0) and every other context keep all five.
#
#   bash test-extra-user-paths.sh            # the cases under every shell found
#   bash test-extra-user-paths.sh --mutate   # ... plus mutants that must each be CONVICTED under each shell
#
# Pure logic -- no device. extra_user_paths is EXTRACTED from nowhere_roamd.sh by anchor, never copied, and its
# context file /proc/self/attr/current is re-rooted by sed to a fixture under the temp root. Each fixture ends in
# a NUL, as the kernel writes it. EXTRAPATHS_SHELLS=<names> restricts the shells (the mutant runner uses it).
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for everything this suite makes; the EXIT trap is the only one.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""
for s in ${EXTRAPATHS_SHELLS:-bash dash mksh sh}; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "skip $s: not found"; fi
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

CTX=/proc/self/attr/current
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }

F=$(fn_of "$SUT" extra_user_paths)
[ -n "$F" ] || { echo "EXTRACTION FAILED: function extra_user_paths not found in $SUT" >&2; exit 2; }

# P1: the context path is a fixed literal, read once, with no override. On the code before this change it is
# absent, which is a FAIL here (the cases below then show the wrong output too), never a skip.
n=$(printf '%s\n' "$F" | grep -cF "$CTX")
if [ "$n" = 1 ]; then ok "P1 extra_user_paths reads $CTX exactly once"; else bad "P1 extra_user_paths names $CTX $n time(s), want 1"; fi

U=10
ADS="/data/system/adservices/$U"; PRO="/data/misc/profiles/cur/$U"; BAK="/data/backup/$U"
MUS="/data/misc/user/$U"; GKP="/data/misc/gatekeeper/$U"
TWO="$ADS
$BAK"
FIVE="$ADS
$PRO
$BAK
$MUS
$GKP"

# fixture <name> <kind> [<context>]: a case dir holding the re-rooted function; kind = ctx | missing | empty.
fixture() {
  local d
  d=$(mktemp -d -p "$W") || exit 2
  case "$2" in
    ctx) printf '%s\0' "$3" > "$d/ctx" ;;
    empty) : > "$d/ctx" ;;
    missing) ;;
  esac
  printf '%s\n' "$F" | sed "s#$CTX#$d/ctx#g" > "$d/fn.sh"
  if grep -qF "$CTX" "$d/fn.sh"; then echo "RE-ROOT INCOMPLETE: $CTX left in the copy" >&2; exit 2; fi
  eval "D_$1=\$d"
}
fixture priv ctx 'u:r:endospore_priv:s0'
fixture mediad ctx 'u:r:endospore_mediad:s0'
fixture su ctx 'u:r:su:s0'
fixture missing missing
fixture empty empty

# check <label> <dir> <uid> <want>: run the function under each shell; stdout must equal <want>, stderr be empty.
check() {
  local label="$1" d="$2" uid="$3" want="$4" sh out err
  for sh in $SHELLS; do
    out=$("$sh" -c '. "$1"; extra_user_paths "$2"' _ "$d/fn.sh" "$uid" 2>"$d/err")
    err=$(cat "$d/err")
    if [ "$out" = "$want" ] && [ -z "$err" ]; then
      ok "$label $sh"
    else
      bad "$label $sh: got [$(printf '%s' "$out" | tr '\n' ' ')] stderr [$err]"
    fi
  done
}

check "E1 endospore_priv -> adservices, backup" "$D_priv" "$U" "$TWO"
check "E2 endospore_mediad -> adservices, backup" "$D_mediad" "$U" "$TWO"
check "D1 su:s0 -> all five in order" "$D_su" "$U" "$FIVE"
check "D2 missing context file -> all five" "$D_missing" "$U" "$FIVE"
check "D3 empty context file -> all five" "$D_empty" "$U" "$FIVE"
for c in priv mediad su missing empty; do
  eval "d=\$D_$c"
  check "G $c uid '' -> nothing" "$d" "" ""
  check "G $c uid 'x' -> nothing" "$d" "x" ""
done

# --- mutants ------------------------------------------------------------------------------------------------
# Each edit is keyed on lines INSIDE extra_user_paths (the function's anchor to its closing brace), and on the
# arm it sits in where the two arms share a line. A mutant that does not change the file is a failure.
mutate_one() {
  local name="$1" prog="$2" md s rc
  md=$(mktemp -d -p "$W") || exit 2
  if ! awk "$prog" "$SUT" > "$md/m"; then bad "mutant $name: awk failed"; return; fi
  if cmp -s "$SUT" "$md/m"; then bad "mutant $name did not apply"; return; fi
  for s in $SHELLS; do
    EXTRAPATHS_SHELLS="$s" bash "$0" "$md/m" >/dev/null 2>&1; rc=$?
    if [ "$rc" != 0 ]; then ok "CONVICTED $name $s"; else bad "SURVIVED $name $s"; fi
  done
}

if [ "$MUTATE" = yes ]; then
  # Shared awk preamble: f = inside extra_user_paths, e = inside its endospore arm, o = inside its *) arm.
  PRE='$0 == "extra_user_paths() {" {f=1} f && $0 ~ /^    u:r:endospore_\*\)$/ {e=1} f && $0 ~ /^    \*\)$/ {o=1}'
  END_ARM='f && $0 ~ /^      ;;$/ {e=0; o=0} f && $0 == "}" {f=0}'
  # The arm bodies M1 swaps in, read by awk from its environment (no quoting through the program text).
  export E5='      echo "/data/system/adservices/$1"
      echo "/data/misc/profiles/cur/$1"
      echo "/data/backup/$1"
      echo "/data/misc/user/$1"
      echo "/data/misc/gatekeeper/$1"'
  export E2='      echo "/data/system/adservices/$1"
      echo "/data/backup/$1"'
  # M1 the edition test inverted: the endospore arm gets the five, *) gets the two.
  mutate_one "M1 edition test inverted" "$PRE"' e && /^      echo / {if (!d1) {print ENVIRON["E5"]; d1=1}; next} o && /^      echo / {if (!d2) {print ENVIRON["E2"]; d2=1}; next} '"$END_ARM"' {print}'
  # M2 the prefix widened to every context.
  mutate_one "M2 prefix widened to u:r:*" '$0 == "extra_user_paths() {" {f=1} f && $0 ~ /^    u:r:endospore_\*\)$/ {sub(/endospore_\*/, "*")} f && $0 == "}" {f=0} {print}'
  # M3-M5 one of the three left in on Endospore.
  for path in misc/profiles/cur misc/user misc/gatekeeper; do
    mutate_one "M3-5 /data/$path left in on Endospore" "$PRE"' e && /^      echo "\/data\/backup\/\$1"$/ {print; print "      echo \"/data/'"$path"'/$1\""; next} '"$END_ARM"' {print}'
  done
  # M6 adservices dropped on Endospore.
  mutate_one "M6 adservices dropped on Endospore" "$PRE"' e && /^      echo "\/data\/system\/adservices\/\$1"$/ {next} '"$END_ARM"' {print}'
  # M7 the uid guard removed.
  mutate_one "M7 uid guard removed" '$0 == "extra_user_paths() {" {f=1} f && index($0, "case \"$1\" in '"''"'|*[!0-9]*) return 0;; esac") {next} f && $0 == "}" {f=0} {print}'
fi

echo "shells:$SHELLS; $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
