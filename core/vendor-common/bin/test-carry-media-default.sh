#!/usr/bin/env bash
# test-carry-media-default.sh [<nowhere_roamd.sh>] [--mutate] -- NWP-20261023-09: the #media essential carry is ON
# by default.
#
# WHY. roamd exports NOWHERE_CARRY_ESSENTIAL_MEDIA with `:-<default>`, and the agent's carryEssentialMedia is on only
# for "1". An image staged with no ring (every Diaspore build, a stable/prod build) bakes no conf, so the default is
# what runs. Defaulted to 0, two handsets signed into one profile on such an image lost each other's sub-1 MiB #media
# files from the ACCOUNT. DECIDED 2026-09-12 (docs/product-decisions.md): two handsets MAY be signed in at once, so
# the shared scopes must converge. This suite pins the default, that an explicit 0 still switches it off, and that the
# #media push hands the value to the agent as _push's 5th argument.
#
# Checks: (A) exactly one `export NOWHERE_CARRY_ESSENTIAL_MEDIA=` line; (B) that line, evaluated under every POSIX
# shell present (sh, plus dash and mksh if found), reads 1 from unset, 1 from empty, 0 from "0", 1 from "1" -- a
# case that prints no value FAILS, so a line that does not evaluate never passes; (C) the #media push, extracted by
# anchor, passes "$NOWHERE_CARRY_ESSENTIAL_MEDIA" as its 5th argument.
#
#   bash test-carry-media-default.sh [<nowhere_roamd.sh>]            # plain
#   bash test-carry-media-default.sh [<nowhere_roamd.sh>] --mutate   # plus mutants that must each be CONVICTED
#
# Pure shell, no device. One temp root, removed on exit.
set -uo pipefail

MUTATE=no
ROAMD=""
for a in "$@"; do
  case "$a" in
    --mutate) MUTATE=yes ;;
    *) ROAMD="$a" ;;
  esac
done
[ -n "$ROAMD" ] || ROAMD="$(dirname "$0")/nowhere_roamd.sh"
[ -f "$ROAMD" ] || { echo "EXTRACTION FAILED: no such file: $ROAMD" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# The evaluator: run the export line, then print what the variable reads (or <unset>).
EVAL='eval "$1" && printf "READ=[%s]\n" "${NOWHERE_CARRY_ESSENTIAL_MEDIA-<unset>}"'

# read_case <shell> <case> <line> -> prints the value read, or <none> when the line did not evaluate
read_case() {
  local sh_="$1" case_="$2" line="$3" out v
  case "$case_" in
    unset) out=$(env -u NOWHERE_CARRY_ESSENTIAL_MEDIA "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
    empty) out=$(env NOWHERE_CARRY_ESSENTIAL_MEDIA= "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
    zero)  out=$(env NOWHERE_CARRY_ESSENTIAL_MEDIA=0 "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
    one)   out=$(env NOWHERE_CARRY_ESSENTIAL_MEDIA=1 "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
  esac
  case "$out" in
    *'READ=['*']'*) v=${out#*READ=[}; printf '%s' "${v%%]*}" ;;
    *) printf '%s' '<none>' ;;
  esac
}

