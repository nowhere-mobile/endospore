#!/usr/bin/env bash
# test-bootsweep-uiderrors.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's uiderrors category
# (NWP-20261011-33), run for real rather than grepped.
#
# /data/system/uiderrors.txt is the framework's append-only record of app-data destroys, so across sessions it
# names what every departed profile had installed. The bootsweep op truncates it. What this pins:
#   - a non-empty file is TRUNCATED IN PLACE (same inode, still there) and its old size is reported;
#   - an absent or empty file reports uiderrors=0, and an absent one is not created;
#   - a path that cannot be stat'ed for any reason but ENOENT, a symbolic link, or a file that cannot be written
#     reports UNREACHABLE -- and a link's target is never touched;
#   - a file still non-empty after the truncation reports <old>/LEFT:<now>;
#   - the category appends to _swept EXACTLY ONCE on every path (the op's INVARIANT);
#   - the block sits after the dropbox category and before the result line, inside the bootsweep op.
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR -- its own header line, up to the next category header
# or the result comment, whichever comes first -- never by line count and never copied; if the anchors move,
# extraction fails loudly rather than a stale copy passing forever.
#
# NWP-20261112-36: and under every shell. The block ran only under bash (an `eval` in a bash subshell, and the
# mutants re-ran the suite with `bash`), while the device runs roamd under mksh -- and the category leans on
# `$(stat ... 2>&1)` status capture, a `: >` truncation and case patterns on stat's error text, none of which the
# suite exercised off bash. The block is now written into a runner file with each case's variables and run under each
# of bash, sh, dash and mksh found (an `sh` that is the same binary as one already listed is skipped), parsed by that
# shell first; every case runs under every shell, tagged `[<sh>]`, and a mutant convicts only when every shell has its
# own FAIL line. Every case dir and the mutant copy live under one temp root, removed on exit.
#
#   bash test-bootsweep-uiderrors.sh            # the behaviour cases
#   bash test-bootsweep-uiderrors.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Each shell under its own name; an `sh` that is the same binary as one already listed adds nothing.
SHELLS=""; SEEN=""
for s in bash dash mksh sh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p" 2>/dev/null) || r="$p"
  if [ "$s" = sh ]; then case " $SEEN " in *" $r "*) continue ;; esac; fi
  SHELLS="$SHELLS $s"; SEEN="$SEEN $r"
done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }

PASS=0; FAIL=0; SH=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction -----------------------------------------------------------------------------------------
HDR='  # --- fix 8: uiderrors (NWP-20261011-33) ---'
BLK=$(awk -v h="$HDR" '$0 == h {f=1; print; next} f && (/^  # ---/ || /^  # Report what was actually removed/) {exit} f' "$SUT")
case "$BLK" in *'_ue="/data/system/uiderrors.txt"'*) ;; *) echo "EXTRACTION FAILED: the uiderrors category" >&2; exit 2 ;; esac
# Point the block at a temp file: the one path assignment is substituted, nothing else.
BLK_T=$(sed 's@^  _ue="/data/system/uiderrors.txt"$@  _ue="$UE"@' <<< "$BLK")
[ "$BLK_T" != "$BLK" ] || { echo "EXTRACTION FAILED: the path assignment did not substitute" >&2; exit 2; }

