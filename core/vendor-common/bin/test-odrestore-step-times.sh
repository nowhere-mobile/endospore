#!/usr/bin/env bash
# test-odrestore-step-times.sh [<nowhere_roamd.sh>] [--mutate] -- the `odrestore steps` line each odrestore op writes
# to roam.log (NWP-20261202-16).
#
# WHY THIS IS COMMITTED. h53 #1 (docs/product-decisions.md, 2026-11-02) asks whether an On-demand restore spends its
# time in the shared reads or in each package's own work. NOWHERE-1418's census counts execs, not time, so only a
# handset can answer it. Each op now writes one line with its wall ms per step (force-stop, copy, the filtered pm
# read, grant with the shared `pm list packages -3` read timed apart and marked pm, cache or none, a11y, autofill,
# Keystore, external reown, total). The line names no package, profile, path or batch token.
#
# This suite runs the REAL arm and the REAL grant_perms_for (each extracted by its anchor, never copied) on a PLANTED
# clock: every stubbed device command and helper APPENDS its cost to $SIM/cost, and `_ms` prints the sum. Appends,
# not a read-modify-write counter, because grant_perms_for runs its `pm grant` / `cmd appops` calls as background
# jobs. Costs: am force-stop 200, `pm list packages -U` (with or without -a) 400, `pm list packages ... -3` 3000,
# each `pm grant` 700, each `cmd appops` 300, a11y_apply 50, autofill_apply 60, keystore_register 80,
# reown_ext_appdata 90. Pkg com.foo, uid 11, a look-alike com.foo.bar in every pm table.
#
#   S1 a tapped install (CE hold onto an app-owned dest, code)  S2 a two-op list, com.foo then com.baz
#   S3 an archived placeholder, in the same shell process as S1  S4 the grant skip path (granted this session)
#   S5 no steps line names a package, the token or /data         S6 the arm with NO _ms: every ms field 0, no error
#
#   bash test-odrestore-step-times.sh              # the cases, under each shell found
#   bash test-odrestore-step-times.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. cp/rm/mkdir/mv are real against a temp tree; the /data paths are re-rooted into it.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, the stub dir and every mutant copy are made inside W, so a run leaves nothing behind.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

# bash, dash and mksh each run under their own name whenever found; an `sh` that is the same binary as one of them
# is skipped.
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
PKG2=com.baz
APPID2=10235
NS2=$((UID_ * 100000 + APPID2))
PKG3=com.qux
NS3=$((UID_ * 100000 + 10236))
TOKB=b0123abcd

# PATH stubs: each appends "<cmd> <argv>" to $CENSUS and its cost to $SIM/cost. pm answers `list packages` from
# $SIM/pm-U (-U), $SIM/pm-Ua (-U -a) or $SIM/pm-3 (-3), only the lines holding a trailing FILTER when one is given.
BIN="$W/bin"; mkdir -p "$BIN"
cat > "$BIN/pm" <<'EOF'
#!/bin/sh
echo "pm $*" >> "$CENSUS"
case "$1" in
  grant) echo 700 >> "$SIM/cost"; exit 0 ;;
  list) ;;
  *) exit 0 ;;
esac
shift 2
U=0; A=0; T=0; F=""
while [ $# -gt 0 ]; do
  case "$1" in -U) U=1 ;; -a) A=1 ;; -3) T=1 ;; --user) shift ;; -*) ;; *) F="$1" ;; esac
  shift
done
if [ "$T" = 1 ]; then t=pm-3; echo 3000 >> "$SIM/cost"
elif [ "$U" = 1 ]; then echo 400 >> "$SIM/cost"; if [ "$A" = 1 ]; then t=pm-Ua; else t=pm-U; fi
else t=pm-plain; fi
[ -f "$SIM/$t" ] || exit 0
if [ -n "$F" ]; then grep -F -- "$F" "$SIM/$t"; else cat "$SIM/$t"; fi
exit 0
EOF
cat > "$BIN/am" <<'EOF'
#!/bin/sh
echo "am $*" >> "$CENSUS"
[ "$1" = force-stop ] && echo 200 >> "$SIM/cost"
exit 0
EOF
cat > "$BIN/cmd" <<'EOF'
#!/bin/sh
echo "cmd $*" >> "$CENSUS"
[ "$1" = appops ] && echo 300 >> "$SIM/cost"
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
for c in settings restorecon chown chmod du; do
  printf '#!/bin/sh\necho "%s $*" >> "$CENSUS"\nexit 0\n' "$c" > "$BIN/$c"
