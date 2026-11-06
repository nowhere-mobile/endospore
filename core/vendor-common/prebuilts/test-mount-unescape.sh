#!/bin/sh
# test-mount-unescape.sh -- NWP-20260828-08. Guards unesc_mount() in nowhere_mediad.sh.
#
# WHY THIS EXISTS. /proc/mounts writes a space in a mount path as the octal escape "\040". Every umount in
# nowhere_mediad.sh used to take the path from /proc/mounts VERBATIM, so umount(8) named a file that does
# not exist and failed -- silently, because the error went to $LOG and the trailing && dropped the success
# line too. WhatsApp names every media folder with a space ("WhatsApp Images", "WhatsApp Voice Notes", ...),
# so on any profile carrying WhatsApp media EVERY overlay leaked, went ENOTCONN, and the logoff seal was
# refused FOREVER: the walk could not read those dirs, #111's guard correctly refused a manifest that was
# short by construction, and the session could never be saved. Measured on lynx 2026-08-28: of 126 mounts,
# the 60 whose path contained a space were ALL dead and the 66 without were ALL alive.
#
# It reads the function OUT OF THE REAL SCRIPT rather than restating it, so the test cannot drift from the
# code it guards -- the failure mode that let the original contacts-extractor bug ship (NWC-20260827-21).
#
# Run anywhere with a POSIX sh + sed:  sh core/vendor-common/prebuilts/test-mount-unescape.sh
set -u

HERE=$(dirname "$0")
# MEDIAD overrides the script under test (--mutate points it at broken copies).
SRC="${MEDIAD:-$HERE/../bin/nowhere_mediad.sh}"

# --mutate: re-run against sed-broken copies of the mediad; each must FAIL. A mutant that does not apply counts
# as a failure, never a pass.
if [ "${1:-}" = "--mutate" ]; then
  _tmp=$(mktemp -d) || exit 1
  trap 'rm -rf "$_tmp"' EXIT
  _bad=0
  mutant() { # <label> <sed script>
    sed -e "$2" "$SRC" > "$_tmp/m.sh"
    if cmp -s "$SRC" "$_tmp/m.sh"; then echo "  MUTANT DID NOT APPLY: $1"; _bad=$((_bad+1)); return; fi
    if MEDIAD="$_tmp/m.sh" sh "$0" > "$_tmp/out" 2>&1; then echo "  SURVIVED: $1"; _bad=$((_bad+1))
    else echo "  convicted: $1"; fi
  }
  mutant 'drop the \040 decode' "/^unesc_mount() {/,/^}/s| -e 's/[\][\]040/ /g'||"
  mutant 'drop the \134 decode' "/^unesc_mount() {/,/^}/s| -e 's/[\][\]134/[\][\]/g'||"
  [ "$_bad" = 0 ] || { echo "FAIL: $_bad mutant(s) not convicted"; exit 1; }
  echo "PASS: every mutant convicted"; exit 0
fi
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

# shellcheck disable=SC1090 -- the function under test is extracted from the shipping script on purpose
eval "$(sed -n '/^unesc_mount()/,/^}/p' "$SRC")"
command -v unesc_mount > /dev/null 2>&1 || { echo "unesc_mount not found in $SRC" >&2; exit 2; }

fail=0
chk() { # <input> <expected> <label>
  got=$(unesc_mount "$1")
  if [ "$got" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n         got  [%s]\n         want [%s]\n' "$3" "$got" "$2"
    fail=$((fail + 1))
  fi
}

TAB=$(printf '\t')

# the exact path that could not be unmounted on lynx
chk '/data/media/10/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp\040Images' \
    '/data/media/10/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images' \
    'the real WhatsApp path'
chk '/x/WhatsApp\040Voice\040Notes/202430' '/x/WhatsApp Voice Notes/202430' 'two spaces in one segment'
chk 'a\040b\040c' 'a b c'                                                   'multiple spaces'
chk 'a\011b'      "a${TAB}b"                                                'tab'
chk 'a\134b'      'a\b'                                                     'literal backslash'

# \134 is decoded LAST, so a path that literally contains the TEXT "\040" survives: /proc/mounts writes it
# as "\134040", no "\040" substring matches, and the final rule restores it. Same as the Go single pass in
# media_seal.go unescapeMountPath, which this mirrors.
chk '\134040' '\040' 'a path literally containing the text backslash-040 round-trips'

# paths with nothing to decode must come back byte-identical -- the common case, and the one that would
# break every unmount if a rule were too greedy
chk '/data/media/10/DCIM/NatureID' '/data/media/10/DCIM/NatureID' 'no escapes -> unchanged'
chk '/x/.nowhere-media/.under/DCIM_NatureID' '/x/.nowhere-media/.under/DCIM_NatureID' 'a real .under bind path'

if [ "$fail" -eq 0 ]; then
  echo "PASS: unesc_mount decodes /proc/mounts escapes correctly"
  exit 0
fi
echo "FAIL: $fail case(s)" >&2
exit 1