# --- harness --------------------------------------------------------------------------------------------
# bash and dash have no `print`; mksh's own is the one the device runs.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
# run_blk <dir> <uiderrors path> [stubbed-stat-sizes...] -> runs the block under "$SH" from <dir>/run.sh, as roamd
# would run it: the case's variables first, then the block; leaves _swept in <dir>/swept.
# With sizes given, `stat` is a function answering them in order (to reach the LEFT branch, which needs the
# framework to append between the truncation and the re-stat).
run_blk(){
  local T="$1" UE="$2"; shift 2
  {
    [ "$SH" = mksh ] || printf '%s\n' "$PRINT_SHIM"
    printf "T='%s'\nUE='%s'\nLOG='%s/log'\n_swept=''\n" "$T" "$UE" "$T"
    if [ $# -gt 0 ]; then
      printf '%s\n' "$@" > "$T/stat.seq"
      printf '%s\n' 'stat(){ local v; v=$(head -n 1 "$T/stat.seq"); sed -i 1d "$T/stat.seq"; echo "$v"; }'
    fi
    printf '%s\n' "$BLK_T"
    printf '%s\n' 'printf '"'"'%s'"'"' "$_swept" > "$T/swept"'
  } > "$T/run.sh"
  "$SH" "$T/run.sh" </dev/null >/dev/null 2>&1
}
# sweep <dir> [stubbed-stat-sizes...] -> runs the block with UE=<dir>/uiderrors.txt.
sweep(){ local T="$1"; shift; run_blk "$T" "$T/uiderrors.txt" "$@"; }
swept(){ cat "$1/swept" 2>/dev/null; }
once(){   # once <dir> -> the category appears exactly once in _swept
  local s w n=0; s=$(swept "$1")
  for w in $s; do case "$w" in uiderrors=*) n=$((n + 1)) ;; esac; done
  [ "$n" = 1 ]
}
LINE='10/10/26, 5:04 PM: Destroying /data/user_de/10/com.example.secretapp due to: Package not installed'

