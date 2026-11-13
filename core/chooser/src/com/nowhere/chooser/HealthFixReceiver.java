package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261201-10: a health notice's Fix button. Runs IN THE ROAMED USER (the notice is in that user's shade, so its
 * PendingIntent fires there) and asks the daemon to run the rule's Fix, which restarts Play services. It only ever
 * sends HEALTH-FIX: a Fix never signs a profile out. Only the reply word is logged. The socket's connect cap (8 s) plus
 * the read cap stay under the 60 s background-broadcast limit (#77). Not exported; only our own PendingIntent reaches it.
 */
public class HealthFixReceiver extends BroadcastReceiver {
    private static final int READ_CAP_MS = 20000;

    @Override
    public void onReceive(Context ctx, Intent intent) {
        final PendingResult pr = goAsync();
        Thread worker = new Thread(() -> {
            try {
                String reply = DaemonSocket.roundTrip("HEALTH-FIX\nplay-push-frozen\n", READ_CAP_MS);
                android.util.Log.i("NowhereChooser", "health fix -> " + reply.split("\\s+", 2)[0]);
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "health fix", t);
            } finally {
                pr.finish();
            }
        }, "nowhere-health-fix");
        worker.setDaemon(true);
        worker.start();
    }
}
