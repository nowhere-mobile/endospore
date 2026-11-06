#!/usr/bin/env bash
# gos-chooser-grant.sh -- roam GrapheneOS per-app hardening state (NWP-20260821-17, architecture A").
#
# GrapheneOS per-app settings (Settings > Apps > <app> > "Exploit protection compatibility mode" and the
# other hardening switches) are GosPackageState, which is per-(package,user) and therefore VIRGIN on every
# Nowhere login -- every login mints a brand-new Android user. Chester's banking apps need compat mode, and
# GrapheneOS itself recommends it for them, so the setting has to survive the roam.
#
# WHY A PATCH IS REQUIRED AT ALL. GosPackageState has NO shell read: `edit-gos-package-state`
# (PackageManagerShellCommand.java) is the only entry point and every one of its verbs is a WRITE
# (device-proven on lynx: `cmd package get-gos-package-state` -> "Unknown command", rc=255). The only read
# is the binder API, and access to it is gated by a hardcoded appId table in GosPackageStatePermissions with
# no signature, device-owner or platform-cert door. So CAPTURE is impossible without either a new read verb
# or an entry in that table. This patch adds the entry. See docs/gos-package-state-roam.md.
#
# WHAT IT GRANTS, AND WHAT IT DELIBERATELY DOES NOT:
#   * `settingsReadWriteFlags` ONLY -- the exact hardening set the Settings app already holds, which is
#     where ENABLE_EXPLOIT_PROTECTION_COMPAT_MODE lives. Reusing the upstream ARRAY (not a copied list) means
#     the grant tracks upstream automatically if GrapheneOS adds a hardening switch.
#   * NO playIntegrityFlags. Bit 26 PLAY_INTEGRITY_API_USED_AT_LEAST_ONCE is derived USAGE BOOKKEEPING, not a
#     user setting -- and it is the only GosPackageState found in the wild on our own test device
#     (toonblast, flags-1=67108864). Because GosPackageStatePermission.filterRead() masks every read to the
#     caller's granted flags, withholding it here makes it STRUCTURALLY UNREADABLE by the chooser rather than
#     merely filtered in our own code. The grant IS the allowlist.
#   * NO storage-scopes / contact-scopes fields, and NOT their enable flags. Both are BLOCKED BY DESIGN for
#     roaming (the storage blob embeds the SOURCE USER ID as a literal path; the contact blob is raw
#     contacts-DB row ids). See docs/gos-package-state-roam.md sections 1 and 4.
#   * NO crossUserPermission of any kind. The chooser does capture and apply from INSIDE the roamed user, so
#     targetUserId == callingUserId and checkCrossUserPermissions() short-circuits. Note that the CROSS_USER_
#     PROFILE variants would not have helped anyway -- they require getProfileParentId(target) == caller, and
#     Nowhere's roamed users are independent secondaries, not work profiles. Only createFull() carries
#     ALLOW_CROSS_ANY_USER_WRITES, and we deliberately do not ask for it.
#
# ⚠ Builder.apply(String, Computer) requires the package to RESOLVE and to be a SYSTEM package. The chooser
#   is platform-signed and ships in the image, so it qualifies. On a debuggable build a miss THROWS
#   (GosPackageStatePermission.java: `if (Build.IS_DEBUGGABLE) throw new IllegalStateException(msg)`), so a
#   wrong package name is loud on userdebug and silent on user -- test on userdebug first.
# ⚠ REBASE WATCH: if upstream ever grants this appId itself, apply(int) also throws on debuggable
#   (checkState(grantedPermissions.get(appId) == null)). Re-check on every GrapheneOS rebase.
#
# Idempotent; aborts loudly if the anchor moves. Endospore-only -- GosPackageState does not exist on
# LineageOS, which is why the chooser side is all reflection and no-ops on Diaspore.
set -euo pipefail
T="${1:?usage: gos-chooser-grant.sh <graphene-tree>}"

