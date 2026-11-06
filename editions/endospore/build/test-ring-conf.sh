#!/usr/bin/env bash
# test-ring-conf.sh [<repo>] [--mutate] -- every ring conf names exactly one gateway and no store creds, and both
# stage-vendor.sh scripts log the gateway a ring bakes and refuse a ring that bakes none.
#
# WHY THIS IS COMMITTED (NWP-20261011-32). Both stage-vendor.sh scripts logged the baked ring with
# `grep -m1 '^GATEWAY_URL='`, but rings/beta-setup.conf -- the release driver's default ring -- carries
# NOWHERE_GATEWAY_DEFAULT= and no GATEWAY_URL= (that file's header says why the two keys differ). The log
# printed an empty value, so a wrong or missing gateway looked identical to a correct one. The stage now prints
# whichever key the conf carries, labelled by the key, and fails on a ring with neither.
#
# The ring block is extracted from each real stage-vendor.sh BY ANCHOR, never copied. If an anchor moves the
# extraction is empty and the suite exits 2 -- a test holding a stale copy would keep passing after the code
# changed.
#
#   bash test-ring-conf.sh             # the ring-conf checks and the ring-block cases, both editions
#   bash test-ring-conf.sh --mutate    # ... plus broken copies that must each CONVICT the suite
#
# <repo> is the repository root (default: this script's own); --mutate points the suite at scratch copies
# holding only the two stage-vendor.sh scripts and core/vendor-common/etc/rings/. Pure logic -- no build, no
# tree, no network.
set -uo pipefail

