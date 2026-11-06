#!/usr/bin/env bash
# test-app-drops-java.sh [<ProfileActivity.java>] [--mutate] -- captureAppDrops' drop decision and pmDroppable's parity
# with it, RUN rather than compiled.
#
# WHY THIS IS COMMITTED. captureAppDrops writes the three files that decide what the logoff seal leaves out:
# nowhere-appdrop.list (roamd's NOWHERE_DROP_LIST: a listed package's CE, DE and external data stay OUT of the seal),
# nowhere-appkeepcode.list (roamd subtracts it on the code side, so an inferred orphan keeps its APK bytes) and
# nowhere-apporphan.list (re-pointed). The agent's loadDropList subtracts only the keep-set, so nothing downstream
# protects a bundled app, whose data IS the profile: the chooser's skips are the only guard. Until this suite the only
# off-device check was one source-level pin in test-yourapps-off-row.sh; none of the decision was executed.
#
# captureAppDrops, pmDroppable, isBundledSystem, both explicitlyTurnedOff forms, inferredOrphans, readAppModes, the
# readAppModesIn it delegates to (NWP-20261112-07), the readAppModesStrictIn and parseAppModes that one delegates to
# (NWP-20261112-03), readAppKeep, and the inferredOrphansStrict and recordInferredOrphan beside inferredOrphans
# (NWP-20261123-09) are LIFTED verbatim out of ProfileActivity.java, with SettingsText.read (the strict reader's read),
# with StoreInstaller's AtomicIo seam, FILE_IO and both writeAtomic overloads (which captureAppDrops now writes through)
# (`private` stripped, brace-matched, like test-resolvable-keep-java.sh), with the constants they read, into a harness
# class that supplies getFilesDir() (a temp dir), getPackageName() (com.nowhere.chooser) and getPackageManager() (a
# stub answering per package), compiled against small Android stubs and RUN. An anchor that moved, or braces that do
# not balance, is EXTRACTION FAILED (exit 2), never a pass.
#
# EQUIVALENT MUTANTS, DELIBERATELY ABSENT FROM THE LIST BELOW. The launcher pass reads pm.getApplicationInfo(p, 0)
# twice -- once in isBundledSystem and again in its own try block (FLAG_SYSTEM, FLAG_UPDATED_SYSTEM_APP, sourceDir) --
# and pmDroppable likewise calls isBundledSystem before its own flag tests. So removing just the isBundledSystem
# call, or just one of the flag tests, from either place changes nothing observable: the other copy of the same
# check still answers. Do not add them back as "missing". Only removing the duplicates TOGETHER changes behaviour,
# and that is what the mutants below do.
#
# What this does NOT prove: the device run (switch one app Off, keep another, sign out and in: the Off app's data is
# gone, the kept app's is not, a bundled app is untouched) stays on the backlog row.
#
#   bash test-app-drops-java.sh              # the cases
#   bash test-app-drops-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; else SUT="$a"; fi
done
[ -f "$SUT" ] || { echo "test-app-drops-java: FAIL -- no such file: $SUT"; exit 2; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-app-drops-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

# Every temp of this suite, java.io.tmpdir included, lives inside $WORK.
WORK="$(mktemp -d)" || exit 2; trap 'rm -rf "$WORK"' EXIT

SIGS=(
  'static boolean isBundledSystem('
  'private boolean pmDroppable('
  'private java.util.LinkedHashSet<String> explicitlyTurnedOff() {'
  'static java.util.LinkedHashSet<String> explicitlyTurnedOff(android.content.Context ctx) {'
  'private java.util.LinkedHashSet<String> inferredOrphans('
  'private java.util.LinkedHashSet<String> inferredOrphansStrict('
  'private void recordInferredOrphan('
  'private java.util.LinkedHashMap<String,String> readAppModes('
  'static java.util.LinkedHashMap<String,String> readAppModesIn('
  'static java.util.LinkedHashMap<String,String> readAppModesStrictIn('
  'static java.util.LinkedHashMap<String,String> parseAppModes('
  'private java.util.LinkedHashSet<String> readAppKeep('
  'private void captureAppDrops('
)
CONSTS=(
  'static final String MODE_INSTALLED = '
  'static final String MODE_ONDEMAND  = '
  'static final String MODE_AUTO      = '
  'static final String GMS_PKG = '
  'static final String GSF_PKG = '
  'static final String VENDING_PKG = '
)

extract() { # extract <file> <signature-fragment>: exit 2 unless it matches exactly once
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
n = src.count(sys.argv[2])
if n != 1:
    sys.stderr.write('EXTRACTION FAILED: %d matches of %s\n' % (n, sys.argv[2])); sys.exit(2)
i = src.find(sys.argv[2])
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('EXTRACTION FAILED: unbalanced ' + sys.argv[2] + '\n'); sys.exit(2)
PY
}

constline() { # constline <file> <prefix>: the whole declaration line, exit 2 unless it matches exactly once
  python3 - "$1" "$2" <<'PY'
import io, sys
lines = [l.strip() for l in io.open(sys.argv[1], encoding='utf-8') if l.strip().startswith(sys.argv[2])]
if len(lines) != 1:
    sys.stderr.write('EXTRACTION FAILED: %d matches of %s\n' % (len(lines), sys.argv[2])); sys.exit(2)
print(lines[0])
PY
}

# lift_si -> $WORK/StoreInstaller.java: the writeAtomic the lifted writers now call, with its AtomicIo seam and FILE_IO,
# cut verbatim out of StoreInstaller.java (a piece that is missing or matches twice is EXTRACTION FAILED, exit 2).
brace_block() { # brace_block <file> <signature prefix>: from the line that starts with it to the brace that closes it
  awk -v sig="$2" '
    !on && index($0, sig) == 1 { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}
lift_si() {
  local si="$HERE/src/com/nowhere/chooser/StoreInstaller.java" piece
  {
    echo "import java.io.File;"
    echo "final class StoreInstaller {"
    brace_block "$si" "    interface AtomicIo {"
    awk '!on && index($0, "    static final AtomicIo FILE_IO = ") == 1 { on=1 } on { print } on && $0 == "    };" { exit }' "$si"
    brace_block "$si" "    static void writeAtomic(File f, String content) throws "
    brace_block "$si" "    static void writeAtomic(File f, String content, AtomicIo io) throws "
    echo "}"
  } > "$WORK/StoreInstaller.java"
  for piece in "    interface AtomicIo {" "    static final AtomicIo FILE_IO = " \
               "    static void writeAtomic(File f, String content) throws " \
               "    static void writeAtomic(File f, String content, AtomicIo io) throws "; do
    [ "$(grep -cF -- "$piece" "$WORK/StoreInstaller.java" || true)" = 1 ] || return 1
  done
  [ "$(grep -c '^    };$' "$WORK/StoreInstaller.java" || true)" = 1 ] || return 1
}

# lift_st -> $WORK/SettingsText.java: SettingsText.read, the strict reader inferredOrphansStrict calls (NWP-20261123-09),
# cut verbatim out of SettingsText.java into a default-package class (never the whole file: its package line).
lift_st() {
  local body
  body=$(extract "$HERE/src/com/nowhere/chooser/SettingsText.java" 'static String read(java.io.File f) {') || return 1
  [ -n "$body" ] || return 1
  printf 'final class SettingsText {\n%s\n}\n' "$body" > "$WORK/SettingsText.java"
}

lift() { # lift <ProfileActivity.java> -> $WORK/Lifted.java
  local src="$1" sig body
  {
    echo 'import android.content.Intent;'
    echo 'import android.content.pm.PackageManager;'
    echo 'final class Lifted extends android.content.Context {'
    echo '  final java.io.File dir; final PackageManager pm;'
    echo '  Lifted(java.io.File dir, PackageManager pm) { this.dir = dir; this.pm = pm; }'
    echo '  @Override public java.io.File getFilesDir() { return dir; }'
    echo '  @Override public String getPackageName() { return "com.nowhere.chooser"; }'
    echo '  PackageManager getPackageManager() { return pm; }'
    for sig in "${CONSTS[@]}"; do
      body=$(constline "$src" "$sig") || return 1
      [ -n "$body" ] || return 1
      printf '  %s\n' "$body"
    done
    for sig in "${SIGS[@]}"; do
      body=$(extract "$src" "$sig") || return 1
      [ -n "$body" ] || return 1
      printf '%s\n\n' "${body#private }"
    done
    echo '}'
  } > "$WORK/Lifted.java"
}

mkdir -p "$WORK/stubs/android/content/pm" "$WORK/stubs/android/util"
cat > "$WORK/stubs/android/content/Context.java" <<'JAVA'
package android.content;
public abstract class Context {
  public abstract java.io.File getFilesDir();
  public abstract String getPackageName();
}
JAVA
cat > "$WORK/stubs/android/content/Intent.java" <<'JAVA'
package android.content;
public class Intent {
  public static final String ACTION_MAIN = "android.intent.action.MAIN";
  public static final String CATEGORY_LAUNCHER = "android.intent.category.LAUNCHER";
  public Intent(String action) {}
  public Intent addCategory(String c) { return this; }
}
JAVA
cat > "$WORK/stubs/android/content/pm/ActivityInfo.java" <<'JAVA'
package android.content.pm;
public class ActivityInfo { public String packageName; }
JAVA
cat > "$WORK/stubs/android/content/pm/ResolveInfo.java" <<'JAVA'
package android.content.pm;
public class ResolveInfo { public ActivityInfo activityInfo = new ActivityInfo(); }
JAVA
cat > "$WORK/stubs/android/content/pm/ApplicationInfo.java" <<'JAVA'
package android.content.pm;
public class ApplicationInfo {
  public static final int FLAG_SYSTEM = 1;
  public static final int FLAG_UPDATED_SYSTEM_APP = 1 << 7;
  public int flags;
  public String sourceDir;
}
JAVA
cat > "$WORK/stubs/android/content/pm/PackageManager.java" <<'JAVA'
package android.content.pm;
import android.content.Intent;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
public class PackageManager {
  public static class NameNotFoundException extends Exception {}
  /** What getApplicationInfo(p, 0) answers for a package. */
  public enum Kind { USER, SYSTEM, UPDATED, NOSRC, THROWS }
  public final Map<String, Kind> kind = new HashMap<>();
  /** Launcher-visible packages, in launcher order -- independent of kind. */
  public final List<String> visible = new ArrayList<>();
  public ApplicationInfo getApplicationInfo(String p, int flags) throws NameNotFoundException {
    Kind k = kind.get(p);
    if (k == null || k == Kind.THROWS) throw new NameNotFoundException();
    ApplicationInfo ai = new ApplicationInfo();
    ai.sourceDir = k == Kind.NOSRC ? "" : "/data/app/" + p + "/base.apk";
    if (k == Kind.SYSTEM) ai.flags = ApplicationInfo.FLAG_SYSTEM;
    if (k == Kind.UPDATED) ai.flags = ApplicationInfo.FLAG_UPDATED_SYSTEM_APP;
    return ai;
  }
  public List<ResolveInfo> queryIntentActivities(Intent i, int flags) {
    List<ResolveInfo> out = new ArrayList<>();
    for (String p : visible) { ResolveInfo ri = new ResolveInfo(); ri.activityInfo.packageName = p; out.add(ri); }
    return out;
  }
}
JAVA
cat > "$WORK/stubs/android/util/Log.java" <<'JAVA'
package android.util;
public class Log {
  /** Every line logged, so a case can tell a refusal from a write that was tried (NWP-20261123-09). */
  public static final java.util.List<String> lines = new java.util.ArrayList<>();
  public static int i(String tag, String msg) { lines.add(tag + ": " + msg); return 0; }
  public static int w(String tag, String msg) { lines.add(tag + ": " + msg); return 0; }
  public static int w(String tag, String msg, Throwable t) {
    lines.add(tag + ": " + msg);
    if (t != null) lines.add("THROWN " + tag + ": " + msg);
    return 0;
  }
}
JAVA

cat > "$WORK/Cases.java" <<'JAVA'
import android.content.pm.PackageManager;
import android.content.pm.PackageManager.Kind;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public class Cases {
  static final String OWN = "com.nowhere.chooser";
  static final String VEND = "com.android.vending";
  static final String GMS = "com.google.android.gms";
  static int fails = 0;
  static File dir;
  static PackageManager pm;

  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }
  static void fresh() throws Exception {
    dir = Files.createTempDirectory("ad").toFile();
    pm = new PackageManager();
    android.util.Log.lines.clear();
  }
  /** "Exists, cannot be read": an empty DIRECTORY at the file's path (a FileReader on it throws). */
  static void unreadable(String name) { new File(dir, name).mkdir(); }
  static boolean isEmptyDir(String name) {
    File f = new File(dir, name); String[] l = f.list();
    return f.isDirectory() && l != null && l.length == 0;
  }
  static boolean logged(String s) { for (String l : android.util.Log.lines) if (l.contains(s)) return true; return false; }
  static boolean noTmp() {
    for (String n : new String[] {"nowhere-appdrop.list", "nowhere-appkeepcode.list", "nowhere-apporphan.list"})
      if (has(n + ".tmp")) return false;
    return true;
  }
  static void put(String name, String text) throws Exception {
    Files.write(new File(dir, name).toPath(), text.getBytes(StandardCharsets.UTF_8));
  }
  static boolean has(String name) { return new File(dir, name).exists(); }
  static List<String> read(String name) throws Exception {
    File f = new File(dir, name);
    if (!f.exists()) return new ArrayList<>();
    String s = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
    return s.isEmpty() ? new ArrayList<>() : new ArrayList<>(Arrays.asList(s.split("\n", -1)).subList(0, s.split("\n", -1).length - 1));
  }
  static List<String> drop() throws Exception { return read("nowhere-appdrop.list"); }
  static List<String> keepcode() throws Exception { return read("nowhere-appkeepcode.list"); }
  static List<String> orphan() throws Exception { return read("nowhere-apporphan.list"); }
  static void user(String p, boolean launcher) { pm.kind.put(p, Kind.USER); if (launcher) pm.visible.add(p); }
  static void run() { new Lifted(dir, pm).captureAppDrops(); }
  static int count(List<String> l, String p) { int n = 0; for (String s : l) if (s.equals(p)) n++; return n; }

  public static void main(String[] a) throws Exception {
    // C1
    fresh(); user("a", true); run();
    check("C1 launcher-visible user app, not kept -> listed", drop().equals(Arrays.asList("a")), "drop=" + drop());

    // C2
    for (String line : new String[] {"a", "a\tondemand", "a\tauto"}) {
      fresh(); user("a", true); put("nowhere-appkeep", line + "\n"); run();
      check("C2 kept as [" + line.replace("\t", "<TAB>") + "] -> never listed", drop().isEmpty() && !has("nowhere-appdrop.list"), "drop=" + drop());
    }

    // C3, C4
    fresh(); pm.kind.put("s", Kind.SYSTEM); pm.visible.add("s"); run();
    check("C3 FLAG_SYSTEM -> never listed", drop().isEmpty(), "drop=" + drop());
    fresh(); pm.kind.put("u", Kind.UPDATED); pm.visible.add("u"); run();
    check("C4 FLAG_UPDATED_SYSTEM_APP -> never listed", drop().isEmpty(), "drop=" + drop());

    // C5, C6, C7
    fresh(); pm.kind.put("t", Kind.THROWS); pm.visible.add("t"); run();
    check("C5 getApplicationInfo throws -> never listed", drop().isEmpty(), "drop=" + drop());
    fresh(); pm.kind.put("n", Kind.NOSRC); pm.visible.add("n"); run();
    check("C6 empty sourceDir -> never listed", drop().isEmpty(), "drop=" + drop());
    fresh(); user(OWN, true); run();
    check("C7 own package -> never listed", drop().isEmpty(), "drop=" + drop());

    // C8a: archived (not visible, PM throws), switched Off
    fresh(); pm.kind.put("arch", Kind.THROWS); put("nowhere-appoff.list", "arch\n"); run();
    check("C8a archived app named in nowhere-appoff.list -> listed", drop().equals(Arrays.asList("arch")), "drop=" + drop());
    check("C8a an explicit Off is not code-retained (no keepcode file)", !has("nowhere-appkeepcode.list"), "keepcode=" + keepcode());
    // C8b
    fresh(); pm.kind.put("arch", Kind.THROWS); put("nowhere-appoff.list", "arch\n"); put("nowhere-appkeep", "arch\tondemand\n"); run();
    check("C8b the same app also kept -> not listed", drop().isEmpty(), "drop=" + drop());
    // C8c
    fresh(); pm.kind.put("bundled", Kind.SYSTEM); put("nowhere-appoff.list", "bundled\n"); run();
    check("C8c not launcher-visible, PM says FLAG_SYSTEM, named Off -> not listed", drop().isEmpty(), "drop=" + drop());

    // C9: vending as Off residue plus inferred orphan
    fresh(); user(VEND, true); put("nowhere-appoff.list", VEND + "\n"); put("nowhere-apporphan.list", VEND + "\n"); run();
    check("C9 vending line in appoff is residue: listed ONCE", count(drop(), VEND) == 1, "drop=" + drop());
    check("C9 vending is code-retained", keepcode().equals(Arrays.asList(VEND)), "keepcode=" + keepcode());
    fresh();
    check("C9 control: explicitlyTurnedOff drops vending/gms/gsf and keeps others",
        explicitOff("x\n" + VEND + "\n" + GMS + "\ncom.google.android.gsf\ny\n").equals(Arrays.asList("x", "y")), "got=" + explicitOff("x\n" + VEND + "\n" + GMS + "\ncom.google.android.gsf\ny\n"));

    // C10
    fresh(); user(VEND, true); put("nowhere-apporphan.list", VEND + "\n"); run();
    check("C10 launcher-visible inferred orphan -> listed exactly once", count(drop(), VEND) == 1, "drop=" + drop());
    check("C10 ... and in nowhere-appkeepcode.list", keepcode().equals(Arrays.asList(VEND)), "keepcode=" + keepcode());
    check("C10 ... and nowhere-apporphan.list still names it", orphan().equals(Arrays.asList(VEND)), "orphan=" + orphan());

    // C11
    // the orphan is ALSO switched Off by the user (a package other than the filtered Play three)
    fresh(); pm.kind.put("orph", Kind.THROWS); put("nowhere-apporphan.list", "orph\n"); put("nowhere-appoff.list", "orph\n"); run();
    check("C11 inferred orphan also switched Off -> in the drop list", count(drop(), "orph") == 1, "drop=" + drop());
    check("C11 ... NOT in nowhere-appkeepcode.list", !keepcode().contains("orph") && !has("nowhere-appkeepcode.list"), "keepcode=" + keepcode());
    check("C11 ... and nowhere-apporphan.list no longer names it", !orphan().contains("orph"), "orphan=" + orphan());

    // C12
    fresh(); user("o1", true); user("o2", true); put("nowhere-apporphan.list", "o1\no2\n"); put("nowhere-appkeep", "o1\n"); run();
    check("C12 kept orphan is in neither the drop list nor keepcode",
        !drop().contains("o1") && !keepcode().contains("o1"), "drop=" + drop() + " keepcode=" + keepcode());
    check("C12 the other orphan is dropped and code-retained", drop().equals(Arrays.asList("o2")) && keepcode().equals(Arrays.asList("o2")),
        "drop=" + drop() + " keepcode=" + keepcode());
    check("C12 nowhere-apporphan.list is rewritten naming only the other", orphan().equals(Arrays.asList("o2")), "orphan=" + orphan());

    // C13
    fresh(); put("nowhere-appdrop.list", "stale\n"); put("nowhere-appkeepcode.list", "stale\n");
    put("nowhere-apporphan.list", "k\n"); put("nowhere-appkeep", "k\n"); user("k", true); run();
    check("C13 empty result deletes nowhere-appdrop.list", !has("nowhere-appdrop.list"), "still present: " + drop());
    check("C13 empty result deletes nowhere-appkeepcode.list", !has("nowhere-appkeepcode.list"), "still present: " + keepcode());
    check("C13 empty result deletes nowhere-apporphan.list", !has("nowhere-apporphan.list"), "still present: " + orphan());

    // C14
    fresh(); user("z", true); user("y", true); user("x", true); put("nowhere-appoff.list", "y\nw\n"); pm.kind.put("w", Kind.THROWS);
    pm.visible.add("z"); pm.visible.add("y"); run();
    check("C14 no package twice, launcher order kept, Off-only package last", drop().equals(Arrays.asList("z", "y", "x", "w")), "drop=" + drop());

    // C15 parity
    String[] names = {"p-user", "p-system", "p-updated", "p-nosrc", "p-throws", OWN};
    Kind[] kinds = {Kind.USER, Kind.SYSTEM, Kind.UPDATED, Kind.NOSRC, Kind.THROWS, Kind.USER};
    fresh();
    for (int i = 0; i < names.length; i++) { pm.kind.put(names[i], kinds[i]); pm.visible.add(names[i]); }
    run();
    List<String> listed = drop();
    Lifted l = new Lifted(dir, pm);
    for (String n : names) {
      boolean in = listed.contains(n);
      check("C15 parity for " + n + " (pmDroppable " + l.pmDroppable(n) + ", listed " + in + ")", l.pmDroppable(n) == in, "pmDroppable disagrees with the logoff pass");
    }
    check("C15 control: only the plain user app is listed", listed.equals(Arrays.asList("p-user")), "listed=" + listed);
    check("C15 pmDroppable(null) and (empty) are false", !l.pmDroppable(null) && !l.pmDroppable(""), "true");

    // D1 (NWP-20261123-09): nowhere-apporphan.list exists but cannot be read. Read as empty, vending would be listed
    // for drop with no keepcode line (its APK bytes leave #apps), and kc == 0 would delete the record.
    fresh(); user(VEND, true); unreadable("nowhere-apporphan.list");
    put("nowhere-appdrop.list", "stale\n"); put("nowhere-appkeepcode.list", "prev\n"); run();
    check("D1 orphan record unreadable -> nowhere-appdrop.list removed (the seal carries everything)",
        !has("nowhere-appdrop.list"), "drop=" + drop());
    check("D1 ... nowhere-appkeepcode.list untouched", keepcode().equals(Arrays.asList("prev")), "keepcode=" + keepcode());
    check("D1 ... nowhere-apporphan.list untouched (still the unreadable entry)", isEmptyDir("nowhere-apporphan.list"),
        "exists=" + has("nowhere-apporphan.list"));
    check("D1 ... no .tmp left", noTmp(), "a .tmp is left");
    check("D1 ... the log names the orphan record", logged("captureAppDrops: nowhere-apporphan.list unreadable"),
        "lines=" + android.util.Log.lines);

    // D2: nowhere-appkeep exists but cannot be read. Read as empty, every kept user app would be listed for drop.
    fresh(); user("a", true); unreadable("nowhere-appkeep");
    put("nowhere-appdrop.list", "stale\n"); put("nowhere-appkeepcode.list", "prev\n"); put("nowhere-apporphan.list", "o9\n"); run();
    check("D2 keep-set unreadable -> nowhere-appdrop.list removed", !has("nowhere-appdrop.list"), "drop=" + drop());
    check("D2 ... nowhere-appkeepcode.list untouched", keepcode().equals(Arrays.asList("prev")), "keepcode=" + keepcode());
    check("D2 ... nowhere-apporphan.list untouched", orphan().equals(Arrays.asList("o9")), "orphan=" + orphan());
    check("D2 ... nowhere-appkeep untouched", isEmptyDir("nowhere-appkeep"), "exists=" + has("nowhere-appkeep"));
    check("D2 ... no .tmp left", noTmp(), "a .tmp is left");
    check("D2 ... the log names the keep-set", logged("captureAppDrops: nowhere-appkeep unreadable"),
        "lines=" + android.util.Log.lines);

    // D2b: both unreadable.
    fresh(); user("a", true); unreadable("nowhere-appkeep"); unreadable("nowhere-apporphan.list");
    put("nowhere-appdrop.list", "stale\n"); run();
    check("D2b both unreadable -> nowhere-appdrop.list removed, the record untouched",
        !has("nowhere-appdrop.list") && isEmptyDir("nowhere-apporphan.list") && !has("nowhere-appkeepcode.list"),
        "drop=" + drop() + " keepcode=" + keepcode());
    check("D2b ... the log names both files", logged("captureAppDrops: nowhere-appkeep and nowhere-apporphan.list unreadable"),
        "lines=" + android.util.Log.lines);

    // D3: nowhere-apporphan.list ABSENT is empty, not unknown -- today's behaviour (C1 and C14 also run with no record).
    fresh(); user(VEND, true); run();
    check("D3 orphan record absent -> vending listed as an ordinary user app", drop().equals(Arrays.asList(VEND)), "drop=" + drop());
    check("D3 ... no keepcode file and no record written", !has("nowhere-appkeepcode.list") && !has("nowhere-apporphan.list"),
        "keepcode=" + keepcode() + " orphan=" + orphan());

    // D4a: recordInferredOrphan over an unreadable record writes nothing. The directory fixture alone cannot show a
    // write attempt (the rename over a directory fails and the .tmp is removed), so the log is checked too.
    fresh(); unreadable("nowhere-apporphan.list"); new Lifted(dir, pm).recordInferredOrphan("o2");
    check("D4a record unreadable -> left as it was, no .tmp", isEmptyDir("nowhere-apporphan.list") && noTmp(),
        "exists=" + has("nowhere-apporphan.list"));
    check("D4a ... the refusal is logged", logged("nowhere-apporphan.list unreadable -- nothing written (NWP-20261123-09)"),
        "lines=" + android.util.Log.lines);
    check("D4a ... no write was tried", !logged("THROWN NowhereChooser: recordInferredOrphan"), "lines=" + android.util.Log.lines);
    check("D4a ... the refusal names no package", !logged("o2"), "lines=" + android.util.Log.lines);

    // D4b: a readable record keeps every entry.
    fresh(); put("nowhere-apporphan.list", "o1\n"); new Lifted(dir, pm).recordInferredOrphan("o2");
    check("D4b readable record naming o1, record o2 -> exactly o1, o2", orphan().equals(Arrays.asList("o1", "o2")), "orphan=" + orphan());
    // D4c: absent record -> created with the one package.
    fresh(); new Lifted(dir, pm).recordInferredOrphan("o2");
    check("D4c absent record, record o2 -> exactly o2", orphan().equals(Arrays.asList("o2")), "orphan=" + orphan());

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }

  static List<String> explicitOff(String text) throws Exception {
    fresh(); put("nowhere-appoff.list", text);
    return new ArrayList<>(new Lifted(dir, pm).explicitlyTurnedOff());
  }
}
JAVA

suite() { # suite <ProfileActivity.java> [quiet]  -> 0 pass, 1 cases failed, 2 would not lift/compile
  rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  lift "$1" && lift_si && lift_st || { [ "${2:-}" = quiet ] || echo "EXTRACTION FAILED"; return 2; }
  "$JAVAC" -nowarn -d "$WORK/out" $(find "$WORK/stubs" -name '*.java') "$WORK/Lifted.java" "$WORK/StoreInstaller.java" "$WORK/SettingsText.java" "$WORK/Cases.java" \
      2>"$WORK/javac.err" \
    || { [ "${2:-}" = quiet ] || { echo "compile failed:"; head -8 "$WORK/javac.err"; }; return 2; }
  # fresh()'s createTempDirectory uses java.io.tmpdir, which is /tmp whatever TMPDIR says: point it at $WORK.
  local jt=-Djava.io.tmpdir="$WORK"
  if [ "${2:-}" = quiet ]; then "$JAVA" "$jt" -cp "$WORK/out" Cases >/dev/null 2>&1; else "$JAVA" "$jt" -cp "$WORK/out" Cases; fi
}

suite "$SUT"; RC=$?
[ "$RC" = 0 ] || { [ "$MUTATE" = 0 ] && exit $RC; echo; echo "suite already failing -- fix that before mutating"; exit $RC; }
[ "$MUTATE" = 0 ] && exit 0

echo
echo "== mutations (each MUST be convicted) =="
MRC=0
CAP='/private void captureAppDrops/,/private void captureAppCode/'
PMD='/private boolean pmDroppable/,/^    }/'
mutant() { # mutant <label> <sed expr>... -- a mutant that does not change the file counts as a failure
  local label="$1" m="$WORK/mut.java"; shift
  local args=(); for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then printf '  ⚠ NOT APPLIED  %s\n' "$label"; MRC=1; return; fi
  # Only exit 1 (a case FAILED) convicts; 2 (would not lift or compile) means the mutant is broken, never a pass.
  local rc=0; suite "$m" quiet || rc=$?
  case "$rc" in
    0) printf '  ⚠ SURVIVED  %s\n' "$label"; MRC=1 ;;
    1) printf '  convicted   %s\n' "$label" ;;
    *) printf '  ⚠ DID NOT COMPILE/EXTRACT  %s\n' "$label"; MRC=1 ;;
  esac
}
mutant 'launcher pass: isBundledSystem + both flag tests removed together' \
  "$CAP{/part of the OS, not a user app/d;/FLAG_SYSTEM) != 0) continue;/d;/FLAG_UPDATED_SYSTEM_APP) != 0) continue;/d}"
