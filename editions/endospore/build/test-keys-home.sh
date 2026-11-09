#!/usr/bin/env bash
# test-keys-home.sh [--mutate] [<keys-home.sh>] -- keys-home.sh gives a GrapheneOS tree one device's signing keys from the
# keys home, and refuses a tree whose keys are not the home's (NWP-20261105-19).
#
# Each case builds a synthetic tree and keys home in a temp dir and runs the script under every shell found (sh, bash,
# dash, mksh): it is POSIX sh, and build-device.sh and sign-release.sh call it with sh. Every run sets NOWHERE_KEYS_HOME
# to the case's own home (or to a path that does not exist), never to the host's. The fixture keys are text files.
# Three source pins check where the callers run it: build-device.sh after its dev-build exit and before its own key
# checks and the passphrase prompt; sign-release.sh first in check_keys, in the preflight, before the prompt; and the
# same default home in keys-home.sh and gen-keys.sh.
#
#   bash test-keys-home.sh             # the cases k1-k21 under every shell, and pins P1-P3
#   bash test-keys-home.sh --mutate    # ... plus mutants K1-K13 that must each CONVICT a named case
#
# Pure logic -- no build, no device, no network.
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${1:-$HERE/keys-home.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT"; exit 2; }
SUT=$(cd "$(dirname "$SUT")" && pwd)/$(basename "$SUT")
for t in readlink cmp sha256sum; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required"; exit 1; }; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
# The script refuses a keys home inside a source tree (an ancestor holding .repo/), so the fixtures must not sit in one.
p=$(readlink -f "$W"); while [ -n "$p" ] && [ "$p" != / ]; do
  [ -d "$p/.repo" ] && { echo "FAIL: the suite's temp dir $W is inside a source tree ($p); set TMPDIR elsewhere"; exit 1; }
  p=${p%/*}
done

SHELLS=""
for s in sh bash dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done
PUB="releasekey.x509.pem platform.x509.pem avb_pkmd.bin id_ed25519.pub"
PRIV="releasekey.pk8 platform.pk8 avb.pem id_ed25519"

# mkkeys <dir> <tag>: one device's fixture keys; every file holds <tag>
mkkeys() { local d="$1" f; mkdir -p "$d"; for f in $PUB $PRIV; do echo "$2-$f" > "$d/$f"; done; }

# snapd <dir> -> every file under <dir> with its sha256, and every link with its target
snapd() {
  (cd "$1" && find . \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"; else printf 'F %s %s\n' "$f" "$(sha256sum < "$f" | cut -d' ' -f1)"; fi
  done)
}

# has <haystack> <needle>: 0 if the fixed string <needle> is anywhere in <haystack>; no pipe
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# run <shell> <tree> <device> <home|-> [extra-arg]: OUT, ERR, RC. "-" = a home path that does not exist.
run() {
  local sh="$1" t="$2" d="$3" h="$4"
  [ "$h" = - ] && h="$W/no-such-home"
  if [ "$#" -ge 5 ]; then
    OUT=$(NOWHERE_KEYS_HOME="$h" "$sh" "$SUT" "$t" "$d" "$5" 2>"$W/err"); RC=$?
  else
    OUT=$(NOWHERE_KEYS_HOME="$h" "$sh" "$SUT" "$t" "$d" 2>"$W/err"); RC=$?
  fi
  ERR=$(cat "$W/err")
}

# world <name> -> a fresh case dir holding tree/ (empty) and nothing else; prints its path
world() { local c="$W/$1"; rm -rf "$c"; mkdir -p "$c/tree"; printf '%s\n' "$c"; }

P=0; X=0
ok()  { P=$((P+1)); printf '  ok    %s\n' "$1"; }
bad() { X=$((X+1)); printf '  FAIL  %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cases() {   # <shell>
  local sh="$1" c t h b hb
  # k1 the tree's own keys/ and no keys home: used, with the only-copy warning; nothing changed
  c=$(world k1); t="$c/tree"; mkkeys "$t/keys/dev" a; b=$(snapd "$c"); run "$sh" "$t" dev -
  chk "k1 [$sh] own keys/, no home: exit 0" '[ "$RC" = 0 ] && has "$OUT" "is this tree'"'"'s own keys directory"'
  chk "k1 [$sh] ... warns that it is the only copy" 'has "$OUT" "WARNING: the keys home has no"'
  chk "k1 [$sh] ... nothing changed" '[ "$(snapd "$c")" = "$b" ]'

  # k2 no keys/, a home holding dev: keys/ becomes a link to the home; the home is unchanged
  c=$(world k2); t="$c/tree"; h="$c/home"; mkkeys "$h/dev" a; hb=$(snapd "$h"); run "$sh" "$t" dev "$h"
  chk "k2 [$sh] no keys/, the home has dev: exit 0, linked" '[ "$RC" = 0 ] && [ -L "$t/keys" ] && [ "$(readlink "$t/keys")" = "$h" ] && has "$OUT" "linked $t/keys -> $h"'
  chk "k2 [$sh] ... the home unchanged" '[ "$(snapd "$h")" = "$hb" ]'
  # k3 a re-run of k2: the link is used as it is
  b=$(snapd "$c"); run "$sh" "$t" dev "$h"
  chk "k3 [$sh] re-run: exit 0, the link used, nothing changed" '[ "$RC" = 0 ] && has "$OUT" "(the keys home)" && [ "$(snapd "$c")" = "$b" ]'

  # k4 no keys/, a home without dev: refused, nothing created
  c=$(world k4); t="$c/tree"; h="$c/home"; mkkeys "$h/other" a; b=$(snapd "$c"); run "$sh" "$t" dev "$h"
  chk "k4 [$sh] no keys/, the home lacks dev: exit 4" '[ "$RC" = 4 ] && has "$ERR" "no signing keys for dev"'
  chk "k4 [$sh] ... nothing created" '[ ! -e "$t/keys" ] && [ ! -L "$t/keys" ] && [ "$(snapd "$c")" = "$b" ]'

  # k5 no keys/ and no home at all: refused, nothing created
  c=$(world k5); t="$c/tree"; run "$sh" "$t" dev -
  chk "k5 [$sh] no keys/, no home: exit 4, nothing created" '[ "$RC" = 4 ] && [ ! -e "$t/keys" ] && [ ! -L "$t/keys" ]'

  # k6 keys/ a link to another directory that holds dev: refused, the link unchanged
  c=$(world k6); t="$c/tree"; h="$c/home"; mkkeys "$h/dev" a; mkkeys "$c/elsewhere/dev" a; ln -s "$c/elsewhere" "$t/keys"
  b=$(snapd "$c"); run "$sh" "$t" dev "$h"
  chk "k6 [$sh] keys/ links elsewhere: exit 3, nothing changed" '[ "$RC" = 3 ] && has "$ERR" "not to the keys home" && [ "$(snapd "$c")" = "$b" ]'

  # k7 keys/ a regular file: refused
  c=$(world k7); t="$c/tree"; h="$c/home"; mkkeys "$h/dev" a; echo x > "$t/keys"; run "$sh" "$t" dev "$h"
  chk "k7 [$sh] keys/ a file: exit 3" '[ "$RC" = 3 ] && has "$ERR" "neither a directory nor a link"'

  # k8 keys/ a link to a home that has no dev: refused
  c=$(world k8); t="$c/tree"; h="$c/home"; mkkeys "$h/other" a; ln -s "$h" "$t/keys"; run "$sh" "$t" dev "$h"
  chk "k8 [$sh] linked, the home lacks dev: exit 4" '[ "$RC" = 4 ] && has "$ERR" "is not a directory"'

  # k9 the tree's own keys/ and a home holding dev: every public half identical, every private half different (as a
  # re-encryption leaves them): used
  c=$(world k9); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkkeys "$h/dev" a
  for f in $PRIV; do echo "re-encrypted-$f" > "$h/dev/$f"; done
  run "$sh" "$t" dev "$h"
  chk "k9 [$sh] own keys/ matching the home's public halves: exit 0" '[ "$RC" = 0 ] && has "$OUT" "match the keys home'"'"'s"'

  # k10 the same, but the home's avb_pkmd.bin differs: refused, the file named
  c=$(world k10); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkkeys "$h/dev" a; echo another-root > "$h/dev/avb_pkmd.bin"
  run "$sh" "$t" dev "$h"
  chk "k10 [$sh] a different avb_pkmd.bin: exit 3, named" '[ "$RC" = 3 ] && has "$ERR" "$t/keys/dev/avb_pkmd.bin differs"'

  # k11 the same, with a different releasekey certificate
  c=$(world k11); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkkeys "$h/dev" a; echo another-cert > "$h/dev/releasekey.x509.pem"
  run "$sh" "$t" dev "$h"
  chk "k11 [$sh] a different releasekey.x509.pem: exit 3, named" '[ "$RC" = 3 ] && has "$ERR" "$t/keys/dev/releasekey.x509.pem differs"'

  # k12 the tree's own keys/ without dev, while the home has dev: refused, with the way out
  c=$(world k12); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/other" a; mkkeys "$h/dev" a; run "$sh" "$t" dev "$h"
  chk "k12 [$sh] own keys/ without dev, the home has it: exit 4, says move it aside" '[ "$RC" = 4 ] && has "$ERR" "aside and re-run"'

  # k13 usage: exit 2 and nothing created
  c=$(world k13); t="$c/tree"; h="$c/home"; mkkeys "$h/dev" a
  run "$sh" "$t" dev "$h" extra;  chk "k13 [$sh] a third argument: exit 2" '[ "$RC" = 2 ]'
  run "$sh" "$t" "" "$h";         chk "k13 [$sh] an empty device: exit 2" '[ "$RC" = 2 ]'
  run "$sh" "$t" ../dev "$h";     chk "k13 [$sh] a device with a slash: exit 2" '[ "$RC" = 2 ]'
  run "$sh" "$t" .dev "$h";       chk "k13 [$sh] a device with a leading dot: exit 2" '[ "$RC" = 2 ]'
  run "$sh" "$t" -dev "$h";       chk "k13 [$sh] a device with a leading dash: exit 2" '[ "$RC" = 2 ]'
  run "$sh" "$c/no-tree" dev "$h"; chk "k13 [$sh] no tree: exit 2" '[ "$RC" = 2 ]'
  run "$sh" "$t" dev "k13/home";  chk "k13 [$sh] a relative NOWHERE_KEYS_HOME: exit 2" '[ "$RC" = 2 ]'
  chk "k13 [$sh] ... nothing created" '[ ! -e "$t/keys" ] && [ ! -L "$t/keys" ]'

  # k14 keys/ a link to the home path while the home does not exist: refused
  c=$(world k14); t="$c/tree"; h="$c/home"; ln -s "$h" "$t/keys"; run "$sh" "$t" dev "$h"
  chk "k14 [$sh] linked to a missing home: exit 4" '[ "$RC" = 4 ] && has "$ERR" "does not exist"'

  # k15 the tree's own copy lacks a public half the home has: only the halves both hold are compared
  c=$(world k15); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkkeys "$h/dev" a; rm -f "$t/keys/dev/id_ed25519.pub"
  run "$sh" "$t" dev "$h"
  chk "k15 [$sh] a half missing from the tree's copy: exit 0" '[ "$RC" = 0 ]'

  # k16 keys/ a dangling link to elsewhere: refused
  c=$(world k16); t="$c/tree"; h="$c/home"; mkkeys "$h/dev" a; ln -s "$c/gone" "$t/keys"; run "$sh" "$t" dev "$h"
  chk "k16 [$sh] a dangling link elsewhere: exit 3" '[ "$RC" = 3 ]'

  # k17 the tree's own keys/ and the home differ only in id_ed25519.pub: refused, the file named
  c=$(world k17); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkkeys "$h/dev" a; echo another-ssh > "$h/dev/id_ed25519.pub"
  run "$sh" "$t" dev "$h"
  chk "k17 [$sh] a different id_ed25519.pub: exit 3, named" '[ "$RC" = 3 ] && has "$ERR" "$t/keys/dev/id_ed25519.pub differs"'

  # k18 the tree's own keys/ and a home that exists but holds only another device: used, with the only-copy warning
  c=$(world k18); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkkeys "$h/other" a; run "$sh" "$t" dev "$h"
  chk "k18 [$sh] own keys/, the home lacks dev: exit 0, warns, no match line" \
    '[ "$RC" = 0 ] && has "$OUT" "WARNING: the keys home has no" && ! has "$OUT" "match the keys home"'

  # k19 the home holds dev but none of its public halves: nothing compared, so a warning and no match line
  c=$(world k19); t="$c/tree"; h="$c/home"; mkkeys "$t/keys/dev" a; mkdir -p "$h/dev"; for f in $PRIV; do echo "a-$f" > "$h/dev/$f"; done
  run "$sh" "$t" dev "$h"
  chk "k19 [$sh] the home's dev holds no public half: exit 0, warns, no match line" \
    '[ "$RC" = 0 ] && has "$OUT" "nothing was compared" && ! has "$OUT" "match the keys home"'

  # k20 a keys home inside a source tree (an ancestor holds .repo/): refused before anything is linked
  c=$(world k20); t="$c/tree"; mkdir -p "$c/src/.repo"; mkkeys "$c/src/keys/dev" a; run "$sh" "$t" dev "$c/src/keys"
  chk "k20 [$sh] a home inside a source tree: exit 3, nothing linked" \
    '[ "$RC" = 3 ] && has "$ERR" "inside a source tree" && [ ! -e "$t/keys" ] && [ ! -L "$t/keys" ]'

  # k21 the home's dev is a link into the tree's own keys/ (one copy under two names): refused, no match line
  c=$(world k21); t="$c/tree"; h="$c/home"; mkdir -p "$t/.repo" "$h"; mkkeys "$t/keys/dev" a; ln -s "$t/keys/dev" "$h/dev"
  run "$sh" "$t" dev "$h"
  chk "k21 [$sh] the home's dev links into the tree: exit 3, no match line" \
    '[ "$RC" = 3 ] && has "$ERR" "inside a source tree" && ! has "$OUT" "match the keys home"'
}

# line <file> <exact line> -> its line number, only when it occurs exactly once
line() { awk -v want="$2" '$0 == want { n++; at = NR } END { if (n == 1) print at }' "$1"; }

pins() {
  local B="$HERE/build-device.sh" S="$HERE/sign-release.sh" G="$HERE/gen-keys.sh" dv kh id gr ck kc fk pr ks gk
  dv=$(line "$B" 'if [ "$DO_RELEASE" -eq 0 ]; then')
  kh=$(line "$B" 'sh "$REPO/editions/endospore/build/keys-home.sh" "$TREE" "$DEV" || fail "signing keys for $DEV (keys-home.sh)"')
  id=$(line "$B" 'if [ ! -f "$TREE/keys/$DEV/id_ed25519" ]; then')
  gr=$(line "$B" 'bash script/generate-release.sh "$DEV" "$BN" || fail "generate-release"')
  chk "P1 build-device.sh runs keys-home.sh after the dev-build exit, before its key checks and generate-release" \
    '[ -n "$dv" ] && [ -n "$kh" ] && [ -n "$id" ] && [ -n "$gr" ] && [ "$dv" -lt "$kh" ] && [ "$kh" -lt "$id" ] && [ "$id" -lt "$gr" ]'
  ck=$(line "$S" 'check_keys() {     # <dev>: 2c, the key files build-device.sh checks before its own prompt')
  kc=$(line "$S" '  if ! sh "$B/keys-home.sh" "$TREE" "$DEV" >&2; then')
  fk=$(line "$S" '  f=$(compgen -G "$K/*.pk8" || true)')
  pr=$(line "$S" '  check_keys "${DEVS[$i]}"')
  ks=$(grep -n "^printf 'passphrase for the release keys" "$S" | head -1 | cut -d: -f1)
  chk "P2 sign-release.sh's check_keys runs keys-home.sh first, in the preflight, before the prompt" \
    '[ -n "$ck" ] && [ -n "$kc" ] && [ -n "$fk" ] && [ -n "$pr" ] && [ -n "$ks" ] && [ "$ck" -lt "$kc" ] && [ "$kc" -lt "$fk" ] && [ "$pr" -lt "$ks" ]'
  kh=$(grep -c '^HOME_DIR="${NOWHERE_KEYS_HOME:-/mnt/build/keys/endospore}"$' "$SUT")
  gk=$(grep -c '^KH="${NOWHERE_KEYS_HOME:-/mnt/build/keys/endospore}"$' "$G")
  chk "P3 keys-home.sh and gen-keys.sh name the same default keys home" '[ "$kh" = 1 ] && [ "$gk" = 1 ]'
}

plain() {
  local sh
  for sh in $SHELLS; do cases "$sh"; done
  pins
  [ "$X" = 0 ]
}

if [ "$MUTATE" = 0 ]; then
  echo "test-keys-home.sh (shells:$SHELLS)"
  plain; rc=$?
  echo "$P passed, $X failed"
  [ "$rc" = 0 ] && echo "PASS" || echo "FAILED"
  exit "$rc"
fi

# ---- mutants ----
# mutant <name> <want-case-prefixes> <sed-script>: the copy must change, and the suite must FAIL each named case
FAILS=0
mutant() {
  local name="$1" want="$2" script="$3" m="$W/mut-$1.sh" out c
  sed "$script" "$SUT" > "$m"
  if cmp -s "$m" "$SUT"; then echo "  FAIL  $name did not apply"; FAILS=$((FAILS+1)); return; fi
  out=$(bash "$0" "$m" 2>&1) || true
  for c in $want; do
    if grep -q -- "^  FAIL  $c " <<<"$out"; then echo "  ok    $name convicted by $c"
    else echo "  FAIL  $name NOT convicted by $c"; FAILS=$((FAILS+1)); fi
  done
}

echo "test-keys-home.sh --mutate (shells:$SHELLS)"
out=$(plain); rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || { echo "FAILED (plain run)"; exit 1; }

mutant K1 "k6"  's/^  if \[ -z "\$want" \] || \[ "\$got" != "\$want" \]; then$/  if false; then/'
mutant K2 "k4"  's/^  if \[ ! -d "\$H" \]; then$/  if false; then/'
mutant K3 "k10 k11" 's/^      if ! cmp -s "\$f" "\$K\/\$DEV\/\$b"; then$/      if false; then/'
mutant K4 "k8"  '/^\[ -d "\$K\/\$DEV" \] || {/d'
mutant K5 "k13" '/^case "\$HOME_DIR" in \/\*)/d'
mutant K6 "k9"  's/^    for f in "\$H"\/\*\.x509\.pem "\$H\/avb_pkmd\.bin" "\$H\/id_ed25519\.pub"; do$/    for f in "$H"\/*.x509.pem "$H\/avb_pkmd.bin" "$H\/id_ed25519.pub" "$H"\/*.pk8 "$H\/avb.pem"; do/'
mutant K7 "k7"  '/neither a directory nor a link -- refusing/{n;s/exit 3/exit 0/}'
mutant K8 "k12" 's/^    if \[ ! -d "\$K\/\$DEV" \]; then$/    if false; then/'
mutant K9 "k1"  '/WARNING: the keys home has no/d'
mutant K10 "k17" 's/^    for f in "\$H"\/\*\.x509\.pem "\$H\/avb_pkmd\.bin" "\$H\/id_ed25519\.pub"; do$/    for f in "$H"\/*.x509.pem "$H\/avb_pkmd.bin"; do/'
mutant K11 "k18" 's/^  if \[ -d "\$H" \]; then$/  if [ -d "$HOME_DIR" ]; then/'
mutant K12 "k19" 's/^    if \[ "\$n" -eq 0 \]; then$/    if false; then/'
mutant K13 "k20 k21" 's/^  if { \[ -e "\$x" \] || \[ -L "\$x" \]; } && in_tree "\$x"; then$/  if false; then/'

if [ "$FAILS" = 0 ]; then echo "PASS (all mutants convicted)"; else echo "FAILED ($FAILS)"; exit 1; fi
