package com.nowhere.chooser;

import android.app.Activity;
import android.os.Bundle;

/**
 * #135 B3: the ACTION_SENDTO (sms:/smsto:/mms:/mmsto:) target Android requires the default SMS app to
 * declare. The amnesiac gate has no messaging composer (composing/sending is a per-person feature that
 * belongs inside a logged-in profile, not on the shared user-0 gate), so this simply finishes -- it exists
 * only to satisfy the default-SMS-app component contract.
 */
public final class ComposeSmsActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        finish();
    }
}
