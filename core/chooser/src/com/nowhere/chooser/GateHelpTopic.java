package com.nowhere.chooser;

import android.content.Context;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * One topic of the gate's Help combo screen, opened in place under its tile or the Forgot card (NWP-20261208-26; the
 * design approved 2026-11-17, NWP-20261116-48). It copies the step cards of ProfileActivity.showHelpPage (decision
 * 2026-11-03): one card at a time, its position and dots, Back and Next, and the support-pages line under the last
 * card; Back on the first card closes the topic. A tile with a related page shows "Also see: <page>" under its last card.
 *
 * Each card is one step, its words verbatim: never HelpCards.text, because the gate's steps are not Profile paths
 * ("Profile › Lock — keep on this device: ..." keeps its prefix). Static text, the same for everyone, in views that the
 * combo screen swaps inside Lock-Task: no activity, no dialog, no pref, no daemon call, no profile name.
 */
final class GateHelpTopic {
    private GateHelpTopic() {}

    /**
     * The topic's view: steps as cards, alsoLine (or null) as a link under the last card that runs openAlso, and close
     * run by Back on the first card. The colours are r's.
     */
    static View build(Context c, GateHelpArt.Roles r, String[] steps, String alsoLine, Runnable openAlso, Runnable close) {
        final String[][] cards = HelpCards.cards(steps);
        final int n = cards.length;
        final int[] at = {0};

        LinearLayout ll = new LinearLayout(c);
        ll.setOrientation(LinearLayout.VERTICAL);
        int pad = GateHelpScreen.dp(c, 8);
        ll.setPadding(pad, pad, pad, pad);

        final TextView text = text(c, r.ink, 15);
        ll.addView(text, wide(c, 4));
        final TextView pos = text(c, r.body, 13);
        pos.setGravity(Gravity.CENTER);
        ll.addView(pos, wide(c, 12));
        // TalkBack reads the position line, so the dots are hidden from it.
        final TextView dots = text(c, r.body, 10);
        dots.setGravity(Gravity.CENTER);
        dots.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        ll.addView(dots, wide(c, 4));

        LinearLayout row = new LinearLayout(c);
        row.setOrientation(LinearLayout.HORIZONTAL);
        final TextView back = text(c, r.accent, 14);
        back.setText(HelpCards.BACK);
        final TextView next = text(c, r.accent, 14);
        next.setText(HelpCards.NEXT);
        int bh = GateHelpScreen.dp(c, 8), bv = GateHelpScreen.dp(c, 12);
        back.setPadding(bh, bv, bh, bv);
        next.setPadding(bh, bv, bh, bv);
        int wrap = ViewGroup.LayoutParams.WRAP_CONTENT;
        row.addView(back, new LinearLayout.LayoutParams(wrap, wrap));
        row.addView(new View(c), new LinearLayout.LayoutParams(0, wrap, 1f));
        row.addView(next, new LinearLayout.LayoutParams(wrap, wrap));
        ll.addView(row, wide(c, 4));

        final TextView more = text(c, r.body, 13);
        more.setText(GateHelpPages.moreLine());
        more.setVisibility(View.GONE);
        ll.addView(more, wide(c, 8));

        final TextView also;
        if (alsoLine != null) {
            also = text(c, r.accent, 14);
            also.setText(alsoLine);
            also.setContentDescription(alsoLine);
            also.setPadding(0, bv, 0, bv);
            also.setVisibility(View.GONE);
            also.setOnClickListener(v -> openAlso.run());
            ll.addView(also, wide(c, 4));
        } else {
            also = null;
        }

        // go moves dir cards (1, -1, or 0 for the first draw) and redraws the card.
        final java.util.function.IntConsumer go = dir -> {
            if (n == 0) {
                more.setVisibility(View.VISIBLE);
                return;
            }
            at[0] = HelpCards.next(at[0], n, dir);
            boolean last = at[0] == n - 1;
            String where = HelpCards.position(at[0], n);
            text.setText(String.join("\n", cards[at[0]]));
            pos.setText(where);
            dots.setText(HelpCards.dots(at[0], n));
            back.setContentDescription(HelpCards.BACK + ", " + where);
            next.setContentDescription(HelpCards.NEXT + ", " + where);
            next.setVisibility(last ? View.GONE : View.VISIBLE);
            more.setVisibility(last ? View.VISIBLE : View.GONE);
            if (also != null) also.setVisibility(last ? View.VISIBLE : View.GONE);
        };
        // Back on the first card closes the topic; the combo screen stays.
        back.setOnClickListener(v -> {
            if (at[0] == 0) close.run();
            else go.accept(-1);
        });
        next.setOnClickListener(v -> go.accept(1));
        go.accept(0);
        return ll;
    }

    private static TextView text(Context c, int color, float sp) {
        TextView t = new TextView(c);
        t.setTextColor(color);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        return t;
    }

    private static LinearLayout.LayoutParams wide(Context c, int topDp) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = GateHelpScreen.dp(c, topDp);
        return lp;
    }
}