done
chmod 755 "$BIN"/*

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
fn_of() { awk -v a="$2() {" '$0 == a {f=1} f{print} f&&/^}$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" |])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> <sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" sh="$2" quiet="${3:-}" p=0 x=0 ARM GPF RA RG ODH PKGOK n R k L1 L2 sum ng na e
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    [$sh] $l"; else x=$((x+1)); printf '  FAIL  [%s] %s\n' "$sh" "$l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  ge() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -ge "$2" ] 2>/dev/null; }
  # steps <root> <n>: the n-th steps line of roam.log, or empty
  steps() { grep -F '[roamd] odrestore steps ' "$1/roam.log" 2>/dev/null | sed -n "${2}p"; }
  nsteps() { local c; c=$(grep -cF '[roamd] odrestore steps ' "$1/roam.log" 2>/dev/null); echo "${c:-0}"; }
  # fld <line> <key>: the value of key=value in a steps line, or empty
  fld() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | sed -n 1p; }
  # pos <line>: the token between `user <uid> ` and `:`
  pos() { printf '%s\n' "$1" | sed -n 's/.*\[roamd\] odrestore steps user [0-9]* \([^ :]*\): .*/\1/p'; }
  lacks() { [ -n "$1" ] || return 1; case "$1" in *"$2"*) return 1 ;; esac; return 0; }   # an empty text proves nothing
  # grant_is <line> <pm grant count> <cmd appops count>: the grant field is the planted cost of exactly that census
  grant_is() { [ "$2" -ge 3 ] && eqv "$(fld "$1" grant)" "$((3000 + 700 * $2 + 300 * $3))"; }

  ARM=$(arm_of "$f" odrestore)
  GPF=$(fn_of "$f" grant_perms_for)
  PKGOK=$(fn_of "$f" pkgname_ok)
  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  case "$ARM" in *'echo "OK NOSRC" > "$RES"'*'echo "ERR-NOTREADY" > "$RES"'*) ;; *) echo "EXTRACTION FAILED: the odrestore arm in $f" >&2; return 2 ;; esac
  [ -n "$GPF" ] && [ "$(printf '%s\n' "$GPF" | sed -n '$p')" = "}" ] || { echo "EXTRACTION FAILED: grant_perms_for in $f" >&2; return 2; }
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  RA=$(reroot "$ARM"); RG=$(reroot "$GPF")
  for k in "$RA" "$RG"; do
    n=$(nleft "$k")
    [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: $n absolute /data path(s) left in live code" >&2; return 2; }
  done

  # runner <root> <clock yes|no> <list>: ONE shell process that runs the REAL arm once per "<pkg>:<token>" of the list
  runner() {
    local t
    { printf '%s\n' "$PRINT_SHIM"
      printf "%s='%s'\n" ROOT "$1" uid "$UID_" op odrestore LOG "$1/roam.log" RES "$1/res" \
        ACCT_AUTH_PKG com.example.authenticator STATE "$1/state" C "$1/sim/calls" CENSUS "$1/sim/census" \
        SIM "$1/sim" PATH "$BIN:$PATH" ODLIST "$3"
      printf '%s\n' 'export CENSUS SIM PATH' 'USERDIR="$ROOT/data/user/$uid"' "$ODH" "$PKGOK"
      [ "$2" = yes ] && printf '%s\n' '_ms() { awk '"'"'{s+=$1} END{print s+0}'"'"' "$SIM/cost"; }'
      printf '%s() { echo "%s $*" >> "$C"; echo %s >> "$SIM/cost"; }\n' a11y_apply a11y_apply 50 \
        autofill_apply autofill_apply 60 keystore_register keystore_register 80 reown_ext_appdata reown_ext_appdata 90
      for t in pkg_live_pids reown_restored od_relabel cutoff_prog wait_acct_authenticator acct_reload sync_apply; do
        printf '%s() { echo "%s $*" >> "$C"; }\n' "$t" "$t"
      done
      printf '%s\n' 'vpn_preconsent_off() { :; }   # NWP-20261202-03'
      printf '%s\n' 'od_watched() { shift; "$@" 2>&1; }'
      printf '%s\n' 'od_fetch_data() { return 0; }; od_listed() { return 1; }; od_block_app() { return 0; }; od_unblock_app() { :; }; od_pending_clear() { :; }; od_block_installed() { :; }; od_shipped_prep() { return 0; }; od_park_var() { :; }; od_unf_path() { echo "$STATE/odfetch.$1/unfetched.$2"; }   # NWP-20261130-03'
      printf '%s\n' "$RG"
      printf 'for _stl in $ODLIST; do\nsrcunit=${_stl%%%%:*}; skind=${_stl#*:}\ncase "$op" in\n%s\nesac\ndone\n' "$RA"
    } > "$1/run.sh"
  }
  HARN=""
  run_od() {  # run_od <root> <clock yes|no> <list>: the runner under the shell named
    local e
    : > "$1/sim/census"; : > "$1/sim/calls"; : > "$1/sim/cost"; runner "$1" "$2" "$3"
    "$sh" -n "$1/run.sh" 2>/dev/null || { HARN="$HARN [$sh: the runner does not parse]"; return; }
    "$sh" "$1/run.sh" >/dev/null 2>>"$1/sim/stderr"
    e=$(grep -m1 -iE 'command not found|unbound variable|syntax error|bad substitution|not found|arithmetic' "$1/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || [ "$2" = no ] || HARN="$HARN [$sh: $e]"
  }
  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/state" "$R/data/system" "$R/data/user/$UID_/com.nowhere.chooser/files" \
             "$R/data/user_de/$UID_" "$R/data/media/$UID_/Android/data" "$R/data/media/$UID_/Android/obb"
    : > "$R/sim/owners"; : > "$R/sim/stderr"
    # No INTERNET line for com.foo, so its INTERNET default runs.
    printf '%s\n' "$PKG android.permission.CAMERA" "$PKG android.permission.READ_CONTACTS" \
      > "$R/data/user/$UID_/com.nowhere.chooser/files/nowhere-perms"
    echo "$PKG $APPID 0 /data/user/0/$PKG default:targetSdkVersion=34 none 0 1 1234" > "$R/data/system/packages.list"
    printf '%s\n' "package:$LA uid:$LA_NS" "package:$PKG uid:$NS" > "$R/sim/pm-U"
    printf '%s\n' "package:$LA uid:$LA_NS" "package:$PKG uid:$NS" "package:$PKG3 uid:$NS3" > "$R/sim/pm-Ua"
    printf '%s\n' "package:$LA" "package:$PKG" > "$R/sim/pm-3"
    echo "$R/data/user/$UID_/$PKG $NS" > "$R/sim/owners"
  }
  plant_hold() {
    mkdir -p "$1/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG" "$1/data/user/$UID_/$PKG"
    echo payload > "$1/data/user/$UID_/com.nowhere.chooser/.nowhere-odhold/$PKG/f.txt"
  }
  pkg2() {
    echo "$PKG2 $APPID2 0 /data/user/0/$PKG2 default:targetSdkVersion=34 none 0 1 1235" >> "$1/data/system/packages.list"
    echo "package:$PKG2 uid:$NS2" >> "$1/sim/pm-U"; echo "package:$PKG2 uid:$NS2" >> "$1/sim/pm-Ua"
    echo "package:$PKG2" >> "$1/sim/pm-3"
    echo "$1/data/user/$UID_/$PKG2 $NS2" >> "$1/sim/owners"
  }
  ALL=""

  say "== [$sh] S1 + S3: a tapped install of $PKG, then $PKG3 as an archived placeholder, in ONE shell process =="
  mkroot; plant_hold "$R"
  run_od "$R" yes "$PKG: $PKG3:"
  L1=$(steps "$R" 1); L2=$(steps "$R" 2); ALL="$ALL$L1$L2"
  ng=$(grep -c '^pm grant ' "$R/sim/census"); na=$(grep -c '^cmd appops ' "$R/sim/census")
  sum=0
  for k in stop copy pmread grant a11y autofill keystore ext; do
    e=$(fld "$L1" "$k"); case "$e" in ''|*[!0-9]*) e=0 ;; esac; sum=$((sum + e))
  done
  chk "S1 a steps line for the op" eqv "$(nsteps "$R")" 2
  chk "S1 the position is one" eqv "$(pos "$L1")" one
  chk "S1 stop=200" eqv "$(fld "$L1" stop)" 200
  chk "S1 pmread=400" eqv "$(fld "$L1" pmread)" 400
  chk "S1 shared3=3000:pm" eqv "$(fld "$L1" shared3)" 3000:pm
  chk "S1 grant = 3000 + 700 x $ng pm grant + 300 x $na cmd appops (at least 3 pm grant)" grant_is "$L1" "$ng" "$na"
  chk "S1 a11y=50 autofill=60 keystore=80 ext=90" eqv "$(fld "$L1" a11y) $(fld "$L1" autofill) $(fld "$L1" keystore) $(fld "$L1" ext)" "50 60 80 90"
  chk "S1 total >= the sum of the fields ($sum)" ge "$(fld "$L1" total)" "$((sum > 0 ? sum : 1))"
  chk "S1 reply=OK code=yes" eqv "$(fld "$L1" reply) $(fld "$L1" code)" "OK yes"
  chk "S3 grant=0 a11y=0 autofill=0 keystore=0" eqv "$(fld "$L2" grant) $(fld "$L2" a11y) $(fld "$L2" autofill) $(fld "$L2" keystore)" "0 0 0 0"
  chk "S3 shared3=0:none (the arm-top reset)" eqv "$(fld "$L2" shared3)" 0:none
  chk "S3 code=no reply=NOSRC" eqv "$(fld "$L2" code) $(fld "$L2" reply)" "no NOSRC"

  say "== [$sh] S2: a two-op list, $PKG ($TOKB.1.2) then $PKG2 ($TOKB.2.2) =="
  mkroot; pkg2 "$R"
  run_od "$R" yes "$PKG:$TOKB.1.2"
  run_od "$R" yes "$PKG2:$TOKB.2.2"
  L1=$(steps "$R" 1); L2=$(steps "$R" 2); ALL="$ALL$L1$L2"
  chk "S2 op 1 is 1/2 with shared3=3000:pm" eqv "$(pos "$L1") $(fld "$L1" shared3)" "1/2 3000:pm"
  chk "S2 op 2 is 2/2 with shared3=0:cache" eqv "$(pos "$L2") $(fld "$L2" shared3)" "2/2 0:cache"

  say "== [$sh] S4: the skip path, $PKG granted this session, no hold, not materialised =="
  mkroot; echo "$PKG" > "$R/state/.granted.$UID_"
  run_od "$R" yes "$PKG:"
  L1=$(steps "$R" 1); ALL="$ALL$L1"
  chk "S4 shared3=0:none code=yes" eqv "$(fld "$L1" shared3) $(fld "$L1" code)" "0:none yes"

  say "== [$sh] S5: no steps line names a package, the token's b-part or /data =="
  chk "S5 lines were read" eqv "${ALL:+yes}" yes
  for k in "$PKG" "$PKG2" "$PKG3" "$TOKB" /data; do chk "S5 no '$k' in a steps line" lacks "$ALL" "$k"; done

  say "== [$sh] S6: the arm with NO _ms defined =="
  mkroot; plant_hold "$R"
  run_od "$R" no "$PKG:"
  L1=$(steps "$R" 1)
  chk "S6 the steps line is written" eqv "$(nsteps "$R")" 1
  chk "S6 every ms field is 0" eqv "$(for k in stop copy pmread grant a11y autofill keystore ext total; do printf '%s ' "$(fld "$L1" "$k")"; done)$(fld "$L1" shared3)" "0 0 0 0 0 0 0 0 0 0:pm"
  e=$(grep -m1 -iE 'command not found|unbound variable|syntax error|bad substitution|not found|arithmetic|bad number' "$R/sim/stderr" 2>/dev/null)
  chk "S6 the line written with no shell error on the runner's stderr${e:+ ($e)}" eqv "$(nsteps "$R")/$e" 1/

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "[$sh] $p passed, $x failed"
  [ "$x" = 0 ]
}

