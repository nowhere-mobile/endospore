#!/usr/bin/env bash
# test-daemon-connect-java.sh [--mutate] -- NWP-20261022-20: DaemonSocket.connect()'s bound runs under javac, and a new
# bare chooser connect fails CI. Runs core/chooser/tests/daemon-connect under javac, plus a FENCE over core/chooser/src and
# core/napps/src.
#
# WHY THIS IS COMMITTED. Every chooser daemon call goes through DaemonSocket.connect (ProfileActivity's connect sites,
# ChooserActivity, UnarchiveService, StoreService, WifiMirror, NfcFido2; sendDaemon -> roundTrip). LocalSocket has no
# connect timeout, so a wedged daemon blocks a bare connect forever, and that cost the 60 s background-broadcast ANR that
# killed the persistent gate process (#77). connect() bounds it with a watchdog that closes the socket at
# CONNECT_CAP_MS if it wins a compare-and-set on `settled`; the caller's post-connect compare-and-set refuses a socket the
# watchdog already closed. Nothing executed that code. Three breakages passed CI green: dropping the post-connect
# check hands a caller a closed socket (every call on a slow-accepting daemon then fails as "no reply"); a watchdog that
# closes without the compare-and-set kills healthy connections (on the interrupt, at once); a new bare
# `new LocalSocket()` brings #77 back. The cases cover the first two; the FENCE covers the third.
#
# THIS SUITE PINS SHIPPED BEHAVIOUR: its cases pass on main. What must fail is every mutant (--mutate).
#
# WHAT IT DOES NOT PROVE: that a real LocalSocket.connect() against a WEDGED daemon (accepting, never answering) is
# unblocked by close() -- that is the backlog row's remaining device step ("doLogoff's LOGOUT and SEAL-STATUS socket
# connects have no timeout"). The stub closes a blocked connect the way the FP3 did in #77; the bound is what is tested.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below; the
# version is printed first so the log proves which compiler ran.
#
#   bash test-daemon-connect-java.sh            # the cap pin, the cases, the fence
#   bash test-daemon-connect-java.sh --mutate   # ... plus broken copies that must each FAIL the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
CH="$root/core/chooser/src/com/nowhere/chooser"
NAPPS="$root/core/napps/src"
DS="$CH/DaemonSocket.java"
RUN="$root/core/chooser/tests/daemon-connect/run.sh"
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
[ -f "$DS" ] && [ -f "$RUN" ] && [ -d "$NAPPS" ] || { echo "FAIL: missing $DS, $RUN or $NAPPS" >&2; exit 2; }
command -v perl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 \
  || { echo "FAIL: the suite needs perl and python3, and one is missing -- refusing to report" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export DAEMON_CONNECT_TMP="$W" TMPDIR="$W"

# codeonly: each line reduced to CODE -- line and block comments dropped, string, char and text-block literals
# emptied -- so a match cannot be fooled by prose. Same scanner as core/chooser/test-playdep-lock.sh.
codeonly(){ awk -v SQ="'" '
  BEGIN { inblock=0; intext=0 }
  {
    code=""; n=length($0); i=1
    while (i<=n) {
      c=substr($0, i, 1); two=substr($0, i, 2)
      if (inblock) { if (two=="*/") { inblock=0; i+=2 } else i++; continue }
      if (intext) { if (substr($0, i, 3)=="\"\"\"") { intext=0; i+=3 } else i++; continue }
      if (two=="//") break
      if (two=="/*") { inblock=1; i+=2; continue }
      if (substr($0, i, 3)=="\"\"\"") { intext=1; i+=3; code=code "\"\""; continue }
      if (c=="\"" || c==SQ) {
        q=c; i++
        while (i<=n) { d=substr($0, i, 1); if (d=="\\") { i+=2; continue }; if (d==q) break; i++ }
        i++; code=code q q; continue
      }
      code=code c; i++
    }
    print code
  }'; }

BARE='(^|[^[:alnum:]_$.])new[[:space:]]+(android[[:space:]]*\.[[:space:]]*net[[:space:]]*\.[[:space:]]*)?LocalSocket[[:space:]]*\('
ALLOWED="chooser/BackupNowReceiver.java chooser/DaemonSocket.java chooser/IdleLogoffReceiver.java chooser/ReloginReceiver.java"
WATCHDOGS="BackupNowReceiver IdleLogoffReceiver ReloginReceiver"

# pin_cap <DaemonSocket.java>: the shipped cap is declared exactly once, as 8000. -> 0 or 1
pin_cap() {
  local decls
  decls=$(codeonly < "$1" | grep -E 'CONNECT_CAP_MS[[:space:]]*=' || true)
  if [ "$(printf '%s' "$decls" | grep -c .)" != 1 ] \
     || ! grep -qE '^[[:space:]]*static final int CONNECT_CAP_MS = 8000;[[:space:]]*$' <<<"$decls"; then
    echo "  PIN   DaemonSocket.java must declare 'static final int CONNECT_CAP_MS = 8000;' exactly once (got: ${decls:-nothing})" >&2
    return 1
  fi
}

# sites <chooser-src-dir> <napps-src-dir>: print "<tier>/<relative path>" once per bare LocalSocket construction in code.
sites() {
  local tier dir f n
  for tier in chooser napps; do
    case "$tier" in chooser) dir="$1" ;; *) dir="$2" ;; esac
    while IFS= read -r f; do
      n=$(codeonly < "$f" | grep -cE "$BARE" || true)
      while [ "$n" -gt 0 ]; do echo "$tier/${f#"$dir"/}"; n=$((n-1)); done
    done < <(find "$dir" -name '*.java' | LC_ALL=C sort)
  done
}

