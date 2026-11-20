package com.nowhere.chooser;

import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.function.Predicate;

/**
 * NWP-20261106-03: whether ProfileActivity honours the {@code auto} extra (java.lang, java.lang.ref and java.util only,
 * so it runs under javac).
 *
 * <p>ProfileActivity is exported (the drawer's Profile entry), so any app in a session can start it with
 * {@code auto=true}. The L4 backstop (five wrong keyguard unlocks) starts the non-exported {@code .AutoLogoff}
 * alias instead; the extra is honoured only when the launch came through that alias.
 *
 * <p>NWP-20261208-02: the L4 start decision ({@link #shouldStart}) and the live-instance registry ({@link Live}) that
 * lets AdminReceiver ask whether a Profile screen is already ending the session.
 */
final class AutoLogoffGate {
    private AutoLogoffGate() {}

    static final String ALIAS = "com.nowhere.chooser.AutoLogoff";

    static boolean honoured(String launchedClass, boolean autoExtra) {
        return autoExtra && ALIAS.equals(launchedClass);
    }

    /** NWP-20261208-02: whether the L4 backstop starts the .AutoLogoff alias: on the max-th wrong unlock and every
     *  one after it, unless a sign-out or a terminal Profile screen is already under way (a cleared task would
     *  destroy that screen and start a second sign-out). */
    static boolean shouldStart(int fails, int max, boolean underWay) {
        return fails >= max && !underWay;
    }

    /** NWP-20261208-02: the live instances of an activity, held weakly. MAIN THREAD ONLY: activity callbacks and a
     *  manifest receiver's onReceive both run there, so there is no lock. remove is by identity; remove and any
     *  prune references whose activity was collected without an onDestroy. */
    static final class Live<T> {
        private final List<WeakReference<T>> refs = new ArrayList<>();

        void add(T t) {
            refs.add(new WeakReference<>(t));
        }

        void remove(T t) {
            for (Iterator<WeakReference<T>> i = refs.iterator(); i.hasNext(); ) {
                T u = i.next().get();
                if (u == null || u == t) i.remove();
            }
        }

        boolean any(Predicate<T> p) {
            boolean hit = false;
            for (Iterator<WeakReference<T>> i = refs.iterator(); i.hasNext(); ) {
                T u = i.next().get();
                if (u == null) { i.remove(); continue; }
                if (p.test(u)) hit = true;
            }
            return hit;
        }
    }
}
