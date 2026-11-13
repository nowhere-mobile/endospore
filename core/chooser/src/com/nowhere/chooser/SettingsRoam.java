package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Predicate;
import java.util.regex.Pattern;

/**
 * NWP-20261130-12 (Q012 and #70, docs/product-decisions.md 2026-10-20 and 2026-10-22): the curated per-user settings
 * roam. Roamd captures each row of the allowlist at seal into the sibling file nowhere-settings-roam (never new
 * nowhere-prefs keys) and surfaces its rows as sroam= lines in GET-PREFS. The chooser replays them here, row by row,
 * through the live provider, as the one writer of a restore. A later slice adds a row to settings-roam.list, not code.
 *
 * A custom tile (custom(pkg/cls)) is package-keyed. When its package is not installed at apply time it is left out of
 * the live value, and it stays stored: the TILES_KEY row holds the whole list with that tile marked ?. The seal puts a
 * marked tile back into the record (sroam_merge_tiles), and reconcile() puts it into the live value when the package
 * lands. No behaviour here depends on how SystemUI treats a live custom tile with no package.
 *
 * APPLIED_KEY tells the seal that the live rows are this profile's. The apply sets it last, and only after no failed put
 * and no malformed value, because a seal before it would replace the record with SystemUI's default for good.
 *
 * Pure java.util, so a javac suite compiles it off the build host (core/vendor-common/bin/test-settings-roam.sh). Text
 * moves only through split and String.join: $ is legal in a class name and is a group reference in a regex replacement.
 * Nothing here logs. Result holds counts, because a tile list names installed apps.
 */
final class SettingsRoam {
    private SettingsRoam() {}

    static final String PREF_PREFIX = "sroam=";
    static final String APPLIED_KEY = "nowhere_sroam_applied";
    static final String TILES_KEY = "nowhere_sroam_tiles";
    static final String LIST_PATH = "/system/etc/nowhere/settings-roam.list";
    static final String KIND_TILES = "tiles";
    private static final String SECURE = "secure";
    private static final String SYSTEM = "system";
    private static final String CUSTOM_PREFIX = "custom(";
    static final int TILE_VALUE_MAX = 8192;
    // roamd's sroam_tiles_valid is the same set; test-settings-roam.sh's P1 compares them for every printable character.
    static final Pattern TILE_VALUE = Pattern.compile("[A-Za-z0-9_./(),$-]+");
    private static final Pattern KEY = Pattern.compile("[A-Za-z0-9_]+");

    /** The live provider for the session's user. A false put is a failed put. */
    interface Store {
        String get(String scope, String key);
        boolean put(String scope, String key, String value);
    }

    static final class Row {
        final String scope;
        final String key;
        final String kind; // null for a plain value

        Row(String scope, String key, String kind) {
            this.scope = scope;
            this.key = key;
            this.kind = kind;
        }
    }

    /** Counts only: this is what the sign-in logs. */
    static final class Result {
        int rows;
        int applied;
        int failed;
        int malformed;
        int waiting;
        boolean marked;
    }

    /** The list's row grammar: <scope> <key> [<kind>]. Roamd's sroam_row_ok holds the same rule. */
    static List<Row> parseList(List<String> lines) {
        List<Row> rows = new ArrayList<>();
        if (lines == null) return rows;
        for (String line : lines) {
            String t = line == null ? "" : line.trim();
            if (t.isEmpty()) continue;
            String[] f = t.split("\\s+");
            if (f.length < 2 || f.length > 3) continue;
            if (!SECURE.equals(f[0]) && !SYSTEM.equals(f[0])) continue;
            if (!KEY.matcher(f[1]).matches()) continue;
            String kind = f.length == 3 ? f[2] : null;
            if (kind != null && !KIND_TILES.equals(kind)) continue;
            rows.add(new Row(f[0], f[1], kind));
        }
        return rows;
    }

    static boolean tilesValid(String value) {
        return value != null && value.length() <= TILE_VALUE_MAX && TILE_VALUE.matcher(value).matches();
    }

    /** The package of custom(pkg/cls), or null when the tile is not a custom one. */
    static String customPackage(String tile) {
        if (!tile.startsWith(CUSTOM_PREFIX) || !tile.endsWith(")")) return null;
        int slash = tile.indexOf('/');
        return slash <= CUSTOM_PREFIX.length() ? null : tile.substring(CUSTOM_PREFIX.length(), slash);
    }

    private static boolean isWaiting(String tile) {
        return tile.startsWith("?");
    }

    private static String bare(String tile) {
        return isWaiting(tile) ? tile.substring(1) : tile;
    }

    private static String[] tiles(String list) {
        return list.split(",", -1);
    }

