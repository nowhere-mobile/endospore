#!/usr/bin/env bash
# test-a11y-roam.sh [<nowhere_roamd.sh>] [--mutate] -- accessibility services and shortcut targets roam (NWP-20261108-15),
# and an on-demand app's carried entries are put back at its first install this session (NWP-20261108-18).
#
# Q024 (docs/product-decisions.md, 2026-10-20): the enabled accessibility services and the shortcut targets are captured
# at seal into the sibling file nowhere-a11y and put back at grant once their app is installed. Every failure here is
# silent: a capture that runs before this session's apply reads the fresh user's empty lists and deletes the record at
# one periodic seal; an apply that ignores the installed filter writes a service for an app that is not there; an apply
# that overwrites drops what the user holds; a colour-inversion shortcut (a pseudo-package no listing names) is captured
# and never put back; a log line that names a component outlives the session in roam.log.
#
# Cases B1-B9 (NWP-20261108-18): `a11y_apply <uid> <pkg>`, the odrestore arm's call. It puts back only <pkg>'s captured
# entries, whatever the listing says, and only once per session: the install-heal sends RESTORE-ODDATA on every
# PACKAGE_ADDED, updates included, so a second call must not turn back on a service the user switched off this session.
# The record is $STATE/.a11ydone.<uid>; the grant-time apply adds the packages it applied to it.
#
# NWP-20261121-12: the T-Y1/T-Y2 cases plant the apply's marker path as a DIRECTORY, so its `( : > marker )` fails (as
# root too), and check that the apply still returns, keeps its rc, logs its outcome and makes the control's settings
# writes. Bash runs as --posix there: a bare `: >` that fails ends only a POSIX shell. No capture runs after a plant: its
# `[ ! -e marker ]` guard reads a directory as present. A real failed create leaves no file, as the no-marker cases show.
#
# The two helpers are extracted from nowhere_roamd.sh BY ANCHOR, each exactly once, never copied. settings and pm are
# stubbed. Every case runs under every shell found (bash, sh, dash, mksh).
#
#   bash test-a11y-roam.sh            # the truth table + the source pins
#   bash test-a11y-roam.sh --mutate   # ... plus mutants that must each CONVICT, under every shell
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
  for fn in a11y_seal_capture a11y_apply; do
    n=$(grep -c "^${fn}() {\$" "$f")
    if [ "$n" != 1 ]; then echo "EXTRACTION FAILED: ${fn}() found $n times" >&2; return 1; fi
    sed -n "/^${fn}() {\$/,/^}\$/p" "$f" >> "$dest"
  done
  cat >> "$dest" <<'STUB'
