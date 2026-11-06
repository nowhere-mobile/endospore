#!/usr/bin/env bash
# test-media-status-java.sh [--mutate] -- the gate reads every GET-MEDIA-STATUS line, run under javac (NWP-20261117-15).
#
# WHY THIS IS COMMITTED. mediad's writeProg (core/agent/media_server.go) writes media.progress as up to three lines
# (LOADING, DAMAGED, INCOMPLETE) and the daemon's GET-MEDIA-STATUS arm (core/agent/main.go) relays the file whole.
# The gate's backup watcher read it with a one-line helper, so it saw only the first line:
#   - a "<file> is damaged" notice waited until every fetch had ended (LOADING was the first line);
#   - a short-restore notice waited for the fetches too;
#   - beside a damaged file the short-restore notice never showed (DAMAGED was always the first line).
# The routing lives in MediaStatus (java.* only) and is compiled here with its cases. Source checks on the
# comment-stripped real files pin that the watcher reads every line and routes them through MediaStatus, and the
# premise: writeProg writes the three kinds as separate lines and the daemon relays them whole.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-media-status-java.sh            # the cases and the source checks
#   bash test-media-status-java.sh --mutate  # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="${MEDIA_STATUS_SRC:-$SRC/MediaStatus.java}"
CHOOSER="$SRC/ChooserActivity.java"
MEDIA_GO="$root/core/agent/media_server.go"
MAIN_GO="$root/core/agent/main.go"
CASES="$root/core/chooser/tests/media-status/MediaStatusCases.java"
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

