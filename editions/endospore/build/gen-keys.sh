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
# WHERE (NWP-20261105-19). On a host with a keys home ($NOWHERE_KEYS_HOME, default /mnt/build/keys/endospore; it must be
# an absolute path, else exit 2), keys/<device> above is <home>/<device>: the keys are made only in the home, so a
# device's keys never live only in one tree and no tree gets a second set beside the home's. A tree with no keys/, or
# whose keys/ is a link to the home, makes them in the home (build-device.sh --release then links a tree to it through
# keys-home.sh). A tree whose keys/ does not resolve to the home (its own directory, a link elsewhere) is refused
# (exit 3), as is a home path that is not a directory; nothing is created. Without a home, keys/<device> is in the
# tree, as before. A keys directory that cannot be made or entered stops the script (exit 1) before any key is made.
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
TOP=$(pwd)   # the tree root: the tools are reached from here, not by ../.. from a keys dir that may be the home
KD="keys/$DEV"

# NWP-20261105-19: with a keys home, the keys are made in it (WHERE, above). A tree whose own keys/ held a device the home
# lacks would otherwise be the only copy, and one beside a home that holds the device would be a second set.
KH="${NOWHERE_KEYS_HOME:-/mnt/build/keys/endospore}"
case "$KH" in /*) ;; *) echo "gen-keys.sh: NOWHERE_KEYS_HOME must be an absolute path: $KH" >&2; exit 2 ;; esac
if [ -e "$KH" ] || [ -L "$KH" ]; then
  if [ ! -d "$KH" ]; then
    echo "gen-keys.sh: REFUSING. The keys home $KH exists but is not a directory. Nothing was created." >&2
    exit 3
  fi
  if [ -e keys ] || [ -L keys ]; then
    if [ "$(readlink -f keys 2>/dev/null)" != "$(readlink -f "$KH")" ]; then
      echo "gen-keys.sh: REFUSING. This host has a keys home, $KH, and keys are made only there; this tree's keys/ is not it." >&2
      echo "  If this tree's keys/$DEV is not in the keys home yet, copy it there first (docs/release-runbook.md section 1b)." >&2
      echo "  Then move this tree's keys/ aside and re-run. Nothing was created." >&2
      exit 3
    fi
  fi
  KD="$KH/$DEV"
fi

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

# Fail closed: a failed cd would leave the cwd at the tree root, and the steps below would make keys THERE.
mkdir -p "$KD" || { echo "FAILED mkdir $KD"; exit 1; }
cd "$KD" || { echo "FAILED cd $KD"; exit 1; }

for k in releasekey platform shared media networkstack bluetooth sdk_sandbox gmscompat_lib nfc; do
  if [ -f "$k.pk8" ] && [ -f "$k.x509.pem" ]; then echo "skip $k (exists)"; continue; fi
  "$TOP/development/tools/make_key" "$k" "/CN=$CN/" </dev/null || true
  if [ -f "$k.pk8" ] && [ -f "$k.x509.pem" ]; then echo "made $k"; else echo "FAILED $k"; exit 1; fi
done

[ -f avb.pem ]      || openssl genrsa -out avb.pem 4096 || true
[ -f avb.pem ]      && echo "avb.pem ok"      || { echo "FAILED avb.pem"; exit 1; }
[ -f avb_pkmd.bin ] || "$TOP/external/avb/avbtool.py" extract_public_key --key avb.pem --output avb_pkmd.bin || true
[ -f avb_pkmd.bin ] && echo "avb_pkmd.bin ok" || { echo "FAILED avb_pkmd.bin"; exit 1; }
[ -f id_ed25519 ]   || ssh-keygen -t ed25519 -f id_ed25519 -N "" -q || true
[ -f id_ed25519 ]   && echo "id_ed25519 ok"   || { echo "FAILED id_ed25519"; exit 1; }

echo "--- $KD ---"
ls -la
