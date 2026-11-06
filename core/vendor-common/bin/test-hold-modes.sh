#!/usr/bin/env bash
# test-hold-modes.sh [<nowhere_roamd.sh>] [--mutate] -- which keep-set rows get their data PARKED at login.
#
# WHY THIS IS COMMITTED. hold_ondemand moves a just-restored app's CE/DE data out of the canonical dir before
# the chooser installs the app, because a restore-created dir is root-owned, remap_per_pkg cannot reown it
# (the package is not in packages.list yet), and installd then finds owner 0:0 and WIPES it. Miss a row here
# and that app silently loses ALL its roamed data on every single login -- no error surfaces in the app, the
# code comes back fine, and only `E cutils: Expected path ... but found 0:0` in logcat says why.
#
# The gate is a `case` over the keep-set's MODE COLUMN, and the file spells the same mode two ways:
#   `pkg`                      -> bare line, mode column EMPTY  == installed (the common form)
#   `pkg\tinstalled\tgroup:x`  -> mode SPELLED OUT, because field 2 must exist to reach the group in field 3
# The gate originally accepted only the empty form, so every GROUPED installed app lost its data
# (NWP-20260903-15, device-reproduced on lynx: 2 MB planted, sealed, restored, then wiped by installd).
# Java's readAppModes resolves any non-ondemand/auto value to installed; this suite is what keeps the shell
# side from drifting away from that again.
#
#   bash test-hold-modes.sh            # the mode truth table
#   bash test-hold-modes.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Pure logic -- the gate is extracted by anchor and exercised directly. No device, no restore, no store.
#
# NWP-20261112-31: and under every shell. The gate ran only inside `bash -c`, while the device runs roamd under
# mksh. Each case now writes the gate and its mode into a runner file and runs it under each of bash, dash, mksh
# and sh found (an `sh` that is one of those binaries is skipped), after that shell parses it with `-n`; every
# case line is tagged `[<sh>]`, and a mutant convicts only when every shell has its own FAIL line.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite. The runners carry it in single quotes.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
case "$W" in *\'*) echo "temp root has a quote: $W" >&2; exit 2 ;; esac

# The shells: bash, dash and mksh each under its own name, then sh unless it is one of those binaries.
SHELLS=""; seen=" "
for s in bash dash mksh sh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  if [ "$s" = sh ]; then
    case "$seen" in *" $r "*) continue ;; esac
  fi
  seen="$seen$r "; SHELLS="$SHELLS $s"
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

PASS=0; FAIL=0; BROKEN=0; TAG=""; CUR_SH=""
ok(){ PASS=$((PASS+1)); printf '  ok    %s%s\n' "$TAG" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s%s\n' "$TAG" "$1"; }

# --- extraction -------------------------------------------------------------------------------------------
# The one line that decides parking. Pulled from the script so a stale copy here cannot pass after a change.
# NWP-20261112-31: anchored on hold_ondemand's own `case "$mode" in` line, not on the patterns it accepts, so a
# gate rewritten to park everything is still extracted and RUN (it used to fail extraction, rc 2, and count as
# a conviction without one case having run).
GATE=$(awk '/^hold_ondemand\(\) \{/{f=1} f&&/^\}$/{exit} f&&/^ *case "\$mode" in /{print; exit}' "$SUT")
case "$GATE" in
  *'case "$mode" in'*esac*) ;;
  *) echo "EXTRACTION FAILED -- the hold gate moved in $SUT" >&2; exit 2 ;;
esac

# runner <file> <mode> -- the gate in a loop, as roamd runs it. The gate `continue`s to skip; reaching the end
# means parked.
runner(){
  {
    printf "mode='%s'\n" "$2"
    printf 'for _hm_i in 1; do\n'
    printf '%s\n' "$GATE"
    printf '  echo held; exit 0\n'
    printf 'done\n'
    printf 'echo skipped\n'
  } > "$1"
}
# held <sh> <mode> -> "held" | "skipped"
held(){
  local sh="$1" mode="$2" d out
  d=$(mktemp -d -p "$W")
  runner "$d/run.sh" "$mode"
  out=$("$sh" "$d/run.sh" 2>/dev/null)
  rm -rf "$d"
  printf '%s\n' "$out"
}
is(){ local got; got=$(held "$CUR_SH" "$2")
      [ "$got" = "$1" ] && ok "$3" || no "$3 -- got $got, want $1"; }
# parse_ok <sh> -- the runner must PARSE under that shell, or a syntax error would read as a verdict.
parse_ok(){
  local sh="$1" d
  d=$(mktemp -d -p "$W")
  runner "$d/run.sh" ""
  if "$sh" -n "$d/run.sh" 2>/dev/null; then rm -rf "$d"; return 0; fi
  rm -rf "$d"
  no "THE GATE BLOCK DOES NOT PARSE under $sh in $SUT"; BROKEN=1; return 1
}

for sh in $SHELLS; do
TAG="[$sh] "; CUR_SH="$sh"
parse_ok "$sh" || continue

echo "== [$sh] installed mode, BOTH spellings (a missed one means silent total data loss) =="
is held ""          "empty column (a bare \`pkg\` line) -- the common installed form"
is held "installed" "the mode SPELLED OUT -- what the chooser writes when a group token is present"

echo "== [$sh] the deferred modes this gate was built for =="
is held "ondemand"  "ondemand parks (the #204 placeholder case)"
is held "auto"      "auto parks exactly like ondemand (#130)"

echo "== [$sh] rows that must NOT be parked =="
is skipped "off"      "an app switched OFF keeps no data, so there is nothing to park"
is skipped "garbage"  "an unrecognised mode is not silently parked"
done
TAG=""; CUR_SH=""

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  # mutate <label> <sed-expr> [<prefix>] -- convicted only when EVERY shell has its own FAIL line (one whose label
  # starts with <prefix>, when given). rc 2 is the harness refusing to run, never a verdict.
  mutate(){
    local rc out sh miss=""
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    out=$(bash "$0" "$M/m.sh" 2>&1); rc=$?
    case "$rc" in
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      1)
        for sh in $SHELLS; do
          case "$out" in *"  FAIL  [$sh] ${3:-}"*) ;; *) miss="$miss $sh" ;; esac
        done
        if [ -n "$miss" ]; then no "NOT CONVICTED under$miss: $1"
        else
          ok "convicted: $1 [$SHELLS ]"
          printf '%s\n' "$out" | grep -F "  FAIL  [" | sed 's/^/      /'
        fi ;;
      *) no "INCONCLUSIVE (rc=$rc): $1 -- the mutation broke the harness, so nothing was tested" ;;
    esac
  }
  mutate "the filed bug: explicit \`installed\` drops out of the gate" \
         "s#ondemand|auto|installed|'')#ondemand|auto|'')#"
  mutate "the empty (bare-line) form drops out -- every ordinary installed app loses its data" \
         "s#ondemand|auto|installed|'')#ondemand|auto|installed)#" "empty column"
  mutate "the gate parks EVERYTHING, including switched-off apps" \
         "s#case \"\$mode\" in ondemand|auto|installed|'') ;; \*) continue;; esac#case \"\$mode\" in *) ;; esac#"
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$BROKEN" = 0 ] || exit 2
[ "$FAIL" = 0 ]
