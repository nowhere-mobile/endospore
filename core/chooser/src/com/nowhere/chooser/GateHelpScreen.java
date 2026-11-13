package com.nowhere.chooser;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * The gate's Help combo screen (NWP-20261130-11; chosen by Chester on 2026-11-06, "Go with combo", NWP-20261105-27): a
 * hero card of the whole loop with "Watch the 3 steps", a three-step intro with Skip on every step, the topic tiles and
 * the "Forgot your passphrase?" card. The words are GateHelpHome's, the colours GatePalette's.
 *
 * Each screen is a view that ChooserActivity swaps in with setContentView, so Help stays inside Lock-Task. The gate's
 * onBackPressed does nothing, so each screen has its own way out. It holds no state and reads no pref, daemon reply or
 * profile name: the same static screen for everyone, so blind login holds.
 */
final class GateHelpScreen {
    private GateHelpScreen() {}

    /** What the screen asks of the gate. */
    interface Nav {
        /** Show this screen in place of the current one. */
        void show(View v);
        /** Back to the sign-in screen. */
        void close();
        /** Open the page of tile i. */
        void openTile(int i);
        /** Open the page of the Forgot card. */
        void openForgot();
    }

    /** The home screen: the hero card, the tiles, the Forgot card and Back. */
    static View home(Context c, GatePalette p, Nav nav) {
        GateHelpArt.Roles r = GateHelpArt.of(p);
        LinearLayout ll = page(c, r);

        TextView title = text(c, GateHelpPages.indexTitle(), r.ink, 26, true);
        ll.addView(title, wide());

        LinearLayout hero = new LinearLayout(c);
        hero.setOrientation(LinearLayout.VERTICAL);
        hero.setBackground(card(c, r.cardFill, r.cardEdge, 1));
        int pad = dp(c, 16);
        hero.setPadding(pad, pad, pad, pad);
        GateHelpArtView art = new GateHelpArtView(c, GateHelpHome.ART_HERO, r);
        art.setContentDescription(GateHelpHome.HERO_DESCRIPTION);
        hero.addView(art, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(c, 96)));
        LinearLayout.LayoutParams tlp = wide();
        tlp.topMargin = dp(c, 12);
        TextView heroTitle = text(c, GateHelpHome.HERO_TITLE, r.ink, 20, true);
        hero.addView(heroTitle, tlp);
        LinearLayout.LayoutParams blp = wide();
        blp.topMargin = dp(c, 4);
        hero.addView(text(c, GateHelpHome.HERO_BODY, r.body, 13, true), blp);
        Button watch = button(c, r, GateHelpHome.WATCH);
        watch.setContentDescription(GateHelpHome.WATCH_DESCRIPTION);
        watch.setOnClickListener(v -> nav.show(intro(c, p, 0, nav)));
        LinearLayout.LayoutParams wlp = wide();
        wlp.topMargin = dp(c, 12);
        hero.addView(watch, wlp);
        LinearLayout.LayoutParams hlp = wide();
        hlp.topMargin = dp(c, 16);
        ll.addView(hero, hlp);

        TextView topics = text(c, GateHelpHome.TOPICS_HEADING, r.body, 13, false);
        topics.setTypeface(Typeface.DEFAULT_BOLD);
        LinearLayout.LayoutParams hdr = wide();
        hdr.topMargin = dp(c, 20);
        hdr.bottomMargin = dp(c, 4);
        ll.addView(topics, hdr);
        // The tiles' own margins (4dp) reach the page's edge, so the grid has no margin here.
        ll.addView(new GateHelpTileGrid(c, r, nav), wide());

        ll.addView(forgotCard(c, r, nav), forgotParams(c));

