#!/usr/bin/env bash
# subscription-user-filter.sh -- #176 picker parity (2026-07-23).
#
# The outbound SIM-lock (#176/#435) blocks a roamed owner from SENDING on a SIM it does not own (the
# SmsProvider refuses the insert for a sub associated with a different user). But the roamed Messages app
# (Bugle) STILL LISTED the unbound SIM in its per-conversation SIM picker -- selecting it just silently
# failed. Calls already hide it (Telecom PhoneAccounts are per-user), so this brings SMS to parity.
#
# ROOT CAUSE: SubscriptionManagerService.getActiveSubscriptionInfoList DOES filter by per-user association
# (getSubscriptionInfoStreamAsUser -> isSubscriptionAssociatedWithUserInternal), but that predicate short-
# circuits to `return true` (NO filtering) unless BOTH a feature flag (enforceSubscriptionUserFilter) AND a
# per-app compat change (FILTER_ACCESSIBLE_SUBS_BY_USER) are enabled -- both OFF here, so Bugle saw every sub.
#
# FIX: enforce the per-user filter for ROAMED (secondary) users regardless of the flag/compat gate, while
# EXEMPTING user 0 (the gate) + USER_ALL so they keep seeing EVERY subscription for cross-user inbound
# interception + SIM management. (Naively enabling the AOSP flag would instead HIDE the bound physical SIM
# from the gate, because we pin the unbound sub to user 0 -> the gate would count as "having its own sub".)
#
# Idempotent. OS-level patch (applies to the GrapheneOS tree); wired into the endospore build flow (README).
set -euo pipefail
T="${1:?usage: subscription-user-filter.sh <graphene-tree>}"
F="$T/frameworks/opt/telephony/src/java/com/android/internal/telephony/subscription/SubscriptionManagerService.java"
[ -f "$F" ] || { echo "[sub-user-filter] MISSING $F"; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = '''        if (!mFeatureFlags.enforceSubscriptionUserFilter()
                || !CompatChanges.isChangeEnabled(FILTER_ACCESSIBLE_SUBS_BY_USER,
                Binder.getCallingUid())) {
            return true;
        }'''
new = '''        // #176 (nowhere/endospore): user 0 (the gate) + system must see EVERY subscription for
        // cross-user inbound interception + SIM management; only ROAMED secondary users are filtered
        // to the SIM(s) bound to them, so a roamed SMS app lists only its bound SIM in the picker
        // (parity with how Telecom already hides a foreign SIM from the dialer). Enforce the per-user
        // filter for secondary users REGARDLESS of the AOSP feature flag / compat gate (both off by
        // default -> would return true here = no filtering, which is why Bugle still showed the eSIM).
        if (userId == UserHandle.USER_SYSTEM || userId == UserHandle.USER_ALL) {
            return true;
        }'''
# NWP-20261016-22: the already-applied test keys on the patch's OWN tag (line 0 of `new`), not on a generic
# Java statement a pristine tree can hold elsewhere; the tag must come with the whole block.
tag = new.splitlines()[0]
if tag in s:
    if new not in s:
        print("[sub-user-filter] DRIFT: the #176 tag is present but the full block is not (hand-edited or half-reverted tree) -- aborting")
        sys.exit(2)
    print("[sub-user-filter] already applied -- skipped")
    sys.exit(0)
n = s.count(old)
if n == 0:
    print("[sub-user-filter] PATCH ANCHOR NOT FOUND (upstream changed?) -- aborting")
    sys.exit(2)
if n > 1:
    print("[sub-user-filter] PATCH ANCHOR FOUND %d TIMES (expected exactly 1) -- aborting, file untouched" % n)
    sys.exit(2)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
print("[sub-user-filter] patched isSubscriptionAssociatedWithUserInternal (roamed-user SMS picker filter)")
PY
