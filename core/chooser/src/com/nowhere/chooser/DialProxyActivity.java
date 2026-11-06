package com.nowhere.chooser;

import android.app.Activity;
import android.os.Bundle;

/**
 * #135 B4: the ACTION_DIAL (tel:) activity Android requires a ROLE_DIALER holder to declare -- without it the
 * role won't attach. The amnesiac gate has no user-facing dialer (placing calls is a per-person feature that
 * belongs inside a logged-in profile, not on the shared user-0 gate), so this immediately finishes; it exists
 * only to satisfy the default-dialer component contract.
 */
public final class DialProxyActivity extends Activity {
    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        finish();
    }
}
