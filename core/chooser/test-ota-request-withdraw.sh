#!/usr/bin/env bash
# test-ota-request-withdraw.sh [<ProfileActivity.java>] [--mutate] -- a "Sign out & install" request is withdrawn
# by every sign-out that is not the install button's own (NWP-20261017-17).
#
# WHY. The request lives in the daemon's RAM for 2 h. A Profile screen that recorded it and died before LOGOUT left
# it pending, and a later sign-out of that session (the failed-unlock auto-logoff, which never probes) would start an
# install nobody tapped at that moment. The rule is structural: doLogoff() withdraws, doLogoffForInstall() is the
# one sign-out that does not, and confirmSignOutAndInstall is its only caller.
#
# PINNED (source level, file-based -- no `| grep -q` under pipefail):
#   a. the withdrawing sign-out writes OTA-AFTER-LOGOFF\n0\n BEFORE LOGOUT\n in the same method (order, not presence);
#   b. doLogoffForInstall() is called exactly once, from confirmSignOutAndInstall, and doLogoffImpl(false) is reached
#      only by doLogoff(); the count of plain doLogoff() call sites is pinned, so a NEW one is a deliberate edit;
#   c. confirmSignOutAndInstall uses the non-withdrawing variant and still records `1 <uid> <nonce>`;
#   d. onCreate's auto branch calls the withdrawing doLogoff() (onNewIntent's is pinned by test-auto-logoff-gate-java.sh);
#   e. daemon side (Go): handleColdLock withdraws once the lock is taken -- TestHandleColdLockWithdrawsOtaRequestWhenLockTaken.
#      Needs a Go toolchain; --mutate FAILS without one rather than skipping that leg.
# No JDK leg: the lifted members are not compiled here (the merger's javac check covers ProfileActivity).
#
#   bash test-ota-request-withdraw.sh            # the invariants
#   bash test-ota-request-withdraw.sh --mutate   # ... plus mutants that must each CONVICT
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SUT:-$HERE/src/com/nowhere/chooser/ProfileActivity.java}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
AGENT="$HERE/../agent"

# Whole-line // and javadoc comments dropped (strings are kept: the wire text is the thing under test).
code_of() { grep -vE '^[[:space:]]*(//|/\*|\*)' "$1"; }

# method <file> <header-regex> -> the method's lines, header to the closing 4-space brace.
method() {
  RE="$2" awk '
    !on && $0 ~ ENVIRON["RE"] { on = 1 }
    on { print }
    on && $0 ~ /^    }$/ { exit }
  ' "$1"
}

