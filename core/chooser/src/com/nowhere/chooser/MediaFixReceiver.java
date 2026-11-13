package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * NWP-20261202-26: the media-health notice's Fix button, and the notice itself. Runs IN THE ROAMED USER (the notice is
 * in that user's shade, so its PendingIntent fires there) and asks the daemon to restart the session's media service.
 * It only ever sends MEDIA-RESTART; the daemon accepts it only from the live session's own user and waits for a running
 * save itself. Only the reply's first word is logged. When the reply is not QUEUED (DENIED, ERR-NOSESSION, or a daemon
 * that does not know the verb) it logs "media health: fix refused" and re-posts the notice WITHOUT a Fix; it cancels
 * nothing. The socket's connect cap (8 s) plus the read cap stay under the 60 s background-broadcast limit (#77).
 * Not exported; only our own PendingIntent reaches it.
 */
public class MediaFixReceiver extends BroadcastReceiver {
    private static final int READ_CAP_MS = 20000;
    static final int NOTIF_ID = 0x0D27; // ChooserActivity.NOTIF_HEALTH_ID holds 0x0D26
    // The health channel of NWP-20261201-10 (ChooserActivity.NOTIF_HEALTH_CHANNEL). Its name and description must
    // stay equal to postHealthNotice's: a second createNotificationChannel with other text renames the channel.
    static final String CHANNEL = "nowhere.health";

    @Override
    public void onReceive(final Context ctx, Intent intent) {
        final PendingResult pr = goAsync();
        Thread worker = new Thread(() -> {
            try {
                String reply = DaemonSocket.roundTrip("MEDIA-RESTART\n", READ_CAP_MS);
                android.util.Log.i("NowhereChooser", "media fix -> " + (reply == null ? "" : reply.split("\\s+", 2)[0]));
                if (!MediaHealth.fixAccepted(reply)) {
                    android.util.Log.i("NowhereChooser", "media health: fix refused");
                    post(ctx, false);
                }
            } catch (Throwable t) {
                android.util.Log.w("NowhereChooser", "media fix", t);
            } finally {
                pr.finish();
            }
        }, "nowhere-media-fix");
        worker.setDaemon(true);
        worker.start();
    }

    /** Post the media-health notice in the shade of {@code uc}'s user (the roamed user). Dismissible. With
     *  {@code withFix}, one Fix action: a broadcast to this receiver from {@code uc}, so it fires in that user. */
    static void post(Context uc, boolean withFix) {
        try {
            android.app.NotificationManager nm = uc.getSystemService(android.app.NotificationManager.class);
            if (nm == null) return;
            android.app.NotificationChannel ch = new android.app.NotificationChannel(
                    CHANNEL, "Phone health", android.app.NotificationManager.IMPORTANCE_DEFAULT);
            ch.setDescription("Tells you about a known fault on this phone and offers a fix");
            nm.createNotificationChannel(ch);
            String body = withFix ? MediaHealth.BODY : MediaHealth.BODY_NO_FIX;
            android.app.Notification.Builder b = new android.app.Notification.Builder(uc, CHANNEL)
                    .setSmallIcon(R.drawable.ic_backup_warn)
                    .setContentTitle(MediaHealth.TITLE)
                    .setContentText(body)
                    .setStyle(new android.app.Notification.BigTextStyle().bigText(body))
                    .setOnlyAlertOnce(true)
                    .setShowWhen(false);
            if (withFix) {
                android.app.PendingIntent fix = android.app.PendingIntent.getBroadcast(uc, 0,
                        new Intent(uc, MediaFixReceiver.class),
                        android.app.PendingIntent.FLAG_UPDATE_CURRENT | android.app.PendingIntent.FLAG_IMMUTABLE);
                b.addAction(new android.app.Notification.Action.Builder(
                        (android.graphics.drawable.Icon) null, MediaHealth.FIX, fix).build());
            }
            nm.notify(NOTIF_ID, b.build());
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "media health post", t);
        }
    }
}
