#!/usr/bin/env bash
# test-od-parked-report.sh [<nowhere_roamd.sh>] [--mutate] -- every sign-in logs one line with how many On-demand and
# Auto apps' data its restores fetched only to park, and the CE and DE size of it (NWP-20261119-17).
#
# WHY THIS IS COMMITTED. The vault and #de restores fetch the data of every kept app at every sign-in, and
# hold_ondemand then parks the On-demand and Auto apps' share in .nowhere-odhold until a tap. The decided per-package
# fetch (docs/product-decisions.md, 2026-10-26, #2) is to be judged by what it saves, and before this slice no log line
# held that number: a profile with gigabytes parked and one with none read the same. od_parked_report writes it. This
# suite pins what the line counts (ondemand and auto rows only, never installed or a bad name), that ONE du runs under
# a 3 s timeout however many apps there are, that no package name reaches roam.log, and that a failed or timed-out du
# logs "size unknown" and never fails the sign-in.
#
# So it EXECUTES the real extracted od_parked_report and pkgname_ok, under every shell found (the device's is mksh),
# against a re-rooted temp tree with holds of known sizes:
#   C1 a mixed appkeep: the line counts ondemand+auto per volume, du ran once under `timeout 3`, no name in roam.log
#   C2 an app with only a CE hold and one with only a DE hold   C3 no appkeep -> no line, no du
#   C4 ondemand/auto rows but no holds -> `of 0`, no du   C5 timeout returns 124 -> size unknown, rc 0
#   C6 du fails (rc 1) -> size unknown, rc 0   C7 unexpected du lines are ignored
# and, for the issue report's sign-in summary (NWP-20261122-09), with NOWHERE_SIGNIN_SUMMARY set by the `in` arm:
#   C8 C1's fixture -> one `v=1 parked apps=2 ce_kib=<n> de_kib=<n>` line, the same numbers roam.log shows
#   C9 C1's fixture, the variable unset -> no summary file   C10 C5's timeout -> `v=1 parked apps=2 size=unknown`
#   C11 no appkeep -> no summary file
# plus a text pin: in the `in` op, od_parked_report "$uid" is the line right after hold_ondemand "$uid".
#
#   bash test-od-parked-report.sh              # the cases, under every shell found
#   bash test-od-parked-report.sh --mutate     # ... plus mutants of roamd that must each CONVICT under each shell
#
# Pure logic -- no device. No case reads wall time: _ms and date are stubs.
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(dirname "$0")/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }
# Every case root, runner and mutant copy is made inside W, so a run that passes, fails or convicts leaves nothing.
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS=(); seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$s")
done
[ "${#SHELLS[@]}" -gt 0 ] || { echo "no shell found" >&2; exit 2; }
echo "shells: ${SHELLS[*]}"

UID_=12
anchor_of() { awk -v a="$2" 'index($0, a) == 1 {f=1} f{print} f&&/^\}$/{exit}' "$1"; }
nleft() { printf '%s\n' "$1" | sed -E 's/(^|[[:space:]])#.*$//' | sed 's#\$ROOT/data/##g' | grep -cE '(^|[^[:alnum:]_])/data/'; }

