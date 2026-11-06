#!/usr/bin/env bash
# test-end-unsaved-java.sh [--mutate] -- the chooser's sign-out-refusal decisions and copy, run under javac
# (NWP-20261010-10).
#
# WHY THIS IS COMMITTED. Which exit a failed sign-out offers ("End session without saving", "Restart without saving",
# or none), what its confirmation says is discarded and kept, and the advice for each refusal class all live in
# private static helpers in ProfileActivity.java. Nothing else executes them off a device, and a wrong one either
# hides the user's only exit or offers a control that destroys data. core/chooser/tests/end-unsaved/run.sh lifts the
# helpers into a plain class and runs EndUnsavedCases against it.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. A suite that quietly passes because its tool is missing reads
# exactly like one that ran (the missing-gofmt rc-127 false green, nowhere-phone/worklog.md). javac comes from PATH,
# else from the build host's JDK below; the CI runner is the build VM, which has it. The version is printed first so
# the log proves which compiler ran.
#
#   bash test-end-unsaved-java.sh            # the cases
#   bash test-end-unsaved-java.sh --mutate   # ... plus broken copies of the helpers that must each FAIL the cases
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
# One temp root (NWP-20261113-18): every mutant dir, and run.sh's own, is made inside it and goes with it on exit.
W=$(mktemp -d) || exit 1
export TMPDIR="$W"
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser/ProfileActivity.java"
GATE="$root/core/chooser/src/com/nowhere/chooser/ChooserActivity.java" # NWP-20261013-20: the gate's lost-credit notice
RUN="$root/core/chooser/tests/end-unsaved/run.sh"
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
[ -f "$SRC" ] && [ -f "$GATE" ] && [ -f "$RUN" ] || { echo "FAIL: missing $SRC, $GATE or $RUN" >&2; exit 1; }

