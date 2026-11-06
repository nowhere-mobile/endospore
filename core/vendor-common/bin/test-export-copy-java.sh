#!/usr/bin/env bash
# test-export-copy-java.sh [--mutate] -- NWP-20261101-02: "Export a copy" names what a copy leaves out
# (docs/product-decisions.md, 2026-10-20, Q155). Runs core/chooser/tests/export-copy (ExportCopy's two strings and
# doneText, compiled and EXECUTED) and source checks that ProfileActivity shows the line under the button and builds
# the done line through ExportCopy.doneText.
# NWP-20261124-21: also the export's read cap and its lost replies. ExportCopy.READ_MS and the unanswered texts are
# executed; source checks s12-s17 pin that sendExport and the EXPORT-MEDIA send read for ExportCopy.READ_MS, that
# READ_MS outlasts BOTH core/agent/main.go arms' deadlines (EXPORT and EXPORT-MEDIA; the daemon must give up first,
# #744), and that runExport reports an empty reply as "may still export", never as failed.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must FAIL: a mutant that does not apply (INERT) or
# does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-export-copy-java.sh            # the cases
#   bash test-export-copy-java.sh --mutate   # ... plus the mutants
set -uo pipefail
MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-export-copy-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
command -v perl >/dev/null 2>&1 || { echo "test-export-copy-java: FAIL -- the source checks need perl, and there is none; this suite did NOT run" >&2; exit 2; }
EC="$ROOT/core/chooser/src/com/nowhere/chooser/ExportCopy.java"
PA="$ROOT/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
MG="$ROOT/core/agent/main.go"

# check <ExportCopy.java> <ProfileActivity.java> <main.go>: the cases, then the source checks.
check() {
  local ec=$1 pa=$2 mg=$3 out rc src line
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/export-copy/run.sh" "$ec" || return 1
  src=$(cat "$pa")
  # (s1) the line after the Export a copy button adds a view holding ExportCopy.UNDER_BUTTON
  line=$(grep -n 'secondaryButton("Export a copy"' <<<"$src" | head -1 | cut -d: -f1)
  [ -n "$line" ] || { echo "FAIL s1: no Export a copy button"; return 1; }
  out=$(sed -n "$((line+1)),$((line+4))p" <<<"$src")
  case "$out" in *ExportCopy.UNDER_BUTTON*) ;; *) echo "FAIL s1: no view holding ExportCopy.UNDER_BUTTON under the button"; return 1 ;; esac
  # (s2) startExport's success line calls ExportCopy.doneText
  case "$src" in *"st.setText(ExportCopy.doneText("*) ;; *) echo "FAIL s2: the success line does not call ExportCopy.doneText"; return 1 ;; esac
  # (s3) no literal "Exported " + remains
  case "$src" in *'"Exported " +'*) echo "FAIL s3: a literal \"Exported \" + remains"; return 1 ;; esac
  echo "  ok   source checks s1 s2 s3"
  unread_checks "$pa" || return 1
  echo "  ok   source checks s4 s5 s6 s7 s8 s9 s10 s11"
  read_cap_checks "$ec" "$pa" "$mg" || return $?
  echo "  ok   source checks s12 s13 s14 s15 s16 s17"
}

# strip <in> <out>: Java comments removed, string literals kept (so "content://sms" survives).
strip() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*")|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : ""}gse' "$1" > "$2"
}

