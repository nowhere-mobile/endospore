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
# NWP-20261202-28 (S6a of docs/media-after-gate.md §8): a fourth kind. mediad writes
# "RESTORING <done B> <total B> <files left>" while the after-gate #media restore has files left (NWP-20261201-14).
# route() gives it slot 3, restoring() validates it, and the watcher posts the media notice in its restoring form
# (MediaStatus.RESTORING_TITLE, a byte bar) after an on-access LOADING and before a background PREFETCH. The D-checks
# pin that order and that postMediaNotice parses through MediaStatus.restoring with the decided title and a
# determinate bar from MediaStatus.restoringPermille (a zero-byte set too: RESTORING 0 0 1); B4 pins the line in
# writeProg.
#
# NWP-20261207-11 (S6b half 1, docs/media-after-gate.md §6 and §10 O3): a fifth line. mediad writes "RESTORE-WAITING",
# the token alone, after the RESTORING line while the lander is parked on transient fetch errors. route() gives it
# slot 4 by exact match, restoreWaiting() needs a valid RESTORING line beside it, and the restoring notice then reads
# MediaStatus.WAITING_BODY under the same title and bar. D8 pins that the watcher passes restoreWaiting, D9 that the
# body reads WAITING_BODY, B5 the line in writeProg, and F1 that WAITING_BODY is the O3 words of
# docs/product-decisions.md.
#
# NWP-20261208-09: the watcher holds the landed rescan while GET-SWEEP reports a live Auto sweep, capped at
# RESCAN_SWEEP_CAP_MS (60 min). Cases H1-H10 and C1 run MediaStatus.holdRescanForSweep; E2 and E7-E9 pin the
# watcher's hold, its single requestMediaRescan call and both resets; E10 pins the premise in auto_sweep.go and main.go.
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
SWEEP_GO="$root/core/agent/auto_sweep.go"
DECISIONS="$root/docs/product-decisions.md"
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

