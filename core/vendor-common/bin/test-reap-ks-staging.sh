#!/usr/bin/env bash
# test-reap-ks-staging.sh [<nowhere_roamd.sh>] [--mutate] [--baseline] -- the reap clears its own user's Keystore
# staging after the seal (NWP-20261114-18), run for real rather than grepped.
#
# At sign-in roamd restores the profile's #keys bundles into keystore-in/<uid> (/data/nowhere), and an on-demand tap
# moves one into nowhere-import/<uid>NNNNN.keys (/data/misc/keystore). Both are plaintext keystore2 blobs. The reap
# (cleanstorage) sealed them into #keys and removed neither: keystore2's remove_user does not remove an import file,
# and the boot sweep did not list nowhere-import before NWP-20261114-23, so a clean sign-out and a power-off left them
# on /data.
# ks_reap_clear <uid> <verdict> must:
#   - on `sealed` or `nothing`, remove keystore-in/<uid> and this uid's <uid>NNNNN.keys imports, and log the counts;
#   - on `notsealed`, remove the same and log the cleared line with the #6 suffix (the store's previous #keys holds
#     them, NWP-20261124-13), and log no kept line;
#   - leave every other user's bundles and the nowhere-import dir itself (keystore2 owns it);
#   - on any other verdict (notsealed-unmapped, empty, unknown), remove nothing and log the kept line;
#   - do nothing for a uid that is empty, not all digits or below 10;
#   - never follow a symbolic link at keystore-in/<uid>;
#   - log counts only: no package, ns or profile name, and never rm's own diagnostics (they name the file);
#   - count a bundle as cleared only when its rm removed it, and say how many could not be removed.
# C9 runs the reap's real path end to end: ks_in_dir, ks_ns_mine, ks_prog, keystore_push and ks_reap_clear extracted by
# name, and cleanstorage's lines from `keystore_push wait` to the ks_reap_clear call, against an AGENT that replaces a
# scratch store head with each stage and then fails (a PUT that landed behind a lost reply). With an import of this
# uid that has no KS_MAP package, the landed head lacks that import, so the reap must keep the staging (verdict
# notsealed-unmapped); a mapped import, an unmapped export, a credless defer and a stale KS_STAGE_VERDICT all clear.
# Two source pins: cleanstorage captures `_kssv="${KS_STAGE_VERDICT:-$_ksv}"` after `_ksv="$KS_VERDICT"` and calls
# `ks_reap_clear "$uid" "$_kssv"` after it (W1), and its notsealed export removal is this uid's glob, not every user's (W2).
# Mutants (--mutate): Q1' the notsealed arm kept as today; Q2 the import glob drops the uid prefix; Q3 the keystore-in
# removal takes every user's; Q4 the call line deleted; Q5 the notsealed export removal every user's; Q6 rm diagnostics
# to the log; Q7 a failed removal counted as cleared; Q8 the import glob drops the uid prefix for notsealed only; Q8b
# the keystore-in removal takes every user's for notsealed only; Q9 the log line names a file; Q10 keystore_push never
# sets notsealed-unmapped; Q11 cleanstorage passes $_ksv, not $_kssv; Q12 the KS_STAGE_VERDICT reset deleted; Q13 an
# unmapped export also sets notsealed-unmapped; Q14 ks_reap_clear clears on notsealed-unmapped too.
#
# The helper is extracted from nowhere_roamd.sh BY ANCHOR; if the anchor moves, extraction fails loudly (exit 2).
# --baseline stands a no-op in for a missing helper, so the cases fail by BEHAVIOUR against a script that lacks it.
# The paths point into a temp tree and the cases run under every shell present among bash, sh, dash and mksh; each
# mutant must be convicted under each shell.
#
#   bash test-reap-ks-staging.sh              # the behaviour cases and the source pins
#   bash test-reap-ks-staging.sh --mutate     # ... plus mutations that must each CONVICT the suite
#   bash test-reap-ks-staging.sh --baseline <roamd>   # run against a script without the helper (it must fail)
# ONLY_SHELL=<path> (internal) restricts the shell loop to one shell.
set -uo pipefail

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