# fence <chooser-src-dir> <napps-src-dir>: 0 when the sites are exactly ALLOWED and each receiver keeps its watchdog.
fence() {
  local got want f rc=0
  got=$(sites "$1" "$2" | sort | tr '\n' ' ' | sed 's/ $//')
  want=$(printf '%s\n' $ALLOWED | sort | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" != "$want" ]; then
    echo "  FENCE bare LocalSocket constructions: [$got], want exactly [$want] -- use DaemonSocket.connect()" >&2
    rc=1
  fi
  for f in $WATCHDOGS; do
    # the receiver's watchdog thread: sleeps its CONNECT_CAP_MS, then closes the socket, and is STARTED (an unstarted watchdog bounds nothing)
    if ! codeonly < "$1/$f.java" | perl -0ne 'exit(/Thread\s+(\w+)\s*=\s*new Thread\(\(\) -> \{\s*try \{ Thread\.sleep\(CONNECT_CAP_MS\); \} catch[^\n]*\n(?:(?!new Thread).)*?\bs\.close\(\).*?\n\s*\}\);(?:(?!new Thread).)*?\b\1\.start\(\)/s ? 0 : 1)'; then
      echo "  FENCE $f.java no longer holds a STARTED watchdog that sleeps CONNECT_CAP_MS and closes its socket" >&2
      rc=1
    fi
  done
  return "$rc"
}

# suite <DaemonSocket.java> -> 0 pass, 1 a pin or a case failed, 2 connect() did not extract, 3 it did not compile.
# Only 1 may convict a mutant; 2 and 3 prove nothing about the logic.
suite() {
  pin_cap "$1" || return 1
  bash "$RUN" "$1"
}

echo "== controls"
want4=$(sites "$CH" "$NAPPS" | wc -l | tr -d ' ')
[ "$want4" = 4 ] || { echo "FAIL: the fence found $want4 construction sites, want exactly 4 (DaemonSocket + 3 receivers)" >&2; exit 1; }
sample=$'// new LocalSocket()\n/* new LocalSocket() */\nString x = "new LocalSocket()";\nLocalSocket s = new android.net.LocalSocket();\nLocalSocket t = new LocalSocket ();'
c=$(codeonly <<<"$sample" | grep -cE "$BARE" || true)
[ "$c" = 2 ] || { echo "FAIL: the fence pattern matched $c of a sample's 2 real constructions (comments and strings must not count)" >&2; exit 1; }
echo "  the fence finds exactly the 4 allowed sites, and ignores comments and string literals"

echo "== $DS"
pin_cap "$DS" || { echo "FAILED"; exit 1; }
suite "$DS" || { echo "FAILED"; exit 1; }
echo "== fence"
fence "$CH" "$NAPPS" || { echo "FAILED"; exit 1; }
echo "  every chooser connect is DaemonSocket.connect or one of the 3 watchdog receivers"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED -- a mutant that does not apply, extract or compile proves nothing)"
# mut <label> <perl-expr>: a broken copy of DaemonSocket.java must fail the suite with rc 1
mut() {
  local d m rc
  d=$(mktemp -d -p "$W") || return 1
  m="$d/DaemonSocket.java"
  if ! perl -0pe "$2" "$DS" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; return 1; fi
  if cmp -s "$DS" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  suite "$m" >"$d/out" 2>&1; rc=$?
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) if grep -q '^FAIL ' "$d/out"; then echo "  convicted $1: $(grep -m1 '^FAIL ' "$d/out" | cut -c1-90)"; return 0
       else echo "  BROKEN    $1 -- failed without a FAIL line"; return 1; fi ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
