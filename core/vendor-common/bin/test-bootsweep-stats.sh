#!/usr/bin/env bash
# test-bootsweep-stats.sh [<nowhere_roamd.sh>] [--mutate] -- the boot sweep's `appop_db`, `graphicsstats` and
# `dropbox` categories (fixes 5, 6 and 7; NWP-20261026-11), run for real rather than grepped.
#
# The three oldest categories used to break the rules fixes 8-10 (uiderrors, fingerprint, anr) state. Each must now:
#   - graphicsstats, dropbox: never follow a symbolic link (UNREACHABLE, the link and its target left, one log line);
#   - never read a denied listing or a denied `[ -d ]` as 0 (UNREACHABLE, nothing removed); appop_db likewise, and it
#     reads 0 only when /data/system lists and names no `appops`;
#   - empty the contents only (dotfiles and nested package dirs included), keep the directory, report <cat>=<n>;
#   - list again afterwards: <cat>=<n>/LEFT:<m> for what stays, <cat>=<n>/LEFT:UNREACHABLE for a denied re-list;
#   - put no file name in the log, the result or stderr (graphicsstats paths name packages);
#   - append its category to `_swept` exactly once on every path.
#
# The blocks are extracted from nowhere_roamd.sh BY ANCHOR (each header up to the next `  # ---` header); if the
# anchors move, extraction fails loudly. The paths are substituted by a temp tree and the cases run under every
# shell present among bash, sh, dash and mksh (BOOTSWEEP_SHELLS=<paths> restricts the list; --mutate uses it to
# convict each mutant under each shell on its own).
#
#   bash test-bootsweep-stats.sh            # the behaviour cases
#   bash test-bootsweep-stats.sh --mutate   # ... plus mutations that must each CONVICT the suite under each shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(dirname "$0")
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
if [ -n "${BOOTSWEEP_SHELLS:-}" ]; then
  read -r -a SHELLS <<< "$BOOTSWEEP_SHELLS"
else
  seen=" "
  for s in bash sh dash mksh; do
    p=$(command -v "$s" 2>/dev/null) || continue
    r=$(readlink -f "$p")
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "; SHELLS+=("$p")
  done
fi

# --- extraction -----------------------------------------------------------------------------------------
# extract <header prefix> <token that must appear> -> the block, header through the line before the next header
extract(){ local b
  b=$(awk -v h="$1" '
    on && index($0, "  # ---") == 1 { exit }
    index($0, h) == 1 { on = 1 }
    on { print }' "$SUT")
  case "$b" in *"$2"*) ;; *) echo "EXTRACTION FAILED: $1" >&2; exit 2 ;; esac
  printf '%s\n' "$b"
}
H5="  # --- fix 5:"; H6="  # --- fix 6:"; H7="  # --- fix 7:"
B5=$(extract "$H5" 'appop_db='); B6=$(extract "$H6" 'graphicsstats='); B7=$(extract "$H7" 'dropbox=')
BLOCK=$(printf '%s\n%s\n%s\n' "$B5" "$B6" "$B7")
printf '%s\n' "$BLOCK" > "$W/block.sh"
bash -n "$W/block.sh" 2>/dev/null || { echo "EXTRACTION FAILED: the blocks do not parse" >&2; exit 2; }
POS=$(awk -v h5="$H5" -v h7="$H7" '
  /^if \[ "\$op" = "bootsweep" \]; then$/ { op = NR }
  index($0, h5) == 1 { a = NR }
  index($0, h7) == 1 { c = NR }
  /echo "\[roamd\] bootsweep result:\$_swept/ { res = NR }
  END { print (op && a > op && c > a && res > c) ? "in" : "out" }' "$SUT")

# --- harness --------------------------------------------------------------------------------------------
# /data/system -> $R/system, `[ -d ` -> _tdir, ls/rm -> stubs, so a denial or a failed remove can be simulated per
# path (root ignores mode bits, so chmod proves nothing on a CI runner). The stubs are POSIX: dash and mksh run them.
#   DENY_D=<dirs>   _tdir fails          DENY_LS=<dirs>  every listing of it fails
#   DENY_LS2=<dir>  its 2nd and later listings fail (counted in $R/lscount)
#   RMMODE=fail     rm removes nothing   keep1: rm skips the operand named $RMKEEP   noisy: names paths, removes nothing
RUNBLK=$(printf '%s\n' "$BLOCK" | sed -e 's@/data/system@$R/system@g' -e 's@\[ -d @_tdir @g')
{
  cat <<'STUBS'
_tdir(){ case " ${DENY_D:-} " in *" $1 "*) return 1 ;; esac; [ -d "$1" ]; }
ls(){ for last; do :; done
  case " ${DENY_LS:-} " in *" $last "*) return 1 ;; esac
  if [ "$last" = "${DENY_LS2:-/nonexistent-deny-ls2}" ]; then
    echo x >> "$R/lscount"
    [ "$(wc -l < "$R/lscount")" -ge 2 ] && return 1
  fi
  command ls "$@"; }
