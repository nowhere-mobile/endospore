#!/usr/bin/env bash
# test-grant-keystore-sweep.sh [<nowhere_roamd.sh>] [--mutate] -- the grant arm stages this session's restored #keys
# bundles before switch-in, for one `pm` call (NWP-20261113-05).
#
# WHY THIS IS COMMITTED. A restored bundle moves from keystore-in/<uid> to the keystore2 import dir only in
# keystore_register, reached from odrestore (an on-demand tap, the login-time odrestore of installed apps) and from
# keystore_register_all, which ran only in the `out` arm. A bundled (system / /product) app never passes odrestore,
# so its carried keys waited for the first periodic seal: on the S3 device-proof run `#keys restored (1 bundle(s))`
# at 17:33:31, Seedvault staged for import only at 17:36:21. An app that looks up its key in that window misses the
# carry, and a create-on-miss app mints fresh keys whose dump then wins at logoff. The grant arm (the chooser's last
# login step, before switch-in) now runs keystore_register_all, and the sweep passes each bundle the namespace from
# its own `pm` capture, so the whole sweep is one `pm` call. Cases, under every shell found (bash sh dash mksh):
#   - after the REAL grant arm, the two bundles whose packages pm lists are in the import dir as <ns>.keys with
#     their planted contents, and gone from keystore-in/<uid>;
#   - a bundle whose package pm does not list stays in keystore-in (odrestore's, as before);
#   - KS_MAP holds the two packages' rows;
#   - pm -U ran at most twice (one sweep call, plus the unlisted package's own fallback lookup);
#   - roam.log holds exactly one `TIMING grant-keystore` line and the arm completed (OK);
#   - a bundle named for a prefix of a listed package (com.ex.bundle vs com.ex.bundled) is not given that
#     package's namespace: the capture is matched by the whole `package:<pkg> uid:<n>` line;
#   - NWP-20261119-08, the staging cost is bounded: with 1, 3 and 12 planted bundles the sweep runs restorecon, chown
#     and chmod each exactly twice (once on the import dir, once over every staged file), the one restorecon over the
#     files names every staged path, each bundle lands as <ns>.keys, an unlisted package keeps its bundle, `date`
#     runs the same number of times whatever the bundle count, and `basename` never runs;
#   - the single-package keystore_register call (odrestore, the tap: no batch argument) still runs its own
#     restorecon, chown and chmod of the import dir and of the staged file, twice each, as before.
# The arm, keystore_register_all, keystore_register and ks_in_dir are extracted from nowhere_roamd.sh BY ANCHOR,
# never copied; every other helper the arm calls is a no-op stub. restorecon, chown, chmod, mv, date and basename are
# stubs that log each call (mv still moves).
#
# Mutants: M1-M5 above the bounded cost; m1 the per-file restorecon back inside the loop; m2 the one restorecon over
# the staged files dropped; m3 the import dir prepared per bundle again; m4 batch mode leaks into the single-package
# call. A mutated copy that any shell refuses as a syntax error is a mutant FAILURE, never a conviction.
#
#   bash test-grant-keystore-sweep.sh            # the cases
#   bash test-grant-keystore-sweep.sh --mutate   # ... plus mutants that must each CONVICT the suite under every shell
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

# extract <script> <out> [noarm] -> 0 when every anchor was found; <out> is a runnable body: the four pieces, then the
# arm (left out with noarm)
extract() {
  local f="$1" out="$2" noarm="${3:-}" piece fn
  : > "$out"
  for fn in _ms _tlog; do
    piece=$(sed -n "/^$fn() /p" "$f")
    [ -n "$piece" ] || return 1
    printf '%s\n' "$piece" >> "$out"
  done
  for fn in ks_in_dir keystore_register keystore_register_all; do
    piece=$(sed -n "/^$fn() {\$/,/^}\$/p" "$f")
    [ -n "$piece" ] || return 1
    printf '%s\n' "$piece" >> "$out"
  done
  [ -z "$noarm" ] || return 0
  # The arm minus its `grant)` and `;;` lines, so it runs as a body.
  piece=$(sed -n '/^  grant)$/,/^    ;;$/p' "$f" | sed '1d;$d')
  [ -n "$piece" ] || return 1
  printf '%s\n' "$piece" >> "$out"
}

