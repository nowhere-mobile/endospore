package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/** Records every message; answers `reply`, or throws when `boom` is set. */
final class DaemonSocket {
    static final List<String> sent = new ArrayList<>();
    static String reply = "";
    static boolean boom;
    static String roundTrip(String msg, int readCapMs) {
        sent.add(msg);
        if (boom) throw new IllegalStateException("socket exploded");
        return reply;
    }
}
