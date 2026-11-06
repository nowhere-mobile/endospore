package com.nowhere.chooser;

import java.io.File;

/** NWP-20261105-03: keepAutoImpl's answer when the keep line could not be written, and getAppReply's three replies. */
public class KeepWriteFailCases {
  static int fails = 0;

  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }

  static String read(File f) throws Exception {
    return new String(java.nio.file.Files.readAllBytes(f.toPath()), java.nio.charset.StandardCharsets.UTF_8);
  }

  static File fresh(File root, String name) {
    File d = new File(root, name);
    d.mkdirs();
    StoreInstaller.reset();
    return d;
  }

  public static void main(String[] a) throws Exception {
    File root = new File(a[0]);
    String P = "org.example.app";

    File d = fresh(root, "write-throws");
    File keep = new File(d, "nowhere-appkeep");
    java.nio.file.Files.write(keep.toPath(), "org.other\tauto\n".getBytes("UTF-8"));
    StoreInstaller.failWrite = true;
    boolean r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, false, "auto");
    check("the write throws -> not kept", !r, "answered " + r);
    check("the write throws -> nowhere-appkeep unchanged", read(keep).equals("org.other\tauto\n"), read(keep));

    d = fresh(root, "read-throws");
    new File(d, "nowhere-appkeep").mkdirs();
    r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, false, "auto");
    check("the read throws (keep file is a directory) -> not kept", !r, "answered " + r);
    check("the read throws -> nothing written", StoreInstaller.writes == 0, "writes=" + StoreInstaller.writes);

    d = fresh(root, "clear-throws");
    StoreInstaller.failClear = true;
    r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, false, "auto");
    check("clearTurnedOff throws after the write -> kept", r, "answered " + r);
    check("clearTurnedOff throws -> the line is on disk", read(new File(d, "nowhere-appkeep")).equals(P + "\tauto\n"),
        read(new File(d, "nowhere-appkeep")));

    d = fresh(root, "present");
    keep = new File(d, "nowhere-appkeep");
    java.nio.file.Files.write(keep.toPath(), (P + "\ton-demand\n").getBytes("UTF-8"));
    r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, false, "auto");
    check("already present -> kept, no write", r && StoreInstaller.writes == 0 && read(keep).equals(P + "\ton-demand\n"),
        "answered " + r + " writes=" + StoreInstaller.writes);

    d = fresh(root, "over-plan");
    r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, true, "auto");
    check("over plan -> not kept, no write", !r && StoreInstaller.writes == 0 && !new File(d, "nowhere-appkeep").exists(),
        "answered " + r + " writes=" + StoreInstaller.writes);

    d = fresh(root, "off");
    r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, false, ProfileActivity.APPDEF_OFF);
    check("APPDEF_OFF -> kept, no write", r && StoreInstaller.writes == 0 && !new File(d, "nowhere-appkeep").exists(),
        "answered " + r + " writes=" + StoreInstaller.writes);

    d = fresh(root, "happy");
    r = StoreInstaller.keepAutoImpl(new android.content.Context(d), P, false, "auto");
    check("a clean write -> kept, line on disk", r && read(new File(d, "nowhere-appkeep")).equals(P + "\tauto\n"),
        "answered " + r);

    // Expected string first: run.sh stubs an absent getAppReply (origin/main) to return null, which must FAIL, not NPE.
    check("getAppReply kept", ("OK " + P).equals(StoreService.getAppReply(true, false, P)), StoreService.getAppReply(true, false, P));
    check("getAppReply kept, over plan flag ignored", ("OK " + P).equals(StoreService.getAppReply(true, true, P)), "");
    check("getAppReply not kept + over plan", ("OK-SESSION-ONLY " + P).equals(StoreService.getAppReply(false, true, P)),
        StoreService.getAppReply(false, true, P));
    check("getAppReply not kept + gate open", ("OK-UNSAVED " + P).equals(StoreService.getAppReply(false, false, P)),
        StoreService.getAppReply(false, false, P));

    System.out.println(fails == 0 ? "ALL CASES PASSED" : fails + " CASE(S) FAILED");
    System.exit(fails == 0 ? 0 : 1);
  }
}
