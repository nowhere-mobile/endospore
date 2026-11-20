#!/usr/bin/env bash
# test-push-gateway.sh [--mutate] -- NWP-20261203-13: NowherePush reads the gateway nowhere_login.sh publishes.
# PushService.gatewayBase read persist.nowhere.gateway_url, which nothing set, so every image (a beta ring too) minted push
# endpoints on the production gateway. Now nowhere_login.sh publishes nowhere.gateway_url at boot from the merged conf by
# the agent's own rule (issueGatewayURL: GATEWAY_URL, else NOWHERE_GATEWAY_DEFAULT), sepolicy labels it
# nowhere_gateway_prop (set by the nowhere domain, read by platform_app), and PushService reads it, prod only when unset.
#
# Cases:
#   (a) GATEWAY_PROP, DEFAULT_GATEWAY and gatewayFrom are lifted VERBATIM (by signature) into a harness run under a real
#       JVM: a1 "" -> the prod default, a2 null -> the prod default, a3 the beta host -> itself, a4 one trailing "/" ->
#       stripped, a5 GATEWAY_PROP is nowhere.gateway_url; a6 (source pin) gatewayBase's body reads GATEWAY_PROP through
#       gatewayFrom and names no persist. property.
#   (b) nowhere_login.sh is EXECUTED as test-launcher-env.sh does (absolute paths rewritten into a temp root, a stub
#       agent, an empty environment) with a setprop stub that logs its argv, under each of sh, dash and mksh found:
#       b1 ring GATEWAY_URL=beta -> setprop beta; b2 ring NOWHERE_GATEWAY_DEFAULT=beta -> beta; b3 ring default=beta and
#       device conf GATEWAY_URL=X -> X only; b4 a conf with no gateway key -> no nowhere.gateway_url call at all; b5 no
#       conf -> no call.
#   (c) sepolicy, each matched as a whole line: c1 the property_contexts label, c2 system_public_prop, c3 set_prop for
#       the nowhere domain, c4 the file read for platform_app; c5 the same read for platform_app_all in the Endospore
#       delta (editions/endospore/vendor/sepolicy/endospore.te): GrapheneOS runs a platform app in a per-SDK domain
#       (platform_app_36), which c4's rule does not cover (NWP-20261117-47).
# Mutants (--mutate), each CONVICTED by its named assertion (launcher mutants under every shell found):
#   G1 the property name back to persist.nowhere.gateway_url (a5); G2 gatewayFrom always returns DEFAULT_GATEWAY (a3);
#   G3 the slash strip removed (a4); G4 the login.sh setprop line removed (b1); G5 precedence swapped (b3); G6 the
#   non-empty guard removed (b4); G7 the property_contexts line removed (c1); G8 set_prop removed (c3); G9 the
#   platform_app read removed (c4); G10 the Endospore platform_app_all read removed (c5).
# On origin/main (a) prints EXTRACTION FAILED (no gatewayFrom), b1-b3 FAIL (no setprop call) and c1-c4 FAIL.
#
# Needs a JDK and FAILS (exit 2) without one: javac/java from PATH, then the build VM's prebuilt JDK 21.
#   bash test-push-gateway.sh            # the cases
#   bash test-push-gateway.sh --mutate   # ... plus mutants G1-G9
# PUSH_SERVICE_SRC, LOGIN_SH_SRC, SEPOLICY_DIR and ENDOSPORE_TE override the files under test.
# Exit: 0 pass, 1 a case failed, 2 cannot run (no JDK, EXTRACTION FAILED), 3 the harness does not compile.
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SRC=${PUSH_SERVICE_SRC:-$ROOT/core/pushd/src/com/nowhere/push/PushService.java}
LOGIN=${LOGIN_SH_SRC:-$ROOT/core/vendor-common/bin/nowhere_login.sh}
SEPOL=${SEPOLICY_DIR:-$ROOT/core/vendor-common/sepolicy}
ENDO=${ENDOSPORE_TE:-$ROOT/editions/endospore/vendor/sepolicy/endospore.te}
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-push-gateway: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

BETA=https://api-beta.nowhere.mobile
PROD=https://api.nowhere.mobile
OTHER=https://gw.example.test

lift(){ # lift <signature prefix> <file>: from the signature line to the first 4-space-indented closing brace
  awk -v sig="$1" 'index($0,sig)==1{p=1} p{print} p&&$0=="    }"{exit}' "$2"
}