rm(){ case "${RMMODE:-}" in
    fail) return 1 ;;
    keep1) for last; do case "$last" in -*) ;; *) [ "${last##*/}" = "$RMKEEP" ] || command rm -rf "$last" ;; esac; done ;;
    noisy) for last; do case "$last" in -*) ;; *) echo "rm: $last/1700000000000/com.example.bank/1/total: Permission denied" >&2 ;; esac; done; return 1 ;;
    *) command rm "$@" ;;
  esac; }
LOG="$R/log"; _swept=""
STUBS
  printf '%s\n' "$RUNBLK"
  printf "printf '%%s' \"\$_swept\"\n"
} > "$W/driver.sh"

# runblk <shell> <root> [VAR=val ...] -> prints the resulting _swept
runblk(){ local sh="$1" r="$2"; shift 2
  env "$@" R="$r" "$sh" "$W/driver.sh" 2>>"$r/stderr"; }
tok(){ printf '%s\n' "$1" | tr ' ' '\n' | grep "^$2=" | head -n 1; }          # tok <swept> <cat> -> "cat=value"
once(){ [ "$(printf '%s\n' "$1" | grep -o "$2=" | wc -l)" -eq 1 ]; }
mktree(){ local t; t=$(mktemp -d -p "$W"); mkdir -p "$t/system/appops" "$t/system/graphicsstats" "$t/system/dropbox" "$t/target"; : > "$t/log"; echo "$t"; }
fill_gs(){ mkdir -p "$1/system/graphicsstats/1700000000000/com.example.bank/123" "$1/system/graphicsstats/1700000086400/com.example.chat/1"
  echo x > "$1/system/graphicsstats/1700000000000/com.example.bank/123/total"; echo x > "$1/system/graphicsstats/1700000086400/com.example.chat/1/total"
  echo x > "$1/system/graphicsstats/.hidden"; echo x > "$1/system/graphicsstats/..odd"; }       # 4 top-level entries
fill_db(){ echo x > "$1/system/dropbox/data_app_crash@1700000000000.txt.gz"; echo x > "$1/system/dropbox/system_server_anr@1700000001000.txt"
  echo x > "$1/system/dropbox/.tmp"; }                                                           # 3 entries
fill_ao(){ local f; for f in long short; do
    : > "$1/system/appops/app_op_history_${f}_interval.db"; : > "$1/system/appops/app_op_history_${f}_interval.db-wal"
    : > "$1/system/appops/app_op_history_${f}_interval.db-shm"; done
  echo keep > "$1/system/appops/appops.xml"; mkdir -p "$1/system/appops/discrete"; echo keep > "$1/system/appops/discrete/f"; }   # 6 databases
snap(){ ( cd "$1" && find system target -print 2>/dev/null | sort && find system target -type f -exec cksum {} + 2>/dev/null | sort ); }
leaks(){ grep -q -e com.example -e 1700000 -e app_op_history -e graphicsstats/ -e dropbox/ -e Permission "$1/log" "$1/stderr" 2>/dev/null; }

echo "== position =="
[ "$POS" = in ] && ok "fixes 5, 6 and 7 sit inside the bootsweep op, in order, before its result line" \
  || no "the categories are not in order between the bootsweep op and its result line"

for sh in "${SHELLS[@]}"; do
tag="[${sh##*/}]"
# chk <tag> <swept> <cat> <want> <what>
chk(){ local g; g=$(tok "$2" "$3"); [ "$g" = "$3=$4" ] && ok "$1 $5: $3=$4" || no "$1 $5: got '$g', want '$3=$4' (all: '$2')"; }

