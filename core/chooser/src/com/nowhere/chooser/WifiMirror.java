package com.nowhere.chooser;

import android.content.Context;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;

/**
 * #98 -- capture the roamed session's saved Wi-Fi configs and hand them to the login daemon (WIFI-MIRROR)
 * so the user-0 gate can adopt them: Android saves networks PER-USER, so a network joined in-session is
 * otherwise invisible at the gate and the switch back drops connectivity.
 *
 * Static + self-contained because the capture must run from EVERY roamed-user exit path, not just the
 * Profile app: ProfileActivity (manual log-off / lock now), ReloginReceiver (#97 "Load my saved data" --
 * Chester's repro: this path never touches ProfileActivity, so build-262 captured nothing), and
 * IdleLogoffReceiver (L4 idle cold-lock). Runs as the session's PROFILE OWNER (priv, platform-signed ->
 * READ_WIFI_CREDENTIAL) via getPrivilegedConfiguredNetworks. Quoted (ASCII) PSKs + open networks only (a
 * raw 64-hex PSK can't ride the gate's quoted-config re-add). Synchronous but bounded (5s socket timeout)
 * -- callers already run on worker threads / goAsync receivers with their own watchdogs. Best-effort: any
 * failure just logs; the exit path must never stall on the mirror.
 */
final class WifiMirror {
    private static final String SOCKET = "nowhere_login";
    private static final int SO_TIMEOUT_MS = 5000;

    private WifiMirror() {}

    static void capture(Context ctx) {
        try {
            // #98 v3: self-grant the location-family runtime perms first (the DO in user 0 / the PO in a
            // session may do this for its own package -- DIA-45 precedent). Without a fine-location grant
            // the privileged Wi-Fi reads SOFT-FAIL TO EMPTY rather than throwing, which is exactly the
            // silent "nothing to capture" Chester's build-264 repro showed. Idempotent, best-effort.
            try {
                android.app.admin.DevicePolicyManager dpm = (android.app.admin.DevicePolicyManager)
                        ctx.getSystemService(Context.DEVICE_POLICY_SERVICE);
                android.content.ComponentName admin =
                        new android.content.ComponentName(ctx, AdminReceiver.class);
                for (String p : new String[] {android.Manifest.permission.ACCESS_FINE_LOCATION,
                        "android.permission.NEARBY_WIFI_DEVICES"}) {
                    dpm.setPermissionGrantState(admin, ctx.getPackageName(), p,
                            android.app.admin.DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED);
                }
            } catch (Throwable ignore) {}
            android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager)
                    ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm == null) return;
            java.util.List<android.net.wifi.WifiConfiguration> cfgs = wm.getPrivilegedConfiguredNetworks();
            int cur = -1;
            try { android.net.wifi.WifiInfo wi = wm.getConnectionInfo(); if (wi != null) cur = wi.getNetworkId(); } catch (Throwable ignore) {}
            java.util.List<String> lines = new java.util.ArrayList<>();
            int currentAt = -1, skipped = 0;
            for (android.net.wifi.WifiConfiguration c : cfgs) {
                if (c == null || c.SSID == null) continue;
                String line = WifiMirrorLine.encode(c.SSID, c.preSharedKey, c.macRandomizationSetting);
                if (line == null) { skipped++; continue; }
                // WifiMirrorLine.encode appends the third field. #118/#467: carry the per-network MAC-randomization mode as a THIRD field. WITHOUT IT the gate
                // re-adds every network at the platform default, which on GrapheneOS is RANDOMIZATION_ALWAYS
                // (100) -- a NEW MAC on every single connection. A MAC-allowlist AP (a typical office) then
                // rejects the gate, so Wi-Fi silently dies after each login / cold-lock, and the owner's
                // "use device MAC" choice is discarded every time.
                //
                // #467 added exactly this to the DAEMON capture (wifi_store.go) and stopped there. But that path
                // reads the PER-USER CE store, which is EMPTY on this Android -- saved networks live device-wide
                // in /data/misc/apexdata/com.android.wifi -- so it parses zero entries and returns without
                // logging. Measured on lynx: 616 "queued for the gate" (this path) vs 0 "captured from user
                // store" (that one). The fix landed on the path that never runs, so all four saved networks,
                // the work AP included, sat at 100. ALWAYS check WHICH of two capture paths is the live one.
                // (NWP-20260903-30: this comment named a REAL employer SSID until 2026-09-03. Public mirrors
                //  ship the full buildable OS every release, so a debugging detail became published personal
                //  data about a real person. Use a placeholder in comments, always.)
                if (cur != -1 && c.networkId == cur) currentAt = lines.size();
                lines.add(line);
            }
            // NWP-20261120-14: the connected network goes first, within the cap (WifiMirrorPick.MAX).
            java.util.List<String> sent = WifiMirrorPick.order(lines, currentAt);
            int n = sent.size();
            if (n == 0) {
                // Say WHY: an empty framework list (permission/visibility soft-fail) reads very differently
                // from "everything got filtered".
                android.util.Log.i("NowhereChooser", "wifi-mirror: nothing to capture (framework list="
                        + cfgs.size() + ", filtered=" + skipped + ", user=" + android.os.UserHandle.myUserId() + ")");
                return;
            }
            StringBuilder sb = new StringBuilder();
            for (String l : sent) sb.append(l).append('\n');
            String reply = send("WIFI-MIRROR\n" + n + "\n" + sb);
            android.util.Log.i("NowhereChooser", "wifi-mirror: sent " + n + " network(s) (of " + cfgs.size()
                    + " visible, " + (lines.size() - n) + " dropped by the cap, current="
                    + (currentAt != -1 ? "yes" : "no") + "), reply=" + reply);
        } catch (Throwable t) {
            android.util.Log.w("NowhereChooser", "wifi-mirror capture", t);
        }
    }

    private static String send(String payload) throws Exception {
        LocalSocket s = DaemonSocket.connect(); // NWP-20261005-25: bounded connect
        try {
            if (s == null) throw new java.io.IOException("daemon connect timed out");
            s.setSoTimeout(SO_TIMEOUT_MS);
            OutputStream os = s.getOutputStream();
            os.write(payload.getBytes("UTF-8"));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(s.getInputStream(), "UTF-8"));
            return br.readLine();
        } finally {
            if (s != null) try { s.close(); } catch (Throwable ignore) {}
        }
    }
}