MUTATE=no; BASELINE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; --baseline) BASELINE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(dirname "$0")
SUT="${SUT:-$HERE/nowhere_roamd.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

SHELLS=()
seen=" "
for s in bash sh dash mksh; do
  p=$(command -v "$s" 2>/dev/null) || continue
  r=$(readlink -f "$p")
  case "$seen" in *" $r "*) continue ;; esac
  seen="$seen$r "; SHELLS+=("$p")
done
if [ -n "${ONLY_SHELL:-}" ]; then SHELLS=("$ONLY_SHELL"); fi

# --- extraction -----------------------------------------------------------------------------------------
FN=$(awk '/^ks_reap_clear\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
fn_ok=no
case "$FN" in *'restored bundle(s)'*'staged import(s)'*) case "$FN" in *'kept: #keys'*) fn_ok=yes ;; esac ;; esac
if [ "$BASELINE" = yes ]; then
  [ "$fn_ok" = yes ] || FN='ks_reap_clear() { :; }'
else
  [ "$fn_ok" = yes ] || { echo "EXTRACTION FAILED: ks_reap_clear" >&2; exit 2; }
fi
printf '%s\n' "$FN" > "$W/fn.sh"
bash -n "$W/fn.sh" 2>/dev/null || { echo "EXTRACTION FAILED: ks_reap_clear does not parse" >&2; exit 2; }
# The cleanstorage op, from its dispatch line to the next column-0 `fi`.
OP=$(awk '/^if \[ "\$op" = "cleanstorage" \]; then$/ { on = 1 } on { print } on && /^fi$/ { exit }' "$SUT")
case "$OP" in *'keystore_push wait'*) ;; *) echo "EXTRACTION FAILED: the cleanstorage op" >&2; exit 2 ;; esac

# C9: the reap's path from the seal to the clear. The functions by name, the stage under the case dir (the rewrite must
# hit exactly one line), and cleanstorage's lines from `keystore_push wait` to the ks_reap_clear call.
INT_OK=yes
for fnm in ks_in_dir ks_ns_mine ks_prog keystore_push; do
  part=$(awk -v h="$fnm() {" '$0 == h { on = 1 } on { print } on && /^}$/ { exit }' "$SUT")
  [ -n "$part" ] || { echo "EXTRACTION FAILED: $fnm" >&2; exit 2; }
  printf '%s\n' "$part" >> "$W/intfn.sh"
done
unset fnm part
[ "$(grep -c '^  KSTAGE="\$STATE/keystore-stage"$' "$W/intfn.sh")" = 1 ] || { echo "REWRITE FAILED: KSTAGE" >&2; exit 2; }
SEG=$(printf '%s\n' "$OP" | awk '/^  keystore_push wait/ { on = 1 } on { print } on && /^  ks_reap_clear "\$uid"/ { exit }')
case "$SEG" in *'_ksv="$KS_VERDICT"'*'ks_reap_clear "$uid"'*) ;; *) INT_OK=no ;; esac
{
  printf '%s\n' 'LOG="$D/log"; KS_IN="$D/nw/keystore-in"; KS_IMPORT="$D/import"; KS_EXPORT="$D/export"; KS_MAP="$D/map"'
  printf '%s\n' 'KS_DROP="$D/drop"; STATE="$D/state"; AGENT="$D/agent.sh"; uid=10; unset NOWHERE_PROGRESS; export D'
  printf '%s\n' 'print() { while [ $# -gt 0 ]; do case "$1" in -r) shift ;; --) shift; break ;; *) break ;; esac; done; printf "%s\n" "$*"; }'
  printf '%s\n' 'pw() { printf "%s" "$1"; }; qn() { printf "%s" "$1"; }; timeout() { shift 3; "$@"; }; sleep() { :; }'
  sed 's#^  KSTAGE="\$STATE/keystore-stage"$#  KSTAGE="$D/keystore-stage"#' "$W/intfn.sh"
  printf '%s\n' "$FN"
  printf '%s\n' "$SEG"
  printf '%s\n' 'echo "$KS_VERDICT" > "$D/res"'
} > "$W/int.sh"
bash -n "$W/int.sh" 2>/dev/null || INT_OK=no

