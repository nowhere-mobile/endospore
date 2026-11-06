#!/usr/bin/env bash
# test-carry-essential-default.sh [<nowhere_roamd.sh>] [--mutate] -- NWP-20261118-10: the #apps essential carry is ON
# by default.
#
# WHY. roamd exports NOWHERE_CARRY_ESSENTIAL with `:-<default>`, and the agent's carryEssential is on only for "1".
# An image staged with no ring (every Diaspore build, a stable/prod build) bakes no conf, and neither ring conf sets
# this flag, so the default is what runs. Defaulted to 0, no image wrote the #apps per-app index, the carry or the
# uninstall tombstones. DECIDED 2026-10-30 (docs/product-decisions.md, h48 #2): the index comes from turning this flag
# on. The export is PROCESS-WIDE and the flag is #apps-only, so the #keys, #sys and data pushes pin it to 0 at their
# call sites (NWP-20260908-01) and appcode_seal passes it through. This suite pins the default, that an explicit 0
# still switches it off, the three pins and the pass-through.
#
# Checks: (A) exactly one `export NOWHERE_CARRY_ESSENTIAL=` line; (B) that line, evaluated under every POSIX shell
# present (sh, plus dash and mksh if found), reads 1 from unset, 1 from empty, 0 from "0", 1 from "1" -- a case that
# prints no value FAILS, so a line that does not evaluate never passes; (C) keystore_push, acct_seal and the out op's
# data push _push (the task text's "seal_wl_end": that helper only releases the wakelock; _push is the push the out
# op runs under it), each extracted by its `name() {` anchor, hold exactly one NOWHERE_CARRY_ESSENTIAL=0 pin each, the
# whole file holds exactly three, and appcode_seal passes NOWHERE_CARRY_ESSENTIAL="$NOWHERE_CARRY_ESSENTIAL".
# Pin counts skip comment lines (first non-blank `#`): the export's own comment names NOWHERE_CARRY_ESSENTIAL=0 as
# the way to turn the carry off.
#
#   bash test-carry-essential-default.sh [<nowhere_roamd.sh>]            # plain
#   bash test-carry-essential-default.sh [<nowhere_roamd.sh>] --mutate   # plus mutants that must each be CONVICTED
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

# The POSIX shells the evaluator runs under: sh, plus dash and mksh when present. Computed once, so a mutant's
# expected markers name the same shells the child run uses.
SHELLS="sh"
for sh_ in dash mksh; do
  if command -v "$sh_" >/dev/null 2>&1; then SHELLS="$SHELLS $sh_"; else printf 'skip: %s not installed\n' "$sh_"; fi
done
unset sh_

# The evaluator: run the export line, then print what the variable reads (or <unset>).
EVAL='eval "$1" && printf "READ=[%s]\n" "${NOWHERE_CARRY_ESSENTIAL-<unset>}"'

# read_case <shell> <case> <line> -> prints the value read, or <none> when the line did not evaluate
read_case() {
  local sh_="$1" case_="$2" line="$3" out v
  case "$case_" in
    unset) out=$(env -u NOWHERE_CARRY_ESSENTIAL "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
    empty) out=$(env NOWHERE_CARRY_ESSENTIAL= "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
    zero)  out=$(env NOWHERE_CARRY_ESSENTIAL=0 "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
    one)   out=$(env NOWHERE_CARRY_ESSENTIAL=1 "$sh_" -c "$EVAL" _ "$line" 2>&1) ;;
  esac
  case "$out" in
    *'READ=['*']'*) v=${out#*READ=[}; printf '%s' "${v%%]*}" ;;
    *) printf '%s' '<none>' ;;
  esac
}

# body <file> <anchor-ERE> <end-ERE> -> the lines from the anchor through the first end line after it; when the anchor
# matched other than once, a last line ANCHORS=<n>.
body() {
  # ENVIRON, not -v: awk -v rewrites the backslash escapes the anchors need.
  BODY_A="$2" BODY_E="$3" awk '
    BEGIN { a = ENVIRON["BODY_A"]; e = ENVIRON["BODY_E"] }
    $0 ~ a { cnt++; if (cnt == 1) { f = 1; print; next } }
    f == 1 { print; if ($0 ~ e) f = 2 }
    END { if (cnt != 1) print "ANCHORS=" cnt + 0 }' "$1"
}

# pins <text> -> how many NOWHERE_CARRY_ESSENTIAL=0 the text holds on its non-comment lines
pins() {
  { printf '%s\n' "$1" | grep -v '^[[:space:]]*#' | grep -o 'NOWHERE_CARRY_ESSENTIAL=0' || true; } | wc -l | tr -d ' '
}

