#!/usr/bin/env bash
# test-keepset-uninstall.sh [<ProfileActivity.java>] [--mutate] -- a keep line must not outlive its app.
#
# WHY THIS IS COMMITTED. The keep-set is what ROAMS, so a line for an app that no longer exists is permanent:
# "Your data" computes keptSetForDelta() minus the #apps head, so a phantom line reads "Not saved yet: <app>"
# on every visit, forever, and no roam clears it. CLEAN-ROOM PROVEN on lynx 2026-09-04 (fresh profile, one
# Aurora app, NWP-20260904-06): install -> set on-demand -> uninstall -> logoff -> login left the line intact
# with the package absent from PM entirely.
#
# THE PRUNE HAS TWO INDEPENDENT INPUTS AND BOTH MATTER, which is what these checks pin:
#   * seen  -- "was it here?", a receipt that only ever GROWS. It cannot notice a departure, and two doors
#              wrote a keep line without ever recording a sighting (a Play/Aurora/sideload heal, and the
#              Your-apps mode toggle), so for those the prune's FIRST clause was false forever.
#   * gone  -- "did it leave?", the PACKAGE_REMOVED transition itself. Needs no receipt.
# Dropping either one re-opens the bug from a different side, so both are asserted here.
#
# AND pmKnows MUST SURVIVE IN THE CONDITION. It is the only thing separating "the user removed it" from
# "on-demand, not materialised yet" -- an archived placeholder stays KNOWN to PM. Without it a prune would
# delete the very on-demand opt-ins the keep-set exists to hold, which is the regression NWP-20260821-15's
# closing condition names.
#
#   bash test-keepset-uninstall.sh            # the invariants
#   bash test-keepset-uninstall.sh --mutate   # ... plus mutations that must each CONVICT the suite
#
# Source-level checks on FUNCTIONAL forms (never comment text), same committed style as
# test-captureperms-keepset.sh -- the chooser has no unit-test harness.
# Every temp lives under one EXIT-trapped root ($W), so a pass, a failed check and --mutate leave nothing behind.
set -uo pipefail
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(dirname "$0")"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
RCV="$HERE/src/com/nowhere/chooser/AppInstallReceiver.java"
STO="$HERE/src/com/nowhere/chooser/StoreInstaller.java"
APP="$HERE/src/com/nowhere/chooser/NowhereApp.java"

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "pass" >/dev/null 2>&1; then PY=$c; break; fi
done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").

body(){ awk "/$1/,/$2/" "$SUT"; }
CODE=$(body 'private void captureAppCode\(\) \{' 'private void capturePrefs\(\) \{')
MODES=$(body 'private java.util.Set<String> writeAppModes\(' 'private java.util.Set<String> setAppMode\(')
DROPS=$(body 'private void captureAppDrops\(\) \{' 'private void captureAppCode\(\) \{')
LOGOFF=$(body 'private void doLogoffImpl\(final boolean forInstall\) \{' 'private void doColdLock\(\) \{')
[ -n "$CODE" ] && [ -n "$MODES" ] && [ -n "$DROPS" ] && [ -n "$LOGOFF" ] || { echo "EXTRACTION FAILED -- method anchors moved in $SUT" >&2; exit 2; }

echo "== the prune fires on a WATCHED DEPARTURE, not only on a receipt sighting =="
if grep -q 'gone.contains(pkg)' <<<"$CODE"; then
  ok "a package observed leaving is eligible to be pruned"
else
  no "the prune is receipt-only again -- a keep line written by a door that records no sighting outlives its app FOREVER"
fi
if grep -q 'seen.contains(pkg)' <<<"$CODE"; then
  ok "the receipt sighting is still honoured too (both inputs, not one)"
else
  no "the receipt input was dropped -- the seen-then-absent case regresses"
fi
if grep -q 'StoreInstaller.appGoneThisSession(this)' <<<"$CODE"; then
  ok "the departure set is actually read"
else
  no "nothing populates gone -- the clause above can never fire"
fi

