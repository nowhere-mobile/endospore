#!/usr/bin/env bash
# test-create-progress-java.sh [--mutate] -- NWP-20261120-06 (Q167): a create streams its progress into the gate's bar,
# the purge of a deleted name included. The daemon writes "PROGRESS create <d> <t>" lines before the CREATE /
# CREATE-CODE verdict (core/agent/create_progress.go; its Go half is create_progress_test.go). This suite compiles and
# EXECUTES CreateReplyStream.verdict over streamed replies (P1-P8), and pins in ChooserActivity.java that both CREATE
# sends read through createStreaming (S1), which paints the bar and never the status text (S2).
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs the suite against broken copies of CreateReplyStream.java or ChooserActivity.java, each of which
# must FAIL a named case; a mutant that does not apply (INERT) or fails another way (BROKEN) counts as a failure.
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-create-progress-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
CSRC="$ROOT/core/chooser/src/com/nowhere/chooser"
STREAM="$CSRC/CreateReplyStream.java"
CHOOSER="$CSRC/ChooserActivity.java"

CASES="$W/CreateProgressCases.java"
cat > "$CASES" <<'JAVA'
package com.nowhere.chooser;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

public class CreateProgressCases {
    static int fails = 0, n = 0;

    static void check(String id, boolean ok, String detail) {
        n++;
        if (ok) System.out.println("PASS " + id);
        else { fails++; System.out.println("FAIL " + id + " -- " + detail); }
    }

    static void stream(String id, String in, List<Integer> wantPcts, String wantVerdict) {
        List<Integer> got = new ArrayList<>();
        String v = CreateReplyStream.verdict(new BufferedReader(new StringReader(in)), got::add);
        check(id, got.equals(wantPcts) && v.equals(wantVerdict),
                "got pcts " + got + " verdict \"" + v + "\", want " + wantPcts + " \"" + wantVerdict + "\"");
    }

    static String body(String src, String sig) {
        int i = src.indexOf(sig);
        if (i < 0) return null;
        int b = src.indexOf('{', i), depth = 0;
        for (int k = b; k < src.length(); k++) {
            char c = src.charAt(k);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return src.substring(b, k + 1);
        }
        return null;
    }

    public static void main(String[] a) throws Exception {
        stream("P1 lines then a verdict", "PROGRESS create 0 20\nPROGRESS create 7 20\nPROGRESS create 20 20\nOK 0 RECOVERY a b c\n",
                List.of(0, 35, 100), "OK 0 RECOVERY a b c");
        stream("P2 EOF with no verdict", "PROGRESS create 0 20\n", List.of(0), "");
        stream("P3 a foreign PROGRESS phase is skipped", "PROGRESS restore 3 9\nBLANK\n", List.of(), "BLANK");
        stream("P4 t=0 is 0", "PROGRESS create 5 0\nBLANK\n", List.of(0), "BLANK");
        stream("P5 d>t clamps to 100, d<0 to 0", "PROGRESS create 30 20\nPROGRESS create -1 20\nBLANK\n", List.of(100, 0), "BLANK");
        stream("P6 malformed numbers are skipped", "PROGRESS create x y\nPROGRESS create 3\n\n  EXISTS  \n", List.of(), "EXISTS");
        List<Integer> got = new ArrayList<>();
        Reader bad = new Reader() {
            public int read(char[] c, int o, int l) throws IOException { throw new IOException("gone"); }
            public void close() {}
        };
        String v = CreateReplyStream.verdict(new BufferedReader(bad), got::add);
        check("P7 an IOException is \"\"", v.equals("") && got.isEmpty(), "got \"" + v + "\" " + got);
        stream("P8 an old daemon's single line", "NOSTORE\n", List.of(), "NOSTORE");

        String src = new String(Files.readAllBytes(Paths.get(a[0])), StandardCharsets.UTF_8);
        String rl = body(src, "private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {");
        int at = rl == null ? -1 : rl.indexOf("String cr = code.isEmpty()\n");
        String send = at < 0 ? "" : rl.substring(at);
        String[] ln = send.split("\n", 4);
        check("S1 both CREATE sends read through createStreaming",
                ln.length >= 3
                        && ln[1].trim().startsWith("? createStreaming(\"CREATE\\n\"")
                        && ln[2].trim().startsWith(": createStreaming(\"CREATE-CODE\\n\"")
                        && !src.contains("sendDaemon(\"CREATE"),
                "roamLogin's create send is not the two createStreaming calls after String cr = code.isEmpty()");
        String cs = body(src, "private String createStreaming(String msg)");
        check("S2 createStreaming paints the bar and never the status text",
                cs != null
                        && cs.contains("DaemonSocket.connect()")
                        && cs.contains("setSoTimeout(90000)")
                        && cs.contains("CreateReplyStream.verdict(")
                        && cs.contains("progressBar.setProgress(")
                        && cs.contains("finally")
                        && !cs.contains("result.")
                        && !cs.contains("setText("),
                cs == null ? "no createStreaming(String msg)" : "body:\n" + cs);

        if (fails > 0) { System.out.println(fails + " of " + n + " FAILED"); System.exit(1); }
        System.out.println("ALL " + n + " PASS");
    }
}
JAVA