# --- harness --------------------------------------------------------------------------------------------
# keystore-in -> $R/nw/keystore-in, nowhere-import -> $R/import, nowhere-export -> $R/export, $LOG -> $R/log.
{
  printf '%s\n' 'LOG="$R/log"; KS_IN="$R/nw/keystore-in"; KS_IMPORT="$R/import"; KS_EXPORT="$R/export"'
  # FAILRM=1: every rm fails as a permission denial would, and prints the diagnostic real rm prints (it names the
  # file). A shell function, so the case is the same as root, where a read-only mode bit does not stop rm.
  printf '%s\n' 'if [ -n "${FAILRM:-}" ]; then rm() { for _x in "$@"; do case "$_x" in -*) ;; *) echo "rm: cannot remove '"'"'$_x'"'"': Permission denied" >&2 ;; esac; done; return 1; }; fi'
  printf '%s\n' "$FN"
  printf '%s\n' 'ks_reap_clear "$U" "$V"'
} > "$W/driver.sh"

# run <shell> <root> <uid> <verdict> [VAR=val ...]
run(){ local sh="$1" r="$2" u="$3" v="$4"; shift 4
  env "$@" R="$r" U="$u" V="$v" "$sh" "$W/driver.sh" 2>>"$r/stderr"; }
# mktree: user 10's two restored bundles and one staged import, user 11's of each, one export dump of each user, and
# a dir outside the staging that only a followed link could reach.
mktree(){ local t; t=$(mktemp -d -p "$W")
  mkdir -p "$t/nw/keystore-in/10" "$t/nw/keystore-in/11" "$t/import" "$t/export" "$t/outside"
  echo k > "$t/nw/keystore-in/10/a.keys"; echo k > "$t/nw/keystore-in/10/b.keys"; echo k > "$t/nw/keystore-in/11/c.keys"
  echo k > "$t/import/1010001.keys"; echo k > "$t/import/1110002.keys"
  echo k > "$t/export/1010003.keys"; echo k > "$t/export/1110004.keys"
  echo secret > "$t/outside/sentinel.keys"; : > "$t/log"; : > "$t/stderr"; echo "$t"; }
snap(){ ( cd "$1" && find nw import export outside -print 2>/dev/null | sort && find nw import export outside -type f -exec cksum {} + 2>/dev/null | sort ); }
gone(){ if [ -e "$1" ] || [ -L "$1" ]; then return 1; fi; return 0; }
haslog(){ local l; l=$(cat "$1/log" 2>/dev/null); case "$l" in *"$2"*) return 0 ;; esac; return 1; }

# cleared <label> <verdict> [<suffix>]: the removals and the stays of a reap of user 10 that clears (sealed, nothing,
# notsealed). <suffix> is the text the cleared line carries after the verdict.
cleared(){ local label="$1" v="$2" sfx="${3:-}"
  T=$(mktree); run "$sh" "$T" 10 "$v"
  gone "$T/nw/keystore-in/10" && ok "$tag $label: keystore-in/10 (a.keys, b.keys) removed" || no "$tag $label: keystore-in/10 is still there"
  gone "$T/import/1010001.keys" && ok "$tag $label: nowhere-import/1010001.keys removed" || no "$tag $label: nowhere-import/1010001.keys is still there"
  [ -f "$T/nw/keystore-in/11/c.keys" ] && ok "$tag $label: keystore-in/11/c.keys stays" || no "$tag $label: user 11's restored bundle was removed"
  [ -f "$T/import/1110002.keys" ] && ok "$tag $label: nowhere-import/1110002.keys stays" || no "$tag $label: user 11's staged import was removed"
  [ -d "$T/import" ] && ok "$tag $label: the nowhere-import dir itself stays" || no "$tag $label: the nowhere-import dir was removed"
  [ -f "$T/export/1010003.keys" ] && [ -f "$T/export/1110004.keys" ] && ok "$tag $label: nowhere-export is untouched" \
    || no "$tag $label: an export dump was removed"
  haslog "$T" "[roamd] reap: keystore staging of user 10 cleared (2 restored bundle(s), 1 staged import(s)) after #keys $v$sfx (NWP-20261114-18)" \
    && ok "$tag $label: the log line counts 2 restored bundles and 1 staged import" || no "$tag $label: no cleared line with the counts 2 and 1 (log: $(cat "$T/log"))"
  [ "$(wc -l < "$T/log")" = 1 ] && ok "$tag $label: exactly one log line" || no "$tag $label: the log has not exactly one line"
  if haslog "$T" "kept: #keys"; then no "$tag $label: a kept line was logged"; else ok "$tag $label: no kept line"; fi
  [ -s "$T/stderr" ] && no "$tag $label: stderr: $(cat "$T/stderr")" || ok "$tag $label: nothing on stderr"
}

