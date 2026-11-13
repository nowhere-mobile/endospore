package com.nowhere.chooser;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.util.TypedValue;
import android.view.View;

/**
 * The pictures of the gate's Help combo screen (NWP-20261130-11), drawn in code, so there is no bitmap and the colours
 * are the gate's. One view with four kinds (GateHelpHome.ART_*): the hero's whole loop (phone, store, any phone, check)
 * and one picture for each intro step. All words come from GateHelpHome.HERO_NODES. The parent gives the size.
 */
final class GateHelpArtView extends View {
    private static final int INNER_NONE = 0, INNER_PERSON = 1, INNER_LOCK = 2;

    final int kind;
    private final GateHelpArt.Roles roles;
    private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint label = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final RectF box = new RectF();
    private final float labelPx, headMax;

    GateHelpArtView(Context c, int kind, GateHelpArt.Roles roles) {
        super(c);
        this.kind = kind;
        this.roles = roles;
        line.setStyle(Paint.Style.STROKE);
        line.setStrokeCap(Paint.Cap.ROUND);
        line.setStrokeJoin(Paint.Join.ROUND);
        line.setStrokeWidth(GateHelpScreen.dp(c, 1.5f));
        headMax = GateHelpScreen.dp(c, 8);
        fill.setStyle(Paint.Style.FILL);
        label.setTextAlign(Paint.Align.CENTER);
        labelPx = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 11, getResources().getDisplayMetrics());
    }

    @Override
    protected void onDraw(Canvas cv) {
        float w = getWidth(), h = getHeight();
        switch (kind) {
            case GateHelpHome.ART_HERO: hero(cv, w, h); break;
            case GateHelpHome.ART_ANY_PHONE: anyPhone(cv, w, h); break;
            case GateHelpHome.ART_SAVING: saving(cv, w, h); break;
            default: lock(cv, w, h); break;
        }
    }

    /** Four slots: phone -> store -> any phone -> check, with the three labels under the pictures. */
    private void hero(Canvas cv, float w, float h) {
        float slot = w / 4f;
        float labelSpace = labelPx * 1.8f;
        float cy = (h - labelSpace) / 2f;
        float size = Math.min(h - labelSpace, slot) * 0.8f;
        phone(cv, slot * 0.5f, cy, size, INNER_PERSON);
        store(cv, slot * 1.5f, cy, size * 0.7f);
        phone(cv, slot * 2.5f, cy, size, INNER_PERSON);
        check(cv, slot * 3.5f, cy, size * 0.3f);
        float gap = size * 0.44f; // clear of the store, the widest picture
        for (int i = 0; i < 3; i++) {
            arrow(cv, slot * (i + 0.5f) + gap, slot * (i + 1.5f) - gap, cy);
        }
        label.setColor(roles.body);
        label.setTextSize(labelPx);
        float widest = 0f;
        for (int i = 0; i < GateHelpHome.HERO_NODES.length; i++) {
            widest = Math.max(widest, label.measureText(GateHelpHome.HERO_NODES[i]));
        }
        // A large font scale shrinks the labels to their slots, so two labels never touch.
        if (widest > slot * 0.95f) label.setTextSize(labelPx * slot * 0.95f / widest);
        for (int i = 0; i < GateHelpHome.HERO_NODES.length; i++) {
            cv.drawText(GateHelpHome.HERO_NODES[i], slot * (i + 0.5f), h - labelPx * 0.4f, label);
        }
    }

    /** Intro step 1: the store in the middle, and a phone on each side receiving the profile. */
    private void anyPhone(Canvas cv, float w, float h) {
        float cy = h / 2f, size = Math.min(h * 0.8f, w / 3.5f);
        store(cv, w * 0.5f, cy, size * 0.8f);
        phone(cv, w * 0.15f, cy, size, INNER_PERSON);
        phone(cv, w * 0.85f, cy, size, INNER_PERSON);
        arrow(cv, w * 0.5f - size * 0.5f, w * 0.15f + size * 0.34f, cy);
        arrow(cv, w * 0.5f + size * 0.5f, w * 0.85f - size * 0.34f, cy);
    }

    /** Intro step 2: a phone sending the profile to the store, and a check. */
    private void saving(Canvas cv, float w, float h) {
        float cy = h / 2f, size = Math.min(h * 0.8f, w / 3.5f);
        phone(cv, w * 0.25f, cy, size, INNER_PERSON);
        arrow(cv, w * 0.25f + size * 0.34f, w * 0.72f - size * 0.5f, cy);
        store(cv, w * 0.72f, cy, size * 0.8f);
        check(cv, w * 0.72f + size * 0.4f, cy - size * 0.32f, size * 0.14f);
    }

    /** Intro step 3: a locked phone, then a phone sending the profile to the store. */
    private void lock(Canvas cv, float w, float h) {
        float cy = h / 2f, size = Math.min(h * 0.8f, w / 3.5f);
        phone(cv, w * 0.15f, cy, size, INNER_LOCK);
        phone(cv, w * 0.5f, cy, size, INNER_PERSON);
        arrow(cv, w * 0.5f + size * 0.34f, w * 0.85f - size * 0.5f, cy);
        store(cv, w * 0.85f, cy, size * 0.8f);
    }

    private void phone(Canvas cv, float cx, float cy, float height, int inner) {
        float hw = height * 0.28f, hh = height * 0.5f, corner = height * 0.07f;
        line.setColor(roles.ink);
        box.set(cx - hw, cy - hh, cx + hw, cy + hh);
        cv.drawRoundRect(box, corner, corner, line);
        cv.drawLine(cx - hw * 0.35f, cy + hh * 0.82f, cx + hw * 0.35f, cy + hh * 0.82f, line);
        if (inner == INNER_PERSON) {
            fill.setColor(roles.accent);
            cv.drawCircle(cx, cy - hh * 0.22f, hw * 0.3f, fill);
            box.set(cx - hw * 0.55f, cy + hh * 0.02f, cx + hw * 0.55f, cy + hh * 0.72f);
            cv.drawArc(box, 180f, 180f, true, fill);
        } else if (inner == INNER_LOCK) {
            padlock(cv, cx, cy, hw * 0.9f);
        }
    }

    /** The store: a box with a padlock on it. */
    private void store(Canvas cv, float cx, float cy, float size) {
        float hw = size * 0.5f, hh = size * 0.42f, corner = size * 0.1f;
        line.setColor(roles.ink);
        box.set(cx - hw, cy - hh, cx + hw, cy + hh);
        cv.drawRoundRect(box, corner, corner, line);
        padlock(cv, cx, cy, size * 0.42f);
    }

    private void padlock(Canvas cv, float cx, float cy, float size) {
        float hw = size * 0.5f, top = cy - size * 0.05f, corner = size * 0.1f;
        fill.setColor(roles.accent);
        box.set(cx - hw, top, cx + hw, top + size * 0.55f);
        cv.drawRoundRect(box, corner, corner, fill);
        line.setColor(roles.accent);
        box.set(cx - hw * 0.6f, top - size * 0.42f, cx + hw * 0.6f, top + size * 0.3f);
        cv.drawArc(box, 180f, 180f, false, line);
    }

    private void arrow(Canvas cv, float x0, float x1, float y) {
        float head = Math.min(Math.abs(x1 - x0) * 0.3f, headMax);
        float back = x1 > x0 ? x1 - head : x1 + head;
        line.setColor(roles.accent);
        cv.drawLine(x0, y, x1, y, line);
        path.reset();
        path.moveTo(back, y - head);
        path.lineTo(x1, y);
        path.lineTo(back, y + head);
        cv.drawPath(path, line);
    }

    private void check(Canvas cv, float cx, float cy, float r) {
        fill.setColor(roles.accent);
        cv.drawCircle(cx, cy, r, fill);
        line.setColor(roles.onAccent);
        path.reset();
        path.moveTo(cx - r * 0.45f, cy);
        path.lineTo(cx - r * 0.1f, cy + r * 0.38f);
        path.lineTo(cx + r * 0.5f, cy - r * 0.35f);
        cv.drawPath(path, line);
    }
}
