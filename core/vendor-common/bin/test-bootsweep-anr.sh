#!/usr/bin/env bash
# test-bootsweep-anr.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's `anr` category (NWP-20261015-21),
# run for real rather than grepped.
#
# ANR traces in /data/anr open with `Cmd line: <package>`, so each names an app a departed session ran, and
# nothing else clears them. The category must:
#   - empty the directory's CONTENTS, subdirectories and dotfiles included, and never remove the directory itself;
#   - never follow a symbolic link at /data/anr (it is left, and reads UNREACHABLE);
#   - report what it removed, and LEFT:<m> when something stayed (LEFT:UNREACHABLE when the re-list fails);
#   - say ABSENT only when /data lists and holds no `anr`; a failing `[ -d ]` or listing reads UNREACHABLE;
#   - append to `_swept` exactly once on every path (the bootsweep INVARIANT), and never print a file name.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR (its header line up to the next `  # ---` header or the
# `  # Report what was actually removed` line), never copied and never by line count; if the anchors move,
# extraction fails loudly rather than a stale copy passing forever. /data is substituted by a temp dir.
#
# NWP-20261112-35: and under every shell. The cases ran the block with `eval` in a bash subshell, over a bash-only
# `ls` stub, and the mutants were judged by a bash re-run's exit code alone -- while the device runs the boot sweep
# under mksh, and this category is what removes traces naming departed sessions' apps. Its dotfile globs, an
# unmatched glob left literal for `rm -rf`, the status of `_l=$(ls -1A ...)`, `[ -L ]` and a function override of
# `rm` are all shell behaviour. Each case now writes the block, its stubs and its variables into a runner file and
# runs it under each shell found, parsed by that shell first; every line is tagged `[<sh>]`, and a mutant convicts
# only when its re-run under each shell exits 1 with a `FAIL  [<sh>]` line of its own (an exit 2 is a broken
# mutant, never a conviction). bash, dash and mksh always run under their own names; sh is skipped only when it is
# the same binary as one of them; ONLY_SHELL=<name> (internal, the mutant re-run) runs exactly that shell with no
# dedup, and exits 2 when it is not available. Extraction now also stops at the `bootsweep result:` echo and asks
# only for the category's own `anr=` report, so a lost ABSENT or UNREACHABLE report is convicted by the cases that
# assert it rather than by an extraction exit. Every temp lives under one root, removed on exit.
#
#   bash test-bootsweep-anr.sh            # the behaviour cases
#   bash test-bootsweep-anr.sh --mutate   # ... plus mutations that must each CONVICT the suite
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
HDR='  # --- fix 10: anr (NWP-20261015-21) ---'
BLOCK=$(awk -v h="$HDR" '
  $0 == h { on = 1; print; next }
  on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1 \
         || index($0, "  echo \"[roamd] bootsweep result:") == 1) { exit }
  on { print }' "$SUT")
case "$BLOCK" in *'anr='*) ;;
  *) echo "EXTRACTION FAILED: the anr category" >&2; exit 2 ;; esac
# The category must sit INSIDE the bootsweep op, before its result line -- extracted correctly but dead code
# outside the op would pass every case below.
POS=$(awk -v h="$HDR" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  $0 == h { blk = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && blk > op && res > blk) ? "in" : "out" }' "$SUT")

# --- harness --------------------------------------------------------------------------------------------
# /data -> $R/data. `[ -d ` -> _tdir, and ls -> a stub, so a denial can be simulated per path (root ignores
# mode bits, so chmod 000 proves nothing on a CI runner that runs as root).
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data@$R/data@g' -e 's@\[ -d @_tdir @g')
# The stubs are POSIX: they run inside the runner file under each shell. `_st_*` names never meet the block's.
# DENY_LS2=<path> denies only the SECOND listing of <path> (the re-list after the rm); the call count lives in a
# file because each `$(ls ...)` runs in a subshell. NORM=noisy: an rm that fails, naming each path on stderr the
# way toybox does (`rm: /data/anr/anr_<ts>: Permission denied`).
STUBS=$(cat <<'EOF'
_tdir(){ case " ${DENY_D:-} " in *" $1 "*) return 1 ;; esac; [ -d "$1" ]; }
ls(){ for _st_last; do :; done
  case " ${DENY_LS:-} " in *" $_st_last "*) return 1 ;; esac
  if [ -n "${DENY_LS2:-}" ] && [ "$_st_last" = "$DENY_LS2" ]; then
    _st_c=$(( $(cat "$LSCOUNT" 2>/dev/null || echo 0) + 1 )); echo "$_st_c" > "$LSCOUNT"; [ "$_st_c" -eq 2 ] && return 1
  fi
  command ls "$@"; }
case "${NORM:-}" in
  1) rm(){ :; } ;;
  noisy) rm(){ for _st_a; do case "$_st_a" in -*) ;; *) printf 'rm: %s: Permission denied\n' "$_st_a" >&2 ;; esac; done
    return 1; } ;;
