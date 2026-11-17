#!/usr/bin/env bash
# test-push-fgs-refused.sh [--mutate] -- NWP-20261203-25: NowherePush survives a refused foreground start.
# Device-proof S6 on lynx 2026111001: an app's REGISTER reached DistributorReceiver.onReceive, enqueueRegister called
# startFg, and startForegroundService threw ForegroundServiceStartNotAllowedException from the background. The exception
# killed the distributor process (system_app_crash) and the app got no answer at all. Now startFg catches exactly
# IllegalStateException (ForegroundServiceStartNotAllowedException on API 31+, a background startService before it) and
# returns false; a refused REGISTER is answered REGISTRATION_FAILED "error" (the reason handleRegister's catch sends); a
# refused UNREGISTER sends the app nothing (the endpoint was not dropped); the log line names the op only.
#
# Lifts PushService's enqueueRegister, enqueueUnregister, startFg, registrationFailedIntent and
# broadcastRegistrationFailed VERBATIM (by signature), its six TAG/op/extra constants and DistributorReceiver's four
# action/extra constants, into a harness with stand-ins for Context (it refuses the start when told to and records every
# start and broadcast), Intent, Build (SDK_INT 34), Log (records every line) and Android's exception hierarchy
# (ForegroundServiceStartNotAllowedException extends ServiceStartNotAllowedException extends IllegalStateException).
#
# Cases: (a) a refused REGISTER: no exception escapes, exactly one broadcast: REGISTRATION_FAILED to the app's package,
# FLAG_INCLUDE_STOPPED_PACKAGES, its token, reason "error"; (b) a refused UNREGISTER: no exception escapes, no broadcast;
# (c) an allowed REGISTER and UNREGISTER: one start each, no broadcast; (d) every log line of (a) and (b) says
# `foreground start refused: register|unregister` and names neither the package, the token nor the exception message;
# (e) a failure that is not an IllegalStateException still propagates out of startFg; (f) broadcastRegistrationFailed
# still sends the same intent.
# On origin/main the suite prints EXTRACTION FAILED (no `private static boolean startFg(` and no registrationFailedIntent)
# and exits 2.
#
# Needs a JDK and FAILS (exit 2) without one: javac/java from PATH, then the build VM's prebuilt JDK 21.
#   bash test-push-fgs-refused.sh            # the cases
#   bash test-push-fgs-refused.sh --mutate   # ... plus mutants M1-M7 that must each be CONVICTED by a FAIL in a named case
# PUSH_SERVICE_SRC overrides the PushService.java under test (DistributorReceiver.java is read from its directory).
# Exit: 0 pass, 1 a case failed, 2 cannot run (no JDK, EXTRACTION FAILED), 3 the harness does not compile.
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${PUSH_SERVICE_SRC:-$ROOT/core/pushd/src/com/nowhere/push/PushService.java}
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-push-fgs-refused: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-XX:-UsePerfData -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

lift(){ # lift <signature prefix> <file>: from the signature line to the first 4-space-indented closing brace
  awk -v sig="$1" 'index($0,sig)==1{p=1} p{print} p&&$0=="    }"{exit}' "$2"
}