for sh in "${SHELLS[@]}"; do
tag="[${sh##*/}]"
echo "== $tag C1 sealed =="
cleared "C1 sealed" sealed

echo "== $tag C2 nothing =="
cleared "C2 nothing" nothing

NS6=" (the store's previous #keys holds them, #6)"
echo "== $tag C3 notsealed: this uid's bundles removed, the cleared line logged, no kept line =="
cleared "C3 notsealed" notsealed "$NS6"

echo "== $tag C4 a uid that is empty, not a number or below 10: nothing removed =="
for u in '' abc 5; do
  T=$(mktree); mkdir -p "$T/nw/keystore-in/5"; echo k > "$T/nw/keystore-in/5/x.keys"; echo k > "$T/import/500001.keys"
  B=$(snap "$T"); run "$sh" "$T" "$u" sealed; A=$(snap "$T")
  [ "$A" = "$B" ] && ok "$tag C4 uid '$u': nothing removed" || no "$tag C4 uid '$u': the tree changed"
  if haslog "$T" cleared; then no "$tag C4 uid '$u': a cleared line was logged"; else ok "$tag C4 uid '$u': no cleared line"; fi
done

for v in sealed notsealed; do
sfx=""; [ "$v" = notsealed ] && sfx="$NS6"
echo "== $tag C5 $v: a symbolic link at keystore-in/10 is never followed =="
T=$(mktree); rm -rf "$T/nw/keystore-in/10"; ln -s "$T/outside" "$T/nw/keystore-in/10"; run "$sh" "$T" 10 "$v"
[ -f "$T/outside/sentinel.keys" ] && ok "$tag C5 $v: the outside dir's file survives" || no "$tag C5 $v: the outside dir was emptied through the link"
[ -d "$T/outside" ] && ok "$tag C5 $v: the outside dir survives" || no "$tag C5 $v: the outside dir was removed"
gone "$T/nw/keystore-in/10" && ok "$tag C5 $v: the link itself is removed" || no "$tag C5 $v: the link is still there"
[ -f "$T/nw/keystore-in/11/c.keys" ] && [ -f "$T/import/1110002.keys" ] && ok "$tag C5 $v: user 11's bundles stay" \
  || no "$tag C5 $v: a bundle of user 11 was removed"
haslog "$T" "cleared (0 restored bundle(s), 1 staged import(s)) after #keys $v$sfx (NWP-20261114-18)" && ok "$tag C5 $v: nothing behind the link is counted" \
  || no "$tag C5 $v: the counts are not 0 and 1 (log: $(cat "$T/log"))"

