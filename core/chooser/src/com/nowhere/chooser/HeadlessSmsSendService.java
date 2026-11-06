package com.nowhere.chooser;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/**
 * #135 B3: the ACTION_RESPOND_VIA_MESSAGE service Android requires the default SMS app to declare (the
 * "quick reply" from the incoming-call screen). The amnesiac gate does not send messages, so this is an
 * inert stub -- it exists only to satisfy the default-SMS-app component contract.
 */
public final class HeadlessSmsSendService extends Service {
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        stopSelf(startId);
        return START_NOT_STICKY;
    }
}
