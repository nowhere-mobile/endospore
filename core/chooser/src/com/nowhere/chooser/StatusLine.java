package com.nowhere.chooser;

import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.SystemClock;
import android.text.SpannableStringBuilder;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.ReplacementSpan;
import android.widget.TextView;

/**
 * NWP-20261007-13: one look for an inline status line -- the line under a form's button, or the line that stands in
 * for content while it loads. Busy is the accent teal with a small spinner in front of the text; an error is soft red.
 * Chester, lynx 2026100701: a tie that runs for minutes needs "some kind of busy sign", and a busy line should not
 * share its grey with an error in the same place. Before this a wrong passphrase and "working…" looked the same.
 *
 * The colour and the spinner ride the TEXT as spans, never the view's text colour. So whatever the line shows next
 * through a plain setText -- a result, a hint -- is in that line's own colour, and the spinner stops by itself the
 * moment its text is replaced: a branch that forgets this class cannot leave a line stuck teal, or spinning.
 * Nothing else on the screen is disabled or greyed by it; a Back that works while a list loads keeps working.
 *
 * NWP-20261115-15: the teal and the red are the accent and error roles of GatePalette.active(), read when a line is
 * set: the gate's own look in the gate, and the same device look in a signed-in user's process, where ProfileActivity
 * calls GatePalette.use() with the look it reads from GatePalette.GLOBAL_KEY (NWP-20261117-21).
 * BUSY and ERROR stay as the dark values for the screens that read them by name.
 */
final class StatusLine {
    static final int BUSY  = 0xFF4FD6AC; // the chooser's ACCENT
    static final int ERROR = 0xFFE06C6C; // the soft red the chooser's remove/fail lines already use

    private StatusLine() {}

    /** Shows text as in progress: the spinner, then the text, both teal. */
    static void busy(TextView tv, CharSequence text) {
        SpannableStringBuilder sb = new SpannableStringBuilder(" ").append(text);
        Spinner sp = new Spinner(tv);
        sb.setSpan(sp, 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        sb.setSpan(new ForegroundColorSpan(GatePalette.active().accent), 1, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        tv.setText(sb);
        sp.run();
    }

    /** Shows text as an error: soft red, no spinner. */
    static void error(TextView tv, CharSequence text) {
        SpannableStringBuilder sb = new SpannableStringBuilder(text);
        sb.setSpan(new ForegroundColorSpan(GatePalette.active().error), 0, sb.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
        tv.setText(sb);
    }

    /** A teal arc sized to the line's text, turning while its text is on screen. It drives its own frames from the
     *  host view and stops at the first frame after the host's text no longer holds it. A host that is never attached
     *  holds the frame in its run queue rather than spinning. */
    private static final class Spinner extends ReplacementSpan implements Runnable {
        private static final long TURN_MS = 900;
        private final TextView host;
        private final Paint arc = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF box = new RectF();

        Spinner(TextView host) {
            this.host = host;
            arc.setStyle(Paint.Style.STROKE);
            arc.setStrokeCap(Paint.Cap.ROUND);
            arc.setColor(GatePalette.active().accent);
        }

        @Override
        public int getSize(Paint paint, CharSequence text, int start, int end, Paint.FontMetricsInt fm) {
            return Math.round(paint.getTextSize() * 1.45f); // the arc, then a gap before the text
        }

        @Override
        public void draw(Canvas canvas, CharSequence text, int start, int end, float x, int top, int y, int bottom,
                         Paint paint) {
            float size = paint.getTextSize();
            Paint.FontMetrics fm = paint.getFontMetrics();
            float cy = y + (fm.ascent + fm.descent) / 2f; // the middle of the text beside it
            float r = size * 0.4f;
            arc.setStrokeWidth(size * 0.12f);
            box.set(x + size * 0.1f, cy - r, x + size * 0.1f + 2 * r, cy + r);
            float angle = (SystemClock.uptimeMillis() % TURN_MS) * 360f / TURN_MS;
            canvas.drawArc(box, angle, 270f, false, arc);
        }

        @Override
        public void run() {
            CharSequence t = host.getText();
            if (!(t instanceof Spanned) || ((Spanned) t).getSpanStart(this) < 0) return; // replaced: stop
            host.invalidate();
            host.postDelayed(this, 33);
        }
    }
}
