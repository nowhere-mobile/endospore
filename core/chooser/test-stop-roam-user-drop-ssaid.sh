#!/usr/bin/env bash
# test-stop-roam-user-drop-ssaid.sh -- ChooserActivity.stopRoamUser sends DROP-SSAID once removeUser has returned
# (NWP-20261115-14).
#
# Backlog row: "A sign-in that does not land can leave passphrase-verifier material in `users/<uid>`; the reap does
# not run on `stopRoamUser`". Decision: docs/product-decisions.md, 2026-10-24 (dn-1023 #4): the narrow op runs
# "once `removeUser` has returned". NWP-20261115-01's daemon arm (core/agent/drop_ssaid.go) is the receiver; this
# suite pins the chooser's send.
#
# Comment-stripped source checks on core/chooser/src/com/nowhere/chooser, the stopRoamUser body taken from its exact
# signature line to its closing brace:
#   s1  the body holds exactly one dpm.removeUser(admin, android.os.UserHandle.of(uid)) and exactly one
#       "DROP-SSAID\n" + uid + "\n", the removeUser first
#   s2  the send is inside a new Thread( started in a finally, after a uid >= 10 guard
#   s3  the roundTrip bound is 30000
#   s4  exactly four stopRoamUser(uid) call sites remain in ChooserActivity.java (the fourth is NWP-20261117-12's
#       ERR-NOTMPFS roam-in branch)
#   s5  no other file under the source dir sends DROP-SSAID
#
# --mutate: runs the plain checks, then each mutant on a copy of the source dir; every mutant must be CONVICTED.
#   C1 the send moved above removeUser   C2 the thread removed (sent inline)   C3 the send dropped
#   C4 the verb misspelt (DROP-SSID)     C5 the uid guard removed              C6 one caller's call removed
#   C7 the bound set to 0
#
# Usage: test-stop-roam-user-drop-ssaid.sh [--mutate] [<chooser src dir>]
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/src/com/nowhere/chooser"
MUTATE=0
for a in "$@"; do
  case $a in
    --mutate) MUTATE=1 ;;
    *) SRC=$a ;;
  esac
done

command -v perl >/dev/null 2>&1 || { echo "FAIL: no perl: the comment-stripped source checks cannot run" >&2; exit 1; }
[ -f "$SRC/ChooserActivity.java" ] || { echo "FAIL: no ChooserActivity.java under $SRC" >&2; exit 1; }

# strip_comments <file> -> the Java source on stdout with // and /* */ comments removed (string and char literals kept).
# Same expression as core/vendor-common/bin/test-rekey-battery-java.sh.
strip_comments() {
  perl -0pe 's{("(?:\\.|[^"\\\n])*"|\x27(?:\\.|[^\x27\\\n])*\x27)|//[^\n]*|/\*.*?\*/}{defined $1 ? $1 : " "}gse' "$1"
}

# first_line <text> <fixed string> -> the 1-based number of the first line holding the string, or 0.
first_line() {
  local hit
  hit=$(printf '%s\n' "$1" | grep -n -F -m1 -- "$2")
  [ -n "$hit" ] && echo "${hit%%:*}" || echo 0
}

# count_lines <text> <fixed string> -> how many lines hold the string.
count_lines() {
  local n
  n=$(printf '%s\n' "$1" | grep -c -F -- "$2")
  echo "${n:-0}"
}

REMOVE='dpm.removeUser(admin, android.os.UserHandle.of(uid))'
SEND='"DROP-SSAID\n" + uid + "\n"'
BOUNDED='DaemonSocket.roundTrip("DROP-SSAID\n" + uid + "\n", 30000)'

