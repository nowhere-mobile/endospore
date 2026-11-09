#!/usr/bin/env bash
# test-odrestore-exec-census.sh [<nowhere_roamd.sh>] [--mutate] -- which commands the `odrestore)` arm's post-loop
# steps exec for one package, counted, per shape (NWP-20261122-03).
#
# WHY THIS IS COMMITTED. The backlog row "Each On-demand restore after a sign-in spends 5-11 s, almost all of it in
# its one-package grant step ..." asks first which execs a one-package grant runs and which repeat work the session
# already did. This suite answers that from the code: it runs the REAL arm with the REAL grant_perms_for and
# keystore_register (each extracted by its anchor, never copied), puts every device command they reach on PATH as a
# stub that appends its argv to a census file and answers from a planted table, and prints the per-command counts.
# It then pins the cuts NWP-20261122-03 made:
#   - an app with code: ONE filtered `pm list packages -U --user <uid> <pkg>`, and keystore_register gets the
#     namespace from it, so the unfiltered every-package `pm list packages -U -a --user <uid>` is gone;
#   - an archived placeholder (listed by pm only with -a): no grant, a11y, autofill or Keystore step, one log line,
#     and its declines are not used up before its install (the C-then-A case: the install's declines pass runs);
#   - a pm that answers nothing, fails or prints a non-digit uid: the steps run exactly as before.
#
# Shapes (pkg com.foo, uid 11; a look-alike com.foo.bar sits in every pm table and must never count):
#   A  a tapped install: a CE hold onto an app-owned dest, the app has code
#   B  a restore-only retry: no hold, the app has code
#   C  an archived placeholder: a CE hold onto a dest that is not app-owned, no code (listed only with -a)
#   CA C, then A on the same STATE and log (the declines defect)
#   D  pm lists only the look-alike in both calls      E  every pm list call fails
#   F  the exact line carries a non-digit uid           G1 call (i) lists only the look-alike, call (ii) the package
#   G2 both calls list only the look-alike
#   BB two shape-B retries as one RESTORE-ODDATA list (com.foo then com.baz, tokens b<8 hex>.1.2 and .2.2): one
#      `pm list packages -3` for the pair through $STATE/.odbatch3.<uid>.<b-part>, which op 2 removes; a cached list
#      that lacks com.baz, a malformed token and a cache that is a directory each fall back to pm (NWP-20261125-08);
#      op 2 removes the cache even as an archived placeholder or with no perms file (BB8, BB9)
#
#   bash test-odrestore-exec-census.sh              # the cases and the census tables, under each shell found
#   bash test-odrestore-exec-census.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. Every other helper the arm calls is a recorder; cp/rm/mkdir/mv are real against a temp
# tree; the /data paths of the arm and both functions are re-rooted into it.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, the stub dir and every mutant copy are made inside W, so a run leaves nothing behind.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh each run under their own name whenever found; only an `sh` that is the same binary as one of
# them is skipped, so it can never stand in for (or suppress) a named shell.
SHELLS=(); named=" "
for s in bash dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  named="$named$(readlink -f "$p") "
done
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  if [ "$s" = sh ]; then
    case "$named" in *" $(readlink -f "$p") "*) continue ;; esac
  fi
  SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"
PRINT_SHIM='command -v print >/dev/null 2>&1 || print() { _pn=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) _pn=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$_pn" = 1 ]; then command printf "%s\n" "$*"; else command printf "%s" "$*"; fi; }'

PKG=com.foo
LA=com.foo.bar
UID_=11
APPID=10234
NS=$((UID_ * 100000 + APPID))
LA_NS=$((UID_ * 100000 + 10999))
PERM=android.permission.POST_NOTIFICATIONS
PKG2=com.baz
APPID2=10235
NS2=$((UID_ * 100000 + APPID2))
TOKB=b0123abcd

