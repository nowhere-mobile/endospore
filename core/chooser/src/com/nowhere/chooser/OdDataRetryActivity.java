package com.nowhere.chooser;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/** NWP-20261130-03: the "Try again" button of an app suspended until its data lands. The platform's suspension dialog
 *  starts this activity (ACTION_SHOW_SUSPENDED_APP_DETAILS, guarded by SEND_SHOW_SUSPENDED_APP_DETAILS) with the app's
 *  name; it shows nothing. OdDataBarrierHost.retry sends one more RESTORE-ODDATA for a package the barrier holds. */
public class OdDataRetryActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        Intent i = getIntent();
        OdDataBarrierHost.retry(getApplicationContext(), i == null ? null : i.getStringExtra(Intent.EXTRA_PACKAGE_NAME));
        finish();
    }
}