rc=0
for sh in "${SHELLS[@]}"; do suite "$SUT" "$sh"; r=$?; [ "$r" -gt "$rc" ] && rc=$r; done
[ "$MUTATE" = yes ] || exit "$rc"
[ "$rc" = 0 ] || exit "$rc"

# --- mutants ------------------------------------------------------------------------------------------------
# Each is a transform of roamd's text by exact line or line prefix, passed to awk through ENVIRON; a mutant that
# changes nothing is a failure of the suite.
export M_STEPS='    echo "[roamd] odrestore steps user $uid $_odpos: '
export M_T5='      _odt5=$(_ms 2>/dev/null)'
export M_GPF='      grant_perms_for "$uid" "$pkg" "$_first" ${odbatch:+"$odbatch"}'
export M_TOP='    GPF3_MS=0; GPF3_SRC=none; _odt0=$(_ms 2>/dev/null)'
export M_CACHE='    [ "$_g3hit" = 1 ] && GPF3_SRC=cache'
export M_GT1='    [ "$_g3hit" = 1 ] || { _gt1=$(_ms 2>/dev/null); GPF3_MS=$(( ${_gt1:-0} - ${_gt0:-0} )); GPF3_SRC=pm; }'
export M_INET='    pm grant --user "$uid" "$dpkg" android.permission.INTERNET </dev/null >/dev/null 2>&1 && { dflt=$((dflt+1)); echo "$dpkg" >> "$_gok"; }'
export M_POS='    _odpos=one; [ -n "$odbatch" ] && _odpos="$_odbi/$_odbn"'
for l in "$M_T5" "$M_GPF" "$M_CACHE" "$M_GT1" "$M_INET" "$M_POS"; do
  [ "$(grep -cxF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor line not unique in $SUT: $l" >&2; exit 2; }