# The device commands the arm, grant_perms_for and keystore_register exec, each a PATH stub that appends
# "<cmd> <argv>" to $CENSUS. pm answers `list packages` from $SIM/pm-U (-U), $SIM/pm-Ua (-U -a) or $SIM/pm-3 (-3),
# only the lines holding a trailing FILTER when one is given (pm's substring filter), rc from $SIM/pm-rc.
BIN="$W/bin"; mkdir -p "$BIN"
cat > "$BIN/pm" <<'EOF'
#!/bin/sh
echo "pm $*" >> "$CENSUS"
[ -z "${NOWHERE_SEAL_KIND+x}" ] || echo "SEALKIND=$NOWHERE_SEAL_KIND" >> "$SIM/sealkind"
[ "$1" = list ] || exit 0
rc=$(cat "$SIM/pm-rc" 2>/dev/null); rc=${rc:-0}
[ "$rc" = 0 ] || exit "$rc"
shift 2
U=0; A=0; T=0; F=""
while [ $# -gt 0 ]; do
  case "$1" in -U) U=1 ;; -a) A=1 ;; -3) T=1 ;; --user) shift ;; -*) ;; *) F="$1" ;; esac
  shift
done
if [ "$T" = 1 ]; then t=pm-3; elif [ "$A" = 1 ]; then t=pm-Ua; elif [ "$U" = 1 ]; then t=pm-U; else t=pm-plain; fi
[ -f "$SIM/$t" ] || exit 0
if [ -n "$F" ]; then grep -F -- "$F" "$SIM/$t"; else cat "$SIM/$t"; fi
exit 0
EOF
cat > "$BIN/stat" <<'EOF'
#!/bin/sh
echo "stat $*" >> "$CENSUS"
awk -v p="$3" '$1 == p {print $2; f=1} END{exit !f}' "$SIM/owners"
EOF
cat > "$BIN/timeout" <<'EOF'
#!/bin/sh
echo "timeout $*" >> "$CENSUS"
while [ $# -gt 0 ]; do case "$1" in -k|-s) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
exec "$@"
EOF
for c in cmd settings am restorecon chown chmod du; do
  printf '#!/bin/sh\necho "%s $*" >> "$CENSUS"\nexit 0\n' "$c" > "$BIN/$c"
done
chmod 755 "$BIN"/*

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
fn_of() { awk -v a="$2() {" '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" |])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> <sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 ARM GPF KSR RA RG RK ODH PKGOK n R d k
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$sh] $l"; else x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  cnt() { grep -cxF -- "$2" "$1" 2>/dev/null; }          # cnt <file> <line>: whole-line count
  has() { [ "$(cnt "$1" "$2")" -ge 1 ]; }
  hasnt() { [ "$(cnt "$1" "$2")" = 0 ]; }
  pre() { local c; c=$(grep -c -- "$2" "$1" 2>/dev/null); [ "${c:-0}" -ge 1 ]; }   # pre <file> <regex>
  nopre() { ! pre "$1" "$2"; }

  ARM=$(arm_of "$f" odrestore)
  GPF=$(fn_of "$f" grant_perms_for)
  KSR=$(fn_of "$f" keystore_register)
  PKGOK=$(fn_of "$f" pkgname_ok)
  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  EXP=$(grep -m1 -F 'export NOWHERE_SEAL_KIND="$skind"' "$f")
  [ -n "$EXP" ] || { echo "EXTRACTION FAILED: the line-6 NOWHERE_SEAL_KIND export in $f" >&2; return 2; }
  case "$ARM" in *'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  for k in "$GPF" "$KSR"; do
    [ -n "$k" ] && [ "$(printf '%s\n' "$k" | sed -n '$p')" = "}" ] || { echo "EXTRACTION FAILED: grant_perms_for or keystore_register in $f" >&2; return 2; }
  done
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  RA=$(reroot "$ARM"); RG=$(reroot "$GPF"); RK=$(reroot "$KSR")
  for k in "$RA" "$RG" "$RK"; do
    n=$(nleft "$k")
    [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) left in live code" >&2; return 2; }
  done

  # runner <root>: the REAL arm, grant_perms_for and keystore_register, the other helpers recorders, PATH stubs first
  runner() {
    local t
    { printf '%s\n' "$PRINT_SHIM"
      printf "%s='%s'\n" ROOT "$1" uid "$UID_" op odrestore srcunit "${OD_PKG:-$PKG}" skind "${OD_KIND:-}" \
        LOG "$1/roam.log" RES "$1/res" \
        ACCT_AUTH_PKG com.example.authenticator STATE "$1/state" C "$1/sim/calls" CENSUS "$1/sim/census" \
        SIM "$1/sim" KS_MAP "$1/ks/map" KS_IMPORT "$1/ks/import" KS_IN "$1/ks/in" PATH "$BIN:$PATH"
      printf '%s\n' 'export CENSUS SIM PATH' "$EXP" 'USERDIR="$ROOT/data/user/$uid"' "$ODH" "$PKGOK"
      for t in a11y_apply autofill_apply pkg_live_pids reown_restored od_relabel cutoff_prog reown_ext_appdata \
               wait_acct_authenticator acct_reload sync_apply keystore_unit; do
        printf '%s() { echo "%s $*" >> "$C"; }\n' "$t" "$t"
      done
      printf '%s\n' 'od_watched() { shift; "$@" 2>&1; }'
      printf '%s\n' 'ks_in_dir() { echo "ks_in_dir" >> "$C"; printf "%s\n" "$KS_IN/$uid"; }'
      printf '%s\n%s\n' "$RG" "$RK"
      printf 'case "$op" in\n%s\nesac\n' "$RA"
    } > "$1/run.sh"
  }
  d=$(mktemp -d -p "$W") || return 2
  mkdir -p "$d/sim"; runner "$d"
  "$sh" -n "$d/run.sh" 2>/dev/null || { echo "PARSE FAILED: the census runner under $sh" >&2; return 2; }

  HARN=""
  run_od() {  # run_od <root>: the runner under the shell named, census and calls reset first
    local e
    : > "$1/sim/census"; : > "$1/sim/calls"; runner "$1"
    "$sh" "$1/run.sh" >/dev/null 2>>"$1/sim/stderr"
    e=$(grep -m1 -iE 'command not found|unbound variable|syntax error|bad substitution|not found' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$sh: $e]"
  }
  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/ks/in/$UID_" "$R/data/system" "$R/data/user/$UID_/com.nowhere.chooser/files" \
             "$R/data/user_de/$UID_" "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/sim/stderr"
    printf '%s\n' "$PKG $PERM" "$PKG appop:android:system_alert_window" "$PKG flags:user-set:android.permission.CAMERA" \
      > "$R/data/user/$UID_/com.nowhere.chooser/files/nowhere-perms"
  }
  code() {  # code <root>: the app is installed with code for this user
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$1/data/system/packages.list"
    printf '%s\n' "package:$LA uid:$LA_NS" "package:$PKG uid:$NS" > "$1/sim/pm-U"
    printf '%s\n' "package:$LA uid:$LA_NS" "package:$PKG uid:$NS" "package:com.other uid:1110555" > "$1/sim/pm-Ua"
    printf '%s\n' "package:$LA" "package:$PKG" > "$1/sim/pm-3"
    echo "$1/data/user/$UID_/$PKG $NS" > "$1/sim/owners"
  }
  placeholder() {  # placeholder <root>: archived, listed only with -a; its CE dest exists but is root-owned
    : > "$1/data/system/packages.list"
    printf '%s\n' "package:$LA uid:$LA_NS" > "$1/sim/pm-U"
    printf '%s\n' "package:$LA uid:$LA_NS" "package:$PKG uid:$NS" "package:com.other uid:1110555" > "$1/sim/pm-Ua"
    printf '%s\n' "package:$LA" > "$1/sim/pm-3"
    echo "$1/data/user/$UID_/$PKG 0" > "$1/sim/owners"
  }
  plant_hold() {
    mkdir -p "$1/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG" "$1/data/user/$UID_/$PKG"
    echo payload > "$1/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG/f.txt"
  }
  table() {  # the per-command counts of one shape's census
    [ -n "$quiet" ] && return 0
    printf '  [%s] census %s (%s execs):\n' "$sh" "$1" "$(grep -c . "$2")"
    awk '$1 == "pm" && $2 == "list" {print; next} {print $1, $2}' "$2" | sort | uniq -c | sed 's/^/      /'
  }
  FILT="pm list packages -U --user $UID_ $PKG"
  FILTA="pm list packages -U -a --user $UID_ $PKG"
  UNF="pm list packages -U -a --user $UID_"
  NOCODE="[roamd] odrestore $PKG -> no code for user $UID_ yet: grant, a11y, autofill and Keystore steps left to its install (NWP-20261122-03)"
  SETF="pm set-permission-flags --user $UID_ $PKG android.permission.CAMERA user-set"
  nocode_n() { grep -cF -- "$NOCODE" "$1/roam.log" 2>/dev/null; }
  grant_ran() { pre "$1/roam.log" "GRANT ($PKG) ->"; }
  grant_not() { nopre "$1/roam.log" "GRANT ($PKG) ->"; }
  declined() { grep -qxF -- "$PKG" "$1/state/.declined.$UID_" 2>/dev/null; }
  undeclined() { ! declined "$1"; }

  # pkg2 <root>: a second app with code (NWP-20261125-08's lists), after code <root>
  pkg2() {
    echo "$PKG2 $APPID2 0 /data/user/0/$PKG2 default:targetSdkVersion=34 none 0 1 1235" >> "$1/data/system/packages.list"
    echo "package:$PKG2 uid:$NS2" >> "$1/sim/pm-U"; echo "package:$PKG2 uid:$NS2" >> "$1/sim/pm-Ua"
    echo "package:$PKG2" >> "$1/sim/pm-3"
    echo "$1/data/user/$UID_/$PKG2 $NS2" >> "$1/sim/owners"
    echo "$PKG2 $PERM" >> "$1/data/user/$UID_/com.nowhere.chooser/files/nowhere-perms"
  }
  # run_pair <root> <token 1> <token 2> [<between>]: op 1 (com.foo) then op 2 (com.baz); $1/sim/both is the two
  # censuses, $1/sim/cache1 records whether the -3 cache existed after op 1. <between> runs between the ops.
  run_pair() {
    OD_PKG=$PKG OD_KIND=$2 run_od "$1"; cp "$1/sim/census" "$1/sim/both"
    if [ -f "$1/state/.odbatch3.$UID_.$TOKB" ]; then echo yes; else echo no; fi > "$1/sim/cache1"
    [ -z "${4:-}" ] || "$4" "$1"
    OD_PKG=$PKG2 OD_KIND=$3 run_od "$1"; cat "$1/sim/census" >> "$1/sim/both"
  }
  add_pkg2_3() { echo "package:$PKG2" >> "$1/sim/pm-3"; }
  # archive_pkg2 <root>: com.baz loses its code between the ops (pm lists it only with -a, as an archived app)
  archive_pkg2() { grep -vF "package:$PKG2 " "$1/sim/pm-U" > "$1/sim/pm-U.next"; mv "$1/sim/pm-U.next" "$1/sim/pm-U"; }
  drop_perms() { rm -f "$1/data/user/$UID_/com.nowhere.chooser/files/nowhere-perms"; }
  T3="pm list packages --user $UID_ -3"
  G2I="pm grant --user $UID_ $PKG2 android.permission.INTERNET"
  G2P="pm grant --user $UID_ $PKG2 $PERM"
  granted2() { grep -qxF -- "$PKG2" "$1/state/.granted.$UID_" 2>/dev/null; }
  nokind() { [ ! -s "$1/sim/sealkind" ]; }
  nocache() { ! ls "$1/state"/.odbatch3.* >/dev/null 2>&1; }
  bb_one() { eqv "$(cnt "$1/sim/both" "$T3")" 1 && nokind "$1"; }
  bb_grant() { eqv "$(cnt "$1/sim/both" "$T3")" 1 && has "$1/sim/both" "$G2I" && has "$1/sim/both" "$G2P" && granted2 "$1"; }
  bb_cache() { eqv "$(cat "$1/sim/cache1")" yes && nocache "$1"; }
  bb_fallback() { eqv "$(cnt "$1/sim/both" "$T3")" 2 && has "$1/sim/both" "$G2I" && granted2 "$1" && nokind "$1"; }
  bb_none() { eqv "$(cnt "$1/sim/both" "$T3")" 2 && nocache "$1" && nokind "$1" && has "$1/sim/both" "$G2I"; }

  say "== [$sh] A: a tapped install, CE hold onto an app-owned dest, the app has code =="
  mkroot; code "$R"; plant_hold "$R"
  run_od "$R"; table A "$R/sim/census"
  chk "A the reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"
  chk "A exactly one filtered '$FILT'" eqv "$(cnt "$R/sim/census" "$FILT")" 1
  chk "A no unfiltered '$UNF'" hasnt "$R/sim/census" "$UNF"
  chk "A no '$FILTA' (call (ii) not needed)" hasnt "$R/sim/census" "$FILTA"
  chk "A grant_perms_for ran" grant_ran "$R"
  chk "A \$STATE/.declined.$UID_ gains $PKG" declined "$R"
  chk "A the declines pass set the flags" has "$R/sim/census" "$SETF"
  chk "A keystore registered $PKG with the namespace from the read" pre "$R/roam.log" "keystore registered $PKG ns $NS for carry"
  chk "A a11y_apply and autofill_apply ran" eqv "$(cnt "$R/sim/calls" "a11y_apply $UID_ $PKG")$(cnt "$R/sim/calls" "autofill_apply $UID_ $PKG")" 11
  chk "A no 'no code' line" eqv "$(nocode_n "$R")" 0

  say "== [$sh] B: a restore-only retry, no hold, the app has code =="
  mkroot; code "$R"
  run_od "$R"; table B "$R/sim/census"
  chk "B the reply is OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"
  chk "B exactly one filtered '$FILT'" eqv "$(cnt "$R/sim/census" "$FILT")" 1
  chk "B no unfiltered '$UNF'" hasnt "$R/sim/census" "$UNF"
  chk "B grant_perms_for ran" grant_ran "$R"
  chk "B keystore registered $PKG with the namespace from the read" pre "$R/roam.log" "keystore registered $PKG ns $NS for carry"
  chk "B reown_ext_appdata ran" has "$R/sim/calls" "reown_ext_appdata $PKG"

  say "== [$sh] C: an archived placeholder, CE hold onto a root-owned dest, no code =="
  mkroot; placeholder "$R"; plant_hold "$R"
  run_od "$R"; table C "$R/sim/census"
  chk "C the reply is ERR-NOTREADY (as before)" eqv "$(cat "$R/res" 2>/dev/null)" ERR-NOTREADY
  chk "C no 'pm grant'" nopre "$R/sim/census" '^pm grant '
  chk "C no 'pm list packages --user $UID_ -3'" hasnt "$R/sim/census" "pm list packages --user $UID_ -3"
  chk "C no unfiltered '$UNF'" hasnt "$R/sim/census" "$UNF"
  chk "C no a11y_apply call" nopre "$R/sim/calls" '^a11y_apply '
  chk "C no autofill_apply call" nopre "$R/sim/calls" '^autofill_apply '
  chk "C no Keystore step" nopre "$R/roam.log" 'keystore register'
  chk "C grant_perms_for did not run" grant_not "$R"
  chk "C the one 'no code' log line" eqv "$(nocode_n "$R")" 1
  chk "C reown_ext_appdata still ran" has "$R/sim/calls" "reown_ext_appdata $PKG"
  chk "C restorecon of the external data dir still ran" has "$R/sim/census" "restorecon -R -D $R/data/media/$UID_/Android/data/$PKG"
  chk "C \$STATE/.declined.$UID_ does not hold $PKG" undeclined "$R"

  say "== [$sh] CA: the placeholder's op, then its real install's op, on the same STATE =="
  code "$R"
  run_od "$R"; table "CA (the install's op)" "$R/sim/census"
  chk "CA the install's reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"
  chk "CA the install's declines pass ran ('$SETF')" has "$R/sim/census" "$SETF"
  chk "CA \$STATE/.declined.$UID_ holds $PKG once" eqv "$(cnt "$R/state/.declined.$UID_" "$PKG")" 1

  say "== [$sh] D: pm lists only the look-alike in both calls -> the steps run as before =="
  mkroot; code "$R"; plant_hold "$R"
  printf '%s\n' "package:$LA uid:$LA_NS" > "$R/sim/pm-U"; printf '%s\n' "package:$LA uid:$LA_NS" > "$R/sim/pm-Ua"
  run_od "$R"; table D "$R/sim/census"
  chk "D grant_perms_for ran" grant_ran "$R"
  chk "D the one-argument keystore_register's listing '$UNF' ran" eqv "$(cnt "$R/sim/census" "$UNF")" 1
  chk "D a11y_apply ran" has "$R/sim/calls" "a11y_apply $UID_ $PKG"
  chk "D no 'no code' line" eqv "$(nocode_n "$R")" 0
  chk "D the reply is OK $PKG" eqv "$(cat "$R/res" 2>/dev/null)" "OK $PKG"

  say "== [$sh] E: every pm list call fails -> the steps run as before =="
  mkroot; code "$R"; plant_hold "$R"; echo 1 > "$R/sim/pm-rc"
  run_od "$R"
  chk "E grant_perms_for ran" grant_ran "$R"
  chk "E the one-argument keystore_register's listing ran" eqv "$(cnt "$R/sim/census" "$UNF")" 1
  chk "E call (ii) not run after a failed call (i)" hasnt "$R/sim/census" "$FILTA"
  chk "E no 'no code' line" eqv "$(nocode_n "$R")" 0

  say "== [$sh] F: the exact line carries a non-digit uid -> the steps run as before, call (ii) not run =="
  mkroot; code "$R"; plant_hold "$R"; printf '%s\n' "package:$PKG uid:abc" > "$R/sim/pm-U"
  run_od "$R"
  chk "F grant_perms_for ran" grant_ran "$R"
  chk "F call (ii) not run" hasnt "$R/sim/census" "$FILTA"
  chk "F the one-argument keystore_register's listing ran" eqv "$(cnt "$R/sim/census" "$UNF")" 1
  chk "F no 'no code' line" eqv "$(nocode_n "$R")" 0

  say "== [$sh] G1: call (i) lists only the look-alike, call (ii) lists the package -> a placeholder =="
  mkroot; placeholder "$R"; plant_hold "$R"
  run_od "$R"
  chk "G1 no 'pm grant'" nopre "$R/sim/census" '^pm grant '
  chk "G1 grant_perms_for did not run" grant_not "$R"
  chk "G1 the one 'no code' log line" eqv "$(nocode_n "$R")" 1

  say "== [$sh] G2: both calls list only the look-alike -> the steps run as before =="
  mkroot; placeholder "$R"; plant_hold "$R"; printf '%s\n' "package:$LA uid:$LA_NS" > "$R/sim/pm-Ua"
  run_od "$R"
  chk "G2 grant_perms_for ran" grant_ran "$R"
  chk "G2 no 'no code' line" eqv "$(nocode_n "$R")" 0

  say "== [$sh] BB: two shape-B retries as one list, com.foo ($TOKB.1.2) then com.baz ($TOKB.2.2) =="
  mkroot; code "$R"; pkg2 "$R"
  run_pair "$R" "$TOKB.1.2" "$TOKB.2.2"; table BB "$R/sim/both"
  chk "BB1 ONE '$T3' for the pair, and no NOWHERE_SEAL_KIND" bb_one "$R"
  chk "BB2 op 2 still grants $PKG2 (INTERNET default, its perm, .granted.$UID_) from the one read" bb_grant "$R"
  chk "BB3 the -3 cache exists after op 1 and is gone after op 2" bb_cache "$R"
  chk "BB the replies are OK NOSRC" eqv "$(cat "$R/res" 2>/dev/null)" "OK NOSRC"

  say "== [$sh] BB4: the cached list lacks $PKG2 (installed after op 1's read) -> op 2 runs pm again =="
  mkroot; code "$R"; pkg2 "$R"
  printf '%s\n' "package:$LA" "package:$PKG" > "$R/sim/pm-3"
  run_pair "$R" "$TOKB.1.2" "$TOKB.2.2" add_pkg2_3
  chk "BB4 two '$T3', $PKG2 granted INTERNET and recorded, no NOWHERE_SEAL_KIND" bb_fallback "$R"

  say "== [$sh] BB5: shape B with no token =="
  mkroot; code "$R"
  run_od "$R"
  chk "BB5 shape B with no token still runs 6 execs" eqv "$(grep -c . "$R/sim/census")" 6

  for k in "$TOKB.1.x:$TOKB.2.x" "b0123ABCD.1.2:b0123ABCD.2.2" "$TOKB.01.2:$TOKB.02.2" "$TOKB.1.2.3:$TOKB.2.2.3" \
           "x0123abcd.1.2:x0123abcd.2.2" "b0123abc.1.2:b0123abc.2.2"; do
    say "== [$sh] BB6: a malformed token (${k%%:*}, ${k#*:}) is no token =="
    mkroot; code "$R"; pkg2 "$R"
    run_pair "$R" "${k%%:*}" "${k#*:}"
    chk "BB6 ${k%%:*}: two '$T3', no -3 cache, no NOWHERE_SEAL_KIND, $PKG2 granted" bb_none "$R"
  done

  say "== [$sh] BB7: the -3 cache path is a directory -> pm, never the directory =="
  mkroot; code "$R"; pkg2 "$R"; mkdir -p "$R/state/.odbatch3.$UID_.$TOKB"
  run_pair "$R" "$TOKB.1.2" "$TOKB.2.2"
  chk "BB7 two '$T3', both granted, no NOWHERE_SEAL_KIND" bb_fallback "$R"
  chk "BB7 $PKG granted from pm" pre "$R/roam.log" "GRANT ($PKG) ->"

  # RF-001: the last op removes the -3 cache even when it never reaches grant_perms_for's read.
  say "== [$sh] BB8: $PKG2 is an archived placeholder by op 2 -> no grant, and the -3 cache is still removed =="
  mkroot; code "$R"; pkg2 "$R"
  run_pair "$R" "$TOKB.1.2" "$TOKB.2.2" archive_pkg2
  chk "BB8 the -3 cache exists after op 1 and is gone after op 2" bb_cache "$R"
  chk "BB8 op 2 ran no grant for $PKG2" hasnt "$R/sim/both" "$G2I"
  chk "BB8 op 2 logged its 'no code' line" pre "$R/roam.log" "odrestore $PKG2 -> no code for user $UID_ yet"

  say "== [$sh] BB9: the perms file is gone by op 2 -> grant_perms_for returns early, and the -3 cache is still removed =="
  mkroot; code "$R"; pkg2 "$R"
  run_pair "$R" "$TOKB.1.2" "$TOKB.2.2" drop_perms
  chk "BB9 the -3 cache exists after op 1 and is gone after op 2" bb_cache "$R"
  chk "BB9 op 2's grant_perms_for found no perms file" pre "$R/roam.log" "GRANT ($PKG2) -> 0 perms (no file, user $UID_)"

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "[$sh] $p passed, $x failed"
  [ "$x" = 0 ]
}

rc=0
for sh in "${SHELLS[@]}"; do suite "$SUT" "$sh"; r=$?; [ "$r" -gt "$rc" ] && rc=$r; done
[ "$MUTATE" = yes ] || exit "$rc"
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of roamd's text, by exact line (m3 by exact substring); a mutant that changes nothing is a
# failure of the suite.
L_SKIP='    if [ "$_odcode" = no ]; then'
L_KS='      keystore_register "$pkg" "$_odns"'
L_II='          if _odpu=$(pm list packages -U -a --user "$uid" "$pkg" </dev/null 2>/dev/null); then'
L_RE='    reown_ext_appdata "$pkg"; restorecon -R -D "/data/media/$uid/Android/data/$pkg" 2>>"$LOG"'
N_EXACT='package:$pkg uid:"'
# NWP-20261125-08's lines, passed to awk through ENVIRON (one ends in a backslash, which -v would read as an escape).
export M_CR='    if [ -n "$_gbf" ] && [ -f "$_gbf" ] && [ -r "$_gbf" ] \'
export M_GR='       && grep -qxF -- "$pkgfilter" "$_gbf" 2>/dev/null; then'
export M_RM='    [ "$odlast" = 1 ] && rm -f "$STATE/.odbatch3.$uid.${odbatch%%.*}" 2>>"$LOG"'
export M_TV='        case "$_odbi.$_odbn" in *[!0-9.]*|0*|*.0*|.*|*.|*.*.*) ;; *) odbatch="$skind" ;; esac ;;'
export M_EX='[ "$op" != "in" ] && [ "$op" != "odrestore" ] && [ -n "$skind" ] && export NOWHERE_SEAL_KIND="$skind"  # -> the seal tags its snapshot manual (pinned) vs automatic'
for l in "$L_SKIP" "$L_KS" "$L_II" "$L_RE" "$M_CR" "$M_GR" "$M_RM" "$M_TV" "$M_EX"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
[ "$(grep -cF -- "$N_EXACT" "$SUT")" = 4 ] || { echo "EXTRACTION FAILED: want 4 exact-line needles in $SUT" >&2; exit 2; }
# A mutant convicts only with rc 1 AND a FAIL line under each shell's own tag; rc 0 is NOT CONVICTED, rc 1 without
# such a line UNPROVEN, any other rc (extraction, parse, harness) BROKEN -- every one a failure of the suite.
mut() {
  local name="$1" prog="$2" t out r sh ev
  t=$(mktemp -p "$W")
  awk -v SKIP="$L_SKIP" -v KS="$L_KS" -v II="$L_II" -v RE="$L_RE" -v NX="$N_EXACT" "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  for sh in "${SHELLS[@]}"; do
    out=$(suite "$t" "$sh" quiet 2>&1); r=$?
    ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$sh] ")
    if [ "$r" = 0 ]; then echo "  FAIL  NOT CONVICTED [$sh]: $name"; MFAIL=1
    elif [ "$r" != 1 ]; then echo "  FAIL  BROKEN (rc=$r) [$sh]: $name"; printf '%s\n' "$out" | sed 's/^/          /'; MFAIL=1
    elif [ -z "$ev" ]; then echo "  FAIL  UNPROVEN [$sh]: $name"; MFAIL=1
    else echo "  ok    CONVICTED [$sh]: $name"; printf '%s\n' "$ev" | sed 's/^/          /'
    fi
  done
  command rm -f "$t"
}
MFAIL=0
echo "== mutants =="
mut "m1 the placeholder skip removed" \
  '$0==SKIP{print "    if false; then"; next} {print}'
mut "m2 keystore_register called without the namespace" \
  '$0==KS{print "      keystore_register \"$pkg\""; next} {print}'
# m3: the needles in file order are call (i)'s match and cut, then call (ii)'s; each pair loosened on its own.
M3='{ s=$0; o=""; while ((i=index(s,NX))>0) { k++; o=o substr(s,1,i-1) ((k>=LO && k<=HI) ? "package:$pkg\"*\"uid:\"" : NX); s=substr(s,i+length(NX)) } print o s }'
mut "m3a call (i)'s exact-line match loosened to a prefix (<pkg>.bar counts)" "BEGIN{LO=1;HI=2} $M3"
mut "m3b call (ii)'s exact-line match loosened to a prefix (<pkg>.bar counts)" "BEGIN{LO=3;HI=4} $M3"
mut "m4 the skip condition inverted" \
  '$0==SKIP{print "    if [ \"$_odcode\" != no ]; then"; next} {print}'
mut "m5 the skip also skips the external re-own" \
  '$0==RE{next} $0==KS{print; r=RE; sub(/^    /,"",r); print "      " r; next} {print}'
mut "m6 the -a confirmation dropped (an empty first call alone skips)" \
  '$0==II{print "          _odcode=no; if false; then"; next} {print}'
mut "m7 the -3 cache read dropped" \
  '$0==ENVIRON["M_CR"]{print "    if false \\"; next} {print}'
mut "m8 the i = n removal of the -3 cache dropped" \
  '$0==ENVIRON["M_RM"]{next} {print}'
mut "m9 the batch token not validated" \
  '$0==ENVIRON["M_TV"]{print "        odbatch=\"$skind\" ;;"; next} {print}'
mut "m10 the token exported as NOWHERE_SEAL_KIND" \
  '$0==ENVIRON["M_EX"]{print "[ \"$op\" != \"in\" ] && [ -n \"$skind\" ] && export NOWHERE_SEAL_KIND=\"$skind\""; next} {print}'
mut "m11 the missing-package fallback dropped (a cache that lacks the package is used)" \
  '$0==ENVIRON["M_GR"]{print "       ; then"; next} {print}'
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
