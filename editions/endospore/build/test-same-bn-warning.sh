#!/usr/bin/env bash
# test-same-bn-warning.sh [<build-device.sh>] [--mutate] -- the PREV_BN block of build-device.sh
# (NWP-20261017-37).
#
# A changed build number purges the generated build.prop; an UNCHANGED one must keep it (a same-number
# rebuild stays byte-reproducible) but WARN, because the image then carries the fingerprint a flashed
# device already has, PackageManager does not re-scan system apps, and a new chooser component silently
# fails to register. Three cases: number moved, number equal, no prior build.prop.
#
# The block is lifted from build-device.sh by anchor, never copied: moved anchors fail loudly.
#   bash test-same-bn-warning.sh            # the behaviour cases
#   bash test-same-bn-warning.sh --mutate   # ... plus 3 mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/build-device.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT   # every case dir, the excerpt and each mutant copy

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

extract(){ sed -n '/^PREV_BN="\$(sed/,/^echo "== \[\$(ts)\] m /p' "$1" | sed '$d'; }

# run <block-file> <prior-bn|-> <bn> -> sets OUTF/ERRF (stdout/stderr files) and PROP (build.prop path)
run(){
  local blk=$1 prev=$2 bn=$3 T
  T=$(mktemp -d -p "$W"); OUT_DIR="$T/out"; DEV=lynx
  PROP="$OUT_DIR/target/product/$DEV/vendor/build.prop"
  mkdir -p "$(dirname "$PROP")"
  if [ "$prev" != "-" ]; then
    echo "ro.vendor.build.fingerprint=google/lynx/lynx:17/CP2A.260605.012/$prev:userdebug/release-keys" > "$PROP"
  fi
  { echo 'OUT_DIR=$1; DEV=lynx; BN=$2'; cat "$blk"; } > "$T/run.sh"
  OUTF="$T/out.txt"; ERRF="$T/err.txt"
  bash "$T/run.sh" "$OUT_DIR" "$bn" > "$OUTF" 2> "$ERRF"
}
has(){ grep -q -- "$2" "$1" && echo yes || echo no; }

cases(){
  local blk=$1
  [ -s "$blk" ] || { echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; FAIL=$((FAIL+1)); return; }
  run "$blk" 2026101701 2026101702
  is "moved: purge message printed"     "$(has "$OUTF" 'purging generated build.prop')" yes
  is "moved: build.prop deleted"        "$([ -e "$PROP" ] && echo kept || echo gone)" gone
  is "moved: no WARNING"                "$(has "$ERRF" WARNING)$(has "$OUTF" WARNING)" nono
  run "$blk" 2026101702 2026101702
  is "equal: WARNING on stderr"         "$(has "$ERRF" 'WARNING: lynx was already built as 2026101702')" yes
  is "equal: warning names the wipe"    "$(has "$ERRF" 'Wipe data on flash')" yes
  is "equal: build.prop kept"           "$([ -e "$PROP" ] && echo kept || echo gone)" kept
  is "equal: no purge message"          "$(has "$OUTF" purging)" no
  run "$blk" - 2026101702
  is "no prior: no WARNING"             "$(has "$ERRF" WARNING)$(has "$OUTF" WARNING)" nono
  is "no prior: no purge message"       "$(has "$OUTF" purging)" no
}

BLK=$(mktemp -p "$W"); extract "$SUT" > "$BLK"
cases "$BLK"

if [ "$MUTATE" = yes ]; then
  mutant(){ # <name> <sed-expr>
    local M; M=$(mktemp -p "$W"); sed "$2" "$BLK" > "$M"
    if cmp -s "$BLK" "$M"; then no "mutant $1 did not apply"; return; fi
    local before=$FAIL; cases "$M" >/dev/null
    if [ "$FAIL" -gt "$before" ]; then FAIL=$before; ok "mutant $1 convicted"; else no "mutant $1 SURVIVED"; fi
  }
  mutant warning-removed   's/^elif \[ -n "\$PREV_BN" \]; then/elif false; then/'
  mutant warns-other-bn    's/^elif \[ -n "\$PREV_BN" \]; then/elif [ -n "$PREV_BN" ] \&\& [ "$PREV_BN" != "$BN" ]; then/'
  mutant equal-also-purges 's/^  echo "WARNING:/  find "$OUT_DIR\/target\/product\/$DEV" -name build.prop -delete; echo "WARNING:/'
fi
printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
