package com.nowhere.chooser;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;

/** NWP-20261208-32: a tap on the "update available" notice opens Profile at its Update card, where "Sign out &amp;
 *  install" is, on every channel (ordinary and mandatory alike). ChooserActivity.postUpdateNotice posts the notice from
 *  user 0 into the session's user through createContextAsUser(uid), so the PendingIntent is made on that user's context
 *  (uc), as postHealthNotice does; made on user 0's context, the tap would start Profile in the gate's user, not the
 *  session's. ProfileActivity.openUpdateIfAsked reads the extra and act() decides what it does. Lifted here so the
 *  intent, the PendingIntent and the decision run under javac (core/chooser/test-update-notice-tap-java.sh). */
final class UpdateNoticeTap {
    private UpdateNoticeTap() {}

    /** The LandingLine.EXTRA_OPEN value that asks Profile for its Update card. */
    static final String OPEN_UPDATE = "update";
    /** The notice's id (ChooserActivity.NOTIF_UPDATE_ID): one PendingIntent per notice. */
    static final int REQUEST = 0x0D23;

    /** Profile in uc's package, asked for its Update card. SINGLE_TOP: a Profile screen already on top gets
     *  onNewIntent, not a second copy. */
    static Intent intent(Context uc) {
        return new Intent().setClassName(uc, "com.nowhere.chooser.ProfileActivity")
                .putExtra(LandingLine.EXTRA_OPEN, OPEN_UPDATE)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
    }

    /** The notice's content intent, made on the context it is given (the session user's) and no other. */
    static PendingIntent pending(Context uc) {
        return PendingIntent.getActivity(uc, REQUEST, intent(uc),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    /** What Profile does with an EXTRA_OPEN: NONE (not ours), WAIT (the probe has not answered: keep the extra),
     *  DROP (answered, no update offered: remove the extra), SCROLL (answered and offered: remove it, show the card). */
    enum Act { NONE, WAIT, DROP, SCROLL }

    static Act act(String open, boolean probed, boolean avail) {
        if (!OPEN_UPDATE.equals(open)) return Act.NONE;
        if (!probed) return Act.WAIT;
        return avail ? Act.SCROLL : Act.DROP;
    }
}
