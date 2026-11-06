#!/usr/bin/env bash
# test-no-bare-truncate.sh [--dir <d>] [--mutate] -- no bare `: > "$f"` in the six device scripts (NWP-20261114-09).
#
# A failed redirection on the special builtin `:` ends a POSIX shell. mksh (the device's /system/bin/sh) and dash
# obey; bash survives it unless it runs as sh. So a truncation that fails (a full state tmpfs, a permission change)
# ends the whole roamd or mediad op before its reply is written, and the daemon waits out its own timeout. Neither
# `if !` nor a `2>>"$LOG"` on the line catches it. In a subshell, `( : > "$f" )`, the error ends only the subshell.
#
# What this pins:
#   - LINT: no non-comment line of nowhere_{gate,login,mediad,otad,provision,roamd}.sh runs `:` as the command of a
#     redirection to a file, at the line start or after `;`, `{`, `(`, `)` (a case arm), `&&`, `||`, `!`, `then`,
#     `else`, `do`, `if`, `elif`, `while` or `until`. The subshell form `( : > X )` is allowed. Each finding prints
#     as file:line. CONTROL: the scan read more than 1000 lines of nowhere_roamd.sh and saw the boot sweep's fixed
#     `( : > "$_ue" )` line (NWP-20261112-36) as an allowed truncation, so "no findings" cannot mean "never read".
#   - BEHAVIOUR, under each of bash, sh, dash and mksh found, tagged [<sh>]: the subshell form survives a target it
#     cannot write; and the bare form ends the shell, except under bash, where it survives by design.
#
#   bash test-no-bare-truncate.sh                # the lint over this directory + the behaviour cases
#   bash test-no-bare-truncate.sh --dir <d>      # ... the lint over the six scripts in <d>
#   bash test-no-bare-truncate.sh --mutate       # ... plus mutations that must each CONVICT the lint
set -uo pipefail

MUTATE=no; DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutate) MUTATE=yes ;;
    --dir) shift; DIR="${1:-}" ;;
    *) echo "usage: $0 [--dir <d>] [--mutate]" >&2; exit 2 ;;
  esac
  shift
done
DIR="${DIR:-$(dirname "$0")}"
SCRIPTS="nowhere_gate.sh nowhere_login.sh nowhere_mediad.sh nowhere_otad.sh nowhere_provision.sh nowhere_roamd.sh"

