#!/usr/bin/env bash
# test-push-secret.sh [--mutate] -- NWP-20261115-02: NowherePush keeps the push stream secret and presents it (dn-1102 #5).
# The gateway (nowhere-cloud NWC-20261114-01) answers /push/register with {"endpoint","token","secret"}, takes the secret
# in the POST /push/stream body as "secrets":{"<token>":"<secret>"} and in the /push/unregister body as "secret", and
# refuses a presented wrong or empty secret. From GATEWAY_PUSH_SECRETLESS_UNTIL (NWC-20261114-09) a token sent without its
# secret is announced gone. So the phone keeps each registration's secret in registrations.json and presents it.
#
# Lifts PushService's static helpers VERBATIM (by signature) into a harness and runs them under a real JVM: Reg (both
# constructors), parseRegister, jsonString, streamBody, unregisterBody, regFromJson and regToJson (harness A); and
# handleRegister alone, with a harness-own Reg and stubs (harness B). The org.json stand-in declares Android's checked
# JSONException on JSONObject(String), getString and put, so a helper that drops its throws clause does not compile here
# (exit 3), as on the build host.
#
# Cases: (a) parseRegister with a secret, without one, with "" (null), and with no token (null); (b) streamBody's exact
# bytes: no secret, mixed, escaping in a token and a secret, and never an empty value; (c) unregisterBody's exact bytes,
# with and without a secret; (d) regToJson -> toString -> JSONObject -> regFromJson keeps the secret, and a legacy object
# (no "secret") or "" loads null; (e) regToJson of a secret-less Reg has no "secret" key; (f) handleRegister keeps the
# secret gatewayRegister returned (its `new Reg(` passes ep[2]).
# On origin/main harness A prints EXTRACTION FAILED (no parseRegister and the other new helpers) and harness B compiles and
# FAILs (f) on its assertion (the secret is null): exit 2. test-push-stream.sh covers streamLoop and the re-mint (S4).
#
# Needs a JDK and FAILS (exit 2) without one: javac/java from PATH, then the build VM's prebuilt JDK 21.
#   bash test-push-secret.sh            # the cases
#   bash test-push-secret.sh --mutate   # ... plus mutants S1-S3 and S5-S8 that must each be CONVICTED by a FAIL
# PUSH_SERVICE_SRC overrides the PushService.java under test.
# Exit: 0 pass, 1 a case failed, 2 cannot run (no JDK, EXTRACTION FAILED), 3 a harness does not compile.
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
  echo "test-push-secret: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -J-XX:-UsePerfData -version 2>&1 | sed 's/^/using /'

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

lift(){ # lift <signature prefix> <file>: from the signature line to the first 4-space-indented closing brace
  awk -v sig="$1" 'index($0,sig)==1{p=1} p{print} p&&$0=="    }"{exit}' "$2"
}