echo "== pmKnows still gates the prune (an archived placeholder must NOT be pruned) =="
if grep -q '!pmKnows(pm, pkg)' <<<"$CODE"; then
  ok "only a package PM can no longer see is dropped"
else
  no "pmKnows is gone -- an on-demand placeholder now reads as removed and its opt-in is DELETED"
fi

echo "== a keep line is a claim, so writing one records the sighting =="
# The GUARD is asserted, not just the call: a first cut grepped for the call alone, and the mutation that
# disables it (`if (false) StoreInstaller.snapshotAppSeen(...)`) left that substring intact and was NOT
# CONVICTED. Pin the whole conditional so the only way to pass is to actually run it.
if grep -q 'if (!sighted.isEmpty()) StoreInstaller.snapshotAppSeen(this, sighted);' <<<"$MODES"; then
  ok "writeAppModes records a sighting for the packages it claims"
else
  no "the Your-apps toggle writes a claim with no sighting -- the door the clean-room repro came through"
fi
if grep -q 'if (pmKnows(pm, p)) sighted.add(p);' <<<"$MODES"; then
  ok "... and only for packages PM can actually see"
else
  no "the sighting is recorded unconditionally -- a line for an absent package would later read as was-here-now-gone"
fi
if grep -q 'noteAppSeen(ctx, pkg);' "$STO"; then
  ok "the install-time claim (keepAutoImpl) records a sighting too"
else
  no "a Play/Aurora/sideload heal still writes a claim with no sighting"
fi

echo "== the removal receiver: registered, and guarded =="
if grep -q 'f.addAction(android.content.Intent.ACTION_PACKAGE_REMOVED);' "$APP"; then
  ok "ACTION_PACKAGE_REMOVED is registered AT RUNTIME (a manifest receiver never fires for it)"
else
  no "the removal action is not registered -- the receiver can never run"
fi
if grep -q 'StoreInstaller.noteAppGone(context, gone);' "$RCV"; then
  ok "the receiver records the departure"
else
  no "the receiver does not record anything"
fi
if grep -q 'if (intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return;' "$RCV"; then
  ok "an UPDATE (removed+added) is ignored -- it must not un-keep an app the user still has"
else
  no "EXTRA_REPLACING is not checked -- every app update would drop its keep line"
fi
if grep -q 'android.intent.extra.ARCHIVAL' "$RCV"; then
  ok "an ARCHIVAL removal is ignored -- parking an on-demand app is not an uninstall"
else
  no "an archive now reads as an uninstall -- it would delete the on-demand opt-in it just parked"
fi
if grep -q 'if (ProfileActivity.pmKnows(context.getPackageManager(), gone)) return;' "$RCV"; then
  ok "a package PM still knows is not recorded as gone (belt-and-braces with the archival flag)"
else
  no "nothing re-checks PM -- an archived placeholder could be recorded as gone"
fi

# lineof <text> <ERE>: the line number of the ONLY line of <text> matching <ERE>; empty when it is absent or repeated.
lineof(){ local hits; hits=$(grep -nE "$2" <<<"$1" | cut -d: -f1); [ -n "$hits" ] && [ "$(wc -l <<<"$hits")" -eq 1 ] && echo "$hits"; }

echo "== a Settings/launcher uninstall reaches the drop list (NWP-20261109-20) =="
# The keep-set prune is the drop-list source for an uninstall: it records the gone app as turned off, and
# captureAppDrops, which runs right after it at sign-out, unions that record into nowhere-appdrop.list. roamd's
# ks_stage_drop then stages the list so keystore_push drops the app's <pkg>.keys. Every ERE is anchored on the
# statement, so a commented-out line never matches.
a=$(lineof "$CODE" 'uninstalled\.add\(pkg\);')
r=$(lineof "$CODE" '^[[:space:]]*for \(String pkg : uninstalled\) recordTurnedOff\(pkg\);')
k=$(lineof "$CODE" '^[[:space:]]*removeKeepLines\(drop\);')
if [ -n "$a" ] && [ -n "$r" ] && [ -n "$k" ] && [ "$a" -lt "$r" ] && [ "$r" -lt "$k" ]; then
  ok "U1 the prune records an uninstalled kept app as turned off, before it removes the keep line"
