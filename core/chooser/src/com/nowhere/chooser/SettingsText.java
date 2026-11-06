package com.nowhere.chooser;

/** NWP-20261111-17: the Profile screen's three read-modify-write settings files (nowhere-config,
 *  nowhere-media-tiers, nowhere-pins), read strictly. read() tells an ABSENT file ("") from one that exists and
 *  could not be read (null), so a writer refuses instead of rewriting -- or, for the tiers, deleting -- the whole
 *  file from an empty read. The parsers are the rules readConfig/readTiers/readPins applied, moved unchanged.
 *  java.* only, so it runs under plain javac (core/vendor-common/bin/test-settings-text-java.sh). */
final class SettingsText {
    private SettingsText() {}

    /** "" when the file is absent, its whole text (each line ended by '\n') when readable, null when it exists
     *  but could not be opened or read whole (EIO, a wrong owner after a restore, a directory at the path). */
    static String read(java.io.File f) {
        if (!f.exists()) return "";
        StringBuilder sb = new StringBuilder();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.FileReader(f))) {
            String ln;
            while ((ln = r.readLine()) != null) sb.append(ln).append('\n');
        } catch (Throwable t) {
            return null;
        }
        return sb.toString();
    }

    /** nowhere-config: key=value per line; '#', blank and eq<=0 lines skipped; both sides trimmed. */
    static java.util.LinkedHashMap<String,String> parseConfig(String text) {
        java.util.LinkedHashMap<String,String> m = new java.util.LinkedHashMap<>();
        try (java.io.BufferedReader br = new java.io.BufferedReader(new java.io.StringReader(text == null ? "" : text))) {
            String ln;
            while ((ln = br.readLine()) != null) {
                ln = ln.trim();
                int eq = ln.indexOf('=');
                if (ln.isEmpty() || ln.startsWith("#") || eq <= 0) continue;
                m.put(ln.substring(0, eq).trim(), ln.substring(eq + 1).trim());
            }
        } catch (java.io.IOException unreachable) { // a StringReader does not throw
        }
        return m;
    }

    /** nowhere-media-tiers: "<app> <tier>" per line, split on the first space; '#', blank and space-less lines
     *  skipped; both sides trimmed. */
    static java.util.LinkedHashMap<String,String> parseTiers(String text) {
        java.util.LinkedHashMap<String,String> m = new java.util.LinkedHashMap<>();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.StringReader(text == null ? "" : text))) {
            String ln;
            while ((ln = r.readLine()) != null) {
                ln = ln.trim();
                if (ln.isEmpty() || ln.startsWith("#")) continue;
                int sp = ln.indexOf(' ');
                if (sp <= 0) continue;
                m.put(ln.substring(0, sp).trim(), ln.substring(sp + 1).trim());
            }
        } catch (java.io.IOException unreachable) { // a StringReader does not throw
        }
        return m;
    }

    /** nowhere-pins: one app segment per line, trimmed; blank lines skipped. */
    static java.util.LinkedHashSet<String> parsePins(String text) {
        java.util.LinkedHashSet<String> s = new java.util.LinkedHashSet<>();
        try (java.io.BufferedReader r = new java.io.BufferedReader(new java.io.StringReader(text == null ? "" : text))) {
            String ln;
            while ((ln = r.readLine()) != null) { ln = ln.trim(); if (!ln.isEmpty()) s.add(ln); }
        } catch (java.io.IOException unreachable) { // a StringReader does not throw
        }
        return s;
    }
}
