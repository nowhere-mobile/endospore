package com.nowhere.chooser;

import android.Manifest;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioRecordingConfiguration;
import android.media.AudioTrack;
import android.os.SystemClock;
import android.telecom.TelecomManager;
import android.util.Log;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * NWP-20261210-11: the debug-only R0 call-relay spike verb (docs/call-relay.md section 14). The pure half, the run
 * procedure and why this is debug-only are in CallRelaySpike's header.
 *
 * Not exported and no intent-filter: only root (adb root, `am broadcast -n`) or the chooser itself can reach it. The
 * FIRST statement of onReceive refuses the verb unless ro.debuggable is exactly "1", before any extra, service or
 * thread, so a user build does nothing but log the refusal.
 *
 * One run at a time (BUSY). The run is on a plain new Thread and onReceive returns at once: the run lasts longer than
 * the broadcast timeout, so it holds no broadcast result. It answers through TelecomManager.acceptRingingCall. It never
 * hangs up (the human ends the call) and never reads a number or a caller.
 */
public final class CallRelaySpikeReceiver extends BroadcastReceiver {

    private static final AtomicBoolean BUSY = new AtomicBoolean(false);
    private static final int RATE = 48000;

    @Override public void onReceive(Context ctx, Intent intent) {
        if (!CallRelaySpike.allowed(sysProp("ro.debuggable", "0"))) { Log.i(CallRelaySpike.TAG, CallRelaySpike.REFUSED); return; }
        if (!BUSY.compareAndSet(false, true)) {
            Log.i(CallRelaySpike.TAG, CallRelaySpike.BUSY);
            return;
        }
        try {
            final Context app = ctx.getApplicationContext();
            final int[] modes = CallRelaySpike.parseModes(intent.getStringExtra("modes"));
            final int secs = CallRelaySpike.clampSecs(intent.getIntExtra("secs", 0));
            Thread t = new Thread(() -> runSpike(app, modes, secs), CallRelaySpike.TAG);
            t.start();
        } catch (Throwable e) {
            BUSY.set(false);
            Log.i(CallRelaySpike.TAG, CallRelaySpike.errLine("thread", e.getClass().getSimpleName()));
        }
    }

    /** Copied from ChooserActivity.sysProp (private there): a denied or empty read returns def. */
    private static String sysProp(String key, String def) {
        try {
            String v = android.os.SystemProperties.get(key, "");
            return (v == null || v.isEmpty()) ? def : v;
        } catch (Throwable t) {
            return def;
        }
    }

    private static String cls(Throwable e) {
        return e.getClass().getSimpleName();
    }

    private static void log(String line) {
        Log.i(CallRelaySpike.TAG, line);
    }

    private static void runSpike(Context app, int[] modes, int secs) {
        try {
            runInCall(app, modes, secs);
        } catch (Throwable e) {
            log(CallRelaySpike.errLine("setup", cls(e)));
        } finally {
            BUSY.set(false);
        }
    }

