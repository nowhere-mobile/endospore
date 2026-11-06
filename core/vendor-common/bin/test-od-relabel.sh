#!/usr/bin/env bash
# test-od-relabel.sh [<nowhere_roamd.sh>] [--mutate] -- odrestore's relabel of a handed-back app dir
# (NWP-20261005-03): od_relabel, relabel_restored, and their wiring into the odrestore copy branch.
#
# WHY THIS IS COMMITTED. odrestore used to finish with `restorecon -R "$dst"`, which relabels NOTHING under an app
# dir (toybox restorecon will not descend into app data without -D), so every restored entry kept the daemon's
# bare s0 instead of the app's MLS categories -- measured on lynx 2026-10-05 at 606 of 715 Play Store entries. Its
# replacement copies the pkg dir's own context onto every entry beneath it, and two details are silent when
# wrong: a mediad overlay mountpoint under the dir must be PRUNED (find -xdev still lists it, as the mounted root,
# and a chcon there lands on the overlay), and the external volumes, whose dirs are not app_data_file, must keep
# restorecon. Both were device-proven on lynx; this suite keeps them from regressing in CI.
#
# NWP-20261112-30: the mountpoints come from /proc/self/mountinfo octal-escaped (a space is \040), so the prune
# decodes each with mi_path and hands find a glob-escaped copy; N1-N6 pin that. Every case runs under each of bash,
# sh, dash and mksh found (mksh is the device's /system/bin/sh), and a mutant convicts only with a FAIL under each.
#
# NWP-20261030-09: a mountinfo line must fork only when it has to. 0.5.49 decoded every line, several forks each,
# and each CE and DE volume of an odrestore took 73-94 s on frankel instead of 0-2 s; one app's restore outlived the
# daemon's 150 s wait and every op behind it was refused busy. P1-P3 count sed calls. P1: a line elsewhere costs none.
# P2: nor does one elsewhere that holds an escape, or an escaped look-alike sibling (the raw "$d/" test skips both,
# so P2, and P5 on a DE dir holding a capital, a digit and an underscore, pin that a package dir takes that test). P3: a mountpoint under the dir with nothing to decode or
# escape is pruned without one. P4 pins, by its find arguments, that a dir holding a space is compared after the
# decode and its look-alike sibling is still not pruned. N7 holds a glob character and a trailing newline together,
# and N8 a ? on its own. The sed stub counts the calls and runs the real sed, so every other case sees the same
# behaviour as before. A fork without a sed would pass every count, so W3 pins the loop byte for byte.
#
# Blocks are extracted from nowhere_roamd.sh BY ANCHOR, never copied, and each extraction is asserted. `stat`,
# `find`, `chcon` and `restorecon` are stubbed as shell functions that RECORD their arguments; /proc/self/mountinfo
# is re-pointed at a fixture. The suite asserts the arguments roamd builds, not toybox's behaviour -- that half was
# proven on the device (a tmpfs mounted under a category-labelled app dir kept its own label; without the prune it
# was relabelled).
#
#   bash test-od-relabel.sh            # the behaviour cases
#   bash test-od-relabel.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# Every shell found, each under its own name (bash-as-sh runs in POSIX mode and earns its own line).
SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
# The same shim as test-mediad-sweep.sh's PRINT_SHIM: bash and dash have no `print`; mksh (the device's sh) does.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'

extract_fns() { sed -n '/^mi_path() {$/,/^}$/p; /^od_relabel() {$/,/^}$/p; /^relabel_restored() {$/,/^}$/p' "$1"; }
# The odrestore op's copy branch, from its case label to the next op's.
extract_odrestore() { sed -n '/^  odrestore)$/,/^  silence-alarm)$/p' "$1"; }

