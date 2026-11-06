#!/usr/bin/env bash
# NWP-20261025-23: retain the owned SSE worker after closeStream clears streamThread.
# This test extracts start0 and the launch declarations from cases (l) and (m).
# A real worker runs each close hook before start0 returns. No sockets are needed.
# The original Pump-return launcher compiles, then fails the ownership assertions.
#
# Usage:
#   bash core/pushd/test-push-stream-thread-handoff.sh [--mutate]
#   bash core/pushd/test-push-stream-thread-handoff.sh --source /path/to/old-suite.sh
# PUSH_STREAM_HARNESS_SRC can also select the source script.
# --mutate requires the corrected launcher. Each mutation must compile and fail
# both named ownership assertions. Extraction and compilation errors never count.
# Exit: 0 pass, 1 assertion failure, 2 cannot run or extract, 3 compilation failure.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${PUSH_STREAM_HARNESS_SRC:-$HERE/test-push-stream.sh}
MUTATE=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes; shift ;;
    --source)
      [ "$#" -ge 2 ] || { echo 'thread-handoff: --source needs a path' >&2; exit 2; }
      SRC=$2; shift 2 ;;
    --help|-h)
      echo 'Usage: test-push-stream-thread-handoff.sh [--mutate] [--source PATH]'
      echo 'PUSH_STREAM_HARNESS_SRC can also select the source script.'
      exit 0 ;;
    *) echo "thread-handoff: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -f "$SRC" ] || { echo "thread-handoff: source script is missing: $SRC" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'thread-handoff: python3 is required' >&2; exit 2; }
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo 'thread-handoff: no JDK; this test did not run' >&2
  exit 2
fi

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

python3 - "$SRC" "$W" "$MUTATE" <<'PY'
from pathlib import Path
import re
import sys

source, root, mutate = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == "yes"

def require(ok, message):
    if not ok:
        raise ValueError(message)

