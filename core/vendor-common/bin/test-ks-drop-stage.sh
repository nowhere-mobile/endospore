#!/bin/bash
# NWP-20261102-04 (Q049): ks_stage_drop copies the chooser's CE drop list, minus the live keep-set, to $KS_DROP while
# the user still exists -- the #keys push runs later at the credless reap, when that CE file is gone. This suite
# extracts ks_stage_drop (and pkgname_ok) from nowhere_roamd.sh BY ANCHOR, never a copy, and runs it over scratch
# dirs under every shell the runner has (bash, sh, plus dash and mksh where installed).
#   test-ks-drop-stage.sh [<roamd>]            run the cases
#   test-ks-drop-stage.sh --mutate [<roamd>]   every mutant must be CONVICTED under every shell
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
HERE=$(cd "$(dirname "$0")" && pwd)
SUT=${1:-$HERE/nowhere_roamd.sh}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

SHELLS="bash sh"
for s in mksh dash; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

ok=0; no=0
chk() {  # chk <label> <shell> <want> <got>
  if [ "$3" = "$4" ]; then ok=$((ok + 1)); else no=$((no + 1)); echo "  FAIL [$2] $1"; echo "    want: $(printf %s "$3" | head -c 300 | tr '\n' '~')"; echo "    got:  $(printf %s "$4" | head -c 300 | tr '\n' '~')"; fi
}

# prep <sut> <out>: pkgname_ok + ks_stage_drop, each found exactly once. rc 2 = the extraction itself failed.
prep() {
  local sut="$1" out="$2" fn n
  : > "$out"
  for fn in pkgname_ok ks_stage_drop; do
    n=$(grep -c "^$fn() {\$" "$sut")
    if [ "$n" != 1 ]; then echo "EXTRACTION FAILED: $fn() anchor found $n times in $sut"; return 2; fi
    sed -n "/^$fn() {\$/,/^}\$/p" "$sut" >> "$out"
  done
  bash -n "$out" 2>/dev/null && sh -n "$out" 2>/dev/null || { echo "EXTRACTION FAILED: extract does not parse"; return 2; }
  return 0
}

# run1 <fn-file> <shell> <case-dir> <uid>
run1() {
  "$2" -c '. "$1"; KS_DROP="$2/ks/keystore-drop"; LOG="$2/log"; ks_stage_drop "$2/ud" "$3"' _ "$1" "$3" "$4"
}

# setup <case-dir>: fresh scratch tree
setup() { mkdir -p "$1/ud/com.nowhere.chooser/files" "$1/ks"; }