# suite <MediaStatus.java> -> 0 pass, 1 a case failed or the class is missing, 3 did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  MediaStatus.java does not exist (the routing is not lifted)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/MediaStatus.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/MediaStatusCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.MediaStatusCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# strip_java <file> -> the Java source on stdout with // and /* */ comments removed (string and char literals kept).
strip_java() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse' "$1"
}
# strip_go <text on stdin> -> the same for Go, with a backtick raw string kept whole.
strip_go() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27|`[^`]*`)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse'
}

# has <id> <what> <haystack> <needle>: fails (prints, returns 1) when the needle is not in the haystack.
has() {
  [[ $3 == *"$4"* ]] && return 0
  echo "  FAIL  $1 $2" >&2
  return 1
}

# source_check <ChooserActivity.java> <media_server.go> <main.go> -> 0 when the wiring holds, 1 otherwise.
source_check() {
  local chooser="$1" mediago="$2" maingo="$3" code body raw bad=0
  command -v perl >/dev/null 2>&1 || { echo "  FAIL  no perl: the comment-stripped source checks cannot run" >&2; return 1; }
  [ -f "$chooser" ] && [ -f "$mediago" ] && [ -f "$maingo" ] || { echo "  FAIL  a source file is missing" >&2; return 1; }

  # (a) the watcher reads every line and routes them through MediaStatus.
  code=$(strip_java "$chooser") || { echo "  FAIL  could not strip comments from $chooser" >&2; return 1; }
  body=$(printf '%s\n' "$code" | awk '/private void startSyncStatusWatcher\(\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  has A0 "startSyncStatusWatcher not found, or it no longer reads GET-MEDIA-APP-PROGRESS (control)" \
    "$body" 'GET-MEDIA-APP-PROGRESS' || bad=1
  has A1 'the watcher does not read GET-MEDIA-STATUS with DaemonSocket.roundTripLines(.., 5000)' \
    "$body" 'DaemonSocket.roundTripLines("GET-MEDIA-STATUS\n", 5000)' || bad=1
  has A2 'the watcher does not route the reply through MediaStatus.route' "$body" 'MediaStatus.route(' || bad=1
  if [[ $body == *'pollDaemon("GET-MEDIA-STATUS'* || $body == *'roundTrip("GET-MEDIA-STATUS'* ]]; then
    echo "  FAIL  A3 the watcher still reads GET-MEDIA-STATUS with a one-line helper" >&2; bad=1
  fi

  # (b) the premise: writeProg writes the three kinds as separate "\n"-ended lines.
  raw=$(awk '/^func \(s \*mediaServer\) writeProg\(\) \{/ { on = 1 } on { print } on && /^}$/ { exit }' "$mediago")
  body=$(strip_go <<<"$raw")
  has B0 "writeProg not found in $mediago, or it no longer renames the progress file into place (control)" \
    "$body" 'os.Rename(tmp, s.progPath)' || bad=1
  has B1 'writeProg no longer writes a "LOADING ...\n" line' "$body" 'lines = fmt.Sprintf("LOADING %d %d %d %s\n",' || bad=1
  has B2 'writeProg no longer appends a "DAMAGED ...\n" line' "$body" 'lines += fmt.Sprintf("DAMAGED %d %s\n",' || bad=1
  has B3 'writeProg no longer appends an "INCOMPLETE ...\n" line' "$body" 'lines += fmt.Sprintf("INCOMPLETE %d %s\n",' || bad=1

  # (c) the daemon's GET-MEDIA-STATUS arm relays the file whole.
  raw=$(awk '/^\tif name == "GET-MEDIA-STATUS" \{/ { on = 1 } on { print } on && /^\t}$/ { exit }' "$maingo")
  body=$(strip_go <<<"$raw")
  has C0 "the GET-MEDIA-STATUS arm not found in $maingo, or it no longer reads mediaProgressFile (control)" \
    "$body" 'mediaProgressFile' || bad=1
  has C1 'the arm no longer trims only the trailing CR/LF of the file' \
    "$body" 'line := strings.TrimRight(string(b), "\r\n")' || bad=1
  has C2 'the arm no longer relays the file whole' "$body" 'fmt.Fprint(conn, line+"\n")' || bad=1

  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$CHOOSER" "$MEDIA_GO" "$MAIN_GO" || { echo "FAILED (source)"; exit 1; }
echo "source: ok"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <perl-expr>   (mutates MediaStatus.java; the cases must fail)
  local d c rc; d=$(mktemp -d -p "$W") || return 1; c="$d/MediaStatus.java"
  cp "$SUT" "$c"
  if ! perl -0pi -e "$2" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$SUT" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
mutsrc() { # mutsrc <label> <chooser|media|main> <perl-expr>   (mutates one source copy; the source check must fail)
  local label="$1" kind="$2" expr="$3" d orig c rc ch="$CHOOSER" md="$MEDIA_GO" mn="$MAIN_GO"
  case "$kind" in
    chooser) orig="$CHOOSER" ;; media) orig="$MEDIA_GO" ;; main) orig="$MAIN_GO" ;;
    *) echo "  ERROR     $label -- unknown source kind $kind"; return 1 ;;
  esac
  d=$(mktemp -d -p "$W") || return 1; c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$kind" in chooser) ch="$c" ;; media) md="$c" ;; main) mn="$c" ;; esac
  source_check "$ch" "$md" "$mn" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $label"; return 1; fi
  echo "  convicted $label"
}
fails=0
mut "R1 route keeps only the first line" \
  's/(if \(slot >= 0 && out\[slot\] == null\) out\[slot\] = line;)/$1\n            break;/' || fails=$((fails+1))
mut "R2 route puts a DAMAGED line in the incomplete slot" \
  's/startsWith\("DAMAGED"\) \? 1/startsWith("DAMAGED") ? 2/' || fails=$((fails+1))
mut "R3 route stops at the first line that is not LOADING" \
  's/(: -1;)/$1\n            if (slot != 0) break;/' || fails=$((fails+1))
mutsrc "R4 the watcher reads with pollDaemon again" chooser \
  's/DaemonSocket\.roundTripLines\("GET-MEDIA-STATUS\\n", 5000\)/java.util.Arrays.asList(pollDaemon("GET-MEDIA-STATUS\\n"))/' \
  || fails=$((fails+1))
mutsrc "R5 the DAMAGED format loses its newline" media 's/"DAMAGED %d %s\\n"/"DAMAGED %d %s"/' || fails=$((fails+1))
mutsrc "R6 the daemon arm relays only the first line" main \
  's/(if name == "GET-MEDIA-STATUS" \{.*?)fmt\.Fprint\(conn, line\+"\\n"\)/$1fmt.Fprint(conn, strings.SplitN(line, "\\n", 2)[0]+"\\n")/s' \
  || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
