package com.nowhere.chooser;

/** NWP-20261125-18: the build-aside-and-swap of an archived-placeholder snapshot, files/nowhere-appmeta/<pkg>.
 *  ProfileActivity.captureArchivedMeta (called by captureAppCode at sign-out and by AppInstallReceiver.recaptureCode
 *  in a session, both under AppCodeLine.LOCK) used to rmTree the published dir and then rebuild it in place, so any
 *  throw after the delete (a full /data on the meta write, a PackageManager binder failure) left no snapshot, and a
 *  failed signer read wrote a cert-less meta over a good one. installArchivedPlaceholder refuses both, so the app lost
 *  its launcher icon and then its code line. Now the snapshot is built in stagingFor(files, pkg) and publish swaps it
 *  in only when it is complete, or when there is no previous snapshot to keep.
 *
 *  The published dir never moves and its meta is never deleted: publish moves the old icons aside, moves the new
 *  icons in, and then renames the new meta over the old one, which replaces it in one step. So at every point, and
 *  after any failure, nowhere-appmeta/<pkg>/meta is the old meta or the new one, and roamd's appcode_seal always finds
 *  a raisable snapshot. A failure before the meta rename moves the old icons back (copying when a rename fails); an old
 *  icon that cannot come back stays in the aside dir until a later recover puts it back.
 *
 *  The staging and aside dirs live OUTSIDE nowhere-appmeta: roamd's appcode_seal copies nowhere-appmeta/<pkg> by name
 *  and captureAppCode prunes every child that is not a kept pkg, so nothing but <pkg> dirs may ever appear there.
 *  Pure java.* (with AppCodeManifest), so test-appmeta-swap-java.sh compiles this class alone and executes it. */
final class AppMetaDir {
    private AppMetaDir() {}

    /** Renames one file; the test seam for publish. */
    interface Renamer { boolean rename(java.io.File from, java.io.File to); }

    /** Copies one file tree (to must not exist); the test seam for publish and recover. */
    interface Copier { boolean copy(java.io.File from, java.io.File to); }

    /** Where captureArchivedMeta builds the new snapshot of pkg: files/.nowhere-appmeta-staging/<pkg>. */
    static java.io.File stagingFor(java.io.File filesDir, String pkg) {
        return new java.io.File(new java.io.File(filesDir, ".nowhere-appmeta-staging"), pkg);
    }

    /** Where publish holds the previous icons of pkg during the swap: files/.nowhere-appmeta-old/<pkg>. */
    static java.io.File asideFor(java.io.File filesDir, String pkg) {
        return new java.io.File(new java.io.File(filesDir, ".nowhere-appmeta-old"), pkg);
    }