echo "== $tag populated: contents gone, directories kept, counts reported =="
T=$(mktree); fill_gs "$T"; fill_db "$T"; fill_ao "$T"; S=$(runblk "$sh" "$T")
chk "$tag" "$S" graphicsstats 4 "dotfiles and nested package dirs counted"
chk "$tag" "$S" dropbox 3 "dotfile counted"
chk "$tag" "$S" appop_db 6 "four databases and their sidecars"
[ -d "$T/system/graphicsstats" ] && [ -z "$(command ls -A "$T/system/graphicsstats")" ] && ok "$tag graphicsstats emptied (dotfiles too), directory kept" || no "$tag graphicsstats not emptied or removed"
[ -d "$T/system/dropbox" ] && [ -z "$(command ls -A "$T/system/dropbox")" ] && ok "$tag dropbox emptied (dotfile too), directory kept" || no "$tag dropbox not emptied or removed"
[ "$(command ls -A "$T/system/appops" | tr '\n' ' ')" = "appops.xml discrete " ] && ok "$tag appops: only the databases went" || no "$tag appops left '$(command ls -A "$T/system/appops" | tr '\n' ' ')'"
for c in appop_db graphicsstats dropbox; do once "$S" "$c" && ok "$tag $c appears exactly once in _swept" || no "$tag _swept has '$S'"; done
leaks "$T" && no "$tag a name reached the log or stderr" || ok "$tag no name in the log or stderr"
T=$(mktree); S=$(runblk "$sh" "$T")
chk "$tag" "$S" graphicsstats 0 "empty directory"; chk "$tag" "$S" dropbox 0 "empty directory"; chk "$tag" "$S" appop_db 0 "empty directory"

echo "== $tag a symbolic link is never followed =="
for pair in graphicsstats:graphicsstats dropbox:dropbox; do c=${pair%%:*}; d=${pair##*:}
  T=$(mktree); echo keep > "$T/target/marker"; rmdir "$T/system/$d"; ln -s "$T/target" "$T/system/$d"
  S=$(runblk "$sh" "$T")
  chk "$tag" "$S" "$c" UNREACHABLE "a link at $d"
  [ -f "$T/target/marker" ] && ok "$tag $c: the link target's marker survives" || no "$tag $c: the target was emptied through the link"
  [ -L "$T/system/$d" ] && ok "$tag $c: the link itself is left" || no "$tag $c: the link was removed"
  [ "$(grep -c 'symbolic link' "$T/log")" -eq 1 ] && grep -q "$T/system/$d is a symbolic link" "$T/log" && ok "$tag $c: one log line, naming the directory" || no "$tag $c: log is '$(cat "$T/log")'"
  once "$S" "$c" && ok "$tag $c appears exactly once in _swept" || no "$tag _swept has '$S'"
done

echo "== $tag a denial is never 0 and removes nothing =="
for d in graphicsstats dropbox appops; do case $d in graphicsstats) c=graphicsstats; f=fill_gs ;; dropbox) c=dropbox; f=fill_db ;; *) c=appop_db; f=fill_ao ;; esac
  T=$(mktree); $f "$T"; B=$(snap "$T"); S=$(runblk "$sh" "$T" DENY_LS="$T/system/$d"); A=$(snap "$T")
  chk "$tag" "$S" "$c" UNREACHABLE "a listing denied after an allowed getattr ($d)"
  [ "$A" = "$B" ] && ok "$tag $c: nothing removed blind" || no "$tag $c: the tree changed"
  once "$S" "$c" && ok "$tag $c appears exactly once in _swept" || no "$tag _swept has '$S'"
  T=$(mktree); $f "$T"; B=$(snap "$T"); S=$(runblk "$sh" "$T" DENY_D="$T/system/$d"); A=$(snap "$T")
  chk "$tag" "$S" "$c" UNREACHABLE "[ -d ] denied on an existing $d"
  [ "$A" = "$B" ] && ok "$tag $c: nothing removed blind" || no "$tag $c: the tree changed"
done

echo "== $tag appop_db: absent is 0 only when /data/system lists and names no appops =="
T=$(mktree); rmdir "$T/system/appops"; S=$(runblk "$sh" "$T"); chk "$tag" "$S" appop_db 0 "appops absent from a listable /data/system"
T=$(mktree); rmdir "$T/system/appops"; S=$(runblk "$sh" "$T" DENY_LS="$T/system"); chk "$tag" "$S" appop_db UNREACHABLE "/data/system unlistable and appops absent"
once "$S" appop_db && ok "$tag appop_db appears exactly once in _swept" || no "$tag _swept has '$S'"

echo "== $tag a denied re-list is LEFT:UNREACHABLE =="
for d in graphicsstats dropbox appops; do case $d in graphicsstats) c=graphicsstats; f=fill_gs; n=4 ;; dropbox) c=dropbox; f=fill_db; n=3 ;; *) c=appop_db; f=fill_ao; n=6 ;; esac
  T=$(mktree); $f "$T"; S=$(runblk "$sh" "$T" DENY_LS2="$T/system/$d")
  chk "$tag" "$S" "$c" "$n/LEFT:UNREACHABLE" "second listing denied ($d)"
  [ "$(wc -l < "$T/lscount")" -eq 2 ] && ok "$tag $c: listed exactly twice" || no "$tag $c: listed $(wc -l < "$T/lscount") times"
  once "$S" "$c" && ok "$tag $c appears exactly once in _swept" || no "$tag _swept has '$S'"