# cases -> every behaviour case, run under "$SH". The case dirs are the caller's T; they live under $W.
cases(){
  local T SZ INO L TSZ OP_AT DB_AT UE_AT RS_AT
  echo "== [$SH] a non-empty file is truncated in place and its old size reported =="
  T=$(mktemp -d -p "$W")
  printf '%s\n%s\n' "$LINE" "$LINE" > "$T/uiderrors.txt"
  SZ=$(wc -c < "$T/uiderrors.txt"); INO=$(stat -c %i "$T/uiderrors.txt")
  sweep "$T"
  [ -f "$T/uiderrors.txt" ] && ok "the file still exists (truncated, not unlinked)" || no "the file is gone"
  [ "$(stat -c %i "$T/uiderrors.txt" 2>/dev/null)" = "$INO" ] && ok "same inode: owner, mode and label kept" \
    || no "inode changed: the file was replaced, not truncated"
  [ "$(wc -c < "$T/uiderrors.txt" 2>/dev/null)" = 0 ] && ok "the file holds 0 bytes" \
    || no "the file holds $(wc -c < "$T/uiderrors.txt" 2>/dev/null) bytes"
  [ "$(swept "$T")" = " uiderrors=$SZ" ] && ok "reports uiderrors=$SZ" || no "_swept was '$(swept "$T")', want ' uiderrors=$SZ'"
  once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  L=$(cat "$T/log" 2>/dev/null)
  [[ "$L" != *secretapp* ]] && ok "no file content reaches the log" || no "the log carries the file's content"
  rm -rf "$T"

  echo "== [$SH] an absent file reports uiderrors=0 and is not created =="
  T=$(mktemp -d -p "$W"); sweep "$T"
  [ "$(swept "$T")" = " uiderrors=0" ] && ok "reports uiderrors=0" || no "_swept was '$(swept "$T")', want ' uiderrors=0'"
  once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  [ ! -e "$T/uiderrors.txt" ] && ok "no file was created" || no "the sweep created the file"
  rm -rf "$T"

  echo "== [$SH] an empty file reports uiderrors=0 =="
  T=$(mktemp -d -p "$W"); : > "$T/uiderrors.txt"; sweep "$T"
  [ "$(swept "$T")" = " uiderrors=0" ] && ok "reports uiderrors=0" || no "_swept was '$(swept "$T")', want ' uiderrors=0'"
  once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  [ -f "$T/uiderrors.txt" ] && ok "the file still exists" || no "the empty file is gone"
  rm -rf "$T"

  echo "== [$SH] a stat failure that is not ENOENT reports UNREACHABLE, not 0 =="
  # The parent is a regular file, so stat fails with ENOTDIR -- an error, not absence. (Run as root too: unlike a
  # mode-000 directory, this cannot be bypassed by privilege.)
  T=$(mktemp -d -p "$W"); mkdir "$T/d"; : > "$T/d/x"
  run_blk "$T" "$T/d/x/uiderrors.txt"
  [ "$(swept "$T")" = " uiderrors=UNREACHABLE" ] && ok "reports UNREACHABLE" \
    || no "_swept was '$(swept "$T")', want ' uiderrors=UNREACHABLE'"
  once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  rm -rf "$T"

  echo "== [$SH] a symbolic link is never followed =="
  T=$(mktemp -d -p "$W"); printf '%s\n' "$LINE" > "$T/target"; ln -s "$T/target" "$T/uiderrors.txt"
  TSZ=$(wc -c < "$T/target"); sweep "$T"
  [ "$(wc -c < "$T/target")" = "$TSZ" ] && ok "the link's target is untouched" || no "the sweep truncated through the link"
  [ -L "$T/uiderrors.txt" ] && ok "the link itself is left" || no "the link was removed or replaced"
  [ "$(swept "$T")" = " uiderrors=UNREACHABLE" ] && ok "reports UNREACHABLE" \
    || no "_swept was '$(swept "$T")', want ' uiderrors=UNREACHABLE'"
  once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  rm -rf "$T"

  echo "== [$SH] a file that cannot be written reports UNREACHABLE =="
  # A directory at the path: stat succeeds, the truncation fails (EISDIR) whatever the privilege.
  T=$(mktemp -d -p "$W"); mkdir "$T/uiderrors.txt"; : > "$T/uiderrors.txt/a-name-long-enough-to-give-the-dir-a-size"
  if [ "$(stat -c %s "$T/uiderrors.txt")" != 0 ]; then
    sweep "$T"
    [ "$(swept "$T")" = " uiderrors=UNREACHABLE" ] && ok "reports UNREACHABLE" \
      || no "_swept was '$(swept "$T")', want ' uiderrors=UNREACHABLE'"
    once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  else
    echo "  skip  [$SH] this filesystem reports a directory size of 0, so the unwritable case is unreachable here"
  fi
  rm -rf "$T"

  echo "== [$SH] a file still non-empty after the truncation reports LEFT =="
  T=$(mktemp -d -p "$W"); printf '%s\n' "$LINE" > "$T/uiderrors.txt"
  sweep "$T" 40 7   # the framework appended 7 bytes between the truncation and the re-stat
  [ "$(swept "$T")" = " uiderrors=40/LEFT:7" ] && ok "reports uiderrors=40/LEFT:7" \
    || no "_swept was '$(swept "$T")', want ' uiderrors=40/LEFT:7'"
  once "$T" && ok "the category appears exactly once" || no "the category does not appear exactly once"
  rm -rf "$T"

  echo "== [$SH] the category runs after dropbox and before the result line, inside the bootsweep op =="
  OP_AT=$(grep -n '^if \[ "\$op" = "bootsweep" \]; then$' "$SUT" | cut -d: -f1)
  DB_AT=$(grep -n '^    _swept="\$_swept dropbox=UNREACHABLE"$' "$SUT" | cut -d: -f1)
  UE_AT=$(grep -nxF "$HDR" "$SUT" | cut -d: -f1)
  RS_AT=$(grep -n '^  echo "\[roamd\] bootsweep result:\$_swept' "$SUT" | cut -d: -f1)
  if [ -n "$OP_AT" ] && [ -n "$DB_AT" ] && [ -n "$UE_AT" ] && [ -n "$RS_AT" ] \
     && [ "$OP_AT" -lt "$DB_AT" ] && [ "$DB_AT" -lt "$UE_AT" ] && [ "$UE_AT" -lt "$RS_AT" ]; then
    ok "op $OP_AT < dropbox $DB_AT < uiderrors $UE_AT < result $RS_AT"
  else
    no "order wrong or anchor missing (op=$OP_AT dropbox=$DB_AT uiderrors=$UE_AT result=$RS_AT)"
  fi
  [ "$(grep -cxF "$HDR" "$SUT")" = 1 ] && ok "the header is unique" || no "the header is not unique"
}