# java_cases <PushService.java> -> 0 pass, 1 a case failed, 2 EXTRACTION FAILED, 3 no compile
java_cases(){
  local src=$1 d consts fn base out rc=0
  consts=$(grep -E '^    (private )?static final String (GATEWAY_PROP|DEFAULT_GATEWAY) = ' "$src")
  fn=$(lift '    static String gatewayFrom(String prop)' "$src")
  base=$(lift '    private String gatewayBase()' "$src")
  case "$consts" in *GATEWAY_PROP*) ;; *) echo "EXTRACTION FAILED: GATEWAY_PROP"; rc=2 ;; esac
  case "$consts" in *DEFAULT_GATEWAY*) ;; *) echo "EXTRACTION FAILED: DEFAULT_GATEWAY"; rc=2 ;; esac
  [ -n "$fn" ] || { echo "EXTRACTION FAILED: gatewayFrom"; rc=2; }
  [ -n "$base" ] || { echo "EXTRACTION FAILED: gatewayBase"; rc=2; }
  if [ -n "$base" ]; then
    case "$base" in
      *'SystemProperties.get(GATEWAY_PROP, "")'*) ;;
      *) echo "FAIL a6: gatewayBase does not read SystemProperties.get(GATEWAY_PROP, \"\")"; [ "$rc" = 0 ] && rc=1 ;;
    esac
    case "$base" in
      *'gatewayFrom('*) ;;
      *) echo "FAIL a6: gatewayBase does not return through gatewayFrom"; [ "$rc" = 0 ] && rc=1 ;;
    esac
    case "$base" in
      *persist.*) echo "FAIL a6: gatewayBase still names a persist. property"; [ "$rc" = 0 ] && rc=1 ;;
    esac
  fi
  [ "$rc" = 2 ] && return 2
  d=$(mktemp -d -p "$W")
  {
    echo 'public class GwHarness {'
    printf '%s\n' "$consts"
    printf '%s\n' "$fn"
    cat <<J
    static int fails = 0;
    static void eq(String id, String want, String got) {
        if (!want.equals(got)) { System.out.println("FAIL " + id + ": " + want + " vs " + got); fails++; }
    }
    public static void main(String[] a) {
        eq("a1", "$PROD", gatewayFrom(""));
        eq("a1", DEFAULT_GATEWAY, gatewayFrom(""));
        eq("a2", "$PROD", gatewayFrom(null));
        eq("a3", "$BETA", gatewayFrom("$BETA"));
        eq("a4", "$BETA", gatewayFrom("$BETA/"));
        eq("a5", "nowhere.gateway_url", GATEWAY_PROP);
        System.exit(fails == 0 ? 0 : 1);
    }
}
J
  } >"$d/GwHarness.java"
  if ! out=$("$JAVAC" -J-XX:-UsePerfData -J-Djava.io.tmpdir="$W" -d "$d" "$d/GwHarness.java" 2>&1); then
    printf '%s\n' "$out"; echo "HARNESS DOES NOT COMPILE"; return 3
  fi
  out=$("$JAVA" -XX:-UsePerfData -Djava.io.tmpdir="$W" -cp "$d" GwHarness 2>&1) || { [ "$rc" = 0 ] && rc=1; }
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# login_case <login.sh> <shell> <id> <ring conf body or -> <device conf body or -> <expected value or ->
login_case(){
  local src=$1 sh=$2 id=$3 ring=$4 dev=$5 want=$6 root script log lines n
  root=$(mktemp -d -p "$W")
  mkdir -p "$root/sys" "$root/sysfs" "$root/data/nowhere/state" "$root/stub" "$root/stubbin" "$root/run"
  [ "$ring" = - ] || printf '%s\n' "$ring" >"$root/sys/nowhere.conf"
  [ "$dev" = - ] || printf '%s\n' "$dev" >"$root/data/nowhere/nowhere.conf"
  printf '#!/bin/sh\nexit 0\n' >"$root/stub/nowhere_agent"
  printf '#!/bin/sh\necho "$*" >> "%s/setprop.log"\nexit 0\n' "$root" >"$root/stubbin/setprop"
  printf '#!/bin/sh\necho "default via 10.0.0.1 dev wlan0"\n' >"$root/stubbin/ip"
  printf '#!/bin/sh\nexit 0\n' >"$root/stubbin/sleep"
  chmod +x "$root/stub/nowhere_agent" "$root/stubbin/"*
  script=$root/run/login.sh
  sed -e "s@/sys/@__SYSFS__/@g" \
      -e "s@/system/etc/nowhere@$root/sys@g" \
      -e "s@/system/bin/nowhere_agent@$root/stub/nowhere_agent@g" \
      -e "s@/data/@$root/data/@g" \
      -e "s@__SYSFS__@$root/sysfs@g" \
      "$src" >"$script"
  ( cd "$root" && env -i PATH="$root/stubbin:/usr/bin:/bin" timeout 60 "$sh" "$script" ) >"$root/out" 2>&1
  log=
  [ -f "$root/setprop.log" ] && log=$(cat "$root/setprop.log")
  lines=$(printf '%s\n' "$log" | grep -E '^nowhere\.gateway_url( |$)')
  n=0; [ -n "$lines" ] && n=$(printf '%s\n' "$lines" | wc -l)
  if [ "$want" = - ]; then
    if [ "$n" -ne 0 ]; then echo "FAIL $id ($sh): setprop was called for nowhere.gateway_url: [$lines]"; return 1; fi
  elif [ "$n" -ne 1 ] || [ "$lines" != "nowhere.gateway_url $want" ]; then
    echo "FAIL $id ($sh): want exactly [nowhere.gateway_url $want], got [$lines]"; return 1
  fi
  return 0
}

