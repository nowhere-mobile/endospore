#!/usr/bin/env bash
# test-wifi-netmatch-java.sh [--mutate] -- the gate's Wi-Fi join matches a saved network on SSID AND security type,
# run under javac (NWP-20261116-18, docs/wifi-retention-spec.md §5 F2).
#
# WHY THIS IS COMMITTED. When addNetwork refused a duplicate, connectWifi reused the FIRST saved config with the
# same SSID, whatever its security type, then rewrote it with the new config and enabled it. Android keys a config
# on (SSID, security type), so with an open "Cafe" and a WPA2 "Cafe" saved, a join of the WPA2 one overwrote the
# open one. The match now lives in WifiNetMatch, a pure class with no android.* import, compiled here with its
# cases. A source guard checks that connectWifi's fallback goes through findNet, that findNet reads every
# key-management bit, and that the mirror adopt keeps existingNetId (the mirror line carries no security type).
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-wifi-netmatch-java.sh            # the cases + source guard
#   bash test-wifi-netmatch-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src"
COPY="$SRC/com/nowhere/chooser/WifiNetMatch.java"
ACT="$SRC/com/nowhere/chooser/ChooserActivity.java"
CASES="$root/core/chooser/tests/wifi-netmatch/WifiNetMatchCases.java"
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

# guard <ChooserActivity.java> -> 0 clean, 1 a guard failed. Output is captured into variables (no pipe into grep -q).
guard() {
  local act="$1" bad=0 cw mirror fn n k
  # G-a: connectWifi's already-saved fallback goes through findNet with the join's own security type.
  cw=$(perl -0ne 'print $1 if /(    private String connectWifi\(String ssid, String pw, String identity.*?)\n    (?:private |\/\*\*)/s' "$act")
  if [ -z "$cw" ]; then echo "  GUARD could not extract the 6-argument connectWifi's body" >&2; bad=1
  else
    n=$(printf '%s\n' "$cw" | grep -c -F 'findNet(wm, ssid, WifiNetMatch.joinSec(pw, identity))')
    [ "$n" = 1 ] || { echo "  GUARD connectWifi calls findNet(wm, ssid, WifiNetMatch.joinSec(pw, identity)) $n times, want exactly 1" >&2; bad=1; }
    n=$(printf '%s\n' "$cw" | grep -c -F 'existingNetId(')
    [ "$n" = 0 ] || { echo "  GUARD connectWifi still calls existingNetId( ($n times): it matches SSID alone" >&2; bad=1; }
  fi
  # G-b (control): the mirror adopt keeps existingNetId, so the search sees the source.
  mirror=$(perl -0ne 'print $1 if /(    void maybeMirrorWifi\(\) \{.*?\n    \}\n)/s' "$act")
  if [ -z "$mirror" ]; then echo "  GUARD control: could not extract maybeMirrorWifi's body" >&2; bad=1
  else
    n=$(printf '%s\n' "$mirror" | grep -c -F 'existingNetId(wm, e[0])')
    [ "$n" -ge 1 ] || { echo "  GUARD control: maybeMirrorWifi no longer calls existingNetId(wm, e[0])" >&2; bad=1; }
  fi
  # G-c: findNet reads every key-management bit secOf needs, and decides through WifiNetMatch.
  fn=$(perl -0ne 'print $1 if /(    private int findNet\(.*?\n    \}\n)/s' "$act")
  if [ -z "$fn" ]; then echo "  GUARD could not extract findNet's body" >&2; bad=1
  else
    for k in KeyMgmt.WPA_EAP KeyMgmt.IEEE8021X KeyMgmt.SUITE_B_192 KeyMgmt.WPA_PSK KeyMgmt.SAE 'WifiNetMatch.secOf(' 'WifiNetMatch.find('; do
      n=$(printf '%s\n' "$fn" | grep -c -F "$k")
      [ "$n" -ge 1 ] || { echo "  GUARD findNet does not read $k" >&2; bad=1; }
    done
  fi
  return "$bad"
}

# suite <WifiNetMatch.java> <ChooserActivity.java> -> 0 pass, 1 a case or guard failed (the only code that convicts
# a mutant), 3 the class or the cases did not compile.
suite() {
  local copy="$1" act="$2" d out rc bad=0
  guard "$act" || bad=1
  [ -f "$copy" ] || { echo "  FAIL  WifiNetMatch.java does not exist" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$copy" "$d/src/com/nowhere/chooser/WifiNetMatch.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/WifiNetMatchCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.WifiNetMatchCases 2>&1); rc=$?
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
  local d c a rc target; d=$(mktemp -d -p "$W"); c="$d/WifiNetMatch.java"; a="$d/ChooserActivity.java"
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
mut "N1 find ignores sec"                         copy 's/ && sec\.equals\(e\[1\]\)//' || fails=$((fails+1))
mut "N2 secOf tests sae before psk"               copy 's/(        if \(psk\) return "psk";\n)(        if \(sae\) return "sae";\n)/$2$1/' || fails=$((fails+1))
mut "N3 secOf never returns eap"                  copy 's/        if \(eap\) return "eap";\n//' || fails=$((fails+1))
mut "N4 joinSec gives psk for an empty pw"        copy 's/if \(pw == null \|\| pw\.isEmpty\(\)\) return "open";/if (pw == null) return "open";/' || fails=$((fails+1))
mut "N5 connectWifi's fallback on existingNetId"  act  's/findNet\(wm, ssid, WifiNetMatch\.joinSec\(pw, identity\)\)/existingNetId(wm, ssid)/' || fails=$((fails+1))
mut "N6 joinSec ignores identity"                 copy 's/        if \(identity != null && !identity\.isEmpty\(\)\) return "eap";\n//' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