        TextView back = text(c, GateHelpHome.BACK, r.accent, 14, true);
        int bp = dp(c, 16);
        back.setPadding(bp, bp, bp, bp);
        back.setContentDescription(GateHelpHome.BACK_DESCRIPTION);
        back.setOnClickListener(v -> nav.close());
        LinearLayout.LayoutParams backLp = wide();
        backLp.topMargin = dp(c, 8);
        ll.addView(back, backLp);
        return scroll(c, r, ll);
    }

    /** Intro step i: a picture, a title, two lines, the dots, Next (Done on the last) and Skip. */
    static View intro(Context c, GatePalette p, int step, Nav nav) {
        GateHelpArt.Roles r = GateHelpArt.of(p);
        LinearLayout ll = page(c, r);
        ll.setGravity(Gravity.CENTER_VERTICAL);
        String[] s = GateHelpHome.INTRO[step];

        GateHelpArtView art = new GateHelpArtView(c, GateHelpHome.INTRO_ART[step], r);
        art.setContentDescription(GateHelpHome.INTRO_ART_DESCRIPTIONS[step]);
        ll.addView(art, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(c, 160)));

        LinearLayout.LayoutParams tlp = wide();
        tlp.topMargin = dp(c, 24);
        ll.addView(text(c, s[0], r.ink, 22, true), tlp);
        LinearLayout.LayoutParams l1 = wide();
        l1.topMargin = dp(c, 10);
        ll.addView(text(c, s[1], r.body, 14, true), l1);
        LinearLayout.LayoutParams l2 = wide();
        l2.topMargin = dp(c, 6);
        ll.addView(text(c, s[2], r.body, 14, true), l2);

        LinearLayout.LayoutParams dlp = wide();
        dlp.topMargin = dp(c, 24);
        ll.addView(dots(c, r, step), dlp);

        Button next = button(c, r, GateHelpHome.nextLabel(step));
        next.setContentDescription(GateHelpHome.nextDescription(step));
        int following = GateHelpHome.introNext(step);
        next.setOnClickListener(v -> nav.show(following < 0 ? home(c, p, nav) : intro(c, p, following, nav)));
        LinearLayout.LayoutParams nlp = wide();
        nlp.topMargin = dp(c, 24);
        ll.addView(next, nlp);

        TextView skip = text(c, GateHelpHome.SKIP, r.accent, 14, true);
        int sp = dp(c, 16);
        skip.setPadding(sp, sp, sp, sp);
        skip.setContentDescription(GateHelpHome.SKIP_DESCRIPTION);
        skip.setOnClickListener(v -> nav.show(home(c, p, nav)));
        LinearLayout.LayoutParams slp = wide();
        slp.topMargin = dp(c, 8);
        ll.addView(skip, slp);
        return scroll(c, r, ll);
    }

    static int dp(Context c, float v) {
        return Math.round(v * c.getResources().getDisplayMetrics().density);
    }

    /** A rounded card: fill, and an edge of edgeDp. */
    static GradientDrawable card(Context c, int fill, int edge, int edgeDp) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill);
        g.setCornerRadius(dp(c, 13));
        g.setStroke(dp(c, edgeDp), edge);
        return g;
    }

    /** The highlighted card: an accent edge, the key, the title and one line. */
    private static View forgotCard(Context c, GateHelpArt.Roles r, Nav nav) {
        LinearLayout row = new LinearLayout(c);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setBackground(card(c, r.cardFill, r.accent, 2));
        int pad = dp(c, 14);
        row.setPadding(pad, pad, pad, pad);
        row.setContentDescription(GateHelpHome.forgotDescription());
        row.setFocusable(true);
        row.setOnClickListener(v -> nav.openForgot());

        ImageView key = new ImageView(c);
        key.setImageResource(R.drawable.ic_help_key);
        key.setImageTintList(ColorStateList.valueOf(r.accent));
        key.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        int size = dp(c, 28);
        row.addView(key, new LinearLayout.LayoutParams(size, size));

        LinearLayout words = new LinearLayout(c);
        words.setOrientation(LinearLayout.VERTICAL);
        words.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        TextView title = text(c, GateHelpHome.FORGOT_TITLE, r.ink, 15, false);
        title.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        words.addView(title, wide());
        TextView sub = text(c, GateHelpHome.FORGOT_SUB, r.body, 12, false);
        sub.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        words.addView(sub, wide());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.leftMargin = dp(c, 12);
        row.addView(words, lp);
        return row;
    }

    private static LinearLayout.LayoutParams forgotParams(Context c) {
        LinearLayout.LayoutParams lp = wide();
        int gap = dp(c, 4);
        lp.leftMargin = gap;
        lp.rightMargin = gap;
        lp.topMargin = dp(c, 12);
        return lp;
    }

    /** One dot a step, the current one in the accent. TalkBack reads the row once, from its description. */
    private static View dots(Context c, GateHelpArt.Roles r, int step) {
        LinearLayout row = new LinearLayout(c);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER);
        row.setContentDescription(GateHelpHome.dotsDescription(step));
        int size = dp(c, 8), gap = dp(c, 4);
        for (int i = 0; i < GateHelpHome.INTRO.length; i++) {
            View dot = new View(c);
            GradientDrawable g = new GradientDrawable();
            g.setShape(GradientDrawable.OVAL);
            g.setColor(i == step ? r.accent : r.dotOff);
            dot.setBackground(g);
            dot.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(size, size);
            lp.leftMargin = gap;
            lp.rightMargin = gap;
            row.addView(dot, lp);
        }
        return row;
    }

    private static LinearLayout page(Context c, GateHelpArt.Roles r) {
        LinearLayout ll = new LinearLayout(c);
        ll.setOrientation(LinearLayout.VERTICAL);
        ll.setBackgroundColor(r.screen);
        ll.setPadding(dp(c, 20), dp(c, 52), dp(c, 20), dp(c, 24));
        return ll;
    }

    private static ScrollView scroll(Context c, GateHelpArt.Roles r, View content) {
        ScrollView sv = new ScrollView(c);
        sv.setBackgroundColor(r.screen);
        sv.setFillViewport(true);
        sv.addView(content);
        return sv;
    }

    private static LinearLayout.LayoutParams wide() {
        return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private static TextView text(Context c, String s, int color, float sp, boolean centre) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextColor(color);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        if (centre) t.setGravity(Gravity.CENTER);
        return t;
    }

    private static Button button(Context c, GateHelpArt.Roles r, String label) {
        Button b = new Button(c);
        b.setText(label);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        b.setTextColor(r.onAccent);
        GradientDrawable g = new GradientDrawable();
        g.setColor(r.accent);
        g.setCornerRadius(dp(c, 13));
        b.setBackground(g);
        b.setStateListAnimator(null);
        b.setMinimumHeight(dp(c, 48));
        return b;
    }
}
