#!/usr/bin/env bash
# test-ota-check-wait-java.sh [--mutate] -- what a tap on "Check for updates" waits for, run under javac (NWP-20261019-12).
#
# WHY THIS IS COMMITTED. A tap used to be answered from the daemon's cache (OTA-STATUS), so a release published inside
# the 15-minute cache TTL never showed however often the owner tapped. The tap now sends OTA-REFRESH once and waits
# for an attempt that FINISHED after it, read from OTA-VERSIONS tried_ms/refreshing. When to keep waiting, when the
# answer is live, when the check itself failed (never to be rendered as "Up to date"), when to give up, and when to
# fall back to today's behaviour (an older daemon) all live in core/chooser/src/com/nowhere/chooser/OtaCheckWait.java.
# core/chooser/tests/ota-check-wait/run.sh compiles that file as it stands, with OtaCheckWaitCases.
#
# THE CALL SITES ARE PINNED, AS BLOCKS (same reason as test-ota-update-java.sh): a correct helper called wrongly is
# the same bug. The Check listener and the whole doTapCheck block in ChooserActivity are held byte for byte.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md).
# javac comes from PATH, else from the build host's JDK below; the CI runner is the build VM, which has it.
#
#   bash test-ota-check-wait-java.sh            # the cases + the pins
#   bash test-ota-check-wait-java.sh --mutate   # ... plus broken copies that must each FAIL them
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

# One root for every temp this suite makes (mut's copies, run.sh's build dir): nothing is left in $TMPDIR.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
DIR="$root/core/chooser/src/com/nowhere/chooser"
SRC="$DIR/OtaCheckWait.java"
CHO="$DIR/ChooserActivity.java"
RUN="$root/core/chooser/tests/ota-check-wait/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
for f in "$SRC" "$CHO" "$RUN"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }; done

# ---- the pinned blocks (quoted heredocs: every backslash below is literal source text) ----
IFS= read -r -d '' P_TAP <<'EOF'
        final java.util.concurrent.atomic.AtomicBoolean tapChecking = new java.util.concurrent.atomic.AtomicBoolean();
        final Runnable doTapCheck = () -> {
            if (!tapChecking.compareAndSet(false, true)) return; // a second tap joins the wait already running
            runOnUiThread(() -> StatusLine.busy(swMsg, "Checking…"));
            new Thread(() -> {
                try {
                    final OtaCheckWait.Versions before = OtaCheckWait.parse(daemonCmd("OTA-VERSIONS"));
                    if ("NOSTORE".equals(daemonCmd("OTA-REFRESH\ntap").trim())) { doCheck.run(); return; }
                    final long t0 = android.os.SystemClock.uptimeMillis();
                    for (;;) {
                        final int d = OtaCheckWait.decide(before, OtaCheckWait.parse(daemonCmd("OTA-VERSIONS")),
                                android.os.SystemClock.uptimeMillis() - t0, 30000);
                        if (d == OtaCheckWait.WAIT) {
                            try { Thread.sleep(1500); } catch (InterruptedException ie) { return; }
                            continue;
                        }
                        if (d == OtaCheckWait.LEGACY || d == OtaCheckWait.FRESH) {
                            doCheck.run();
                        } else if (d == OtaCheckWait.CHECK_FAILED) {
                            final String[] rp = otaStatusAndProg();
                            final String head = rp[0].isEmpty() ? "" : rp[0].split(" ", 2)[0];
                            runOnUiThread(() -> {
                                renderOtaStatus(rp[0], rp[1], rp[2], swMsg, check, install, otaBar, otaBelow);
                                // the check this tap started failed: the cache's "Up to date" is not an answer to it
                                if (OtaCheckWait.replaceUpToDate(d, head)) StatusLine.error(swMsg, "Couldn't check for updates — is Wi-Fi on?");
                            });
                        } else {
                            runOnUiThread(() -> {
                                swMsg.setTextColor(MUTED);
                                swMsg.setText("The update service is slow to answer — it keeps trying in the background. Tap Check to ask again.");
                                otaBelow.setVisibility(View.GONE);
                            });
                        }
                        return;
                    }
                } finally {
                    tapChecking.set(false);
                }
            }).start();
        };
EOF
IFS= read -r -d '' P_LISTENER <<'EOF'
        check.setOnClickListener(v -> doTapCheck.run());
EOF

