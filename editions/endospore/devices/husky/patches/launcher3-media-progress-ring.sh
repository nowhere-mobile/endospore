#!/bin/bash
# launcher3-media-progress-ring.sh -- port the #129 offline-media prefetch progress RING to Endospore's
# launcher (GrapheneOS Launcher3QuickStep). The FP3/Trebuchet twin is
# editions/diaspore/build/patches/trebuchet-media-progress-ring.sh; the icon-draw + receiver code is IDENTICAL
# (same BubbleTextView / DoubleShadowBubbleTextView / Launcher API surface), only the surrounding lines differ,
# so this re-anchors the same hunks against packages/apps/Launcher3. Out-of-repo source patch, run before `m`,
# reapplied per build like launcher3-grid.sh. Adds:
#   * BubbleTextView: a static pkg->percent map (setMediaProgress) + an onDraw hook drawMediaRingIfNecessary
#     that paints an arc around the icon while 0<pct<100 (drawer icons).
#   * DoubleShadowBubbleTextView (workspace/hotseat icons): its onDraw double-shadow branch never calls
#     super.onDraw, so it must invoke drawMediaRingIfNecessary itself -- else the ring shows only in the drawer.
#   * Launcher: a RECEIVER_EXPORTED receiver for app.nowhere.MEDIA_PROGRESS (the device-owner chooser relays the
#     daemon's GET-MEDIA-APP-PROGRESS cross-user into the roamed user) -> setMediaProgress + invalidate icons.
# The chooser already broadcasts to setPackage("com.android.launcher3"), which IS this launcher's package
# (QuickstepLauncher extends Launcher), so no chooser/agent change is needed -- only the launcher was deaf.
# NWP-20261027-13: nothing is written unless all three hunks apply, and a half-applied tree is refused. The three
# end-state markers (the verify's own) are read first: all three present = "already applied"; none = apply; one or two
# = HALF-APPLIED. Every hunk is then dry-run before any write, and the .endospore-orig copies are made only after
# all three dry-runs pass. Exit codes: 0 applied or already applied; 1 a missing target file or a failed end-state
# verify; 2 a hunk that does not dry-run or whose innermost context anchor is gone (upstream drift), nothing
# written; 3 half-applied, nothing written. All three hunks run at --fuzz=3, as they always have. At --fuzz=3 a
# pure insertion drops all its context and "applies" to any file by line number, so before each dry-run the hunk's
# innermost leading context line (the last unchanged line before its first added line) must be present in the
# target as a whole line: a renamed or moved anchor is drift, exit 2, not a hunk placed by line number.
# The dry-run and the apply use the same flags. Executed in CI over synthetic trees by
# editions/endospore/build/test-ring-patch-guard.sh.
# Usage: launcher3-media-progress-ring.sh <graphene-tree-root>
set -euo pipefail
TREE="${1:?usage: launcher3-media-progress-ring.sh <graphene-tree-root>}"
SRC="$TREE/packages/apps/Launcher3/src/com/android/launcher3"
[ -d "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }
cd "$SRC"
for f in BubbleTextView.java Launcher.java views/DoubleShadowBubbleTextView.java; do
  [ -f "$f" ] || { echo "launcher3-media-progress-ring: missing $SRC/$f" >&2; MISSING=1; }
done
[ -z "${MISSING:-}" ] || exit 1
HAVE=""; LACK=""
mark() { # <file> <needle>: file them under HAVE or LACK
  if grep -c -F -- "$2" "$1" >/dev/null; then HAVE="$HAVE $1"; else LACK="$LACK $1"; fi
}
mark BubbleTextView.java drawMediaRingIfNecessary
mark Launcher.java app.nowhere.MEDIA_PROGRESS
mark views/DoubleShadowBubbleTextView.java drawMediaRingIfNecessary
if [ -z "$LACK" ]; then
  echo "launcher3-media-progress-ring: already applied"; exit 0
fi
if [ -n "$HAVE" ]; then
  echo "launcher3-media-progress-ring: HALF-APPLIED --${HAVE# } patched,${LACK# } not; restore them from their .endospore-orig copies (or git -C $TREE/packages/apps/Launcher3 checkout -- src/) and re-run" >&2
  exit 3
fi
run_hunk() { "$1" | patch -p0 --forward --fuzz="$2" ${3:+"$3"}; } # <hunk fn> <fuzz> [--dry-run]
anchor() { # <file> <hunk fn>: the hunk's innermost leading context line must be a whole line of <file>
  local line
  line=$("$2" | awk '/^\+\+\+ /{next} /^ /{c=substr($0,2); next} /^\+/{print c; exit}')
  [ -n "$line" ] && grep -Fx -- "$line" "$1" >/dev/null || {
    echo "launcher3-media-progress-ring: $1 lost the context line its hunk anchors on (upstream drift?) -- nothing written" >&2
    exit 2
  }
}
dryrun() { # <file> <hunk fn> <fuzz>
  local out
  anchor "$1" "$2"
  out=$(run_hunk "$2" "$3" --dry-run 2>&1) || {
    echo "launcher3-media-progress-ring: $1 does not take its hunk (upstream drift?) -- nothing written" >&2
    echo "$out" >&2; exit 2
  }
}
hunk_btv() {
cat <<'PATCH_BTV'
--- BubbleTextView.java
+++ BubbleTextView.java
@@ -934,6 +934,48 @@
         super.onDraw(canvas);
         drawDotIfNecessary(canvas);
         drawRunningAppIndicatorIfNecessary(canvas);
+        drawMediaRingIfNecessary(canvas); // #129: offline-media prefetch progress ring
+    }
+
+    // #129: pkg -> Tier-2 prefetch percent (0..100). Set by Launcher's cross-user MEDIA_PROGRESS receiver;
+    // a volatile map swap keeps the UI-thread read in onDraw lock-free. Empty map (idle) skips all drawing.
+    private static volatile java.util.Map<String, Integer> sMediaProgress = java.util.Collections.emptyMap();
+    private Paint mMediaRingPaint;
+
+    public static void setMediaProgress(java.util.Map<String, Integer> p) {
+        sMediaProgress = (p == null) ? java.util.Collections.<String, Integer>emptyMap() : p;
+    }
+
+    // #129: draw an iOS-style progress arc around an icon whose app is currently prefetching offline media
+    // (0 < pct < 100). Mirrors drawDotIfNecessary's icon-bounds + scroll-translate approach.
+    protected void drawMediaRingIfNecessary(Canvas canvas) {
+        java.util.Map<String, Integer> prog = sMediaProgress;
+        if (prog.isEmpty() || !(getTag() instanceof ItemInfoWithIcon)) {
+            return;
+        }
+        String pkg = ((ItemInfoWithIcon) getTag()).getTargetPackage();
+        if (pkg == null) {
+            return;
+        }
+        Integer pct = prog.get(pkg);
+        if (pct == null || pct <= 0 || pct >= 100) {
+            return; // no ring when idle or complete
+        }
+        Rect b = new Rect();
+        getIconBounds(b);
+        if (mMediaRingPaint == null) {
+            mMediaRingPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
+            mMediaRingPaint.setStyle(Paint.Style.STROKE);
+            mMediaRingPaint.setStrokeCap(Paint.Cap.ROUND);
+            mMediaRingPaint.setColor(0xFF4A90D9);
+        }
+        float sw = Math.max(3f, b.width() * 0.055f);
+        mMediaRingPaint.setStrokeWidth(sw);
+        RectF oval = new RectF(b.left + sw, b.top + sw, b.right - sw, b.bottom - sw);
+        int sx = getScrollX(), sy = getScrollY();
+        canvas.translate(sx, sy);
+        canvas.drawArc(oval, -90f, 360f * pct / 100f, false, mMediaRingPaint);
+        canvas.translate(-sx, -sy);
     }

     protected void drawSelectedBackgroundIfNecessary(Canvas canvas) {
PATCH_BTV
}
hunk_launcher() {
cat <<'PATCH_LAUNCHER'
--- Launcher.java
+++ Launcher.java
@@ -1109,10 +1109,47 @@
     protected void onResume() {
         TraceHelper.INSTANCE.beginSection(ON_RESUME_EVT);
         super.onResume();
         mLauncherUiState.setIsResumedActivity(true);
         DragView.removeAllViews(this);
+        // #129: while resumed, receive the roamed session's per-app media-prefetch progress (sent cross-user
+        // by the device-owner chooser) and repaint the icon rings.
+        try {
+            registerReceiver(mMediaProgressReceiver,
+                    new android.content.IntentFilter("app.nowhere.MEDIA_PROGRESS"),
+                    android.content.Context.RECEIVER_EXPORTED);
+        } catch (Throwable ignore) {}
         TraceHelper.INSTANCE.endSection();
     }

+    // #129: cross-user media-prefetch progress -> Launcher3 icon rings. Extra "prog" = the daemon's
+    // GET-MEDIA-APP-PROGRESS lines ("pkg done total STATUS\n...") relayed by the chooser. Initialized at
+    // construction (before onResume), so the register above sees it.
+    private final android.content.BroadcastReceiver mMediaProgressReceiver = new android.content.BroadcastReceiver() {
+        @Override public void onReceive(android.content.Context context, android.content.Intent intent) {
+            java.util.HashMap<String, Integer> m = new java.util.HashMap<>();
+            String prog = intent.getStringExtra("prog");
+            if (prog != null) {
+                for (String ln : prog.split("\n")) {
+                    String[] f = ln.trim().split(" ");
+                    if (f.length >= 3) {
+                        try {
+                            long done = Long.parseLong(f[1]), total = Long.parseLong(f[2]);
+                            m.put(f[0], total > 0 ? (int) (done * 100 / total) : 0);
+                        } catch (NumberFormatException ignore) {}
+                    }
+                }
+            }
+            BubbleTextView.setMediaProgress(m);
+            if (getWorkspace() != null) {
+                getWorkspace().mapOverItems((info, view) -> {
+                    if (view instanceof BubbleTextView) {
+                        view.invalidate();
+                    }
+                    return false;
+                });
+            }
+        }
+    };
+
     @Override
     protected void onPause() {
@@ -1128,4 +1166,5 @@
         mAppWidgetHolder.setActivityResumed(false);
+        try { unregisterReceiver(mMediaProgressReceiver); } catch (Throwable ignore) {} // #129
     }

     /**
PATCH_LAUNCHER
}
hunk_dsbtv() {
cat <<'PATCH_DSBTV'
--- views/DoubleShadowBubbleTextView.java
+++ views/DoubleShadowBubbleTextView.java
@@ -135,6 +135,7 @@

         drawDotIfNecessary(canvas);
         drawRunningAppIndicatorIfNecessary(canvas);
+        drawMediaRingIfNecessary(canvas); // #129: media prefetch ring on shadowed (workspace/hotseat) icons
     }

     private boolean skipDoubleShadow() {
PATCH_DSBTV
}
dryrun BubbleTextView.java hunk_btv 3
dryrun Launcher.java hunk_launcher 3
dryrun views/DoubleShadowBubbleTextView.java hunk_dsbtv 3
for f in BubbleTextView.java Launcher.java views/DoubleShadowBubbleTextView.java; do
  cp -n "$f" "$f.endospore-orig"
done
run_hunk hunk_btv 3
run_hunk hunk_launcher 3
run_hunk hunk_dsbtv 3
grep -q drawMediaRingIfNecessary BubbleTextView.java \
  && grep -q drawMediaRingIfNecessary views/DoubleShadowBubbleTextView.java \
  && grep -q 'app.nowhere.MEDIA_PROGRESS' Launcher.java \
  && echo "launcher3-media-progress-ring: applied + verified" \
  || { echo "launcher3-media-progress-ring: VERIFY FAILED" >&2; exit 1; }
