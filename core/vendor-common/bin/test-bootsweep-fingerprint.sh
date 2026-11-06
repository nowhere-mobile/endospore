#!/usr/bin/env bash
# test-bootsweep-fingerprint.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's `fingerprint` category
# (NWP-20261011-34), run for real rather than grepped.
#
# The Goodix fingerprint HAL keeps a device-wide plaintext roster of which Android users enrolled and
# authenticated in /data/vendor/fingerprint/ (NWP-20260914-13). The category must:
#   - empty the directory's CONTENTS, dotfiles included, and never remove the directory itself (the HAL owns it);
#   - report what it removed, and LEFT:<m> when something stayed;
#   - say ABSENT only when /data/vendor lists and holds no `fingerprint`. A failing `[ -d ]` or a failing listing
#     is a denial as often as an absence, so it must read UNREACHABLE -- the dropbox lesson in roamd;
#   - append to `_swept` exactly once on every path (the bootsweep INVARIANT), and never print a file name.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (its header line up to the next `  # ---` header or the
# `  # Report what was actually removed` line), never copied and never by line count; if the anchors move,
# extraction fails loudly rather than a stale copy passing forever. /data/vendor is substituted by a temp dir.
#
# NWP-20261112-35: and under every shell. The cases ran the block with `eval` in a bash subshell, over a bash-only
# `ls` stub, and the mutants were judged by a bash re-run's exit code alone -- while the device runs the boot sweep
# under mksh, and this category is what empties the roster of identities (NWP-20260914-13). Its dotfile glob, an
# unmatched glob left literal for `rm -rf`, the status of `_l=$(ls -1A ...)` and a function override of `rm` are
# all shell behaviour. Each case now writes the block, its stubs and its variables into a runner file and runs it
# under each shell found, parsed by that shell first; every line is tagged `[<sh>]`, and a mutant convicts only
# when its re-run under each shell exits 1 with a `FAIL  [<sh>]` line of its own (an exit 2 is a broken mutant,
# never a conviction). bash, dash and mksh always run under their own names; sh is skipped only when it is the
# same binary as one of them; ONLY_SHELL=<name> (internal, the mutant re-run) runs exactly that shell with no
# dedup, and exits 2 when it is not available. Extraction now also stops at the `bootsweep result:` echo and asks
# only for the category's own `fingerprint=` report, so a lost ABSENT or UNREACHABLE report is convicted by the
# cases that assert it rather than by an extraction exit. Every temp lives under one root, removed on exit.
#
#   bash test-bootsweep-fingerprint.sh            # the behaviour cases
#   bash test-bootsweep-fingerprint.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh run under their own names; sh only when it is not the same binary as one of them.
SHELLS=()
if [ -n "${ONLY_SHELL:-}" ]; then
  case "$ONLY_SHELL" in bash|sh|dash|mksh) ;; *) echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2 ;; esac
  command -v "$ONLY_SHELL" >/dev/null 2>&1 || { echo "FAIL  ONLY_SHELL=$ONLY_SHELL is not an available shell"; exit 2; }
  SHELLS=("$ONLY_SHELL")
else
  for s in bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS+=("$s"); done
  if p=$(command -v sh 2>/dev/null); then
    r=$(readlink -f "$p"); dup=""
    for s in "${SHELLS[@]}"; do [ "$(readlink -f "$(command -v "$s")")" = "$r" ] && { dup=$s; break; }; done
    if [ -n "$dup" ]; then echo "skip shell sh: same binary as $dup"; else SHELLS+=(sh); fi
  fi
fi
[ "${#SHELLS[@]}" -gt 0 ] || { echo "FAIL  no shell found"; exit 2; }

PASS=0; FAIL=0; SH=all; SHP=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
HDR='  # --- fix 9: fingerprint (NWP-20261011-34) ---'
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1 \
         || index($0, "  echo \"[roamd] bootsweep result:") == 1) { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'fingerprint='*) ;;
  *) echo "EXTRACTION FAILED: the fingerprint category" >&2; exit 2 ;; esac
# The category must sit INSIDE the bootsweep op, before its result line -- extracted correctly but dead code
# outside the op would pass every case below.
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  $0 == h { blk = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && blk > op && res > blk) ? "in" : "out" }' "$SUT")