settings() {
  case "$1" in
    get) [ "${GETRC:-0}" = 0 ] || return 1
         if [ -f "$FX/get.$5" ]; then cat "$FX/get.$5"; else echo null; fi ;;
    put) echo "$*" >> "$PUTLOG"
         # PUTFAIL=<key>: only that key's put fails; STATEFUL=1: a put that lands is what a later get reads (B9)
         [ "${PUTFAIL:-}" != "$5" ] || return 1
         [ "${PUTRC:-0}" = 0 ] || return "$PUTRC"
         [ -z "${STATEFUL:-}" ] || printf '%s\n' "$6" > "$FX/get.$5"
         return 0 ;;
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
  out="$files/nowhere-a11y"
  rm -rf "$root" "$st" "$fx"; mkdir -p "$files" "$st" "$fx"; : > "$logf"
  local have=yes
  if ! extract "$sut" "$lib"; then no "extraction"; have=no; fi

  # reset: a fresh case -- no record, no marker, nothing live, no packages
  reset() {
    rm -rf "$fx" "$st"; mkdir -p "$fx" "$st"; rm -f "$files"/nowhere-a11y* "$files/nowhere-appkeep"
    : > "$W/put.$$"; : > "$W/pm.$$"
  }
  live() { printf '%s\n' "$2" > "$fx/get.$1"; }       # live <key> <value>
  pkgs() { printf '%s\n' "$@" > "$fx/pkgs"; }
  mark() { : > "$st/.a11yapplied.10"; }
  # a11y_seal_capture takes <userdir> <uid>; a11y_apply takes <uid>
  app() { env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" A11Y_USER_ROOT="$root" \
      "$sh" -c '. "$1"; a11y_apply 10' x "$lib" </dev/null; }
  # appk <pkg> [VAR=val...]: the odrestore arm's call, a11y_apply <uid> <pkg>
  appk() { local _pk="$1"; shift
    env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" A11Y_USER_ROOT="$root" \
      "$sh" -c '. "$1"; a11y_apply 10 "$2"' x "$lib" "$_pk" </dev/null; }
  inrec() { grep -qxF -- "$1" "$st/.a11ydone.10" 2>/dev/null; }   # inrec <pkg>: a whole line of the session record
  cap() { env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" A11Y_USER_ROOT="$root" \
      "$sh" -c '. "$1"; a11y_seal_capture "$2" 10' x "$lib" "$root/10" </dev/null; }
  val() { sed -n "s/^$1=//p" "$out" 2>/dev/null | head -n 1; }   # val <key>: the captured value

  local S=enabled_accessibility_services T=accessibility_shortcut_target_service
  local B=accessibility_button_targets Q=accessibility_qs_targets F=accessibility_enabled

  if [ "$have" = yes ]; then
    # A1 with the marker, a live service of an installed app is captured
    reset; mark; pkgs com.x.reader; live $S com.x.reader/com.x.reader.Svc; live $F 1
    cap A=1
    if [ "$(val $S)" = com.x.reader/com.x.reader.Svc ] && [ "$(val $F)" = 1 ]; then ok "A1 live service of an installed app captured"; else no "A1 captured '$(val $S)' flag '$(val $F)'"; fi
    if [ "$(ls -l "$out" 2>/dev/null | cut -c1-10)" = "-rw-------" ]; then ok "A1 mode 600"; else no "A1 mode"; fi
    if [ ! -e "$out.tmp" ]; then ok "A1 no tmp left"; else no "A1 tmp left"; fi

    # A2 a malformed entry is dropped and counted
    reset; mark; pkgs com.x.reader
    live $S "com.x.reader/Svc:bad entry:../x/y:com.x/a/b:justaword:com.x.reader/Svc"
    cap A=1
    if [ "$(val $S)" = com.x.reader/Svc ]; then ok "A2 malformed entries dropped, duplicate folded"; else no "A2 captured '$(val $S)'"; fi
    if grep -q '4 malformed' "$logf"; then ok "A2 malformed counted"; else no "A2 count not logged"; fi
    # entry grammar: a framework no-/ form is valid, a bare other token is not, a class with a slash is not
    reset; mark; pkgs com.x.reader
    live $S "com.android.server.accessibility.MagnificationController:com.android.other.Thing:1abc.d/e"
    cap A=1
    if [ "$(val $S)" = com.android.server.accessibility.MagnificationController ]; then ok "A2 no-/ framework form valid, other bare token not"; else no "A2 grammar '$(val $S)'"; fi

    # A3 a not-installed captured entry named in nowhere-appkeep is kept, one not named is dropped
    reset; mark; pkgs com.x.reader
    printf '%s=com.od.reader/S:com.gone/S\n%s=\naccessibility_enabled=1\n' $S $T > "$out"
    printf 'com.od.reader\t1\n' > "$files/nowhere-appkeep"
    live $S ""; live $F 1
    cap A=1
    if [ "$(val $S)" = com.od.reader/S ]; then ok "A3 never-tapped on-demand entry kept, uninstalled one dropped"; else no "A3 captured '$(val $S)'"; fi
    # an entry named in appkeep that IS installed is NOT carried over: the user turned it off
    reset; mark; pkgs com.od.reader
    printf '%s=com.od.reader/S\n' $S > "$out"; printf 'com.od.reader\t1\n' > "$files/nowhere-appkeep"
    live $S ""; live $F 0
    cap A=1
    if [ ! -e "$out" ]; then ok "A3 installed app the user turned off is not kept"; else no "A3 kept a turned-off service: $(cat "$out")"; fi

    # A4 all empty removes the file
    reset; mark; pkgs com.x.reader
    printf '%s=com.x.reader/S\n' $S > "$out"
    live $F 0
    cap A=1
    if [ ! -e "$out" ]; then ok "A4 nothing to carry -> file removed"; else no "A4 file kept"; fi

    # A5 a failing settings get leaves the old file byte for byte
    reset; mark; pkgs com.x.reader
    printf '%s=com.x.reader/S\naccessibility_enabled=1\n' $S > "$out"; cp "$out" "$W/ref.$$"
    cap GETRC=1
    if cmp -s "$out" "$W/ref.$$"; then ok "A5 failed read leaves the record byte for byte"; else no "A5 record changed on a failed read"; fi
    # an empty package listing leaves it too
    reset; mark; printf '%s=com.x.reader/S\n' $S > "$out"; cp "$out" "$W/ref.$$"; live $S ""
    cap A=1
    if cmp -s "$out" "$W/ref.$$"; then ok "A15 capture with an empty listing leaves the record byte for byte"; else no "A15 record changed on an empty listing"; fi

    # A6 WITHOUT the marker the file stays byte for byte and the line is logged
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S\naccessibility_enabled=1\n' $S > "$out"; cp "$out" "$W/ref.$$"
    live $S ""; live $F 0
    cap A=1
    if cmp -s "$out" "$W/ref.$$"; then ok "A6 no marker -> record byte for byte"; else no "A6 record changed before this session's apply"; fi
    if grep -q 'not applied yet this session for user 10' "$logf"; then ok "A6 line logged"; else no "A6 no log line"; fi

    # A7 apply puts installed entries and both framework forms, unioned with live; drops a not-installed one
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S:com.android.server.accessibility/ColorInversion:com.android.server.accessibility.MagnificationController:com.gone/S\n' $S > "$out"
    printf '%s=com.android.server.accessibility/ColorInversion\naccessibility_enabled=1\n' $B >> "$out"
    live $S com.live/L
    app A=1
    if [ "$(grep -c "secure $S " "$W/put.$$")" = 1 ] && grep -qx "put --user 10 secure $S com.live/L:com.x.reader/S:com.android.server.accessibility/ColorInversion:com.android.server.accessibility.MagnificationController" "$W/put.$$"; then ok "A7 one put: live first, installed + both framework forms, not-installed dropped"; else no "A7 puts: $(cat "$W/put.$$")"; fi
    if grep -qx "put --user 10 secure $B com.android.server.accessibility/ColorInversion" "$W/put.$$"; then ok "A7 colour inversion target put with no such package listed"; else no "A7 framework target not put"; fi
    if ! grep -q 'com.gone' "$W/put.$$"; then ok "A7 not-installed entry never put"; else no "A7 put a not-installed entry"; fi
    if [ -e "$st/.a11yapplied.10" ]; then ok "A7 marked"; else no "A7 not marked"; fi
    # union, not overwrite: an entry already live is not duplicated and nothing is put when nothing is added
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S\n' $S > "$out"; live $S com.x.reader/S:com.live/L
    app A=1
    if [ ! -s "$W/put.$$" ]; then ok "A7 nothing added -> no put"; else no "A7 put with nothing to add: $(cat "$W/put.$$")"; fi

    # A16 every live key reads null (the fresh user at grant): exactly the captured installed entries, no null token
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S:com.gone/S\n%s=com.android.server.accessibility/ColorInversion\naccessibility_enabled=1\n' $S $T > "$out"
    app A=1
    if grep -qx "put --user 10 secure $S com.x.reader/S" "$W/put.$$" && grep -qx "put --user 10 secure $T com.android.server.accessibility/ColorInversion" "$W/put.$$" && grep -qx "put --user 10 secure $F 1" "$W/put.$$" && [ "$(wc -l < "$W/put.$$")" -eq 3 ] && ! grep -q null "$W/put.$$"; then ok "A16 all live null -> exactly the captured installed entries, no null token"; else no "A16 puts: $(cat "$W/put.$$")"; fi

    # A8 apply with no file writes nothing and marks
    reset; pkgs com.x.reader
    app A=1
    if [ ! -s "$W/put.$$" ] && [ -e "$st/.a11yapplied.10" ]; then ok "A8 no file -> no put, marked"; else no "A8 no-file apply"; fi

    # A13 apply with an empty package listing: no put, no mark, record byte for byte
    reset; printf '%s=com.x.reader/S\naccessibility_enabled=1\n' $S > "$out"; cp "$out" "$W/ref.$$"
    app A=1
    if [ ! -s "$W/put.$$" ] && [ ! -e "$st/.a11yapplied.10" ] && cmp -s "$out" "$W/ref.$$"; then ok "A13 empty listing -> no put, not marked, record byte for byte"; else no "A13 empty-listing apply: $(cat "$W/put.$$")"; fi
    # A14 a failed live read in apply: no put over it, no mark
    reset; pkgs com.x.reader; printf '%s=com.x.reader/S\naccessibility_enabled=1\n' $S > "$out"
    app GETRC=1
    if [ ! -s "$W/put.$$" ] && [ ! -e "$st/.a11yapplied.10" ]; then ok "A14 failed live read -> no put, not marked"; else no "A14 failed-read apply: $(cat "$W/put.$$")"; fi

    # A9 accessibility_enabled is put 1 only with a service in the list
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S\naccessibility_enabled=1\n' $S > "$out"
    app A=1
    if grep -qx "put --user 10 secure $F 1" "$W/put.$$"; then ok "A9 flag put 1 with a service in the list"; else no "A9 flag not put: $(cat "$W/put.$$")"; fi
    reset; pkgs com.x.reader
    printf '%s=com.gone/S\naccessibility_enabled=1\n' $S > "$out"
    app A=1
    if ! grep -q "secure $F" "$W/put.$$"; then ok "A9 flag not put when every service filtered out"; else no "A9 flag put with an empty list"; fi
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S\naccessibility_enabled=0\n' $S > "$out"
    app A=1
    if ! grep -q "secure $F" "$W/put.$$"; then ok "A9 captured 0 -> never put (not on by default)"; else no "A9 flag put from a captured 0"; fi

    # A10 a failed put is logged and does NOT mark
    reset; pkgs com.x.reader
    printf '%s=com.x.reader/S\n' $S > "$out"
    app PUTRC=1
    if grep -q 'settings put FAILED for user 10' "$logf"; then ok "A10 failed put logged"; else no "A10 failed put not logged"; fi
    if [ ! -e "$st/.a11yapplied.10" ]; then ok "A10 not marked after a failed put"; else no "A10 marked after a failed put"; fi
    if [ -f "$out" ]; then ok "A10 record survives"; else no "A10 record gone"; fi

    # A11 no log line holds a package or a component
    if ! grep -q 'com\.\(x\|od\|gone\|live\)\|ColorInversion\|MagnificationController' "$logf" && grep -q 'a11y:' "$logf"; then ok "A11 log names no package or component"; else no "A11 log names a package or component (or logged nothing)"; fi
    # A12 pm never gets -a
    if [ -s "$W/pm.$$" ] && ! grep -Eq ' -[A-Za-z]*a|^-[A-Za-z]*a' "$W/pm.$$"; then ok "A12 pm never gets -a"; else no "A12 pm argv: $(cat "$W/pm.$$")"; fi
    # no marker is written by the capture
    reset; mark; pkgs com.x.reader; live $S com.x.reader/S; live $F 1
    cap A=1; rm -f "$st/.a11yapplied.10"
    cap A=1
    if [ ! -e "$st/.a11yapplied.10" ]; then ok "capture never writes the marker"; else no "capture wrote the marker"; fi

    # B1 apply with a pkg adds that package's entries even when the listing does not show it
    local OD="com.od.reader/com.od.reader.Svc" XR="com.x.reader/com.x.reader.Svc" CI="com.android.server.accessibility/ColorInversion"
    reset; pkgs com.x.reader
    printf '%s=%s:%s:%s\n%s=%s\n%s=com.od.reader/com.od.reader.Btn\naccessibility_enabled=1\n' $S "$XR" "$OD" "$CI" $T "$CI" $B > "$out"
    appk com.od.reader A=1
    if [ "$(grep -c "secure $S " "$W/put.$$")" = 1 ] && grep -qx "put --user 10 secure $S $OD" "$W/put.$$"; then ok "B1 the app's service put though the listing does not show it"; else no "B1 puts: $(cat "$W/put.$$")"; fi
    if grep -qx "put --user 10 secure $B com.od.reader/com.od.reader.Btn" "$W/put.$$"; then ok "B1 the app's button target put"; else no "B1 button target not put: $(cat "$W/put.$$")"; fi
    if grep -qx "put --user 10 secure $F 1" "$W/put.$$"; then ok "B1 the flag put 1 with the service added"; else no "B1 flag not put: $(cat "$W/put.$$")"; fi
    if inrec com.od.reader; then ok "B1 the pkg recorded"; else no "B1 the pkg not recorded"; fi
    if [ "$(ls -l "$st/.a11ydone.10" 2>/dev/null | cut -c1-10)" = "-rw-------" ]; then ok "B1 record mode 600"; else no "B1 record mode"; fi
    if [ ! -s "$W/pm.$$" ]; then ok "B1 no package listing taken"; else no "B1 pm called: $(cat "$W/pm.$$")"; fi
    if [ ! -e "$st/.a11yapplied.10" ]; then ok "B1 the grant marker is not written by a pkg call"; else no "B1 a pkg call wrote .a11yapplied"; fi
    # B2 another captured package's entries and the framework targets are not added by that call
    if ! grep -q 'com.x.reader' "$W/put.$$"; then ok "B2 another package's entry not put"; else no "B2 put another package's entry: $(cat "$W/put.$$")"; fi
    if ! grep -q "secure $T " "$W/put.$$" && ! grep -q ColorInversion "$W/put.$$"; then ok "B2 framework targets not re-added"; else no "B2 framework target put: $(cat "$W/put.$$")"; fi
    if [ "$(wc -l < "$W/put.$$")" -eq 3 ]; then ok "B2 exactly the three puts"; else no "B2 puts: $(cat "$W/put.$$")"; fi
    if ! inrec com.x.reader; then ok "B2 another package not recorded"; else no "B2 recorded another package"; fi

    # B3 the live value is kept (union)
    reset; printf '%s=%s\naccessibility_enabled=1\n' $S "$OD" > "$out"; live $S com.live/L; live $F 1
    appk com.od.reader A=1
    if grep -qx "put --user 10 secure $S com.live/L:$OD" "$W/put.$$" && [ "$(wc -l < "$W/put.$$")" -eq 1 ]; then ok "B3 live first, the app's entry unioned, flag already 1 not put"; else no "B3 puts: $(cat "$W/put.$$")"; fi

    # B4 no capture -> no put, the pkg recorded
    reset
    appk com.od.reader A=1
    if [ ! -s "$W/put.$$" ] && inrec com.od.reader && [ ! -e "$st/.a11yapplied.10" ]; then ok "B4 no capture -> no put, pkg recorded, not marked"; else no "B4 puts: $(cat "$W/put.$$")"; fi
    # no entry for the pkg in the capture -> nothing written, recorded
    reset; printf '%s=%s\naccessibility_enabled=1\n' $S "$XR" > "$out"
    appk com.od.reader A=1
    if [ ! -s "$W/put.$$" ] && inrec com.od.reader; then ok "B4 no entry for the pkg -> no put, pkg recorded"; else no "B4 no-entry puts: $(cat "$W/put.$$")"; fi

    # B5 a second call for the same pkg, after the user turned it off, writes nothing (the update heal)
    reset; printf '%s=%s\naccessibility_enabled=1\n' $S "$OD" > "$out"
    appk com.od.reader A=1
    live $S ""; live $F 0; : > "$W/put.$$"
    appk com.od.reader A=1
    if [ ! -s "$W/put.$$" ]; then ok "B5 the update heal writes nothing"; else no "B5 the second call put: $(cat "$W/put.$$")"; fi
    if grep -q 'already applied this session' "$logf"; then ok "B5 one line logged"; else no "B5 no log line"; fi
    if [ "$(grep -cxF com.od.reader "$st/.a11ydone.10")" = 1 ]; then ok "B5 recorded once"; else no "B5 record: $(cat "$st/.a11ydone.10" 2>/dev/null)"; fi
    # a look-alike recorded package does not count (whole-line match)
    reset; printf '%s=%s\n' $S "$OD" > "$out"; printf 'com.od.reader2\nx.com.od.reader\n' > "$st/.a11ydone.10"
    appk com.od.reader A=1
    if grep -qx "put --user 10 secure $S $OD" "$W/put.$$"; then ok "B5 a look-alike record line does not count"; else no "B5 look-alike: $(cat "$W/put.$$")"; fi

    # B6 the grant-time apply records the packages it applied; a later pkg call for one of them writes nothing
    reset; pkgs com.x.reader
    printf '%s=%s:%s:%s\naccessibility_enabled=1\n' $S "$XR" "$OD" "$CI" > "$out"
    app A=1
    if inrec com.x.reader; then ok "B6 grant records the installed package it applied"; else no "B6 grant did not record: $(cat "$st/.a11ydone.10" 2>/dev/null)"; fi
    if ! inrec com.od.reader && ! inrec com.android.server.accessibility; then ok "B6 a package waiting for install and a framework target not recorded"; else no "B6 recorded: $(cat "$st/.a11ydone.10" 2>/dev/null)"; fi
    live $S ""; live $F 0; : > "$W/put.$$"
    appk com.x.reader A=1
    if [ ! -s "$W/put.$$" ]; then ok "B6 the update heal of a grant-applied app writes nothing"; else no "B6 puts: $(cat "$W/put.$$")"; fi
    appk com.od.reader A=1
    if grep -qx "put --user 10 secure $S $OD" "$W/put.$$"; then ok "B6 the waiting app's first install still applies"; else no "B6 waiting app: $(cat "$W/put.$$")"; fi
    # a grant apply with a failed put records nothing
    reset; pkgs com.x.reader; printf '%s=%s\n' $S "$XR" > "$out"
    app PUTRC=1
    if [ ! -e "$st/.a11ydone.10" ]; then ok "B6 a failed grant put records nothing"; else no "B6 recorded after a failed put"; fi

    # B7 a pkg call whose put failed does not record it
    reset; printf '%s=%s\naccessibility_enabled=1\n' $S "$OD" > "$out"
    appk com.od.reader PUTRC=1
    if ! inrec com.od.reader; then ok "B7 failed put -> pkg not recorded"; else no "B7 recorded after a failed put"; fi
    if [ ! -e "$st/.a11yapplied.10" ]; then ok "B7 not marked"; else no "B7 marked"; fi
    reset; printf '%s=%s\n' $S "$OD" > "$out"
    appk com.od.reader GETRC=1
    if [ ! -s "$W/put.$$" ] && ! inrec com.od.reader; then ok "B7 failed live read -> no put, not recorded"; else no "B7 failed read: $(cat "$W/put.$$")"; fi

    # B9 (RF-001) a partial success: the services put landed, the flag put failed -> not recorded, and the retry,
    # finding the service already live, still puts the flag before it records the package. Stateful settings.
    reset; printf '%s=%s\naccessibility_enabled=1\n' $S "$OD" > "$out"; live $F 0
    appk com.od.reader STATEFUL=1 PUTFAIL=$F
    if [ "$(cat "$fx/get.$S" 2>/dev/null)" = "$OD" ] && [ "$(cat "$fx/get.$F")" = 0 ] && ! inrec com.od.reader; then ok "B9 flag put failed -> service live, flag 0, not recorded"; else no "B9 first call: svc '$(cat "$fx/get.$S" 2>/dev/null)' flag '$(cat "$fx/get.$F")' rec '$(cat "$st/.a11ydone.10" 2>/dev/null)'"; fi
    : > "$W/put.$$"
    appk com.od.reader STATEFUL=1
    if [ "$(cat "$fx/get.$F")" = 1 ] && grep -qx "put --user 10 secure $F 1" "$W/put.$$" && ! grep -q "secure $S " "$W/put.$$"; then ok "B9 the retry puts the flag, not the live service again"; else no "B9 retry: flag '$(cat "$fx/get.$F")' puts: $(cat "$W/put.$$")"; fi
    if inrec com.od.reader; then ok "B9 recorded once the flag landed"; else no "B9 not recorded after the retry"; fi
    # an unrecorded app whose captured service is already live (an earlier call landed it) gets its flag
    reset; printf '%s=%s\naccessibility_enabled=1\n' $S "$OD" > "$out"; live $S "$OD"; live $F 0
    appk com.od.reader STATEFUL=1
    if [ "$(cat "$fx/get.$F")" = 1 ] && inrec com.od.reader; then ok "B9 an unrecorded app whose service is live gets its flag"; else no "B9 live service: flag '$(cat "$fx/get.$F")'"; fi
    # but another package's live service never turns the flag on at this app's call
    reset; printf '%s=%s:%s\naccessibility_enabled=1\n' $S "$XR" "$OD" > "$out"; live $S "$XR"; live $F 0
    appk com.od.reader STATEFUL=1 PUTFAIL=$S
    if ! grep -q "secure $F" "$W/put.$$" && ! inrec com.od.reader; then ok "B9 another app's live service does not put the flag"; else no "B9 other app's service: $(cat "$W/put.$$")"; fi

    # B8 the pkg calls' log lines name no package or component either
    if ! grep -q 'com\.\(x\|od\|gone\|live\)\|ColorInversion\|MagnificationController' "$logf"; then ok "B8 log names no package or component"; else no "B8 log names a package or component"; fi

    # T-Y1/T-Y2 (NWP-20261121-12): a11y_apply returns and logs with a marker that cannot be written. The marker path is a
    # DIRECTORY, so `: >` on it fails as root too. Bash runs as --posix: POSIX makes a redirection error on a special
    # builtin fatal, so only a POSIX shell shows a bare `: >` ending the op. The seal capture's guard is
    # `[ ! -e marker ]`, and a directory reads as present: no capture runs after a plant.
    appx() { local o=""; [ "$sh" = bash ] && o=--posix
      env "$@" FX="$fx" STATE="$st" LOG="$logf" PUTLOG="$W/put.$$" PMLOG="$W/pm.$$" A11Y_USER_ROOT="$root" \
        "$sh" ${o:+"$o"} -c '. "$1"; a11y_apply 10; _r=$?; echo REACHED; exit "$_r"' x "$lib" </dev/null; }
    local tg=""; [ "$sh" = bash ] && tg=" (bash as --posix)"
    trunc_case() {  # $1 label, $2 the outcome log text, $3 the fixture setup -> control run, then the plant run
      local o rc crc am="$st/.a11yapplied.10" cp="$W/ctlput.$$" cr="$W/ctlrec.$$"
      reset; "$3"; : > "$logf"; rm -f "$cp" "$cr"
      appx A=1 >/dev/null 2>&1; crc=$?
      if [ "$crc" = 0 ]; then ok "$1$tg: the control run returns 0"; else no "$1$tg: the control run returns $crc"; fi
      if [ -f "$am" ]; then ok "$1$tg: the control run writes the marker"; else no "$1$tg: the control run did not reach the marker"; fi
      cp "$W/put.$$" "$cp"; [ ! -e "$st/.a11ydone.10" ] || cp "$st/.a11ydone.10" "$cr"
      reset; "$3"; : > "$logf"; mkdir -p "$am"
      if ( : > "$am" ) 2>/dev/null; then no "$1$tg: the plant did not block the write"; fi
      o=$(appx A=1 2>/dev/null); rc=$?
      case "$o" in *REACHED*) ok "$1$tg: a11y_apply returns to its caller" ;; *) no "$1$tg: the shell ended inside a11y_apply (no REACHED)" ;; esac
      if [ "$rc" = "$crc" ]; then ok "$1$tg: a11y_apply returns $rc, as in the control run"; else no "$1$tg: a11y_apply returns $rc, the control run $crc"; fi
      if grep -qF "$2" "$logf"; then ok "$1$tg: the outcome is logged ($2)"; else no "$1$tg: no '$2' in the log"; fi
      if cmp -s "$cp" "$W/put.$$"; then ok "$1$tg: the settings writes equal the control's"; else no "$1$tg: the settings writes differ from the control's: $(cat "$W/put.$$")"; fi
      if { [ -e "$cr" ] && cmp -s "$cr" "$st/.a11ydone.10"; } || { [ ! -e "$cr" ] && [ ! -e "$st/.a11ydone.10" ]; }; then
        ok "$1$tg: the session record equals the control's"; else no "$1$tg: the session record differs from the control's"; fi
      if [ -d "$am" ]; then ok "$1$tg: the plant is still a directory"; else no "$1$tg: the plant is gone"; fi
      rm -f "$cp" "$cr"
    }
    ty1() { pkgs com.x.reader; }
    ty2() { pkgs com.x.reader; printf '%s=com.x.reader/com.x.reader.Svc\naccessibility_enabled=1\n' $S > "$out"; }
    trunc_case "T-Y1 no capture, marker unwritable" "a11y: no capture for user 10" ty1
    reset; ty2; appx A=1 >/dev/null 2>&1
    if grep -qx "put --user 10 secure $S com.x.reader/com.x.reader.Svc" "$W/put.$$" && inrec com.x.reader; then ok "T-Y2$tg: the control puts the service and records the package"; else no "T-Y2$tg: the control: $(cat "$W/put.$$")"; fi
    trunc_case "T-Y2 applied, marker unwritable" "a11y: user 10: 1 carried, 1 applied, 0 waiting for install, 0 malformed, 0 failed puts" ty2
  fi

  # pins: the three call sites, read from the whole script
  local outarm grantarm inarm odarm n pl
  outarm=$(awk '/^  out\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  grantarm=$(awk '/^  grant\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  inarm=$(awk '/^  in\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  odarm=$(awk '/^  odrestore\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  n=$(printf '%s\n' "$outarm" | grep -c '^    a11y_seal_capture "\$USERDIR" "\$uid"')
  pl=$(printf '%s\n' "$outarm" | grep -B1 '^    a11y_seal_capture "\$USERDIR" "\$uid"' | head -n 1)
  case "$pl" in *'aod_seal_capture "$USERDIR" "$uid"'*) pl=yes ;; *) pl=no ;; esac
  if [ "$n" = 1 ] && [ "$pl" = yes ]; then ok "P1 out calls a11y_seal_capture once, right after aod_seal_capture"; else no "P1 out call missing, repeated or misplaced ($n, after aod: $pl)"; fi
  n=$(printf '%s\n' "$grantarm" | grep -c '^    a11y_apply "\$uid"')
  pl=$(printf '%s\n' "$grantarm" | grep -B1 '^    a11y_apply "\$uid"' | head -n 1)
  case "$pl" in *'aod_apply "$uid"'*) pl=yes ;; *) pl=no ;; esac
  if [ "$n" = 1 ] && [ "$pl" = yes ]; then ok "P2 grant calls a11y_apply once, right after aod_apply"; else no "P2 grant call missing, repeated or misplaced ($n, after aod: $pl)"; fi
  n=$(printf '%s\n' "$inarm" | grep -c '^    rm -f "\$STATE/.a11yapplied.\$uid" 2>/dev/null')
  if [ "$n" = 1 ]; then ok "P3 in clears .a11yapplied for its uid"; else no "P3 in's marker clear missing or repeated ($n)"; fi
  n=$(printf '%s\n' "$odarm" | grep -c '^      a11y_apply "\$uid" "\$pkg"')
  # NWP-20261202-16: the odrestore steps line's time stamps (`_odtN=$(_ms 2>/dev/null)`) are skipped, so only a stamp may sit between the two.
  pl=$(printf '%s\n' "$odarm" | grep -v '^      _odt[0-9]*=\$(_ms 2>/dev/null)$' | grep -B1 '^      a11y_apply "\$uid" "\$pkg"' | head -n 1)
  case "$pl" in '      grant_perms_for "$uid" "$pkg" "$_first"'*) pl=yes ;; *) pl=no ;; esac
  if [ "$n" = 1 ] && [ "$pl" = yes ]; then ok "P4 odrestore calls a11y_apply <uid> <pkg> once, on the line after grant_perms_for"; else no "P4 odrestore call missing, repeated or misplaced ($n, after grant_perms_for: $pl)"; fi
  n=$(printf '%s\n' "$inarm" | grep -c '^      rm -f "\$STATE/.a11ydone.\$uid" 2>>"\$LOG"')
  pl=$(printf '%s\n' "$inarm" | grep -B1 '^      rm -f "\$STATE/.a11ydone.\$uid" 2>>"\$LOG"' | head -n 1)
  case "$pl" in '      rm -f "$STATE/.granted.$uid" 2>>"$LOG"'*) pl=yes ;; *) pl=no ;; esac
  if [ "$n" = 1 ] && [ "$pl" = yes ]; then ok "P5 in clears .a11ydone for its uid, on the line after the .granted clear"; else no "P5 in's record clear missing, repeated or misplaced ($n, after .granted: $pl)"; fi

  rm -rf "$root" "$st" "$fx" "$lib" "$logf" "$W/put.$$" "$W/pm.$$" "$W/ref.$$" "$W/ctlput.$$" "$W/ctlrec.$$"
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
mutant "N1 the keep-record (nowhere-appkeep) check dropped" \
  's#\[ -n "\$(printf .%s\\n. "\$_ak" | grep -xF "\$_p")" \] || continue#:#'