# stubs <dir>: the Android stand-ins
stubs(){
  local d=$1
  mkdir -p "$d/android/util" "$d/android/os" "$d/android/app" "$d/android/content"
  cat >"$d/android/util/Log.java" <<'J'
package android.util;
public final class Log {
    public static final java.util.List<String> msgs = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    public static int w(String t, String m, Throwable e) { msgs.add(t + ": " + m + " (" + e + ")"); return 0; }
    public static int w(String t, String m) { msgs.add(t + ": " + m); return 0; }
    public static int i(String t, String m) { msgs.add(t + ": " + m); return 0; }
    public static int e(String t, String m) { msgs.add(t + ": " + m); return 0; }
}
J
  cat >"$d/android/os/Build.java" <<'J'
package android.os;
public final class Build {
    public static final class VERSION { public static final int SDK_INT = 34; }
    public static final class VERSION_CODES { public static final int O = 26; }
}
J
  cat >"$d/android/app/ServiceStartNotAllowedException.java" <<'J'
package android.app;
public abstract class ServiceStartNotAllowedException extends IllegalStateException {
    ServiceStartNotAllowedException(String m) { super(m); }
}
J
  cat >"$d/android/app/ForegroundServiceStartNotAllowedException.java" <<'J'
package android.app;
public final class ForegroundServiceStartNotAllowedException extends ServiceStartNotAllowedException {
    public ForegroundServiceStartNotAllowedException(String m) { super(m); }
}
J
  cat >"$d/android/content/Intent.java" <<'J'
package android.content;
import java.util.*;
public class Intent {
    public static final int FLAG_INCLUDE_STOPPED_PACKAGES = 0x00000020;
    private String action, pkg;
    private int flags;
    private final Map<String, String> extras = new LinkedHashMap<>();
    public Intent(String action) { this.action = action; }
    public Intent(Context c, Class<?> cls) { }
    public Intent setPackage(String p) { pkg = p; return this; }
    public Intent addFlags(int f) { flags |= f; return this; }
    public Intent putExtra(String k, String v) { extras.put(k, v); return this; }
    public String getAction() { return action; }
    public String getPackage() { return pkg; }
    public int getFlags() { return flags; }
    public String getStringExtra(String k) { return extras.get(k); }
}
J
  cat >"$d/android/content/Context.java" <<'J'
package android.content;
import java.util.*;
/** Stand-in: refuses the start when throwOnStart is "fgs" (as Android does from the background) or "runtime". */
public class Context {
    public String throwOnStart;
    public final List<Intent> started = new ArrayList<>();
    public final List<Intent> broadcasts = new ArrayList<>();
    private Object start(Intent i) {
        if ("fgs".equals(throwOnStart))
            throw new android.app.ForegroundServiceStartNotAllowedException("startForegroundService() not allowed due to mAllowStartForeground false");
        if ("runtime".equals(throwOnStart)) throw new SecurityException("stand-in");
        started.add(i);
        return null;
    }
    public Object startForegroundService(Intent i) { return start(i); }
    public Object startService(Intent i) { return start(i); }
    public void sendBroadcast(Intent i) { broadcasts.add(i); }
}
J
}

