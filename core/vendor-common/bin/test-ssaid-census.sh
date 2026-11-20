#!/usr/bin/env bash
# test-ssaid-census.sh [<nowhere_roamd.sh>] [--mutate] -- roamd's seedssaid arm counts the settings_ssaid.xml that
# SettingsProvider pre-filled for a new user before it removes it, and leaves the counts in $STATE/ssaid-prefill
# for the session's issue report (NWP-20261207-16).
#
# WHY THIS IS COMMITTED. The backlog row "On a boot after a flash or an OTA, the bundled apps of every sign-in share
# one ANDROID_ID" comes from GrapheneOS source and a log pattern only. The arm used to log one line and remove the
# file, so no report could say what the table held: how many rows, a userkey row or not, how many app rows share
# one value. ssaid_census counts it and prints digits and fixed words only, never a value, a name or a package:
# the table's userkey row is a passphrase VERIFIER when the file is a reaped profile's (DIA-20260815-12). A table
# that cannot be read is UNREAD with a fixed class, never rows=0. This suite plants each table, drives the REAL
# extracted arm and helper under every shell found, and checks roam.log, the state file and the tree.
#
#   bash test-ssaid-census.sh              # the cases
#   bash test-ssaid-census.sh --mutate     # ... plus mutations that must each be CONVICTED under every shell
#   bash test-ssaid-census.sh <old roamd>  # the same cases against another copy (C1 and C8 must FAIL before the fix)
#
# Pure logic -- no device. The arm, userdir_has_record and ssaid_census are EXTRACTED from nowhere_roamd.sh by
# anchor, never copied, and re-rooted to a temp tree; _ms, chown and restorecon are stubbed, print gets a stand-in
# where the shell has no builtin, and abx2xml is a PATH stub that copies the text fixture a fake ABX file names.
# Exit: 0 every case passes; 1 a case failed; 2 the harness could not run.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

# One root for everything this suite makes; nothing is left behind on a pass, a failed check or --mutate.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

KEY64=9f3A0c7E5b21D84e6a0F3c9B17d2E58a4C0e6F1b3D97a2c5E08f4B6d1A3c7e90
# Every value a fixture holds. None may reach roam.log or the state file.
VAL=5e1a9c0b7d3f2468
F2V="a1b2c3d4e5f60718 0f1e2d3c4b5a6978 9a8b7c6d5e4f3021 13579bdf2468ace0"
F3V=7c3e9a1f5b2d8064; F3W=2e4f6a8c0b1d3e57; F3K=d00dfeedcafe1234
SECRETS="$VAL $F2V $F3V $F3W $F3K com.fixture 1012"

# Shells: bash, plus sh/dash/mksh where they are a different interpreter (deduped by realpath).
SHELLS=""; SEEN=" "
for cand in bash sh dash mksh; do
  p=$(command -v "$cand" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$SEEN" in *" $r "*) continue ;; esac
  SEEN="$SEEN$r "; SHELLS="$SHELLS $p"
done
[ -n "$SHELLS" ] || { echo "no POSIX shell found" >&2; exit 2; }

BASEPATH="$PATH"
# F6 needs a PATH with no abx2xml at all; a host that ships one cannot run that case.
if PATH="$BASEPATH" command -v abx2xml >/dev/null 2>&1; then echo "this host has an abx2xml on PATH" >&2; exit 2; fi

# --- fixtures -------------------------------------------------------------------------------------------------
FX="$W/fx"; mkdir -p "$FX" "$W/abxbin" || exit 2
# The abx2xml stub: records its argv (the count, then one argument per line), then acts by $ABX_MODE.
cat > "$W/abxbin/abx2xml" <<'EOF_ABX'
#!/bin/sh
{ echo "$#"; for a in "$@"; do echo "$a"; done; } >> "$ABX_ARGV"
case "${ABX_MODE:-}" in
  fail) exit 1 ;;
  empty) : > "$2"; exit 0 ;;
  none) exit 0 ;;
esac
cp "$(sed -n 2p "$1")" "$2"
EOF_ABX
chmod +x "$W/abxbin/abx2xml" || exit 2

