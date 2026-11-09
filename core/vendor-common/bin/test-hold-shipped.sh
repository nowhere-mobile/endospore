#!/usr/bin/env bash
# test-hold-shipped.sh [<nowhere_roamd.sh>] [--mutate] -- hold_ondemand leaves the data of an app the image ships in
# place, and parks everything else as before (NWP-20261129-27).
#
# WHY THIS IS COMMITTED. A release can bundle an app a profile already keeps. hold_ondemand parked that app's restored
# data by its keep line, and nothing handed it back: Endospore lets no store install land over a system app, so no
# RESTORE-ODDATA came; AppInstallReceiver.heal skips a bundled app; captureAppCode then pruned the keep line with no
# drop record, so the hold sealed into every later head and the app ran empty, with no log line saying why.
#
# This suite EXECUTES the real extracted hold_ondemand and pkgname_ok, re-rooted to a temp tree, under every shell
# found (the device's is mksh), with pm, timeout and restorecon stubbed:
#   S1  an installed row -s names and -3 does not: in place on all four volumes, no hold dir, the counts line says 1
#   S1e the same with an empty -3 listing, which is usable
#   S2  a third-party row: parked on all four volumes
#   S3a the -s call exits 1 after printing a listing   S3b the -s call exits 0 with no output: both rows parked
#   S4  pm ignores -s (both listings name every package): nothing skipped
#   S5  -s names com.example.app.extra, the row is com.example.app: parked
#   S5b -3 names com.example.app.extra, -s names the row: in place (the -3 match is exact too)
#   S6  an ondemand row and an auto row of shipped packages: neither parked, one read for both
#   S7  the -3 call exits 1: everything parked
#   S8  a shipped row with an existing hold: its canonical is neither merged nor removed
#   S9  no keep-set: no pm call, no log line
#
#   bash test-hold-shipped.sh                # the cases, under every shell found
#   bash test-hold-shipped.sh --mutate       # ... plus mutants that must each CONVICT their case under EACH shell
#
# Pure logic -- no device. Every temp is made inside W, so a pass, a failed check or --mutate leaves nothing.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=()
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS+=("$s"); else echo "  skip  shell $s not installed"; fi
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"

U=12
SHIPPED=com.example.app
USERAPP=org.example.user
UNREADABLE='[roamd] hold: the system package list could not be read -- every kept app parked as before (NWP-20261129-27) DATE'

anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }

FN=$(anchor_of "$SUT" 'hold_ondemand() {')
PKGOK=$(anchor_of "$SUT" 'pkgname_ok() {')
ODH=$(grep -m1 -E '^ODHOLD=' "$SUT")
case "$FN" in *'nowhere-appkeep'*'$ODHOLD'*) ;; *) echo "EXTRACTION FAILED: hold_ondemand in $SUT" >&2; exit 2 ;; esac
case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $SUT" >&2; exit 2 ;; esac
[ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= in $SUT" >&2; exit 2; }
HOLD=${ODH#ODHOLD=}; HOLD=${HOLD//\"/}

# reroot <text> -> the text with each quoted /data path under $ROOT; refuses an absolute /data path left in live code.
reroot() {
  local t n
  t=$(printf '%s\n' "$1" | sed 's#"/data/#"$ROOT/data/#g')
  n=$(printf '%s\n' "$t" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_/])/data/')
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) in live code" >&2; return 2; }
  printf '%s\n' "$t"
}