cases() {  # cases <sut>: rc 1 if any case failed, 2 if extraction failed
  local sut="$1" fn sh d F before
  fn=$(mktemp -p "$W") || return 2
  prep "$sut" "$fn" || return 2
  before=$no
  for sh in $SHELLS; do
    F="ud/com.nowhere.chooser/files"
    # C1 drop list minus keep-set, with header
    d=$(mktemp -d -p "$W"); setup "$d"
    printf 'a.b\nc.d\ne.f\n' > "$d/$F/nowhere-appdrop.list"; printf 'c.d\tondemand\n' > "$d/$F/nowhere-appkeep"
    run1 "$fn" "$sh" "$d" 10
    chk "C1 list minus keep-set, header" "$sh" "$(printf '# 10\na.b\ne.f\n')" "$(cat "$d/ks/keystore-drop" 2>&1)"
    # C2 absent list removes a stale file
    d=$(mktemp -d -p "$W"); setup "$d"; echo stale > "$d/ks/keystore-drop"; echo stale > "$d/ks/keystore-drop.new"
    run1 "$fn" "$sh" "$d" 10
    chk "C2 absent list -> file removed" "$sh" "gone" "$([ -e "$d/ks/keystore-drop" ] || [ -e "$d/ks/keystore-drop.new" ] && echo present || echo gone)"
    # C3 empty list -> header alone
    d=$(mktemp -d -p "$W"); setup "$d"; : > "$d/$F/nowhere-appdrop.list"
    run1 "$fn" "$sh" "$d" 10
    chk "C3 empty list -> header only" "$sh" "# 10" "$(cat "$d/ks/keystore-drop" 2>&1)"
    # C4 malformed lines skipped
    d=$(mktemp -d -p "$W"); setup "$d"
    printf 'x/y.z\na b.c\n../x\nok.pkg\n' > "$d/$F/nowhere-appdrop.list"
    run1 "$fn" "$sh" "$d" 10
    chk "C4 slash/space/dotdot skipped" "$sh" "$(printf '# 10\nok.pkg\n')" "$(cat "$d/ks/keystore-drop" 2>&1)"
    # C5 duplicate once, and a last line with no newline still counts
    d=$(mktemp -d -p "$W"); setup "$d"
    printf 'a.b\na.b\nz.y' > "$d/$F/nowhere-appdrop.list"
    run1 "$fn" "$sh" "$d" 10
    chk "C5 duplicate once, unterminated last line" "$sh" "$(printf '# 10\na.b\nz.y\n')" "$(cat "$d/ks/keystore-drop" 2>&1)"
    # C6 the log holds the count and no package name
    d=$(mktemp -d -p "$W"); setup "$d"
    printf 'secret.one\nsecret.two\n' > "$d/$F/nowhere-appdrop.list"
    run1 "$fn" "$sh" "$d" 10
    local lg; lg=$(cat "$d/log" 2>&1)
    case "$lg" in *secret*) chk "C6 log names no package" "$sh" clean named ;; *"staged 2 package"*) chk "C6 log names no package" "$sh" clean clean ;; *) chk "C6 log has the count" "$sh" counted "$lg" ;; esac
    # C8 the header binds the uid
    d=$(mktemp -d -p "$W"); setup "$d"; printf 'a.b\n' > "$d/$F/nowhere-appdrop.list"
    run1 "$fn" "$sh" "$d" 23
    chk "C8 header carries the uid" "$sh" "# 23" "$(head -n 1 "$d/ks/keystore-drop" 2>&1)"
  done
  # C7 (source) out calls it exactly once, before the first data push
  local o c p
  o=$(awk '/^  out\)$/ {print NR; exit}' "$sut")
  c=$(awk -v o="${o:-0}" 'NR > o && /ks_stage_drop "\$USERDIR" "\$uid"/ {print NR; exit}' "$sut")
  p=$(awk -v o="${o:-0}" 'NR > o && /_push vault "\$name" "\$USERDIR"/ {print NR; exit}' "$sut")
  local cnt; cnt=$(grep -c 'ks_stage_drop "\$USERDIR" "\$uid"' "$sut")
  if [ -n "$o" ] && [ -n "$c" ] && [ -n "$p" ] && [ "$o" -lt "$c" ] && [ "$c" -lt "$p" ] && [ "$cnt" = 1 ]; then
    chk "C7 out calls ks_stage_drop before the data pushes" source ok ok
  else
    chk "C7 out calls ks_stage_drop before the data pushes" source ok "o=$o c=$c p=$p calls=$cnt"
  fi
  [ "$no" = "$before" ]
}

# shellfail <sut> <shell>: does the case set fail under this shell alone? (rc 0 = convicted)
shell_fails() {
  local sut="$1" only="$2" saved="$SHELLS" rc
  SHELLS="$only"; local o=$ok n=$no
  cases "$sut" >/dev/null 2>&1; rc=$?
  SHELLS="$saved"; ok=$o; no=$n
  [ "$rc" = 1 ]
}

if [ "$MUTATE" = 0 ]; then
  cases "$SUT"; rc=$?
  if [ "$rc" = 0 ]; then echo "PASS: $ok checks under $SHELLS"; exit 0; fi
  echo "FAIL: $no failed, $ok passed (rc $rc)"; exit 1
fi

cases "$SUT" >/dev/null 2>&1 || { echo "FAIL: the unmutated suite does not pass; no mutant can be judged"; exit 1; }
bad=0
mutant() {  # mutant <name> <sed-script...>
  local name="$1" m sh
  shift
  m=$(mktemp -p "$W")
  sed "$@" "$SUT" > "$m"
  if cmp -s "$SUT" "$m"; then echo "FAIL: mutant $name did not apply"; bad=1; return; fi
  for sh in $SHELLS; do
    if shell_fails "$m" "$sh"; then echo "  CONVICTED $name [$sh]"; else echo "FAIL: mutant $name SURVIVED under $sh"; bad=1; fi
  done
}
mutant S1-keep-set-subtraction -e 's/^    case "\$nl\$keep\$nl" in \*"\$nl\$p\$nl"\*) k=\$((k + 1)); continue ;; esac$/    :/'
mutant S2-absent-writes-header -e "s/^    rm -f \"\$KS_DROP\" \"\$KS_DROP.new\" 2>\/dev\/null\$/    printf '# %s\\\\n' \"\$2\" > \"\$KS_DROP\"/"
mutant S3-uid-header-dropped -e "s/printf '# %s\\\\n' \"\\\$2\"; //"
mutant S4-log-prints-names -e 's/staged \$n package(s)/staged $(printf "%s " $body) package(s)/'
mutant S5-call-removed -e '/^    ks_stage_drop "\$USERDIR" "\$uid"$/d'
if [ "$bad" = 0 ]; then echo "PASS: every mutant convicted under $SHELLS"; exit 0; fi
echo "FAIL: a mutant survived or did not apply"; exit 1
