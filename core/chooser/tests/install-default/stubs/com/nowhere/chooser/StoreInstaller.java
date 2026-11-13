package com.nowhere.chooser;
import android.content.Context;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;

/** Journal stub: records every call decide makes, in order, and answers from per-case state. */
final class StoreInstaller {
  static final List<String> journal = new ArrayList<>();
  static final Set<String> gone = new HashSet<>();
  static final Set<String> kept = new HashSet<>();
  static boolean keepInModeAnswer = true;

  static void reset() { journal.clear(); gone.clear(); kept.clear(); keepInModeAnswer = true; }

  static java.util.Set<String> appGoneThisSession(Context ctx) {
    journal.add("appGoneThisSession");
    return new HashSet<>(gone);
  }
  static boolean keepSetHas(Context ctx, String pkg) {
    journal.add("keepSetHas:" + pkg);
    return kept.contains(pkg);
  }
  static void removeKeepLines(Context ctx, java.util.Set<String> drop) {
    journal.add("removeKeepLines:" + new TreeSet<>(drop));
  }
  static boolean keepInMode(Context ctx, String pkg, boolean overPlan, String mode) {
    journal.add("keepInMode:" + pkg + "," + overPlan + "," + mode);
    return keepInModeAnswer;
  }
  static void clearTurnedOff(Context ctx, java.util.Collection<String> pkgs) {
    journal.add("clearTurnedOff:" + new TreeSet<>(pkgs));
  }
}
