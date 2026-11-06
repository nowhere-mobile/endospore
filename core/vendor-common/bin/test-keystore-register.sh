#!/usr/bin/env bash
# test-keystore-register.sh [<nowhere_roamd.sh>] [--mutate] -- keystore_register's package -> namespace mapping.
#
# WHY THIS IS COMMITTED. keystore_register resolves an app's keystore namespace from
# `pm list packages -U -a --user N | grep -F "package:$_p uid:" | head -1 | sed`, rejects an empty or
# non-numeric answer, appends "<ns> <pkg>" to KS_MAP if absent, and moves KS_IN/<pkg>.keys to
# KS_IMPORT/<ns>.keys. If that match ever widens (com.foo against com.foo.bar, a regex dot, the wrong uid)
# one app is handed ANOTHER app's credentials. No branch of it had ever run off-device: the suites that
# mention it only stub it or grep it.
#
# This lifts keystore_unit, keystore_register and keystore_register_all out of roamd BY NAME and runs the
# real bodies against a temp root, with pm / chown / restorecon / chmod stubbed. Only the two device paths
# (/data/nowhere/unit-id and /data/misc/keystore) are rewritten, and the rewrite must change exactly 4
# lines or the suite stops. KS_MAP/KS_IN/KS_IMPORT/KS_UNIT are top-level assignments in roamd, so the
# harness simply defines them.
#
# NWP-20261112-01 (P1): restored bundles live at KS_IN/<uid>/<pkg>.keys (ks_in_dir, lifted too) and only THIS
# user's are promoted, so a bundle another user's sign-in restored is never moved into this user's apps.
#
# The cases run once under EACH shell found (bash and sh always, mksh and dash when installed; mksh is the
# device's /system/bin/sh), and every mutant must be convicted under each shell on its own run.
#
#   bash test-keystore-register.sh               # the cases, under every shell found
#   bash test-keystore-register.sh --mutate      # ... plus mutations that must each CONVICT, per shell
#   bash test-keystore-register.sh --shell=mksh  # the cases under one shell only
#
set -uo pipefail

MUTATE=no; SUT=""; ONLY=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --shell=*) ONLY="${a#--shell=}" ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT   # every run root and mutant copy is made inside it

if [ -n "$ONLY" ]; then
  command -v "$ONLY" >/dev/null 2>&1 || { echo "no such shell: $ONLY" >&2; exit 2; }
  SHELLS="$ONLY"
else
  SHELLS="bash sh"
  for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
fi

PASS=0; FAIL=0; SH=""
ok(){ PASS=$((PASS+1)); printf '  ok    [%s] %s\n' "$SH" "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  [%s] %s\n' "$SH" "$1"; }

# --- extraction: the four functions, by name -------------------------------------------------------------
FUNCS=""
for fn in keystore_unit keystore_register_all keystore_register ks_in_dir; do
  body=$(sed -n "/^$fn() {\$/,/^}\$/p" "$SUT")
  case "$body" in
    "$fn() {"*) FUNCS="$FUNCS$body"$'\n' ;;
    *) echo "EXTRACTION FAILED -- $fn not found in $SUT" >&2; exit 2 ;;
  esac
done
REWRITTEN=$(printf "%s\n" "$FUNCS" \
  | sed -e 's#/data/nowhere/unit-id#$T/nowhere/unit-id#g' -e 's#/data/misc/keystore#$T/keystore#g')
changed=$(diff <(printf '%s\n' "$FUNCS") <(printf '%s\n' "$REWRITTEN") | grep -c '^>')
[ "$changed" = 4 ] || { echo "EXTRACTION FAILED -- path rewrite changed $changed lines, want 4 ($SUT)" >&2; exit 2; }

# --- harness ----------------------------------------------------------------------------------------------
# run <fixture> <body>: runs under $SH. fixture is the stubbed `pm list packages` output; body runs after the functions are
# defined, with $T the temp root. The body's stdout is returned. The sweep's log line, if the body wrote
# one, follows on a line of its own as "sweep: <line>" (nothing is added when the sweep did not run).
run(){
  local T; T=$(mktemp -d -p "$W")
  mkdir -p "$T/nowhere" "$T/keystore" "$T/in/10"
  printf '%b' "$1" > "$T/fixture"
  {
    echo "T='$T'; LOG=\"\$T/log\"; uid=10; : > \"\$LOG\""
    echo 'KS_MAP=$T/nowhere/keystore-map; KS_IN=$T/in; KS_IMPORT=$T/keystore/nowhere-import'
    echo 'KS_UNIT=$T/keystore/nowhere-unit-id'
    echo 'pm(){ cat "$T/fixture"; }; chown(){ :; }; restorecon(){ :; }; chmod(){ :; }'
    printf '%s\n' "$REWRITTEN"
    echo "$2"
  } > "$T/run.sh"
  "$SH" "$T/run.sh" 2>/dev/null
  local sw; sw=$(grep -o 'keystore sweep registered.*unresolvable)' "$T/log" 2>/dev/null)
  [ -z "$sw" ] || printf 'sweep: %s\n' "$sw"
  rm -rf "$T"
}
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2], want [$3]"; }

