package com.nowhere.push;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/**
 * The UnifiedPush distributor front door (#157). Apps broadcast REGISTER / UNREGISTER here (they discover
 * us by querying receivers for org.unifiedpush.android.distributor.REGISTER). We hand the work to
 * {@link PushService}, which mints an endpoint at the gateway and holds the SSE stream. Kept thin -- a
 * BroadcastReceiver can't do network on its short-lived main thread.
 */
public class DistributorReceiver extends BroadcastReceiver {
    static final String TAG = "NowherePush";

    // Apps -> distributor
    static final String ACTION_REGISTER = "org.unifiedpush.android.distributor.REGISTER";
    static final String ACTION_UNREGISTER = "org.unifiedpush.android.distributor.UNREGISTER";
    static final String ACTION_MESSAGE_ACK = "org.unifiedpush.android.distributor.MESSAGE_ACK";
    // distributor -> apps
    static final String ACTION_NEW_ENDPOINT = "org.unifiedpush.android.connector.NEW_ENDPOINT";
    static final String ACTION_REGISTRATION_FAILED = "org.unifiedpush.android.connector.REGISTRATION_FAILED";
    static final String ACTION_UNREGISTERED = "org.unifiedpush.android.connector.UNREGISTERED";
    static final String ACTION_MESSAGE = "org.unifiedpush.android.connector.MESSAGE";
    // extras
    static final String EXTRA_TOKEN = "token";
    static final String EXTRA_ENDPOINT = "endpoint";
    static final String EXTRA_APPLICATION = "application";
    static final String EXTRA_PI = "pi";
    static final String EXTRA_BYTES_MESSAGE = "bytesMessage";
    static final String EXTRA_MESSAGE_ID = "id";
    static final String EXTRA_REASON = "message"; // registration-failed reason (legacy string extra)

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String action = intent.getAction();
        if (action == null) return;
        String token = intent.getStringExtra(EXTRA_TOKEN);
        switch (action) {
            case ACTION_REGISTER: {
                String app = appPackage(intent);
                if (app == null || token == null || token.isEmpty()) {
                    Log.w(TAG, "REGISTER missing app/token (app=" + app + ")");
                    return;
                }
                PushService.enqueueRegister(ctx, app, token);
                break;
            }
            case ACTION_UNREGISTER:
                if (token != null && !token.isEmpty()) PushService.enqueueUnregister(ctx, token);
                break;
            case ACTION_MESSAGE_ACK:
                // Our gateway delivers each push exactly once over SSE; there is no per-message redelivery
                // to cancel, so an ACK is a no-op (accepted for spec-compliance).
                break;
            default:
                break;
        }
    }

    /**
     * The registering app's package. Prefer the PendingIntent's creator package (a caller cannot forge
     * another app's package that way); fall back to the EXTRA_APPLICATION string for older connectors.
     */
    @SuppressWarnings("deprecation")
    static String appPackage(Intent intent) {
        try {
            PendingIntent pi = intent.getParcelableExtra(EXTRA_PI);
            if (pi != null) {
                String p = pi.getCreatorPackage();
                if (p != null && !p.isEmpty()) return p;
            }
        } catch (Throwable ignore) {
        }
        String app = intent.getStringExtra(EXTRA_APPLICATION);
        return (app != null && !app.isEmpty()) ? app : null;
    }
}
