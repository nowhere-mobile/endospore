#!/usr/bin/env bash
# test-store-signer-pin-java.sh [--mutate] -- the store's signer pin, run under javac (NWP-20261023-04).
#
# WHY THIS IS COMMITTED. The store's one provenance guarantee is that an installed APK's signer equals the cert the
# DAEMON resolved from the signed catalog. FETCH-APP's success is "OK <pkg> <signer|->"; a reply that lost its third
# token, named another package or was cut short at EOF must NOT read as "the catalog omits the cert" (= no pin), and
# installStaged must refuse a null pin. StoreSignerPin is a pure class with no android.* import, compiled here with
# its cases; a source check pins that getApp calls it and that installStaged's null arm refuses before createSession,
# inside the try whose finally deletes the staged bytes. NWP-20261030-05: an EMPTY pin (the daemon's "-") refuses
# too (NOSIGNER, same place, no `!wantSigner.isEmpty()` guard left), getApp maps it to ERR-NOSIGNER and the nApps
# store names the reason.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-store-signer-pin-java.sh            # the cases + the source check
#   bash test-store-signer-pin-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/StoreSignerPin.java"
SERVICE="$SRC/StoreService.java"
INSTALLER="$SRC/StoreInstaller.java"
NAPPS="$root/core/napps/src/com/nowhere/napps/StoreActivity.java"
CASES="$root/core/chooser/tests/store-signer-pin/StoreSignerPinCases.java"
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
[ -f "$CASES" ] || { echo "FAIL: missing $CASES" >&2; exit 2; }
[ -f "$SERVICE" ] && [ -f "$INSTALLER" ] && [ -f "$NAPPS" ] || { echo "FAIL: missing StoreService.java, StoreInstaller.java or StoreActivity.java" >&2; exit 2; }

