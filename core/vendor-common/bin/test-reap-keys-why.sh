#!/usr/bin/env bash
# test-reap-keys-why.sh [<nowhere_roamd.sh>] [--mutate] -- a refused #keys seal at the reap records WHY it was refused
# (NWP-20261203-22; the backlog row "When the sign-out reap restarts the system server, the `#keys` seal that follows
# is refused for want of a restore-completion receipt and the session's new Keystore bundles are destroyed").
#
# WHY THIS IS COMMITTED. Before this slice the reap ledger row of a notsealed reap said only `keys=notsealed`. roam.log
# is cut to a tail by log_scrub at the same reap, and a gate report carries neither roam.log nor login.log, so a field
# ticket could not tell a seal the agent refused for want of a restore-completion receipt from a network failure.
# Evidence only: the verdict, the 5 s / 30 s / 2 min ladder and the destroy-on-notsealed rule do not change.
#
# keystore_push now sets KS_WHY: "" when the last push sealed (or no push ran); for rc 4 (exitSealRefused) the reason
# of the FIRST `keys <reason>` line the LAST attempt appended to $STATE/seal.refusal-why (the entry guard's; fence and
# stale follow it, sealRefusalReasons in core/agent/end_unsaved.go), from a closed list, else `other`; for another rc
# `rc<n>`. The NOT SEALED line carries ` why=$KS_WHY`. cleanstorage writes ` kwhy=<class>` (`none` when no push ran)
# on its roam.log line and LAST on its reap-ledger row, on a notsealed reap only.
#
# ks_in_dir, ks_ns_mine, ks_prog and keystore_push are extracted from nowhere_roamd.sh BY NAME, never copied, and the
# stage path is rewritten under a scratch root, as test-keystore-keys-retry.sh does. pw/qn/print/timeout are stubbed,
# `sleep` is a no-op, and AGENT is a script that appends $D/app.<n> to $NOWHERE_STATE/seal.refusal-why at attempt <n>
# and exits with field <n> of $RCS (the last field past the end). Each case runs under bash and sh, plus dash and mksh
# where installed -- roamd is #!/system/bin/sh (mksh on the device).
#
# CASES
#   K1 every attempt exits 4 and appends `keys no-receipt`: KS_WHY=no-receipt, notsealed, 4 pushes, the NOT SEALED
#      line carries why=no-receipt.
#   K2 an older `keys shrink` line is already in the file; each attempt appends `keys no-receipt`: no-receipt.
#   K3 every attempt exits 5: rc5, on the NOT SEALED line too.
#   K4 success: KS_WHY set and empty, sealed, the `#keys sealed` line unchanged and no why=.
#   K5 attempts 1-3 append `keys stale-base`, attempt 4 `keys shrink` then `keys fence`: shrink.
#   K6 a second call after K1 that seals: KS_WHY empty again.
#   K7 the last attempt appends `apps shrink` then `keys deleted`: other.
#   K8 cleanstorage's two capture lines, evaluated: a sealed or nothing reap gets no field; a notsealed reap with no
#      push reads ` kwhy=none`; a refused one ` kwhy=no-receipt`.
#   S1 static: the roam.log echo holds keys=$_ksv$_kswf, the ledger echo ends census:$_udc...$_kswf", the capture
#      lines sit directly after _ksv="$KS_VERDICT", and the field line holds the notsealed condition.
#   S2 static: cleanstorage reads sys.system_server.start_count exactly three times, at _ud_ssc0, _ud_ssc1 and
#      NWP-20261203-01's _rp_ssc2 (as on main), and not in the kwhy capture lines; keystore_push reads it nowhere.
#   S3 static: from the kwhy capture to the ledger echo, nothing reassigns, unsets, loops over or declares the field
#      variable (named by the ledger echo) or _ksw.
#
# MUTANTS (--mutate; each must be convicted under every shell)
#   W1 KS_WHY not reset per call                    -> K6
#   W2 one mark before the ladder, not per attempt  -> K5
#   W3 the last `keys` line of the attempt          -> K5
#   W4 kwhy written on a sealed reap                -> K8, S1
#   W5 a start_count read added to cleanstorage     -> S2
#   W6 the field variable unset before the echoes   -> S3
#   W6b the field variable reused as a loop variable -> S3
#   W7 the field variable named _ksf (KS-PRUNE's loop variable) -> S3
#
#   bash test-reap-keys-why.sh            # the cases
#   bash test-reap-keys-why.sh --mutate   # ... plus the mutants
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2          # the ONE scratch root: every other temp is made inside it
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# mksh's builtin, as these scripts use it: print -r -- / print -rn --.
PRINT_SHIM='print() { local nl=1; while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done; if [ "$nl" = 1 ]; then printf "%s\n" "$*"; else printf "%s" "$*"; fi; }'
STUBS="$PRINT_SHIM"'
pw() { printf "%s" "$1"; }
qn() { printf "%s" "$1"; }
timeout() { shift 3; "$@"; }
sleep() { :; }
'

