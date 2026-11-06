#!/usr/bin/env bash
# test-install-heal.sh [--mutate] -- the install-heal's three load-bearing choices (NWP-20260903-11).
#
# WHY THIS IS COMMITTED. The heal spans three files in two languages, and each of its choices reverses a
# plausible-looking "cleanup":
#   1. roamd's odrestore PROBES the hold before force-stopping. Un-gating the kill reads as simplification
#      and turns every plain Play install into a visible app kill; gating it on the WRONG condition quietly
#      re-opens the Ring clobber (a gap process flushing its first-run state over the restored data).
#   2. The receiver fires the heal ON UPDATES TOO (EXTRA_REPLACING). "Skip updates like decide() does" is
#      exactly the symmetry a refactor would impose -- and an install over the ARCHIVED PLACEHOLDER is a
#      replacement, so imposing it re-orphans the row's own core case.
#   3. The marker is written on every OK so a later tap LAUNCHES instead of downgrade-installing the sealed
#      APK over the newer one.
#   4. NWP-20261012-04: the marker is no longer a downgrade guard at all. An app that HAS code -- whoever installed
#      it: the App store, Play, Aurora, a sideload, or our own materialise -- is never fetched or installed again, by
#      the sweep, a queued tap or a group's dep list; if its restore is unconfirmed it gets a RESTORE-ODDATA retry
#      only. That is the "retry without re-downloading or re-installing the APK" NWP-20260923-01 requires. Chester,
#      2026-10-12: "installed an app from Appstore, when to your apps and clicked on install - its reinstalling it".
#      The decision (autoAction) and the sweep's split (splitAuto) are pure and run under javac
#      (core/chooser/tests/install-pending); their call sites are pinned here.
# No compiler sees most of this: Go, Java and shell each hold a part of the contract.
#
# ⚠ THE JAVAC HALF FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's
# JDK; the CI runner is the build VM, which has it. Its version is printed so the log proves which compiler ran.
#
#   bash test-install-heal.sh            # the invariants
#   bash test-install-heal.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; esac; done
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ROAMD="${TEST_ROAMD:-$ROOT/core/vendor-common/bin/nowhere_roamd.sh}"
RECV="${TEST_RECV:-$ROOT/core/chooser/src/com/nowhere/chooser/AppInstallReceiver.java}"
AGENT="${TEST_AGENT:-$ROOT/core/agent/app_code.go}"
UNARCH="${TEST_UNARCH:-$ROOT/core/chooser/src/com/nowhere/chooser/UnarchiveService.java}"
PENDING_RUN="$ROOT/core/chooser/tests/install-pending/run.sh"
for f in "$ROAMD" "$RECV" "$AGENT" "$UNARCH" "$PENDING_RUN"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }; done
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA

PASS=0; FAIL=0
# One root holds every temp: the pending output, the mutant dir and the temps of every child this suite runs (each
# is given TMPDIR="$W"), so a run that passes, fails or convicts leaves nothing behind.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match below reads its input to the end: a here-string (`grep -q PAT <<<"$var"`) or
# `grep -c PAT >/dev/null` on a pipe, never `cmd | grep -q`. Under pipefail grep -q exits at its first match,
# the producer can die of SIGPIPE, and the pipeline fails: an absence check then passes on the code it exists
# to reject, a presence check goes red at random (docs/backlog.md, "pipes into grep -q under pipefail").

echo "== roamd: the kill is gated on a hold existing =="
# Extract odrestore from its case label to the force-stop, and demand the probe precede the kill.
BLOCK=$(sed -n '/^  odrestore)$/,/odn=0; odsrc=0/p' "$ROAMD")
case "$BLOCK" in *odrestore*) ;; *) echo "EXTRACTION FAILED: odrestore" >&2; exit 2 ;; esac
PROBE=$(printf '%s\n' "$BLOCK" | grep -n '_hold=1' | head -1 | cut -d: -f1)
KILL=$(printf '%s\n' "$BLOCK" | grep -n 'am force-stop' | head -1 | cut -d: -f1)
if [ -n "$PROBE" ] && [ -n "$KILL" ] && [ "$PROBE" -lt "$KILL" ]; then
  ok "the hold probe precedes the force-stop (probe $PROBE < kill $KILL)"
else
  no "no hold probe before the kill (probe=$PROBE kill=$KILL) -- every plain install kills the app it just installed"
