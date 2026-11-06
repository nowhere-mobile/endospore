#!/usr/bin/env bash
# test-signin-stage-truncate.sh [<nowhere_roamd.sh>] [--mutate] -- the roam-in's apps.out, doze-apps.out and prefs.out
# stages reach their next step when the target cannot be written (NWP-20261121-07).
#
# WHY THIS IS COMMITTED. A failed redirection on the special builtin `:` ends a POSIX shell: mksh (the device's
# /system/bin/sh) and dash obey, and bash obeys only in POSIX mode. NWP-20261114-09 put every truncation of the device
# scripts in a subshell, `( : > X )`, where the error ends only the subshell; test-no-bare-truncate.sh refuses the
# bare form by text. This suite shows each of the three sign-in stages in roamd's `in` arm still reaches its cp, and
# the statement after it, with a target it cannot write. If a later edit drops a stage's subshell, a truncation that
# fails (a full state tmpfs, a permission change) ends the sign-in before its reply is written, and the login daemon
# waits out its own timeout (the #150/#151 silent-wait shape).
#
# Each block is extracted BY ANCHOR, from its truncation line through the cp that follows it, and run against temp
# dirs. A directory at the target refuses the truncation, as root too. Each case writes the identity probe, the
# variables, the block and `echo REACHED` into a run file and executes it in a CHILD of each shell found among bash,
# sh, dash and mksh; bash runs as `bash --posix`. A run file that recorded no identity is a HARNESS error (exit 2),
# never a FAIL. A moved anchor prints EXTRACTION FAILED and exits 2. A mutant (one stage's truncation back in its bare
# form) is convicted only when every shell found has its own failing line for that stage.
#
#   bash test-signin-stage-truncate.sh            # the cases
#   bash test-signin-stage-truncate.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every temp of the run lives inside W.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=""; for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
IDPROBE='_id="${KSH_VERSION:+ksh:$KSH_VERSION}${BASH_VERSION:+bash:$BASH_VERSION}"; [ -n "$_id" ] || _id=posix; _pr=none; command -v print >/dev/null 2>&1 && _pr=builtin'
REF_SH=""; command -v sh >/dev/null 2>&1 && REF_SH=$(sh -c "$IDPROBE; printf '%s|%s\n' \"\$_id\" \"\$_pr\"")
sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# idok <shell> <id file> -> 0 iff the file holds at least one line and every line is that shell's identity
idok(){
  local s="$1" f="$2" l n=0
  [ -s "$f" ] || return 1
  while IFS= read -r l; do
    n=$((n+1))
    case "$s" in
      bash) case "$l" in bash:*'|none') ;; *) return 1 ;; esac ;;
      dash) [ "$l" = 'posix|none' ] || return 1 ;;
      mksh) case "$l" in 'ksh:|'*) return 1 ;; ksh:?*'|builtin') ;; *) return 1 ;; esac ;;
      sh)   [ "$l" = "$REF_SH" ] || return 1 ;;
      *)    return 1 ;;
    esac
  done < "$f"
  [ "$n" -gt 0 ]
}
# notrun <shell> <case dir>: a run file that recorded no identity never launched -- a HARNESS error (noted in
# $W/harness, which suite turns into exit 2). One that recorded the WRONG shell is noted in $W/notrun.
notrun() {
  [ -s "$2/shell.id" ] || { echo "$1" >> "$W/harness"; return 1; }
  idok "$1" "$2/shell.id" || { echo "$1" >> "$W/notrun"; return 1; }
}

# The three stages: <tag>|<target in $STATE>|<source in the chooser's files dir>|<block length>|<last line>.
CF='$USERDIR/com.nowhere.chooser/files'
BLOCKS="A|apps.out|nowhere-apps.list|3|        && cp \"$CF/nowhere-apps.list\" \"\$STATE/apps.out\" 2>> \"\$LOG\"
D|doze-apps.out|nowhere-doze-apps|4|             || rm -f \"\$STATE/doze-apps.out\"; }
P|prefs.out|nowhere-prefs|3|        && cp \"$CF/nowhere-prefs\" \"\$STATE/prefs.out\" 2>> \"\$LOG\""

