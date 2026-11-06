#!/usr/bin/env bash
# test-web-package-version.sh [<make-web-package.sh>] [--mutate] -- the installer URL segment moves with
# every BUILD, same-day re-cuts included (NWP-20261011-06).
#
# WHY THIS IS COMMITTED. make-web-package.sh writes the manifest's "version", and with it the image URL
# /install/endospore/<device>/<version>/img/factory.zip. The storefront serves that URL immutable with
# max-age=1y, so the segment IS the browser/CDN cache key. It used to be YYYY.MM.DD, which dropped the
# build number's two-digit counter: 2026091306 and 2026091307 published two different zips at one URL, and
# the install page fetched the stale one and failed its hash check (NWP-20260913-14). This pins the
# derivation to the WHOLE build number and the 10-digit guard in front of it.
#
# The block is extracted from make-web-package.sh BY ANCHOR, never copied. If the anchors move, extraction
# is empty and the suite exits 2 loudly -- a test holding a stale copy would keep passing after the real
# code changed, which is the failure mode worth engineering against.
#
#   bash test-web-package-version.sh            # the behaviour cases
#   bash test-web-package-version.sh --mutate   # ... plus 3 mutations that must each CONVICT the suite
#
# Pure logic -- no build, no tree, no network. Runs anywhere bash does.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/make-web-package.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }

# --- extraction: the BN guard through the REL_VER line, by anchor ----------------------------------------
START='/^case "\$BN" in/'
END='/^REL_VER=/'
BLOCK=$(sed -n "$START,$END p" "$SUT")
case "$BLOCK" in
  *'case "$BN" in'*REL_VER=*) ;;
  *) echo "EXTRACTION FAILED -- anchors moved in $SUT" >&2; exit 2 ;;
esac

# --- harness: run the block in a SUBPROCESS with BN set; print "<rc>|<segment>|<stderr>" ------------------
# A subprocess, not eval: the guard's `exit 1` would otherwise end the suite itself.
derive(){
  local T rc seg err
  T=$(mktemp -d)
  { printf 'BN=%q\n' "$1"; printf '%s\n' "$BLOCK"; echo 'printf "%s" "$REL_VER" > "$RESULT"'; } > "$T/run.sh"
  RESULT="$T/result" bash "$T/run.sh" >/dev/null 2>"$T/err"; rc=$?
  seg=""; [ -f "$T/result" ] && seg=$(cat "$T/result")
  err=$(tr '\n' ' ' < "$T/err")
  rm -rf "$T"; printf '%s|%s|%s' "$rc" "$seg" "$err"
}
f(){ printf '%s' "$1" | cut -d'|' -f"$2"; }

echo "== a same-day re-cut gets its own segment =="
A=$(derive 2026091306); B=$(derive 2026091307)
is "2026091306 derives cleanly"  "$(f "$A" 1)" "0"
is "2026091306 -> 2026.09.13.06" "$(f "$A" 2)" "2026.09.13.06"
is "2026091307 derives cleanly"  "$(f "$B" 1)" "0"
is "2026091307 -> 2026.09.13.07" "$(f "$B" 2)" "2026.09.13.07"
[ "$(f "$A" 2)" != "$(f "$B" 2)" ] && ok "two BNs from one day differ" \
  || no "same segment for 2026091306 and 2026091307: $(f "$A" 2)"

echo "== the date still moves =="
C=$(derive 2026091401)
is "2026091401 -> 2026.09.14.01" "$(f "$C" 2)" "2026.09.14.01"
[ "$(f "$C" 2)" != "$(f "$A" 2)" ] && ok "next-day BN differs" \
  || no "2026091401 and 2026091306 share a segment: $(f "$C" 2)"

echo "== a BN that is not 10 digits is refused =="
for bad in 202609130 2026091306x 2026O91306 ""; do
  R=$(derive "$bad")
  [ "$(f "$R" 1)" != "0" ] && ok "refused [$bad]" || no "accepted [$bad] -> $(f "$R" 2)"
  is "no segment minted for [$bad]" "$(f "$R" 2)" ""
  case "$(f "$R" 3)" in
    *"10 digits"*) ok "refusal names the shape [$bad]" ;;
    *) no "refusal message for [$bad]: $(f "$R" 3)" ;;
  esac
done

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d)
  # A BROKEN mutation that never applied would make the suite exit non-zero and read as "convicted" --
  # a false green in the one place whose whole job is detecting false greens. Prove each applied first.
  mutate(){   # $1 label  $2 sed-expr  [$3 = want-exit: any|2]  [$4 = required output substring]
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then
      no "MUTATION BROKEN (sed failed), verdict meaningless: $1 -- $(cat "$M/err")"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then
      no "MUTATION INERT (matched nothing), verdict meaningless: $1"; return; fi
    OUT=$(bash "$0" "$M/m.sh" 2>&1); rc=$?
    case "${3:-any}" in
      2) if [ "$rc" = 2 ]; then
           case "$OUT" in *"${4:-}"*) ok "convicted loudly: $1" ;; *) no "exit 2 but no '$4' in output: $1" ;; esac
         else no "NOT CONVICTED LOUDLY (rc=$rc, want 2): $1"; fi ;;
      *) if [ "$rc" = 0 ]; then no "NOT CONVICTED: $1 -- suite passes on broken code"; else ok "convicted: $1"; fi ;;
    esac; }
  mutate "the old date-only segment (NWP-20260913-14)" \
    's@^REL_VER=.*@REL_VER="${BN:0:4}.${BN:4:2}.${BN:6:2}"@'
  mutate "BN guard made inert (accepts any shape)" \
    's@^  \[0-9\]\[0-9\].*) ;;@  *) ;;@'
  mutate "anchors moved -- extraction must fail LOUDLY, not pass on nothing" \
    's@^case "\$BN" in@case "$BUILDNO" in@' 2 "EXTRACTION FAILED"
  rm -rf "$M"
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
