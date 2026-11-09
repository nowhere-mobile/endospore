#!/bin/sh
# keys-home.sh <tree> <device> -- give a GrapheneOS tree the Endospore signing keys of <device> before a release
# (NWP-20261105-19). build-device.sh --release runs it before its own key checks and the passphrase prompt, and
# sign-release.sh runs it in its preflight for every device.
#
# WHY. The per-device keys (avb.pem, avb_pkmd.bin, releasekey, platform, ..., id_ed25519) live in ONE place outside
# every tree: the keys home, $NOWHERE_KEYS_HOME (default /mnt/build/keys/endospore), one directory per device.
# GrapheneOS's script/generate-release.sh reads them only from the tree it runs in (PERSISTENT_KEY_DIR=keys/$DEVICE),
# and script/ is GrapheneOS's: an edit there is reverted by the next sync, like every out-of-repo patch. So a tree
# reaches the keys through its own keys/, and this script makes that a link to the home when the tree has none. Until
# 2026-11-05 the only copy on the build host was the June tree's own keys/: the 2026110200 tree could not sign, and
# deleting the June tree a cycle after the move (docs/release-runbook.md section 1b, step 8) would have deleted the
# keys with it.
#
#   <tree>/keys a link to the home    -> used; a link to anywhere else is refused (exit 3)
#   <tree>/keys absent                -> linked to the home when the home holds <device>; else refused (exit 4)
#   <tree>/keys the tree's own dir    -> used as it is (the June tree's copy). When the home also holds <device>, each
#                                        public half there (*.x509.pem, avb_pkmd.bin, id_ed25519.pub) that the tree's
#                                        copy also holds must be byte-identical to it, or the tree is refused (exit 3);
#                                        when the home does not hold <device>, or nothing could be compared, a warning
#                                        says the tree's copy may be the only one on this host
#   <tree>/keys anything else         -> refused (exit 3)
# First of all, a keys home, or a <device> of it, that resolves inside a repo-managed source tree (an ancestor holds
# .repo/) is refused (exit 3): it would be deleted with that tree. Then <tree>/keys/<device> must be a directory (exit
# 4). The script never creates, copies, moves or reads a private
# key: the only files it reads are public halves, and the only thing it ever creates is the link. A refusal names what
# is missing and leaves the tree and the home as they were. NEVER answer a refusal with gen-keys.sh for a device that has
# shipped: a new avb.pem is a new AVB root, and every relocked handset rejects an image signed by it.
# Exit 0 = <tree>/keys/<device> is usable, 2 = usage, 3 = <tree>/keys is not this device's keys, 4 = no keys for <device>.
# Pinned by test-keys-home.sh (--mutate).
set -u
[ "$#" -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || { echo "usage: keys-home.sh <tree> <device>" >&2; exit 2; }
TREE="$1"; DEV="$2"
case "$DEV" in */*|.*|-*) echo "keys-home.sh: '$DEV' is not a device name" >&2; exit 2 ;; esac
HOME_DIR="${NOWHERE_KEYS_HOME:-/mnt/build/keys/endospore}"
case "$HOME_DIR" in /*) ;; *) echo "keys-home.sh: NOWHERE_KEYS_HOME must be an absolute path (a relative link breaks): $HOME_DIR" >&2; exit 2 ;; esac
[ -d "$TREE" ] || { echo "keys-home.sh: no tree at $TREE" >&2; exit 2; }
K="$TREE/keys"
H="$HOME_DIR/$DEV"

# in_tree <path>: 0 when <path> resolves to a place inside a repo-managed source tree (an ancestor holds .repo/). A keys
# home there, or a <device> of it linked there, is deleted with that tree (section 1b, step 8), so it is no home at all.
in_tree() {
  p=$(readlink -f "$1" 2>/dev/null) || return 1
  while [ -n "$p" ] && [ "$p" != / ]; do
    [ -d "$p/.repo" ] && return 0
    p=${p%/*}
  done
  return 1
}
for x in "$HOME_DIR" "$H"; do
  if { [ -e "$x" ] || [ -L "$x" ]; } && in_tree "$x"; then
    echo "keys-home.sh: $x resolves to $(readlink -f "$x" 2>/dev/null), inside a source tree -- refusing; the keys home must be a" >&2
    echo "  directory of its own, or deleting that tree deletes the keys" >&2
    exit 3
  fi
done

if [ -L "$K" ]; then
  if [ ! -d "$HOME_DIR" ]; then
    echo "keys-home.sh: $K is a link to $(readlink "$K"), and the keys home $HOME_DIR does not exist -- no signing keys for $DEV" >&2
    exit 4
  fi
  want=$(readlink -f "$HOME_DIR") || want=""
  got=$(readlink -f "$K" 2>/dev/null) || got=""
  if [ -z "$want" ] || [ "$got" != "$want" ]; then
    echo "keys-home.sh: $K is a link to $(readlink "$K"), not to the keys home $HOME_DIR -- refusing; fix or remove the link" >&2
    exit 3
  fi
  echo "[keys] $K -> $HOME_DIR (the keys home)"
elif [ -d "$K" ]; then
  if [ -d "$H" ]; then
    if [ ! -d "$K/$DEV" ]; then
      echo "keys-home.sh: $K is this tree's own keys directory and has no $DEV, while the keys home has $H." >&2
      echo "  Move $K aside and re-run: a tree with no keys/ is linked to the keys home." >&2
      exit 4
    fi
    command -v cmp >/dev/null 2>&1 || { echo "keys-home.sh: cmp is not installed, so this tree's keys cannot be compared with the keys home's -- refusing" >&2; exit 3; }
    n=0
    for f in "$H"/*.x509.pem "$H/avb_pkmd.bin" "$H/id_ed25519.pub"; do
      [ -f "$f" ] || continue
      b=${f##*/}
      [ -e "$K/$DEV/$b" ] || continue
      if ! cmp -s "$f" "$K/$DEV/$b"; then
        echo "keys-home.sh: $K/$DEV/$b differs from the keys home's $f -- this tree's keys for $DEV are not the keys home's; refusing" >&2
        exit 3
      fi
      n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
      echo "[keys] $K is this tree's own keys directory"
      echo "[keys] WARNING: the keys home's $H holds no public half this tree also holds, so nothing was compared and this tree's $K/$DEV may be the only copy on this host. Restore the keys home's $DEV (docs/release-runbook.md section 1b)."
    else
      echo "[keys] $K is this tree's own keys directory; its $n public half/halves for $DEV match the keys home's"
    fi
  else
    echo "[keys] $K is this tree's own keys directory"
    echo "[keys] WARNING: the keys home has no $H, so this tree's $K/$DEV is the only copy on this host and deleting the tree deletes it. Copy it into the keys home (docs/release-runbook.md section 1b)."
  fi
elif [ -e "$K" ]; then
  echo "keys-home.sh: $K exists but is neither a directory nor a link -- refusing" >&2
  exit 3
else
  if [ ! -d "$H" ]; then
    echo "keys-home.sh: no signing keys for $DEV: $K does not exist and the keys home has no $H." >&2
    echo "  Restore the keys into $H (from a tree's keys/$DEV or the off-box backup); this script never creates keys," >&2
    echo "  and gen-keys.sh must not be used for a device that has shipped (a new avb.pem is a new AVB root)." >&2
    exit 4
  fi
  ln -s "$HOME_DIR" "$K" || { echo "keys-home.sh: could not link $K to $HOME_DIR" >&2; exit 4; }
  echo "[keys] linked $K -> $HOME_DIR (the keys home; the tree had no keys/)"
fi

[ -d "$K/$DEV" ] || { echo "keys-home.sh: $K/$DEV is not a directory -- no signing keys for $DEV in this tree" >&2; exit 4; }
exit 0
