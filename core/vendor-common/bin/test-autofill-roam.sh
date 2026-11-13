#!/usr/bin/env bash
# test-autofill-roam.sh [<nowhere_roamd.sh>] [--mutate] -- the autofill service a profile chooses roams (NWP-20261109-15).
#
# Q078 (docs/product-decisions.md, 2026-10-20), in the shape Q024 gave accessibility: Secure autofill_service is
# captured at seal into the sibling file nowhere-autofill once this session's grant has applied it, and put back at grant
# when its app is installed. Every failure here is silent: a capture that runs before this session's apply reads the
# fresh user's unset row and deletes the record at one periodic seal; a failed read that clears the record loses the
# choice; an apply that ignores the installed check names a service whose app is not there; an apply that marks after a
# failed put lets the next seal drop the record; a log line that names a component outlives the session in roam.log.
#
# NWP-20261112-12: cases G1-G10, pins P4/P5. `autofill_apply <uid> <pkg>`, from the odrestore op, puts an ON-DEMAND
# app's carried service back at its first install, once per package per session ($STATE/.autofilldone.<uid>), never
# over a service chosen this session, with no package listing and never writing .autofillapplied. The grant records the
# installed package whose service it put, so that app's update heal puts nothing either (G10).
#
# NWP-20261121-13: cases T1-T4. Each of autofill_apply's four .autofillapplied truncations (no capture, malformed,
# not installed, applied) runs with the marker planted as a DIRECTORY, a target no shell and no uid can truncate. The
# function must run past the site, log its outcome and make the same put and pm calls as a control run with a writable
# marker. bash runs these cases as bash --posix: plain bash survives a failed redirection on ':', which ends mksh, dash
# and sh. Inside a function mksh ends only the function (it returns 1) and its caller goes on, so each case also asserts
# that the function returns 0 and that the chmod after the site ran. The capture guard tests -e, so a directory reads as
# applied: these cases assert nothing about the capture.
#
# The two helpers are extracted from nowhere_roamd.sh BY ANCHOR, each exactly once, never copied. settings and pm are
# stubbed. Every case runs under every shell found (bash, sh, dash, mksh).
#
#   bash test-autofill-roam.sh            # the truth table + the source pins
#   bash test-autofill-roam.sh --mutate   # ... plus mutants that must each CONVICT, under every shell
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
[ -n "$SHELLS" ] || { echo "no shell to run under" >&2; exit 2; }
echo "shells:$SHELLS"

extract() {  # $1 = script, $2 = dest lib -> 0 iff each function is found exactly once
  local f="$1" dest="$2" fn n
  : > "$dest"
  for fn in autofill_seal_capture autofill_apply; do
    n=$(grep -c "^${fn}() {\$" "$f")
    if [ "$n" != 1 ]; then echo "EXTRACTION FAILED: ${fn}() found $n times" >&2; return 1; fi
    sed -n "/^${fn}() {\$/,/^}\$/p" "$f" >> "$dest"
  done
  cat >> "$dest" <<'STUB'
settings() {
  case "$1" in
    get) [ "${GETRC:-0}" = 0 ] || return 1
         if [ -f "$FX/get" ]; then cat "$FX/get"; else echo null; fi ;;
    put) echo "$*" >> "$PUTLOG"; return "${PUTRC:-0}" ;;
  esac
}
pm() {
  echo "$*" >> "$PMLOG"
  [ -f "$FX/pkgs" ] && sed 's/^/package:/' "$FX/pkgs"
  return 0
}
STUB
}