mutant "N2 apply ignores the installed filter" \
  's#if \[ "\$_kind" = pkg \] \&\& \[ -z #if false \&\& [ -z #'
mutant "N3 apply overwrites instead of union" \
  '/a11y_apply() {/,/^}/s#_res="\$_live"; _added=0#_res=""; _added=0#'
mutant "N4 capture shrinks on a failed read" \
  '/a11y_seal_capture() {/,/^}/s#</dev/null 2>/dev/null) || {#</dev/null 2>/dev/null); true || {#'
mutant "N5 a log line prints the component" \
  's#captured for user \$_uid: \$_nc carried#captured for user $_uid ($_body): $_nc carried#'
mutant "N6 the capture's marker guard removed" \
  's#if \[ ! -e "\$STATE/.a11yapplied.\$_uid" \]; then#if false; then#'
mutant "N7 apply marks after a failed put" \
  's#  if \[ "\$_nf" != 0 \]; then#  if false; then#'
mutant "N8 the framework rule narrowed to the no-/ form" \
  's#\[ "\$_p" = com.android.server.accessibility \] && _kind=fw#false#'
mutant "N9 the out call removed" \
  '/^    a11y_seal_capture "\$USERDIR" "\$uid"/d'
mutant "N10 the grant call removed" \
  '/^    a11y_apply "\$uid"  #/d'