# --- harness --------------------------------------------------------------------------------------------
# /data/vendor -> $R/vendor. `[ -d ` -> _tdir, and ls -> a stub, so a denial can be simulated per path (root
# ignores mode bits, so chmod 000 proves nothing on a CI runner that runs as root).
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data/vendor@$R/vendor@g' -e 's@\[ -d @_tdir @g')
# The stubs are POSIX: they run inside the runner file under each shell. `_st_*` names never meet the block's.
STUBS=$(cat <<'EOF'
_tdir(){ case " ${DENY_D:-} " in *" $1 "*) return 1 ;; esac; [ -d "$1" ]; }
ls(){ for _st_last; do :; done; case " ${DENY_LS:-} " in *" $_st_last "*) return 1 ;; esac; command ls "$@"; }
case "${NORM:-}" in 1) rm(){ :; } ;; esac
EOF
)
# mksh has `print`; the shim gives bash and dash one, so a block that calls it does not fail only off mksh.
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
# runblk <root>  -> prints the resulting _swept; the LOG is <root>/log. The block runs from <root>/run.sh under
# "$SHP": the shim, the case's variables, the stubs, the block, then the _swept it left.
runblk(){
  local r="$1" f="$1/run.sh" n v
  {
    printf '%s\n' "$PRINT_SHIM"
    for n in R NORM DENY_D DENY_LS; do
      if [ "$n" = R ]; then v=$r; else v=${!n:-}; fi
      case "$v" in *"'"*) echo "runblk: a quote in $n" >&2; return 2 ;; esac
      printf "%s='%s'\n" "$n" "$v"
    done
    printf '%s\n' 'LOG="$R/log"; _swept=""' "$STUBS" "$RUNBLK" "printf '%s' \"\$_swept\""
  } > "$f" || return 2
  "$SHP" "$f" 2>>"$r/stderr"
}
once(){ [ "$(printf '%s\n' "$1" | grep -o 'fingerprint=' | wc -l)" -eq 1 ]; }
mkfp(){   # mkfp <root>: three HAL files and one dotfile
  mkdir -p "$1/vendor/fingerprint" "$1/vendor/other"
  echo "0xc,1757800000" > "$1/vendor/fingerprint/EnrollEventContainer"
  echo "8.1,9.2" > "$1/vendor/fingerprint/FingerSizes.EnrollmentFingerSizes"
  echo "1" > "$1/vendor/fingerprint/AuthStats.0"
  echo "x" > "$1/vendor/fingerprint/.hal_state"
}

cases(){
echo "== [$SH] position =="
[ "$POS" = in ] && ok "the category sits inside the bootsweep op, before its result line" \
  || no "the category is not between the bootsweep op and its result line"

echo "== [$SH] a populated directory ends empty, still exists, and reports its count =="
T=$(mktemp -d -p "$W"); mkfp "$T"; S=$(runblk "$T")
[ "$S" = " fingerprint=4" ] && ok "reports fingerprint=4" || no "reported '$S', want ' fingerprint=4'"
[ -d "$T/vendor/fingerprint" ] && ok "the directory itself is kept (the HAL owns it)" || no "the directory was removed"
[ -z "$(command ls -1A "$T/vendor/fingerprint" 2>/dev/null)" ] && ok "the directory is empty, dotfile included" \
  || no "left behind: $(command ls -1A "$T/vendor/fingerprint" 2>/dev/null | tr '\n' ' ')"
[ -d "$T/vendor/other" ] && ok "a sibling under /data/vendor is untouched" || no "a sibling was removed"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
if grep -q -e EnrollEvent -e FingerSizes -e AuthStats -e hal_state "$T/log" "$T/stderr" 2>/dev/null \
   || case "$S" in *Enroll*|*Finger*|*Auth*|*hal_*) true ;; *) false ;; esac; then no "a file name was printed"
else ok "no file name in the result, the log or stderr"; fi
rm -rf "$T"

echo "== [$SH] a subdirectory goes with the contents =="
T=$(mktemp -d -p "$W"); mkfp "$T"; mkdir -p "$T/vendor/fingerprint/sub"; : > "$T/vendor/fingerprint/sub/f"
S=$(runblk "$T")
[ "$S" = " fingerprint=5" ] && [ -z "$(command ls -1A "$T/vendor/fingerprint")" ] && ok "fingerprint=5, emptied" \
  || no "reported '$S', left '$(command ls -1A "$T/vendor/fingerprint" | tr '\n' ' ')'"
rm -rf "$T"

echo "== [$SH] an empty directory reports zero =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor/fingerprint"; S=$(runblk "$T")
[ "$S" = " fingerprint=0" ] && ok "reports fingerprint=0" || no "reported '$S'"
rm -rf "$T"

echo "== [$SH] what stays is reported as LEFT =="
T=$(mktemp -d -p "$W"); mkfp "$T"; S=$(NORM=1 runblk "$T")
[ "$S" = " fingerprint=4/LEFT:4" ] && ok "a failing rm reports fingerprint=4/LEFT:4" || no "reported '$S'"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
rm -rf "$T"

echo "== [$SH] absent: /data/vendor lists and holds no fingerprint =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor/other"; S=$(runblk "$T")
[ "$S" = " fingerprint=ABSENT" ] && ok "reports fingerprint=ABSENT" || no "reported '$S'"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
[ ! -e "$T/vendor/fingerprint" ] && ok "nothing is created" || no "the directory was created"
rm -rf "$T"

