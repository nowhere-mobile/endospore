package com.nowhere.chooser;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.IBinder;
import android.os.Parcel;
import android.os.UserHandle;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * A session's side of the gate's HotspotService (NWP-20261028-11): bind it in user 0, make ONE transaction, unbind.
 * The contract (codes, parcel layout, one-line replies) is Hotspot's; the service is HotspotService.
 *
 * The name and passphrase cross only in the Binder parcel, here, in process. Nothing in this class logs, toasts or
 * returns them. transact BLOCKS (the bind waits up to BIND_WAIT_MS, START/STOP up to 10 s in the service): callers
 * run it off the main thread. A failure of any kind answers "", which Hotspot.toast and Hotspot.switchOn read as
 * "not confirmed" and "off".
 */
final class HotspotClient {
    private HotspotClient() {}

    static final int BIND_WAIT_MS = 5_000;

    /** STATE: the gate's one-line state, or "" when it could not be asked. */
    static String state(Context c) {
        return transact(c, Hotspot.STATE, null, null, null);
    }

    /** STOP one type. */
    static String stop(Context c, String type) {
        return transact(c, Hotspot.STOP, type, null, null);
    }

    /** START one type; ssid and pass are read only for wifi. */
    static String start(Context c, String type, String ssid, String pass) {
        return transact(c, Hotspot.START, type, ssid, pass);
    }

    private static String transact(Context c, int code, String type, String ssid, String pass) {
        final IBinder[] box = new IBinder[1];
        final CountDownLatch up = new CountDownLatch(1);
        ServiceConnection conn = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName n, IBinder b) {
                box[0] = b;
                up.countDown();
            }

            @Override
            public void onServiceDisconnected(ComponentName n) {}
        };
        boolean bound = false;
        try {
            Intent i = new Intent().setClassName(c.getPackageName(), HotspotService.class.getName());
            bound = c.bindServiceAsUser(i, conn, Context.BIND_AUTO_CREATE, UserHandle.SYSTEM);
            if (!bound || !up.await(BIND_WAIT_MS, TimeUnit.MILLISECONDS) || box[0] == null) return "";
            Parcel data = Parcel.obtain();
            Parcel reply = Parcel.obtain();
            try {
                if (type != null) data.writeString(type);
                if (code == Hotspot.START && Hotspot.TYPE_WIFI.equals(type)) {
                    data.writeString(ssid);
                    data.writeString(pass);
                }
                if (!box[0].transact(code, data, reply, 0)) return "";
                String line = reply.readString();
                return line == null ? "" : line;
            } finally {
                data.recycle();
                reply.recycle();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return "";
        } catch (Throwable t) {
            return "";
        } finally {
            if (bound) {
                try {
                    c.unbindService(conn);
                } catch (Throwable ignore) {
                    // already gone
                }
            }
        }
    }
}
