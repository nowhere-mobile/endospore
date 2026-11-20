package com.nowhere.chooser;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;

/**
 * NWP-20261122-15 (h50 #5, docs/product-decisions.md 2026-11-01): the card a sign-in shows when its Auto sweep has apps
 * to fetch. Started by {@link UnarchiveService}'s sweepAuto, once per sign-in, with its rows ({@link #EXTRA_PKGS}):
 * since NWP-20261130-09 the deps that ride with the work list (Play services, GSF), then the work list in sweep order.
 *
 * NWP-20261126-05 (docs/product-decisions.md 2026-11-03, "the Auto sweep's landing notice is a checklist card, and
 * Profile Help's cards show where to tap", option D): a rounded card {@link LandingLine#WIDTH_SHARE} of the screen wide,
 * in the gate's light or dark look, titled {@link LandingLine#TITLE}. Up to {@link LandingLine#ROWS_MAX} apps: one row
 * per app with its state, then {@link LandingLine#KEEP}. From {@code ROWS_MAX + 1}: the headline count, a bar, at most
 * {@link LandingLine#ROWS_BIG} rows and "+<n> more", which opens Your apps. Both sizes then end with one filled
 * {@link LandingLine#GOT_IT} button above Pause and Stop (NWP-20261203-28, docs/product-decisions.md 2026-11-12 "the
 * Auto sweep's landing card has "Got it" at every size"). Fixed slots, so the card keeps one size and never scrolls.
 * The rules and words are LandingLine's. A row's name is fixed at its first paint (NWP-20261201-31).
 *
 * sweepAuto records each app outcome and the end in {@link LandingLine.Sweep} (its id rides {@link #EXTRA_SWEEP}),
 * and each dep that lands (NWP-20261130-09), then sends {@link #ACTION_APP} (package-local; the package never goes to
 * the daemon) or {@link UnarchiveService#ACTION_SWEEP_DONE}. The card registers its receiver FIRST and reads the record AFTER, and
 * reads it again on each broadcast, so an outcome or the end sent before the card started, or while it was being
 * recreated, is never missed. Only an ok outcome ticks the app off: a failed app stays "coming back". In the from-5
 * window it leaves the rows and counts in "+<n> more" until the window reaches it near the end (LandingLine.rows). The
 * card closes
 * {@link LandingLine#CLOSE_AFTER_MS} after its sweep ends: apps a joined rerun pass fetches after it show only in the
 * notification and Your apps. The notification stays the record. Dismissible, not pinned: no lock task. Got it, Back,
 * "+<n> more" (which opens Your apps) and the close {@link LandingLine#CLOSE_AFTER_MS} after the sweep close it; a tap
 * outside does not (NWP-20261201-32). None of them pauses or stops the sweep.
 *
 * NWP-20261201-34 (docs/product-decisions.md, 2026-11-09 "eight answers to harvest 62 ...", #3): each row reads ready,
 * installing or coming back. sweepAuto and the dep loop record each start in LandingLine.Sweep, then send
 * {@link #ACTION_STARTED}. From {@code ROWS_MAX + 1} apps the rows are the rolling window of LandingLine.rows: the app
 * that landed last, the app installing and the next one coming back.
 *
 * NWP-20261201-13 (backlog "An Auto sweep cannot be paused or stopped"): one row of two text buttons, Pause and Stop. Each
 * raises {@link SweepHold} and sweepAuto ends after the app in flight. A paused card stays and its Pause reads Resume; a
 * stopped one closes as an ended sweep does.
 *
 * NWP-20261207-12 (Q106 S6b, O3): a sign-in whose background media set is large says so once. When this card's sweep
 * is open, MediaLandingNoticeActivity.check records the decision in MediaLanding and sends {@link #ACTION_MEDIA}; the
 * card then shows {@link MediaLanding#IN_CARD} between the rows and the line under them. sync() reads the record too,
 * so a card that starts or is recreated after the decision still shows it.
 *
 * NWP-20261208-24 (backlog "Up to four separate pop-ups can land together right after sign-in ..."; design approved
 * 2026-11-17, NWP-20261116-48): the last-save line and the skip notice fold into this card while it is up. Each check
 * adds its words to {@link LandingQueue} and sends {@link #ACTION_NOTICE}; sync() draws every line not drawn yet, in
 * the gate's amber, under the title (or the from-5 headline), and records each folded skip notice shown. The card
 * reports itself shown at onCreate and gone when it finishes, so the Google Play setup card waits until it closes.
 */
