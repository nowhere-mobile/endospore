#!/bin/bash
# NWP-20260823-05 (+ -15): FallbackHome shows a styled cover -- "Resuming..." for a roamed user, and
# "Finishing booting..." for user 0 OVER the #160 boot brand.
#
# WHY A SOURCE PATCH: the D4/#160 FallbackHome overlay (the boot-brand windowBackground + stripped spinner
# layout) applies to the Settings APK, i.e. to EVERY user. A NON-ZERO user only ever meets FallbackHome in one
# place -- the cold-lock RESUME's CE-unlock window, after the user switch and before Launcher3 (not
# direct-boot-aware) can start -- and there the boot-brand image (spore cluster + wordmark + tagline) reads as
# "the boot screen" in the middle of a resume (Chester, 2026-08-23, screenshot). An RRO cannot branch on user,
# so the branch lives in FallbackHome.java: user 0 keeps the brand image (seamless with the boot animation,
# the whole point of #160); any other user gets the transition-cover style -- wordmark + "Resuming…" +
# spinner -- matching the gate's buildCoverView family.
#
# ⚠ KNOWN RESIDUE, accepted: the activity's STARTING window is drawn by the system from the THEME before this
# code runs, so a sub-second flash of the brand image can precede the resume view. Removing that too would
# need a per-user theme, which does not exist.
#
# Two hunks, both idempotent, both anchored on lines GrapheneOS tracks from AOSP:
#   1. onCreate: after super.onCreate -- build + show a cover for EVERY user. The branch is on WHAT is
#      drawn, not on WHETHER: user 0 keeps the #160 brand windowBackground and gains a low "Finishing
#      booting..." status line; a non-zero user gets an opaque black cover with "Resuming...".
#   2. mProgressTimeoutRunnable: `if (true) return;` -- bails for EVERY user, because the stock stripped
#      layout is TRANSPARENT and would blank the words ~2 s in, for user 0 as much as for a roamed one.
#
# NOTE this summary said "for myUserId() != 0" and "bail for non-zero users" until 2026-09-03. That was
# the pre--15 behaviour and it had drifted from the code below, which -15 widened to every user -- so the
# header claimed user 0 was untouched while the patch was changing user 0's boot frame.
# Usage: settings-fallbackhome-resume.sh <tree>   (auto-run by build-device.sh's patch pass)
set -e
TREE="${1:?usage: $0 <tree>}"
F="$TREE/packages/apps/Settings/src/com/android/settings/FallbackHome.java"
[ -f "$F" ] || { echo "no FallbackHome.java at $F" >&2; exit 1; }

if grep -q "nowhere-resume (NWP-20260823-05)" "$F"; then echo "already applied (no change)"; exit 0; fi

python3 - "$F" <<'PY'
import io, sys
path = sys.argv[1]
s = io.open(path, encoding='utf-8').read()

# ---- hunk 1: the resume view for non-zero users --------------------------------------------------
anchor = ("    protected void onCreate(Bundle savedInstanceState) {\n"
          "        super.onCreate(savedInstanceState);\n")
if s.count(anchor) != 1:
    sys.exit("onCreate anchor not found exactly once -- upstream changed, patch by hand")
inject = anchor + """        // nowhere-resume (NWP-20260823-05): a non-zero user only ever sees FallbackHome during a
        // cold-lock RESUME's CE-unlock window, where the boot brand reads as "the boot screen" mid-resume.
        //
        // NWP-20260823-15: user 0 now gets a cover too, because this is the ONLY boot frame that can carry
        // WORDS. Chester asked twice for "endospore / Finishing booting..."; the frame after this one is the
        // Android 12 SPLASH WINDOW, which the system draws from the theme before any app code runs and which
        // CANNOT render text at all -- the most it can carry is windowSplashScreenBrandingImage, a static
        // image. FallbackHome is a real activity, so text is simply a TextView.
        //
        // The two differ in what they keep behind the words: user 0 KEEPS the #160 brand windowBackground
        // (the spore cluster + wordmark, seamless with the end of the boot animation) and only adds a status
        // line low on the screen; a roamed user gets an opaque black cover instead, because the brand image
        // mid-resume is exactly what read wrong.
        {
            final boolean bootUser = android.os.UserHandle.myUserId() == 0;
            if (!bootUser) {
                getWindow().setBackgroundDrawable(
                        new android.graphics.drawable.ColorDrawable(0xFF000000));
            }
            float dp = getResources().getDisplayMetrics().density;
            android.widget.LinearLayout col = new android.widget.LinearLayout(this);
            col.setOrientation(android.widget.LinearLayout.VERTICAL);
            col.setGravity(bootUser
                    ? (android.view.Gravity.CENTER_HORIZONTAL | android.view.Gravity.BOTTOM)
                    : android.view.Gravity.CENTER);
            if (!bootUser) {
                col.setBackgroundColor(0xFF000000);
            }
            android.widget.TextView brand = new android.widget.TextView(this);
            brand.setText("endospore");
            // The brand image already carries the wordmark for user 0 -- don't print it twice.
            brand.setVisibility(bootUser ? android.view.View.GONE : android.view.View.VISIBLE);
            brand.setTextColor(0xFFEAF1EE);
            brand.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 34);
            col.addView(brand, new android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT));
            android.widget.TextView sub = new android.widget.TextView(this);
            sub.setText(bootUser ? "Finishing booting\\u2026" : "Resuming\\u2026");
            sub.setTextColor(0xFF4FD6AC);
            sub.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 15);
            android.widget.LinearLayout.LayoutParams subLp = new android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT);
            subLp.topMargin = (int) (6 * dp);
            col.addView(sub, subLp);
            android.widget.ProgressBar spin = new android.widget.ProgressBar(
                    this, null, android.R.attr.progressBarStyleHorizontal);
            spin.setIndeterminate(true);
            spin.setIndeterminateTintList(
                    android.content.res.ColorStateList.valueOf(0xFF4FD6AC));
            android.widget.LinearLayout.LayoutParams spLp = new android.widget.LinearLayout.LayoutParams(
                    (int) (160 * dp), android.widget.LinearLayout.LayoutParams.WRAP_CONTENT);
            spLp.topMargin = (int) (22 * dp);
            col.addView(spin, spLp);
            if (bootUser) {
                col.setPadding(0, 0, 0, (int) (96 * dp)); // clear of the brand artwork above
            }
            setContentView(col);
        }
"""
s = s.replace(anchor, inject, 1)

# ---- hunk 2: the stock delayed layout must not replace the resume view ---------------------------
anchor2 = "    private final Runnable mProgressTimeoutRunnable = () -> {\n"
if s.count(anchor2) != 1:
    sys.exit("mProgressTimeoutRunnable anchor not found exactly once -- upstream changed, patch by hand")
inject2 = anchor2 + """        // nowhere-resume (NWP-20260823-05, widened by -15): the cover view is already up for EVERY user
        // now, and the stock stripped layout is TRANSPARENT -- letting it run would blank the words a couple
        // of seconds in, which is the whole point of drawing them.
        if (true) return;
"""
s = s.replace(anchor2, inject2, 1)

io.open(path, 'w', encoding='utf-8', newline='\n').write(s)
print("applied: FallbackHome cover -- brand + 'Finishing booting' for user 0, black + 'Resuming' otherwise")
PY