# suite <StoreSignerPin.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 the class or the cases did not compile.
suite() {
  local src="$1" d out rc
  [ -f "$src" ] || { echo "  FAIL  StoreSignerPin.java does not exist (the pin is not built)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/StoreSignerPin.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/StoreSignerPinCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.StoreSignerPinCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# sources <StoreService.java> <StoreInstaller.java> <StoreActivity.java> -> 0 when every call-site rule holds, 1 (with
# the reason) when not.
sources() {
  local svc="$1" ins="$2" nap="$3" a b c
  a=$(awk '
    /public String getApp\(/ { in_m = 1 }
    in_m && /StoreSignerPin\.fromFetchReply\(/ { calls++ }
    in_m && /tok\.length >= 3/ { old++ }
    in_m && /^        }$/ { in_m = 0 }
    END { if (calls >= 1 && old == 0) print "ok"; else print "bad: calls=" calls+0 " old-parse=" old+0 }
  ' "$svc")
  [ "$a" = ok ] || { echo "  FAIL  getApp: $a (want StoreSignerPin.fromFetchReply( and no tok.length >= 3)" >&2; return 1; }
  b=$(awk '
    /static String installStaged\(/ { in_m = 1 }
    in_m && /^        try \{/ && !tr { tr = NR }
    in_m && /if \(signerHex == null\)/ && !nl { nl = NR }
    in_m && nl && !rt && /return FAIL;/ { rt = NR }
    in_m && /if \(wantSigner\.isEmpty\(\)\)/ && !em { em = NR }
    in_m && em && !ns && /return NOSIGNER;/ { ns = NR }
    in_m && /!wantSigner\.isEmpty\(\)/ { guard++ }
    in_m && /createSession\(/ && !cs { cs = NR }
    in_m && /^        } finally \{/ { fin = NR }
    in_m && /rmTree\(dir\)/ { rm = NR }
    in_m && /^    }$/ { in_m = 0 }
    END {
      if (tr && nl && rt && cs && tr < nl && nl < rt && rt - nl <= 3 && rt < cs && fin > cs && rm > fin \
          && em > rt && ns > em && ns - em <= 4 && ns < cs && guard == 0) print "ok"
      else print "bad: try=" tr+0 " null=" nl+0 " return=" rt+0 " empty=" em+0 " NOSIGNER=" ns+0 " guard=" guard+0 " createSession=" cs+0 " finally=" fin+0 " rmTree=" rm+0
    }
  ' "$ins")
  [ "$b" = ok ] || { echo "  FAIL  installStaged: $b (want try < if (signerHex == null) return FAIL < if (wantSigner.isEmpty()) return NOSIGNER < createSession < finally rmTree, no !wantSigner.isEmpty() guard)" >&2; return 1; }
  c=$(awk '
    /public String getApp\(/ { in_m = 1 }
    in_m && /StoreInstaller\.NOSIGNER\.equals\(verdict\)\) return "ERR-NOSIGNER";/ { m = NR }
    in_m && /!StoreInstaller\.OK\.equals\(verdict\)\) return "ERR-INSTALL";/ { g = NR }
    in_m && /^        }$/ { in_m = 0 }
    END { if (m && g && m < g) print "ok"; else print "bad: NOSIGNER-map=" m+0 " ERR-INSTALL=" g+0 }
  ' "$svc")
  [ "$c" = ok ] || { echo "  FAIL  getApp: $c (want NOSIGNER mapped to ERR-NOSIGNER before the ERR-INSTALL mapping)" >&2; return 1; }
  c=$(awk '
    /private void onGet\(/ { in_m = 1 }
    in_m && /"ERR-NOSIGNER"\.equals\(r\)/ { b = NR }
    in_m && b && /its store entry names no publisher signature to check it against, so it isn.t installed\./ { t = NR }
    in_m && /Name the cause the daemon gave/ { g = NR }
    in_m && /^    }$/ { in_m = 0 }
    END { if (b && t && g && b < t && t < g) print "ok"; else print "bad: branch=" b+0 " text=" t+0 " generic=" g+0 }
  ' "$nap")
  [ "$c" = ok ] || { echo "  FAIL  onGet: $c (want an ERR-NOSIGNER branch with the reason text before the generic else)" >&2; return 1; }
  return 0
}

echo "== $SUT"
ok=yes
suite "$SUT" || ok=no
sources "$SERVICE" "$INSTALLER" "$NAPPS" || ok=no
[ "$ok" = yes ] || { echo "FAILED"; exit 1; }
echo "ok: cases + source check"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile proves nothing)"
mut() { # mut <label> <file: pin|installer|service|napps> <perl-expr>
  local d c rc orig
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    pin) orig="$SUT"; c="$d/StoreSignerPin.java" ;;
    service) orig="$SERVICE"; c="$d/StoreService.java" ;;
    napps) orig="$NAPPS"; c="$d/StoreActivity.java" ;;
    *) orig="$INSTALLER"; c="$d/StoreInstaller.java" ;;
  esac
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  if [ "$2" = pin ]; then suite "$c" >/dev/null 2>&1; rc=$?
  else
    case "$2" in
      service) sources "$c" "$INSTALLER" "$NAPPS" >/dev/null 2>&1; rc=$? ;;
      napps) sources "$SERVICE" "$INSTALLER" "$c" >/dev/null 2>&1; rc=$? ;;
      *) sources "$SERVICE" "$c" "$NAPPS" >/dev/null 2>&1; rc=$? ;;
    esac
  fi
  rm -rf "$d"
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "the exactly-three-tokens check dropped" pin 's/tok\.length != 3/tok.length < 2/' || fails=$((fails+1))
mut "the package comparison dropped"         pin 's/if \(!tok\[1\]\.equals\(pkg\)\) return null;//' || fails=$((fails+1))
mut "\"-\" mapped to null"                   pin 's/if \("-"\.equals\(tok\[2\]\)\) return "";/if ("-".equals(tok[2])) return null;/' || fails=$((fails+1))
mut "the hex check dropped"                  pin 's/if \(!isHex64\(tok\[2\]\)\) return null;//' || fails=$((fails+1))
mut "the lowercasing dropped"                pin 's/return tok\[2\]\.toLowerCase\(java\.util\.Locale\.ROOT\);/return tok[2];/' || fails=$((fails+1))
mut "the OK comparison made a prefix test"   pin 's/!"OK"\.equals\(tok\[0\]\)/!tok[0].startsWith("OK")/' || fails=$((fails+1))
mut "installStaged maps a null pin to \"\""  installer 's/if \(signerHex == null\) \{.*?\n            \}\n            String wantSigner = signerHex\.trim\(\);/String wantSigner = signerHex == null ? "" : signerHex.trim();/s' || fails=$((fails+1))
mut "S1 the empty-signer arm deleted" installer 's/            if \(wantSigner\.isEmpty\(\)\) \{.*?return NOSIGNER;\n            \}\n//s' || fails=$((fails+1))
mut "S2 the !wantSigner.isEmpty() guard restored" installer 's/if \(wantSigner\.length\(\) != 64 \|\| !stagedSignerMatches\(ctx, apks\.get\(0\), wantSigner\)\) \{/if (!wantSigner.isEmpty() \&\& (wantSigner.length() != 64 || !stagedSignerMatches(ctx, apks.get(0), wantSigner))) {/' || fails=$((fails+1))
mut "S3 the empty-signer arm moved after createSession" installer 's/(            if \(wantSigner\.isEmpty\(\)\) \{.*?return NOSIGNER;\n            \}\n)(.*?sid = pi\.createSession\(p\);\n)/$2$1/s' || fails=$((fails+1))
mut "S4 getApp's NOSIGNER mapping deleted" service 's/ *if \(StoreInstaller\.NOSIGNER\.equals\(verdict\)\) return "ERR-NOSIGNER";\n//' || fails=$((fails+1))
mut "S5 the nApps ERR-NOSIGNER branch deleted" napps 's/\} else if \("ERR-NOSIGNER"\.equals\(r\)\) \{.*?(\} else \{\n *\/\/ Name the cause)/$1/s' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