run_checks() {
  local roamd="$1" lines n line sh_ c want got spec fn anchor end b
  lines=$(grep '^export NOWHERE_CARRY_ESSENTIAL=' "$roamd" || true)
  n=0
  if [ -n "$lines" ]; then n=$(printf '%s\n' "$lines" | wc -l | tr -d ' '); fi
  printf 'export lines: %s\n' "$n"
  if [ "$n" = 1 ]; then
    ok "exactly one export line"
    line="$lines"
    for sh_ in $SHELLS; do
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

  # (C) the three pins, one per function body. _push is nested in the out op, so its anchor and end are indented.
  for spec in 'keystore_push|^keystore_push\(\) \{|^\}' 'acct_seal|^acct_seal\(\) \{|^\}' \
              '_push|^    _push\(\) \{|^    \}'; do
    fn=${spec%%|*}; anchor=${spec#*|}; end=${anchor#*|}; anchor=${anchor%%|*}
    b=$(body "$roamd" "$anchor" "$end")
    case "$b" in
      *ANCHORS=*) no "$fn: anchor matched other than once ($(printf '%s' "$b" | tail -n 1))"; continue ;;
    esac
    n=$(pins "$b")
    if [ "$n" = 1 ]; then ok "$fn: 1 NOWHERE_CARRY_ESSENTIAL=0 pin"
    else no "$fn: $n NOWHERE_CARRY_ESSENTIAL=0 pins, want 1"; fi
  done
  n=$(pins "$(cat "$roamd")")
  if [ "$n" = 3 ]; then ok "whole file: 3 code-line pins"
  else no "whole file: $n pins, want 3"; fi

  b=$(body "$roamd" '^appcode_seal\(\) \{' '^\}')
  case "$b" in
    *ANCHORS=*) no "appcode_seal: anchor matched other than once ($(printf '%s' "$b" | tail -n 1))" ;;
    *'NOWHERE_CARRY_ESSENTIAL="$NOWHERE_CARRY_ESSENTIAL"'*) ok "appcode_seal passes the flag through" ;;
    *) no "appcode_seal does not pass the flag through" ;;
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
# mutant <name> <sed edit expression> <expected FAIL marker>... -- CONVICTED only when the child fails AND its output
# holds EVERY marker. An evaluator mutant passes one marker per shell in $SHELLS, so a shell that reads the mutant
# line as the baseline leaves its own marker missing and the mutant is not convicted.
mutant() {
  local name="$1" expr="$2" m out rc mk missing=""
  shift 2
  m=$(mktemp -p "$W")
  cp "$ROAMD" "$m"
  sed -i -e "$expr" "$m"
  if cmp -s "$ROAMD" "$m"; then no "$name: MUTANT DID NOT APPLY"; rm -f "$m"; return; fi
  out=$(MUTANT_CHILD=1 bash "$0" "$m" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    for mk in "$@"; do
      case "$out" in
        *"$mk"*) ;;
        *) missing="$missing [$mk]" ;;
      esac
    done
    if [ -z "$missing" ]; then ok "$name CONVICTED"
    else no "$name failed but not on$missing"; fi
  else
    no "$name SURVIVED"
  fi
  rm -f "$m"
}

# eval_mutant <name> <sed edit expression> <marker with SH for the shell name> -- one marker per shell in $SHELLS
eval_mutant() {
  local name="$1" expr="$2" tmpl="$3" sh_ markers=()
  for sh_ in $SHELLS; do markers+=("${tmpl//SH/$sh_}"); done
  mutant "$name" "$expr" "${markers[@]}"
}

eval_mutant M1 '/^export NOWHERE_CARRY_ESSENTIAL=/s/:-1}/:-0}/' 'FAIL  SH unset: read 0, want 1'
eval_mutant M1b '/^export NOWHERE_CARRY_ESSENTIAL=/s/:-1}/:-0}/' 'FAIL  SH empty: read 0, want 1'
eval_mutant M2 '/^export NOWHERE_CARRY_ESSENTIAL=/s/:-1}/-1}/' 'FAIL  SH empty: read , want 1'
mutant M3 '/^export NOWHERE_CARRY_ESSENTIAL=/p' 'FAIL  export lines: 2, want exactly 1'
mutant M4 '/^keystore_push() {/,/^}/s/NOWHERE_CARRY_ESSENTIAL=0 //' \
  'FAIL  keystore_push: 0 NOWHERE_CARRY_ESSENTIAL=0 pins, want 1'
mutant M5 '/^acct_seal() {/,/^}/s/NOWHERE_CARRY_ESSENTIAL=0 //' \
  'FAIL  acct_seal: 0 NOWHERE_CARRY_ESSENTIAL=0 pins, want 1'
mutant M6 '/^    _push() {/,/^    }/s/NOWHERE_CARRY_ESSENTIAL=0 //' \
  'FAIL  _push: 0 NOWHERE_CARRY_ESSENTIAL=0 pins, want 1'
mutant M7 '/^appcode_seal() {/,/^}/s/NOWHERE_CARRY_ESSENTIAL="\$NOWHERE_CARRY_ESSENTIAL"/NOWHERE_CARRY_ESSENTIAL=0/' \
  'FAIL  appcode_seal does not pass the flag through'

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
