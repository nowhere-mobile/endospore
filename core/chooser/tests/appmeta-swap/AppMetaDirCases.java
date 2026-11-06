package com.nowhere.chooser;

/** NWP-20261125-18: executes AppMetaDir on real temp dirs under java.io.tmpdir (test-appmeta-swap-java.sh). */
public final class AppMetaDirCases {
    interface Case { void run(java.io.File files) throws Throwable; }
    static final String P = "com.example.app";
    static final String GOOD = "vc\t7\ntsdk\t33\ncert\tQUFB\nact\tcom.example.app/.Main\tExample\n";
    static int bad = 0;
    static int caseBad;

    // run: one case id on a fresh files/ dir, in its own try/catch, then the layout check on that dir.
    static void run(String id, String what, Case c) {
        caseBad = 0;
        java.io.File files = null;
        try {
            files = java.nio.file.Files.createTempDirectory("files").toFile();
            c.run(files);
            assertClean(id, files);
        } catch (Throwable t) { System.out.println("FAIL " + id + " threw " + t); caseBad++; }
        if (caseBad == 0) System.out.println("ok " + id + " " + what);
        bad += caseBad;
        rm(files);
    }
    static void eq(String id, String what, Object want, Object got) {
        if (java.util.Objects.equals(want, got)) return;
        System.out.println("FAIL " + id + " " + what + ": want " + want + ", got " + got);
        caseBad++;
    }

    static java.io.File appmeta(java.io.File files) { return new java.io.File(files, "nowhere-appmeta"); }
    static java.io.File target(java.io.File files) { return new java.io.File(appmeta(files), P); }
    static java.io.File staging(java.io.File files) { return AppMetaDir.stagingFor(files, P); }
    static java.io.File aside(java.io.File files) { return AppMetaDir.asideFor(files, P); }

