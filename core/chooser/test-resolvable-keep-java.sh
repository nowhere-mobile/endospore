#!/usr/bin/env bash
# test-resolvable-keep-java.sh [<ProfileActivity.java>] [--mutate] -- resolvableForKeep's three branches and the
# inferred-orphan list's reader and writer, RUN rather than compiled.
#
# WHY THIS IS COMMITTED. The seal-backed branch of resolvableForKeep is what lets a retained inferred orphan be
# re-added in a fresh user where Package Manager has no record of it (backlog: "A Play stack member the user never
# switched off is dropped from the seal at logoff, and can then never come back"). Its own comment calls it "the
# half without which the rest of this slice is inert", and on the 2026-08-30/31 lynx run it never fired because the
# App Store had pre-installed gms first. Nothing off-device executed it.
#
# So inferredOrphans, recordInferredOrphan, resolvableForKeep and isInstalledPkg are LIFTED verbatim out of
# ProfileActivity.java (`private` stripped, brace-matched, like test-ingest-event.sh), and with them StoreInstaller's
# AtomicIo seam, FILE_IO and both writeAtomic overloads (recordInferredOrphan writes through them), plus the
# inferredOrphansStrict both list readers now go through and the SettingsText.read it calls (NWP-20261123-09), into a harness class that
# supplies getFilesDir() (a temp dir) and getPackageManager() (a stub whose answer per package is installed /
# archived / absent), compiled against small Android stubs and RUN.
#
# What this does NOT prove: the pure on-device case (a Play-dependent app installed while the stack is orphaned and
# uninstalled) -- that device step stays on the backlog row. captureAppDrops' logoff re-point of the list is read
# only here and is not lifted.
#
#   bash test-resolvable-keep-java.sh              # the cases
#   bash test-resolvable-keep-java.sh --mutate     # ... plus mutants that must each CONVICT the suite
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/src/com/nowhere/chooser/ProfileActivity.java"
MUTATE=0
for a in "$@"; do
  if [ "$a" = "--mutate" ]; then MUTATE=1; else SUT="$a"; fi
done
[ -f "$SUT" ] || { echo "test-resolvable-keep-java: FAIL -- no such file: $SUT"; exit 2; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-resolvable-keep-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran

# Every temp of this suite, java.io.tmpdir included, lives inside $WORK.
WORK="$(mktemp -d)" || exit 2; trap 'rm -rf "$WORK"' EXIT

SIGS=(
  'private java.util.LinkedHashSet<String> inferredOrphans('
  'private java.util.LinkedHashSet<String> inferredOrphansStrict('
  'private void recordInferredOrphan('
  'private boolean resolvableForKeep('
  'private boolean isInstalledPkg('
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
    echo 'import android.content.pm.PackageManager;'
    echo 'final class Lifted {'
    echo '  final java.io.File dir; final PackageManager pm;'
    echo '  Lifted(java.io.File dir, PackageManager pm) { this.dir = dir; this.pm = pm; }'
    echo '  java.io.File getFilesDir() { return dir; }'
    echo '  PackageManager getPackageManager() { return pm; }'
    for sig in "${SIGS[@]}"; do
      body=$(extract "$src" "$sig") || return 1
      [ -n "$body" ] || return 1
      printf '%s\n\n' "${body#private }"
    done
    echo '}'
  } > "$WORK/Lifted.java"
}

mkdir -p "$WORK/stubs/android/content/pm" "$WORK/stubs/android/util"
cat > "$WORK/stubs/android/content/pm/PackageManager.java" <<'JAVA'
package android.content.pm;
import java.util.HashMap;
import java.util.Map;
public class PackageManager {
  public static final long MATCH_ARCHIVED_PACKAGES = 1L << 32;
  public static final long MATCH_UNINSTALLED_PACKAGES = 0x00002000L;
  public static class NameNotFoundException extends Exception {}
  public static class ApplicationInfoFlags {
    final long v;
    private ApplicationInfoFlags(long v) { this.v = v; }
    public static ApplicationInfoFlags of(long v) { return new ApplicationInfoFlags(v); }
  }
  /** installed: answers every query; archived: answers only the archived/uninstalled flags; absent: throws. */
  public enum State { INSTALLED, ARCHIVED, ABSENT }
  public final Map<String, State> state = new HashMap<>();
  State of(String p) { State s = state.get(p); return s == null ? State.ABSENT : s; }
  public ApplicationInfo getApplicationInfo(String p, int flags) throws NameNotFoundException {
    if (of(p) != State.INSTALLED) throw new NameNotFoundException();
    return new ApplicationInfo();
  }
  public ApplicationInfo getApplicationInfo(String p, ApplicationInfoFlags f) throws NameNotFoundException {
    long want = MATCH_ARCHIVED_PACKAGES | MATCH_UNINSTALLED_PACKAGES;
    if (of(p) == State.ABSENT || (of(p) == State.ARCHIVED && (f.v & want) == 0)) throw new NameNotFoundException();
    return new ApplicationInfo();
  }
}
JAVA
cat > "$WORK/stubs/android/content/pm/ApplicationInfo.java" <<'JAVA'
package android.content.pm;
public class ApplicationInfo {}
JAVA
cat > "$WORK/stubs/android/util/Log.java" <<'JAVA'
package android.util;
import java.util.ArrayList;
import java.util.List;
public class Log {
  public static final List<String> lines = new ArrayList<>();
  public static int i(String tag, String msg) { lines.add(tag + ": " + msg); return 0; }
  public static int w(String tag, String msg) { lines.add(tag + ": " + msg); return 0; }
  public static int w(String tag, String msg, Throwable t) { return 0; }
}
JAVA