# extract <roamd.sh> <target> <last line> -> the block on stdout. The first line is the truncation in either form,
# subshell or bare, so a bare-form mutant still extracts; the block ends at the first line equal to <last line>.
extract() {
  awk -v t="$2" -v e="$3" '
    $0 == "      ( : > \"$STATE/" t "\" )" || $0 == "      : > \"$STATE/" t "\"" { n++; on = 1 }
    on { print }
    on && $0 == e { on = 0 }
    END { if (n != 1) exit 1 }' "$1"
}

# prep <roamd.sh> -> writes $W/blk.<tag> for each stage; prints EXTRACTION FAILED and returns 2 when an anchor moved
prep() {
  local f="$1" row tag out src len last
  while IFS= read -r row; do
    tag="${row%%|*}"; row="${row#*|}"; out="${row%%|*}"; row="${row#*|}"; src="${row%%|*}"; row="${row#*|}"
    len="${row%%|*}"; last="${row#*|}"
    if ! extract "$f" "$out" "$last" > "$W/blk.$tag" || [ "$(wc -l < "$W/blk.$tag")" != "$len" ] \
       || [ "$(tail -1 "$W/blk.$tag")" != "$last" ]; then
      echo "EXTRACTION FAILED: $tag block ($out) not found in $f"; return 2
    fi
  done <<EOF
$BLOCKS
EOF
  return 0
}

suite() {  # suite <roamd.sh> <shell> -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" s="$2" p=0 x=0 row tag out src len last d rc out_
  ok(){ p=$((p+1)); printf '  ok    [%s] %s\n' "$s" "$1"; }
  no(){ x=$((x+1)); printf '  FAIL  [%s] %s\n' "$s" "$1"; }
  : > "$W/notrun"; : > "$W/harness"

  # run <tag> <mode>: run block <tag> once in a child of $s. <mode> is ctl (the target is writable), none (no source)
  # or dir (a directory stands at the target). Sets d (the caller removes it), rc and out.
  run() {
    d=$(mktemp -d -p "$W") || exit 2; mkdir -p "$d/u/com.nowhere.chooser/files" "$d/s"
    [ "$2" = none ] || printf 'line one\nline two\n' > "$d/u/com.nowhere.chooser/files/$src"
    [ "$2" = dir ] && mkdir -p "$d/s/$out"
    {
      printf '%s; printf "%%s|%%s\\n" "$_id" "$_pr" >> %s\n' "$IDPROBE" "$(sq "$d/shell.id")"
      printf 'USERDIR=%s; STATE=%s; LOG=%s\n' "$(sq "$d/u")" "$(sq "$d/s")" "$(sq "$d/log")"
      cat "$W/blk.$1"
      printf '%s\n' 'echo REACHED'
    } > "$d/run.sh"
    case "$s" in bash) out_=$(bash --posix "$d/run.sh" 2>/dev/null) ;; *) out_=$("$s" "$d/run.sh" 2>/dev/null) ;; esac
    rc=$?
    notrun "$s" "$d" || out_="${out_}NOTRUN"
  }

  while IFS= read -r row; do
    tag="${row%%|*}"; row="${row#*|}"; out="${row%%|*}"; row="${row#*|}"; src="${row%%|*}"; row="${row#*|}"
    len="${row%%|*}"; last="${row#*|}"
    if "$s" -n "$W/blk.$tag" 2>/dev/null; then ok "${tag}1 the $out block parses under $s -n"; else no "${tag}1 the $out block does not parse under $s -n"; fi

    run "$tag" ctl
    if [ "$rc" = 0 ] && [ "$out_" = REACHED ] && [ -f "$d/s/$out" ] && cmp -s "$d/u/com.nowhere.chooser/files/$src" "$d/s/$out"; then
      ok "${tag}C control: \$STATE/$out is a copy of $src, and the block returns"
    else no "${tag}C control: rc $rc, stdout [$out_], \$STATE/$out is not a copy of $src"; fi
    rm -rf "$d"

    run "$tag" none
    if [ "$rc" = 0 ] && [ "$out_" = REACHED ] && [ -f "$d/s/$out" ] && [ ! -s "$d/s/$out" ]; then
      ok "${tag}N no $src: the truncation leaves an empty \$STATE/$out, and the block returns"
    else no "${tag}N no $src: rc $rc, stdout [$out_], \$STATE/$out is not an empty file"; fi
    rm -rf "$d"

    run "$tag" dir
    if [ "$rc" = 0 ] && [ "$out_" = REACHED ] && [ -f "$d/s/$out/$src" ]; then
      ok "${tag}F \$STATE/$out cannot be written: the stage reaches its cp and the statement after it"
    else no "${tag}F \$STATE/$out cannot be written: rc $rc, stdout [$out_] (want rc 0 and REACHED), cp reached: $([ -f "$d/s/$out/$src" ] && echo yes || echo no)"; fi
    rm -rf "$d"
  done <<EOF
