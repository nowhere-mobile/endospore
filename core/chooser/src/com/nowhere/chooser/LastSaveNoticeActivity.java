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
 * NWP-20261205-02 (h58 #1, docs/product-decisions.md 2026-11-04): the one line a sign-in shows when its last save
 * left a scope unsaved, {@link LastSaveCopy#LINE}, with Got it.
 *
 * {@link #check} runs on its own daemon thread from {@link UnarchiveService}'s switch-landing start (every sign-in and
 * cold-lock resume). It asks GET-LASTSAVE and starts this card on a LASTSAVE line. The card shows once per sign-in:
 * the stamp holds the Android user's serial, which is new at every sign-in and unchanged across a cold-lock resume.
 * check() writes the stamp BEFORE it starts the card, so a failed start loses the line for this sign-in (safe) and
 * never shows it twice. Until the agent slice and the gate verb are on main the daemon answers anything but a
 * LASTSAVE line, and nothing shows.
 *
 * NWP-20261208-24 (design approved 2026-11-17, NWP-20261116-48): after the stamp, check() asks {@link LandingQueue}.
 * While the Auto sweep's card is up and its sweep runs, the line goes into that card as an amber line under its
 * headline, and this card does not start. Otherwise this card starts once the landing card has closed.
 *
 * The card sits at the top of the screen, so it never covers the Auto sweep's card, which is centred. Dismissible,
 * not pinned: Got it, Back, or a tap outside. Nothing is sent back to the daemon. No log line names the scopes, the
 * time, the serial or the profile.
 */
public class LastSaveNoticeActivity extends Activity {
    private GatePalette look = GatePalette.DARK;

    /** Read the last save's verdict and, when it left a scope unsaved, start the card once. Never on the main thread. */
    static void check(Context app, String serial, File stamp) {
        String r = DaemonSocket.roundTrip("GET-LASTSAVE\n", 10000);
        if (!LastSaveCopy.show(LastSaveCopy.unsaved(r), readStamp(stamp), serial)) {
            android.util.Log.i("NowhereChooser", "last save line: none");
            return;
        }
        try {
            StoreInstaller.writeAtomic(stamp, serial);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "last save line: stamp not written", t);
            return;
        }
        // NWP-20261208-24: while the Auto sweep's card is up, the line goes into it; else this card shows, after that
        // card has closed when there is one.
        if (LandingQueue.place(LandingQueue.DECIDE_MS, id -> !LandingLine.Sweep.done(id)) == LandingQueue.Place.CARD) {
            LandingQueue.addLine(LastSaveCopy.LINE, 0);
            try {
                app.sendBroadcast(new Intent(LandingNoticeActivity.ACTION_NOTICE).setPackage(app.getPackageName()));
                android.util.Log.i("NowhereChooser", "last save line: folded");
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "last save line: card not told", t);
            }
            return;
        }
        try {
            app.startActivity(new Intent(app, LastSaveNoticeActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            android.util.Log.i("NowhereChooser", "last save line: showing");
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "last save line: card not started", t);
        }
    }

    /** The serial the line was last shown for, or null when there is no readable stamp. */
    private static String readStamp(File f) {
        if (f == null || !f.isFile()) return null;
        try {
            return new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (Throwable t) { return null; }
    }

    @Override protected void onCreate(Bundle b) {
        // The gate's one device-wide look, read as LandingNoticeActivity reads it. A failed read is dark.
        try {
            look = GatePalette.forLook(android.provider.Settings.Global.getString(getContentResolver(), GatePalette.GLOBAL_KEY));
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "last save line look not read, dark: " + t);
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

        // No title: only the line is decided, so the card shows the line and Got it.
        TextView words = new TextView(this);
        words.setText(LastSaveCopy.LINE);
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
        // At the top of the screen, a little down: the Auto sweep's card is centred, so this one never covers it.
        WindowManager.LayoutParams wl = getWindow().getAttributes();
        wl.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        wl.y = dp(24);
        getWindow().setAttributes(wl);
        setFinishOnTouchOutside(true);
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