# suite <hold_ondemand text> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
suite() {
  local fn="$1" quiet="${2:-}" p=0 x=0 FNR sh HARN="" R C L v t h
  FNR=$(reroot "$fn") || return 2
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  absent() { [ ! -e "$1" ]; }
  nlines() { local n; n=$(grep -cxF -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }
  val() { if [ -f "$1" ]; then cat "$1"; else printf '%s' -; fi; }

  vols() { printf '%s\n' "data/user/$U CE" "data/user_de/$U DE" "data/media/$U/Android/data DATA" "data/media/$U/Android/obb OBB"; }

  # newcase: a fresh tree and an empty keep-set. listing <s|t> <rc> <text>: one scripted pm listing.
  newcase() {
    R=$(mktemp -d -p "$W") || exit 2
    C="$R/sim"
    mkdir -p "$C" "$R/data/user/$U/com.nowhere.chooser/files"
    printf '%s' "$1" > "$R/data/user/$U/com.nowhere.chooser/files/nowhere-appkeep"
    : > "$C/pm.calls"; : > "$C/timeout.calls"; : > "$C/restorecon.calls"; : > "$R/roam.log"
  }
  listing() { printf '%s' "$3" > "$C/$1.out"; printf '%s' "$2" > "$C/$1.rc"; }
  # plant <pkg>: distinct readable bytes in the canonical dir on each volume.
  plant() {
    local v d t
    while read -r v t; do
      d="$R/$v/$1"; mkdir -p "$d"; printf '%s' "$t:$1" > "$d/f.bin"
    done < <(vols)
  }
  run() {
    local d="$R/driver.sh" e
    {
      printf "ROOT='%s'\nLOG='%s'\nC='%s'\nuid=%s\n" "$R" "$R/roam.log" "$C" "$U"
      cat <<'EOF'
set -u
date() { echo DATE; }
restorecon() { echo "$*" >> "$C/restorecon.calls"; }
timeout() { echo "$*" >> "$C/timeout.calls"; while [ "${1:-}" = -k ]; do shift 2; done; shift; "$@"; }
pm() {
  echo "$*" >> "$C/pm.calls"
  case "$*" in
    "list packages -s -u") cat "$C/s.out"; return "$(cat "$C/s.rc")" ;;
    "list packages -3 -u") cat "$C/t.out"; return "$(cat "$C/t.rc")" ;;
  esac
  return 99
}
EOF
      printf '%s\n%s\n%s\n' "$ODH" "$PKGOK" "$FNR"
      printf 'hold_ondemand "$uid"\necho "$?" > "$C/rc"\n'
    } > "$d"
    "$sh" -n "$d" 2>"$C/stderr" || { HARN="$HARN [$sh: the driver does not parse]"; return; }
    "$sh" "$d" >/dev/null 2>"$C/stderr"
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found|parameter not set' "$C/stderr")
    [ -z "$e" ] || HARN="$HARN [$sh: $e]"
  }
  rc0() { chk "$L rc 0" eqv "$(cat "$C/rc" 2>/dev/null)" 0; }
  # inplace <tag> <pkg>: each canonical file holds its exact bytes, and no hold of the package exists on any volume.
  inplace() {
    local v t
    while read -r v t; do
      chk "$L $1 $2 $t: canonical bytes in place" eqv "$(val "$R/$v/$2/f.bin")" "$t:$2"
      chk "$L $1 $2 $t: no hold dir" absent "$R/$v/com.nowhere.chooser/$HOLD/$2"
    done < <(vols)
  }
  # parked <tag> <pkg>: each hold file holds its exact bytes, and each canonical dir is gone.
  parked() {
    local v t
    while read -r v t; do
      chk "$L $1 $2 $t: parked with its bytes" eqv "$(val "$R/$v/com.nowhere.chooser/$HOLD/$2/f.bin")" "$t:$2"
      chk "$L $1 $2 $t: canonical gone" absent "$R/$v/$2"
    done < <(vols)
  }
  counts() { printf '[roamd] hold: %s kept app(s) the image ships left in place, not parked (NWP-20261129-27) DATE' "$1"; }
  nocounts() { local n; n=$(grep -c 'the image ships left in place' "$R/roam.log"); chk "$L $1 no counts line" eqv "$n" 0; }
  once_unreadable() { chk "$L $1 the unreadable line, once" eqv "$(nlines "$R/roam.log" "$UNREADABLE")" 1; }
  no_unreadable() { chk "$L $1 no unreadable line" eqv "$(nlines "$R/roam.log" "$UNREADABLE")" 0; }

  TWO="$SHIPPED	installed
$USERAPP	installed
"
  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh S1: a shipped installed row stays in place on all four volumes =="
    newcase "$SHIPPED	installed
"
    listing s 0 "package:android
package:$SHIPPED
"
    listing t 0 "package:$USERAPP