done
for l in "$M_STEPS" "$M_TOP"; do
  [ "$(grep -cF -- "$l" "$SUT")" = 1 ] || { echo "EXTRACTION FAILED: anchor prefix not unique in $SUT: $l" >&2; exit 2; }
done
# A mutant convicts only with rc 1 AND a FAIL line naming its assertion under each shell's own tag; rc 0 is NOT
# CONVICTED, rc 1 without that line UNPROVEN, any other rc (extraction, parse, harness) BROKEN -- each a failure.
mut() {
  local name="$1" want="$2" prog="$3" t out r sh ev
  t=$(mktemp -p "$W")
  awk "$prog" "$SUT" > "$t"
  if cmp -s "$t" "$SUT"; then echo "  FAIL  mutant did not apply: $name"; MFAIL=1; command rm -f "$t"; return; fi
  for sh in "${SHELLS[@]}"; do
    out=$(suite "$t" "$sh" quiet 2>&1); r=$?
    ev=$(printf '%s\n' "$out" | grep -F "  FAIL  [$sh] $want")
    if [ "$r" = 0 ]; then echo "  FAIL  NOT CONVICTED [$sh]: $name"; MFAIL=1
    elif [ "$r" != 1 ]; then echo "  FAIL  BROKEN (rc=$r) [$sh]: $name"; printf '%s\n' "$out" | sed 's/^/          /'; MFAIL=1
    elif [ -z "$ev" ]; then echo "  FAIL  UNPROVEN [$sh] (no '$want' failure): $name"; printf '%s\n' "$out" | sed 's/^/          /'; MFAIL=1
    else echo "  ok    CONVICTED [$sh]: $name"; printf '%s\n' "$ev" | sed 's/^/          /'
    fi
  done
  command rm -f "$t"
}
MFAIL=0
echo "== mutants =="
mut "m1 the steps line removed" "S1 a steps line for the op" \
  'index($0, ENVIRON["M_STEPS"]) == 1 {next} {print}'