# One root for every temp; nothing outlives the suite.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# lint <dir>: one awk pass over the six scripts. Prints each finding as `file:line: text`, then the counts and the
# control. Returns 0 only with no finding and the control met; 1 on a finding; 3 on a control failure; 2 on a
# missing script.
lint() {
  local d="$1" s
  for s in $SCRIPTS; do
    [ -f "$d/$s" ] || { echo "MISSING: $d/$s"; return 2; }
  done
  (cd "$d" && awk '
    FNR == 1 { if (FILENAME == "nowhere_roamd.sh") roam = 1; else roam = 0 }
    { if (roam) roamlines++ }
    /^[[:space:]]*#/ { next }
    {
      l = $0
      # The allowed form first: `( : > X )`, X one quoted word or one bare word. Each is replaced by a token, so
      # its `:` cannot trip the refusal below.
      while (match(l, /\([[:space:]]*:[[:space:]]*>>?[[:space:]]*("[^"]*"|[^[:space:]();|&]+)[[:space:]]*\)/)) {
        allowed++
        if (roam && index(substr(l, RSTART, RLENGTH), "\"$_ue\"")) ue = 1
        l = substr(l, 1, RSTART - 1) " @TRUNC@ " substr(l, RSTART + RLENGTH)
      }
      if (l ~ /(^|[;{()|&!]|(^|[^[:alnum:]_])(then|else|do|if|elif|while|until))[[:space:]]*:[[:space:]]*>/) {
        printf "%s:%d: %s\n", FILENAME, FNR, $0
        findings++
      }
    }
    END {
      printf "findings %d; allowed truncations %d; nowhere_roamd.sh lines scanned %d; fixed _ue line seen %s\n", \
        findings + 0, allowed + 0, roamlines + 0, (ue ? "yes" : "no")
      if (roamlines <= 1000 || !ue) {
        printf "CONTROL FAILED: the scan must read more than 1000 lines of nowhere_roamd.sh and see ( : > \"$_ue\" )\n"
        exit 3
      }
      exit (findings ? 1 : 0)
    }' $SCRIPTS)
}

echo "== lint: $DIR"
out=$(lint "$DIR"); rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
if [ "$rc" -eq 0 ]; then ok "no bare ': >' in the six device scripts, and the control holds"
else no "the lint refused $DIR (rc=$rc)"; fi

# --- behaviour, under each shell found -------------------------------------------------------------------------
echo "== behaviour"
for sh in bash sh dash mksh; do
  if ! command -v "$sh" >/dev/null 2>&1; then
    printf '  [%s] not installed: its lines run on the CI host\n' "$sh"
    continue
  fi
  bout=$("$sh" -c '( : > "$1/nodir/x" ) 2>/dev/null; echo survived' _ "$W" 2>&1); brc=$?
  if [ "$brc" -eq 0 ] && [ "$bout" = survived ]; then ok "[$sh] ( : > unwritable ) ends only the subshell: survived, rc 0"
  else no "[$sh] ( : > unwritable ): rc=$brc out='$bout' (want survived, rc 0)"; fi
  if [ "$sh" = bash ]; then
    printf '  [bash] SKIP strict control: bash survives a bare failed redirection by design\n'
    continue
  fi
  bout=$("$sh" -c ': > "$1/nodir/x" 2>/dev/null; echo survived' _ "$W" 2>&1); brc=$?
  case "$bout" in
    *survived*) no "[$sh] control: the bare ': > unwritable' did not end the shell (rc=$brc)" ;;
    *) if [ "$brc" -ne 0 ]; then ok "[$sh] control: the bare ': > unwritable' ends the shell (rc=$brc, no survived)"
       else no "[$sh] control: the bare form printed nothing but rc 0"; fi ;;
  esac
done

# --- mutants -------------------------------------------------------------------------------------------------
# mutant <name> <want> <sed|append> <sed-expr|line> <file>: a copy of the six scripts under $W, one edit, then the lint.
# <want> is the text the lint output must hold (a finding's file:line, or the control failure). An edit that changes
# nothing is FAILED TO APPLY, a failure.
MUT_OK=0; MUT_BAD=0
mutant() {
  local name="$1" want="$2" how="$3" arg="$4" file="$5" d s mout mrc
  d=$(mktemp -d -p "$W") || exit 2
  for s in $SCRIPTS; do cp "$DIR/$s" "$d/$s"; done
  case "$how" in
    sed) sed -i "$arg" "$d/$file" || : ;;
    append) printf '%s\n' "$arg" >> "$d/$file" || : ;;
  esac
  if [ ! -f "$d/$file" ] || cmp -s "$DIR/$file" "$d/$file"; then
    MUT_BAD=$((MUT_BAD+1)); printf '  MUTANT FAILED TO APPLY  %s\n' "$name"; return
  fi
  # A planted line's finding names its line number: the copy's last line.
  case "$want" in @LAST@) want="$file:$(wc -l < "$d/$file" | tr -d ' '):" ;; esac
  mout=$(lint "$d"); mrc=$?
  case "$mout" in
    *"$want"*) if [ "$mrc" -ne 0 ]; then MUT_OK=$((MUT_OK+1)); printf '  CONVICTED  %s\n' "$name"; return; fi ;;
  esac
  MUT_BAD=$((MUT_BAD+1)); printf '  SURVIVED   %s (rc=%s; want "%s")\n' "$name" "$mrc" "$want"
  printf '%s\n' "$mout" | sed 's/^/      /'
}

if [ "$MUTATE" = yes ]; then
  echo "== mutants"
  mutant "M1 one converted roamd site put back to bare (prefs.out)" "nowhere_roamd.sh:" \
    sed 's|^      ( : > "\$STATE/prefs.out" )$|      : > "$STATE/prefs.out"|' nowhere_roamd.sh
  mutant "M2 the mediad site put back to bare" "nowhere_mediad.sh:" \
    sed 's|^  ( : > "\$SWEPT" ); _swrc=\$?; chmod|  : > "$SWEPT"; _swrc=$?; chmod|' nowhere_mediad.sh
  mutant "M3 a bare ':>x' with no space planted" @LAST@ append '  :>"$STATE/lint-x"' nowhere_roamd.sh
  mutant "M4 a bare 'x) : > y ;;' case arm planted" @LAST@ append '    x) : > y ;;' nowhere_roamd.sh
  mutant "M5 the control's fixed ( : > \"\$_ue\" ) line removed" "CONTROL FAILED" \
    sed '/( : > "\$_ue" )/d' nowhere_roamd.sh
  mutant "M6 a bare 'if ! : > x; then' planted" @LAST@ append '  if ! : > "$STATE/lint-y"; then :; fi' nowhere_roamd.sh
  echo "mutants: $MUT_OK convicted, $MUT_BAD not"
  [ "$MUT_BAD" -eq 0 ] || FAIL=$((FAIL+1))
fi

echo "test-no-bare-truncate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
