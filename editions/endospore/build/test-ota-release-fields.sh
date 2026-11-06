#!/usr/bin/env bash
# test-ota-release-fields.sh [--mutate] -- ota-release-fields.sh refuses every flag file the phone's reader refuses
# (NWP-20261027-22).
#
# WHY THIS IS COMMITTED. The writer make-web-package.sh runs says it fails a malformed flag file "before anything is
# signed". The reader (core/agent/ota_mandatory.go, checkOtaText) also refuses a reason or consequence with leading or
# trailing space, a control character, more than 200 characters, invalid UTF-8, or a privacy/security claim word; when
# the writer did not, e4-ota-publish.sh refused the file only AFTER the operator had signed the manifest. These run the
# real script with python3 on fixture files. The Go side (TestOtaReleaseFields* in core/agent) holds the same rows
# against the reader and the claim-word pattern against ota_notes.go.
#
# The script under test is bash, and so is this suite: its cases run under bash only (not dash or mksh).
#
#   bash test-ota-release-fields.sh            # the cases
#   bash test-ota-release-fields.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
SUT="${SUT:-$(cd "$(dirname "$0")" && pwd)/ota-release-fields.sh}"
[ -f "$SUT" ] || { echo "no such file: $SUT" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
GOOD_R='A reason.'; GOOD_C='A consequence.'

# fixture <reason> <consequence>: a critical flag file for 0.5.45; prints its path.
fixture() {
  local f; f=$(mktemp -p "$W") || return 1
  printf 'version 0.5.45\nseverity critical\nreason %s\nconsequence %s\n' "$1" "$2" > "$f"
  printf '%s' "$f"
}

# run <file>: sets RC, OUT, ERR.
run() {
  local o e
  o=$(mktemp -p "$W"); e=$(mktemp -p "$W")
  NOWHERE_OTA_PUBLISHED=2026-10-12 bash "$SUT" 0.5.45 "$1" >"$o" 2>"$e"; RC=$?
  OUT=$(cat "$o"); ERR=$(cat "$e")
}

# refused <name> <substring of stderr> <file>
refused() {
  run "$3"
  case "$ERR" in *Traceback*) no "$1: a traceback, not a message"; return ;; esac
  if [ "$RC" -eq 0 ]; then no "$1: accepted: $OUT"; return; fi
  case "$ERR" in *"$2"*) ok "$1" ;; *) no "$1: refused without \"$2\": $ERR" ;; esac
}

f=$(fixture "Sign-in now asks the servers differently — café." "$GOOD_C"); run "$f"
case "$OUT" in
  *'"severity": "critical"'*"Sign-in now asks the servers differently — café."*) [ "$RC" -eq 0 ] && ok "a good critical file is accepted, its reason verbatim" || no "a good file exited $RC" ;;
  *) no "a good file: rc $RC, out $OUT, err $ERR" ;;
esac

long=$(printf 'é%.0s' $(seq 200)); f=$(fixture "$long" "$GOOD_C"); run "$f"
case "$OUT" in *"$long"*) [ "$RC" -eq 0 ] && ok "a reason of exactly 200 characters is accepted" || no "200 characters exited $RC" ;; *) no "200 characters: rc $RC, err $ERR" ;; esac

refused "w1 a reason with a trailing space"         reason      "$(fixture "A reason. " "$GOOD_C")"
refused "w2 a consequence with a leading space"     consequence "$(fixture "$GOOD_R" " A consequence.")"
refused "w3 a reason holding a tab"                 reason      "$(fixture "A"$'\t'"reason." "$GOOD_C")"
refused "w4 a reason of 201 characters"             reason      "$(fixture "$(printf 'x%.0s' $(seq 201))" "$GOOD_C")"
refused "w5 a reason saying security"               reason      "$(fixture "Fixes a security problem in sign-in." "$GOOD_C")"
refused "w6 a reason saying Privacy"                reason      "$(fixture "Privacy settings now load faster." "$GOOD_C")"
refused "w7 a reason saying encrypted"              reason      "$(fixture "Backups are encrypted differently." "$GOOD_C")"
refused "w8 a reason saying can't see"              reason      "$(fixture "Our servers can't see the old format." "$GOOD_C")"
f=$(mktemp -p "$W"); printf 'version 0.5.45\nseverity critical\nreason Bad byte \377 here.\nconsequence %s\n' "$GOOD_C" > "$f"
refused "w9 a reason holding the byte 0xff"         "not UTF-8" "$f"
refused "w10 a reason with ésafe"                   reason      "$(fixture "Now ésafe to use." "$GOOD_C")"
f=$(mktemp -p "$W"); printf 'version 0.5.45\nseverity critical\nreason A reason.\nconsequence A consequence.\r' > "$f"
refused "w11 a lone CR at the end of the file"      consequence "$f"
refused "w12 a reason with ſ (RE2 folds it to s)"   reason      "$(fixture "Sign-in is anonymouſly faster." "$GOOD_C")"
refused "w13 a reason with K (RE2 folds it to k)"   reason      "$(fixture "No more tracKing pixels." "$GOOD_C")"

run "$W/absent"
case "$OUT" in *'"severity": "none"'*) [ "$RC" -eq 0 ] && ok "an absent file is an ordinary release" || no "absent file exited $RC" ;; *) no "absent file: rc $RC, out $OUT" ;; esac

if [ "$MUTATE" = yes ]; then
  echo
  echo "== mutations (each MUST be convicted) =="
  M=$(mktemp -d -p "$W")
  mutate() {
    if ! sed "$2" "$SUT" > "$M/ota-release-fields.sh" 2>"$M/err"; then no "MUTATION BROKEN (sed): $1"; return; fi
    if cmp -s "$SUT" "$M/ota-release-fields.sh"; then no "MUTATION INERT: $1"; return; fi
    if bash "$0" "$M/ota-release-fields.sh" >/dev/null 2>&1; then no "NOT CONVICTED: $1 -- suite passes on broken code"
    else ok "convicted: $1"; fi
  }
  mutate "F1 the whitespace check removed"          '/^        if v != v.strip():$/,+1d'
  mutate "F2 the length check removed"              '/^        if len(v) > TEXT_MAX:$/,+1d'
  mutate "F3 the control-character check removed"   '/^        if any(unicodedata.category(c) == "Cc" for c in v):$/,+1d'
  mutate "F4 the claim-word check removed"          's/^        m = CLAIM_RE.search(v)$/        m = None/'
  mutate "F5 re.ASCII dropped"                      's/re.IGNORECASE | re.ASCII)/re.IGNORECASE)/'
  mutate "F6 re.IGNORECASE dropped"                 's/re.IGNORECASE | re.ASCII)/re.ASCII)/'
  mutate "F7 security deleted from CLAIM_WORDS"     '/^CLAIM_WORDS = r"/s/security|//'
  mutate "F8 the UTF-8 decode error not caught"     's/except UnicodeDecodeError:/except ZeroDivisionError:/'
  mutate "F9 universal newlines on the file read"   's/, newline=""//'
  mutate "F10 the RE2 case folds not spelled out"   's/^CLAIM_RE = re\.compile(.*$/CLAIM_RE = re.compile(CLAIM_WORDS, re.IGNORECASE | re.ASCII)/'
  rm -rf "$M"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
