package com.nowhere.chooser;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.drawable.Drawable;
import android.text.method.PasswordTransformationMethod;
import android.text.method.TransformationMethod;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;

/**
 * Chester #81: a tap-to-reveal control INSIDE every masked credential field.
 *
 * WHY NOT TextInputLayout. Material Components ships exactly this
 * ({@code app:endIconMode="password_toggle"}) and the prebuilt IS in the tree
 * (prebuilts/sdk/current/extras/material-design-x). It is still the wrong tool here: TextInputLayout throws at
 * construction unless the host theme descends from Theme.MaterialComponents -- not optional, it reads style
 * attributes that exist nowhere else -- and the chooser has no XML theme at all. Every view is built in code
 * against the platform default with our own colours, so adopting a Material theme would restyle the whole gate
 * to fix one field. Its filled/outlined box with a floating label is also not what our fields look like.
 *
 * WHY NOT A COMPOUND DRAWABLE. Setting the eye via setCompoundDrawablesWithIntrinsicBounds + an OnTouchListener
 * needs no call-site changes at all, which is tempting. But a drawable inside an EditText is NOT an
 * accessibility node: TalkBack cannot see it, cannot announce it, and cannot activate it. Since this reveals a
 * credential, that is the one control on the screen a screen-reader user most needs to be able to find. This
 * codebase already pays that cost elsewhere on purpose (see the #152 contentDescription on the gate's "?" and
 * gear glyphs), so a real focusable button it is.
 *
 * WHAT THIS IS. {@link #wrap} puts the field and a genuine clickable ImageView in a FrameLayout, right-aligned,
 * and pads the field so text never runs under the icon. The button carries a contentDescription that flips
 * between "Show passphrase" and "Hide passphrase" so a screen reader announces the ACTION and the current state.
 *
 * SECURITY. Revealing is per-field and never sticky: {@link #maskAll} re-masks every field under a view tree and
 * is called whenever a screen loses the foreground, so a revealed credential cannot linger on screen for the
 * next person to read -- the same rule the gate's old "Show passphrase" TextView followed.
 */
final class PassReveal {

    private PassReveal() {}

    /**
     * Wrap {@code f} so it carries its own reveal toggle, and return the view to add to the layout IN ITS PLACE.
     * The caller keeps its reference to the EditText -- only what gets added to the parent changes.
     */
    static View wrap(EditText f, int tint) {
        return new RevealBox(f.getContext(), f, tint, null);
    }

    /** #96 (DIA-20260813-17): wrap with a GROUP -- every RevealBox sharing {@code group} (same object identity)
     *  under the same content view toggles TOGETHER, so a type-it-twice pair (passphrase + confirm) reveals with
     *  one tap. Opt-in per call site: single fields (Wi-Fi password, SIM PIN) and deliberately-separate secrets
     *  (change-passphrase's CURRENT passphrase) keep per-field toggles. This restores the linked behaviour the
     *  gate's pre-#639 "Show passphrase" TextView had, without giving up #639's per-field control or its
     *  accessibility contract: the group toggle drives each member's own setRevealed, so every button's
     *  Show/Hide announcement stays correct, maskAll still re-masks everything on pause, and lockGateForm's
     *  setToggleEnabled still greys each member individually. */
    static View wrap(EditText f, int tint, Object group) {
        return new RevealBox(f.getContext(), f, tint, group);
    }