MUTATE=no; REPO=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) REPO="$a" ;; esac; done
REPO="${REPO:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RINGS="$REPO/core/vendor-common/etc/rings"
[ -d "$RINGS" ] || { echo "no rings dir: $RINGS" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1 -- [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 -- [$3] present in: $2" ;; *) ok "$1" ;; esac; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- (a) every committed ring conf -------------------------------------------------------------------
echo "== (a) rings/*.conf: exactly one https gateway key, no store creds =="
NCONF=0
for c in "$RINGS"/*.conf; do
  [ -f "$c" ] || continue
  NCONF=$((NCONF+1)); n=$(basename "$c")
  keys=$(grep -cE '^(GATEWAY_URL|NOWHERE_GATEWAY_DEFAULT)=' "$c")
  is "$n: exactly one of GATEWAY_URL= / NOWHERE_GATEWAY_DEFAULT=" "$keys" "1"
  val=$(grep -m1 -E '^(GATEWAY_URL|NOWHERE_GATEWAY_DEFAULT)=' "$c" | sed 's/^[A-Z_]*=//; s/\r$//')
  case "$val" in https://?*) ok "$n: the gateway is an https:// URL ($val)" ;; *) no "$n: gateway value [$val] is not https://" ;; esac
  creds=$(grep -cE '^[[:space:]]*(export[[:space:]]+)?S3_(ACCESS|SECRET)_KEY[[:space:]]*=' "$c")
  is "$n: carries no S3_ACCESS_KEY / S3_SECRET_KEY line" "$creds" "0"
done
[ "$NCONF" -gt 0 ] && ok "found $NCONF ring conf(s)" || no "no ring conf under $RINGS"
[ -f "$RINGS/beta-setup.conf" ] || { echo "no beta-setup.conf under $RINGS" >&2; exit 2; }
SETUP_GW=$(grep -m1 '^NOWHERE_GATEWAY_DEFAULT=' "$RINGS/beta-setup.conf")
[ -n "$SETUP_GW" ] || no "beta-setup.conf carries no NOWHERE_GATEWAY_DEFAULT= (the case (b) pins)"

# --- (b) each stage-vendor.sh's ring block ----------------------------------------------------------
# The whole `if [ -n "${NOWHERE_RING:-}" ]` block through its closing `fi`, run against a scratch REPO/DEST.
extract_ring(){ sed -n '/^if \[ -n "\${NOWHERE_RING:-}" \]; then/,/^fi$/ p' "$1"; }

# runring <block-file> <ring> [<conf-content>] -> "<rc>|<stdout+stderr>"; without content, the real ring conf
runring(){
  local blk="$1" ring="$2" r="$T/ring.sh" fr="$T/fake-repo" rc
  rm -rf "$fr" "$T/dest"; mkdir -p "$fr/core/vendor-common/etc/rings" "$T/dest/etc"
  if [ "$#" -ge 3 ]; then printf '%s' "$3" > "$fr/core/vendor-common/etc/rings/$ring.conf"
  else cp "$RINGS/$ring.conf" "$fr/core/vendor-common/etc/rings/$ring.conf"; fi
  { echo 'set -euo pipefail'
    printf 'REPO=%q; DEST=%q; NOWHERE_RING=%q\n' "$fr" "$T/dest" "$ring"
    cat "$blk"; } > "$r"
  bash "$r" > "$T/ring.out" 2>&1; rc=$?
  printf '%s|%s' "$rc" "$(cat "$T/ring.out")"
}

for ed in endospore diaspore; do
  SV="$REPO/editions/$ed/build/stage-vendor.sh"
  [ -f "$SV" ] || { echo "no such script: $SV" >&2; exit 2; }
  BLK="$T/$ed.block"; extract_ring "$SV" > "$BLK"
  case "$(cat "$BLK")" in *'RING_GW='*'baked ring'*) ;; *) echo "EXTRACTION FAILED -- ring-block anchors moved in $SV" >&2; exit 2 ;; esac
  echo "== (b) $ed stage-vendor.sh: the ring log =="

  R=$(runring "$BLK" beta-setup)
  is    "$ed: beta-setup stages (rc 0)"                              "${R%%|*}" "0"
  has   "$ed: beta-setup logs its labelled NOWHERE_GATEWAY_DEFAULT" "$R" "($SETUP_GW)"
  hasnt "$ed: beta-setup log carries no empty value"                "$R" "nowhere.conf ()"

  R=$(runring "$BLK" beta)
  is    "$ed: beta stages (rc 0)"                                   "${R%%|*}" "0"
  has   "$ed: beta logs its labelled GATEWAY_URL"                   "$R" "($(grep -m1 '^GATEWAY_URL=' "$RINGS/beta.conf"))"

  R=$(runring "$BLK" crlf $'# x\r\nGATEWAY_URL=https://gw.example\r\n')
  is    "$ed: a CRLF ring logs the gateway without the CR"          "$R" "0|[stage-vendor] baked ring 'crlf' -> vendor/$ed/etc/nowhere.conf (GATEWAY_URL=https://gw.example)"

  R=$(runring "$BLK" setup-only $'NOWHERE_GATEWAY_DEFAULT=https://gw.example\n')
  is    "$ed: a NOWHERE_GATEWAY_DEFAULT-only ring stages and logs it" "$R" "0|[stage-vendor] baked ring 'setup-only' -> vendor/$ed/etc/nowhere.conf (NOWHERE_GATEWAY_DEFAULT=https://gw.example)"

  R=$(runring "$BLK" nogw $'# GATEWAY_URL=https://commented.example\nOTA_RING=nogw\n')
  is    "$ed: a ring with neither key fails the stage (rc 1)"       "${R%%|*}" "1"
  has   "$ed: the error names the ring file"                        "$R" "rings/nogw.conf"
  has   "$ed: the error names both keys"                            "$R" "neither GATEWAY_URL= nor NOWHERE_GATEWAY_DEFAULT="
  hasnt "$ed: no 'baked ring' line for a ring with no gateway"      "$R" "baked ring"
  [ ! -e "$T/dest/etc/nowhere.conf" ] && ok "$ed: the gateway-less conf is not left staged" \
                                       || no "$ed: the gateway-less conf was left in DEST"
done

# --- (c) --mutate: each broken copy must fail the suite (rc 1, a real conviction -- not an extraction exit) ---
if [ "$MUTATE" = yes ]; then
  echo "== (c) mutations =="
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  # mutate <label> <file relative to the scratch repo> <shell snippet that edits "$F">
  mutate(){
    local label="$1" rel="$2" snip="$3" M="$T/mut" rc F
    rm -rf "$M"; mkdir -p "$M/core/vendor-common/etc" "$M/editions/endospore/build" "$M/editions/diaspore/build"
    cp -a "$RINGS" "$M/core/vendor-common/etc/rings"
    cp "$REPO/editions/endospore/build/stage-vendor.sh" "$M/editions/endospore/build/"
    cp "$REPO/editions/diaspore/build/stage-vendor.sh" "$M/editions/diaspore/build/"
    F="$M/$rel"; cp "$F" "$T/mut.orig"
    eval "$snip"
    if cmp -s "$F" "$T/mut.orig"; then no "mutation '$label' did not change $rel -- not counted"; return; fi
    bash "$SELF" "$M" > "$T/mut.out" 2>&1; rc=$?
    case "$rc" in
      1) ok "mutation convicted: $label" ;;
      0) no "mutation SURVIVED: $label" ;;
      *) no "mutation '$label' hit an extraction/setup exit (rc $rc), not a conviction"; tail -3 "$T/mut.out" | sed 's/^/        /' ;;
    esac
  }
  for ed in endospore diaspore; do
    mutate "$ed: the old GATEWAY_URL-only grep"      "editions/$ed/build/stage-vendor.sh" \
      'sed -i "s#grep -m1 -E '"'"'^(GATEWAY_URL|NOWHERE_GATEWAY_DEFAULT)='"'"'#grep -m1 '"'"'^GATEWAY_URL='"'"'#" "$F"'
    mutate "$ed: the no-gateway refusal removed"     "editions/$ed/build/stage-vendor.sh" \
      'sed -i "s/^  if \[ -z \"\$RING_GW\" \]; then\$/  if false; then/" "$F"'
    mutate "$ed: the refusal does not exit"          "editions/$ed/build/stage-vendor.sh" \
      'sed -i "/neither GATEWAY_URL= nor/{n;s/^    exit 1\$/    :/}" "$F"'
  done
  mutate "a ring carries a store access key"         "core/vendor-common/etc/rings/beta.conf" \
    'printf "S3_ACCESS_KEY=AKFAKE\n" >> "$F"'
  mutate "a ring carries a store secret key"         "core/vendor-common/etc/rings/beta-setup.conf" \
    'printf "S3_SECRET_KEY=SKFAKE\n" >> "$F"'
  mutate "a ring carries both gateway keys"          "core/vendor-common/etc/rings/beta-setup.conf" \
    'printf "GATEWAY_URL=https://gw.example\n" >> "$F"'
  mutate "a ring gateway is plain http"              "core/vendor-common/etc/rings/beta.conf" \
    'sed -i "s|^GATEWAY_URL=https://|GATEWAY_URL=http://|" "$F"'
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