HDR="<?xml version='1.0' encoding='utf-8' standalone='yes' ?>"
# row <id> <name> <value> <package>: one SettingsProvider row; defaultValue= catches a regex without the blank.
row() { printf '<setting id="%s" name="%s" value="%s" package="%s" defaultValue="%s" defaultSysSet="false" tag="null" />' "$1" "$2" "$3" "$4" "$3"; }
# F1: the pre-fill -- six bundled apps sharing one value, and a userkey row holding that SAME value.
{ printf '%s<settings version="-1">' "$HDR"
  printf '<setting id="0" name="userkey" value="%s" package="android" defaultSysSet="false" tag="null" />' "$VAL"
  i=1; for p in alpha beta gamma delta epsilon zeta; do row "$i" "1012$i" "$VAL" "com.fixture.$p"; i=$((i+1)); done
  printf '</settings>\n'; } > "$FX/f1.xml"
# F2: four apps, four values, no userkey.
{ printf '%s<settings version="-1">' "$HDR"
  i=1; for v in $F2V; do row "$i" "1012$i" "$v" "com.fixture.p$i"; i=$((i+1)); done
  printf '</settings>\n'; } > "$FX/f2.xml"
# F3: a TEXT table, one tag per line: a userkey, two apps sharing a value and one on its own.
{ echo "$HDR"; echo '<settings version="-1">'
  printf '<setting id="0" name="userkey" value="%s" package="android" defaultSysSet="false" tag="null" />\n' "$F3K"
  row 1 10121 "$F3V" com.fixture.a; echo; row 2 10122 "$F3V" com.fixture.b; echo; row 3 10123 "$F3W" com.fixture.c; echo
  echo '</settings>'; } > "$FX/f3.xml"
printf 'ABX\n%s\n' "$FX/f1.xml" > "$FX/f1.abx"; printf 'ABX\n%s\n' "$FX/f2.xml" > "$FX/f2.abx"
printf 'PK\003\004 not a table\n' > "$FX/f7.bin"

# --- extraction (the shapes test-seedssaid-stale.sh uses) -----------------------------------------------------
fn_of() { awk -v n="$2" '$0 == n "() {" {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }
nrew() { printf '%s\n' "$1" | grep -o '\$ROOT/data/' | grep -c .; }

NOTED=""
# build <roamd> <out>: the scenario-independent body (stubs + functions + arm) into <out>; 2 when it cannot.
build() {
  local arm fn cf ra rf n
  arm=$(arm_of "$1" seedssaid); fn=$(fn_of "$1" userdir_has_record); cf=$(fn_of "$1" ssaid_census)
  case "$arm" in *nowhere-ssaid-seed*settings_ssaid.xml*|*settings_ssaid.xml*nowhere-ssaid-seed*) ;;
    *) echo "EXTRACTION FAILED: no '  seedssaid)' arm in $1"; return 2 ;; esac
  case "$fn" in 'userdir_has_record() {'*) ;; *) echo "EXTRACTION FAILED: no userdir_has_record in $1"; return 2 ;; esac
  # A roamd from before NWP-20261207-16 has no ssaid_census: run without it, so its cases FAIL (rc 1), not rc 2.
  case "$cf" in 'ssaid_census() {'*) ;;
    *) [ -n "$NOTED" ] || echo "  note: no ssaid_census in $1 (a roamd from before NWP-20261207-16)"; NOTED=1; cf="" ;; esac
  ra=$(reroot "$arm"); rf=$(reroot "$fn")
  n=$(nleft "$ra"); [ "$n" = 0 ] || { echo "RE-ROOT FAILED: $n absolute /data path(s) left in the arm"; return 2; }
  n=$(nleft "$rf"); [ "$n" = 0 ] || { echo "RE-ROOT FAILED: $n absolute /data path(s) left in userdir_has_record"; return 2; }
  n=$(nleft "$cf"); [ "$n" = 0 ] || { echo "RE-ROOT FAILED: $n absolute /data path(s) in ssaid_census"; return 2; }
  n=$(nrew "$ra"); [ "$n" -ge 3 ] || { echo "RE-ROOT FAILED: only $n path(s) rewritten in the arm"; return 2; }
  {
    printf 'op=seedssaid; name=x; uid=11; sesec=%s\n' "$KEY64"
    cat <<'EOF_STUBS'
LOG="$ROOT/roam.log"; RES="$ROOT/res"
_ms() { echo 0; }; chown() { :; }; restorecon() { :; }
if ! command -v print >/dev/null 2>&1; then
  print() {  # mksh's builtin, as the arm uses it: print -rn --
    local nl=1
    while [ $# -gt 0 ]; do case "$1" in -rn|-nr) nl=0; shift ;; -r) shift ;; --) shift; break ;; *) break ;; esac; done
    if [ "$nl" = 1 ]; then printf '%s\n' "$*"; else printf '%s' "$*"; fi
  }
fi
EOF_STUBS
    printf '%s\n' "$rf" "$cf" 'case "$op" in' "$ra" 'esac'
  } > "$2"
}

