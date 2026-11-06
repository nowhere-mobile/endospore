#!/usr/bin/env bash
# test-keep-order-java.sh [--mutate] -- "Your apps" order and "Wake for notifications", run under javac (NWP-20261012-06).
#
# WHY THIS IS COMMITTED. Two decisions of 2026-10-12 (docs/product-decisions.md) live in rules nothing else executes off
# a device. ORDER: kept apps are dragged into order in Your apps, and that order -- the line order of nowhere-appkeep,
# which roams with the profile -- is the order the automatic install works through; "Download first" is retired, its
# marks folded to the top of the keep order once. WAKE: a per-app check decides whether a restored app is taken out of
# Android's stopped state so push messages reach it; the default is the messaging rule, the user's choice is kept in
# nowhere-appwake. The rules are in core/chooser/src/com/nowhere/chooser/KeepOrder.java (pure Java), compiled as it
# stands with core/chooser/tests/keep-order/KeepOrderCases.java.
#
# THE CALL SITES ARE PINNED, AS BLOCKS. A correct rule called wrongly is the same bug (a sweep that still asks the
# messaging rule alone, a gate that hands over a failed restore, a drag that is never written). The pins below hold
# each wiring block byte for byte, and the call-site mutations at the end must each be convicted by one. The absence
# checks (no "Download first" left) each carry a control that must match, so a missing file cannot read as clean.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md).
# javac comes from PATH, else from the build host's JDK below; the CI runner is the build VM, which has it. The version
# is printed first so the log proves which compiler ran.
#
#   bash test-keep-order-java.sh            # the cases + the pins
#   bash test-keep-order-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
SRC="$DIR/KeepOrder.java"
STI="$DIR/StoreInstaller.java"
UNA="$DIR/UnarchiveService.java"
PRO="$DIR/ProfileActivity.java"
CHO="$DIR/ChooserActivity.java"
RMD="$root/core/vendor-common/bin/nowhere_roamd.sh"
RUN="$root/core/chooser/tests/keep-order/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$STI" "$UNA" "$PRO" "$CHO" "$RMD" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# ---- the pinned blocks (quoted heredocs: every backslash below is literal source text) ----
IFS= read -r -d '' P_REORDER <<'EOF'
    static boolean reorderKeepLines(Context ctx, java.util.List<String> order) {
        synchronized (APPKEEP_LOCK) {
            try {
                File f = new File(ctx.getFilesDir(), "nowhere-appkeep");
                if (!f.exists()) return true;
                String was = KeepOrder.readText(f);
                String now = KeepOrder.reorder(was, order);
                if (!now.equals(was)) writeAtomic(f, now);
                return true;
EOF
IFS= read -r -d '' P_FOLD <<'EOF'
    static void foldAppFirst(Context ctx) {
        synchronized (APPKEEP_LOCK) {
            File first = new File(ctx.getFilesDir(), "nowhere-appfirst");
            if (!first.exists()) return;
            java.util.List<String> marks;
            try { marks = KeepOrder.marks(KeepOrder.readText(first)); }
            catch (Throwable t) { Log.w("NowhereChooser", "foldAppFirst: read", t); return; }
            if (!reorderKeepLines(ctx, marks)) return;
            if (!first.delete() && first.exists()) { Log.w("NowhereChooser", "foldAppFirst: delete failed"); return; }
EOF
IFS= read -r -d '' P_WAKEREAD <<'EOF'
            File f = new File(ctx.getFilesDir(), "nowhere-appwake");
            try { return f.exists() ? KeepOrder.parseWake(KeepOrder.readText(f)) : new java.util.LinkedHashMap<>(); }
EOF
IFS= read -r -d '' P_WAKEWRITE <<'EOF'
                File f = new File(ctx.getFilesDir(), "nowhere-appwake");
                writeAtomic(f, KeepOrder.setWake(f.exists() ? KeepOrder.readText(f) : "", pkg, on));
EOF
IFS= read -r -d '' P_RULE <<'EOF'
    static boolean wakeOnRestore(android.content.Context ctx, String pkg) {
        return KeepOrder.wakeFor(StoreInstaller.wakeOverrides(ctx), pkg, () -> isMessagingApp(ctx, pkg));
    }
EOF
IFS= read -r -d '' P_SWEEPWAKE <<'EOF'
                if (quiet && rr != null && rr.startsWith("OK") && wakeOnRestore(this, pkg)) unstop(this, pkg);
EOF
IFS= read -r -d '' P_ORDER <<'EOF'
                    + " has no placeholder -- group dep, rides its entry point");
        }
        if (restoreOnly != null) restoreOnly.addAll(retry);
        // NWP-20261012-06: keep-set order IS the install order -- the user drags it in Your apps ("Download first",
        // NWP-20261005-13, is retired and folded into it: StoreInstaller.foldAppFirst).
        return work;
    }
EOF
IFS= read -r -d '' P_SWEEPHEAD <<'EOF'
        StoreInstaller.foldAppFirst(this); // NWP-20261012-06: before the order is read; a no-op once folded
        java.util.List<String> retry = new ArrayList<>();
        java.util.List<String> work = pendingAutoApps(this, true, retry);
EOF
IFS= read -r -d '' P_RESTORED <<'EOF'
            if (!hasInstalledCode(this, pkg)) continue;
            try {
                boolean stopped = (getPackageManager().getApplicationInfo(pkg, 0).flags
                        & android.content.pm.ApplicationInfo.FLAG_STOPPED) != 0;
                if (stopped && wakeOnRestore(this, pkg)) unstop(this, pkg);
EOF
IFS= read -r -d '' P_SWEEPCALL <<'EOF'
                try { wakeRestored(restoredOk); }
                catch (Throwable t) { android.util.Log.w("NowhereChooser", "wake restored", t); }
                try { sweepAutoJoined(byHand); }
EOF
IFS= read -r -d '' P_EXTRA <<'EOF'
        final String[] restoredOk = intent != null ? intent.getStringArrayExtra(EXTRA_WAKE) : null;
EOF
IFS= read -r -d '' P_GATEOK <<'EOF'
                            String rr = sendDaemon("RESTORE-ODDATA\n" + pkg + "\n");
                            // NWP-20261012-06: the roamed user decides whether to wake it (its own nowhere-appwake),
                            // and only for a confirmed restore -- the sweep kick hands this set over.
                            if (rr != null && rr.startsWith("OK"))
                                RESTORED_OK.computeIfAbsent(uid, k -> java.util.concurrent.ConcurrentHashMap.newKeySet()).add(pkg);
EOF
IFS= read -r -d '' P_GATEKICK <<'EOF'
    private static void kickAutoMaterialise(final android.content.Context appCtx, final int uid) {
        final java.util.Set<String> restoredOk = RESTORED_OK.remove(uid);
EOF
IFS= read -r -d '' P_GATEPASS <<'EOF'
                android.content.Intent sw = new android.content.Intent(appCtx, UnarchiveService.class)
                        .putExtra(UnarchiveService.EXTRA_SWEEP, true);
                if (restoredOk != null && !restoredOk.isEmpty())
                    sw.putExtra(UnarchiveService.EXTRA_WAKE, restoredOk.toArray(new String[0]));
                appCtx.startServiceAsUser(sw, android.os.UserHandle.of(uid));
EOF
IFS= read -r -d '' P_YAFOLD <<'EOF'
            StoreInstaller.foldAppFirst(this); // NWP-20261012-06: old "Download first" marks lead the order, once
            // NWP-20261005-02: what an "Install pending apps now" tap would install -- the sweep's OWN list.
            final java.util.List<String> pendingAuto = UnarchiveService.pendingAutoApps(this, false);
EOF
IFS= read -r -d '' P_YASORT <<'EOF'
                java.util.List<String> sorted = KeepOrder.keptFirst(pkgs, keptNow);
                pkgs.clear();
                pkgs.addAll(sorted);
EOF
IFS= read -r -d '' P_YADRAG <<'EOF'
                list.setOnDragListener(keepOrderDrag(list));
                for (String p : pkgs)
EOF
IFS= read -r -d '' P_DRAGEND <<'EOF'
                case android.view.DragEvent.ACTION_DRAG_ENDED:
                    dragged.setAlpha(1f);
                    writeKeepOrder(list);
                    return true;
EOF
IFS= read -r -d '' P_WRITER <<'EOF'
    private static final java.util.concurrent.ExecutorService KEEP_ROW_WRITES =
            java.util.concurrent.Executors.newSingleThreadExecutor(r -> {
EOF
IFS= read -r -d '' P_KEEPWRITES <<'EOF'
    private int keepOrderWrites;
EOF
IFS= read -r -d '' P_WRITEORDER <<'EOF'
        final int write = ++keepOrderWrites;
        final android.content.Context app = getApplicationContext();
        KEEP_ROW_WRITES.execute(() -> {
            if (StoreInstaller.reorderKeepLines(app, order)) return;
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) return;
                android.widget.Toast.makeText(this, KeepOrder.ORDER_NOT_SAVED, android.widget.Toast.LENGTH_SHORT).show();
                // a later drag or move is queued (its own outcome rules), or the owner left Your apps (it reads the file anew)
                if (write != keepOrderWrites || !list.isAttachedToWindow()) return;
                showYourApps();
            });
        });
    }
EOF
IFS= read -r -d '' P_LOCALSTATE <<'EOF'
            if (!(ls instanceof View) || ((View) ls).getParent() != list) return false;
EOF
IFS= read -r -d '' P_DRAGLOOP <<'EOF'
                        if (y > (c.getTop() + c.getBottom()) / 2f) to++;
                        if (c.getTag() instanceof KeepRowTag && ((KeepRowTag) c.getTag()).kept) lastKept = others;
                        others++;
EOF
IFS= read -r -d '' P_ROWWAKE <<'EOF'
                for (String p : pkgs) if (keptNow.contains(p)) keepRowWake.put(p, UnarchiveService.wakeOnRestore(this, p));
EOF
IFS= read -r -d '' P_DEFAULT <<'EOF'
                    wake.setEnabled(false);
                    final android.content.Context app = getApplicationContext();
                    KEEP_ROW_WRITES.execute(() -> {
                        final boolean d = UnarchiveService.wakeOnRestore(app, pkg);
                        wakeHeld[0] = d;
                        runOnUiThread(() -> {
EOF
IFS= read -r -d '' P_WAKELOCK <<'EOF'
    static boolean setWakeOverride(Context ctx, String pkg, boolean on) {
        synchronized (WAKE_LOCK) {
EOF
IFS= read -r -d '' P_WAKERESULT <<'EOF'
                writeAtomic(f, KeepOrder.setWake(f.exists() ? KeepOrder.readText(f) : "", pkg, on));
                return true;
            } catch (Throwable t) {
                Log.w("NowhereChooser", "setWakeOverride", t);
                return false;
            }
EOF
IFS= read -r -d '' P_MARK <<'EOF'
            if (pkg == null || pkg.isEmpty()) continue;
            markInstalledRestored(this, pkg);
            if (!hasInstalledCode(this, pkg)) continue;
EOF
IFS= read -r -d '' P_MARKFILE <<'EOF'
    static final String INSTALLED_RESTORED = "nowhere-installed-restored";
EOF
IFS= read -r -d '' P_ROAMDCLEAR <<'EOF'
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-od-restored" 2>>"$LOG"
EOF
IFS= read -r -d '' P_ROAMDCLEAR2 <<'EOF'
      rm -f "$USERDIR/com.nowhere.chooser/files/nowhere-installed-restored" 2>>"$LOG"
EOF
IFS= read -r -d '' P_R1 <<'EOF'
                if (w != null) {
                    wakeHeld[0] = w;
                    wake.setChecked(w);
                    wake.setOnCheckedChangeListener(onWake);
                } else {
EOF
IFS= read -r -d '' P_R2 <<'EOF'
                        runOnUiThread(() -> {
                            wake.setChecked(d);
                            wake.setOnCheckedChangeListener(onWake);
                            wake.setEnabled(true);
                        });
EOF
IFS= read -r -d '' P_R7 <<'EOF'
            if (wakeable && !wakeRead[0]) {
                wakeRead[0] = true;
EOF
IFS= read -r -d '' P_R6 <<'EOF'
        final java.util.List<String> order = new java.util.ArrayList<>();
        for (int i = 0; i < list.getChildCount(); i++) {
            Object t = list.getChildAt(i).getTag();
            if (t instanceof KeepRowTag) order.add(((KeepRowTag) t).pkg);
        }
EOF
IFS= read -r -d '' P_R10 <<'EOF'
                case android.view.DragEvent.ACTION_DRAG_STARTED:
                    dragged.setAlpha(0.4f);
                    return true;
EOF
IFS= read -r -d '' P_R11 <<'EOF'
        handle.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
        handle.setAccessibilityDelegate(new View.AccessibilityDelegate() {
EOF
IFS= read -r -d '' P_R4 <<'EOF'
                if (keepRowCanMove(row, -1)) info.addAction(
                        new android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction(A11Y_MOVE_UP, "Move up"));
                if (keepRowCanMove(row, 1)) info.addAction(
                        new android.view.accessibility.AccessibilityNodeInfo.AccessibilityAction(A11Y_MOVE_DOWN, "Move down"));
EOF
IFS= read -r -d '' P_R3 <<'EOF'
    private static boolean keepRowCanMove(View row, int d) {
        if (!(row.getParent() instanceof android.view.ViewGroup)) return false;
        if (!(row.getTag() instanceof KeepRowTag) || !((KeepRowTag) row.getTag()).kept) return false;
        android.view.ViewGroup list = (android.view.ViewGroup) row.getParent();
        int to = list.indexOfChild(row) + d;
        if (to < 0 || to >= list.getChildCount()) return false;
EOF
IFS= read -r -d '' P_R14 <<'EOF'
                keepRowWake.clear(); // the map outlives the visit: a stale entry would paint an old default
                for (String p : pkgs) if (keptNow.contains(p)) keepRowWake.put(p, UnarchiveService.wakeOnRestore(this, p));
EOF
IFS= read -r -d '' P_FOCUS <<'EOF'
        writeKeepOrder(list);
        handle.post(() -> handle.performAccessibilityAction(
                android.view.accessibility.AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null));
        return true;
EOF
IFS= read -r -d '' P_STATE <<'EOF'
                String pos = keepRowPosition(row);
                if (pos != null) info.setStateDescription(pos); // read live, so it is never stale after a move
EOF
IFS= read -r -d '' P_POS <<'EOF'
            if (!(t instanceof KeepRowTag) || !((KeepRowTag) t).kept) continue;
            m++;
            if (list.getChildAt(i) == row) n = m;
        }
        return "Position " + n + " of " + m;
EOF
IFS= read -r -d '' P_NAME <<'EOF'
        handle.setContentDescription("Reorder " + rowLabel); // NWP-20261012-06: names its app, row by row
EOF
IFS= read -r -d '' P_A11Y <<'EOF'
            public boolean performAccessibilityAction(View host, int action, Bundle args) {
                if (action == A11Y_MOVE_UP) return moveKeepRow(row, host, -1);
                if (action == A11Y_MOVE_DOWN) return moveKeepRow(row, host, 1);
EOF
IFS= read -r -d '' P_A11YBLOCK <<'EOF'
        Object t = list.getChildAt(to).getTag();
        return t instanceof KeepRowTag && ((KeepRowTag) t).kept;
    }
EOF
IFS= read -r -d '' P_A11YWRITE <<'EOF'
        list.removeView(row);
        list.addView(row, to);
        writeKeepOrder(list);
EOF
IFS= read -r -d '' P_DRAGCLAMP <<'EOF'
                    to = Math.min(to, lastKept + 1); // indices among the other rows: never below the kept block
EOF
IFS= read -r -d '' P_HANDLE <<'EOF'
            if (ev.getActionMasked() != android.view.MotionEvent.ACTION_DOWN || !tag.kept) return false;
EOF
IFS= read -r -d '' P_WAKEGUARDS <<'EOF'
        final boolean[] wakeHeld = { false };
        final boolean[] wakeReverting = { false };
        final int[] wakeTaps = { 0 };
        final android.widget.CompoundButton.OnCheckedChangeListener onWake = (b, on) -> {
            if (wakeReverting[0]) return;
            final int tap = ++wakeTaps[0];
            final android.content.Context app = getApplicationContext();
EOF
IFS= read -r -d '' P_ONWAKE <<'EOF'
            KEEP_ROW_WRITES.execute(() -> {
                final boolean saved = StoreInstaller.setWakeOverride(app, pkg, on);
                if (!saved) {
                    final boolean held = wakeHeld[0];
                    runOnUiThread(() -> {
                        if (isFinishing() || isDestroyed()) return;
                        android.widget.Toast.makeText(this, KeepOrder.WAKE_NOT_SAVED, android.widget.Toast.LENGTH_SHORT).show();
                        if (wakeTaps[0] != tap) return; // a later tap is queued: its own outcome sets the check
                        wakeReverting[0] = true;
                        wake.setChecked(held);
                        wakeReverting[0] = false;
                    });
                    return;
                }
                wakeHeld[0] = on;
                if (!on || !UnarchiveService.hasInstalledCode(app, pkg)) return;
EOF
IFS= read -r -d '' P_WAKEGUARD <<'EOF'
                String md = appMode(pkg);
                boolean restored = MODE_AUTO.equals(md) ? UnarchiveService.odRestored(app, pkg)
                        : MODE_INSTALLED.equals(md) && UnarchiveService.installedRestored(app, pkg);
                if (!restored) return;
                try {
                    if ((app.getPackageManager().getApplicationInfo(pkg, 0).flags
                            & android.content.pm.ApplicationInfo.FLAG_STOPPED) != 0) UnarchiveService.unstop(app, pkg);
EOF
IFS= read -r -d '' P_SHOWS <<'EOF'
            tag.kept = m != null;
            handle.setVisibility(AppFilter.reorderable(m != null, tag.searching) ? View.VISIBLE : View.INVISIBLE);
            boolean wakeable = MODE_AUTO.equals(m) || MODE_INSTALLED.equals(m);
EOF
IFS= read -r -d '' P_WAKESHOW <<'EOF'
            wake.setVisibility(wakeable ? View.VISIBLE : View.GONE);
EOF
IFS= read -r -d '' P_PAINT <<'EOF'
            String m = appMode(pkg);
            paintModeChip(chip, m);
            orderWake.show(m);
EOF
IFS= read -r -d '' P_DIALOG <<'EOF'
        // NWP-20261012-06: no "Download first" button -- the install order is the order of the rows, dragged.
        new android.app.AlertDialog.Builder(this)
EOF
IFS= read -r -d '' P_CHIP <<'EOF'
        chip.setText(label);
EOF

# pinned <file> <label> <block>: the block must appear verbatim in the file.
pinned() {
  local body; body=$(cat "$1")
  [[ "$body" == *"$3"* ]] && return 0
  echo "  PIN   $2 -- the block is gone or changed in $(basename "$1")" >&2
  return 1
}
# absent <file> <label> <text> <control>: <text> must not appear, and <control> (which must) proves the file was read.
absent() {
  local body; body=$(cat "$1")
  if [[ "$body" != *"$4"* ]]; then echo "  CTRL  $2 -- the control is missing from $(basename "$1"), the check proves nothing" >&2; return 1; fi
  [[ "$body" == *"$3"* ]] || return 0
  echo "  BACK  $2 -- found in $(basename "$1")" >&2
  return 1
}

# suite <KeepOrder> <StoreInstaller> <UnarchiveService> <ProfileActivity> <ChooserActivity> <nowhere_roamd.sh> -> 0 pass; 1 a case or a pin
# failed (both are behaviour here: a pin is how a call-site mutant is convicted); 3 the class or the cases did not compile.
suite() {
  local o="$1" s="$2" u="$3" p="$4" c="$5" rd="$6" bad=0
  pinned "$s" "the reorder holds the keep-set lock and writes what KeepOrder.reorder made" "$P_REORDER" || bad=1
  pinned "$s" "the fold reorders by the marks, then deletes them only if that landed"  "$P_FOLD"      || bad=1
  pinned "$s" "the wake choices are read from nowhere-appwake"                          "$P_WAKEREAD"  || bad=1
  pinned "$s" "a wake choice is written as made"                                        "$P_WAKEWRITE" || bad=1
  pinned "$u" "the wake rule: the override, else the messaging rule"                     "$P_RULE"      || bad=1
  pinned "$u" "the sweep wakes on the rule, after a confirmed restore"                   "$P_SWEEPWAKE" || bad=1
  pinned "$u" "pendingAutoApps returns the keep-set order"                            "$P_ORDER"     || bad=1
  pinned "$u" "the sweep folds the old marks before it reads the order"              "$P_SWEEPHEAD" || bad=1
  pinned "$u" "a Keep-installed restore is woken only while stopped, on the rule"        "$P_RESTORED"  || bad=1
  pinned "$u" "the sweep thread wakes the gate's restores before the sweep"             "$P_SWEEPCALL" || bad=1
  pinned "$u" "the sweep reads the gate's restored set"                                 "$P_EXTRA"     || bad=1
  pinned "$c" "the gate records only a restore that answered OK"                        "$P_GATEOK"    || bad=1
  pinned "$c" "the kick takes this user's set"                                          "$P_GATEKICK"  || bad=1
  pinned "$c" "the kick hands the set to the sweep"                                     "$P_GATEPASS"  || bad=1
  pinned "$p" "Your apps folds the old marks before it reads the order"                 "$P_YAFOLD"    || bad=1
  pinned "$p" "Your apps lists the kept rows first, in keep-set order"                  "$P_YASORT"    || bad=1
  pinned "$p" "Your apps' list takes the drag"                                          "$P_YADRAG"    || bad=1
  pinned "$p" "a drag's end writes the rows' order to the keep-set, off the UI thread"   "$P_DRAGEND"   || bad=1
  pinned "$p" "a kept row never sinks below the kept block"                             "$P_DRAGCLAMP" || bad=1
  pinned "$p" "only a kept row starts a drag"                                           "$P_HANDLE"    || bad=1
  pinned "$p" "the last choice on file is held; a revert does not re-run the listener, and each tap is counted" "$P_WAKEGUARDS" || bad=1
  pinned "$p" "a check is kept; a failed write puts back the last choice on file and wakes nothing; a saved check is held, and wakes an installed stopped app" "$P_ONWAKE" || bad=1
  pinned "$p" "... only over restored data: Keep-installed, or Auto with RESTORE-ODDATA OK" "$P_WAKEGUARD" || bad=1
  pinned "$p" "one single-thread writer for the order and wake writes"                  "$P_WRITER"    || bad=1
  pinned "$p" "each order write is counted on the UI thread"                           "$P_KEEPWRITES" || bad=1
  pinned "$p" "the order is written on that writer; a failed write says so and redraws from the file" "$P_WRITEORDER" || bad=1
  pinned "$p" "the drag listener takes only its own list's rows"                        "$P_LOCALSTATE" || bad=1
  pinned "$p" "the kept block is measured from the kept rows"                           "$P_DRAGLOOP"  || bad=1
  pinned "$p" "each kept row's wake default comes from the rule"                        "$P_ROWWAKE"   || bad=1
  pinned "$p" "a later row's wake default is read off the UI thread"                    "$P_DEFAULT"   || bad=1
  pinned "$s" "a wake choice is written under WAKE_LOCK, and the write returns its result" "$P_WAKELOCK" || bad=1
  pinned "$s" "a wake write returns true only when it landed, false from its catch"     "$P_WAKERESULT" || bad=1
  pinned "$p" "Move up / Move down move the row"                                        "$P_A11Y"      || bad=1
  pinned "$p" "... only inside the kept block"                                          "$P_A11YBLOCK" || bad=1
  pinned "$p" "... and are written as a drag is"                                        "$P_A11YWRITE" || bad=1
  pinned "$u" "the gate's OK restores are recorded before the wake decision"            "$P_MARK"      || bad=1
  pinned "$u" "... in their own file, not nowhere-od-restored"                          "$P_MARKFILE"  || bad=1
  pinned "$rd" "roamd clears the od-restored marker at roam-in (control)"               "$P_ROAMDCLEAR" || bad=1
  pinned "$rd" "... and its Keep-installed twin beside it"                              "$P_ROAMDCLEAR2" || bad=1
  pinned "$p" "a precomputed default is set BEFORE the listener (no phantom override)"   "$P_R1"        || bad=1
  pinned "$p" "an async default is set before the listener, then enabled"               "$P_R2"        || bad=1
  pinned "$p" "the default is read once per row"                                        "$P_R7"        || bad=1
  pinned "$p" "the order snapshot takes every row, top to bottom"                       "$P_R6"        || bad=1
  pinned "$p" "the list accepts the drag it is offered"                                 "$P_R10"       || bad=1
  pinned "$p" "the handle is an accessibility node with the move actions"               "$P_R11"       || bad=1
  pinned "$p" "each move is offered per direction"                                      "$P_R4"        || bad=1
  pinned "$p" "a move needs a kept row, a parent and a neighbour in range"              "$P_R3"        || bad=1
  pinned "$p" "the wake defaults are recomputed each visit"                             "$P_R14"       || bad=1
  pinned "$p" "TalkBack focus returns to the handle after a move"                       "$P_FOCUS"     || bad=1
  pinned "$p" "the handle says its position among the kept rows"                        "$P_STATE"     || bad=1
  pinned "$p" "... counted over the kept rows only"                                     "$P_POS"       || bad=1
  pinned "$p" "the handle names its app"                                                "$P_NAME"      || bad=1
  pinned "$p" "the handle shows on kept rows (not under a search); the check on Auto and Keep-installed" "$P_SHOWS" || bad=1
  pinned "$p" "the check is hidden on every other row"                                  "$P_WAKESHOW"  || bad=1
  pinned "$p" "paint shows the handle and the check from the stored mode"               "$P_PAINT"     || bad=1
  pinned "$p" "the mode dialog has no Download first button"                            "$P_DIALOG"    || bad=1
  pinned "$p" "the chip says the mode and nothing else"                                 "$P_CHIP"      || bad=1
  absent "$p" "the · first chip label"           '" · first"'           'chip.setText(label);'                  || bad=1
  absent "$p" "a writer of the Download first marks" 'setAppFirst('     'StoreInstaller.foldAppFirst(this);'    || bad=1
  absent "$u" "the Download first sweep order"   'appFirstOrder('       'return work;'                          || bad=1
  absent "$p" "a dead write of the tapped wake into the defaults map" 'keepRowWake.put(pkg, on)' 'keepRowWake.put(p, UnarchiveService.wakeOnRestore(this, p))' || bad=1
  absent "$p" "the wake rule run on the UI thread" 'UnarchiveService.wakeOnRestore(this, pkg)' 'UnarchiveService.wakeOnRestore(app, pkg)' || bad=1
  absent "$p" "a wake revert read anew from the file (a failed read gives the messaging rule)" 'final boolean held = UnarchiveService.' '                    final boolean held = wakeHeld[0];' || bad=1
  absent "$p" "a Your apps write on its own thread" 'new Thread(() -> StoreInstaller.' '            if (StoreInstaller.reorderKeepLines(app, order)) return;' || bad=1
  [ "$bad" = 0 ] || return 1
  bash "$RUN" "$o"
}

echo "== $SRC (+ pins in $(basename "$STI"), $(basename "$UNA"), $(basename "$PRO"), $(basename "$CHO"), $(basename "$RMD"))"
suite "$SRC" "$STI" "$UNA" "$PRO" "$CHO" "$RMD" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not compile proves nothing)"
# mut <label> <which: O|S|U|P|C|R> <perl-expr>   (R = nowhere_roamd.sh)
mut() {
  local d rc o="$SRC" s="$STI" u="$UNA" p="$PRO" c="$CHO" rd="$RMD" t
  d=$(mktemp -d)
  case "$2" in O) t="$SRC" ;; S) t="$STI" ;; U) t="$UNA" ;; P) t="$PRO" ;; C) t="$CHO" ;; R) t="$RMD" ;; esac
  local m="$d/$(basename "$t")"
  if ! perl -0pe "$3" "$t" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$t" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in O) o="$m" ;; S) s="$m" ;; U) u="$m" ;; P) p="$m" ;; C) c="$m" ;; R) rd="$m" ;; esac
  suite "$o" "$s" "$u" "$p" "$c" "$rd" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
# the rules
mut "O1 the order is ignored"                          O 's/if \(order != null\) \{/if (false) {/' || fails=$((fails+1))
mut "O2 lines the order does not name are dropped"     O 's/if \(done\.contains\(e\.getKey\(\)\)\) continue;/if (true) continue;/' || fails=$((fails+1))
mut "O3 a line is rebuilt, not re-emitted verbatim"    O 's/for \(String ln : ls\) sb\.append\(ln\)\.append/for (String ln : ls) sb.append(k).append/' || fails=$((fails+1))
mut "O4 an order name is not trimmed"                  O 's/String k = p\.trim\(\);/String k = p;/' || fails=$((fails+1))
mut "O5 a second line of one package is lost"          O 's/byPkg\.computeIfAbsent\(keyOf\(ln\), k -> new ArrayList<>\(\)\)\.add\(ln\);/byPkg.put(keyOf(ln), new ArrayList<>(java.util.Collections.singletonList(ln)));/' || fails=$((fails+1))
mut "O6 a name given twice emits its line twice"       O 's/if \(ls == null \|\| !done\.add\(k\)\) continue;/if (ls == null) continue; done.add(k);/' || fails=$((fails+1))
mut "O7 blank lines are kept"                          O 's/if \(!ln\.trim\(\)\.isEmpty\(\)\) out\.add\(ln\);/out.add(ln);/' || fails=$((fails+1))
mut "O8 the marks lose their order"                    O 's/LinkedHashSet<String> s = new LinkedHashSet<>\(\);\n        for \(String ln : lines\(text\)\) s\.add\(ln\.trim\(\)\);/java.util.TreeSet<String> s = new java.util.TreeSet<>();\n        for (String ln : lines(text)) s.add(ln.trim());/' || fails=$((fails+1))
mut "O9 the rows' kept block ignores keep-set order"   O 's/for \(String p : keepOrder\) if \(inRows\.contains\(p\) && kept\.add\(p\)\) out\.add\(p\);/for (String p : rows) if (keepOrder.contains(p) \&\& kept.add(p)) out.add(p);/' || fails=$((fails+1))
mut "O10 a later wake on does not win"                 O 's/\{ m\.remove\(pkg\); m\.put\(pkg, Boolean\.TRUE\); \}/m.putIfAbsent(pkg, Boolean.TRUE);/' || fails=$((fails+1))
mut "O11 a later wake off does not win"                O 's/\{ m\.remove\(pkg\); m\.put\(pkg, Boolean\.FALSE\); \}/m.putIfAbsent(pkg, Boolean.FALSE);/' || fails=$((fails+1))
mut "O12 a wake line with extra fields is believed"    O 's/if \(f\.length != 2\) continue;/if (f.length < 2) continue;/' || fails=$((fails+1))
mut "O13 the override is ignored"                      O 's/return v != null \? v : messaging\.getAsBoolean\(\);/return messaging.getAsBoolean();/' || fails=$((fails+1))
mut "O14 the messaging rule asked even with a choice"  O 's/return v != null \? v : messaging\.getAsBoolean\(\);/boolean mr = messaging.getAsBoolean(); return v != null ? v : mr;/' || fails=$((fails+1))
mut "O15 a choice is written inverted"                 O 's/e\.getValue\(\) \? WAKE_ON : WAKE_OFF/e.getValue() ? WAKE_OFF : WAKE_ON/' || fails=$((fails+1))
mut "O16 the key is the whole line"                    O 's/return line\.split\("\\t", 2\)\[0\]\.trim\(\);/return line.trim();/' || fails=$((fails+1))
mut "O17 setWake drops the other choices"              O 's/LinkedHashMap<String, Boolean> m = parseWake\(text\);\n        m\.remove\(pkg\);/LinkedHashMap<String, Boolean> m = new LinkedHashMap<>();\n        m.remove(pkg);/' || fails=$((fails+1))
mut "O18 the wake values are read upper-case"          O 's/WAKE_ON = "on";/WAKE_ON = "ON";/' || fails=$((fails+1))
# the call sites -- each must be convicted by a pin
mut "C1 the sweep wakes on the messaging rule alone"   U 's/rr\.startsWith\("OK"\) && wakeOnRestore\(this, pkg\)\) unstop/rr.startsWith("OK") \&\& isMessagingApp(this, pkg)) unstop/' || fails=$((fails+1))
mut "C2 the wake rule ignores the user's choices"      U 's/KeepOrder\.wakeFor\(StoreInstaller\.wakeOverrides\(ctx\), pkg,/KeepOrder.wakeFor(new java.util.HashMap<String, Boolean>(), pkg,/' || fails=$((fails+1))
mut "C3 the sweep re-sorts the keep order"             U 's/        if \(restoreOnly != null\) restoreOnly\.addAll\(retry\);
/        java.util.Collections.sort(work);
        if (restoreOnly != null) restoreOnly.addAll(retry);
/' || fails=$((fails+1))
mut "C4 the sweep never folds the old marks"           U 's/        StoreInstaller\.foldAppFirst\(this\); \/\/ NWP-20261012-06: before the order is read; a no-op once folded\n//' || fails=$((fails+1))
mut "C5 the gate hands over a failed restore"          C 's/if \(rr != null && rr\.startsWith\("OK"\)\)\n/if (rr != null)\n/' || fails=$((fails+1))
mut "C6 the kick never hands the set over"             C 's/                    sw\.putExtra\(UnarchiveService\.EXTRA_WAKE, restoredOk\.toArray\(new String\[0\]\)\);\n/                    android.util.Log.i("NowhereChooser", "wake set dropped");\n/' || fails=$((fails+1))
mut "C7 a Keep-installed app is woken while running"   U 's/if \(stopped && wakeOnRestore\(this, pkg\)\) unstop/if (wakeOnRestore(this, pkg)) unstop/' || fails=$((fails+1))
mut "C8 the sweep thread skips the gate's restores"    U 's/                try \{ wakeRestored\(restoredOk\); \}\n                catch \(Throwable t\) \{ android\.util\.Log\.w\("NowhereChooser", "wake restored", t\); \}\n//' || fails=$((fails+1))
mut "C9 the reorder drops the keep-set lock"           S 's/(static boolean reorderKeepLines\(Context ctx, java\.util\.List<String> order\) \{\n        )synchronized \(APPKEEP_LOCK\) \{/${1}{/' || fails=$((fails+1))
mut "C10 the marks deleted though the reorder failed"  S 's/            if \(!reorderKeepLines\(ctx, marks\)\) return;\n/            reorderKeepLines(ctx, marks);\n/' || fails=$((fails+1))
mut "C11 a wake choice written inverted"               S 's/KeepOrder\.setWake\(f\.exists\(\) \? KeepOrder\.readText\(f\) : "", pkg, on\)/KeepOrder.setWake(f.exists() ? KeepOrder.readText(f) : "", pkg, !on)/' || fails=$((fails+1))
mut "C12 Your apps lists rows unsorted"                P 's/java\.util\.List<String> sorted = KeepOrder\.keptFirst\(pkgs, keptNow\);/java.util.List<String> sorted = new java.util.ArrayList<>(pkgs);/' || fails=$((fails+1))
mut "C13 a drag is never written"                      P 's/                    dragged\.setAlpha\(1f\);\n                    writeKeepOrder\(list\);\n/                    dragged.setAlpha(1f);\n/' || fails=$((fails+1))
mut "C14 Download first is offered again"              P 's/(rows, dragged\.\n        new android\.app\.AlertDialog\.Builder\(this\))\n/$1.setNeutralButton("Download first", null)\n/' || fails=$((fails+1))
mut "C15 checking the box does not wake the app"       P 's/ != 0\) UnarchiveService\.unstop\(app, pkg\);/ != 0) Log.i("NowhereChooser", "not woken");/' || fails=$((fails+1))
mut "C16 the check is offered on On-demand rows too"   P 's/boolean wakeable = MODE_AUTO\.equals\(m\) \|\| MODE_INSTALLED\.equals\(m\);/boolean wakeable = m != null;/' || fails=$((fails+1))
mut "C17 the first chip label is back"                 P 's/        chip\.setText\(label\);/        chip.setText(MODE_AUTO.equals(mode) ? label + " · first" : label);/' || fails=$((fails+1))
mut "C18 an Off row starts a drag"                     P 's/ACTION_DOWN \|\| !tag\.kept\) return false;/ACTION_DOWN) return false;/' || fails=$((fails+1))
mut "C19 a kept row may sink among the Off rows"       P 's/                    to = Math\.min\(to, lastKept \+ 1\);/                    to = Math.max(to, 0);/' || fails=$((fails+1))
mut "C20 the list never takes the drag"                P 's/                list\.setOnDragListener\(keepOrderDrag\(list\)\);\n//' || fails=$((fails+1))
mut "C21 Your apps reads the order before the fold"    P 's/            StoreInstaller\.foldAppFirst\(this\); \/\/ NWP-20261012-06: old "Download first" marks lead the order, once\n//' || fails=$((fails+1))
mut "C22 the wake choice is never kept"                P 's/                final boolean saved = StoreInstaller\.setWakeOverride\(app, pkg, on\);\n/                final boolean saved = true;\n/' || fails=$((fails+1))
mut "C23 a stored choice read from the wrong file"     S 's/(File f = new File\(ctx\.getFilesDir\(\), )"nowhere-appwake"(\);\n            try \{ return)/$1"nowhere-appwake.list"$2/' || fails=$((fails+1))
mut "O19 readText drops the line ends"                 O 's/while \(\(ln = r\.readLine\(\)\) != null\) sb\.append\(ln\)\.append\(\(char\) 10\);/while ((ln = r.readLine()) != null) sb.append(ln);/' || fails=$((fails+1))
mut "C24 a drag written on a thread of its own"        P 's/KEEP_ROW_WRITES\.execute\(\(\) -> \{\n(\s+)if \(StoreInstaller\.reorderKeepLines\(app, order\)\) return;/new Thread(() -> {\n${1}if (StoreInstaller.reorderKeepLines(app, order)) return;/' || fails=$((fails+1))
mut "C25 a wake tap written on a thread of its own"    P 's/KEEP_ROW_WRITES\.execute\(\(\) -> \{\n(\s+)final boolean saved = StoreInstaller\.setWakeOverride/new Thread(() -> {\n${1}final boolean saved = StoreInstaller.setWakeOverride/' || fails=$((fails+1))
mut "C26 the writer is a pool, not one thread"         P 's/Executors\.newSingleThreadExecutor\(r -> \{\n(\s+)Thread t = new Thread\(r, "nowhere-yourapps-write"\);/Executors.newCachedThreadPool(r -> {\n${1}Thread t = new Thread(r, "nowhere-yourapps-write");/' || fails=$((fails+1))
mut "C27 a check wakes an app over an empty data dir"  P 's/                if \(!restored\) return;\n//' || fails=$((fails+1))
mut "C28 an Auto app woken before its restore"         P 's/MODE_AUTO\.equals\(md\) \? UnarchiveService\.odRestored\(app, pkg\)/MODE_AUTO.equals(md) ? true/' || fails=$((fails+1))
mut "C29 every row's wake default is unchecked"        P 's/keepRowWake\.put\(p, UnarchiveService\.wakeOnRestore\(this, p\)\);/keepRowWake.put(p, false);/' || fails=$((fails+1))
mut "C30 the kept block counts Off rows"               P 's/if \(c\.getTag\(\) instanceof KeepRowTag && \(\(KeepRowTag\) c\.getTag\(\)\)\.kept\) lastKept = others;/lastKept = others;/' || fails=$((fails+1))
mut "C31 the listener takes another list's drag"       P 's/if \(!\(ls instanceof View\) \|\| \(\(View\) ls\)\.getParent\(\) != list\) return false;/if (!(ls instanceof View)) return false;/' || fails=$((fails+1))
mut "C32 a wake choice written without WAKE_LOCK"      S 's/(static boolean setWakeOverride\(Context ctx, String pkg, boolean on\) \{\n        )synchronized \(WAKE_LOCK\) \{/${1}{/' || fails=$((fails+1))
mut "C33 a later row's default read on the UI thread"  P 's/                    wake\.setEnabled\(false\);\n/                    wake.setChecked(UnarchiveService.wakeOnRestore(this, pkg));\n                    wake.setEnabled(false);\n/' || fails=$((fails+1))
mut "C34 Move down leaves the kept block"              P 's/        return t instanceof KeepRowTag && \(\(KeepRowTag\) t\)\.kept;\n/        return true;\n/' || fails=$((fails+1))
mut "C35 a Move is never written"                      P 's/        list\.addView\(row, to\);\n        writeKeepOrder\(list\);\n/        list.addView(row, to);\n/' || fails=$((fails+1))
mut "C36 the actions do nothing"                       P 's/if \(action == A11Y_MOVE_UP\) return moveKeepRow\(row, host, -1\);/if (action == A11Y_MOVE_UP) return true;/' || fails=$((fails+1))
mut "A1 a Keep-installed app woken with no restore marker" P 's/: MODE_INSTALLED\.equals\(md\) && UnarchiveService\.installedRestored\(app, pkg\);/: MODE_INSTALLED.equals(md);/' || fails=$((fails+1))
mut "A2 the gate's restores are never recorded"         U 's/            markInstalledRestored\(this, pkg\);\n//' || fails=$((fails+1))
mut "A3 a Keep-installed restore recorded as materialised" U 's/            markInstalledRestored\(this, pkg\);\n/            markOdRestored(this, pkg);\n/' || fails=$((fails+1))
mut "A4 roamd leaves the Keep-installed marker in place" R 's/      rm -f "\$USERDIR\/com\.nowhere\.chooser\/files\/nowhere-installed-restored" 2>>"\$LOG"\n//' || fails=$((fails+1))
mut "A5 the marker's file is the od-restored one"       U 's/INSTALLED_RESTORED = "nowhere-installed-restored";/INSTALLED_RESTORED = "nowhere-od-restored";/' || fails=$((fails+1))
mut "R1 the listener attached before the precomputed default" P 's/                    wake\.setChecked\(w\);\n                    wake\.setOnCheckedChangeListener\(onWake\);\n/                    wake.setOnCheckedChangeListener(onWake);\n                    wake.setChecked(w);\n/' || fails=$((fails+1))
mut "R2 the listener attached before the async default" P 's/                            wake\.setChecked\(d\);\n                            wake\.setOnCheckedChangeListener\(onWake\);\n/                            wake.setOnCheckedChangeListener(onWake);\n                            wake.setChecked(d);\n/' || fails=$((fails+1))
mut "R7 the default re-read on every paint"             P 's/            if \(wakeable && !wakeRead\[0\]\) \{/            if (wakeable) {/' || fails=$((fails+1))
mut "R8 the check never re-enabled"                     P 's/                            wake\.setEnabled\(true\);\n//' || fails=$((fails+1))
mut "R6 the snapshot skips the first row"               P 's/(final java\.util\.List<String> order = new java\.util\.ArrayList<>\(\);\n        )for \(int i = 0; /${1}for (int i = 1; /' || fails=$((fails+1))
mut "R10 the list refuses the drag"                     P 's/                    dragged\.setAlpha\(0\.4f\);\n                    return true;/                    dragged.setAlpha(0.4f);\n                    return false;/' || fails=$((fails+1))
mut "R13 the move actions never installed"              P 's/        handle\.setAccessibilityDelegate\(new View\.AccessibilityDelegate\(\) \{/        new View.AccessibilityDelegate() {/' || fails=$((fails+1))
mut "R11 the handle hidden from accessibility"          P 's/View\.IMPORTANT_FOR_ACCESSIBILITY_YES\);/View.IMPORTANT_FOR_ACCESSIBILITY_NO);/' || fails=$((fails+1))
mut "R3 an Off row may move"                            P 's/        if \(!\(row\.getTag\(\) instanceof KeepRowTag\) \|\| !\(\(KeepRowTag\) row\.getTag\(\)\)\.kept\) return false;\n        android\.view\.ViewGroup list = \(android\.view\.ViewGroup\) row\.getParent\(\);\n        int to/        android.view.ViewGroup list = (android.view.ViewGroup) row.getParent();\n        int to/' || fails=$((fails+1))
mut "R4 Move down offered where only up is possible"   P 's/                if \(keepRowCanMove\(row, 1\)\) info\.addAction\(/                if (keepRowCanMove(row, -1)) info.addAction(/' || fails=$((fails+1))
mut "R5 a move past the last row"                       P 's/if \(to < 0 \|\| to >= list\.getChildCount\(\)\) return false;/if (to < 0) return false;/' || fails=$((fails+1))
mut "R14 the defaults map kept across visits"           P 's/                keepRowWake\.clear\(\); \/\/ the map outlives the visit: a stale entry would paint an old default\n//' || fails=$((fails+1))
mut "R15 the tapped wake written into the defaults map" P 's/(            final android\.content\.Context app = getApplicationContext\(\);\n)(            \/\/ KEEP_ROW_WRITES, never a thread per tap)/${1}            keepRowWake.put(pkg, on);\n${2}/' || fails=$((fails+1))
mut "F1 focus not returned after a move"               P 's/        handle\.post\(\(\) -> handle\.performAccessibilityAction\(\n                android\.view\.accessibility\.AccessibilityNodeInfo\.ACTION_ACCESSIBILITY_FOCUS, null\)\);\n//' || fails=$((fails+1))
mut "F2 the position counts Off rows"                  P 's/            if \(!\(t instanceof KeepRowTag\) \|\| !\(\(KeepRowTag\) t\)\.kept\) continue;\n            m\+\+;/            m++;/' || fails=$((fails+1))
mut "F3 the handle names no app"                       P 's/handle\.setContentDescription\("Reorder " \+ rowLabel\);/handle.setContentDescription("Drag to reorder");/' || fails=$((fails+1))
# NWP-20261125-26: a failed write is never shown as saved
mut "W1 the wake write's catch reports success"        S 's/("setWakeOverride", t\);\n                )return false;/${1}return true;/' || fails=$((fails+1))
mut "W2 the wake write's result is not returned"       S 's/static boolean setWakeOverride/static void setWakeOverride/' || fails=$((fails+1))
mut "W3 an unsaved check still wakes the app"          P 's/(                        wakeReverting\[0\] = false;\n                    \}\);\n)                    return;\n/${1}/' || fails=$((fails+1))
mut "W4 the revert shows the tap, not the file"        P 's/wake\.setChecked\(held\);/wake.setChecked(on);/' || fails=$((fails+1))
mut "W5 the revert re-runs the listener"               P 's/            if \(wakeReverting\[0\]\) return;\n//' || fails=$((fails+1))
mut "W6 an earlier tap's revert overwrites a later tap" P 's/                        if \(wakeTaps\[0\] != tap\) return;[^\n]*\n//' || fails=$((fails+1))
mut "W7 a failed wake write says nothing"              P 's/                        android\.widget\.Toast\.makeText\(this, KeepOrder\.WAKE_NOT_SAVED[^\n]*\n//' || fails=$((fails+1))
mut "W8 the drag's result is dropped again"            P 's/            if \(StoreInstaller\.reorderKeepLines\(app, order\)\) return;/            StoreInstaller.reorderKeepLines(app, order);\n            if (true) return;/' || fails=$((fails+1))
mut "W9 a failed order is not redrawn"                 P 's/(!list\.isAttachedToWindow\(\)\) return;\n)                showYourApps\(\);\n/${1}/' || fails=$((fails+1))
mut "W10 a failed order says nothing"                  P 's/                android\.widget\.Toast\.makeText\(this, KeepOrder\.ORDER_NOT_SAVED[^\n]*\n//' || fails=$((fails+1))
mut "W11 the wake words claim a save"                  O 's/WAKE_NOT_SAVED = "[^"]*";/WAKE_NOT_SAVED = "Saved.";/' || fails=$((fails+1))
mut "W12 the order words are empty"                    O 's/ORDER_NOT_SAVED = "[^"]*";/ORDER_NOT_SAVED = "";/' || fails=$((fails+1))
mut "W13 the revert reads the file anew"               P 's/final boolean held = wakeHeld\[0\];/final boolean held = UnarchiveService.wakeOnRestore(app, pkg);/' || fails=$((fails+1))
mut "W14 a saved tap is not held"                      P 's/                wakeHeld\[0\] = on;\n//' || fails=$((fails+1))
mut "W15 a precomputed default is not held"            P 's/                    wakeHeld\[0\] = w;\n//' || fails=$((fails+1))
mut "W16 an async default is not held"                 P 's/                        wakeHeld\[0\] = d;\n//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
