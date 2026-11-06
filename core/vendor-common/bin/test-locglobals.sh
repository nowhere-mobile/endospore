#!/usr/bin/env bash
# test-locglobals.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's SESSION-SCOPED LOCATION GLOBALS (NWP-20261016-45),
# run for real against a stubbed `settings`, rather than grepped.
#
# WHY THIS IS COMMITTED. GrapheneOS's network location (Settings.Global network_location) and geocoding
# (Settings.Global geocoder) are DEVICE settings. roamd now applies one profile's choice of them while that profile's
# session is in front and puts the baseline (both 0) back whenever it is not. A mistake in either direction is
# silent: a claim that maps "on" to the wrong value sends the phone's Wi-Fi and cell surroundings to Apple directly
# instead of through GrapheneOS's proxy; a release that ignores the owner record switches off the session now in
# front (the #123 reap of a superseded cold lock); a release or boot sweep that never runs leaves one profile's choice
# on for every profile after it. Nothing off-device executed any of this. What this pins:
#   - the CLAIM (op locapply): netloc=1 -> network_location=2 (GRAPHENEOS_APPLE_PROXY), geocoder=1 -> geocoder=2
#     (GRAPHENEOS server); a file with neither key (every profile sealed before this slice), a missing file and any
#     value but 1 -> 0; the chooser's parse rules (first line wins, blanks and CR trimmed, no prefix match); the
#     owner record written; a value set by hand corrected; the reply is OK APPLIED only when both read back;
#   - the RELEASE (op locrelease): the baseline written and the owner forgotten -- unless ANOTHER uid owns the
#     globals, which are then left exactly as they are; a failed write keeps the owner so the reap can retry;
#   - an OWNER WHOSE USER IS GONE (its /data/user/<n> answers "No such file": a sign-in the chooser abandoned and
#     removed) is no owner, for a release and for the boot sweep alike; a denied lookup is not proof, and keeps it;
#   - the REAP: cleanstorage's own release line, executed, is in the op, above the rest of its work;
#   - the BOOT SWEEP: its category, executed -- the baseline with no owner, nothing touched with one, a single
#     space-free token on every path, inside the op and before its result line;
#   - DIASPORE: with no GrapheneOS provider on the image, no `settings` call at all on any path;
#   - LOGS carry the uid and the two values only: the reason slot is reduced to lowercase letters, so a name cannot
#     reach roam.log through it;
#   - the provider path is the one literal the daemon and the chooser test too;
#   - an OWNER RECORD THAT IS NOT A UID (`12x`, `.`) is no owner, even where its lookup is denied or answers (G1-G2),
#     and a read-back that ends in CR still counts as the value written (A14).
#
# The block is extracted from nowhere_roamd.sh BY ANCHOR, never copied, and its two device roots are substituted
# (each substitution is checked); if an anchor moves, extraction fails loudly (exit 2) rather than a stale copy passing.
#
# EVERY SHELL (NWP-20261112-34). The device runs roamd under mksh (/system/bin/sh); this suite used to run the block
# with `eval` in bash only. The values whose handling differs between shells are exactly the ones this block guards:
# loc_owner's `*[!0-9]*` clear, loc_set's `tr -cd '0-9a-z'` read-backs and the op's `[ "$uid" -ge 10 ]` -- mksh reads
# a non-number in `-ge` as 0, silently, where bash and dash error. So each run (the op, the bootsweep category, the
# reap's release line) is written into a runner file -- the harness, the case's assignments, the extracted text --
# and run by "$sh", and the block is parse-checked by "$sh -n". The shells are bash, dash and mksh, each under its own
# name wherever found, then sh unless it is the same binary as one already listed (on Debian sh is dash, so it is
# skipped). Every case prints under each shell's tag, and a mutant is convicted only by a FAIL line under each one.
# Every temp lives under one root, removed on any exit.
#
#   bash test-locglobals.sh            # the behaviour cases, under every shell found
#   bash test-locglobals.sh --mutate   # ... plus broken copies that must each be CONVICTED under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
ROOT=$(cd "$HERE/../../.." && pwd)
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

# The shells: bash, dash and mksh under their own names; sh last, and skipped only when it is the same binary as one
# already listed, so a Debian host (sh -> dash) runs [dash], never [sh] in its place.
SHPATHS=(); SHTAGS=(); TAGS=""
for s in bash dash mksh sh; do
  p=$(command -v "$s" 2>/dev/null) || { echo "  skip  shell $s: not installed"; continue; }
  if [ "$s" = sh ]; then
    r=$(readlink -f "$p"); dup=""
    for q in "${SHPATHS[@]}"; do [ "$(readlink -f "$q")" = "$r" ] && dup=$q; done
    if [ -n "$dup" ]; then echo "  skip  shell sh: same binary as $(basename "$dup") ($r)"; continue; fi
  fi
  SHPATHS+=("$p"); SHTAGS+=("$s"); TAGS="$TAGS $s"
