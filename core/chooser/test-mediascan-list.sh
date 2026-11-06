#!/usr/bin/env bash
# test-mediascan-list.sh [<MediaScanReceiver.java>] [--mutate] -- MediaScanReceiver.readList, RUN rather than grepped.
#
# WHY THIS IS COMMITTED. readList decides which files the chooser asks MediaProvider to index in the roamed user,
# and its path bound ("canonicalize, require the external-storage prefix, skip a vanished file") is load-bearing:
# the receiver runs with the chooser's privileges. Nothing executed it. And the class header promises "a space in
# a filename cannot become a parsing bug" while readList did line.trim(): a synced file whose name starts or ends
# in a space or tab was looked up under the trimmed name and silently skipped for the rest of the session
# (NWP-20261016-43). The writer (writeMediaSyncList) joins with "\n" and never pads.
#
# EXTRACTS readList straight out of the source (verbatim, by signature) into a harness with stubs for Context
# (unused), android.util.Log (records messages) and Environment.getExternalStorageDirectory() (a temp dir
# standing for /storage/emulated/<uid>), so the tested code is the shipped code.
#
#   bash test-mediascan-list.sh            # the cases
#   bash test-mediascan-list.sh --mutate   # ... plus mutants that must each CONVICT the suite
#
# Needs javac+java (PATH, else the build host's prebuilts JDK); FAILS (exit 2) without one rather than skip.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/MediaScanReceiver.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }

VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-mediascan-list: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /'