# stubs <dir>: android.util.Log (records every message) and the org.json stand-in with Android's checked exceptions
stubs(){
  local d=$1
  mkdir -p "$d/android/util" "$d/org/json"
  cat >"$d/android/util/Log.java" <<'J'
package android.util;
public final class Log {
    public static final java.util.List<String> msgs = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
    public static int w(String t, String m, Throwable e) { msgs.add(t + ": " + m + " (" + e + ")"); return 0; }
    public static int w(String t, String m) { msgs.add(t + ": " + m); return 0; }
    public static int i(String t, String m) { msgs.add(t + ": " + m); return 0; }
}
J
  cat >"$d/org/json/JSONException.java" <<'J'
package org.json;
public class JSONException extends Exception { public JSONException(String m) { super(m); } }
J
  cat >"$d/org/json/JSONObject.java" <<'J'
package org.json;
import java.util.*;
/** Stand-in: a flat object of string fields. The checked exceptions mirror Android's org.json. */
public class JSONObject {
    private final Map<String, String> m = new LinkedHashMap<>();
    public JSONObject() { }
    public JSONObject(String s) throws JSONException {
        int[] i = {0};
        ws(s, i);
        if (i[0] >= s.length() || s.charAt(i[0]) != '{') throw new JSONException("not an object");
        i[0]++; ws(s, i);
        if (i[0] < s.length() && s.charAt(i[0]) == '}') return;
        while (true) {
            ws(s, i); String k = str(s, i); ws(s, i);
            if (i[0] >= s.length() || s.charAt(i[0]) != ':') throw new JSONException("no colon");
            i[0]++; ws(s, i);
            m.put(k, str(s, i)); ws(s, i);
            if (i[0] >= s.length()) throw new JSONException("unterminated");
            char c = s.charAt(i[0]++);
            if (c == '}') return;
            if (c != ',') throw new JSONException("bad separator");
        }
    }
    private static void ws(String s, int[] i) { while (i[0] < s.length() && Character.isWhitespace(s.charAt(i[0]))) i[0]++; }
    private static String str(String s, int[] i) throws JSONException {
        if (i[0] >= s.length() || s.charAt(i[0]) != '"') throw new JSONException("not a string");
        StringBuilder b = new StringBuilder();
        for (i[0]++; i[0] < s.length(); i[0]++) {
            char c = s.charAt(i[0]);
            if (c == '"') { i[0]++; return b.toString(); }
            if (c == '\\') {
                char e = s.charAt(++i[0]);
                if (e == 'u') { b.append((char) Integer.parseInt(s.substring(i[0] + 1, i[0] + 5), 16)); i[0] += 4; }
                else b.append(e);
            } else b.append(c);
        }
        throw new JSONException("unterminated string");
    }
    public String getString(String k) throws JSONException {
        String v = m.get(k);
        if (v == null) throw new JSONException("no value for " + k);
        return v;
    }
    public JSONObject put(String k, String v) throws JSONException {
        if (k == null) throw new JSONException("null key");
        m.put(k, v);
        return this;
    }
    public String optString(String k, String d) { return m.getOrDefault(k, d); }
    public boolean has(String k) { return m.containsKey(k); }
    private static void q(StringBuilder b, String s) {
        b.append('"');
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        b.append('"');
    }
    @Override public String toString() {
        StringBuilder b = new StringBuilder("{");
        for (Map.Entry<String, String> e : m.entrySet()) {
            if (b.length() > 1) b.append(',');
            q(b, e.getKey()); b.append(':'); q(b, e.getValue());
        }
        return b.append('}').toString();
    }
}
J
}