shells(){
  local s p
  for s in sh dash mksh; do p=$(command -v "$s" 2>/dev/null) && echo "$p"; done
}

# login_cases <login.sh> [shell...] -> 0 pass, 1 a case failed
login_cases(){
  local src=$1 sh rc=0; shift
  for sh in "$@"; do
    login_case "$src" "$sh" b1 "GATEWAY_URL=$BETA" - "$BETA" || rc=1
    login_case "$src" "$sh" b2 "NOWHERE_GATEWAY_DEFAULT=$BETA" - "$BETA" || rc=1
    login_case "$src" "$sh" b3 "NOWHERE_GATEWAY_DEFAULT=$BETA" "GATEWAY_URL=$OTHER" "$OTHER" || rc=1
    login_case "$src" "$sh" b4 "S3_BUCKET=x" - - || rc=1
    login_case "$src" "$sh" b5 - - - || rc=1
  done
  return "$rc"
}

# sepol_cases <sepolicy dir> -> 0 pass, 1 a case failed
sepol_cases(){
  local d=$1 rc=0 endo
  endo=$ENDO; [ -f "$d/endospore.te" ] && endo=$d/endospore.te  # a mutant's copy, else the tree's delta
  grep -qxE 'nowhere\.gateway_url[[:space:]]+u:object_r:nowhere_gateway_prop:s0' "$d/property_contexts" \
    || { echo "FAIL c1: property_contexts does not label nowhere.gateway_url nowhere_gateway_prop"; rc=1; }
  grep -qxF 'system_public_prop(nowhere_gateway_prop)' "$d/nowhere.te" \
    || { echo "FAIL c2: nowhere.te has no system_public_prop(nowhere_gateway_prop)"; rc=1; }
  grep -qxF 'set_prop(nowhere, nowhere_gateway_prop)' "$d/nowhere.te" \
    || { echo "FAIL c3: nowhere.te has no set_prop(nowhere, nowhere_gateway_prop)"; rc=1; }
  grep -qxF 'allow platform_app nowhere_gateway_prop:file { read open getattr map };' "$d/nowhere.te" \
    || { echo "FAIL c4: nowhere.te has no file read of nowhere_gateway_prop for platform_app"; rc=1; }
  grep -qxF 'allow platform_app_all nowhere_gateway_prop:file { read open getattr map };' "$endo" \
    || { echo "FAIL c5: endospore.te has no file read of nowhere_gateway_prop for platform_app_all"; rc=1; }
  return "$rc"
}

SHELLS=$(shells)
# shellcheck disable=SC2086
echo "test-push-gateway: shells:" $SHELLS
"$JAVAC" -J-XX:-UsePerfData -version 2>&1 | sed 's/^/using /'

# all_cases <PushService.java> <login.sh> <sepolicy dir>: every case, even when (a) cannot extract
all_cases(){
  local rc=0 r
  java_cases "$1"; r=$?; [ "$r" -gt "$rc" ] && rc=$r
  # shellcheck disable=SC2086
  login_cases "$2" $SHELLS || { [ "$rc" = 0 ] && rc=1; }
  sepol_cases "$3" || { [ "$rc" = 0 ] && rc=1; }
  return "$rc"
}

out=$(all_cases "$SRC" "$LOGIN" "$SEPOL"); rc=$?
[ -n "$out" ] && printf '%s\n' "$out"
if [ "$rc" != 0 ]; then echo "test-push-gateway: FAIL (exit $rc)"; exit "$rc"; fi
echo "test-push-gateway: PASS (a1-a6, b1-b5 per shell, c1-c5)"
[ "$MUTATE" = yes ] || exit 0