has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
op_of() { sed -n "/^if \\[ \"\\\$op\" = \"$2\" \\]; then\$/,/^fi\$/p" "$1"; }

# extract <roamd.sh> <fn name> <out> -- one function by name. 0 ok, 2 not found.
extract() {
  local sut="$1" nm="$2" out="$3"
  sed -n "/^$nm() {\$/,/^}\$/p" "$sut" > "$out"
  if [ ! -s "$out" ] || [ "$(head -1 "$out")" != "$nm() {" ] || [ "$(tail -1 "$out")" != '}' ]; then
    echo "EXTRACTION FAILED: $nm() { ... } not found in $sut" >&2; return 2
  fi
  return 0
}

# prep_fn <roamd.sh> <out> -- ks_in_dir + ks_ns_mine + ks_prog + keystore_push, the stage under $TROOT. 0 ok, 2 harness error.
prep_fn() {
  local sut="$1" out="$2" fnm part all
  all=$(mktemp -p "$W")
  for fnm in ks_in_dir ks_ns_mine ks_prog; do
    part=$(mktemp -p "$W")
    extract "$sut" "$fnm" "$part" || return 2
    cat "$part" >> "$all"
  done
  part=$(mktemp -p "$W")
  extract "$sut" keystore_push "$part" || return 2
  { cat "$all"; sed 's#^  KSTAGE="\$STATE/keystore-stage"$#  KSTAGE="$TROOT/keystore-stage"#' "$part"; } > "$out"
  if [ "$(grep -c 'KSTAGE="\$TROOT/keystore-stage"' "$out")" != 1 ]; then
    echo "REWRITE FAILED: want exactly one KSTAGE=\"\$STATE/keystore-stage\" line in keystore_push of $sut" >&2; return 2
  fi
  if ! bash -n "$out" || ! sh -n "$out"; then
    echo "EXTRACTION FAILED: the extracted functions do not parse ($sut)" >&2; return 2
  fi
  return 0
}

