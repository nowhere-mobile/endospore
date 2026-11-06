#!/usr/bin/env bash
# test-storage-usage-java.sh [--mutate] -- the chooser's GET-USAGE reply reasons, run under javac (NWP-20261011-21).
#
# WHY THIS IS COMMITTED. Whether a GET-USAGE reply renders as a figure, as formatUsage's dash, or as a reason in the
# body style is decided by usageNoAnswer, a private static helper in ProfileActivity.java. Nothing else executes it
# off a device, and when it is wrong the Storage screen goes back to a bare "—" that nobody can diagnose -- the
# 2026-09-10 screenshot this slice exists for (docs/backlog.md, NWP-20260910-01).
# core/chooser/tests/storage-usage/run.sh lifts the helpers into a plain class and runs UsageCases against them; the
# PINS below check that both screens that read GET-USAGE actually ask the helper before formatUsage. PIN 3 is the same
# breakdown screen's Clear on "Streamed maps and photos" (NWP-20261016-49): an OK measures the screen again rather
# than set the row to 0, which is the half of that slice no Go or roamd suite can see.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. A suite that quietly passes because its tool is missing reads
# exactly like one that ran (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md). javac comes from PATH,
# else from the build host's JDK below; the CI runner is the build VM, which has it. The version is printed first so
# the log proves which compiler ran.
#
#   bash test-storage-usage-java.sh            # the cases
#   bash test-storage-usage-java.sh --mutate   # ... plus broken copies of the helpers that must each FAIL the cases
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
RUN="$root/core/chooser/tests/storage-usage/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 2; }

