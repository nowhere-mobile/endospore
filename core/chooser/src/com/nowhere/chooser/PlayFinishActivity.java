package com.nowhere.chooser;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * NWP-20261202-22 (docs/product-decisions.md, 2026-11-10, item 1): the one-time "Finish setting up Google Play" card.
 * A profile created with Play on gets play.wanted=1 and installs nothing, so after its first switch-in this card points
 * the user at the GrapheneOS App Store. The rule and the words are {@link PlayFinishPrompt}'s.
 *
 * {@link #check} runs on its own daemon thread from {@link UnarchiveService}'s switch-landing start, beside the skip
 * notice. It reads the play.finish marker and shows the card, settles the marker, or does nothing.
 *
 * The card records the marker DONE at its FIRST onResume, when the words are on screen, on a background thread. A
 * saved-state flag keeps a rotation or a recreation from writing it twice. Dismissible, not pinned: Open App Store,
 * Not now, Back, or a tap outside. No log line names the profile, a package or the store.
 */
public class PlayFinishActivity extends Activity {
    private static final String STATE_DONE_SENT = "nowhere.playfinish.doneSent";

    private GatePalette look = GatePalette.DARK;
    private boolean doneSent;

    /** Read the marker and show the card or settle it. Reads files and PackageManager: never on the main thread. */
    static void check(Context app) {
        try {
            PlayFinishPrompt.Verdict v = PlayFinishPrompt.decide(
                    ProfileActivity.cfgStatic(app, PlayFinishPrompt.CFG_KEY),
                    PlayChoice.effective(PlayChoice.parse(ProfileActivity.cfgStatic(app, PlayChoice.CFG_KEY)),
                            ProfileActivity.gosStorePresent(app)),
                    playStoreOnPhone(app));
            if (v == PlayFinishPrompt.Verdict.SETTLE) {
                ProfileActivity.cfgPutStatic(app, PlayFinishPrompt.CFG_KEY, PlayFinishPrompt.DONE);
                android.util.Log.i("NowhereChooser", "play finish: settled");
            } else if (v == PlayFinishPrompt.Verdict.SHOW) {
                try {
                    app.startActivity(new Intent(app, PlayFinishActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    android.util.Log.i("NowhereChooser", "play finish: showing");
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "play finish: card not started", t);
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "play finish: not read", t);
        }
    }

    /** ProfileActivity.isOnDevicePkg's test for Play Store, static: installed (flags 0) OR an archived On-demand
     *  placeholder. MATCH_ARCHIVED_PACKAGES is a LONG, so it only reaches PM through ApplicationInfoFlags.of(). */
    static boolean playStoreOnPhone(Context ctx) {
        PackageManager pm = ctx.getPackageManager();
        try {
            pm.getApplicationInfo(PlayChoice.VENDING, 0);
            return true;
        } catch (Throwable notInstalled) {
            // fall through to the archived test
        }
        try {
            pm.getApplicationInfo(PlayChoice.VENDING,
                    PackageManager.ApplicationInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES));
            return true;
        } catch (Throwable notThere) {
            return false;
        }
    }

    @Override protected void onCreate(Bundle b) {
        // The gate's one device-wide look, read as SkipNoticeActivity reads it. A failed read is dark.
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "play finish look not read, dark", t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);
        doneSent = b != null && b.getBoolean(STATE_DONE_SENT, false);

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
        title.setText(PlayFinishPrompt.TITLE);
        title.setTextSize(20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(look.ink);
        card.addView(title);

        TextView words = new TextView(this);
        words.setText(PlayFinishPrompt.DRAFT_BODY);
        words.setTextSize(17);
        words.setTextColor(look.ink);
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        wlp.topMargin = dp(12);
        card.addView(words, wlp);

        Button open = new Button(this);
        open.setText(PlayFinishPrompt.DRAFT_OPEN);
        open.setAllCaps(false);
        open.setTextColor(look.onAccent);
        GradientDrawable fill = new GradientDrawable();
        fill.setColor(look.accent);
        fill.setCornerRadius(dp(12));
        open.setBackground(fill);
        open.setOnClickListener(v -> openStore());
        LinearLayout.LayoutParams olp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        olp.topMargin = dp(20);
        card.addView(open, olp);

        Button later = new Button(this);
        later.setText(PlayFinishPrompt.DRAFT_LATER);
        later.setAllCaps(false);
        later.setTextColor(look.ink);
        later.setBackgroundColor(Color.TRANSPARENT);
        later.setOnClickListener(v -> finish());
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        llp.topMargin = dp(8);
        card.addView(later, llp);

        setContentView(card);
        getWindow().setLayout(LandingLine.widthPx(getResources().getDisplayMetrics().widthPixels),
                WindowManager.LayoutParams.WRAP_CONTENT);
    }

    /** Profile › Your apps, then the GrapheneOS App Store (ProfileActivity.openYourAppsIfAsked). */
    private void openStore() {
        try {
            startActivity(new Intent(this, ProfileActivity.class)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(LandingLine.EXTRA_OPEN, PlayFinishPrompt.OPEN_PLAY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "play finish: profile not started", t);
        }
        finish();
    }

    @Override protected void onResume() {
        super.onResume();
        // The words are on screen: record the card shown, once per profile.
        if (!doneSent) {
            doneSent = true;
            final Context app = getApplicationContext();
            Thread th = new Thread(() -> markDone(app), "nowhere-play-finish-done");
            th.setDaemon(true);
            th.start();
        }
    }

    @Override protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        out.putBoolean(STATE_DONE_SENT, doneSent);
    }

    /** Record the card shown. No retry: an unrecorded marker shows the card again at the next sign-in. */
    private static void markDone(Context app) {
        try {
            ProfileActivity.cfgPutStatic(app, PlayFinishPrompt.CFG_KEY, PlayFinishPrompt.DONE);
            android.util.Log.i("NowhereChooser", "play finish: done recorded");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "play finish: done not recorded", t);
        }
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
