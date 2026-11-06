package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Profile > Preferences > "Sign out of Google" (NWP-20261107-11; #743, decided 2026-10-20 dn-1025 #2, copy decided
 * 2026-10-21 dn-1106 #2). The pure parts: the decided wording, the mark roamd's #sys account guard looks for, and the
 * rewrite of the marks file. The guard (nowhere_roamd.sh acct_seal) lets a zero-row #sys seal through only when every
 * account that arrived carries a mark, so the chooser writes the mark BEFORE it removes the account and takes it back
 * out when the removal does not happen. Nothing here touches android.*; ProfileActivity supplies the Store that does the I/O.
 *
 * The hash and the file are roamd's contract (the choices above acct_mark_file): a mark is the lowercase hex SHA-256
 * of MARK_PREFIX + the account name, one per line in files/MARK_FILE, never the name itself.
 */
final class GoogleSignOut {
    private GoogleSignOut() {}

    static final String ACCOUNT_TYPE = "com.google";
    static final String ROW_LABEL = "Sign out of Google";
    static final String GROUP_LABEL = "Google accounts";
    static final String CONFIRM = "Signing out here removes this account from your profile at the next save. "
            + "Signing out in Android Settings does not stick.";
    static final String MARK_PREFIX = "nowhere-acct-mark-v1:";
    static final String MARK_FILE = "nowhere-acct-marks";
    static final String JOURNAL_FILE = "nowhere-acct-marks.pending";

    /** The mark of an account: lowercase hex SHA-256 of MARK_PREFIX + name, in UTF-8. */
    static String markHash(String name) {
        try {
            byte[] d = MessageDigest.getInstance("SHA-256").digest((MARK_PREFIX + name).getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(64);
            for (byte b : d) {
                sb.append(Character.forDigit((b >> 4) & 0xF, 16)).append(Character.forDigit(b & 0xF, 16));
            }
            return sb.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static boolean isHash(String s) {
        if (s.length() != 64) return false;
        for (int i = 0; i < 64; i++) {
            char c = s.charAt(i);
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
        }
        return true;
    }

    private static List<String> lines(String existing) {
        List<String> out = new ArrayList<>();
        if (existing == null) return out;
        for (String l : existing.split("\n")) {
            String t = l.trim();
            if (isHash(t)) out.add(t);
        }
        return out;
    }

    private static String join(List<String> hs) {
        StringBuilder sb = new StringBuilder();
        for (String h : hs) sb.append(h).append('\n');
        return sb.toString();
    }

    /** The marks file's new content: its valid hash lines in order, then hash unless present; anything else dropped. */
    static String withMark(String existing, String hash) {
        List<String> hs = lines(existing);
        if (!hs.contains(hash)) hs.add(hash);
        return join(hs);
    }

    /** The marks file's content without hash; "" when no mark is left (the caller then deletes the file). */
    static String withoutMark(String existing, String hash) {
        List<String> hs = lines(existing);
        hs.removeIf(h -> h.equals(hash));
        return join(hs);
    }

    /** Offered to a STORED, online session only, as MobileData.offered: a throwaway is never sealed. */
    static boolean offered(String sessionType, boolean offline) {
        return !offline && "STORED".equals(sessionType);
    }

    /** The marks file, as the lifecycle below sees it. read: "" when absent, IOException when it exists and cannot be
     *  read. write: replace the whole file atomically (a temp and a rename). delete: succeeds when already absent. */
    interface Store {
        String read() throws java.io.IOException;
        void write(String content) throws java.io.IOException;
        void delete() throws java.io.IOException;
    }

    // Every read-modify-write of the marks file and of the journal, and the per-account claim, run under this one
    // lock: two sign-outs that overlap cannot each read the old file and leave only one entry, and a rollback cannot
    // write back a stale copy that holds the mark it is removing (or lacks another account's).
    private static final Object LOCK = new Object();
    private static final Set<String> PENDING = new HashSet<>();

    /** Claim an account (by its hash) for one sign-out; false when one is already running for it. */
    static boolean claim(String hash) {
        synchronized (LOCK) {
            return PENDING.add(hash);
        }
    }

    /** End the claim once the removal's outcome is settled. */
    static void release(String hash) {
        synchronized (LOCK) {
            PENDING.remove(hash);
        }
    }

    /**
     * Record hash in the journal and then in the marks file; true only when both are on disk. The journal (the same
     * line format, JOURNAL_FILE; roamd's acct_seal refuses a drop while it is non-empty) is the durable memory of a
     * sign-out whose outcome is not settled: it is written first and cleared only once the removal landed (settle) or the mark came back out
     * (unmark). A chooser that dies, or a rollback that cannot land, therefore leaves an entry that the next sweep
     * acts on whether or not the account is still on the phone.
     */
    static boolean mark(Store marks, Store journal, String hash) {
        synchronized (LOCK) {
            try {
                journal.write(withMark(journal.read(), hash));
                marks.write(withMark(marks.read(), hash));
                return true;
            } catch (java.io.IOException | RuntimeException e) {
                return false;
            }
        }
    }

    /** The removal landed: forget the journal entry. False when it could not be cleared (the sweep then withdraws the
     *  mark, which only makes roamd refuse a later drop, the safe direction). */
    static boolean settle(Store journal, String hash) {
        synchronized (LOCK) {
            return dropEntry(journal, hash);
        }
    }

    private static boolean dropEntry(Store journal, String hash) {
        try {
            String left = withoutMark(journal.read(), hash);
            if (left.isEmpty()) journal.delete(); else journal.write(left);
            return true;
        } catch (java.io.IOException | RuntimeException e) {
            return false;
        }
    }

    /**
     * Take hash back out after a removal that did not happen. A mark beside an account still on the phone would let a
     * later destruction of that account seal, so when the precise rewrite cannot land (the file cannot be read, or
     * written) the whole file goes: every pending mark is lost with it, which only makes roamd refuse a later drop,
     * the safe direction. Returns false only when the mark is provably still there (nothing could be changed); the
     * journal entry then stays, so the sweep keeps trying, in this process or the next.
     */
    static boolean unmark(Store marks, Store journal, String hash) {
        synchronized (LOCK) {
            boolean out;
            try {
                String left = withoutMark(marks.read(), hash);
                if (left.isEmpty()) marks.delete(); else marks.write(left);
                out = true;
            } catch (java.io.IOException | RuntimeException e) {
                try {
                    marks.delete();
                    out = true;
                } catch (java.io.IOException | RuntimeException e2) {
                    out = false;
                }
            }
            if (out) dropEntry(journal, hash);
            return out;
        }
    }

    /**
     * Withdraw every mark that no longer stands for a sign-out that happened: one whose journal entry is still open
     * with no sign-out running (a rollback that could not land, a chooser that died mid-way), whether or not its
     * account is still present, and one beside a Google account still on the phone with no sign-out running. A
     * sign-out that completed has no journal entry and an absent account, so its mark is left for roamd. present is
     * read INSIDE the lock, and a claimed account is skipped. An unreadable journal withdraws every mark, and the
     * precise rewrite falls back to deleting the file: both only make roamd refuse a later drop. Returns false only
     * when a stale mark is provably still there.
     */
    static boolean sweep(Store marks, Store journal, java.util.function.Supplier<Set<String>> present) {
        synchronized (LOCK) {
            Set<String> open = new HashSet<>();
            boolean journalLost = false;
            try {
                for (String h : lines(journal.read())) if (!PENDING.contains(h)) open.add(h);
            } catch (java.io.IOException | RuntimeException e) {
                journalLost = true;
            }
            try {
                Set<String> here = present.get();
                List<String> keep = new ArrayList<>();
                boolean stale = false;
                for (String h : lines(marks.read())) {
                    if (PENDING.contains(h)) { keep.add(h); continue; }
                    if (journalLost || open.contains(h) || here.contains(h)) stale = true; else keep.add(h);
                }
                if (stale) {
                    try {
                        if (keep.isEmpty()) marks.delete(); else marks.write(join(keep));
                    } catch (java.io.IOException | RuntimeException e) {
                        marks.delete();
                    }
                }
            } catch (java.io.IOException | RuntimeException e) {
                try {
                    marks.delete();
                } catch (java.io.IOException | RuntimeException e2) {
                    return false;
                }
            }
            // the marks are clean: the open entries have done their work
            for (String h : open) dropEntry(journal, h);
            return !journalLost;
        }
    }

    /** The status line when the sign-out did not happen; why is "not recorded" or "not removed". */
    static String failLine(String why) {
        return "Couldn't sign out of Google (" + why + ").";
    }

    /** The Preferences row's second line: how many Google accounts the "Google accounts" screen lists. */
    static String groupSubtitle(int n) {
        return n == 1 ? "1 account" : n + " accounts";
    }
}
