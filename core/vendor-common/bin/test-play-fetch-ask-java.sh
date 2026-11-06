#!/usr/bin/env bash
# test-play-fetch-ask-java.sh [--mutate] -- dn-1023 #5's ask before the Play-stack fetch, run under javac
# (NWP-20261114-14).
#
# WHY THIS IS COMMITTED. dn-1023 #5 (DECIDED 2026-10-24, docs/product-decisions.md): the first tap on an on-demand app
# that needs Play shows the size and asks before the fetch starts; an app set to Auto is not asked. Before it, one tap
# spent ~130 MB and ~2.5 minutes fetching the Play stack before anything said so. PlayFetchAsk (needsAsk, message,
# parseSize, the one-shot Asker) is a pure class with no android.* import, compiled here with its cases. A source
# check on UnarchiveService.java pins the wiring the cases cannot see: materializeLocked asks after pendingDeps and
# before qEnqueue(group), passes `quiet`, and returns false on NO/TIMEOUT before any materializeMember; the ask is made
# once in the file and never from materializeMember or sweepAuto; the manifest declares the activity unexported.
# h49 #9 (DECIDED 2026-10-31; NWP-20261119-27) adds PlayFetchAsk.WHERE, where the download's progress shows, between
# the size and the question on both bodies; M10 and M11 drop it from each.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-play-fetch-ask-java.sh            # the cases + the source check
#   bash test-play-fetch-ask-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/PlayFetchAsk.java"
UNA="$SRC/UnarchiveService.java"
MANIFEST="$root/core/chooser/AndroidManifest.xml"
CASES="$root/core/chooser/tests/play-fetch-ask/PlayFetchAskCases.java"
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
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }
[ -f "$UNA" ] && [ -f "$MANIFEST" ] || { echo "FAIL: missing UnarchiveService.java or AndroidManifest.xml" >&2; exit 2; }

# suite <PlayFetchAsk.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 the class or the cases did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  PlayFetchAsk.java does not exist (the ask is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/PlayFetchAsk.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/PlayFetchAskCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PlayFetchAskCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# meth <file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}