suite() {  # suite <roamd.sh> [quiet] -> 0 all ok, 1 a case failed, 2 the harness could not run
  local f="$1" quiet="${2:-}" p=0 x=0 FN FNR PKGOK ODH n sh L R HARN="" ARM nxt
  local ECE EDE CEH DEH SS=""
  say() { [ -n "$quiet" ] || printf '%s\n' "$1"; }
  chk() {
    local l="$1"; shift
    if "$@"; then p=$((p+1)); say "  ok    $l"; else x=$((x+1)); say "  FAIL  $l"; fi
  }
  eqv() { [ "$1" = "$2" ]; }
  hasnt() { [ ! -f "$1" ] || ! grep -qF -- "$2" "$1"; }   # hasnt <file> <substring>
  nl_() { [ -f "$1" ] && grep -c . "$1" || echo 0; }        # nl_ <file> -> its non-empty line count, 0 when absent
  val() { [ -f "$1" ] && cat "$1" || echo -; }
  absent() { [ ! -e "$1" ]; }

  FN=$(anchor_of "$f" 'od_parked_report() {')
  ODH=$(grep -m1 -E '^ODHOLD=' "$f")
  PKGOK=$(anchor_of "$f" 'pkgname_ok() {')
  case "$FN" in *'nowhere-appkeep'*'$ODHOLD'*) ;; *) echo "EXTRACTION FAILED: od_parked_report in $f" >&2; return 2 ;; esac
  [ -n "$ODH" ] || { echo "EXTRACTION FAILED: ODHOLD= not found in $f" >&2; return 2; }
  case "$PKGOK" in *'return 1'*'return 0'*) ;; *) echo "EXTRACTION FAILED: pkgname_ok in $f" >&2; return 2 ;; esac
  FNR=$(printf '%s\n' "$FN" | sed 's#"/data/#"$ROOT/data/#g')
  n=$(printf '%s\n' "$FNR" | grep -c '"\$ROOT/data/')
  [ "$n" -ge 3 ] || { echo "RE-ROOT FAILED: od_parked_report has $n rewritten paths, want >= 3" >&2; return 2; }
  n=$(nleft "$FNR")
  [ "$n" = 0 ] || { echo "RE-ROOT INCOMPLETE: od_parked_report keeps $n absolute /data path(s) in live code" >&2; return 2; }

  # The call-site pin (text, untagged): in the `in` op the line after hold_ondemand "$uid" is the report.
  ARM=$(awk '$0 == "  in)" {f=1} f{print} f&&/^    ;;$/{exit}' "$f")
  nxt=$(printf '%s\n' "$ARM" | awk 'g{print; exit} $0 == "      hold_ondemand \"$uid\"" {g=1}')
  case "$nxt" in
    '      od_parked_report "$uid"'|'      od_parked_report "$uid" '*'#'*) chk "pin: the in op runs od_parked_report right after hold_ondemand" true ;;
    *) chk "pin: the in op runs od_parked_report right after hold_ondemand (got: $nxt)" false ;;
  esac

  CEH="data/user/$UID_/com.nowhere.chooser/.nowhere-odhold"
  DEH="data/user_de/$UID_/com.nowhere.chooser/.nowhere-odhold"
  mkroot() {
    R=$(mktemp -d -p "$W") || exit 2
    mkdir -p "$R/sim" "$R/data/nowhere" "$R/data/user/$UID_/com.nowhere.chooser/files" "$R/data/user_de/$UID_/com.nowhere.chooser"
  }
  appkeep() { printf '%b' "$1" > "$R/data/user/$UID_/com.nowhere.chooser/files/nowhere-appkeep"; }
  hold() {  # hold <CE|DE> <pkg> <KiB of payload>
    local v d
    v=$CEH; [ "$1" = DE ] && v=$DEH
    d="$R/$v/$2"
    mkdir -p "$d"
    dd if=/dev/zero of="$d/blob" bs=1024 count="$3" 2>/dev/null
  }
  kib() {  # kib <dir>... -> the sum of the real du -sk of each, so filesystem block sizes never matter
    local s=0 d k
    for d in "$@"; do k=$(command du -sk "$d" | cut -f1); s=$((s + k)); done
    echo "$s"
  }
  # runner <root>: stubs + the extracted text, written to a FILE so the shell under test parses it. A case that
  # sets SS=<path> runs with NOWHERE_SIGNIN_SUMMARY exported to it; otherwise the variable is unset.
  runner() {
    local d="$1/runner.sh"
    {
      printf "ROOT='%s'\nLOG='%s'\nC='%s'\n" "$1" "$1/roam.log" "$1/sim"
      if [ -n "${SS:-}" ]; then printf "NOWHERE_SIGNIN_SUMMARY='%s'; export NOWHERE_SIGNIN_SUMMARY\n" "$SS"
      else printf 'unset NOWHERE_SIGNIN_SUMMARY\n'; fi
      cat <<'EOF'
_ms() { echo 0; }
date() { echo DATE; }
timeout() {
  printf '%s\n' "$*" >> "$C/timeout.calls"
  if [ -f "$C/to_rc" ]; then return "$(cat "$C/to_rc")"; fi
  while [ "${1:-}" = -k ]; do shift 2; done
  shift
  "$@"
}
du() {
  echo x >> "$C/du.calls"
  if [ -f "$C/du_rc" ]; then return "$(cat "$C/du_rc")"; fi
  if [ -f "$C/du_junk" ]; then printf 'junk\n0x1\t%s\n007\t%s\n\n12a\t%s\n' "$ROOT/data/user/12/x" "$ROOT/data/user/12/y" "$ROOT/data/user/12/z"; fi
  command du "$@"
}
EOF
      printf '%s\n%s\n%s\n' "$ODH" "$PKGOK" "$FNR"
      printf 'od_parked_report %s\necho "rc=$?" > "$C/rc"\n' "$UID_"
    } > "$d"
  }
  run() {  # run <sh> <root>
    runner "$2"
    if ! "$1" -n "$2/runner.sh" 2>"$2/sim/stderr"; then HARN="$HARN [$1: the runner does not parse]"; return; fi
    "$1" "$2/runner.sh" >/dev/null 2>"$2/sim/stderr"
    local e
    e=$(grep -m1 -E 'command not found|unbound variable|syntax error|bad substitution|not found' "$2/sim/stderr" 2>/dev/null)
    [ -z "$e" ] || HARN="$HARN [$1: $e]"
  }
  line() {  # line <n> <tail> -> the whole roam.log line
    printf '%s' "[roamd] IN parked data of $1 On-demand/Auto app(s), fetched by the sign-in's restores: $2, measured in 0ms (NWP-20261026-35 #2) DATE"
  }
  noname() { hasnt "$1" com.ex. && hasnt "$1" evil && hasnt "$1" /data/; }
  mixed() {  # the C1 fixture: every kind of row, each with CE and DE holds of distinct sizes
    appkeep 'com.ex.od\tondemand\ncom.ex.au\tauto\tgrp\ncom.ex.inst\tinstalled\ncom.ex.bare\ncom.ex.od\tondemand\n../evil\tondemand\ncom.ex.off\toff\n'
    hold CE com.ex.od 8; hold DE com.ex.od 4
    hold CE com.ex.au 16; hold DE com.ex.au 12
    hold CE com.ex.inst 64; hold DE com.ex.inst 32
    hold CE com.ex.bare 128; hold DE com.ex.bare 96
    hold CE com.ex.off 40; hold DE com.ex.off 20
    mkdir -p "$R/data/user/$UID_/com.nowhere.chooser/evil"; dd if=/dev/zero of="$R/data/user/$UID_/com.nowhere.chooser/evil/blob" bs=1024 count=256 2>/dev/null
    ECE=$(kib "$R/$CEH/com.ex.od" "$R/$CEH/com.ex.au")
    EDE=$(kib "$R/$DEH/com.ex.od" "$R/$DEH/com.ex.au")
  }

  for sh in "${SHELLS[@]}"; do
    L="[$sh]"
    say "== $sh C1: a mixed appkeep -> ondemand+auto only, per volume, one du under timeout 3, no name =="
    mkroot; mixed
    run "$sh" "$R"
    chk "$L C1 the one line, with the per-volume KiB" eqv "$(val "$R/roam.log")" "$(line 2 "CE $ECE KiB, DE $EDE KiB")"
    chk "$L C1 du ran once" eqv "$(nl_ "$R/sim/du.calls")" 1
    chk "$L C1 timeout ran once, as timeout 3 du -sk" eqv "$(sed -n '1s/^\(3 du -sk \).*/\1/p' "$R/sim/timeout.calls" 2>/dev/null)/$(nl_ "$R/sim/timeout.calls")" "3 du -sk /1"
    chk "$L C1 no package name or path in roam.log" noname "$R/roam.log"
    chk "$L C1 rc 0" eqv "$(val "$R/sim/rc")" rc=0
    chk "$L C1 the holds are untouched" eqv "$(kib "$R/$CEH/com.ex.od" "$R/$CEH/com.ex.au")" "$ECE"

    say "== $sh C2: one app with only a CE hold, one with only a DE hold =="
    mkroot
    appkeep 'com.ex.od\tondemand\ncom.ex.au\tauto\n'
    hold CE com.ex.od 24; hold DE com.ex.au 48
    ECE=$(kib "$R/$CEH/com.ex.od"); EDE=$(kib "$R/$DEH/com.ex.au")
    run "$sh" "$R"
    chk "$L C2 of 2, each volume its own size" eqv "$(val "$R/roam.log")" "$(line 2 "CE $ECE KiB, DE $EDE KiB")"
    chk "$L C2 du ran once" eqv "$(nl_ "$R/sim/du.calls")" 1

    say "== $sh C3: no appkeep -> no line, no du =="
    mkroot
    hold CE com.ex.od 8
    run "$sh" "$R"
    chk "$L C3 no roam.log line" eqv "$(nl_ "$R/roam.log")" 0
    chk "$L C3 no du" eqv "$(nl_ "$R/sim/du.calls")" 0
    chk "$L C3 rc 0" eqv "$(val "$R/sim/rc")" rc=0

    say "== $sh C4: ondemand/auto rows but no holds -> of 0, no du =="
    mkroot
    appkeep 'com.ex.od\tondemand\ncom.ex.au\tauto\ncom.ex.inst\tinstalled\n'
    hold CE com.ex.inst 8
    run "$sh" "$R"
    chk "$L C4 of 0, 0 KiB" eqv "$(val "$R/roam.log")" "$(line 0 "CE 0 KiB, DE 0 KiB")"
    chk "$L C4 no du, no timeout" eqv "$(nl_ "$R/sim/du.calls")/$(nl_ "$R/sim/timeout.calls")" 0/0
    chk "$L C4 rc 0" eqv "$(val "$R/sim/rc")" rc=0

    say "== $sh C5: timeout returns 124 -> size unknown, rc 0 =="
    mkroot; mixed
    echo 124 > "$R/sim/to_rc"
    run "$sh" "$R"
    chk "$L C5 size unknown" eqv "$(val "$R/roam.log")" "$(line 2 "size unknown")"
    chk "$L C5 rc 0" eqv "$(val "$R/sim/rc")" rc=0
    chk "$L C5 no package name or path in roam.log" noname "$R/roam.log"

    say "== $sh C6: du fails (rc 1) -> size unknown, rc 0 =="
    mkroot; mixed
    echo 1 > "$R/sim/du_rc"
    run "$sh" "$R"
    chk "$L C6 size unknown" eqv "$(val "$R/roam.log")" "$(line 2 "size unknown")"
    chk "$L C6 rc 0" eqv "$(val "$R/sim/rc")" rc=0

    say "== $sh C7: unexpected du lines are ignored =="
    mkroot; mixed
    : > "$R/sim/du_junk"
    run "$sh" "$R"
    chk "$L C7 the sums are unchanged" eqv "$(val "$R/roam.log")" "$(line 2 "CE $ECE KiB, DE $EDE KiB")"

    say "== $sh C8: the sign-in summary gets the parked line, with roam.log's numbers =="
    mkroot; mixed
    SS="$R/state/signin-summary.$UID_"; mkdir -p "$R/state"
    run "$sh" "$R"
    chk "$L C8 the summary holds one parked line, CE and DE in order" eqv "$(val "$SS")" "v=1 parked apps=2 ce_kib=$ECE de_kib=$EDE"
    chk "$L C8 roam.log is unchanged" eqv "$(val "$R/roam.log")" "$(line 2 "CE $ECE KiB, DE $EDE KiB")"
    chk "$L C8 rc 0" eqv "$(val "$R/sim/rc")" rc=0
    SS=""

    say "== $sh C9: the variable unset -> no summary file =="
    mkroot; mixed
    run "$sh" "$R"
    chk "$L C9 no summary file anywhere in the root" eqv "$(find "$R" -name 'signin-summary*' | grep -c .)" 0
    chk "$L C9 roam.log still has its line" eqv "$(val "$R/roam.log")" "$(line 2 "CE $ECE KiB, DE $EDE KiB")"

    say "== $sh C10: a timed-out du -> size=unknown in the summary, rc 0 =="
    mkroot; mixed
    echo 124 > "$R/sim/to_rc"
    SS="$R/state/signin-summary.$UID_"; mkdir -p "$R/state"
    run "$sh" "$R"
    chk "$L C10 the summary holds the size=unknown line" eqv "$(val "$SS")" "v=1 parked apps=2 size=unknown"
    chk "$L C10 rc 0" eqv "$(val "$R/sim/rc")" rc=0
    SS=""

    say "== $sh C11: no appkeep -> no summary line =="
    mkroot
    SS="$R/state/signin-summary.$UID_"; mkdir -p "$R/state"
    run "$sh" "$R"
    chk "$L C11 no summary file" absent "$SS"
    SS=""
  done

  [ -z "$HARN" ] || { echo "HARNESS ERROR:$HARN" >&2; return 2; }
  say "$p passed, $x failed"
  [ "$x" = 0 ]
}

