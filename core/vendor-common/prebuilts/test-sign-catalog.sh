#!/bin/bash
# test-sign-catalog.sh -- NWP-20261102-13. Executes sign-catalog.sh, which no suite ran before.
#
# WHY THIS EXISTS. sign-catalog.sh signs core/vendor-common/etc/catalog.json and, through publish-fdroid-index.sh
# (steps 3-4 and its fail-closed verify), every F-Droid index the device's REFRESH-INDEX accepts. Two defects sat
# in it because nothing ran it: `verify` built its SubjectPublicKeyInfo with `xxd` (ships with vim, not coreutils),
# so on a host without it the verify died 127 and publish-fdroid-index.sh refused every publish with an error that
# named xxd, not the cause; and `keygen` created the private key with the caller's umask and narrowed it with a
# chmod afterwards.
#
# k2 DEVIATION FROM THE OBVIOUS TEST. Stock OpenSSL >= 1.1.0 on POSIX already opens a genpkey output 0600, so
# running the old script with only chmod shimmed still gives 600. k2 therefore also wraps `openssl` so that
# genpkey writes by plain shell redirection (as an openssl that does not pin the mode does): the old script then
# leaves 644 and the fixed one 600. The assertion is the script's own guarantee, not the first openssl's habit.
#
# c1 verifies the COMMITTED catalog.json.sig against the catalogPubKey read out of core/agent/catalog.go, which
# proves the DER prefix the octal escapes write is right. It only reads the repo.
#
# Run:  bash core/vendor-common/prebuilts/test-sign-catalog.sh [--mutate]     (ONLY="k2 v5" runs just those)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
# SIGN_CATALOG overrides the script under test (--mutate points it at broken copies).
SC="${SIGN_CATALOG:-$HERE/sign-catalog.sh}"
BASH_BIN=$(command -v bash)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
# Every invocation of the script under test (and of this suite's re-invocations) puts its temps inside $W.
export TMPDIR="$W"

if ! command -v openssl > /dev/null 2>&1; then
  echo "FAIL: openssl not found (>= 1.1.1 required for ed25519)"; exit 1
fi
openssl version

if [ "${1:-}" = "--mutate" ]; then
  bad=0
  mutant() { # <label> <case> <python replace: old> <new>
    local label="$1" kase="$2" m out rc
    m=$(mktemp -p "$W") || { bad=$((bad+1)); return; }
    SC_SRC="$SC" SC_OUT="$m" SC_OLD="$3" SC_NEW="$4" python3 -I -c '
import os
s = open(os.environ["SC_SRC"]).read()
o = os.environ["SC_OLD"]
open(os.environ["SC_OUT"], "w").write(s.replace(o, os.environ["SC_NEW"], 1) if o in s else s)'
    if cmp -s "$SC" "$m"; then echo "  MUTANT DID NOT APPLY: $label"; bad=$((bad+1)); return; fi
    out=$(SIGN_CATALOG="$m" ONLY="$kase" "$BASH_BIN" "$0" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && [[ "$out" == *"FAIL $kase"* ]]; then echo "  convicted: $label (by $kase)"
    else echo "  SURVIVED: $label (rc=$rc)"; bad=$((bad+1)); fi
  }
  mutant 'S1 one octal byte of the DER prefix changed' c1 '\145\160' '\146\160'
  mutant 'S2 the 32-byte check removed' v4 ' || [ "$(wc -c < "$tmp.raw")" -ne 32 ]' ''
  mutant 'S3 umask 077 removed' k2 'umask 077; ' ''
  mutant 'S4 the overwrite refusal removed' k1 '[ -e "$key" ] && { echo "refusing to overwrite existing $key" >&2; exit 1; }' ':'
  mutant 'S5 verify BAD arm exits 0' v2 'echo "BAD: signature INVALID" >&2; exit 1' 'echo "BAD: signature INVALID" >&2; exit 0'
  [ "$bad" = 0 ] || { echo "FAIL: $bad mutant(s) not convicted"; exit 1; }
  echo "PASS: every mutant convicted"; exit 0
fi
[ -r "$SC" ] || { echo "cannot read $SC" >&2; exit 2; }

fail=0
want() { case " ${ONLY:-} " in *" $1 "*) return 0 ;; esac; [ -z "${ONLY:-}" ]; }
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s: %s\n' "$1" "$2"; fail=$((fail+1)); }

# fixture catalog + keys
CAT=$(mktemp -p "$W"); printf '{"apps":[{"id":"org.example.app","v":1}]}\n' > "$CAT"
KEY=$W/k1.key
KEY2=$W/k2.key
PUB=""