# pinned <file> <label> <block>: the block must appear verbatim in the file.
pinned() {
  local body; body=$(cat "$1")
  [[ "$body" == *"$3"* ]] && return 0
  echo "  PIN   $2 -- the block is gone or changed in $(basename "$1")" >&2
  return 1
}

# suite <OtaCheckWait> <ChooserActivity> -> 0 pass; 1 a case or a pin failed; 3 the class or the cases did not compile.
suite() {
  local o="$1" c="$2" bad=0
  pinned "$c" "the tap waits for an attempt after it (OTA-REFRESH once, OTA-VERSIONS polled)" "$P_TAP"      || bad=1
  pinned "$c" "the Check link starts the tap's wait, not the cache read"                       "$P_LISTENER" || bad=1
  [ "$bad" = 0 ] || return 1
  bash "$RUN" "$o"
}

echo "== $SRC (+ pins in $(basename "$CHO"))"
suite "$SRC" "$CHO" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour or a pin: a mutant that does not compile proves nothing)"
# mut <label> <which: O|C> <perl-expr>
mut() {
  local d rc o="$SRC" c="$CHO" t
  d=$(mktemp -d)
  case "$2" in O) t="$SRC" ;; C) t="$CHO" ;; esac
  local m="$d/$(basename "$t")"
  if ! perl -0pe "$3" "$t" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$t" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in O) o="$m" ;; C) c="$m" ;; esac
  suite "$o" "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 changed ignores before"                    O 's/boolean changed = now\.triedMs >= 0 && now\.triedMs != before\.triedMs;/boolean changed = now.triedMs >= 0;/' || fails=$((fails+1))
mut "M2 FRESH while still refreshing"              O 's/if \(changed && !now\.refreshing\) return verdict\(now\);/if (changed) return verdict(now);/' || fails=$((fails+1))
mut "M3 lasterr ignored"                           O 's/return "none"\.equals\(now\.lastErr\) \? FRESH : CHECK_FAILED;/return FRESH;/' || fails=$((fails+1))
mut "M4 the cap ignored"                           O 's/if \(waitedMs >= capMs\) return/if (false) return/' || fails=$((fails+1))
mut "M5 LEGACY treated as WAIT"                    O 's/if \(!before\.known \|\| !now\.known\) return LEGACY;/if (!before.known || !now.known) return WAIT;/' || fails=$((fails+1))
mut "M6 an unknown before is not LEGACY"           O 's/if \(!before\.known \|\| !now\.known\) return LEGACY;/if (!now.known) return LEGACY;/' || fails=$((fails+1))
mut "M7 replaceUpToDate true for AVAIL"            O 's/"UNKNOWN"\.equals\(statusHead\)\);/"UNKNOWN".equals(statusHead) || "AVAIL".equals(statusHead));/' || fails=$((fails+1))
mut "M8 replaceUpToDate for any decision"          O 's/return decision == CHECK_FAILED && \(/return (/' || fails=$((fails+1))
mut "M9 replaceUpToDate false for UNKNOWN"         O 's/\("NONE"\.equals\(statusHead\) \|\| "UNKNOWN"\.equals\(statusHead\)\)/"NONE".equals(statusHead)/' || fails=$((fails+1))
mut "C1 the listener calls doCheck again"          C 's/check\.setOnClickListener\(v -> doTapCheck\.run\(\)\);/check.setOnClickListener(v -> doCheck.run());/' || fails=$((fails+1))
mut "C2 the tap never sends OTA-REFRESH"           C 's/daemonCmd\("OTA-REFRESH\x5cntap"\)/daemonCmd("OTA-VERSIONS")/' || fails=$((fails+1))
mut "C3 the tap polls OTA-REFRESH"                 C 's/OtaCheckWait\.parse\(daemonCmd\("OTA-VERSIONS"\)\),\n/OtaCheckWait.parse(daemonCmd("OTA-REFRESH\x5cntap")),\n/' || fails=$((fails+1))
mut "C4 a failed check renders Up to date"         C 's/if \(OtaCheckWait\.replaceUpToDate\(d, head\)\) //' || fails=$((fails+1))
mut "C5 the wait runs on the UI thread"            C 's/            new Thread\(\(\) -> \{\n                try \{\n                    final OtaCheckWait\.Versions before/            ((Runnable) () -> {\n                try {\n                    final OtaCheckWait.Versions before/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
