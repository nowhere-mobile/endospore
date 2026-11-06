#!/usr/bin/env bash
# test-sessionlive-clear-java.sh [--mutate] -- the gate clears a stale sessionLive, run under javac (NWP-20261115-12).
#
# WHY THIS IS COMMITTED. The reap watcher's #123 self-heal sets sessionLive from any unlocked secondary user, and
# createRoamUser starts the new user before ROAM-IN. A sign-in that failed after one parked tick removed that user
# and nothing cleared sessionLive: the #73 orphan sweep and the #46 watchdog stayed off and the watcher polled at
# 250 ms until a sign-out or a reboot. The rule now lives in SessionLiveClear, a pure class with no android.*
# import, compiled here with its cases; a source guard checks ensureReapWatcher's fast tier goes through it, names
# every busy flag, and that the #123 self-heal is still there.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-sessionlive-clear-java.sh            # the cases + source guard
#   bash test-sessionlive-clear-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src"
COPY="$SRC/com/nowhere/chooser/SessionLiveClear.java"
ACT="$SRC/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/sessionlive-clear/SessionLiveClearCases.java"
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
command -v perl >/dev/null 2>&1 || { echo "FAIL: this suite needs perl, and there is none" >&2; exit 2; }
[ -f "$ACT" ] && [ -f "$CASES" ] || { echo "FAIL: missing $ACT or $CASES" >&2; exit 2; }

HEAL='if (um != null && um.isUserUnlocked(uh)) { sessionLive = true; break; }'

# guard <ChooserActivity.java> -> 0 clean, 1 a guard failed. Output is captured into variables (no pipe into grep -q).
guard() {
  local act="$1" bad=0 watcher fast code n busy name heal
  watcher=$(awk '/static void ensureReapWatcher\(Context ctx\) \{/ { on = 1 } on { print } on && /^    }$/ { exit }' "$act")
  case "$watcher" in
    *POLL-REAP*) ;;
    *) echo "  GUARD control: the extraction did not find ensureReapWatcher (no POLL-REAP in it)" >&2; return 1 ;;
  esac
  fast=$(printf '%s\n' "$watcher" | awk '/^                if \(signingOut \|\| sessionLive\) \{$/ { on = 1 }
                                        on && /^                \} else \{$/ { exit } on { print }')
  if [ -z "$fast" ]; then echo "  GUARD control: the extraction did not find the fast tier" >&2; return 1; fi
  code=$(printf '%s\n' "$fast" | sed 's,//.*$,,')
  n=$(printf '%s\n' "$code" | grep -c 'SessionLiveClear\.observe(')
  [ "$n" = 1 ] || { echo "  GUARD the fast tier calls SessionLiveClear.observe( $n times, want exactly 1" >&2; bad=1; }
  if ! perl -0e 'my $s = do { local $/; <STDIN> }; exit($s =~ /SessionLiveClear\.shouldClear\([^)]*\)\)\s*\{[^}]*\bsessionLive = false;/ ? 0 : 1)' \
       <<<"$code"; then
    echo "  GUARD the fast tier does not set sessionLive = false under SessionLiveClear.shouldClear(" >&2; bad=1
  fi
  n=$(printf '%s\n' "$code" | grep -c 'sessionLive = true')
  [ "$n" = 0 ] || { echo "  GUARD the fast tier sets sessionLive = true ($n line(s))" >&2; bad=1; }
  busy=$(printf '%s\n' "$code" | grep 'boolean slBusy = ')
  if [ -z "$busy" ]; then echo "  GUARD the fast tier has no busy expression (boolean slBusy = ...)" >&2; bad=1
  else
    for name in signingOut loginInProgress switchingIn; do
      case "$busy" in *"$name"*) ;; *) echo "  GUARD the busy expression does not name $name" >&2; bad=1 ;; esac
    done
  fi
  heal=$(grep -c -F "$HEAL" "$act")
  [ "$heal" = 1 ] || { echo "  GUARD the #123 self-heal line is present $heal times, want exactly 1" >&2; bad=1; }
  return "$bad"
}

# suite <SessionLiveClear.java> <ChooserActivity.java> -> 0 pass, 1 a case or guard failed (the only code that
# convicts a mutant), 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc bad=0
  guard "$act" || bad=1
  [ -f "$copy" ] || { echo "  FAIL  SessionLiveClear.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/SessionLiveClear.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/SessionLiveClearCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SessionLiveClearCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

echo "== $COPY"
suite "$COPY" "$ACT" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <copy|act> <perl-expr>
  local d c a rc target; d=$(mktemp -d -p "$W"); c="$d/SessionLiveClear.java"; a="$d/ChooserActivity.java"
  cp "$COPY" "$c"; cp "$ACT" "$a"
  target="$c"; [ "$2" = act ] && target="$a"
  if ! perl -0pi -e "$3" "$target"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$COPY" "$c" && cmp -s "$ACT" "$a"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$c" "$a" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "S1 null counted as none"                copy 's/if \(!Boolean\.FALSE\.equals\(anyUnlocked\)\) return 0;/if (Boolean.TRUE.equals(anyUnlocked)) return 0;/' || fails=$((fails+1))
mut "S2 busy ignored"                        copy 's/if \(!live \|\| busy\) return 0;/if (!live) return 0;/' || fails=$((fails+1))
mut "S3 threshold 1"                         copy 's/return streak >= 2;/return streak >= 1;/' || fails=$((fails+1))
mut "S4 an unlocked user does not reset"     copy 's/(if \(!Boolean\.FALSE\.equals\(anyUnlocked\)\))/if (Boolean.TRUE.equals(anyUnlocked)) return streak;\n        $1/' || fails=$((fails+1))
mut "S5 the watcher call removed"            act  's/slStreak = SessionLiveClear\.observe\(slStreak, sessionLive, slBusy, slAny\);/slStreak = 0;/' || fails=$((fails+1))
mut "S6 loginInProgress dropped from busy"   act  's/boolean slBusy = signingOut \|\| loginInProgress \|\| switchingIn;/boolean slBusy = signingOut || switchingIn;/' || fails=$((fails+1))
mut "S7 the clear assigns true"              act  's/(SessionLiveClear\.shouldClear\(slStreak\)\) \{\s*)sessionLive = false;/${1}sessionLive = true;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
