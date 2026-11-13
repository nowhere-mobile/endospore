package com.nowhere.chooser;

import android.app.Dialog;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.util.List;
import java.util.function.Consumer;
import java.util.function.IntConsumer;

/**
 * NWP-20261201-28: draws a PopupSheet model as a bottom sheet in GatePalette.active()'s colours (design A,
 * docs/backlog.md "Popups are plain dialogs: ..."). No layout XML and no bitmaps. Back or a touch outside the sheet
 * only closes it. A tap closes the sheet first and then acts; the isShowing check keeps a second queued tap from acting
 * twice. A model that breaks a rule of PopupSheet is logged by count and shown anyway.
 */
final class SheetDialog {
    private SheetDialog() {}

    private static final int WRAP = LinearLayout.LayoutParams.WRAP_CONTENT;
    private static final int MATCH = LinearLayout.LayoutParams.MATCH_PARENT;

    /** A card per option. A tap on one closes the sheet and calls onPick with its index. */
    static void picker(Context ctx, PopupSheet.Picker m, IntConsumer onPick) {
        warn(PopupSheet.violations(m));
        if (m == null) return;
        GatePalette p = GatePalette.active();
        Dialog dlg = new Dialog(ctx);
        LinearLayout panel = panel(ctx, p);
        panel.addView(title(ctx, p, m.title), new LinearLayout.LayoutParams(MATCH, WRAP));
        for (int i = 0; i < m.options.size(); i++) {
            if (m.options.get(i) == null) continue;
            final int index = i;
            panel.addView(card(ctx, p, m.options.get(i), () -> {
                if (!dlg.isShowing()) return;
                dlg.dismiss();
                onPick.accept(index);
            }), topMargin(ctx, 10));
        }
        show(dlg, panel);
    }

    /** The tone icon, title, context and lines, then the buttons in model order. actions[i] runs after button i closes
     *  the sheet; a null action only closes it. A line with a linkKey closes the sheet and calls onLink with the key. */
    static void confirm(Context ctx, PopupSheet.Confirm m, Runnable[] actions, Consumer<String> onLink) {
        warn(PopupSheet.violations(m));
        if (m == null) return;
        GatePalette p = GatePalette.active();
        Dialog dlg = new Dialog(ctx);
        LinearLayout panel = panel(ctx, p);
        panel.addView(toneIcon(ctx, p, m.tone));
        panel.addView(title(ctx, p, m.title), topMargin(ctx, 12));
        TextView context = text(ctx, m.context, 14, p.muted);
        panel.addView(context, topMargin(ctx, 4));
        for (PopupSheet.Line l : m.lines) if (l != null) panel.addView(line(ctx, p, l, dlg, onLink), topMargin(ctx, 4));
        panel.addView(buttons(ctx, p, m, dlg, actions), topMargin(ctx, 16));
        show(dlg, panel);
    }

    private static void warn(List<String> breaches) {
        if (!breaches.isEmpty()) Log.w("NowhereChooser", "popup rules: " + breaches.size() + " breach(es)");
    }

    private static void show(Dialog dlg, LinearLayout panel) {
        dlg.requestWindowFeature(Window.FEATURE_NO_TITLE);
        ScrollView scroll = new ScrollView(dlg.getContext());
        scroll.addView(panel, new ViewGroup.LayoutParams(MATCH, WRAP));
        dlg.setContentView(scroll);
        Window w = dlg.getWindow();
        w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        w.setGravity(Gravity.BOTTOM);
        w.setLayout(MATCH, WRAP);
        dlg.setCanceledOnTouchOutside(true);
        dlg.show();
    }

