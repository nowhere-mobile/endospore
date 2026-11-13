package com.nowhere.chooser;

import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.UserHandle;
import android.provider.Settings;
import android.util.Log;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.List;
import java.util.function.Predicate;

/** NWP-20261130-12: SettingsRoam's Android side: the list file, the live provider and the installed check. It logs
 *  counts only, because a tile list names installed apps. */
final class SettingsRoamLive {
    private SettingsRoamLive() {}

    private static final String TAG = "NowhereChooser";
    private static final Object RECONCILE_LOCK = new Object();

    private static List<String> readList() {
        try {
            return Files.readAllLines(new File(SettingsRoam.LIST_PATH).toPath(), StandardCharsets.UTF_8);
        } catch (Throwable t) {
            return null;
        }
    }

    private static SettingsRoam.Store store(ContentResolver cr) {
        return new SettingsRoam.Store() {
            @Override public String get(String scope, String key) {
                try {
                    return "system".equals(scope) ? Settings.System.getString(cr, key) : Settings.Secure.getString(cr, key);
                } catch (Throwable t) {
                    return null;
                }
            }

            @Override public boolean put(String scope, String key, String value) {
                try {
                    return "system".equals(scope) ? Settings.System.putString(cr, key, value)
                            : Settings.Secure.putString(cr, key, value);
                } catch (Throwable t) {
                    return false;
                }
            }
        };
    }

    /** An exception reads as not installed, the direction that keeps the tile stored. Flags 0 exclude an archived
     *  placeholder, so an on-demand app counts only once its code has landed. */
    private static Predicate<String> installed(PackageManager pm) {
        return pkg -> {
            try {
                pm.getPackageInfo(pkg, 0);
                return true;
            } catch (Throwable t) {
                return false;
            }
        };
    }

    /** The gate's sign-in: replay the session's rows into its user, on the login thread, before switch-in. */
    static void applyAtSignIn(Context gate, int uid, List<String> lines) {
        try {
            Context user = gate.createContextAsUser(UserHandle.of(uid), 0);
            SettingsRoam.Result r = SettingsRoam.apply(SettingsRoam.parseList(readList()), lines,
                    store(user.getContentResolver()), installed(user.getPackageManager()));
            Log.i(TAG, "settings roam: user " + uid + " rows=" + r.rows + " applied=" + r.applied + " failed=" + r.failed
                    + " malformed=" + r.malformed + " waiting=" + r.waiting + " marked=" + r.marked + " (Q012)");
        } catch (Throwable t) {
            Log.w(TAG, "settings roam: not applied for user " + uid + " (Q012): " + t.getClass().getName());
        }
    }

    /** The session's chooser: a package landed, or this process was born after a landing it could not hear. */
    static void reconcile(Context session) {
        if (UserHandle.myUserId() == 0) return;
        try {
            synchronized (RECONCILE_LOCK) {
                SettingsRoam.Store st = store(session.getContentResolver());
                String waiting = st.get("secure", SettingsRoam.TILES_KEY);
                if (waiting == null || waiting.isEmpty()) return;
                SettingsRoam.Row row = null;
                for (SettingsRoam.Row r : SettingsRoam.parseList(readList())) {
                    if (SettingsRoam.KIND_TILES.equals(r.kind)) { row = r; break; }
                }
                int landed = SettingsRoam.reconcile(row, st, installed(session.getPackageManager()));
                if (landed > 0) Log.i(TAG, "settings roam: " + landed + " waiting tile(s) landed (Q012)");
            }
        } catch (Throwable t) {
            Log.w(TAG, "settings roam: reconcile failed (Q012): " + t.getClass().getName());
        }
    }
}