fi
if grep -q 'if \[ "\$_hold" = 1 \]; then' <<<"$BLOCK"; then
  ok "the force-stop runs only when a hold exists"
else
  no "the force-stop is unconditional again -- the no-hold path kills a possibly-open app for nothing"
fi

echo "== receiver: the heal fires on updates too, and marks on OK =="
if grep -q 'heal(context, pkg, replacing);' "$RECV"; then
  ok "heal is fired from the broadcast path with the replacing flag"
else
  no "heal is not fired from onReceive with replacing -- placeholder-replacing installs are re-orphaned"
fi
if grep -A3 'private static void heal' "$RECV" | grep -c 'replacing' >/dev/null; then :; fi
if grep -q 'if (replacing) return;' "$RECV" || grep -q '!replacing &&[^&]*heal' "$RECV"; then
  no "the heal skips EXTRA_REPLACING -- an install over the archived placeholder is a replacement, that IS the row"
else
  ok "nothing gates the heal on !replacing"
fi
if grep -q 'r.startsWith("OK")' "$RECV" && grep -q 'UnarchiveService.markOdRestored(context, pkg);' "$RECV"; then
  ok "the od-restored marker is written on OK (closes the downgrade half)"
else
  no "no marker write on OK -- the next tap materialises the sealed APK over the newer installed one"
fi

echo "== agent: the seal-suppression window is armed at RESTORE-ODDATA entry =="
# NWP-20261011-01 moved the arm into armOdLease (a per-package lease that only ever moves out: pinned by
# od_window_test.go's TestOdWindowLeasesExtendOnlyAndRespectTheEpoch). Here: the handler arms it, before the worker op.
# NWP-20261125-08: both sit in restoreOdOne, the per-package helper of the one-package and the list forms.
OD=$(sed -n '/^func restoreOdOne(/,/^}/p' "$AGENT")
case "$OD" in *restoreOdOne*) ;; *) echo "EXTRACTION FAILED: restoreOdOne" >&2; exit 2 ;; esac
ARM=$(grep -n '^[[:space:]]*armOdLease(pkg, ' <<<"$OD" | head -1 | cut -d: -f1)
RUN=$(grep -n 'odRestoreWorker(dest, "odrestore"' <<<"$OD" | head -1 | cut -d: -f1)
if [ -n "$ARM" ] && [ -n "$RUN" ] && [ "$ARM" -lt "$RUN" ]; then
  ok "the window is armed before the odrestore worker op (arm $ARM < op $RUN)"
else
  no "RESTORE-ODDATA does not arm the #204 window (arm=$ARM op=$RUN) -- a periodic seal can queue ahead of the install-heal's reunite"
fi

echo "== chooser: an app that has code is never fetched or reinstalled (NWP-20261012-04) =="
"$JAVAC" -version 2>&1 | sed 's/^/  /'
TMPDIR="$W" bash "$PENDING_RUN" "$UNARCH" > "$W/pending.out" 2>&1; prc=$?
sed 's/^/  /' "$W/pending.out"
case "$prc" in
  0) ok "autoAction + splitAuto: the cases pass under javac" ;;
  1) no "autoAction / splitAuto: a case failed (above)" ;;
  *) echo "EXTRACTION OR COMPILE FAILED: install-pending run.sh rc=$prc" >&2; exit 2 ;;
esac
# meth <name> -- one method of UnarchiveService.java, from its signature to its closing brace at 4 spaces.
meth(){ sed -n "/^    [a-z].* $1(/,/^    }\$/p" "$UNARCH"; }
# lineof <fixed string> <text> -- the first line number of the string in the text, empty when absent.
lineof(){ grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }
# lineafter <fixed string> <text> <line> -- the first line number of the string at or after <line>, empty when absent.
lineafter(){ [ -n "$3" ] || return 0; grep -nF -- "$1" <<<"$2" | awk -F: -v n="$3" '$1 >= n { print $1; exit }'; }
PEND=$(meth pendingAutoApps); SWEEP=$(meth sweepAuto); MAI=$(meth materializeAndInstall)
DEPS=$(meth pendingDeps); MLOCK=$(meth materializeLocked); RONLY=$(meth restoreOnlyLocked)
RTAIL=$(meth restoreOnlyReplied); RLIST=$(meth restoreOnlyListLocked)
for v in PEND SWEEP MAI DEPS MLOCK RONLY RTAIL RLIST; do
  [ -n "${!v}" ] || { echo "EXTRACTION FAILED: $v" >&2; exit 2; }
