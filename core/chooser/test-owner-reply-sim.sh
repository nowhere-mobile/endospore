#!/usr/bin/env bash
# test-owner-reply-sim.sh [<ChooserActivity.java>] [--mutate] -- which unassigned SIM an owner-inbox Reply uses (NWP-20261014-31).
#
# WHY COMMITTED. On a phone with two or more unassigned SIMs a Reply used to leave on unboundSims().get(0), not on
# the line that received the message: the recipient saw the wrong number and the wrong line was billed. The inbox
# row already carries sub_id (core/agent/telephony_owner.go ownerInboxRow); ownerSimIndexFor picks the unbound SIM
# whose subId matches. ⚠ A subId is renumbered across reboots and the item stores no ICCID, so it is honoured ONLY
# for an item that arrived after this boot; an older one returns -1 and the compose screen says the line cannot be
# confirmed. Putting the arrival ICCID in the item is a daemon change and is out of scope. The Compose SIM picker
# is also out of scope.
#
# RUN, not grepped: ownerSimIndexFor and SimInfo are lifted verbatim out of ChooserActivity.java (neither touches
# Android) and executed under a real JVM, like test-ingest-key.sh. Two source checks pin the wiring.
#
#   bash test-owner-reply-sim.sh            # the truth table
#   bash test-owner-reply-sim.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
SUT="$(dirname "$0")/src/com/nowhere/chooser/ChooserActivity.java"
MUTATE=0
for a in "$@"; do case "$a" in --mutate) MUTATE=1 ;; *) SUT="$a" ;; esac; done
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
command -v javac >/dev/null || { echo "javac not on PATH"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

extract() { # extract <file> <signature-fragment>
  python3 - "$1" "$2" <<'PY'
import io, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.find(sys.argv[2])
if i < 0:
    sys.stderr.write('NOT FOUND: ' + sys.argv[2] + '\n'); sys.exit(1)
j = src.index('{', i); depth = 0
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            print(src[i:k+1]); sys.exit(0)
sys.stderr.write('UNBALANCED: ' + sys.argv[2] + '\n'); sys.exit(1)
PY
}

build() { # build <ChooserActivity.java> -> harness compiled into $WORK
  rm -rf "$WORK/K.java" "$WORK"/*.class
  {
    echo 'import java.util.*;'
    echo 'public class K {'
    extract "$1" 'private static class SimInfo' | sed 's/^private static class/static class/' || return 1
    extract "$1" 'static int ownerSimIndexFor' || return 1
    cat <<'JAVA'
  static int fails = 0;
  static void eq(String n, int want, int got) {
    if (want == got) System.out.println("  ok    " + n); else { fails++; System.out.println("  FAIL  " + n + " (want " + want + ", got " + got + ")"); }
  }
  static List<SimInfo> sims(int... ids) { List<SimInfo> l = new ArrayList<>(); for (int id : ids) { SimInfo s = new SimInfo(); s.subId = id; l.add(s); } return l; }
  public static void main(String[] a) {
    final long boot = 1_000_000L, after = boot + 5_000L, before = boot - 5_000L;
    eq("matches the first unbound SIM",  0, ownerSimIndexFor(sims(3, 4), 3, after, boot));
    eq("matches the second unbound SIM", 1, ownerSimIndexFor(sims(3, 4), 4, after, boot));
    eq("subId absent from the unbound list -> -1", -1, ownerSimIndexFor(sims(3, 4), 9, after, boot));
    eq("no arriving subId (-1) -> -1", -1, ownerSimIndexFor(sims(3, 4), -1, after, boot));
    eq("-1 never matches a SIM that reports subId -1", -1, ownerSimIndexFor(sims(-1, 4), -1, after, boot));
    eq("empty unbound list -> -1", -1, ownerSimIndexFor(sims(), 3, after, boot));
    eq("matching subId from before this boot -> -1", -1, ownerSimIndexFor(sims(3, 4), 4, before, boot));
    eq("arrival exactly at boot is this boot", 1, ownerSimIndexFor(sims(3, 4), 4, boot, boot));
    System.out.println(fails == 0 ? "suite passed" : "suite FAILED (" + fails + ")");
    System.exit(fails == 0 ? 0 : 1);
  }
}
JAVA
  } > "$WORK/K.java"
  javac -nowarn -d "$WORK" "$WORK/K.java" 2>"$WORK/javac.err"
}

wired() { # the Reply/Compose wiring, source level, on the file named by $1
  local src; src=$(cat "$1")
  local rc=0
  grep -q 'row.optInt("sub_id", -1)' <<<"$src" || { echo "  FAIL  the inbox loop does not read sub_id"; rc=1; }
  grep -q 'buildOwnerComposeScreen(from, arrivedSub, when)' <<<"$src" || { echo "  FAIL  Reply does not pass the arriving subId and time"; rc=1; }
  grep -q 'ownerSimIndexFor(u, arrivedSub, arrivedWhen' <<<"$src" || { echo "  FAIL  the compose resolver does not use ownerSimIndexFor"; rc=1; }
  [ "$rc" = 0 ] && echo "  ok    Reply wiring: sub_id read, passed through, resolved"
  return $rc
}

suite() { # suite <file> [quiet]
  build "$1" || { [ "${2:-}" = quiet ] || { echo "extract/compile failed:"; head -5 "$WORK/javac.err"; }; return 2; }
  if [ "${2:-}" = quiet ]; then java -cp "$WORK" K >/dev/null 2>&1 || return 1; wired "$1" >/dev/null; return $?
  else java -cp "$WORK" K || return 1; wired "$1"; fi
}

suite "$SUT"; RC=$?
[ "$MUTATE" = 0 ] && exit $RC
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit $RC; }

echo; echo "== mutations (each MUST be convicted) =="
MRC=0
mutant() { # mutant <label> <sed expr>
  local m="$WORK/mut.java"
  if ! sed "$2" "$SUT" > "$m" || cmp -s "$SUT" "$m"; then printf '  ⚠ BROKEN/INERT MUTANT  %s\n' "$1"; MRC=1; return; fi
  if suite "$m" quiet; then printf '  ⚠ SURVIVED  %s\n' "$1"; MRC=1; else printf '  convicted   %s\n' "$1"; fi
}
mutant "always the first SIM (today's behaviour)" 's|if (unbound.get(i).subId == arrivedSubId) return i;|if (true) return 0;|'
mutant "boot guard dropped (a renumbered subId is trusted)" 's/ || arrivedWhen < bootWallClock//'
mutant "last index instead of the match" 's|if (unbound.get(i).subId == arrivedSubId) return i;|if (unbound.get(i).subId == arrivedSubId) return unbound.size() - 1;|'
mutant "the -1 guard dropped" 's/arrivedSubId < 0 || //'
mutant "Reply no longer passes the arriving subId" 's/buildOwnerComposeScreen(from, arrivedSub, when)/buildOwnerComposeScreen(from, -1, when)/'
echo
[ "$MRC" = 0 ] && echo "all mutations convicted" || echo "⚠ at least one mutation was not convicted"
exit $MRC
