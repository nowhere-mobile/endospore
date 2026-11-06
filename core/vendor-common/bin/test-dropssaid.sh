#!/usr/bin/env bash
# test-dropssaid.sh [--mutate] [roamd] -- NWP-20261115-01 (dn-1023 #4): roamd's dropssaid op, the gate's clean-up of a
# sign-in that did not land. It removes exactly nowhere-ssaid-seed and settings_ssaid.xml from users/<uid>: never
# through a link at users/<uid>, never creating the directory, never for a uid under 10, and it answers ERR-RM when a
# file stays. The arm is extracted with arm_of and /data is re-rooted (as test-userdir-orphan.sh does); every case runs
# under each shell found of bash, sh, dash and mksh. --mutate: each D mutant must be CONVICTED under every shell found;
# one that does not apply is INERT, a failure.
set -u
SUT=${2:-$(dirname "$0")/nowhere_roamd.sh}
[ "${1:-}" = --mutate ] || [ "${1:-}" = "" ] || SUT=$1
[ -f "$SUT" ] || { echo "no roamd at $SUT"; exit 2; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

arm_of() { awk -v a="  $2)" '$0 == a {f=1} f{print} f&&/^    ;;$/{exit}' "$1"; }
reroot() { printf '%s\n' "$1" | sed -E 's#([" ])/data/#\1$ROOT/data/#g'; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }
nrew() { printf '%s\n' "$1" | grep -o '\$ROOT/data/' | grep -c .; }

SHELLS=""
for s in bash sh dash mksh; do
  if command -v "$s" >/dev/null 2>&1; then SHELLS="$SHELLS $s"; else echo "skip $s (not found)"; fi
done
[ -n "$SHELLS" ] || { echo "no shell found"; exit 2; }

HEX=d0a5e1f7c3b9a2e46f81c0d7b5e3a9f2c4d6e8a0b1c3d5e7f9a2b4c6d8e0f1a3

# extract <roamd> <out-file>: the re-rooted arm, or exit 2 when the extraction or the re-root is not complete.
extract() {
  local arm ra nr nl
  arm=$(arm_of "$1" dropssaid)
  case "$arm" in *nowhere-ssaid-seed*) ;; *) echo "EXTRACT FAILED: no dropssaid arm in $1"; exit 2 ;; esac
  case "$arm" in *'
    ;;') ;; *) echo "EXTRACT FAILED: the arm does not end with its ;; line"; exit 2 ;; esac
  ra=$(reroot "$arm")
  nr=$(nrew "$ra"); nl=$(nleft "$ra")
  if [ "$nr" -lt 1 ] || [ "$nl" -ne 0 ]; then echo "RE-ROOT INCOMPLETE ($nr rewritten, $nl left)"; exit 2; fi
  printf '%s\n' "$ra" > "$2"
}

# run_arm <shell> <arm-file> <root> <uid> [stub-file]: runs the arm as roamd would, the reply in $root/res.
run_arm() {
  local sh=$1 armf=$2 root=$3 uid=$4 stub=${5:-} drv
  drv=$(mktemp -p "$W")
  {
    printf 'ROOT=%s\nuid=%s\nop=dropssaid\nname=x\npass=\n' "'$root'" "'$uid'"
    printf 'LOG="$ROOT/roam.log"\nRES="$ROOT/res"\nSTATE="$ROOT/state"\n'
    [ -n "$stub" ] && cat "$stub"
    printf 'case "$op" in\n'
    cat "$armf"
    printf 'esac\n'
  } > "$drv"
  "$sh" "$drv" 2>>"$root/stderr"
}

FAILS=0
# fail <label>: one failed check of the current run.
fail() { echo "    FAIL $1"; FAILS=$((FAILS + 1)); }

# res_is <root> <want> <label>
res_is() {
  local got
  got=$(cat "$1/res" 2>/dev/null)
  [ "$got" = "$2" ] || fail "$3: reply '$got', want '$2'"
}

mkroot() {
  local r
  r=$(mktemp -d -p "$W")
  mkdir -p "$r/state" "$r/data/system/users"
  printf '%s\n' "$r"
}

