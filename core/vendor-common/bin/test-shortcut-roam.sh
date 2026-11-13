#!/usr/bin/env bash
# test-shortcut-roam.sh [<nowhere_roamd.sh>] [--mutate] -- pinned home-screen shortcuts roam (NWP-20261202-13).
#
# docs/product-decisions.md 2026-10-26: a pinned shortcut roams with the profile and comes back once its owning app is
# on the profile. roamd captures ShortcutService's per-user files at seal into nowhere-shortcuts (the sealed chooser CE
# dir) with the user id tokenised, and at grant, before switch-in, stages the installed owners' files, unloads the user
# with `cmd shortcut unload-user` and places them. Every failure here is silent: a tokeniser that rewrites any digit
# corrupts a shortcut id or a timestamp; a capture before this session's apply deletes the record; a capture without
# its .fp skip runs abx2xml at every periodic seal; a capture without carry-forward loses an absent app's shortcut; an
# apply that places an absent owner leaves a broken icon; an apply that places without a successful unload, or converts
# after it, races ShortcutService's reload; a log line that names a package outlives the session in roam.log.
#
# The four helpers (shortcut_xml, shortcut_pins, shortcut_seal_capture, shortcut_apply) are extracted from
# nowhere_roamd.sh BY ANCHOR, each exactly once, never copied. pm, cmd, abx2xml/xml2abx (a text copy that logs its
# call), chown, restorecon, cp, find and _ms are stubbed; the failure stubs print a package path. Every case runs
# under every shell found (bash, sh, dash, mksh).
#
#   bash test-shortcut-roam.sh            # the truth table + the source pins
#   bash test-shortcut-roam.sh --mutate   # ... plus mutants that must each CONVICT, under every shell
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

# A real abx2xml on the host would answer `command -v` in the NOTOOL cases: run every case with a PATH without it.
CLEANPATH=""
IFS_OLD=$IFS; IFS=:
for d in $PATH; do [ -x "$d/abx2xml" ] || [ -x "$d/xml2abx" ] || CLEANPATH="${CLEANPATH:+$CLEANPATH:}$d"; done
IFS=$IFS_OLD

extract() {  # $1 = script, $2 = dest lib -> 0 iff each function is found exactly once
  local f="$1" dest="$2" fn n
  : > "$dest"
  for fn in shortcut_xml shortcut_pins shortcut_seal_capture shortcut_apply; do
    n=$(grep -c "^${fn}() {\$" "$f")
    if [ "$n" != 1 ]; then echo "EXTRACTION FAILED: ${fn}() found $n times" >&2; return 1; fi
    sed -n "/^${fn}() {\$/,/^}\$/p" "$f" >> "$dest"
  done
  cat >> "$dest" <<'STUB'
pm() {
  echo "pm $*" >> "$CALLS"
  case " $* " in *" -a "*) [ -f "$FX/pkgs.all" ] && { sed 's/^/package:/' "$FX/pkgs.all"; return 0; } ;; esac
  [ -f "$FX/pkgs" ] && sed 's/^/package:/' "$FX/pkgs"
  return 0
}
cmd() { echo "cmd $*" >> "$CALLS"; return "${UNLOADRC:-0}"; }
if [ -z "${NOTOOL:-}" ]; then
  abx2xml() { echo "abx2xml $1" >> "$CALLS"; cp "$1" "$2" || return 1; return 0; }
  xml2abx() { echo "xml2abx $1" >> "$CALLS"; cp "$1" "$2" || return 1; return "${XABXRC:-0}"; }
fi
# Each failure stub prints an error that NAMES a package path, as the real tool does, so a helper that sends the
# stream to $LOG leaks it (L2).
chown() {
  echo "chown $*" >> "$CALLS"
  [ -z "${CHOWNRC:-}" ] || { echo "chown: $3/packages/com.x.browser.xml: Operation not permitted" >&2; return 1; }
}
restorecon() {
  echo "restorecon $*" >> "$CALLS"
  [ -z "${RCONRC:-}" ] || { echo "restorecon: $2/packages/com.x.browser.xml: Permission denied" >&2; return 1; }
}
find() {
  case " $* " in *" -type ${CHMODRC:-none} -exec chmod "*) { echo "chmod: $1/packages/com.x.browser.xml: Read-only" >&2; return 1; } ;; esac
  command find "$@"
}
cp() {
  case " $* " in *"/bitmaps/"*) [ -z "${CPFAIL:-}" ] || { echo "cp: cannot open '$2/com.x.browser/1010.png': I/O error" >&2; return 1; } ;; esac
  command cp "$@"
}
_ms() { echo 1000; }
STUB
}

HDR="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"
# pkgxml <pkg> <uid-or-@U@>: an owner's package file, one tag per line (as the normaliser prints it)
pkgxml() {
  printf '%s\n' "$HDR" "<package name=\"$1\" call-count=\"0\" last-reset=\"0\">" \
    "<shortcut id=\"p-$1\" title=\"T\" intent-base=\"https://bank.example/\" bitmap-path=\"/data/system_ce/$2/shortcut_service/bitmaps/$1/7.png\" />" \
    '</package>'
}
# the live browser package file carries every decoy: ids, timestamps, a non -user attribute and another user's prefix
browserxml() {
  printf '%s\n' "$HDR" '<package name="com.x.browser" call-count="0" last-reset="1699100000010">' \
    '<package-info version="10" last_udpate_time="1699100000010" />' \
    "<shortcut id=\"s10\" title=\"Bank\" intent-base=\"https://bank.example/\" timestamp=\"1699100000010\" rank=\"10\" bitmap-path=\"/data/system_ce/$1/shortcut_service/bitmaps/com.x.browser/1010.png\" note=\"/data/system_ce/100/x\">" \
    '<intent-extras />' '</shortcut>' '</package>'
}
# userxml: the user file
userxml() { printf '%s\n' "$HDR" '<user locales="en-US" last-app-scan-time2="1699100000010" />'; }

