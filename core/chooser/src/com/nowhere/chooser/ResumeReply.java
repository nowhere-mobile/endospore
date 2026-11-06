package com.nowhere.chooser;

/** NWP-20261109-19: the verdict of the daemon's RESUME reply, pure java.lang so a javac suite runs it
 *  (core/vendor-common/bin/test-resume-reply-java.sh).
 *
 *  <p>core/agent/main.go handleResume answers with exactly six things: {@code NONE}, {@code WRONGPASS},
 *  {@code ERR-WORKER-BUSY} (the {@code workerBusy} const), {@code NEEDKEY}, {@code ERR-RESTORE} and
 *  {@code OK <uid>}. The tokens are matched EXACTLY, on purpose: only {@link #WRONG} may clear the typed entry and
 *  say "wrong passphrase", so it must be affirmative. NWP-20261006-23: a reply that is not a credential verdict (an
 *  empty one from a dead socket or a timeout, an unknown code) used to be rendered as "wrong passphrase", and a user
 *  told their right passphrase is wrong may sign in fresh, which reaps the cold-locked session. NWP-20261023-03: the
 *  busy lane answers ERR-WORKER-BUSY and the daemon's comment relies on that being rendered as "couldn't resume --
 *  try again" with the entry kept, which is {@link #RETRY}. The uid must be above 0: user 0 is the gate.
 *
 *  <p>NWP-20261117-12 (#30): before handleResume runs, handleLogin's dispatch ({@code refuseNoTmpfs}) answers
 *  {@code ERR-NOTMPFS} when the daemon's state dir is not a tmpfs. That is {@link #NOTMPFS}: not {@link #WRONG} (the
 *  entry stays typed) and not {@link #RETRY} (a retry cannot help; only a restart does). */
final class ResumeReply {
    private ResumeReply() {}

    static final int SWITCH = 1;          // "OK <uid>", uid > 0: switch into that user
    static final int GONE = 2;            // "NONE": no cold-locked session any more -> a fresh gate
    static final int RESTORE_FAILED = 3;  // "ERR-RESTORE": right entry, but its account file could not be put back
    static final int NEEDKEY = 4;         // "NEEDKEY": the passphrase is fine, the key read failed
    static final int WRONG = 5;           // "WRONGPASS": the only credential verdict
    static final int RETRY = 6;           // everything else: "", ERR-WORKER-BUSY, an OK without a usable uid, an unknown code
    static final int NOTMPFS = 7;         // "ERR-NOTMPFS": the state dir is not a tmpfs (refused at the dispatch)

    static final class Verdict {
        final int kind;
        final int uid;                    // > 0 for SWITCH, -1 otherwise
        Verdict(int kind, int uid) { this.kind = kind; this.uid = uid; }
    }

    static Verdict of(String reply) {
        final String t = reply == null ? "" : reply.trim();
        if (t.equals("OK") || t.startsWith("OK ")) {
            final String n = t.substring(2).trim();
            int uid = -1;
            boolean digits = !n.isEmpty();
            for (int i = 0; i < n.length() && digits; i++) digits = n.charAt(i) >= '0' && n.charAt(i) <= '9';
            if (digits) { try { uid = Integer.parseInt(n); } catch (NumberFormatException e) { uid = -1; } }
            if (uid > 0) return new Verdict(SWITCH, uid);
            return new Verdict(RETRY, -1);
        }
        if (t.equals("NONE")) return new Verdict(GONE, -1);
        if (t.equals("ERR-RESTORE")) return new Verdict(RESTORE_FAILED, -1);
        if (t.equals("NEEDKEY")) return new Verdict(NEEDKEY, -1);
        if (t.equals("WRONGPASS")) return new Verdict(WRONG, -1);
        if (t.equals("ERR-NOTMPFS")) return new Verdict(NOTMPFS, -1);
        return new Verdict(RETRY, -1);
    }
}