echo "== $SUT (shells:$SHELLS)"
for SH in $SHELLS; do
  # The block must PARSE under the shell that runs it, or a mutant's syntax error would read as a conviction.
  pf=$(mktemp -p "$W") || exit 2
  printf '%s\n' "$BLK_T" > "$pf"
  "$SH" -n "$pf" 2>/dev/null || { no "THE BLOCK DOES NOT PARSE"; exit 2; }
  cases
done

# --- mutations ------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  SH=mutate
  # judge <label> -> the suite re-run on $M/m.sh must FAIL (rc 1) with a FAIL line of its own under EVERY shell
  # found. A mutant that changes nothing, a sed that fails, or a child that cannot extract or parse (rc 2) is a
  # failure, never a conviction.
  judge(){
    local out rc s
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    out=$(bash "$0" "$M/m.sh" 2>&1); rc=$?
    case "$rc" in
      0) no "NOT CONVICTED: $1 -- suite passes on broken code"; return ;;
      1) ;;
      *) no "MUTATION BROKEN (rc $rc): $1 -- the mutant no longer extracts or parses"; return ;;
    esac
    for s in $SHELLS; do
      case "$out" in
        *"  FAIL  [$s] "*) ok "convicted [$s]: $1" ;;
        *) no "NOT CONVICTED [$s]: $1 -- no failing case under $s" ;;
      esac
    done
  }
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    judge "$1"
  }
  mutate "unlink instead of truncate" 's@^  elif ! ( : > "\$_ue" ) 2>> "\$LOG"; then$@  elif ! rm -f "$_ue" 2>> "$LOG"; then@'
  mutate "truncation skipped" 's@^  elif ! ( : > "\$_ue" ) 2>> "\$LOG"; then$@  elif false; then@'
  mutate "category omitted on the absent path" 's@^      \*"No such file or directory"\*) _swept="\$_swept uiderrors=0" ;;$@      *"No such file or directory"*) : ;;@'
  mutate "category omitted on the empty path" '/^  elif \[ "\$_n" = 0 \]; then$/{n;s@_swept="\$_swept uiderrors=0"@:@}'
  mutate "every stat failure read as absent" 's@^      \*"No such file or directory"\*)@      *)@'
  mutate "symbolic link followed" 's@^  if \[ -L "\$_ue" \]; then$@  if false; then@'
  mutate "LEFT reported as success" 's@^  elif \[ "\$_left" != 0 \]; then$@  elif false; then@'
  mutate "category appended twice" 's@^    _swept="\$_swept uiderrors=\$_n"$@&\n&@'
  mutate "old size not reported" 's@^    _swept="\$_swept uiderrors=\$_n"$@    _swept="$_swept uiderrors=0"@'
  # A re-stat size that is not a number: every compare here is a string compare, so each shell must land on LEFT
  # (mksh would read `x0` as 0 in an arithmetic test, silently).
  mutate "re-stat size made non-numeric" 's@^  elif ! _left=\$(stat -c %s "\$_ue" 2>> "\$LOG") || \[ -z "\$_left" \]; then$@  elif ! _left=x$(stat -c %s "$_ue" 2>> "$LOG") || [ -z "$_left" ]; then@'
  # Moved BEFORE dropbox: the boot-wipe's removeUser lines would then survive the sweep.
  awk -v h="$HDR" '
    $0 == h {f=1}
    f && (/^  # Report what was actually removed/) {f=0}
    f {blk = blk $0 "\n"; next}
    {rest[++n] = $0}
    END { for (i = 1; i <= n; i++) { if (rest[i] ~ /^  # --- fix 7: dropbox/) printf "%s", blk; print rest[i] } }
  ' "$SUT" > "$M/m.sh"
  judge "category moved before dropbox"
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