mut "m2 the steps line prints \$pkg" "S5 no 'com.foo' in a steps line" \
  'index($0, ENVIRON["M_STEPS"]) == 1 {sub(/user \$uid \$_odpos:/, "user $uid $pkg $_odpos:")} {print}'
mut "m3 _odt5 taken before grant_perms_for" "S1 grant = " \
  '$0 == ENVIRON["M_T5"] {next} $0 == ENVIRON["M_GPF"] {print ENVIRON["M_T5"]} {print}'
mut "m4 the arm-top GPF3 reset removed" "S3 shared3=0:none" \
  'index($0, ENVIRON["M_TOP"]) == 1 {sub(/GPF3_MS=0; GPF3_SRC=none; /, "")} {print}'
mut "m5 a cache hit reported as pm" "S2 op 2 is 2/2" \
  '$0 == ENVIRON["M_CACHE"] {sub(/GPF3_SRC=cache/, "GPF3_SRC=pm")} {print}'
mut "m6 the -3 end stamp moved after the INTERNET loop" "S1 shared3=3000:pm" \
  '$0 == ENVIRON["M_GT1"] {next} $0 == ENVIRON["M_INET"] {i=1} i && $0 == "  done" {print; print ENVIRON["M_GT1"]; i=0; next} {print}'
mut "m7 the :-0 defaults dropped" "S6 the steps line is written" \
  '{ o=""; s=$0; while (match(s, /\$\{_odt[0-9]+:-0\}/)) { o = o substr(s, 1, RSTART-1) "$" substr(s, RSTART+2, RLENGTH-6); s = substr(s, RSTART+RLENGTH) } print o s }'
mut "m8 the position printed as the batch token" "S2 op 1 is 1/2" \
  '$0 == ENVIRON["M_POS"] {sub(/_odpos="\$_odbi\/\$_odbn"/, "_odpos=\"$odbatch\"")} {print}'
mut "m8 the position printed as the batch token (S5)" "S5 no 'b0123abcd' in a steps line" \
  '$0 == ENVIRON["M_POS"] {sub(/_odpos="\$_odbi\/\$_odbn"/, "_odpos=\"$odbatch\"")} {print}'
[ "$MFAIL" = 0 ] || exit 1
echo "all mutants convicted"