run_checks() {
  local roamd="$1" lines n line sh_ c want got shells block ctl
  lines=$(grep '^export NOWHERE_CARRY_ESSENTIAL_MEDIA=' "$roamd" || true)
  n=0
  if [ -n "$lines" ]; then n=$(printf '%s\n' "$lines" | wc -l | tr -d ' '); fi
  printf 'export lines: %s\n' "$n"
  if [ "$n" = 1 ]; then
    ok "exactly one export line"
    line="$lines"
    shells="sh"
    for sh_ in dash mksh; do
      if command -v "$sh_" >/dev/null 2>&1; then shells="$shells $sh_"; else printf 'skip: %s not installed\n' "$sh_"; fi
    done
    for sh_ in $shells; do
      for c in unset:1 empty:1 zero:0 one:1; do
        want=${c#*:}; c=${c%%:*}
        got=$(read_case "$sh_" "$c" "$line")
        printf '%s %s: read [%s]\n' "$sh_" "$c" "$got"
        if [ "$got" = '<none>' ]; then no "$sh_ $c: did not evaluate"
        elif [ "$got" = "$want" ]; then ok "$sh_ $c: read $got"
        else no "$sh_ $c: read $got, want $want"; fi
      done
    done
  else
    no "export lines: $n, want exactly 1"
  fi

  # (C) the #media push, by anchor: the anchor line plus every continuation line, through the one after the last `\`.
  # The anchor is spelled in two pieces: split while conf_flags_scoped_test.go also scanned the test-*.sh suites
  # for `_push <label> "<profile>"`; it no longer does since NWP-20261024-06.
  block=$(awk -v a="_push"' media "${name}#media"' '
    index($0, a) { cnt++; if (cnt == 1) f = 1 }
    f == 1 { print; if ($0 !~ /\\$/) f = 2 }
    END { if (cnt != 1) print "ANCHORS=" cnt + 0 }' "$roamd")
  case "$block" in
    *ANCHORS=*) no "#media push: anchor matched other than once ($(printf '%s' "$block" | tail -n 1))"; return ;;
    '') no "#media push: anchor not found"; return ;;
  esac
  block=$(printf '%s\n' "$block" | sed -e 's/^.*\[ -d [^]]* \] *&& *//' -e 's/\\$//' | tr '\n' ' ')
  ctl=$(sh -c '_push() { printf "ARG5=[%s]\n" "$5"; }; name=N uid=U USERDIR=D STATE=S NOWHERE_CARRY_ESSENTIAL_MEDIA=__CARRY__; eval "$1"' _ "$block" 2>&1)
  printf '#media push: %s\n' "$ctl"
  case "$ctl" in
    *'ARG5=[__CARRY__]'*) ok "#media push passes the flag as arg 5" ;;
    *'ARG5=['*) no "#media push arg 5: read ${ctl#*ARG5=[}" ;;
    *) no "#media push: did not evaluate" ;;
  esac
}

if [ "$MUTATE" = no ] || [ "${MUTANT_CHILD:-}" = 1 ]; then
  run_checks "$ROAMD"
  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" = 0 ]
  exit $?
fi

run_checks "$ROAMD"

# --- mutants -----------------------------------------------------------------------------------------------
# mutant <name> <expected FAIL marker> <sed|awk-free edit expression>
mutant() {
  local name="$1" marker="$2" expr="$3" m out rc
  m=$(mktemp -p "$W")
  cp "$ROAMD" "$m"
  sed -i -e "$expr" "$m"
  if cmp -s "$ROAMD" "$m"; then no "$name: MUTANT DID NOT APPLY"; return; fi
  out=$(MUTANT_CHILD=1 bash "$0" "$m" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    case "$out" in
      *"$marker"*) ok "$name CONVICTED" ;;
      *) no "$name failed but not on [$marker]" ;;
    esac
  else
    no "$name SURVIVED"
  fi
  rm -f "$m"
}

mutant M1 'FAIL  sh unset: read 0, want 1' '/^export NOWHERE_CARRY_ESSENTIAL_MEDIA=/s/:-1}/:-0}/'
mutant M1b 'FAIL  sh empty: read 0, want 1' '/^export NOWHERE_CARRY_ESSENTIAL_MEDIA=/s/:-1}/:-0}/'
mutant M2 'FAIL  sh empty: read , want 1' '/^export NOWHERE_CARRY_ESSENTIAL_MEDIA=/s/:-1}/-1}/'
mutant M3 'FAIL  #media push arg 5: read 0' '/^ *"\$NOWHERE_CARRY_ESSENTIAL_MEDIA" \\$/s/"\$NOWHERE_CARRY_ESSENTIAL_MEDIA"/0/'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