echo "== $tag C6 $v: the log line names no package, ns or profile =="
T=$(mktree); rm -f "$T/nw/keystore-in/10/"*.keys "$T/import/1010001.keys"
echo k > "$T/nw/keystore-in/10/com.example.alpha.keys"; echo k > "$T/import/1010077.keys"
run "$sh" "$T" 10 "$v" name=profileX profile=profileX
gone "$T/nw/keystore-in/10" && gone "$T/import/1010077.keys" && ok "$tag C6 $v: the bundles are removed" || no "$tag C6 $v: a bundle is still there"
L=$(cat "$T/log" "$T/stderr")
case "$L" in *com.example*) no "$tag C6 $v: the log names a package" ;; *) ok "$tag C6 $v: no package in the log" ;; esac
case "$L" in *1010077*) no "$tag C6 $v: the log names an ns" ;; *) ok "$tag C6 $v: no ns in the log" ;; esac
case "$L" in *profileX*) no "$tag C6 $v: the log names the profile" ;; *) ok "$tag C6 $v: no profile name in the log" ;; esac
case "$L" in *keystore-in/*|*"$T"*) no "$tag C6 $v: the log names a path" ;; *) ok "$tag C6 $v: no path in the log" ;; esac

echo "== $tag C7 $v: a failed removal: no rm diagnostic in the log, nothing counted as cleared =="
T=$(mktree); rm -f "$T/nw/keystore-in/10/"*.keys
echo k > "$T/nw/keystore-in/10/com.example.private.keys"
run "$sh" "$T" 10 "$v" FAILRM=1
[ -f "$T/nw/keystore-in/10/com.example.private.keys" ] && [ -f "$T/import/1010001.keys" ] \
  && ok "$tag C7 $v: the harness rm failed (the bundles stay)" || no "$tag C7 $v: the harness rm removed a bundle"
L=$(cat "$T/log")
case "$L" in *com.example*) no "$tag C7 $v: the log names a package (log: $L)" ;; *) ok "$tag C7 $v: no package in the log" ;; esac
case "$L" in *1010001*) no "$tag C7 $v: the log names an ns (log: $L)" ;; *) ok "$tag C7 $v: no ns in the log" ;; esac
case "$L" in *"Permission denied"*|*"$T"*) no "$tag C7 $v: an rm diagnostic or a path is in the log" ;; *) ok "$tag C7 $v: no rm diagnostic or path in the log" ;; esac
if haslog "$T" "user 10 cleared"; then no "$tag C7 $v: the failed removal is logged as cleared"; else ok "$tag C7 $v: no cleared line"; fi
haslog "$T" "[roamd] reap: keystore staging of user 10 partly cleared (0 restored bundle(s), 0 staged import(s)); 2 bundle(s) could not be removed after #keys $v$sfx (NWP-20261114-18)" \
  && ok "$tag C7 $v: the partly-cleared line counts 0, 0 and 2 left" || no "$tag C7 $v: no partly-cleared line with the counts 0, 0 and 2 (log: $L)"
[ "$(wc -l < "$T/log")" = 1 ] && ok "$tag C7 $v: exactly one log line" || no "$tag C7 $v: the log has not exactly one line"
done

echo "== $tag C8 an empty or unknown verdict: nothing removed, the kept line logged =="
for v in notsealed-unmapped '' bogus Notsealed notsealed2; do
  T=$(mktree); B=$(snap "$T"); run "$sh" "$T" 10 "$v"; A=$(snap "$T")
  [ "$A" = "$B" ] && ok "$tag C8 verdict '$v': nothing removed" || no "$tag C8 verdict '$v': the tree changed"
  haslog "$T" "[roamd] reap: keystore staging of user 10 kept: #keys $v (NWP-20261114-18)" \
    && ok "$tag C8 verdict '$v': the kept line is logged" || no "$tag C8 verdict '$v': no kept line (log: $(cat "$T/log"))"
  if haslog "$T" cleared; then no "$tag C8 verdict '$v': a cleared line was logged"; else ok "$tag C8 verdict '$v': no cleared line"; fi
done

# intcase <map rows> <export ns list> <name> -> a case dir: user 10's restored com.b.keys and staged import 1010002.keys
# (promoted from the carried com.c), user 11's of each, the given exports, a store head holding com.b and com.c, and an
# AGENT that copies each stage over the head and fails.
intcase(){ local t n; t=$(mktemp -d -p "$W")
  mkdir -p "$t/nw/keystore-in/10" "$t/nw/keystore-in/11" "$t/import" "$t/export" "$t/state" "$t/store"
  printf b > "$t/nw/keystore-in/10/com.b.keys"; printf c > "$t/import/1010002.keys"
  printf x > "$t/nw/keystore-in/11/com.x.keys"; printf y > "$t/import/1110002.keys"
  printf b > "$t/store/com.b.keys"; printf c > "$t/store/com.c.keys"
  printf '%s' "$1" > "$t/map"
  for n in $2; do printf "f$n" > "$t/export/$n.keys"; done
  printf '#!/bin/sh\nrm -rf "$D/store" && cp -r "$5" "$D/store"\nexit 1\n' > "$t/agent.sh"; chmod +x "$t/agent.sh"
  : > "$t/log"; echo "$t"; }
# intrun <shell> <dir> <name> [VAR=val ...]
intrun(){ local sh="$1" d="$2" nm="$3"; shift 3
  env "$@" D="$d" name="$nm" pass=secret "$sh" "$W/int.sh" >/dev/null 2>&1; touch "$d/res"; }
heads(){ ls "$1/store" 2>/dev/null | tr '\n' ' '; }

if [ "$INT_OK" != yes ]; then
  no "$tag C9 the cleanstorage lines from keystore_push wait to the ks_reap_clear call were not found or do not parse"
else
echo "== $tag C9a an unmapped import and a PUT that landed behind a lost reply: the staging is kept =="
T=$(intcase '1010001 com.a
' "1010001"); intrun "$sh" "$T" prof
[ "$(cat "$T/res")" = notsealed ] && ok "$tag C9a KS_VERDICT is notsealed" || no "$tag C9a KS_VERDICT '$(cat "$T/res")', want notsealed"
[ "$(heads "$T")" = "com.a.keys com.b.keys " ] && ok "$tag C9a the landed head lacks the unmapped import (the premise)" \
  || no "$tag C9a the store head is '$(heads "$T")', want com.a.keys com.b.keys"
[ -f "$T/import/1010002.keys" ] && ok "$tag C9a the unmapped import 1010002.keys stays" || no "$tag C9a the unmapped import was removed: its only copy is gone"
[ -f "$T/nw/keystore-in/10/com.b.keys" ] && ok "$tag C9a keystore-in/10/com.b.keys stays" || no "$tag C9a keystore-in/10 was cleared"
haslog "$T" "[roamd] reap: keystore staging of user 10 kept: #keys notsealed-unmapped (NWP-20261114-18)" \
  && ok "$tag C9a the kept line names notsealed-unmapped" || no "$tag C9a no kept line for notsealed-unmapped (log: $(cat "$T/log"))"
if haslog "$T" "user 10 cleared"; then no "$tag C9a a cleared line was logged"; else ok "$tag C9a no cleared line"; fi

echo "== $tag C9b the same with the import mapped: the head holds it, the staging is cleared =="
T=$(intcase '1010001 com.a
1010002 com.c
' "1010001"); intrun "$sh" "$T" prof
[ "$(cat "$T/res")" = notsealed ] && ok "$tag C9b KS_VERDICT is notsealed" || no "$tag C9b KS_VERDICT '$(cat "$T/res")', want notsealed"
[ "$(heads "$T")" = "com.a.keys com.b.keys com.c.keys " ] && ok "$tag C9b the landed head holds every bundle" \
  || no "$tag C9b the store head is '$(heads "$T")'"
gone "$T/import/1010002.keys" && gone "$T/nw/keystore-in/10" && ok "$tag C9b this uid's staging is removed" || no "$tag C9b this uid's staging is still there"
[ -f "$T/import/1110002.keys" ] && [ -f "$T/nw/keystore-in/11/com.x.keys" ] && ok "$tag C9b user 11's staging stays" || no "$tag C9b user 11's staging was removed"
haslog "$T" "cleared (1 restored bundle(s), 1 staged import(s)) after #keys notsealed$NS6 (NWP-20261114-18)" \
  && ok "$tag C9b the cleared line carries the #6 suffix" || no "$tag C9b no cleared line with the #6 suffix (log: $(cat "$T/log"))"

echo "== $tag C9c an unmapped export, the import mapped: the staging is cleared =="
T=$(intcase '1010001 com.a
1010002 com.c
' "1010001 1010009"); intrun "$sh" "$T" prof
gone "$T/import/1010002.keys" && gone "$T/nw/keystore-in/10" && haslog "$T" "after #keys notsealed$NS6" \
  && ok "$tag C9c an unmapped export does not keep the staging" || no "$tag C9c the staging was kept (log: $(cat "$T/log"))"

echo "== $tag C9d no credentials, an unmapped import: nothing pushed, the head is the restored one, the staging is cleared =="
T=$(intcase '1010001 com.a
' "1010001"); intrun "$sh" "$T" ""
[ "$(heads "$T")" = "com.b.keys com.c.keys " ] && ok "$tag C9d the head is untouched" || no "$tag C9d the store head is '$(heads "$T")'"
gone "$T/import/1010002.keys" && gone "$T/nw/keystore-in/10" && haslog "$T" "after #keys notsealed$NS6" \
  && ok "$tag C9d the credless defer clears the staging" || no "$tag C9d the staging was kept (log: $(cat "$T/log"))"

echo "== $tag C9e a stale KS_STAGE_VERDICT from an earlier op does not keep a safe reap's staging =="
T=$(intcase '1010001 com.a
1010002 com.c
' "1010001"); intrun "$sh" "$T" prof KS_STAGE_VERDICT=notsealed-unmapped
gone "$T/import/1010002.keys" && gone "$T/nw/keystore-in/10" && haslog "$T" "after #keys notsealed$NS6" \
  && ok "$tag C9e the stale value is reset" || no "$tag C9e the staging was kept (log: $(cat "$T/log"))"
fi
done

echo "== source pins =="
CALL=$(printf '%s\n' "$OP" | grep -n '^  ks_reap_clear "\$uid" "\$_kssv"' | head -1 | cut -d: -f1)
SVRD=$(printf '%s\n' "$OP" | grep -n '^  _kssv="\${KS_STAGE_VERDICT:-\$_ksv}"' | head -1 | cut -d: -f1)
VERD=$(printf '%s\n' "$OP" | grep -n '^  _ksv="\$KS_VERDICT"' | head -1 | cut -d: -f1)
if [ -n "$CALL" ] && [ -n "$SVRD" ] && [ -n "$VERD" ] && [ "$SVRD" -gt "$VERD" ] && [ "$CALL" -gt "$SVRD" ]; then
  ok 'W1 cleanstorage captures _kssv after _ksv and calls ks_reap_clear "$uid" "$_kssv" after both'
else
  no 'W1 cleanstorage does not capture _kssv="${KS_STAGE_VERDICT:-$_ksv}" after _ksv="$KS_VERDICT" and call ks_reap_clear "$uid" "$_kssv" after it'
fi
NS=$(printf '%s\n' "$OP" | awk '/^  if \[ "\$_ksv" = notsealed \]; then$/ { on = 1 } on { print } on && /^  fi$/ { exit }')
w2=yes
case "$NS" in *'"$KS_EXPORT/$uid"[0-9][0-9][0-9][0-9][0-9].keys'*) ;; *) w2=no ;; esac
case "$NS" in *'"$KS_EXPORT"/*.keys'*) w2=no ;; esac
case "$NS" in *'destroyed the unsealable #keys dump'*) ;; *) w2=no ;; esac
[ "$w2" = yes ] && ok "W2 the notsealed export removal is this uid's glob, not every user's" \
  || no "W2 the notsealed export removal is not \"\$KS_EXPORT/\$uid\"[0-9]{5}.keys (or still names \"\$KS_EXPORT\"/*.keys)"

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each must CONVICT the suite, under each shell) =="
  # mutate <label> <sed args...>: the mutant must apply, and the suite must exit non-zero with a FAIL line.
  mutate(){ local m label="$1" s rc out; shift
    m=$(mktemp -d -p "$W")
    if ! sed "$@" "$SUT" > "$m/m" 2>"$m/err"; then no "MUTATION BROKEN (sed): $label: $(cat "$m/err")"; rm -rf "$m"; return; fi
    if cmp -s "$SUT" "$m/m"; then no "MUTATION INERT: $label"; rm -rf "$m"; return; fi
    for s in "${SHELLS[@]}"; do
      out=$(ONLY_SHELL="$s" bash "$0" "$m/m" 2>&1); rc=$?
      case "$out" in *'  FAIL  '*) ;; *) rc=0 ;; esac
      if [ "$rc" -eq 0 ]; then no "SURVIVED $label [${s##*/}] -- suite passes on broken code"; else ok "CONVICTED $label [${s##*/}]"; fi
    done
    rm -rf "$m"
  }
  mutate "Q1': the notsealed arm is kept as today" -e '/^ks_reap_clear() {$/,/^}$/ s@^    notsealed) _why=.*@    notsealed) echo "[roamd] reap: keystore staging of user $_u kept: #keys $_v (NWP-20261114-18) $(date)" >> "$LOG"; return 0 ;;@'
  mutate "Q2: the import glob drops the uid prefix" -e 's@"\$KS_IMPORT/\$_u"\[0-9\]\[0-9\]\[0-9\]\[0-9\]\[0-9\]\.keys@"$KS_IMPORT"/*.keys@'
  mutate "Q3: the keystore-in removal takes every user's" -e 's@^  _d="\$KS_IN/\$_u"$@  _d="$KS_IN"@'
  mutate "Q4: the call line is deleted" -e '/^  ks_reap_clear "\$uid" "\$_kssv"/d'
  mutate "Q5: the notsealed export removal reverts to every user's" \
    -e 's@^    for _kx in "\$KS_EXPORT/\$uid"\[0-9\]\[0-9\]\[0-9\]\[0-9\]\[0-9\]\.keys; do@    for _kx in "$KS_EXPORT"/*.keys; do@'
  mutate "Q6: rm diagnostics go to the log" -e '/^ks_reap_clear() {$/,/^}$/ s@rm -f "\$_f" 2>/dev/null@rm -f "$_f" 2>>"$LOG"@'
  mutate "Q7: a failed removal counts as cleared" -e '/^ks_reap_clear() {$/,/^}$/ s@then _c=\$((_c + 1)); else _a=\$((_a + 1)); fi@then _a=$((_a + 1)); else _a=$((_a + 1)); fi@' \
    -e '/^ks_reap_clear() {$/,/^}$/ s@then _c=\$((_c + 1)); else _b=\$((_b + 1)); fi@then _b=$((_b + 1)); else _b=$((_b + 1)); fi@'
  mutate "Q8: the import glob drops the uid prefix for notsealed only" \
    -e '/^ks_reap_clear() {$/,/^}$/ s@"\$KS_IMPORT/\$_u"\[0-9\]\[0-9\]\[0-9\]\[0-9\]\[0-9\]\.keys@"$KS_IMPORT/$([ -n "$_why" ] || printf %s "$_u")"*.keys@'
  mutate "Q8b: the keystore-in removal takes every user's for notsealed only" \
    -e '/^ks_reap_clear() {$/,/^}$/ s@^  _d="\$KS_IN/\$_u"$@  _d="$KS_IN/$_u"; [ -z "$_why" ] || _d="$KS_IN"@'
  mutate "Q9: the log line names a file" -e '/^ks_reap_clear() {$/,/^}$/ s@ cleared (\$_a restored@ cleared ($_f, $_a restored@'
  mutate "Q10: keystore_push never sets notsealed-unmapped" -e '/^    \[ "\$_knomapi" = 0 \] || KS_STAGE_VERDICT=notsealed-unmapped$/d'
  mutate "Q11: cleanstorage passes \$_ksv, not \$_kssv" -e 's@^  ks_reap_clear "\$uid" "\$_kssv"@  ks_reap_clear "$uid" "$_ksv"@'
  mutate "Q12: the KS_STAGE_VERDICT reset is deleted" -e '/^keystore_push() {$/,/^}$/ { /^  KS_STAGE_VERDICT=""/d; }'
  mutate "Q13: an unmapped export also sets notsealed-unmapped" \
    -e '/^keystore_push() {$/,/^}$/ s@\[roamd\] keystore_push: ns \$_ns has no package mapping, dropped \$_kmev \$(date)" >> "\$LOG"; _knomap=\$((_knomap + 1));@&_knomapi=$((_knomapi + 1));@'
  mutate "Q14: ks_reap_clear clears on notsealed-unmapped too" -e '/^ks_reap_clear() {$/,/^}$/ s@^    notsealed) _why=@    notsealed|notsealed-unmapped) _why=@'
fi

echo
echo "shells: ${SHELLS[*]}"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