    private static LinearLayout panel(Context ctx, GatePalette p) {
        LinearLayout panel = new LinearLayout(ctx);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(ctx, 20), dp(ctx, 20), dp(ctx, 20), dp(ctx, 20));
        float r = dp(ctx, 20);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(p.panel);
        bg.setCornerRadii(new float[] { r, r, r, r, 0, 0, 0, 0 });
        panel.setBackground(bg);
        return panel;
    }

    private static View card(Context ctx, GatePalette p, PopupSheet.Option o, Runnable tap) {
        LinearLayout card = new LinearLayout(ctx);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setBaselineAligned(false);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setPadding(dp(ctx, 14), dp(ctx, 12), dp(ctx, 14), dp(ctx, 12));
        card.setMinimumHeight(dp(ctx, 48));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(p.fieldBg);
        bg.setCornerRadius(dp(ctx, 14));
        bg.setStroke(dp(ctx, 2), o.current ? p.accent : p.fieldLn);
        card.setBackground(bg);
        card.setContentDescription(o.current ? o.name + ", current" : o.name);
        card.setSoundEffectsEnabled(false);
        card.setOnClickListener(v -> tap.run());

        card.addView(new StepIcon(ctx, p, PresetPicker.scalePos(o.name)),
                new LinearLayout.LayoutParams(dp(ctx, 40), dp(ctx, 40)));

        LinearLayout body = new LinearLayout(ctx);
        body.setOrientation(LinearLayout.VERTICAL);
        TextView name = text(ctx, o.current ? o.name + " " + PopupSheet.CURRENT_SUFFIX : o.name, 16, p.ink);
        body.addView(name, new LinearLayout.LayoutParams(MATCH, WRAP));
        if (!o.chips.isEmpty()) {
            LinearLayout chips = new LinearLayout(ctx);
            chips.setOrientation(LinearLayout.HORIZONTAL);
            chips.setBaselineAligned(false);
            for (int i = 0; i < o.chips.size(); i++) {
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(WRAP, WRAP);
                if (i > 0) lp.leftMargin = dp(ctx, 6);
                chips.addView(chip(ctx, p, o.chips.get(i)), lp);
            }
            body.addView(chips, topMargin(ctx, 6));
        }
        if (o.description != null && !o.description.isEmpty()) {
            body.addView(text(ctx, o.description, 13, p.muted), topMargin(ctx, 6));
        }
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0, WRAP, 1f);
        blp.leftMargin = dp(ctx, 12);
        card.addView(body, blp);

        if (o.current) {
            TextView check = text(ctx, "✓", 18, p.accent);
            LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(WRAP, WRAP);
            clp.leftMargin = dp(ctx, 8);
            card.addView(check, clp);
        }
        return card;
    }

    private static TextView chip(Context ctx, GatePalette p, String words) {
        TextView t = text(ctx, words, 12, p.ink);
        t.setPadding(dp(ctx, 8), dp(ctx, 3), dp(ctx, 8), dp(ctx, 3));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(ctx, 10));
        bg.setStroke(dp(ctx, 1), p.outline);
        t.setBackground(bg);
        return t;
    }

    private static TextView title(Context ctx, GatePalette p, String words) {
        TextView t = text(ctx, words, 18, p.ink);
        t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    private static View toneIcon(Context ctx, GatePalette p, PopupSheet.Tone tone) {
        int colour = tone == PopupSheet.Tone.WARNING ? p.warn
                : tone == PopupSheet.Tone.DESTRUCTIVE ? p.danger : p.accent;
        String glyph = tone == PopupSheet.Tone.WARNING ? "!" : tone == PopupSheet.Tone.DESTRUCTIVE ? "×" : "✓";
        TextView t = text(ctx, glyph, 22, p.onAccent);
        t.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(colour);
        t.setBackground(bg);
        t.setLayoutParams(new LinearLayout.LayoutParams(dp(ctx, 44), dp(ctx, 44)));
        t.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        return t;
    }

    private static View line(Context ctx, GatePalette p, PopupSheet.Line l, Dialog dlg, Consumer<String> onLink) {
        boolean link = l.linkKey != null;
        LinearLayout row = new LinearLayout(ctx);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setBaselineAligned(false);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(ctx, 4), 0, dp(ctx, 4));
        TextView icon = text(ctx, link ? "›" : "•", 14, link ? p.accent : p.muted);
        icon.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        row.addView(icon, new LinearLayout.LayoutParams(dp(ctx, 16), WRAP));
        TextView t = text(ctx, l.text, 14, link ? p.accent : p.muted);
        row.addView(t, new LinearLayout.LayoutParams(0, WRAP, 1f));
        if (link) {
            t.setPaintFlags(t.getPaintFlags() | Paint.UNDERLINE_TEXT_FLAG);
            row.setMinimumHeight(dp(ctx, 48));
            row.setSoundEffectsEnabled(false);
            row.setOnClickListener(v -> {
                if (!dlg.isShowing()) return;
                dlg.dismiss();
                if (onLink != null) onLink.accept(l.linkKey);
            });
        }
        return row;
    }

    /** A routine sheet's buttons sit side by side; a warning's and a destructive sheet's are stacked. */
    private static View buttons(Context ctx, GatePalette p, PopupSheet.Confirm m, Dialog dlg, Runnable[] actions) {
        boolean beside = m.tone == PopupSheet.Tone.ROUTINE;
        LinearLayout row = new LinearLayout(ctx);
        row.setOrientation(beside ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        row.setBaselineAligned(false);
        for (int i = 0; i < m.buttons.size(); i++) {
            if (m.buttons.get(i) == null) continue;
            final Runnable action = actions != null && i < actions.length ? actions[i] : null;
            Button b = button(ctx, p, m.buttons.get(i));
            b.setOnClickListener(v -> {
                if (!dlg.isShowing()) return;
                dlg.dismiss();
                if (action != null) action.run();
            });
            LinearLayout.LayoutParams lp = beside ? new LinearLayout.LayoutParams(0, WRAP, 1f)
                    : new LinearLayout.LayoutParams(MATCH, WRAP);
            if (i > 0) {
                if (beside) lp.leftMargin = dp(ctx, 8);
                else lp.topMargin = dp(ctx, 8);
            }
            row.addView(b, lp);
        }
        return row;
    }

    private static Button button(Context ctx, GatePalette p, PopupSheet.Button m) {
        Button b = new Button(ctx);
        b.setText(m.label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(ctx, 13));
        if (m.style == PopupSheet.Style.GREEN_FILLED) {
            bg.setColor(p.accent);
            b.setTextColor(p.onAccent);
        } else if (m.style == PopupSheet.Style.RED_FILLED) {
            bg.setColor(p.danger);
            b.setTextColor(p.onAccent);
        } else if (m.style == PopupSheet.Style.RED_OUTLINED) {
            bg.setStroke(dp(ctx, 1), p.danger);
            b.setTextColor(p.danger);
        } else {
            bg.setStroke(dp(ctx, 1), p.muted);
            b.setTextColor(p.ink);
        }
        b.setBackground(bg);
        b.setStateListAnimator(null);
        b.setSoundEffectsEnabled(false);
        b.setMinHeight(dp(ctx, 48));
        b.setMinimumHeight(dp(ctx, 48));
        return b;
    }

    private static TextView text(Context ctx, String words, int sp, int colour) {
        TextView t = new TextView(ctx);
        t.setText(words);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setTextColor(colour);
        return t;
    }

    private static LinearLayout.LayoutParams topMargin(Context ctx, int top) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(MATCH, WRAP);
        lp.topMargin = dp(ctx, top);
        return lp;
    }

    private static int dp(Context ctx, int v) {
        return Math.round(v * ctx.getResources().getDisplayMetrics().density);
    }

    /** A round icon: a mini five-step scale with one step filled, or a ring when step is off the scale. */
    private static final class StepIcon extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final GatePalette p;
        private final int step;

        StepIcon(Context ctx, GatePalette p, int step) {
            super(ctx);
            this.p = p;
            this.step = step;
        }

        @Override protected void onDraw(Canvas c) {
            float w = getWidth();
            float h = getHeight();
            float r = Math.min(w, h) / 2f;
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(p.panel);
            c.drawCircle(w / 2f, h / 2f, r, paint);
            if (step < 0) {
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(r * 0.18f);
                paint.setColor(p.accent);
                c.drawCircle(w / 2f, h / 2f, r * 0.55f, paint);
                return;
            }
            int steps = PresetPicker.SCALE.size();
            float slot = r * 1.2f / steps;
            float left = w / 2f - r * 0.6f;
            float bottom = h / 2f + r * 0.45f;
            for (int i = 0; i < steps; i++) {
                paint.setColor(i == step ? p.accent : p.fieldLn);
                float top = bottom - r * 0.9f * (i + 1) / steps;
                c.drawRect(left + i * slot, top, left + (i + 1) * slot - r * 0.06f, bottom, paint);
            }
        }
    }
}