public class LandingNoticeActivity extends Activity {
    static final String EXTRA_COUNT = "nowhere.landing.count";
    /** String[]: the card's rows (LandingLine.cardPkgs). */
    static final String EXTRA_PKGS = "nowhere.landing.pkgs";
    /** One app's outcome: {@link #EXTRA_PKG} and {@link #EXTRA_OK}. Package-local. */
    static final String ACTION_APP = "com.nowhere.chooser.action.LANDING_APP";
    /** An app or a dep started installing: read the record again. Package-local, no extras. */
    static final String ACTION_STARTED = "com.nowhere.chooser.action.LANDING_STARTED";
    /** NWP-20261207-12: the media sentence goes into the card (MediaLandingNoticeActivity.check). Package-local. */
    static final String ACTION_MEDIA = "com.nowhere.chooser.action.LANDING_MEDIA";
    /** NWP-20261208-24: a notice was folded: read LandingQueue.lines() again. Package-local, no extras. */
    static final String ACTION_NOTICE = "com.nowhere.chooser.action.LANDING_NOTICE";
    static final String EXTRA_PKG = "nowhere.landing.pkg";
    static final String EXTRA_OK = "nowhere.landing.ok";
    /** long: the card's sweep in {@link LandingLine.Sweep}. */
    static final String EXTRA_SWEEP = "nowhere.landing.sweep";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private GatePalette look = GatePalette.DARK;
    private String[] pkgs;
    private String[] labels;
    private long sweep;
    /** The outcome came back ok: the tick, the count and the rows. A copy of LandingLine.Sweep's. */
    private boolean[] landed;
    /** The installing row and the row that landed last, -1 for none. Copies of LandingLine.Sweep's. */
    private int installing = -1, lastLanded = -1;
    private boolean big, closing;
    private TextView headline;
    private ProgressBar bar;
    private View[] rowViews;
    private TextView[] rowLabels, rowStates;
    private TextView moreRow;
    private Button pauseBtn, stopBtn;
    /** The small card's line under the rows: KEEP, or the paused or stopped line. */
    private TextView holdLine;
    /** NWP-20261207-12: the media sentence, hidden until this sign-in's decision put it in the card. */
    private TextView mediaLine;
    /** NWP-20261208-24: the folded notices' lines, hidden until the first one; and how many of them are drawn. */
    private LinearLayout noticeBox;
    private int noticeDrawn;
    private BroadcastReceiver receiver;

    @Override protected void onCreate(Bundle b) {
        // The gate's one device-wide look, read as MaterializingActivity reads it. A failed read is dark.
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "landing card look not read, dark: " + t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);
        // NWP-20261201-32 (row "The landing card drops an app ..."): the dialog theme finishes on any outside touch; only Got it, Back and the close after the sweep close the card.
        setFinishOnTouchOutside(false);
        pkgs = getIntent() != null ? getIntent().getStringArrayExtra(EXTRA_PKGS) : null;
        if (pkgs == null || pkgs.length == 0) { finish(); return; } // the service never sends it; nothing to say
        int n = pkgs.length;
        labels = new String[n];
        landed = new boolean[n];
        sweep = getIntent().getLongExtra(EXTRA_SWEEP, 0L);
        LandingQueue.cardShown(sweep); // NWP-20261208-24: the Play card and the alone notices wait until it is gone
        big = LandingLine.big(n);

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

        TextView title = new TextView(this);
        title.setText(LandingLine.TITLE);
        title.setTextSize(22);
        title.setTextColor(look.title);
        card.addView(title);

        if (!LandingLine.big(n)) {
            addNoticeBox(card);
            addRows(card, n);
            addMediaLine(card);
            TextView keep = new TextView(this);
            keep.setText(LandingLine.KEEP);
            keep.setTextSize(15);
            keep.setTextColor(look.muted);
            keep.setPadding(0, dp(16), 0, 0);
            card.addView(keep);
            holdLine = keep;

            addGotIt(card);
            addHoldRow(card);
        } else {
            headline = new TextView(this);
            headline.setTextSize(17);
            headline.setTextColor(look.ink);
            headline.setPadding(0, dp(12), 0, dp(8));
            card.addView(headline);
            addNoticeBox(card);

            bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
            bar.setMax(n);
            bar.setProgressTintList(ColorStateList.valueOf(look.accent));
            card.addView(bar, new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));