run() { # run <CreateReplyStream.java> <ChooserActivity.java>
  local d
  d=$(mktemp -d -p "$W")
  mkdir -p "$d/src" "$d/out"
  cp "$1" "$d/src/CreateReplyStream.java"
  cp "$CASES" "$d/src/CreateProgressCases.java"
  "$JAVAC" -J-Djava.io.tmpdir="$W" -d "$d/out" "$d/src/CreateReplyStream.java" "$d/src/CreateProgressCases.java" || return 3
  "$JAVA" -Djava.io.tmpdir="$W" -cp "$d/out" com.nowhere.chooser.CreateProgressCases "$2"
}
run "$STREAM" "$CHOOSER" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> stream|chooser <perl-expr> <case the mutant must fail>
  local d f out rc orig
  d=$(mktemp -d -p "$W")
  if [ "$2" = stream ]; then orig=$STREAM; else orig=$CHOOSER; fi
  f="$d/$(basename "$orig")"
  cp "$orig" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$orig" "$f"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  if [ "$2" = stream ]; then out=$(run "$f" "$CHOOSER" 2>&1); rc=$?; else out=$(run "$STREAM" "$f" 2>&1); rc=$?; fi
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if ! grep -qF -- "FAIL $4" <<<"$out"; then
    echo "  BROKEN    $1 -- it failed, but not the case '$4' (rc=$rc)"; return 1
  fi
  echo "  convicted $1 (fails '$4')"
}
fails=0
mut "c1 a PROGRESS line returned as the verdict" stream 's/if \(p >= 0\) onPct\.accept\(p\);/return line;/' \
  "P1 lines then a verdict" || fails=$((fails+1))
mut "c2 createStreaming sets the status text" chooser 's/(\n( *)progressBar\.setProgress\(pct\);\n)(\s*\}\)\);\n\s*\} catch \(Exception e\) \{\n\s*android\.util\.Log\.w\("NowhereChooser", "createStreaming)/$1$2result.setText("Creating — " + pct + "%");\n$3/' \
  "S2 createStreaming paints the bar and never the status text" || fails=$((fails+1))
mut "c3 the clamp is gone" stream 's/return \(int\) Math\.max\(0, Math\.min\(100, pc\)\);/return (int) pc;/' \
  "P5 d>t clamps to 100, d<0 to 0" || fails=$((fails+1))
mut "c4 CREATE goes back to the one-line sendDaemon" chooser 's/\? createStreaming\("CREATE\\n"/? sendDaemon("CREATE\\n"/' \
  "S1 both CREATE sends read through createStreaming" || fails=$((fails+1))
mut "c5 a foreign PROGRESS line is the verdict" stream 's/\} else if \(line\.startsWith\("PROGRESS "\)\) \{\n\s*continue;[^\n]*\n//' \
  "P3 a foreign PROGRESS phase is skipped" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
