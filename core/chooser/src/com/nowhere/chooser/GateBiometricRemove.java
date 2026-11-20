package com.nowhere.chooser;

import android.content.Context;

import java.io.File;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/**
 * NWP-20261208-20 (h45 #1, docs/product-decisions.md 2026-10-25): the FingerprintManager / FaceManager calls and the
 * "removed" marker that remove a fingerprint or face enrolled in user 0, the gate. GateBiometricClear holds the run
 * order, the verdict and the two texts.
 *
 * The calls it uses, all hidden framework methods reached by reflection, so that a method missing on either edition
 * becomes REPORT (or a count of 0 for an absent manager), never a crash or a compile break:
 *   count:  FingerprintManager.getEnrolledFingerprints(int), FaceManager.getEnrolledFaces(int), with userId 0;
 *   remove: FingerprintManager.removeAll(int, FingerprintManager.RemovalCallback) and
 *           FaceManager.removeAll(int, FaceManager.RemovalCallback), else remove(Fingerprint|Face, int, callback)
 *           per template.
 * The callback is an empty RemovalCallback: the verdict is the recount, never the callback. The removal is
 * asynchronous in the HAL, so removeAll() polls the count every 500 ms for up to 10 s before GateBiometricClear counts
 * again. The chooser holds MANAGE_FINGERPRINT, MANAGE_BIOMETRIC and USE_BIOMETRIC_INTERNAL by its platform signature
 * (AndroidManifest.xml).
 *
 * The calls act on user 0, so run() returns at once in any other user: never from a session. The log lines carry the
 * Port's line (digits and an action name) and exception class names only, never a template, its name or its id: a
 * template name is user text and can name a person.
 */
final class GateBiometricRemove {
    private GateBiometricRemove() {}

    private static final String TAG = "NowhereChooser";

    /** The action of the last finished run, for the Owner settings line; null until a run finishes. */
    static volatile GateBiometricClear.Action last;

    static File removedMarker(Context ctx) {
        return new java.io.File(ctx.getFilesDir(), "gate-biometric-removed");
    }

    /** One run off the UI thread. */
    static void runAsync(Context ctx, String why) {
        final Context app = ctx.getApplicationContext();
        new Thread(() -> run(app, why), "nowhere-gate-biometric").start();
    }

    /** One run = count, remove, count again. Serialised: two gate starts can overlap. */
    static synchronized void run(Context ctx, String why) {
        if (CredentialService.myUserId() != 0) return; // the gate's user only, never a session
        try {
            android.app.admin.DevicePolicyManager dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            if (dpm == null || !dpm.isDeviceOwnerApp(ctx.getPackageName())) return;
        } catch (Throwable t) {
            android.util.Log.w(TAG, "gate-biometric " + why + ": no device policy (" + t.getClass().getSimpleName() + ")");
            return;
        }
        // The order and the verdict are GateBiometricClear.run's.
        GateBiometricClear.Action a = GateBiometricClear.run(new GateBiometricClear.Port() {
            @Override public int enrolled() throws Exception {
                try {
                    return count(ctx, true) + count(ctx, false);
                } catch (Throwable t) {
                    throw asException(t, why);
                }
            }
            @Override public boolean canRemove() {
                try {
                    return removable(ctx, true) && removable(ctx, false);
                } catch (Throwable t) {
                    return false;
                }
            }
            @Override public void removeAll() throws Exception {
                Throwable first = null;
                try {
                    removeUser0(ctx, true);
                } catch (Throwable t) {
                    first = t;
                }
                try {
                    removeUser0(ctx, false);
                } catch (Throwable t) {
                    if (first == null) first = t;
                }
                for (int i = 0; i < 20; i++) { // 20 x 500 ms = 10 s: the HAL removes asynchronously
                    try {
                        if (count(ctx, true) + count(ctx, false) == 0) break;
                    } catch (Throwable t) {
                        break; // GateBiometricClear's recount reports it
                    }
                    Thread.sleep(500);
                }
                if (first != null) throw asException(first, why);
            }
            @Override public void writeMarker() {
                try {
                    StoreInstaller.writeAtomic(removedMarker(ctx), "1");
                } catch (Throwable t) {
                    android.util.Log.w(TAG, "gate-biometric " + why + ": marker write failed (" + t.getClass().getSimpleName() + ")");
                }
            }
            @Override public void log(String line) { android.util.Log.i(TAG, "gate-biometric " + why + ": " + line); }
        });
        if (a != null) last = a; // a failed first count leaves last unchanged
    }

    /** The manager's class: FingerprintManager, or FaceManager when the framework has it; null when absent. */
    private static Class<?> managerClass(boolean fingerprint) {
        if (fingerprint) return android.hardware.fingerprint.FingerprintManager.class;
        try {
            return Class.forName("android.hardware.face.FaceManager");
        } catch (ClassNotFoundException e) {
            return null;
        }
    }

