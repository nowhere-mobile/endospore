#!/usr/bin/env bash
# test-signin-trace-java.sh [--mutate] -- NWP-20261203-04: the sign-in chooser-kill evidence. Backlog row "At every
# sign-in the session's chooser process is killed for "permissions revoked" and its CredentialService is left
# restarting with the sign-in's starts pending".
#
# Runs core/chooser/tests/signin-trace (SignInTrace's holderClass / permBits / startKind / exitLine, compiled and
# EXECUTED), then source checks on the real files (comment-only lines dropped, except where P3 / P5 say so):
#   P1 in roamLogin, the code line before the `#149 live-intercept-mode` Log.i is the step-0 smsProbe;
#   P2 the code line after `disableRoamedDialerComponents(fuid);` is the step-1 smsProbe;
#   P3 the Log.i, the cede and the dialer call are three adjacent lines of the file (the sms-notice and missed-call pins);
#   P4 in CredentialService.onStartCommand, the statement after `ACTIVE.incrementAndGet();` is the credsvc trace;
#   P5 in NowhereApp.onCreate, the exitinfo trace sits in an `if (android.os.UserHandle.myUserId() != 0) {` block that
#      closes before the `// NWP-20261001-05 / NWP-20261002-01` push-doze comment;
#   P6 smsProbe's step 1 starts the +1 s / +5 s reads (steps 2 and 3) on its own thread, and its trace carries
#      SignInTrace.holderClass and SignInTrace.permBits.
# What it does not prove: the chooser is not compiled here (the build host's javac check is), and nothing runs on a
# device -- which step kills the session chooser is the lynx sign-in this evidence is for.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
#
# --mutate re-runs the suite against broken copies, each of which must be CONVICTED: a mutant that does not apply
# (INERT) or does not compile (BROKEN) counts as a failure, never a pass.
#
#   bash test-signin-trace-java.sh            # the cases and source checks
#   bash test-signin-trace-java.sh --mutate   # ... plus the mutants
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
  echo "test-signin-trace-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
SRCDIR="$ROOT/core/chooser/src/com/nowhere/chooser"
SIT="$SRCDIR/SignInTrace.java"
CA="$SRCDIR/ChooserActivity.java"
CS="$SRCDIR/CredentialService.java"
APP="$SRCDIR/NowhereApp.java"

# code <file>: the file without its comment-only lines, each kept line prefixed `<file line>:`
code() { grep -nv '^[[:space:]]*//' "$1"; }

# lineof <fixed string> <text>: the 1-based line of the text where it first occurs, 0 when absent
lineof() {
  local n
  n=$(grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1)
  echo "${n:-0}"
}

# countof <fixed string> <text>: how many lines of the text hold it
countof() { grep -cF -- "$1" <<<"$2"; }

# idx <file line> <code text>: the 1-based line of the code text that holds that file line, 0 when it is a comment
idx() { awk -F: -v l="$1" '$1 == l { print NR; f=1; exit } END { if (!f) print 0 }' <<<"$2"; }

# body <n> <text>: line n of the text, without the `<file line>:` prefix code() put there
body() { sed -n "${1}p" <<<"$2" | cut -d: -f2-; }

# has <fixed string> <text>: true when the text holds it (no pipe into grep -q)
has() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

LOGI='android.util.Log.i("NowhereChooser", "#149 live-intercept-mode: SIM stays on gate, no associate");'
CEDE='                cedeSmsToMessagingInRoamedUser(fuid);'
DIAL='                disableRoamedDialerComponents(fuid); // NWP-20261012-07: the missed-call receiver works only in user 0'
INC='        ACTIVE.incrementAndGet();'
DOZE='        // NWP-20261001-05 / NWP-20261002-01: keep the push apps on the Doze allow-list (ChooserActivity'
GUARD='        if (android.os.UserHandle.myUserId() != 0) {'