$BLOCKS
EOF

  if [ -s "$W/harness" ]; then echo "HARNESS ERROR: a run file left no identity: $s did not launch it" >&2; return 2; fi
  if grep -qx "$s" "$W/notrun"; then no "identity: a case did not run under $s"; else ok "identity: every case ran under $s"; fi
  printf '  -- [%s] %d ok, %d failed\n' "$s" "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "== $SUT"
echo "shells:$SHELLS (bash runs as bash --posix)"
echo "sh identity: $REF_SH"
prep "$SUT" || exit 2
FAILED=""; HARNESS=""
for s in $SHELLS; do
  suite "$SUT" "$s"
  case $? in 0) ;; 1) FAILED=1 ;; *) HARNESS=1 ;; esac
done
[ -z "$HARNESS" ] || { echo "HARNESS ERROR"; exit 2; }
[ -z "$FAILED" ] || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED under every shell found)"
# mut <label> <tag> <sed-expr>: exactly one line changes, and every shell has a FAIL line for <tag>F
mut() {
  local m o r s n conv="" alive="" err=""
  m=$(mktemp -p "$W") || exit 2
  if ! sed -e "$3" "$SUT" > "$m"; then echo "  ERR       $1 -- the sed program failed"; return 1; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -f "$m"; return 1; fi
  n=$(diff "$SUT" "$m" | grep -c '^>')
  [ "$n" = 1 ] || { echo "  ERR       $1 -- the mutation changed $n lines, want 1"; rm -f "$m"; return 1; }
  if ! o=$(prep "$m"); then echo "  HARNESS   $1 -- $o"; rm -f "$m"; return 1; fi
  for s in $SHELLS; do
    o=$(suite "$m" "$s" 2>&1); r=$?
    case "$r" in
      2) err="$err $s" ;;
      1) case "$o" in *"FAIL  [$s] ${2}F "*) conv="$conv $s" ;; *) alive="$alive $s" ;; esac ;;
      *) alive="$alive $s" ;;
    esac
  done
  rm -f "$m"
  if [ -n "$err" ]; then echo "  HARNESS   $1 -- harness error (not a conviction) under:$err"; return 1; fi
  if [ -n "$alive" ]; then echo "  SURVIVED  $1 -- under:$alive"; return 1; fi
  echo "  convicted $1 -- under:$conv"; return 0
}
fails=0
mut "mA the apps.out truncation is bare again" A \
  '/^      ( : > "\$STATE\/apps\.out" )$/,/^        && cp .*"\$STATE\/apps\.out" 2>> "\$LOG"$/s/^      ( : > \("\$STATE\/apps\.out"\) )$/      : > \1/' || fails=$((fails+1))
mut "mD the doze-apps.out truncation is bare again" D \
  '/^      ( : > "\$STATE\/doze-apps\.out" )$/,/^             || rm -f "\$STATE\/doze-apps\.out"; }$/s/^      ( : > \("\$STATE\/doze-apps\.out"\) )$/      : > \1/' || fails=$((fails+1))
mut "mP the prefs.out truncation is bare again" P \
  '/^      ( : > "\$STATE\/prefs\.out" )$/,/^        && cp .*"\$STATE\/prefs\.out" 2>> "\$LOG"$/s/^      ( : > \("\$STATE\/prefs\.out"\) )$/      : > \1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