cases(){
echo "== prefix: com.foo must not take com.foo.bar's uid =="
FIX='package:com.foo.bar uid:10100\npackage:com.foo uid:10200\n'
OUT=$(run "$FIX" 'echo K1 > $KS_IN/10/com.foo.keys; echo K2 > $KS_IN/10/com.foo.bar.keys
  keystore_register com.foo; echo "rc=$?"
  echo "foo=$(cat $KS_IMPORT/10200.keys 2>&1)"; echo "left=$(ls $KS_IN/10 | tr "\n" " ")"
  echo "map=$(cat $KS_MAP | tr "\n" ";")"')
case "$OUT" in *"rc=0"*) ok "com.foo registers (rc 0)" ;; *) no "com.foo registers -- $OUT" ;; esac
case "$OUT" in *"foo=K1"*) ok "com.foo's bundle lands at 10200.keys" ;; *) no "com.foo's bundle lands at 10200.keys -- $OUT" ;; esac
case "$OUT" in *"map=10200 com.foo;"*) ok "KS_MAP maps com.foo to 10200 only" ;; *) no "KS_MAP maps com.foo to 10200 only -- $OUT" ;; esac
case "$OUT" in *"left=com.foo.bar.keys "*) ok "com.foo.bar's bundle is untouched" ;; *) no "com.foo.bar's bundle is untouched -- $OUT" ;; esac
OUT=$(run "$FIX" 'echo K2 > $KS_IN/10/com.foo.bar.keys; keystore_register com.foo.bar
  echo "bar=$(cat $KS_IMPORT/10100.keys 2>&1)"')
case "$OUT" in *"bar=K2"*) ok "com.foo.bar's bundle lands at 10100.keys" ;; *) no "com.foo.bar's bundle lands at 10100.keys -- $OUT" ;; esac

echo "== a dotted name never regex-matches =="
OUT=$(run 'package:com.fooXbar uid:10300\n' 'echo K > $KS_IN/10/com.foo.bar.keys
  keystore_register com.foo.bar; echo "rc=$?"; ls $KS_IN/10; ls $KS_IMPORT; cat $KS_MAP 2>/dev/null')
is "com.foo.bar vs com.fooXbar: skipped, bundle stays, nothing mapped" "$OUT" $'rc=1\ncom.foo.bar.keys'

echo "== unresolvable: SKIPPED, returns 1, bundle stays in KS_IN =="
OUT=$(run 'package:com.foo uid:10200,10201\n' 'echo K > $KS_IN/10/com.foo.keys
  keystore_register com.foo; echo "rc=$?"; ls $KS_IN/10; ls $KS_IMPORT; cat $KS_MAP 2>/dev/null; cat $LOG')
case "$OUT" in "rc=1"$'\n'"com.foo.keys"$'\n'"[roamd] keystore register SKIPPED com.foo"*) ok "shared-uid list: skipped, bundle stays, nothing staged or mapped" ;; *) no "shared-uid list -- $OUT" ;; esac
OUT=$(run 'package:com.other uid:10200\n' 'echo K > $KS_IN/10/com.foo.keys
  keystore_register com.foo; echo "rc=$?"; ls $KS_IN/10; ls $KS_IMPORT; cat $LOG')
case "$OUT" in "rc=1"$'\n'"com.foo.keys"$'\n'"[roamd] keystore register SKIPPED com.foo"*) ok "package not listed: skipped, bundle stays" ;; *) no "package not listed -- $OUT" ;; esac

echo "== first listing wins (CONTRIVED: pm never lists a package twice; this pins head -1) =="
OUT=$(run 'package:com.foo uid:10100\npackage:com.foo uid:10200\n' 'keystore_register com.foo; cat $KS_MAP')
is "a package listed twice resolves to the first uid" "$OUT" "10100 com.foo"

