#!/usr/bin/env bash
# endospore-brand-strings.sh -- rebrand the "missed" GrapheneOS / AOSP-system user-facing strings to
# endospore (DIA-20260714, task item (i)). The earlier Endospore branding pass (recovery-rebrand.sh)
# covered the recovery/fastbootd titles; these are the strings that still surface the GrapheneOS/AOSP
# identity to the user and were missed:
#
#   1. framework-res  android_system_label   "Android System" -> "endospore"
#        The android.uid.system sharedUserLabel -- the "Android System" name in Settings > Apps, some
#        permission prompts, etc. Stock AOSP string (GrapheneOS leaves it "Android System"). NOTE: this is
#        NOT the notification-shade header (that is target 4 -- a subtle but real distinction; see below).
#   2. framework-res  deprecated_abi_message_grapheneos  (the 32-bit-app compatibility warning) -- its one
#        "GrapheneOS" mention -> "endospore".
#   3. Settings  strings_ext.xml  duress-password confirmation  "GrapheneOS will remain installed"
#        -> "endospore will remain installed".
#   4. framework-res AndroidManifest.xml  <application android:label="GrapheneOS">  -> "endospore"
#        THE notification-shade header for every pkg=android system notification -- "Charging this device via
#        USB", "USB debugging connected", etc. The shade's loadHeaderAppName() shows the `android` package's
#        <application> label, which GrapheneOS hardcodes to the LITERAL "GrapheneOS" (not a @string ref).
#        Confirmed on-device 2026-07-14: android_system_label was the WRONG string for these; this is the one.
#
# We deliberately do NOT touch the strings that name GrapheneOS's ACTUAL infrastructure / technology -- the
# connectivity / PSDS / remote-provisioning / cert-transparency / geocoder / network-location proxy + server
# names, the Play Integrity explainer, and the exploit-protection toggle summary (all in strings_ext.xml /
# strings_app_exploit_protection.xml). Those describe real GrapheneOS servers and behaviour; renaming them
# to endospore would be factually wrong until the Endospore attestation / connectivity posture is settled
# (task #10). Each sed below targets a UNIQUE phrase, so it can never collide with those strings.
#
# Same class as recovery-rebrand.sh: a direct SOURCE PATCH of the out-of-repo GrapheneOS tree, reapplied on
# the build host before `m`. It lands in framework-res.apk and Settings.apk, so after building reflash the
# system partition. Idempotent -- a second run finds the source strings already replaced and is a no-op.
#
# Casing: lowercase "endospore" to match the OS wordmark -- ro.nowhere.brand=endospore, and the gate title,
# the user/org name (ChooserActivity.brand() returns the prop verbatim) and the recovery titles all render
# lowercase "endospore". (If prose title-case is preferred for the two full-sentence strings (#2, #3), it's
# a one-word tweak.)
#
# Usage: endospore-brand-strings.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: endospore-brand-strings.sh <graphene-tree-root>}"
FRW="$TREE/frameworks/base/core/res/res/values/strings.xml"
FRWMAN="$TREE/frameworks/base/core/res/AndroidManifest.xml"
SEX="$TREE/packages/apps/Settings/res/values/strings_ext.xml"
[ -f "$FRW" ] || { echo "no framework-res strings at $FRW" >&2; exit 1; }
[ -f "$FRWMAN" ] || { echo "no framework-res manifest at $FRWMAN" >&2; exit 1; }
[ -f "$SEX" ] || { echo "no Settings strings_ext at $SEX" >&2; exit 1; }

changed=0

# 1. android_system_label -> the "Android System" surfaces (Settings > Apps entry, the android.uid.system
#    sharedUserLabel, some permission dialogs). NOTE: this is NOT the notification-shade header -- that comes
#    from the framework `android` package's <application android:label>, rebranded in step 4 below.
if grep -qF '<string name="android_system_label">Android System</string>' "$FRW"; then
  sed -i 's#<string name="android_system_label">Android System</string>#<string name="android_system_label">endospore</string>#' "$FRW"
  echo "[brand-strings] android_system_label: Android System -> endospore"; changed=1
else
  echo "[brand-strings] android_system_label already rebranded -- skipped"
fi

# 2. 32-bit-app deprecation warning (its single GrapheneOS mention; unique phrase).
if grep -qF 'GrapheneOS plans to phase out' "$FRW"; then
  sed -i 's#GrapheneOS plans to phase out#endospore plans to phase out#' "$FRW"
  echo "[brand-strings] deprecated_abi_message_grapheneos: GrapheneOS -> endospore"; changed=1
