#!/usr/bin/env bash
# test-no-mediaprovider-db-write.sh [--root <repo>] [--mutate] -- nothing in a sign-in writes MediaProvider's database
# (NWP-20261208-07).
#
# docs/product-decisions.md, 2026-11-10: MediaProvider's databases leave the seal and the restore, and nothing in a
# sign-in writes them. NWP-20261202-02 removed the calls; NWP-20261208-07 deleted the writers themselves (roamd's
# remap and insert functions, nowhere_db_fix's two media ops and the agent's list for them). This suite pins, at the
# source, that none of them comes back:
#   (a) no installed daemon script (nowhere_{gate,login,mediad,otad,provision,roamd}.sh) names
#       `providers.media.module/databases`, comments included;
#   (b) no daemon script and no non-test core/agent/*.go names `media.rows` or runs `nowhere_db_fix media-`;
#   (c) core/vendor-common/src/nowhere_db_fix.c has no `strcmp(op, "media-` arm.
# CONTROLS, so a file the suite could not read cannot pass: CONTROL-ROAMD, roamd's cutoff_keep fixed list
# (`_k=" com.nowhere.chooser ...`) names com.android.providers.media.module; CONTROL-C, nowhere_db_fix.c holds the
# telscrub arm; CONTROL-GO, the Go set holds main.go with its `case "restore":`.
#
#   bash test-no-mediaprovider-db-write.sh                 # the checks over this repository
#   bash test-no-mediaprovider-db-write.sh --root <repo>   # ... over another tree
#   bash test-no-mediaprovider-db-write.sh --mutate        # ... plus mutants on copies, each convicted by a named check
set -uo pipefail
export LC_ALL=C

MUTATE=no; ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --root) shift; ROOT="${1:-}" ;;
    *) echo "usage: $0 [--root <repo>] [--mutate]" >&2; exit 2 ;;
  esac
  shift
done
ROOT="${ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPTS="nowhere_gate.sh nowhere_login.sh nowhere_mediad.sh nowhere_otad.sh nowhere_provision.sh nowhere_roamd.sh"
BIN=core/vendor-common/bin
CSRC=core/vendor-common/src/nowhere_db_fix.c

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# hits <fixed-string> <file>...: every line holding the string, as file:line: text, the file relative to the tree
# check() reads ($HROOT). Empty when none.
HROOT=""
hits() {
  local pat="$1" f out
  shift
  for f in "$@"; do
    out=$(grep -nF -- "$pat" "$f" 2>/dev/null) || continue
    printf '%s\n' "$out" | sed "s|^|${f#"$HROOT"/}:|"
  done
}

