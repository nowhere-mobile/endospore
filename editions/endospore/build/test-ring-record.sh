#!/usr/bin/env bash
# test-ring-record.sh [<build-dir>] [--mutate] -- a build takes its ring from a record and checks what was baked (NWP-20261104-01).
#
# build-device.sh used to guess `${NOWHERE_RING:-beta-setup}`; lynx 2026091901/02 shipped the wrong ring and only Chester noticed
# (Q006, docs/product-decisions.md). ring-for-build.sh resolves the ring from ring-record.tsv (device x release/dev) and refuses a
# NOWHERE_RING that disagrees; assert-baked-ring.sh checks the staged conf against its template. This runs both under every shell
# found (bash, sh, dash, mksh) and reads build-device.sh as data. Pure logic: no build, no tree, no network.
#
#   bash test-ring-record.sh             # the gates
#   bash test-ring-record.sh --mutate    # ... plus mutants that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<build-dir>] [--mutate]" >&2; exit 2 ;; *) DIR="$a" ;; esac; done
DIR="${DIR:-$(cd "$(dirname "$0")" && pwd)}"
RFB="$DIR/ring-for-build.sh"; ABR="$DIR/assert-baked-ring.sh"; REC="$DIR/ring-record.tsv"; BD="$DIR/build-device.sh"
ROOT="$(cd "$DIR/../../.." && pwd)"; RINGS="$ROOT/core/vendor-common/etc/rings"
[ -f "$BD" ] || { echo "no such file: $BD" >&2; exit 2; }
[ -d "$RINGS" ] || { echo "no such dir: $RINGS" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

SHELLS="${RING_TEST_SHELLS:-}"
if [ -z "$SHELLS" ]; then for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
TAB=$'\t'

# rfb <shell> <dev> <kind> [VAR=val ...] -> RC, OUT, ERR. A missing helper is a FAIL of every case, not an abort.
rfb() {
  local s="$1" d="$2" k="$3"; shift 3
  local o e; o=$(mktemp -p "$W"); e=$(mktemp -p "$W")
  env -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE -u RING_RECORD "$@" "$s" "$RFB" "$d" "$k" >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e"); rm -f "$o" "$e"
}
# want <label> <rc> <out> : check the last rfb.
want() { if [ "$RC" = "$2" ] && [ "$OUT" = "$3" ]; then ok "$1"; else no "$1 (rc=$RC out='$OUT', want rc=$2 out='$3') $ERR"; fi; }

# abr <shell> <etc> <ring> <repo> -> RC
abr() { local s="$1"; shift; "$s" "$ABR" "$@" >/dev/null 2>&1; RC=$?; }
rc() { if [ "$RC" = "$2" ]; then ok "$1"; else no "$1 (rc=$RC, want $2)"; fi; }
etcdir() { local e; e=$(mktemp -d -p "$W"); [ "${2:-os}" = os ] && : > "$e/os-ref-lynx"; [ -n "${1:-}" ] && cp "$1" "$e/nowhere.conf"; echo "$e"; }

gates() {
  local s e r bad
  for s in $SHELLS; do
    rfb "$s" lynx dev;                          want "[$s] lynx dev, unset -> beta" 0 beta
    rfb "$s" lynx dev NOWHERE_RING=;            want "[$s] lynx dev, empty -> beta" 0 beta
    rfb "$s" lynx release;                      want "[$s] lynx release -> beta-setup" 0 beta-setup
    rfb "$s" frankel dev;                       want "[$s] frankel dev -> beta-setup" 0 beta-setup
    rfb "$s" tegu release;                      want "[$s] tegu release -> beta-setup" 0 beta-setup
    rfb "$s" lynx dev NOWHERE_RING=beta;        want "[$s] lynx dev, equal -> beta" 0 beta
    rfb "$s" lynx dev NOWHERE_RING=beta-setup
    if [ "$RC" = 1 ] && [[ "$ERR" == *beta-setup* && "$ERR" == *beta* && "$ERR" == *NOWHERE_RING_OVERRIDE* ]]; then ok "[$s] lynx dev, mismatch -> 1 naming both and the override"
    else no "[$s] lynx dev, mismatch (rc=$RC) $ERR"; fi
    rfb "$s" lynx dev NOWHERE_RING=beta-setup NOWHERE_RING_OVERRIDE=1
    if [ "$RC" = 0 ] && [ "$OUT" = beta-setup ] && [[ "$ERR" == *override* ]]; then ok "[$s] lynx dev, override -> beta-setup"
    else no "[$s] lynx dev, override (rc=$RC out='$OUT') $ERR"; fi
    rfb "$s" lynx dev NOWHERE_RING=beta NOWHERE_RING_OVERRIDE=1
    if [ "$RC" = 0 ] && [ "$OUT" = beta ] && [[ "$ERR" == *override* ]]; then ok "[$s] lynx dev, equal + override -> beta, says override"
    else no "[$s] lynx dev, equal + override (rc=$RC out='$OUT') $ERR"; fi
    rfb "$s" lynx bogus;                        want "[$s] bad kind -> 2" 2 ""
    rfb "$s" Lynx dev;                          want "[$s] bad device -> 2" 2 ""
    rfb "$s" "" dev;                            want "[$s] empty device -> 2" 2 ""
    rfb "$s" lynx dev NOWHERE_RING=nosuch NOWHERE_RING_OVERRIDE=1; want "[$s] ring with no template -> 2" 2 ""
    rfb "$s" lynx dev RING_RECORD="$W/missing.tsv"; want "[$s] record missing -> 2" 2 ""
    r=$(mktemp -p "$W"); printf 'lynx\tdev\tnosuch\n' > "$r"
    rfb "$s" lynx dev RING_RECORD="$r";         want "[$s] record row naming a ring with no template -> 2" 2 ""
    printf 'lynx\tdev\n' > "$r"
    rfb "$s" lynx dev RING_RECORD="$r";         want "[$s] garbled record -> 2" 2 ""
    printf '*\tdev\tbeta-setup\nhusky\tdev\tnone\n' > "$r"
    rfb "$s" husky dev RING_RECORD="$r";        want "[$s] exact row beats * (none -> empty)" 0 ""
    rfb "$s" frankel dev RING_RECORD="$r";      want "[$s] * row serves a device with no row" 0 beta-setup
    rm -f "$r"

    # assert-baked-ring.sh
    e=$(etcdir "$RINGS/beta.conf");             abr "$s" "$e" beta "$ROOT"; rc "[$s] beta staged, ring beta -> 0" 0
    abr "$s" "$e" beta-setup "$ROOT";           rc "[$s] beta staged, ring beta-setup -> 1" 1
    abr "$s" "$e" beta;  rc "[$s] wrong arity -> 2" 2
    abr "$s" "$e" nosuch "$ROOT";               rc "[$s] ring with no template -> 2" 2
    abr "$s" "$e" "" "$ROOT";                   rc "[$s] conf staged, empty ring -> 1" 1
    e=$(etcdir "$RINGS/beta-setup.conf");       abr "$s" "$e" beta-setup "$ROOT"; rc "[$s] beta-setup staged, ring beta-setup -> 0" 0
    e=$(etcdir "");                             abr "$s" "$e" "" "$ROOT";         rc "[$s] no conf, empty ring -> 0" 0
    abr "$s" "$e" beta "$ROOT"; rc "[$s] no conf, ring beta -> 1" 1
    e=$(etcdir "" none);                        abr "$s" "$e" "" "$ROOT";         rc "[$s] no conf and no os-ref, empty ring -> 1" 1
    e=$(mktemp -d -p "$W"); : > "$e/os-ref-lynx"; sed 's/beta\.nowhere/betx.nowhere/' "$RINGS/beta.conf" > "$e/nowhere.conf"
    cmp -s "$e/nowhere.conf" "$RINGS/beta.conf" && no "[$s] control fixture inert"
    abr "$s" "$e" beta "$ROOT"; rc "[$s] one byte changed -> 1 (the control)" 1
    bad=$(mktemp -d -p "$W"); mkdir -p "$bad/core/vendor-common/etc/rings"
    sed 's/^GATEWAY_URL=/NOWHERE_GATEWAY_DEFAULT=/' "$RINGS/beta.conf" > "$bad/core/vendor-common/etc/rings/beta.conf"
    e=$(etcdir "$bad/core/vendor-common/etc/rings/beta.conf"); abr "$s" "$e" beta "$bad"; rc "[$s] template with the wrong key matches by cmp, fails the marker -> 1" 1
  done
}

pins() {
  local n_rfb n_abr l_rfb l_case l_abr l_gate l_prep1 l_fi1 l_prep2 n_if n_old n_ctl line
  n_rfb=$(grep -c 'ring-for-build\.sh' "$BD"); n_abr=$(grep -c 'assert-baked-ring\.sh' "$BD")
  [ "$n_rfb" -ge 1 ] && ok "build-device.sh calls ring-for-build.sh" || no "build-device.sh calls ring-for-build.sh"
  [ "$n_abr" -ge 1 ] && ok "build-device.sh calls assert-baked-ring.sh" || no "build-device.sh calls assert-baked-ring.sh"
  line=$(grep -A1 'assert-baked-ring\.sh' "$BD" | tr '\n' ' ')
  [[ "$line" == *'"$RING"'* && "$line" == *'|| fail'* ]] && ok "the assertion call carries \"\$RING\" and || fail" || no "the assertion call carries \"\$RING\" and || fail"
  l_rfb=$(grep -n '^RING=.*ring-for-build\.sh' "$BD" | head -1 | cut -d: -f1)
  l_case=$(grep -n '^case "\$DEV" in' "$BD" | head -1 | cut -d: -f1)
  if [[ "$l_rfb" =~ ^[0-9]+$ && "$l_case" =~ ^[0-9]+$ && "$l_rfb" -lt "$l_case" ]]; then ok "ring-for-build.sh is called before case \"\$DEV\" in"; else no "ring-for-build.sh is called before case \"\$DEV\" in (${l_rfb:-none} vs ${l_case:-none})"; fi
  n_old=$(grep -cF '${NOWHERE_RING:-beta-setup}' "$BD")
  [ "$n_old" = 0 ] && ok "the guessed default is gone" || no "build-device.sh still holds \${NOWHERE_RING:-beta-setup}"
  l_abr=$(grep -n '^sh .*assert-baked-ring\.sh' "$BD" | head -1 | cut -d: -f1)
  l_gate=$(grep -n 'no os-ref-\$DEV staged' "$BD" | head -1 | cut -d: -f1)
  # Upper bound: the first `if [ "$PREP" = 1 ]; then` after the gate, not the echo inside it (a call just inside that if passed the echo bound, M7).
  l_prep1=$(grep -n '^if \[ "\$PREP" = 1 \]; then$' "$BD" | head -1 | cut -d: -f1)
  l_fi1=$(grep -n '^fi$' "$BD" | awk -F: -v a="${l_prep1:-0}" '$1 > a {print $1; exit}')
  l_prep2=$(grep -n '^if \[ "\$PREP" = 1 \]; then$' "$BD" | awk -F: -v g="${l_gate:-0}" '$1 > g {print $1; exit}')
  n_if=$(grep -n '^if ' "$BD" | awk -F: -v a="${l_fi1:-0}" -v b="${l_abr:-0}" '$1 > a && $1 < b {n++} END {print n+0}')
  if [[ "$l_abr" =~ ^[0-9]+$ && "$l_gate" =~ ^[0-9]+$ && "$l_fi1" =~ ^[0-9]+$ && "$l_prep2" =~ ^[0-9]+$ && "$l_fi1" -lt "$l_abr" && "$l_abr" -gt "$l_gate" && "$l_abr" -lt "$l_prep2" && "$n_if" = 0 ]]; then ok "the assertion sits between the os-ref gate and the second PREP block, under no if (runs for PREP=0)"
  else no "the assertion sits between the os-ref gate and the second PREP block, under no if (${l_gate:-none} < ${l_abr:-none} < ${l_prep2:-none}; $n_if if line(s) after the first PREP fi at ${l_fi1:-none})"; fi
  n_ctl=$(grep -c 'ota-field-guard\.sh' "$BD")
  [ "$n_ctl" -ge 1 ] && ok "control: the ota-field-guard call is found by the same reader" || no "control: the ota-field-guard call is not found"
}

wiring() {
  local code d out rc
  code=$(sed -n '/^KIND=dev; \[ "\$DO_RELEASE" = 1 \] && KIND=release$/,/^RING_HOW=/p' "$BD")
  if [[ "$code" != *ring-for-build.sh* ]]; then no "wiring: the KIND/RING lines were not found in build-device.sh"; return; fi
  out=$(env -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE DEV=lynx DO_RELEASE=0 REPO="$ROOT" bash -c "$code"$'\necho "RING=$RING how=$RING_HOW"' 2>&1)
  [ "$out" = "RING=beta how=record" ] && ok "wiring: lynx dev -> beta (record)" || no "wiring: lynx dev -> '$out'"
  out=$(env NOWHERE_RING=beta NOWHERE_RING_OVERRIDE=1 DEV=lynx DO_RELEASE=0 REPO="$ROOT" bash -c "$code"$'\necho "RING=$RING how=$RING_HOW"' 2>/dev/null)
  [ "$out" = "RING=beta how=override" ] && ok "wiring: lynx dev, NOWHERE_RING=beta + override -> beta (override)" || no "wiring: lynx dev, beta + override -> '$out'"
  out=$(env -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE DEV=lynx DO_RELEASE=1 REPO="$ROOT" bash -c "$code"$'\necho "RING=$RING"' 2>&1)
  [ "$out" = "RING=beta-setup" ] && ok "wiring: lynx release -> beta-setup" || no "wiring: lynx release -> '$out'"
  out=$(env -u NOWHERE_RING_OVERRIDE NOWHERE_RING=beta-setup DEV=lynx DO_RELEASE=0 REPO="$ROOT" bash -c "$code"$'\necho reached' 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok "wiring: a mismatch exits 1 before anything after it runs" || no "wiring: mismatch rc=$rc out='$out'"
  out=$(env -u NOWHERE_RING_OVERRIDE NOWHERE_RING=nosuch DEV=lynx DO_RELEASE=0 REPO="$ROOT" bash -c "$code"$'\necho reached' 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok "wiring: a mismatch without override exits before use" || no "wiring: rc=$rc"
  d=$(grep -c . <<<"$code"); [ "$d" -ge 3 ] || no "wiring: extract too short"
}

gates; pins; wiring

if [ "$MUTATE" = yes ]; then
  echo; echo "== mutants =="
  M=$(mktemp -d -p "$W")
  mutate(){ # mutate <label> <file-basename> <sed-script>
    local s file="$2"
    rm -rf "$M/editions" "$M/core"; mkdir -p "$M/editions/endospore/build" "$M/core/vendor-common/etc/rings"
    cp "$RFB" "$ABR" "$REC" "$BD" "$M/editions/endospore/build/"; cp "$RINGS"/*.conf "$M/core/vendor-common/etc/rings/"
    if ! sed -i "$3" "$M/editions/endospore/build/$file" 2>"$M/err"; then no "MUTATION BROKEN (sed failed): $1 -- $(cat "$M/err")"; return; fi
    if cmp -s "$DIR/$file" "$M/editions/endospore/build/$file"; then no "MUTATION INERT (matched nothing): $1"; return; fi
    for s in $SHELLS; do
      if RING_TEST_SHELLS=$s bash "$0" "$M/editions/endospore/build" >/dev/null 2>&1; then no "NOT CONVICTED [$s]: $1"; else ok "convicted [$s]: $1"; fi
    done; }
  mutate "* beats the exact row" ring-for-build.sh 's/^WANT="\$EXACT"$/WANT="$STAR"/'
  mutate "override ignored" ring-for-build.sh 's/"\${NOWHERE_RING_OVERRIDE:-}" = 1/"${NOWHERE_RING_OVERRIDE:-}" = never/'
  mutate "empty NOWHERE_RING taken as a mismatch" ring-for-build.sh 's/^if \[ -z "\${NOWHERE_RING:-}" \]; then$/if [ -z "${NOWHERE_RING+x}" ]; then/'
  mutate "cmp control removed" assert-baked-ring.sh '/^cmp -s /d'
  mutate "marker check inverted" assert-baked-ring.sh 's/^  beta)       if \[ "\$GU" -ge 1 \] \&\& \[ "\$GD" -eq 0 \]/  beta)       if [ "$GD" -ge 1 ] \&\& [ "$GU" -eq 0 ]/'
  mutate "build-device.sh assertion call removed" build-device.sh '/^sh .*assert-baked-ring\.sh/,/^  || fail "the staged ring conf/d'
  mutate "M7 assertion call moved just inside the second PREP block" build-device.sh '/^sh .*assert-baked-ring\.sh/{N;h;d};/^echo "== \[\$(ts)\] default apps ==/{x;G}'
fi

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
