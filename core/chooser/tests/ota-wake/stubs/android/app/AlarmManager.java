package android.app;

import java.util.ArrayList;
import java.util.List;

/** Records each alarm as {"exact"|"inexact", when}; either call can be told to throw. */
public class AlarmManager {
    public static final int ELAPSED_REALTIME_WAKEUP = 2;
    public final List<Object[]> calls = new ArrayList<>();
    public boolean exactThrows;
    public boolean inexactThrows;
    public void setExactAndAllowWhileIdle(int type, long when, PendingIntent pi) {
        if (exactThrows) throw new SecurityException("exact alarms not permitted");
        calls.add(new Object[] {"exact", when});
    }
    public void setAndAllowWhileIdle(int type, long when, PendingIntent pi) {
        if (inexactThrows) throw new IllegalStateException("alarm refused");
        calls.add(new Object[] {"inexact", when});
    }
}
