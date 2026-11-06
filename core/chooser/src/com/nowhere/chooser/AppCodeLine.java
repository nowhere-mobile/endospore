package com.nowhere.chooser;

/** NWP-20261119-10: one line of files/nowhere-appcode.list, and the one lock its writers hold.
 *
 *  The list has TWO writers since this slice: ProfileActivity.captureAppCode rewrites the whole file at sign-out,
 *  and AppInstallReceiver.recaptureCode rewrites ONE package's line in a session, when a kept app is installed or
 *  updated (backlog row "A periodic seal's `#apps` staging spends two to three minutes staging nothing: ..."). Both
 *  build their lines here, so the two can never drift apart. Pure java.*, so the javac suite
 *  (test-app-code-line-java.sh) compiles it alone.
 *
 *  The line, tab-separated, which roamd's appcode_seal reads (col4 = mode, col5 = base.apk):
 *    pkg  vc  sideloaded(0|1)  mode  base.apk  [split ...]  [group:<name>]
 *  The group token is optional and always LAST; an APK path starts with '/', so it is never read as a path.
 *
 *  A package's line is the one whose FIELD 1 equals the package name, whole-field: com.a never matches com.ab.
 *
 *  LOCK: StoreInstaller.writeAtomic writes "<name>.tmp" beside its target, so two writers of one file share that
 *  temp name and can tear or rename each other's temp; and captureArchivedMeta builds nowhere-appmeta/<pkg> aside and
 *  swaps the dir in while captureAppCode's meta prune walks the same dir. So both writers hold LOCK for their whole
 *  read-modify-write. */
final class AppCodeLine {
    private AppCodeLine() {}

    /** The one lock both writers of nowhere-appcode.list (and of nowhere-appmeta) hold. */
    static final Object LOCK = new Object();

    /** One package's line, with NO trailing newline. A null or empty split is skipped; a null or empty group
     *  writes no group token. */
    static String build(String pkg, long vc, boolean sideloaded, String mode,
                        String sourceDir, String[] splits, String group) {
        StringBuilder sb = new StringBuilder();
        sb.append(pkg).append('\t').append(vc).append('\t').append(sideloaded ? '1' : '0');
        sb.append('\t').append(mode);
        sb.append('\t').append(sourceDir); // base.apk
        if (splits != null)
            for (String sp : splits) if (sp != null && !sp.isEmpty()) sb.append('\t').append(sp);
        if (group != null && !group.isEmpty()) sb.append('\t').append("group:").append(group);
        return sb.toString();
    }

    /** Field 1 of a line (no terminator): up to the first tab, or the whole line. */
    private static String field1(String line) {
        int t = line.indexOf('\t');
        return t < 0 ? line : line.substring(0, t);
    }

    /** The first line of text whose field 1 is exactly pkg, without its terminator; null when there is none. */
    static String lineOf(String text, String pkg) {
        if (text == null || pkg == null) return null;
        int i = 0, n = text.length();
        while (i < n) {
            int nl = text.indexOf('\n', i);
            int end = nl < 0 ? n : nl;
            String ln = text.substring(i, end);
            if (field1(ln).equals(pkg)) return ln;
            i = nl < 0 ? n : nl + 1;
        }
        return null;
    }

    /** The name in a line's trailing group: token; null for a null line, no token, or an empty name. */
    static String groupOf(String line) {
        if (line == null) return null;
        int t = line.lastIndexOf('\t');
        if (t < 0) return null;
        String last = line.substring(t + 1);
        if (!last.startsWith("group:")) return null;
        String g = last.substring("group:".length());
        return g.isEmpty() ? null : g;
    }

    /** text with pkg's line replaced by line, or line appended when pkg has none. The FIRST matching line takes the
     *  new line and keeps its own terminator; a later line for the same package is removed (two lines would make
     *  roamd stage the package twice). Every other line is copied byte for byte, terminator included: no trim, no
     *  reorder. An append after an unterminated last line adds the '\n' that line lacked first. */
    static String replaceIn(String text, String pkg, String line) {
        if (text == null) text = "";
        StringBuilder sb = new StringBuilder(text.length() + line.length() + 1);
        boolean done = false;
        int i = 0, n = text.length();
        while (i < n) {
            int nl = text.indexOf('\n', i);
            int end = nl < 0 ? n : nl;
            int next = nl < 0 ? n : nl + 1;
            if (field1(text.substring(i, end)).equals(pkg)) {
                if (!done) { sb.append(line).append(text, end, next); done = true; }
            } else {
                sb.append(text, i, next);
            }
            i = next;
        }
        if (!done) {
            if (sb.length() > 0 && sb.charAt(sb.length() - 1) != '\n') sb.append('\n');
            sb.append(line).append('\n');
        }
        return sb.toString();
    }

    /** NWP-20261123-12: the old code list's lines keyed by field 1, for captureAppCode's DIA-20260726-08
     *  carry-forward. text is SettingsText.read of the list: null (the list exists but could not be read whole)
     *  gives null, unknown and never "no old lines"; "" (absent) gives an empty map. A line counts only when its
     *  first tab is at index > 0; a later line for the same package wins. The loop captureAppCode ran, moved
     *  unchanged. */
    static java.util.Map<String,String> oldLinesByPkg(String text) {
        if (text == null) return null;
        java.util.HashMap<String,String> m = new java.util.HashMap<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader(text))) {
            String ln;
            while ((ln = br.readLine()) != null) {
                int t = ln.indexOf('\t');
                if (t > 0) m.put(ln.substring(0, t), ln);
            }
        } catch (java.io.IOException unreachable) { // a StringReader does not throw
        }
        return m;
    }
}