mutant 'launcher pass: kept skip removed'          "$CAP{s/if (kept.contains(p)) continue;//}"
mutant 'launcher pass: sourceDir test removed'     "$CAP{/ai.sourceDir.isEmpty()) continue;/d}"
mutant 'launcher pass: PM-throw continue falls through' "$CAP{s|continue; // cannot confirm it is user-installed|// cannot confirm it is user-installed|}"
mutant 'launcher pass: own-package test removed'   "$CAP{s/p.isEmpty() || getPackageName().equals(p)) continue;/p.isEmpty()) continue;/}"
mutant 'launcher pass: inferred-before-seen check removed' "$CAP{/if (inferred.contains(p)) continue;/d}"
mutant 'explicit-Off pass: kept skip removed'      "$CAP{/for (String p : explicitOff)/{n;s/ || kept.contains(p)//}}"
mutant 'explicit-Off pass: isBundledSystem skip removed' "$CAP{/for (String p : explicitOff)/{n;n;d}}"
mutant 'explicitlyTurnedOff: vending/gms/gsf filter removed' '/if (VENDING_PKG.equals(ln) || GMS_PKG.equals(ln) || GSF_PKG.equals(ln)) continue;/d'
mutant 'kc == 0 no longer deletes nowhere-appkeepcode.list' 's/codeOut.delete();/;/'
mutant 'kc == 0 no longer deletes nowhere-apporphan.list'   's/orphanOut.delete();/;/'
mutant 'n == 0 no longer deletes nowhere-appdrop.list' "$CAP{/if (n == 0) {/{n;s/out.delete();/;/}}"
mutant 'strict orphan reader returns empty on a read error' \
  '/private java.util.LinkedHashSet<String> inferredOrphansStrict/,/^    }/{s/if (text == null) return null;/if (text == null) return new java.util.LinkedHashSet<>();/}'
