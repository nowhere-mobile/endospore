package com.nowhere.chooser;

/** NWP-20261121-05: the sign-in's two app-code restore parses, lifted verbatim out of ChooserActivity so a javac
 *  suite (test-appcode-manifest-java.sh) can compile this class alone and execute them. Pure java.*.
 *
 *  1. files/.appcode/manifest.tsv, one row per kept app. Writers: roamd's appcode_seal (nowhere_roamd.sh) and the
 *     worker's catalog fetch (core/agent/catalog.go, which appends one row). Reader: ChooserActivity.installRoamedAppCode.
 *       pkg  versionCode  sideloaded  mode  apk1 [apk2 ...]  [group:<name>]
 *     mode is installed | ondemand | auto (appcode_seal writes an unknown mode as installed). Back-compat: a pre-mode
 *     row has an APK basename in column 4, not a mode word, so it reads as installed with APKs from column 4. The
 *     group token rides after the APK names; the FIRST one wins. Do NOT reuse AppCodeLine.groupOf here: that parser
 *     reads the other list (nowhere-appcode.list) with a different rule (last field only, an empty name is null).
 *
 *  2. .appcode/<pkg>/_meta/meta, the sealed ArchivedPackageInfo snapshot of a deferred app. Writer:
 *     ProfileActivity.captureArchivedMeta. Readers: ChooserActivity.hasLauncherMeta and installArchivedPlaceholder.
 *       vc \t <versionCode>   tsdk \t <targetSdk>   cert \t <base64 DER>   act \t <flatComponent> \t <label>
 *       inst \t <installer package>
 *     NWP-20261128-20 (h50 #3): captureArchivedMeta writes the inst line (installerToRecord); its reader is
 *     installer(), called by OlderCopy.playCount at the Auto sweep's end and OlderCopy.rowState for a Your apps row
 *     (NWP-20261130-07). parseMeta ignores it. */
final class AppCodeManifest {
    private AppCodeManifest() {}

    static final String MODE_INSTALLED = "installed";
    static final String MODE_ONDEMAND  = "ondemand";
    static final String MODE_AUTO      = "auto";

    private static boolean isMode(String w) {
        return MODE_INSTALLED.equals(w) || MODE_ONDEMAND.equals(w) || MODE_AUTO.equals(w); // #130
    }

    /** One manifest.tsv row. apks are the basenames, in order; group may be null (no token, no default group). */
    static final class Row {
        final String pkg, mode;
        final boolean deferred;
        final String group;
        final java.util.List<String> apks;
        private Row(String pkg, String mode, boolean deferred, String group, java.util.List<String> apks) {
            this.pkg = pkg; this.mode = mode; this.deferred = deferred; this.group = group; this.apks = apks;
        }
    }

    /** Null for an empty line or one with fewer than 4 tab fields. defaultGroup answers for a row with no group
     *  token (ProfileActivity::defaultGroupFor at the sign-in). */
    static Row parseRow(String line, java.util.function.Function<String, String> defaultGroup) {
        if (line == null || line.isEmpty()) return null;
        String[] f = line.split("\t", -1);
        if (f.length < 4) return null;
        String pkg = f[0];
        boolean hasMode = isMode(f[3]);
        String mode = hasMode ? f[3] : MODE_INSTALLED;
        int apkStart = hasMode ? 4 : 3;
        // group-materialize: an optional trailing `group:<name>` token rides after the apk basenames.
        // Fall back to the built-in DEFAULT_GROUPS (GMS set) so the feature works with no manifest token.
        String group = null;
        for (int i = apkStart; i < f.length; i++)
            if (f[i].startsWith("group:")) { group = f[i].substring(6).trim(); break; }
        if (group == null) group = defaultGroup.apply(pkg);
        java.util.List<String> apks = new java.util.ArrayList<>();
        for (int i = apkStart; i < f.length; i++) {
            if (f[i].isEmpty() || f[i].startsWith("group:")) continue; // group token is not an apk
            apks.add(f[i]);
        }
        boolean deferred = MODE_ONDEMAND.equals(mode) || MODE_AUTO.equals(mode);
        return new Row(pkg, mode, deferred, group, java.util.Collections.unmodifiableList(apks));
    }