# newcase -> a fresh scratch dir: uid 10's fresh dump 1010001 (-> com.a), a carried com.b bundle, the stub AGENT.
newcase() {
  local d; d=$(mktemp -d -p "$W")
  mkdir -p "$d/in/10" "$d/imp" "$d/exp" "$d/state"
  echo "1010001 com.a" > "$d/map"
  printf fresh > "$d/exp/1010001.keys"
  printf carried > "$d/in/10/com.b.keys"
  cat > "$d/agent.sh" <<'AG'
#!/bin/sh
n=$(cat "$D/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$D/n"
[ -f "$D/app.$n" ] && cat "$D/app.$n" >> "$NOWHERE_STATE/seal.refusal-why"
rc=0; i=1
for r in $RCS; do rc=$r; [ "$i" = "$n" ] && break; i=$((i + 1)); done
exit "$rc"
AG
  chmod +x "$d/agent.sh"
  printf '%s\n' "$d"
}

# app <dir> <attempt> <line>... -- the lines the stub agent appends at that attempt
app() { local d="$1" n="$2"; shift 2; printf '%s\n' "$@" > "$d/app.$n"; }

# runcase <fn> <shell> <dir> <RCS> [calls] -- `keystore_push wait` <calls> times; result <k> in $D/res.<k>
runcase() {
  local fn="$1" sh="$2" d="$3" rcs="$4" calls="${5:-1}" k
  {
    printf 'D=%s\nTROOT=%s\nSTATE=%s\nNOWHERE_STATE=%s\nLOG=%s\nKS_IN=%s\nKS_IMPORT=%s\nKS_EXPORT=%s\nKS_MAP=%s\nKS_DROP=%s\nuid=10\n' \
      "$d" "$d" "$d/state" "$d/state" "$d/log" "$d/in" "$d/imp" "$d/exp" "$d/map" "$d/drop"
    printf "AGENT=%s\nRCS='%s'\nname=prof\npass=secret\nexport D RCS NOWHERE_STATE\nunset NOWHERE_PROGRESS\n" "$d/agent.sh" "$rcs"
    printf '%s\n' "$STUBS"
    cat "$fn"
    k=1
    while [ "$k" -le "$calls" ]; do
      [ "$k" = 1 ] || printf '[ -e "$D/exp/1010001.keys" ] || printf fresh > "$D/exp/1010001.keys"\nmkdir -p "$D/in/10"; [ -e "$D/in/10/com.b.keys" ] || printf carried > "$D/in/10/com.b.keys"\n'
      printf 'keystore_push wait\nprintf "verdict=%%s why=[%%s] set=%%s\\n" "$KS_VERDICT" "${KS_WHY-}" "${KS_WHY+set}" > "$D/res.%s"\n' "$k"
      k=$((k + 1))
    done
  } > "$d/run.sh"
  "$sh" "$d/run.sh" >/dev/null 2>&1
  touch "$d/log" "$d/n" "$d/res.1"
}

# k8_eval <shell> <capture lines file> <field var> <_ksv> [KS_WHY] -- the field variable's value after the capture lines
k8_eval() {
  local sh="$1" cap="$2" v="$3" ksv="$4" s
  s=$(mktemp -p "$W")
  {
    printf '_ksv=%s\n' "$ksv"
    if [ $# -ge 5 ]; then printf 'KS_WHY=%s\n' "$5"; else printf 'unset KS_WHY\n'; fi
    cat "$cap"
    printf 'printf "[%%s]\\n" "$%s"\n' "$v"
  } > "$s"
  "$sh" "$s" 2>/dev/null
  command rm -f "$s"
}

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" fn p=0 x=0 sh rc d why log op opc V cap ln lln n wl e re nm pat B line
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  fin() {  # fin <label> <dir> -- report the accumulated $why, drop the scratch dir
    if [ -z "$why" ]; then ok "$1 [$sh]"; else no "$1 [$sh] --$why"; fi
    [ -z "${2:-}" ] || command rm -rf "$2"
  }
  B='[^A-Za-z0-9_]'
  op=$(op_of "$f" cleanstorage)
  [ -n "$op" ] || { echo "EXTRACTION FAILED: the cleanstorage op not found in $f" >&2; return 2; }
  opc=$(printf '%s\n' "$op" | sed 's/[[:space:]]#.*$//')
  # The field variable, named by the ledger echo: the last $<name> before its closing quote.
  lln=$(printf '%s\n' "$op" | grep 'reap-ledger 2>/dev/null' | grep 'uid=\$uid class=' || true)
  V=$(printf '%s\n' "$lln" | sed -n 's/.*\$\([A-Za-z_][A-Za-z0-9_]*\)"; } >>.*/\1/p')
  cap=$(mktemp -p "$W")
  ln=$(printf '%s\n' "$op" | grep -n '^  _ksw=' | cut -d: -f1)
  if [ "$(printf '%s\n' "$lln" | grep -c .)" = 1 ] && [ "$(printf '%s\n' "$V" | grep -c .)" = 1 ] \
     && [ "$(printf '%s\n' "$ln" | grep -c .)" = 1 ]; then
    printf '%s\n' "$op" | sed -n "${ln}p;$((ln + 1))p" > "$cap"
  else
    V=""; ln=""
  fi

  # --- static cases (the unrewritten roamd) ---
  sh=static
  # S1: the echo text and the capture position.
  why=""
  [ -n "$V" ] || why="$why EXTRACTION FAILED: no single ledger echo with a field variable, or no single '  _ksw=' line;"
  re=$(printf '%s\n' "$op" | grep '^  echo "\[roamd\] cleanstorage user \$uid class=' || true)
  if [ "$(printf '%s\n' "$re" | grep -c .)" != 1 ] || ! has "$re" 'keys=$_ksv$_kswf userdir=$_udf loop='; then
    why="$why the roam.log echo does not hold keys=\$_ksv\$_kswf userdir=\$_udf loop=;"
  fi
  case "$lln" in *' census:$_udc'*'$_kswf"; } >> /data/nowhere/reap-ledger 2>/dev/null') ;;
    *) why="$why the ledger echo does not end census:\$_udc...\$_kswf\";" ;; esac
  line=$(printf '%s\n' "$op" | grep -A1 '^  _ksv="\$KS_VERDICT"' | sed -n 2p)
  case "$line" in '  _ksw="${KS_WHY:-none}"'*) ;; *) why="$why the line after _ksv=\"\$KS_VERDICT\" is not the _ksw capture;" ;; esac
  line=$(sed -n 2p "$cap")
  has "$line" '_kswf=""; [ "$_ksv" = notsealed ] && _kswf=" kwhy=$_ksw"' || why="$why the field line lacks the notsealed condition;"
  fin "S1 kwhy= on the roam.log echo and last on the ledger echo, on a notsealed reap only"
  # S2: start_count reads.
  why=""
  n=$(printf '%s\n' "$opc" | grep -c 'sys\.system_server\.start_count')
  [ "$n" = 3 ] || why="$why $n line(s) name sys.system_server.start_count in cleanstorage, want 3;"
  [ "$(printf '%s\n' "$opc" | grep -c '^  _ud_ssc0=\$(getprop sys\.system_server\.start_count ')" = 1 ] || why="$why no single _ud_ssc0 read;"
  [ "$(printf '%s\n' "$opc" | grep -c '^ *_ud_ssc1=\$(getprop sys\.system_server\.start_count ')" = 1 ] || why="$why no single _ud_ssc1 read;"
  [ "$(printf '%s\n' "$opc" | grep -c '^  _rp_ssc2=\$(getprop sys\.system_server\.start_count ')" = 1 ] || why="$why no single _rp_ssc2 read;"
  # The anchor: the kwhy capture is there, and it is not one of the reads (the count above covers any added read).
  [ -n "$ln" ] || why="$why no single '  _ksw=' capture line in cleanstorage;"
  has "$(cat "$cap")" 'start_count' && why="$why the kwhy capture reads start_count;"
  d=$(mktemp -p "$W")
  if extract "$f" keystore_push "$d" 2>/dev/null; then
    [ "$(grep -c 'start_count' "$d")" = 0 ] || why="$why keystore_push names start_count;"
  else why="$why keystore_push not found;"; fi
  fin "S2 cleanstorage's start_count reads stay _ud_ssc0, _ud_ssc1 and _rp_ssc2; none added" "$d"
  # S3: no clobber of the field variable or _ksw between the capture and the ledger echo.
  why=""
  if [ -z "$V" ]; then why="$why EXTRACTION FAILED: no field variable;"
  else
    has "$re" "keys=\$_ksv\$$V " || why="$why the roam.log echo does not print \$$V after keys=\$_ksv;"
    for nm in "$V" _ksw; do
      n=$(printf '%s\n' "$opc" | grep -cE "(^|$B)$nm=")
      [ "$n" = 1 ] || why="$why $n line(s) assign $nm in the op, want 1;"
    done
    wl=$(printf '%s\n' "$opc" | sed -n '/^  _ksw=/,/reap-ledger 2>\/dev\/null/p' | sed '1,2d')
    for nm in "$V" _ksw; do
      for pat in "for[[:space:]]+$nm([^A-Za-z0-9_]|\$)" "unset([[:space:]]+[A-Za-z0-9_]+)*[[:space:]]+$nm([^A-Za-z0-9_]|\$)" \
                 "(local|read)[[:space:]].*(^|$B)$nm([^A-Za-z0-9_]|\$)" "(^|$B)$nm="; do
        n=$(printf '%s\n' "$wl" | grep -cE "$pat")
        [ "$n" = 0 ] || why="$why $n line(s) in the window match /$pat/;"
      done
    done
  fi
  fin "S3 nothing clobbers \$${V:-?} or _ksw between the capture and the ledger echo"

  fn=$(mktemp -p "$W")
  prep_fn "$f" "$fn"; rc=$?
  [ "$rc" = 0 ] || { command rm -f "$fn" "$cap"; return 2; }
  for sh in $SHELLS; do
    # K1
    d=$(newcase); why=""
    for n in 1 2 3 4; do app "$d" "$n" 'keys no-receipt'; done
    runcase "$fn" "$sh" "$d" 4
    [ "$(cat "$d/res.1")" = "verdict=notsealed why=[no-receipt] set=set" ] || why="$why res '$(cat "$d/res.1")';"
    [ "$(cat "$d/n")" = 4 ] || why="$why $(cat "$d/n") push(es), want 4;"
    log=$(cat "$d/log")
    n=$(printf '%s\n' "$log" | grep -c -- '-- NOT SEALED;.* why=no-receipt ')
    [ "$n" = 1 ] || why="$why $n NOT SEALED line(s) with ' why=no-receipt ', want 1: $(printf '%s' "$log" | tail -1);"
    fin "K1 rc 4 with keys no-receipt: KS_WHY=no-receipt, on the NOT SEALED line" "$d"
    # K2
    d=$(newcase); why=""
    printf 'keys shrink\n' > "$d/state/seal.refusal-why"
    for n in 1 2 3 4; do app "$d" "$n" 'keys no-receipt'; done
    runcase "$fn" "$sh" "$d" 4
    [ "$(cat "$d/res.1")" = "verdict=notsealed why=[no-receipt] set=set" ] || why="$why res '$(cat "$d/res.1")';"
    fin "K2 an older keys shrink line in the file: the last attempt's no-receipt" "$d"
    # K3
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 5
    [ "$(cat "$d/res.1")" = "verdict=notsealed why=[rc5] set=set" ] || why="$why res '$(cat "$d/res.1")';"
    n=$(grep -c -- '-- NOT SEALED;.* why=rc5 ' "$d/log")
    [ "$n" = 1 ] || why="$why $n NOT SEALED line(s) with ' why=rc5 ', want 1;"
    fin "K3 rc 5: KS_WHY=rc5, on the NOT SEALED line" "$d"
    # K4
    d=$(newcase); why=""
    runcase "$fn" "$sh" "$d" 0
    [ "$(cat "$d/res.1")" = "verdict=sealed why=[] set=set" ] || why="$why res '$(cat "$d/res.1")';"
    n=$(grep -c '#keys sealed (2 pkg, 1 fresh, 0 dropped) ' "$d/log")
    [ "$n" = 1 ] || why="$why $n '#keys sealed (2 pkg, 1 fresh, 0 dropped)' line(s), want 1;"
    n=$(grep -c 'why=' "$d/log")
    [ "$n" = 0 ] || why="$why $n log line(s) carry why= on a sealed push;"
    fin "K4 success: KS_WHY set and empty, the sealed line unchanged" "$d"
    # K5
    d=$(newcase); why=""
    for n in 1 2 3; do app "$d" "$n" 'keys stale-base'; done
    app "$d" 4 'keys shrink' 'keys fence'
    runcase "$fn" "$sh" "$d" 4
    [ "$(cat "$d/res.1")" = "verdict=notsealed why=[shrink] set=set" ] || why="$why res '$(cat "$d/res.1")';"
    fin "K5 the FIRST keys line of the LAST attempt: shrink, not stale-base or fence" "$d"
    # K6
    d=$(newcase); why=""
    for n in 1 2 3 4; do app "$d" "$n" 'keys no-receipt'; done
    runcase "$fn" "$sh" "$d" "4 4 4 4 0" 2
    [ "$(cat "$d/res.1")" = "verdict=notsealed why=[no-receipt] set=set" ] || why="$why call 1 res '$(cat "$d/res.1")';"
    [ "$(cat "$d/res.2" 2>/dev/null)" = "verdict=sealed why=[] set=set" ] || why="$why call 2 res '$(cat "$d/res.2" 2>/dev/null)';"
    fin "K6 a sealing call after a refused one: KS_WHY empty again" "$d"
    # K7
    d=$(newcase); why=""
    for n in 1 2 3 4; do app "$d" "$n" 'apps shrink' 'keys deleted'; done
    runcase "$fn" "$sh" "$d" 4
    [ "$(cat "$d/res.1")" = "verdict=notsealed why=[other] set=set" ] || why="$why res '$(cat "$d/res.1")';"
    fin "K7 a reason outside the list (and an apps line before it): other" "$d"
    # K8
    why=""
    if [ -z "$V" ]; then why="$why EXTRACTION FAILED: no capture lines or field variable;"
    else
      [ "$(k8_eval "$sh" "$cap" "$V" sealed no-receipt)" = "[]" ] || why="$why sealed: '$(k8_eval "$sh" "$cap" "$V" sealed no-receipt)';"
      [ "$(k8_eval "$sh" "$cap" "$V" nothing)" = "[]" ] || why="$why nothing: '$(k8_eval "$sh" "$cap" "$V" nothing)';"
      [ "$(k8_eval "$sh" "$cap" "$V" notsealed)" = "[ kwhy=none]" ] || why="$why notsealed, no push: '$(k8_eval "$sh" "$cap" "$V" notsealed)';"
      [ "$(k8_eval "$sh" "$cap" "$V" notsealed no-receipt)" = "[ kwhy=no-receipt]" ] || why="$why notsealed: '$(k8_eval "$sh" "$cap" "$V" notsealed no-receipt)';"
    fi
    fin "K8 the cleanstorage field: none on sealed/nothing, kwhy=none or kwhy=<class> on notsealed"
  done
  command rm -f "$fn" "$cap"
  [ -n "$quiet" ] || printf '  -- %d ok, %d failed\n' "$p" "$x"
  [ "$x" -eq 0 ] && return 0 || return 1
}

