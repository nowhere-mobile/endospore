package com.nowhere.chooser;

/**
 * NWP-20261204-12: what a GATE issue report carries for the backlog row "After a sign-out the gate can show a missed
 * call from inside the session, and a location icon". Chester, 2026-10-12, on frankel: "on frankel, after logging off,
 * lock screen shows missed call and location service icon. thought it would have cleared?" The row names three causes,
 * and one report filed at the gate after a sign-out now tells them apart:
 *
 *  (A) the gate's own notices, kept until cleared by design: gate_tel_notices (tag SmsDeliverReceiver.TEL_CHANNEL, the
 *      per-line hints), gate_loss_notices (tag TEL_LOSS_TAG) and gate_other_notices (any other tag, or none);
 *  (B) Telecom's own missed-call notice in user 0. Telecom hands the miss to user 0's DEFAULT dialer only, and only
 *      when that dialer resolves ACTION_SHOW_MISSED_CALLS_NOTIFICATION; so dialer_role (a lost role is cause B whatever
 *      the receiver says), missed_call_receiver (the query Telecom makes) and missed_call_broadcasts (did Telecom
 *      delegate at all);
 *  (C) the location icon: location_grant (the chooser's own fine-location grant state by device policy, which scanWifi
 *      sets) and location_on (user 0's location switch, which scanWifi turns on until stopScanLocation runs).
 *
 * Gate scope. The gate preview renders the report on screen to whoever holds the phone (core/agent/report_issue.go,
 * the deviceScope comment), and the gate is blind-login: nothing here may say which profiles exist or what a session
 * did. So every value is a device fact or a count a stranger at the gate may see. The notice counts are of the gate's
 * own banner, which anyone at the gate sees, and a notice is read by its tag only, never its title, text or payload.
 * missed_call_broadcasts is bucketed 0/1/2+: it says whether Telecom delegated, never how many calls a session missed.
 * It counts the broadcasts this chooser process received since it started (MissedCallReceiver.RECEIVED), so a process
 * restart between the miss and the report resets it to 0. Nothing names a profile, a line, a number or an app.
 *
 * This class reads only: it posts, clears and grants nothing. Every value is a String, because the daemon decodes the
 * report's status as map[string]string. Every key has its own try, and a failed read writes "unreadable": a key is
 * never omitted, so a missing key means an older chooser, not a failed read.
 */
final class GateNoticeEvidence {
    private GateNoticeEvidence() {}

    /** {tel, loss, other} over the gate's own notice tags; a null tag counts as other. */
    static int[] countTags(String[] tags, String telTag, String lossTag) {
        int[] c = new int[3];
        if (tags == null) return c;
        for (String t : tags) {
            if (telTag.equals(t)) c[0]++;
            else if (lossTag.equals(t)) c[1]++;
            else c[2]++;
        }
        return c;
    }

    /** DevicePolicyManager.PERMISSION_GRANT_STATE_DEFAULT = 0, _GRANTED = 1, _DENIED = 2, by value: the suite that
     *  runs this has no android.jar. */
    static String grantName(int state) {
        switch (state) {
            case 0: return "default";
            case 1: return "policy_granted";
            case 2: return "policy_denied";
            default: return "unknown";
        }
    }

    /** The receivers Telecom's query finds; n < 0 when the query failed. */
    static String receiverState(int n) {
        if (n < 0) return "unreadable";
        if (n == 0) return "absent";
        return "resolves";
    }

    static String roleName(boolean available, boolean held) {
        if (!available) return "unavailable";
        return held ? "held" : "not_held";
    }

    /** 0, 1 or 2+: whether Telecom delegated, never how many calls a session missed. */
    static String bucket(int n) {
        if (n <= 0) return "0";
        if (n == 1) return "1";
        return "2+";
    }

    private static void putQuiet(org.json.JSONObject st, String k, String v) {
        try { st.put(k, v); } catch (Throwable ignore) {}
    }

    static void put(android.content.Context ctx, org.json.JSONObject st) {
        // One read of the chooser's own active notices in user 0, by tag only; null when it fails.
        String[] tags;
        try {
            android.app.NotificationManager nm = ctx.getSystemService(android.app.NotificationManager.class);
            android.service.notification.StatusBarNotification[] act = nm.getActiveNotifications();
            tags = new String[act.length];
            for (int i = 0; i < act.length; i++) tags[i] = act[i].getTag();
        } catch (Throwable t) { tags = null; }
        final int[] c = tags == null ? null
                : countTags(tags, SmsDeliverReceiver.TEL_CHANNEL, SmsDeliverReceiver.TEL_LOSS_TAG);
        try {
            st.put("gate_tel_notices", c == null ? "unreadable" : String.valueOf(c[0]));
        } catch (Throwable t) { putQuiet(st, "gate_tel_notices", "unreadable"); }
        try {
            st.put("gate_loss_notices", c == null ? "unreadable" : String.valueOf(c[1]));
        } catch (Throwable t) { putQuiet(st, "gate_loss_notices", "unreadable"); }
        try {
            st.put("gate_other_notices", c == null ? "unreadable" : String.valueOf(c[2]));
        } catch (Throwable t) { putQuiet(st, "gate_other_notices", "unreadable"); }
        try {
            st.put("missed_call_receiver", receiverState(ctx.getPackageManager().queryBroadcastReceivers(
                    new android.content.Intent(MissedCallReceiver.ACTION).setPackage(ctx.getPackageName()), 0).size()));
        } catch (Throwable t) { putQuiet(st, "missed_call_receiver", "unreadable"); }
        try {
            st.put("missed_call_broadcasts", bucket(MissedCallReceiver.RECEIVED.get()));
        } catch (Throwable t) { putQuiet(st, "missed_call_broadcasts", "unreadable"); }
        try {
            android.app.role.RoleManager rm = ctx.getSystemService(android.app.role.RoleManager.class);
            st.put("dialer_role", rm == null ? "unreadable"
                    : roleName(rm.isRoleAvailable(android.app.role.RoleManager.ROLE_DIALER),
                            rm.isRoleHeld(android.app.role.RoleManager.ROLE_DIALER)));
        } catch (Throwable t) { putQuiet(st, "dialer_role", "unreadable"); }
        try {
            android.app.admin.DevicePolicyManager dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager.class);
            st.put("location_grant", grantName(dpm.getPermissionGrantState(
                    new android.content.ComponentName(ctx, AdminReceiver.class), ctx.getPackageName(),
                    android.Manifest.permission.ACCESS_FINE_LOCATION)));
        } catch (Throwable t) { putQuiet(st, "location_grant", "unreadable"); }
        try {
            android.location.LocationManager lm = ctx.getSystemService(android.location.LocationManager.class);
            st.put("location_on", lm.isLocationEnabled() ? "on" : "off");
        } catch (Throwable t) { putQuiet(st, "location_on", "unreadable"); }
    }
}