# sources <UnarchiveService.java> <AndroidManifest.xml> -> 0 when every wiring rule holds, 1 (with the reason) when not.
# Comment lines (//, *, /*) never count as code.
sources() {
  local una="$1" man="$2" ml mm sw r
  ml=$(meth "$una" materializeLocked)
  mm=$(meth "$una" materializeMember)
  sw=$(meth "$una" sweepAuto)
  [ -n "$ml" ] && [ -n "$mm" ] && [ -n "$sw" ] || { echo "  FAIL  materializeLocked, materializeMember or sweepAuto not found" >&2; return 1; }
  # P1: pendingDeps < the needsAsk call < qEnqueue(group); < the first materializeMember(.
  r=$(printf '%s\n' "$ml" | awk '
    /^ *(\/\/|\*|\/\*)/ { next }
    index($0, "pendingDeps(pkg, depRestoreOnly)") && !p { p = NR }
    index($0, "PlayFetchAsk.needsAsk(") && !n { n = NR }
    index($0, "qEnqueue(group);") && !q { q = NR }
    index($0, "materializeMember(") && !m { m = NR }
    END { if (p && n && q && m && p < n && n < q && q < m) print "ok"
          else print "bad: pendingDeps=" p+0 " needsAsk=" n+0 " qEnqueue=" q+0 " materializeMember=" m+0 }')
  [ "$r" = ok ] || { echo "  FAIL  P1 materializeLocked: $r (want pendingDeps < needsAsk < qEnqueue(group); < materializeMember)" >&2; return 1; }
  # P2: the call passes the method's own `quiet`, so the Auto sweep is never asked.
  r=$(printf '%s\n' "$ml" | awk '!/^ *(\/\/|\*|\/\*)/ && index($0, "PlayFetchAsk.needsAsk(quiet, deps,") { c++ } END { print c+0 }')
  [ "$r" = 1 ] || { echo "  FAIL  P2 materializeLocked: the needsAsk call does not pass \`quiet, deps,\` ($r)" >&2; return 1; }
  # P3: a NO/TIMEOUT stop returns false between the ask and qEnqueue(group); (so before any fetch).
  r=$(printf '%s\n' "$ml" | awk '
    /^ *(\/\/|\*|\/\*)/ { next }
    index($0, "PlayFetchAsk.needsAsk(") && !n { n = NR }
    index($0, "qEnqueue(group);") && !q { q = NR }
    n && !q && index($0, "if (a != PlayFetchAsk.Reply.YES) {") { g = NR }
    n && !q && g && /^ *return false;$/ { rf++ }
    END { if (g && rf == 1) print "ok"; else print "bad: stop-guard=" g+0 " return-false=" rf+0 }')
  [ "$r" = ok ] || { echo "  FAIL  P3 materializeLocked: $r (want \`if (a != PlayFetchAsk.Reply.YES) {\` then one \`return false;\` before qEnqueue(group);)" >&2; return 1; }
  # P4: between the call and qEnqueue(group); the size is read and the dialog is shown.
  r=$(printf '%s\n' "$ml" | awk '
    /^ *(\/\/|\*|\/\*)/ { next }
    index($0, "PlayFetchAsk.needsAsk(") && !n { n = NR }
    index($0, "qEnqueue(group);") && !q { q = NR }
    n && !q && index($0, "\"APP-FETCH-SIZE\\n\"") { s++ }
    n && !q && index($0, "PlayFetchAskActivity.ask(") { k++ }
    END { if (s == 1 && k == 1) print "ok"; else print "bad: APP-FETCH-SIZE=" s+0 " ask=" k+0 }')
  [ "$r" = ok ] || { echo "  FAIL  P4 materializeLocked: $r (want one APP-FETCH-SIZE read and one PlayFetchAskActivity.ask( before qEnqueue(group);)" >&2; return 1; }
  # P5: the ask is made once in the whole file, and never from a group dep or the Auto sweep.
  r=$(awk '!/^ *(\/\/|\*|\/\*)/ { if (index($0, "PlayFetchAskActivity.ask(")) a++; if (index($0, "PlayFetchAsk.needsAsk(")) n++ }
           END { print a+0 " " n+0 }' "$una")
  [ "$r" = "1 1" ] || { echo "  FAIL  P5 UnarchiveService: PlayFetchAskActivity.ask( / PlayFetchAsk.needsAsk( occur \"$r\" times, want \"1 1\"" >&2; return 1; }
  r=$(printf '%s\n%s\n' "$mm" "$sw" | awk '/PlayFetchAsk/ { c++ } END { print c+0 }')
  [ "$r" = 0 ] || { echo "  FAIL  P5 materializeMember or sweepAuto names PlayFetchAsk ($r line(s))" >&2; return 1; }
  # P6: the manifest declares the dialog, unexported.
  r=$(awk '/<activity android:name="\.PlayFetchAskActivity" android:exported="false"/ { c++ } END { print c+0 }' "$man")
  [ "$r" = 1 ] || { echo "  FAIL  P6 AndroidManifest.xml: no <activity android:name=\".PlayFetchAskActivity\" android:exported=\"false\" ($r)" >&2; return 1; }
  return 0
}

echo "== $SUT"
ok=yes
suite "$SUT" || ok=no
sources "$UNA" "$MANIFEST" || ok=no
[ "$ok" = yes ] || { echo "FAILED"; exit 1; }
echo "ok: cases + source check"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <file: ask|una> <perl-expr>
  local d c rc orig out why
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    ask) orig="$SUT"; c="$d/PlayFetchAsk.java" ;;
    *) orig="$UNA"; c="$d/UnarchiveService.java" ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = ask ]; then out=$(suite "$c" 2>&1); rc=$?
  else out=$(sources "$c" "$MANIFEST" 2>&1); rc=$?
  fi
  rm -rf "$d"
  why=$(printf '%s\n' "$out" | awk '/FAIL/ { sub(/^ +/, ""); print; exit }')
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1 -- $why"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 needsAsk ignores quiet"                ask 's/if \(quiet \|\| fetchDeps == null\) return false;/if (fetchDeps == null) return false;/' || fails=$((fails+1))
mut "M2 needsAsk is true for any dep"          ask 's/d != null && isStack\.test\(d\)/d != null/' || fails=$((fails+1))
mut "M3 message drops the size"                ask 's/"About " \+ mb \+ " MB, " \+ /"About " + /' || fails=$((fails+1))
mut "M4 the NO branch falls through"           una 's/(if \(a != PlayFetchAsk\.Reply\.YES\) \{.*?)\n *return false;\n/$1\n/s' || fails=$((fails+1))
mut "M5 the ask moved after qEnqueue"          una 's/( *\/\/ dn-1023 #5 .*?\n        }\n)(.*?qEnqueue\(group\);\n)/$2$1/s' || fails=$((fails+1))
mut "M6 await treats TIMEOUT as YES"           ask 's/(if \(!l\.await\([^\n]*\)\)) return Reply\.TIMEOUT;/$1 return Reply.YES;/' || fails=$((fails+1))
mut "M7 a stale token answers"                 ask 's/if \(token != this\.token \|\| answer != null\) return false;/if (answer != null) return false;/' || fails=$((fails+1))
mut "M8 the call site passes false for quiet"  una 's/PlayFetchAsk\.needsAsk\(quiet, deps,/PlayFetchAsk.needsAsk(false, deps,/' || fails=$((fails+1))
mut "M9 the ask runs for a dep too"            una 's/(private boolean materializeMember\(String pkg\) \{\n)/$1        PlayFetchAsk.needsAsk(false, null, null);\n/' || fails=$((fails+1))
mut "M10 WHERE dropped from the size arm"      ask 's/ minutes\. " \+ WHERE \+ " Download now\?"/ minutes. Download now?"/' || fails=$((fails+1))
mut "M11 WHERE dropped from UNKNOWN"           ask 's/a large download\. " \+ WHERE \+ " Download now\?"/a large download. Download now?"/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