done
[ "${#SHPATHS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }

# mksh has print; the others get the same shim the other per-shell suites use.
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
# sq <value>: the value as one single-quoted shell word, for a runner file's assignments
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

BEGIN_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (begin) -------------------------------------------------------'
END_HDR='# ---- NWP-20261016-45: SESSION-SCOPED LOCATION GLOBALS (end) ---------------------------------------------------------'
BOOT_HDR='  # --- fix 11: locglobals (NWP-20261016-45) ---'
REAP_LINE='  loc_release "$uid" reap   # NWP-20261016-45: the reap'"'"'s backstop for the location globals; another owner is left alone'
APK_LINE='LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk  # GrapheneOS'"'"'s NetworkLocation (handheld_system.mk)'
ROOT_LINE='LOC_USER_ROOT=/data/user        # one CE directory per Android user: <n>/com.nowhere.chooser holds the prefs'
PREFS_PATH='"$LOC_USER_ROOT/$uid/com.nowhere.chooser/files/nowhere-prefs"'

# suite <roamd.sh> <shell path> <shell tag> [quiet] -> 0 all ok, 1 an assertion failed (the only verdict that convicts
# a mutant), 2 the harness could not run (an anchor moved, a substitution did not apply, the block does not parse
# under that shell). quiet hides the ok lines and the summary; a FAIL line always prints, tagged with the shell.
suite() {
  local f="$1" shpath="$2" tag="$3" quiet="${4:-}" PASS=0 FAIL=0 BLK BOOT RUNBLK T out at v u pf
  ok() { PASS=$((PASS+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$tag" "$1"; }
  no() { FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$tag" "$1"; }

  # --- extraction -------------------------------------------------------------------------------------------
  [ "$(grep -cxF "$BEGIN_HDR" "$f")" = 1 ] && [ "$(grep -cxF "$END_HDR" "$f")" = 1 ] \
    || { echo "EXTRACTION FAILED: the block's begin/end anchors in $f" >&2; return 2; }
  BLK=$(awk -v b="$BEGIN_HDR" -v e="$END_HDR" '$0 == b {on = 1} on {print} $0 == e {exit}' "$f")
  case "$BLK" in *'loc_claim()'*'loc_release()'*'loc_boot()'*'"$op" = "locapply"'*) ;;
    *) echo "EXTRACTION FAILED: the functions or the op in the block" >&2; return 2 ;; esac
  [ "$(grep -cxF "$APK_LINE" <<< "$BLK")" = 1 ] || { echo "EXTRACTION FAILED: the provider path line" >&2; return 2; }
  [ "$(grep -cxF "$ROOT_LINE" <<< "$BLK")" = 1 ] || { echo "EXTRACTION FAILED: the user-root line" >&2; return 2; }
  [ "$(grep -cF "$PREFS_PATH" <<< "$BLK")" = 1 ] || { echo "EXTRACTION FAILED: the prefs path" >&2; return 2; }
  RUNBLK=$(sed -e 's@^LOC_PROVIDER_APK=/system/priv-app/NetworkLocation/NetworkLocation.apk @LOC_PROVIDER_APK="$T/provider.apk" @' \
               -e 's@^LOC_USER_ROOT=/data/user @LOC_USER_ROOT="$T/user" @' <<< "$BLK")
  if grep -v '^[[:space:]]*#' <<< "$RUNBLK" | grep -qE '/system/|/data/'; then
    echo "EXTRACTION FAILED: a device path is left in the live code after substitution" >&2; return 2
  fi
  BOOT=$(awk -v h="$BOOT_HDR" '$0 == h {on = 1; print; next}
    on && (index($0, "  # ---") == 1 || index($0, "  # Report what was actually removed") == 1) {exit} on {print}' "$f")
  case "$BOOT" in *loc_boot*'locglobals=$LOC_BOOT'*) ;; *) echo "EXTRACTION FAILED: the bootsweep category" >&2; return 2 ;; esac

  # --- harness ----------------------------------------------------------------------------------------------
  # A device: $T/g.<key> is the global table, $T/provider.apk the provider, $T/user/<uid>/.../nowhere-prefs a CE.
  # settings answers only the two calls roamd makes; anything else lands in $T/unexpected. deny-put = the write
  # fails; stuck-put = the write says yes and changes nothing (a readback that disagrees); blind-get = no output.
  # crlf-get = each read-back ends in CR LF, as a `settings get` over a tty line can.
  # $T/user/<n> is user <n>'s CE directory (12 and 13 exist); deny-ls = looking one up is denied rather than answered.
  mkdev() {
    T=$(mktemp -d -p "$W") || exit 2; mkdir -p "$T/state" "$T/user/12/com.nowhere.chooser/files" "$T/user/13/com.nowhere.chooser/files"
    : > "$T/provider.apk"; : > "$T/calls"
  }
  prefs() { printf '%b' "$2" > "$T/user/$1/com.nowhere.chooser/files/nowhere-prefs"; }
  setg() { printf '%s' "$2" > "$T/g.$1"; }
  getg() { if [ -f "$T/g.$1" ]; then cat "$T/g.$1"; else echo unset; fi; }
  owner() { if [ -f "$T/state/.locglobals" ]; then tr -d '\n' < "$T/state/.locglobals"; else echo none; fi; }
  ncalls() { grep -c . "$T/calls" 2>/dev/null || true; }
  harness='
    settings() {
      echo "settings $*" >> "$T/calls"
      case "$1 $2" in
        "put global") [ -f "$T/deny-put" ] && return 1; [ -f "$T/stuck-put" ] && return 0
                      printf "%s" "$4" > "$T/g.$3"; return 0 ;;
        "get global") [ -f "$T/blind-get" ] && return 0
                      if [ -f "$T/crlf-get" ]; then
                        if [ -f "$T/g.$3" ]; then cat "$T/g.$3"; else printf null; fi; printf "\r\n"; return 0
                      fi
                      if [ -f "$T/g.$3" ]; then cat "$T/g.$3"; echo; else echo null; fi; return 0 ;;
      esac
      echo "settings $*" >> "$T/unexpected"; return 1
    }
    ls() {
      if [ -f "$T/deny-ls" ]; then echo "ls: ${2:-$1}: Permission denied" >&2; return 1; fi
      command ls "$@"
    }
    STATE="$T/state"; LOG="$T/log"; RES="$T/res"'
  # The harness, the block and the reap line, parsed by the shell under test, from a file, before any case runs. The
  # bootsweep category is not in it: M17 moves that category, and a misplaced one must reach D1 (and, if its
  # extraction no longer parses, every boot case through clean's syntax-error check), not end the suite at rc 2.
  pf=$(mktemp -p "$W") || return 2
  printf "T=/x\nop=x uid=12 name=x pass=''\n%s\n%s\n%s\n" "$harness" "$RUNBLK" "$REAP_LINE" > "$pf"
  "$shpath" -n "$pf" 2>/dev/null || { rm -f "$pf"; echo "EXTRACTION FAILED: the block does not parse under $tag" >&2; return 2; }
  rm -f "$pf"
  # runner <assignments> <body>: one file, run by the shell under test as roamd's worker runs the op -- the case dir,
  # set -u (as the suite's own subshells had), the print shim where the shell has no print, the harness, the case's
  # assignments, then the extracted text.
  runner() {
    { printf 'T=%s\nset -u\n' "$(sq "$T")"
      [ "$tag" = mksh ] || printf '%s\n' "$PRINT_SHIM"
      printf '%s\n%s\n%s\n' "$harness" "$1" "$2"
    } > "$T/run.sh"
    "$shpath" "$T/run.sh" >/dev/null 2>>"$T/stderr"
  }
  # op <op> <uid> <reason>: run the block as the worker would for that request.
  op() {
    runner "op=$(sq "$1") uid=$(sq "$2") name=$(sq "$3") pass=''" "$RUNBLK
echo \"the op block fell through\" >> \"\$T/unexpected\""
    cat "$T/res" 2>/dev/null; rm -f "$T/res"
  }
  # boot: the bootsweep category, with the block's functions defined -> prints _swept
  boot() {
    runner "op=bootsweep uid='' name='' pass='' _swept=''" "$RUNBLK
$BOOT
printf '%s' \"\$_swept\" > \"\$T/swept\""
    cat "$T/swept" 2>/dev/null
  }
  # reap <uid>: cleanstorage's release line, extracted from the op, with the block's functions defined
  reap() {
    runner "op=cleanstorage uid=$(sq "$1") name=x pass=''" "$RUNBLK
$REAP_LINE"
  }
  clean() {  # no harness error may hide behind a passing case (bash's, dash's and mksh's spellings of each)
    if [ -s "$T/stderr" ] && grep -qE 'command not found|: not found|inaccessible or not found|unbound variable|parameter not set|[Ss]yntax error|[Bb]ad substitution' "$T/stderr"; then
      no "$1: the harness reported $(head -n 1 "$T/stderr")"
    fi
    if [ -s "$T/unexpected" ]; then no "$1: unexpected calls: $(tr '\n' ';' < "$T/unexpected")"; fi
    rm -rf "$T"
  }

  # --- the CLAIM ----------------------------------------------------------------------------------------------
  mkdev; prefs 12 'tz=\nlocale=en-US\nnetloc=1\n'
  out=$(op locapply 12 signin)
  [ "$out" = "OK APPLIED network_location=2 geocoder=0" ] && ok "A1 netloc=1 -> OK APPLIED network_location=2 geocoder=0" \
    || no "A1 reply '$out'"
  [ "$(getg network_location)/$(getg geocoder)" = "2/0" ] && ok "A1 network_location=2 (GrapheneOS's Apple proxy), geocoder=0" \
    || no "A1 table $(getg network_location)/$(getg geocoder), want 2/0"
  [ "$(owner)" = 12 ] && ok "A1 the claim records user 12 as the owner" || no "A1 owner '$(owner)', want 12"
  grep -q '^\[roamd\] locglobals user 12 (signin): network_location=2 geocoder=0 APPLIED ' "$T/log" \
    && ok "A1 the log line names the uid and both values" || no "A1 log: $(cat "$T/log" 2>/dev/null)"
  clean A1

  mkdev; prefs 12 'tz=Europe/Paris\nlocale=fr-FR\nidle=15\nnetloc=1\ngeocoder=1\n'
  out=$(op locapply 12 live)
  [ "$out" = "OK APPLIED network_location=2 geocoder=2" ] && [ "$(getg network_location)/$(getg geocoder)" = "2/2" ] \
    && ok "A2 both on -> 2/2 (geocoder=2 is GrapheneOS's server, not OpenStreetMap's 1)" \
    || no "A2 reply '$out', table $(getg network_location)/$(getg geocoder)"
  clean A2

  mkdev; prefs 12 'tz=\nlocale=en-US\nidle=15\nwipe=12\nholdlock=0\n'; setg network_location 2; setg geocoder 2
  out=$(op locapply 12 signin)
  [ "$out" = "OK APPLIED network_location=0 geocoder=0" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] \
    && ok "A3 a file written before this slice (neither key) is Off -- and corrects a value left set by hand" \
    || no "A3 reply '$out', table $(getg network_location)/$(getg geocoder)"
  [ "$(owner)" = 12 ] && ok "A3 an Off claim still records its owner" || no "A3 owner '$(owner)'"
  clean A3

  mkdev; rm -f "$T/user/12/com.nowhere.chooser/files/nowhere-prefs"
  out=$(op locapply 12 offline)
  [ "$out" = "OK APPLIED network_location=0 geocoder=0" ] && ok "A4 no prefs file at all (an offline sign-in) -> the baseline" \
    || no "A4 reply '$out'"
  clean A4

  for v in 0 2 3 true yes on '' '1x' '11'; do
    mkdev; prefs 12 "netloc=$v\ngeocoder=$v\n"
    out=$(op locapply 12 live)
    [ "$out" = "OK APPLIED network_location=0 geocoder=0" ] && ok "A5 a stored value of '$v' is Off" || no "A5 '$v' -> '$out'"
    clean "A5 $v"
  done

  mkdev; prefs 12 'netloc= 1 \r\ngeocoder=1\r\n'
  out=$(op locapply 12 live)
  [ "$out" = "OK APPLIED network_location=2 geocoder=2" ] && ok "A6 blanks and a CRLF are trimmed, as the chooser trims them" \
    || no "A6 reply '$out'"
  clean A6

  mkdev; prefs 12 'netloc=0\nnetloc=1\ngeocoder=1'
  out=$(op locapply 12 live)
  [ "$out" = "OK APPLIED network_location=0 geocoder=2" ] \
    && ok "A7 the FIRST netloc line wins, and a last line with no newline still counts" || no "A7 reply '$out'"
  clean A7

  mkdev; prefs 12 'netlocx=1\nmygeocoder=1\nNETLOC=1\n'
  out=$(op locapply 12 live)
  [ "$out" = "OK APPLIED network_location=0 geocoder=0" ] && ok "A8 no prefix, suffix or case match" || no "A8 reply '$out'"
  clean A8

  mkdev; prefs 12 'netloc=1\n'; : > "$T/deny-put"
  out=$(op locapply 12 live)
  case "$out" in "ERR-LOC network_location="*",geocoder="*) ok "A9 a failed write answers ERR-LOC with what the keys read" ;;
    *) no "A9 reply '$out'" ;; esac
  grep -q 'NOT APPLIED' "$T/log" && ok "A9 ...and the log says NOT APPLIED" || no "A9 log: $(cat "$T/log" 2>/dev/null)"
  clean A9
  mkdev; prefs 12 'netloc=1\n'; : > "$T/stuck-put"
  out=$(op locapply 12 live)
  [ "$out" = "ERR-LOC network_location=null,geocoder=null" ] \
    && ok "A10 a write that exits 0 but does not read back is not APPLIED" || no "A10 reply '$out'"
  clean A10
  mkdev; prefs 12 'netloc=1\n'; : > "$T/blind-get"
  out=$(op locapply 12 live)
  [ "$out" = "ERR-LOC network_location=?,geocoder=?" ] \
    && ok "A10b a readback that yields nothing is not APPLIED either, and says ?" || no "A10b reply '$out'"
  clean A10b

  mkdev; prefs 12 'netloc=1\ngeocoder=1\n'; rm -f "$T/provider.apk"; setg network_location 7
  out=$(op locapply 12 signin)
  [ "$out" = "OK UNAVAILABLE" ] && [ "$(ncalls)" = 0 ] && [ "$(getg network_location)" = 7 ] && [ "$(owner)" = none ] \
    && ok "A11 no GrapheneOS provider (Diaspore): OK UNAVAILABLE, no settings call, no owner" \
    || no "A11 reply '$out', $(ncalls) call(s), table $(getg network_location), owner $(owner)"
  clean A11

  for u in abc 5 ''; do
    mkdev; out=$(op locapply "$u" live)
    [ "$out" = "ERR-UID" ] && [ "$(ncalls)" = 0 ] && ok "A12 uid '$u' -> ERR-UID, nothing written" || no "A12 uid '$u' -> '$out'"
    clean "A12 $u"
  done

  mkdev; prefs 12 'netloc=1\n'
  out=$(op locapply 12 'zq Alice Smith')
  if grep -q '(other)' "$T/log" && ! grep -q 'zq\|Alice\|Smith' "$T/log"; then
    ok "A13 a reason that is not lowercase letters is logged as (other); no name reaches the log"
  else no "A13 log: $(cat "$T/log" 2>/dev/null)"; fi
  clean A13

  mkdev; prefs 12 'netloc=1\n'; : > "$T/crlf-get"
  out=$(op locapply 12 live)
  [ "$out" = "OK APPLIED network_location=2 geocoder=0" ] \
    && ok "A14 a read-back that ends in CR LF is still the value written: only digits and letters are compared" \
    || no "A14 reply '$out'"
  clean A14

  # --- the RELEASE ---------------------------------------------------------------------------------------------
  mkdev; setg network_location 2; setg geocoder 2; echo 12 > "$T/state/.locglobals"
  out=$(op locrelease 12 signout)
  [ "$out" = "OK BASELINE" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] && [ "$(owner)" = none ] \
    && ok "B1 the owner's release writes 0/0 and forgets the owner" \
    || no "B1 reply '$out', table $(getg network_location)/$(getg geocoder), owner $(owner)"
  grep -q '^\[roamd\] locglobals user 12 (signout): baseline network_location=0 geocoder=0 RESTORED ' "$T/log" \
    && ok "B1 the log line says RESTORED with both values" || no "B1 log: $(cat "$T/log" 2>/dev/null)"
  clean B1

  mkdev; setg network_location 2; setg geocoder 2; echo 13 > "$T/state/.locglobals"
  out=$(op locrelease 12 reap)
  [ "$out" = "OK KEPT" ] && [ "$(getg network_location)/$(getg geocoder)" = "2/2" ] && [ "$(owner)" = 13 ] \
    && ok "B2 another session's globals are left exactly as they are (the #123 superseded reap)" \
    || no "B2 reply '$out', table $(getg network_location)/$(getg geocoder), owner $(owner)"
  grep -q "settings put" "$T/calls" && no "B2 a release for a non-owner WROTE a setting" || ok "B2 ...and nothing was written"
  clean B2

  mkdev; setg geocoder 2
  out=$(op locrelease 12 coldlock)
  [ "$out" = "OK BASELINE" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] \
    && ok "B3 with no owner on record the baseline is written anyway (corrects a hand-set geocoder=2)" \
    || no "B3 reply '$out', table $(getg network_location)/$(getg geocoder)"
  clean B3

  mkdev; setg network_location 2; echo 12 > "$T/state/.locglobals"; : > "$T/deny-put"
  out=$(op locrelease 12 signout)
  case "$out" in ERR-LOC*) ok "B4 a failed baseline answers ERR-LOC" ;; *) no "B4 reply '$out'" ;; esac
  [ "$(owner)" = 12 ] && ok "B4 ...and keeps the owner, so the reap's release tries again" || no "B4 owner '$(owner)'"
  clean B4

  mkdev; rm -f "$T/provider.apk"; setg network_location 2
  out=$(op locrelease 12 signout)
  [ "$out" = "OK UNAVAILABLE" ] && [ "$(ncalls)" = 0 ] && ok "B5 Diaspore: no settings call on release" \
    || no "B5 reply '$out', $(ncalls) call(s)"
  clean B5

  # --- an owner whose user is gone --------------------------------------------------------------------------------
  mkdev; setg network_location 2; setg geocoder 2; echo 14 > "$T/state/.locglobals"
  out=$(op locrelease 12 reap)
  [ "$out" = "OK BASELINE" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] && [ "$(owner)" = none ] \
    && ok "F1 an owner whose user no longer exists is no owner: a release writes the baseline and forgets it" \
    || no "F1 reply '$out', table $(getg network_location)/$(getg geocoder), owner $(owner)"
  grep -q '^\[roamd\] locglobals: the owner, user 14, no longer exists -- not counted as an owner ' "$T/log" \
    && ok "F1 ...and the log says why, by uid" || no "F1 log: $(cat "$T/log" 2>/dev/null)"
  clean F1
  mkdev; setg network_location 2; setg geocoder 2; echo 14 > "$T/state/.locglobals"
  out=$(boot)
  [ "$out" = " locglobals=baseline" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] \
    && ok "F2 the boot sweep does not keep a removed session's choice -> locglobals=baseline" \
    || no "F2 _swept '$out', table $(getg network_location)/$(getg geocoder)"
  clean F2
  mkdev; setg network_location 2; echo 14 > "$T/state/.locglobals"; : > "$T/deny-ls"
  out=$(op locrelease 12 reap)
  [ "$out" = "OK KEPT" ] && [ "$(getg network_location)" = 2 ] && [ "$(owner)" = 14 ] \
    && ok "F3 a denied lookup is not proof the owner is gone: its globals are kept" \
    || no "F3 reply '$out', table $(getg network_location), owner $(owner)"
  out=$(boot)
  [ "$out" = " locglobals=KEPT:user14" ] && ok "F3 ...by the boot sweep too" || no "F3 _swept '$out'"
  clean F3

  # --- an owner record that is not a uid -------------------------------------------------------------------------
  mkdev; setg network_location 2; setg geocoder 2; echo 12x > "$T/state/.locglobals"; : > "$T/deny-ls"
  out=$(op locrelease 12 reap)
  [ "$out" = "OK BASELINE" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] && [ "$(owner)" = none ] \
    && ok "G1 an owner record that is not a number is no owner, even where its lookup is denied: the baseline goes back" \
    || no "G1 reply '$out', table $(getg network_location)/$(getg geocoder), owner $(owner)"
  clean G1
  mkdev; setg network_location 2; setg geocoder 2; echo 12x > "$T/state/.locglobals"; : > "$T/deny-ls"
  out=$(boot)
  [ "$out" = " locglobals=baseline" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] \
    && ok "G1 ...and the boot sweep writes the baseline over it -> locglobals=baseline" \
    || no "G1 _swept '$out', table $(getg network_location)/$(getg geocoder)"
  clean G1b
  mkdev; setg network_location 2; setg geocoder 2; echo . > "$T/state/.locglobals"
  out=$(op locrelease 12 reap)
  [ "$out" = "OK BASELINE" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] && [ "$(owner)" = none ] \
    && ok "G2 an owner record of '.' (whose lookup answers: the user root itself) is no owner either" \
    || no "G2 reply '$out', table $(getg network_location)/$(getg geocoder), owner $(owner)"
  clean G2

  # --- the REAP -------------------------------------------------------------------------------------------------
  at=$(awk -v l="$REAP_LINE" '/^if \[ "\$op" = "cleanstorage" \]; then$/ {op = NR} $0 == l {ln = NR}
    op && !mm && /^  stop_mediad / {mm = NR} END {print op " " ln " " mm}' "$f")
  set -- $at
  if [ "$#" = 3 ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ] && [ "$(grep -cxF "$REAP_LINE" "$f")" = 1 ]; then
    ok "C1 cleanstorage releases the location globals, once, before any of its other work"
  else no "C1 the reap's release line is missing, duplicated or misplaced (op/line/stop_mediad: $at)"; fi
  mkdev; setg network_location 2; setg geocoder 2; echo 12 > "$T/state/.locglobals"
  reap 12
  [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] && [ "$(owner)" = none ] \
    && ok "C2 the reap of the owner restores the baseline" || no "C2 table $(getg network_location)/$(getg geocoder)"
  clean C2
  mkdev; setg network_location 2; echo 13 > "$T/state/.locglobals"
  reap 12
  [ "$(getg network_location)" = 2 ] && [ "$(owner)" = 13 ] && ok "C3 the reap of another uid leaves the owner's globals" \
    || no "C3 table $(getg network_location), owner $(owner)"
  clean C3

  # --- the BOOT SWEEP ---------------------------------------------------------------------------------------------
  at=$(awk -v h="$BOOT_HDR" '/^if \[ "\$op" = "bootsweep" \]; then$/ {op = NR} $0 == h {blk = NR}
    /echo "\[roamd\] bootsweep result:\$_swept/ {res = NR} END {print (op && blk > op && res > blk) ? "in" : "out"}' "$f")
  [ "$at" = in ] && [ "$(grep -cxF "$BOOT_HDR" "$f")" = 1 ] \
    && ok "D1 the category sits inside the bootsweep op, once, before its result line" || no "D1 the category is misplaced"
  mkdev; setg network_location 2; setg geocoder 2
  out=$(boot)
  [ "$out" = " locglobals=baseline" ] && [ "$(getg network_location)/$(getg geocoder)" = "0/0" ] \
    && ok "D2 no owner at boot: the baseline goes back -> locglobals=baseline" \
    || no "D2 _swept '$out', table $(getg network_location)/$(getg geocoder)"
  clean D2
  mkdev; setg network_location 2; echo 12 > "$T/state/.locglobals"
  out=$(boot)
  [ "$out" = " locglobals=KEPT:user12" ] && [ "$(getg network_location)" = 2 ] && [ "$(ncalls)" = 0 ] \
    && ok "D3 a session that signed in before the sweep keeps its choice -> locglobals=KEPT:user12" \
    || no "D3 _swept '$out', table $(getg network_location), $(ncalls) call(s)"
  clean D3
  mkdev; rm -f "$T/provider.apk"
  out=$(boot)
  [ "$out" = " locglobals=UNAVAILABLE" ] && [ "$(ncalls)" = 0 ] && ok "D4 Diaspore -> locglobals=UNAVAILABLE, no settings call" \
    || no "D4 _swept '$out', $(ncalls) call(s)"
  clean D4
  mkdev; setg network_location 2; : > "$T/deny-put"
  out=$(boot)
  case "$out" in " locglobals=FAILED("*")") ;; *) out="BAD:$out" ;; esac
  [ "$(wc -w <<< "$out")" = 1 ] && [ "${out#BAD:}" = "$out" ] \
    && ok "D5 a failed write reports one token, locglobals=FAILED(...)" || no "D5 _swept '$out'"
  clean D5

  # --- placement + the shared literal -----------------------------------------------------------------------------
  at=$(awk -v b="$BEGIN_HDR" '$0 == b {blk = NR}
    /^\[ -n "\$op" \] && \[ -n "\$name" \] && \[ -n "\$uid" \] \|\|/ && !arg {arg = NR}
    /^if \[ "\$op" = "cleanstorage" \]; then$/ {cs = NR} /^if \[ "\$op" = "bootsweep" \]; then$/ {bs = NR}
    END {print (blk && arg && cs && bs && blk < cs && blk < bs && blk < arg) ? "ok" : "bad " blk " " arg " " cs " " bs}' "$f")
  [ "$at" = ok ] && ok "E1 the block is defined above cleanstorage and bootsweep (no forward reference) and the global arg check" \
    || no "E1 placement: $at"
  local lit=/system/priv-app/NetworkLocation/NetworkLocation.apk
  if grep -qF "const locProviderAPK = \"$lit\"" "$ROOT/core/agent/locglobals.go" 2>/dev/null \
     && grep -qF "LOC_PROVIDER_APK = \"$lit\"" "$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java" 2>/dev/null \
     && grep -qF "LOC_PROVIDER_APK=$lit " "$f"; then
    ok "E2 roamd, the daemon and the chooser test the same provider file"
  else no "E2 the provider path differs between roamd, core/agent/locglobals.go and ProfileActivity.java"; fi

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" = 0 ] && return 0 || return 1
}