cat > "$WORK/Cases.java" <<'JAVA'
import android.content.pm.PackageManager;
import android.content.pm.PackageManager.State;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

public class Cases {
  static int fails = 0;
  static void check(String what, boolean ok, String detail) {
    if (ok) System.out.println("  ok    " + what);
    else { System.out.println("  FAIL  " + what + ": " + detail); fails++; }
  }
  static File dir;
  static PackageManager pm = new PackageManager();
  static Lifted act() { return new Lifted(dir, pm); }
  static void list(String text) throws Exception {
    Files.write(new File(dir, "nowhere-apporphan.list").toPath(), text.getBytes(StandardCharsets.UTF_8));
  }
  static String read() throws Exception {
    return new String(Files.readAllBytes(new File(dir, "nowhere-apporphan.list").toPath()), StandardCharsets.UTF_8);
  }
  static void fresh() throws Exception {
    dir = Files.createTempDirectory("fk").toFile();
    pm.state.clear();
    android.util.Log.lines.clear();
  }

  public static void main(String[] a) throws Exception {
    // control: the stub PM's three answers are distinguishable, so a stub that answers everything cannot pass
    fresh();
    pm.state.put("inst", State.INSTALLED); pm.state.put("arch", State.ARCHIVED);
    Lifted l = act();
    check("control: installed is true under flags 0", l.isInstalledPkg("inst"), "installed read false");
    check("control: archived is false under flags 0", !l.isInstalledPkg("arch"), "archived read true under flags 0");
    check("control: absent is false under flags 0", !l.isInstalledPkg("gone"), "absent read true");
    boolean archivedQuery = true, absentQuery = false;
    try { pm.getApplicationInfo("arch", PackageManager.ApplicationInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES)); }
    catch (Throwable t) { archivedQuery = false; }
    try { pm.getApplicationInfo("gone", PackageManager.ApplicationInfoFlags.of(PackageManager.MATCH_ARCHIVED_PACKAGES)); absentQuery = true; }
    catch (Throwable t) { }
    check("control: archived answers the archived flags, absent never does", archivedQuery && !absentQuery,
          "archivedQuery=" + archivedQuery + " absentQuery=" + absentQuery);

    fresh(); pm.state.put("p", State.INSTALLED);
    check("installed -> true", act().resolvableForKeep("p"), "false");

    fresh(); pm.state.put("p", State.ARCHIVED);
    check("archived, not listed -> true", act().resolvableForKeep("p"), "false");

    fresh(); list("other\np\n");
    check("absent and listed -> true", act().resolvableForKeep("p"), "false");
    boolean logged = false;
    for (String s : android.util.Log.lines) if (s.contains("resolvableForKeep(p)") && s.contains("RETAINED inferred orphan")) logged = true;
    check("absent and listed -> the seal-backed Log.i line is recorded", logged, "lines=" + android.util.Log.lines);

    fresh(); list("other\n");
    check("absent and not listed -> false", !act().resolvableForKeep("p"), "true");

    fresh();
    check("absent with no list file -> false", !act().resolvableForKeep("p"), "true");

    fresh(); list("  p \n\n\tq\n");
    check("listed line with surrounding whitespace -> still true", act().resolvableForKeep("p") && act().resolvableForKeep("q"), "false");

    fresh(); list("a\nb\n");
    act().recordInferredOrphan("c");
    check("record appends once, keeping earlier entries in order", read().equals("a\nb\nc\n"), "file=" + read().replace("\n", "|"));
    String before = read();
    act().recordInferredOrphan("c");
    check("a second record for the same package leaves the file byte-identical", read().equals(before), "file=" + read().replace("\n", "|"));
    act().recordInferredOrphan("a");
    check("recording an earlier entry leaves the file byte-identical", read().equals(before), "file=" + read().replace("\n", "|"));

    fresh();
    act().recordInferredOrphan("x");
    check("record with no list file creates it", read().equals("x\n"), "file=" + read().replace("\n", "|"));

    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
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
mutant() { # mutant <label> <sed expr>... -- a mutant that does not change the file counts as a failure
  local label="$1" m="$WORK/mut.java"; shift
  local args=(); for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then printf '  ⚠ NOT APPLIED  %s\n' "$label"; MRC=1; return; fi
  if suite "$m" quiet; then printf '  ⚠ SURVIVED  %s\n' "$label"; MRC=1
  else printf '  convicted   %s\n' "$label"; fi
}
mutant 'seal-backed answer removed'            's|boolean sealed = inferredOrphans().contains(pkg);|boolean sealed = false;|'
mutant 'archived/uninstalled query dropped'    's|^\( *\)getPackageManager().getApplicationInfo(pkg,$|\1if (true) throw new RuntimeException(); getPackageManager().getApplicationInfo(pkg,|'
mutant 'inferredOrphans stops trimming'        's|ln = ln.trim(); ||'
mutant 'record writes only the new package'    "s|for (String p : s) sb.append(p).append('\\\\n');|sb.append(pkg).append('\\\\n');|"

echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