# MASK ASSERTION (NWP-20261014-38; docs/gos-package-state-roam.md "Rebase watch" item 2). The editor is atomic
# (fact 8): one retired or unknown flag index in a write makes the package's whole apply write NOTHING, so a
# rebase that retires an index inside GosState.MASK silently stops every roamed hardening setting. Every set
# bit of MASK must therefore be a LIVE index of the upstream enum. This runs BEFORE the "already present"
# exit below on purpose: the patch is idempotent and re-run on every build, and a rebase changes the enum
# under an already-patched tree -- the exact case this exists to catch.
GOS_STATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../core/chooser/src/com/nowhere/chooser/GosState.java"
FLAGS=$(find "$T/frameworks/base" -name GosPackageStateFlag.java 2>/dev/null) || FLAGS=""
if [ -z "$FLAGS" ] || [ "$(printf '%s\n' "$FLAGS" | wc -l)" -ne 1 ]; then
  echo "[gos-chooser-grant] CANNOT DETERMINE the live flag indices: want exactly one GosPackageStateFlag.java under $T/frameworks/base, found: ${FLAGS:-none}"
  exit 2
fi
python3 - "$FLAGS" "$GOS_STATE" <<'PY'
import re, sys
flags_path, state_path = sys.argv[1], sys.argv[2]
try:
    state = open(state_path, encoding='utf-8').read()
except OSError:
    print("[gos-chooser-grant] CANNOT DETERMINE the carry mask: cannot read %s" % state_path); sys.exit(2)
m = re.search(r'static final long MASK = 0x([0-9A-Fa-f]+)L;', state)
if not m:
    print("[gos-chooser-grant] CANNOT DETERMINE the carry mask: no `static final long MASK = 0x...L;` in %s" % state_path); sys.exit(2)
mask = int(m.group(1), 16)
src = open(flags_path, encoding='utf-8').read()
src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
src = re.sub(r'//[^\n]*', '', src)
live = {int(v) for _, v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+)\b', src)}
consts = len(re.findall(r'\b[A-Za-z_][A-Za-z0-9_]*\s*=\s*\d+\b', src))
for b in range(mask.bit_length()):
    if mask >> b & 1 and b not in live:
        print("[gos-chooser-grant] MASK BIT %d (0x%x in GosState.MASK) is NOT a live index in %s -- a retired index makes the whole package apply write nothing; see docs/gos-package-state-roam.md 'Rebase watch' item 2" % (b, mask, flags_path))
        sys.exit(2)
print("[gos-chooser-grant] mask 0x%x ⊆ live flag indices (%d constants)" % (mask, consts))
PY

F="$T/frameworks/base/services/core/java/com/android/server/pm/GosPackageStatePermissions.java"
[ -f "$F" ] || { echo "[gos-chooser-grant] MISSING $F"; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

MARK = 'com.nowhere.chooser'
if MARK in s:
    print("[gos-chooser-grant] chooser grant already present -- skipped"); sys.exit(0)

# Anchor on the END of the Settings grant: it is the block that defines settingsReadWriteFlags' use, so
# inserting immediately after it keeps the variable in scope and puts our grant beside the one it mirrors.
anchor = '''                .apply(ksp.settings, computer);

        userManager = Objects.requireNonNull(LocalServices.getService(UserManagerInternal.class));'''

new = '''                .apply(ksp.settings, computer);

        // Nowhere (NWP-20260821-17): the chooser captures these flags at logoff and replays them at the next
        // login, so a per-app hardening setting survives the amnesiac roam (every login mints a NEW user, so
        // without this every such setting is silently back to default). Same-user only: the chooser does both
        // halves from inside the roamed user, so it needs no cross-user permission. Deliberately NOT granted:
        // playIntegrityFlags (bit 26 is derived usage bookkeeping, not a setting) and the storage/contact
        // scope fields (their blobs embed the source user id / raw contacts-DB row ids and cannot roam).
        // filterRead() masks reads to exactly what is granted, so this list IS the carry allowlist.
        builder()
                .readWriteFlags(settingsReadWriteFlags)
                .apply("com.nowhere.chooser", computer);

        userManager = Objects.requireNonNull(LocalServices.getService(UserManagerInternal.class));'''

if anchor not in s:
    print("[gos-chooser-grant] PATCH ANCHOR NOT FOUND (upstream changed?) -- aborting"); sys.exit(2)

s = s.replace(anchor, new, 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("[gos-chooser-grant] granted com.nowhere.chooser readWrite on settingsReadWriteFlags (same-user only)")
PY