echo "a refused #keys seal records why: $SUT"
echo "shells: $SHELLS"
suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2          # the harness could not extract, rewrite or parse the functions
[ "$rc" = 0 ] || FAILED=1

if [ "$MUTATE" = yes ]; then
  echo
  echo "mutations (each must CONVICT under every shell):"
  mtmp=$(mktemp -d -p "$W")
  ALLSHELLS="$SHELLS"
  mutate() {  # <label> <sed program>
    local label="$1" prog="$2" mf="$mtmp/r.sh" r s1
    if ! sed "$prog" "$SUT" > "$mf"; then printf '  ERR   %-60s mutation program failed\n' "$label"; MFAIL=1; return; fi
    if cmp -s "$SUT" "$mf"; then printf '  SKIP  %-60s mutation was a NO-OP\n' "$label"; MFAIL=1; return; fi
    # One suite run PER shell, so one shell's conviction cannot hide a survivor on another (mksh is the device's shell).
    for s1 in $ALLSHELLS; do
      SHELLS="$s1"; suite "$mf" quiet >/dev/null 2>&1; r=$?
      case "$r" in
        0) printf '  XX    %-60s SURVIVED [%s]\n' "$label" "$s1"; MFAIL=1 ;;
        1) printf '  ok    %-60s convicted [%s]\n' "$label" "$s1" ;;
        *) printf '  ERR   %-60s harness error (rc=%s) [%s], not a conviction\n' "$label" "$r" "$s1"; MFAIL=1 ;;
      esac
    done
    SHELLS="$ALLSHELLS"
  }
  mutate 'W1 KS_WHY not reset per call (K6)' \
    's/^  KS_WHY=""   # NWP-20261203-22.*$/  :/'
  mutate 'W2 one mark before the ladder (K5)' \
    '/^  _ka=0$/i\
  _kwl=0; [ -f "$STATE/seal.refusal-why" ] && _kwl=$(wc -l < "$STATE/seal.refusal-why" | tr -cd 0-9)