            addRows(card, LandingLine.ROWS_BIG);
            addMediaLine(card);
            moreRow = new TextView(this);
            moreRow.setTextSize(15);
            moreRow.setTextColor(look.accent);
            moreRow.setPadding(0, dp(12), 0, 0);
            moreRow.setOnClickListener(v -> {
                try {
                    startActivity(new Intent(this, ProfileActivity.class)
                            .putExtra(LandingLine.EXTRA_OPEN, LandingLine.OPEN_YOUR_APPS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                } catch (Throwable t) { android.util.Log.w("NowhereChooser", "landing card: open Your apps", t); }
                finish();
            });
            card.addView(moreRow);
            addGotIt(card);
            addHoldRow(card);
        }

        setContentView(card);
        getWindow().setLayout(LandingLine.widthPx(getResources().getDisplayMetrics().widthPixels),
                WindowManager.LayoutParams.WRAP_CONTENT);

        receiver = new BroadcastReceiver() {
            @Override public void onReceive(Context c, Intent in) {
                String a = in.getAction();
                if (ACTION_APP.equals(a) || ACTION_STARTED.equals(a) || UnarchiveService.ACTION_SWEEP_DONE.equals(a)) sync();
                if (ACTION_MEDIA.equals(a)) showMedia();
                if (ACTION_NOTICE.equals(a)) sync();
            }
        };
        IntentFilter f = new IntentFilter(ACTION_APP);
        f.addAction(ACTION_STARTED);
        f.addAction(UnarchiveService.ACTION_SWEEP_DONE);
        f.addAction(ACTION_MEDIA);
        f.addAction(ACTION_NOTICE);
        registerReceiver(receiver, f, Context.RECEIVER_NOT_EXPORTED);
        // AFTER the receiver: what the sweep recorded before this point is read here, anything later is broadcast.
        sync();
    }

    /** Read the card's sweep from LandingLine.Sweep, draw it, and close CLOSE_AFTER_MS after the sweep ended. */
    private void sync() {
        if (LandingLine.Sweep.dropped(sweep)) { finish(); return; } // NWP-20261208-23: the running card replaced this one
        boolean[] l = LandingLine.Sweep.landed(sweep);
        if (l != null && l.length == landed.length) {
            landed = l;
        }
        installing = LandingLine.Sweep.installing(sweep);
        lastLanded = LandingLine.Sweep.lastLanded(sweep);
        render();
        if (LandingLine.Sweep.done(sweep)) closeSoon();
        showMedia();
        // NWP-20261208-24: the folded notices, in the order they came. The skip times are taken BEFORE the lines are
        // read, so a time is only recorded shown with its line drawn here.
        long[] skipShown = LandingQueue.takeSkipTimes();
        java.util.List<String> notices = LandingQueue.lines();
        for (; noticeDrawn < notices.size(); noticeDrawn++) {
            TextView t = new TextView(this);
            t.setText(notices.get(noticeDrawn));
            t.setTextSize(15);
            t.setTextColor(look.warn);
            t.setPadding(0, dp(8), 0, 0);
            noticeBox.addView(t);
        }
        if (noticeDrawn > 0) noticeBox.setVisibility(View.VISIBLE);
        for (long time : skipShown) {
            Thread th = new Thread(() -> SkipNoticeActivity.markShown(time), "nowhere-skip-notice-shown");
            th.setDaemon(true);
            th.start();
        }
    }

    /** NWP-20261208-24: the folded notices' box, under the title or the headline, hidden until sync() draws a line. */
    private void addNoticeBox(LinearLayout card) {
        noticeBox = new LinearLayout(this);
        noticeBox.setOrientation(LinearLayout.VERTICAL);
        noticeBox.setVisibility(View.GONE);
        card.addView(noticeBox);
    }

    /** NWP-20261207-12: show the media sentence when this sign-in's decision put it in the card. */
    private void showMedia() {
        if (mediaLine != null && MediaLanding.shownFor(MediaLandingNoticeActivity.serial(this))) mediaLine.setVisibility(View.VISIBLE);
    }