# suite <roamd> <shell> [quiet] -> 0 iff every check holds under that shell
suite() {
  local sut="$1" sh="$2" quiet="${3:-}" p=0 x=0
  local lib="$W/lib.$$.sh" logf="$W/log.$$" root="$W/root.$$" st="$W/state.$$" fx="$W/fx.$$"
  local files="$W/root.$$/10/com.nowhere.chooser/files" out
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok   [%s] %s\n' "$sh" "$1"; }
  no() { x=$((x+1)); printf '  FAIL [%s] %s\n' "$sh" "$1"; }
  out="$files/nowhere-autofill"
  rm -rf "$root" "$st" "$fx"; mkdir -p "$files" "$st" "$fx"; : > "$logf"; : > "$W/pm.$$"; : > "$W/pmall.$$"; : > "$W/pmg.$$"
  local have=yes
  local f
  if ! extract "$sut" "$lib"; then
    have=no
    for f in F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 F11 F12 F13 F14 F15 F16 F17 F18 G1 G2 G3 G4 G5 G6 G7 G8 G9 G10 T1 T2 T3 T4; do no "$f not run: the helpers are not in the script"; done
  fi

  # reset: a fresh case -- no record, no marker, live row null, no packages
  reset() {
    rm -rf "$fx" "$st"; mkdir -p "$fx" "$st"; rm -f "$files"/nowhere-autofill* "$files/nowhere-appkeep"
    cat "$W/pm.$$" >> "$W/pmall.$$" 2>/dev/null; : > "$W/put.$$"; : > "$W/pm.$$"
  }
  live() { printf '%s\n' "$1" > "$fx/get"; }       # live <value>
  pkgs() { printf '%s\n' "$@" > "$fx/pkgs"; }
  mark() { : > "$st/.autofillapplied.10"; }
  rec() { printf '%s\n' "$1" > "$out"; cp "$out" "$W/ref.$$"; }   # rec <line>: the record, and a reference copy
  # autofill_seal_capture takes <userdir> <uid>; autofill_apply takes <uid> [<pkg>]; appk <pkg> [VAR=val...] is the
  # pkg call, and folds its pm argv into pmg (G9)
  appk() { local k="$1"; shift
    cat "$W/pm.$$" >> "$W/pmall.$$" 2>/dev/null; : > "$W/pm.$$"
    env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" AUTOFILL_USER_ROOT="$root" \
      "$sh" -c '. "$1"; autofill_apply 10 "$2"' x "$lib" "$k" </dev/null
    cat "$W/pm.$$" >> "$W/pmg.$$"; }
  donehas() { grep -qxF -- "$1" "$st/.autofilldone.10" 2>/dev/null; }
  app() { env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" AUTOFILL_USER_ROOT="$root" \
      "$sh" -c '. "$1"; autofill_apply 10' x "$lib" </dev/null; }
  cap() { env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" AUTOFILL_USER_ROOT="$root" \
      "$sh" -c '. "$1"; autofill_seal_capture "$2" 10' x "$lib" "$root/10" </dev/null; }
  # tapp: autofill_apply <uid> with REACHED echoed after it, under the POSIX-mode shell. $psh is unquoted on purpose:
  # for bash it is two words, "bash --posix".
  local psh="$sh"; [ "$sh" = bash ] && psh="bash --posix"
  tapp() { env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" AUTOFILL_USER_ROOT="$root" \
      $psh -c '. "$1"; autofill_apply 10; echo "REACHED $?"' x "$lib" </dev/null > "$W/tout.$$" 2>/dev/null; }
  # tcase <id> <setup> <outcome text>: a control run with a writable marker, then the same case with the marker a
  # directory. The second run must reach past the site, log the outcome and make the control's put and pm calls.
  tcase() {
    local id="$1" setup="$2" want="$3"
    reset; $setup; tapp A=1
    cp "$W/put.$$" "$W/cput.$$"; cp "$W/pm.$$" "$W/cpm.$$"
    if [ "$(cat "$W/tout.$$")" = "REACHED 0" ]; then ok "$id control returns 0"; else no "$id control: '$(cat "$W/tout.$$")'"; fi
    if [ -f "$st/.autofillapplied.10" ]; then ok "$id control marks"; else no "$id control did not mark"; fi
    reset; $setup; mkdir "$st/.autofillapplied.10"; : > "$logf"; tapp A=1
    if [ "$(cat "$W/tout.$$")" = "REACHED 0" ]; then ok "$id runs past the site and returns 0 (dir marker)"; else no "$id did not run past the site or return 0 (dir marker): '$(cat "$W/tout.$$")'"; fi
    # mksh ends only the FUNCTION on a failed redirection of ':' (it returns 1), so the caller's echo still runs: the
    # site's own chmod 600, the next command on its line, shows that the function went on past it
    if [ "$(ls -ld "$st/.autofillapplied.10" | cut -c1-10)" = "drw-------" ]; then ok "$id the chmod after the site ran (dir marker)"; else no "$id the chmod after the site did not run (dir marker): $(ls -ld "$st/.autofillapplied.10" | cut -c1-10)"; fi
    if grep -qF -- "$want" "$logf"; then ok "$id outcome logged (dir marker)"; else no "$id outcome not logged (dir marker): $(cat "$logf")"; fi
    if cmp -s "$W/put.$$" "$W/cput.$$" && cmp -s "$W/pm.$$" "$W/cpm.$$"; then ok "$id same put and pm calls as the control (dir marker)"; else no "$id put/pm differ from the control (dir marker): $(cat "$W/put.$$") / $(cat "$W/pm.$$")"; fi
    chmod 700 "$st/.autofillapplied.10" 2>/dev/null   # autofill_apply's chmod 600 took the directory's x bit
  }
  t1() { :; }
  t2() { rec justaword; }
  t3() { rec "$C"; pkgs com.other; }
  t4() { rec "$C"; pkgs com.x.vault; }

  local C=com.x.vault/com.x.vault.Svc O=com.od.vault/com.od.vault.Svc

  if [ "$have" = yes ]; then
    # F1 with the marker, an installed app's live component is recorded
    reset; mark; pkgs com.x.vault; live "$C"
    cap A=1
    if [ "$(cat "$out" 2>/dev/null)" = "$C" ]; then ok "F1 live component of an installed app recorded"; else no "F1 recorded '$(cat "$out" 2>/dev/null)'"; fi
    if [ "$(ls -l "$out" 2>/dev/null | cut -c1-10)" = "-rw-------" ]; then ok "F1 mode 600"; else no "F1 mode"; fi
    if [ ! -e "$out.tmp" ]; then ok "F1 no tmp left"; else no "F1 tmp left"; fi
    # a changed choice replaces the record
    reset; mark; pkgs com.x.vault com.od.vault; rec "$O"; live "$C"
    cap A=1
    if [ "$(cat "$out" 2>/dev/null)" = "$C" ]; then ok "F1 a changed choice replaces the record"; else no "F1 replace recorded '$(cat "$out" 2>/dev/null)'"; fi

    # F2 a malformed value leaves the file byte for byte, and is counted
    local v
    for v in 'com.x;rm/x' 'justaword' '1abc.d/e' 'com.x.vault/a/b' 'com.x.vault/'; do
      reset; mark; pkgs com.x.vault; rec "$O"; live "$v"
      cap A=1
      if cmp -s "$out" "$W/ref.$$"; then ok "F2 malformed '$v' leaves the record byte for byte"; else no "F2 malformed '$v' changed the record: $(cat "$out" 2>/dev/null)"; fi
    done
    if grep -q '1 malformed value for user 10' "$logf"; then ok "F2 malformed counted"; else no "F2 count not logged"; fi

    # F3 null with an installed recorded app removes the record (the user turned autofill off)
    reset; mark; pkgs com.x.vault; rec "$C"; live null
    printf 'com.x.vault\t1\n' > "$files/nowhere-appkeep"
    cap A=1
    if [ ! -e "$out" ]; then ok "F3 null + installed app -> record removed"; else no "F3 record kept: $(cat "$out")"; fi
    # an empty row reads the same as null
    reset; mark; pkgs com.x.vault; rec "$C"; live ""
    cap A=1
    if [ ! -e "$out" ]; then ok "F3 empty + installed app -> record removed"; else no "F3 empty kept the record"; fi

    # F4 null with a not-installed recorded app: named in nowhere-appkeep keeps it, not named removes it
    reset; mark; pkgs com.x.vault; rec "$O"; live null
    printf 'com.other\t1\ncom.od.vault\t1\n' > "$files/nowhere-appkeep"
    cap A=1
    if cmp -s "$out" "$W/ref.$$"; then ok "F4 not installed + in nowhere-appkeep -> record kept byte for byte"; else no "F4 kept-for-install record changed"; fi
    reset; mark; pkgs com.x.vault; rec "$O"; live null
    printf 'com.other\t1\ncom.od.vault.extra\t1\n' > "$files/nowhere-appkeep"
    cap A=1
    if [ ! -e "$out" ]; then ok "F4 not installed + not in nowhere-appkeep -> record removed"; else no "F4 record kept with no appkeep line"; fi
    # F16 a MULTILINE live value is malformed as a whole, never its valid first line (RF-001)
    for v in "$C
INVALID!" "$C
$O" "INVALID!
$C" "com.x.vault/.Svc
x/y"; do
      reset; mark; pkgs com.x.vault com.od.vault; rec "$O"; printf '%s\n' "$v" > "$fx/get"
      cap A=1
      if cmp -s "$out" "$W/ref.$$"; then ok "F16 multiline live value leaves the record byte for byte"; else no "F16 multiline live value changed the record: $(cat "$out" 2>/dev/null)"; fi
    done
    # and a multiline record is not read as its first line when the row is null: it is malformed, so it is removed
    reset; mark; rec "$O"; printf 'trailing\n' >> "$out"; live null
    printf 'com.od.vault\t1\n' > "$files/nowhere-appkeep"
    cap A=1
    if [ ! -e "$out" ]; then ok "F16 null + multiline record -> removed, not kept for its first line's install"; else no "F16 multiline record kept"; fi

    # F18 a live value with a TRAILING blank line is malformed as a whole, never its valid component (RF-001): the
    # capture strips only settings' own output terminator, not every trailing newline
    local tl
    for tl in '\n\n' '\n\n\n'; do
      reset; : > "$logf"; mark; pkgs com.x.vault com.od.vault; rec "$O"; printf "%s$tl" "$C" > "$fx/get"
      cap A=1
      if cmp -s "$out" "$W/ref.$$"; then ok "F18 trailing blank line leaves the record byte for byte"; else no "F18 trailing blank line changed the record: $(cat "$out" 2>/dev/null)"; fi
      if grep -q '1 malformed value for user 10' "$logf" && ! grep -q 'autofill: captured for user 10' "$logf"; then ok "F18 counted as malformed, not captured"; else no "F18 not logged as malformed: $(cat "$logf")"; fi
    done

    # F15 capture on null with an empty listing keeps the record
    reset; mark; rec "$C"; live null
    cap A=1
    if cmp -s "$out" "$W/ref.$$"; then ok "F15 null + empty listing -> record byte for byte"; else no "F15 record changed on an empty listing"; fi

    # F5 a failing settings get leaves the file
    reset; mark; pkgs com.x.vault; rec "$C"
    cap GETRC=1
    if cmp -s "$out" "$W/ref.$$"; then ok "F5 failed read leaves the record byte for byte"; else no "F5 record changed on a failed read"; fi

    # F6 WITHOUT the marker the file stays byte for byte and the line is logged
    reset; pkgs com.x.vault; rec "$C"; live null
    cap A=1
    if cmp -s "$out" "$W/ref.$$"; then ok "F6 no marker -> record byte for byte"; else no "F6 record changed before this session's apply"; fi
    if grep -q "not applied yet this session for user 10 -> the profile's record is kept" "$logf"; then ok "F6 line logged"; else no "F6 no log line"; fi

    # F7 apply writes an installed app's component, and marks
    reset; pkgs com.x.vault; rec "$C"
    app A=1
    if [ "$(cat "$W/put.$$")" = "put --user 10 secure autofill_service $C" ]; then ok "F7 one put of the recorded component"; else no "F7 puts: $(cat "$W/put.$$")"; fi
    if [ -e "$st/.autofillapplied.10" ]; then ok "F7 marked"; else no "F7 not marked"; fi

    # F8 apply skips a not-installed one, and marks
    reset; pkgs com.x.vault; rec "$O"
    app A=1
    if [ ! -s "$W/put.$$" ] && [ -e "$st/.autofillapplied.10" ] && cmp -s "$out" "$W/ref.$$"; then ok "F8 not installed -> no put, marked, record kept"; else no "F8 not-installed apply: $(cat "$W/put.$$")"; fi

    # F9 apply with no file writes nothing, logs, and marks
    reset; pkgs com.x.vault
    app A=1
    if [ ! -s "$W/put.$$" ] && [ -e "$st/.autofillapplied.10" ]; then ok "F9 no file -> no put, marked"; else no "F9 no-file apply"; fi
    if grep -q 'autofill: no capture for user 10' "$logf"; then ok "F9 no-capture line logged"; else no "F9 no line"; fi
    # a malformed record: nothing written, marked
    reset; pkgs com.x.vault; rec 'com.x;rm/x'
    app A=1
    if [ ! -s "$W/put.$$" ] && [ -e "$st/.autofillapplied.10" ]; then ok "F9 malformed record -> no put, marked"; else no "F9 malformed apply: $(cat "$W/put.$$")"; fi

    # F17 a MULTILINE record is malformed as a whole: no put of its first line, marked (RF-001)
    local r
    for r in "$C
INVALID!" "$C
$C" "$C
" "INVALID!
$C"; do
      reset; pkgs com.x.vault; printf '%s\n' "$r" > "$out"; cp "$out" "$W/ref.$$"
      app A=1
      if [ ! -s "$W/put.$$" ] && [ -e "$st/.autofillapplied.10" ] && cmp -s "$out" "$W/ref.$$"; then ok "F17 multiline record -> no put, marked"; else no "F17 multiline record applied: $(cat "$W/put.$$")"; fi
    done
    if grep -q 'capture for user 10 is malformed' "$logf"; then ok "F17 malformed record logged"; else no "F17 no malformed line"; fi

    # F10 a failed put is logged and does NOT mark; the record survives
    reset; pkgs com.x.vault; rec "$C"
    app PUTRC=1
    if grep -q 'settings put FAILED for user 10' "$logf"; then ok "F10 failed put logged"; else no "F10 failed put not logged"; fi
    if [ ! -e "$st/.autofillapplied.10" ]; then ok "F10 not marked after a failed put"; else no "F10 marked after a failed put"; fi
    if cmp -s "$out" "$W/ref.$$"; then ok "F10 record survives"; else no "F10 record changed"; fi

    # F13 apply with an empty package listing: no put, no mark
    reset; rec "$C"
    app A=1
    if [ ! -s "$W/put.$$" ] && [ ! -e "$st/.autofillapplied.10" ]; then ok "F13 empty listing -> no put, not marked"; else no "F13 empty-listing apply"; fi

    # F14 the capture never writes the marker
    reset; mark; pkgs com.x.vault; live "$C"
    cap A=1; rm -f "$st/.autofillapplied.10"
    cap A=1
    if [ ! -e "$st/.autofillapplied.10" ]; then ok "F14 capture never writes the marker"; else no "F14 capture wrote the marker"; fi

    # F11 no log line holds a package or component
    if ! grep -q 'com\.\(x\|od\|other\)\|Svc\|rm/x\|justaword\|abc' "$logf" && grep -q 'autofill:' "$logf"; then ok "F11 log names no package or component"; else no "F11 log names a package or component (or logged nothing)"; fi
    # F12 pm never gets -a, on any call of any case above (reset folds each case's argv into pmall)
    reset
    if [ -s "$W/pmall.$$" ] && ! grep -Eq ' -[A-Za-z]*a|^-[A-Za-z]*a' "$W/pmall.$$"; then ok "F12 pm never gets -a"; else no "F12 pm argv: $(cat "$W/pmall.$$")"; fi
    # and both helpers list once each: a not-installed record kept for its install, then applied
    reset; mark; pkgs com.x.vault; rec "$O"; live null
    printf 'com.od.vault\t1\n' > "$files/nowhere-appkeep"
    cap A=1; app A=1
    if [ "$(grep -c . "$W/pm.$$")" = 2 ] && ! grep -Eq ' -[A-Za-z]*a|^-[A-Za-z]*a' "$W/pm.$$"; then ok "F12 capture and apply each list once, without -a"; else no "F12 pm argv: $(cat "$W/pm.$$")"; fi

    # G: the pkg call (odrestore, NWP-20261112-12). No mark and no pkgs: the grant's marker is not this call's, and the
    # op has just installed <pkg>, so it lists nothing. The G log is kept apart for G8.
    reset; : > "$logf"
    # G1 the record names <pkg>, the live row is unset: one put of the record, <pkg> recorded (mode 600), no marker
    reset; rec "$O"; live null
    appk com.od.vault A=1
    if [ "$(cat "$W/put.$$")" = "put --user 10 secure autofill_service $O" ]; then ok "G1 one put of the record"; else no "G1 puts: $(cat "$W/put.$$")"; fi
    if donehas com.od.vault; then ok "G1 <pkg> recorded in .autofilldone"; else no "G1 not recorded"; fi
    if [ "$(ls -l "$st/.autofilldone.10" 2>/dev/null | cut -c1-10)" = "-rw-------" ]; then ok "G1 .autofilldone mode 600"; else no "G1 .autofilldone mode: $(ls -l "$st/.autofilldone.10" 2>/dev/null)"; fi
    if [ ! -e "$st/.autofillapplied.10" ]; then ok "G1 .autofillapplied untouched"; else no "G1 the pkg call wrote .autofillapplied"; fi
    if cmp -s "$out" "$W/ref.$$"; then ok "G1 record byte for byte"; else no "G1 record changed"; fi
    if grep -q 'autofill: applied at its install for user 10' "$logf"; then ok "G1 applied logged"; else no "G1 no applied line"; fi
    # G2 a second pkg call for the same <pkg> (an update heal, after a switch-off this session): no put
    : > "$W/put.$$"; live null
    appk com.od.vault A=1
    if [ ! -s "$W/put.$$" ]; then ok "G2 second call for the same <pkg> -> no put"; else no "G2 puts: $(cat "$W/put.$$")"; fi
    if [ "$(grep -cxF com.od.vault "$st/.autofilldone.10" 2>/dev/null)" = 1 ]; then ok "G2 <pkg> recorded once"; else no "G2 record: $(cat "$st/.autofilldone.10" 2>/dev/null)"; fi
    # G3 the record names another package: no put, <pkg> recorded
    reset; rec "$C"; live null
    appk com.od.vault A=1
    if [ ! -s "$W/put.$$" ] && donehas com.od.vault; then ok "G3 record names another app -> no put, recorded"; else no "G3 puts: $(cat "$W/put.$$")"; fi
    # G4 the live row already holds a different component (chosen this session): no put, recorded
    reset; rec "$O"; live "$C"
    appk com.od.vault A=1
    if [ ! -s "$W/put.$$" ] && donehas com.od.vault; then ok "G4 a service chosen this session -> no put, recorded"; else no "G4 puts: $(cat "$W/put.$$")"; fi
    # G5 a failed live read: no put, NOT recorded (a later heal retries)
    reset; rec "$O"
    appk com.od.vault GETRC=1
    if [ ! -s "$W/put.$$" ] && [ ! -e "$st/.autofilldone.10" ]; then ok "G5 failed read -> no put, not recorded"; else no "G5 puts: $(cat "$W/put.$$") record: $(cat "$st/.autofilldone.10" 2>/dev/null)"; fi
    # G6 a failed put: logged, NOT recorded, the record survives
    reset; rec "$O"; live null
    appk com.od.vault PUTRC=1
    if grep -q 'autofill: settings put at its install FAILED for user 10' "$logf"; then ok "G6 failed put logged"; else no "G6 failed put not logged"; fi
    if [ ! -e "$st/.autofilldone.10" ] && [ ! -e "$st/.autofillapplied.10" ]; then ok "G6 not recorded, not marked"; else no "G6 recorded or marked after a failed put"; fi
    if cmp -s "$out" "$W/ref.$$"; then ok "G6 record survives"; else no "G6 record changed"; fi
    # G7 no record file: no put, recorded; a malformed or multiline record: the same
    reset; live null
    appk com.od.vault A=1
    if [ ! -s "$W/put.$$" ] && donehas com.od.vault && [ ! -e "$st/.autofillapplied.10" ]; then ok "G7 no record -> no put, recorded, not marked"; else no "G7 no-record pkg call"; fi
    for r in 'com.x;rm/x' "$O
INVALID!"; do
      reset; printf '%s
' "$r" > "$out"; live null
      appk com.od.vault A=1
      if [ ! -s "$W/put.$$" ] && donehas com.od.vault && [ ! -e "$st/.autofillapplied.10" ]; then ok "G7 malformed record -> no put, recorded, not marked"; else no "G7 malformed pkg call: $(cat "$W/put.$$")"; fi
    done
    # G10 the grant records the installed package whose service it put, so that app's update heal (after a switch-off
    # this session) puts nothing; and a not-installed grant records nothing, so the first install still applies
    reset; pkgs com.x.vault; rec "$C"
    app A=1
    if donehas com.x.vault; then ok "G10 the grant's put records its package"; else no "G10 the grant did not record its package"; fi
    : > "$W/put.$$"; rm -f "$fx/pkgs"; live null
    appk com.x.vault A=1
    if [ ! -s "$W/put.$$" ]; then ok "G10 an update heal after the grant's put -> no put"; else no "G10 puts: $(cat "$W/put.$$")"; fi
    reset; pkgs com.x.vault; rec "$O"
    app A=1
    if [ ! -e "$st/.autofilldone.10" ]; then ok "G10 a not-installed grant records nothing"; else no "G10 not-installed grant recorded: $(cat "$st/.autofilldone.10")"; fi
    : > "$W/put.$$"; rm -f "$fx/pkgs"; live null
    appk com.od.vault A=1
    if [ "$(cat "$W/put.$$")" = "put --user 10 secure autofill_service $O" ]; then ok "G10 then its first install applies the record"; else no "G10 first install puts: $(cat "$W/put.$$")"; fi
    # G8 no G log line holds a package or component
    if ! grep -q 'com\.\(x\|od\|other\)\|Svc\|rm/x\|INVALID' "$logf" && grep -q 'autofill:' "$logf"; then ok "G8 log names no package or component"; else no "G8 log names a package or component (or logged nothing): $(cat "$logf")"; fi
    # G9 no pkg call ran a pm listing
    if [ ! -s "$W/pmg.$$" ]; then ok "G9 a pkg call runs no pm listing"; else no "G9 pm argv: $(cat "$W/pmg.$$")"; fi

    # T1-T4 (NWP-20261121-13): each .autofillapplied truncation with the marker a directory
    tcase T1 t1 'autofill: no capture for user 10 -> nothing to apply'
    tcase T2 t2 'autofill: capture for user 10 is malformed -> nothing applied'
    tcase T3 t3 'autofill: app not installed for user 10 -> nothing applied, waiting for install'
    if [ -s "$W/pm.$$" ]; then ok "T3 the package listing ran"; else no "T3 no package listing"; fi
    tcase T4 t4 'autofill: applied for user 10'
    if [ "$(cat "$W/put.$$")" = "put --user 10 secure autofill_service $C" ]; then ok "T4 one put of the recorded component (dir marker)"; else no "T4 puts (dir marker): $(cat "$W/put.$$")"; fi
  fi

  # pins: the three call sites, each exactly once and AFTER the a11y line (order, not adjacency: sibling slices may
  # merge a line between)
  local outarm grantarm inarm n a b
  outarm=$(awk '/^  out\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  grantarm=$(awk '/^  grant\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  inarm=$(awk '/^  in\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  n=$(printf '%s\n' "$outarm" | grep -c '^    autofill_seal_capture "\$USERDIR" "\$uid"')
  a=$(printf '%s\n' "$outarm" | grep -n '^    a11y_seal_capture "\$USERDIR" "\$uid"' | head -n 1 | cut -d: -f1)
  b=$(printf '%s\n' "$outarm" | grep -n '^    autofill_seal_capture "\$USERDIR" "\$uid"' | head -n 1 | cut -d: -f1)
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then ok "P1 out calls autofill_seal_capture once, after a11y_seal_capture"; else no "P1 out call missing, repeated or misplaced ($n)"; fi
  n=$(printf '%s\n' "$grantarm" | grep -c '^    autofill_apply "\$uid"')
  a=$(printf '%s\n' "$grantarm" | grep -n '^    a11y_apply "\$uid"' | head -n 1 | cut -d: -f1)
  b=$(printf '%s\n' "$grantarm" | grep -n '^    autofill_apply "\$uid"' | head -n 1 | cut -d: -f1)
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then ok "P2 grant calls autofill_apply once, after a11y_apply"; else no "P2 grant call missing, repeated or misplaced ($n)"; fi
  n=$(printf '%s\n' "$inarm" | grep -c '^    rm -f "\$STATE/.autofillapplied.\$uid" 2>/dev/null')
  if [ "$n" = 1 ]; then ok "P3 in clears .autofillapplied for its uid"; else no "P3 in's marker clear missing or repeated ($n)"; fi
  # P4 the odrestore arm calls the pkg mode once, on the line right after a11y_apply's (NWP-20261112-12), with only a
  # time stamp line of the odrestore steps line between them (NWP-20261202-16): those are filtered out here.
  local odarm
  odarm=$(awk '/^  odrestore\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut" \
    | grep -v '^      _odt[0-9]*=\$(_ms 2>/dev/null)$')
  n=$(printf '%s\n' "$odarm" | grep -c '^      autofill_apply "\$uid" "\$pkg"')
  a=$(printf '%s\n' "$odarm" | grep -n '^      a11y_apply "\$uid" "\$pkg"' | head -n 1 | cut -d: -f1)
  b=$(printf '%s\n' "$odarm" | grep -n '^      autofill_apply "\$uid" "\$pkg"' | head -n 1 | cut -d: -f1)
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$b" = "$((a+1))" ]; then ok "P4 odrestore calls autofill_apply <uid> <pkg> once, right after a11y_apply"; else no "P4 odrestore call missing, repeated or misplaced ($n)"; fi
  # P5 the in arm clears .autofilldone for its uid
  n=$(printf '%s\n' "$inarm" | grep -c '^      rm -f "\$STATE/.autofilldone.\$uid" 2>>"\$LOG"')
  if [ "$n" = 1 ]; then ok "P5 in clears .autofilldone for its uid"; else no "P5 in's .autofilldone clear missing or repeated ($n)"; fi

  rm -rf "$root" "$st" "$fx" "$lib" "$logf" "$W/put.$$" "$W/pm.$$" "$W/pmall.$$" "$W/pmg.$$" "$W/ref.$$" \
    "$W/tout.$$" "$W/cput.$$" "$W/cpm.$$"
  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh" "$p" "$x"
  [ "$x" = 0 ]
}

RC=0
for s in $SHELLS; do
  echo "== as committed [$s] =="
  suite "$SUT" "$s" || RC=1
done
if [ "$MUTATE" = no ]; then echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; fi
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo; echo "== mutations (each MUST be convicted under every shell) =="
MRC=0
# A mutant that did not apply is not evidence: it must exist, be non-empty and differ from the source.
apply_mut() {  # $1 dest, $2 sed expr
  sed "$2" "$SUT" > "$1" 2>/dev/null || return 1
  [ -s "$1" ] || return 1
  ! cmp -s "$1" "$SUT"
}
mutant() {  # $1 label, $2 sed expr
  local m sh; m=$(mktemp -p "$W")
  if ! apply_mut "$m" "$2"; then
    printf '  ⚠ NOT APPLIED  %s -- sed failed or changed nothing; NOT a conviction\n' "$1"; MRC=1; rm -f "$m"; return
  fi
  for sh in $SHELLS; do
    if suite "$m" "$sh" quiet >/dev/null; then printf '  ⚠ SURVIVED  %s [%s]\n' "$1" "$sh"; MRC=1; else printf '  convicted   %s [%s]\n' "$1" "$sh"; fi
  done
  rm -f "$m"
}
mutant "A1 the capture's marker guard removed" \
  's#if \[ ! -e "\$STATE/.autofillapplied.\$_uid" \]; then#if false; then#'
mutant "A2 the keep-record (nowhere-appkeep) rule dropped" \
  's#\] && \[ -n "\$(cut -f1 "\$_bd/nowhere-appkeep" 2>/dev/null | grep -xF "\$_p")" \]; then#] \&\& false; then#'
mutant "A3 apply ignores the installed check" \
  '/^autofill_apply() {/,/^}/s#if \[ -z "\$(printf .%s\\n. "\$_pl" | grep -xF "package:\$_p")" \]; then#if false; then#'
mutant "A4 a failed read clears the record" \
  '/^autofill_seal_capture() {/,/^}/s#settings read failed for user \$_uid -> the profile.s record is kept \$(date)" >> "\$LOG"#&; rm -f "$_out"#'
mutant "A5 a log line prints the component" \
  's#autofill: captured for user \$_uid #autofill: captured $_v for user $_uid #'
mutant "A6 apply marks after a failed put" \
  's#echo "\[roamd\] autofill: settings put FAILED for user \$_uid#: > "$STATE/.autofillapplied.$_uid"; &#'
mutant "A7 the out call removed" \
  '/^    autofill_seal_capture "\$USERDIR" "\$uid"/d'
mutant "A8 the grant call removed" \
  '/^    autofill_apply "\$uid"/d'
mutant "A9 the in arm's .autofillapplied clear dropped" \
  '/^    rm -f "\$STATE\/.autofillapplied.\$uid" 2>\/dev\/null/d'
mutant "A10 apply marks after an empty listing" \
  's#not marked, record kept for the next sign-in \$(date)" >> "\$LOG"#&; : > "$STATE/.autofillapplied.$_uid"#'
mutant "A11 apply passes -a to pm" \
  '/^autofill_apply() {/,/^}/s#pm list packages --user#pm list packages -a --user#'
mutant "A12 the capture skips the listing check on null" \
  '/^autofill_seal_capture() {/,/^}/s#  if \[ -n "\$_p" \]; then#  if false; then#'
mutant "A13 the capture validates only the first line of a multiline value" \
  '/^autofill_seal_capture() {/,/^}/s#    case "\$_v" in \*"\$_nl"\*) _p=""; _c="" ;; esac#    :#'
mutant "A14 apply applies the first line of a multiline record" \
  '/^autofill_apply() {/,/^}/s#_comp=\$(cat "\$_f" 2>/dev/null; echo .); _comp=\${_comp%.}; _comp=\${_comp%"\$_nl"}#_comp=$(head -n 1 "$_f" 2>/dev/null)#'
mutant "A15 a null row keeps a multiline record for its first line's install" \
  '/^autofill_seal_capture() {/,/^}/s#^    \*"\$_nl"\*) ;;$#    *"$_nl"*) _p=${_old%%/*}; _p=${_p%%"$_nl"*} ;;#'
mutant "A16 the capture strips every trailing newline of the live value" \
  '/^autofill_seal_capture() {/,/^}/s#2>/dev/null; _c=\$?; echo .; exit \$_c)#2>/dev/null)#'
mutant "A_g1 the pkg call's done-record check removed" \
  '/^autofill_apply() {/,/^}/s#if \[ -n "\$_only" \] \&\& grep -qxF -- "\$_only" "\$_rec" 2>/dev/null; then#if false; then#'
mutant "A_g2 the pkg call's live-value guard removed (it puts over a session choice)" \
  '/^autofill_apply() {/,/^}/s#if \[ -n "\$_v" \] \&\& \[ "\$_v" != null \]; then#if false; then#'
mutant "A_g3 the pkg call writes .autofillapplied" \
  's#echo "\[roamd\] autofill: applied at its install#: > "$STATE/.autofillapplied.$_uid"; &#'
mutant "A_g4 the odrestore call removed" \
  '/^      autofill_apply "\$uid" "\$pkg"/d'
mutant "A_g5 the in op's .autofilldone clear removed" \
  '/^ *rm -f "\$STATE\/.autofilldone.\$uid"/d'
mutant "A_g6 the grant does not record the package whose service it put" \
  '/^autofill_apply() {/,/^}/{/^    grep -qxF -- "\$_p" "\$_rec" 2>\/dev\/null || /d;}'
# T1-T4 (NWP-20261121-13): one site's subshell reverted to the bare ': >', scoped to autofill_apply and to that line
mutant "T1 autofill_apply's no-capture .autofillapplied truncation is bare again" \
  '/^autofill_apply() {$/,/^}$/{/autofill: no capture for user/,/return 0/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
mutant "T2 autofill_apply's malformed .autofillapplied truncation is bare again" \
  '/^autofill_apply() {$/,/^}$/{/is malformed -> nothing applied/,/return 0/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
mutant "T3 autofill_apply's not-installed .autofillapplied truncation is bare again" \
  '/^autofill_apply() {$/,/^}$/{/app not installed for user/,/return 0/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
mutant "T4 autofill_apply's applied .autofillapplied truncation is bare again" \
  '/^autofill_apply() {$/,/^}$/{/^  if settings put --user/,/applied for user/s#( : > \("[^"]*"\) ) 2>>"\$LOG"#: > \1 2>>"$LOG"#;}'
echo; [ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ a mutation survived or did not apply"
exit $MRC