# cases <shell> <arm-file>: every case once under one shell; leaves the failed-check count in FAILS.
cases() {
  local sh=$1 armf=$2 r d u stub log e
  # C1 both files: both gone; the directory and the other files untouched.
  r=$(mkroot); d="$r/data/system/users/17"; mkdir -p "$d"
  printf '%s' "$HEX" > "$d/nowhere-ssaid-seed"; printf 'x' > "$d/settings_ssaid.xml"
  printf 's' > "$d/settings_secure.xml"; printf 'o' > "$d/nowhere-other"
  run_arm "$sh" "$armf" "$r" 17
  res_is "$r" "OK 2" "C1 both files"
  [ -e "$d/nowhere-ssaid-seed" ] && fail "C1 the seed is still there"
  [ -e "$d/settings_ssaid.xml" ] && fail "C1 settings_ssaid.xml is still there"
  [ -d "$d" ] || fail "C1 the directory is gone"
  [ -e "$d/settings_secure.xml" ] || fail "C1 settings_secure.xml was removed"
  [ -e "$d/nowhere-other" ] || fail "C1 nowhere-other was removed"
  # C8 the log: the uid and the counts, never the seed's content.
  log=$(cat "$r/roam.log" 2>/dev/null)
  case "$log" in *"dropssaid user 17: 2 SSAID file(s) removed, 0 stuck"*) ;; *) fail "C8 the log line is '$log'" ;; esac
  case "$log" in *"$HEX"*) fail "C8 the log holds the seed's content" ;; esac
  e=$(cat "$r/stderr" 2>/dev/null); [ -z "$e" ] || fail "C1 stderr: $e"

  # C2 only the seed.
  r=$(mkroot); d="$r/data/system/users/17"; mkdir -p "$d"; printf '%s' "$HEX" > "$d/nowhere-ssaid-seed"
  run_arm "$sh" "$armf" "$r" 17
  res_is "$r" "OK 1" "C2 only the seed"
  [ -e "$d/nowhere-ssaid-seed" ] && fail "C2 the seed is still there"

  # C3 neither file.
  r=$(mkroot); d="$r/data/system/users/17"; mkdir -p "$d"
  run_arm "$sh" "$armf" "$r" 17
  res_is "$r" "OK 0" "C3 neither file"
  [ -d "$d" ] || fail "C3 the directory is gone"

  # C4 no directory: OK 0, and it is not created.
  r=$(mkroot); d="$r/data/system/users/17"
  run_arm "$sh" "$armf" "$r" 17
  res_is "$r" "OK 0" "C4 no directory"
  if [ -e "$d" ] || [ -L "$d" ]; then fail "C4 the directory was created"; fi

  # C5 users/17 a symbolic link to a directory holding both files: ERR-LINK, nothing removed.
  r=$(mkroot); mkdir -p "$r/elsewhere"
  printf '%s' "$HEX" > "$r/elsewhere/nowhere-ssaid-seed"; printf 'x' > "$r/elsewhere/settings_ssaid.xml"
  ln -s "$r/elsewhere" "$r/data/system/users/17"
  run_arm "$sh" "$armf" "$r" 17
  res_is "$r" "ERR-LINK" "C5 a link"
  [ -e "$r/elsewhere/nowhere-ssaid-seed" ] || fail "C5 the seed behind the link was removed"
  [ -e "$r/elsewhere/settings_ssaid.xml" ] || fail "C5 settings_ssaid.xml behind the link was removed"
  [ -L "$r/data/system/users/17" ] || fail "C5 the link is gone"

  # C6 a uid that is empty, not a number, or under 10: ERR-UID, nothing touched.
  for u in "" abc 9; do
    r=$(mkroot); d="$r/data/system/users/9"; mkdir -p "$d"
    printf '%s' "$HEX" > "$d/nowhere-ssaid-seed"; printf 'x' > "$d/settings_ssaid.xml"
    run_arm "$sh" "$armf" "$r" "$u"
    res_is "$r" "ERR-UID" "C6 uid '$u'"
    [ -e "$d/nowhere-ssaid-seed" ] || fail "C6 uid '$u': the seed of users/9 was removed"
    [ -e "$d/settings_ssaid.xml" ] || fail "C6 uid '$u': settings_ssaid.xml of users/9 was removed"
  done

  # C7 an rm that leaves the file: ERR-RM.
  r=$(mkroot); d="$r/data/system/users/17"; mkdir -p "$d"
  printf '%s' "$HEX" > "$d/nowhere-ssaid-seed"; printf 'x' > "$d/settings_ssaid.xml"
  stub=$(mktemp -p "$W"); printf 'rm() { :; }\n' > "$stub"
  run_arm "$sh" "$armf" "$r" 17 "$stub"
  res_is "$r" "ERR-RM" "C7 a stuck file"
  [ -e "$d/nowhere-ssaid-seed" ] || fail "C7 the stub did not keep the seed"
}