done
# 4a. The row and the sweep both read the list splitAuto returns, fed by the real code and restored reads.
if grep -qF 'java.util.List<String> work = splitAuto(ProfileActivity.autoKeepSet(ctx),' <<<"$PEND" \
   && grep -qF 'pkg -> hasInstalledCode(ctx, pkg),' <<<"$PEND" \
   && grep -qF 'pkg -> odRestored(ctx, pkg),' <<<"$PEND" \
   && grep -qF 'if (restoreOnly != null) restoreOnly.addAll(retry);' <<<"$PEND"; then
  ok "pendingAutoApps splits on code + the restored marker and hands the restore-only apps out separately"
else
  no "pendingAutoApps no longer splits through splitAuto on the real reads -- an installed app can count as pending"
fi
# 4b. The sweep retries the restore-only apps in chunks of OdRestoreList.CHUNK (NWP-20261128-16), under MAT_LOCK,
#     re-checking the REAL state under the lock, and never queues them as downloads. A chunk left with one app goes
#     through restoreOnlyLocked; two or more go as one list through restoreOnlyListLocked.
#     The lock and unlock are the first ones AFTER the loop line: NWP-20261122-11's remembered taps take MAT_LOCK above it.
RL=$(lineof 'for (int c = 0; c < retry.size(); c += OdRestoreList.CHUNK) {' "$SWEEP"); LK=$(lineafter 'MAT_LOCK.lock();' "$SWEEP" "$RL")
RO=$(lineof '== AUTO_RESTORE_ONLY) keep.add(pkg);' "$SWEEP"); UL=$(lineafter 'MAT_LOCK.unlock();' "$SWEEP" "$RL")
R1=$(lineof 'if (keep.size() == 1) restoreOnlyLocked(keep.get(0));' "$SWEEP")
RD=$(lineof 'else if (keep.size() > 1) restoreOnlyListLocked(keep);' "$SWEEP")
if [ -n "$RL" ] && [ -n "$LK" ] && [ -n "$RO" ] && [ -n "$R1" ] && [ -n "$RD" ] && [ -n "$UL" ] \
   && [ "$RL" -lt "$LK" ] && [ "$LK" -lt "$RO" ] && [ "$RO" -lt "$R1" ] && [ "$R1" -lt "$RD" ] && [ "$RD" -lt "$UL" ] \
   && grep -qF 'pendingAutoApps(this, true, retry);' <<<"$SWEEP" \
   && grep -qF 'if (autoAction(hasInstalledCode(pkg), odRestored(pkg), false)' <<<"$SWEEP"; then
  ok "the sweep retries the restore-only apps under MAT_LOCK, re-checked under it (loop $RL < lock $LK < keep $RO < one $R1 < list $RD < unlock $UL)"
else
  no "the sweep's restore-only retry is missing, unlocked, or not re-checked (loop=$RL lock=$LK keep=$RO one=$R1 list=$RD unlock=$UL)"
fi
if grep -qE 'qEnqueue\((retry|restoreOnly)' <<<"$SWEEP"; then
  no "the sweep queues the restore-only apps as downloads"
else
  ok "the restore-only apps are not queued as downloads"
fi
# 4c. A queued item (sweep or tap) that has code returns before materializeLocked: retry, launch on a tap, leave the
#     queue, in that order, then return.
G=$(lineof 'if (action == AUTO_RESTORE_ONLY) {' "$MAI"); M=$(lineof 'boolean ok = materializeLocked(pkg, quiet);' "$MAI")
BR=""; [ -n "$G" ] && [ -n "$M" ] && BR=$(sed -n "${G},${M}p" <<<"$MAI")
GR=$(lineof 'restoreOnlyLocked(pkg);' "$BR"); GL=$(lineof 'if (!quiet) launchApp(pkg);' "$BR")
GQ=$(lineof 'qFinish(pkg);' "$BR"); GRET=$(lineof 'return true;' "$BR")
if grep -qF 'final int action = autoAction(code, code && odRestored(pkg), true);' <<<"$MAI" \
   && [ -n "$GR" ] && [ -n "$GL" ] && [ -n "$GQ" ] && [ -n "$GRET" ] \
   && [ "$GR" -lt "$GL" ] && [ "$GL" -lt "$GQ" ] && [ "$GQ" -lt "$GRET" ]; then
  ok "materializeAndInstall: an item with code retries, opens on a tap, leaves the queue, returns before materializeLocked"
