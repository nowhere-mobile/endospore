#!/usr/bin/env bash
# ssaid-userkey-seed.sh -- let a roamed profile carry its app identities across the roam (#210).
#
# THE PROBLEM. An app's ANDROID_ID (SSAID) is not stored identity, it is DERIVED:
#   SSAID = f(per-user "userkey", app signing certificate)
# Every login builds a NEW Android user, Android mints that user a RANDOM userkey, so every app
# recomputes a brand-new id and device-identity-bound sessions (Amazon MAP et al.) log out on every
# single login. Carrying the ONE userkey row reproduces EVERY app's id -- no per-app rows, no uid
# remapping (uids don't even exist yet at roam-in).
#
# WHY THIS HAS TO BE A FRAMEWORK PATCH. Seeding the settings_ssaid.xml FILE cannot work, at any time.
# SettingsProvider instantiates the per-user ssaid SettingsState when the user is created, caches it in
# system_server, and NEVER re-reads the file -- it only writes it. Proven on lynx 2026-07-28:
#   12:19:24.351 SettingsState:    No settings state /data/system/users/11/settings_ssaid.xml
#   12:19:25     [roamd] seedssaid OK user 11 (#210)      <- our write, one second too late, ignored
# The write lands on disk and is then clobbered by the cached (empty -> randomly minted) state. Two
# earlier attempts died here: seeding at roam-in ("SKIPPED (state already live)") and seeding between
# createAndManageUser and startUserInBackground (logged OK, had no effect -- the id still rotated).
#
# THE FIX. Patch the mint itself. generateUserKeyLocked() is called LAZILY from generateSsaidLocked()
# the first time any app in that user asks for its id -- well after login -- so a seed staged by
# nowhere_roamd at /data/system/users/<userId>/nowhere-ssaid-seed is simply there to be consumed when
# the key is minted. No race: we are not writing a file the framework might already have read, we are
# handing the framework the value at the moment it asks for one.
#
# The seed is a ONE-SHOT: consumed or not, valid or not, the file is deleted, so a stale seed left by a
# reaped user can never be replayed onto a recycled user id. Absent seed (user 0, the gate, any
# non-roamed user) -> the stock random key, byte-for-byte stock behaviour.
#
# NB roamd must STILL remove a stale settings_ssaid.xml left behind by a recycled user id
# (DIA-20260728-08): if that file exists, SettingsProvider loads a userkey from it, generateUserKeyLocked
# is never called, and the seed is never consumed.
#
# Same class as keyguard-roaming-noocclude.sh: a direct SOURCE PATCH of the out-of-repo GrapheneOS /
# LineageOS tree, reapplied on the build host before `m`. Tree-agnostic (the anchors are stock AOSP,
# unchanged in GrapheneOS). Idempotent -- a second run detects the marker and no-ops.
#
# Lands in SettingsProvider.apk (/system/priv-app), so after building, reflash the SYSTEM partition.
#
# Usage: ssaid-userkey-seed.sh <tree-root>
set -euo pipefail
TREE="${1:?usage: ssaid-userkey-seed.sh <tree-root>}"
SP="$TREE/frameworks/base/packages/SettingsProvider/src/com/android/providers/settings/SettingsProvider.java"
[ -f "$SP" ] || { echo "no SettingsProvider at $SP" >&2; exit 1; }

MARKER="nowhere-ssaid-seed"
ANCHOR='            final String userKey = HexEncoding.encodeToString(keyBytes, true /* upperCase */);'

if grep -qF "$MARKER" "$SP"; then
  echo "[ssaid-seed] SettingsProvider already patched -- skipped"
  exit 0
fi

# Count the anchor the way the awk below will see it (whole-line exact matches): the awk replaces only the first,
# so a second site would be left minting a random userkey under a success exit (NWP-20261016-33). `|| true`: grep
# exits 1 on a zero count, which under set -e/pipefail would abort before the message.
ANCHOR_N=$(grep -cxF -- "$ANCHOR" "$SP" || true)
if [ "$ANCHOR_N" -eq 0 ]; then
  echo "[ssaid-seed] anchor not found in $SP -- upstream changed generateUserKeyLocked, patch by hand" >&2
  exit 1
elif [ "$ANCHOR_N" -ne 1 ]; then
  echo "[ssaid-seed] anchor matched $ANCHOR_N times in $SP -- upstream changed generateUserKeyLocked, patch by hand" >&2
  exit 1
fi

# The replacement block. Fully qualified type names throughout so the patch adds no imports (an import
# hunk is a second anchor to rot); `userKey` loses its `final` because we may override it.
NEW=$(cat <<'JAVA'
            // #210 (nowhere): consume this profile's staged SSAID userkey if nowhere_roamd left one for
            // this user. An app's SSAID is DERIVED f(userkey, app signing cert), so a userkey the profile
            // reproduces on every device reproduces every app's id -- device-bound logins survive a roam
            // instead of dropping at each login. Seeding the settings_ssaid.xml FILE cannot work: the
            // per-user ssaid state is instantiated at user creation and never re-read, only written. So the
            // seed is consumed HERE, at mint time. One-shot: the file is always deleted, so a stale seed
            // from a reaped user can never be replayed onto a recycled user id. No seed -> stock random.
            String userKey = HexEncoding.encodeToString(keyBytes, true /* upperCase */);
            final java.io.File nowhereSeed =
                    new java.io.File("/data/system/users/" + userId + "/nowhere-ssaid-seed");
            try {
                final byte[] nowhereRaw = new byte[80];
                final int nowhereLen;
                try (java.io.FileInputStream nowhereIn = new java.io.FileInputStream(nowhereSeed)) {
                    nowhereLen = nowhereIn.read(nowhereRaw);
                }
                final String nowhereHex = new String(nowhereRaw, 0, Math.max(nowhereLen, 0),
                        java.nio.charset.StandardCharsets.UTF_8).trim();
                if (nowhereHex.matches("[0-9A-Fa-f]{64}")) {
                    userKey = nowhereHex.toUpperCase(java.util.Locale.US);
                    Slog.i(LOG_TAG, "nowhere: seeded ssaid userkey for user " + userId + " (#210)");
                } else {
                    Slog.w(LOG_TAG, "nowhere: ssaid seed for user " + userId
                            + " is malformed -- minting a random userkey (#210)");
                }
            } catch (java.io.FileNotFoundException e) {
                // No seed for this user (user 0, the gate, any non-roamed user) -- stock behaviour.
            } catch (Exception e) {
                Slog.w(LOG_TAG, "nowhere: ssaid seed for user " + userId
                        + " is unreadable -- minting a random userkey (#210)", e);
            } finally {
                nowhereSeed.delete();
            }
JAVA
)

# Swap the one anchor line for the block. awk, not sed: the block is multi-line and carries slashes,
# quotes and ampersands that sed's replacement syntax would mangle.
awk -v anchor="$ANCHOR" -v block="$NEW" '
  $0 == anchor && !done { print block; done = 1; next }
  { print }
' "$SP" > "$SP.nowhere.tmp"

# Never leave a half-written source file behind on a failed rewrite.
if ! grep -qF "$MARKER" "$SP.nowhere.tmp"; then
  rm -f "$SP.nowhere.tmp"
  echo "[ssaid-seed] rewrite produced no marker -- aborted, $SP untouched" >&2
  exit 1
fi
mv "$SP.nowhere.tmp" "$SP"
echo "[ssaid-seed] SettingsProvider.generateUserKeyLocked: consumes /data/system/users/<id>/nowhere-ssaid-seed (#210)"
