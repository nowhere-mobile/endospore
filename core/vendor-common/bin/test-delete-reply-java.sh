#!/usr/bin/env bash
# test-delete-reply-java.sh [--mutate] -- the Delete screen's reply-to-copy decision, run under javac
# (NWP-20261014-30, #140).
#
# WHY THIS IS COMMITTED. #140 exists because every delete failure once rendered as a credential accusation. The rule --
# only NOTFOUND blames the passphrase; every failure says "nothing was deleted" except the no-answer one -- lives in
# deleteFailCopy / deleteSucceeded in ProfileActivity.java, which nothing else executes off a device.
# core/chooser/tests/delete-reply/run.sh lifts them into a plain class and runs DeleteReplyCases against it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS (see test-end-unsaved-java.sh).
#
#   bash test-delete-reply-java.sh            # the cases
#   bash test-delete-reply-java.sh --mutate   # ... plus broken copies of the helpers that must each FAIL the cases
set -uo pipefail
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W"

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
RUN="$root/core/chooser/tests/delete-reply/run.sh"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 1
fi
export JAVAC JAVA
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 1; }
[ -f "$SRC" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC or $RUN" >&2; exit 1; }

# suite <ProfileActivity.java> -> 0 pass, 1 a case or the listener pin failed, 2 a helper did not extract, 3 the lifted
# class did not compile. Only 1 may convict a mutant.
suite() {
  local f="$1"
  # PIN: the listener renders through the helpers, not a second inline copy of the rule.
  grep -qF 'StatusLine.error(msg, deleteFailCopy(r));' "$f" && grep -qF 'if (deleteSucceeded(r)) {' "$f" || {
    echo "  PIN   the delete listener no longer calls deleteFailCopy / deleteSucceeded" >&2; return 1; }
  # NWP-20261028-03 PINS, read as data: the no-network check precedes the send and its branch returns with the
  # ERR-STORE copy; the reads fail open; the any-network read skips a VPN.
  perl -0ne 'exit(/del\.setOnClickListener\(v -> \{.*?if \(deleteSkipsStore\(net\[0\], net\[1\]\)\) \{\s*msg\.setTextColor\(MUTED\);\s*StatusLine\.error\(msg, deleteFailCopy\("ERR-STORE"\)\);\s*return;\s*\}.*?sendDaemon\("DELETE\\n"/s ? 0 : 1)' "$f" || {
    echo "  PIN   the Delete listener must check deleteSkipsStore, show the ERR-STORE copy and return BEFORE sendDaemon(DELETE)" >&2; return 1; }
  perl -0ne 'exit(/private boolean\[\] hasAnyNetwork\(\).*?if \(cm == null\) return new boolean\[\] \{true, true\};.*?catch \(Throwable t\) \{\s*return new boolean\[\] \{true, true\};/s ? 0 : 1)' "$f" || {
    echo "  PIN   hasAnyNetwork must fail open (a network) on a null manager and on a throw" >&2; return 1; }
  perl -0ne 'exit(/private boolean\[\] hasAnyNetwork\(\).*?NET_CAPABILITY_INTERNET\)\s*&& !nc\.hasTransport\(android\.net\.NetworkCapabilities\.TRANSPORT_VPN\)/s ? 0 : 1)' "$f" || {
    echo "  PIN   hasAnyNetwork must skip TRANSPORT_VPN networks" >&2; return 1; }
  bash "$RUN" "$f"
}

echo "== $SRC"
suite "$SRC" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d m rc; d=$(mktemp -d -p "$W") || return 1; m="$d/ProfileActivity.java"
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
mut "M1 ERR-STORE renders the NOTFOUND copy"      's/(r\.startsWith\("ERR-STORE"\)\) \{\n\s*return )"[^"]*"/$1"that passphrase doesn\x27t match this profile — nothing was deleted."/' || fails=$((fails+1))
mut "M2 the no-answer arm is dropped"             's/\} else if \(r\.isEmpty\(\)\) \{/} else if (false) {/' || fails=$((fails+1))
mut "M3 the generic copy drops its nothing-deleted line" 's/couldn\x27t delete — nothing was deleted\. Try again\./couldn\x27t delete. Try again./' || fails=$((fails+1))
mut "E1 the any-network arm is dropped"           's/return !activeNetwork && !anyInternetNetwork;/return !activeNetwork;/' || fails=$((fails+1))
mut "E2 the skip decision is inverted"            's/return !activeNetwork && !anyInternetNetwork;/return !(!activeNetwork && !anyInternetNetwork);/' || fails=$((fails+1))
mut "E3 the check runs after the send"            's/(\n[ ]*)(final boolean\[\] net = hasAnyNetwork\(\);\s*if \(deleteSkipsStore\(net\[0\], net\[1\]\)\) \{.*?return;\s*\})/$1/s; s/(String r = sendDaemon\("DELETE\\n"[^\n]*\n)/$1final boolean[] net = hasAnyNetwork(); if (deleteSkipsStore(net[0], net[1])) { return; }\n/' || fails=$((fails+1))
mut "E4 the reads fail closed"                    's/(catch \(Throwable t\) \{\s*return new boolean\[\] )\{true, true\}(;\s*\}\s*\}\s*\n\s*\/\*\*\s*\n\s*\* DIA-20260812-08)/$1\{false, false\}$2/' || fails=$((fails+1))
mut "E5 the skip branch shows the no-answer copy" 's/(deleteSkipsStore\(net\[0\], net\[1\]\)\) \{\s*msg\.setTextColor\(MUTED\);\s*StatusLine\.error\(msg, deleteFailCopy\()"ERR-STORE"/$1""/' || fails=$((fails+1))
mut "E6 the TRANSPORT_VPN exclusion is removed"   's/\n\s*&& !nc\.hasTransport\(android\.net\.NetworkCapabilities\.TRANSPORT_VPN\)//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