    /** The stored list with each custom tile whose package is not installed marked ?. */
    static String pendingFor(String stored, Predicate<String> installed) {
        List<String> out = new ArrayList<>();
        for (String t : tiles(stored)) {
            String pkg = customPackage(t);
            out.add(pkg != null && !installed.test(pkg) ? "?" + t : t);
        }
        return String.join(",", out);
    }

    /** The annotated list without its waiting tiles: the value for the live row. */
    static String liveOf(String annotated) {
        List<String> out = new ArrayList<>();
        for (String t : tiles(annotated)) if (!isWaiting(t) && !t.isEmpty()) out.add(t);
        return String.join(",", out);
    }

    private static int waitingIn(String annotated) {
        int n = 0;
        for (String t : tiles(annotated)) if (isWaiting(t)) n++;
        return n;
    }

    private static Row onList(List<Row> rows, String scope, String key) {
        for (Row r : rows) if (r.scope.equals(scope) && r.key.equals(key)) return r;
        return null;
    }

    /**
     * Replay the surfaced rows. lines is the GET-PREFS reply, or null for a failed read. A null read or an empty list
     * writes nothing and sets no marker, so the seal keeps the record. A line off the list is ignored: it never reaches a
     * put. A malformed value writes nothing and withholds the marker. The other rows still apply.
     */
    static Result apply(List<Row> rows, List<String> lines, Store store, Predicate<String> installed) {
        Result res = new Result();
        if (lines == null || rows == null || rows.isEmpty()) return res;
        for (String line : lines) {
            if (!line.startsWith(PREF_PREFIX)) continue;
            String[] f = line.substring(PREF_PREFIX.length()).split(" ", 3);
            if (f.length < 2) continue;
            Row row = onList(rows, f[0], f[1]);
            if (row == null) continue;
            res.rows++;
            String value = f.length == 3 ? f[2] : "";
            if (!KIND_TILES.equals(row.kind)) {
                if (value.isEmpty()) res.malformed++;
                else if (store.put(row.scope, row.key, value)) res.applied++;
                else res.failed++;
                continue;
            }
            if (!tilesValid(value)) {
                res.malformed++;
                continue;
            }
            String annotated = pendingFor(value, installed);
            int waiting = waitingIn(annotated);
            if (waiting > 0 && !store.put(SECURE, TILES_KEY, annotated)) {
                res.failed++;
                continue;
            }
            res.waiting += waiting;
            String live = liveOf(annotated);
            // Every tile waits: an empty list must not reach SystemUI, so the live row stays at its default.
            if (live.isEmpty()) continue;
            if (store.put(row.scope, row.key, live)) res.applied++;
            else res.failed++;
        }
        if (res.failed == 0 && res.malformed == 0) res.marked = store.put(SECURE, APPLIED_KEY, "1");
        return res;
    }

    /**
     * Put each waiting tile whose package has landed into the live value, after the nearest stored tile before it that is
     * live, else first. Then rewrite the row without that mark, and empty it when no tile waits. Returns the tiles landed.
     * A crash between the two puts leaves the tile live and marked, and the next call does not double it.
     */
    static int reconcile(Row row, Store store, Predicate<String> installed) {
        if (row == null) return 0;
        String annotated = store.get(SECURE, TILES_KEY);
        if (annotated == null || annotated.isEmpty()) return 0;
        String[] marked = tiles(annotated);
        List<String> plain = new ArrayList<>();
        for (String t : marked) plain.add(bare(t));
        if (!tilesValid(String.join(",", plain))) return 0;
        String live = store.get(row.scope, row.key);
        List<String> now = new ArrayList<>();
        if (live != null && !live.isEmpty()) {
            if (!tilesValid(live)) return 0;
            for (String t : tiles(live)) now.add(t);
        }
        List<String> rest = new ArrayList<>();
        int landed = 0;
        int waiting = 0;
        String last = null;
        for (String t : marked) {
            String tile = bare(t);
            boolean isLive = now.contains(tile);
            String pkg = isWaiting(t) ? customPackage(tile) : null;
            boolean lands = isWaiting(t) && pkg != null && installed.test(pkg);
            if (lands && !isLive) {
                now.add(last == null ? 0 : now.indexOf(last) + 1, tile);
                landed++;
                isLive = true;
            }
            if (isLive) last = tile;
            boolean stillWaits = isWaiting(t) && !lands;
            if (stillWaits) waiting++;
            rest.add(stillWaits ? t : tile);
        }
        if (rest.equals(java.util.Arrays.asList(marked))) return 0;
        if (landed > 0 && !store.put(row.scope, row.key, String.join(",", now))) return 0;
        store.put(SECURE, TILES_KEY, waiting == 0 ? "" : String.join(",", rest));
        return landed;
    }
}
