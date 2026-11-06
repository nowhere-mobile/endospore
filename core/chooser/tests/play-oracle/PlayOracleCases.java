package com.nowhere.chooser;

import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;

/** NWP-20261022-18: the Play-stack orphan oracle's decision table, one case per row, each on its own files dir. */
public class PlayOracleCases {
  static int fails = 0, n = 0;
  static File root, dir;
  static PackageManager pm;
  static ProfileActivity act;
  static final String GMS = "com.google.android.gms", GSF = "com.google.android.gsf", VEND = "com.android.vending";
  static final String KEY = "com.google.android.gms.version";

  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }

  static void fresh() {
    dir = new File(root, "c" + (++n));
    if (!dir.mkdir()) throw new IllegalStateException("mkdir " + dir);
    pm = new PackageManager();
    act = new ProfileActivity(dir, pm);
    ProfileActivity.VC.clear();
    ProfileActivity.OWN = "com.nowhere.chooser";
    android.util.Log.lines.clear();
  }
  static void put(String name, String text) throws Exception {
    Files.write(new File(dir, name).toPath(), text.getBytes(StandardCharsets.UTF_8));
  }
  static String get(String name) throws Exception {
    File f = new File(dir, name);
    return f.exists() ? new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8) : null;
  }
  static void readable(String pkg, boolean declares) {
    ApplicationInfo ai = new ApplicationInfo();
    ai.sourceDir = "/data/app/" + pkg;
    ai.metaData = new Bundle();
    if (declares) ai.metaData.keys.add(KEY);
    pm.infos.put(pkg, ai);
  }
  static void archived(String pkg, String sourceDir) { // a successful lookup of a placeholder with no APK
    ApplicationInfo ai = new ApplicationInfo();
    ai.sourceDir = sourceDir;
    pm.infos.put(pkg, ai);
  }
  static Map<String, String> keep(String... pkgs) {
    Map<String, String> m = new LinkedHashMap<>();
    for (String p : pkgs) m.put(p, "ondemand");
    return m;
  }
  /** NWP-20261111-06: a non-empty directory where the record belongs -- it exists and cannot be opened. */
  static void dirRecord(String name) throws Exception {
    File t = new File(dir, name);
    if (!t.mkdir() || !new File(t, "keep").createNewFile()) throw new IllegalStateException("dirRecord " + t);
  }
  static boolean logged(String sub) {
    for (String s : android.util.Log.lines) if (s.contains(sub)) return true;
    return false;
  }

  public static void main(String[] a) throws Exception {
    root = new File(a[0]);

    // (1) the stack itself is skipped
    fresh();
    check("1 gms, gsf and vending alone -> orphaned", act.playStackOrphanKnown(keep(GMS, GSF, VEND)), "false");
    check("1 ... and nothing is logged", android.util.Log.lines.isEmpty(), "lines=" + android.util.Log.lines);
    fresh();
    check("1 an empty map -> orphaned", act.playStackOrphanKnown(keep()), "false");

    // (2) the chooser's own package is skipped
    fresh();
    check("2 the chooser's own package is skipped", act.playStackOrphanKnown(keep("com.nowhere.chooser", GMS)), "false");

    // (3) a recorded Play client
    fresh(); put("nowhere-playdeps", "app.client\n");
    check("3 a package in nowhere-playdeps -> not orphaned", !act.playStackOrphanKnown(keep("app.client")), "true");
    check("3 ... logged 'is a recorded Play client'", logged("app.client is a recorded Play client"), "lines=" + android.util.Log.lines);
    fresh(); put("nowhere-playdeps", "app.client\n"); put("nowhere-playseen", "app.client\t5\tn\n");
    ProfileActivity.VC.put("app.client", 5L);
    check("3 the playdeps arm wins over a current 'n' record", !act.playStackOrphanKnown(keep("app.client")), "true");

    // (4) readable, declares the dependency
    fresh(); readable("app.yes", true); ProfileActivity.VC.put("app.yes", 7L);
    check("4 a readable manifest declaring the key -> not orphaned", !act.playStackOrphanKnown(keep("app.yes")), "true");
    check("4 ... logged 'declares a Play dependency'", logged("app.yes declares a Play dependency"), "lines=" + android.util.Log.lines);
    check("4 ... nowhere-playseen gains pkg<TAB>7<TAB>y", "app.yes\t7\ty\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));

    // (5) readable, does not declare it
    fresh(); readable("app.no", false); ProfileActivity.VC.put("app.no", 3L);
    check("5 a readable manifest without the key, alone -> orphaned", act.playStackOrphanKnown(keep("app.no")), "false");
    check("5 ... recorded n", "app.no\t3\tn\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));

    // (6) an archived placeholder: a successful lookup with no sourceDir is no answer
    for (String sd : new String[] { null, "" }) {
      String lbl = sd == null ? "null" : "empty";
      fresh(); archived("app.arch", sd); ProfileActivity.VC.put("app.arch", 4L);
      check("6 " + lbl + " sourceDir -> readsPlayServices is null, not false", ProfileActivity.readsPlayServices(act, "app.arch") == null,
            "answered " + ProfileActivity.readsPlayServices(act, "app.arch"));
      put("nowhere-playseen", "app.arch\t4\ty\n");
      check("6 " + lbl + " sourceDir -> the walk falls to the y record", !act.playStackOrphanKnown(keep("app.arch")), "true");
      check("6 ... and the record is not overwritten", "app.arch\t4\ty\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    }
    fresh();
    check("6 a package the PM does not know -> null", ProfileActivity.readsPlayServices(act, "app.gone") == null, "answered");

    // (7) unreadable, record at the current version
    fresh(); put("nowhere-playseen", "app.u\t9\ty\n"); ProfileActivity.VC.put("app.u", 9L);
    check("7 unreadable, current y record -> not orphaned", !act.playStackOrphanKnown(keep("app.u")), "true");
    check("7 ... logged 'was determined to be a Play client'", logged("app.u was determined to be a Play client"), "lines=" + android.util.Log.lines);
    fresh(); put("nowhere-playseen", "app.u\t9\tn\n"); ProfileActivity.VC.put("app.u", 9L);
    check("7 unreadable, current n record, alone -> orphaned", act.playStackOrphanKnown(keep("app.u")), "false");
    fresh(); put("nowhere-playseen", "app.u\t9\tn\napp.w\t2\ty\n"); ProfileActivity.VC.put("app.u", 9L); ProfileActivity.VC.put("app.w", 2L);
    check("7 an n record continues the walk to the next package", !act.playStackOrphanKnown(keep("app.u", "app.w")), "true");

    // (8) unreadable, record at another version
    fresh(); put("nowhere-playseen", "app.v\t8\tn\n"); ProfileActivity.VC.put("app.v", 9L);
    check("8 an n record at another version -> not orphaned", !act.playStackOrphanKnown(keep("app.v")), "true");
    check("8 ... logged 'has updated since it was checked'", logged("app.v has updated since it was checked"), "lines=" + android.util.Log.lines);

    // (9) unreadable, no record
    fresh(); ProfileActivity.VC.put("app.x", 1L);
    check("9 unreadable with no record -> not orphaned", !act.playStackOrphanKnown(keep("app.x")), "true");
    check("9 ... logged 'has never been checked'", logged("app.x has never been checked"), "lines=" + android.util.Log.lines);

    // (10) unreadable, a record, but the version cannot be resolved
    fresh(); put("nowhere-playseen", "app.y\t5\tn\n");
    check("10 a record but versionCodeOf -1 -> not orphaned", !act.playStackOrphanKnown(keep("app.y")), "true");
    fresh(); put("nowhere-playseen", "app.y\t-1\tn\n");
    check("10 a record of -1 does not match an unresolved -1", !act.playStackOrphanKnown(keep("app.y")), "true");

    // (11) readPlaySeen
    fresh();
    put("nowhere-playseen", "a\t5\ty\nb\t5\nc\t5\tmaybe\n  d \t 7 \t n  \ne\t1\t2\ty\n\n");
    Map<String, String[]> seen = ProfileActivity.readPlaySeen(act);
    check("11 a valid line is read", seen.get("a") != null && seen.get("a")[0].equals("5") && seen.get("a")[1].equals("y"), "a=" + seen.get("a"));
    check("11 a two-field line is dropped", !seen.containsKey("b"), "b=" + seen.get("b"));
    check("11 an answer other than y or n is dropped", !seen.containsKey("c"), "c=" + seen.get("c"));
    check("11 fields are trimmed", seen.get("d") != null && seen.get("d")[0].equals("7") && seen.get("d")[1].equals("n"), "d=" + seen.get("d"));
    check("11 a four-field line is dropped", !seen.containsKey("e"), "e=" + seen.get("e"));
    check("11 exactly the two good lines survive", seen.size() == 2, "size=" + seen.size());
    fresh();
    check("11 no file -> empty map", ProfileActivity.readPlaySeen(act).isEmpty(), "not empty");

    // (12) notePlaySeen
    fresh();
    ProfileActivity.notePlaySeen(act, "app.z", true);
    check("12 versionCodeOf -1 writes nothing", get("nowhere-playseen") == null, "file=" + get("nowhere-playseen"));
    fresh(); ProfileActivity.VC.put("app.z", 6L);
    ProfileActivity.notePlaySeen(act, "app.z", true);
    check("12 a resolved version writes pkg<TAB>vc<TAB>y", "app.z\t6\ty\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    File f = new File(dir, "nowhere-playseen");
    long old = 1_000_000_000_000L;
    check("12 (setup) the mtime could be pinned", f.setLastModified(old) && f.lastModified() == old, "lastModified=" + f.lastModified());
    String bytes = get("nowhere-playseen");
    ProfileActivity.notePlaySeen(act, "app.z", true);
    check("12 an unchanged determination leaves the bytes alone", bytes.equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    check("12 ... and the mtime", f.lastModified() == old, "lastModified=" + f.lastModified());
    ProfileActivity.notePlaySeen(act, "app.z", false);
    check("12 a changed answer rewrites it", "app.z\t6\tn\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    ProfileActivity.VC.put("app.z", 7L);
    ProfileActivity.notePlaySeen(act, "app.z", false);
    check("12 a new version rewrites it", "app.z\t7\tn\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    String[] left = dir.list((d, name) -> name.endsWith(".tmp"));
    check("12 no .tmp is left behind", left != null && left.length == 0, "tmp=" + (left == null ? "null" : String.join(",", left)));

    // (13) playDependent
    fresh(); readable("app.l", true); ProfileActivity.VC.put("app.l", 2L);
    check("13 readable declaring -> true", act.playDependent("app.l"), "false");
    check("13 ... and recorded y", "app.l\t2\ty\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    fresh(); readable("app.l", false); ProfileActivity.VC.put("app.l", 2L);
    check("13 readable not declaring -> false", !act.playDependent("app.l"), "true");
    check("13 ... and recorded n", "app.l\t2\tn\n".equals(get("nowhere-playseen")), "file=" + get("nowhere-playseen"));
    fresh(); put("nowhere-playseen", "app.m\t2\ty\n");
    check("13 unreadable with a y record -> true", act.playDependent("app.m"), "false");
    fresh(); put("nowhere-playseen", "app.m\t2\ty\n"); ProfileActivity.VC.put("app.m", 3L);
    check("13 a y record is trusted at another version", act.playDependent("app.m"), "false");
    fresh(); put("nowhere-playseen", "app.m\t2\tn\n");
    check("13 unreadable with an n record -> false", !act.playDependent("app.m"), "true");
    fresh();
    check("13 unreadable with no record -> false", !act.playDependent("app.m"), "true");
    check("13 ... and nothing is written", get("nowhere-playseen") == null, "file=" + get("nowhere-playseen"));

    // (14) an unreadable record abstains (NWP-20261111-06). app.o is kept, its manifest cannot be read (no PM answer)
    // and nowhere-playseen holds a determined n at its current version -- alone, that answer passes the walk.
    fresh(); dirRecord("nowhere-playdeps"); put("nowhere-playseen", "app.o\t5\tn\n"); ProfileActivity.VC.put("app.o", 5L);
    check("14 (setup) app.o's manifest cannot be read", ProfileActivity.readsPlayServices(act, "app.o") == null, "readable");
    check("14 (setup) readPlayDepsStrict is null for the directory", ProfileActivity.readPlayDepsStrict(act) == null, "not null");
    check("14 nowhere-playdeps unopenable -> not orphaned", !act.playStackOrphanKnown(keep("app.o")), "true");
    check("14 ... logged 'a Play record is unreadable'", logged("a Play record is unreadable"), "lines=" + android.util.Log.lines);
    fresh(); put("nowhere-playdeps", "app.o\n"); put("nowhere-playseen", "app.o\t5\tn\n"); ProfileActivity.VC.put("app.o", 5L);
    check("14 control: nowhere-playdeps readable and naming app.o -> not orphaned", !act.playStackOrphanKnown(keep("app.o")), "true");
    fresh(); put("nowhere-playseen", "app.o\t5\tn\n"); ProfileActivity.VC.put("app.o", 5L);
    check("14 control: nowhere-playdeps absent, the same playseen -> orphaned", act.playStackOrphanKnown(keep("app.o")), "false");
    fresh(); dirRecord("nowhere-playseen"); ProfileActivity.VC.put("app.o", 5L);
    check("14 (setup) readPlaySeenStrict is null for the directory", ProfileActivity.readPlaySeenStrict(act) == null, "not null");
    check("14 nowhere-playseen unopenable -> not orphaned", !act.playStackOrphanKnown(keep("app.o")), "true");
    check("14 ... logged 'a Play record is unreadable'", logged("a Play record is unreadable"), "lines=" + android.util.Log.lines);

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