# --- the cases ----------------------------------------------------------------------------------------------
# suite <roamd> <quiet> <shell>: 0 every case passes, 1 a case failed, 2 the harness could not run.
suite() {
  local sut="$1" quiet="$2" sh="$3" body bad=0 R S U ST ARGV out rc s lg sf cbad
  body=$(mktemp -p "$W") || return 2
  build "$sut" "$body" || return 2
  "$sh" -n "$body" 2>/dev/null || { echo "EXTRACTION FAILED: the extracted arm does not parse under $sh"; return 2; }
  KEYF=$(mktemp -p "$W") || return 2; printf '%s' "$KEY64" > "$KEYF"
  say() { [ -n "$cbad" ] || [ -n "$quiet" ] || echo "$@"; cbad=""; }
  fail() { echo "  FAIL [${sh##*/}] $*"; bad=1; cbad=1; }
  # scen <setup> [<abx mode>] [<path>]: a fresh tree with users/11, its record and user 0's record; <setup>
  # plants the stale name. Leaves R, U, ST (the state dir), ARGV (the stub's record), out, lg (roam.log), sf.
  scen() {
    cbad=""
    R=$(mktemp -d -p "$W") || return 2
    U="$R/data/system/users"; ST="$R/state"; ARGV="$R/abx.argv"
    mkdir -p "$U/0" "$U/11" "$ST"; : > "$U/0.xml"; : > "$U/11.xml"; : > "$ARGV"
    eval "$1"
    S=$(mktemp -p "$W") || return 2
    printf "ROOT='%s'; STATE='%s'; PATH='%s'; ABX_MODE='%s'; ABX_ARGV='%s'; export PATH ABX_MODE ABX_ARGV\n" \
      "$R" "$ST" "${3:-$W/abxbin:$BASEPATH}" "${2:-}" "$ARGV" > "$S"
    cat "$body" >> "$S"
    "$sh" "$S" >/dev/null 2>"$R/stderr"; rc=$?
    out=$(cat "$R/res" 2>/dev/null); lg=$(cat "$R/roam.log" 2>/dev/null); sf=$(cat "$ST/ssaid-prefill" 2>/dev/null)
    [ "$rc" = 0 ] || fail "$CASE: the arm exited $rc"
    s=$(cat "$R/stderr")
    case "$s" in *"not found"*|*"parameter not set"*|*"syntax error"*|*unbound*|*"bad substitution"*|*"No such file"*)
      fail "$CASE: the shell complained: $s" ;; esac
    # Never a value, a package or an app name, in the log or the state file.
    local x
    for x in $SECRETS; do
      case "$lg" in *"$x"*) fail "$CASE: roam.log holds the fixture string $x" ;; esac
      case "$sf" in *"$x"*) fail "$CASE: the state file holds the fixture string $x" ;; esac
    done
    return 0
  }
  # landed <state line>: the checks every case that reaches the staging shares.
  landed() {
    [ "$out" = OK ] || fail "$CASE: reply '$out', want OK"
    [ ! -e "$U/11/settings_ssaid.xml" ] && [ ! -L "$U/11/settings_ssaid.xml" ] || fail "$CASE: the stale file was not removed"
    [ -f "$U/11/nowhere-ssaid-seed" ] && cmp -s "$KEYF" "$U/11/nowhere-ssaid-seed" || fail "$CASE: the seed is not staged"
    [ "$sf" = "$1" ] || fail "$CASE: state file '$sf', want '$1'"
    s=$(ls -A "$ST"); [ "$s" = ssaid-prefill ] || fail "$CASE: \$STATE holds '$s', want ssaid-prefill only"
  }
  # census <counts or class>: the census line and the arm's own removal line, both in roam.log.
  census() {
    case "$lg" in *"[roamd] seedssaid stale table user 11: $1 (NWP-20261207-16) "*) ;;
      *) fail "$CASE: roam.log has no 'seedssaid stale table user 11: $1' line" ;; esac
    case "$lg" in *"seedssaid removing stale ssaid from a recycled user id 11 "*) ;;
      *) fail "$CASE: the 'removing stale ssaid' line is gone" ;; esac
  }
  noabx() { s=$(cat "$ARGV"); [ -z "$s" ] || fail "$CASE: abx2xml was called"; }

  CASE="C1 (F1) the pre-fill: six apps share one value, the userkey holds it too"
  scen 'cp "$FX/f1.abx" "$U/11/settings_ssaid.xml"' || return 2
  census "rows=7 userkey=1 apps=6 distinct=1 largest=6"
  landed "v=1 rows=7 userkey=1 apps=6 distinct=1 largest=6"
  s=$(sed -n 1p "$ARGV"); [ "$s" = 2 ] || fail "$CASE: abx2xml got '$s' arguments, want 2"
  s=$(sed -n 2p "$ARGV"); [ "$s" = "$U/11/settings_ssaid.xml" ] || fail "$CASE: abx2xml's input is '$s'"
  s=$(sed -n 3p "$ARGV"); case "$s" in "$ST"/?*) ;; *) fail "$CASE: abx2xml's output '$s' is not in \$STATE" ;; esac
  say "  ok [${sh##*/}] $CASE"

  CASE="C2 (F2) four apps, four values, no userkey"
  scen 'cp "$FX/f2.abx" "$U/11/settings_ssaid.xml"' || return 2
  census "rows=4 userkey=0 apps=4 distinct=4 largest=1"
  landed "v=1 rows=4 userkey=0 apps=4 distinct=4 largest=1"
  say "  ok [${sh##*/}] $CASE"

  CASE="C3 (F3) a text table is counted without abx2xml"
  scen 'cp "$FX/f3.xml" "$U/11/settings_ssaid.xml"' || return 2
  census "rows=4 userkey=1 apps=3 distinct=2 largest=2"
  landed "v=1 rows=4 userkey=1 apps=3 distinct=2 largest=2"
  noabx
  say "  ok [${sh##*/}] $CASE"

  CASE="C4 (F4) abx2xml fails"
  scen 'cp "$FX/f1.abx" "$U/11/settings_ssaid.xml"' fail || return 2
  census "unread=convert"; landed "v=1 unread=convert"
  say "  ok [${sh##*/}] $CASE"

  CASE="C5 (F5) abx2xml writes an empty file: the <settings control"
  scen 'cp "$FX/f1.abx" "$U/11/settings_ssaid.xml"' empty || return 2
  census "unread=parse"; landed "v=1 unread=parse"
  say "  ok [${sh##*/}] $CASE"

  CASE="C5b abx2xml exits 0 and writes no file"
  scen 'cp "$FX/f1.abx" "$U/11/settings_ssaid.xml"' none || return 2
  census "unread=convert"; landed "v=1 unread=convert"
  say "  ok [${sh##*/}] $CASE"

  CASE="C6 (F6) no abx2xml on PATH"
  scen 'cp "$FX/f1.abx" "$U/11/settings_ssaid.xml"' "" "$BASEPATH" || return 2
  census "unread=notool"; landed "v=1 unread=notool"
  say "  ok [${sh##*/}] $CASE"

  CASE="C7 (F7) first bytes PK"
  scen 'cp "$FX/f7.bin" "$U/11/settings_ssaid.xml"' || return 2
  census "unread=format"; landed "v=1 unread=format"; noabx
  say "  ok [${sh##*/}] $CASE"

  CASE="C8 (F8) no stale file"
  scen ':' || return 2
  landed "v=1 none"
  case "$lg" in *"stale table"*) fail "$CASE: a census line with no stale file" ;; esac
  noabx
  say "  ok [${sh##*/}] $CASE"

  CASE="C9 (F9) an early refusal (ERR-NOUSER) leaves no older session's file"
  scen 'echo "v=1 rows=1 userkey=0 apps=1 distinct=1 largest=1" > "$ST/ssaid-prefill"; rm -f "$U/11.xml"' || return 2
  [ "$out" = ERR-NOUSER ] || fail "$CASE: reply '$out', want ERR-NOUSER"
  [ ! -e "$ST/ssaid-prefill" ] || fail "$CASE: the previous ssaid-prefill is still there"
  s=$(ls -A "$ST"); [ -z "$s" ] || fail "$CASE: \$STATE holds '$s', want nothing"
  say "  ok [${sh##*/}] $CASE"

  CASE="C10 (F10) a symbolic link at the stale name is never read through"
  scen 'cp "$FX/f1.abx" "$R/target"; ln -s "$R/target" "$U/11/settings_ssaid.xml"' || return 2
  census "unread=link"; landed "v=1 unread=link"; noabx
  [ -f "$R/target" ] || fail "$CASE: the link's target was removed"
  say "  ok [${sh##*/}] $CASE"

  CASE="C11 a stale DIRECTORY (ERR-STALE) leaves no ssaid-prefill"
  scen 'mkdir -p "$U/11/settings_ssaid.xml"; : > "$U/11/settings_ssaid.xml/x"' || return 2
  [ "$out" = ERR-STALE ] || fail "$CASE: reply '$out', want ERR-STALE"
  case "$lg" in *"seedssaid stale table user 11: unread=format (NWP-20261207-16) "*) ;;
    *) fail "$CASE: roam.log has no 'stale table user 11: unread=format' line" ;; esac
  s=$(ls -A "$ST"); [ -z "$s" ] || fail "$CASE: \$STATE holds '$s', want nothing"
  say "  ok [${sh##*/}] $CASE"
  return $bad
}