# suite <ProfileActivity.java> <ChooserActivity.java> -> 0 pass, 1 a case failed (behaviour) or the source pin failed (a textual check, not
# behaviour: it is how M8 convicts), 2 a helper did not extract, 3 the lifted class did not compile. Only 1 may convict
# a mutant; 2 and 3 prove nothing about the logic.
suite() {
  local f="$1" g="$2"
  # PIN: the restart confirmation asks the dialog's own helper, never a second copy of its threshold (round 5).
  grep -qF 'if (!"RESTART".equals(failedDialogExit("MEDIA", fresh))) {' "$f" || {
    echo "  PIN   confirmRestartUnsaved no longer shares failedDialogExit's decision" >&2; return 1; }
  # PIN (NWP-20261017-16): the logoff loop hands sealStatus()'s reason to the dialog helper, so the lifted cases
  # cover a path that is actually wired (the loop itself is not liftable).
  grep -qF 'failReason = sealStatusReason;' "$f" && grep -qF 'logoffFailMessage(failWhy, refusal, failReason, this::fmtWhen)' "$f" || {
    echo "  PIN   doLogoff no longer passes the gateway's reason to logoffFailMessage" >&2; return 1; }
  # PIN (NWP-20261013-20): every gate appearance asks for the notice, and it is cleared from the OK button -- after the
  # user has seen it -- never at the fetch.
  grep -qF 'refreshCreditLostNotice(); // NWP-20261013-20' "$g" || {
    echo "  PIN   the gate's onResume no longer asks for the lost-credit notice" >&2; return 1; }
  grep -qF '.setPositiveButton("OK", (d, w) -> new Thread(() -> {' "$g" && grep -qF 'try { sendDaemon(creditLostClearCommand(stamp)); }' "$g" || {
    echo "  PIN   the lost-credit notice is no longer cleared from its OK button" >&2; return 1; }
  [ "$(grep -cF 'creditLostClearCommand(stamp)' "$g")" = 1 ] || {
    echo "  PIN   the lost-credit notice is cleared from more than one place" >&2; return 1; }
  # PINS (NWP-20261101-08, Q070): the wiring the lifted helpers cannot cover. Captured into variables, never
  # `cmd | grep -q` under pipefail.
  local src; src=$(cat "$f")
  case "$src" in *'|| failWhy.isEmpty() ? logoffRefusal() : null;'*) ;; *)
    echo "  PIN   the generic failure is not asked for the refusal (failWhy.isEmpty())" >&2; return 1 ;; esac
  local lockarm; lockarm=$(grep -cF 'b.setPositiveButton("Lock", (d, w) -> doColdLock());' "$f")
  [ "$lockarm" = 1 ] || { echo "  PIN   the LOCK arms no longer call doColdLock()" >&2; return 1; }
  case "$src" in *'pushStuckCount(fresh) < 2'*) ;; *)
    echo "  PIN   confirmEndUnsaved does not admit a second unreachable-store sign-out" >&2; return 1 ;; esac
  # PIN (NWP-20261111-07, Q016): the KEY-END handler sends ADOPT-FIDO2 -- never ENROLL-FIDO2 -- as the first line of
  # its own thread, read past the daemon's 90 s deadline. The literal goes through ENVIRON: awk -v would turn \n into a
  # newline.
  local adoptsend
  adoptsend=$(PIN_ADOPT='final String r = DaemonSocket.roundTrip("ADOPT-FIDO2\n", 100000);' \
    awk 'index($0, ENVIRON["PIN_ADOPT"]) && prev ~ /new Thread\(\(\) -> \{[ \t]*$/ { n++ } { prev = $0 } END { print n + 0 }' "$f")
  [ "$adoptsend" = 1 ] || { echo "  PIN   the KEY-END handler no longer sends ADOPT-FIDO2 on a background thread" >&2; return 1; }
  # PINS (NWP-20261113-11, row "Your data's save copy says the wrong thing in four cases", case 2): Your data's refused
  # sentence comes from lastSaveHeldText on SEAL-DELTA's scopes, the old sentence only as its fallback; Back up now's
  # DONE PARTIAL arm asks lastSaveHeldText, and says "Your data areas are saved." only when no blocking scope was refused.
  case "$src" in *'String held = lastSaveHeldText(verdict, o.optString("scopes", ""), this::fmtWhen);'*) ;; *)
    echo "  PIN   Your data's refused sentence does not come from lastSaveHeldText(SEAL-DELTA scopes)" >&2; return 1 ;; esac
  case "$src" in *'d.append(held != null ? held + " "'*'"changed while the save was running. This usually clears on its own. ");'*) ;; *)
    echo "  PIN   Your data's old refused sentence is not the fallback of lastSaveHeldText" >&2; return 1 ;; esac
  local backup; backup=$(perl -0ne 'print $1 if /(private void doBackup\(\) \{.*?\n    \}\n)/s' "$f")
  case "$backup" in *'lastSaveHeldText("refused",'*) ;; *)
    echo "  PIN   Back up now does not ask lastSaveHeldText for a refused data scope" >&2; return 1 ;; esac
  case "$backup" in *'if (eq > 0 && blockingScope(p.substring(0, eq).trim())'*) ;; *)
    echo "  PIN   Back up now does not test the parts for a refused blocking scope" >&2; return 1 ;; esac
  case "$backup" in *'+ (fDataRefused ? (fHeld != null ? ". " + fHeld : ".") : ". Your data areas are saved."));'*) ;; *)
    echo "  PIN   Back up now's DONE PARTIAL arm says \"Your data areas are saved.\" when a data scope was refused" >&2; return 1 ;; esac
  local areas; areas=$(grep -cF 'Your data areas are saved.' "$f")
  [ "$areas" = 1 ] || { echo "  PIN   \"Your data areas are saved.\" is said in $areas places, not one" >&2; return 1; }
  bash "$RUN" "$f" "$g"
}