# Each stub appends one line per call to $D/calls, with printf, never echo: dash's and mksh's echo expand the
# backslashes the N2 case is about. find answers $D/nfind lines to a -print walk (the number of entries whose
# context differs) and nothing to an -exec walk.
STUBS=$(cat <<'EOF'
stat() {
  [ "$1" = -c ] && [ "$2" = "%C" ] && [ $# = 3 ] || { printf '%s\n' "stat $*" >> "$D/unexpected"; return 1; }
  cat "$D/ctx" 2>/dev/null
}
find() {
  printf '%s\n' "find $*" >> "$D/calls"
  case " $* " in *" -print "*) local i=0 n; n=$(cat "$D/nfind"); while [ "$i" -lt "$n" ]; do echo "e$i"; i=$((i+1)); done ;; esac
  return 0
}
chcon() { printf '%s\n' "chcon $*" >> "$D/calls"; }
restorecon() { printf '%s\n' "restorecon $*" >> "$D/calls"; }
sed() { printf 'x\n' >> "$D/seds"; command sed "$@"; }
EOF
)

# run <sh> <fns> <vol> <dir> <ctx> <nfind> <mountinfo-mountpoints...>  ->  "rc|<calls>|<log>", one line each joined
# by ;. A mountpoint is written to the fixture as given (printf, never echo), so `\040` stays the kernel's escape.
run() {
  local sh="$1" fns="$2" vol="$3" dir="$4" ctx="$5" nf="$6" rc D m i=30; shift 6
  D=$(mktemp -d -p "$W")
  printf '%s' "$ctx" > "$D/ctx"; echo "$nf" > "$D/nfind"; : > "$D/calls"; : > "$D/log"; : > "$D/seds"
  : > "$D/mountinfo"
  for m in "$@"; do printf '%s\n' "$i 1 0:$i / $m rw,relatime - fuse.nowheremedia nowheremedia rw" >> "$D/mountinfo"; i=$((i+1)); done
  {
    printf '%s\n' "command -v print >/dev/null 2>&1 || $PRINT_SHIM"
    printf "D='%s'; LOG=\"\$D/log\"; MI=\"\$D/mountinfo\"\n" "$D"
    printf '%s\n' "$STUBS"
    cat "$fns"
    printf '%s\n' 'od_relabel "$1" "$2"' 'echo "$?" > "$D/rc"'
  } > "$D/runner.sh"
  "$sh" "$D/runner.sh" "$vol" "$dir" >/dev/null 2>&1
  rc=$(cat "$D/rc" 2>/dev/null)
  printf '%s|%s|%s|%s\n' "${rc:-none}" "$(tr '\n' ';' < "$D/calls")" "$(tr '\n' ';' < "$D/log")" "$(cat "$D/unexpected" 2>/dev/null)"
  # The sed calls of this run, for P1-P3. run is called in a command substitution, so a variable would not survive it.
  wc -l < "$D/seds" | tr -d ' ' > "$W/seds"
  command rm -rf "$D"
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 fns out ctx d blk sh tab n2 rel p1="" p2="" p3 d4 d4w i=0
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh" "$1"; }
  no(){ x=$((x+1)); if [ -n "$quiet" ]; then printf 'FAILED [%s] %s\n' "$sh" "$1"; else printf '  FAIL  [%s] %s\n' "$sh" "$1"; fi; }

  sh=-
  fns=$(mktemp -p "$W")
  extract_fns "$f" | sed 's#< /proc/self/mountinfo#< "$MI"#' > "$fns"
  # Fail CLOSED on the extraction: an empty function file would make every case below a no-op that "passes".
  grep -q '^od_relabel() {$' "$fns" && grep -q '^relabel_restored() {$' "$fns" && grep -q '^mi_path() {$' "$fns" \
    || { no "EXTRACTION FAILED -- od_relabel/relabel_restored/mi_path moved or changed shape in $f"; command rm -f "$fns"; return 1; }
  grep -q '< "\$MI"' "$fns" && ! grep -q '/proc/self/mountinfo' "$fns" \
    || { no "RE-POINT FAILED -- relabel_restored no longer reads /proc/self/mountinfo as expected"; command rm -f "$fns"; return 1; }

  ctx='u:object_r:app_data_file:s0:c89,c257,c523,c768'
  d=/data/user/11/com.example.app
  tab=$(printf '\t')
  rel="|[roamd] relabelled 1 restored entr(ies) of com.example.app to the app's context (NWP-20261005-03);|"
  # P1's mountinfo: 200 mountpoints with no escape, none under the dir. P2's: 200 that hold an escape, none under
  # the dir, then 20 escaped look-alike siblings of it. P3's: three under the dir with nothing to decode or escape.
  # All three are passed unquoted, so they hold no space or glob. P4's dir holds a space; d4w is how mountinfo
  # writes it.
  while [ "$i" -lt 200 ]; do
    p1="$p1 /mnt/pass_through/0/emulated/p$i"; p2="$p2 /mnt/pass_through/0/emulated/My\\040Maps$i"; i=$((i+1))
  done
  i=0; while [ "$i" -lt 20 ]; do p2="$p2 ${d}2/files/My\\040Maps$i"; i=$((i+1)); done
  p3="$d/files/m0 $d/files/m1 $d/cache/m2"
  d4='/data/user/11/com.example app'; d4w='/data/user/11/com.example\040app'

  for sh in $SHELLS; do
  if ! "$sh" -n "$fns" 2>/dev/null; then no "S0 syntax error in the extracted functions"; continue; fi

  # R1: the whole shape, with one overlay under the dir, one sibling whose path merely STARTS with the dir's, and
  # one elsewhere. Only the first may be pruned.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 3 "$d/files/big" "${d}2/files/x" /data/media/11/x)
  case "$out" in
    "0|find $d -xdev -path $d/files/big -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/big -prune -o ! -context $ctx -exec chcon -h $ctx {} +;|[roamd] relabelled 3 restored entr(ies) of com.example.app to the app's context (NWP-20261005-03);|")
      ok "R1 CE: walks one filesystem, prunes the overlay under the dir (not the look-alike sibling), relabels to the dir's context" ;;
    *) no "R1 got '$out'" ;;
  esac
  # R2: nothing differs -> count only, no chcon walk.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 0)
  case "$out" in "0|find $d -xdev ! -context $ctx -print;|[roamd] relabelled 0 "*) ok "R2 nothing to relabel: no chcon walk" ;; *) no "R2 got '$out'" ;; esac
  # R3: DE takes the same path.
  out=$(run "$sh" "$fns" /data/user_de/11 /data/user_de/11/com.example.app "$ctx" 2)
  case "$out" in "0|find /data/user_de/11/com.example.app -xdev ! -context $ctx -print;find "*"-exec chcon -h $ctx {} +;|"*) ok "R3 DE is relabelled like CE" ;; *) no "R3 got '$out'" ;; esac
  # R4: a privileged app's dir is privapp_data_file and is accepted.
  out=$(run "$sh" "$fns" /data/user/11 "$d" 'u:object_r:privapp_data_file:s0:c512,c768' 1)
  case "$out" in "0|"*"-exec chcon -h u:object_r:privapp_data_file:s0:c512,c768 {} +;|"*) ok "R4 privapp_data_file is accepted" ;; *) no "R4 got '$out'" ;; esac
  # R5: a dir with any other context is left alone and reported.
  out=$(run "$sh" "$fns" /data/user/11 "$d" 'u:object_r:media_rw_data_file:s0' 4)
  case "$out" in "1||[roamd] WARN relabel com.example.app: unexpected dir context [u:object_r:media_rw_data_file:s0] -- left as is"*) ok "R5 an unexpected dir context: no walk, a WARN, rc 1" ;; *) no "R5 got '$out'" ;; esac
  out=$(run "$sh" "$fns" /data/user/11 "$d" '' 4)
  case "$out" in "1||[roamd] WARN relabel com.example.app: unexpected dir context [none]"*) ok "R6 an unreadable dir context: no walk" ;; *) no "R6 got '$out'" ;; esac
  # R7: the external volumes keep restorecon and never reach the copy-the-context walk.
  out=$(run "$sh" "$fns" /data/media/11/Android/data /data/media/11/Android/data/com.example.app "$ctx" 5)
  case "$out" in "0|restorecon -R /data/media/11/Android/data/com.example.app;||") ok "R7 Android/data keeps restorecon" ;; *) no "R7 got '$out'" ;; esac
  out=$(run "$sh" "$fns" /data/media/11/Android/obb /data/media/11/Android/obb/com.example.app "$ctx" 5)
  case "$out" in "0|restorecon -R /data/media/11/Android/obb/com.example.app;||") ok "R8 Android/obb keeps restorecon" ;; *) no "R8 got '$out'" ;; esac

  # N: the mountpoints arrive as mountinfo writes them (NWP-20261112-30). find must get the DECODED path, its glob
  # metacharacters escaped, so -path matches that one mountpoint and nothing else.
  # N1: a space, written \040.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d"'/files/My\040Maps')
  case "$out" in
    "0|find $d -xdev -path $d/files/My Maps -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/My Maps -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N1 a mountpoint with a space (\\040) is decoded before it is pruned" ;;
    *) no "N1 got '$out'" ;;
  esac
  # N2: a path holding the literal text "\040" arrives as \134040: \134 is decoded last, so it stays that text, and
  # its backslash is escaped for the glob (the recorded call holds a doubled backslash).
  n2='a\\040b'
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d"'/files/a\134040b')
  case "$out" in
    "0|find $d -xdev -path $d/files/$n2 -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/$n2 -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N2 \\134 is decoded last, and the decoded backslash is escaped for -path" ;;
    *) no "N2 got '$out'" ;;
  esac
  # N3: [, * and ? are escaped, so -path does not read them as a glob.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d/files/x[1]" "$d/files/a*b?")
  case "$out" in
    "0|find $d -xdev -path $d/files/x\\[1] -prune -o -path $d/files/a\\*b\\? -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/x\\[1] -prune -o -path $d/files/a\\*b\\? -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N3 [, * and ? in a mountpoint are escaped for -path" ;;
    *) no "N3 got '$out'" ;;
  esac
  # N4: R1's look-alike rule with an escape in the sibling: a sibling that merely starts with the dir's path is not
  # pruned. The raw "$d/" test drops it before any decode; P4 holds the same rule on decoded paths.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "${d}-x"'/files/My\040Maps' "$d"'/files/My\040Maps')
  case "$out" in
    "0|find $d -xdev -path $d/files/My Maps -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/My Maps -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N4 an escaped look-alike sibling (\$d-x/...) is not pruned" ;;
    *) no "N4 got '$out'" ;;
  esac
  # N5: a tab (\011) and an interior newline (\012, shown as ; by the harness).
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d"'/files/t\011u' "$d"'/files/m\012n')
  case "$out" in
    "0|find $d -xdev -path $d/files/t${tab}u -prune -o -path $d/files/m;n -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/t${tab}u -prune -o -path $d/files/m;n -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N5 a tab and a newline in a mountpoint are decoded" ;;
    *) no "N5 got '$out'" ;;
  esac
  # N6: a trailing newline survives the decode and the escape (a command substitution would strip it).
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d"'/files/n\012')
  case "$out" in
    "0|find $d -xdev -path $d/files/n; -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/n; -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N6 a decoded trailing newline is kept" ;;
    *) no "N6 got '$out'" ;;
  esac
  # N7: a glob character and a trailing newline in one mountpoint: escaped for -path, and the newline kept.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d"'/files/n*\012')
  case "$out" in
    "0|find $d -xdev -path $d/files/n\\*; -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/n\\*; -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N7 a glob character and a trailing newline: escaped, and the newline kept" ;;
    *) no "N7 got '$out'" ;;
  esac
  # N8: a ? is the mountpoint's only glob character, so only the glob test's ? arm sends it to the escape.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 "$d/files/a?b")
  case "$out" in
    "0|find $d -xdev -path $d/files/a\\?b -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/a\\?b -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel")
      ok "N8 a ? on its own is escaped for -path" ;;
    *) no "N8 got '$out'" ;;
  esac

  # P (NWP-20261030-09): a mountinfo line forks only when it has to. 0.5.49 ran mi_path on every line.
  # P1: 200 lines with no backslash, none under the dir: R2's walk, and not one sed.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 0 $p1)
  case "$out|$(cat "$W/seds")" in
    "0|find $d -xdev ! -context $ctx -print;|[roamd] relabelled 0 "*"||0")
      ok "P1 200 mountinfo lines with no backslash cost no sed" ;;
    *) no "P1 got '$out|$(cat "$W/seds")'" ;;
  esac
  # P2: 200 lines that hold an escape, none under the dir, and 20 escaped look-alike siblings: still not one sed.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 0 $p2)
  case "$out|$(cat "$W/seds")" in
    "0|find $d -xdev ! -context $ctx -print;|[roamd] relabelled 0 "*"||0")
      ok "P2 escaped lines elsewhere, and escaped look-alike siblings, cost no sed" ;;
    *) no "P2 got '$out|$(cat "$W/seds")'" ;;
  esac
  # P5: P2 again on a DE dir whose package holds a capital, a digit and an underscore: every character class a
  # package dir can hold must keep it on the raw test (P2's dir has only lower case and dots).
  out=$(run "$sh" "$fns" /data/user_de/10 /data/user_de/10/Com.Ex_9.app "$ctx" 0 $p2)
  case "$out|$(cat "$W/seds")" in
    "0|find /data/user_de/10/Com.Ex_9.app -xdev ! -context $ctx -print;|[roamd] relabelled 0 "*"||0")
      ok "P5 a DE dir with capitals, digits and _ takes the raw test too" ;;
    *) no "P5 got '$out|$(cat "$W/seds")'" ;;
  esac
  # P3: three mountpoints under the dir with nothing to decode or escape: each pruned as written, not one sed.
  out=$(run "$sh" "$fns" /data/user/11 "$d" "$ctx" 1 $p3)
  case "$out|$(cat "$W/seds")" in
    "0|find $d -xdev -path $d/files/m0 -prune -o -path $d/files/m1 -prune -o -path $d/cache/m2 -prune -o ! -context $ctx -print;find $d -xdev -path $d/files/m0 -prune -o -path $d/files/m1 -prune -o -path $d/cache/m2 -prune -o ! -context $ctx -exec chcon -h $ctx {} +;$rel|0")
      ok "P3 a mountpoint under the dir with nothing to decode or escape is pruned without a sed" ;;
    *) no "P3 got '$out|$(cat "$W/seds")'" ;;
  esac
  # P4: a dir that itself holds a space (no package dir can) is compared after the decode: its escaped mountpoint
  # is pruned by its decoded path, and its escaped look-alike sibling is not pruned.
  out=$(run "$sh" "$fns" /data/user/11 "$d4" "$ctx" 1 "$d4w/files/x" "${d4w}2/files/y")
  case "$out" in
    "0|find $d4 -xdev -path $d4/files/x -prune -o ! -context $ctx -print;find $d4 -xdev -path $d4/files/x -prune -o ! -context $ctx -exec chcon -h $ctx {} +;|[roamd] relabelled 1 restored entr(ies) of com.example app to the app's context (NWP-20261005-03);|")
      ok "P4 a dir holding a space is compared after the decode; its look-alike sibling is not pruned" ;;
    *) no "P4 got '$out'" ;;
  esac
  done

  # W: the wiring. Both arms of the copy (clean and failed) relabel through od_relabel, and the old no-op is gone.
  # Shell-independent (a grep), so it runs once, tagged [-].
  sh=-
  blk=$(extract_odrestore "$f")
  if [ -z "$blk" ]; then no "W0 EXTRACTION FAILED -- the odrestore op moved"
  else
    [ "$(printf '%s\n' "$blk" | grep -c '^          od_relabel "\$vol" "\$dst"$')" = 2 ] \
      && ok "W1 both copy arms relabel through od_relabel" || no "W1 od_relabel is not on both copy arms"
    grep -q 'restorecon -R "\$dst"' <<<"$blk" \
      && no "W2 odrestore still runs restorecon -R on the app dir (it relabels nothing there)" || ok "W2 the no-op restorecon is gone"
  fi
  # W3 (NWP-20261030-09): relabel_restored's mountinfo loop, byte for byte. P1-P3 and P5 count sed calls, so a fork without
  # a sed (a bare command substitution on every line) would pass them; this pin is what keeps every other fork out.
  # A change to the loop changes this block in the same commit.
  blk=$(sed -n '/^relabel_restored() {$/,/^}$/p' "$f" | sed -n '/^  while read -r _ _ _ _ mp _; do$/,/^  done < \/proc\/self\/mountinfo$/p')
  if [ "$blk" = "$(cat <<'LOOP'
  while read -r _ _ _ _ mp _; do
    if [ "$plain" = 1 ]; then case "$mp" in "$d"/*) ;; *) continue;; esac; fi
    case "$mp" in *\\*) mp=$(mi_path "${mp}x"); mp=${mp%x};; esac
    case "$mp" in "$d"/*)
      g=$mp
      case "$mp" in *\[*|*\**|*\?*|*\\*) g=$(print -r -- "${mp}x" | sed 's/[[*?\\]/\\&/g'); g=${g%x};; esac
      set -- "$@" -path "$g" -prune -o;;
    esac
  done < /proc/self/mountinfo
LOOP
)" ]; then ok "W3 relabel_restored's mountinfo loop is the pinned block"
  else no "W3 relabel_restored's mountinfo loop is not the pinned block -- a line must fork only when it has to"; fi

  command rm -f "$fns"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "odrestore relabel: $SUT"
echo "shells:$SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell):"
  mtmp=$(mktemp -d -p "$W")
  # mutate <label> <sed -E program> [any]: convicted only when the suite fails with a FAILED line under EVERY shell;
  # `any` is for a mutant only the shell-independent W checks can see, which a FAILED [-] line convicts.
  mutate() {
    local label="$1" prog="$2" scope="${3:-}" mf="$mtmp/r.sh" r out s miss=""
    if ! sed -E "$prog" "$SUT" > "$mf"; then printf '  ERR   %-64s sed program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-64s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    out=$(suite "$mf" quiet 2>&1); r=$?
    case "$r" in
      0) printf '  XX    %-64s SURVIVED\n' "$label"; MFAIL=1; return ;;
      1) ;;
      *) printf '  ERR   %-64s harness error (rc=%s), not a conviction\n' "$label" "$r"; MFAIL=1; return ;;
    esac
    if [ "$scope" = any ]; then
      case "$out" in *"FAILED [-] "*) printf '  ok    %-64s convicted by the wiring check\n' "$label" ;;
        *) printf '  XX    %-64s no wiring FAIL line\n' "$label"; MFAIL=1 ;; esac
      return
    fi
    for s in $SHELLS; do case "$out" in *"FAILED [$s] "*) ;; *) miss="$miss $s" ;; esac; done
    if [ -z "$miss" ]; then printf '  ok    %-64s convicted under%s\n' "$label" "$SHELLS"
    else printf '  XX    %-64s SURVIVED under%s\n' "$label" "$miss"; MFAIL=1; fi
  }
  mutate 'mountpoints are not pruned'                  's#^      set -- "\$@" -path "\$g" -prune -o;;$#      :;;#'
  mutate 'the prune also takes a look-alike sibling'   's@^    case "\$mp" in "\$d"/\*\)$@    case "$mp" in "$d"*)@'
  mutate 'mountpoints are not decoded'                 's@^    case "\$mp" in \*\\\\\*\) mp=\$\(mi_path "\$\{mp\}x"\); mp=\$\{mp%x\};; esac$@    :@'
  mutate 'a plain field under the dir is decoded too'  's@^    case "\$mp" in \*\\\\\*\) (mp=\$\(mi_path "\$\{mp\}x"\); mp=\$\{mp%x\});; esac$@    \1@'
  mutate 'the raw "$d/" test is gone'                  's@^    if \[ "\$plain" = 1 \]; then case "\$mp" in "\$d"/\*\) ;; \*\) continue;; esac; fi$@    :@'
  mutate 'the raw test passes a look-alike sibling'    's@^(    if \[ "\$plain" = 1 \]; then case "\$mp" in "\$d")/(\*\) ;; .*)$@\1\2@'
  mutate 'every dir takes the raw test'                's@^  case "\$d" in .*\) plain=0;; esac$@  :@'
  mutate 'the plain set lets a space through'          's@_\./-\]\*\) plain=0@_./\\ -]*) plain=0@'
  mutate 'the plain set loses the digits'              's@0123456789_\./-\]\*\) plain=0@_./-]*) plain=0@'
  mutate 'the plain set loses the underscore'          's@0123456789_\./-\]\*\) plain=0@0123456789./-]*) plain=0@'
  mutate 'the plain set loses the capitals'            's@ABCDEFGHIJKLMNOPQRSTUVWXYZ@@'
  mutate 'a package dir does not take the raw test'    's@0123456789_\./-\]\*\) plain=0@0123456789_/-]*) plain=0@'
  mutate 'every pruned path is glob-escaped'           's@^      case "\$mp" in [^)]*\) (g=\$\(print -r -- .*; g=\$\{g%x\});; esac$@      \1@'
  mutate 'the glob test misses ?'                      "$(cat <<'EOF'
s@^(      case "\$mp" in \*\\\[\*\|\*\\\*\*)\|\*\\\?\*@\1@
EOF
)"
  mutate 'the glob test misses ['                      "$(cat <<'EOF'
s@^(      case "\$mp" in )\*\\\[\*\|@\1@
EOF
)"
  mutate 'the glob test misses *'                      "$(cat <<'EOF'
s@^(      case "\$mp" in \*\\\[\*)\|\*\\\*\*@\1@
EOF
)"
  mutate 'the glob test misses a backslash'            "$(cat <<'EOF'
s@^(      case "\$mp" in \*\\\[\*\|\*\\\*\*\|\*\\\?\*)\|\*\\\\\*\)@\1)@
EOF
)"
  mutate 'a fork on every line, without a sed'         's@^(  while read -r _ _ _ _ mp _; do)$@\1\n    mp=$(print -r -- "${mp}x"); mp=${mp%x}@' any
  mutate '\134 is decoded first'                       "$(cat <<'EOF'
s@^(  print -r -- "\$1" \| sed )(-e 's/\\\\040/ /g' .*) (-e 's/\\\\134/\\\\/g')$@\1\3 \2@
EOF
)"
  mutate 'the -path glob is not escaped'               "$(cat <<'EOF'
s@g=\$\(print -r -- "\$\{mp\}x" \| sed '[^']*'\); g=\$\{g%x\};; esac$@g=$mp;; esac@
EOF
)"
  mutate 'a decoded trailing newline is dropped'       's@mi_path "\$\{mp\}x"\); mp=\$\{mp%x\}@mi_path "$mp")@'
  mutate 'the glob copy drops a trailing newline'      's@g=\$\(print -r -- "\$\{mp\}x" (\| sed .*)\); g=\$\{g%x\};; esac$@g=$(print -r -- "$mp" \1);; esac@'
  mutate 'the chcon walk crosses filesystems'          's@^  \[ "\$n" -gt 0 \] && find "\$d" -xdev @  [ "$n" -gt 0 ] \&\& find "$d" @'
  mutate 'the chcon walk runs when nothing differs'    's@^  \[ "\$n" -gt 0 \] && find @  find @'
  mutate 'chcon follows symlinks'                      's@-exec chcon -h "\$ctx"@-exec chcon "$ctx"@'
  mutate 'any dir context is accepted'                 's@^    u:object_r:app_data_file:s0\*\|u:object_r:privapp_data_file:s0\*\) ;;$@    *) ;;@'
  mutate 'the external volumes take the CE walk'       's@^    /data/media/\*\) restorecon -R "\$2" 2>>"\$LOG" ;;$@    /data/media/*) relabel_restored "$2" ;;@'
  mutate 'the clean copy goes back to restorecon'      '0,/^          od_relabel "\$vol" "\$dst"$/ s@^          od_relabel "\$vol" "\$dst"$@          restorecon -R "$dst" 2>>"$LOG"@' any
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
fi

exit "${FAILED:-0}"
