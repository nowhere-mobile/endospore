package com.nowhere.chooser;

import android.app.Activity;
import android.app.ActivityManager;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.telecom.Call;
import android.telecom.CallAudioState;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Locale;

/**
 * #135 B4.b: the gate's full-screen incoming-call surface. Shows over the (insecure user-0) keyguard on a
 * cold-lock ring and turns the screen on, WITHOUT unlocking the device -- answering a call is a user-0-only
 * action that must never switch to / unlock the roamed user. Two states: RINGING (number + Answer/Decline)
 * and ACTIVE (number + live timer + Mute / Speaker / Hang up).
 *
 * NWP-20261001-04: also hosts the owner's OWN outgoing call (owner-mode transmit on the unbound SIM, 637) —
 * a "Calling…" dialing state that reuses the ACTIVE controls (so Hang up works before the call connects) and
 * never shows Answer/Decline. No Recorder is ever registered for it (fire-and-forget: no sent record).
 *
 * It is a thin VIEW over {@link NowhereInCallService}: every button calls a service static and the service
 * drives the Call; the activity never seals or scrubs (the service Recorder is the single source of truth).
 * It lives in the chooser package, so it shares the gate's LockTask task and stays LOCKED -- no second task,
 * no kiosk drop. It replicates the gate's volume-key swallow: the confined nowhere_chooser domain has no
 * MediaSessionManager, so PhoneWindow's default volume path NPEs -> crash -> kiosk escape.
 */
public final class IncomingCallActivity extends Activity implements NowhereInCallService.UiListener {

    static volatile boolean sShowing = false;
    static boolean isShowing() { return sShowing; }

