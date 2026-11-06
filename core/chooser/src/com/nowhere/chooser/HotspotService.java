package com.nowhere.chooser;

import android.app.ActivityManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.TetheringManager;
import android.net.wifi.SoftApConfiguration;
import android.net.wifi.WifiManager;
import android.net.wifi.WifiSsid;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.Process;
import android.os.SystemClock;
import android.os.UserHandle;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * A signed-in profile's hotspot and USB/Bluetooth tethering (NWP-20261028-08; docs/product-decisions.md 2026-10-19).
 *
 * Android keeps tethering for the admin user, and here the admin user is the gate (user 0), whose chooser is
 * platform-signed: TETHER_PRIVILEGED and NETWORK_SETTINGS are granted by declaring them. A session (user 10+) runs
 * a second instance of this same app with no authority of its own, so it BINDS this service in user 0 and asks.
 * Why a Binder and not a command: the passphrase crosses only as a parcel and stays in process, never argv.
 *
 * The contract is Hotspot's (transaction codes, types, one-line replies, the ERR-HS reasons). Plain Binder
 * subclass, no AIDL. START and STOP can block up to 10 s: callers transact off the main thread.
 *
 * The owner (the session that started a type) is a static of this persistent process. If the process restarted it
 * is null and a release stops everything, the safe direction. NEVER log or reply the name or passphrase.
 */
public class HotspotService extends Service {
    private static final String TAG = "NowhereChooser";

    static final Object LOCK = new Object();
    /** The session user that started what is on; null = unknown. Guarded by LOCK. */
    static Integer owner;

    private static final Executor CB = Executors.newSingleThreadExecutor();
    private static boolean watching;
    /** Callback cache: unknown until the first tethered-interface AND regexp events arrive; only interface events confirm a stop. */
    private static final Hotspot.TetherCache CACHE = new Hotspot.TetherCache();

    private final Binder binder = new Binder() {
        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws android.os.RemoteException {
            if (code != Hotspot.START && code != Hotspot.STOP && code != Hotspot.STATE) {
                return super.onTransact(code, data, reply, flags);
            }
            int cu = Binder.getCallingUid();
            boolean sameApp = UserHandle.getAppId(cu) == UserHandle.getAppId(Process.myUid());
            int callerUser = UserHandle.getUserId(cu);
            String op = code == Hotspot.START ? "start" : code == Hotspot.STOP ? "stop" : "state";
            String type = "-";
            String line;
            try {
                if (UserHandle.myUserId() != 0) {
                    line = Hotspot.errLine(Hotspot.R_USER);
                } else if (code == Hotspot.STATE) {
                    line = sameApp ? state() : Hotspot.errLine(Hotspot.R_CALLER);
                } else {
                    String t = data.readString();
                    type = Hotspot.typeOf(t);
                    if (type == null) {
                        type = "-";
                        line = Hotspot.errLine(Hotspot.R_TYPE);
                    } else if (code == Hotspot.START) {
                        line = start(data, type, sameApp, callerUser);
                    } else {
                        line = stop(type, sameApp, callerUser);
                    }
                }
            } catch (SecurityException e) {
                line = Hotspot.errLine(Hotspot.R_DENIED);
            } catch (Throwable e) {
                line = Hotspot.errLine(Hotspot.R_FAILED);
            }
            log(op, type, callerUser, line);
            // The wire format is the bare string (Hotspot.START/STOP/STATE): no exception header before it.
            reply.writeString(line);
            return true;
        }
    };

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    private static void log(String op, String type, int user, String reply) {
        Log.i(TAG, "hotspot " + op + " " + type + " user=" + user + ": " + reply);
    }

    private static int tetherType(String type) {
        switch (type) {
            case Hotspot.TYPE_USB: return TetheringManager.TETHERING_USB;
            case Hotspot.TYPE_BLUETOOTH: return TetheringManager.TETHERING_BLUETOOTH;
            default: return TetheringManager.TETHERING_WIFI;
        }
    }

    private WifiManager wifi() {
        return getSystemService(WifiManager.class);
    }

    private TetheringManager tether() {
        TetheringManager tm = getSystemService(TetheringManager.class);
        synchronized (LOCK) {
            if (!watching) {
                watching = true;
                tm.registerTetheringEventCallback(CB, new TetheringManager.TetheringEventCallback() {
                    @Override
                    public void onTetheredInterfacesChanged(List<String> ifaces) {
                        CACHE.onIfaces(ifaces);
                    }

                    @Override
                    public void onTetherableInterfaceRegexpsChanged(TetheringManager.TetheringInterfaceRegexps r) {
                        CACHE.onRegexs(Collections.singletonList(join(r.getTetherableUsbRegexs())),
                                Collections.singletonList(join(r.getTetherableBluetoothRegexs())));
                    }
                });
            }
        }
        return tm;
    }

    private static String join(List<String> l) {
        return l == null || l.isEmpty() ? "(?!)" : "(?:" + String.join(")|(?:", l) + ")";
    }

    private boolean isOn(String type) {
        if (Hotspot.TYPE_WIFI.equals(type)) {
            return wifi().getWifiApState() == WifiManager.WIFI_AP_STATE_ENABLED;
        }
        // Unknown (the callbacks have not reported yet) counts as ON: never claim off from an empty cache.
        return CACHE.isOn(type);
    }

