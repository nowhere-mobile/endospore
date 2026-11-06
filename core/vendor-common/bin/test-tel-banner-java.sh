#!/usr/bin/env bash
# test-tel-banner-java.sh [--mutate] -- NWP-20261013-41: the gate banner groups its telephony notices by line and counts
# EVENTS, not notices. Runs core/chooser/tests/tel-banner: ChooserActivity.summarize compiled and EXECUTED, and the
# receiver's running count checked at its call sites (tests/tel-banner/run.sh says how).
#
# WHY THIS IS COMMITTED. A line has one notice per kind and a second text replaces the first in place, so counting
# notices read two texts on Sim1 plus one on another line as "2 new messages" with no line named -- misleading when one
# line is bound and the other is not (Chester, handset test 2026-09-27). The banner now names each line's notices under
# its label, and the receiver carries a running nowhere_count so a second text counts. Each of those is one line a later
# edit can change without breaking a build.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE (a copy that no longer
# compiles convicts nothing and is reported).
#
#   bash test-tel-banner-java.sh            # the cases
#   bash test-tel-banner-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/tel-banner/run.sh"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-tel-banner-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
bash "$RUN" "$CH"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case) =="
  M=$(mktemp -d)
  trap 'rm -rf "$M"' EXIT
  mutate(){ # mutate <label> <file under the chooser dir> <sed script>
    rm -rf "$M/c"; mkdir -p "$M/c/src/com/nowhere/chooser"
    cp "$CH"/src/com/nowhere/chooser/*.java "$M/c/src/com/nowhere/chooser/"
    local f="$M/c/$2"
    if ! sed -i "$3" "$f" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$f" "$CH/$2"; then no "MUTATION INERT: $1"; return; fi
    bash "$RUN" "$M/c" >/dev/null 2>&1; local r=$?
    case "$r" in
      1) ok "convicted: $1" ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTATION BROKEN (run.sh exit $r, not a case): $1" ;;
    esac
  }
  C=src/com/nowhere/chooser/ChooserActivity.java; R=src/com/nowhere/chooser/SmsDeliverReceiver.java
  mutate "ungrouped: a line's kinds spread over separate groups" $C 's/int\[\] c = byLine.get(n\[0\]);/int[] c = byLine.get(n[0] + n[1]);/; s/byLine.put(n\[0\], c);/byLine.put(n[0] + n[1], c);/'
  mutate "ungrouped: every notice its own group"              $C 's/int\[\] c = byLine.get(n\[0\]);/int[] c = null;/'
  mutate "notices counted, not the count extra"               $C 's/int k = Integer.parseInt(n\[2\]);/int k = 1;/'
  mutate "the label dropped"                                  $C 's/if (!e.getKey().isEmpty()) sb.append(e.getKey()).append(" — ");//'
  mutate "every line folded into one group"                   $C 's/int\[\] c = byLine.get(n\[0\]);/int[] c = byLine.get("");/; s/byLine.put(n\[0\], c);/byLine.put("", c);/'
  mutate "a counted notice keeps its rich text"               $C 's/if (notices.size() == 1 \&\& "1".equals(notices.get(0)\[2\]))/if (notices.size() == 1)/'
  mutate "a loss notice counted as a message"                 $C 's/if ("true".equals(n\[3\])) c\[2\] += k; else if/if (false) c[2] += k; else if/'
  mutate "the old flat separator between lines"               $C '/static String summarize/,/^    }$/s/if (!firstLine) sb.append(" · ");/if (!firstLine) sb.append("  ·  ");/'
  mutate "the banner ignores the notice's count"              $C 's/String.valueOf(Math.max(1, ex.getInt("nowhere_count", 1)))/"1"/'
  mutate "the banner ignores the notice's line"               $C 's/notices.add(new String\[\]{noticeLabel(sbn),/notices.add(new String[]{"",/'
  mutate "the receiver never adds the new arrival"            $R 's/ox.getInt("nowhere_count", 1)) + 1;/ox.getInt("nowhere_count", 1));/'
  mutate "the receiver never stores the count"                $R '/nx.putInt("nowhere_count", count);/d'
  mutate "the receiver reads no previous count"               $R 's/if (old == null || old.getId() != nid || !TEL_CHANNEL.equals(old.getTag())) continue;/continue;/'
  mutate "the second arrival's title loses the label suffix"  $R 's/title + "  -  " + line)/title)/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