    /** True if the meta text has at least one launcher activity (an `act` line with 3+ fields). */
    static boolean hasLauncherLine(String metaText) {
        for (String line : lines(metaText)) {
            String[] f = line.split("\t", -1);
            if (f.length >= 3 && "act".equals(f[0])) return true;
        }
        return false;
    }

    /** The parsed meta. vc and tsdk are 0 when absent or not a number; certs stay base64 (the caller decodes);
     *  each act is {flatComponent, label}. */
    static final class Meta {
        final int vc, tsdk;
        final java.util.List<String> certs;
        final java.util.List<String[]> acts;
        private Meta(int vc, int tsdk, java.util.List<String> certs, java.util.List<String[]> acts) {
            this.vc = vc; this.tsdk = tsdk; this.certs = certs; this.acts = acts;
        }
    }

    static Meta parseMeta(String metaText) {
        int vc = 0, tsdk = 0;
        java.util.List<String> certs = new java.util.ArrayList<>();
        java.util.List<String[]> acts = new java.util.ArrayList<>(); // {flatComponent, label}
        for (String line : lines(metaText)) {
            String[] f = line.split("\t", -1);
            if (f.length < 2) continue;
            if ("vc".equals(f[0])) { try { vc = (int) Long.parseLong(f[1].trim()); } catch (Throwable ignore) {} }
            else if ("tsdk".equals(f[0])) { try { tsdk = Integer.parseInt(f[1].trim()); } catch (Throwable ignore) {} }
            else if ("cert".equals(f[0])) certs.add(f[1]);
            else if ("act".equals(f[0]) && f.length >= 3) acts.add(new String[]{f[1], f[2]});
        }
        return new Meta(vc, tsdk, java.util.Collections.unmodifiableList(certs),
                java.util.Collections.unmodifiableList(acts));
    }

    private static final java.util.regex.Pattern PKG_NAME =
            java.util.regex.Pattern.compile("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+");

    /** A valid package name: two or more segments, at most 255 chars. A tab, newline or space refuses it. */
    private static boolean isPackageName(String s) {
        return s != null && s.length() <= 255 && PKG_NAME.matcher(s).matches();
    }

    /** NWP-20261128-20 (h50 #3): the value of the first `inst` line that is a valid package name, else null. The
     *  value is the whole rest of the line, so a second tab refuses it. */
    static String installer(String metaText) {
        for (String line : lines(metaText)) {
            if (!line.startsWith("inst\t")) continue;
            String v = line.substring(5);
            if (isPackageName(v)) return v;
        }
        return null;
    }

    /** NWP-20261128-20 (h50 #3): the installer the sign-out records. current (the app's installer now) when it is a
     *  valid package name other than own (the chooser); else the previous meta's installer, so an app the chooser
     *  re-installed from the sealed copy keeps the store it came from; else null (no inst line). */
    static String installerToRecord(String current, String own, String previousMetaText) {
        if (isPackageName(current) && !current.equals(own)) return current;
        return installer(previousMetaText);
    }

    /** The archived install is REJECTED (INSTALL_FAILED_DEPRECATED_SDK_VERSION -- "found 0") unless the package
     *  declares a target SDK >= 24; proven on lynx 2026-07-25. Use the captured value; floor at 24 for a pre-tsdk
     *  _meta (the real APK's own targetSdk takes over when it's materialised + installed on tap). */
    static int targetSdkFor(int tsdk) {
        return tsdk >= 24 ? tsdk : 24;
    }

    /** The lines of text as BufferedReader.readLine splits a file (\n, \r or \r\n); none for null. */
    private static java.util.List<String> lines(String text) {
        java.util.List<String> out = new java.util.ArrayList<>();
        if (text == null) return out;
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader(text))) {
            String line;
            while ((line = br.readLine()) != null) out.add(line);
        } catch (java.io.IOException e) {
            throw new java.io.UncheckedIOException(e); // a StringReader never throws
        }
        return out;
    }
}