    private static void runInCall(Context app, int[] modes, int secs) throws InterruptedException {
        final AudioManager am = app.getSystemService(AudioManager.class);
        final TelecomManager tm = app.getSystemService(TelecomManager.class);
        if (am == null || tm == null) {
            log(CallRelaySpike.errLine("setup", "NoService"));
            return;
        }
        final int priorMode = am.getMode();
        final boolean ringing = tm.isRinging();
        log(CallRelaySpike.startLine(am.isPstnCallAudioInterceptable(), am.isCallScreeningModeSupported(), priorMode,
                app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
                ringing));
        if (ringing) {
            tm.acceptRingingCall();
            log(CallRelaySpike.ANSWERED);
            long until = SystemClock.elapsedRealtime() + 5000;
            while (!tm.isInCall() && SystemClock.elapsedRealtime() < until) Thread.sleep(200);
        }
        if (!tm.isInCall()) {
            log(CallRelaySpike.NO_CALL);
            return;
        }

        AudioRecord rec = null;
        AudioTrack track = null;
        Thread writer = null;
        final AtomicBoolean stop = new AtomicBoolean(false);
        try {
            for (int m : modes) {
                try {
                    am.setMode(m);
                    Thread.sleep(300);
                    int got = am.getMode();
                    log(CallRelaySpike.modeLine(m, got));
                    if (got == m) break;
                } catch (InterruptedException e) {
                    throw e;
                } catch (Throwable e) {
                    log(CallRelaySpike.modeErrLine(m, cls(e)));
                }
            }

            am.setMicrophoneMute(true);
            try {
                rec = am.getCallDownlinkExtractionAudioRecord(new AudioFormat.Builder().setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build());
                if (rec == null) {
                    log(CallRelaySpike.errLine("downlink", "Null"));
                } else {
                    rec.startRecording();
                }
            } catch (Throwable e) {
                log(CallRelaySpike.errLine("downlink", cls(e)));
                if (rec != null) {
                    try { rec.release(); } catch (Throwable ignored) { }
                    rec = null;
                }
            }
            try {
                track = am.getCallUplinkInjectionAudioTrack(new AudioFormat.Builder().setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build());
                if (track == null) {
                    log(CallRelaySpike.errLine("uplink", "Null"));
                } else {
                    track.play();
                    final AudioTrack out = track;
                    // 4800 frames is 100 ms: 100 whole cycles of 1 kHz at 48 kHz, so the loop has no seam.
                    final short[] buf = CallRelaySpike.tone(RATE, 2, 1000, 4800, 0.25);
                    writer = new Thread(() -> {
                        try {
                            while (!stop.get()) {
                                if (out.write(buf, 0, buf.length) < 0) {
                                    log(CallRelaySpike.errLine("uplink", "WriteError"));
                                    return;
                                }
                            }
                        } catch (Throwable e) {
                            log(CallRelaySpike.errLine("uplink", cls(e)));
                        }
                    }, CallRelaySpike.TAG + "-tx");
                    writer.start();
                }
            } catch (Throwable e) {
                log(CallRelaySpike.errLine("uplink", cls(e)));
                if (track != null) {
                    try { track.release(); } catch (Throwable ignored) { }
                    track = null;
                }
            }

            final short[] sec = new short[RATE];
            for (int i = 0; i < secs; i++) {
                long start = SystemClock.elapsedRealtime();
                int filled = 0;
                if (rec != null) {
                    long until = start + 1500;
                    while (filled < sec.length && SystemClock.elapsedRealtime() < until) {
                        int r = rec.read(sec, filled, sec.length - filled);
                        if (r <= 0) break;
                        filled += r;
                    }
                }
                long left = 1000 - (SystemClock.elapsedRealtime() - start);
                if (left > 0 && filled < sec.length) Thread.sleep(left);
                int silenced = -1;
                if (rec != null) {
                    AudioRecordingConfiguration rc = rec.getActiveRecordingConfiguration();
                    if (rc != null) silenced = rc.isClientSilenced() ? 1 : 0;
                }
                int head = track != null ? track.getPlaybackHeadPosition() : -1;
                int under = track != null ? track.getUnderrunCount() : -1;
                log(CallRelaySpike.secondLine(i, am.getMode(), am.isMicrophoneMute(), silenced,
                        CallRelaySpike.dbfs(sec, filled), head, under));
            }
        } finally {
            stop.set(true);
            if (track != null) {
                try { track.pause(); track.flush(); track.stop(); } catch (Throwable e) { log(CallRelaySpike.errLine("uplink", cls(e))); }
            }
            if (writer != null) {
                try { writer.join(1000); } catch (Throwable ignored) { }
            }
            if (track != null) {
                try { track.release(); } catch (Throwable e) { log(CallRelaySpike.errLine("uplink", cls(e))); }
            }
            if (rec != null) {
                try { rec.stop(); } catch (Throwable e) { log(CallRelaySpike.errLine("downlink", cls(e))); }
                try { rec.release(); } catch (Throwable e) { log(CallRelaySpike.errLine("downlink", cls(e))); }
            }
            try { am.setMicrophoneMute(false); } catch (Throwable e) { log(CallRelaySpike.errLine("unmute", cls(e))); }
            try { am.setMode(AudioManager.MODE_NORMAL); } catch (Throwable e) { log(CallRelaySpike.errLine("restore", cls(e))); }
            try { log(CallRelaySpike.endLine(am.getMode(), am.isMicrophoneMute())); } catch (Throwable ignored) { }
        }
    }
}
