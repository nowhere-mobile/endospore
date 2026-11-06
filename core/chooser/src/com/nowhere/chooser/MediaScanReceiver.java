package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Environment;
import android.media.MediaScannerConnection;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;

/**
 * NWP-20260908-21: make another handset's media VISIBLE in this session.
 *
 * The seal's carry keeps another handset's new media in the account head, and NWP-20260908-21 fetches the bytes
 * down mid-session. Neither makes the file appear: MediaStore does not notice a write it did not mediate, and
 * nothing in this tree has ever triggered a media scan. What makes a LOGIN work is implicit and not ours -- the
 * roamed user starts, emulated;&lt;uid&gt; mounts, and that user's own MediaProvider attaches and scans. There is no
 * mid-session equivalent (NWP-20260908-18, measured on lynx: a file written straight to the lower fs AND a file
 * written through the FUSE mount both stayed unindexed indefinitely; one scan_file call indexed either).
 *
 * ⚠ WHY THIS LIVES IN THE CHOOSER RATHER THAN IN roamd. The scan has to be issued AS THE ROAMED USER. roamd is
 * endospore_priv and our sepolicy grants it nothing towards MediaProvider -- a grep for "mediaprovider" across
 * the whole policy returns nothing -- so that route needs new allows. This app is ALREADY installed and running
 * in the roamed user, where the call is same-user and rides the stock app_domain binder rules. roamd only has
 * to nudge it, which it can already do: `am broadcast --user` is used in production for CHECKIN.
 *
 * The paths arrive in a FILE the daemon drops in our own files dir, not in the intent: a space in a filename
 * cannot become a parsing bug, and a big sync cycle cannot overrun the broadcast size limit.
 *
 * Not exported. Only the daemon (root, cross-user) reaches it.
 */
public class MediaScanReceiver extends BroadcastReceiver {

    /** Written by nowhere_roamd.sh after a #media push that materialized anything. One absolute path per line. */
    static final String LIST = "nowhere-mediascan.list";

    @Override
    public void onReceive(Context ctx, Intent intent) {
        final PendingResult pending = goAsync();
        final Context app = ctx.getApplicationContext();
        new Thread(new Runnable() {
            @Override public void run() {
                try {
                    scan(app);
                } catch (Throwable t) {
                    android.util.Log.w("NowhereChooser", "media-scan", t);
                } finally {
                    pending.finish();
                }
            }
        }, "nowhere-media-scan").start();
    }

    private static void scan(Context ctx) {
        File list = new File(ctx.getFilesDir(), LIST);
        List<File> files = readList(ctx, list);
        // Consume it either way: a list we could not act on must not be retried forever, and roamd rewrites it
        // on the next cycle that lands anything.
        list.delete();
        if (files.isEmpty()) {
            return;
        }
        String[] paths = new String[files.size()];
        for (int i = 0; i < paths.length; i++) {
            paths[i] = files.get(i).getAbsolutePath();
        }
        final int want = paths.length;
        final int[] done = new int[]{0, 0}; // {callbacks seen, rows actually created}
        // ⚠ MediaScannerConnection, NOT MediaStore.scanFile. Both end in the same MediaProvider scan -- and
        // scan_file is literally the call proven on the device -- but MediaStore.scanFile is @SystemApi, so
        // whether MediaProvider ACCEPTS it from an app uid is a question no compile can answer. This one is
        // the public, app-facing API with no such question. It is asynchronous, hence the counting below.
        MediaScannerConnection.scanFile(ctx, paths, null,
                new MediaScannerConnection.OnScanCompletedListener() {
                    @Override public void onScanCompleted(String path, android.net.Uri uri) {
                        synchronized (done) {
                            done[0]++;
                            if (uri != null) {
                                done[1]++;
                            }
                            if (done[0] == want) {
                                // How many of how many, and how many produced a ROW. A scan that runs and
                                // indexes nothing is indistinguishable from one that never ran -- the failure
                                // this area keeps repeating -- so a null Uri is counted separately.
                                android.util.Log.i("NowhereChooser", "media-scan: " + done[1] + " of " + want
                                        + " newly synced file(s) indexed");
                            }
                        }
                    }
                });
    }

    /**
     * Reads the list, keeping only paths that exist and live under this user's own external storage.
     *
     * The bound is not defensive dressing: this receiver runs with the chooser's privileges, and a path outside
     * the media tree is either a bug in the daemon or something that should never have reached us. Dropping it
     * silently is wrong too, so each rejection is logged.
     */
    private static List<File> readList(Context ctx, File list) {
        List<File> out = new ArrayList<>();
        File root = Environment.getExternalStorageDirectory();
        String prefix = root != null ? root.getAbsolutePath() + File.separator : null;
        if (prefix == null) {
            android.util.Log.w("NowhereChooser", "media-scan: no external storage root; nothing scanned");
            return out;
        }
        BufferedReader r = null;
        try {
            r = new BufferedReader(new FileReader(list));
            String line;
            while ((line = r.readLine()) != null) {
                // NWP-20261016-43: the line is used EXACTLY as readLine returns it. The writer
                // (writeMediaSyncList) joins with "\n" and never pads, and readLine has already ended the line
                // at "\n", "\r" or "\r\n" and dropped the terminator -- so trimming can only damage a real
                // name: a file whose name starts or ends in a space or tab was looked up under the trimmed name,
                // failed isFile() and stayed out of MediaStore for the session.
                if (line.isEmpty()) {
                    continue;
                }
                File f = new File(line);
                String canon;
                try {
                    canon = f.getCanonicalPath();
                } catch (Throwable t) {
                    canon = f.getAbsolutePath();
                }
                if (!canon.startsWith(prefix)) {
                    android.util.Log.w("NowhereChooser", "media-scan: refusing a path outside " + prefix);
                    continue;
                }
                if (!f.isFile()) {
                    continue; // gone again already: the session is live, and that is not an error
                }
                out.add(f);
            }
        } catch (java.io.FileNotFoundException e) {
            // No list: the daemon nudged us for a cycle that landed nothing, or another instance got here first.
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "media-scan: read list", t);
        } finally {
            if (r != null) {
                try { r.close(); } catch (Throwable ignore) {}
            }
        }
        return out;
    }
}
