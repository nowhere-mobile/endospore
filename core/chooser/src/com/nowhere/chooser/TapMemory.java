package com.nowhere.chooser;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** NWP-20261122-11 (h51 #1, docs/product-decisions.md, 2026-11-01): the on-demand taps a chooser has queued and not
 *  yet served, remembered in the session so a chooser restart (a cold lock and its resume) does not drop them. The
 *  tap worker adds its app before it queues it and removes it when its install ends, whether it worked or failed.
 *  When the chooser starts again in the same session, the sweep installs the remembered taps first, not opened.
 *
 *  The file is `v=1 serial=<the session user's serial>`, then one package name per line. Package names only.
 *  It lives in the session user's own chooser files dir, so the vault seal carries it. Two things stop a sealed copy
 *  from running at a later sign-in: the sign-out clears it, and every sign-in makes a new user whose serial is never
 *  reused, so a copy restored into another session reads as foreign and is deleted at its first read.
 *
 *  Pure: java.io and java.util only. No method throws; a failure is a false (or an empty list) the caller logs.
 *  Every member that touches the file holds LOCK, so a tap worker and the sweep thread cannot lose an update. */
final class TapMemory {
    static final String NAME = "nowhere-tapmemory";
    private static final int MAX_BYTES = 64 * 1024; // a larger file is malformed
    private static final Object LOCK = new Object();

    private TapMemory() {}

    static File file(File filesDir) {
        return new File(filesDir, NAME);
    }

    /** The remembered packages in file order, each once. A missing file, or an unknown session (serial < 0), reads
     *  empty and is left alone. A stamp that is not exactly this serial, a malformed header or any line that is not a
     *  package name reads empty AND deletes the file, so a file from another session never runs. */
    static List<String> read(File f, long serial) {
        synchronized (LOCK) {
            List<String> out = readLocked(f, serial);
            return out == null ? new ArrayList<String>() : out;
        }
    }

    /** Remembers pkg (once). False when nothing could be recorded: no session serial, a bad name, or a failed write. */
    static boolean add(File f, long serial, String pkg) {
        if (serial < 0 || !isPackageName(pkg)) return false;
        synchronized (LOCK) {
            List<String> cur = readLocked(f, serial);
            if (cur == null) cur = new ArrayList<>();
            if (cur.contains(pkg)) return true;
            cur.add(pkg);
            return writeLocked(f, serial, cur);
        }
    }

    /** Forgets pkg. The last one gone deletes the file. False on a failed write or delete. */
    static boolean remove(File f, long serial, String pkg) {
        if (serial < 0) return false;
        synchronized (LOCK) {
            List<String> cur = readLocked(f, serial);
            if (cur == null) return true;
            if (!cur.remove(pkg)) return true;
            if (cur.isEmpty()) return deleteLocked(f);
            return writeLocked(f, serial, cur);
        }
    }

    /** Forgets every remembered tap (the sign-out). True when the file is gone after the call. */
    static boolean clear(File f) {
        synchronized (LOCK) {
            try {
                File tmp = tmpOf(f);
                if (tmp.exists() && !tmp.delete()) return false;
            } catch (RuntimeException e) {
                return false;
            }
            return deleteLocked(f);
        }
    }

    /** The remembered taps nobody in this process is serving now (not in live), in their order, each once. */
    static List<String> afterRestart(List<String> remembered, Set<String> live) {
        List<String> out = new ArrayList<>();
        if (remembered == null) return out;
        Set<String> seen = new LinkedHashSet<>();
        Set<String> busy = live == null ? Collections.<String>emptySet() : live;
        for (String p : remembered) {
            if (p == null || busy.contains(p) || !seen.add(p)) continue;
            out.add(p);
        }
        return out;
    }

    /** SmsRoleRoam.isPackageName's rule, copied: that class needs Android types and this one must not. */
    private static boolean isPackageName(String s) {
        if (s == null || s.isEmpty() || s.length() > 255 || s.indexOf('.') < 0) return false;
        if (s.startsWith(".") || s.endsWith(".") || s.contains("..")) return false;
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (!(c == '.' || c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return false;
        }
        return true;
    }

    /** null for a missing file or an unknown session (nothing deleted); an empty list for a foreign or malformed file,
     *  which is deleted. */
    private static List<String> readLocked(File f, long serial) {
        if (serial < 0) return null;
        byte[] raw;
        try {
            if (!f.exists()) return null;
            raw = readAll(f);
        } catch (IOException | RuntimeException e) {
            raw = null;
        }
        List<String> pkgs = raw == null ? null : parse(raw, serial);
        if (pkgs == null) {
            deleteLocked(f);
            return new ArrayList<>();
        }
        return pkgs;
    }

    /** The packages, or null when the header is not exactly this serial's or a line is not a package name. */
    private static List<String> parse(byte[] raw, long serial) {
        String s;
        try {
            s = new String(raw, "UTF-8");
        } catch (java.io.UnsupportedEncodingException e) {
            return null;
        }
        if (s.endsWith("\n")) s = s.substring(0, s.length() - 1);
        String[] lines = s.split("\n", -1);
        if (lines.length == 0 || !lines[0].equals("v=1 serial=" + serial)) return null;
        List<String> out = new ArrayList<>();
        for (int i = 1; i < lines.length; i++) {
            if (!isPackageName(lines[i])) return null;
            if (!out.contains(lines[i])) out.add(lines[i]);
        }
        return out;
    }

    private static byte[] readAll(File f) throws IOException {
        if (f.length() > MAX_BYTES) return null;
        try (InputStream in = new FileInputStream(f)) {
            ByteArrayOutputStream b = new ByteArrayOutputStream();
            byte[] buf = new byte[4096];
            int n;
            while ((n = in.read(buf)) > 0) {
                b.write(buf, 0, n);
                if (b.size() > MAX_BYTES) return null;
            }
            return b.toByteArray();
        }
    }

    /** The whole file to a temp in the same dir, then renamed over (SmsRoleRoam.write's model). */
    private static boolean writeLocked(File f, long serial, List<String> pkgs) {
        StringBuilder sb = new StringBuilder("v=1 serial=").append(serial).append('\n');
        for (String p : pkgs) sb.append(p).append('\n');
        File tmp = tmpOf(f);
        try {
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(sb.toString().getBytes("UTF-8"));
                out.getFD().sync();
            }
            if (tmp.renameTo(f)) return true;
        } catch (IOException | RuntimeException e) {
            // falls through to the cleanup
        }
        try { tmp.delete(); } catch (RuntimeException e) { /* nothing more to do */ }
        return false;
    }

    private static boolean deleteLocked(File f) {
        try {
            return !f.exists() || f.delete() || !f.exists();
        } catch (RuntimeException e) {
            return false;
        }
    }

    private static File tmpOf(File f) {
        return new File(f.getParentFile(), f.getName() + ".tmp");
    }
}