# suite <script> <shell> [quiet] -> 0 when every case behaved
suite() {
  local f="$1" sh_="$2" quiet="${3:-}" p=0 x=0 body body1 T run n k nb dt dt1 paths miss
  ok() { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    [%s] %s\n' "$sh_" "$1"; }
  no() { x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  [%s] %s\n' "$sh_" "$1"; }
  body=$(mktemp -p "$W") || return 2
  extract "$f" "$body" || { no "EXTRACTION FAILED -- _ms, _tlog, ks_in_dir, keystore_register(_all) or the grant arm is missing in $f"; rm -f "$body"; return 1; }
  body1=$(mktemp -p "$W") || return 2
  extract "$f" "$body1" noarm || { no "EXTRACTION FAILED -- the functions are missing in $f"; rm -f "$body" "$body1"; return 1; }

  # prep <dir> [<body> <last line>] -> writes <dir>/run.sh: the re-rooted body (default: the functions and the arm)
  # behind the variables and stubs it needs, then <last line>. <dir>/pmfix, when present, is pm -U's answer.
  prep() {
    local d="$1" b="${2:-$body}" last="${3:-}"
    mkdir -p "$d/data/nowhere/keystore-in/10" "$d/data/misc/keystore" "$d/state"
    : > "$d/log"; : > "$d/pmlog"; : > "$d/rc"; : > "$d/co"; : > "$d/cm"; : > "$d/mv"; : > "$d/dt"; : > "$d/bn"
    {
      printf "uid=10; LOG='%s'; STATE='%s'; RES='%s'; PMLOG='%s'; PMFIX='%s'\n" "$d/log" "$d/state" "$d/res" "$d/pmlog" "$d/pmfix"
      printf "RCLOG='%s'; COLOG='%s'; CMLOG='%s'; MVLOG='%s'; DTLOG='%s'; BNLOG='%s'\n" \
        "$d/rc" "$d/co" "$d/cm" "$d/mv" "$d/dt" "$d/bn"
      printf "KS_IN='%s'; KS_IMPORT='%s'; KS_MAP='%s'; KS_EXPORT='%s'\n" \
        "$d/data/nowhere/keystore-in" "$d/data/misc/keystore/nowhere-import" "$d/data/nowhere/keystore-map" \
        "$d/data/misc/keystore/nowhere-export"
      printf '%s\n' "ACCT_AUTH_PKG=com.google.android.gms; PLAY_STORE_PKG=com.android.vending"
      printf '%s\n' 'home_pin() { :; }; nav_apply() { :; }; aod_apply() { :; }; a11y_apply() { :; }; autofill_apply() { :; }'
      printf '%s\n' 'grant_perms_for() { :; }; acct_reload() { :; }; sync_apply() { :; }; keystore_unit() { :; }; am() { :; }'
      printf '%s\n' 'chmod() { echo "$*" >> "$CMLOG"; }; chown() { echo "$*" >> "$COLOG"; }; restorecon() { echo "$*" >> "$RCLOG"; }'
      printf '%s\n' 'mv() { echo "$*" >> "$MVLOG"; command mv "$@"; }; basename() { echo "$*" >> "$BNLOG"; command basename "$@"; }'
      printf '%s\n' 'date() { echo x >> "$DTLOG"; echo DATE; }'
      printf '%s\n' 'pm() { echo "$*" >> "$PMLOG"; case "$*" in *-U*) if [ -f "$PMFIX" ]; then cat "$PMFIX"; else printf "package:com.ex.bundled uid:1010072\npackage:com.ex.other uid:1010080\n"; fi ;; esac; return 0; }'
      sed "s#/data/#$d/data/#g" "$b"
      [ -z "$last" ] || printf '%s\n' "$last"
    } > "$d/run.sh"
  }
  # cnt <file> -> its line count (0 when absent)
  cnt() { local c; c=$(wc -l < "$1" 2>/dev/null) || c=0; echo $((c+0)); }

  # ---- case 1: two listed bundles and one unlisted ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T"
  printf 'bundled-keys\n' > "$T/data/nowhere/keystore-in/10/com.ex.bundled.keys"
  printf 'other-keys\n'   > "$T/data/nowhere/keystore-in/10/com.ex.other.keys"
  printf 'absent-keys\n'  > "$T/data/nowhere/keystore-in/10/com.ex.absent.keys"
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  run="$T/data/misc/keystore/nowhere-import"
  [ "$(cat "$run/1010072.keys" 2>/dev/null)" = bundled-keys ] && [ "$(cat "$run/1010080.keys" 2>/dev/null)" = other-keys ] \
    && ok "both listed bundles are staged for import as <ns>.keys" \
    || no "listed bundles not staged: import dir holds '$(ls "$run" 2>/dev/null | tr '\n' ' ')'"
  [ ! -e "$T/data/nowhere/keystore-in/10/com.ex.bundled.keys" ] && [ ! -e "$T/data/nowhere/keystore-in/10/com.ex.other.keys" ] \
    && ok "the staged bundles have left keystore-in" || no "a listed bundle is still in keystore-in after the grant"
  [ "$(cat "$T/data/nowhere/keystore-in/10/com.ex.absent.keys" 2>/dev/null)" = absent-keys ] \
    && ok "an unlisted package's bundle stays in keystore-in for odrestore" || no "the unlisted package's bundle was moved or lost"
  n=$(grep -cxE '1010072 com\.ex\.bundled|1010080 com\.ex\.other' "$T/data/nowhere/keystore-map" 2>/dev/null)
  [ "$n" = 2 ] && ok "KS_MAP holds both packages' rows" || no "KS_MAP holds ${n:-0} of the 2 rows"
  n=$(grep -c -- '-U' "$T/pmlog" 2>/dev/null); n=${n:-0}
  [ "$n" -ge 1 ] && [ "$n" -le 2 ] && ok "pm -U ran $n time(s) (one sweep call, at most one fallback)" || no "pm -U ran $n time(s), want 1 or 2"
  n=$(grep -c '^\[roamd\] TIMING grant-keystore ' "$T/log" 2>/dev/null)
  [ "$n" = 1 ] && ok "one TIMING grant-keystore line" || no "${n:-0} TIMING grant-keystore line(s), want 1"
  [ "$(cat "$T/res" 2>/dev/null)" = OK ] && ok "the arm completed (OK)" || no "the arm did not complete: res='$(cat "$T/res" 2>/dev/null)'"

  # ---- case 2: a bundle named for a prefix of a listed package ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T"
  printf 'prefix-keys\n'  > "$T/data/nowhere/keystore-in/10/com.ex.bundle.keys"
  printf 'bundled-keys\n' > "$T/data/nowhere/keystore-in/10/com.ex.bundled.keys"
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  [ "$(cat "$T/data/nowhere/keystore-in/10/com.ex.bundle.keys" 2>/dev/null)" = prefix-keys ] \
    && [ "$(cat "$T/data/misc/keystore/nowhere-import/1010072.keys" 2>/dev/null)" = bundled-keys ] \
    && ok "a prefix of a listed package is not given its namespace" \
    || no "com.ex.bundle took com.ex.bundled's namespace (or com.ex.bundled was not staged)"

  # ---- case 3 (NWP-20261119-08): 1, 3 and 12 bundles cost the same restorecon, chown and chmod ----
  dt1=""
  for nb in 1 3 12; do
    T=$(mktemp -d -p "$W") || return 2
    prep "$T"
    run="$T/data/misc/keystore/nowhere-import"
    k=1; : > "$T/pmfix"
    while [ "$k" -le "$nb" ]; do
      printf 'package:com.ex.p%d uid:%d\n' "$k" $((1010100+k)) >> "$T/pmfix"
      printf 'keys-%d\n' "$k" > "$T/data/nowhere/keystore-in/10/com.ex.p$k.keys"
      k=$((k+1))
    done
    printf 'unlisted-keys\n' > "$T/data/nowhere/keystore-in/10/com.ex.unlisted.keys"
    "$sh_" "$T/run.sh" >/dev/null 2>&1
    [ "$(cnt "$T/rc")" = 2 ] && [ "$(cnt "$T/co")" = 2 ] && [ "$(cnt "$T/cm")" = 2 ] \
      && ok "$nb bundle(s): restorecon, chown and chmod ran twice each" \
      || no "$nb bundle(s): restorecon ran $(cnt "$T/rc"), chown $(cnt "$T/co"), chmod $(cnt "$T/cm") time(s), want 2 each"
    [ "$(sed -n 1p "$T/rc")" = "$run" ] && ok "$nb bundle(s): the first restorecon is the import dir alone" \
      || no "$nb bundle(s): the first restorecon is '$(sed -n 1p "$T/rc")', want the import dir"
    paths=" $(sed -n 2p "$T/rc") "; miss=""; k=1
    while [ "$k" -le "$nb" ]; do
      case "$paths" in *" $run/$((1010100+k)).keys "*) ;; *) miss="$miss $((1010100+k))" ;; esac
      [ "$(cat "$run/$((1010100+k)).keys" 2>/dev/null)" = "keys-$k" ] && [ ! -e "$T/data/nowhere/keystore-in/10/com.ex.p$k.keys" ] \
        || miss="$miss land:$k"
      k=$((k+1))
    done
    [ -z "$miss" ] && ok "$nb bundle(s): every bundle lands as <ns>.keys and is in the one restorecon over the files" \
      || no "$nb bundle(s): not landed or not in the second restorecon:$miss"
    [ "$(cat "$T/data/nowhere/keystore-in/10/com.ex.unlisted.keys" 2>/dev/null)" = unlisted-keys ] \
      && ok "$nb bundle(s): the unlisted package keeps its bundle" || no "$nb bundle(s): the unlisted bundle was moved or lost"
    [ "$(cnt "$T/bn")" = 0 ] && ok "$nb bundle(s): basename ran 0 times" || no "$nb bundle(s): basename ran $(cnt "$T/bn") time(s), want 0"
    n=$(grep -c "), $nb bundle(s) staged " "$T/log" 2>/dev/null)
    [ "$n" = 1 ] && ok "$nb bundle(s): the summary line counts $nb bundle(s) staged" || no "$nb bundle(s): no summary line with '$nb bundle(s) staged'"
    dt=$(cnt "$T/dt"); [ -n "$dt1" ] || dt1=$dt
    [ "$dt" = "$dt1" ] && ok "$nb bundle(s): date ran $dt time(s), as with 1 bundle" || no "$nb bundle(s): date ran $dt time(s), $dt1 with 1 bundle"
  done

  # ---- case 4 (NWP-20261119-08): the single-package call stages as before ----
  T=$(mktemp -d -p "$W") || return 2
  prep "$T" "$body1" 'keystore_register com.ex.bundled'
  run="$T/data/misc/keystore/nowhere-import"
  printf 'bundled-keys\n' > "$T/data/nowhere/keystore-in/10/com.ex.bundled.keys"
  "$sh_" "$T/run.sh" >/dev/null 2>&1
  [ "$(cat "$run/1010072.keys" 2>/dev/null)" = bundled-keys ] && ok "single-package call: the bundle lands as <ns>.keys" \
    || no "single-package call: the bundle did not land"
  [ "$(tr '\n' ';' < "$T/rc")" = "$run;$run/1010072.keys;" ] \
    && ok "single-package call: restorecon of the dir, then of the file" || no "single-package call: restorecon calls '$(tr '\n' ';' < "$T/rc")'"
  [ "$(cnt "$T/co")" = 2 ] && [ "$(cnt "$T/cm")" = 2 ] && ok "single-package call: chown and chmod ran twice each" \
    || no "single-package call: chown ran $(cnt "$T/co"), chmod $(cnt "$T/cm") time(s), want 2 each"

  rm -f "$body" "$body1"
  [ -n "$quiet" ] || printf '  [%s] (%d ok, %d failed)\n' "$sh_" "$p" "$x"
  [ "$x" = 0 ]
}