echo "== $SRC + $GATE"
suite "$SRC" "$GATE" || { echo "FAILED"; exit 1; }
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- by behaviour: a mutant that does not extract or compile proves nothing)"
mut() { # mut <label> <perl-expr>
  local d m rc; d=$(mktemp -d -p "$W"); m="$d/ProfileActivity.java"
  if ! perl -0pe "$2" "$SRC" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$SRC" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$m" "$GATE" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 the restart offered after ONE failed sweep"  's/mediaStuckCount\(reply\) >= 2\) return "RESTART";/mediaStuckCount(reply) >= 1) return "RESTART";/' || fails=$((fails+1))
mut "M2 a FAILED MEDIA sign-out loses the END offer"  's/return \("REFUSED"\.equals\(why\) \|\| "MEDIA"\.equals\(why\)\) && refusalFinal\(refusal\);/return "REFUSED".equals(why) \&\& refusalFinal(refusal);/' || fails=$((fails+1))
mut "M3 the restart hides the lost texts and calls"  's/"[^"]*Texts and calls this phone is still holding for delivery", "the phone restarts"/"", "the phone restarts"/' || fails=$((fails+1))
mut "M4 \"deleted\" said on a guard token alone"       's/s = deleted \? "This profile was deleted/s = true ? "This profile was deleted/' || fails=$((fails+1))
mut "M5 the blind dialog hides a FINAL shrink"       's/guardFinal\(s\[2\]\) && !"blind"\.equals\(s\[2\]\)\) \{/guardFinal(s[2]) \&\& false) {/' || fails=$((fails+1))
mut "M6 the FINAL copy promises certainty again"     's/signing out again will most likely fail the same way/signing out again won\x27t change that/' || fails=$((fails+1))
# \x5c is a backslash: a doubled backslash in a mutation is mangled by Git Bash's argument conversion, so none is used.
mut "M7 the MEDIA line split on single spaces"       's/(int mediaStuckCount\(String reply\) \{\n(?:[^\n]*\n){2}[^\n]*)\x5c\x5cs\+/$1 /' || fails=$((fails+1))
mut "M8 the restart confirmation keeps its own threshold" 's/if \(!"RESTART"\.equals\(failedDialogExit\("MEDIA", fresh\)\)\) \{/if (mediaStuckCount(fresh) < 3) {/' || fails=$((fails+1))
mut "M9 the chooser never asks PowerManager itself"  's/if \(!selfTried && waitedMs >= 15000\) return "REBOOT";/if (false) return "REBOOT";/' || fails=$((fails+1))
mut "M10 the Restarting screen waits forever"        's/if \(waitedMs >= 90000\) return "UNKNOWN";/if (false) return "UNKNOWN";/' || fails=$((fails+1))
mut "M11 our own timeout claims the daemon's FAILED"  's/if \(waitedMs >= 90000\) return "UNKNOWN";/if (waitedMs >= 90000) return "FAILED";/' || fails=$((fails+1))
mut "M12 the unknown copy claims the session is saved" 's/Restarting the phone yourself "/You\x27re still signed in and this session is being saved. Restarting the phone yourself "/' || fails=$((fails+1))
mut "M13 ERR-RESTARTING falls through to the generic failure" 's/if \(r\.startsWith\("ERR-RESTARTING"\)\) \{/if (r.startsWith("ERR-RESTARTING-NEVER")) {/' || fails=$((fails+1))
mut "M14 the restarting copy says try again in a minute"  's/redeem it after the phone restarts and you sign in\./try again in a minute./' || fails=$((fails+1))
# javac rejects any statement after an unconditional return as unreachable, so a mutant that short-circuits a method
# returns under "if (true)" (M15, M17); and a quote inside a Java string literal is \x5c\x22, never a bare \x22 (M16).
mut "M15 the NOCREDIT dialog ignores the gateway's reason" 's/if \(reason == null \|\| reason\.trim\(\)\.isEmpty\(\)\) return base;/if (true) return base;/' || fails=$((fails+1))
mut "M16 a reason is quoted on a REFUSED dialog" 's/(if \("REFUSED"\.equals\(why\)\) \{)/$1 if (reason != null) return "The storage service said: \x5c\x22" + reason + "\x5c\x22.";/' || fails=$((fails+1))
mut "M18 the logoff loop drops the reason before the dialog" 's/failReason = sealStatusReason;/failReason = null;/' || fails=$((fails+1))
mut "M17 the REASON line is never parsed" 's/if \(line == null \|\| !line\.startsWith\("REASON "\)\) return null;/if (true) return null;/' || fails=$((fails+1))
mut "M19 OK-CREDIT-LOST read as a failed end"           's/if \("OK"\.equals\(r\) \|\| "OK-CREDIT-LOST"\.equals\(r\)\) return null;(\n\s*if \("BUSY")/if ("OK".equals(r)) return null;$1/' || fails=$((fails+1))
mut "M20 the credit-lost end shows no warning"            's/if \(!"OK-CREDIT-LOST"\.equals\(r\)\) return null;/if (true) return null;/' || fails=$((fails+1))
mut "M21 the warning says the earlier credit is lost too"  's/Credit you had before this session is safe\./All your storage credit is lost./' || fails=$((fails+1))
# NWP-20261117-32: a BUSY that is not a seal never reads as one, and every BUSY offers the control again. M24 is
# anchored on endUnsavedMayRetry's own line: the two message helpers test the same prefix with `if (`.
mut "M22 teardown mapped to the save text"              's/"This session is already being signed out or locked, so it wasn\x27t ended\./"A save is running right now, so the session wasn\x27t ended./' || fails=$((fails+1))
mut "M23 bare BUSY mapped to the save text"             's/"The phone is busy, so the session wasn\x27t ended\./"A save is running right now, so the session wasn\x27t ended./' || fails=$((fails+1))
mut "M24 a BUSY token not retried"                      's/(return "BUSY"\.equals\(r\)) \|\| r\.startsWith\("BUSY "\)/$1/' || fails=$((fails+1))
mut "N1 LOCK-END at PUSH 1"                              's/return pushStuckCount\(reply\) >= 2 \? "LOCK-END" : "LOCK";/return pushStuckCount(reply) >= 1 ? "LOCK-END" : "LOCK";/' || fails=$((fails+1))
mut "N2 the generic failure no longer names Lock"        's/Tap Lock to keep this session safe: it locks/It is kept: it locks/' || fails=$((fails+1))
mut "N3 the offline confirmation drops the credit sentence" 's/"\. Storage credit added in this session that wasn.t saved to your store is lost\."/"."/' || fails=$((fails+1))
mut "N4 pushStuckCount reads the MEDIA line"             's/"PUSH"\.equals\(f\[0\]\)/"MEDIA".equals(f[0])/' || fails=$((fails+1))
mut "N5 the generic failure is not asked for the refusal" 's/ \|\| failWhy\.isEmpty\(\) \? logoffRefusal\(\)/ ? logoffRefusal()/' || fails=$((fails+1))
mut "N6 confirmEndUnsaved admits only refusalFinal"      's/offline \&\& pushStuckCount\(fresh\) < 2/offline/' || fails=$((fails+1))
mut "N7 refusalCause drops the locks-changed case"       's/case "locks-changed":\n\s*case "locks-changed-key":/case "x-locks-changed":/' || fails=$((fails+1))
mut "N8 the unlock-lost case uses the changed sentence"  's/"This phone can no longer unlock this profile to save it: /"This profile\x27s sign-in was changed after this phone signed in, so this phone can\x27t save to it. /' || fails=$((fails+1))
mut "N9 guardFinal omits unlock-lost-key"                's/ \|\| "unlock-lost-key"\.equals\(g\)//' || fails=$((fails+1))
mut "N10 the time is the SAVED line, not the vault SCOPE line" 's/vaultSaved = parseUnix\(s\[3\]\);/vaultSaved = refusalRestSaved(refusal);/' || fails=$((fails+1))
mut "N11 KEY-END for a guard without -key"             's/"locks-changed-key"\.equals\(s\[2\]\) \|\| "unlock-lost-key"\.equals\(s\[2\]\)/s[2].startsWith("locks-changed") || s[2].startsWith("unlock-lost")/' || fails=$((fails+1))
mut "N12 KEY-END from a non-blocking scope"            's/if \(blockingScope\(s\[0\]\) && ("refused"\.equals\(s\[1\]\)\n\s*&& \("locks-changed-key")/if (true \&\& $1/' || fails=$((fails+1))
mut "N13 ERR-NOKEY gets the generic text"              's/if \("ERR-NOKEY"\.equals\(r\)\) return "That key/if ("ERR-NOKEY-NEVER".equals(r)) return "That key/' || fails=$((fails+1))
mut "N14 the KEY-END handler sends ENROLL-FIDO2"       's/DaemonSocket\.roundTrip\("ADOPT-FIDO2\x5cn", 100000\)/DaemonSocket.roundTrip("ENROLL-FIDO2\x5cn", 100000)/' || fails=$((fails+1))
# NWP-20261113-18: a stalled save (TIMEOUT) loses its own text, or its Lock exit.
mut "N15 the stalled-save text removed"                's/\n\s*if \("TIMEOUT"\.equals\(why\)\) \{ \/\/ NWP-20261113-18.*?\n\s*\}\n/\n/s' || fails=$((fails+1))
mut "N16 the stalled-save Lock exit removed"           's/\n\s*if \("TIMEOUT"\.equals\(why\)\) return "LOCK";[^\n]*//' || fails=$((fails+1))
# NWP-20261113-11 (case 2): the words for a refused last save, on Your data and Back up now.
mut "H1 lastSaveHeldText ignores the scopes"            's/(lastSaveHeldText\(String verdict, String scopes, java\.util\.function\.LongFunction<String> at\) \{\n)/${1}        if (true) return null;\n/' || fails=$((fails+1))
mut "H2 lastSaveHeldText returns the old sentence"      's/return refusalCause\("REFUSED RETRY 0\x5cn" \+ scopes, at\);/return "The last save was held back to protect your stored copy: this profile changed while the save was running. This usually clears on its own.";/' || fails=$((fails+1))
mut "H3 lastSaveHeldText accepts a non-blocking scope"  's/if \(blockingScope\(s\[0\]\) && ("refused"\.equals\(s\[1\]\)\) return refusalCause)/if ($1/' || fails=$((fails+1))
mut "H4 Back up now always says the data areas are saved" 's/\+ \(fDataRefused \? \(fHeld != null \? "\. " \+ fHeld : "\."\) : "\. Your data areas are saved\."\)\);/+ ". Your data areas are saved.");/' || fails=$((fails+1))
mut "H5 Your data drops lastSaveHeldText"               's/String held = lastSaveHeldText\(verdict, o\.optString\("scopes", ""\), this::fmtWhen\);/String held = null;/' || fails=$((fails+1))
mutg() { # mutg <label> <perl-expr> -- as mut, on ChooserActivity.java (the gate's notice, NWP-20261013-20)
  local d m rc; d=$(mktemp -d -p "$W"); m="$d/ChooserActivity.java"
  if ! perl -0pe "$2" "$GATE" > "$m"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if [ ! -s "$m" ]; then echo "  ERROR     $1 -- the mutant is empty"; rm -rf "$d"; return 1; fi
  if cmp -s "$GATE" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  suite "$SRC" "$m" >/dev/null 2>&1; rc=$?
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not extract or compile (rc=$rc)"; return 1 ;;
  esac
}
mutg "G1 the notice is raised again while it is on screen"  's/return stamp > 0 && !showing && !finishing;/return stamp > 0 \&\& !finishing;/' || fails=$((fails+1))
mutg "G2 a NONE reply reads as a notice"                   's/if \(!r\.startsWith\("NOTICE "\)\) return 0;/if (!r.startsWith("NOTICE ")) return 1;/' || fails=$((fails+1))
mutg "G3 a non-positive time reads as a notice"           's/return t > 0 \? t : 0;/return t != 0 ? t : 0;/' || fails=$((fails+1))
mutg "G4 the clear drops the notice's time"               's/return "CLEAR-CREDIT-LOST\x5cn" \+ stamp \+ "\x5cn";/return "CLEAR-CREDIT-LOST\x5cn\x5cn";/' || fails=$((fails+1))
# G5 is anchored on the notice's own first line: the supersede warning (NWP-20261016-47) says the same last sentence.
mutg "G5 the notice says the earlier credit is lost too"  's/(couldn\x27t be saved, and is lost\. "\n\s*\+ ")Credit saved before that session is safe\./$1All your storage credit is lost./' || fails=$((fails+1))
mutg "G6 the gate never asks for the notice"              's/        refreshCreditLostNotice\(\); \/\/ NWP-20261013-20[^\n]*\n//' || fails=$((fails+1))
mutg "G7 the notice is cleared at the fetch, unseen"      's/(if \(stamp <= 0\) return;)/$1 sendDaemon(creditLostClearCommand(stamp));/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