try:
    lines = source.read_text().splitlines()
    starts = [i for i, line in enumerate(lines)
              if re.match(r"^    static (?:Pump|Thread) start0\(", line)]
    require(len(starts) == 1, "expected one start0 method")
    first = starts[0]
    last = next(i for i in range(first + 1, len(lines)) if lines[i] == "    }")
    method = "\n".join(lines[first:last + 1])
    require(method.count("th.start();") == 1, "expected one worker start")

    def launch(case):
        markers = [i for i, line in enumerate(lines)
                   if re.match(r"\s*\{ // \(" + case + r"\)", line)]
        require(len(markers) == 1, "expected one case " + case)
        marker = markers[0]
        end = next(i for i in range(marker + 1, len(lines)) if "s.waitFor(" in lines[i])
        first = next(i for i in range(marker + 1, end) if "final Pump p =" in lines[i])
        text = "\n".join(lines[first:end])
        require(len(re.findall(r"\bstart0\(", text)) == 1, "expected one launcher in " + case)
        require(len(re.findall(r"final Thread th =", text)) == 1, "expected one handle in " + case)
        return text

    launches = {case: launch(case) for case in ("l", "m")}
    prefix = r'''
import java.util.*;

public final class StreamThreadHandoff {
    static int failures;
    static final class Thread extends java.lang.Thread {
        static Thread launched;
        Thread(Runnable action, String name) {
            super(action, name);
            launched = this;
        }
        @Override public void start() {
            super.start();
            try {
                super.join(2000);
            } catch (InterruptedException e) {
                java.lang.Thread.currentThread().interrupt();
                throw new AssertionError("FORCED_SCHEDULE_INTERRUPTED", e);
            }
            if (super.isAlive()) {
                interrupt();
                throw new AssertionError("FORCED_SCHEDULE_WORKER_DID_NOT_FINISH");
            }
        }
    }
    static final class Pump {
        static final class Reg {}
        volatile Thread streamThread;
        volatile Runnable beforeOpen;
        int port, openIdx, closes;
        boolean entered, finished;
        void runLoop(List<String> tokens, Map<String, Reg> byGw) {
            entered = true;
            if (!tokens.equals(new ArrayList<>(byGw.keySet()))) return;
            Runnable hook = beforeOpen;
            beforeOpen = null;
            if (hook != null) hook.run();
            finished = true;
        }
        void closeNow() {
            Thread worker = streamThread;
            streamThread = null;
            closes++;
            if (worker != null) worker.interrupt();
        }
    }
    static final class Port {
        int getLocalPort() { return 12345; }
    }
    static final class Srv { final Port ss = new Port(); }
    static Map<String, Pump.Reg> ours() {
        return Collections.singletonMap("test-token", new Pump.Reg());
    }
    static void check(String name, boolean ok) {
        System.out.println((ok ? "PASS " : "FAIL ") + name);
        if (!ok) failures++;
    }
    static void inspect(Pump p, Thread th, String name, int index) {
        check("HOOK_ONCE_" + name, p.closes == 1);
        check("CALL_ARGUMENTS_" + name, p.port == 12345 && p.openIdx == index);
        check("WORKER_RAN_" + name, p.entered && p.finished);
        check("SHARED_FIELD_CLEARED_" + name, p.streamThread == null);
        check("OWNED_THREAD_" + name, th != null && th == Thread.launched);
        check("THREAD_FINISHED_" + name, th != null && !th.isAlive());
    }
'''

    def fixture(factory, callers):
        result = prefix + "\n" + factory + "\n"
        for case, index in (("l", 1), ("m", 0)):
            result += "    static void case_" + case + "() {\n        final Srv s = new Srv();\n"
            result += callers[case] + "\n"
            result += '        inspect(p, th, "' + case + '", ' + str(index) + ');\n    }\n'
        result += "    public static void main(String[] args) {\n"
        result += "        case_l();\n        case_m();\n        if (failures != 0) System.exit(1);\n    }\n}\n"
        return result

    variants = {"control": fixture(method, launches)}
    if mutate:
        require(re.search(r"static Thread start0\(", method) is not None,
                "--mutate needs the corrected Thread-return launcher")
        require(len(re.findall(r"\breturn th;", method)) == 1, "expected the owned Thread return")
        variants["return-field"] = fixture(re.sub(r"\breturn th;", "return p.streamThread;", method), launches)
        changed = {}
        for case, text in launches.items():
            pattern = r"final Thread th = (start0\([^;]+\));"
            require(len(re.findall(pattern, text)) == 1, "expected the owned launch handle in " + case)
            changed[case] = re.sub(pattern, r"\1;\n            final Thread th = p.streamThread;", text)
        variants["caller-field"] = fixture(method, changed)
    for name, text in variants.items():
        directory = root / name
        directory.mkdir()
        (directory / "StreamThreadHandoff.java").write_text(text)
except (ValueError, StopIteration, OSError) as exc:
    print("thread-handoff: extraction failed: " + str(exc), file=sys.stderr)
    sys.exit(2)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

compile_fixture() {
  local name=$1
  "$JAVAC" -d "$W/$name" "$W/$name/StreamThreadHandoff.java" >"$W/$name/compile.txt" 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$W/$name/compile.txt" >&2
    echo "thread-handoff: $name did not compile; no mutation was convicted" >&2
    return 3
  fi
}

compile_fixture control || exit "$?"
"$JAVA" -Djava.io.tmpdir="$W" -cp "$W/control" StreamThreadHandoff >"$W/control/result.txt" 2>&1
rc=$?
cat "$W/control/result.txt"
[ "$rc" -eq 0 ] || exit 1
echo 'thread-handoff: both actual launch sites retain their owned worker'

if [ "$MUTATE" = yes ]; then
  for name in return-field caller-field; do
    compile_fixture "$name" || exit "$?"
    "$JAVA" -Djava.io.tmpdir="$W" -cp "$W/$name" StreamThreadHandoff >"$W/$name/result.txt" 2>&1
    rc=$?
    if [ "$rc" -eq 1 ] &&
       grep -qx 'FAIL OWNED_THREAD_l' "$W/$name/result.txt" &&
       grep -qx 'FAIL OWNED_THREAD_m' "$W/$name/result.txt"; then
      echo "thread-handoff: convicted $name through both ownership assertions"
    else
      cat "$W/$name/result.txt" >&2
      echo "thread-handoff: $name did not fail both ownership assertions (exit $rc)" >&2
      exit 1
    fi
  done
fi