# harness_a <dir> <lifted.txt>: the static helpers, (a)-(e)
harness_a(){
  local d=$1 body=$2
  {
    cat <<'J'
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.json.JSONException;
import org.json.JSONObject;

final class Svc {
J
    cat "$body"
    echo "}"
    cat <<'J'
public final class HarnessA {
    static int pass, fail;
    static void check(String name, boolean ok, String why) {
        if (ok) { pass++; System.out.println("  ok    " + name); } else { fail++; System.out.println("  FAIL  " + name + " -- " + why); }
    }
    static String s(byte[] b) { return new String(b, StandardCharsets.UTF_8); }
    static String body(List<String> tokens, Svc.Reg... regs) {
        Map<String, Svc.Reg> byGw = new LinkedHashMap<>();
        for (Svc.Reg r : regs) byGw.put(r.gatewayToken, r);
        return s(Svc.streamBody(tokens, byGw));
    }
    static String show(String[] a) { return a == null ? "null" : Arrays.toString(a); }
    public static void main(String[] args) throws Exception {
        { // (a) parseRegister
            String[] r1 = Svc.parseRegister("{\"endpoint\":\"https://gw/ep-a\",\"token\":\"gwtok-a\",\"secret\":\"sec-a-7q\"}");
            check("(a1) an answer with a secret -> [endpoint, token, secret]",
                  r1 != null && r1.length == 3 && "https://gw/ep-a".equals(r1[0]) && "gwtok-a".equals(r1[1]) && "sec-a-7q".equals(r1[2]), "got " + show(r1));
            String[] r2 = Svc.parseRegister("{\"endpoint\":\"https://gw/ep-a\",\"token\":\"gwtok-a\"}");
            check("(a2) an older gateway's answer (no secret) -> secret null",
                  r2 != null && r2.length == 3 && "gwtok-a".equals(r2[1]) && r2[2] == null, "got " + show(r2));
            String[] r3 = Svc.parseRegister("{\"endpoint\":\"https://gw/ep-a\",\"token\":\"gwtok-a\",\"secret\":\"\"}");
            check("(a3) an empty secret -> null, never \"\"", r3 != null && r3.length == 3 && r3[2] == null, "got " + show(r3));
            String[] r4 = Svc.parseRegister("{\"endpoint\":\"https://gw/ep-a\",\"secret\":\"sec-a-7q\"}");
            check("(a4) no token -> null", r4 == null, "got " + show(r4));
        }
        { // (b) streamBody's exact bytes
            Svc.Reg a = new Svc.Reg("p", "t", "a", "e"), b = new Svc.Reg("p", "t2", "b", "e2");
            String none = body(Arrays.asList("a", "b"), a, b);
            check("(b1) no secret: exactly the tokens-only body", none.equals("{\"tokens\":[\"a\",\"b\"]}"), "got " + none);
            Svc.Reg ma = new Svc.Reg("p", "t", "a", "e", "sec-a-7q"), mc = new Svc.Reg("p", "t3", "c", "e3", "sec-c-7q");
            String mixed = body(Arrays.asList("a", "b", "c"), ma, b, mc);
            String wantMixed = "{\"tokens\":[\"a\",\"b\",\"c\"],\"secrets\":{\"a\":\"sec-a-7q\",\"c\":\"sec-c-7q\"}}";
            check("(b2) mixed: only the tokens with a secret, in token order", mixed.equals(wantMixed), "got " + mixed + " want " + wantMixed);
            String qt = "q\"t\\" + (char) 1, qs = "s\"\\" + (char) 2;
            String esc = body(Arrays.asList(qt), new Svc.Reg("p", "t", qt, "e", qs));
            String wantEsc = "{\"tokens\":[\"q\\\"t\\\\\\u0001\"],\"secrets\":{\"q\\\"t\\\\\\u0001\":\"s\\\"\\\\\\u0002\"}}";
            check("(b3) a quote, a backslash and a control char are escaped in the token and the secret", esc.equals(wantEsc), "got " + esc + " want " + wantEsc);
            String empty = body(Arrays.asList("a"), new Svc.Reg("p", "t", "a", "e", ""));
            check("(b4) a \"\" secret is never sent: no secrets entry and no empty value",
                  empty.equals("{\"tokens\":[\"a\"]}") && !empty.contains(":\"\""), "got " + empty);
        }
        { // (c) unregisterBody's exact bytes
            String u1 = s(Svc.unregisterBody("gwtok-a", null));
            check("(c1) no secret: exactly {\"token\":\"gwtok-a\"}", u1.equals("{\"token\":\"gwtok-a\"}"), "got " + u1);
            String u2 = s(Svc.unregisterBody("gwtok-a", "sec-a-7q"));
            check("(c2) with a secret: exactly {\"token\":\"gwtok-a\",\"secret\":\"sec-a-7q\"}", u2.equals("{\"token\":\"gwtok-a\",\"secret\":\"sec-a-7q\"}"), "got " + u2);
        }
        { // (d) the registrations.json round trip
            Svc.Reg r = new Svc.Reg("org.example.app", "apptok", "gwtok-a", "https://gw/ep-a", "sec-a-7q");
            String text = Svc.regToJson(r).toString();
            Svc.Reg back = Svc.regFromJson(new JSONObject(text));
            check("(d1) regToJson -> toString -> JSONObject -> regFromJson keeps all five fields",
                  back.appPackage.equals("org.example.app") && back.appToken.equals("apptok") && back.gatewayToken.equals("gwtok-a")
                  && back.endpoint.equals("https://gw/ep-a") && "sec-a-7q".equals(back.secret), "file text " + text + " -> secret " + back.secret);
            Svc.Reg legacy = Svc.regFromJson(new JSONObject("{\"app\":\"org.example.app\",\"appToken\":\"apptok\",\"gw\":\"gwtok-a\",\"endpoint\":\"https://gw/ep-a\"}"));
            check("(d2) an object written before the secret (no key) loads null", legacy.secret == null && legacy.gatewayToken.equals("gwtok-a"), "secret " + legacy.secret);
            Svc.Reg blank = Svc.regFromJson(new JSONObject("{\"app\":\"org.example.app\",\"appToken\":\"apptok\",\"gw\":\"gwtok-a\",\"endpoint\":\"https://gw/ep-a\",\"secret\":\"\"}"));
            check("(d3) a \"\" secret loads null", blank.secret == null, "secret [" + blank.secret + "]");
        }
        { // (e) a secret-less Reg writes no secret key
            JSONObject o = Svc.regToJson(new Svc.Reg("org.example.app", "apptok", "gwtok-a", "https://gw/ep-a"));
            check("(e) regToJson of a secret-less Reg has no \"secret\" key", !o.has("secret") && !o.toString().contains("secret"), "object " + o);
        }
        System.out.println("passed " + pass + ", failed " + fail);
        System.exit(fail == 0 ? 0 : 1);
    }
}
J
  } >"$d/HarnessA.java"
}

# harness_b <dir> <lifted.txt>: handleRegister with a harness-own Reg and stubs, (f)
harness_b(){
  local d=$1 body=$2
  {
    cat <<'J'
import java.util.*;
import android.util.Log;

final class Svc2 {
    private static final String TAG = "NowherePush";
    static final class Reg {
        final String appPackage, appToken, gatewayToken, endpoint;
        final String secret;
        Reg(String p, String t, String g, String e) { this(p, t, g, e, null); }
        Reg(String p, String t, String g, String e, String s) { appPackage = p; appToken = t; gatewayToken = g; endpoint = e; secret = s; }
    }
    final Map<String, Reg> regs = new LinkedHashMap<>();
    int saves, reconnects;
    final List<String> newEps = new ArrayList<>(), failed = new ArrayList<>();
    private String[] gatewayRegister() { return new String[]{"https://gw/ep-a", "gwtok-a", "sec-a-7q"}; }
    private void saveRegs() { saves++; }
    private void broadcastNewEndpoint(Reg r) { newEps.add(r.appToken + "=" + r.endpoint); }
    private void broadcastRegistrationFailed(String p, String t, String why) { failed.add(t + ":" + why); }
    private void reconnectStream() { reconnects++; }
J
    cat "$body"
    echo '    void register(String p, String t) { handleRegister(p, t); }'
    echo "}"
    cat <<'J'
public final class HarnessB {
    public static void main(String[] args) {
        Svc2 s = new Svc2();
        s.register("org.example.app", "apptok");
        Svc2.Reg r = s.regs.get("apptok");
        boolean ok = r != null && "sec-a-7q".equals(r.secret) && "gwtok-a".equals(r.gatewayToken) && s.saves == 1
                && s.newEps.equals(Arrays.asList("apptok=https://gw/ep-a")) && s.failed.isEmpty();
        boolean leak = false;
        for (String m : Log.msgs) if (m.contains("sec-a-7q")) leak = true;
        if (ok && !leak) System.out.println("  ok    (f) handleRegister keeps the secret gatewayRegister returned, saves once, broadcasts once, logs no secret");
        else System.out.println("  FAIL  (f) handleRegister keeps the secret gatewayRegister returned -- reg "
                + (r == null ? "null" : r.gatewayToken + " secret=" + r.secret) + " saves=" + s.saves + " eps=" + s.newEps + " failed=" + s.failed + " leak=" + leak);
        System.exit(ok && !leak ? 0 : 1);
    }
}
J
  } >"$d/HarnessB.java"
}

# worst <a> <b>: the status that wins, 2 over 3 over 1 over 0
worst(){
  local x
  for x in 2 3 1; do
    if [ "$1" = "$x" ] || [ "$2" = "$x" ]; then echo "$x"; return; fi
  done
  echo 0
}

# run_side <dir> <class> -> compile + run status
run_side(){
  local d=$1 cls=$2
  "$JAVAC" -J-XX:-UsePerfData -encoding UTF-8 -d "$d/out" "$d"/android/util/*.java "$d"/org/json/*.java "$d/$cls.java" >"$d/compile.log" 2>&1 \
    || { cat "$d/compile.log" >&2; return 3; }
  "$JAVA" -XX:-UsePerfData -Djava.io.tmpdir="$W" -cp "$d/out" "$cls"
}

# run_one <PushService.java> [sed script applied to the LIFTED code] -> the worst of harness A's and harness B's status
run_one(){
  local src=$1 mut=${2:-} d a b ra=0 rb=0 f sig name
  d=$(mktemp -d -p "$W")
  [ -f "$src" ] || { echo "EXTRACTION FAILED: no $src" >&2; return 2; }
  a="$d/a"; b="$d/b"; mkdir -p "$a" "$b"
  : >"$a/lifted.txt"
  for sig in '    static final class Reg {' '    static String[] parseRegister(' '    static void jsonString(' \
             '    static byte[] streamBody(' '    static byte[] unregisterBody(' '    static Reg regFromJson(' \
             '    static JSONObject regToJson('; do
    f=$(mktemp -p "$d")
    lift "$sig" "$src" >"$f"
    if [ ! -s "$f" ]; then
      name=${sig#    }; echo "EXTRACTION FAILED: $name not found in $src" >&2; ra=2
    fi
    cat "$f" >>"$a/lifted.txt"
  done
  lift '    private void handleRegister(' "$src" >"$b/lifted.txt"
  [ -s "$b/lifted.txt" ] || { echo "EXTRACTION FAILED: handleRegister not found in $src" >&2; rb=2; }
  if [ -n "$mut" ]; then
    cat "$a/lifted.txt" "$b/lifted.txt" >"$d/before.txt"
    sed -i "$mut" "$a/lifted.txt" "$b/lifted.txt" || return 2
    cat "$a/lifted.txt" "$b/lifted.txt" | cmp -s - "$d/before.txt" && { echo "MUTATION INERT" >&2; return 2; }
  fi
  if [ "$ra" = 0 ]; then
    stubs "$a"; harness_a "$a" "$a/lifted.txt"; run_side "$a" HarnessA; ra=$?
  fi
  if [ "$rb" = 0 ]; then
    stubs "$b"; harness_b "$b" "$b/lifted.txt"; run_side "$b" HarnessB; rb=$?
  fi
  case "$(worst "$ra" "$rb")" in 0) return 0 ;; 1) return 1 ;; 2) return 2 ;; *) return 3 ;; esac
}

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

echo "== the cases =="
run_one "$SRC"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (exit $rc: 1 a case, 2 cannot run / extraction failed, 3 no compile)"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ]; then
  echo
  echo "== mutants (each MUST be convicted by a FAIL in a case) =="
  mutant(){ # mutant <label> <sed script on the lifted code>
    local r mo
    mo=$(run_one "$SRC" "$2" 2>&1); r=$?
    case "$r" in
      1) case "$mo" in
           *"  FAIL  ("*) ok "convicted: $1 ($(printf '%s\n' "$mo" | grep -m1 '  FAIL  (' | sed 's/^  FAIL  //; s/ .*//'))" ;;
           *) no "MUTANT exit 1 with no FAIL line: $1" ;;
         esac ;;
      0) no "NOT CONVICTED: $1 -- suite passes on broken code" ;;
      *) no "MUTANT BROKEN (exit $r, not a case): $1" ;;
    esac
  }
  mutant "S1: streamBody drops the secrets object"      's/if (r == null || r.secret == null || r.secret.isEmpty()) continue;/if (true) continue;/'
  mutant "S2: a secret-less Reg is sent as \"\""        's/if (r == null || r.secret == null || r.secret.isEmpty()) continue;/if (r == null) continue;/; s/jsonString(sb, r.secret);/jsonString(sb, r.secret == null ? "" : r.secret);/'
  mutant "S3: parseRegister drops the secret"           's/secret.isEmpty() ? null : secret}/null}/'
  mutant "S5: unregisterBody omits the secret"          's/if (secret != null) {/if (false) {/'
  mutant "S6: regFromJson ignores the secret"           's/ s.isEmpty() ? null : s)/ null)/'
  mutant "S7: regToJson omits the secret"               '/o.put("secret"/d'
  mutant "S8: handleRegister passes null for the secret" 's/(appPackage, appToken, ep\[1\], ep\[0\], ep\[2\])/(appPackage, appToken, ep[1], ep[0], null)/'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ] && exit 0
# cannot-run (2) and no-compile (3) are not a failed case: keep the status at the suite boundary
case "$rc" in 2|3) exit "$rc" ;; esac
exit 1