    /** The manager, or null when the phone has no such hardware (or the framework no such class). */
    private static Object manager(Context ctx, boolean fingerprint) {
        Class<?> cls = managerClass(fingerprint);
        return cls == null ? null : ctx.getSystemService(cls);
    }

    /** User 0's templates in one manager; empty when the manager is absent. A failed call throws. */
    private static java.util.List<?> templates(Context ctx, boolean fingerprint) throws Exception {
        Object mgr = manager(ctx, fingerprint);
        if (mgr == null) return java.util.Collections.emptyList();
        Method m = managerClass(fingerprint).getMethod(fingerprint ? "getEnrolledFingerprints" : "getEnrolledFaces", int.class);
        Object r = m.invoke(mgr, 0);
        return r == null ? java.util.Collections.emptyList() : (java.util.List<?>) r;
    }

    private static int count(Context ctx, boolean fingerprint) throws Exception {
        return templates(ctx, fingerprint).size();
    }

    private static Class<?> callbackClass(boolean fingerprint) throws ClassNotFoundException {
        return Class.forName(fingerprint ? "android.hardware.fingerprint.FingerprintManager$RemovalCallback"
                : "android.hardware.face.FaceManager$RemovalCallback");
    }

    private static Class<?> templateClass(boolean fingerprint) throws ClassNotFoundException {
        return Class.forName(fingerprint ? "android.hardware.fingerprint.Fingerprint" : "android.hardware.face.Face");
    }

    /** removeAll(int, RemovalCallback), or null when this framework has none. */
    private static Method removeAllMethod(boolean fingerprint) {
        try {
            return managerClass(fingerprint).getMethod("removeAll", int.class, callbackClass(fingerprint));
        } catch (Throwable t) {
            return null;
        }
    }

    /** remove(Fingerprint|Face, int, RemovalCallback), or null when this framework has none. */
    private static Method removeOneMethod(boolean fingerprint) {
        try {
            return managerClass(fingerprint).getMethod("remove", templateClass(fingerprint), int.class, callbackClass(fingerprint));
        } catch (Throwable t) {
            return null;
        }
    }

    /** True when the manager holds no template, or has a removal call for them. */
    private static boolean removable(Context ctx, boolean fingerprint) throws Exception {
        if (count(ctx, fingerprint) == 0) return true;
        return removeAllMethod(fingerprint) != null || removeOneMethod(fingerprint) != null;
    }

    /** An empty callback: the verdict is the recount. Created only once the manager exists, so an absent class never loads. */
    private static Object callback(boolean fingerprint) {
        if (fingerprint) return new android.hardware.fingerprint.FingerprintManager.RemovalCallback() {};
        return new android.hardware.face.FaceManager.RemovalCallback() {};
    }

    /** Removes user 0's templates in one manager: removeAll when it resolves, else remove per template. */
    private static void removeUser0(Context ctx, boolean fingerprint) throws Exception {
        java.util.List<?> held = templates(ctx, fingerprint);
        if (held.isEmpty()) return;
        Object mgr = manager(ctx, fingerprint);
        Object cb = callback(fingerprint);
        Method all = removeAllMethod(fingerprint);
        if (all != null) {
            all.invoke(mgr, 0, cb);
            return;
        }
        Method one = removeOneMethod(fingerprint);
        if (one == null) throw new NoSuchMethodException("no removal call");
        for (Object t : held) one.invoke(mgr, t, 0, cb);
    }

    /** The cause of a reflected call's throw, as an Exception. An Error's class is logged here, as it is lost after. */
    private static Exception asException(Throwable t, String why) {
        Throwable c = t instanceof InvocationTargetException && t.getCause() != null ? t.getCause() : t;
        if (c instanceof Exception) return (Exception) c;
        android.util.Log.w(TAG, "gate-biometric " + why + ": " + c.getClass().getSimpleName());
        return new IllegalStateException(c);
    }

    /** Owner settings: adds the removed notice (once) or the report line, if one holds. UI thread. */
    static void addNotice(android.app.Activity act, android.widget.LinearLayout ll, int color) {
        try {
            File marker = removedMarker(act);
            String line = GateBiometricClear.noticeLine(marker.exists(), last);
            if (line == null) return;
            android.widget.TextView tv = new android.widget.TextView(act);
            tv.setText(line);
            tv.setTextColor(color);
            tv.setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 13);
            tv.setGravity(android.view.Gravity.CENTER);
            android.widget.LinearLayout.LayoutParams lp = new android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.MATCH_PARENT, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.topMargin = Math.round(12 * act.getResources().getDisplayMetrics().density);
            ll.addView(tv, lp);
            //noinspection ResultOfMethodCallIgnored
            if (!GateBiometricClear.keepsMarker(line)) marker.delete();
        } catch (Throwable t) {
            android.util.Log.w(TAG, "gate-biometric notice failed (" + t.getClass().getSimpleName() + ")");
        }
    }
}