mutant 'captureAppDrops reads the keep-set through readAppKeep() again' \
  "$CAP{s/final java.util.LinkedHashMap<String,String> keptModes = readAppModesStrictIn(getFilesDir());/final java.util.LinkedHashMap<String,String> keptModes = new java.util.LinkedHashMap<>(); for (String k : readAppKeep()) keptModes.put(k, MODE_INSTALLED);/}"
mutant 'null branch keeps the stale drop list'   "$CAP{/unreadable -- drop list removed/{n;s/out.delete();/;/}}"
mutant 'recordInferredOrphan writes on a null read' \
  '/private void recordInferredOrphan/,/^    }/{s/if (s == null) {/if (s == null) s = new java.util.LinkedHashSet<>(); if (false) {/}'
mutant 'pmDroppable: sourceDir test removed'       '/ai.sourceDir.isEmpty()) return false;/d'
mutant 'pmDroppable: catch returns true'           's|return false; // cannot confirm user-installed -> the seal will carry it|return true;|'
mutant 'pmDroppable: isBundledSystem + both flag tests removed together' \
  "$PMD{/isBundledSystem(pm, pkg)) return false;/d;/FLAG_SYSTEM) != 0) return false;/d;/FLAG_UPDATED_SYSTEM_APP) != 0) return false;/d}"

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