# fmut <label> <file> <perl-expr>: a copy of the chooser tree with <file> mutated must fail the fence
fmut() {
  local d
  d=$(mktemp -d -p "$W") || return 1
  cp -R "$CH" "$d/chooser" || return 1
  perl -0pi -e "$3" "$d/chooser/$2" || { echo "  ERROR     $1 -- perl failed on the mutation"; return 1; }
  if diff -rq "$CH" "$d/chooser" >/dev/null; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  if fence "$d/chooser" "$NAPPS" >/dev/null 2>&1; then echo "  SURVIVED  $1"; return 1; fi
  echo "  convicted $1"
}
fails=0
mut "M1 the post-connect compareAndSet check removed"       's/if \(!settled\.compareAndSet\(false, true\)\) \{/if (false) {/' || fails=$((fails+1))
mut "M2 the watchdog closes without the compareAndSet"      's/if \(settled\.compareAndSet\(false, true\)\) \{ \/\/ watchdog won/if (true) { \/\/ watchdog won/' || fails=$((fails+1))
mut "M3 the watchdog is never started"                      's/\n\s*wd\.start\(\);//' || fails=$((fails+1))
mut "M4 the catch no longer closes the socket"              's/(settled\.set\(true\);)\s*try \{ s\.close\(\); \} catch \(Throwable ignore\) \{\}/$1/' || fails=$((fails+1))
fmut "F1 a bare new LocalSocket() in ProfileActivity"        ProfileActivity.java 's/(\npublic (?:final )?class ProfileActivity[^\n]*\{\n)/$1    static android.net.LocalSocket bareProbe = new LocalSocket();\n/' || fails=$((fails+1))
fmut "F2 a receiver watchdog that no longer sleeps its cap"  IdleLogoffReceiver.java 's/Thread\.sleep\(CONNECT_CAP_MS\)/Thread.sleep(1)/' || fails=$((fails+1))
fmut "F3 a receiver watchdog that no longer closes"          ReloginReceiver.java 's/(RELOGIN: daemon unresponsive, abandoning"\);\s*)try \{ s\.close\(\); \} catch \(Throwable ignore\) \{\}/$1/' || fails=$((fails+1))
fmut "F4 a receiver watchdog that is never started"          BackupNowReceiver.java 's/\n\s*watchdog\.start\(\);//' || fails=$((fails+1))
fmut "F5 a receiver watchdog that is never started"          IdleLogoffReceiver.java 's/\n\s*watchdog\.start\(\);//' || fails=$((fails+1))
fmut "F6 a receiver watchdog that is never started"          ReloginReceiver.java 's/\n\s*watchdog\.start\(\);//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
