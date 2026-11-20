package com.nowhere.chooser;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;

/**
 * NWP-20261207-12 (Q106 S6b, half 2, O3): the media half of the landing line. A sign-in whose background media set is
 * over 200 files or 50 MiB says so once: {@link MediaLanding#IN_CARD} in the Auto sweep's card when one is open, else
 * this one-line card with {@link MediaLanding#ALONE} and Got it. The rule, the words (drafts) and the residuals are
 * {@link MediaLanding}'s.
 *
 * {@link #check} runs on its own daemon thread from {@link UnarchiveService}'s switch-landing start (every sign-in and
 * cold-lock resume). It asks GET-MEDIA-STATUS until mediad's RESTORING line shows or {@link MediaLanding#WAIT_MS}
 * passes; {@link MediaLanding#firstRestoring} discards a reply that arrives after that deadline. Once per sign-in:
 * the stamp holds the Android user's serial, new at every sign-in and unchanged across a cold-lock resume. check()
 * writes the stamp BEFORE it sends the sentence to the card or starts this one, so a failed send loses the line for
 * this sign-in (safe) and never shows it twice. Behind NOWHERE_MEDIA_AFTER_GATE: with the flag off mediad publishes no
 * RESTORING line, and nothing shows.
 *
 * The card sits at the bottom of the screen, so it covers neither the last-save card (top) nor the Auto sweep's card
 * (centre). Dismissible, not pinned: Got it, Back, or a tap outside. Nothing is sent back to the daemon. No log line
 * names a number, the serial or the profile.
 */
public class MediaLandingNoticeActivity extends Activity {
    private GatePalette look = GatePalette.DARK;

    /** Read the background set and, when it is large, say so once. Never on the main thread. */
    static void check(Context app, String serial, File stamp) {
        // The deadline is MediaLanding.firstRestoring's: no ask starts and no reply counts after WAIT_MS.
        long[] r = MediaLanding.firstRestoring(
                cap -> MediaStatus.restoring(MediaStatus.route(
                        DaemonSocket.roundTripLines("GET-MEDIA-STATUS\n", (int) cap))[3]),
                new MediaLanding.Clock() {
                    @Override public long now() { return android.os.SystemClock.elapsedRealtime(); }
                    @Override public void sleep(long ms) throws InterruptedException { Thread.sleep(ms); }
                });
        if (r == null) {
            android.util.Log.i("NowhereChooser", "media landing line: none");
            return;
        }
        if (!MediaLanding.large(r)) {
            android.util.Log.i("NowhereChooser", "media landing line: small set");
            return;
        }
        if (!MediaLanding.show(true, readStamp(stamp), serial)) return;
        try {
            StoreInstaller.writeAtomic(stamp, serial);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "media landing line: stamp not written", t);
            return;
        }
        // NWP-20261119-37: wait for sweepAuto's card decision before choosing, with the bound the other landing notices
        // use (LandingQueue.DECIDE_MS). The waiting card that used to be open here is gone (NWP-20261119-35), so the
        // apps card can begin after this read; the sentence then came as a card of its own under it, over the dock
        // (lynx 2026112001, 2026-11-19). A decision of no card, or none within the bound, still shows it alone.
        LandingQueue.awaitDecided(LandingQueue.DECIDE_MS);
        // The record means "the sentence went to the apps card", so only that arm sets it: set before the branch, a
        // card that begins after the alone card would say it a second time.
        if (LandingLine.Sweep.open()) {
            MediaLanding.mark(serial);
            try {
                app.sendBroadcast(new Intent(LandingNoticeActivity.ACTION_MEDIA).setPackage(app.getPackageName()));
                android.util.Log.i("NowhereChooser", "media landing line: in the card");
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "media landing line: not sent", t);
            }
        } else {
            try {
                app.startActivity(new Intent(app, MediaLandingNoticeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                android.util.Log.i("NowhereChooser", "media landing line: alone");
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "media landing line: card not started", t);
            }
        }
    }

    /** This sign-in's key, the Android user's serial; null on a negative serial or a failed read (null shows nothing).
     *  The rule of UnarchiveService.landingSerial; the apps card reads it here. */
    static String serial(Context c) {
        try {
            long s = ((android.os.UserManager) c.getSystemService(Context.USER_SERVICE))
                    .getSerialNumberForUser(android.os.Process.myUserHandle());
            return s < 0 ? null : Long.toString(s);
        } catch (Throwable t) { return null; }
    }

    /** The serial the line was last shown for, or null when there is no readable stamp. */
    private static String readStamp(File f) {
        if (f == null || !f.isFile()) return null;
        try {
            return new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (Throwable t) { return null; }
    }

    @Override protected void onCreate(Bundle b) {
        // The gate's one device-wide look, read as LastSaveNoticeActivity reads it. A failed read is dark.
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "media landing line look not read, dark: " + t);
        }
        if (look == GatePalette.LIGHT) setTheme(android.R.style.Theme_Material_Light_Dialog_NoActionBar);
        super.onCreate(b);

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

        // No title: the card shows the line and Got it.
        TextView words = new TextView(this);
        words.setText(MediaLanding.ALONE);
        words.setTextSize(17);
        words.setTextColor(look.ink);
        card.addView(words);

        Button ok = new Button(this);
        ok.setText(LandingLine.GOT_IT);
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
        // At the bottom of the screen, a little up: the last-save card is at the top and the Auto sweep's card is
        // centred, so this one covers neither.
        WindowManager.LayoutParams wl = getWindow().getAttributes();
        wl.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        wl.y = dp(24);
        getWindow().setAttributes(wl);
        setFinishOnTouchOutside(true);
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