echo "== a failed mv keeps the bundle and says so =="
OUT=$(run 'package:com.foo uid:10200\n' 'mv(){ return 1; }; echo K > $KS_IN/10/com.foo.keys
  keystore_register com.foo; echo "rc=$?"; ls $KS_IN/10; ls $KS_IMPORT; grep -c "keystore stage FAILED for com.foo: bundle kept" $LOG')
is "mv fails: bundle kept in KS_IN, nothing staged, FAILED logged" "$OUT" $'rc=0\ncom.foo.keys\n1'

echo "== an already-mapped ns is not appended twice =="
OUT=$(run 'package:com.foo uid:10200\n' 'echo "10200 com.foo" > $KS_MAP
  keystore_register com.foo; keystore_register com.foo; grep -c "^10200 " $KS_MAP')
is "pre-mapped ns, registered twice: one row" "$OUT" 1
OUT=$(run 'package:com.foo uid:10200\n' 'keystore_register com.foo; keystore_register com.foo; grep -c "^10200 " $KS_MAP')
is "unmapped ns, registered twice: one row" "$OUT" 1

echo "== keystore_register_all stages what resolves and leaves the rest =="
OUT=$(run 'package:com.foo.bar uid:10100\npackage:com.foo uid:10200\npackage:com.gone uid:10300\n' \
  'echo A > $KS_IN/10/com.foo.keys; echo B > $KS_IN/10/com.foo.bar.keys; echo C > $KS_IN/10/com.nope.keys
  keystore_register_all; echo "rc=$?"
  echo "left=$(ls $KS_IN/10 | tr "\n" " ")"; echo "imp=$(ls $KS_IMPORT | tr "\n" " ")"
  echo "foo=$(cat $KS_IMPORT/10200.keys)"; echo "bar=$(cat $KS_IMPORT/10100.keys)"
  echo "map=$(cat $KS_MAP | tr "\n" ";")"; ls $T/nowhere | tr "\n" " "')
case "$OUT" in *"rc=0"*) ok "_all returns 0" ;; *) no "_all returns 0 -- $OUT" ;; esac
case "$OUT" in *"left=com.nope.keys "*) ok "_all leaves the unresolvable bundle in KS_IN" ;; *) no "_all leaves the unresolvable bundle -- $OUT" ;; esac
case "$OUT" in *"imp=10100.keys 10200.keys "*) ok "_all stages exactly the resolvable bundles" ;; *) no "_all stages exactly the resolvable bundles -- $OUT" ;; esac
case "$OUT" in *"foo=A"*"bar=B"*) ok "_all keeps each bundle with its own ns" ;; *) no "_all keeps each bundle with its own ns -- $OUT" ;; esac
case "$OUT" in *"map=10100 com.foo.bar;10200 com.foo;10300 com.gone;"*) ok "_all maps every listed package once" ;; *) no "_all maps every listed package once -- $OUT" ;; esac
case "$OUT" in *"keystore-map.sweep"*) no "_all leaves its sweep temp file behind" ;; *) ok "_all leaves no sweep temp file" ;; esac

echo "== keystore_register_all counts the bundles keystore_register refused =="
SWEEP='keystore_register_all; echo "imp=$(ls $KS_IMPORT | tr "\n" " ")"'
OUT=$(run 'package:com.foo uid:10200\npackage:com.bar uid:10300\n' \
  'echo A > $KS_IN/10/com.foo.keys; echo B > $KS_IN/10/com.bar.keys; echo C > $KS_IN/10/com.nope.keys; '"$SWEEP")
case "$OUT" in *"imp=10200.keys 10300.keys "*) ok "two resolvable, one not: the resolvable two are staged" ;; *) no "two resolvable, one not: staged -- $OUT" ;; esac
case "$OUT" in *"sweep: keystore sweep registered 2 package(s) before teardown (1 unresolvable)") ok "two resolvable, one not: (1 unresolvable)" ;; *) no "two resolvable, one not: count -- $OUT" ;; esac
OUT=$(run 'package:com.foo uid:10200\npackage:com.bar uid:10300\n' \
  'echo A > $KS_IN/10/com.foo.keys; echo B > $KS_IN/10/com.bar.keys; '"$SWEEP")
case "$OUT" in *"sweep: keystore sweep registered 2 package(s) before teardown (0 unresolvable)") ok "all resolvable: (0 unresolvable)" ;; *) no "all resolvable: count -- $OUT" ;; esac
OUT=$(run 'package:com.other uid:10400\n' \
  'echo A > $KS_IN/10/com.foo.keys; echo B > $KS_IN/10/com.bar.keys; '"$SWEEP")
