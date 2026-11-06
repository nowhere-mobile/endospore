#!/usr/bin/env bash
# libselinux-pkgdir-uid-aliasing.sh -- fix pkgdir_selabel_lookup() corrupting the package-info cache
# (DIA-20260806-15). Idempotent; re-applied on every build like the other patches here.
#
# THE BUG (upstream libselinux, reachable on any Android device via `restorecon -D`):
#
#   external/selinux/libselinux/src/android/android_device.c, pkgdir_selabel_lookup():
#       info = package_info_lookup(pkgname);        <- pointer INTO the process-global pkgTab hash
#       ...
#       info->uid += userid_from_path * AID_USER_OFFSET;
#
# package_info_lookup() returns a borrowed pointer into a cache parsed once per process from
# /data/system/packages.list. The `+=` was meant as a local adjustment but writes back into that shared
# entry, so the Nth lookup of a given package within one restorecon process yields
#
#       uid = appid + N * userid * AID_USER_OFFSET
#
# i.e. a derived userid of N x the real one. seapp_context_lookup() turns that into MCS categories, so a
# single `restorecon -R -D /data/user/10/<pkg>` walks c522 -> c532 -> c542 -> ... +10 per entry in fts order.
#
# Measured on lynx 2026-08-06: 743/798 CE entries and 446/500 DE entries mislabelled, across 202 of 202
# category-bearing packages. Launcher3, contacts, MTP and cellbroadcast all crashed with SQLiteCantOpen /
# "Permission denied" on their own databases, because the app's process context (c522) no longer dominated
# its own files (c532, c542, c662, ...).
#
# It hides well for three reasons, all of which we hit:
#   - installd never executes the branch: it calls selinux_android_restorecon_pkgdir() WITH seinfo, and the
#     mutation sits inside `if (!seinfo)`. Only the /system/bin/restorecon CLI reaches it.
#   - user 0 is immune: userid_from_path is 0, so the added term is 0 and nothing drifts. Any comparison
#     against an unroamed device therefore looks clean.
#   - restorecon is self-consistent: a fresh process rebuilds the cache and re-derives the SAME corrupted
#     sequence, so `restorecon -n` reports nothing to change. The corruption is a fixed point of its own walk.
#
# THE FIX: compute into a local instead of mutating the cached entry. One statement, no behaviour change for
# any correct caller. Worth reporting upstream.
# It refuses (exit 1, file untouched) a tree with no 'info ? info->uid : uid' read site to redirect (NWP-20261026-16).
set -euo pipefail
T="${1:?usage: libselinux-pkgdir-uid-aliasing.sh <graphene-tree>}"
F="$T/external/selinux/libselinux/src/android/android_device.c"
[ -f "$F" ] || { echo "[libselinux-uid] MISSING $F"; exit 1; }

python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

if 'nowhere_resolved_uid' in s:
    print("[libselinux-uid] already applied")
    raise SystemExit(0)

mutate = "\t\tinfo->uid += userid_from_path * AID_USER_OFFSET;"
if mutate not in s:
    print("[libselinux-uid] ERROR: the mutating statement was not found -- upstream changed, re-check by hand")
    raise SystemExit(1)

# 1. declare the local inside pkgdir_selabel_lookup() SPECIFICALLY.
#
# `struct pkg_info *info = NULL;` appears in more than one function in this file. Anchoring on the first
# occurrence put the declaration in package_info_init() and the build failed with "use of undeclared
# identifier" at the three use sites -- a local declared in the wrong function is invisible, not wrong-looking.
# Anchor to the function signature, then take the FIRST declaration after it.
fn = "static int pkgdir_selabel_lookup("
fn_at = s.find(fn)
if fn_at < 0:
    print("[libselinux-uid] ERROR: pkgdir_selabel_lookup() not found -- upstream changed, re-check by hand")
    raise SystemExit(1)
decl_old = "\tstruct pkg_info *info = NULL;"
decl_at = s.find(decl_old, fn_at)
if decl_at < 0:
    print("[libselinux-uid] ERROR: no pkg_info declaration inside pkgdir_selabel_lookup()")
    raise SystemExit(1)
# ...and it must precede the statement we are about to change, or we are editing the wrong function.
if decl_at > s.find(mutate):
    print("[libselinux-uid] ERROR: declaration site is after the mutation site -- anchors are wrong")
    raise SystemExit(1)
ins = decl_at + len(decl_old)
s = (s[:ins]
     + "\n\t/* nowhere (DIA-20260806-15): resolve into a LOCAL. info points into the process-global\n"
       "\t * pkgTab cache, so adjusting info->uid in place made every later lookup of the same package\n"
       "\t * in this process see an accumulated userid, and stamp drifting MCS categories. */\n"
       "\tuid_t nowhere_resolved_uid = uid;"
     + s[ins:])

# 2. stop mutating the cache entry
s = s.replace(mutate, "\t\tnowhere_resolved_uid = info->uid + userid_from_path * AID_USER_OFFSET;", 1)

# 3. every read of the adjusted uid uses the local
n = s.count("info ? info->uid : uid")
if n == 0:
    print("[libselinux-uid] ERROR: no 'info ? info->uid : uid' read site found -- upstream changed, re-check by hand")
    raise SystemExit(1)
s = s.replace("info ? info->uid : uid", "nowhere_resolved_uid")
open(p, 'w', encoding='utf-8', newline='').write(s)
print(f"[libselinux-uid] patched: cache mutation removed, {n} read site(s) redirected to the local")
PY