esac
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
    for n in R NORM DENY_D DENY_LS DENY_LS2 LSCOUNT; do
      if [ "$n" = R ]; then v=$r; else v=${!n:-}; fi
      case "$v" in *"'"*) echo "runblk: a quote in $n" >&2; return 2 ;; esac
      printf "%s='%s'\n" "$n" "$v"
    done
    printf '%s\n' 'LOG="$R/log"; _swept=""' "$STUBS" "$RUNBLK" "printf '%s' \"\$_swept\""
  } > "$f" || return 2
  "$SHP" "$f" 2>>"$r/stderr"
}
once(){ [ "$(printf '%s\n' "$1" | grep -o 'anr=' | wc -l)" -eq 1 ]; }
mkanr(){   # mkanr <root>: two traces and one dotfile, plus a sibling under /data
  mkdir -p "$1/data/anr" "$1/data/other"
  echo "Cmd line: com.example.bank" > "$1/data/anr/anr_2026-10-14-09-12-33-101"
  echo "Cmd line: com.example.chat" > "$1/data/anr/anr_2026-10-14-11-40-02-877"
  echo "x" > "$1/data/anr/.hidden_trace"
}

cases(){
echo "== [$SH] position =="
[ "$POS" = in ] && ok "the category sits inside the bootsweep op, before its result line" \
  || no "the category is not between the bootsweep op and its result line"

echo "== [$SH] a populated directory ends empty, still exists, and reports its count =="
T=$(mktemp -d -p "$W"); mkanr "$T"; mkdir "$T/data/anr/sub"; : > "$T/data/anr/sub/f"; S=$(runblk "$T")
[ "$S" = " anr=4" ] && ok "reports anr=4 (two traces, a dotfile, a subdirectory)" || no "reported '$S', want ' anr=4'"
[ -d "$T/data/anr" ] && ok "the directory itself is kept" || no "the directory was removed"
[ -z "$(command ls -1A "$T/data/anr" 2>/dev/null)" ] && ok "the directory is empty, dotfile and subdirectory included" \
  || no "left behind: $(command ls -1A "$T/data/anr" 2>/dev/null | tr '\n' ' ')"
[ -d "$T/data/other" ] && ok "a sibling under /data is untouched" || no "a sibling was removed"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
if grep -q -e anr_2026 -e hidden_trace -e com.example "$T/log" "$T/stderr" 2>/dev/null \
   || case "$S" in *anr_2026*|*hidden*|*com.example*) true ;; *) false ;; esac; then no "a file name or package was printed"
else ok "no file name in the result, the log or stderr"; fi
rm -rf "$T"

echo "== [$SH] a double-dot name goes too =="
T=$(mktemp -d -p "$W"); mkanr "$T"; : > "$T/data/anr/..odd"; S=$(runblk "$T")
[ "$S" = " anr=4" ] && [ -z "$(command ls -1A "$T/data/anr")" ] && ok "anr=4, emptied" \
  || no "reported '$S', left '$(command ls -1A "$T/data/anr" | tr '\n' ' ')'"
rm -rf "$T"

echo "== [$SH] an empty directory reports zero =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/data/anr"; S=$(runblk "$T")
[ "$S" = " anr=0" ] && ok "reports anr=0" || no "reported '$S'"
rm -rf "$T"

echo "== [$SH] what stays is reported as LEFT =="
T=$(mktemp -d -p "$W"); mkanr "$T"; S=$(NORM=1 runblk "$T")
[ "$S" = " anr=3/LEFT:3" ] && ok "a failing rm reports anr=3/LEFT:3" || no "reported '$S'"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkanr "$T"; S=$(NORM=noisy runblk "$T")
[ "$S" = " anr=3/LEFT:3" ] && ok "an rm that fails naming each file reports anr=3/LEFT:3" || no "reported '$S'"
if grep -q -e anr_2026 -e hidden_trace "$T/log" "$T/stderr" 2>/dev/null; then no "rm's file names reached the log or stderr"
else ok "rm's file names reach neither the log nor stderr"; fi
rm -rf "$T"

echo "== [$SH] a directory that cannot be re-listed after the rm is LEFT:UNREACHABLE, never clean =="
T=$(mktemp -d -p "$W"); mkanr "$T"; S=$(DENY_LS2="$T/data/anr" LSCOUNT="$T/lscount" runblk "$T")
[ "$(cat "$T/lscount" 2>/dev/null)" = 2 ] && ok "the directory was listed exactly twice" \
  || no "listed $(cat "$T/lscount" 2>/dev/null) times, want 2"
[ "$S" = " anr=3/LEFT:UNREACHABLE" ] && ok "reports anr=3/LEFT:UNREACHABLE" || no "reported '$S'"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
rm -rf "$T"

echo "== [$SH] a symbolic link at /data/anr is never followed =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/data" "$T/elsewhere"; echo keep > "$T/elsewhere/sentinel"
ln -s "$T/elsewhere" "$T/data/anr"; S=$(runblk "$T")
[ "$S" = " anr=UNREACHABLE" ] && ok "reports anr=UNREACHABLE" || no "reported '$S'"
[ -f "$T/elsewhere/sentinel" ] && ok "the link target's content survives" || no "the target was emptied through the link"
[ -L "$T/data/anr" ] && ok "the link itself is left" || no "the link was removed"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
rm -rf "$T"