# From the signature to the closing brace at method indent (4 spaces + '}').
M=$(awk '/^    private static List<File> readList\(/,/^    \}$/' "$SUT")
[ -n "$M" ] || { echo "EXTRACTION FAILED -- readList moved in $SUT" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

write_stubs(){ # $1 = dir
  mkdir -p "$1/android/util" "$1/android/os" "$1/android/content"
  cat > "$1/android/content/Context.java" <<'JAVA'
package android.content;
public class Context {}
JAVA
  cat > "$1/android/util/Log.java" <<'JAVA'
package android.util;
import java.util.ArrayList;
import java.util.List;
public class Log {
    public static final List<String> msgs = new ArrayList<>();
    public static int w(String tag, String m) { msgs.add(m); return 0; }
    public static int w(String tag, String m, Throwable t) { msgs.add(m); return 0; }
    public static int i(String tag, String m) { msgs.add(m); return 0; }
}
JAVA
  cat > "$1/android/os/Environment.java" <<'JAVA'
package android.os;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
public class Environment {
    public static File root;
    public static File getExternalStorageDirectory() { return root; }
}
JAVA
}

write_harness(){ # $1 = dir, $2 = method text
  {
    cat <<'JAVA'
import android.content.Context;
import android.os.Environment;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
public class MediaListT {
JAVA
    echo "$2"
    cat <<'JAVA'
    static int fails = 0;
    static void check(String what, boolean cond) {
        if (!cond) { System.out.println("FAIL " + what); fails++; } else System.out.println("ok   " + what);
    }
    static void put(File f, String body) throws Exception {
        f.getParentFile().mkdirs();
        try (FileWriter w = new FileWriter(f)) { w.write(body); }
    }
    static File list;
    static List<File> run(String body) throws Exception {
        put(list, body);
        android.util.Log.msgs.clear();
        return readList(new Context(), list);
    }
    static boolean has(List<File> l, File f) {
        for (File x : l) if (x.getPath().equals(f.getPath())) return true;
        return false;
    }
    public static void main(String[] a) throws Exception {
        File base = new File(a[0]).getCanonicalFile();
        File root = new File(base, "emulated0");
        File lists = new File(base, "lists");
        list = new File(lists, "nowhere-mediascan.list");
        root.mkdirs();
        Environment.root = root;

        File plain = new File(root, "DCIM/a.jpg");           put(plain, "x");
        File trail = new File(root, "DCIM/trail ");          put(trail, "x");
        File outside = new File(base, "outside/x");          put(outside, "x");
        File evil = new File(base, "emulated0-evil/x");      put(evil, "x");
        File dir = new File(root, "DCIM/adir");              dir.mkdirs();
        File viaLink = new File(root, "link/x");
        Files.createSymbolicLink(new File(root, "link").toPath(), new File(base, "outside").toPath());

        List<File> r;
        r = run(plain.getPath() + "\n");
        check("a regular file under the root is kept", r.size() == 1 && has(r, plain));
        check("a kept file logs nothing", android.util.Log.msgs.isEmpty());

        r = run(trail.getPath() + "\n");
        check("a name ending in a space is kept", r.size() == 1 && has(r, trail));

        r = run(plain.getPath() + "\r\n");
        check("a CRLF-terminated line still resolves", r.size() == 1 && has(r, plain));

        r = run(outside.getPath() + "\n");
        check("a path outside the root is refused", r.isEmpty());
        check("... and the refusal is logged", android.util.Log.msgs.size() == 1);

        r = run(root.getPath() + "/../outside/x\n");
        check("<root>/../outside/x (canonicalizes outside) is refused", r.isEmpty());
        check("... and logged", android.util.Log.msgs.size() == 1);

        r = run(viaLink.getPath() + "\n");
        check("a symlink under the root pointing outside is refused", r.isEmpty());
        check("... and logged", android.util.Log.msgs.size() == 1);

        r = run(evil.getPath() + "\n");
        check("<root>-evil/x (shares the root's string prefix) is refused", r.isEmpty());
        check("... and logged", android.util.Log.msgs.size() == 1);

        r = run(new File(root, "DCIM/gone.jpg").getPath() + "\n");
        check("a listed file that does not exist is skipped", r.isEmpty());
        check("... without a log", android.util.Log.msgs.isEmpty());

        r = run(dir.getPath() + "\n");
        check("a directory under the root is skipped", r.isEmpty());

        r = run("\n\n" + plain.getPath() + "\n\n");
        check("blank lines are skipped", r.size() == 1 && has(r, plain));

        list.delete();
        android.util.Log.msgs.clear();
        r = readList(new Context(), list);
        check("a missing list file returns empty", r.isEmpty());
        check("... without logging", android.util.Log.msgs.isEmpty());

        Environment.root = null;
        put(list, plain.getPath() + "\n");
        android.util.Log.msgs.clear();
        r = readList(new Context(), list);
        check("a null storage root returns empty", r.isEmpty());
        check("... and logs", android.util.Log.msgs.size() == 1);

        System.out.println(fails == 0 ? "ALL OK" : fails + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }
}
JAVA
  } > "$1/MediaListT.java"
}

# run_case <label> <method-text>: compile + run; echoes output; returns the harness's status (3 = compile error).
run_case(){
  local d; d=$(mktemp -d -p "$T")
  write_stubs "$d"; write_harness "$d" "$2"
  if ! "$JAVAC" -d "$d/out" $(find "$d" -name '*.java') >"$d/javac.log" 2>&1; then
    cat "$d/javac.log"; return 3
  fi
  "$JAVA" -cp "$d/out" MediaListT "$d/data"
}

echo "== control: the shipped readList"
OUT=$(run_case control "$M"); RC=$?
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "test-mediascan-list: FAIL (control exit $RC)"; exit 1; }
[ "$MUTATE" = yes ] || { echo "test-mediascan-list: PASS"; exit 0; }

BAD=0
mutant(){ # <name> <sed-expr>
  local m; m=$(printf '%s\n' "$M" | sed -E "$2")
  if [ "$m" = "$M" ]; then echo "MUTANT DID NOT APPLY: $1"; BAD=$((BAD+1)); return; fi
  local o rc
  o=$(run_case "$1" "$m"); rc=$?
  if [ "$rc" -eq 1 ]; then echo "convicted: $1"
  else echo "$o" | tail -5; echo "NOT CONVICTED (exit $rc): $1"; BAD=$((BAD+1)); fi
}
echo "== mutants"
mutant "trim() restored" '/while \(\(line = r\.readLine\(\)\) != null\) \{/a line = line.trim();'
mutant "prefix check without the separator" 's/canon\.startsWith\(prefix\)/canon.startsWith(root.getAbsolutePath())/'
mutant "absolute path instead of canonical" 's/canon = f\.getCanonicalPath\(\);/canon = f.getAbsolutePath();/'
mutant "isFile() skip removed"          's/if \(!f\.isFile\(\)\)/if (false)/'

if [ "$BAD" -ne 0 ]; then echo "test-mediascan-list: FAIL ($BAD mutant problem(s))"; exit 1; fi
echo "test-mediascan-list: PASS (control + 4 mutants convicted)"
