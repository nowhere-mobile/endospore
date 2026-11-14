#!/usr/bin/env bash
# test-roamd-media-rescan.sh [--mutate] -- NWP-20261113-45: after the sign-in's #media restore, roamd asks the
# session's chooser to run MediaProvider's own volume scan, because the provider scanned at user start, before the
# restore, and since NWP-20261202-02 its index is not roamed (0.5.56: the Gallery showed nothing restored).
#
# rescan_media is extracted from nowhere_roamd.sh BY ANCHOR, never copied (a moved anchor stops the suite with
# EXTRACTION FAILED, exit 2) and run in a child shell against a stub `am` that records its argv and exits a chosen
# code. The source pins check that the sign-in calls it right after restore_media_tail, inside the restore-succeeded
# branch, and that CredentialService answers the start with the provider's scan_volume call.
#
#   bash test-roamd-media-rescan.sh            # the cases and the source pins
#   bash test-roamd-media-rescan.sh --mutate   # ... plus mutants, each of which must be convicted
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
ROAMD="${ROAMD:-$HERE/nowhere_roamd.sh}"
CRED="${CRED:-$HERE/../../chooser/src/com/nowhere/chooser/CredentialService.java}"
for f in "$ROAMD" "$CRED"; do [ -f "$f" ] || { echo "EXTRACTION FAILED: no such file: $f" >&2; exit 2; }; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# --- extraction ------------------------------------------------------------------------------------------
extract_fn() { # $1 = source file -> rescan_media's body on stdout
  awk '/^rescan_media\(\) \{$/{p=1} p{print} p&&/^\}$/{exit}' "$1"
}
FN="$W/fn.sh"
extract_fn "$ROAMD" > "$FN"
grep -q '^rescan_media() {' "$FN" && grep -q '^}$' "$FN" || { echo "EXTRACTION FAILED: rescan_media() not found" >&2; exit 2; }

# run_case <fn file> <am exit code> -> sets ARGS (the stub's argv) and LOGTXT (what the helper logged)
run_case() {
  local fn="$1" rc="$2" d="$W/case.$RANDOM"
  mkdir -p "$d/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\nexit %s\n' "$d" "$rc" > "$d/bin/am"
  chmod +x "$d/bin/am"
  : > "$d/log"
  PATH="$d/bin:$PATH" LOG="$d/log" sh -c ". '$fn'; rescan_media 12" </dev/null >/dev/null 2>&1
  ARGS=""; [ -f "$d/argv" ] && ARGS=$(tr '\n' ' ' < "$d/argv")   # no argv file = am was never run
  LOGTXT=$(cat "$d/log")
}

# check <fn file> -> 0 when every behavioural expectation holds
check() {
  local fn="$1" bad=0
  run_case "$fn" 0
  case "$ARGS" in
    "startservice --user 12 -n com.nowhere.chooser/.CredentialService --ez rescanmedia true ") ;;
    *) echo "    argv was: [$ARGS]"; bad=1 ;;
  esac
  case "$LOGTXT" in *"media rescan requested from the session chooser (user 12, rc=0) (NWP-20261113-45)"*) ;; *) echo "    log was: [$LOGTXT]"; bad=1 ;; esac
  run_case "$fn" 1
  case "$LOGTXT" in *"(user 12, rc=1)"*) ;; *) echo "    failure log was: [$LOGTXT]"; bad=1 ;; esac
  return $bad
}

echo "rescan_media (extracted from $(basename "$ROAMD"))"
if check "$FN"; then ok "starts CredentialService rescanmedia as the session user and logs am's exit code"; else no "rescan_media behaviour"; fi

# --- source pins -------------------------------------------------------------------------------------------
echo "source pins"
# The call sits right after restore_media_tail, before the branch closes: only a restore that succeeded rescans.
if awk '/restore_media_tail "\$MEDIADIR"$/{a=NR} a&&NR==a+1&&/_ssum reown/{b=NR} b&&NR==b+1&&/^ *rescan_media "\$uid"/{f=1} b&&NR==b+2&&f&&/^ *fi$/{print "yes"; exit}' "$ROAMD" | grep -q yes; then
  ok "the sign-in calls rescan_media right after restore_media_tail, inside the restore-succeeded branch"
else no "the sign-in's rescan_media call is not where the restore succeeded"; fi
if grep -q 'getBooleanExtra("rescanmedia", false)' "$CRED" && grep -q '"scan_volume"' "$CRED" \
   && grep -q 'MediaStore.VOLUME_EXTERNAL_PRIMARY, null)' "$CRED"; then
  ok "CredentialService answers rescanmedia with MediaProvider's scan_volume on external_primary"
else no "CredentialService does not answer rescanmedia with scan_volume"; fi

# --- mutants -----------------------------------------------------------------------------------------------
if [ "$MUTATE" = yes ]; then
  echo "mutants (each must be convicted)"
  mutant() { # $1 = name, $2 = sed expression applied to the extracted function
    local m="$W/m.sh"; sed "$2" "$FN" > "$m"
    if cmp -s "$m" "$FN"; then no "mutant $1 did not change the function (sed missed)"; return; fi
    if check "$m" >/dev/null; then no "mutant $1 SURVIVED"; else ok "mutant $1 convicted"; fi
  }
  mutant "wrong-user"   's/--user "\$1"/--user 0/'
  mutant "wrong-extra"  's/--ez rescanmedia true/--ez claims true/'
  mutant "rc-dropped"   's/_rsrc=\$?/_rsrc=0/'
  mutant "no-start"     's/^  am startservice.*$/  :/'
  srcm="$W/roamd.mut"; sed 's/^\( *\)rescan_media "\$uid".*$/\1: #/' "$ROAMD" > "$srcm"
  if awk '/restore_media_tail "\$MEDIADIR"$/{a=NR} a&&NR==a+1&&/_ssum reown/{b=NR} b&&NR==b+1&&/^ *rescan_media "\$uid"/{print "yes"; exit}' "$srcm" | grep -q yes; then
    no "mutant call-removed SURVIVED the source pin"; else ok "mutant call-removed convicted"; fi
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
