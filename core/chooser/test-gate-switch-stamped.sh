#!/usr/bin/env bash
# test-gate-switch-stamped.sh [<ChooserActivity.java>] [--mutate] -- every gate-initiated ActivityManager
# .switchUser is stamped with markGateSwitch(), the user-switch watcher still excludes logins STRUCTURALLY,
# and ACTION_USER_SWITCHED is still registered at RUNTIME rather than in the manifest (NWP-20260922-06).
#
# WHY THIS IS COMMITTED. The watcher this pins tears a session DOWN. Its whole safety rests on being able to
# tell the gate's own switches from a hand-switch, and every way of getting that wrong fails in the same
# direction: it cold-locks a HEALTHY session. That is the "100% of logins, silently" failure this repo already
# refused DISALLOW_USER_SWITCH for (docs/fleet-lock-design.md:475, "a fleet-wide brick outright"), so the
# discrimination is pinned here rather than left to whoever adds the fifth switch site.
#
# WHAT IS PINNED, all in FUNCTIONAL form (never comment text):
#   * EVERY `.switchUser(` call in ChooserActivity is preceded, within two code lines, by `markGateSwitch()`.
#     A fifth switch site added without the stamp is invisible: it compiles, it switches, and the watcher then
#     reads it as a hand-switch and tears the session down. There is no log that would say so, because from
#     the watcher's side that IS the thing it exists to do.
#   * `handleUserSwitched` still early-returns when the switch was TO a non-zero user. This is what excludes a
#     normal login, and it excludes it STRUCTURALLY -- a login switches TO the session. The alternative the
#     gate already had (the `active && cur == 0` poll in onResume) cannot make that distinction, because the
#     daemon writes .roamsession BEFORE the login switch lands, which is exactly why that branch only logs.
#     "Improving" this to also handle switches between two secondary users would re-admit the login case.
#   * The watcher still checks the gate-teardown flags (signingOut / coldLockIn / loginInProgress) as well as
#     the timestamp. Belt and braces on purpose: the timestamp is a 20 s window, a reap is not.
#   * ACTION_USER_SWITCHED is registered via registerReceiver and does NOT appear in AndroidManifest.xml. The
#     NWP-20260825-19 rule: a manifest receiver gets no implicit broadcast on Android 8+ unless the action is
#     on the platform exemption list, which cost AppInstallReceiver four slices of never firing once. Moving
#     this to the manifest would be silent -- no build break, no log line, just a teardown that never runs.
#
# COMMENTS AND STRING LITERALS ARE STRIPPED before anything is matched. Without that, the `switchUser` named
# in this file's own explanatory comments would count as call sites (a false FAIL), and a `markGateSwitch()`
# written inside a comment or a log string would satisfy the stamp check (a false GREEN). Both shapes are
# probed under --mutate.
#
#   bash test-gate-switch-stamped.sh            # the invariants
#   bash test-gate-switch-stamped.sh --mutate   # ... plus mutations that must each CONVICT
#
# Pure text analysis -- no device, no build, no Java toolchain.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/src/com/nowhere/chooser/ChooserActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
MANIFEST="$(dirname "$0")/AndroidManifest.xml"