    static void write(java.io.File dir, String name, String text) throws java.io.IOException {
        dir.mkdirs();
        java.nio.file.Files.write(new java.io.File(dir, name).toPath(),
                text.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
    // an old, published snapshot: meta + two icons.
    static void old(java.io.File files) throws java.io.IOException {
        java.io.File t = target(files);
        write(t, "meta", "vc\t5\ncert\tT0xE\nact\tcom.example.app/.Main\tOld\nact\tcom.example.app/.Two\tTwo\n");
        write(t, "0.png", "old-icon-0");
        write(t, "1.png", "old-icon-1");
    }
    // snap: every file under dir as "relative path=bytes", sorted; "<absent>" for no dir.
    static String snap(java.io.File dir) throws java.io.IOException {
        if (!dir.exists()) return "<absent>";
        java.util.TreeMap<String, String> m = new java.util.TreeMap<>();
        walk(dir, "", m);
        return m.toString();
    }
    static void walk(java.io.File f, String rel, java.util.Map<String, String> m) throws java.io.IOException {
        java.io.File[] kids = f.listFiles();
        if (kids == null) {
            m.put(rel, new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8));
            return;
        }
        m.put(rel + "/", "");
        for (java.io.File k : kids) walk(k, rel + "/" + k.getName(), m);
    }
    // assertClean: nowhere-appmeta holds only <pkg> dirs, and no staging or aside dir of P is left.
    static void assertClean(String id, java.io.File files) {
        java.io.File[] kids = appmeta(files).listFiles();
        if (kids != null) for (java.io.File k : kids)
            if (!k.isDirectory() || !P.equals(k.getName()))
                { System.out.println("FAIL " + id + " nowhere-appmeta holds " + k.getName()); caseBad++; }
        if (staging(files).exists()) { System.out.println("FAIL " + id + " a staging dir is left"); caseBad++; }
        if (aside(files).exists()) { System.out.println("FAIL " + id + " an aside dir is left"); caseBad++; }
    }
    // incompleteKeepsOld: an incomplete staged snapshot over an old one -> false, the old dir byte for byte.
    static void incompleteKeepsOld(String id, java.io.File files, java.io.File staged) throws Throwable {
        old(files);
        String before = snap(target(files));
        eq(id, "publish", false, AppMetaDir.publish(target(files), staged, aside(files)));
        eq(id, "old dir byte for byte", before, snap(target(files)));
    }
    // raisable: what the sign-out seal hands the next sign-in, checked right after publish returns. roamd's appcode_seal
    // copies nowhere-appmeta/<pkg> to <pkg>/_meta only when it is a dir ([ -d ] && cp -r); installArchivedPlaceholder
    // then needs _meta/meta as a file with a cert and an act line. cert is the cert the snapshot must carry.
    static void raisable(String id, java.io.File files, String cert) throws java.io.IOException {
        java.io.File sealed = new java.io.File(new java.io.File(files, "sealed"), "_meta");
        if (target(files).isDirectory()) copyTree(target(files), sealed);
        java.io.File m = new java.io.File(sealed, "meta");
        if (!m.isFile()) { System.out.println("FAIL " + id + " the seal holds no _meta/meta"); caseBad++; }
        else {
            AppCodeManifest.Meta mm = AppCodeManifest.parseMeta(new String(java.nio.file.Files.readAllBytes(m.toPath()),
                    java.nio.charset.StandardCharsets.UTF_8));
            eq(id, "sealed certs", java.util.Collections.singletonList(cert), mm.certs);
            eq(id, "sealed act lines present", true, !mm.acts.isEmpty());
        }
        rm(sealed.getParentFile());
    }
    static void copyTree(java.io.File from, java.io.File to) throws java.io.IOException {
        if (from.isDirectory()) {
            to.mkdirs();
            for (java.io.File k : from.listFiles()) copyTree(k, new java.io.File(to, k.getName()));
        } else java.nio.file.Files.copy(from.toPath(), to.toPath());
    }
    static void rm(java.io.File f) {
        if (f == null) return;
        java.io.File[] kids = f.listFiles();
        if (kids != null) for (java.io.File k : kids) rm(k);
        f.delete();
    }

    public static void main(String[] a) {
        run("C1", "a complete snapshot replaces the old one whole", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            write(staging(f), "0.png", "new-icon-0");
            eq("C1", "publish", true, AppMetaDir.publish(target(f), staging(f), aside(f)));
            eq("C1", "target", "{/=, /0.png=new-icon-0, /meta=" + GOOD + "}", snap(target(f)));
        });
        run("C2", "a staged meta with no cert line keeps the old dir", f -> {
            write(staging(f), "meta", "vc\t7\nact\tcom.example.app/.Main\tExample\n");
            write(staging(f), "0.png", "new-icon-0");
            incompleteKeepsOld("C2", f, staging(f));
        });
        run("C3", "a staged dir with no meta file keeps the old dir", f -> {
            write(staging(f), "0.png", "new-icon-0");
            incompleteKeepsOld("C3", f, staging(f));
        });
        run("C4", "a staged meta whose only cert is empty keeps the old dir", f -> {
            write(staging(f), "meta", "vc\t7\ncert\t \n");
            incompleteKeepsOld("C4", f, staging(f));
        });
        run("C5", "a staged meta with a cert but no vc line keeps the old dir", f -> {
            write(staging(f), "meta", "cert\tQUFB\n");
            incompleteKeepsOld("C5", f, staging(f));
        });
        run("C6", "no old dir: an incomplete snapshot is published as built", f -> {
            write(staging(f), "meta", "vc\t7\n");
            write(staging(f), "0.png", "new-icon-0");
            eq("C6", "publish", true, AppMetaDir.publish(target(f), staging(f), aside(f)));
            eq("C6", "target", "{/=, /0.png=new-icon-0, /meta=vc\t7\n}", snap(target(f)));
        });
        run("C7", "no nowhere-appmeta at all: a complete snapshot creates it", f -> {
            write(staging(f), "meta", GOOD);
            eq("C7", "publish", true, AppMetaDir.publish(target(f), staging(f), aside(f)));
            eq("C7", "target", "{/=, /meta=" + GOOD + "}", snap(target(f)));
        });
        run("C8", "a staged path that does not exist (a failed rename) keeps the old dir", f -> {
            incompleteKeepsOld("C8", f, staging(f));
            eq("C8", "no old dir either", false,
                    AppMetaDir.publish(new java.io.File(appmeta(f), "absent"), staging(f), aside(f)));
        });
        run("C9", "the meta rename fails: the old dir is put back byte for byte, and it stays raisable", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            write(staging(f), "0.png", "new-icon-0");
            String before = snap(target(f));
            java.io.File sm = new java.io.File(staging(f), "meta");
            eq("C9", "publish", false, AppMetaDir.publish(target(f), staging(f), aside(f),
                    (from, to) -> !from.equals(sm) && from.renameTo(to)));
            eq("C9", "old dir byte for byte", before, snap(target(f)));
            raisable("C9", f, "T0xE");
        });
        run("C10", "the first old-icon move fails: the old dir stays byte for byte", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            String before = snap(target(f));
            java.io.File t = target(f);
            eq("C10", "publish", false, AppMetaDir.publish(t, staging(f), aside(f),
                    (from, to) -> !from.getParentFile().equals(t) && from.renameTo(to)));
            eq("C10", "old dir byte for byte", before, snap(target(f)));
            raisable("C10", f, "T0xE");
        });
        run("C11", "complete: vc 0 and CRLF lines count; no meta, or a meta dir, does not", f -> {
            java.io.File s = staging(f);
            write(s, "meta", "vc\t0\ncert\tQUFB\n");
            eq("C11", "vc 0", true, AppMetaDir.complete(s));
            write(s, "meta", "vc\t7\r\ncert\tQUFB\r\n");
            eq("C11", "CRLF", true, AppMetaDir.complete(s));
            write(s, "meta", "vc\tjunk\ncert\tQUFB\n");
            eq("C11", "vc junk", false, AppMetaDir.complete(s));
            new java.io.File(s, "meta").delete();
            eq("C11", "no meta", false, AppMetaDir.complete(s));
            new java.io.File(s, "meta").mkdirs();
            eq("C11", "meta is a dir", false, AppMetaDir.complete(s));
            eq("C11", "no staged dir", false, AppMetaDir.complete(new java.io.File(f, "nothing")));
            AppMetaDir.clear(s, null);
        });
        run("C12", "staging and aside live outside nowhere-appmeta; clear removes leftovers of both", f -> {
            String am = appmeta(f).getCanonicalPath() + java.io.File.separator;
            for (java.io.File d : new java.io.File[]{staging(f), aside(f)}) {
                eq("C12", d + " outside nowhere-appmeta", false, d.getCanonicalPath().startsWith(am));
                eq("C12", d + " last name", P, d.getName());
                eq("C12", d + " not nowhere-appmeta itself", false,
                        d.getParentFile().getCanonicalPath().equals(appmeta(f).getCanonicalPath()));
            }
            old(f);
            String before = snap(target(f));
            write(staging(f), "meta", GOOD);
            write(aside(f), "0.png", "old-icon-0");
            AppMetaDir.clear(staging(f), aside(f));
            eq("C12", "staging cleared", false, staging(f).exists());
            eq("C12", "aside cleared", false, aside(f).exists());
            eq("C12", "target untouched by clear", before, snap(target(f)));
            AppMetaDir.clear(null, null);
        });
        run("C13", "a throw in the swap: the old dir is put back byte for byte", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            write(staging(f), "0.png", "new-icon-0");
            String before = snap(target(f));
            java.io.File st = staging(f), t = target(f), sm = new java.io.File(st, "meta");
            eq("C13", "meta rename throws", false, AppMetaDir.publish(t, st, aside(f), (from, to) -> {
                if (from.equals(sm)) throw new SecurityException("C13");
                return from.renameTo(to);
            }));
            eq("C13", "old dir byte for byte after a meta-rename throw", before, snap(t));
            raisable("C13", f, "T0xE");
            write(st, "meta", GOOD);
            write(st, "0.png", "new-icon-0");
            eq("C13", "a new icon move throws", false, AppMetaDir.publish(t, st, aside(f), (from, to) -> {
                if (from.getParentFile().equals(st)) throw new SecurityException("C13b");
                return from.renameTo(to);
            }));
            eq("C13", "old dir byte for byte after an icon-move throw", before, snap(t));
            raisable("C13", f, "T0xE");
        });
        run("C14", "the meta rename and every rename back fail: the old icons are copied back", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            String before = snap(target(f));
            java.io.File t = target(f);
            eq("C14", "publish", false, AppMetaDir.publish(t, staging(f), aside(f),
                    (from, to) -> from.getParentFile().equals(t) && from.renameTo(to)));
            eq("C14", "old dir byte for byte", before, snap(t));
            raisable("C14", f, "T0xE");
        });
        run("C15", "the meta rename and every rename after it fail: right after publish, the seal finds the old meta", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            write(staging(f), "0.png", "new-icon-0");
            java.io.File t = target(f), sm = new java.io.File(staging(f), "meta");
            String before = snap(t);
            boolean[] down = {false};
            eq("C15", "publish", false, AppMetaDir.publish(t, staging(f), aside(f), (from, to) -> {
                if (from.equals(sm)) down[0] = true;
                return !down[0] && from.renameTo(to);
            }));
            eq("C15", "target is a dir", true, t.isDirectory());
            eq("C15", "the old dir byte for byte", before, snap(t));
            raisable("C15", f, "T0xE");
        });
        run("C16", "the meta rename and every rename and copy back fail: the old icons wait in aside, never deleted", f -> {
            old(f);
            write(staging(f), "meta", GOOD);
            write(staging(f), "0.png", "new-icon-0");
            java.io.File t = target(f), st = staging(f), sm = new java.io.File(st, "meta"), as = aside(f);
            String before = snap(t);
            String oldMeta = new String(java.nio.file.Files.readAllBytes(new java.io.File(t, "meta").toPath()),
                    java.nio.charset.StandardCharsets.UTF_8);
            eq("C16", "publish", false, AppMetaDir.publish(t, st, as,
                    (from, to) -> !from.equals(sm) && !from.getParentFile().equals(as) && from.renameTo(to),
                    (from, to) -> false));
            // right after publish returns: the published dir holds the old meta and no new icon; the old icons are
            // all in aside, with the copy of the meta they belong to. This is the one case where target cannot stay
            // byte for byte: the old icons left target before the meta rename failed, and every primitive that could
            // put them back (a rename, a copy) fails. java.io and android.system.Os have no atomic swap of two
            // non-empty dirs, so no ordering avoids it; the old meta stays, so the placeholder stays raisable
            // (moderator amendment, 2026-11-03, RF-001). publish returns false, and S6 pins that captureArchivedMeta
            // logs that "swap failed".
            eq("C16", "target right after publish", "{/=, /meta=" + oldMeta + "}", snap(t));
            raisable("C16", f, "T0xE");
            eq("C16", "aside holds every old icon", "{/=, /0.png=old-icon-0, /1.png=old-icon-1, /meta=" + oldMeta + "}",
                    snap(as));
            eq("C16", "a failing recover keeps aside", false,
                    AppMetaDir.recover(t, as, (from, to) -> false, (from, to) -> false));
            eq("C16", "aside after a failing recover",
                    "{/=, /0.png=old-icon-0, /1.png=old-icon-1, /meta=" + oldMeta + "}", snap(as));
            eq("C16", "recover", true, AppMetaDir.recover(t, as));
            eq("C16", "old dir byte for byte after recover", before, snap(t));
            eq("C16", "aside gone after recover", false, as.exists());
        });
        run("C17", "a stale aside is discarded; a held one blocks the swap until recover puts it back", f -> {
            old(f);
            java.io.File t = target(f), as = aside(f), st = staging(f);
            String before = snap(t);
            write(as, "meta", "vc\t9\ncert\tTkVX\n");
            write(as, "0.png", "stale-icon-0");
            eq("C17", "recover of a stale aside", true, AppMetaDir.recover(t, as));
            eq("C17", "target untouched by a stale aside", before, snap(t));
            eq("C17", "stale aside gone", false, as.exists());
            write(as, "meta", new String(java.nio.file.Files.readAllBytes(new java.io.File(t, "meta").toPath()),
                    java.nio.charset.StandardCharsets.UTF_8));
            write(as, "2.png", "held-icon-2");
            write(st, "meta", GOOD);
            write(st, "0.png", "new-icon-0");
            eq("C17", "publish while the held icon cannot come back", false,
                    AppMetaDir.publish(t, st, as, (from, to) -> !from.getParentFile().equals(as) && from.renameTo(to),
                            (from, to) -> false));
            eq("C17", "target untouched while held", before, snap(t));
            eq("C17", "the held icon is still in aside", true, new java.io.File(as, "2.png").isFile());
            eq("C17", "recover", true, AppMetaDir.recover(t, as));
            eq("C17", "the held icon is back", "held-icon-2",
                    new String(java.nio.file.Files.readAllBytes(new java.io.File(t, "2.png").toPath()),
                            java.nio.charset.StandardCharsets.UTF_8));
            new java.io.File(t, "2.png").delete();
            eq("C17", "target otherwise as before", before, snap(t));
        });
        if (bad > 0) System.exit(1);
    }
}
