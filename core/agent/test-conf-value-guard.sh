#!/usr/bin/env bash
# test-conf-value-guard.sh [--mutate] -- NWP-20261030-01: the nowhere.conf writers refuse a value that is not inert as a
# sourced KEY=value assignment. Runs the focused Go tests; --mutate applies each mutant to pristine copies of
# conf_value_guard.go and main.go (restored on exit) and requires a real `--- FAIL`: a mutant that does not apply, or
# that does not compile, is a failure, never a conviction.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp main.go "$W/main.go.orig" || exit 2
cp conf_value_guard.go "$W/guard.go.orig" || exit 2
trap 'cp "$W/main.go.orig" main.go; cp "$W/guard.go.orig" conf_value_guard.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN="ConfValueGuard|ConfWriter|WriteManagedConf"
out=$(go test -count=1 -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# mutate <label> <file> <python body acting on s>: apply to a pristine copy, require a real --- FAIL
mutate() {
  local lbl="$1" f="$2" body="$3" o
  cp "$W/main.go.orig" main.go; cp "$W/guard.go.orig" conf_value_guard.go
  if ! python3 -c "
f = '$f'
s = open(f).read(); t = s
$body
if t == s: raise SystemExit('mutant did not apply')
open(f,'w').write(t)"; then
    echo "  FAIL  MUTATION BROKEN: $lbl"; FAILS=$((FAILS+1))
    cp "$W/main.go.orig" main.go; cp "$W/guard.go.orig" conf_value_guard.go; return
  fi
  o=$(go test -count=1 -run "$RUN" . 2>&1)
  case "$o" in
    *"--- FAIL"*) echo "  ok    convicted: $lbl" ;;
    *) echo "  FAIL  NOT CONVICTED (no --- FAIL; a compile error is not a conviction): $lbl"; FAILS=$((FAILS+1)) ;;
  esac
  cp "$W/main.go.orig" main.go; cp "$W/guard.go.orig" conf_value_guard.go
}
echo "== mutations =="
mutate "M1: \$ added to the allow-list" conf_value_guard.go "
t = s.replace(\"c == '+', c == '=', c == '%':\", \"c == '+', c == '=', c == '%', c == '\$':\", 1)"
mutate "M2: ~ added to the allow-list" conf_value_guard.go "
t = s.replace(\"c == '+', c == '=', c == '%':\", \"c == '+', c == '=', c == '%', c == '~':\", 1)"
mutate "M3: writeStoreConf does not check" main.go "
t = s.replace('''		if err := checkConfValue(f.key, f.val); err != nil {
			return err
		}''', '''		_ = f''', 1)"
mutate "M4: upsertConfLine does not check" main.go "
t = s.replace('''	if !confKeyOK(key) {
		return fmt.Errorf(\"conf key: %w\", errConfValueUnsafe)
	}
	if err := checkConfValue(key, val); err != nil {
		return err
	}
''', '', 1)"
mutate "M5: writeManagedConf does not check" main.go "
t = s.replace('''	if err := checkConfValue(\"GATEWAY_URL\", gw); err != nil {
		return err
	}
''', '', 1)"
mutate "M6: writeStoreConf checks only the endpoint" main.go "
t = s.replace('{\"S3_ENDPOINT\", ep}, {\"S3_REGION\", rg}, {\"S3_BUCKET\", bk}, {\"S3_ACCESS_KEY\", ak}, {\"S3_SECRET_KEY\", sk},', '{\"S3_ENDPOINT\", ep},', 1)"
[ "$FAILS" = 0 ] || { echo "$FAILS mutant(s) not convicted"; exit 1; }