    private String start(Parcel data, String type, boolean sameApp, int callerUser) {
        synchronized (LOCK) {
            // The foreground is read HERE, under the lock the release takes: a START queued behind a release must
            // see the session already gone, or it would restore the credentials the release just cleared.
            if (!Hotspot.mayStart(sameApp, callerUser, ActivityManager.getCurrentUser())) return Hotspot.errLine(Hotspot.R_CALLER);
            TetheringManager tm = tether();
            if (Hotspot.TYPE_WIFI.equals(type)) {
                String ssid = data.readString();
                String pass = data.readString();
                if (!Hotspot.validSsid(ssid)) return Hotspot.errLine(Hotspot.R_SSID);
                if (!Hotspot.validPassphrase(pass)) return Hotspot.errLine(Hotspot.R_PASSPHRASE);
                try {
                    SoftApConfiguration cfg = new SoftApConfiguration.Builder()
                            .setWifiSsid(WifiSsid.fromBytes(ssid.getBytes(StandardCharsets.UTF_8)))
                            .setPassphrase(pass, SoftApConfiguration.SECURITY_TYPE_WPA2_PSK)
                            .build();
                    if (!wifi().setSoftApConfiguration(cfg)) return Hotspot.errLine(Hotspot.R_CONFIG);
                } catch (SecurityException e) {
                    throw e;
                } catch (RuntimeException e) {
                    return Hotspot.errLine(Hotspot.R_CONFIG);
                }
            }
            // Already on: stop first, so the configuration just set takes effect and a second start is not refused.
            if (isOn(type)) {
                int before = CACHE.mark();
                tm.stopTethering(tetherType(type));
                if (!awaitOff(type, Hotspot.STOP_TIMEOUT_MS, before)) return Hotspot.errLine(Hotspot.R_TIMEOUT);
            }
            final CountDownLatch done = new CountDownLatch(1);
            final boolean[] ok = {false};
            // Recorded BEFORE the start, so a release can always stop what was started.
            owner = callerUser;
            tm.startTethering(new TetheringManager.TetheringRequest.Builder(tetherType(type))
                    .setShouldShowEntitlementUi(false).build(), CB,
                    new TetheringManager.StartTetheringCallback() {
                        @Override
                        public void onTetheringStarted() {
                            ok[0] = true;
                            done.countDown();
                        }

                        @Override
                        public void onTetheringFailed(int error) {
                            done.countDown();
                        }
                    });
            long deadline = SystemClock.elapsedRealtime() + Hotspot.START_TIMEOUT_MS;
            try {
                if (!done.await(Hotspot.START_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                    return Hotspot.errLine(Hotspot.R_TIMEOUT);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return Hotspot.errLine(Hotspot.R_FAILED);
            }
            if (!ok[0]) return Hotspot.errLine(Hotspot.R_FAILED);
            if (Hotspot.TYPE_WIFI.equals(type)) {
                while (true) {
                    int st = wifi().getWifiApState();
                    if (st == WifiManager.WIFI_AP_STATE_ENABLED) break;
                    if (st == WifiManager.WIFI_AP_STATE_FAILED) return Hotspot.errLine(Hotspot.R_FAILED);
                    if (SystemClock.elapsedRealtime() >= deadline) return Hotspot.errLine(Hotspot.R_TIMEOUT);
                    SystemClock.sleep(100);
                }
            }
            return Hotspot.okOn(type);
        }
    }

    private String stop(String type, boolean sameApp, int callerUser) {
        synchronized (LOCK) {
            if (!Hotspot.mayStop(sameApp, callerUser, owner)) return Hotspot.errLine(Hotspot.R_CALLER);
            TetheringManager tm = tether();
            int before = CACHE.mark();
            tm.stopTethering(tetherType(type));
            if (!awaitOff(type, Hotspot.STOP_TIMEOUT_MS, before)) return Hotspot.errLine(Hotspot.R_TIMEOUT);
            boolean any = false;
            for (String t : Hotspot.types()) any |= isOn(t);
            if (!any) owner = null;
            return Hotspot.okOff(type);
        }
    }

    private String state() {
        tether();
        // Give the first callbacks a moment; a type still unknown is reported ON (the safe reading).
        for (int i = 0; i < 20 && !CACHE.known(); i++) SystemClock.sleep(100);
        return Hotspot.stateLine(isOn(Hotspot.TYPE_WIFI), isOn(Hotspot.TYPE_USB), isOn(Hotspot.TYPE_BLUETOOTH));
    }

    /** Off is confirmed only by a callback event newer than {@code since} (the cache may predate the stop). */
    private boolean awaitOff(String type, int ms, int since) {
        long deadline = SystemClock.elapsedRealtime() + ms;
        while (true) {
            boolean off = Hotspot.TYPE_WIFI.equals(type)
                    ? wifi().getWifiApState() != WifiManager.WIFI_AP_STATE_ENABLED
                            && wifi().getWifiApState() != WifiManager.WIFI_AP_STATE_ENABLING
                    : CACHE.stopConfirmed(type, since);
            if (off) return true;
            if (SystemClock.elapsedRealtime() >= deadline) return false;
            SystemClock.sleep(100);
        }
    }
}