mutant "N11 the in arm's marker clear dropped" \
  '/^    rm -f "\$STATE\/.a11yapplied.\$uid" 2>\/dev\/null/d'
mutant "N12 apply keeps a live null as an entry" \
  '/a11y_apply() {/,/^}/s#\[ "\$_live" = null \] && _live=""#:#'
mutant "N13 apply marks after an empty listing" \
  '/a11y_apply() {/,/^}/s#nothing applied, record kept for the next sign-in \$(date)" >> "\$LOG"#&; : > "$STATE/.a11yapplied.$_uid"#'
mutant "N14 apply puts over a failed live read" \
  '/a11y_apply() {/,/^}/s#</dev/null 2>/dev/null) || { _nf=\$((_nf+1)); continue; }#</dev/null 2>/dev/null) || _live=""#'
mutant "N15 capture proceeds on an empty listing" \
  '/a11y_seal_capture() {/,/^}/s#  if \[ -z "\$_pl" \]; then#  if false; then#'
mutant "P1 the pkg filter ignored (every captured entry written at a tap)" \
  '/a11y_apply() {/,/^}/{/\[ "\$_p" = "\$_only" \]/d}'
mutant "P2 the session record check dropped" \
  's#if \[ -n "\$_only" \] \&\& grep -qxF -- "\$_only" "\$_rec" 2>/dev/null; then#if false; then#'