"
    plant "$SHIPPED"; run; rc0
    inplace S1 "$SHIPPED"
    chk "$L S1 no hold dir at all" eqv "$(find "$R/data" -name "$HOLD" | wc -l | tr -d ' ')" 0
    chk "$L S1 the counts line says 1" eqv "$(nlines "$R/roam.log" "$(counts 1)")" 1
    chk "$L S1 the log is that line alone (counts only, no name)" eqv "$(cat "$R/roam.log")" "$(counts 1)"
    chk "$L S1 pm read the two listings, once each" eqv "$(cat "$C/pm.calls")" "list packages -s -u
list packages -3 -u"
    chk "$L S1 both reads are bounded" eqv "$(cat "$C/timeout.calls")" "-k 2 20 pm list packages -s -u
-k 2 20 pm list packages -3 -u"
    chk "$L S1 no restorecon" eqv "$(wc -l < "$C/restorecon.calls" | tr -d ' ')" 0

    say "== $sh S1e: an empty -3 listing is usable =="
    newcase "$SHIPPED	installed
"
    listing s 0 "package:$SHIPPED
"
    listing t 0 ""
    plant "$SHIPPED"; run; rc0
    inplace S1e "$SHIPPED"
    chk "$L S1e the counts line says 1" eqv "$(nlines "$R/roam.log" "$(counts 1)")" 1
    no_unreadable S1e

    say "== $sh S2: a third-party row is parked as today =="
    newcase "$USERAPP	installed
"
    listing s 0 "package:$SHIPPED
"
    listing t 0 "package:$USERAPP
"
    plant "$USERAPP"; run; rc0
    parked S2 "$USERAPP"
    nocounts S2; no_unreadable S2

    say "== $sh S3: an unreadable -s listing parks everything =="
    newcase "$TWO"
    listing s 1 "package:$SHIPPED
"
    listing t 0 "package:$USERAPP
"
    plant "$SHIPPED"; plant "$USERAPP"; run; rc0
    parked S3a "$SHIPPED"; parked S3a "$USERAPP"
    once_unreadable S3a; nocounts S3a
    newcase "$TWO"
    listing s 0 ""
    listing t 0 "package:$USERAPP
"
    plant "$SHIPPED"; plant "$USERAPP"; run; rc0
    parked S3b "$SHIPPED"; parked S3b "$USERAPP"
    once_unreadable S3b; nocounts S3b

    say "== $sh S4: pm ignores -s: nothing is skipped =="
    newcase "$TWO"
    listing s 0 "package:$SHIPPED
package:$USERAPP
"
    listing t 0 "package:$SHIPPED
package:$USERAPP
"
    plant "$SHIPPED"; plant "$USERAPP"; run; rc0
    parked S4 "$SHIPPED"; parked S4 "$USERAPP"
    nocounts S4; no_unreadable S4

    say "== $sh S5: the match is the exact line =="
    newcase "$SHIPPED	installed
"
    listing s 0 "package:$SHIPPED.extra
"
    listing t 0 ""
    plant "$SHIPPED"; run; rc0
    parked S5 "$SHIPPED"
    nocounts S5
    newcase "$SHIPPED	installed
"
    listing s 0 "package:$SHIPPED
"
    listing t 0 "package:$SHIPPED.extra
"
    plant "$SHIPPED"; run; rc0
    inplace S5b "$SHIPPED"
    chk "$L S5b the counts line says 1" eqv "$(nlines "$R/roam.log" "$(counts 1)")" 1

    say "== $sh S6: ondemand and auto rows of shipped packages are not parked =="
    newcase "$SHIPPED	ondemand
$SHIPPED.two	auto
"
    listing s 0 "package:$SHIPPED
package:$SHIPPED.two
package:android
"
    listing t 0 ""
    plant "$SHIPPED"; plant "$SHIPPED.two"; run; rc0
    inplace S6 "$SHIPPED"; inplace S6 "$SHIPPED.two"
    chk "$L S6 the counts line says 2" eqv "$(nlines "$R/roam.log" "$(counts 2)")" 1
    chk "$L S6 one read for both rows" eqv "$(wc -l < "$C/pm.calls" | tr -d ' ')" 2

    say "== $sh S7: an unreadable -3 listing parks everything =="
    newcase "$TWO"
    listing s 0 "package:$SHIPPED
"
    listing t 1 ""
    plant "$SHIPPED"; plant "$USERAPP"; run; rc0
    parked S7 "$SHIPPED"; parked S7 "$USERAPP"
    once_unreadable S7; nocounts S7

    say "== $sh S8: a shipped row with an existing hold: no merge, no removal =="
    newcase "$SHIPPED	installed