    /** Whether staged can raise a placeholder: staged/meta is a file holding a vc line (any number, 0 included:
     *  captureArchivedMeta always writes one) and at least one non-empty cert line, read by AppCodeManifest.parseMeta's
     *  line rules. No act line is required: a launcher-less group member has none. Never throws. */
    static boolean complete(java.io.File staged) {
        try {
            java.io.File m = new java.io.File(staged, "meta");
            if (!m.isFile()) return false;
            String text = new String(java.nio.file.Files.readAllBytes(m.toPath()),
                    java.nio.charset.StandardCharsets.UTF_8);
            boolean vc = false;
            try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader(text))) {
                String line;
                while ((line = br.readLine()) != null) {
                    String[] f = line.split("\t", -1);
                    if (f.length < 2 || !"vc".equals(f[0])) continue;
                    try { Long.parseLong(f[1].trim()); vc = true; } catch (NumberFormatException ignore) {}
                }
            }
            if (!vc) return false;
            for (String c : AppCodeManifest.parseMeta(text).certs) if (!c.trim().isEmpty()) return true;
            return false;
        } catch (Throwable t) {
            return false;
        }
    }

    static boolean publish(java.io.File target, java.io.File staged, java.io.File aside) {
        return publish(target, staged, aside, java.io.File::renameTo, AppMetaDir::copy);
    }

    static boolean publish(java.io.File target, java.io.File staged, java.io.File aside, Renamer r) {
        return publish(target, staged, aside, r, AppMetaDir::copy);
    }

    /** Swap staged in as target. A complete staged dir always replaces target; an incomplete one replaces it only when
     *  there is no target (a first capture is published as built). False when target was kept: staged is then
     *  removed. Never throws.
     *  With a previous target dir: (0) recover puts back the icons of an earlier failed swap, and aside gets a copy of
     *  the old meta, (1) every old non-meta file moves to aside, (2) every new non-meta file moves in, (3) staged/meta
     *  is renamed over target/meta. Target and its meta are never deleted, so a failure at any step leaves the old meta
     *  (or, after step 3, the new one) in place. A failure before step 3 runs restore, which removes the new icons that
     *  moved in and puts the old icons back. An old icon that cannot be put back stays in aside, never deleted: the
     *  next capture's recover puts it back first. */
    static boolean publish(java.io.File target, java.io.File staged, java.io.File aside, Renamer r, Copier c) {
        boolean swapping = false;
        java.util.List<java.io.File> in = new java.util.ArrayList<>();
        try {
            boolean whole = complete(staged);
            boolean had = target.exists();
            if (had && !whole) { rm(staged); return false; }
            if (!staged.isDirectory()) return false;
            if (had && !target.isDirectory()) { rm(target); had = target.exists(); }
            if (!had) return first(target, staged, r);
            if (!recover(target, aside, r, c)) { rm(staged); return false; }
            if (!aside.mkdirs() && !aside.isDirectory()) { rm(staged); return false; }
            try {
                java.nio.file.Files.write(new java.io.File(aside, "meta").toPath(), metaOf(target));
            } catch (Throwable t) { rm(aside); rm(staged); return false; }
            swapping = true;
            java.io.File[] old = target.listFiles();
            if (old == null) throw new java.io.IOException("cannot list " + target);
            for (java.io.File f : old) {
                if ("meta".equals(f.getName())) continue;
                if (!r.rename(f, new java.io.File(aside, f.getName()))) throw new java.io.IOException("aside " + f);
            }
            java.io.File[] neu = staged.listFiles();
            if (neu == null) throw new java.io.IOException("cannot list " + staged);
            for (java.io.File f : neu) {
                if ("meta".equals(f.getName())) continue;
                java.io.File to = new java.io.File(target, f.getName());
                in.add(to); // before the rename: a rename that moves and then throws still leaves a file to remove
                if (!r.rename(f, to)) throw new java.io.IOException("in " + f);
            }
            if (!r.rename(new java.io.File(staged, "meta"), new java.io.File(target, "meta")))
                throw new java.io.IOException("meta " + target);
            swapping = false;
            rm(aside); // a leftover holds the old meta: recover discards it unless the new meta has the same text
            rm(staged);
            return true;
        } catch (Throwable t) {
            if (swapping) restore(target, aside, in, r, c);
            try { rm(staged); } catch (Throwable ignore) {}
            return false;
        }
    }

    /** No previous target: rename staged to target, creating its parent; when the rename fails, copy staged into
     *  target, and remove a partial copy. True when target holds the snapshot. */
    private static boolean first(java.io.File target, java.io.File staged, Renamer r) {
        java.io.File parent = target.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs() && !parent.isDirectory()) {
            rm(staged);
            return false;
        }
        try { if (r.rename(staged, target)) return true; } catch (Throwable ignore) {}
        boolean ok = copy(staged, target);
        if (!ok) rm(target);
        rm(staged);
        return ok;
    }

    /** Undo steps 1 and 2 of publish: remove the files in moved into target, then recover the old icons from aside.
     *  target/meta is never touched. True when every old icon is back and aside is gone. Never throws. */
    static boolean restore(java.io.File target, java.io.File aside, java.util.List<java.io.File> in, Renamer r,
            Copier c) {
        try { for (java.io.File f : in) rm(f); } catch (Throwable ignore) {}
        return recover(target, aside, r, c);
    }

    static boolean recover(java.io.File target, java.io.File aside) {
        return recover(target, aside, java.io.File::renameTo, AppMetaDir::copy);
    }

    /** Put back the old icons a failed swap left in aside. aside/meta is the copy of the meta those icons belong to:
     *  when target is gone, or its meta differs (the swap completed), aside is stale and is removed. Otherwise each
     *  held file goes back into target (copying when a rename fails) and leaves aside only once it is in target; aside
     *  is removed only when nothing of it is left to put back. True when no aside is left. Never throws. */
    static boolean recover(java.io.File target, java.io.File aside, Renamer r, Copier c) {
        try {
            if (!aside.exists()) return true;
            java.io.File mark = new java.io.File(aside, "meta");
            boolean belongs = mark.isFile() && target.isDirectory() && java.util.Arrays.equals(
                    java.nio.file.Files.readAllBytes(mark.toPath()), metaOf(target));
            if (!belongs) { rm(aside); return !aside.exists(); }
            java.io.File[] held = aside.listFiles();
            if (held == null) return false;
            boolean all = true;
            for (java.io.File f : held) {
                if ("meta".equals(f.getName())) continue;
                java.io.File to = new java.io.File(target, f.getName());
                boolean ok = false;
                try { ok = r.rename(f, to); } catch (Throwable ignore) {}
                if (!ok) {
                    try {
                        rm(to);
                        ok = c.copy(f, to);
                    } catch (Throwable ignore) { ok = false; }
                    if (ok) rm(f); else { rm(to); all = false; }
                }
            }
            if (!all) return false;
            rm(aside);
            return !aside.exists();
        } catch (Throwable t) {
            return false;
        }
    }

    /** The bytes of dir/meta; none when dir holds no meta file. */
    private static byte[] metaOf(java.io.File dir) throws java.io.IOException {
        java.io.File m = new java.io.File(dir, "meta");
        return m.isFile() ? java.nio.file.Files.readAllBytes(m.toPath()) : new byte[0];
    }

    /** Before a capture starts: remove a leftover staged dir and a leftover aside dir of one pkg. Neither holds the
     *  published meta, which only ever lives in nowhere-appmeta/<pkg>. Call recover first: an aside that recover did
     *  not empty holds the only copy of old icons. Either argument may be null. Never throws. */
    static void clear(java.io.File staged, java.io.File aside) {
        try { rm(staged); } catch (Throwable ignore) {}
        try { rm(aside); } catch (Throwable ignore) {}
    }

    /** Copy the tree from into to (to must not exist). False on any failure. */
    private static boolean copy(java.io.File from, java.io.File to) {
        try {
            if (from.isDirectory()) {
                if (!to.mkdirs()) return false;
                java.io.File[] kids = from.listFiles();
                if (kids == null) return false;
                for (java.io.File k : kids) if (!copy(k, new java.io.File(to, k.getName()))) return false;
                return true;
            }
            java.nio.file.Files.copy(from.toPath(), to.toPath());
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    /** Recursively delete a file/dir tree (best-effort), as ProfileActivity.rmTree does. */
    private static void rm(java.io.File f) {
        if (f == null) return;
        java.io.File[] kids = f.listFiles();
        if (kids != null) for (java.io.File k : kids) rm(k);
        try { f.delete(); } catch (Throwable ignore) {}
    }
}