echo "== [$SH] absent: /data lists and holds no anr (a sibling named anr_old does not count) =="
T=$(mktemp -d -p "$W"); mkdir -p "$T/data/other" "$T/data/anr_old"; : > "$T/data/anr_old/keep"; S=$(runblk "$T")
[ "$S" = " anr=ABSENT" ] && ok "reports anr=ABSENT" || no "reported '$S'"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
[ ! -e "$T/data/anr" ] && ok "nothing is created" || no "the directory was created"
[ -f "$T/data/anr_old/keep" ] && ok "the anr_old sibling is untouched" || no "the anr_old sibling was touched"
rm -rf "$T"

echo "== [$SH] a denial is never ABSENT =="
T=$(mktemp -d -p "$W"); mkanr "$T"; S=$(DENY_D="$T/data/anr" runblk "$T")
[ "$S" = " anr=UNREACHABLE" ] && ok "[ -d ] denied on an existing directory: UNREACHABLE" || no "reported '$S'"
[ "$(command ls -1A "$T/data/anr" | wc -l)" -eq 3 ] && ok "and nothing was touched" || no "files were removed"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkanr "$T"; S=$(DENY_LS="$T/data/anr" runblk "$T")
[ "$S" = " anr=UNREACHABLE" ] && ok "the directory exists but cannot be listed: UNREACHABLE" || no "reported '$S'"
[ "$(command ls -1A "$T/data/anr" | wc -l)" -eq 3 ] && ok "and nothing was removed blind" || no "files were removed"
once "$S" && ok "appears exactly once in _swept" || no "_swept has '$S'"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkdir -p "$T/data/other"; S=$(DENY_D="$T/data/anr" DENY_LS="$T/data" runblk "$T")
[ "$S" = " anr=UNREACHABLE" ] && ok "/data cannot be listed: UNREACHABLE, not ABSENT" || no "reported '$S'"
rm -rf "$T"
T=$(mktemp -d -p "$W"); mkdir -p "$T/data"; S=$(runblk "$T")
[ "$S" = " anr=UNREACHABLE" ] && ok "/data lists EMPTY: UNREACHABLE (proves nothing)" || no "reported '$S'"
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
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1: $(cat "$M/err")"; return; fi
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
  mutate "the symlink guard is dropped" 's@^  if \[ -L "\$_an" \]; then$@  if false; then@'
  mutate "removes the directory itself" 's@^      rm -rf "\$_an"/\* .*$@      rm -rf "$_an" 2>/dev/null@'
  mutate "skips dotfiles" 's@ "\$_an"/\.\[!\.\]\* "\$_an"/\.\.?\* 2>/dev/null@ 2>/dev/null@'
  mutate "no report on the absent path" 's@^      0) _swept="\$_swept anr=ABSENT" ;;$@      0) : ;;@'
  mutate "a failing [ -d ] reads ABSENT" 's@^  elif _dl=\$(ls -1A /data 2>/dev/null) && \[ -n "\$_dl" \]; then$@  elif _dl=; true; then@'
  mutate "an unlistable directory reads ABSENT" 's@^      _swept="\$_swept anr=UNREACHABLE"$@      _swept="$_swept anr=ABSENT"@'
  mutate "an unlistable /data reads ABSENT" 's@^    _swept="\$_swept anr=UNREACHABLE"$@    _swept="$_swept anr=ABSENT"@'
  mutate "what stays is not reported as LEFT" 's@elif \[ -n "\$_l" \]; then _swept="\$_swept anr=\$_n/LEFT@elif false; then _swept="$_swept anr=$_n/LEFT@'
  mutate "a file name is printed" 's@^      rm -rf "\$_an"/\* \(.*\) 2>/dev/null$@      rm -rf "$_an"/* \1 2>>"$LOG"; echo "$_l" >> "$LOG"@'
  mutate "rm's stderr goes to the log" 's@^\(      rm -rf "\$_an"/\* .*\) 2>/dev/null$@\1 2>>"$LOG"@'
  mutate "rm's stderr is not redirected" 's@^\(      rm -rf "\$_an"/\* .*\) 2>/dev/null$@\1@'
  mutate "an unlistable directory after the rm reads clean" 's@anr=\$_n/LEFT:UNREACHABLE"@anr=$_n"@'
  mutate "the absent check matches anr as a substring" 's@grep -cx anr)@grep -c anr)@'
  mutate "reports twice" 's@^      else _swept="\$_swept anr=\$_n"; fi$@&\n      _swept="$_swept anr=$_n"@'
  mutate "the category moved after the result line" \
    '/^  # --- fix 10: anr (NWP-20261015-21) ---$/,/^  # Report what was actually removed/{/^  # Report what was actually removed/!d}; s@^\(  echo "\[roamd\] bootsweep result:\$_swept\)@  # --- fix 10: anr (NWP-20261015-21) ---\n  _swept="$_swept anr=ABSENT"\n\1@'
  mutate "the count is not a number" '/^  # --- fix 10: anr (NWP-20261015-21) ---$/,/^  # ---/s@ && _n=\$(printf @ \&\& _n=x$(printf @'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