echo "== [$SH] a denial is never ABSENT =="
T=$(mktemp -d -p "$W"); mkfp "$T"; S=$(DENY_D="$T/vendor/fingerprint" runblk "$T")
[ "$S" = " fingerprint=UNREACHABLE" ] && ok "[ -d ] denied on an existing directory: UNREACHABLE" || no "reported '$S'"
[ "$(command ls -1A "$T/vendor/fingerprint" | wc -l)" -eq 4 ] && ok "and nothing was touched" || no "files were removed"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkfp "$T"; S=$(DENY_LS="$T/vendor/fingerprint" runblk "$T")
[ "$S" = " fingerprint=UNREACHABLE" ] && ok "the directory exists but cannot be listed: UNREACHABLE" || no "reported '$S'"
[ "$(command ls -1A "$T/vendor/fingerprint" | wc -l)" -eq 4 ] && ok "and nothing was removed blind" || no "files were removed"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor/other"; S=$(DENY_D="$T/vendor/fingerprint" DENY_LS="$T/vendor" runblk "$T")
[ "$S" = " fingerprint=UNREACHABLE" ] && ok "/data/vendor cannot be listed: UNREACHABLE, not ABSENT" || no "reported '$S'"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkdir -p "$T/vendor"; S=$(runblk "$T")
[ "$S" = " fingerprint=UNREACHABLE" ] && ok "/data/vendor lists EMPTY: UNREACHABLE (proves nothing)" || no "reported '$S'"
rm -rf "$T"
}

# Parse first, then every case, under each shell.
printf '%s\n' "$PRINT_SHIM" "$STUBS" "$RUNBLK" > "$W/parse.sh"
for SH in "${SHELLS[@]}"; do
  SHP=$(command -v "$SH")
  "$SHP" -n "$W/parse.sh" 2>/dev/null || { no "THE BLOCK DOES NOT PARSE under $SH"; exit 2; }
  cases
done
SH=all

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite) =="
  M=$(mktemp -d -p "$W")
  # A mutant convicts only when its re-run under EACH shell exits 1 with a FAIL line tagged for that shell.
  mutate(){
    local SH=all s out rc ev
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    for s in "${SHELLS[@]}"; do
      SH=$s
      out=$(ONLY_SHELL="$s" TMPDIR="$W" bash "$0" "$M/m.sh" 2>&1); rc=$?
      ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$s] " || true)
      if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"
      elif [ "$rc" != 1 ]; then no "MUTANT BROKEN: $1 (rc=$rc)"
      elif [ -z "$ev" ]; then no "UNPROVEN: $1 -- rc 1 with no FAIL line under $s"
      else ok "convicted: $1"; printf '%s\n' "$ev" | sed 's/^/        /'; fi
    done
  }
  mutate "removes the directory itself" \
    's@rm -rf /data/vendor/fingerprint/\* /data/vendor/fingerprint/\.\[!\.\]\* 2>/dev/null@rm -rf /data/vendor/fingerprint 2>/dev/null@'
  mutate "skips dotfiles" 's@ /data/vendor/fingerprint/\.\[!\.\]\* 2>/dev/null@ 2>/dev/null@'
  mutate "no report on the absent path" 's@^      0) _swept="\$_swept fingerprint=ABSENT" ;;$@      0) : ;;@'
  mutate "a failing [ -d ] reads ABSENT" 's@^  elif _vl=\$(ls -1A /data/vendor 2>/dev/null) && \[ -n "\$_vl" \]; then$@  elif _vl=; true; then@'
  mutate "an unlistable directory reads ABSENT" 's@^      _swept="\$_swept fingerprint=UNREACHABLE"$@      _swept="$_swept fingerprint=ABSENT"@'
  mutate "an unlistable /data/vendor reads ABSENT" 's@^    _swept="\$_swept fingerprint=UNREACHABLE"$@    _swept="$_swept fingerprint=ABSENT"@'
  mutate "what stays is not reported as LEFT" 's@elif \[ -n "\$_l" \]; then _swept="\$_swept fingerprint=\$_n/LEFT@elif false; then _swept="$_swept fingerprint=$_n/LEFT@'
  mutate "reports twice" 's@^      else _swept="\$_swept fingerprint=\$_n"; fi$@&\n      _swept="$_swept fingerprint=$_n"@'
  mutate "the category moved after the result line" \
    '/^  # --- fix 9: fingerprint (NWP-20261011-34) ---$/,/^  # Report what was actually removed/{/^  # Report what was actually removed/!d}; s@^\(  echo "\[roamd\] bootsweep result:\$_swept\)@  # --- fix 9: fingerprint (NWP-20261011-34) ---\n  _swept="$_swept fingerprint=ABSENT"\n\1@'
  mutate "the count is not a number" '/^  # --- fix 9: fingerprint (NWP-20261011-34) ---$/,/^  # --- fix 10/s@ && _n=\$(printf @ \&\& _n=x$(printf @'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