# check <root>: runs every check over <root> and prints one `ok <label>` or `FAIL <label>` line per check, with the
# hits below a FAIL. Returns 2 when an input is missing, 1 when any check fails, 0 otherwise.
check() {
  local r="$1" s f out bad=0 scripts="" gofiles=""
  HROOT="$r"
  for s in $SCRIPTS; do
    [ -f "$r/$BIN/$s" ] || { echo "MISSING: $r/$BIN/$s"; return 2; }
    scripts="$scripts $r/$BIN/$s"
  done
  [ -f "$r/$CSRC" ] || { echo "MISSING: $r/$CSRC"; return 2; }
  for f in "$r"/core/agent/*.go; do
    [ -f "$f" ] || continue
    case "$f" in *_test.go) continue ;; esac
    gofiles="$gofiles $f"
  done
  [ -n "$gofiles" ] || { echo "MISSING: no non-test Go file in $r/core/agent"; return 2; }

  # shellcheck disable=SC2086
  out=$(hits 'providers.media.module/databases' $scripts)
  if [ -z "$out" ]; then echo "ok (a) no daemon script names providers.media.module/databases"
  else echo "FAIL (a) a daemon script names MediaProvider's database path:"; printf '%s\n' "$out" | sed 's/^/    /'; bad=1; fi

  # shellcheck disable=SC2086
  out=$(hits 'media.rows' $scripts $gofiles; hits 'nowhere_db_fix media-' $scripts $gofiles)
  if [ -z "$out" ]; then echo "ok (b) no daemon script or agent file names media.rows or runs nowhere_db_fix media-"
  else echo "FAIL (b) a daemon script or agent file names media.rows or runs nowhere_db_fix media-:"; printf '%s\n' "$out" | sed 's/^/    /'; bad=1; fi

  out=$(hits 'strcmp(op, "media-' "$r/$CSRC")
  if [ -z "$out" ]; then echo "ok (c) nowhere_db_fix.c has no media- op"
  else echo "FAIL (c) nowhere_db_fix.c has a media- op:"; printf '%s\n' "$out" | sed 's/^/    /'; bad=1; fi

  out=$(grep -nE '^[[:space:]]*_k=" com\.nowhere\.chooser .* com\.android\.providers\.media\.module ' "$r/$BIN/nowhere_roamd.sh")
  if [ -n "$out" ]; then echo "ok CONTROL-ROAMD cutoff_keep's fixed list names com.android.providers.media.module"
  else echo "FAIL CONTROL-ROAMD cutoff_keep's _k= list not found: the suite could not read nowhere_roamd.sh"; bad=1; fi

  out=$(hits 'strcmp(op, "telscrub") == 0' "$r/$CSRC")
  if [ -n "$out" ]; then echo "ok CONTROL-C nowhere_db_fix.c holds the telscrub arm"
  else echo "FAIL CONTROL-C the telscrub arm not found: the suite could not read nowhere_db_fix.c"; bad=1; fi

  out=""
  [ -f "$r/core/agent/main.go" ] && out=$(hits 'case "restore":' "$r/core/agent/main.go")
  if [ -n "$out" ]; then echo "ok CONTROL-GO main.go holds case \"restore\":"
  else echo "FAIL CONTROL-GO main.go's case \"restore\": not found: the suite could not read the agent"; bad=1; fi

  return "$bad"
}

echo "== checks: $ROOT"
out=$(check "$ROOT"); rc=$?
while IFS= read -r line; do
  case "$line" in
    "ok "*) ok "${line#ok }" ;;
    "FAIL "*) no "${line#FAIL }" ;;
    *) printf '    %s\n' "$line" ;;
  esac
done <<EOF
$out
EOF
[ "$rc" -eq 2 ] && no "an input file is missing (rc=2)"

# --- mutants -------------------------------------------------------------------------------------------------
# mutant <name> <label> <file> <python-op> <arg1> [<arg2>]: a copy of the inputs under $W, one edit, then the checks.
# <label> is the check that must FAIL (`(a)`, `CONTROL-ROAMD`, ...), or `SURVIVE` for a control mutant that must
# leave every check passing. <python-op> is append (arg1 appended), replace (arg1 -> arg2, once, must be present),
# delline (every line starting, after blanks, with arg1 removed) or newfile (arg1 written as <file>). An edit that
# changes nothing is FAILED TO APPLY, a failure.
MUT_OK=0; MUT_BAD=0
mutant() {
  local name="$1" label="$2" file="$3" op="$4" a1="$5" a2="${6:-}" d s mout mrc
  d=$(mktemp -d -p "$W") || exit 2
  mkdir -p "$d/$BIN" "$d/core/vendor-common/src" "$d/core/agent"
  for s in $SCRIPTS; do cp "$ROOT/$BIN/$s" "$d/$BIN/$s"; done
  cp "$ROOT/$CSRC" "$d/$CSRC"
  cp "$ROOT"/core/agent/*.go "$d/core/agent/"
  if ! python3 - "$d/$file" "$op" "$a1" "$a2" <<'PY'
import sys
p, op, a1, a2 = sys.argv[1:5]
if op == "newfile":
    open(p, "w").write(a1); sys.exit(0)
s = open(p).read()
if op == "append":
    t = s + a1 + "\n"
elif op == "replace":
    if a1 not in s: sys.exit(1)
    t = s.replace(a1, a2, 1)
elif op == "delline":
    t = "".join(l for l in s.splitlines(True) if not l.lstrip().startswith(a1))
else:
    sys.exit(1)
if t == s: sys.exit(1)
open(p, "w").write(t)
PY
  then MUT_BAD=$((MUT_BAD+1)); printf '  MUTANT FAILED TO APPLY  %s\n' "$name"; return; fi
  mout=$(check "$d"); mrc=$?
  if [ "$label" = SURVIVE ]; then
    if [ "$mrc" -eq 0 ]; then MUT_OK=$((MUT_OK+1)); printf '  SURVIVED as it must  %s\n' "$name"
    else MUT_BAD=$((MUT_BAD+1)); printf '  CONVICTED but must survive  %s (rc=%s)\n' "$name" "$mrc"; printf '%s\n' "$mout" | sed 's/^/      /'; fi
    return
  fi
  case "$mout" in
    *"FAIL $label "*) if [ "$mrc" -eq 1 ]; then MUT_OK=$((MUT_OK+1)); printf '  CONVICTED by %s  %s\n' "$label" "$name"; return; fi ;;
  esac
  MUT_BAD=$((MUT_BAD+1)); printf '  SURVIVED   %s (rc=%s; want FAIL %s)\n' "$name" "$mrc" "$label"
  printf '%s\n' "$mout" | sed 's/^/      /'
}

if [ "$MUTATE" = yes ]; then
  echo "== mutants"
  R=$BIN/nowhere_roamd.sh
  # shellcheck disable=SC2016
  mutant "Z1 a function naming MediaProvider's external.db appended to roamd" "(a)" "$R" append \
    'zz_media_db() { db="$2/com.android.providers.media.module/databases/external.db"; [ -f "$db" ]; }'
  # shellcheck disable=SC2016
  mutant "Z2 rm -f of \$STATE/media.rows appended to roamd" "(b)" "$R" append 'rm -f "$STATE/media.rows"'
  mutant "Z3 a media-remap arm before telscrub's in nowhere_db_fix.c" "(c)" "$CSRC" replace \
    '    if (strcmp(op, "telscrub") == 0) {' \
    '    if (strcmp(op, "media-remap") == 0) { return 0; }
    if (strcmp(op, "telscrub") == 0) {'
  mutant "Z4 a Go file writing filepath.Join(st, \"media.rows\")" "(b)" core/agent/zz_media.go newfile \
    'package main

import (
	"os"
	"path/filepath"
)

func zzMedia(st string) { _ = os.WriteFile(filepath.Join(st, "media.rows"), nil, 0o600) }
'
  mutant "Z5 cutoff_keep's _k= line removed from roamd" CONTROL-ROAMD "$R" delline '_k=" com.nowhere.chooser '
  mutant "Z6 nowhere_db_fix.c's telscrub arm renamed" CONTROL-C "$CSRC" replace \
    'strcmp(op, "telscrub") == 0' 'strcmp(op, "telscrub2") == 0'
  mutant "Z7 main.go's case \"restore\": renamed" CONTROL-GO core/agent/main.go replace \
    'case "restore":' 'case "restore2":'
  mutant "S1 a roamd log wording no check reads (must survive)" SURVIVE "$R" replace \
    'media rescan requested from the session chooser' 'media rescan asked of the session chooser'
  echo "mutants: $MUT_OK as required, $MUT_BAD not"
  [ "$MUT_BAD" -eq 0 ] || FAIL=$((FAIL+1))
fi

echo "test-no-mediaprovider-db-write: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