"
    listing s 0 "package:$SHIPPED
"
    listing t 0 ""
    plant "$SHIPPED"
    while read -r v t; do
      h="$R/$v/com.nowhere.chooser/$HOLD/$SHIPPED"; mkdir -p "$h"
      printf '%s' "HOLD:$t" > "$h/hold-only.bin"
    done < <(vols)
    run; rc0
    while read -r v t; do
      h="$R/$v/com.nowhere.chooser/$HOLD/$SHIPPED"
      chk "$L S8 $t: canonical bytes in place" eqv "$(val "$R/$v/$SHIPPED/f.bin")" "$t:$SHIPPED"
      chk "$L S8 $t: the hold keeps its own file" eqv "$(val "$h/hold-only.bin")" "HOLD:$t"
      chk "$L S8 $t: the canonical is not merged into the hold" absent "$h/f.bin"
    done < <(vols)
    chk "$L S8 the counts line says 1" eqv "$(nlines "$R/roam.log" "$(counts 1)")" 1

    say "== $sh S9: no keep-set: no pm call, no log line =="
    newcase ""
    rm -f "$R/data/user/$U/com.nowhere.chooser/files/nowhere-appkeep"
    run; rc0
    chk "$L S9 no pm call" eqv "$(wc -l < "$C/pm.calls" | tr -d ' ')" 0
    chk "$L S9 no log line" eqv "$(wc -c < "$R/roam.log" | tr -d ' ')" 0
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$FN"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST convict its named case under EACH shell) =="
MF=0
# mutant <id> <label> <named case> <mutated text>: fails the run when the text did not change, the harness could not
# run, or the named case did not fail under some shell.
mutant() {
  local id="$1" label="$2" named="$3" text="$4" out mrc s miss=""
  if [ "$text" = "$FN" ]; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$text" 2>&1); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label: $out"; MF=$((MF+1)); return; fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] $named "*) echo "  ok    convicted under $s: $id $label" ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED under:$miss: $id $label"; MF=$((MF+1)); fi
}
SKIP_ARM='*) _nk=$((_nk + 1)); continue ;; esac ;;'
EXCL='case "$_tl" in *"${_nl}package:$pkg$_nl"*) ;; *) _nk=$((_nk + 1)); continue ;; esac ;;'
S_PAT='case "$_sl" in
        *"${_nl}package:$pkg$_nl"*)'
T_PAT='case "$_tl" in *"${_nl}package:$pkg$_nl"*)'
BLOCK='    # NWP-20261129-27: the image ships it, so its data stays where the restore put it (no move, no hold dir).
    if [ "$_use" = 1 ]; then
      case "$_sl" in
        *"${_nl}package:$pkg$_nl"*)
          case "$_tl" in *"${_nl}package:$pkg$_nl"*) ;; *) _nk=$((_nk + 1)); continue ;; esac ;;
      esac
    fi
'
EXT='    # DIA-20260816-19: the EXTERNAL app-data volumes'
M5=${FN/"$BLOCK"/}
[ "$M5" = "$FN" ] || M5=${M5/"$EXT"/"$BLOCK$EXT"}
mutant M1 "the skip is removed" S1 "${FN/"$SKIP_ARM"/*) ;; esac ;;}"
mutant M2 "the -3 exclusion is dropped" S4 "${FN/"$EXCL"/_nk=\$((_nk + 1)); continue ;;}"
mutant M3 "the -s status is ignored" S3a "${FN/'[ "$_src" = 0 ] && '/}"
mutant M4 "the -s match is a substring" S5 "${FN/"$S_PAT"/case \"\$_sl\" in
        *\"package:\$pkg\"*)}"
mutant M5 "the skip moves below the CE/DE loop" S1 "$M5"
mutant M6 "the -3 status is ignored" S7 "${FN/' && [ "$_trc" = 0 ]'/}"
mutant M7 "an empty -s listing is usable" S3b "${FN/' && [ -n "$_sl" ]'/}"
mutant M8 "the -3 match is a substring" S5b "${FN/"$T_PAT"/case \"\$_tl\" in *\"package:\$pkg\"*)}"

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