echo "== $SUT (shells:$SHELLS)"
rc=0
for sh in $SHELLS; do suite "$SUT" "" "$sh"; r=$?; [ "$r" -gt "$rc" ] && rc=$r; done
[ "$rc" = 0 ] || { echo "FAILED"; exit "$rc"; }
echo "== all cases pass"
[ "$MUTATE" = yes ] || exit 0

echo "== mutations (each must be CONVICTED)"
# mut <label> <sed|awk> <program>: convicted under EACH shell's own line; inert, empty or failed is a failure.
mut() {
  local m r sh bad=0
  m=$(mktemp -p "$W")
  "$2" -e "$3" "$SUT" > "$m" || { echo "  ERROR     $1 -- the $2 program failed"; return 1; }
  [ -s "$m" ] || { echo "  ERROR     $1 -- the mutant is empty"; return 1; }
  if cmp -s "$SUT" "$m"; then echo "  INERT     $1 -- the mutation changed nothing"; return 1; fi
  for sh in $SHELLS; do
    suite "$m" quiet "$sh" >/dev/null 2>&1; r=$?
    case "$r" in
      1) echo "  convicted $1 [${sh##*/}]" ;;
      0) echo "  SURVIVED  $1 [${sh##*/}]"; bad=1 ;;
      *) echo "  BROKEN    $1 [${sh##*/}] (rc=$r), not a conviction"; bad=1 ;;
    esac
  done
  return $bad
}
fails=0
mut "N1 a failed conversion reported as rows=0 (C4)" sed \
  's/rm -f "\$_t" 2>\/dev\/null; echo "v=1 unread=convert"; return 0/rm -f "$_t" 2>\/dev\/null; echo "v=1 rows=0 userkey=0 apps=0 distinct=0 largest=0"; return 0/' \
  || fails=$((fails+1))
