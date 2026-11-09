package com.nowhere.chooser;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * NWP-20261128-08 (h50 #6, docs/product-decisions.md 2026-11-01): the card a sign-in shows when a phone's sign-out
 * skipped its seal after this profile's passphrase was changed on another phone. The words are h48 #5
 * ({@link SkipNoticeCopy#words}); the parser and the fallback for an empty label are {@link SkipNoticeCopy}'s.
 *
 * {@link #check} runs on its own daemon thread from {@link UnarchiveService}'s switch-landing start (every sign-in and
 * cold-lock resume, about 15 s after the switch). It asks GET-SKIP-NOTICE and starts this card on a notice. The daemon
 * answers NONE to a throwaway or offline session and to any caller outside the live session, so the card adds no
 * error path of its own (the blind rule).
 *
 * The card records the notice shown (SKIP-NOTICE-SHOWN) at its FIRST onResume, when the words are on screen, on a
 * background thread. A saved-state flag keeps a rotation or a recreation from sending it twice. An ERR or no answer
 * only logs: the next sign-in shows the notice again, which is the safe direction. Dismissible, not pinned: one OK
 * button, Back, or a tap outside. No log line names the phone, the time or the profile.
 */
public class SkipNoticeActivity extends Activity {
    static final String EXTRA_PHONE = "nowhere.skipnotice.phone";
    /** long: the notice's unix time in seconds. */
    static final String EXTRA_TIME = "nowhere.skipnotice.time";
    private static final String STATE_SHOWN_SENT = "nowhere.skipnotice.shownSent";

    private GatePalette look = GatePalette.DARK;
    private long time;
    private boolean shownSent;

    /** Read the notice and, when there is one, start the card. Blocks up to 70 s: never on the main thread. */
    static void check(Context app) {
        String r = DaemonSocket.roundTrip("GET-SKIP-NOTICE\n", 70000);
        SkipNoticeCopy.Notice n = SkipNoticeCopy.parse(r);
        if (n == null) {
            android.util.Log.i("NowhereChooser", "NONE".equals(r) ? "skip notice: none" : "skip notice: not read");
            return;
        }
        try {
            app.startActivity(new Intent(app, SkipNoticeActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(EXTRA_PHONE, n.phone)
                    .putExtra(EXTRA_TIME, n.time));
            android.util.Log.i("NowhereChooser", "skip notice: showing");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "skip notice: card not started", t);
        }
    }

    @Override protected void onCreate(Bundle b) {
        // The gate's one device-wide look, read as LandingNoticeActivity reads it. A failed read is dark.
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "skip notice look not read, dark: " + t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);
        shownSent = b != null && b.getBoolean(STATE_SHOWN_SENT, false);
        Intent in = getIntent();
        time = in != null ? in.getLongExtra(EXTRA_TIME, 0L) : 0L;
        if (time <= 0) { finish(); return; } // check() never sends it; nothing to say and nothing to record
        String phone = in.getStringExtra(EXTRA_PHONE);
        // The chooser runs in the session's own Android user, so the default zone is the session's.
        java.text.DateFormat df = java.text.DateFormat.getDateTimeInstance(
                java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT);
        df.setTimeZone(java.util.TimeZone.getDefault());
        String when = df.format(new java.util.Date(time * 1000L));

        // The window is transparent, so the card's rounded corners show.
        getWindow().setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
        int pad = dp(24);
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(pad, pad, pad, pad);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(look.bg);
        bg.setCornerRadius(dp(20));
        card.setBackground(bg);

        // No title: no title words are decided, so the card shows the decided sentence and OK only.
        TextView words = new TextView(this);
        words.setText(SkipNoticeCopy.words(phone, when));
        words.setTextSize(17);
        words.setTextColor(look.ink);
        card.addView(words);

        Button ok = new Button(this);
        ok.setText(SkipNoticeCopy.OK_BUTTON);
        ok.setAllCaps(false);
        ok.setTextColor(look.onAccent);
        GradientDrawable fill = new GradientDrawable();
        fill.setColor(look.accent);
        fill.setCornerRadius(dp(12));
        ok.setBackground(fill);
        ok.setOnClickListener(v -> finish());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(20);
        card.addView(ok, lp);

        setContentView(card);
        getWindow().setLayout(LandingLine.widthPx(getResources().getDisplayMetrics().widthPixels),
                WindowManager.LayoutParams.WRAP_CONTENT);
    }

    @Override protected void onResume() {
        super.onResume();
        // The words are on screen: record them shown, once per notice card.
        if (!shownSent && time > 0) {
            shownSent = true;
            final long t = time;
            Thread th = new Thread(() -> markShown(t), "nowhere-skip-notice-shown");
            th.setDaemon(true);
            th.start();
        }
    }

    @Override protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        out.putBoolean(STATE_SHOWN_SENT, shownSent);
    }

    /** Record the notice at {@code t} shown. No retry: an unrecorded notice shows again at the next sign-in. */
    private static void markShown(long t) {
        String r = DaemonSocket.roundTrip(SkipNoticeCopy.shownRequest(t), 70000);
        android.util.Log.i("NowhereChooser", "OK".equals(r) ? "skip notice: shown recorded" : "skip notice: shown not recorded");
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
