#!/bin/bash
# NWP-20260822-17 -- DIAGNOSTIC ONLY. NOT A SHIPPING PATCH. DO NOT ADD TO THE BUILD.
#
# Why this exists: the "To unpin this app, swipe up & hold" toast repeats throughout a pinned logoff with no
# user input, and LOGCAT CANNOT SEE IT. LockTaskController.showLockTaskToast() calls
# statusBarService.showPinningEscapeToast() and logs nothing on success -- only on RemoteException. So the
# "zero toast events" reading that made me think NWP-20260822-18 had closed this was meaningless; the thing
# being counted could never appear.
#
# The toast has six call sites (LockTaskController.java :301 :312 :352 :370 :511 and
# ActivityClientController.showLockTaskEscapeMessage). Only :301 and :511 log, and :301's log ("Not finishing
# task in lock task mode") is ABSENT from the capture -- so a blocked finish is ruled out and the live
# candidates are all silent. Rather than add a log to each and guess which, log ONCE inside the toast itself
# WITH A STACK TRACE: that names the exact caller in a single logoff, whichever it is.
#
# THIS DIRECTORY IS DELIBERATELY NOT `build/patches/`. build-device.sh globs
# `editions/endospore/build/patches/*.sh` and would apply this to every image, shipping a stack-dumping
# framework to users. Keep diagnostics out of that glob.
#
# Usage:   bash nwp-20260822-17-locktask-toast-trace.sh <tree>            # apply
#          bash nwp-20260822-17-locktask-toast-trace.sh <tree> --revert   # remove
# Then:    a full `m` (framework -> services.jar), flash, reproduce one logoff, and read:
#          logcat -b all | grep -A25 "NowhereDiag17"
set -e
TREE="${1:?usage: $0 <tree> [--revert]}"
MODE="${2:-apply}"
F="$TREE/frameworks/base/services/core/java/com/android/server/wm/LockTaskController.java"
[ -f "$F" ] || { echo "no LockTaskController at $F" >&2; exit 1; }

MARK='NowhereDiag17'

if [ "$MODE" = "--revert" ]; then
  if grep -q "$MARK" "$F"; then
    sed -i "/$MARK/d" "$F"
    echo "reverted: diagnostic removed from LockTaskController"
  else
    echo "already clean (no diagnostic present)"
  fi
  exit 0
fi

if grep -q "$MARK" "$F"; then echo "already applied (no change)"; exit 0; fi

# Anchor on the guard inside showLockTaskToast. Matching the METHOD plus its guard rather than the guard alone
# matters: LOCK_TASK_MODE_PINNED is compared in several places in this file.
python3 - "$F" "$MARK" <<'PY'
import io, sys
path, mark = sys.argv[1], sys.argv[2]
s = io.open(path, encoding='utf-8').read()
anchor = ("    void showLockTaskToast() {\n"
          "        if (mLockTaskModeState == LOCK_TASK_MODE_PINNED) {\n")
if s.count(anchor) != 1:
    sys.exit("anchor not found exactly once in showLockTaskToast -- upstream changed, patch by hand")
inject = anchor + ('            android.util.Slog.i("%s", "pinning escape toast -- who called?", '
                   'new Throwable("caller"));\n' % mark)
io.open(path, 'w', encoding='utf-8', newline='\n').write(s.replace(anchor, inject, 1))
print("applied: stack-dumping Slog inside showLockTaskToast")
PY
