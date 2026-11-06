package com.nowhere.chooser;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * NWP-20261119-15 (h49 #1, Q055 in docs/product-decisions.md): the question a tap asks before it installs a Play client
 * on an Endospore profile with no Play Store. It shows {@link PlayNeed#title}, {@link PlayNeed#body}, "Not now" and
 * "Install anyway". Back, and a close without an answer (onDestroy), count as Not now. Same shape and gate look as
 * {@link PlayFetchAskActivity}.
 *
 * {@link #ask} runs on the UnarchiveService worker: it opens a token on {@link #ASKER}, starts this activity and waits.
 * The holder is this activity's own, so a late Back or onDestroy of the Play-stack download ask never answers this one.
 */
public class PlayNeedAskActivity extends Activity {
    static final String EXTRA_TOKEN = "nowhere.playneed.token";
    static final String EXTRA_LABEL = "nowhere.playneed.label";
    /** The one live ask. The service and this activity share one process per user, so a static is shared. */
    static final PlayFetchAsk.Asker ASKER = new PlayFetchAsk.Asker();
    private static volatile PlayNeedAskActivity current;
    private long token;

    @Override protected void onCreate(Bundle b) {
        // The gate's one device-wide look, read from the Global setting the gate mirrors it to. A failed read is dark.
        GatePalette look = GatePalette.DARK;
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "play-need ask look not read, dark: " + t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);
        Intent in = getIntent();
        token = in != null ? in.getLongExtra(EXTRA_TOKEN, -1) : -1;
        // The service read the label while the app was still archived; a miss reads "This app".
        CharSequence label = in != null ? in.getCharSequenceExtra(EXTRA_LABEL) : null;

        int pad = Math.round(24 * getResources().getDisplayMetrics().density);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(pad, pad, pad, pad / 2);

        TextView title = new TextView(this);
        title.setText(PlayNeed.title(label));
        title.setTextSize(20);
        title.setPadding(0, 0, 0, pad / 2);
        col.addView(title);
        TextView body = new TextView(this);
        body.setText(PlayNeed.body(label));
        body.setTextSize(16);
        col.addView(body);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.END);
        buttons.setPadding(0, pad / 2, 0, 0);
        Button notNow = new Button(this);
        notNow.setText(PlayNeed.NOT_NOW);
        notNow.setOnClickListener(v -> answer(false));
        buttons.addView(notNow, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        Button install = new Button(this);
        install.setText(PlayNeed.INSTALL_ANYWAY);
        install.setOnClickListener(v -> answer(true));
        buttons.addView(install, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        col.addView(buttons);

        setContentView(col);
        setFinishOnTouchOutside(false); // an outside tap must not install a broken app, or refuse it
        current = this;
    }

    private void answer(boolean yes) {
        ASKER.answer(token, yes);
        finish();
    }

    @Override public void onBackPressed() {
        answer(false);
    }

    @Override protected void onDestroy() {
        super.onDestroy();
        ASKER.answer(token, false); // a no-op once answered, or for a stale token
        if (current == this) current = null;
    }

    /** Dismiss the live question, if any. Safe to call from the UnarchiveService worker thread. */
    static void dismiss() {
        final PlayNeedAskActivity a = current;
        if (a != null) new Handler(Looper.getMainLooper()).post(a::finish);
    }

    /** Ask, and wait at most waitMs. A failed start gives TIMEOUT at once; a TIMEOUT takes the dialog down. */
    static PlayFetchAsk.Reply ask(Context ctx, CharSequence label, long waitMs) {
        long t = ASKER.open();
        try {
            Intent i = new Intent(ctx, PlayNeedAskActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION)
                    .putExtra(EXTRA_TOKEN, t);
            if (label != null && label.length() > 0) i.putExtra(EXTRA_LABEL, label);
            ctx.startActivity(i);
        } catch (Throwable e) {
            android.util.Log.w("NowhereChooser", "play-need ask: start failed", e);
            return PlayFetchAsk.Reply.TIMEOUT;
        }
        PlayFetchAsk.Reply r = ASKER.await(t, waitMs);
        if (r == PlayFetchAsk.Reply.TIMEOUT) dismiss();
        return r;
    }
}
