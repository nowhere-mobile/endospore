package com.nowhere.chooser;

import android.widget.TextView;

/** Stub for the prep harness (NWP-20261113-22): the real busy() writes a spinner span, then the text, in one setText. */
final class StatusLine {
    private StatusLine() {}

    static void busy(TextView tv, CharSequence text) { tv.setText(" " + text); }
}