done

echo "== $tag what stays is LEFT, never counted as done =="
T=$(mktree); fill_gs "$T"; fill_db "$T"; fill_ao "$T"; S=$(runblk "$sh" "$T" RMMODE=keep1 RMKEEP=.hidden)
chk "$tag" "$S" graphicsstats 4/LEFT:1 "an rm that leaves one entry"
T=$(mktree); fill_db "$T"; S=$(runblk "$sh" "$T" RMMODE=keep1 RMKEEP=.tmp); chk "$tag" "$S" dropbox 3/LEFT:1 "an rm that leaves one entry"
T=$(mktree); fill_ao "$T"; S=$(runblk "$sh" "$T" RMMODE=keep1 RMKEEP=app_op_history_long_interval.db); chk "$tag" "$S" appop_db 6/LEFT:1 "an rm that leaves one database"
T=$(mktree); fill_gs "$T"; fill_db "$T"; fill_ao "$T"; S=$(runblk "$sh" "$T" RMMODE=fail)
chk "$tag" "$S" graphicsstats 4/LEFT:4 "a failing rm"; chk "$tag" "$S" dropbox 3/LEFT:3 "a failing rm"; chk "$tag" "$S" appop_db 6/LEFT:6 "a failing rm"
for c in appop_db graphicsstats dropbox; do once "$S" "$c" && ok "$tag $c appears exactly once in _swept" || no "$tag _swept has '$S'"; done

echo "== $tag a noisy rm leaks no name =="
T=$(mktree); fill_gs "$T"; fill_db "$T"; fill_ao "$T"; S=$(runblk "$sh" "$T" RMMODE=noisy)
leaks "$T" && no "$tag rm's stderr reached the log or stderr: $(cat "$T/log" "$T/stderr")" || ok "$tag nothing of rm's stderr in the log or stderr"
case "$S" in *com.example*|*1700000*|*app_op_history*|*Permission*) no "$tag a name reached _swept: '$S'" ;; *) ok "$tag no name in _swept" ;; esac
chk "$tag" "$S" graphicsstats 4/LEFT:4 "counts only"
done

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite under each shell) =="
  # mutate <label> <sed>: one copy, then the suite once per shell, each of which must fail
  mutate(){ local m s; m=$(mktemp -d -p "$W")
    if ! sed "$2" "$SUT" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN (sed): $1: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $1"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      BOOTSWEEP_SHELLS="$s" bash "$0" "$m/m" >/dev/null 2>&1
      if [ $? -eq 0 ]; then no "NOT CONVICTED under ${s##*/}: $1 -- suite passes on broken code"; else ok "convicted under ${s##*/}: $1"; fi
    done
    rm -rf "$m"
  }
  mutate "M1: graphicsstats symlink test removed" 's@^  if \[ -L "\$_gs" \]; then$@  if false; then@'
  mutate "M2: dropbox symlink test removed" 's@^  if \[ -L "\$_db" \]; then$@  if false; then@'
  mutate "M3: dropbox lists with ls -1 and ignores the failure (reads 0 again)" 's@^  elif \[ -d "\$_db" \] \&\& _l=\$(ls -1A "\$_db" 2>/dev/null); then$@  elif [ -d "$_db" ] \&\& _l=$(ls -1 "$_db" 2>/dev/null; true); then@'
  mutate "M4: graphicsstats re-list removed" 's@^    if ! _l=\$(ls -1A "\$_gs" 2>/dev/null); then _swept=.*$@    if false; then :@; s@^    elif \[ -n "\$_l" \]; then _swept="\$_swept graphicsstats=.*$@    elif false; then :@'
  mutate "M5: graphicsstats rm stderr back to the log" 's@^    rm -rf "\$_gs"/\* "\$_gs"/\.\[!\.\]\* "\$_gs"/\.\.?\* 2>/dev/null$@    rm -rf "$_gs"/* "$_gs"/.[!.]* "$_gs"/..?* 2>> "$LOG"@'
  mutate "M6: appop_db UNREACHABLE on a denied listing reads 0" 's@^      _swept="\$_swept appop_db=UNREACHABLE"$@      _swept="$_swept appop_db=0"@'
  mutate "M7: dropbox dotfiles no longer removed" 's@^    rm -rf "\$_db"/\* "\$_db"/\.\[!\.\]\* "\$_db"/\.\.?\* 2>/dev/null$@    rm -rf "$_db"/* 2>/dev/null@'
  mutate "M8: appop_db failed unlink counted as done" 's@^        if \[ "\$_left" -gt 0 \]; then _swept=.*$@        if false; then :@'
fi

echo
echo "position: $POS; shells: ${SHELLS[*]}"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ] && [ "$POS" = in ]