# --- strip comments + string/char literals, keeping line numbering intact -----------------------------------
# One pass, character by character, so a `//` inside a string and a quote inside a comment both behave.
strip_code() {
  awk '
    BEGIN { inblk = 0 }
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); d = substr(line, i, 2)
        if (inblk) { if (d == "*/") { inblk = 0; i += 2 } else { i++ }; continue }
        if (d == "//") { break }
        if (d == "/*") { inblk = 1; i += 2; continue }
        if (c == "\"" || c == "'"'"'") {
          q = c; i++
          while (i <= n) {
            e = substr(line, i, 1)
            if (e == "\\") { i += 2; continue }
            if (e == q) { i++; break }
            i++
          }
          out = out " STR "
          continue
        }
        out = out c; i++
      }
      print out
    }
  ' "$1"
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 tmp code n_sw n_ok
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }

  # The stripped source goes to a FILE, and every check greps that file. NOT `printf "$code" | grep -q`:
  # grep -q exits on its FIRST match, printf then dies of SIGPIPE, and under `set -o pipefail` the pipeline
  # reports failure -- so a pattern that IS present reads as absent. Measured while writing this: three
  # checks failed against correct source. Same family as every other trap here -- a negative result produced
  # by the harness rather than by the code under test.
  tmp=$(mktemp -d); code="$tmp/code.java"
  strip_code "$f" > "$code"

  # ---- 1. every switchUser call site is stamped ------------------------------------------------------------
  n_sw=$(grep -c '\.switchUser(' "$code")
  # A control on the scanner: if the strip or the pattern stops matching, every check below passes vacuously.
  if [ "$n_sw" -ge 4 ]; then ok "found $n_sw switchUser call site(s) in code"
  else no "found only $n_sw switchUser call sites -- the scanner no longer matches, so this suite proves nothing"; fi

  # For each call-site line, look back up to 2 non-blank code lines for the stamp.
  n_ok=$(awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] !~ /\.switchUser\(/) continue
        found = 0; back = 0
        for (j = i - 1; j >= 1 && back < 2; j--) {
          if (lines[j] ~ /^[ \t]*$/) continue
          back++
          if (lines[j] ~ /markGateSwitch\(\)/) { found = 1; break }
        }
        if (found) good++
      }
      print good + 0
    }' "$code")
  if [ "$n_ok" = "$n_sw" ]; then ok "all $n_sw switchUser site(s) stamped with markGateSwitch()"
  else no "only $n_ok of $n_sw switchUser site(s) stamped -- an unstamped switch reads as a hand-switch and tears down a healthy session"; fi

  # ---- 2. logins are excluded STRUCTURALLY ----------------------------------------------------------------
  if grep -q 'if (to != 0) return' "$code"; then
    ok "handleUserSwitched still early-returns on a switch TO a user (logins excluded structurally)"
  else
    no "the 'to != 0' early return is gone -- a login switches TO the session, so the watcher would now tear one down mid-login"
  fi

  # ---- 3. the gate-teardown guards are consulted INSIDE handleUserSwitched ---------------------------------
  # Scoped to the method body, NOT the file. A whole-file grep was the first cut and it was a FALSE GREEN:
  # both guards could be replaced with `if (false) {` and the suite still printed 6 ok / 0 failed, because the
  # flag NAMES still appear in their own declarations elsewhere in the class. A harness that cannot fail on
  # the one mutation it exists to catch is worse than no harness -- it is a green light.
  local body="$tmp/body.java"
  awk '/private static void handleUserSwitched/ { on = 1 } on { print } on && /^    }$/ { exit }' "$code" > "$body"
  if [ "$(grep -c . "$body")" -ge 10 ]; then ok "extracted handleUserSwitched ($(grep -c . "$body") lines)"
  else no "could not extract handleUserSwitched -- the method moved or was renamed, so every guard check below is vacuous"; fi

  local miss=""
  for guard in GATE_SWITCH_GRACE_MS signingOut coldLockIn loginInProgress sOwnerSession; do
    grep -q "$guard" "$body" || miss="$miss $guard"
  done
  if [ -z "$miss" ]; then ok "handleUserSwitched still consults the grace window AND all four gate flags"
  else no "not consulted inside handleUserSwitched:$miss -- the watcher can fire during the gate's own teardown"; fi

  # ---- 3c. coldLockIn is read through its SWITCH_COVER_MS window (NWP-20260923-03, G4) ----------------------
  # An idle cold lock can now be REVOKED while it queues for the worker slot, and a revoked lock leaves coldLockIn
  # set. Read unbounded, that stale flag vetoes a LATER legitimate hand-switch teardown and leaves the session
  # CE-unlocked. applySigningOutUi and onResume already bound it by SWITCH_COVER_MS; this was the only reader
  # that did not. Checked on the STRIPPED body, so the constant named in the explanatory comment cannot satisfy it.
  # ⚠ NAMES ARE NOT ENOUGH (second review): the declaration `boolean coldLockLive = coldLockIn && ...` satisfies a
  # name check on its own, so the guard below could revert to bare coldLockIn -- or drop the term entirely -- with
  # this suite still reporting 10 ok. Pin the CONDITION: the `if (signingOut` guard must use coldLockLive, and no
  # other line in the method may read coldLockIn (\b keeps coldLockInAt out of it).
  local guard_line bare_reads
  guard_line=$(grep -E '^[[:space:]]*if \(signingOut' "$body" | head -1 | sed 's/^[[:space:]]*//')
  bare_reads=$(grep -E '\bcoldLockIn\b' "$body" | grep -vc 'boolean coldLockLive = coldLockIn')
  if grep -q 'SWITCH_COVER_MS' "$body" && grep -q 'coldLockLive' <<<"$guard_line" && [ "$bare_reads" = 0 ]; then
    ok "handleUserSwitched vetoes on coldLockIn only through its SWITCH_COVER_MS window"
  else no "handleUserSwitched's teardown guard does not read coldLockIn through its window (guard: '$guard_line', bare reads: $bare_reads) -- a revoked lock's stale flag vetoes a later hand-switch teardown"; fi

  # ---- 3b. the teardown goes through the DAEMON, not straight to phase 2b ----------------------------------
  # doColdLock is only the device-owner half. Calling it directly skips stopMediad (so mediad's open fds pin
  # the FBE key past the stop -- this slice's OWN bug), the .coldlock marker (so the 12h hard-wipe is armed
  # but declines), and the .roamsession removal (so STATUS stays ACTIVE forever). It also means the uid has to
  # be guessed, and firstSecondaryUid returns the LOWEST secondary user, which a blind-login orphan can make
  # the wrong one. The first cut did exactly this; an adversarial pass caught it before the PR.
  # The VERB is a string literal, and strip_code replaces every literal with " STR " -- so this one check has
  # to read the RAW source, not the stripped copy. (Caught by the suite failing on correct code, which is the
  # direction a harness should fail in.) The doColdLock check below stays on the stripped body, where a
  # mention in a comment must NOT count.
  local raw="$tmp/raw.java"
  awk '/private static void handleUserSwitched/ { on = 1 } on { print } on && /^    }$/ { exit }' "$f" > "$raw"
  if grep -q 'pollDaemon("COLD-LOCK' "$raw"; then
    ok "the teardown is handed to the daemon (COLD-LOCK), so the proven path runs"
  else
    no "handleUserSwitched no longer sends COLD-LOCK -- a direct doColdLock is only phase 2b and leaves the FBE key pinned, the hard-wipe inert and .roamsession behind"
  fi
  if grep -qE 'doColdLock\(|firstSecondaryUid\(' "$body"; then
    no "handleUserSwitched calls doColdLock/firstSecondaryUid directly -- that is the half-teardown this slice was corrected for"
  else
    ok "handleUserSwitched does not call doColdLock or firstSecondaryUid itself"
  fi

  # ---- 4. runtime registration, NOT the manifest -----------------------------------------------------------
  if grep -q 'ACTION_USER_SWITCHED' "$code"; then
    ok "ACTION_USER_SWITCHED is referenced in code (runtime registration)"
  else
    no "ACTION_USER_SWITCHED is not referenced in code -- the watcher cannot be registered at runtime"
  fi
  if [ -f "$MANIFEST" ]; then
    if grep -q 'USER_SWITCHED' "$MANIFEST"; then
      no "ACTION_USER_SWITCHED appears in AndroidManifest.xml -- a manifest receiver gets no implicit broadcast on Android 8+ (NWP-20260825-19) and would silently never fire"
    else
      ok "ACTION_USER_SWITCHED is absent from the manifest (runtime-only, per NWP-20260825-19)"
    fi
  fi

  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  rm -rf "$tmp"
  [ "$x" -eq 0 ]
}

