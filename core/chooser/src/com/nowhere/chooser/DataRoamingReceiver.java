package com.nowhere.chooser;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.telephony.SubscriptionInfo;
import android.telephony.SubscriptionManager;
import android.telephony.TelephonyManager;
import android.util.Log;

/**
 * The gate's write path for data roaming (NWP-20261028-06; docs/product-decisions.md, 2026-10-19, the hotspot
 * entry's item 2). The global settings key is inert, so the write goes through
 * {@code TelephonyManager.setDataRoamingEnabled} (the chooser holds MODIFY_PHONE_STATE) and the read-back is
 * siminfo's own data_roaming for the subscription. Telephony posts the write to its own handler before siminfo
 * changes, so a set re-reads until the value settles, at most DataRoaming.READBACK_MS, and reports the LAST read:
 * a write that never landed reads back as the old value, never as the requested one.
 *
 * Reached only by an explicit component from roamd (root); user 0 (the gate) only. The result line is
 * DataRoaming's contract.
 */
public class DataRoamingReceiver extends BroadcastReceiver {
    private static final String TAG = "NowhereChooser";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (android.os.UserHandle.myUserId() != 0) {
            setResult(Activity.RESULT_OK, DataRoaming.errLine("user"), null);
            return;
        }
        if (intent == null || !DataRoaming.ACTION.equals(intent.getAction())) return;
        final String op = intent.getStringExtra(DataRoaming.EXTRA_OP);
        final boolean hasValue = intent.hasExtra(DataRoaming.EXTRA_VALUE);
        final int value = intent.getIntExtra(DataRoaming.EXTRA_VALUE, -1);
        final int extraSub = intent.getIntExtra(DataRoaming.EXTRA_SUB, -1);
        final PendingResult pending = goAsync();
        final Context app = ctx.getApplicationContext();
        new Thread(() -> {
            String line = DataRoaming.errLine("failed");
            try {
                line = run(app, op, hasValue, value, extraSub);
            } catch (Throwable t) {
                Log.w(TAG, "data-roaming", t);
            } finally {
                pending.setResult(Activity.RESULT_OK, line, null);
                pending.finish();
                Log.i(TAG, "data-roaming op=" + op + " sub=" + extraSub + " -> " + line);
            }
        }, "nowhere-dataroaming").start();
    }

    private static String run(Context app, String op, boolean hasValue, int value, int extraSub) {
        final String which = DataRoaming.parseOp(op, hasValue, value);
        if (which == null) return DataRoaming.errLine("arg");
        final int sub = DataRoaming.pickSub(extraSub, SubscriptionManager.getDefaultDataSubscriptionId());
        if (sub < 0) return DataRoaming.errLine("nosub");
        final boolean isSet = DataRoaming.OP_SET.equals(which);
        if (isSet) {
            try {
                TelephonyManager tm = app.getSystemService(TelephonyManager.class).createForSubscriptionId(sub);
                tm.setDataRoamingEnabled(value == 1);
            } catch (SecurityException e) {
                return DataRoaming.errLine("denied");
            } catch (Throwable t) {
                return DataRoaming.errLine("failed");
            }
        }
        final SubscriptionManager sm = app.getSystemService(SubscriptionManager.class);
        final long t0 = SystemClock.elapsedRealtime();
        int seen;
        while (true) {
            SubscriptionInfo info;
            try {
                info = sm.getActiveSubscriptionInfo(sub);
            } catch (Throwable t) {
                return DataRoaming.errLine("unreadable");
            }
            if (info == null) return DataRoaming.errLine("nosub");
            seen = info.getDataRoaming() == SubscriptionManager.DATA_ROAMING_ENABLE ? 1 : 0;
            if (DataRoaming.readBackDone(isSet, value, seen, SystemClock.elapsedRealtime() - t0)) break;
            SystemClock.sleep(DataRoaming.READBACK_STEP_MS);
        }
        return DataRoaming.okLine(sub, seen == 1);
    }
}