mut "N2 the <settings control dropped (C5)" sed \
  's/if (!root) { print "parse"; exit }//' || fails=$((fails+1))
mut "N3 the userkey row grouped with the apps (C1: largest 7)" sed \
  's/if (av(l, "name") == "userkey") { uk++; continue }/if (av(l, "name") == "userkey") { uk++ }/' || fails=$((fails+1))
mut "N4 largest computed as distinct (C1: largest 1)" sed \
  's/rows - uk, d, big }$/rows - uk, d, d }/' || fails=$((fails+1))
mut "N5 the tmp not removed (C1: \$STATE holds only ssaid-prefill)" sed \
  '/^  \[ -n "\$_t" \] && rm -f "\$_t" 2>\/dev\/null$/d' || fails=$((fails+1))
mut "N6 the census moved after the rm (C1: the counts are gone)" awk '
  /^      _sc=\$\(ssaid_census "\$_stale"\)$/ || /^      echo "\[roamd\] seedssaid stale table user / { blk = blk $0 "\n"; next }
  { print }
  /^      rm -f "\$_stale" 2>>"\$LOG"$/ { printf "%s", blk; blk = "" }' || fails=$((fails+1))
mut "N7 the arm's opening rm of ssaid-prefill dropped (C9)" sed \
  '/^    \[ -n "\${STATE:-}" \] && rm -f "\$STATE\/ssaid-prefill" 2>\/dev\/null$/d' || fails=$((fails+1))
mut "N8 the link check dropped (C10)" sed \
  '/^  if \[ -L "\$1" \]; then echo "v=1 unread=link"; return 0; fi$/d' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