echo "gate-switch stamping: $SUT"
suite "$SUT" || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT):"
  mtmp=$(mktemp -d)
  mutate() {  # <label> <sed program> [expect]
    local label="$1" prog="$2" expect="${3:-convict}" mf="$mtmp/M.java"
    sed -E "$prog" "$SUT" > "$mf"
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-56s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    if suite "$mf" quiet >/dev/null 2>&1; then
      if [ "$expect" = survive ]; then printf '  ok    %-56s survived (as required)\n' "$label"
      else printf '  XX    %-56s SURVIVED\n' "$label"; MFAIL=1; fi
    else
      if [ "$expect" = survive ]; then printf '  XX    %-56s CONVICTED (should have survived)\n' "$label"; MFAIL=1
      else printf '  ok    %-56s convicted\n' "$label"; fi
    fi
  }
  # The actual regression this exists to catch: a switch site loses its stamp.
  mutate 'a switchUser site loses markGateSwitch()' 's@^( *)markGateSwitch\(\); // NWP-20260922-06.*$@\1// removed@'
  # The two guards that stop this firing on a HEALTHY path. Both of these SURVIVED the first cut of this
  # suite -- a whole-file grep saw the flag names in their declarations and reported green -- which is why
  # check 3 is now scoped to the extracted method body.
  mutate 'the 20s gate-switch grace window is neutered' 's@if \(since < GATE_SWITCH_GRACE_MS\) \{@if (false) {@'
  mutate 'the gate-teardown flag test is neutered'      's@if \(signingOut \|\| coldLockLive \|\| loginInProgress \|\| sOwnerSession\) \{@if (false) {@'
  # G4 (NWP-20260923-03): the window is dropped, so coldLockIn is read unbounded again. Anchored to the
  # coldLockLive line: the window's second line is byte-identical at applySigningOutUi, so an unanchored
  # substitution would mutate BOTH sites and prove less.
  mutate 'coldLockIn read UNBOUNDED again (G4 window removed)' '/boolean coldLockLive = coldLockIn/{n;s@.*@                    ;@}'
  # The two shapes the second review showed this suite could not see: the guard itself reverts to the bare
  # flag, or loses the cold-lock term altogether, while the coldLockLive declaration stays behind.
  mutate 'the guard reads bare coldLockIn again'           's@if \(signingOut \|\| coldLockLive \|\|@if (signingOut || coldLockIn ||@'
  mutate 'the cold-lock term is dropped from the guard'    's@if \(signingOut \|\| coldLockLive \|\| @if (signingOut || @'
  # The P0 an adversarial pass caught before the PR: tearing down with phase 2b alone.
  mutate 'teardown reverts to a direct doColdLock'      's@String reply = pollDaemon\("COLD-LOCK.*$@doColdLock(app, 1);@'
  # The structural login exclusion is removed.
  mutate 'the "to != 0" login exclusion is removed'  's@if \(to != 0\) return;@if (to < 0) return;@'
  # A stamp that exists only inside a COMMENT must NOT satisfy the check (the false-green shape).
  mutate 'the stamp is demoted to a comment'         's@^( *)markGateSwitch\(\);@\1// markGateSwitch();@'
  # ...and the mirror image: a `switchUser` mentioned only in a COMMENT must not be counted as a call site,
  # so adding one must leave the suite GREEN. This is the false-FAIL shape.
  mutate 'a switchUser named in a new comment (must SURVIVE)' 's@^(public class ChooserActivity.*)$@// a comment mentioning am.switchUser( here must not count\n\1@' survive
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