else
  no "materializeAndInstall's restore-only branch is broken (retry=$GR launch=$GL qFinish=$GQ return=$GRET of guard $G..materialise $M)"
fi
# 4d. A dep with code is retried restore-only and never reaches the fetch list.
if grep -qF 'final int action = autoAction(code, code && odRestored(dep), false);' <<<"$DEPS" \
   && awk '/^ *if \(action == AUTO_RESTORE_ONLY\) \{$/{g=1} g && /^ *restoreOnly\.add\(dep\);$/{getline; if ($0 ~ /^ *continue;$/) f=1; exit} END{exit !f}' <<<"$DEPS" \
   && grep -qF 'for (String dep : depRestoreOnly) restoreOnlyLocked(dep);' <<<"$MLOCK"; then
  ok "pendingDeps: a dep with code is restore-only, never fetched"
else
  no "pendingDeps can re-fetch and reinstall a dep that has code"
fi
# 4e. The restore-only retry fetches and installs nothing, and marks only on OK. NWP-20261128-16: the one-name request
#     (restoreOnlyLocked) and the list (restoreOnlyListLocked) both hand each app's reply to restoreOnlyReplied.
if grep -qF 'String rr = daemon("RESTORE-ODDATA\n" + pkg + "\n");' <<<"$RONLY" \
   && grep -qF 'return restoreOnlyReplied(pkg, rr);' <<<"$RONLY" \
   && grep -qF 'boolean ok = rr != null && rr.startsWith("OK");' <<<"$RTAIL" \
   && grep -qF 'if (ok) markOdRestored(pkg);' <<<"$RTAIL"; then
  ok "restoreOnlyLocked sends RESTORE-ODDATA and restoreOnlyReplied marks only on OK"
else
  no "restoreOnlyLocked no longer sends RESTORE-ODDATA, or restoreOnlyReplied marks without an OK"
fi
if grep -qF 'DaemonSocket.roundTripLines(OdRestoreList.request(keep), 130000)' <<<"$RLIST" \
   && grep -qF 'restoreOnlyReplied(pkg, replies.get(pkg));' <<<"$RLIST"; then
  ok "restoreOnlyListLocked sends one RESTORE-ODDATA list and gives each app its own reply"
else
  no "restoreOnlyListLocked no longer sends the list, or does not give each app its own reply"
fi
if grep -qE 'installApks|daemonMaterialize|MATERIALIZE-APP|materializeMember|materializeLocked' <<<"$RONLY$RTAIL$RLIST"; then
  no "the restore-only retry fetches or installs -- the restore-only retry IS a reinstall"
else
  ok "the restore-only retry fetches and installs nothing"
fi

# 4f. An app the restore-only retry handed back is woken when its wake rule says so (NWP-20261012-06's
#     wakeOnRestore: the user's Your apps choice, else the messaging rule), as materializeLocked does: odrestore force-stops
#     an app whose hold it returns, and a stopped app gets no FCM until opened. After the marker, only on OK.
MK=$(lineof 'if (ok) markOdRestored(pkg);' "$RTAIL"); WK=$(lineof 'if (ok && wakeOnRestore(this, pkg)) unstop(this, pkg);' "$RTAIL")
if [ -n "$MK" ] && [ -n "$WK" ] && [ "$MK" -lt "$WK" ]; then
  ok "restoreOnlyReplied wakes a messaging app after a confirmed restore (mark $MK < wake $WK)"
else
  no "restoreOnlyReplied does not wake a restored messaging app (mark=$MK wake=$WK) -- it stays force-stopped, no FCM"
fi
# 4g. The sweep returns early only when BOTH lists are empty: Chester's case is a profile whose only outstanding app
#     is a store install with an unconfirmed restore, so its work list is empty and its retry list is not.
if grep -qE '^        if \(work\.isEmpty\(\) && retry\.isEmpty\(\)\) \{ android\.util\.Log\.i\("NowhereChooser", "#130 sweep: nothing to materialise"\); return; \}$' <<<"$SWEEP"; then
  ok "the sweep's early return needs both the install and the restore-only list empty"
else
  no "the sweep's early return is not exactly 'work AND retry empty' -- a store install alone is never retried"
fi
# 4h. A whole app or dep is skipped, never re-fetched (DIA-20260804: a whole gms re-fetched on every tap), and the
#     sweep's placeholder read is the real archived-package lookup (a constant true sweeps gms/gsf alone).
if awk '/^            if \(action == AUTO_WHOLE\) \{$/{g=1; next} g && /^ *return true;$/{f=1; exit} g && /^            \}$/{exit} END{exit !f}' <<<"$MAI"; then
  ok "materializeAndInstall: a whole item returns inside the AUTO_WHOLE branch"