case "$OUT" in *"sweep: keystore sweep registered 1 package(s) before teardown (2 unresolvable)") ok "none resolvable, two bundles: (2 unresolvable)" ;; *) no "none resolvable: count -- $OUT" ;; esac

echo "== P1: only THIS user's restored bundles are promoted (NWP-20261112-01) =="
OUT=$(run 'package:com.ex.p uid:1010001\npackage:com.ex.r uid:1010002\n' \
  'echo P > $KS_IN/10/com.ex.p.keys; mkdir -p $KS_IN/11; echo R > $KS_IN/11/com.ex.r.keys
  keystore_register_all
  echo "imp=$(ls $KS_IMPORT | tr "\n" " ")"; echo "p=$(cat $KS_IMPORT/1010001.keys 2>&1)"
  echo "r11=$(cat $KS_IN/11/com.ex.r.keys 2>&1)"; echo "reg=$(grep -c "keystore registered com.ex.r " $LOG)"')
case "$OUT" in *"imp=1010001.keys "*) ok "P1 user 10's com.ex.p bundle, and only it, is moved to the import dir" ;; *) no "P1 user 10's bundle staged alone -- $OUT" ;; esac
case "$OUT" in *"p=P"*) ok "P1 it lands at its own ns" ;; *) no "P1 it lands at its own ns -- $OUT" ;; esac
case "$OUT" in *"r11=R"*) ok "P1 user 11's com.ex.r bundle stays in keystore-in/11" ;; *) no "P1 user 11's bundle stays -- $OUT" ;; esac
case "$OUT" in *"reg=0"*) ok "P1 user 11's bundle is never registered into user 10's apps" ;; *) no "P1 user 11's bundle is not registered -- $OUT" ;; esac
}

echo "shells: $SHELLS"
for SH in $SHELLS; do
  echo "#### shell: $SH"
  cases
done
SH=mutate

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate(){
    if ! sed "$2" "$SUT" > "$M/m.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/m.sh"; then no "MUTATION INERT: $1"; return; fi
    # One run PER shell: a single run sums failures across shells, so one shell's conviction would hide a
    # survivor on another. Only rc 1 with a FAIL line is a conviction; rc 2 is the harness, not the code.
    local s1 out rc
    for s1 in $SHELLS; do
      out=$(bash "$0" "$M/m.sh" --shell="$s1" 2>&1); rc=$?
      case "$rc:$out" in
        0:*) no "NOT CONVICTED [$s1]: $1 -- suite passes on broken code" ;;
        1:*"  FAIL  [$s1] "*) ok "convicted [$s1]: $1" ;;
        *) no "HARNESS ERROR (rc=$rc) [$s1], not a conviction: $1" ;;
      esac
    done
  }
  mutate "grep -F becomes a regex grep (dots match anything)" \
         's#grep -F "package:\$_p uid:"#grep "package:$_p uid:"#'
  mutate "the ' uid:' anchor is dropped from the pattern (com.foo matches com.foo.bar)" \
         's#grep -F "package:\$_p uid:"#grep -F "package:$_p"#'
  mutate "the non-numeric reject is dropped (a shared-uid list becomes a namespace)" \
         "s#case \"\$_ns\" in ''|\*\[!0-9\]\*)#case \"\$_ns\" in '')#"
  mutate "head -1 becomes tail -1 (the contrived duplicate listing)" \
         's#| grep -F "package:\$_p uid:" | head -1 |#| grep -F "package:$_p uid:" | tail -1 |#'
  mutate "the dedupe '|| echo' becomes '; echo' (KS_MAP grows a row per call)" \
         's#"\$KS_MAP" 2>/dev/null || echo "\$_ns \$_p"#"$KS_MAP" 2>/dev/null; echo "$_ns $_p"#'
  mutate "the promote loop throws the status away again ('|| :')" \
         's#"\$_kns" batch >/dev/null 2>&1 || _nskip=\$((_nskip+1))#"$_kns" batch >/dev/null 2>\&1 || :#'
  mutate "the promote loop counts every call, resolved or not" \
         's#"\$_kns" batch >/dev/null 2>&1 || _nskip=\$((_nskip+1))#"$_kns" batch >/dev/null 2>\&1; _nskip=$((_nskip+1))#'
  mutate "P1m the promotion loop reads every user's keystore-in dir" \
         's#for _inf in "\$_kad"/\*\.keys; do#for _inf in "$KS_IN"/*/*.keys; do#'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