# harness <dir> <consts.txt> <receiver-consts.txt> <lifted.txt>
harness(){
  local d=$1 consts=$2 rconsts=$3 body=$4
  {
    echo "final class DistributorReceiver {"
    cat "$rconsts"
    echo "}"
  } >"$d/DistributorReceiver.java"
  {
    cat <<'J'
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

class PushService extends Context {
J
    cat "$consts" "$body"
    cat <<'J'
    static boolean callStartFg(Context c, Intent i, String op) { return startFg(c, i, op); }
    void callFailed(String p, String t, String r) { broadcastRegistrationFailed(p, t, r); }
}
J
  } >"$d/PushService.java"
  cat >"$d/Harness.java" <<'J'
import android.content.Context;
import android.content.Intent;
import android.util.Log;
import java.util.*;

public final class Harness {
    static final String PKG = "org.example.pushtest", TOK = "tok-7Qx3";
    static int pass, fail;
    static void check(String name, boolean ok, String why) {
        if (ok) { pass++; System.out.println("  ok    " + name); } else { fail++; System.out.println("  FAIL  " + name + " -- " + why); }
    }
    static String show(Intent i) {
        return "[action=" + i.getAction() + " pkg=" + i.getPackage() + " flags=" + i.getFlags() + " token="
                + i.getStringExtra(DistributorReceiver.EXTRA_TOKEN) + " reason=" + i.getStringExtra(DistributorReceiver.EXTRA_REASON) + "]";
    }
    static String show(List<Intent> l) {
        StringBuilder b = new StringBuilder();
        for (Intent i : l) b.append(show(i));
        return l.size() + " " + b;
    }
    static boolean failedAnswer(Intent i, String reason) {
        return DistributorReceiver.ACTION_REGISTRATION_FAILED.equals(i.getAction()) && PKG.equals(i.getPackage())
                && (i.getFlags() & Intent.FLAG_INCLUDE_STOPPED_PACKAGES) != 0
                && TOK.equals(i.getStringExtra(DistributorReceiver.EXTRA_TOKEN))
                && reason.equals(i.getStringExtra(DistributorReceiver.EXTRA_REASON));
    }
    static String logsOk(List<String> logs, String want) {
        if (logs.size() != 1) return "logged " + logs.size() + " lines: " + logs;
        String m = logs.get(0);
        if (!m.contains(want)) return "line [" + m + "] does not say [" + want + "]";
        if (m.contains(PKG) || m.contains(TOK) || m.contains("not allowed")) return "line [" + m + "] names the app, its token or the exception message";
        return null;
    }
    public static void main(String[] args) {
        List<String> logsA = null, logsB = null;
        try { // (a) a refused REGISTER
            Context ctx = new Context();
            ctx.throwOnStart = "fgs";
            Log.msgs.clear();
            PushService.enqueueRegister(ctx, PKG, TOK);
            logsA = new ArrayList<>(Log.msgs);
            check("(a) a refused REGISTER is answered REGISTRATION_FAILED \"error\" to the app's package, with its token",
                  ctx.broadcasts.size() == 1 && failedAnswer(ctx.broadcasts.get(0), "error"), "broadcasts " + show(ctx.broadcasts));
        } catch (Throwable t) {
            check("(a) a refused REGISTER does not throw", false, "escaped " + t);
        }
        try { // (b) a refused UNREGISTER
            Context ctx = new Context();
            ctx.throwOnStart = "fgs";
            Log.msgs.clear();
            PushService.enqueueUnregister(ctx, TOK);
            logsB = new ArrayList<>(Log.msgs);
            check("(b) a refused UNREGISTER sends the app nothing", ctx.broadcasts.isEmpty(), "broadcasts " + show(ctx.broadcasts));
        } catch (Throwable t) {
            check("(b) a refused UNREGISTER does not throw", false, "escaped " + t);
        }
        try { // (c) an allowed REGISTER and UNREGISTER
            Context ctx = new Context();
            Log.msgs.clear();
            PushService.enqueueRegister(ctx, PKG, TOK);
            PushService.enqueueUnregister(ctx, TOK);
            check("(c) an allowed REGISTER and UNREGISTER start the service once each and broadcast nothing",
                  ctx.started.size() == 2 && "register".equals(ctx.started.get(0).getStringExtra("op"))
                  && "unregister".equals(ctx.started.get(1).getStringExtra("op")) && ctx.broadcasts.isEmpty() && Log.msgs.isEmpty(),
                  "started " + ctx.started.size() + " broadcasts " + show(ctx.broadcasts) + " logs " + Log.msgs);
        } catch (Throwable t) {
            check("(c) an allowed REGISTER and UNREGISTER do not throw", false, "escaped " + t);
        }
        { // (d) the refusal log lines
            String why = logsA == null ? "case (a) threw" : logsOk(logsA, "foreground start refused: register");
            if (why == null) why = logsB == null ? "case (b) threw" : logsOk(logsB, "foreground start refused: unregister");
            check("(d) a refusal logs `foreground start refused: <op>` once and names no app, token or exception message", why == null, why);
        }
        try { // (e) any other failure propagates
            Context ctx = new Context();
            ctx.throwOnStart = "runtime";
            boolean r = PushService.callStartFg(ctx, new Intent(ctx, PushService.class), "register");
            check("(e) a failure that is not an IllegalStateException propagates out of startFg", false, "startFg returned " + r);
        } catch (SecurityException e) {
            check("(e) a failure that is not an IllegalStateException propagates out of startFg", true, "");
        } catch (Throwable t) {
            check("(e) a failure that is not an IllegalStateException propagates out of startFg", false, "escaped " + t);
        }
        try { // (f) broadcastRegistrationFailed sends the same intent
            PushService s = new PushService();
            s.callFailed(PKG, TOK, "gateway unreachable");
            check("(f) broadcastRegistrationFailed sends REGISTRATION_FAILED to the app's package, with its token and reason",
                  s.broadcasts.size() == 1 && failedAnswer(s.broadcasts.get(0), "gateway unreachable"), "broadcasts " + show(s.broadcasts));
        } catch (Throwable t) {
            check("(f) broadcastRegistrationFailed does not throw", false, "escaped " + t);
        }
        System.out.println("passed " + pass + ", failed " + fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
J
}

# run_one <PushService.java> [sed script applied to the LIFTED code] -> 0 pass, 1 a case failed, 2 extraction, 3 no compile
run_one(){
  local src=$1 mut=${2:-} d f sig name rsrc n rc=0
  d=$(mktemp -d -p "$W")
  [ -f "$src" ] || { echo "EXTRACTION FAILED: no $src" >&2; return 2; }
  rsrc=$(dirname "$src")/DistributorReceiver.java
  [ -f "$rsrc" ] || { echo "EXTRACTION FAILED: no $rsrc" >&2; return 2; }
  : >"$d/lifted.txt"
  for sig in '    static void enqueueRegister(' '    static void enqueueUnregister(' '    private static boolean startFg(' \
             '    static Intent registrationFailedIntent(' '    private void broadcastRegistrationFailed('; do
    f=$(mktemp -p "$d")
    lift "$sig" "$src" >"$f"
    if [ ! -s "$f" ]; then
      name=${sig#    }; echo "EXTRACTION FAILED: $name not found in $src" >&2; rc=2
    fi
    cat "$f" >>"$d/lifted.txt"
  done
  grep -E '^    private static final String (TAG|EXTRA_OP|OP_REGISTER|OP_UNREGISTER|X_APP|X_APPTOKEN) = ' "$src" >"$d/consts.txt"
  n=$(wc -l <"$d/consts.txt")
  [ "$n" -eq 6 ] || { echo "EXTRACTION FAILED: the 6 TAG/op/extra constants not found in $src (found $n)" >&2; rc=2; }
  grep -E '^    static final String (ACTION_REGISTRATION_FAILED|ACTION_UNREGISTERED|EXTRA_TOKEN|EXTRA_REASON) = ' "$rsrc" >"$d/rconsts.txt"
  n=$(wc -l <"$d/rconsts.txt")
  [ "$n" -eq 4 ] || { echo "EXTRACTION FAILED: the 4 action/extra constants not found in $rsrc (found $n)" >&2; rc=2; }
  [ "$rc" = 0 ] || return "$rc"
  if [ -n "$mut" ]; then
    cp "$d/lifted.txt" "$d/before.txt"
    sed -i "$mut" "$d/lifted.txt" || return 2
    cmp -s "$d/lifted.txt" "$d/before.txt" && { echo "MUTATION INERT" >&2; return 2; }
  fi
  stubs "$d"
  harness "$d" "$d/consts.txt" "$d/rconsts.txt" "$d/lifted.txt"
  "$JAVAC" -J-XX:-UsePerfData -encoding UTF-8 -d "$d/out" "$d"/android/*/*.java "$d"/*.java >"$d/compile.log" 2>&1 \
    || { cat "$d/compile.log" >&2; return 3; }
  "$JAVA" -XX:-UsePerfData -Djava.io.tmpdir="$W" -cp "$d/out" Harness
}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
run_one "$SRC"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (exit $rc: 1 a case, 2 cannot run / extraction failed, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutants (each MUST be convicted by a FAIL in one of its named cases) =="
  mutant(){ # mutant <label> <convicting cases, e.g. "a b"> <sed script on the lifted code>
    local r mo c hit=""
    mo=$(run_one "$SRC" "$3" 2>&1); r=$?
    case "$r" in
      1) for c in $2; do
           case "$mo" in *"  FAIL  ($c)"*) hit="$hit($c)" ;; esac
         done
         if [ -n "$hit" ]; then ok "convicted: $1 by $hit"
         else no "MUTANT exit 1 with no FAIL in its named cases ($2): $1"; fi ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTANT BROKEN (exit $r, not a case): $1" ;;
    esac
  }
  mutant "M1: the catch removed" "a b" \
    's/catch (IllegalStateException e)/catch (UnsupportedOperationException e)/'
  mutant "M2: no REGISTRATION_FAILED on a refused REGISTER" "a" \
    's/if (!startFg(ctx, i, OP_REGISTER)) ctx.sendBroadcast(.*);/startFg(ctx, i, OP_REGISTER);/'
  mutant "M3: setPackage dropped from registrationFailedIntent" "a" \
    's/new Intent(DistributorReceiver.ACTION_REGISTRATION_FAILED).setPackage(appPackage)/new Intent(DistributorReceiver.ACTION_REGISTRATION_FAILED)/'
  mutant "M4: the refusal log names the app" "d" \
    's/"foreground start refused: " + op)/"foreground start refused: " + op + " " + i.getStringExtra(X_APP))/'
  mutant "M5: a refused UNREGISTER answers the app" "b" \
    's/^        startFg(ctx, i, OP_UNREGISTER);/        if (!startFg(ctx, i, OP_UNREGISTER)) ctx.sendBroadcast(registrationFailedIntent("x", appToken, "error"));/'
  mutant "M6: the answer sent even after a successful start" "c" \
    's/if (!startFg(ctx, i, OP_REGISTER)) ctx.sendBroadcast/startFg(ctx, i, OP_REGISTER); ctx.sendBroadcast/'
  mutant "M7: the catch widened to RuntimeException" "e" \
    's/catch (IllegalStateException e)/catch (RuntimeException e)/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ] && exit 0
# cannot-run (2) and no-compile (3) are not a failed case: keep the status at the suite boundary
case "$rc" in 2|3) exit "$rc" ;; esac
exit 1