else
  echo "[brand-strings] 32-bit deprecation warning already rebranded -- skipped"
fi

# 3. Duress-password confirmation (unique phrase; will NOT hit 'GrapheneOS proxy'/'GrapheneOS server').
if grep -qF 'GrapheneOS will remain installed' "$SEX"; then
  sed -i 's#GrapheneOS will remain installed#endospore will remain installed#' "$SEX"
  echo "[brand-strings] duress confirmation: GrapheneOS -> endospore"; changed=1
else
  echo "[brand-strings] duress confirmation already rebranded -- skipped"
fi

# 4. THE notification-shade header for every framework system notification (pkg=android: "Charging this
#    device via USB", "USB debugging connected", etc.). GrapheneOS hardcodes android:label="GrapheneOS" on
#    the framework `android` package's <application> tag -- a LITERAL, not a @string ref -- and the shade's
#    loadHeaderAppName() shows that application label. This (NOT android_system_label) is what actually reads
#    "GrapheneOS" on those notices; confirmed on-device 2026-07-14 (screenshot). Unique literal in the manifest.
if grep -qF 'android:label="GrapheneOS"' "$FRWMAN"; then
  sed -i 's#android:label="GrapheneOS"#android:label="endospore"#' "$FRWMAN"
  echo "[brand-strings] framework <application> label: GrapheneOS -> endospore (system-notification header)"; changed=1
else
  echo "[brand-strings] framework application label already rebranded -- skipped"
fi

# 5. THE notification-shade header ICON for pkg=android system notifications. The shade shows the framework
#    `android` package's <application android:icon="@drawable/ic_launcher_android"> next to the label rebranded
#    in step 4. GrapheneOS ships its own logo there as per-density PNGs; overlay our endospore spore mark as a
#    density-independent vector (drawable-anydpi-v21 wins over the per-density PNGs on API 21+), so the header
#    icon matches the "endospore" wordmark. Source = the same spore vector the chooser/launcher use.
SPIRAL_SRC="${NOWHERE_SPORE_SRC:-$(dirname "$0")/../../vendor/chooser/res/drawable/ic_nowhere.xml}"
SPIRAL_DST="$TREE/frameworks/base/core/res/res/drawable-anydpi-v21/ic_launcher_android.xml"
if [ -f "$SPIRAL_SRC" ] && ! cmp -s "$SPIRAL_SRC" "$SPIRAL_DST" 2>/dev/null; then
  mkdir -p "$(dirname "$SPIRAL_DST")"
  cp "$SPIRAL_SRC" "$SPIRAL_DST"
  echo "[brand-strings] framework app icon -> endospore spore vector (notif-shade header)"; changed=1
elif [ -f "$SPIRAL_DST" ]; then
  echo "[brand-strings] framework app icon already the endospore spore -- skipped"
else
  echo "[brand-strings] DRIFT: spore source not found ($SPIRAL_SRC) -- header icon left as GrapheneOS" >&2; exit 2  # assert:brand-spore-src
fi

# End-state assertions (NWP-20261013-29): the seds and the cp above succeed whether or not they matched.
drift(){ echo "[brand-strings] DRIFT: $1" >&2; exit 2; }
grep -cF -- '<string name="android_system_label">endospore</string>' "$FRW" >/dev/null || drift "android_system_label is not \"endospore\" in $FRW (upstream string moved?)"  # assert:brand-system-label
grep -cF -- 'endospore plans to phase out' "$FRW" >/dev/null || drift "the 32-bit deprecation warning does not say endospore in $FRW (upstream wording moved?)"  # assert:brand-abi-message
grep -cF -- 'endospore will remain installed' "$SEX" >/dev/null || drift "the duress confirmation does not say endospore in $SEX (upstream wording moved?)"  # assert:brand-duress
grep -cF -- 'android:label="endospore"' "$FRWMAN" >/dev/null || drift "the framework <application> label is not \"endospore\" in $FRWMAN (upstream moved the literal?)"  # assert:brand-app-label
cmp -s "$SPIRAL_SRC" "$SPIRAL_DST" || drift "the framework app icon at $SPIRAL_DST is not the endospore spore"  # assert:brand-icon

if [ "$changed" = 1 ]; then
  echo "[brand-strings] done -- rebuild framework-res + Settings and reflash the system partition"
else
  echo "[brand-strings] nothing to change (already applied)"
fi
