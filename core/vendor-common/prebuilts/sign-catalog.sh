#!/bin/bash
# Sign the app-store catalog manifest with the release ed25519 key -> catalog.json.sig, and print the base64
# public key to bake into the agent (catalogPubKey in core/agent/catalog.go). Phase 2 (app store, DIA-20260730).
#
# The signature is over the EXACT bytes of catalog.json (the daemon verifies verbatim via ed25519.Verify), so do
# NOT reformat/re-serialize the manifest after signing. ed25519 via openssl (>= 1.1.1).
#
#   sign-catalog.sh keygen [KEYFILE]                # generate the release signing key (default catalog-signing.key)
#   sign-catalog.sh pubkey [KEYFILE]                # print the base64 raw (32-byte) public key -> catalogPubKey
#   sign-catalog.sh sign  CATALOG.json [KEYFILE]    # write CATALOG.json.sig (raw 64-byte ed25519 signature)
#   sign-catalog.sh verify CATALOG.json PUBB64      # verify CATALOG.json.sig against a base64 public key
#
# The private KEYFILE is a RELEASE SECRET: generate + hold it off the repo and off shared build-host paths
# (same discipline as the other signing keys). The agent bakes catalogPubKey, so every change to the catalog is
# re-signed and its .sig committed beside it; the procedure is in docs/app-store-design.md.
set -euo pipefail
usage() { echo "usage: sign-catalog.sh {keygen [KEY] | pubkey [KEY] | sign CATALOG.json [KEY] | verify CATALOG.json PUBB64}" >&2; exit 2; }

raw_pub() { openssl pkey -in "$1" -pubout -outform DER | tail -c 32 | base64 -w0; }

case "${1:-}" in
  keygen)
    key="${2:-catalog-signing.key}"
    [ -e "$key" ] && { echo "refusing to overwrite existing $key" >&2; exit 1; }
    # The private key must never exist with a wider mode, even briefly: created under the caller's umask (0644 under
    # the usual 022) and narrowed afterwards, another local user (the CI runner shares the signing host) could open
    # it in that window and keep the descriptor. Some openssl builds pin 0600 themselves and some do not, so the
    # script sets the mode itself; the chmod stays as a second safeguard.
    ( umask 077; openssl genpkey -algorithm ed25519 -out "$key" ); chmod 600 "$key"
    echo "wrote $key (KEEP SECRET)"
    echo "catalogPubKey = \"$(raw_pub "$key")\""
    ;;
  pubkey)
    raw_pub "${2:-catalog-signing.key}"; echo
    ;;
  sign)
    cat="${2:?CATALOG.json required}"; key="${3:-catalog-signing.key}"
    openssl pkeyutl -sign -inkey "$key" -rawin -in "$cat" -out "$cat.sig"
    echo "wrote $cat.sig ($(wc -c < "$cat.sig") bytes) over $(wc -c < "$cat") manifest bytes"
    echo "public key: $(raw_pub "$key")"
    ;;
  verify)
    cat="${2:?CATALOG.json required}"; pub="${3:?base64 public key required}"
    tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.der" "$tmp.raw"' EXIT
    # A key that is not exactly 32 bytes is refused here, before openssl, with a message that names the cause (the
    # device's verifyEd25519 refuses the same key).
    if ! printf '%s' "$pub" | base64 -d > "$tmp.raw" 2>/dev/null || [ "$(wc -c < "$tmp.raw")" -ne 32 ]; then
      echo "BAD: public key is not 32 bytes" >&2; exit 1
    fi
    # Rebuild a DER ed25519 SubjectPublicKeyInfo from the raw 32 bytes, then verify. The 12-byte prefix
    # (30 2a 30 05 06 03 2b 65 70 03 21 00) is written with printf octal escapes, not `xxd -r -p`: xxd ships with
    # vim, not coreutils, and on a host without it this fail-closed check died 127 and publish-fdroid-index.sh
    # refused every publish with an error that named xxd, not the cause.
    printf '\060\052\060\005\006\003\053\145\160\003\041\000' > "$tmp.der"
    cat "$tmp.raw" >> "$tmp.der"
    openssl pkey -pubin -inform DER -in "$tmp.der" -out "$tmp"
    openssl pkeyutl -verify -pubin -inkey "$tmp" -rawin -in "$cat" -sigfile "$cat.sig" \
      && echo "OK: signature valid" || { echo "BAD: signature INVALID" >&2; exit 1; }
    ;;
  *) usage ;;
esac