echo "== $SUT (shells:$TAGS)"
rc=0
for i in "${!SHPATHS[@]}"; do
  suite "$SUT" "${SHPATHS[$i]}" "${SHTAGS[$i]}"; r=$?
  [ "$r" = 0 ] || { [ "$rc" = 2 ] || rc=$r; }
done
if [ "$rc" != 0 ]; then echo "FAILED (rc=$rc)"; exit "$rc"; fi
[ "$MUTATE" = yes ] || exit 0

echo
echo "== mutations (each must be CONVICTED by a FAIL line under each shell:$TAGS; one that does not apply or breaks the harness is a failure)"
command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
fails=0
mut() {  # mut <label> <perl -0pe program>
  local m rc i tag out first l bad=0
  m=$(mktemp -p "$W") || exit 2
  if ! perl -0pe "$2" "$SUT" > "$m"; then echo "  ERROR     $1 -- perl failed"; rm -f "$m"; fails=$((fails+1)); return; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -f "$m"; fails=$((fails+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -f "$m"; fails=$((fails+1)); return; fi
  for i in "${!SHPATHS[@]}"; do
    tag=${SHTAGS[$i]}
    out=$(suite "$m" "${SHPATHS[$i]}" "$tag" quiet 2>&1); rc=$?
    case "$rc" in
      0) echo "  SURVIVED  $1 [$tag]"; bad=1; continue ;;
      1) ;;
      *) echo "  BROKEN    $1 [$tag] -- the harness could not run it (rc=$rc), which is not a conviction"; bad=1; continue ;;
    esac
    first=""
    while IFS= read -r l; do case "$l" in "  FAIL  [$tag] "*) first=$l; break ;; esac; done <<< "$out"
    if [ -n "$first" ]; then
      echo "  convicted $1 [$tag]"; echo "      $first"
    else
      echo "  UNPROVEN  $1 [$tag] -- rc 1 with no FAIL line under its own tag"; bad=1
    fi
  done
  rm -f "$m"
  [ "$bad" = 0 ] || fails=$((fails+1))
}
mut "M1 on maps network_location to 1 (Apple directly, not the proxy)" 's/^LOC_NET_ON=2 /LOC_NET_ON=1 /m'
mut "M2 on maps geocoder to 1 (OpenStreetMap, not GrapheneOS)"        's/^LOC_GEO_ON=2 /LOC_GEO_ON=1 /m'
mut "M3 any non-empty stored value reads On"                         's/\[ "\$_v" = 1 \]; return ;;/[ -n "\$_v" ]; return ;;/'
mut "M4 blanks and CR are no longer stripped"                        's/ \| tr -d '"'"' \\t\\r'"'"'\)/)/'
mut "M5 a key matches anywhere in the line, not only at its start"  's/      "\$2="\*\) _v=/      *"\$2="*) _v=/'
mut "M6 the claim writes no owner record"                            's/if ! \{ echo "\$_u" > "\$LOC_OWNER"; \} 2>\/dev\/null; then/if false; then/'
mut "M7 a release ignores the owner record"                          's/if \[ -n "\$_o" \] && \[ "\$_o" != "\$_u" \]; then/if false; then/'
mut "M8 a release forgets the owner even when the reset failed"      's/(    # The owner record stays, so the reap.s release of this uid tries again[^\n]*\n)/$1    rm -f "\$LOC_OWNER"\n/'
mut "M9 the readback is ignored"                                     's/\[ "\$_rn" = 0 \] && \[ "\$_rg" = 0 \] && \[ "\$_n" = "\$1" \] && \[ "\$_g" = "\$2" \]/[ "\$_rn" = 0 ] \&\& [ "\$_rg" = 0 ]/'
mut "M10 the provider gate always passes"                            's/^loc_supported\(\) \{ \[ -f "\$LOC_PROVIDER_APK" \]; \}/loc_supported() { true; }/m'
mut "M11 the op answers a bare OK"                                   's/  echo "\$LOC_VERDICT" > "\$RES"; chmod 600 "\$RES"; exit 0/  echo "OK" > "\$RES"; chmod 600 "\$RES"; exit 0/'
mut "M12 the reason slot is logged as given"                         's/loc_why\(\) \{ case "\$1" in .*?esac; \}/loc_why() { echo "\$1"; }/'
mut "M13 the reap no longer releases"                                's/^  loc_release "\$uid" reap   # NWP-20261016-45[^\n]*\n//m'
mut "M14 the boot sweep ignores the owner"                           's/  if \[ -n "\$_o" \]; then LOC_BOOT="KEPT:user\$_o"; return 0; fi\n//'
mut "M15 the boot sweep reports nothing on the Diaspore path"        's/if ! loc_supported; then LOC_BOOT=UNAVAILABLE; return 0; fi/if ! loc_supported; then LOC_BOOT=""; return 0; fi/'
mut "M16 the baseline is 1, not 0"                                   's/^LOC_OFF=0 /LOC_OFF=1 /m'
mut "M17 the boot category runs after the result line"              's/(  # --- fix 11: locglobals \(NWP-20261016-45\) ---\n.*?  _swept="\$_swept locglobals=\$LOC_BOOT"\n)(.*?  echo "\[roamd\] bootsweep result:[^\n]*\n)/$2$1/s'
mut "M18 geocoder is read from the netloc key"                       's/loc_on "\$_f" geocoder && _g=/loc_on "\$_f" netloc \&\& _g=/'
mut "M19 a successful release keeps the owner record"                's/    rm -f "\$LOC_OWNER"\n(    echo "\[roamd\] locglobals user \$_u \(\$_why\): baseline)/$1/'
mut "M20 the first matching line no longer wins (the loop runs on)"  's/\[ "\$_v" = 1 \]; return ;;/[ "\$_v" = 1 ] \&\& _hit=1 || _hit=0 ;;/; s/(  done < "\$1"\n)  return 1\n(\}\n\n# loc_set )/$1  [ "\${_hit:-0}" = 1 ]\n$2/'
mut "M21 an owner whose user is gone still counts"                   's/  if \[ -n "\$_o" \] && loc_gone "\$_o"; then\n[^\n]*\n    _o=""\n  fi\n//'
mut "M22 a denied lookup counts as a gone user"                      's/  case "\$_e" in \*"No such file"\*\) return 0 ;; esac\n  return 1/  return 0/'
mut "M23 the owner's directory is looked up under another name"     's/_e=\$\(ls -d "\$LOC_USER_ROOT\/\$1" /_e=\$(ls -d "\$LOC_USER_ROOT\/x\$1" /'
mut "M24 loc_owner keeps an owner record that is not a number"      's/  case "\$_o" in \*\[!0-9\]\*\) _o="" ;; esac\n//'
mut "M25 loc_set's read-back keeps what is not a digit or a letter" 's/ \| tr -cd '"'"'0-9a-z'"'"'\)/)/g'
[ "$fails" = 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
