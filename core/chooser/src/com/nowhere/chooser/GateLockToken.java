package com.nowhere.chooser;

import android.content.Context;

import java.io.File;

/**
 * NWP-20261118-04 (h48 #1): the token file, the "cleared" marker and the DevicePolicyManager calls that remove a
 * screen lock from user 0, the gate. GateLockClear holds the decision and the two texts.
 *
 * resetPasswordWithToken acts on the CALLING user (CredentialService's header). Run from the user-0 gate it changes
 * user 0's lock, which is the target here, so run() returns at once in any other user: never from a session.
 *
 * The token is 32 SecureRandom bytes, hex-encoded in user 0's own files dir, mode 600. It is a secret at rest that can
 * only change user 0's lock (the decision's stated cost; docs/threat-model.md section 2). It is never logged, never in
 * an Intent and never in argv: the log lines carry the action name, three booleans and exception class names only.
 */
final class GateLockToken {
    private GateLockToken() {}

    private static final String TAG = "NowhereChooser";

    /** The action of the last finished run, for the Owner settings line; null until a run finishes. */
    static volatile GateLockClear.Action last;

    static File tokenFile(Context ctx) {
        return new java.io.File(ctx.getFilesDir(), "gate-lock-token");
    }

    static File clearedMarker(Context ctx) {
        return new java.io.File(ctx.getFilesDir(), "gate-lock-cleared");
    }

    /** One run off the UI thread. */
    static void runAsync(Context ctx, String why) {
        final Context app = ctx.getApplicationContext();
        new Thread(() -> run(app, why), "nowhere-gate-lock").start();
    }

    /** One run = read the state, decide, act. Serialised: the gate start and a re-arm can overlap. */
    static synchronized void run(Context ctx, String why) {
        if (CredentialService.myUserId() != 0) return; // the gate's user only, never a session
        android.app.admin.DevicePolicyManager dpm;
        android.content.ComponentName admin;
        try {
            dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            if (dpm == null || !dpm.isDeviceOwnerApp(ctx.getPackageName())) return;
            admin = new android.content.ComponentName(ctx, AdminReceiver.class);
        } catch (Throwable t) {
            android.util.Log.w(TAG, "gate-lock " + why + ": no device policy (" + t.getClass().getSimpleName() + ")");
            return;
        }
        // The order (the kept token before the activation query) and the decision are GateLockClear.run's.
        GateLockClear.Action a = GateLockClear.run(new GateLockClear.Port() {
            @Override public boolean secure() {
                android.app.KeyguardManager km = ctx.getSystemService(android.app.KeyguardManager.class);
                if (km == null) throw new IllegalStateException("no KeyguardManager");
                return km.isDeviceSecure();
            }
            @Override public byte[] storedToken() { return readToken(ctx); }
            @Override public boolean active() { return dpm.isResetPasswordTokenActive(admin); }
            @Override public void setToken() { GateLockToken.setToken(ctx, dpm, admin, why); }
            @Override public boolean clear(byte[] token) {
                return dpm.resetPasswordWithToken(admin, null, token, 0); // null password: the lock is removed
            }
            @Override public void writeMarker() {
                try {
                    StoreInstaller.writeAtomic(clearedMarker(ctx), "1");
                } catch (Throwable t) {
                    android.util.Log.w(TAG, "gate-lock " + why + ": marker write failed (" + t.getClass().getSimpleName() + ")");
                }
            }
            @Override public void log(String line) { android.util.Log.i(TAG, "gate-lock " + why + ": " + line); }
        });
        if (a != null) last = a; // a failed read leaves last unchanged
    }

    /** A new token. The file is written only when the platform took it, so a refusal leaves the old file as it was. */
    private static void setToken(Context ctx, android.app.admin.DevicePolicyManager dpm,
                                 android.content.ComponentName admin, String why) {
        byte[] fresh = new byte[32];
        try {
            new java.security.SecureRandom().nextBytes(fresh);
            boolean set;
            try {
                set = dpm.setResetPasswordToken(admin, fresh);
            } catch (Throwable t) {
                android.util.Log.w(TAG, "gate-lock " + why + ": setResetPasswordToken threw (" + t.getClass().getSimpleName() + ")");
                return;
            }
            if (!set) {
                android.util.Log.w(TAG, "gate-lock " + why + ": setResetPasswordToken returned false");
                return;
            }
            try {
                StoreInstaller.writeAtomic(tokenFile(ctx), toHex(fresh));
                android.system.Os.chmod(tokenFile(ctx).getPath(), 0600); // the app umask gives 600 already; this states it
            } catch (Throwable t) {
                android.util.Log.w(TAG, "gate-lock " + why + ": file write failed (" + t.getClass().getSimpleName() + ")");
            }
        } finally {
            java.util.Arrays.fill(fresh, (byte) 0);
        }
    }

    /** The kept token, or null when the file is absent or not exactly 64 lowercase hex characters. */
    private static byte[] readToken(Context ctx) {
        try {
            File f = tokenFile(ctx);
            if (!f.isFile()) return null;
            String s = new String(java.nio.file.Files.readAllBytes(f.toPath()),
                    java.nio.charset.StandardCharsets.US_ASCII).trim();
            if (s.length() != 64) return null;
            byte[] out = new byte[32];
            for (int i = 0; i < 32; i++) {
                int hi = Character.digit(s.charAt(2 * i), 16), lo = Character.digit(s.charAt(2 * i + 1), 16);
                if (hi < 0 || lo < 0 || Character.isUpperCase(s.charAt(2 * i)) || Character.isUpperCase(s.charAt(2 * i + 1))) {
                    java.util.Arrays.fill(out, (byte) 0);
                    return null;
                }
                out[i] = (byte) ((hi << 4) | lo);
            }
            return out;
        } catch (Throwable t) {
            return null;
        }
    }

    private static String toHex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(Character.forDigit((x >> 4) & 0xf, 16)).append(Character.forDigit(x & 0xf, 16));
        return sb.toString();
    }

    /** Owner settings: adds the cleared notice (once) or the report line, if one holds. UI thread. */
    static void addNotice(android.app.Activity act, android.widget.LinearLayout ll, int color) {
        try {
            File marker = clearedMarker(act);
            String line = GateLockClear.noticeLine(marker.exists(), last);
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
            if (!GateLockClear.keepsMarker(line)) marker.delete();
        } catch (Throwable t) {
            android.util.Log.w(TAG, "gate-lock notice failed (" + t.getClass().getSimpleName() + ")");
        }
    }
}