    /** NWP-20261207-12: the media sentence's slot, under the rows, hidden by default. */
    private void addMediaLine(LinearLayout card) {
        TextView t = new TextView(this);
        t.setText(MediaLanding.IN_CARD);
        t.setTextSize(15);
        t.setTextColor(look.ink);
        t.setPadding(0, dp(12), 0, 0);
        t.setVisibility(View.GONE);
        card.addView(t);
        mediaLine = t;
    }

    @Override protected void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        // NWP-20261208-24: closed, not recreated. The Play card and the alone notices may show now.
        if (isFinishing()) LandingQueue.cardGone(sweep);
        if (receiver != null) {
            try { unregisterReceiver(receiver); } catch (Throwable ignore) {}
            receiver = null;
        }
        super.onDestroy();
    }

    /** The card closes CLOSE_AFTER_MS after the sweep ends; once. */
    private void closeSoon() {
        if (closing) return;
        closing = true;
        handler.postDelayed(this::finish, LandingLine.CLOSE_AFTER_MS);
    }

    /**
     * NWP-20261203-28 (docs/product-decisions.md 2026-11-12, "the Auto sweep's landing card has "Got it" at every
     * size"): the filled Got it, in both layouts, above the Pause/Stop row. It only closes the card: the sweep goes on.
     */
    private void addGotIt(LinearLayout card) {
        Button gotIt = new Button(this);
        gotIt.setText(LandingLine.GOT_IT);
        gotIt.setAllCaps(false);
        gotIt.setTextColor(look.onAccent);
        GradientDrawable fill = new GradientDrawable();
        fill.setColor(look.accent);
        fill.setCornerRadius(dp(12));
        gotIt.setBackground(fill);
        gotIt.setOnClickListener(v -> finish());
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(20);
        card.addView(gotIt, lp);
    }

    /** NWP-20261201-13: one row of two text buttons, in both layouts. render() paints them. */
    private void addHoldRow(LinearLayout card) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setPadding(0, dp(8), 0, 0);
        pauseBtn = holdButton(row);
        stopBtn = holdButton(row);
        pauseBtn.setOnClickListener(v -> {
            if (LandingLine.Sweep.paused(sweep)) tapResume(); else tapPause();
        });
        stopBtn.setOnClickListener(v -> tapStop());
        card.addView(row);
    }

    private Button holdButton(LinearLayout row) {
        Button b = new Button(this, null, android.R.attr.borderlessButtonStyle);
        b.setAllCaps(false);
        b.setTextColor(look.accent);
        row.addView(b, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        return b;
    }

    private void tapPause() {
        if (LandingLine.Sweep.done(sweep) || LandingLine.Sweep.paused(sweep)) return;
        SweepHold.pause(sweep);
        holdButtonsInert();
    }

    private void tapStop() {
        if (LandingLine.Sweep.done(sweep) || LandingLine.Sweep.paused(sweep)) return;
        SweepHold.stop();
        holdButtonsInert();
    }

    private void tapResume() {
        holdButtonsInert();
        try {
            startService(new Intent(this, UnarchiveService.class).putExtra(UnarchiveService.EXTRA_SWEEP, true)
                    .putExtra(UnarchiveService.EXTRA_RESUME, true));
        } catch (Throwable t) { android.util.Log.w("NowhereChooser", "landing card: resume the sweep", t); }
    }

    /** A pressed button stays inert until the next sync. */
    private void holdButtonsInert() {
        setHoldButton(pauseBtn, false);
        setHoldButton(stopBtn, false);
    }

    private void setHoldButton(Button b, boolean on) {
        b.setEnabled(on);
        b.setAlpha(on ? 1f : 0.4f);
    }

    /** {@code count} fixed row slots: the app's label, then its state. */
    private void addRows(LinearLayout card, int count) {
        rowViews = new View[count];
        rowLabels = new TextView[count];
        rowStates = new TextView[count];
        for (int s = 0; s < count; s++) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, dp(10), 0, 0);
            TextView label = new TextView(this);
            label.setTextSize(16);
            label.setTextColor(look.ink);
            label.setSingleLine(true);
            label.setEllipsize(TextUtils.TruncateAt.END);
            row.addView(label, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            TextView state = new TextView(this);
            state.setTextSize(15);
            state.setSingleLine(true);
            state.setPadding(dp(12), 0, 0, 0);
            row.addView(state);
            card.addView(row);
            rowViews[s] = row;
            rowLabels[s] = label;
            rowStates[s] = state;
        }
    }

    /** Draw the card from landed, installing and lastLanded. A failed app is not landed: it keeps "coming back" and, in
     *  the from-5 window, its place in the "+<n> more" count. */
    private void render() {
        int got = 0;
        for (boolean l : landed) if (l) got++;
        boolean paused = LandingLine.Sweep.paused(sweep);
        boolean ended = LandingLine.Sweep.done(sweep);
        boolean waiting = LandingLine.Sweep.waiting(sweep); // NWP-20261208-23: the sweep has not started
        String line = LandingLine.heldLine(paused, LandingLine.Sweep.stopped(sweep), got, pkgs.length);
        pauseBtn.setText(paused ? LandingLine.RESUME : LandingLine.PAUSE);
        stopBtn.setText(LandingLine.STOP);
        setHoldButton(pauseBtn, !ended && !waiting);
        setHoldButton(stopBtn, !ended && !paused && !waiting);
        if (!big) {
            for (int i = 0; i < pkgs.length; i++) paintRow(i, i, waiting);
            holdLine.setText(line != null ? line : LandingLine.KEEP);
            return;
        }
        headline.setText(LandingLine.headline(got, pkgs.length));
        if (line != null) headline.setText(line);
        if (waiting) headline.setText(LandingLine.waitingHeadline(pkgs.length));
        if (bar != null) bar.setProgress(waiting ? 0 : got);
        int[] show = LandingLine.rows(pkgs, landed, installing, lastLanded);
        for (int s = 0; s < rowViews.length; s++) {
            if (s < show.length) {
                paintRow(s, show[s], waiting);
                rowViews[s].setVisibility(View.VISIBLE);
            } else {
                rowViews[s].setVisibility(View.INVISIBLE); // INVISIBLE, not GONE: the card keeps one size
            }
        }
        int more = LandingLine.moreCount(pkgs, landed, installing, lastLanded);
        moreRow.setText(LandingLine.more(more));
        moreRow.setVisibility(more > 0 ? View.VISIBLE : View.INVISIBLE);
    }

    private void paintRow(int slot, int i, boolean waiting) {
        rowLabels[slot].setText(label(i));
        rowStates[slot].setText(LandingLine.state(landed[i], i == installing, waiting));
        rowStates[slot].setTextColor(landed[i] ? look.accent : i == installing ? look.ink : look.muted);
    }

    /** The app's name as ProfileActivity.keptLabel resolves it: the installed label, else the archived placeholder's
     *  launcher label, else a provider's fixed name (NWP-20261130-09: it has no placeholder to read), else the package
     *  name. Read once, at the row's first paint, and kept for the card's sweep, so neither the app landing nor a
     *  recreated card renames it (NWP-20261201-31). */
    private String label(int i) {
        if (labels[i] != null) return labels[i];
        String pkg = pkgs[i];
        String got = null;
        try { // installed
            android.content.pm.ApplicationInfo ai = getPackageManager().getApplicationInfo(pkg, 0);
            CharSequence l = getPackageManager().getApplicationLabel(ai);
            if (l != null && l.length() > 0 && !pkg.contentEquals(l)) got = l.toString();
        } catch (Throwable ignore) {}
        if (got == null) {
            try { // archived on-demand placeholder
                android.content.pm.ArchivedPackageInfo api = getPackageManager().getArchivedPackage(pkg);
                if (api != null) {
                    java.util.List<android.content.pm.ArchivedActivityInfo> acts = api.getLauncherActivities();
                    if (acts != null && !acts.isEmpty()) {
                        CharSequence l = acts.get(0).getLabel();
                        if (l != null && l.length() > 0 && !pkg.contentEquals(l)) got = l.toString();
                    }
                }
            } catch (Throwable ignore) {}
        }
        if (got == null) got = LandingLine.depLabel(pkg);
        labels[i] = LandingLine.Sweep.keepLabel(sweep, i, got != null ? got : pkg);
        return labels[i];
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
