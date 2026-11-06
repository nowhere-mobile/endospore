package com.nowhere.chooser;

import android.content.Context;
import android.content.pm.PackageManager;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/** NWP-20261021-09: the cases for AppInstallReceiver.decide's install-default table, run against the lifted method. */
public class InstallDefaultCases {
  static final String P = "org.example.app";
  static final String AURORA = "com.aurora.store";
  static final String VENDING = "com.android.vending";
  static final String NAPPS_OUTCOME = "skipped (nApps -- StoreInstaller applied it on the install path)";
  static final String CLEARED = "not kept (this bucket's default is off) -- and the previous install's keep line was cleared";
  static final String PLAIN_OFF = "not kept (this bucket's default is off)";
  static final String SWITCHED_OFF = "not kept (the user switched this app off)";
  static final String RESET = "re-installed -- reset to this bucket's default";
  static final String REFUSED = "refused by keepInMode";
  static final String LEFT_ALONE = "left alone (already has a keep line)";

  static int fails = 0;
  static PackageManager pm;
  static Context ctx;

  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }

  static void reset() {
    StoreInstaller.reset();
    ProfileActivity.reset();
    android.util.Log.lines.clear();
    android.os.Build.VERSION.SDK_INT = 34;
    pm = new PackageManager();
    ctx = new Context(pm);
  }
  static void installer(String inst) { pm.installer.put(P, inst); }
  static boolean call(boolean replacing, String via) { return AppInstallReceiver.decide(ctx, P, replacing, via); }

  /** The single log line's outcome (the text between " -> " and " (NWP-20260825-19)"), or null with a FAIL. */
  static String outcome(String label) {
    List<String> l = android.util.Log.lines;
    if (l.size() != 1) { check(label + ": exactly one log line", false, "lines=" + l); return null; }
    String s = l.get(0);
    int a = s.indexOf(" -> "), b = s.lastIndexOf(" (NWP-20260825-19)");
    if (a < 0 || b < a) { check(label + ": log line shape", false, s); return null; }
    return s.substring(a + 4, b);
  }
  static List<String> writes() {
    List<String> w = new ArrayList<>();
    for (String j : StoreInstaller.journal) if (j.startsWith("removeKeepLines:") || j.startsWith("keepInMode:")) w.add(j);
    return w;
  }
  static boolean logHas(String frag) { return android.util.Log.lines.toString().contains(frag); }
  static void gone() { StoreInstaller.gone.add(P); }
  static void kept() { StoreInstaller.kept.add(P); }

  interface Case { void run() throws Exception; }
  static void run(String name, Case c) {
    reset();
    try { c.run(); }
    catch (Throwable t) { check(name + ": no exception", false, t.toString()); }
  }

  public static void main(String[] a) {
    run("C1", () -> {
      installer(AURORA); ProfileActivity.mode = "off"; gone(); kept(); ProfileActivity.off.add(P);
      boolean r = call(true, "broadcast");
      check("C1 replacing -> false", !r, "r=" + r);
      check("C1 replacing -> skipped (an update, not a new install)", "skipped (an update, not a new install)".equals(outcome("C1")), "lines=" + android.util.Log.lines);
      check("C1 no StoreInstaller call at all", StoreInstaller.journal.isEmpty(), "journal=" + StoreInstaller.journal);
      check("C1 explicitlyTurnedOff and isBundledSystem never consulted", ProfileActivity.offCalls == 0 && ProfileActivity.bundledCalls == 0,
          "off=" + ProfileActivity.offCalls + " bundled=" + ProfileActivity.bundledCalls);
    });

    run("C2", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; ProfileActivity.bundled = true; gone(); kept();
      boolean r = call(false, "broadcast");
      check("C2 bundled -> false", !r, "r=" + r);
      check("C2 bundled -> skipped (ships in the image)", "skipped (ships in the image -- there is nothing to keep)".equals(outcome("C2")), "lines=" + android.util.Log.lines);
      check("C2 bundled -> nothing written or removed", writes().isEmpty(), "writes=" + writes());
    });

    for (String inst : new String[] {"com.nowhere.chooser", "com.nowhere.napps", "org.fdroid.fdroid"}) {
      for (String mode : new String[] {"auto", "off"}) {
        run("C3 " + inst + "/" + mode, () -> {
          installer(inst); ProfileActivity.mode = mode; gone(); kept();
          boolean r = call(false, "broadcast");
          String tag = "C3 " + inst + " default=" + mode;
          check(tag + " -> false", !r, "r=" + r);
          check(tag + " -> skipped (nApps)", NAPPS_OUTCOME.equals(outcome(tag)), "lines=" + android.util.Log.lines);
          check(tag + " -> nothing written or removed", writes().isEmpty(), "writes=" + writes());
          check(tag + " -> bucket=napps", logHas(" bucket=napps "), "lines=" + android.util.Log.lines);
        });
      }
    }

    run("C4", () -> {
      installer(AURORA); ProfileActivity.mode = "off"; gone(); kept();
      boolean r = call(false, "broadcast");
      check("C4 off default, returning, kept -> false", !r, "r=" + r);
      check("C4 the previous install's keep line was cleared", CLEARED.equals(outcome("C4")), "lines=" + android.util.Log.lines);
      check("C4 removeKeepLines({pkg}) and nothing else written", writes().equals(Arrays.asList("removeKeepLines:[" + P + "]")), "writes=" + writes());
      check("C4 keepInMode never called", !StoreInstaller.journal.contains("keepInMode:" + P + ",false,off"), "journal=" + StoreInstaller.journal);
      check("C4 explicitlyTurnedOff never consulted", ProfileActivity.offCalls == 0, "offCalls=" + ProfileActivity.offCalls);
      check("C4 the full log line",
          android.util.Log.lines.equals(Collections.singletonList("NowhereChooser: install default (broadcast): " + P
              + " installer=" + AURORA + " bucket=aurora default=off -> " + CLEARED + " (NWP-20260825-19)")),
          "lines=" + android.util.Log.lines);
    });
    run("C4b off default tested before the Off record", () -> {
      installer(AURORA); ProfileActivity.mode = "off"; gone(); kept(); ProfileActivity.off.add(P);
      call(false, "broadcast");
      check("C4b pkg also in the Off record -> still the clear", CLEARED.equals(outcome("C4b")), "lines=" + android.util.Log.lines);
      check("C4b the Off record never consulted", ProfileActivity.offCalls == 0, "offCalls=" + ProfileActivity.offCalls);
    });
    run("C4c aurora.services", () -> {
      installer("com.aurora.services"); ProfileActivity.mode = "off"; gone(); kept();
      call(false, "broadcast");
      check("C4c com.aurora.services -> bucket=aurora", logHas(" bucket=aurora "), "lines=" + android.util.Log.lines);
    });

    run("C5", () -> {
      installer(AURORA); ProfileActivity.mode = "off"; kept();
      boolean r = call(false, "broadcast");
      check("C5 off default, kept, NOT returning -> false", !r, "r=" + r);
      check("C5 plain 'not kept'", PLAIN_OFF.equals(outcome("C5")), "lines=" + android.util.Log.lines);
      check("C5 nothing removed", writes().isEmpty(), "writes=" + writes());
    });
    run("C5b off default, returning, NOT kept", () -> {
      installer(AURORA); ProfileActivity.mode = "off"; gone();
      call(false, "broadcast");
      check("C5b nothing to clear -> plain 'not kept', nothing removed", PLAIN_OFF.equals(outcome("C5b")) && writes().isEmpty(),
          "lines=" + android.util.Log.lines + " writes=" + writes());
    });

    run("C6", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; gone(); kept(); ProfileActivity.off.add(P);
      boolean r = call(false, "broadcast");
      check("C6 Off record, returning, kept -> false", !r, "r=" + r);
      check("C6 not kept (the user switched this app off)", SWITCHED_OFF.equals(outcome("C6")), "lines=" + android.util.Log.lines);
      check("C6 nothing written or removed", writes().isEmpty(), "writes=" + writes());
      check("C6 bucket=play", logHas(" bucket=play "), "lines=" + android.util.Log.lines);
    });

    run("C7 reset", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; gone(); kept(); StoreInstaller.keepInModeAnswer = true;
      boolean r = call(false, "broadcast");
      check("C7 returning reset -> true", r, "r=" + r);
      check("C7 removeKeepLines THEN keepInMode(pkg, false, auto)",
          writes().equals(Arrays.asList("removeKeepLines:[" + P + "]", "keepInMode:" + P + ",false,auto")), "writes=" + writes());
      check("C7 re-installed -- reset to this bucket's default", RESET.equals(outcome("C7")), "lines=" + android.util.Log.lines);
    });
    run("C7 reset refused", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; gone(); kept(); StoreInstaller.keepInModeAnswer = false;
      boolean r = call(false, "broadcast");
      check("C7 keepInMode false -> false", !r, "r=" + r);
      check("C7 keepInMode false -> refused by keepInMode", REFUSED.equals(outcome("C7r")), "lines=" + android.util.Log.lines);
      check("C7 keepInMode false: the order is still remove then keepInMode",
          writes().equals(Arrays.asList("removeKeepLines:[" + P + "]", "keepInMode:" + P + ",false,auto")), "writes=" + writes());
    });

    run("C8", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; kept();
      boolean r = call(false, "broadcast");
      check("C8 kept, not returning -> false", !r, "r=" + r);
      check("C8 left alone (already has a keep line)", LEFT_ALONE.equals(outcome("C8")), "lines=" + android.util.Log.lines);
      check("C8 nothing written", writes().isEmpty(), "writes=" + writes());
    });

    for (boolean ret : new boolean[] {false, true}) {
      for (boolean ans : new boolean[] {true, false}) {
        run("C9 returning=" + ret + " answer=" + ans, () -> {
          installer(VENDING); ProfileActivity.mode = "auto"; if (ret) gone(); StoreInstaller.keepInModeAnswer = ans;
          boolean r = call(false, "broadcast");
          String tag = "C9 not kept, not Off (returning=" + ret + ", keepInMode=" + ans + ")";
          check(tag + " -> keepInMode once, nothing removed", writes().equals(Arrays.asList("keepInMode:" + P + ",false,auto")), "writes=" + writes());
          check(tag + " -> decide returns keepInMode's value", r == ans, "r=" + r);
          check(tag + " -> outcome", (ans ? "kept" : REFUSED).equals(outcome(tag)), "lines=" + android.util.Log.lines);
        });
      }
    }

    run("C10 sideload", () -> {
      ProfileActivity.mode = "off";
      call(false, "broadcast");
      check("C10 a null installer -> appDefaultForInstaller asked once, with null",
          ProfileActivity.installerArgs.size() == 1 && ProfileActivity.installerArgs.get(0) == null, "args=" + ProfileActivity.installerArgs);
      check("C10 ... installer=null bucket=other", logHas(" installer=null bucket=other "), "lines=" + android.util.Log.lines);
    });
    run("C10b source info throws", () -> {
      installer(AURORA); pm.throwOnSourceInfo = true;
      call(false, "broadcast");
      check("C10b a throwing getInstallSourceInfo reads as a sideload (bucket=other)", logHas(" bucket=other ")
          && ProfileActivity.installerArgs.size() == 1 && ProfileActivity.installerArgs.get(0) == null, "lines=" + android.util.Log.lines);
    });
    run("C10c SDK 29", () -> {
      installer(AURORA); android.os.Build.VERSION.SDK_INT = 29;
      call(false, "broadcast");
      check("C10c below API 30 the legacy getInstallerPackageName answers", pm.legacyCalls == 1 && pm.sourceInfoCalls == 0 && logHas(" bucket=aurora "),
          "legacy=" + pm.legacyCalls + " source=" + pm.sourceInfoCalls + " lines=" + android.util.Log.lines);
    });
    run("C10d GrapheneOS store", () -> {
      installer("app.grapheneos.apps");
      call(false, "broadcast");
      check("C10d app.grapheneos.apps -> bucket=gos", logHas(" bucket=gos "), "lines=" + android.util.Log.lines);
    });

    run("C11 catch-up, nothing written", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; kept();
      boolean r = call(false, "catch-up");
      check("C11 catch-up with nothing written -> false", !r, "r=" + r);
      check("C11 ... and no log line", android.util.Log.lines.isEmpty(), "lines=" + android.util.Log.lines);
    });
    run("C11 catch-up, written", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; StoreInstaller.keepInModeAnswer = true;
      boolean r = call(false, "catch-up");
      check("C11 catch-up that wrote -> true", r, "r=" + r);
      check("C11 ... and exactly one catch-up line", android.util.Log.lines.size() == 1 && logHas("install default (catch-up): " + P), "lines=" + android.util.Log.lines);
    });
    run("C11 broadcast logs every call", () -> {
      installer(VENDING); ProfileActivity.mode = "auto"; kept();
      call(false, "broadcast");
      check("C11 the broadcast path logs exactly one line even when nothing was written", android.util.Log.lines.size() == 1, "lines=" + android.util.Log.lines);
    });

    // NWP-20261122-06 (h50 #7 A1): with play.wanted=1 a Play stack member installed from the GrapheneOS App Store is
    // kept On-demand although that bucket's default is off, and Play Store alone is recorded as the user's keep.
    final String GOS = "app.grapheneos.apps";
    for (String sp : new String[] {VENDING, "com.google.android.gms", "com.google.android.gsf"}) {
      run("C12 play on, " + sp, () -> {
        pm.installer.put(sp, GOS); ProfileActivity.mode = "off"; ProfileActivity.play = "1";
        boolean r = AppInstallReceiver.decide(ctx, sp, false, "broadcast");
        String tag = "C12 play on, " + sp;
        check(tag + " -> kept", r, "r=" + r);
        check(tag + " -> keepInMode(" + sp + ", false, ondemand)", writes().equals(Arrays.asList("keepInMode:" + sp + ",false,ondemand")), "writes=" + writes());
        check(tag + " -> play.wanted read", ProfileActivity.cfgKeys.contains("play.wanted"), "keys=" + ProfileActivity.cfgKeys);
        boolean wantDep = VENDING.equals(sp);
        check(tag + " -> setPlayDep " + (wantDep ? "(vending, true) once" : "never"),
            ProfileActivity.playDeps.equals(wantDep ? Collections.singletonList(VENDING + ",true") : Collections.<String>emptyList()),
            "playDeps=" + ProfileActivity.playDeps);
      });
    }
    run("C12 play on, vending refused by keepInMode", () -> {
      pm.installer.put(VENDING, GOS); ProfileActivity.mode = "off"; ProfileActivity.play = "1"; StoreInstaller.keepInModeAnswer = false;
      AppInstallReceiver.decide(ctx, VENDING, false, "broadcast");
      check("C12 a refused keep records no playdep", ProfileActivity.playDeps.isEmpty(), "playDeps=" + ProfileActivity.playDeps);
    });
    run("C12 play on, another app", () -> {
      installer(GOS); ProfileActivity.mode = "off"; ProfileActivity.play = "1";
      boolean r = call(false, "broadcast");
      check("C12 play on, a non-Play app keeps its bucket default (off -> not kept)", !r && PLAIN_OFF.equals(outcome("C12o")) && writes().isEmpty(),
          "r=" + r + " lines=" + android.util.Log.lines + " writes=" + writes());
      check("C12 play on, a non-Play app records no playdep", ProfileActivity.playDeps.isEmpty(), "playDeps=" + ProfileActivity.playDeps);
    });
    // NWP-20261122-06 (RF-001): without the GrapheneOS App Store (Diaspore) a roamed play.wanted=1 changes nothing.
    for (String sp : new String[] {VENDING, "com.google.android.gms"}) {
      run("C14 play on, no GrapheneOS App Store, " + sp, () -> {
        pm.installer.put(sp, GOS); ProfileActivity.mode = "off"; ProfileActivity.play = "1"; ProfileActivity.gos = false;
        boolean r = AppInstallReceiver.decide(ctx, sp, false, "broadcast");
        String tag = "C14 play.wanted=1 without the GrapheneOS App Store, " + sp;
        check(tag + " -> the bucket default (off -> not kept)", !r && writes().isEmpty(), "r=" + r + " writes=" + writes());
        check(tag + " -> no playdep", ProfileActivity.playDeps.isEmpty(), "playDeps=" + ProfileActivity.playDeps);
      });
    }
    for (String pv : new String[] {"off", "0"}) {
      run("C13 play " + pv + ", vending", () -> {
        pm.installer.put(VENDING, GOS); ProfileActivity.mode = "off"; ProfileActivity.play = pv;
        boolean r = AppInstallReceiver.decide(ctx, VENDING, false, "broadcast");
        String tag = "C13 play.wanted=" + pv + ", vending";
        check(tag + " -> the bucket default (off -> not kept)", !r && writes().isEmpty(), "r=" + r + " writes=" + writes());
        check(tag + " -> no playdep", ProfileActivity.playDeps.isEmpty(), "playDeps=" + ProfileActivity.playDeps);
      });
    }

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