    /** Drive every group member under {@code root} -- the same traversal shape as maskAll, keyed by identity. */
    private static void revealGroup(View root, Object group, boolean on) {
        if (root instanceof RevealBox) {
            RevealBox b = (RevealBox) root;
            if (b.group == group) b.setRevealed(on);
            return;
        }
        if (root instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) root;
            for (int i = 0; i < g.getChildCount(); i++) revealGroup(g.getChildAt(i), group, on);
        }
    }

    /** Re-mask every wrapped field under {@code root}. Call from onPause: a revealed credential must not survive
     *  losing the foreground (screen off, task switch, user switch). */
    static void maskAll(View root) {
        if (root == null) return;
        if (root instanceof RevealBox) { ((RevealBox) root).setRevealed(false); return; }
        if (root instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) root;
            for (int i = 0; i < g.getChildCount(); i++) maskAll(g.getChildAt(i));
        }
    }

    /** Set the reveal state of the box wrapping {@code f}, if it has one. Lets a screen drive the toggle itself
     *  (the gate re-masks on reset, and reveals after generating a passphrase the user has not seen yet). */
    static void setRevealed(EditText f, boolean on) {
        RevealBox b = boxOf(f);
        if (b != null) b.setRevealed(on);
    }

    /** Grey the toggle with its field. The gate disables the whole form mid-login (lockGateForm) and the toggle
     *  is a SIBLING of the field, not a child -- so disabling the EditText alone would leave the one control
     *  that puts a credential on screen still live behind a locked form. */
    static void setToggleEnabled(EditText f, boolean enabled, float alpha) {
        RevealBox b = boxOf(f);
        if (b != null) b.setToggleEnabled(enabled, alpha);
    }

    /** Hide the toggle entirely for fields where reveal is not wanted. The cold-lock resume screen uses this for
     *  a NUMERIC PIN: that was a deliberate call (a short PIN is far less error-prone than a passphrase, so the
     *  reveal buys little and costs shoulder-surfing risk), and this keeps it, rather than silently reversing it. */
    static void setToggleVisible(EditText f, boolean visible) {
        RevealBox b = boxOf(f);
        if (b != null) b.setToggleVisible(visible);
    }

    /** Show/hide a wrapped field. Must be used instead of {@code f.setVisibility()}: hiding the EditText alone
     *  leaves its toggle on screen AND leaves the wrapper occupying its layout margin, so the gap the field left
     *  behind never closes. Falls back to the field itself if it was never wrapped. */
    static void setFieldVisible(EditText f, boolean visible) {
        if (f == null) return;
        RevealBox b = boxOf(f);
        View target = (b != null) ? b : f;
        target.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (!visible && b != null) b.setRevealed(false);  // never leave a hidden field revealed for its next show
    }

    private static RevealBox boxOf(EditText f) {
        if (f == null) return null;
        Object p = f.getParent();
        return (p instanceof RevealBox) ? (RevealBox) p : null;
    }

    /** A field plus its toggle. Named so {@link #maskAll} can find these by type -- no View tags to collide with
     *  whatever else the screens store there, and no static registry to keep in step with activity lifetimes. */
    private static final class RevealBox extends FrameLayout {
        private final EditText field;
        private final ImageView button;
        private final EyeDrawable eye;
        private final Object group; // #96: null = per-field toggle; non-null = one tap drives every same-group box
        private boolean revealed = false;

        RevealBox(Context c, EditText f, int tint, Object group) {
            super(c);
            this.field = f;
            this.group = group;
            float d = c.getResources().getDisplayMetrics().density;
            int touch = Math.round(44 * d);        // a comfortable target; the drawn eye is ~20dp inside it

            // The field fills the box. Pad its right edge so long text scrolls out from UNDER the icon rather
            // than sitting behind it -- keep the existing vertical/left padding the builder chose.
            f.setPadding(f.getPaddingLeft(), f.getPaddingTop(), touch, f.getPaddingBottom());
            addView(f, new FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));

            eye = new EyeDrawable(tint, d);
            button = new ImageView(c);
            button.setImageDrawable(eye);
            button.setScaleType(ImageView.ScaleType.CENTER);
            button.setClickable(true);
            // focusable for TalkBack, but NOT focusableInTouchMode: tapping it must not pull focus off the field
            // and drop the keyboard mid-entry.
            button.setFocusable(true);
            button.setBackground(null);
            button.setOnClickListener(v -> {
                boolean on = !revealed;
                if (group == null) setRevealed(on);
                else revealGroup(getRootView(), group, on); // #96: the whole pair follows one tap
            });
            addView(button, new FrameLayout.LayoutParams(touch, LayoutParams.MATCH_PARENT, Gravity.END | Gravity.CENTER_VERTICAL));

            applyState();   // establishes the masked transformation + the initial contentDescription
        }

        void setRevealed(boolean on) {
            if (on == revealed) return;
            revealed = on;
            applyState();
        }

        void setToggleEnabled(boolean enabled, float alpha) {
            button.setEnabled(enabled);
            button.setAlpha(alpha);
            // A disabled toggle must not leave a credential on screen behind a locked form.
            if (!enabled && revealed) setRevealed(false);
        }

        void setToggleVisible(boolean visible) {
            button.setVisibility(visible ? VISIBLE : GONE);
            if (!visible && revealed) setRevealed(false);
            // Reclaim the reserved right padding when there is no icon to avoid, so a PIN still centres sensibly.
            float d = getContext().getResources().getDisplayMetrics().density;
            int pad = visible ? Math.round(44 * d) : Math.round(15 * d);
            field.setPadding(field.getPaddingLeft(), field.getPaddingTop(), pad, field.getPaddingBottom());
        }

        private void applyState() {
            // Selection is lost when the transformation method changes, so capture and restore it -- otherwise
            // the caret jumps to 0 and the next keystroke lands at the front of the passphrase.
            int s = field.getSelectionStart(), e = field.getSelectionEnd();
            TransformationMethod tm = revealed ? null : PasswordTransformationMethod.getInstance();
            field.setTransformationMethod(tm);
            try { if (s >= 0 && e >= 0) field.setSelection(s, e); } catch (Throwable ignored) {}
            eye.setSlashed(revealed);
            button.invalidate();
            // Announce the ACTION, not the icon: what a tap will do next.
            button.setContentDescription(revealed ? "Hide passphrase" : "Show passphrase");
        }
    }

    /** An own-drawn eye (outline + pupil), with a slash across it once the text is revealed -- the usual "tap to
     *  hide again" convention. Drawn rather than shipped as an asset, matching how the gate draws its own
     *  shield/help glyphs; also keeps the icon tintable to whatever the host screen's muted colour is. */
    private static final class EyeDrawable extends Drawable {
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        private final float d;
        private boolean slashed;

        EyeDrawable(int color, float density) {
            this.d = density;
            stroke.setStyle(Paint.Style.STROKE);
            stroke.setStrokeWidth(density * 1.6f);
            stroke.setStrokeCap(Paint.Cap.ROUND);
            stroke.setColor(color);
            fill.setStyle(Paint.Style.FILL);
            fill.setColor(color);
        }

        void setSlashed(boolean s) { slashed = s; invalidateSelf(); }

        @Override public int getIntrinsicWidth()  { return Math.round(22 * d); }
        @Override public int getIntrinsicHeight() { return Math.round(22 * d); }

        @Override public void draw(Canvas cv) {
            android.graphics.Rect b = getBounds();
            float cx = b.exactCenterX(), cy = b.exactCenterY();
            float w = Math.min(b.width(), b.height()) * 0.44f;  // half-width of the almond
            float h = w * 0.62f;                                // half-height

            // Almond: two symmetric quadratic curves meeting at the corners.
            path.reset();
            path.moveTo(cx - w, cy);
            path.quadTo(cx, cy - h * 2f, cx + w, cy);
            path.quadTo(cx, cy + h * 2f, cx - w, cy);
            cv.drawPath(path, stroke);
            cv.drawCircle(cx, cy, w * 0.30f, fill);

            if (slashed) {
                // Cut the slash with a background-coloured under-stroke so it reads as ON TOP of the eye rather
                // than merging into the outline where the two cross.
                float k = w * 0.86f;
                cv.drawLine(cx - k, cy - k, cx + k, cy + k, stroke);
            }
        }

        @Override public void setAlpha(int a) { stroke.setAlpha(a); fill.setAlpha(a); }
        @Override public void setColorFilter(android.graphics.ColorFilter cf) { stroke.setColorFilter(cf); fill.setColorFilter(cf); }
        @Override public int getOpacity() { return android.graphics.PixelFormat.TRANSLUCENT; }
    }
}