else
  no "materializeAndInstall: the AUTO_WHOLE fast path is gone -- a whole app falls through to a reinstall"
fi
if awk '/^            if \(action == AUTO_WHOLE\) \{$/{g=1; next} g && /^ *continue;$/{f=1; exit} g && /^            \}$/{exit} END{exit !f}' <<<"$DEPS"; then
  ok "pendingDeps: a whole dep is skipped inside the AUTO_WHOLE branch"
else
  no "pendingDeps: the AUTO_WHOLE skip is gone -- a whole gms is re-fetched on every tap"
fi
if grep -qF 'try { return ctx.getPackageManager().getArchivedPackage(pkg) != null; } catch (Throwable t) { return false; }' <<<"$PEND"; then
  ok "pendingAutoApps reads the placeholder from getArchivedPackage"
else
  no "pendingAutoApps' placeholder read is not the archived-package lookup -- launcher-less deps would be swept alone"
fi
if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){ # <name> <file-var> <sed>
    local src; eval src="\$$2"
    if ! sed "$3" "$src" > "$M/m" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$src" "$M/m"; then no "MUTATION INERT: $1"; return; fi
    local rc
    TMPDIR="$W" TEST_ROAMD="$ROAMD" TEST_RECV="$RECV" TEST_AGENT="$AGENT" TEST_UNARCH="$UNARCH" \
       env "TEST_$2=$M/m" bash "$0" >/dev/null 2>&1; rc=$?
    # 1 = a behaviour case or an invariant failed, the only result that convicts. 2 = an extraction or compile
    # failure, which proves nothing about the logic.
    case "$rc" in
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      1) ok "convicted: $1" ;;
      *) no "BROKEN MUTANT (rc=$rc): $1 -- it did not extract or compile, so it proves nothing" ;;
    esac
  }
  mutate "kill un-gated (every install force-stops the app)" ROAMD \
         's@^    if \[ "\$_hold" = 1 \]; then@    if true; then@'
  mutate "the hold probe sets a non-number (_hold=yes): the kill gate reads no hold" ROAMD \
         's@{ _hold=1; break; }@{ _hold=yes; break; }@'
  mutate "heal gated on !replacing (placeholder installs re-orphaned)" RECV \
         's@private static void heal(Context context, String pkg, boolean replacing) {@private static void heal(Context context, String pkg, boolean replacing) { if (replacing) return;@'
  mutate "marker write dropped (the downgrade path returns)" RECV \
         's@if (r.startsWith("OK")) UnarchiveService.markOdRestored(context, pkg);@// dropped@'
  mutate "window arm dropped from RESTORE-ODDATA" AGENT \
         's@^\(\s*\)armOdLease(pkg, time.Now(), odFetchLease)@\1_ = odFetchLease@'
  # NWP-20261012-04: each is the reinstall of an installed app, or the restore never retried, by another route.
  mutate "autoAction: a missing marker means reinstall again (the bug)" UNARCH \
         's@if (hasCode) return restored ? AUTO_WHOLE : AUTO_RESTORE_ONLY;@if (hasCode) return restored ? AUTO_WHOLE : AUTO_INSTALL;@'
  mutate "autoAction: a missing marker is treated as whole (the restore never retried)" UNARCH \
         's@if (hasCode) return restored ? AUTO_WHOLE : AUTO_RESTORE_ONLY;@if (hasCode) return AUTO_WHOLE;@'
  mutate "autoAction: the restored marker is ignored (whole apps retried forever)" UNARCH \
         's@if (hasCode) return restored ? AUTO_WHOLE : AUTO_RESTORE_ONLY;@if (hasCode) return AUTO_RESTORE_ONLY;@'
  mutate "autoAction: an archived placeholder is no longer pending" UNARCH \
         's@return placeholder ? AUTO_INSTALL : AUTO_GROUP_DEP;@return AUTO_GROUP_DEP;@'
  mutate "splitAuto: restore-only apps counted as pending" UNARCH \
         's@else if (a == AUTO_RESTORE_ONLY) restoreOnly.add(pkg);@else if (a == AUTO_RESTORE_ONLY) work.add(pkg);@'
  mutate "pendingAutoApps: the restored marker is not consulted" UNARCH \
         's@pkg -> odRestored(ctx, pkg),@pkg -> false,@'
  mutate "pendingAutoApps: restore-only apps dropped, not retried" UNARCH \
         's@if (restoreOnly != null) restoreOnly.addAll(retry);@@'
  mutate "sweep: the restore-only retry is skipped" UNARCH \
         's@== AUTO_RESTORE_ONLY) keep.add(pkg);@== AUTO_RESTORE_ONLY) { }@'
  mutate "sweep: the restore-only retry runs without MAT_LOCK" UNARCH \
         '/for (int c = 0; c < retry.size(); c += OdRestoreList.CHUNK) {/,/^            }$/s@MAT_LOCK.lock();@/* unlocked */@'
  mutate "sweep: a chunk of two or more is never sent" UNARCH \
         's@else if (keep.size() > 1) restoreOnlyListLocked(keep);@@'
  mutate "sweep: the re-check under the lock reads constants, not the state" UNARCH \
         's@if (autoAction(hasInstalledCode(pkg), odRestored(pkg), false)@if (autoAction(true, false, false)@'
  mutate "sweep: restore-only apps queued as downloads" UNARCH \
         's@^        qEnqueue(work);@        qEnqueue(work); qEnqueue(retry);@'
  mutate "materializeAndInstall: the restore-only guard removed" UNARCH \
         's@if (action == AUTO_RESTORE_ONLY) {@if (false) {@'
  mutate "materializeAndInstall: the restored marker is not consulted" UNARCH \
         's@final int action = autoAction(code, code && odRestored(pkg), true);@final int action = autoAction(code, false, true);@'
  mutate "materializeAndInstall: the restore-only item never leaves the queue" UNARCH \
         '/if (action == AUTO_RESTORE_ONLY) {/,/return true;/s@^                qFinish(pkg);$@                /* no qFinish */@'
  mutate "materializeAndInstall: a tap on a restore-only item no longer opens it" UNARCH \
         '/if (action == AUTO_RESTORE_ONLY) {/,/return true;/s@^                if (!quiet) launchApp(pkg);$@                /* no launch */@'
  mutate "pendingDeps: a dep with code falls through to the fetch" UNARCH \
         's@^\( *\)restoreOnly.add(dep);$@\1restoreOnly.add(dep); out.add(dep);@'
  mutate "materializeLocked: the dep restore-only retry dropped" UNARCH \
         's@for (String dep : depRestoreOnly) restoreOnlyLocked(dep);@@'
  mutate "restoreOnlyReplied: marks without an OK" UNARCH \
         's@if (ok) markOdRestored(pkg);@markOdRestored(pkg);@'
  mutate "restoreOnlyReplied: fetches the sealed copy too" UNARCH \
         's@boolean ok = rr != null && rr.startsWith("OK");@boolean ok = rr != null \&\& rr.startsWith("OK"); daemonMaterialize(pkg);@'
  mutate "restoreOnlyReplied: a restored messaging app is left force-stopped" UNARCH \
         's@^        if (ok && wakeOnRestore(this, pkg)) unstop(this, pkg);$@@'
  mutate "restoreOnlyListLocked: the list's apps are not marked" UNARCH \
         's@restoreOnlyReplied(pkg, replies.get(pkg));@ @'
  mutate "restoreOnlyLocked: the one-name reply is never handed to the shared tail" UNARCH \
         's@return restoreOnlyReplied(pkg, rr);@return false;@'
  mutate "sweep: returns early on an empty install list alone (Chester's case never retried)" UNARCH \
         's@if (work.isEmpty() && retry.isEmpty()) {@if (work.isEmpty()) {@'
  mutate "materializeAndInstall: the AUTO_WHOLE fast path removed (whole apps reinstalled)" UNARCH \
         '/private boolean materializeAndInstall(/,/^    }$/s@if (action == AUTO_WHOLE) {@if (false) {@'
  mutate "pendingDeps: the AUTO_WHOLE skip removed (a whole gms re-fetched every tap)" UNARCH \
         '/private java.util.List<String> pendingDeps(/,/^    }$/s@if (action == AUTO_WHOLE) {@if (false) {@'
  mutate "pendingAutoApps: every app without code reads as a placeholder (gms/gsf swept alone)" UNARCH \
         's@try { return ctx.getPackageManager().getArchivedPackage(pkg) != null; } catch (Throwable t) { return false; }@return true;@'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
