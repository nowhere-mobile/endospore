package android.app;

import android.content.Context;
import android.content.Intent;
import java.util.ArrayList;
import java.util.List;

/** NWP-20261208-32 stub: getActivity records each call (context, request, intent, flags). Flags at AOSP values. */
public class PendingIntent {
    public static final int FLAG_UPDATE_CURRENT = 0x08000000;
    public static final int FLAG_IMMUTABLE = 0x04000000;

    public static final class Call {
        public final Context context;
        public final int request;
        public final Intent intent;
        public final int flags;

        Call(Context context, int request, Intent intent, int flags) {
            this.context = context; this.request = request; this.intent = intent; this.flags = flags;
        }
    }

    public static final List<Call> calls = new ArrayList<>();

    public static void reset() { calls.clear(); }

    public static PendingIntent getActivity(Context context, int request, Intent intent, int flags) {
        calls.add(new Call(context, request, intent, flags));
        return new PendingIntent();
    }
}