mutant "P3 the grant-time apply records nothing" \
  '/a11y_apply() {/,/^}/{/_done="\${_done:+\$_done:}\$_p"/d}'
mutant "P4 the odrestore call removed" \
  '/^      a11y_apply "\$uid" "\$pkg"/d'
mutant "P5 the odrestore call placed before grant_perms_for" \
  '/^      a11y_apply "\$uid" "\$pkg"/d;s#^      grant_perms_for "\$uid" "\$pkg" "\$_first"$#      a11y_apply "$uid" "$pkg"\n&#'
mutant "P6 the roam-in clear of .a11ydone dropped" \
  '/^      rm -f "\$STATE\/.a11ydone.\$uid"/d'
mutant "P7 a pkg call puts the flag only for a service it added itself (RF-001)" \
  '/a11y_apply() {/,/^}/s#\&\& _mine="\${_mine:+\$_mine:}\$_e"$#\&\& { case ":$_res:" in *":$_e:"*) ;; *) _mine="${_mine:+$_mine:}$_e" ;; esac; }#'
# T1/T2 (NWP-20261121-12): one marker site each goes back to the bare `: >`, which ends a POSIX shell on an unwritable marker.
mutant "T1 a11y_apply's no-capture marker is a bare : > again" \
  '/^a11y_apply() {$/,/^}$/s#^      ( : > "\$STATE/.a11yapplied.\$_uid" ) 2>>"\$LOG"$#      : > "$STATE/.a11yapplied.$_uid" 2>>"$LOG"#'
mutant "T2 a11y_apply's applied marker is a bare : > again" \
  '/^a11y_apply() {$/,/^}$/s#else ( : > "\$STATE/.a11yapplied.\$_uid" ) 2>>"\$LOG"; fi#else : > "$STATE/.a11yapplied.$_uid" 2>>"$LOG"; fi#'
# R1/R2 (NWP-20261121-12, RF-001): each branch keeps its log line but returns 7 when the marker is a directory. Only the
# rc assertion sees this, so the case must compare a11y_apply's own status, not the status of the `echo` after it.
mutant "R1 a11y_apply's no-capture branch returns 7 on an unwritable marker" \
  '/^a11y_apply() {$/,/^}$/{/a11y: no capture for user/,/^  }$/s#^    return 0$#    [ -d "$STATE/.a11yapplied.$_uid" ] \&\& return 7; return 0#}'
mutant "R2 a11y_apply returns 7 on an unwritable marker after the puts" \
  '/^a11y_apply() {$/,/^}$/s#^  return 0$#  [ -d "$STATE/.a11yapplied.$_uid" ] \&\& return 7; return 0#'
echo; [ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ a mutation survived or did not apply"
exit $MRC