probe=$(mktemp -p "$W") || exit 2
extract "$SUT" "$probe" || { echo "EXTRACTION FAILED -- a function or the grant arm is missing in $SUT"; exit 2; }
rm -f "$probe"

RC=0
for s in $SHELLS; do
  echo "== as committed [$s] =="
  suite "$SUT" "$s" || RC=1
done
[ "$MUTATE" = no ] && { echo; [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"; exit $RC; }
[ "$RC" = 0 ] || { echo; echo "suite already failing -- fix that before mutating"; exit "$RC"; }

echo; echo "== mutants (each MUST be convicted under every shell) =="
MRC=0
CALL='^    _tt=\$(_ms); keystore_register_all; _tlog grant-keystore "\$_tt"$'
mutant() {  # $1 label, then sed arguments
  local m mb s_ label="$1"; shift
  m=$(mktemp -p "$W") || { MRC=1; return; }
  sed "$@" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then printf '  ⚠ DID NOT APPLY  %s\n' "$label"; MRC=1; rm -f "$m"; return; fi
  # The suite runs the extracted body, never the whole file (M2 leaves the file invalid on purpose), so the body is
  # what must parse: a body any shell refuses would convict by a syntax error, which proves nothing.
  mb=$(mktemp -p "$W") || { MRC=1; rm -f "$m"; return; }
  extract "$m" "$mb"
  for s_ in $SHELLS; do
    if ! "$s_" -n "$mb" >/dev/null 2>&1; then printf '  ⚠ SYNTAX ERROR [%s] %s\n' "$s_" "$label"; MRC=1; rm -f "$m" "$mb"; return; fi
  done
  rm -f "$mb"
  for s_ in $SHELLS; do
    if suite "$m" "$s_" quiet; then printf '  ⚠ SURVIVED  [%s] %s\n' "$s_" "$label"; MRC=1; else printf '  convicted   [%s] %s\n' "$s_" "$label"; fi
  done
  rm -f "$m"
}
mutant "M1 the grant arm's keystore_register_all call is deleted" -e "/$CALL/d"
mutant "M2 the call moves after the grant arm's ;; (outside the arm)" \
  -e "/$CALL/{h;d;}" -e '/^  grant)$/,/^    ;;$/{/^    ;;$/G;}'
mutant "M3 keystore_register skips the promotion" \
  -e 's#^  if \[ -n "\$_krd" \] && \[ -f "\$_krd/\$_p.keys" \]; then$#  if false; then#'
mutant "M4 the promotion loop passes \"\" again (one pm call per bundle)" \
  -e 's#keystore_register "\$_kpk" "\$_kns" batch >/dev/null#keystore_register "$_kpk" "" batch >/dev/null#'
mutant "M5 the capture match drops the line anchor (a prefix takes a longer package's ns)" \
  -e 's#_kns=\${_kpu\#\*"\${_knl}package:\$_kpk uid:"}#_kns=${_kpu\#*"package:$_kpk"}; _kns=${_kns\#*" uid:"}#' \
  -e 's#\*"\${_knl}package:\$_kpk uid:"\[0-9\]\*)#*"package:$_kpk"*)#'
mutant "m1 the per-file restorecon is back inside the loop (the count grows with the bundles)" \
  -e 's#^\( *\)KS_BATCH="\$KS_BATCH \$_ns"$#&; restorecon "$KS_IMPORT/$_ns.keys" 2>>"$LOG"#'
mutant "m2 the one restorecon over the staged files is dropped" \
  -e '/^ *restorecon "\$@" 2>>"\$LOG" ||/d'
mutant "m3 the import dir is prepared per bundle again (keystore_register's batch path)" \
  -e '/# NWP-20261119-08: import dir, once$/d' \
  -e 's#^\( *\)if \[ "\$_kb" != batch \]; then *\# NWP-20261119-08: the sweep prepares the dir in batch mode$#\1if :; then#'
mutant "m4 batch mode leaks into the single-package call" \
  -e 's#^\( *\)local _kb="\${3:-}"#\1local _kb=batch#'
echo; [ "$MRC" = 0 ] && echo "all mutants convicted" || echo "SOME MUTANTS NOT CONVICTED"
exit $MRC