# source_check <ChooserActivity.java> <media_server.go> <main.go> <product-decisions.md> <auto_sweep.go> -> 0 when the
# wiring holds, 1 otherwise.
source_check() {
  local chooser="$1" mediago="$2" maingo="$3" decisions="$4" sweepgo="$5" code body raw nb bad=0
  command -v perl >/dev/null 2>&1 || { echo "  FAIL  no perl: the comment-stripped source checks cannot run" >&2; return 1; }
  [ -f "$chooser" ] && [ -f "$mediago" ] && [ -f "$maingo" ] && [ -f "$decisions" ] && [ -f "$sweepgo" ] \
    || { echo "  FAIL  a source file is missing" >&2; return 1; }

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

  # (d) NWP-20261202-28: the watcher shows the RESTORING line, after LOADING and before PREFETCH.
  has D1 'the watcher does not read the RESTORING slot mr[3]' "$body" 'mr[3]' || bad=1
  has D2 'the watcher does not parse the RESTORING line with MediaStatus.restoring(' "$body" 'MediaStatus.restoring(' \
    || bad=1
  local nl='if (loadLine != null)' nr='} else if (MediaStatus.restoring(restLine) != null)' np='} else if (prefetchActive)'
  if [[ $body != *"$nl"* || $body != *"$nr"* || $body != *"$np"* ]]; then
    echo "  FAIL  D3 the notice choice lacks one of: the loadLine, restoring or prefetchActive branch" >&2; bad=1
  else
    local il ir ip pre
    pre=${body%%"$nl"*}; il=${#pre}
    pre=${body%%"$nr"*}; ir=${#pre}
    pre=${body%%"$np"*}; ip=${#pre}
    if ! [ "$il" -lt "$ir" ] || ! [ "$ir" -lt "$ip" ]; then
      echo "  FAIL  D3 the notice choice is not loadLine, then restoring, then prefetchActive" >&2; bad=1
    fi
  fi
  # NWP-20261207-11: the restoring branch passes the parked state.
  has D8 'the watcher does not pass MediaStatus.restoreWaiting(mr) to the restoring notice' \
    "$body" 'postMediaNotice(app, uid, restLine, MediaStatus.restoreWaiting(mr));' || bad=1
  local pmn
  pmn=$(printf '%s\n' "$code" \
    | awk '/private static void postMediaNotice\(Context app, int uid, String status, boolean waiting\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  pmn=$(tr -s ' \n' '  ' <<<"$pmn")
  if [ -z "$pmn" ]; then
    echo "  FAIL  D4 postMediaNotice(Context, int, String, boolean waiting) EXTRACTION FAILED (its signature is not found)" >&2
    bad=1
  else
    has D5 'postMediaNotice does not title the restoring form with MediaStatus.RESTORING_TITLE' \
      "$pmn" 'MediaStatus.RESTORING_TITLE' || bad=1
    has D6 'postMediaNotice does not parse the restoring form with MediaStatus.restoring(' \
      "$pmn" 'MediaStatus.restoring(' || bad=1
    has D7 'postMediaNotice does not give the restoring form a determinate bar from MediaStatus.restoringPermille' \
      "$pmn" 'if (rest != null) { b.setProgress(1000, MediaStatus.restoringPermille(done, total), false);' || bad=1
    has D9 'postMediaNotice does not give the waiting restoring form the body MediaStatus.WAITING_BODY' \
      "$pmn" 'String body = rest != null ? (waiting ? MediaStatus.WAITING_BODY :' || bad=1
  fi

  # (b) the premise: writeProg writes the three kinds as separate "\n"-ended lines.
  raw=$(awk '/^func \(s \*mediaServer\) writeProg\(\) \{/ { on = 1 } on { print } on && /^}$/ { exit }' "$mediago")
  body=$(strip_go <<<"$raw")
  has B0 "writeProg not found in $mediago, or it no longer renames the progress file into place (control)" \
    "$body" 'os.Rename(tmp, s.progPath)' || bad=1
  has B1 'writeProg no longer writes a "LOADING ...\n" line' "$body" 'lines = fmt.Sprintf("LOADING %d %d %d %s\n",' || bad=1
  has B2 'writeProg no longer appends a "DAMAGED ...\n" line' "$body" 'lines += fmt.Sprintf("DAMAGED %d %s\n",' || bad=1
  has B3 'writeProg no longer appends an "INCOMPLETE ...\n" line' "$body" 'lines += fmt.Sprintf("INCOMPLETE %d %s\n",' || bad=1
  has B4 'writeProg no longer appends a "RESTORING ...\n" line' "$body" 'lines += fmt.Sprintf("RESTORING %d %d %d\n",' || bad=1
  has B5 'writeProg no longer gates RESTORE-WAITING on files left and the parked state' \
    "$body" 'if s.restoring.left > 0 && s.restoring.waiting {' || bad=1
  has B5 'writeProg no longer appends a "RESTORE-WAITING\n" line' "$body" 'lines += "RESTORE-WAITING\n"' || bad=1

  # (f) NWP-20261207-11: WAITING_BODY is the decided O3 words, read from the real MediaStatus.java.
  local wb o3
  wb=$(sed -n 's/^ *static final String WAITING_BODY = "\([^"]*\)";$/\1/p' "$SUT")
  o3=$(grep -F -- '- **O3.' "$decisions" || true)
  if [ -z "$wb" ]; then
    echo "  FAIL  F1 WAITING_BODY not found in $SUT" >&2; bad=1
  else
    has F1 "the O3 line of docs/product-decisions.md does not hold *\"$wb\"* while parked" \
      "$o3" "*\"$wb\"* while parked" || bad=1
  fi

  # (c) the daemon's GET-MEDIA-STATUS arm relays the file whole.
  raw=$(awk '/^\tif name == "GET-MEDIA-STATUS" \{/ { on = 1 } on { print } on && /^\t}$/ { exit }' "$maingo")
  body=$(strip_go <<<"$raw")
  has C0 "the GET-MEDIA-STATUS arm not found in $maingo, or it no longer reads mediaProgressFile (control)" \
    "$body" 'mediaProgressFile' || bad=1
  has C1 'the arm no longer trims only the trailing CR/LF of the file' \
    "$body" 'line := strings.TrimRight(string(b), "\r\n")' || bad=1
  has C2 'the arm no longer relays the file whole' "$body" 'fmt.Fprint(conn, line+"\n")' || bad=1

  # (e) NWP-20261114-34: a background landing starts the session's rescan. The watcher polls GET-MEDIA-LANDED, decides
  # with MediaStatus.rescanAfterLanding and calls requestMediaRescan, which starts CredentialService rescanmedia as the
  # session user; the daemon relays media.landed; materialize raises the counter after a run that landed files.
  code=$(strip_java "$chooser")
  body=$(printf '%s\n' "$code" | awk '/private void startSyncStatusWatcher\(\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  nb=$(tr -s ' \n' '  ' <<<"$body")
  has E1 'the watcher does not poll GET-MEDIA-LANDED' "$body" 'pollDaemon("GET-MEDIA-LANDED\n")' || bad=1
  # NWP-20261208-09: a landing is held (rescanHeld), not started at once; the hold asks GET-SWEEP each tick.
  has E2 'a landing does not set the held rescan through MediaStatus.rescanAfterLanding' \
    "$nb" 'if (MediaStatus.rescanAfterLanding(landedSeen, landedReply)) { rescanHeld = MediaStatus.landed(landedReply);' \
    || bad=1
  has E3 'the watcher does not reset its count for a new session' "$nb" 'if (uid != landedUid) { landedUid = uid; landedSeen = "0";' \
    || bad=1
  has E7 'the held rescan does not poll GET-SWEEP' "$nb" 'String sw = pollDaemon("GET-SWEEP\n");' || bad=1
  has E7 'the held rescan does not decide with MediaStatus.holdRescanForSweep on the GET-SWEEP reply and the cap' \
    "$nb" 'MediaStatus.holdRescanForSweep(sw, heldMs, MediaStatus.RESCAN_SWEEP_CAP_MS)' || bad=1
  local rq='requestMediaRescan(' hr='MediaStatus.holdRescanForSweep(' rest n pre ih irq
  rest=${nb//"$rq"/}; n=$(( (${#nb} - ${#rest}) / ${#rq} ))
  if [ "$n" -ne 1 ]; then
    echo "  FAIL  E8 the watcher calls requestMediaRescan( $n times, want exactly 1" >&2; bad=1
  fi
  has E8 'the watcher does not start the held rescan with requestMediaRescan(app, uid, rescanHeld)' \
    "$nb" 'requestMediaRescan(app, uid, rescanHeld);' || bad=1
  if [[ $nb == *"$hr"* && $nb == *"$rq"* ]]; then
    pre=${nb%%"$hr"*}; ih=${#pre}
    pre=${nb%%"$rq"*}; irq=${#pre}
    if ! [ "$ih" -lt "$irq" ]; then
      echo "  FAIL  E8 requestMediaRescan( comes before MediaStatus.holdRescanForSweep(" >&2; bad=1
    fi
  fi
  has E9 'the gate branch does not clear the held rescan' "$nb" 'landedUid = -1; rescanHeld = null; rescanHeldSince = -1;' \
    || bad=1
  has E9 'a new session does not clear the held rescan' \
    "$nb" 'if (uid != landedUid) { landedUid = uid; landedSeen = "0"; rescanHeld = null; rescanHeldSince = -1; }' || bad=1
  local rmr
  rmr=$(printf '%s\n' "$code" \
    | awk '/private static void requestMediaRescan\(Context app, int uid, String count\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }')
  rmr=$(tr -s ' \n' '  ' <<<"$rmr")
  has E4 'requestMediaRescan does not start CredentialService rescanmedia as the session user' \
    "$rmr" 'app.startServiceAsUser( new android.content.Intent(app, CredentialService.class).putExtra(ScanNetHold.EXTRA_LANDED, true).putExtra("rescanmedia", true), android.os.UserHandle.of(uid));' || bad=1
  raw=$(awk '/^\tif name == "GET-MEDIA-LANDED" \{/ { on = 1 } on { print } on && /^\t}$/ { exit }' "$maingo")
  body=$(strip_go <<<"$raw")
  has E5 'the daemon has no GET-MEDIA-LANDED arm reading mediaLandedFile' "$body" 'filepath.Join(dest, mediaLandedFile)' || bad=1
  raw=$(awk '/^func \(s \*mediaServer\) materialize\(/ { on = 1 } on { print } on && /^}$/ { exit }' "$mediago")
  body=$(strip_go <<<"$raw")
  has E6 'materialize does not raise the landed counter after a run that landed files' \
    "$body" 'bumpMediaLanded(s.stateDir, label+" materialize")' || bad=1
  # NWP-20261208-09, the premise: GET-SWEEP answers "LIVE <s>" or "NONE" and is on the lock-free list.
  raw=$(awk '/^func handleGetSweep\(conn net\.Conn\) \{/ { on = 1 } on { print } on && /^}$/ { exit }' "$sweepgo")
  body=$(strip_go <<<"$raw")
  has E10 'handleGetSweep does not write "LIVE <seconds>\n" while the lease is live' \
    "$body" 'fmt.Fprintf(conn, "LIVE %d\n", int(age.Seconds()))' || bad=1
  has E10 'handleGetSweep does not write "NONE\n" otherwise' "$body" 'fmt.Fprint(conn, "NONE\n")' || bad=1
  raw=$(awk '/^func concurrentSafeCmd\(name string\) bool \{/ { on = 1 } on { print } on && /^}$/ { exit }' "$maingo")
  body=$(strip_go <<<"$raw")
  has E10 'GET-SWEEP is not on the lock-free list (concurrentSafeCmd)' "$body" '"GET-SWEEP",' || bad=1

  [ "$bad" -eq 0 ]
}

echo "== $SUT"
suite "$SUT" || { echo "FAILED"; exit 1; }
source_check "$CHOOSER" "$MEDIA_GO" "$MAIN_GO" "$DECISIONS" "$SWEEP_GO" || { echo "FAILED (source)"; exit 1; }
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
mutsrc() { # mutsrc <label> <chooser|media|main|decisions|sweep> <perl-expr>   (mutates one source copy; the source check must fail)
  local label="$1" kind="$2" expr="$3" d orig c rc ch="$CHOOSER" md="$MEDIA_GO" mn="$MAIN_GO" dc="$DECISIONS" sw="$SWEEP_GO"
  case "$kind" in
    chooser) orig="$CHOOSER" ;; media) orig="$MEDIA_GO" ;; main) orig="$MAIN_GO" ;; decisions) orig="$DECISIONS" ;;
    sweep) orig="$SWEEP_GO" ;;
    *) echo "  ERROR     $label -- unknown source kind $kind"; return 1 ;;
  esac
  d=$(mktemp -d -p "$W") || return 1; c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$expr" "$c"; then echo "  ERROR     $label -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $label -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$kind" in chooser) ch="$c" ;; media) md="$c" ;; main) mn="$c" ;; decisions) dc="$c" ;; sweep) sw="$c" ;; esac
  source_check "$ch" "$md" "$mn" "$dc" "$sw" >/dev/null 2>&1; rc=$?
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
# NWP-20261202-28: the RESTORING slot, its parser, the watcher's order and the notice's title.
mut "R7 slot 3 is never filled (cases S10-S13)" \
  's/\n\s*: line\.startsWith\("RESTORING"\) \? 3//' || fails=$((fails+1))
mut "R8 RESTORING is routed into slot 0 (cases S10, S12, S13)" \
  's/startsWith\("RESTORING"\) \? 3/startsWith("RESTORING") ? 0/' || fails=$((fails+1))
mut "R9 restoring accepts left 0 (case P3)" 's/if \(v\[2\] <= 0\) return null;/if (v[2] < 0) return null;/' \
  || fails=$((fails+1))
mut "R10 restoring accepts done > total (case P4)" 's/if \(v\[0\] > v\[1\]\) return null;/if (false) return null;/' \
  || fails=$((fails+1))
mutsrc "R11 the watcher checks prefetchActive before the restoring line (D3)" chooser \
  's/\} else if \(MediaStatus\.restoring\(restLine\) != null\) \{(.*?)\} else if \(prefetchActive\) \{/} else if (prefetchActive) {$1} else if (MediaStatus.restoring(restLine) != null) {/s' \
  || fails=$((fails+1))
mutsrc "R12 the watcher drops the restoring branch (D2, D3)" chooser \
  's/\} else if \(MediaStatus\.restoring\(restLine\) != null\) \{.*?(\} else if \(prefetchActive\) \{)/$1/s' \
  || fails=$((fails+1))
mutsrc "R13 postMediaNotice uses a literal title, not the constant (D5)" chooser \
  's/\? MediaStatus\.RESTORING_TITLE/? "Restoring photos and files"/' || fails=$((fails+1))
mutsrc "R14 the RESTORING format loses its newline (B4)" media 's/"RESTORING %d %d %d\\n"/"RESTORING %d %d %d"/' \
  || fails=$((fails+1))
mut "R15 restoringPermille gives a zero total the indeterminate -1 (case Q2)" \
  's/if \(total <= 0 \|\| done <= 0\) return 0;/if (total <= 0) return -1;\n        if (done <= 0) return 0;/' \
  || fails=$((fails+1))
mut "R16 restoringPermille multiplies in long and overflows (case Q5)" \
  's/\(int\) \(\(double\) done \* 1000 \/ total\)/(int) (done * 1000 \/ total)/' || fails=$((fails+1))
mutsrc "R17 postMediaNotice gates the restoring bar on total > 0 (D7)" chooser \
  's/if \(rest != null\) \{\s*(?:\/\/[^\n]*\s*)?b\.setProgress\(1000, MediaStatus\.restoringPermille\(done, total\), false\);\s*\} else if \(!prefetch && total > 0/if (!prefetch \&\& total > 0/' \
  || fails=$((fails+1))
# NWP-20261114-34: the landed count and the rescan it starts.
mut "R18 rescanAfterLanding fires on a 0 count (case L10)" 's/now != null && !now\.equals\("0"\) && /now != null \&\& /' \
  || fails=$((fails+1))
mut "R19 rescanAfterLanding fires on an unchanged count (case L9)" 's/ && !now\.equals\(seen\);/;/' || fails=$((fails+1))
mut "R20 landed accepts a negative (case L7)" "s/if \\(c < '0' \\|\\| c > '9'\\) return null;/if ((c < '0' || c > '9') \\&\\& c != '-') return null;/" \
  || fails=$((fails+1))
mutsrc "R21 the watcher never starts the held rescan (E8)" chooser \
  's/\n\s*requestMediaRescan\(app, uid, rescanHeld\);//' || fails=$((fails+1))
mutsrc "R22 requestMediaRescan starts the service as user 0 (E4)" chooser \
  's/(EXTRA_LANDED, true\)\.putExtra\("rescanmedia", true\),\s*)android\.os\.UserHandle\.of\(uid\)/$1android.os.UserHandle.SYSTEM/' || fails=$((fails+1))
mutsrc "R23 materialize no longer raises the counter (E6)" media \
  's/\n\s*bumpMediaLanded\(s\.stateDir, label\+" materialize"\)[^\n]*//' || fails=$((fails+1))
# NWP-20261207-11: the RESTORE-WAITING slot, restoreWaiting, the watcher's argument, the body and the O3 words.
mut "R24 route fills slot 4 by prefix (case W3)" \
  's/line\.equals\("RESTORE-WAITING"\) \? 4/line.startsWith("RESTORE-WAITING") ? 4/' || fails=$((fails+1))
mut "R25 restoreWaiting ignores slot 3 (case W5a)" 's/ && restoring\(routed\[3\]\) != null//' || fails=$((fails+1))
mutsrc "R26 the watcher always passes false (D8)" chooser \
  's/restLine, MediaStatus\.restoreWaiting\(mr\)\)/restLine, false)/' || fails=$((fails+1))
mut "R27 WAITING_BODY text changed (case T2)" 's/"Waiting for a network"/"Waiting for network"/' || fails=$((fails+1))
mutsrc "R28 the body ignores waiting (D9)" chooser 's/waiting \? MediaStatus\.WAITING_BODY : //' || fails=$((fails+1))
mutsrc "R29 the RESTORE-WAITING token is misspelt (B5)" media 's/"RESTORE-WAITING\\n"/"RESTORE_WAITING\\n"/' \
  || fails=$((fails+1))
mutsrc "R30 the O3 words change (F1)" decisions \
  's/\*"Waiting for a network"\* while parked/*"Waiting for network"* while parked/' || fails=$((fails+1))
# NWP-20261208-09: the hold behind the Auto sweep, its cap, the watcher's wiring and the GET-SWEEP premise.
mut "R31 any non-empty reply holds (case H3)" \
  's/(String v = sweepReply\.trim\(\);)/$1\n        if (!v.isEmpty()) return true;/' || fails=$((fails+1))
mut "R32 the cap is ignored (case H8)" 's/ \|\| heldMs >= capMs\) return false;/) return false;/' || fails=$((fails+1))
mut "R33 the cap admits heldMs == capMs (case H8)" 's/heldMs >= capMs/heldMs > capMs/' || fails=$((fails+1))
mut "R34 a negative held time holds (case H10)" 's/ \|\| heldMs < 0 \|\|/ ||/' || fails=$((fails+1))
mutsrc "R35 the watcher passes NONE, not the GET-SWEEP reply (E7)" chooser \
  's/holdRescanForSweep\(sw, /holdRescanForSweep("NONE", /' || fails=$((fails+1))
mutsrc "R36 the old direct call on landing is restored (E2, E8)" chooser \
  's/if \(MediaStatus\.rescanAfterLanding\(landedSeen, landedReply\)\) \{/if (MediaStatus.rescanAfterLanding(landedSeen, landedReply)) requestMediaRescan(app, uid, MediaStatus.landed(landedReply));\n                if (false) {/' \
  || fails=$((fails+1))
mutsrc "R37 a new session keeps the held rescan (E9)" chooser \
  's/landedSeen = "0"; rescanHeld = null; /landedSeen = "0"; /' || fails=$((fails+1))
mutsrc "R38 handleGetSweep writes SWEEP, not LIVE (E10)" sweep 's/"LIVE %d\\n"/"SWEEP %d\\n"/' || fails=$((fails+1))
mut "R39 the cap is 24 hours (case C1)" 's/60L \* 60 \* 1000/24L * 60 * 60 * 1000/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