suite() {
  local f="$1" quiet="${2:-}" p=0 x=0 tmp
  ok(){ p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  no(){ x=$((x+1)); [ -n "$quiet" ] || printf '  FAIL  %s\n' "$1"; }
  tmp=$(mktemp -d)
  code_of "$f" > "$tmp/code.java"
  method "$tmp/code.java" 'private void doLogoffImpl\(' > "$tmp/impl.java"
  method "$tmp/code.java" 'private void confirmSignOutAndInstall\(' > "$tmp/confirm.java"
  method "$tmp/code.java" 'protected void onCreate\(' > "$tmp/oncreate.java"
  method "$tmp/code.java" 'private void doLogoff\(\)' > "$tmp/plain.java"
  method "$tmp/code.java" 'private void doLogoffForInstall\(\)' > "$tmp/forinstall.java"

  local s
  for s in impl confirm oncreate plain forinstall; do
    if [ -s "$tmp/$s.java" ]; then ok "found $s method"; else no "method $s not found -- scanner stale"; fi
  done

  # a. order: the withdrawal write precedes the LOGOUT write inside doLogoffImpl, and is guarded by !forInstall.
  local w l g
  w=$(grep -n 'OTA-AFTER-LOGOFF\\n0\\n' "$tmp/impl.java" | head -1 | cut -d: -f1)
  l=$(grep -n 'LOGOUT\\n' "$tmp/impl.java" | head -1 | cut -d: -f1)
  if [ -n "$w" ] && [ -n "$l" ] && [ "$w" -lt "$l" ]; then ok "withdrawal (line $w) precedes LOGOUT (line $l) in doLogoffImpl"
  else no "OTA-AFTER-LOGOFF 0 must be sent before LOGOUT in doLogoffImpl (withdrawal at '${w:-none}', LOGOUT at '${l:-none}')"; fi
  g=$(grep -c 'if (!forInstall) {' "$tmp/impl.java")
  if [ "$g" = 1 ]; then ok "the withdrawal is skipped only when forInstall"
  else no "doLogoffImpl lacks the single 'if (!forInstall) {' guard around the withdrawal"; fi
  if [ -n "$w" ] && [ -n "$g" ] && [ "$(grep -n 'if (!forInstall) {' "$tmp/impl.java" | head -1 | cut -d: -f1)" -lt "$w" ] 2>/dev/null; then ok "the withdrawal sits under the guard"
  else no "the withdrawal is not under the !forInstall guard"; fi

  # b. call sites.
  local n_inst n_impl_f n_impl_t n_plain
  n_inst=$(grep -c 'doLogoffForInstall()' "$tmp/code.java")          # definition + calls
  if [ "$n_inst" = 2 ]; then ok "doLogoffForInstall(): its definition and exactly one call"
  else no "doLogoffForInstall() appears $n_inst times in code, want 2 (definition + the one call)"; fi
  if grep -q 'doLogoffForInstall()' "$tmp/confirm.java"; then ok "that call is in confirmSignOutAndInstall"
  else no "confirmSignOutAndInstall does not call doLogoffForInstall()"; fi
  n_impl_f=$(grep -c 'doLogoffImpl(false)' "$tmp/code.java"); n_impl_t=$(grep -c 'doLogoffImpl(true)' "$tmp/code.java")
  if [ "$n_impl_f" = 1 ] && [ "$n_impl_t" = 1 ] && grep -q 'doLogoffImpl(false)' "$tmp/plain.java" && grep -q 'doLogoffImpl(true)' "$tmp/forinstall.java"; then
    ok "doLogoffImpl(false) only in doLogoff(), doLogoffImpl(true) only in doLogoffForInstall()"
  else no "doLogoffImpl is reached from somewhere else ($n_impl_f false / $n_impl_t true)"; fi
  # doLogoff() call sites (plus its definition): onCreate auto, onNewIntent auto (NWP-20261113-02), the Profile button x2,
  # the drop-and-sign-out dialog, the KEY-END retry (NWP-20261111-07).
  # a method reference (runOnUiThread(this::doLogoff), NWP-20261029-19) is a call site too
  n_plain=$(( $(grep -c 'doLogoff()' "$tmp/code.java") + $(grep -cE 'this::doLogoff([^A-Za-z0-9_]|$)' "$tmp/code.java") ))
  if [ "$n_plain" = 7 ]; then ok "doLogoff(): its definition and 6 call sites (the KEY-END retry, NWP-20261111-07; onNewIntent auto, NWP-20261113-02) -- all withdrawing"
  else no "doLogoff() appears $n_plain times in code, want 7 (definition + 6 sites); a new sign-out path needs a decision, update this count"; fi

  # c. the install button's own path.
  if grep -q 'OTA-AFTER-LOGOFF\\n1 ' "$tmp/confirm.java"; then ok "confirmSignOutAndInstall still records the request"
  else no "confirmSignOutAndInstall no longer sends 'OTA-AFTER-LOGOFF 1 <uid> <nonce>'"; fi
  if ! grep -qE 'doLogoff\(\)|doLogoffImpl\(false\)' "$tmp/confirm.java"; then ok "confirmSignOutAndInstall never uses the withdrawing variant"
  else no "confirmSignOutAndInstall uses the withdrawing sign-out -- it would cancel its own request"; fi

  # d. the auto branch.
  if grep -q 'getBooleanExtra("auto", false)' "$tmp/oncreate.java" \
     && [ "$(grep -A2 'getBooleanExtra("auto", false)' "$tmp/oncreate.java" | grep -c 'doLogoff();')" = 1 ]; then
    ok "onCreate's auto branch calls the withdrawing doLogoff()"
  else no "onCreate's auto branch does not call doLogoff()"; fi

  rm -rf "$tmp"
  [ -n "$quiet" ] || printf '%s passed, %s failed\n' "$p" "$x"
  [ "$x" = 0 ]
}

LAST_GO_OUT=""
go_leg() {  # <main.go to pin> -> 0 when the Go pin passes
  command -v go >/dev/null 2>&1 || { echo "  FAIL  no Go toolchain: the daemon leg cannot run" >&2; return 2; }
  local out rc
  out=$(cd "$AGENT" && NOWHERE_COLDLOCK_MAIN_SRC="$1" go test -count=1 -run 'TestColdLockWithdrawsSignOutAndInstallRequest|TestHandleColdLockWithdrawsOtaRequestWhenLockTaken' -v . 2>&1); rc=$?
  LAST_GO_OUT="$out"
  return $rc
}

suite "$SUT" || { echo "FAIL"; exit 1; }
if [ "$MUTATE" != yes ]; then
  go_leg "$AGENT/main.go" || { printf '%s\n' "$LAST_GO_OUT" | tail -20; echo "FAIL (daemon leg)"; exit 1; }
  echo "ok    daemon: handleColdLock withdraws the request"
  echo "PASS"; exit 0
fi

fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mutate() {  # <label> <python program operating on s>
  local label="$1" m="$tmp/m.java"
  cp "$SUT" "$m"
  if ! PROG="$2" python3 -c '
import os, sys
p = sys.argv[1]; s = open(p).read(); o = s
exec(os.environ["PROG"])
if s == o: sys.exit(3)
open(p, "w").write(s)
' "$m"; then echo "  FAIL  mutant did not apply: $label"; fail=1; return; fi
  if suite "$m" quiet; then echo "  FAIL  SURVIVED: $label"; fail=1; else echo "  ok    convicted: $label"; fi
}
mutate 'auto branch reverted to the non-withdrawing call' \
  's = s.replace("            doLogoff();\n            return;", "            doLogoffForInstall();\n            return;", 1)'
mutate 'withdrawal moved after LOGOUT' \
  'a = s.index("            if (!forInstall) {"); b = s.index("            boolean acked = false;"); blk = s[a:b]; s = s[:a] + s[b:]; k = s.index("                acked = LogoutAck.acked("); s = s[:k] + blk + s[k:]'
mutate 'confirmSignOutAndInstall switched to the withdrawing variant' \
  's = s.replace("doLogoffForInstall();\n                        } else {", "doLogoff();\n                        } else {", 1)'
mutate 'a new plain doLogoff() call site' \
  's = s.replace("    private void doLogoffForInstall() {", "    private void newPath() { doLogoff(); }\n    private void doLogoffForInstall() {", 1)'
mutate 'the withdrawal is skipped for every sign-out' \
  's = s.replace("if (!forInstall) {", "if (forInstall) {", 1)'

# Daemon mutant: the call removed from handleColdLock must make the Go pin FAIL (a copy that cannot be compiled is not a conviction).
sed '/^\twithdrawOtaAfterLogoffForColdLock(uid)$/d' "$AGENT/main.go" > "$tmp/main_mut.go"
if cmp -s "$AGENT/main.go" "$tmp/main_mut.go"; then echo "  FAIL  Go mutant did not apply"; fail=1
elif go_leg "$tmp/main_mut.go"; then echo "  FAIL  SURVIVED: handleColdLock's call removed"; fail=1
elif printf '%s\n' "$LAST_GO_OUT" | grep -q -- '--- FAIL: TestHandleColdLockWithdrawsOtaRequestWhenLockTaken'; then echo "  ok    convicted: handleColdLock's call removed"
else echo "  FAIL  Go mutant failed without a --- FAIL (build error or no toolchain)"; fail=1; fi

[ "$fail" = 0 ] && { echo "PASS"; exit 0; }
echo "FAIL"; exit 1