else
  no "U1 the prune no longer records an uninstalled kept app as turned off before it removes the keep line -- captureAppDrops cannot name it, so its data and its <pkg>.keys keep roaming"
fi
c=$(lineof "$LOGOFF" '^[[:space:]]*captureAppCode\(\);')
d=$(lineof "$LOGOFF" '^[[:space:]]*captureAppDrops\(\);')
if [ -n "$c" ] && [ -n "$d" ] && [ "$c" -lt "$d" ]; then
  ok "U2 sign-out runs the prune (captureAppCode) before captureAppDrops"
else
  no "U2 captureAppDrops runs before the prune has recorded the uninstall (or one of the two is missing) -- that sign-out drops nothing for it"
fi
e=$(lineof "$DROPS" '^[[:space:]]*final java\.util\.LinkedHashSet<String> explicitOff = explicitlyTurnedOff\(\);')
l=$(lineof "$DROPS" '^[[:space:]]*for \(String p : explicitOff\) \{')
lb=""; [ -n "$l" ] && lb=$(awk -v s="$l" 'NR>s && /^            }$/ {exit} NR>s' <<<"$DROPS")
if [ -n "$e" ] && [ -n "$l" ] && grep -qF "sb.append(p).append('\n');" <<<"$lb"; then
  ok "U3 captureAppDrops unions nowhere-appoff.list (explicitlyTurnedOff) into the drop list"
else
  no "U3 captureAppDrops no longer unions nowhere-appoff.list -- neither an Off of an archived app nor a pruned uninstall reaches the drop list"
fi

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  [ -n "$PY" ] || echo "  SKIP  mutations: no working python on PATH" >&2
  mutate(){
    [ -n "$PY" ] || { no "MUTATION UNRUN (no python): $1"; return; }
    if ! "$PY" -c "
import io,sys
p,out=sys.argv[1],sys.argv[2]
s=io.open(p,encoding='utf-8',newline='').read()
$2
io.open(out,'w',encoding='utf-8',newline=chr(10)).write(s)
" "$SUT" "$M/m.java"; then no "MUTATION BROKEN: $1"; return; fi
    if cmp -s "$SUT" "$M/m.java"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/m.java" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "the departure clause is removed (back to receipt-only -- the filed bug)" \
    "s=s.replace('if ((seen.contains(pkg) || gone.contains(pkg)) && !pmKnows(pm, pkg))','if (seen.contains(pkg) && !pmKnows(pm, pkg))',1)"
  mutate "pmKnows is dropped from the condition (an archived placeholder gets pruned)" \
    "s=s.replace('if ((seen.contains(pkg) || gone.contains(pkg)) && !pmKnows(pm, pkg))','if ((seen.contains(pkg) || gone.contains(pkg)))',1)"
  mutate "the Your-apps toggle stops recording its sighting" \
    "s=s.replace('if (!sighted.isEmpty()) StoreInstaller.snapshotAppSeen(this, sighted);','if (false) StoreInstaller.snapshotAppSeen(this, sighted);',1)"
  mutate "the sighting is recorded for packages PM cannot see" \
    "s=s.replace('for (String p : modes.keySet()) if (pmKnows(pm, p)) sighted.add(p);','for (String p : modes.keySet()) sighted.add(p);',1)"
  mutate "the uninstall prune stops recording the app as turned off (NWP-20261109-20)" \
    "s=s.replace('            for (String pkg : uninstalled) recordTurnedOff(pkg);\n','',1)"
  mutate "captureAppDrops runs before captureAppCode at sign-out (NWP-20261109-20)" \
    "a='captureAppCode(); // #199';b='captureAppDrops(); // DIA-20260804-04';s=s.replace(a,'@@A@@',1).replace(b,a,1).replace('@@A@@',b,1)"
  mutate "captureAppDrops drops its explicitOff union (NWP-20261109-20)" \
    "i=s.index('            for (String p : explicitOff) {\n');j=s.index('\n            }\n',i)+len('\n            }\n');s=s[:i]+s[j:]"
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