if want k1; then
  out=$("$BASH_BIN" "$SC" keygen "$KEY" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$KEY" ] || [[ "$out" != *"wrote "* ]] || [[ "$out" != *'catalogPubKey = "'* ]]; then
    bad k1 "keygen rc=$rc out=$out"
  else
    before=$(sha256sum < "$KEY")
    out=$("$BASH_BIN" "$SC" keygen "$KEY" 2>&1); rc=$?
    after=$(sha256sum < "$KEY")
    if [ "$rc" -ne 1 ] || [[ "$out" != *"refusing to overwrite"* ]] || [ "$before" != "$after" ]; then
      bad k1 "second keygen rc=$rc out=$out changed=$([ "$before" = "$after" ] && echo no || echo yes)"
    else ok k1; fi
  fi
fi
# later cases need the keys whatever ONLY selected
[ -s "$KEY" ] || "$BASH_BIN" "$SC" keygen "$KEY" > /dev/null 2>&1
"$BASH_BIN" "$SC" keygen "$KEY2" > /dev/null 2>&1

if want k2; then
  shim=$(mktemp -d -p "$W")
  REAL=$(command -v openssl)
  printf '#!/bin/sh\nexit 0\n' > "$shim/chmod"
  cat > "$shim/openssl" <<WRAP
#!/bin/bash
# stands in for an openssl that does not pin the mode of a private-key output: -out becomes a redirection
real="$REAL"
if [ "\${1:-}" = genpkey ]; then
  args=(); f=""
  while [ \$# -gt 0 ]; do
    if [ "\$1" = -out ]; then f="\$2"; shift 2; else args+=("\$1"); shift; fi
  done
  "\$real" "\${args[@]}" > "\$f"
else
  exec "\$real" "\$@"
fi
WRAP
  chmod +x "$shim/chmod" "$shim/openssl"
  k=$W/k2case.key
  out=$(umask 022; PATH="$shim:$PATH" "$BASH_BIN" "$SC" keygen "$k" 2>&1); rc=$?
  mode=$(stat -c %a "$k" 2>/dev/null)
  if [ "$rc" -ne 0 ]; then bad k2 "keygen rc=$rc out=$out"
  elif [ "$mode" != 600 ]; then bad k2 "key mode is $mode, want 600"
  else ok k2; fi
fi

PUB=$("$BASH_BIN" "$SC" pubkey "$KEY" 2>&1)
PUB2=$("$BASH_BIN" "$SC" pubkey "$KEY2" 2>&1)

if want p1; then
  n=$(printf '%s' "$PUB" | base64 -d 2> /dev/null | wc -c)
  if [[ "$PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] && [ "$n" -eq 32 ]; then ok p1
  else bad p1 "pubkey=$PUB decodes to $n bytes"; fi
fi

# run sign then verify the way v1 and v5 do; sets sout/vout/vrc/siglen
sign_verify() { # <PATH for the script> -- the catalog copy is fresh each time
  local p="$1" c
  c=$(mktemp -p "$W"); cp "$CAT" "$c"
  sout=$(PATH="$p" "$BASH_BIN" "$SC" sign "$c" "$KEY" 2>&1); srcode=$?
  vout=$(PATH="$p" "$BASH_BIN" "$SC" verify "$c" "$PUB" 2>&1); vrc=$?
  siglen=$(wc -c < "$c.sig" 2> /dev/null)
  SIGNED=$c
}

if want v1; then
  sign_verify "$PATH"
  if [ "$srcode" -eq 0 ] && [ "$vrc" -eq 0 ] && [[ "$vout" == *"OK: signature valid"* ]] && [ "${siglen:-0}" -eq 64 ]; then ok v1
  else bad v1 "sign rc=$srcode verify rc=$vrc sig=${siglen:-?} bytes out=$sout / $vout"; fi
fi

if want v2; then
  c=$(mktemp -p "$W"); cp "$CAT" "$c"
  "$BASH_BIN" "$SC" sign "$c" "$KEY" > /dev/null 2>&1
  sed -i 's/"v":1/"v":2/' "$c"
  out=$("$BASH_BIN" "$SC" verify "$c" "$PUB" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && [[ "$out" == *"BAD: signature INVALID"* ]]; then ok v2
  else bad v2 "rc=$rc out=$out"; fi
fi

if want v3; then
  c=$(mktemp -p "$W"); cp "$CAT" "$c"
  "$BASH_BIN" "$SC" sign "$c" "$KEY" > /dev/null 2>&1
  out=$("$BASH_BIN" "$SC" verify "$c" "$PUB2" 2>&1); rc=$?
  if [ "$rc" -eq 1 ]; then ok v3; else bad v3 "rc=$rc out=$out"; fi
fi

if want v4; then
  c=$(mktemp -p "$W"); cp "$CAT" "$c"
  "$BASH_BIN" "$SC" sign "$c" "$KEY" > /dev/null 2>&1
  short=$(printf '%s' "$PUB" | base64 -d 2> /dev/null | head -c 31 | base64 -w0)
  out=$("$BASH_BIN" "$SC" verify "$c" "$short" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && [[ "$out" == *"BAD: public key is not 32 bytes"* ]]; then ok v4
  else bad v4 "rc=$rc out=$out"; fi
fi

if want v5; then
  d=$(mktemp -d -p "$W"); missing=""
  for t in openssl base64 wc cat mktemp rm tail chmod head sed cp; do
    p=$(command -v "$t") && ln -s "$p" "$d/$t" || missing="$missing $t"
  done
  if [ -n "$missing" ]; then bad v5 "host lacks:$missing"
  elif [ -e "$d/xxd" ]; then bad v5 "xxd is on the shim PATH"
  else
    sign_verify "$d"
    if [ "$srcode" -eq 0 ] && [ "$vrc" -eq 0 ] && [[ "$vout" == *"OK: signature valid"* ]]; then ok v5
    else bad v5 "without xxd: sign rc=$srcode verify rc=$vrc out=$sout / $vout"; fi
  fi
fi

if want c1; then
  pk=$(sed -n 's/^var catalogPubKey = "\([^"]*\)".*/\1/p' "$ROOT/core/agent/catalog.go")
  if [ -z "$pk" ]; then bad c1 "catalogPubKey not found in core/agent/catalog.go"
  else
    out=$("$BASH_BIN" "$SC" verify "$ROOT/core/vendor-common/etc/catalog.json" "$pk" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [[ "$out" == *"OK: signature valid"* ]]; then ok c1
    else bad c1 "committed catalog.json.sig does not verify: rc=$rc out=$out"; fi
  fi
fi

[ "$fail" = 0 ] || { echo "FAIL: $fail case(s)"; exit 1; }
echo "PASS"