# check <SignInTrace> <ChooserActivity> <CredentialService> <NowhereApp>: the cases, then P1-P6. Returns 3 when the
# cases do not compile, 1 on any failed case or check.
check() {
  local sit=$1 ca=$2 cs=$3 app=$4 rc src raw n l1 l2 l3 sig end b
  JAVAC=$JAVAC JAVA=$JAVA bash "$ROOT/core/chooser/tests/signin-trace/run.sh" "$sit"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL cases (run.sh rc=$rc)"; [ "$rc" -eq 3 ] && return 3; return 1; }
  # (P1) / (P2)
  raw=$(cat "$ca")
  sig=$(grep -nxF '    private void roamLogin(final String name, final String pw, final boolean isCreate, final String keyMode) {' "$ca" | cut -d: -f1)
  [ -n "$sig" ] || { echo "FAIL P1: no 4-argument roamLogin"; return 1; }
  end=$(awk -v s="$sig" 'NR > s && $0 == "    }" { print NR; exit }' "$ca")
  [ "$(countof "$LOGI" "$raw")" = 1 ] || { echo "FAIL P1: the #149 Log.i is not in ChooserActivity exactly once"; return 1; }
  l1=$(lineof "$LOGI" "$raw")
  [ "$l1" -gt "$sig" ] && [ "$l1" -lt "${end:-0}" ] || { echo "FAIL P1: the #149 Log.i is not inside roamLogin"; return 1; }
  src=$(code "$ca")
  n=$(idx "$l1" "$src")
  [ "$n" -gt 1 ] || { echo "FAIL P1: cannot place the #149 Log.i"; return 1; }
  b=$(body $((n-1)) "$src")
  case "$b" in '                smsProbe(appCtx, fuid, 0);'*) ;; *) echo "FAIL P1: the code line before the #149 Log.i is not the step-0 smsProbe: $b"; return 1 ;; esac
  echo "  ok   P1 the step-0 smsProbe is the code line before the #149 Log.i in roamLogin"
  [ "$(countof "$DIAL" "$raw")" = 1 ] || { echo "FAIL P2: the dialer call is not in ChooserActivity exactly once"; return 1; }
  l3=$(lineof "$DIAL" "$raw")
  n=$(idx "$l3" "$src")
  b=$(body $((n+1)) "$src")
  case "$b" in '                smsProbe(appCtx, fuid, 1);'*) ;; *) echo "FAIL P2: the code line after the dialer call is not the step-1 smsProbe: $b"; return 1 ;; esac
  [ "$(countof 'smsProbe(appCtx, fuid, ' "$raw")" = 2 ] || { echo "FAIL P2: roamLogin does not call smsProbe exactly twice"; return 1; }
  echo "  ok   P2 the step-1 smsProbe is the code line after the dialer call"
  # (P3) raw lines: the pins hold them contiguous, comments included
  l2=$(grep -nxF -- "$CEDE" "$ca" | cut -d: -f1)
  [ "${l2:-0}" = $((l1+1)) ] && [ "$l3" = $((l1+2)) ] \
    || { echo "FAIL P3: the Log.i, cede and dialer lines are not adjacent (lines $l1 ${l2:-0} $l3)"; return 1; }
  echo "  ok   P3 the Log.i, the cede and the dialer call stay adjacent"
  # (P4)
  src=$(code "$cs")
  [ "$(countof "$INC" "$src")" = 1 ] || { echo "FAIL P4: ACTIVE.incrementAndGet() is not in CredentialService exactly once"; return 1; }
  n=$(lineof "$INC" "$src")
  b=$(body $((n+1)) "$src")
  [ "$b" = '        ChooserActivity.idleTrace("credsvc " + SignInTrace.startKind(x -> intent != null && intent.getBooleanExtra(x, false))' ] \
    || { echo "FAIL P4: the statement after ACTIVE.incrementAndGet() is not the credsvc trace: $b"; return 1; }
  b=$(body $((n+2)) "$src")
  [ "$b" = '                + " u=" + android.os.UserHandle.myUserId() + " id=" + startId + " up=" + android.os.SystemClock.uptimeMillis()); // NWP-20261203-04' ] \
    || { echo "FAIL P4: the credsvc trace does not carry u= id=startId up=: $b"; return 1; }
  [ "$(countof 'ChooserActivity.idleTrace("credsvc ' "$src")" = 1 ] || { echo "FAIL P4: the credsvc trace is not in CredentialService exactly once"; return 1; }
  echo "  ok   P4 the credsvc trace is the statement after ACTIVE.incrementAndGet()"
  # (P5) raw lines: the push-doze comment is the anchor
  raw=$(cat "$app")
  [ "$(countof 'ChooserActivity.idleTrace("exitinfo u="' "$raw")" = 1 ] || { echo "FAIL P5: the exitinfo trace is not in NowhereApp exactly once"; return 1; }
  l1=$(lineof 'ChooserActivity.idleTrace("exitinfo u="' "$raw")
  l2=$(lineof "$DOZE" "$raw")
  l3=$(lineof '        PermsLiveRecord.register(this); // NWP-20261112-10' "$raw")
  n=$(awk -v t="$l1" 'NR < t && /^        if \(/ { g=NR } END { print g+0 }' "$app")
  [ "$n" -gt "$l3" ] && [ "$(sed -n "${n}p" "$app")" = "$GUARD" ] \
    || { echo "FAIL P5: the exitinfo trace is not inside the session-only ($GUARD) block after the PermsLiveRecord register"; return 1; }
  end=$(awk -v s="$n" 'NR > s && $0 == "        }" { print NR; exit }' "$app")
  [ "$l2" -gt 0 ] && [ "${end:-0}" -gt "$l1" ] && [ "$end" -lt "$l2" ] \
    || { echo "FAIL P5: the session-only exitinfo block does not close before the push-doze comment (lines $n ${end:-0} $l2)"; return 1; }
  has 'getHistoricalProcessExitReasons(getPackageName(), 0, 1)' "$raw" && has 'SignInTrace.exitLine(' "$raw" \
    || { echo "FAIL P5: the exitinfo block does not read the last exit through SignInTrace.exitLine"; return 1; }
  echo "  ok   P5 the exitinfo block runs only in a session user and precedes the push-doze comment"
  # (P6)
  b=$(awk '$0 == "    private static void smsProbe(final android.content.Context ctx, final int uid, final int step) {" { on=1 } on { print } on && $0 == "    }" { exit }' "$ca")
  [ -n "$b" ] || { echo "FAIL P6: no smsProbe helper"; return 1; }
  l1=$(lineof 'if (step == 1) {' "$b"); l2=$(lineof 'Thread.sleep(1000);' "$b"); l3=$(lineof 'smsProbe(ctx, uid, 2);' "$b")
  n=$(lineof 'Thread.sleep(4000);' "$b")
  [ "$l1" -gt 0 ] && [ "$l2" -gt "$l1" ] && [ "$l3" -gt "$l2" ] && [ "$n" -gt "$l3" ] && has 'smsProbe(ctx, uid, 3);' "$b" \
    && has 'new Thread(() -> {' "$b" \
    || { echo "FAIL P6: smsProbe's step 1 does not start steps 2 and 3 at +1 s and +5 s on a thread"; return 1; }
  has 'SignInTrace.holderClass(holders, ctx.getPackageName(), SmsRoleRoam.MESSAGING)' "$b" && has 'SignInTrace.permBits(granted)' "$b" \
    || { echo "FAIL P6: the smsprobe trace does not carry SignInTrace.holderClass and permBits"; return 1; }
  echo "  ok   P6 smsProbe reads holder + grants and step 1 starts the +1 s / +5 s reads"
}
check "$SIT" "$CA" "$CS" "$APP" || { echo "FAILED"; exit 1; }
echo "== all checks pass"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED; a mutant that does not apply or compile proves nothing)"
mut() { # mut <label> <sit|ca|cs|app> <perl-expr> <text the failure must contain>
  local d f orig sit ca cs app out rc
  d=$(mktemp -d -p "$W"); sit=$SIT; ca=$CA; cs=$CS; app=$APP
  case "$2" in
    sit) orig=$SIT; f="$d/SignInTrace.java";       sit=$f ;;
    ca)  orig=$CA;  f="$d/ChooserActivity.java";   ca=$f ;;
    cs)  orig=$CS;  f="$d/CredentialService.java"; cs=$f ;;
    app) orig=$APP; f="$d/NowhereApp.java";        app=$f ;;
    *) echo "  ERROR     $1 -- unknown target $2"; return 1 ;;
  esac
  cp "$orig" "$f"
  if ! perl -0pi -e "$3" "$f"; then echo "  ERROR     $1 -- perl failed"; return 1; fi
  if cmp -s "$orig" "$f"; then echo "  INERT     $1"; return 1; fi
  out=$(check "$sit" "$ca" "$cs" "$app" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then echo "  SURVIVED  $1"; return 1; fi
  if [ "$rc" -ne 1 ]; then echo "  BROKEN    $1 -- rc=$rc (did not compile)"; return 1; fi
  case "$out" in *"$4"*) ;; *) echo "  BROKEN    $1 -- it failed, but not with '$4'"; return 1 ;; esac
  echo "  convicted $1 (by '$4')"
}
fails=0
mut "M1 holderClass returns 0 for null" sit 's/if \(holders == null\) return -1;/if (holders == null) return 0;/' "FAIL holder-null" || fails=$((fails+1))
mut "M2 permBits ignores bit 5" sit 's/if \(granted\[i\]\) bits/if (granted[i] && i != 5) bits/' "FAIL perms-all" || fails=$((fails+1))
mut "M3 startKind tests ingest before claimsLogin" sit 's/(\n *if \(has\.test\("claimsLogin"\)\) return "claimslogin";)((?:\n[^\n]*){4})(\n *if \(has\.test\("ingest"\)\) return "ingest";)/$3$1$2/' "FAIL kind-two-extras ingest+claimsLogin" || fails=$((fails+1))
mut "M4 exitLine window removed" sit 's/\n *if \(agoMs < 0 \|\| agoMs > EXIT_WINDOW_MS\) return null;//' "FAIL exit-ago-15min+1" || fails=$((fails+1))
mut "M5 step=1 probe deleted" ca 's/\n *smsProbe\(appCtx, fuid, 1\);[^\n]*//' "FAIL P2" || fails=$((fails+1))
mut "M6 credsvc trace moved after the first branch" cs 's/(\n *ChooserActivity\.idleTrace\("credsvc [^\n]*\n[^\n]*NWP-20261203-04)(.*?\n            return START_NOT_STICKY;\n        \})/$2$1/s' "FAIL P4" || fails=$((fails+1))
mut "M7 exitinfo block in user 0" app 's/(\n        if \(android\.os\.UserHandle\.myUserId\(\) )!=( 0\) \{\n            new Thread\(\(\) -> \{\n                try \{\n                    android\.app\.ActivityManager)/$1==$2/' "FAIL P5" || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