suite "$SUT"; rc=$?
[ "$rc" = 2 ] && exit 2
[ "$MUTATE" = yes ] || exit "$rc"

echo
echo "== mutations (each MUST be convicted under EACH shell's own line; m6 by the untagged pin) =="
MF=0
mutate() {  # mutate <id> <label> <perl expr> [pin]
  local id="$1" label="$2" expr="$3" pin="${4:-}" m out mrc s miss=""
  m=$(mktemp -p "$W") || exit 2
  if ! perl -0pe "$expr" "$SUT" > "$m" 2>/dev/null; then echo "  FAIL  MUTATION BROKEN (perl): $id $label"; MF=$((MF+1)); return; fi
  if cmp -s "$SUT" "$m"; then echo "  FAIL  MUTATION INERT (anchor never matched): $id $label"; MF=$((MF+1)); return; fi
  out=$(suite "$m"); mrc=$?
  if [ "$mrc" = 2 ]; then echo "  FAIL  INCONCLUSIVE (the harness could not run): $id $label"; MF=$((MF+1)); rm -f "$m"; return; fi
  if [ "$mrc" = 0 ]; then echo "  FAIL  NOT CONVICTED: $id $label"; MF=$((MF+1)); rm -f "$m"; return; fi
  if [ -n "$pin" ]; then
    case "$out" in *"FAIL  pin: "*) echo "  ok    convicted: $id $label" ;; *) echo "  FAIL  NOT CONVICTED by the pin: $id $label"; MF=$((MF+1)) ;; esac
    rm -f "$m"; return
  fi
  for s in "${SHELLS[@]}"; do
    case "$out" in *"FAIL  [$s] "*) ;; *) miss="$miss $s" ;; esac
  done
  if [ -n "$miss" ]; then echo "  FAIL  NOT CONVICTED under:$miss: $id $label"; MF=$((MF+1)); else echo "  ok    convicted: $id $label"; fi
  rm -f "$m"
}
# Each expression is scoped to od_parked_report's body (from its `() {` to the next `\n}\n`).
B='(od_parked_report\(\) \{(?:(?!\n\}\n).)*?)'
mutate m1 "installed rows are counted" "s/${B}case \"\\\$mode\" in ondemand\\|auto\\) ;;/\$1case \"\\\$mode\" in ondemand|auto|installed|'') ;;/s"
mutate m2 "one du per package" "s/${B}_out=\\\$\\(timeout 3 du -sk \"\\\$@\" 2>\\/dev\\/null\\)/\$1_out=\\\$(for d in \"\\\$@\"; do timeout 3 du -sk \"\\\$d\" 2>\\/dev\\/null || exit; done)/s"
mutate m3 "a package name is printed" "s/${B}(\\(NWP-20261026-35 #2\\) \\\$\\(date\\)\" >> \"\\\$LOG\"\n  \\[ -n )/\$1 \\\$_seen\$2/s"
mutate m4 "a du failure ends the function non-zero" "s/${B}(size unknown.*?\n)      return 0/\$1\$2      return 1/s"
mutate m5 "the timeout bound is removed" "s/${B}timeout 3 du -sk/\$1du -sk/s"
mutate m6 "the in op no longer calls the report" 's/\n      od_parked_report "\$uid"[^\n]*//' pin
# m7-m9 (NWP-20261122-09): the sign-in summary's parked line, convicted by C8 and C10.
mutate m7 "the CE/DE summary append removed" 's/'"$B"'\n  \[ -n "\$\{NOWHERE_SIGNIN_SUMMARY:-\}" \] && echo "v=1 parked apps=[^\n]*/$1/s'
mutate m8 "the size-unknown summary append removed" 's/'"$B"'\n      \[ -n "\$\{NOWHERE_SIGNIN_SUMMARY:-\}" \] && echo "v=1 parked apps=[^\n]*/$1/s'
mutate m9 "CE and DE swapped in the summary append" 's/'"$B"'ce_kib=\$_ce de_kib=\$_de/$1ce_kib=\$_de de_kib=\$_ce/s'

echo
echo "mutants failed: $MF"
[ "$rc" = 0 ] && [ "$MF" = 0 ]