# suite <ProfileActivity.java> -> 0 pass, 1 a case failed (behaviour) or a source pin failed (a textual check, not
# behaviour: it is how M6, M7, M16, M19 and M20-M24 convict), 2 a helper did not extract, 3 the lifted class did not compile.
# Only 1 may convict a mutant; 2 and 3 prove nothing about the logic.
#
# PIN 3's block, byte for byte: after an OK Clear the screen is measured again (showStorageBreakdown re-walks the row
# and the total together), only while it is still the screen showing, and the toast comes first.
PIN3_TOAST='                        android.widget.Toast.makeText(this, msg, android.widget.Toast.LENGTH_LONG).show();'
PIN3_BLOCK=$(cat <<'BLOCK'
                        if (r.startsWith("OK") && list.isAttachedToWindow()) {
                            showStorageBreakdown();
                            return;
                        }
                        paintDeviceLine(device); // the reclaimed space should show at once
BLOCK
)
export PIN3_TOAST PIN3_BLOCK
suite() {
  local f="$1"
  # PIN 1: the Storage screen decides through usageReason(u.text, u.reason()) and renders a reason via showReason,
  # else the figure through formatUsage. Multi-line, so the order is part of the match.
  perl -0ne 'exit(/final String why = usageReason\(u\.text, u\.reason\(\)\);\n\s*if \(why != null\) \{\n\s*showReason\.accept\(why\);\n\s*\} else \{\n\s*restoreHeadline\.run\(\);\n\s*usage\.setText\(formatUsage\(u\.text\)\);/s ? 0 : 1)' "$f" || {
    echo "  PIN   the Storage screen no longer asks usageReason before formatUsage" >&2; return 1; }
  # PIN 2: the storage-breakdown screen reads GET-USAGE through sendDaemonReply and decides the same way.
  perl -0ne 'exit(/final DaemonReply u = sendDaemonReply\("GET-USAGE\\n"\);\n\s*final String why = usageReason\(u\.text, u\.reason\(\)\);[^\n]*\n\s*runOnUiThread\(\(\) -> \{\n[^\n]*\n\s*if \(why == null\) \{ stored\.setText\(formatUsage\(u\.text\)\); return; \}/ ? 0 : 1)' "$f" || {
    echo "  PIN   the storage-breakdown screen no longer reads GET-USAGE through usageReason" >&2; return 1; }
  # PIN 3: inside the FREE-MEDIA-CACHE handler (its sendDaemon to its thread's start), the toast, then only comment
  # lines, then PIN3_BLOCK; no renderStorageList in that handler, and the old `si.cacheBytes = 0` nowhere in the file.
  perl -0ne 'my $i = index($_, q{sendDaemon("FREE-MEDIA-CACHE\n")}); exit 1 if $i < 0;
    my $j = index($_, q|}).start();|, $i); exit 1 if $j < 0;
    my $h = substr($_, $i, $j - $i);
    exit 1 if $h =~ /renderStorageList\(/ || /si\.cacheBytes\s*=\s*0\b/;
    exit($h =~ /\Q$ENV{PIN3_TOAST}\E\n(?:[ ]*\/\/[^\n]*\n)*\Q$ENV{PIN3_BLOCK}\E/ ? 0 : 1)' "$f" || {
    echo "  PIN   an OK Clear on Streamed maps and photos no longer measures the screen again" >&2; return 1; }

  bash "$RUN" "$f"
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d m rc; d=$(mktemp -d); m="$d/ProfileActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 NONE renders the bare dash again"             's/if \(r\.equals\("NONE"\)\) \{/if (r.equals("NONE-NEVER")) {/' || fails=$((fails+1))
mut "M2 an OK without bytes= renders the bare dash"   's/return bytes < 0 \? "Couldn/return bytes < -1 ? "Couldn/' || fails=$((fails+1))
mut "M3 LOCAL gets a reason in this slice"            's/if \(!r\.startsWith\("OK"\)\) return null;/if (!r.startsWith("OK") \&\& !r.equals("LOCAL")) return null;/' || fails=$((fails+1))
mut "M4 a null reply gets a reason"                   's/if \(reply == null\) return null;/if (reply == null) return "Couldn\x27t read this.";/' || fails=$((fails+1))
mut "M5 the wire newline defeats the match"           's/String r = reply\.trim\(\);/String r = reply;/' || fails=$((fails+1))
mut "M6 the Storage screen skips the helper"          's/final String why = usageReason\(u\.text, u\.reason\(\)\);\n(\s*)if \(why != null\) \{/final String why = null;\n$1if (why != null) {/' || fails=$((fails+1))
mut "M7 the breakdown screen keeps the dash"          's/if \(why == null\) \{ stored\.setText\(formatUsage\(u\.text\)\); return; \}/{ stored.setText(formatUsage(u.text)); return; }/' || fails=$((fails+1))
mut "M8 the NONE copy talks about profiles"           's/this phone has no record of the signed-in session/no profile by that name was found/' || fails=$((fails+1))
mut "M9 humanBytes drops the GB decimal"              's/"%\.1f GB", b \/ \(double\)/"%.0f GB", b \/ (double)/' || fails=$((fails+1))
mut "M10 the note speaks on NONE"                    's/if \(!r\.startsWith\("OK"\)\) return null;\n        long used = -1;/long used = -1;/' || fails=$((fails+1))
mut "M11 the note swaps the unit"                    's/"This profile stores " \+ humanBytes\(used\)/"This profile stores " + humanBytes(used * 1024)/' || fails=$((fails+1))
mut "M12 the headroom threshold is >= "              's/else if \(used \* 5 > covered \* 4\) s\.append/else if (used * 5 >= covered * 4) s.append/' || fails=$((fails+1))
mut "M13 the headroom threshold is dropped"          's/else if \(used \* 5 > covered \* 4\) s\.append/else if (true) s.append/' || fails=$((fails+1))
mut "M14 the breakdown warning threshold is >="      's/used \* 5 <= covered \* 4\) return null;/used * 5 < covered * 4) return null;/' || fails=$((fails+1))
mut "M15 the breakdown warning speaks on non-OK"     's/(String r = entitlementReply\.trim\(\);\n)        if \(!r\.startsWith\("OK"\)\) return null;\n        long used = -1, covered/$1        long used = -1, covered/' || fails=$((fails+1))
# M16 is anchored on the line AFTER the breakdown's read: the Storage screen reads GET-USAGE with the same statement
# and comes first in the file, so an unanchored s/// rewrote that read instead -- which no pin covers -- and survived.
mut "M16 the breakdown reads through sendDaemon again" 's/final DaemonReply u = sendDaemonReply\("GET-USAGE\\n"\);(\n\s*final String why = usageReason\(u\.text, u\.reason\(\)\);)/final DaemonReply u = new DaemonReply(sendDaemon("GET-USAGE\\n"), false, false);$1/' || fails=$((fails+1))
mut "M17 usageReason ignores failReason"              's/if \(failReason != null\) return/if (false) return/' || fails=$((fails+1))
mut "M18 usageReason drops the UNMEASURED arm"        's/text\.startsWith\("UNMEASURED"\)/text.startsWith("UNMEASURED-NEVER")/' || fails=$((fails+1))
mut "M19 the Storage screen bypasses usageReason"     's/final String why = usageReason\(u\.text, u\.reason\(\)\);\n(\s*)if \(why != null\) \{/final String why = usageNoAnswer(u.text);\n$1if (why != null) {/' || fails=$((fails+1))
mut "M20 an OK Clear zeroes the row again"            's/(: "Media cache already clear";\n)/$1                            si.cacheBytes = 0;\n                            renderStorageList(list, si, device, labels, droppable, bundled, installed);\n/; s/ {24}if \(r\.startsWith\("OK"\) && list\.isAttachedToWindow\(\)\) \{\n {28}showStorageBreakdown\(\);\n {28}return;\n {24}\}\n//' || fails=$((fails+1))
mut "M21 an OK Clear no longer measures again"       's/\n {28}showStorageBreakdown\(\);\n {28}return;(\n {24}\}\n {24}paintDeviceLine)/$1/' || fails=$((fails+1))
mut "M22 the screen measures again once it is gone"  's/if \(r\.startsWith\("OK"\) && list\.isAttachedToWindow\(\)\) \{/if (r.startsWith("OK")) {/' || fails=$((fails+1))
mut "M23 a failed Clear measures again too"          's/if \(r\.startsWith\("OK"\) && list\.isAttachedToWindow\(\)\) \{/if (list.isAttachedToWindow()) {/' || fails=$((fails+1))
mut "M24 the re-measure returns before the toast"    's/(\n {24}android\.widget\.Toast\.makeText\(this, msg, android\.widget\.Toast\.LENGTH_LONG\)\.show\(\);)((?:\n {24}\/\/[^\n]*)*)(\n {24}if \(r\.startsWith\("OK"\) && list\.isAttachedToWindow\(\)\) \{\n {28}showStorageBreakdown\(\);\n {28}return;\n {24}\})/$2$3$1/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
