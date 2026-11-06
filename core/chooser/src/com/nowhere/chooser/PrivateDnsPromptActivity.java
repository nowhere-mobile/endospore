package com.nowhere.chooser;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

/**
 * NWP-20261127-07 (h50 #4 A1, docs/product-decisions.md 2026-11-01): the blocked-encrypted-DNS dialog in a signed-in
 * session. It runs in the roamed user, opened by the notification PrivateDnsWatch posts there (an immutable
 * PendingIntent carrying the prompt's token). It shows the same dialog as the gate: the decided title, body and two
 * buttons, not cancelable.
 *
 * It decides nothing. A button sends the token and the choice to PrivateDnsChoiceReceiver in user 0 (the
 * ProfileActivity.sendLivePrefs shape), where PrivateDnsWatch's Gate checks the token, the network, the mode and the
 * marker before it writes; the choice applies phone-wide. A dismissal with no choice only finishes and sends nothing,
 * so the notification stays and asks again. No file, no setting, no state beyond the token in RAM.
 *
 * Not exported: only the chooser's own PendingIntent starts it.
 */
public final class PrivateDnsPromptActivity extends Activity {
    static final String EXTRA_TOKEN = "nowhere.privatedns.token";

    private static final String TAG = "NowhereChooser";

    private long token;          // the prompt's token; 0 = none
    private AlertDialog dialog;  // the showing dialog, or null

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        token = tokenOf(getIntent());
        if (token == 0) { finish(); return; } // only the watcher's notification starts it, always with a token
        dialog = new AlertDialog.Builder(this, android.R.style.Theme_Material_Dialog_Alert)
                .setTitle(PrivateDnsDowngrade.TITLE)
                .setMessage(PrivateDnsDowngrade.BODY)
                .setCancelable(false) // a choice is required, as on the gate
                .setPositiveButton(PrivateDnsDowngrade.CONTINUE, (d, w) -> send(PrivateDnsDowngrade.CHOICE_CONTINUE))
                .setNegativeButton(PrivateDnsDowngrade.STAY, (d, w) -> send(PrivateDnsDowngrade.CHOICE_STAY))
                .setOnDismissListener(d -> finish())
                .show();
    }

    /** A second tap while the dialog is up (singleTop): a button sends the newest token. */
    @Override protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        long t = tokenOf(i);
        if (t != 0) token = t;
    }

    @Override protected void onDestroy() {
        AlertDialog d = dialog;
        dialog = null;
        if (d != null) {
            try {
                d.dismiss();
            } catch (Throwable ignored) {
            }
        }
        super.onDestroy();
    }

    private static long tokenOf(Intent i) {
        return i != null ? i.getLongExtra(EXTRA_TOKEN, 0L) : 0L;
    }

    /** The choice to user 0's Gate, by an explicit broadcast. The log names no network. */
    private void send(String choice) {
        try {
            sendBroadcastAsUser(new Intent(this, PrivateDnsChoiceReceiver.class)
                    .putExtra(EXTRA_TOKEN, token)
                    .putExtra(PrivateDnsChoiceReceiver.EXTRA_CHOICE, choice), android.os.UserHandle.SYSTEM);
        } catch (Throwable t) {
            Log.w(TAG, "private dns choice not sent: " + t.getClass().getName());
        }
    }
}
