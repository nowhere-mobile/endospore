package com.nowhere.chooser;

import android.app.AlarmManager;
import android.content.Context;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.SystemClock;
import android.os.UserHandle;
import java.lang.reflect.Field;
import java.util.HashSet;
import java.util.Set;

/** NWP-20261022-13: runs the real OtaWakeReceiver against stubs. Exit 0 = all pass, 1 = a case failed. */
public class OtaWakeCases {
    static final long MIN = 60_000L;
    static final long T0 = 1_000_000L;
    static int failed = 0;
    static Context ctx;
    static AlarmManager am;
    static ConnectivityManager cm;
    static NetworkCapabilities nc;

    static void check(boolean ok, String what) {
        if (!ok) { failed++; System.out.println("--- FAIL: " + what); }
    }

    /** Fresh world: user 0, validated network, no reply, count reset. */
    static void reset() throws Exception {
        ctx = new Context();
        am = new AlarmManager();
        cm = new ConnectivityManager();
        nc = new NetworkCapabilities();
        nc.caps.add(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
        cm.active = new Network();
        cm.caps = nc;
        ctx.services.put(Context.ALARM_SERVICE, am);
        ctx.services.put(Context.CONNECTIVITY_SERVICE, cm);
        SystemClock.now = T0;
        UserHandle.userId = 0;
        DaemonSocket.sent.clear();
        DaemonSocket.reply = "";
        DaemonSocket.boom = false;
        Field f = OtaWakeReceiver.class.getDeclaredField("sConsecutiveFast");
        f.setAccessible(true);
        f.setInt(null, 0);
    }

    static void fire(String action) {
        new OtaWakeReceiver().onReceive(ctx, new Intent(ctx, OtaWakeReceiver.class).setAction(action));
    }

    static long delay(int i) { return (Long) am.calls.get(i)[1] - T0; }

    static boolean normal(long d) { return d >= 100 * MIN && d <= 140 * MIN; }

    static void oneRefresh(String action, String reply, String tag) {
        check(DaemonSocket.sent.size() == 1, tag + ": exactly one OTA-REFRESH, got " + DaemonSocket.sent.size());
        if (DaemonSocket.sent.size() == 1) {
            String[] l = DaemonSocket.sent.get(0).split("\n");
            check(l.length >= 2 && l[0].equals("OTA-REFRESH") && l[1].equals(tag.contains("power") ? "power" : "alarm"),
                    tag + ": message was " + DaemonSocket.sent.get(0).replace("\n", "|"));
        }
        check(am.calls.size() == 1, tag + ": exactly one alarm, got " + am.calls.size());
        if (am.calls.size() == 1) check(normal(delay(0)), tag + ": delay " + delay(0) / MIN + " min not in [100,140]");
    }

    static void noRefreshOneAlarm(String tag) {
        check(DaemonSocket.sent.isEmpty(), tag + ": no OTA-REFRESH, got " + DaemonSocket.sent.size());
        check(am.calls.size() == 1, tag + ": exactly one alarm, got " + am.calls.size());
        if (am.calls.size() == 1) check(normal(delay(0)), tag + ": delay " + delay(0) / MIN + " min not in [100,140]");
    }

    static void nothing(String tag) {
        check(DaemonSocket.sent.isEmpty(), tag + ": sent " + DaemonSocket.sent.size());
        check(am.calls.isEmpty(), tag + ": armed " + am.calls.size());
    }

    public static void main(String[] a) throws Exception {
        // (1) alarm action, validated network, any non-empty reply -> normal cadence
        for (String r : new String[] {"CHECKING", "NOSTORE", "DONE"}) {
            reset(); DaemonSocket.reply = r;
            fire(OtaWakeReceiver.ACTION);
            oneRefresh(OtaWakeReceiver.ACTION, r, "1 alarm " + r);
        }
        // (2) power connected
        reset(); DaemonSocket.reply = "CHECKING";
        fire(Intent.ACTION_POWER_CONNECTED);
        oneRefresh(Intent.ACTION_POWER_CONNECTED, "CHECKING", "2 power");

        // (3) no usable network: no round trip, still re-armed at the normal cadence
        reset(); cm.active = null;
        fire(OtaWakeReceiver.ACTION); noRefreshOneAlarm("3 no network");
        reset(); nc.caps.clear(); nc.caps.add(NetworkCapabilities.NET_CAPABILITY_INTERNET);
        fire(OtaWakeReceiver.ACTION); noRefreshOneAlarm("3 not validated");
        reset(); cm.caps = null;
        fire(OtaWakeReceiver.ACTION); noRefreshOneAlarm("3 null capabilities");

        // (4) the round trip throws: the alarm is still re-armed
        reset(); DaemonSocket.boom = true;
        fire(OtaWakeReceiver.ACTION);
        check(DaemonSocket.sent.size() == 1, "4 the round trip was attempted");
        check(am.calls.size() == 1, "4 a throwing round trip still re-arms exactly once, got " + am.calls.size());
        if (am.calls.size() == 1) check(normal(delay(0)), "4 delay " + delay(0) / MIN + " min");

        // (5) setExact throws -> setAndAllowWhileIdle with the same time
        reset(); am.exactThrows = true; DaemonSocket.reply = "CHECKING";
        fire(OtaWakeReceiver.ACTION);
        check(am.calls.size() == 1 && am.calls.get(0)[0].equals("inexact"), "5 fell back to the inexact alarm");
        if (am.calls.size() == 1) check(normal(delay(0)), "5 delay " + delay(0) / MIN + " min");
        reset(); am.exactThrows = true;
        OtaWakeReceiver.arm(ctx, 7 * MIN);
        check(am.calls.size() == 1 && am.calls.get(0)[0].equals("inexact") && (Long) am.calls.get(0)[1] == T0 + 7 * MIN,
                "5 the fallback carries the same time as the exact call would have");

        // (6) the fast lane: empty reply, at most FAST_MAX in a row, then the count resets
        reset();
        for (int i = 0; i < 4; i++) fire(OtaWakeReceiver.ACTION);
        check(am.calls.size() == 4, "6 four wakes arm four alarms");
        if (am.calls.size() == 4) {
            check(delay(0) == 20 * MIN && delay(1) == 20 * MIN && delay(2) == 20 * MIN,
                    "6 first three empty replies are 20 min: " + delay(0) / MIN + "," + delay(1) / MIN + "," + delay(2) / MIN);
            check(normal(delay(3)), "6 the fourth empty reply is back on the normal cadence: " + delay(3) / MIN);
        }
        am.calls.clear();
        fire(OtaWakeReceiver.ACTION);
        check(am.calls.size() == 1 && delay(0) == 20 * MIN, "6 the count reset: the next empty reply is fast again");
        reset();
        fire(OtaWakeReceiver.ACTION); fire(OtaWakeReceiver.ACTION);
        DaemonSocket.reply = "CHECKING";
        fire(OtaWakeReceiver.ACTION);
        check(am.calls.size() == 3 && normal(delay(2)), "6 a non-empty reply after two fast ones is the normal cadence");
        DaemonSocket.reply = "";
        am.calls.clear();
        fire(OtaWakeReceiver.ACTION);
        check(am.calls.size() == 1 && delay(0) == 20 * MIN, "6 and a non-empty reply reset the fast count");

        // (7) any user but 0
        reset(); UserHandle.userId = 1; DaemonSocket.reply = "CHECKING";
        fire(OtaWakeReceiver.ACTION); nothing("7 onReceive as user 1");
        OtaWakeReceiver.arm(ctx); nothing("7 arm(ctx) as user 1");
        OtaWakeReceiver.arm(ctx, 5 * MIN); nothing("7 arm(ctx, delay) as user 1");

        // (8) unrelated action
        reset();
        fire("android.intent.action.BOOT_COMPLETED"); nothing("8 unrelated action");
        reset();
        fire(null); nothing("8 null action");

        // (9) the jitter is there and bounded
        reset(); DaemonSocket.reply = "CHECKING";
        Set<Long> seen = new HashSet<>();
        for (int i = 0; i < 2000; i++) fire(OtaWakeReceiver.ACTION);
        boolean inRange = am.calls.size() == 2000;
        for (int i = 0; i < am.calls.size(); i++) { inRange &= normal(delay(i)); seen.add(delay(i)); }
        check(inRange, "9 every one of 2000 delays is inside [100,140] min");
        check(seen.size() >= 50, "9 jitter: only " + seen.size() + " distinct delays in 2000");

        System.out.println(failed == 0 ? "OK: all OtaWake cases passed" : failed + " check(s) failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
