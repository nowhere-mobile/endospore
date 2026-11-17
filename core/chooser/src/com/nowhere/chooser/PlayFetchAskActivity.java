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
 * dn-1023 #5 (NWP-20261114-14): the question a tap asks before it fetches the Play stack. It shows the app's label,
 * {@link PlayFetchAsk#message(long)}, "Download" and "Not now". Back, and a close without an answer (onDestroy), count
 * as Not now. Dialog-themed (manifest) and not cancelable by an outside tap, like {@link MaterializingActivity}.
 *
 * {@link #ask} runs on the UnarchiveService worker: it opens a token on {@link PlayFetchAsk#ASKER}, starts this
 * activity and waits. The service and this activity share one process per user, so the static holder is shared.
 * The unarchive broadcast grants the FGS a temporary activity-start allowlist (120 s), so the start is permitted.
 *
 * NWP-20261205-12: the Your apps tap (ProfileActivity.yourAppsTap) asks through this same activity, with
 * {@link #EXTRA_PLAY} false for an app with no Play-stack dep. Two askers can now run at once, so each acts only on
 * its own token: {@link #dismiss(long)} finishes only its own question, and a question whose ask is no longer live
 * never shows.
 */
public class PlayFetchAskActivity extends Activity {
    static final String EXTRA_TOKEN = "nowhere.playask.token";
    static final String EXTRA_PKG = "nowhere.playask.pkg";
    static final String EXTRA_BYTES = "nowhere.playask.bytes";
    /** NWP-20261205-12: true (the default) for the Play setup's words; false for an app with no Play-stack dep. */
    static final String EXTRA_PLAY = "nowhere.playask.play";
    private static volatile PlayFetchAskActivity current;
    /** NWP-20261205-12: the token whose ask waits now, 0 for none. Set with ASKER.open() under one lock. */
    private static final java.util.concurrent.atomic.AtomicLong LIVE = new java.util.concurrent.atomic.AtomicLong();
    private long token;

    @Override protected void onCreate(Bundle b) {
        // NWP-20261117-31: the gate's one device-wide look (docs/product-decisions.md, 2026-10-29, the inference that
        // names this screen), read from the Global setting the gate mirrors it to. A failed read is dark.
        GatePalette look = GatePalette.DARK;
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "play-fetch ask look not read, dark: " + t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);
        Intent in = getIntent();
        token = in != null ? in.getLongExtra(EXTRA_TOKEN, -1) : -1;
        // NWP-20261205-12: an ask that was retired, or timed out before this was created, never shows its question.
        if (token != LIVE.get()) { finish(); return; }
        String pkg = in != null ? in.getStringExtra(EXTRA_PKG) : null;
        long bytes = in != null ? in.getLongExtra(EXTRA_BYTES, -1) : -1;

        int pad = Math.round(24 * getResources().getDisplayMetrics().density);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(pad, pad, pad, pad / 2);

        CharSequence label = label(pkg);
        if (label != null && label.length() > 0) {
            TextView title = new TextView(this);
            title.setText(label);
            title.setTextSize(20);
            title.setPadding(0, 0, 0, pad / 2);
            col.addView(title);
        }
        TextView body = new TextView(this);
        body.setText(in == null || in.getBooleanExtra(EXTRA_PLAY, true) ? PlayFetchAsk.message(bytes) : YourAppsFetch.message(bytes, false));
        body.setTextSize(16);
        col.addView(body);

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.END);
        buttons.setPadding(0, pad / 2, 0, 0);
        Button notNow = new Button(this);
        notNow.setText("Not now");
        notNow.setOnClickListener(v -> answer(false));
        buttons.addView(notNow, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        Button download = new Button(this);
        download.setText("Download");
        download.setOnClickListener(v -> answer(true));
        buttons.addView(download, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        col.addView(buttons);

        setContentView(col);
        setFinishOnTouchOutside(false); // an outside tap must not decide a ~130 MB download either way
        final PlayFetchAskActivity prev = current;
        if (prev != null && prev != this && prev.token != token) prev.finish(); // its ask was retired by ours; its buttons are dead
        current = this;
    }

    /** The label of the still-archived app (getArchivedPackage stops resolving once it is installed); null on a miss. */
    private CharSequence label(String pkg) {
        if (pkg == null) return null;
        try {
            android.content.pm.ArchivedPackageInfo ai = getPackageManager().getArchivedPackage(pkg);
            if (ai != null && ai.getLauncherActivities() != null && !ai.getLauncherActivities().isEmpty())
                return ai.getLauncherActivities().get(0).getLabel();
        } catch (Throwable ignore) {}
        return null;
    }

    private void answer(boolean yes) {
        PlayFetchAsk.ASKER.answer(token, yes);
        finish();
    }

    @Override public void onBackPressed() {
        answer(false);
    }

    @Override protected void onDestroy() {
        super.onDestroy();
        PlayFetchAsk.ASKER.answer(token, false); // a no-op once answered, or for a stale token
        if (current == this) current = null;
    }

    /** Dismiss the question of ask t, if it is the one showing. Safe from any thread. Another ask's question stays. */
    static void dismiss(long t) {
        final PlayFetchAskActivity a = current;
        if (a != null && a.token == t) new Handler(Looper.getMainLooper()).post(a::finish);
    }

    /** NWP-20261205-12: a question is up, or an ask is live whose activity is not created yet. */
    static boolean showing() {
        return current != null || LIVE.get() != 0;
    }

    /** Ask with the Play setup's words (UnarchiveService's call). */
    static PlayFetchAsk.Reply ask(Context ctx, String pkg, long bytes, long waitMs) {
        return ask(ctx, pkg, bytes, true, waitMs);
    }

    /** Ask, and wait at most waitMs. A failed start gives TIMEOUT at once; a TIMEOUT takes this ask's dialog down.
     *  play false: the size-unknown body is YourAppsFetch.UNKNOWN_APP, not the Play stack's. */
    static PlayFetchAsk.Reply ask(Context ctx, String pkg, long bytes, boolean play, long waitMs) {
        long t;
        synchronized (PlayFetchAskActivity.class) {
            t = PlayFetchAsk.ASKER.open();
            LIVE.set(t);
        }
        try {
            try {
                ctx.startActivity(new Intent(ctx, PlayFetchAskActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION)
                        .putExtra(EXTRA_TOKEN, t)
                        .putExtra(EXTRA_PKG, pkg)
                        .putExtra(EXTRA_BYTES, bytes)
                        .putExtra(EXTRA_PLAY, play));
            } catch (Throwable e) {
                android.util.Log.w("NowhereChooser", "play-fetch ask: start failed", e);
                return PlayFetchAsk.Reply.TIMEOUT;
            }
            PlayFetchAsk.Reply r = PlayFetchAsk.ASKER.await(t, waitMs);
            if (r == PlayFetchAsk.Reply.TIMEOUT) dismiss(t);
            return r;
        } finally {
            LIVE.compareAndSet(t, 0);
        }
    }
}