# suite <roamd>: every case under every shell; prints one line per shell; returns the shells that failed, as words.
FAILED_SHELLS=""
suite() {
  local armf sh
  armf=$(mktemp -p "$W")
  extract "$1" "$armf"
  FAILED_SHELLS=""
  for sh in $SHELLS; do
    FAILS=0
    cases "$sh" "$armf"
    if [ "$FAILS" -eq 0 ]; then echo "  ok   $sh"; else echo "  FAIL $sh ($FAILS check(s))"; FAILED_SHELLS="$FAILED_SHELLS $sh"; fi
  done
}

echo "dropssaid arm of $SUT:"
suite "$SUT"
if [ -n "$FAILED_SHELLS" ]; then echo "FAIL: the dropssaid suite failed under:$FAILED_SHELLS"; exit 1; fi
echo "PASS: the dropssaid suite, under:$SHELLS"
[ "${1:-}" = --mutate ] || exit 0

BAD=0
# mutant <label> <python: list of (old, new) pairs, each to match exactly once>
mutant() {
  local label=$1 m sh
  m=$(mktemp -p "$W")
  if ! python3 - "$SUT" "$m" "$2" <<'PY'
import sys, ast
src, dst, pairs = sys.argv[1], sys.argv[2], ast.literal_eval(sys.argv[3])
s = open(src).read()
for old, new in pairs:
    if s.count(old) != 1:
        sys.exit(1)
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  then echo "INERT     $label -- the mutation did not apply"; BAD=$((BAD + 1)); return; fi
  echo "$label:"
  suite "$m" >/dev/null
  for sh in $SHELLS; do
    case " $FAILED_SHELLS " in
      *" $sh "*) echo "  CONVICTED $label under $sh" ;;
      *) echo "  SURVIVED  $label under $sh"; BAD=$((BAD + 1)) ;;
    esac
  done
}

mutant "D1 the link check removed" \
  "[('    if [ -L \"\$_dsd\" ]; then\n      echo \"[roamd] dropssaid user', '    if false; then\n      echo \"[roamd] dropssaid user')]"
mutant "D2 settings_secure.xml added to the list" \
  "[('for _dsf in nowhere-ssaid-seed settings_ssaid.xml; do', 'for _dsf in nowhere-ssaid-seed settings_ssaid.xml settings_secure.xml; do')]"
mutant "D3 the uid >= 10 check removed" \
  "[('    [ \"\$uid\" -ge 10 ] || { echo \"ERR-UID\" > \"\$RES\"; chmod 600 \"\$RES\"; exit 0; }\n    _dsd=', '    _dsd=')]"
mutant "D4 a mkdir -p of the directory added" \
  "[('    _dsn=0; _dss=0\n', '    mkdir -p \"\$_dsd\"; _dsn=0; _dss=0\n')]"
mutant "D5 OK although a file stayed" \
  "[('    if [ \"\$_dss\" = 0 ]; then _dsr=\"OK \$_dsn\"', '    if true; then _dsr=\"OK \$_dsn\"')]"
mutant "D6 the seed's content logged" \
  "[('    _dsn=0; _dss=0\n', '    _dsk=\$(cat \"\$_dsd/nowhere-ssaid-seed\" 2>/dev/null); _dsn=0; _dss=0\n'), ('SSAID file(s) removed, \$_dss stuck (dn-1023 #4)', 'SSAID file(s) removed, \$_dss stuck \$_dsk (dn-1023 #4)')]"

if [ "$BAD" -ne 0 ]; then echo "FAIL: $BAD mutant(s) not convicted"; exit 1; fi
echo "PASS: every mutant CONVICTED under:$SHELLS"