# check <src dir> [quiet] -> 0 when every check holds, 1 otherwise.
check() {
  local src=$1 quiet=${2:-} code body bad=0 nr ns nf ng nt nst calls f other files
  say() { [ -n "$quiet" ] || echo "$@"; }
  code=$(strip_comments "$src/ChooserActivity.java") || { say "FAIL  could not strip $src/ChooserActivity.java"; return 1; }
  body=$(printf '%s\n' "$code" | awk '/^    private void stopRoamUser\(int uid\) \{$/ { on = 1 } on { print } on && /^    }$/ { exit }')
  if [ -z "$body" ]; then say "FAIL  stopRoamUser(int uid) not found"; return 1; fi

  # s1
  nr=$(first_line "$body" "$REMOVE")
  ns=$(first_line "$body" "$SEND")
  if [ "$(count_lines "$body" "$REMOVE")" -eq 1 ] && [ "$(count_lines "$body" "$SEND")" -eq 1 ] \
     && [ "$nr" -gt 0 ] && [ "$ns" -gt "$nr" ]; then
    say "PASS  s1 one removeUser, then one DROP-SSAID send"
  else
    say "FAIL  s1 stopRoamUser must hold one removeUser, then one DROP-SSAID send (removeUser line $nr, send line $ns)"
    bad=1
  fi

  # s2
  nf=$(first_line "$body" "} finally {")
  ng=$(first_line "$body" "if (uid >= 10) {")
  nt=$(first_line "$body" "new Thread(() -> {")
  nst=$(first_line "$body" '}, "nowhere-drop-ssaid").start();')
  if [ "$(count_lines "$body" "new Thread(")" -eq 1 ] && [ "$nr" -gt 0 ] && [ "$nf" -gt "$nr" ] && [ "$ng" -gt "$nf" ] \
     && [ "$nt" -gt "$ng" ] && [ "$ns" -gt "$nt" ] && [ "$nst" -gt "$ns" ]; then
    say "PASS  s2 the send is on a named thread started in a finally, after a uid >= 10 guard"
  else
    say "FAIL  s2 the send must be inside new Thread(...).start() in a finally, after if (uid >= 10)" \
        "(finally $nf, guard $ng, thread $nt, send $ns, start $nst)"
    bad=1
  fi

  # s3
  if [ "$(count_lines "$body" "$BOUNDED")" -eq 1 ]; then
    say "PASS  s3 the roundTrip bound is 30000 ms"
  else
    say "FAIL  s3 the send must be DaemonSocket.roundTrip(<DROP-SSAID>, 30000)"
    bad=1
  fi

  # s4
  calls=$(count_lines "$code" "stopRoamUser(uid);")
  if [ "$calls" -eq 4 ]; then
    say "PASS  s4 four stopRoamUser(uid) call sites"
  else
    say "FAIL  s4 expected four stopRoamUser(uid) call sites, found $calls"
    bad=1
  fi

  # s5
  other=""
  files=$(find "$src" -name '*.java' ! -path "$src/ChooserActivity.java" | sort)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(count_lines "$(strip_comments "$f")" "DROP-SSAID")" -gt 0 ]; then
      other="$other ${f#"$src"/}"
    fi
  done <<<"$files"
  if [ -z "$other" ]; then
    say "PASS  s5 no other chooser source sends DROP-SSAID"
  else
    say "FAIL  s5 another chooser source sends DROP-SSAID:$other"
    bad=1
  fi

  return "$bad"
}

# mutant <label> <perl expr> -> 0 when the mutant applied and check convicted it, 1 otherwise.
mutant() {
  local label=$1 expr=$2 d
  d=$(mktemp -d -p "$W") || return 1
  cp -r "$SRC/." "$d/"
  perl -0pi -e "$expr" "$d/ChooserActivity.java"
  if cmp -s "$SRC/ChooserActivity.java" "$d/ChooserActivity.java"; then
    echo "ERROR     $label -- did not apply"
    rm -rf "$d"
    return 1
  fi
  if check "$d" quiet; then
    echo "SURVIVED  $label"
    rm -rf "$d"
    return 1
  fi
  echo "CONVICTED $label"
  rm -rf "$d"
  return 0
}

if ! check "$SRC"; then
  echo "test-stop-roam-user-drop-ssaid: FAIL"
  exit 1
fi
if [ "$MUTATE" -eq 0 ]; then
  echo "test-stop-roam-user-drop-ssaid: PASS"
  exit 0
fi

failed=0
SENDLINE='( *String reply = DaemonSocket\.roundTrip\("DROP-SSAID\\n" \+ uid \+ "\\n", 30000\);\n)'
mutant "C1 the send moved above removeUser" \
  's{(\n *dpm\.removeUser\(admin, android\.os\.UserHandle\.of\(uid\)\);\n)(.*?)'"$SENDLINE"'}{\n            String reply = DaemonSocket.roundTrip("DROP-SSAID\\n" + uid + "\\n", 30000);$1$2}s' || failed=1
mutant "C2 the thread removed (sent inline)" \
  's{new Thread\(\(\) -> \{}{\{}; s{\}, "nowhere-drop-ssaid"\)\.start\(\);}{\}}' || failed=1
mutant "C3 the send dropped" \
  's{'"$SENDLINE"'( *android\.util\.Log\.i\("NowhereChooser", "drop-ssaid user [^\n]*\n)}{}' || failed=1
mutant "C4 the verb misspelt (DROP-SSID)" \
  's{"DROP-SSAID\\n" \+ uid}{"DROP-SSID\\n" + uid}' || failed=1
mutant "C5 the uid guard removed" \
  's{if \(uid >= 10\) \{}{\{}' || failed=1
mutant "C6 one caller's stopRoamUser call removed" \
  's{(if \(reply\.startsWith\("NEEDKEY"\)\) \{.*?)\n *if \(uid >= 0\) stopRoamUser\(uid\);}{$1}s' || failed=1
mutant "C7 the bound set to 0" \
  's{(roundTrip\("DROP-SSAID\\n" \+ uid \+ "\\n", )30000\)}{${1}0)}' || failed=1

if [ "$failed" -ne 0 ]; then
  echo "test-stop-roam-user-drop-ssaid --mutate: FAIL"
  exit 1
fi
echo "test-stop-roam-user-drop-ssaid --mutate: PASS (C1-C7 convicted)"
