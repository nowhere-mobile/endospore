package com.nowhere.chooser;

import android.content.Context;
import android.content.res.ColorStateList;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * The topic tiles of the gate's Help combo screen (NWP-20261130-11): two rows of three equal tiles, in
 * GateHelpHome.TILES order. A tile holds the TalkBack description; its icon and its label are hidden from TalkBack, so
 * TalkBack reads each tile once.
 */
final class GateHelpTileGrid extends LinearLayout {
    private static final int COLUMNS = 3;
    // In GateHelpHome.TILE_ICONS order; test-gate-help-combo-java.sh pins it.
    private static final int[] ICONS = { R.drawable.ic_help_signin, R.drawable.ic_help_apps, R.drawable.ic_help_saving,
        R.drawable.ic_help_lock, R.drawable.ic_help_calls, R.drawable.ic_help_owner };

    GateHelpTileGrid(Context c, GateHelpArt.Roles r, GateHelpScreen.Nav nav) {
        super(c);
        setOrientation(VERTICAL);
        int gap = GateHelpScreen.dp(c, 4);
        LinearLayout row = null;
        for (int i = 0; i < GateHelpHome.TILES.length; i++) {
            if (i % COLUMNS == 0) {
                row = new LinearLayout(c);
                row.setOrientation(HORIZONTAL);
                row.setBaselineAligned(false);
                addView(row, new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT));
            }
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, LayoutParams.MATCH_PARENT, 1f);
            lp.leftMargin = gap;
            lp.rightMargin = gap;
            lp.topMargin = gap;
            lp.bottomMargin = gap;
            row.addView(tile(c, r, nav, i), lp);
        }
    }

    private static View tile(Context c, GateHelpArt.Roles r, GateHelpScreen.Nav nav, int index) {
        LinearLayout tile = new LinearLayout(c);
        tile.setOrientation(VERTICAL);
        tile.setGravity(Gravity.CENTER);
        tile.setMinimumHeight(GateHelpScreen.dp(c, 88));
        int pad = GateHelpScreen.dp(c, 8);
        tile.setPadding(pad, pad, pad, pad);
        tile.setBackground(GateHelpScreen.card(c, r.cardFill, r.cardEdge, 1));
        tile.setContentDescription(GateHelpHome.tileDescription(index));
        tile.setFocusable(true);
        tile.setOnClickListener(v -> nav.openTile(index));

        ImageView icon = new ImageView(c);
        icon.setImageResource(ICONS[index]);
        icon.setImageTintList(ColorStateList.valueOf(r.accent));
        icon.setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        int size = GateHelpScreen.dp(c, 28);
        tile.addView(icon, new LinearLayout.LayoutParams(size, size));

        TextView label = new TextView(c);
        label.setText(GateHelpHome.TILES[index]);
        label.setTextColor(r.ink);
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        label.setGravity(Gravity.CENTER);
        label.setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT);
        lp.topMargin = GateHelpScreen.dp(c, 6);
        tile.addView(label, lp);
        return tile;
    }
}