    private TextView statusView, numberView, timerView;
    private View ringingRow, activeRow;
    private Button muteBtn, speakerBtn;
    // NWP-20261115-16: the owner's gate look, read in buildUi; DARK draws this screen as it always was.
    private GatePalette pal = GatePalette.DARK;
    private final Handler h = new Handler(Looper.getMainLooper());
    private boolean timing = false;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true); }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Amnesia invariant: the call UI is a user-0-only surface. If a roamed user is somehow foreground (a
        // race between onCallAdded's check and this launch), do not draw over it -- bail to the native path.
        if (currentUser() != 0) { finish(); return; }
        setContentView(buildUi());
        repaintFrom(NowhereInCallService.currentCall());
    }

    @Override protected void onResume() {
        super.onResume();
        sShowing = true;
        if (currentUser() != 0) { finish(); return; }
        NowhereInCallService.bindUi(this);
        Call c = NowhereInCallService.currentCall();
        if (c == null) { finish(); return; } // the call already ended
        repaintFrom(c);
        onAudioState(NowhereInCallService.audioState());
    }

    @Override protected void onPause() {
        sShowing = false;
        NowhereInCallService.unbindUi(this);
        stopTimer();
        super.onPause();
    }

    @Override protected void onDestroy() {
        stopTimer();
        try { getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); } catch (Throwable ignore) {}
        super.onDestroy();
    }

    /** Do not let Back strand a live call behind a dismissed UI (and never expose the gate mid-ring). */
    @Override public void onBackPressed() { /* no-op */ }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        // Same reason as the gate (#99): volume keys must NEVER reach PhoneWindow -- the confined
        // nowhere_chooser domain has no MediaSessionManager, so the default path NPEs and crashes this
        // activity, dropping Lock Task. Handle them ourselves via AudioManager; hard try/catch degrades to a
        // swallow, never a crash. NWP-20261114-30: while the screen shows the call controls (a connected call,
        // or the owner's own outgoing call) the keys adjust the call; while it rings, or with no call, the ringer.
        int kc = event.getKeyCode();
        if (kc == KeyEvent.KEYCODE_VOLUME_UP || kc == KeyEvent.KEYCODE_VOLUME_DOWN
                || kc == KeyEvent.KEYCODE_VOLUME_MUTE) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                try {
                    Call c = NowhereInCallService.currentCall();
                    int st = c != null ? c.getState() : -1;
                    boolean ringing = c != null && (st == Call.STATE_RINGING || st == Call.STATE_SIMULATED_RINGING);
                    boolean outgoing = c != null && isOutgoing(c);
                    int stream = CallVolume.callStream(c != null, ringing, outgoing)
                            ? android.media.AudioManager.STREAM_VOICE_CALL : android.media.AudioManager.STREAM_RING;
                    android.media.AudioManager am =
                            (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
                    if (am != null) {
                        int dir = kc == KeyEvent.KEYCODE_VOLUME_UP ? android.media.AudioManager.ADJUST_RAISE
                                : kc == KeyEvent.KEYCODE_VOLUME_DOWN ? android.media.AudioManager.ADJUST_LOWER
                                : android.media.AudioManager.ADJUST_TOGGLE_MUTE;
                        am.adjustStreamVolume(stream, dir,
                                android.media.AudioManager.FLAG_SHOW_UI);
                    }
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "call volume", t);
                }
            }
            return true; // consumed either way -- PhoneWindow must never see these
        }
        return super.dispatchKeyEvent(event);
    }

    // ===== NowhereInCallService.UiListener (may arrive off the main thread; marshal) =====

    @Override public void onCallState(int state) {
        h.post(() -> {
            Call c = NowhereInCallService.currentCall();
            if (state == Call.STATE_DISCONNECTED || state == Call.STATE_DISCONNECTING || c == null) { finish(); return; }
            repaintFrom(c);
        });
    }

    @Override public void onAudioState(CallAudioState s) {
        h.post(() -> {
            boolean muted = s != null && s.isMuted();
            boolean spk = s != null && s.getRoute() == CallAudioState.ROUTE_SPEAKER;
            if (muteBtn != null) muteBtn.setText(muted ? "Unmute" : "Mute");
            if (speakerBtn != null) speakerBtn.setText(spk ? "Speaker off" : "Speaker");
        });
    }

    private void repaintFrom(Call c) {
        if (c == null) { finish(); return; }
        int state = c.getState();
        String num = "";
        try {
            Uri hnd = c.getDetails().getHandle();
            if (hnd != null && "tel".equals(hnd.getScheme())) num = hnd.getSchemeSpecificPart();
        } catch (Throwable ignore) {}
        numberView.setText(num == null || num.isEmpty() ? "Unknown" : num);
        boolean active = (state == Call.STATE_ACTIVE);
        boolean outgoing = isOutgoing(c);   // NWP-20261001-04: the owner's own outgoing call (owner-mode transmit, 637)
        if (active || outgoing) {
            // An answered incoming call OR the owner's outgoing call both reuse the active controls (Mute / Speaker
            // / Hang up) so the owner can hang up even while it is still dialing; the live timer shows only once the
            // call is connected, and the "Calling…" label shows while an outgoing call is still ringing out.
            statusView.setText(active ? "" : "Calling…");
            ringingRow.setVisibility(View.GONE);
            activeRow.setVisibility(View.VISIBLE);
            timerView.setVisibility(active ? View.VISIBLE : View.GONE);
            if (active) startTimer(); else stopTimer();
        } else {
            statusView.setText("Incoming call");
            ringingRow.setVisibility(View.VISIBLE);
            activeRow.setVisibility(View.GONE);
            timerView.setVisibility(View.GONE);
            stopTimer();
        }
    }

    /** True for the owner's own outgoing call (637); its surface shows Hang up, never Answer/Decline. */
    private static boolean isOutgoing(Call c) {
        try { return c.getDetails().getCallDirection() == Call.Details.DIRECTION_OUTGOING; }
        catch (Throwable t) { return false; }
    }

    // ===== live timer (wall-clock based; guards connectTime==0 so it never renders garbage) =====

    private final Runnable tick = new Runnable() {
        @Override public void run() {
            Call c = NowhereInCallService.currentCall();
            if (c == null) { finish(); return; }
            long connect = 0;
            try { connect = c.getDetails().getConnectTimeMillis(); } catch (Throwable ignore) {}
            long secs = connect > 0 ? Math.max(0, System.currentTimeMillis() - connect) / 1000 : 0;
            timerView.setText(String.format(Locale.US, "%02d:%02d", secs / 60, secs % 60));
            h.postDelayed(this, 1000);
        }
    };
    private void startTimer() { if (timing) return; timing = true; h.post(tick); }
    private void stopTimer() { timing = false; h.removeCallbacks(tick); }

    // ===== programmatic UI (the gate has no XML layouts / styles.xml; build views in code) =====

    private View buildUi() {
        pal = GatePalette.forLook(getSharedPreferences("nowhere_gate", MODE_PRIVATE).getString(GatePalette.KEY, null));
        ChooserActivity.applyGateBars(getWindow(), pal);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(pal.callBg);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(28), dp(96), dp(28), dp(56));

        statusView = new TextView(this);
        statusView.setText("Incoming call");
        statusView.setTextColor(pal.callLabel);
        statusView.setTextSize(16);
        statusView.setGravity(Gravity.CENTER);
        root.addView(statusView, wrapRow(0));

        numberView = new TextView(this);
        numberView.setTextColor(pal.callInk);
        numberView.setTextSize(30);
        numberView.setGravity(Gravity.CENTER);
        root.addView(numberView, wrapRow(dp(12)));

        timerView = new TextView(this);
        timerView.setTextColor(pal.callTimer);
        timerView.setTextSize(20);
        timerView.setGravity(Gravity.CENTER);
        timerView.setText("00:00");
        timerView.setVisibility(View.GONE);
        root.addView(timerView, wrapRow(dp(8)));

        View spacer = new View(this);
        root.addView(spacer, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        ringingRow = row(
                bigBtn("Decline", pal.decline, v -> NowhereInCallService.declineOrHangup()),
                bigBtn("Answer", pal.answer, v -> NowhereInCallService.answer()));
        root.addView(ringingRow, wrapRow(dp(12)));

        muteBtn = bigBtn("Mute", pal.neutralBtn, v -> NowhereInCallService.toggleMute());
        speakerBtn = bigBtn("Speaker", pal.neutralBtn, v -> NowhereInCallService.setSpeaker(!NowhereInCallService.isSpeaker()));
        activeRow = row(muteBtn, speakerBtn, bigBtn("Hang up", pal.decline, v -> NowhereInCallService.declineOrHangup()));
        activeRow.setVisibility(View.GONE);
        root.addView(activeRow, wrapRow(dp(12)));
        return root;
    }

    private LinearLayout row(View... kids) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setGravity(Gravity.CENTER);
        for (View k : kids) {
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(58), 1f);
            int m = dp(8); lp.setMargins(m, m, m, m);
            r.addView(k, lp);
        }
        return r;
    }

    private Button bigBtn(String text, int color, View.OnClickListener cl) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(pal.onBtn);
        b.setTextSize(17);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(color);
        bg.setCornerRadius(dp(14));
        b.setBackground(bg);
        b.setOnClickListener(cl);
        return b;
    }

    private LinearLayout.LayoutParams wrapRow(int topMargin) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = topMargin;
        return lp;
    }

    private int dp(int v) { return Math.round(getResources().getDisplayMetrics().density * v); }

    private static int currentUser() {
        try { return ActivityManager.getCurrentUser(); } catch (Throwable t) { return 0; }
    }
}