# body <file> <signature>: the method from its signature to its closing brace.
body() {
  awk -v sig="$2" '
    !on && index($0, sig) { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1"
}

# has <text> <perl regex>: 0 when the text matches.
has() { perl -0e 'exit(($ARGV[0] =~ /$ARGV[1]/s) ? 0 : 1)' -- "$1" "$2"; }

# unread_checks <ProfileActivity.java>: s4-s11 (NWP-20261112-24), on a comment-stripped copy.
unread_checks() {
  local pa=$1 st b pair fn perm pre r
  st=$(mktemp -p "$W") || return 1
  strip "$pa" "$st" || { echo "FAIL s4: could not strip $pa"; return 1; }
  for pair in buildContactsVCard:READ_CONTACTS buildCalendarICal:READ_CALENDAR buildSmsXml:READ_SMS \
              buildCallLogXml:READ_CALL_LOG; do
    fn=${pair%%:*}; perm=${pair#*:}
    b=$(body "$st" "private byte[] $fn(int[] out)")
    [ -n "$b" ] || { echo "FAIL s4: $fn was not found"; return 1; }
    # (s4) the permission check comes before the first query and returns with out[1] = 0
    case "$b" in *'getContentResolver().query('*) ;; *) echo "FAIL s4: $fn has no getContentResolver().query("; return 1 ;; esac
    pre=${b%%getContentResolver().query(*}
    r='if \(checkSelfPermission\(Manifest\.permission\.'"$perm"'\) != PackageManager\.PERMISSION_GRANTED\) \{\s*out\[0\] = 0;\s*out\[1\] = 0;\s*return null;\s*\}'
    has "$pre" "$r" || { echo "FAIL s4: $fn does not check $perm before its first query and return with out[1] = 0"; return 1; }
    # (s5) its catch flags a failed read
    has "$b" 'catch \(Throwable t\) \{[^}]*out\[1\] = 1;[^}]*\}' \
      || { echo "FAIL s5: $fn's catch does not set out[1] = 1"; return 1; }
    # (s6) its null cursor flags a failed read (and the contacts null vCard stream)
    has "$b" 'if \(c == null\) \{\s*out\[0\] = 0;\s*out\[1\] = 1;\s*return null;\s*\}' \
      || { echo "FAIL s6: $fn's null cursor does not set out[1] = 1"; return 1; }
    case "$b" in *'if (c != null)'*) echo "FAIL s6: $fn still reads a null cursor as none"; return 1 ;; esac
    if [ "$fn" = buildContactsVCard ]; then
      has "$b" 'if \(in == null\) \{\s*out\[0\] = 0;\s*out\[1\] = 1;\s*return null;\s*\}' \
        || { echo "FAIL s6: $fn's null vCard stream does not set out[1] = 1"; return 1; }
    fi
    # (s11) the builder logs nothing: a provider or stream exception can carry a URI or content; runExport logs
    # the kind alone (s10)
    ! has "$b" '(?<![\w.])Log\.[a-z]+\(' \
      || { echo "FAIL s11: $fn logs (an exception or content); only runExport logs, by kind"; return 1; }
  done
  b=$(body "$st" "private void runExport()")
  [ -n "$b" ] || { echo "FAIL s7: runExport was not found"; return 1; }
  # (s7) every kind's out has the failed-read slot
  has "$b" 'final int\[\] cN = \{0, 0\}, eN = \{0, 0\}, sN = \{0, 0\}, lN = \{0, 0\};' \
    || { echo "FAIL s7: runExport does not allocate {0, 0} for cN, eN, sN, lN"; return 1; }
  # (s8) the done line's missing clause names the kinds that could not be read
  has "$b" 'String missing = .*?missing \+= ExportCopy\.unreadLine\(cN\[1\] == 1, eN\[1\] == 1, sN\[1\] == 1, lN\[1\] == 1\);.*?st\.setText\(ExportCopy\.doneText\(' \
    || { echo "FAIL s8: runExport does not append ExportCopy.unreadLine(cN[1], eN[1], sN[1], lN[1]) to missing"; return 1; }
  # (s9) the NOMEDIA arm says which kind could not be read before "Nothing to export yet"
  has "$b" 'final String unread = ExportCopy\.unreadText\(cN\[1\] == 1, eN\[1\] == 1, sN\[1\] == 1, lN\[1\] == 1\);.*?s\.startsWith\("NOMEDIA"\)\s*\?\s*\(!unread\.isEmpty\(\) \? unread\s*:\s*"Nothing to export yet' \
    || { echo "FAIL s9: the NOMEDIA arm is not preceded by the unread check"; return 1; }
  # (s10) one log line per failed kind, its name only
  for pair in c:contacts e:calendar s:messages l:calls; do
    has "$b" 'if \('"${pair%%:*}"'N\[1\] == 1\) Log\.w\("NowhereChooser", "export: '"${pair#*:}"' could not be read"\);' \
      || { echo "FAIL s10: runExport does not log a failed ${pair#*:} read"; return 1; }
  done
}
# arm_deadline <main.go> <verb>: the seconds in the one conn.SetDeadline(time.Now().Add(<n> * time.Second)) of the
# arm `if name == "<verb>" {`, read to its closing brace. Prints nothing when there is not exactly one arm and one
# deadline in it.
arm_deadline() {
  perl -0e '
    my ($f, $v) = @ARGV; open(my $h, "<", $f) or exit 0; local $/; my $t = <$h>;
    my @a = ($t =~ /^\tif name == "\Q$v\E" \{\n(.*?)^\t\}$/msg);
    exit 0 unless @a == 1;
    my @d = ($a[0] =~ /conn\.SetDeadline\(time\.Now\(\)\.Add\((\d+) \* time\.Second\)\)/g);
    print $d[0] if @d == 1;
  ' -- "$1" "$2"
}

