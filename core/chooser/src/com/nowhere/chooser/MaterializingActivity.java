package com.nowhere.chooser;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * On-demand apps (#204, DIA-20260726-08): a lightweight "Getting <app> ready…" screen shown for the POST-DOWNLOAD
 * stretch of a materialise-on-tap (install + data/perms restore, ~5s). Without it that stretch drops the user back to
 * the launcher with no feedback, which reads as "the app didn't open / it crashed".
 *
 * {@link UnarchiveService} shows this AFTER installApks completes (not at tap, not after the download) -- by then the
 * framework's unarchive is done and its download/install progress ring on the icon has gone away, so this card never
 * overlaps the ring. It's dismissed from the worker's finally -- on SUCCESS the real app has already been launched OVER
 * it (launchApp), on FAILURE there's nothing to open so we just clear the screen. Dialog-themed (manifest; the light
 * dialog theme in the gate's light look, NWP-20261117-31) so it floats above the launcher with the system's dim. Single
 * live instance tracked in a static (service + activity share one process/user), dismissed via {@link #dismiss()} from
 * any thread.
 */
public class MaterializingActivity extends Activity {
    static final String EXTRA_LABEL = "nowhere.materialize.label";
    private static volatile MaterializingActivity current;

    @Override protected void onCreate(Bundle b) {
        // NWP-20261117-31: the gate's one device-wide look (docs/product-decisions.md, 2026-10-29, the inference that
        // names this screen), read from the Global setting the gate mirrors it to. A failed read is dark.
        GatePalette look = GatePalette.DARK;
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "materialize look not read, dark: " + t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);
        CharSequence label = getIntent() != null ? getIntent().getCharSequenceExtra(EXTRA_LABEL) : null;
        String msg = (label != null && label.length() > 0)
                ? "Getting " + label + " ready…" : "Getting your app ready…";

        int pad = Math.round(24 * getResources().getDisplayMetrics().density);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(pad, pad, pad, pad);

        ProgressBar spin = new ProgressBar(this); // default = indeterminate spinner
        spin.setIndeterminateTintList(android.content.res.ColorStateList.valueOf(look.accent)); // NWP-20261007-13, NWP-20261117-31
        LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        sp.rightMargin = pad;
        row.addView(spin, sp);

        TextView tv = new TextView(this);
        tv.setText(msg);
        tv.setTextSize(16);
        row.addView(tv);

        setContentView(row);
        setFinishOnTouchOutside(false); // a stray tap must not strand the fetch behind a dead screen
        current = this;
    }

    @Override protected void onDestroy() {
        super.onDestroy();
        if (current == this) current = null;
    }

    /** Dismiss the live loading screen, if any. Safe to call from the UnarchiveService worker thread. */
    static void dismiss() {
        final MaterializingActivity a = current;
        if (a != null) new Handler(Looper.getMainLooper()).post(a::finish);
    }
}
