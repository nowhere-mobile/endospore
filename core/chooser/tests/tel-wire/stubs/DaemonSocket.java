import android.os.SystemClock;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Test stand-in for the chooser's DaemonSocket: records each request, answers from a script (a null entry is "no
 *  answer", as is anything past its end), and moves the stub clock on by a set amount per call. */
final class DaemonSocket {
    static final List<String> sent = new ArrayList<>();
    private static List<String> script = new ArrayList<>();
    private static long advancePerCallMs;

    private DaemonSocket() {}

    static void reset(long advanceMs, String... replies) {
        sent.clear();
        script = new ArrayList<>(Arrays.asList(replies));
        advancePerCallMs = advanceMs;
    }

    static String roundTrip(String msg, int readCapMs) {
        int n = sent.size();
        sent.add(msg);
        SystemClock.advance(advancePerCallMs);
        return n < script.size() ? script.get(n) : null;
    }
}