# read_cap_checks <ExportCopy.java> <ProfileActivity.java> <main.go>: s12-s17 (NWP-20261124-21), on comment-stripped
# copies. Returns 2 when a number could not be read (EXTRACTION FAILED).
read_cap_checks() {
  local ec=$1 pa=$2 mg=$3 st sec b el ms verb n
  st=$(mktemp -p "$W") || return 1
  strip "$pa" "$st" || { echo "FAIL s12: could not strip $pa"; return 1; }
  # (s12) sendExport reads for ExportCopy.READ_MS and sets no other read cap
  b=$(body "$st" "private String sendExport(byte[] bundle)")
  [ -n "$b" ] || { echo "FAIL s12: sendExport was not found"; return 1; }
  has "$b" 's\.setSoTimeout\(ExportCopy\.READ_MS\);' && ! has "$b" 'setSoTimeout\((?!ExportCopy\.READ_MS\))' \
    || { echo "FAIL s12: sendExport does not read for ExportCopy.READ_MS alone"; return 1; }
  b=$(body "$st" "private void runExport()")
  [ -n "$b" ] || { echo "FAIL s13: runExport was not found"; return 1; }
  # (s13) the EXPORT-MEDIA send reads for ExportCopy.READ_MS, not sendDaemon's 90 s
  has "$b" 'DaemonSocket\.roundTrip\("EXPORT-MEDIA\\n", ExportCopy\.READ_MS\)' \
    || { echo "FAIL s13: runExport does not send EXPORT-MEDIA through DaemonSocket.roundTrip(..., ExportCopy.READ_MS)"; return 1; }
  ! has "$b" 'sendDaemon(Multi)?\("EXPORT-MEDIA' \
    || { echo "FAIL s13: runExport still sends EXPORT-MEDIA through sendDaemon"; return 1; }
  # (s14) the partial branch says an unanswered half may still export
  has "$b" 'mediaFailed\s*\?\s*\(mr\.isEmpty\(\) \? ExportCopy\.MEDIA_UNANSWERED\s*:\s*" Your photos & files didn.t export' \
    || { echo "FAIL s14: the partial branch reports an unanswered media half as \"didn't export\""; return 1; }
  has "$b" 'docsFailed\s*\?\s*\(r\.isEmpty\(\) \? ExportCopy\.DOCS_UNANSWERED\s*:\s*" Your contacts, calendar, messages and calls didn.t export' \
    || { echo "FAIL s14: the partial branch reports an unanswered documents half as \"didn't export\""; return 1; }
  # (s15) the nothing-landed branch says the copy may still finish when its reply is ""
  has "$b" ':\s*s\.isEmpty\(\) \? ExportCopy\.unansweredText\(\)\s*:\s*"Couldn.t export — check your connection and try again\.";' \
    || { echo "FAIL s15: the nothing-landed branch reports an empty reply as \"check your connection\""; return 1; }
  # (s17) the nothing-landed branch adds the lost-media clause and sets no bare msg
  el=${b#*'final String s = haveDocs ? r : mr;'}
  [ "$el" != "$b" ] || { echo "FAIL s17: runExport has no nothing-landed branch (final String s = haveDocs ? r : mr;)"; return 1; }
  has "$el" 'st\.setText\(msg \+ ExportCopy\.lostMediaClause\(haveDocs, r, mr\)\);' && ! has "$el" 'st\.setText\(msg\);' \
    || { echo "FAIL s17: the nothing-landed branch does not add ExportCopy.lostMediaClause(haveDocs, r, mr)"; return 1; }
  # (s16) READ_MS outlasts both arms' deadlines in main.go
  ms=$(perl -ne 'if (/static final int READ_MS = ([0-9_]+);/) { (my $v = $1) =~ s/_//g; print $v; exit }' "$ec")
  [ -n "$ms" ] || { echo "EXTRACTION FAILED s16: no static final int READ_MS in $ec"; return 2; }
  for verb in EXPORT EXPORT-MEDIA; do
    n=$(arm_deadline "$mg" "$verb")
    [ -n "$n" ] || { echo "EXTRACTION FAILED s16: no single arm 'if name == \"$verb\" {' with one conn.SetDeadline(... * time.Second) in $mg"; return 2; }
    [ "$ms" -gt $((n * 1000)) ] \
      || { echo "FAIL s16: ExportCopy.READ_MS ($ms ms) does not outlast the $verb arm's deadline ($n s) in main.go"; return 1; }
  done
}
check "$EC" "$PA" "$MG"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; [ "$rc" -eq 2 ] && exit 2; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <ec|pa|mg> <perl-expr> <text the failure must contain>
  local d f o ec pa mg out rc
  d=$(mktemp -d -p "$W"); ec=$EC; pa=$PA; mg=$MG
  case "$2" in
    ec) o=$EC; f="$d/ExportCopy.java" ;;
    pa) o=$PA; f="$d/ProfileActivity.java" ;;
    mg) o=$MG; f="$d/main.go" ;;
    *) echo "  ERROR     $1 -- unknown target $2"; return 1 ;;
  esac
  cp "$o" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$o" "$f"; then echo "  INERT     $1"; return 1; fi
  case "$2" in ec) ec=$f ;; pa) pa=$f ;; mg) mg=$f ;; esac
  out=$(check "$ec" "$pa" "$mg" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4' (rc=$rc)"; return 1 ;; esac
  echo "  convicted $1"
}
fails=0
mut "E1 doneText drops NOT_INCLUDED" ec 's/" to your store\. " \+ NOT_INCLUDED/" to your store."/' "FAIL" || fails=$((fails+1))
mut "E2 2FA codes removed from NOT_INCLUDED" ec 's/\(2FA codes, notes, bookmarks, loyalty cards\)\./(notes, bookmarks, loyalty cards)./' "FAIL" || fails=$((fails+1))
mut "E3 the under-button view removed" pa 's/exportNote\.setText\(ExportCopy\.UNDER_BUTTON\);/exportNote.setText("");/' "FAIL s1" || fails=$((fails+1))
mut "E4 startExport back to the inline Exported string" pa 's/st\.setText\(ExportCopy\.doneText\(android\.text\.TextUtils\.join\(", ", parts\), missing,\s*exportWhereLine\(docsOk \? r : null, mediaOk \? mr : null\)\)\);/st.setText("Exported " + android.text.TextUtils.join(", ", parts) + " to your store." + missing + exportWhereLine(docsOk ? r : null, mediaOk ? mr : null));/' "FAIL s2" || fails=$((fails+1))
mut "M1 buildSmsXml's catch no longer flags a failed read" pa 's/(private byte\[\] buildSmsXml\(int\[\] out\) \{.*?catch \(Throwable t\) \{[^}]*?out\[0\] = 0;)\s*out\[1\] = 1;/$1/s' "FAIL s5" || fails=$((fails+1))
mut "M2 buildContactsVCard's permission check removed" pa 's/(private byte\[\] buildContactsVCard\(int\[\] out\) \{)\s*if \(checkSelfPermission[^}]*\}/$1/' "FAIL s4" || fails=$((fails+1))
mut "M3 buildCalendarICal's null cursor no longer flags a failed read" pa 's/(CalendarContract\.Events\.DTSTART \+ " ASC"\)\) \{\s*if \(c == null\) \{ out\[0\] = 0;) out\[1\] = 1;/$1/' "FAIL s6" || fails=$((fails+1))
mut "M4 unreadKinds drops the last kind" ec 's/ \+ " and " \+ k\.get\(k\.size\(\) - 1\)//' "FAIL unreadKinds" || fails=$((fails+1))
mut "M5 runExport no longer appends unreadLine" pa 's/\n[^\n]*missing \+= ExportCopy\.unreadLine\([^;]*\);//' "FAIL s8" || fails=$((fails+1))
mut "M6 the failure branch says Nothing to export yet when a kind failed" pa 's/\(!unread\.isEmpty\(\) \? unread\s*:\s*("Nothing to export yet[^"]*")\)/$1/' "FAIL s9" || fails=$((fails+1))
mut "M7 buildCallLogXml's catch logs the exception again" pa 's/(private byte\[\] buildCallLogXml\(int\[\] out\) \{.*?catch \(Throwable t\) \{)/$1 Log.w("NowhereChooser", "buildCallLog", t);/s' "FAIL s11" || fails=$((fails+1))
# NWP-20261124-21: the read cap and the lost replies
mut "E5 READ_MS back to 90 s" ec 's/static final int READ_MS = 150_000;/static final int READ_MS = 90_000;/' "FAIL" || fails=$((fails+1))
mut "E6 the EXPORT-MEDIA send back on sendDaemon" pa 's/DaemonSocket\.roundTrip\("EXPORT-MEDIA\\n", ExportCopy\.READ_MS\)/sendDaemon("EXPORT-MEDIA\\n")/' "FAIL s13" || fails=$((fails+1))
mut "E7 the partial branch reads an unanswered media half as didn't export" pa 's/mr\.isEmpty\(\) \? ExportCopy\.MEDIA_UNANSWERED\s*:\s*//' "FAIL s14" || fails=$((fails+1))
mut "E8 the nothing-landed branch reads an empty reply as check your connection" pa 's/: s\.isEmpty\(\) \? ExportCopy\.unansweredText\(\)\s*//' "FAIL s15" || fails=$((fails+1))
mut "E9 main.go's EXPORT-MEDIA arm deadline raised to 200 s" mg 's/(\n\tif name == "EXPORT-MEDIA" \{\n(?:(?!\n\t\}\n).)*?conn\.SetDeadline\(time\.Now\(\)\.Add\()120( \* time\.Second\)\))/${1}200$2/s' "FAIL s16" || fails=$((fails+1))
mut "E10 sendExport back to a 120 s read" pa 's/s\.setSoTimeout\(ExportCopy\.READ_MS\);/s.setSoTimeout(120000);/' "FAIL s12" || fails=$((fails+1))
mut "E11 the partial branch reads an unanswered documents half as didn't export" pa 's/r\.isEmpty\(\) \? ExportCopy\.DOCS_UNANSWERED\s*:\s*//' "FAIL s14" || fails=$((fails+1))
mut "E12 the nothing-landed branch drops the lost-media clause" pa 's/st\.setText\(msg \+ ExportCopy\.lostMediaClause\(haveDocs, r, mr\)\);/st.setText(msg);/' "FAIL s17" || fails=$((fails+1))
mut "E13 lostMediaClause ignores the empty media reply" ec 's/haveDocs && mr\.isEmpty\(\) && /haveDocs && /' "FAIL" || fails=$((fails+1))
mut "E14 lostMediaClause adds the clause after LOCAL or NONE" ec 's/ && !r\.startsWith\("LOCAL"\) && !r\.startsWith\("NONE"\)//' "FAIL" || fails=$((fails+1))
mut "E15 main.go's EXPORT arm deadline raised to 200 s" mg 's/(\n\tif name == "EXPORT" \{\n(?:(?!\n\t\}\n).)*?conn\.SetDeadline\(time\.Now\(\)\.Add\()120( \* time\.Second\)\))/${1}200$2/s' "FAIL s16" || fails=$((fails+1))
mut "E16 main.go's EXPORT-MEDIA arm loses its deadline" mg 's/(\n\tif name == "EXPORT-MEDIA" \{\n(?:(?!\n\t\}\n).)*?)\tconn\.SetDeadline\(time\.Now\(\)\.Add\(120 \* time\.Second\)\)[^\n]*\n/$1/s' "EXTRACTION FAILED s16" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
