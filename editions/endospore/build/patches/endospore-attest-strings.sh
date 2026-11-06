#!/usr/bin/env bash
# endospore-attest-strings.sh -- #10 (DIA-20260716): neutralize the last GrapheneOS-naming CONNECTIVITY /
# ATTESTATION strings, now that the attestation posture is settled.
#
# POSTURE (decided 2026-07-16, mirroring Diaspore's p4.3-verified-boot): endospore ships SELF-SIGNED verified
# boot -- its own AVB + release keys (gen-keys.sh), relocked (E.1/#5/#6/#13) -- and takes NO hardware
# key-attestation-infra dependency. Its security model is verified boot + the amnesiac gate, exactly like
# Diaspore (LineageOS never stood up its own attestation either). Per the accompanying decision we KEEP using
# GrapheneOS's connectivity ENDPOINTS (SUPL/aGPS, PSDS, network-location proxy, remote key provisioning,
# cert-transparency, geocoder, connectivity checks) -- they're privacy-respecting and free, and standing up our
# own is a later phase -- but NEUTRALIZE the user-facing WORDING so the UI reads as the OS brand, not GrapheneOS.
# The endpoints + behaviour are UNCHANGED; only the labels the user sees change. The claims stay truthful:
# endospore is a relocked GrapheneOS derivative, so its connectivity + Play-Integrity posture is identical.
#
# These 10 strings (9 in strings_ext.xml + the exploit-protection compat summary) were the ONE set
# endospore-brand-strings.sh deliberately left "truthful pending #10". Same class: a direct SOURCE PATCH of the
# out-of-repo GrapheneOS tree, reapplied before `m`. Lands in Settings.apk -> reflash the system partition.
# Idempotent (a second run finds no "GrapheneOS" left). Asserts the end state afterwards (NWP-20261013-29):
# each file must hold "endospore" (the blanket sed leaves no "GrapheneOS"), else "[attest-strings] DRIFT: ..." on stderr and exit 2. Blanket per-file replace is exact here: no URL contains
# the brand (verified), and after endospore-brand-strings.sh the only remaining "GrapheneOS" mentions in these
# two files ARE these connectivity/attestation strings.
#
# Usage: endospore-attest-strings.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: endospore-attest-strings.sh <graphene-tree-root>}"
SEX="$TREE/packages/apps/Settings/res/values/strings_ext.xml"
AEP="$TREE/packages/apps/Settings/res/values/strings_app_exploit_protection.xml"

changed=0
for f in "$SEX" "$AEP"; do
  [ -f "$f" ] || { echo "no strings file at $f" >&2; exit 1; }
  n=$(grep -c 'GrapheneOS' "$f" || true)
  if [ "$n" -gt 0 ]; then
    sed -i 's/GrapheneOS/endospore/g' "$f"
    echo "[attest-strings] $(basename "$f"): neutralized $n GrapheneOS mention(s) -> endospore"; changed=1
  else
    echo "[attest-strings] $(basename "$f") already neutralized -- skipped"
  fi
done

# End-state assertions: an unmatched sed exits 0, so a file that never named the brand (upstream reworded or
# moved the strings) would otherwise pass as "already neutralized".
drift(){ echo "[attest-strings] DRIFT: $1" >&2; exit 2; }
for f in "$SEX" "$AEP"; do
  grep -cF -- 'endospore' "$f" >/dev/null || drift "no \"endospore\" in $f (upstream reworded or moved the strings?)"  # assert:attest-endospore
done

if [ "$changed" = 1 ]; then
  echo "[attest-strings] done -- rebuild Settings + reflash the system partition"
else
  echo "[attest-strings] nothing to change (already applied)"
fi
