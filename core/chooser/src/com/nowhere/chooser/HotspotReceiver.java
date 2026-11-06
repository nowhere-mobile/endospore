package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.TetheringManager;
import android.net.wifi.SoftApConfiguration;
import android.net.wifi.WifiManager;
import android.net.wifi.WifiSsid;
import android.os.SystemClock;
import android.os.UserHandle;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Ends a session's shared connection (NWP-20261028-08): roamd, as root, calls this by explicit component at every
 * release path and at boot. It stops all three types and replaces the soft-AP configuration with a fresh random one,
 * which overwrites whatever name and passphrase the session set in WifiConfigStoreSoftAp.xml (the framework rewrites
 * the file on every set) -- amnesia, not a choice. Contract: Hotspot.ACTION_RELEASE, Hotspot.EXTRA_UID (-1 =
 * unconditional), result data OK RELEASED / OK KEPT / ERR-HS <reason>. NEVER log or reply a name or passphrase.
 */
public class HotspotReceiver extends BroadcastReceiver {
    private static final String TAG = "NowhereChooser";
    private static final ExecutorService WORK = Executors.newSingleThreadExecutor();

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !Hotspot.ACTION_RELEASE.equals(intent.getAction())) return;
        if (UserHandle.myUserId() != 0) {
            setResultData(Hotspot.errLine(Hotspot.R_USER));
            return;
        }
        final int uid = intent.getIntExtra(Hotspot.EXTRA_UID, -1);
        final PendingResult pr = goAsync();
        final Context app = context.getApplicationContext() != null ? context.getApplicationContext() : context;
        WORK.execute(() -> {
            String line = Hotspot.errLine(Hotspot.R_FAILED);
            try {
                line = release(app, uid);
            } catch (SecurityException e) {
                line = Hotspot.errLine(Hotspot.R_DENIED);
            } catch (Throwable e) {
                line = Hotspot.errLine(Hotspot.R_FAILED);
            } finally {
                Log.i(TAG, "hotspot release user=" + uid + ": " + line);
                pr.setResultData(line);
                pr.finish();
            }
        });
    }

    private static String release(Context ctx, int uid) {
        synchronized (HotspotService.LOCK) {
            if (Hotspot.releaseDecision(HotspotService.owner, uid) == Hotspot.Release.KEEP) return Hotspot.OK_KEPT;
            TetheringManager tm = ctx.getSystemService(TetheringManager.class);
            WifiManager wm = ctx.getSystemService(WifiManager.class);
            // Every stop and the reset are attempted whatever any one of them does; a failure is reported, never hidden.
            String err = null;
            for (String t : Hotspot.types()) {
                try {
                    tm.stopTethering(tetherType(t));
                } catch (SecurityException e) {
                    err = Hotspot.errLine(Hotspot.R_DENIED);
                } catch (RuntimeException e) {
                    if (err == null) err = Hotspot.errLine(Hotspot.R_FAILED);
                }
            }
            java.security.SecureRandom rng = new java.security.SecureRandom();
            String s = Hotspot.resetSsid(rng);
            String p = Hotspot.resetPassphrase(rng);
            WifiSsid want = WifiSsid.fromBytes(s.getBytes(StandardCharsets.UTF_8));
            boolean set;
            try {
                set = wm.setSoftApConfiguration(new SoftApConfiguration.Builder()
                        .setWifiSsid(want)
                        .setPassphrase(p, SoftApConfiguration.SECURITY_TYPE_WPA2_PSK)
                        .build());
            } catch (SecurityException e) {
                if (err == null) err = Hotspot.errLine(Hotspot.R_DENIED);
                set = false;
            } catch (RuntimeException e) {
                set = false;
            }
            HotspotService.owner = null;
            if (!set) return err != null ? err : Hotspot.errLine(Hotspot.R_RESET);
            WifiSsid got = wm.getSoftApConfiguration().getWifiSsid();
            if (got == null || !got.equals(want)) return err != null ? err : Hotspot.errLine(Hotspot.R_RESET);
            long deadline = SystemClock.elapsedRealtime() + Hotspot.RESET_READBACK_MS;
            while (wm.getWifiApState() == WifiManager.WIFI_AP_STATE_ENABLED) {
                if (SystemClock.elapsedRealtime() >= deadline) return err != null ? err : Hotspot.errLine(Hotspot.R_FAILED);
                SystemClock.sleep(100);
            }
            return err != null ? err : Hotspot.OK_RELEASED;
        }
    }

    private static int tetherType(String type) {
        switch (type) {
            case Hotspot.TYPE_USB: return TetheringManager.TETHERING_USB;
            case Hotspot.TYPE_BLUETOOTH: return TetheringManager.TETHERING_BLUETOOTH;
            default: return TetheringManager.TETHERING_WIFI;
        }
    }
}
