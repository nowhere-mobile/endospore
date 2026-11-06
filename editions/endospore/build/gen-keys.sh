#!/usr/bin/env bash
# Generate Endospore signing keys for a GrapheneOS-derived build (E.1). Run from the GrapheneOS tree root.
#   Usage: gen-keys.sh <device> [--new-avb-root]      e.g.  editions/endospore/build/gen-keys.sh lynx
#
# Produces keys/<device>/ : the 9 app/platform keys (.pk8/.x509.pem), avb.pem (our verified-boot ROOT
# private key) + avb_pkmd.bin (its public form, flashed as the custom AVB key at relock), and id_ed25519
# (OTA metadata signing). Existing keys are left in place, so a re-run only makes what is missing -- EXCEPT
# the AVB root, which is never made beside a device's other keys:
#   * keys/<device> holds other keys but NO avb.pem  => the root is MISSING, not absent. Minting a new one
#     makes every relocked handset reject every later image, so the script refuses (exit 3) and creates,
#     moves and runs nothing. Restore avb.pem from the offline backup (docs/release-runbook.md section 10).
#   * --new-avb-root is the compromise playbook's step 5 and the only way past that refusal. It first moves
#     avb_pkmd.bin to avb_pkmd.bin.old (exit 3 if that already exists), then mints a new root. With avb.pem
#     present it is a usage error (exit 2): an existing avb.pem is never moved or overwritten.
# A missing or unknown argument is a usage error (exit 2) before anything is created. A fresh or empty
# keys/<device> makes everything, as does avb.pem alone (avb_pkmd.bin is derived from it).
#
# NOTE (proof build): keys are UNENCRYPTED at rest here so the build can run unattended. Production custody
# -- script/encrypt-keys with a passphrase + an OFF-box backup of avb.pem (lose it after relock => can't
# update the device; leak it => anyone can sign for it) -- is handled separately at the flash checkpoint.
#
# make_key's EXIT trap calls `exit 1` on EVERY exit (even success), so we verify the OUTPUT FILES rather
# than make_key's exit code, and feed an empty password via </dev/null.
set -uo pipefail
USAGE="usage: gen-keys.sh <device> [--new-avb-root]"
NEW_ROOT=0
case $# in
  1) ;;
  2) [ "$2" = "--new-avb-root" ] && NEW_ROOT=1 || { echo "$USAGE" >&2; exit 2; } ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
DEV="$1"
case "$DEV" in ""|-*) echo "$USAGE" >&2; exit 2 ;; esac
CN=Endospore
KD="keys/$DEV"

if [ "$NEW_ROOT" = 1 ] && [ -f "$KD/avb.pem" ]; then
  echo "gen-keys.sh: --new-avb-root given but $KD/avb.pem exists; this script never moves or overwrites an existing avb.pem." >&2
  echo "  After a compromise (docs/release-runbook.md section 10, step 5), move $KD/avb.pem out of $KD by hand first, then re-run with --new-avb-root." >&2
  exit 2
fi

if [ -d "$KD" ] && [ ! -f "$KD/avb.pem" ]; then
  other=0
  for f in "$KD"/*.pk8 "$KD"/*.x509.pem "$KD/avb_pkmd.bin" "$KD/id_ed25519"; do
    [ -e "$f" ] && other=1
  done
  if [ "$other" = 1 ]; then
    if [ "$NEW_ROOT" = 0 ]; then
      echo "gen-keys.sh: REFUSING. $KD holds other keys but no avb.pem: this device's AVB root is MISSING, not absent." >&2
      echo "  Restore avb.pem from the offline backup (docs/release-runbook.md section 10)." >&2
      echo "  Minting a new one makes every relocked handset reject every later image." >&2
      echo "  Delete $KD only if no handset was ever flashed with these keys." >&2
      echo "  --new-avb-root is the compromise playbook's step 5 (docs/release-runbook.md section 10)." >&2
      exit 3
    fi
    if [ -e "$KD/avb_pkmd.bin.old" ]; then
      echo "gen-keys.sh: $KD/avb_pkmd.bin.old already exists; it is the only copy of the old public half. Nothing changed." >&2
      exit 3
    fi
    if [ -e "$KD/avb_pkmd.bin" ]; then
      mv "$KD/avb_pkmd.bin" "$KD/avb_pkmd.bin.old" || { echo "gen-keys.sh: could not move $KD/avb_pkmd.bin to avb_pkmd.bin.old; no new root minted." >&2; exit 3; }
    fi
    echo "!!! NEW AVB ROOT for $DEV: every relocked $DEV unit must reinstall through the web installer. Old public half: $KD/avb_pkmd.bin.old"
  fi
fi

mkdir -p "$KD"
cd "$KD"

for k in releasekey platform shared media networkstack bluetooth sdk_sandbox gmscompat_lib nfc; do
  if [ -f "$k.pk8" ] && [ -f "$k.x509.pem" ]; then echo "skip $k (exists)"; continue; fi
  ../../development/tools/make_key "$k" "/CN=$CN/" </dev/null || true
  if [ -f "$k.pk8" ] && [ -f "$k.x509.pem" ]; then echo "made $k"; else echo "FAILED $k"; exit 1; fi
done

[ -f avb.pem ]      || openssl genrsa -out avb.pem 4096 || true
[ -f avb.pem ]      && echo "avb.pem ok"      || { echo "FAILED avb.pem"; exit 1; }
[ -f avb_pkmd.bin ] || ../../external/avb/avbtool.py extract_public_key --key avb.pem --output avb_pkmd.bin || true
[ -f avb_pkmd.bin ] && echo "avb_pkmd.bin ok" || { echo "FAILED avb_pkmd.bin"; exit 1; }
[ -f id_ed25519 ]   || ssh-keygen -t ed25519 -f id_ed25519 -N "" -q || true
[ -f id_ed25519 ]   && echo "id_ed25519 ok"   || { echo "FAILED id_ed25519"; exit 1; }

echo "--- keys/$DEV ---"
ls -la
