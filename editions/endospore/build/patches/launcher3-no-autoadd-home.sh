#!/usr/bin/env bash
# Endospore Launcher3: do NOT auto-add a newly installed app to the home screen (NWP-20260820-16).
#
# WHY. Android drops a newly installed app into the first free workspace cell, which on this build is page 2
# (page 0 is deliberately empty -- see launcher3-qsb-firstscreen.sh). The WORKSPACE roams: relabel_launcher
# rewrites favorites.profileId to the new user's serial so the home survives a login. But an app the user has
# NOT kept does not roam -- so the layout comes back referencing a package that is gone, and Launcher3 leaves
# the cell EMPTY. It never compacts a workspace. Chester, on device: "say I downloaded app 1 first, then app
# 2 ... now if i go and set only app 2 to be kept for roam. next login, there will be an empty space between
# app 2 and previously kept apps".
#
# The argument is semantic, not cosmetic: on an amnesiac roaming device a home-screen slot IMPLIES PERMANENCE
# the app does not have, so auto-adding a session-only app misrepresents it -- and page 2 is a CURATED surface
# we seed ourselves from /system/etc/nowhere/default-home (nowhere_roamd seed_home), not a dumping ground.
# The app is still in the drawer; the user can place it deliberately, and that placement is a real choice.
#
# ⚠ This does NOT fully close the class: a user who MANUALLY places an unkept app on page 2 still leaves a
# hole. A login-time compaction would heal that and any layout already in the field, and is tracked as its own
# decision -- silently reflowing a home someone arranged by hand is its own surprise.
#
# WHY A SOURCE PATCH, not an RRO. The default is a hardcoded Kotlin value, not a resource:
#   BaseDefaultsValueProvider.addIconToHome = true      (src/com/android/launcher3/util/DefaultsValueProvider.kt)
# There is no bool resource behind it, so there is nothing for an overlay to override. (Verified: that class is
# the ONLY DefaultsValueProvider implementation in the tree, and dagger binds it in BOTH AppModule.kt for the
# quickstep build and Modules.kt for src_no_quickstep, so patching it is sufficient and complete.)
#
# TWO EDITS, and both are needed or the UI lies. SessionCommitReceiver.isEnabled() reads the stored preference
# with the provider's value as its DEFAULT, while Home settings renders the same key from
# launcher_preferences.xml's android:defaultValue. Change only the provider and the Settings switch still shows
# ON while nothing is added; change only the XML and the behaviour is unaffected until the user opens Settings.
#
# EDITION-ROOT, not per-device (AGENTS.md: a thing goes in the LOWEST tier that still needs it). Unlike
# launcher3-grid.sh, which encodes one device's grid, this is identical for every Pixel -- so it lives here and
# applies to frankel/lynx/stallion/tegu/husky, and to any device added later, without being copied five times.
#
# Idempotent (a second run finds no "true" left to change). Run after a fresh Launcher3 checkout, before `m`.
# Usage: launcher3-no-autoadd-home.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: launcher3-no-autoadd-home.sh <graphene-tree-root>}"

DVP="$TREE/packages/apps/Launcher3/src/com/android/launcher3/util/DefaultsValueProvider.kt"
PREFS="$TREE/packages/apps/Launcher3/res/xml/launcher_preferences.xml"

for f in "$DVP" "$PREFS"; do
  [ -f "$f" ] || { echo "launcher3-no-autoadd-home: missing $f -- upstream moved it"; exit 2; }
done

# 1. the code default that SessionCommitReceiver.isEnabled() falls back to.
if grep -q 'override val addIconToHome: Boolean = true' "$DVP"; then
  sed -i 's/override val addIconToHome: Boolean = true/override val addIconToHome: Boolean = false/' "$DVP"
  echo "launcher3-no-autoadd-home: BaseDefaultsValueProvider.addIconToHome -> false"
elif grep -q 'override val addIconToHome: Boolean = false' "$DVP"; then
  echo "launcher3-no-autoadd-home: addIconToHome already false (idempotent)"
else
  echo "launcher3-no-autoadd-home: addIconToHome anchor not found in $DVP -- upstream changed it"; exit 2
fi

# 2. the Home-settings switch default, scoped to THIS preference block so no other defaultValue is touched.
if grep -q 'pref_add_icon_to_home' "$PREFS"; then
  sed -i '/pref_add_icon_to_home/,/\/>/ s/android:defaultValue="true"/android:defaultValue="false"/' "$PREFS"
  echo "launcher3-no-autoadd-home: pref_add_icon_to_home defaultValue -> false"
else
  echo "launcher3-no-autoadd-home: pref_add_icon_to_home not found in $PREFS -- upstream changed it"; exit 2
fi

# Assert the end state rather than trusting the edits (the artifact, not the marker).
grep -q 'override val addIconToHome: Boolean = false' "$DVP" \
  || { echo "launcher3-no-autoadd-home: FAILED -- provider default is still true"; exit 1; }
# grep -c, not grep -q: under pipefail an early-exiting grep can SIGPIPE sed and fail this check at random.
sed -n '/pref_add_icon_to_home/,/\/>/p' "$PREFS" | grep -c 'android:defaultValue="false"' >/dev/null \
  || { echo "launcher3-no-autoadd-home: FAILED -- switch default is still true"; exit 1; }
echo "launcher3-no-autoadd-home: OK"