/^    _kwl=0; if /d'
  mutate 'W3 the last keys line of the attempt (K5)' \
    's/{ print \$2; exit }/{ r = $2 } END { if (r != "") print r }/'
  mutate 'W4 kwhy written on a sealed reap (K8, S1)' \
    's/^  _kswf=""; \[ "\$_ksv" = notsealed \] && _kswf=/  _kswf=""; _kswf=/'
  mutate 'W5 a start_count read added to cleanstorage (S2)' \
    '/^  _kswf=""; /a\
  _ksss=$(getprop sys.system_server.start_count 2>/dev/null)'
  mutate 'W6 the field variable unset before the echoes (S3)' \
    '/^  echo "\[roamd\] cleanstorage user \$uid class=/i\
  unset _kswf'
  mutate 'W6b the field variable reused as a loop variable (S3)' \
    '/^  echo "\[roamd\] cleanstorage user \$uid class=/i\
  for _kswf in x; do :; done'
  mutate 'W7 the field variable named _ksf (S3)' \
    's/_kswf/_ksf/g'
  echo
  [ "${MFAIL:-0}" = 0 ] && echo "ALL MUTATIONS BEHAVED" || { echo "PROBLEM: a mutation did not behave"; FAILED=1; }
  command rm -rf "$mtmp"
fi

exit "${FAILED:-0}"
