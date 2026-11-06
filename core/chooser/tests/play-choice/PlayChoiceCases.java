package com.nowhere.chooser;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/** NWP-20261122-06: the cases for PlayChoice, the Google Play row's rules (h50 #7: A1 with the not-installed row,
 *  B1 (i), B2). Compiled with PlayChoice.java as-is by core/vendor-common/bin/test-play-choice-java.sh. */
public class PlayChoiceCases {
  static int fails = 0;

  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }
  static void eq(String what, Object want, Object got) {
    check(what, want == null ? got == null : want.equals(got), "want <" + want + "> got <" + got + ">");
  }

  static final String VENDING = "com.android.vending";
  static final String GMS = "com.google.android.gms";
  static final String GSF = "com.google.android.gsf";
  // The decided draft, written out here and NOT read from the constant, so a changed constant fails.
  static final String NOT_INSTALLED = "On · not installed yet — tap to install from the GrapheneOS App Store";

  public static void main(String[] a) {
    final PlayChoice.State ABSENT = PlayChoice.State.ABSENT, ON = PlayChoice.State.ON, OFF = PlayChoice.State.OFF;

    // the three states
    eq("parse \"1\" -> ON", ON, PlayChoice.parse("1"));
    eq("parse \"0\" -> OFF", OFF, PlayChoice.parse("0"));
    eq("parse \" 1 \" -> ON", ON, PlayChoice.parse(" 1 "));
    for (String r : new String[] {null, "", "off", "on", "yes", "no", "false", "2"}) {
      eq("parse " + (r == null ? "null" : "\"" + r + "\"") + " -> ABSENT (absent is never off)", ABSENT, PlayChoice.parse(r));
    }
    eq("raw ON -> \"1\"", "1", PlayChoice.raw(ON));
    eq("raw OFF -> \"0\"", "0", PlayChoice.raw(OFF));
    boolean threw = false;
    try { PlayChoice.raw(ABSENT); } catch (IllegalArgumentException e) { threw = true; }
    check("raw ABSENT refuses (absent is never written)", threw, "no exception");
    eq("CFG_KEY", "play.wanted", PlayChoice.CFG_KEY);

    // effective: a stored flag acts only where the GrapheneOS App Store is installed (RF-001)
    for (PlayChoice.State s : PlayChoice.State.values()) {
      eq("effective " + s + " with the GrapheneOS App Store -> " + s, s, PlayChoice.effective(s, true));
      eq("effective " + s + " without it (Diaspore) -> ABSENT", ABSENT, PlayChoice.effective(s, false));
    }
    eq("Diaspore, stored 0: the reconcile guard does not block", false,
        PlayChoice.blocksVendingReadd(PlayChoice.effective(PlayChoice.parse("0"), false)));
    eq("Endospore, stored 0: the reconcile guard blocks", true,
        PlayChoice.blocksVendingReadd(PlayChoice.effective(PlayChoice.parse("0"), true)));
    for (String p : new String[] {VENDING, GMS, GSF}) {
      eq("Diaspore, stored 1: " + p + " keeps the installer default", "off",
          PlayChoice.keepModeOnInstall(PlayChoice.effective(PlayChoice.parse("1"), false), p, "off"));
      eq("Endospore, stored 1: " + p + " -> ondemand", "ondemand",
          PlayChoice.keepModeOnInstall(PlayChoice.effective(PlayChoice.parse("1"), true), p, "off"));
      eq("Diaspore, stored 0: " + p + " keeps the installer default", "installed",
          PlayChoice.keepModeOnInstall(PlayChoice.effective(PlayChoice.parse("0"), false), p, "installed"));
    }

    // shownOn: absent follows the profile
    eq("absent, vending kept -> shown On", true, PlayChoice.shownOn(ABSENT, true, false));
    eq("absent, vending installed -> shown On", true, PlayChoice.shownOn(ABSENT, false, true));
    eq("absent, neither -> shown Off", false, PlayChoice.shownOn(ABSENT, false, false));
    eq("ON, neither -> shown On", true, PlayChoice.shownOn(ON, false, false));
    eq("OFF, vending kept and installed -> shown Off", false, PlayChoice.shownOn(OFF, true, true));

    // rowText
    for (boolean k : new boolean[] {false, true}) for (boolean i : new boolean[] {false, true}) {
      eq("rowText OFF (kept=" + k + ", installed=" + i + ") -> Off", "Off", PlayChoice.rowText(OFF, k, i));
    }
    eq("rowText absent, neither -> Off", "Off", PlayChoice.rowText(ABSENT, false, false));
    eq("rowText absent, vending kept and installed -> On", "On", PlayChoice.rowText(ABSENT, true, true));
    eq("rowText absent, vending installed -> On", "On", PlayChoice.rowText(ABSENT, false, true));
    eq("rowText ON, installed -> On", "On", PlayChoice.rowText(ON, false, true));
    eq("rowText ON, kept and installed -> On", "On", PlayChoice.rowText(ON, true, true));
    eq("rowText ON, kept, not installed -> the not-installed text (RF-003)", NOT_INSTALLED, PlayChoice.rowText(ON, true, false));
    eq("rowText absent, kept, not installed -> the not-installed text", NOT_INSTALLED, PlayChoice.rowText(ABSENT, true, false));
    eq("rowText ON, neither -> the not-installed text, verbatim", NOT_INSTALLED, PlayChoice.rowText(ON, false, false));
    eq("TITLE", "Google Play", PlayChoice.TITLE);

    // tap
    eq("tap OFF -> TURN_ON", PlayChoice.Tap.TURN_ON, PlayChoice.tap(OFF, true, true));
    eq("tap absent, neither -> TURN_ON", PlayChoice.Tap.TURN_ON, PlayChoice.tap(ABSENT, false, false));
    eq("tap ON, neither -> OPEN_STORE", PlayChoice.Tap.OPEN_STORE, PlayChoice.tap(ON, false, false));
    eq("tap ON, installed -> CONFIRM_OFF", PlayChoice.Tap.CONFIRM_OFF, PlayChoice.tap(ON, false, true));
    eq("tap ON, kept and installed -> CONFIRM_OFF", PlayChoice.Tap.CONFIRM_OFF, PlayChoice.tap(ON, true, true));
    eq("tap ON, kept, not installed -> OPEN_STORE (RF-003)", PlayChoice.Tap.OPEN_STORE, PlayChoice.tap(ON, true, false));
    eq("tap absent, vending kept, not installed -> OPEN_STORE", PlayChoice.Tap.OPEN_STORE, PlayChoice.tap(ABSENT, true, false));
    eq("tap absent, vending kept and installed -> CONFIRM_OFF", PlayChoice.Tap.CONFIRM_OFF, PlayChoice.tap(ABSENT, true, true));
    eq("tap absent, vending installed, not kept -> CONFIRM_OFF", PlayChoice.Tap.CONFIRM_OFF, PlayChoice.tap(ABSENT, false, true));

    // RF-004: On with Play Store missing, then Play Store installed from the App Store, then the row read again on
    // return. The first reading opens the App Store; each later reading (installed before or after decide writes the
    // keep line, or archived on a later sign-in) reads "On" and offers Off.
    eq("RF-004 before the install: the not-installed text", NOT_INSTALLED, PlayChoice.rowText(ON, false, false));
    eq("RF-004 before the install: the tap opens the App Store", PlayChoice.Tap.OPEN_STORE, PlayChoice.tap(ON, false, false));
    eq("RF-004 installed, keep line not written yet: On", "On", PlayChoice.rowText(ON, false, true));
    eq("RF-004 installed, keep line not written yet: the tap asks before Off", PlayChoice.Tap.CONFIRM_OFF, PlayChoice.tap(ON, false, true));
    eq("RF-004 installed and kept On-demand by decide: On", "On",
        PlayChoice.rowText(ON, PlayChoice.keepModeOnInstall(ON, VENDING, "off") != null, true));
    eq("RF-004 installed and kept On-demand by decide: the tap asks before Off", PlayChoice.Tap.CONFIRM_OFF,
        PlayChoice.tap(ON, PlayChoice.keepModeOnInstall(ON, VENDING, "off") != null, true));

    // onMarks: each installed stack member, Play Store first (RF-002)
    eq("onMarks all three installed", Arrays.asList(VENDING, GMS, GSF), PlayChoice.onMarks(p -> true));
    eq("onMarks nothing installed", Collections.emptyList(), PlayChoice.onMarks(p -> false));
    eq("onMarks services installed, Play Store not", Arrays.asList(GMS, GSF),
        PlayChoice.onMarks(p -> GMS.equals(p) || GSF.equals(p)));
    eq("onMarks Play services alone (no GSF on Endospore)", Collections.singletonList(GMS), PlayChoice.onMarks(GMS::equals));
    eq("onMarks Play Store alone", Collections.singletonList(VENDING), PlayChoice.onMarks(VENDING::equals));
    final Set<String> asked = new HashSet<>();
    PlayChoice.onMarks(p -> { asked.add(p); return true; });
    eq("onMarks asks about the three stack members only", new HashSet<>(Arrays.asList(VENDING, GMS, GSF)), asked);

    // keepModeOnInstall
    for (String p : new String[] {VENDING, GMS, GSF}) {
      for (String d : new String[] {"off", "installed", "auto"}) {
        eq("keepModeOnInstall ON " + p + " default " + d + " -> ondemand", "ondemand", PlayChoice.keepModeOnInstall(ON, p, d));
        eq("keepModeOnInstall ABSENT " + p + " default " + d + " -> default", d, PlayChoice.keepModeOnInstall(ABSENT, p, d));
        eq("keepModeOnInstall OFF " + p + " default " + d + " -> default", d, PlayChoice.keepModeOnInstall(OFF, p, d));
      }
    }
    for (PlayChoice.State s : PlayChoice.State.values()) {
      for (String p : new String[] {"com.example.app", "app.grapheneos.apps", "com.google.android.youtube", null}) {
        eq("keepModeOnInstall " + s + " " + p + " -> default, untouched", "off", PlayChoice.keepModeOnInstall(s, p, "off"));
        eq("keepModeOnInstall " + s + " " + p + " (installed) -> default, untouched", "installed",
            PlayChoice.keepModeOnInstall(s, p, "installed"));
      }
    }

    // userKeepsOnInstall: Play Store alone, Play on only
    eq("userKeepsOnInstall ON vending", true, PlayChoice.userKeepsOnInstall(ON, VENDING));
    eq("userKeepsOnInstall ON gms", false, PlayChoice.userKeepsOnInstall(ON, GMS));
    eq("userKeepsOnInstall ON gsf", false, PlayChoice.userKeepsOnInstall(ON, GSF));
    eq("userKeepsOnInstall ON another app", false, PlayChoice.userKeepsOnInstall(ON, "com.example.app"));
    eq("userKeepsOnInstall ABSENT vending", false, PlayChoice.userKeepsOnInstall(ABSENT, VENDING));
    eq("userKeepsOnInstall OFF vending", false, PlayChoice.userKeepsOnInstall(OFF, VENDING));

    // offDrops and the reconcile guard
    eq("offDrops is Play Store alone (B1 (i))", Collections.singleton(VENDING), PlayChoice.offDrops());
    eq("blocksVendingReadd OFF", true, PlayChoice.blocksVendingReadd(OFF));
    eq("blocksVendingReadd ON", false, PlayChoice.blocksVendingReadd(ON));
    eq("blocksVendingReadd ABSENT (absent is never off)", false, PlayChoice.blocksVendingReadd(ABSENT));

    // offered: GrapheneOS App Store present, a stored profile, online
    eq("offered: store, STORED, online", true, PlayChoice.offered(true, "STORED", false));
    eq("offered: no store (Diaspore)", false, PlayChoice.offered(false, "STORED", false));
    eq("offered: a throwaway (LOCAL)", false, PlayChoice.offered(true, "LOCAL", false));
    eq("offered: offline", false, PlayChoice.offered(true, "STORED", true));
    eq("offered: session type unknown yet", false, PlayChoice.offered(true, "", false));

    // the Off warning drafts
    eq("OFF_MESSAGE", "Turning Google Play off removes Play Store from this profile at the next save. Your Google account"
        + " is signed out here, and apps that sign in with it will ask again.", PlayChoice.OFF_MESSAGE);
    eq("OFF_CONFIRM", "Turn off", PlayChoice.OFF_CONFIRM);
    eq("OFF_CANCEL", "Cancel", PlayChoice.OFF_CANCEL);

    System.out.println(fails == 0 ? "cases passed" : "cases FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
