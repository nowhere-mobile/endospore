package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;

/** NWP-20261005-11: how an install settles this installer's own leftover sessions for one package before it creates
 *  a new one. A lock that lands mid-install kills the chooser, but a session it had already COMMITTED keeps running in
 *  the system, and a second commit of that package is refused as a duplicate. So an UNCOMMITTED session of the
 *  package is abandoned (it can never finish), a COMMITTED one is waited out to a bound, and then whether the package
 *  has real code decides the answer. Another package's sessions are never touched.
 *
 *  NWP-20261127-13 lifted the rule out of UnarchiveService.awaitInterruptedInstall, which is now its Android adapter
 *  (the installer, the clock and the log behind Sessions), so the rule runs under javac against a fake installer:
 *  core/vendor-common/bin/test-interrupted-install-java.sh. java.* only -- no Android type. */
final class InterruptedInstall {
    private InterruptedInstall() {}

    /** One session of THIS installer, as getMySessions() reports it. pkg is the session's app package; it may be null. */
    static final class Mine {
        final int id;
        final boolean committed;
        final String pkg;

        Mine(int id, boolean committed, String pkg) {
            this.id = id;
            this.committed = committed;
            this.pkg = pkg;
        }
    }

    /** The installer, the clock and the log, behind one seam. */
    interface Sessions {
        /** Every session of this installer, of EVERY package: settle does the package filter. */
        List<Mine> mine() throws Exception;
        void abandon(int id) throws Exception;
        /** True while the session still exists (getSessionInfo(id) != null). */
        boolean present(int id) throws Exception;
        /** Whether the package has real code installed now. */
        boolean installed();
        long nowMs();
        void sleep(long ms) throws InterruptedException;
        void info(String m);
        /** t may be null. */
        void warn(String m, Throwable t);
    }

    /** TRUE if an earlier install finished and pkg is installed, FALSE if one ended without installing it, null if
     *  there was nothing to wait for, the scan failed, the wait was interrupted or boundMs passed. Never throws from
     *  the installer's side: on any doubt the caller's own install runs. */
    static Boolean settle(Sessions s, String pkg, long boundMs, long pollMs) {
        String p = "unarchive install " + pkg;
        List<Integer> committed = new ArrayList<>();
        try {
            for (Mine m : s.mine()) {
                if (m == null || !pkg.equals(m.pkg)) continue;
                if (m.committed) {
                    committed.add(m.id);
                } else {
                    try { s.abandon(m.id); } catch (Throwable ignore) {}
                    s.info(p + ": abandoned an uncommitted session " + m.id + " left by an interrupted run (NWP-20261005-11)");
                }
            }
        } catch (Throwable t) {
            s.warn(p + ": session scan failed", t);
            return null;
        }
        if (committed.isEmpty()) return null;
        s.info(p + ": an interrupted install is still running " + committed
                + " -- waiting for it instead of committing a duplicate (NWP-20261005-11)");
        long deadline = s.nowMs() + boundMs;
        for (int id : committed) {
            while (true) {
                boolean here;
                try { here = s.present(id); } catch (Throwable ignore) { here = false; }
                if (!here) break; // finished, one way or the other
                if (s.nowMs() > deadline) {
                    s.warn(p + ": the interrupted install is still running at the 10-minute bound -- installing anyway", null);
                    return null;
                }
                try { s.sleep(pollMs); } catch (InterruptedException ie) { return null; }
            }
        }
        boolean landed = s.installed();
        s.info(p + ": the interrupted install ended -> "
                + (landed ? "installed, using it" : "not installed, installing again") + " (NWP-20261005-11)");
        return landed;
    }
}