# suite <roamd> <shell> [quiet] -> 0 iff every check holds under that shell
suite() {
  local sut="$1" sh="$2" quiet="${3:-}" p=0 x=0
  local lib="$W/lib.$$.sh" root="$W/root.$$" st="$W/state.$$" fx="$W/fx.$$" clog="$W/clog.$$" all="$W/all.$$"
  local calls="$W/calls.$$" ref="$W/ref.$$"
  local live="$W/root.$$/ce/10/shortcut_service" rec="$W/root.$$/user/10/com.nowhere.chooser/files/nowhere-shortcuts"
  local live11="$W/root.$$/ce/11/shortcut_service" rec11="$W/root.$$/user/11/com.nowhere.chooser/files/nowhere-shortcuts"
  local files="$W/root.$$/user/10/com.nowhere.chooser/files"
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok   [%s] %s\n' "$sh" "$1"; }
  no() { x=$((x+1)); printf '  FAIL [%s] %s\n' "$sh" "$1"; }
  : > "$all"
  local have=yes f
  if ! extract "$sut" "$lib"; then
    have=no
    for f in K1 K2 K3 K4 C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 A1 A2 A3 A4 A5 A6 A7 A8 A9 A10 A11 A12 A13 L1 L2; do no "$f not run: the helpers are not in the script"; done
  fi

  # run "<VAR=val ...>" <fn> <args...>: one helper call under $sh, with the case log and the call log fresh
  run() {
    local e="$1"; shift
    : > "$clog"; : > "$calls"
    # shellcheck disable=SC2086
    env $e PATH="$CLEANPATH" FX="$fx" STATE="$st" LOG="$clog" CALLS="$calls" SHORTCUT_CE_ROOT="$root/ce" \
      SHORTCUT_USER_ROOT="$root/user" "$sh" -c '. "$1"; shift; "$@"' x "$lib" "$@" </dev/null >/dev/null 2>&1
    cat "$clog" >> "$all"
  }
  cap() { run "${1:-}" shortcut_seal_capture "$root/user/10" 10; }
  app() { run "${2:-}" shortcut_apply "$1"; }
  pkgs() { printf '%s\n' "$@" > "$fx/pkgs"; }
  mark() { : > "$st/.shortcutsapplied.$1"; }
  logs() { grep -qF -- "$1" "$clog"; }
  ncalls() { grep -c "^$1" "$calls"; }
  # reset: a fresh case -- the live user-10 dir with one browser pin (plus a foreign-user block), no record, no marker
  reset() {
    local o
    rm -rf "$root" "$st" "$fx"; mkdir -p "$live/packages" "$live/launchers" "$live/bitmaps/com.x.browser" "$files" "$st" "$fx"
    userxml > "$live/shortcuts.xml"
    browserxml 10 > "$live/packages/com.x.browser.xml"
    for o in com.x.nopin com.x.other; do pkgxml "$o" 10 > "$live/packages/$o.xml"; done
    printf 'PNG10' > "$live/bitmaps/com.x.browser/1010.png"
    printf '%s\n' "$HDR" '<launcher-pins package-name="com.android.launcher3" launcher-user="10">' \
      '<package-info version="1" />' \
      '<package package-name="com.x.browser" package-user="10">' '<pin value="s10" />' '</package>' \
      '<package package-name="com.x.other" package-user="100">' '<pin value="o1" />' '</package>' \
      '</launcher-pins>' > "$live/launchers/com.android.launcher310.xml"
    pkgs com.x.browser com.x.nopin com.x.other; rm -f "$fx/pkgs.all"
  }
  # mkrec <dir> <owner...>: a tokenised record holding these owners, each with a pin, a package file and a bitmap
  mkrec() {
    local d="$1" o; shift
    rm -rf "$d"; mkdir -p "$d/packages" "$d/launchers" "$d/bitmaps"
    userxml > "$d/user.xml"
    { printf '%s\n' "$HDR" '<launcher-pins package-name="com.android.launcher3" launcher-user="@U@">'
      for o in "$@"; do printf '%s\n' "<package package-name=\"$o\" package-user=\"@U@\">" "<pin value=\"p-$o\" />" '</package>'; done
      printf '%s\n' '</launcher-pins>'; } > "$d/launchers/com.android.launcher3.xml"
    for o in "$@"; do
      if [ "$o" = com.x.browser ]; then browserxml @U@ > "$d/packages/$o.xml"; mkdir -p "$d/bitmaps/$o"; printf 'PNG10' > "$d/bitmaps/$o/1010.png"
      else pkgxml "$o" @U@ > "$d/packages/$o.xml"; mkdir -p "$d/bitmaps/$o"; printf 'PNG-%s' "$o" > "$d/bitmaps/$o/7.png"; fi
    done
  }
  snap() { (cd "$1" 2>/dev/null && find . | LC_ALL=C sort | while IFS= read -r q; do echo "$q"; [ -f "$q" ] && cat "$q"; done); }
  nblk() { grep -c "package-name=\"$1\"" "$2" 2>/dev/null; }

  if [ "$have" = yes ]; then
    local L="$rec/launchers/com.android.launcher3.xml" B="$rec/packages/com.x.browser.xml" s

    # K1 tokenise 10: the CE prefix, the -user attributes, the launcher file name
    reset; mark 10
    cap
    if grep -qF 'bitmap-path="/data/system_ce/@U@/shortcut_service/bitmaps/com.x.browser/1010.png"' "$B" 2>/dev/null; then ok "K1 the /data/system_ce/<u>/ prefix tokenised"; else no "K1 prefix: $(grep bitmap-path "$B" 2>/dev/null)"; fi
    if grep -qF 'launcher-user="@U@"' "$L" 2>/dev/null && grep -qF '<package package-name="com.x.browser" package-user="@U@">' "$L"; then ok "K1 launcher-user and package-user tokenised"; else no "K1 -user attributes: $(cat "$L" 2>/dev/null)"; fi
    if [ -f "$L" ] && [ ! -e "$rec/launchers/com.android.launcher310.xml" ]; then ok "K1 the launcher file name drops its trailing <u>"; else no "K1 launcher names: $(ls "$rec/launchers" 2>/dev/null)"; fi
    # K2 every decoy is byte-identical in the record
    for s in 'id="s10"' '<pin value="s10" />' 'timestamp="1699100000010"' 'rank="10"' 'note="/data/system_ce/100/x"' 'version="10"'; do
      if grep -qF -- "$s" "$B" "$L" 2>/dev/null; then ok "K2 decoy $s unchanged"; else no "K2 decoy $s rewritten"; fi
    done
    if cmp -s "$rec/bitmaps/com.x.browser/1010.png" "$live/bitmaps/com.x.browser/1010.png"; then ok "K2 bitmap 1010.png copied under its own name, bytes verbatim"; else no "K2 bitmap missing or changed"; fi
    # K4 the package-user="100" block is malformed: not in the record (.fp aside: it lists the live dir), counted
    if [ -d "$rec" ] && ! grep -rqF --exclude=.fp com.x.other "$rec"; then ok "K4 another user's block is not in the record"; else no "K4 com.x.other in the record: $(grep -rlF --exclude=.fp com.x.other "$rec" 2>/dev/null)"; fi
    if logs 'shortcuts: captured for user 10: 1 pinned owner(s), 0 waiting for install, 1 malformed (NWP-20261202-13)'; then ok "K4 counted as 1 malformed"; else no "K4 log: $(cat "$clog")"; fi
    # C11 files 0600, dirs 0700
    if [ -z "$(find "$rec" -type f ! -perm 600)" ] && [ -z "$(find "$rec" -type d ! -perm 700)" ]; then ok "C11 record files 0600, dirs 0700"; else no "C11 modes: $(find "$rec" ! -perm 600 ! -perm 700)"; fi
    if [ ! -e "$files/.nowhere-shortcuts.new" ] && [ ! -e "$rec/.w" ]; then ok "C11 no work dir left"; else no "C11 work dir left"; fi

    # C6 an unchanged live dir and listing: no abx2xml call
    cp -R "$rec" "$ref"
    cap
    if [ "$(ncalls abx2xml)" = 0 ] && logs '(unchanged)'; then ok "C6 unchanged .fp -> no abx2xml call"; else no "C6 abx2xml calls: $(ncalls abx2xml), log: $(cat "$clog")"; fi
    if [ "$(snap "$rec")" = "$(snap "$ref")" ]; then ok "C6 record untouched"; else no "C6 record changed"; fi
    rm -rf "$ref"

    # K3 round trip: the user-10 record applied to user 11 gives the originals with 10 -> 11 at the rule sites only
    rm -rf "$root/user/11"; mkdir -p "$root/user/11/com.nowhere.chooser/files"; cp -R "$rec" "$rec11"
    pkgs com.x.browser
    app 11
    if [ "$(cat "$live11/packages/com.x.browser.xml" 2>/dev/null)" = "$(browserxml 11)" ]; then ok "K3 package file round trip 10 -> 11"; else no "K3 package file: $(cat "$live11/packages/com.x.browser.xml" 2>/dev/null)"; fi
    if [ "$(cat "$live11/launchers/com.android.launcher311.xml" 2>/dev/null)" = "$(sed -e 's/launcher-user="10"/launcher-user="11"/' -e 's/package-user="10"/package-user="11"/' -e '/com.x.other/,/<\/package>/d' "$live/launchers/com.android.launcher310.xml")" ]; then ok "K3 launcher file round trip, named com.android.launcher311.xml"; else no "K3 launcher: $(ls "$live11/launchers" 2>/dev/null) $(cat "$live11/launchers/"* 2>/dev/null)"; fi
    if cmp -s "$live11/shortcuts.xml" "$live/shortcuts.xml" && cmp -s "$live11/bitmaps/com.x.browser/1010.png" "$live/bitmaps/com.x.browser/1010.png"; then ok "K3 user file and bitmap round trip"; else no "K3 user file or bitmap differ"; fi
    # A9 pm without -a
    if [ -n "$(grep '^pm list packages --user 11' "$calls")" ] && [ -z "$(grep -e ' -a' "$calls" | grep '^pm')" ]; then ok "A9 apply lists packages without -a"; else no "A9 pm calls: $(grep '^pm' "$calls")"; fi

    # C1 no marker: the record is kept, no conversion
    reset; mkrec "$rec" com.x.gone; cp -R "$rec" "$ref"
    cap
    if [ "$(snap "$rec")" = "$(snap "$ref")" ] && [ "$(ncalls abx2xml)" = 0 ] && logs '(unapplied)'; then ok "C1 no marker -> record kept, no abx2xml"; else no "C1 log: $(cat "$clog")"; fi
    # C2 empty listing
    mark 10; : > "$fx/pkgs"
    cap
    if [ "$(snap "$rec")" = "$(snap "$ref")" ] && logs '(nolisting)'; then ok "C2 empty listing -> record kept"; else no "C2 log: $(cat "$clog")"; fi
    # C3 no layout
    pkgs com.x.browser; mv "$live/launchers" "$live/l.off"
    cap
    if [ "$(snap "$rec")" = "$(snap "$ref")" ] && logs '(layout)'; then ok "C3 no launchers/ -> record kept"; else no "C3 launchers log: $(cat "$clog")"; fi
    mv "$live/l.off" "$live/launchers"; mv "$live/packages" "$live/p.off"
    cap
    if [ "$(snap "$rec")" = "$(snap "$ref")" ] && logs '(layout)'; then ok "C3 no packages/ -> record kept"; else no "C3 packages log: $(cat "$clog")"; fi
    mv "$live/p.off" "$live/packages"
    # C4 no abx2xml
    cap NOTOOL=1
    if [ "$(snap "$rec")" = "$(snap "$ref")" ] && logs '(notool)'; then ok "C4 no abx2xml -> record kept"; else no "C4 log: $(cat "$clog")"; fi
    # C5 over the cap
    cap SHORTCUT_MAX_BYTES=100
    if [ "$(snap "$rec")" = "$(snap "$ref")" ] && logs '(toolarge)' && [ ! -e "$files/.nowhere-shortcuts.new" ]; then ok "C5 over the cap -> old record kept byte for byte, no work dir"; else no "C5 log: $(cat "$clog")"; fi
    rm -rf "$ref"

    # C7 an absent owner is carried with its package file, bitmaps and launcher block, once
    reset; mark 10; mkrec "$rec" com.x.gone
    cap
    if [ -f "$rec/packages/com.x.gone.xml" ] && [ -f "$rec/bitmaps/com.x.gone/7.png" ] && [ "$(nblk com.x.gone "$L")" = 1 ] && [ "$(nblk com.x.browser "$L")" = 1 ]; then ok "C7 absent owner carried: package file, bitmaps, launcher block"; else no "C7 record: $(find "$rec" -type f) $(cat "$L" 2>/dev/null)"; fi
    if logs '1 pinned owner(s), 1 waiting for install'; then ok "C7 counted as waiting"; else no "C7 log: $(cat "$clog")"; fi
    if [ "$(cat "$rec/.waiting" 2>/dev/null)" = com.x.gone ]; then ok "C7 .waiting names the carried owner"; else no "C7 .waiting: $(cat "$rec/.waiting" 2>/dev/null)"; fi
    printf 'x' > "$live/bitmaps/com.x.browser/1011.png"
    cap
    if [ "$(nblk com.x.gone "$L")" = 1 ] && [ -f "$rec/packages/com.x.gone.xml" ]; then ok "C7 a second capture carries it again, no duplicate block"; else no "C7 second capture: $(nblk com.x.gone "$L") blocks"; fi
    # C8 an installed owner with no live pin, not waiting, is dropped
    reset; mark 10; mkrec "$rec" com.x.nopin
    cap
    if [ ! -e "$rec/packages/com.x.nopin.xml" ] && [ ! -e "$rec/bitmaps/com.x.nopin" ] && [ "$(nblk com.x.nopin "$L")" = 0 ]; then ok "C8 installed owner without a pin dropped"; else no "C8 still in the record"; fi
    # C9 nothing live and nothing to carry: the record is removed
    reset; mark 10; mkrec "$rec" com.x.nopin; rm -f "$live/launchers/"*
    cap
    if [ ! -e "$rec" ] && logs '0 pinned owner(s), 0 waiting for install'; then ok "C9 empty result removes the record"; else no "C9 record left, log: $(cat "$clog")"; fi
    # C10 a bad package name is malformed, nothing written outside the record
    reset; mark 10
    printf '%s\n' "$HDR" '<launcher-pins package-name="com.android.launcher3" launcher-user="10">' \
      '<package package-name="com.x.browser" package-user="10">' '<pin value="s10" />' '</package>' \
      '<package package-name="../x" package-user="10">' '<pin value="b1" />' '</package>' \
      '</launcher-pins>' > "$live/launchers/com.android.launcher310.xml"
    printf 'evil' > "$live/x.xml"
    cap
    if logs '1 pinned owner(s), 0 waiting for install, 1 malformed' && [ ! -e "$files/x.xml" ] && [ ! -e "$rec/x.xml" ] && ! grep -rqF '../x' "$rec"; then ok "C10 bad name counted malformed, nothing outside the record"; else no "C10 log: $(cat "$clog")"; fi

    # C12 an owner waiting at apply and installed later in the session, with no pin yet, is carried
    reset; mkrec "$rec" com.x.browser com.x.later; pkgs com.x.browser
    app 10
    if [ "$(cat "$rec/.waiting" 2>/dev/null)" = com.x.later ]; then ok "C12 apply names the absent owner in .waiting"; else no "C12 .waiting: $(cat "$rec/.waiting" 2>/dev/null)"; fi
    pkgs com.x.browser com.x.later
    cap
    if [ -f "$rec/packages/com.x.later.xml" ] && [ -f "$rec/bitmaps/com.x.later/7.png" ] && [ "$(nblk com.x.later "$L")" = 1 ] && [ "$(cat "$rec/.waiting" 2>/dev/null)" = com.x.later ]; then ok "C12 installed-later owner still carried, still waiting"; else no "C12 record: $(find "$rec" -type f) .waiting=$(cat "$rec/.waiting" 2>/dev/null)"; fi
    if logs '1 pinned owner(s), 1 waiting for install'; then ok "C12 counted as waiting"; else no "C12 log: $(cat "$clog")"; fi
    # C13 a waiting owner that now has a live pin is captured from live and leaves .waiting
    reset; mark 10; mkrec "$rec" com.x.browser; printf 'com.x.browser\n' > "$rec/.waiting"
    cap
    if [ ! -e "$rec/.waiting" ] && logs '1 pinned owner(s), 0 waiting for install' && grep -qF 'note="/data/system_ce/100/x"' "$B"; then ok "C13 waiting owner with a live pin captured from live"; else no "C13 log: $(cat "$clog") .waiting=$(cat "$rec/.waiting" 2>/dev/null)"; fi

    # A1 only installed owners are placed; absent ones are stripped from the launcher file
    reset; rm -rf "$root/ce/11"; mkdir -p "$root/user/11/com.nowhere.chooser/files"; mkrec "$rec11" com.x.browser com.x.gone
    pkgs com.x.browser; printf '%s\n' com.x.browser com.x.gone > "$fx/pkgs.all"
    app 11
    if [ -f "$live11/packages/com.x.browser.xml" ] && [ ! -e "$live11/packages/com.x.gone.xml" ] && [ ! -e "$live11/bitmaps/com.x.gone" ] && [ -f "$live11/bitmaps/com.x.browser/1010.png" ]; then ok "A1 only the installed owner's files placed"; else no "A1 live: $(find "$live11" -type f)"; fi
    if [ "$(nblk com.x.gone "$live11/launchers/com.android.launcher311.xml")" = 0 ] && [ "$(nblk com.x.browser "$live11/launchers/com.android.launcher311.xml")" = 1 ]; then ok "A1 absent owner stripped from the launcher file"; else no "A1 launcher: $(cat "$live11/launchers/"* 2>/dev/null)"; fi
    if logs 'shortcuts: placed for user 11: 1 owner(s), 1 waiting for install, userfile=placed, 0 ms (NWP-20261202-13)'; then ok "A1 counts logged"; else no "A1 log: $(cat "$clog")"; fi
    # A10 .waiting is exactly the owners not placed
    if [ "$(cat "$rec11/.waiting" 2>/dev/null)" = com.x.gone ] && [ "$(ls -l "$rec11/.waiting" | cut -c1-10)" = "-rw-------" ] && [ ! -e "$rec11/.waiting.new" ]; then ok "A10 .waiting = the absent owner, 0600, no .waiting.new"; else no "A10 .waiting: $(cat "$rec11/.waiting" 2>/dev/null)"; fi
    # A5 marker, chown, restorecon
    if [ -f "$st/.shortcutsapplied.11" ] && [ -n "$(grep -xF "chown -R system:system $live11" "$calls")" ] && [ -n "$(grep -xF "restorecon -R $live11" "$calls")" ]; then ok "A5 marked, chown + restorecon on the live dir"; else no "A5 marker or calls: $(cat "$calls")"; fi
    if [ ! -e "$root/ce/11/.nowhere-shortcuts-stage" ]; then ok "A5 no stage dir left"; else no "A5 stage dir left"; fi
    # A4 one unload, after every xml2abx
    local un lx
    un=$(grep -n '^cmd shortcut unload-user --user 11$' "$calls" | cut -d: -f1)
    lx=$(grep -n '^xml2abx ' "$calls" | tail -n 1 | cut -d: -f1)
    if [ "$(grep -c '^cmd ' "$calls")" = 1 ] && [ -n "$un" ] && [ -n "$lx" ] && [ "$un" -gt "$lx" ]; then ok "A4 one unload-user, after every xml2abx"; else no "A4 calls: $(cat "$calls")"; fi
    # A10 with nothing absent, no .waiting
    rm -rf "$root/ce/11"; mkrec "$rec11" com.x.browser; printf 'com.x.browser\n' > "$rec11/.waiting"
    app 11
    if [ ! -e "$rec11/.waiting" ]; then ok "A10 nothing absent -> no .waiting"; else no "A10 .waiting left: $(cat "$rec11/.waiting")"; fi

    # A2 user.xml only when the live user file is absent
    rm -rf "$root/ce/11"; mkdir -p "$live11"; printf 'LIVE' > "$live11/shortcuts.xml"; mkrec "$rec11" com.x.browser
    app 11
    if [ "$(cat "$live11/shortcuts.xml")" = LIVE ] && logs 'userfile=live'; then ok "A2 a live user file is not overwritten"; else no "A2 live user file: $(cat "$live11/shortcuts.xml"), log: $(cat "$clog")"; fi
    rm -rf "$root/ce/11"
    app 11
    if cmp -s "$live11/shortcuts.xml" "$rec11/user.xml" && logs 'userfile=placed'; then ok "A2 an absent user file is placed"; else no "A2 placed: log $(cat "$clog")"; fi

    # A3 unload failure: nothing placed, no marker, no stage, record intact
    rm -rf "$root/ce/11" "$st"; mkdir -p "$st" "$live11/packages"; printf 'OLD' > "$live11/packages/keep.xml"
    mkrec "$rec11" com.x.browser; cp -R "$rec11" "$ref"; local before; before=$(snap "$live11")
    app 11 UNLOADRC=1
    if [ "$(snap "$live11")" = "$before" ] && [ ! -e "$st/.shortcutsapplied.11" ] && [ ! -e "$root/ce/11/.nowhere-shortcuts-stage" ] && [ "$(snap "$rec11")" = "$(snap "$ref")" ] && logs '(unload-failed)'; then ok "A3 unload failure places nothing, no marker, record intact"; else no "A3 live: $(find "$live11" -type f) marker: $(ls "$st") log: $(cat "$clog")"; fi
    rm -rf "$ref"

    # A6 no record: marked, nothing placed, no cmd
    rm -rf "$root/ce/11" "$rec11" "$st"; mkdir -p "$st"
    app 11
    if [ -f "$st/.shortcutsapplied.11" ] && [ ! -e "$live11" ] && [ "$(ncalls cmd)" = 0 ] && logs '(none)'; then ok "A6 no record -> marked, nothing placed"; else no "A6 log: $(cat "$clog")"; fi
    # A7 no xml2abx
    rm -rf "$st"; mkdir -p "$st"; mkrec "$rec11" com.x.browser
    app 11 NOTOOL=1
    if [ ! -e "$live11" ] && [ ! -e "$st/.shortcutsapplied.11" ] && [ "$(ncalls cmd)" = 0 ] && logs '(notool)'; then ok "A7 no xml2abx -> nothing placed, no unload, no marker"; else no "A7 log: $(cat "$clog")"; fi
    # A8 an xml2abx failure
    app 11 XABXRC=1
    if [ ! -e "$live11" ] && [ ! -e "$st/.shortcutsapplied.11" ] && [ "$(ncalls cmd)" = 0 ] && [ ! -e "$root/ce/11/.nowhere-shortcuts-stage" ] && logs '(stagefail)'; then ok "A8 xml2abx failure -> nothing placed, no unload, no marker"; else no "A8 log: $(cat "$clog")"; fi

    # A11-A13 a failed chown, chmod or restorecon is a placement failure: no marker, no success line
    local e id
    for e in CHOWNRC=1:A11:chown CHMODRC=f:A12:chmod-of-a-file CHMODRC=d:A12:chmod-of-a-dir RCONRC=1:A13:restorecon; do
      id=${e#*:}; id=${id%%:*}
      rm -rf "$root/ce/11" "$st"; mkdir -p "$st"; mkrec "$rec11" com.x.browser
      app 11 "${e%%:*}"
      if [ ! -e "$st/.shortcutsapplied.11" ] && logs '(placefail)' && ! logs 'placed for user'; then ok "$id a failed ${e##*:} -> placefail, no marker, no success line"; else no "$id ${e##*:} failure: marker $(ls "$st"), log: $(cat "$clog")"; fi
      if [ -d "$rec11/packages" ] && [ -f "$rec11/packages/com.x.browser.xml" ]; then ok "$id the record survives a failed ${e##*:}"; else no "$id record lost"; fi
      if ! grep -qF 'com.x.' "$clog"; then ok "L2 a failed ${e##*:} logs no package"; else no "L2 ${e##*:} log: $(cat "$clog")"; fi
    done
    # L2 a failed bitmap copy logs no package, at capture and at apply
    reset; mark 10
    cap CPFAIL=1
    if logs '(writefail)' && ! grep -qF 'com.x.' "$clog"; then ok "L2 a failed capture copy logs no package"; else no "L2 capture log: $(cat "$clog")"; fi
    rm -rf "$root/ce/11" "$st"; mkdir -p "$st"; mkrec "$rec11" com.x.browser; pkgs com.x.browser
    app 11 CPFAIL=1
    if logs '(stagefail)' && ! grep -qF 'com.x.' "$clog"; then ok "L2 a failed apply copy logs no package"; else no "L2 apply log: $(cat "$clog")"; fi

    # L1 no log line, in any case above, names a package, a shortcut id, a URL or a bitmap
    if [ -s "$all" ] && ! grep -qF -e 'com.x.' -e 's10' -e 'bank.example' -e '.png' -e '../x' "$all"; then ok "L1 no log line names a package, id, URL or bitmap"; else no "L1 log: $(grep -F -e 'com.x.' -e 's10' -e 'bank.example' -e '.png' "$all")"; fi
  fi

  # pins: the three call sites, each exactly once, in order (order, not adjacency: sibling slices may merge a line between)
  local outarm grantarm inarm n a b c d
  outarm=$(awk '/^  out\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  grantarm=$(awk '/^  grant\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  inarm=$(awk '/^  in\)$/{f=1;print;next} f&&/^  [a-z-]+\)$/{exit} f{print}' "$sut")
  n=$(printf '%s\n' "$outarm" | grep -c '^    shortcut_seal_capture "\$USERDIR" "\$uid"')
  a=$(printf '%s\n' "$outarm" | grep -n '^    a11y_seal_capture "\$USERDIR" "\$uid"' | head -n 1 | cut -d: -f1)
  b=$(printf '%s\n' "$outarm" | grep -n '^    shortcut_seal_capture "\$USERDIR" "\$uid"' | head -n 1 | cut -d: -f1)
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ]; then ok "P1 out calls shortcut_seal_capture once, after a11y_seal_capture"; else no "P1 out call missing, repeated or misplaced ($n)"; fi
  n=$(printf '%s\n' "$grantarm" | grep -c '^    shortcut_apply "\$uid"')
  a=$(printf '%s\n' "$grantarm" | grep -n '^    a11y_apply "\$uid"' | head -n 1 | cut -d: -f1)
  b=$(printf '%s\n' "$grantarm" | grep -n '^    shortcut_apply "\$uid"' | head -n 1 | cut -d: -f1)
  c=$(printf '%s\n' "$grantarm" | grep -n 'keystore_register_all' | head -n 1 | cut -d: -f1)
  d=$(printf '%s\n' "$grantarm" | grep -n '^    echo "OK" > "\$RES"' | head -n 1 | cut -d: -f1)
  if [ "$n" = 1 ] && [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$b" -gt "$a" ] && [ "$b" -lt "$c" ] && [ "$b" -lt "$d" ]; then ok "P2 grant calls shortcut_apply once, after a11y_apply, before the keystore sweep and the OK reply"; else no "P2 grant call missing, repeated or misplaced ($n)"; fi
  n=$(printf '%s\n' "$inarm" | grep -c '^    rm -f "\$STATE/.shortcutsapplied.\$uid" 2>/dev/null')
  if [ "$n" = 1 ]; then ok "P3 in clears .shortcutsapplied for its uid"; else no "P3 in's marker clear missing or repeated ($n)"; fi

  rm -rf "$root" "$st" "$fx" "$lib" "$clog" "$all" "$calls" "$ref"
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

echo; echo "== mutations (each MUST be convicted under every shell, by the assertion its label names) =="
MRC=0
# A mutant that did not apply is not evidence: it must exist, be non-empty and differ from the source.
apply_mut() {  # $1 dest, $2 sed expr
  sed "$2" "$SUT" > "$1" 2>/dev/null || return 1
  [ -s "$1" ] || return 1
  ! cmp -s "$1" "$SUT"
}
# mutant <label> <assertion id> <sed>: convicted only when the suite fails AND the named assertion is among its failures
mutant() {
  local m sh out; m=$(mktemp -p "$W")
  if ! apply_mut "$m" "$3"; then
    printf '  ⚠ NOT APPLIED  %s -- sed failed or changed nothing; NOT a conviction\n' "$1"; MRC=1; rm -f "$m"; return
  fi
  for sh in $SHELLS; do
    out=$(suite "$m" "$sh" quiet 2>&1)
    if [ $? = 0 ]; then printf '  ⚠ SURVIVED  %s [%s]\n' "$1" "$sh"; MRC=1
    elif [ -z "$(printf '%s\n' "$out" | grep -F "FAIL [$sh] $2 ")" ]; then printf '  ⚠ NOT BY %s  %s [%s]\n' "$2" "$1" "$sh"; MRC=1
    else printf '  convicted by %-4s %s [%s]\n' "$2" "$1" "$sh"; fi
  done
  rm -f "$m"
}
mutant "M1a any digit rewritten (every <u> in an attribute line)" K2 \
  '/^shortcut_xml() {$/,/^}$/s#      o = ""; p = "/data/system_ce/" from "/"#      o = ""; p = "/data/system_ce/" from "/"; gsub(from, to, s)#'
mutant "M1b any attribute equal to <u> (the -user name test dropped)" K2 \
  '/^shortcut_xml() {$/,/^}$/s#if (nm ~ /-user\$/ \&\& v == from)#if (v == from)#'
mutant "M1c the CE prefix matched without its trailing /" K2 \
  '/^shortcut_xml() {$/,/^}$/s#p = "/data/system_ce/" from "/"#p = "/data/system_ce/" from#'
mutant "M1d another user's block accepted as an owner" K4 \
  '/^shortcut_seal_capture() {$/,/^}$/s#\] && \[ "\$_u" = @U@ \] && \[#] \&\& [#'
mutant "M2 the capture's marker guard removed" C1 \
  '/^shortcut_seal_capture() {$/,/^}$/s#if \[ ! -e "\$STATE/.shortcutsapplied.\$_uid" \]; then#if false; then#'
mutant "M3 the .fp skip removed" C6 \
  '/^shortcut_seal_capture() {$/,/^}$/s#if \[ -f "\$_rec/.fp" \] && #if false \&\& #'
mutant "M4 carry-forward removed" C7 \
  '/^shortcut_seal_capture() {$/,/^}$/s#    _nw=\$((_nw+1)); printf .%s @U@\\n. "\$_p" >> "\$_w/carry"#    continue#'
mutant "M5 an absent owner placed" A1 \
  '/^shortcut_apply() {$/,/^}$/{/      \*) printf .%s\\n. "\$_p" >> "\$_stg\/.w\/wait"; continue ;;/d;}'
mutant "M6a unload skipped" A4 \
  '/^shortcut_apply() {$/,/^}$/s#if ! cmd shortcut unload-user --user "\$_uid" </dev/null >/dev/null 2>&1; then#if false; then#'
mutant "M6b unload rc ignored" A3 \
  '/^shortcut_apply() {$/,/^}$/s#if ! cmd shortcut unload-user --user "\$_uid" </dev/null >/dev/null 2>&1; then#if ! { cmd shortcut unload-user --user "$_uid" </dev/null >/dev/null 2>\&1 || :; }; then#'
mutant "M7 unload moved before staging" A4 \
  '/^shortcut_apply() {$/,/^}$/s#^  rm -rf "\$_stg" 2>/dev/null$#  cmd shortcut unload-user --user "$_uid" </dev/null >/dev/null 2>\&1; &#'
mutant "M8 marker written after an unload failure" A3 \
  '/^shortcut_apply() {$/,/^}$/s#^      echo "\[roamd\] shortcuts: unload-user failed#      ( : > "$STATE/.shortcutsapplied.$_uid" ); &#'
mutant "M9 a package name in the log" L1 \
  '/^shortcut_apply() {$/,/^}$/s#placed for user \$_uid: \$_np owner(s)#placed for user $_uid: $_np owner(s) $_p#'
mutant "M10 the out call removed" P1 \
  '/^    shortcut_seal_capture "\$USERDIR" "\$uid"/d'
mutant "M11 the grant call removed" P2 \
  '/^    shortcut_apply "\$uid"/d'
mutant "M12 the in clear removed" P3 \
  '/^    rm -f "\$STATE\/.shortcutsapplied.\$uid" 2>\/dev\/null/d'
mutant "M13 user.xml always placed" A2 \
  '/^shortcut_apply() {$/,/^}$/s#^    if \[ -f "\$_live/shortcuts.xml" \]; then$#    if false; then#'
mutant "M14 apply lists with -a" A1 \
  '/^shortcut_apply() {$/,/^}$/s#pm list packages --user#pm list packages -a --user#'
mutant "M15 .waiting ignored in the carry" C12 \
  '/^shortcut_seal_capture() {$/,/^}$/s#grep -qxF -- "\$_p" "\$_rec/.waiting" 2>/dev/null || continue#continue#'
mutant "M16 apply writes no .waiting" A10 \
  '/^shortcut_apply() {$/,/^}$/s#mv -f "\$_rec/.waiting.new" "\$_rec/.waiting" 2>/dev/null || _bad=1#:#'
mutant "M17 a placed owner kept in .waiting" A10 \
  '/^shortcut_apply() {$/,/^}$/s#    _np=\$((_np+1)); printf .%s @U@\\n. "\$_p" >> "\$_stg/.w/keys"#&; printf "%s\\n" "$_p" >> "$_stg/.w/wait"#'
mutant "M18 a failed chown ignored" A11 \
  '/^shortcut_apply() {$/,/^}$/s#chown -R system:system "\$_live" </dev/null >/dev/null 2>&1 || _bad=1#chown -R system:system "$_live" </dev/null >/dev/null 2>\&1#'
mutant "M19 a failed chmod ignored" A12 \
  '/^shortcut_apply() {$/,/^}$/s#find "\$_live" -type f -exec chmod 600 {} + </dev/null >/dev/null 2>&1 || _bad=1#find "$_live" -type f -exec chmod 600 {} + </dev/null >/dev/null 2>\&1#'
mutant "M19b a failed directory chmod ignored" A12 \
  '/^shortcut_apply() {$/,/^}$/s#find "\$_live" -type d -exec chmod 700 {} + </dev/null >/dev/null 2>&1 || _bad=1#find "$_live" -type d -exec chmod 700 {} + </dev/null >/dev/null 2>\&1#'
mutant "M20 a failed restorecon ignored" A13 \
  '/^shortcut_apply() {$/,/^}$/s#restorecon -R "\$_live" </dev/null >/dev/null 2>&1 || _bad=1#restorecon -R "$_live" </dev/null >/dev/null 2>\&1#'
mutant "M21 chown's error stream in the log" L2 \
  '/^shortcut_apply() {$/,/^}$/s#chown -R system:system "\$_live" </dev/null >/dev/null 2>&1#chown -R system:system "$_live" </dev/null 2>>"$LOG"#'
mutant "M22 the capture's bitmap copy error in the log" L2 \
  '/^shortcut_seal_capture() {$/,/^}$/s#cp -R "\$_live/bitmaps/\$_p" "\$_new/bitmaps/" 2>/dev/null#cp -R "$_live/bitmaps/$_p" "$_new/bitmaps/" 2>>"$LOG"#'
mutant "M23 the apply's bitmap copy error in the log" L2 \
  '/^shortcut_apply() {$/,/^}$/s#cp -R "\$_rec/bitmaps/\$_p" "\$_stg/bitmaps/" 2>/dev/null#cp -R "$_rec/bitmaps/$_p" "$_stg/bitmaps/" 2>>"$LOG"#'
echo; [ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ a mutation survived, did not apply, or was not convicted by its named assertion"
exit $MRC