# ---- mutants ----
MFAIL=0
# copy_sepol -> a fresh dir holding the sepolicy dir's two files and the Endospore delta (as endospore.te)
copy_sepol(){
  local d
  d=$(mktemp -d -p "$W")
  cp "$SEPOL/property_contexts" "$SEPOL/nowhere.te" "$d/"
  cp "$ENDO" "$d/endospore.te"
  echo "$d"
}
# sepol_src <file name> -> the original that copy_sepol copied it from
sepol_src(){ if [ "$1" = endospore.te ]; then echo "$ENDO"; else echo "$SEPOL/$1"; fi; }
# applied <orig> <copy> <id>: the mutant must change the file
applied(){
  if cmp -s "$1" "$2"; then echo "MUTANT DID NOT APPLY: $3"; MFAIL=1; return 1; fi
  return 0
}
# convict <id> <assertion> <output> <rc> [shell]
convict(){
  local id=$1 as=$2 o=$3 r=$4 sh=${5:-}
  local tag=$as; [ -n "$sh" ] && tag="$as ($sh"
  case "$o" in
    *"FAIL $tag"*) if [ "$r" != 0 ]; then echo "CONVICTED: $id by $as${sh:+ ($sh)}"; return 0; fi ;;
  esac
  echo "SURVIVED: $id (no FAIL $as${sh:+ under $sh}, exit $r)"; MFAIL=1
}
# java_mutant <id> <assertion> <awk program applied to PushService.java>
java_mutant(){
  local id=$1 as=$2 prog=$3 m o r
  m=$(mktemp -p "$W")
  awk "$prog" "$SRC" >"$m"
  applied "$SRC" "$m" "$id" || return 0
  o=$(java_cases "$m"); r=$?
  convict "$id" "$as" "$o" "$r"
}
# login_mutant <id> <assertion> <awk program applied to nowhere_login.sh>
login_mutant(){
  local id=$1 as=$2 prog=$3 m o r sh
  m=$(mktemp -p "$W")
  awk "$prog" "$LOGIN" >"$m"
  applied "$LOGIN" "$m" "$id" || return 0
  for sh in $SHELLS; do
    o=$(login_cases "$m" "$sh"); r=$?
    convict "$id" "$as" "$o" "$r" "$sh"
  done
}
# sepol_mutant <id> <assertion> <file> <exact line to delete>
sepol_mutant(){
  local id=$1 as=$2 f=$3 line=$4 d o r
  d=$(copy_sepol)
  awk -v l="$line" '$0!=l' "$(sepol_src "$f")" >"$d/$f.m" && mv "$d/$f.m" "$d/$f"
  applied "$(sepol_src "$f")" "$d/$f" "$id" || return 0
  o=$(sepol_cases "$d"); r=$?
  convict "$id" "$as" "$o" "$r"
}

java_mutant G1 a5 '{gsub(/= "nowhere\.gateway_url"/, "= \"persist.nowhere.gateway_url\"")} {print}'
java_mutant G2 a3 'index($0,"    static String gatewayFrom(String prop)")==1{print; print "        return DEFAULT_GATEWAY;"; print "    }"; s=1; next}
  s&&$0=="    }"{s=0; next} s{next} {print}'
java_mutant G3 a4 'index($0,"    static String gatewayFrom(String prop)")==1{s=1}
  s&&index($0,"return base.endsWith(\"/\")"){print "        return base;"; s=0; next} {print}'
login_mutant G4 b1 '!/setprop nowhere\.gateway_url/'
login_mutant G5 b3 '{gsub(/\$\{GATEWAY_URL:-\$NOWHERE_GATEWAY_DEFAULT\}/, "${NOWHERE_GATEWAY_DEFAULT:-$GATEWAY_URL}")} {print}'
login_mutant G6 b4 '$0 ~ /^  if \[ -n "\$_nwgw" \]; then setprop nowhere\.gateway_url "\$_nwgw"; fi$/ {print "  setprop nowhere.gateway_url \"$_nwgw\""; next} {print}'
sepol_mutant G7 c1 property_contexts 'nowhere.gateway_url            u:object_r:nowhere_gateway_prop:s0'
sepol_mutant G8 c3 nowhere.te 'set_prop(nowhere, nowhere_gateway_prop)'
sepol_mutant G9 c4 nowhere.te 'allow platform_app nowhere_gateway_prop:file { read open getattr map };'
sepol_mutant G10 c5 endospore.te 'allow platform_app_all nowhere_gateway_prop:file { read open getattr map };'

if [ "$MFAIL" != 0 ]; then echo "test-push-gateway: --mutate FAIL (a mutant survived or did not apply)"; exit 1; fi
echo "test-push-gateway: --mutate PASS (G1-G10 convicted)"
