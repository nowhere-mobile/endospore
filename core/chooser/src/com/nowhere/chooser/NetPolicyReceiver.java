package com.nowhere.chooser;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.net.NetworkPolicy;
import android.net.NetworkPolicyManager;
import android.net.NetworkTemplate;
import android.os.UserHandle;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Removes netpolicy's Wi-Fi-template policies and keeps every other one (NWP-20261210-17), as decided 2026-11-14,
 * "DECIDED: five answers to harvest 65 -- every recommendation accepted", item G06. roamd, as root, reaches this by
 * explicit component: roamd's calls to it at every boot and at the reap when no other session is live (decided
 * 2026-11-18, (3)). This receiver does not know or check which trigger called it. The rules and the reply are
 * NetPolicyWifi's; the contract is in its header.
 *
 * The mobile and carrier templates stay, so the owner's data limits and warnings stay. Per-uid background policy is
 * separate state and this receiver never changes it. It goes through NetworkPolicyManager only, never a file.
 * NEVER log or reply a template, a network key, an SSID or a subscriber id: the one log line is the reply line.
 *
 * This file uses hidden platform API (platform_apis, platform certificate): the build host's `m NowhereChooser`
 * compiles it, not test-netpolicy-wifi-java.sh, which pins it as data.
 */
public class NetPolicyReceiver extends BroadcastReceiver {
    private static final String TAG = "NowhereChooser";
    private static final ExecutorService WORK = Executors.newSingleThreadExecutor();

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null || !NetPolicyWifi.ACTION_RESET.equals(intent.getAction())) return;
        if (UserHandle.myUserId() != 0) {
            setResultData(NetPolicyWifi.errLine(NetPolicyWifi.R_USER));
            return;
        }
        final PendingResult pr = goAsync();
        final Context app = context.getApplicationContext() != null ? context.getApplicationContext() : context;
        WORK.execute(() -> {
            String line = NetPolicyWifi.errLine(NetPolicyWifi.R_FAILED);
            try {
                line = reset(app);
            } catch (SecurityException e) {
                line = NetPolicyWifi.errLine(NetPolicyWifi.R_DENIED);
            } catch (Throwable e) {
                line = NetPolicyWifi.errLine(NetPolicyWifi.R_FAILED);
            } finally {
                Log.i(TAG, "netpolicy wifi reset: " + line);
                pr.setResultData(line);
                pr.finish();
            }
        });
    }

    private static String reset(Context ctx) throws ReflectiveOperationException {
        NetworkPolicyManager npm = NetworkPolicyManager.from(ctx);
        if (npm == null) return NetPolicyWifi.errLine(NetPolicyWifi.R_NOSERVICE);
        // The read returns an EMPTY array, not an error, when the caller fails its phone-state check. The chooser holds
        // READ_PRIVILEGED_PHONE_STATE (manifest), and the removed > 0 guard below is what keeps the owner's mobile
        // limits if the read ever comes back empty: an empty read writes nothing.
        NetworkPolicy[] all = npm.getNetworkPolicies();
        if (all == null) all = new NetworkPolicy[0];
        int[] rules = new int[all.length];
        for (int i = 0; i < all.length; i++) {
            rules[i] = all[i] == null || all[i].template == null ? Integer.MIN_VALUE : all[i].template.getMatchRule();
        }
        boolean[] keep = NetPolicyWifi.keep(rules, wifiRules());
        int removed = NetPolicyWifi.removed(keep);
        List<NetworkPolicy> kept = new ArrayList<>();
        for (int i = 0; i < all.length; i++) {
            if (keep[i] && all[i] != null) kept.add(all[i]);
        }
        if (removed > 0) npm.setNetworkPolicies(kept.toArray(new NetworkPolicy[0]));
        return NetPolicyWifi.reply(removed);
    }

    /** MATCH_WIFI, plus MATCH_WIFI_WILDCARD when this tree's NetworkTemplate has it (absent: skipped, not an error). */
    private static int[] wifiRules() throws ReflectiveOperationException {
        try {
            int wildcard = NetworkTemplate.class.getField("MATCH_WIFI_WILDCARD").getInt(null);
            return new int[] {NetworkTemplate.MATCH_WIFI, wildcard};
        } catch (NoSuchFieldException absent) {
            return new int[] {NetworkTemplate.MATCH_WIFI};
        }
    }
}
