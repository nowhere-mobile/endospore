package com.nowhere.chooser;

import android.app.Activity;
import android.app.ActivityManager;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioAttributes;
import android.media.Ringtone;
import android.media.RingtoneManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * #151 (a phone that can't wake you): the gate's full-screen ALARM surface. A roamed session's alarms stop
 * firing once it's logged off / cold-locked; {@link ChooserActivity} schedules a user-0 alarm from the relayed
 * next-alarm TIME (no label/tone -- amnesia-safe) and this rings it over the (insecure user-0) keyguard with
 * Snooze / Dismiss. Mirrors {@link IncomingCallActivity}: full-screen, show-when-locked, and the volume-key
 * swallow (the confined nowhere_chooser domain has no MediaSessionManager, so PhoneWindow's default volume path
 * NPEs -> crash -> Lock Task drop; we adjust the stream ourselves / silence the alarm instead).
 */
public final class GateAlarmActivity extends Activity {

    private static final long SNOOZE_MS = 9 * 60 * 1000L; // 9 min -- the familiar default

    private volatile Ringtone ring;
    private Vibrator vib;
    private volatile boolean stopped;
    /** NWP-20260914-02: when onCreate finished, so onDestroy can say how long this surface lived. */
    private static volatile long sCreatedAt;
    /** NWP-20261028-13: failures noted on the way in, traced by onCreate AFTER the vibrate and the ring start. */
    private static volatile boolean guardErr;
    private volatile boolean vibrateErr;
    /** NWP-20261116-12: automatic snoozes before this ring, from the alarm's PendingIntent (GateAlarmAuto). */
    private int autoSoFar;
    private final Handler h = new Handler(Looper.getMainLooper());
    // NWP-20261115-16: the owner's gate look, read in buildUi; DARK draws this screen as it always was.
    private GatePalette pal = GatePalette.DARK;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(true); setTurnScreenOn(true); }
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Amnesia invariant: this is a user-0-only surface. If a roamed user is foreground (a race vs. the login
        // cancel), do NOT draw over it -- its OWN Clock alarm rings there.
        // NWP-20260914-02: record WHICH WAY this guard went. It is the leading hypothesis for the
        // flash-and-vanish report and no log on a user build could confirm or refute it -- the outcome is
        // a RELATION (are we the foreground user or not), never a user id, so it carries nothing about a
        // session. Both branches are recorded: "the guard fired" and "the guard passed" are different
        // answers and an absent line would be a third, indistinguishable from the activity never starting.
        if (currentUser() != 0) {
            GateTrace.ev("ui-guard-other");
            finish();
            return;
        }
        GateTrace.ev("ui-guard-self");
        autoSoFar = GateAlarmAuto.sane(getIntent().getIntExtra(GateAlarmAuto.EXTRA, 0));
        setContentView(buildUi());
        // Vibrate FIRST (VibratorService lives in system_server -- always reachable from this domain), so the
        // alarm is felt even if the audio path fails. Then ring OFF the main thread: creating the Ringtone's
        // MediaPlayer looks up media.audio_flinger, and a missing service_manager grant makes that lookup WAIT
        // FOREVER (libaudiobase retries on a cv -- no exception) -- on the main thread that ANR'd the whole
        // gate the moment the alarm fired (trace anr_2026-07-17-16-55-05).
        startVibrate();
        new Thread(this::startRing, "gate-alarm-ring").start();
        // NWP-20261116-12: unanswered for GateAlarmAuto.RING_MS, the alarm snoozes or dismisses itself; stopRinging cancels it.
        h.postDelayed(unattended, GateAlarmAuto.RING_MS);
        // After the UI and the ring are under way, never before: the trace must not be in front of the
        // thing the user is waiting for.
        sCreatedAt = android.os.SystemClock.elapsedRealtime();
        GateTrace.ev("ui-create");
        if (guardErr) { guardErr = false; GateTrace.ev("ui-guard-err"); }
        if (vibrateErr) GateTrace.ev("ui-vibrate-err");
    }

    private void startVibrate() {
        try {
            vib = (Vibrator) getSystemService(VIBRATOR_SERVICE);
            if (vib != null && vib.hasVibrator()) {
                long[] pat = {0, 600, 600};
                // Tag the vibration USAGE_ALARM (like the ring's AudioAttributes): a bare vibrate() is
                // USAGE_UNKNOWN, which VibratorManagerService silently suppresses under the gate's settings
                // profile -- proven on lynx 2026-07-17 (audible ring, no buzz, no exception logged).
                if (Build.VERSION.SDK_INT >= 33) {
                    vib.vibrate(VibrationEffect.createWaveform(pat, 0),
                            android.os.VibrationAttributes.createForUsage(android.os.VibrationAttributes.USAGE_ALARM));
                } else if (Build.VERSION.SDK_INT >= 26) {
                    vib.vibrate(VibrationEffect.createWaveform(pat, 0), new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM).build());
                } else {
                    vib.vibrate(pat, 0);
                }
            }
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "alarm vibrate", t);
            vibrateErr = true; // NWP-20261028-13: traced by onCreate once the ring is under way; logcat is unreadable on a user build
        }
    }

    /** Runs on the gate-alarm-ring worker thread -- never the main thread (see onCreate). */
    private void startRing() {
        try {
            Uri u = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM);
            if (u == null) u = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
            Ringtone r = RingtoneManager.getRingtone(getApplicationContext(), u);
            if (r == null) return;
            r.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build());
            if (Build.VERSION.SDK_INT >= 28) r.setLooping(true);
            ring = r;
            if (stopped) { try { r.stop(); } catch (Throwable ignore) {} return; } // Snooze/Dismiss won the race
            r.play();
            GateTrace.ev("ui-ring");
            if (Build.VERSION.SDK_INT < 28) h.post(reRing); // pre-28 Ringtone doesn't loop -> replay it
        } catch (Throwable t) {
            GateTrace.ev("ui-ring-err");
            android.util.Log.w("NowhereChooser", "alarm ring", t);
        }
    }

    private final Runnable reRing = new Runnable() {
        @Override public void run() {
            try { if (!stopped && ring != null && !ring.isPlaying()) ring.play(); } catch (Throwable ignore) {}
            if (!stopped) h.postDelayed(this, 3000);
        }
    };

    /**
     * NWP-20261116-12 (dn-1023 #12, #64): nobody acted on the ring for GateAlarmAuto.RING_MS. Snooze as the button
     * does, carrying one more automatic snooze on the re-armed alarm; once three have run, dismiss as the button does.
     * A lambda, so this::finish names the activity.
     */
    private final Runnable unattended = () -> {
        if (stopped) return; // Snooze, Dismiss or a volume press got there first
        if (GateAlarmAuto.snoozes(autoSoFar)) {
            GateTrace.ev("ui-auto-snooze");
            stopRinging();
            ChooserActivity.scheduleGateAlarmAt(getApplicationContext(), System.currentTimeMillis() + SNOOZE_MS, GateAlarmAuto.next(autoSoFar));
            silenceSessionClock(this::finish);
        } else {
            GateTrace.ev("ui-auto-dismiss");
            stopRinging();
            ChooserActivity.cancelGateAlarm(getApplicationContext(), "cancel-dismiss");
            silenceSessionClock(this::finish);
        }
    };

    private void stopRinging() {
        stopped = true;
        h.removeCallbacks(reRing);
        h.removeCallbacks(unattended);
        try { if (ring != null) ring.stop(); } catch (Throwable ignore) {}
        try { if (vib != null) vib.cancel(); } catch (Throwable ignore) {}
    }

    @Override protected void onDestroy() {
        stopRinging();
        try { getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON); } catch (Throwable ignore) {}
        // NWP-20260914-02: how long this surface actually lived. A two-digit ms here IS the flash-and-vanish
        // report, as a number instead of a description.
        try {
            long ms = sCreatedAt == 0 ? -1 : android.os.SystemClock.elapsedRealtime() - sCreatedAt;
            // A surface that lived for hours would push ms past the report scrubber's 7-digit redaction (any
            // run of 7+ digits becomes <num>), so a long life gets its own verb rather than a number that
            // would arrive unreadable.
            if (ms < 0 || ms >= 1000000L) GateTrace.ev("ui-destroy-long");
            else GateTrace.ev("ui-destroy", "ms", (int) ms);
        } catch (Throwable ignore) {
        }
        super.onDestroy();
    }

    /** Don't let Back leave a ringing-but-hidden alarm (or expose the gate mid-ring). */
    @Override public void onBackPressed() { /* no-op */ }

    @Override public boolean dispatchKeyEvent(KeyEvent event) {
        int kc = event.getKeyCode();
        if (kc == KeyEvent.KEYCODE_VOLUME_UP || kc == KeyEvent.KEYCODE_VOLUME_DOWN || kc == KeyEvent.KEYCODE_VOLUME_MUTE) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) stopRinging(); // a volume press silences the alarm
            return true; // consumed -- PhoneWindow must never see these (no MediaSessionManager here)
        }
        return super.dispatchKeyEvent(event);
    }

    // ===== programmatic UI (the gate has no XML layouts; build views in code, like IncomingCallActivity) =====

    private View buildUi() {
        pal = GatePalette.forLook(getSharedPreferences("nowhere_gate", MODE_PRIVATE).getString(GatePalette.KEY, null));
        ChooserActivity.applyGateBars(getWindow(), pal);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(pal.callBg);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(28), dp(110), dp(28), dp(56));

        TextView label = new TextView(this);
        label.setText("Alarm");
        label.setTextColor(pal.callLabel);
        label.setTextSize(18);
        label.setGravity(Gravity.CENTER);
        root.addView(label, wrapRow(0));

        TextView time = new TextView(this);
        time.setText(new SimpleDateFormat("h:mm a", Locale.getDefault()).format(new Date()));
        time.setTextColor(pal.callInk);
        time.setTextSize(46);
        time.setGravity(Gravity.CENTER);
        root.addView(time, wrapRow(dp(10)));

        View spacer = new View(this);
        root.addView(spacer, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER);
        row.addView(bigBtn("Snooze", pal.neutralBtn, v -> snooze()), btnLp());
        row.addView(bigBtn("Dismiss", pal.answer, v -> dismiss()), btnLp());
        root.addView(row, wrapRow(dp(12)));
        return root;
    }

    private void snooze() {
        GateTrace.ev("ui-snooze");
        stopRinging();
        ChooserActivity.scheduleGateAlarmAt(getApplicationContext(), System.currentTimeMillis() + SNOOZE_MS);
        silenceSessionClock(this::finish);
    }

    private void dismiss() {
        GateTrace.ev("ui-dismiss");
        stopRinging();
        ChooserActivity.cancelGateAlarm(getApplicationContext(), "cancel-dismiss");
        silenceSessionClock(this::finish);
    }

    /**
     * NWP-20260913-05b: also stop the clock app in the ROAMED user, because ours may not be the only thing
     * ringing.
     *
     * ⚠ THIS BUTTON IS IN USER 0 AND THE OTHER ALARM IS IN USER 15. Our gate alarm is a COPY of the roamed
     * alarm’s time, so when the roamed session still rings its own -- device-observed on lynx 2026-09-13
     * after a cold lock, audio uid 1510160 -- BOTH fire at the same instant and stopRinging() silences only
     * ours. The user would tap Dismiss and still be listening to a clock they cannot reach. `am force-stop
     * --user 15 com.android.deskclock` is what silenced it by hand that morning; this is that, asked of the
     * daemon, which is the only side with the reach.
     *
     * ⚠ THE TARGET IS NOT PASSED FROM HERE. The daemon force-stops whatever SET-GATE-ALARM recorded as the
     * alarm’s creator, so a compromised gate cannot name an arbitrary package in an arbitrary user. Fire and
     * forget, off the main thread, and never allowed to block finish(): a phone that will not stop ringing is
     * the complaint this whole slice exists for, and an ANR here would recreate it exactly.
     */
    private void silenceSessionClock(final Runnable then) {
        final android.os.Handler h = new android.os.Handler(android.os.Looper.getMainLooper());
        final java.util.concurrent.atomic.AtomicBoolean done = new java.util.concurrent.atomic.AtomicBoolean();
        // ⚠ FINISH EVEN IF THE DAEMON NEVER ANSWERS. A phone that will not stop ringing is the complaint this
        // whole slice exists for; a hung Dismiss button would BE that complaint.
        h.postDelayed(() -> { if (done.compareAndSet(false, true)) then.run(); }, 2500);
        new Thread(() -> {
            String reply = DaemonSocket.roundTrip("SILENCE-GATE-ALARM\n", 2000);
            // ⚠⚠ THE REPLY IS THE ONLY SIGNAL THERE IS. DaemonSocket.roundTrip NEVER THROWS -- it returns "" on
            // a failed connect, a timeout and any exception alike (DaemonSocket.java) -- so the try/catch this
            // used to have was dead code and the call was completely silent. On 2026-09-13 Chester tapped
            // Snooze at a cold-locked gate, the other clock kept ringing, and NOTHING was logged on either
            // side: the daemon was alive and logging, the target was present, and the chooser had simply
            // thrown the answer away. Third silent path in this one feature, all three mine.
            // NWP-20261028-13: ok ONLY for a literal OK. ERR-LIVE / NONE / ERR-STALE mean the session's clock
            // may still be ringing, which is exactly what a gate report must be able to say.
            GateTrace.ev(GateAlarmVerbs.silence(reply));
            android.util.Log.i("NowhereChooser", "#151 silence: daemon replied "
                    + (reply.isEmpty() ? "<EMPTY -- the call did not reach the daemon>" : reply));
            h.post(() -> { if (done.compareAndSet(false, true)) then.run(); });
        }, "nowhere-alarm-silence").start();
    }

    private LinearLayout.LayoutParams btnLp() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(60), 1f);
        int m = dp(8); lp.setMargins(m, m, m, m);
        return lp;
    }

    private Button bigBtn(String text, int color, View.OnClickListener cl) {
        Button btn = new Button(this);
        btn.setText(text);
        btn.setAllCaps(false);
        btn.setTextColor(pal.onBtn);
        btn.setTextSize(17);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(color);
        bg.setCornerRadius(dp(14));
        btn.setBackground(bg);
        btn.setOnClickListener(cl);
        return btn;
    }

    private LinearLayout.LayoutParams wrapRow(int topMargin) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = topMargin;
        return lp;
    }

    private int dp(int v) { return Math.round(getResources().getDisplayMetrics().density * v); }

    private static int currentUser() {
        try { return ActivityManager.getCurrentUser(); }
        catch (Throwable t) {
            // NWP-20261028-13: still user 0, so the alarm rings -- a missed alarm is the worse failure than
            // drawing over a roamed session in a race. onCreate traces ui-guard-err after the ring is under
            // way (then ui-guard-self), so the choice is visible without sitting in front of the alarm.
            guardErr = true;
            return 0;
        }
    }
}
