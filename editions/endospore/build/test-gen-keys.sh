#!/usr/bin/env bash
# test-gen-keys.sh [--mutate] [<gen-keys.sh>] -- exercise NWP-20261104-15's AVB-root guard in gen-keys.sh, and where it
# makes the keys when the host has a keys home (NWP-20261105-19).
#
# WHY THIS IS COMMITTED. gen-keys.sh mints a NEW AVB root whenever avb.pem is missing. Beside a device's
# existing keys that is the one mistake a relocked fleet cannot recover from: every handset rejects every later
# image and the fix is a web-installer reinstall of the whole fleet. The rule lived only in prose
# (docs/release-runbook.md section 10, build-device.sh's warning) and no suite ran the script.
#
# Each case builds a synthetic tree (stub make_key / avbtool / openssl / ssh-keygen, each logging its name to
# $W/calls) and runs the script from the tree root. make_key exits 1 like the real one, so outputs, not exit
# codes, are what the script checks. Every run sets NOWHERE_KEYS_HOME, never to the host's own home: to a path that does
# not exist for g1-g14 (a tree-local keys/, as on a host with no keys home), and to the case's own home for g15-g25.
#
#   bash test-gen-keys.sh              # the behaviour cases g1-g25 (g24 is skipped under root, with a line saying so)
#   bash test-gen-keys.sh --mutate     # ... plus mutants G1-G19 that must each CONVICT a named case (G18 skipped under root)
# A self-check runs first in both modes: it prints whether printf | grep -q under pipefail can die of SIGPIPE
# on this host, and asserts has() (the suite's substring test) finds a needle and rejects a missing one.
#
# Pure logic -- no build, no device, no network.
set -uo pipefail
# No check pipes into grep. Bash line-buffers its stdout, so `printf "%s" "$ERR"` does one write() per line.
# grep -q exits at its first match, the next write gets SIGPIPE (141), and pipefail makes the check false.
# That turned "g3 restore-from-backup line" red once on a loaded runner (NWP-20261114-19).

MUTATE=0
[ "${1:-}" = "--mutate" ] && { MUTATE=1; shift; }
SUT="${1:-$(dirname "$0")/gen-keys.sh}"
[ -f "$SUT" ] || { echo "no such script: $SUT"; exit 2; }
SUT=$(cd "$(dirname "$SUT")" && pwd)/$(basename "$SUT")

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PAIRS="releasekey platform shared media networkstack bluetooth sdk_sandbox gmscompat_lib nfc"

# mktree <name> -> prints the path of a fresh synthetic tree with the stubs in place
mktree() {
  local t="$W/$1"
  mkdir -p "$t/development/tools" "$t/external/avb" "$t/bin"
  cat > "$t/development/tools/make_key" <<'STUB'
#!/bin/sh
echo make_key >> "$CALLS"
echo "key-$1" > "$1.pk8"
echo "cert-$1" > "$1.x509.pem"
exit 1
STUB
  cat > "$t/external/avb/avbtool.py" <<'STUB'
#!/bin/sh
echo avbtool >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = --output ] && { echo "pkmd-of-$(cat avb.pem)" > "$2"; }; shift; done
exit 0
STUB
  cat > "$t/bin/openssl" <<'STUB'
#!/bin/sh
echo openssl >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = -out ] && { echo "root-$$-$(date +%s%N)" > "$2"; }; shift; done
exit 0
STUB
  cat > "$t/bin/ssh-keygen" <<'STUB'
#!/bin/sh
echo ssh-keygen >> "$CALLS"
while [ $# -gt 0 ]; do [ "$1" = -f ] && { echo ssh > "$2"; echo ssh.pub > "$2.pub"; }; shift; done
exit 0
STUB
  chmod +x "$t/development/tools/make_key" "$t/external/avb/avbtool.py" "$t/bin/openssl" "$t/bin/ssh-keygen"
  printf '%s\n' "$t"
}

# seed <tree> <what...>: pairs | pkmd | ed | pem | old
seed() {
  local t="$1" w k; shift
  mkdir -p "$t/keys/dev"
  for w in "$@"; do
    case "$w" in
      pairs) for k in $PAIRS; do echo "old-key-$k" > "$t/keys/dev/$k.pk8"; echo "old-cert-$k" > "$t/keys/dev/$k.x509.pem"; done ;;
      pkmd) echo old-pkmd > "$t/keys/dev/avb_pkmd.bin" ;;
      old) echo older-pkmd > "$t/keys/dev/avb_pkmd.bin.old" ;;
      ed) echo old-ed > "$t/keys/dev/id_ed25519"; echo old-ed.pub > "$t/keys/dev/id_ed25519.pub" ;;
      pem) echo old-root > "$t/keys/dev/avb.pem" ;;
    esac
  done
}

# snap <tree> -> names and sha256 of every file under keys/
snap() { (cd "$1" && find keys -type f 2>/dev/null | LC_ALL=C sort | xargs -r sha256sum); }

# snapd <dir> -> every file under <dir> with its sha256, and every link with its target (a keys/ link included)
snapd() {
  (cd "$1" && find . \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"; else printf 'F %s %s\n' "$f" "$(sha256sum < "$f" | cut -d' ' -f1)"; fi
  done)
}

# KHOME: the keys home a case gives the script; empty = a path that does not exist (no keys home)
KHOME=""
# run <tree> <args...> -> sets OUT, ERR, RC, CALLS_N (the calls file's lines, newline-joined)
run() {
  local t="$1"; shift
  : > "$W/calls"
  OUT=$(cd "$t" && CALLS="$W/calls" PATH="$t/bin:$PATH" NOWHERE_KEYS_HOME="${KHOME:-$W/no-keys-home}" bash "$SUT" "$@" 2>"$W/err"); RC=$?
  ERR=$(cat "$W/err")
  CALLS_N=$(cat "$W/calls")
}

count() { grep -c "^$1\$" <<<"$CALLS_N" || true; }

# has <haystack> <needle>: 0 if the fixed string <needle> is anywhere in <haystack>; no subprocess, no pipe
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# selfcheck: print whether the printf | grep -q hazard is real here (information only), then assert has()
selfcheck() {
  local pad big st
  printf -v pad '%2097152s' ''
  big="needle"$'\n'"$pad"
  ( set -o pipefail; printf '%s' "$big" | grep -q needle ); st=$?
  case "$st" in
    141) echo "  info  self-check: printf into grep -q under pipefail gave 141: the SIGPIPE hazard is real on this host" ;;
    0)   echo "  info  self-check: printf into grep -q under pipefail gave 0: no hazard seen on this host" ;;
    *)   echo "  info  self-check: printf into grep -q under pipefail gave $st: the writer saw EPIPE" ;;
  esac
  if has "$big" needle; then echo "  ok    self-check has() finds a needle in 2 MiB"
  else echo "  FAIL  self-check has() finds a needle in 2 MiB"; return 1; fi
  if has "abc" zzz; then echo "  FAIL  self-check has() rejects a missing needle"; return 1
  else echo "  ok    self-check has() rejects a missing needle"; fi
}

all_made_at() {   # <keys dir>: every key gen-keys.sh makes is there
  local d="$1" k
  for k in $PAIRS; do [ -f "$d/$k.pk8" ] && [ -f "$d/$k.x509.pem" ] || return 1; done
  [ -f "$d/avb.pem" ] && [ -f "$d/avb_pkmd.bin" ] && [ -f "$d/id_ed25519" ] && [ -f "$d/id_ed25519.pub" ]
}
all_made() { all_made_at "$1/keys/dev"; }

# cases <quiet> -> prints "FAIL gN" per failing case (and ok lines unless quiet); returns 0 if all pass
cases() {
  local quiet="$1" p=0 x=0 t b a
  ok()  { p=$((p+1)); [ -n "$quiet" ] || printf '  ok    %s\n' "$1"; }
  bad() { x=$((x+1)); printf '  FAIL  %s\n' "$1"; }
  chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
  refused() { # <case> <tree> <before>: exit 3, restore line, no avb.pem, no calls, nothing changed
    RT="$2"; RB="$3"
    chk "$1 exit 3" '[ "$RC" = 3 ]'
    chk "$1 restore-from-backup line" 'has "$ERR" "Restore avb.pem from the offline backup"'
    chk "$1 no avb.pem" '[ ! -e "$RT/keys/dev/avb.pem" ]'
    chk "$1 no tool run" '[ -z "$CALLS_N" ]'
    chk "$1 nothing changed" '[ "$(snap "$RT")" = "$RB" ]'
  }

  # g1 no keys/<dev>
  t=$(mktree g1); run "$t" dev
  chk "g1 exit 0" '[ "$RC" = 0 ]'
  chk "g1 everything made" 'all_made "$t"'
  chk "g1 calls" '[ "$(count make_key)" = 9 ] && [ "$(count openssl)" = 1 ] && [ "$(count avbtool)" = 1 ] && [ "$(count ssh-keygen)" = 1 ]'

  # g2 re-run of g1
  b=$(snap "$t"); run "$t" dev
  chk "g2 exit 0" '[ "$RC" = 0 ]'
  chk "g2 no tool run" '[ -z "$CALLS_N" ]'
  chk "g2 byte-identical" '[ "$(snap "$t")" = "$b" ]'

  # g3 pairs only, g4 pkmd only, g5 id_ed25519 only
  t=$(mktree g3); seed "$t" pairs; b=$(snap "$t"); run "$t" dev; refused g3 "$t" "$b"
  t=$(mktree g4); seed "$t" pkmd;  b=$(snap "$t"); run "$t" dev; refused g4 "$t" "$b"
  t=$(mktree g5); seed "$t" ed;    b=$(snap "$t"); run "$t" dev; refused g5 "$t" "$b"

  # g6 avb.pem only
  t=$(mktree g6); seed "$t" pem; run "$t" dev
  chk "g6 exit 0" '[ "$RC" = 0 ]'
  chk "g6 pkmd derived, rest made" 'all_made "$t" && [ "$(count avbtool)" = 1 ] && [ "$(count make_key)" = 9 ] && [ "$(count ssh-keygen)" = 1 ]'
  chk "g6 openssl never called" '[ "$(count openssl)" = 0 ]'
  chk "g6 avb.pem kept" '[ "$(cat "$t/keys/dev/avb.pem")" = old-root ]'

  # g7 a full set minus id_ed25519
  t=$(mktree g7); seed "$t" pairs pem pkmd; run "$t" dev
  chk "g7 exit 0" '[ "$RC" = 0 ]'
  chk "g7 only ssh-keygen called" '[ "$CALLS_N" = ssh-keygen ] && [ -f "$t/keys/dev/id_ed25519" ]'

  # g8 --new-avb-root over the pairs + pkmd, then again
  t=$(mktree g8); seed "$t" pairs pkmd; run "$t" dev --new-avb-root
  chk "g8 exit 0" '[ "$RC" = 0 ]'
  chk "g8 loud line" 'has "$OUT" "NEW AVB ROOT for dev: every relocked dev unit must reinstall through the web installer"'
  chk "g8 old half kept" '[ "$(cat "$t/keys/dev/avb_pkmd.bin.old" 2>/dev/null)" = old-pkmd ]'
  chk "g8 new root and public half" 'all_made "$t" && [ "$(cat "$t/keys/dev/avb_pkmd.bin")" != old-pkmd ]'
  b=$(snap "$t"); run "$t" dev --new-avb-root
  chk "g8 second run exit 2" '[ "$RC" = 2 ]'
  chk "g8 second run nothing changed" '[ "$(snap "$t")" = "$b" ] && [ -z "$CALLS_N" ]'
  chk "g8 second run says move avb.pem out by hand" 'has "$ERR" "move keys/dev/avb.pem out of keys/dev by hand first, then re-run with --new-avb-root"'

  # g9 an existing EMPTY keys/<dev>
  t=$(mktree g9); mkdir -p "$t/keys/dev"; run "$t" dev
  chk "g9 exit 0, all made" '[ "$RC" = 0 ] && all_made "$t"'
  chk "g9 calls" '[ "$(count make_key)" = 9 ] && [ "$(count openssl)" = 1 ]'

  # g10 an unknown second argument, and no device
  t=$(mktree g10); run "$t" dev --bogus
  chk "g10 exit 2, nothing created" '[ "$RC" = 2 ] && [ ! -e "$t/keys" ] && [ -z "$CALLS_N" ]'
  run "$t"
  chk "g10 no device: exit 2, nothing created" '[ "$RC" = 2 ] && [ ! -e "$t/keys" ]'

  # g12 invalid grammar: flag as the device, repeated flag, extra argument -- exit 2, nothing created
  t=$(mktree g12); run "$t" --new-avb-root
  chk "g12 flag as device: exit 2, nothing created" '[ "$RC" = 2 ] && [ ! -e "$t/keys" ] && [ -z "$CALLS_N" ]'
  run "$t" dev --new-avb-root --new-avb-root
  chk "g12 repeated flag: exit 2, nothing created" '[ "$RC" = 2 ] && [ ! -e "$t/keys" ] && [ -z "$CALLS_N" ]'
  run "$t" dev --new-avb-root extra
  chk "g12 extra argument: exit 2, nothing created" '[ "$RC" = 2 ] && [ ! -e "$t/keys" ] && [ -z "$CALLS_N" ]'

  # g13 --new-avb-root with avb_pkmd.bin.old but no current avb_pkmd.bin
  t=$(mktree g13); seed "$t" pairs old; b=$(snap "$t"); run "$t" dev --new-avb-root
  chk "g13 exit 3, nothing changed" '[ "$RC" = 3 ] && [ "$(snap "$t")" = "$b" ] && [ -z "$CALLS_N" ]'

  # g14 the move to avb_pkmd.bin.old fails: exit 3, no new root, old half still in place
  t=$(mktree g14); seed "$t" pairs pkmd; printf '#!/bin/sh\nexit 1\n' > "$t/bin/mv"; chmod +x "$t/bin/mv"
  b=$(snap "$t"); run "$t" dev --new-avb-root
  chk "g14 exit 3, no avb.pem, nothing changed" '[ "$RC" = 3 ] && [ ! -e "$t/keys/dev/avb.pem" ] && [ "$(snap "$t")" = "$b" ] && [ -z "$CALLS_N" ]'

  # g11 --new-avb-root with avb_pkmd.bin.old already there
  t=$(mktree g11); seed "$t" pairs pkmd old; b=$(snap "$t"); run "$t" dev --new-avb-root
  chk "g11 exit 3" '[ "$RC" = 3 ]'
  chk "g11 nothing changed" '[ "$(snap "$t")" = "$b" ] && [ -z "$CALLS_N" ]'

  # ---- a keys home (NWP-20261105-19): each case below names its own home in KHOME
  # g15 an empty home and a tree with no keys/: everything is made IN THE HOME, and the tree is left without keys/
  t=$(mktree g15); KHOME="$W/home15"; mkdir -p "$KHOME"; run "$t" dev
  chk "g15 exit 0" '[ "$RC" = 0 ]'
  chk "g15 made in the home" 'all_made_at "$KHOME/dev"'
  chk "g15 the tree still has no keys/" '[ ! -e "$t/keys" ] && [ ! -L "$t/keys" ]'
  chk "g15 calls" '[ "$(count make_key)" = 9 ] && [ "$(count openssl)" = 1 ] && [ "$(count avbtool)" = 1 ] && [ "$(count ssh-keygen)" = 1 ]'
  # g22 a re-run of g15: nothing runs and the home is byte-identical
  b=$(snapd "$KHOME"); run "$t" dev
  chk "g22 re-run: exit 0, no tool run, the home unchanged" '[ "$RC" = 0 ] && [ -z "$CALLS_N" ] && [ "$(snapd "$KHOME")" = "$b" ]'

  # g16 keys/ is a link to the home, which holds dev's avb.pem only: the rest is made in the home, by the tree's own
  # tools reached from the tree root (from the home's dev, ../.. is not the tree)
  t=$(mktree g16); KHOME="$W/home16"; mkdir -p "$KHOME/dev"; echo old-root > "$KHOME/dev/avb.pem"; ln -s "$KHOME" "$t/keys"; run "$t" dev
  chk "g16 exit 0" '[ "$RC" = 0 ]'
  chk "g16 made in the home, avb.pem kept" 'all_made_at "$KHOME/dev" && [ "$(cat "$KHOME/dev/avb.pem")" = old-root ]'
  chk "g16 make_key and avbtool ran, openssl did not" '[ "$(count make_key)" = 9 ] && [ "$(count avbtool)" = 1 ] && [ "$(count openssl)" = 0 ]'
  chk "g16 keys/ is still the link" '[ -L "$t/keys" ] && [ "$(readlink "$t/keys")" = "$KHOME" ]'

  # g17 a home, and a tree with its own keys/ directory: refused, nothing created anywhere, no tool run
  t=$(mktree g17); KHOME="$W/home17"; mkdir -p "$KHOME"; seed "$t" pairs pkmd ed pem; b=$(snapd "$t"); hb=$(snapd "$KHOME"); run "$t" dev
  chk "g17 exit 3" '[ "$RC" = 3 ]'
  chk "g17 says keys are made only in the home" 'has "$ERR" "and keys are made only there"'
  chk "g17 nothing changed, no tool run" '[ "$(snapd "$t")" = "$b" ] && [ "$(snapd "$KHOME")" = "$hb" ] && [ -z "$CALLS_N" ]'

  # g18 a home, and a tree whose keys/ links elsewhere: refused, nothing created, no tool run
  t=$(mktree g18); KHOME="$W/home18"; mkdir -p "$KHOME" "$W/elsewhere18"; ln -s "$W/elsewhere18" "$t/keys"
  b=$(snapd "$t"); hb=$(snapd "$KHOME"); run "$t" dev
  chk "g18 exit 3, nothing created, no tool run" '[ "$RC" = 3 ] && [ "$(snapd "$t")" = "$b" ] && [ "$(snapd "$KHOME")" = "$hb" ] && [ -z "$(ls -A "$W/elsewhere18")" ] && [ -z "$CALLS_N" ]'

  # g19 the home holds dev's other keys but no avb.pem: the missing-root refusal, against the home
  t=$(mktree g19); KHOME="$W/home19"; mkdir -p "$KHOME/dev"
  for k in $PAIRS; do echo "old-key-$k" > "$KHOME/dev/$k.pk8"; echo "old-cert-$k" > "$KHOME/dev/$k.x509.pem"; done
  hb=$(snapd "$KHOME"); run "$t" dev
  chk "g19 exit 3, the restore line" '[ "$RC" = 3 ] && has "$ERR" "Restore avb.pem from the offline backup"'
  chk "g19 no avb.pem, nothing changed, no tool run" '[ ! -e "$KHOME/dev/avb.pem" ] && [ "$(snapd "$KHOME")" = "$hb" ] && [ -z "$CALLS_N" ] && [ ! -e "$t/keys" ]'

  # g20 a relative NOWHERE_KEYS_HOME, even one that exists from the tree root: usage, nothing created
  t=$(mktree g20); KHOME="rel-home"; mkdir -p "$t/rel-home"; run "$t" dev
  chk "g20 exit 2, nothing created" '[ "$RC" = 2 ] && [ ! -e "$t/keys" ] && [ -z "$(ls -A "$t/rel-home")" ] && [ -z "$CALLS_N" ]'

  # g21 the home path is a file: refused, nothing created
  t=$(mktree g21); KHOME="$W/home21"; echo not-a-dir > "$KHOME"; run "$t" dev
  chk "g21 exit 3, nothing created" '[ "$RC" = 3 ] && [ ! -e "$t/keys" ] && [ "$(cat "$KHOME")" = not-a-dir ] && [ -z "$CALLS_N" ]'

  # g23 the home's dev is a FILE, so the keys dir cannot be made or entered: exit 1, and no key is made in the tree root
  t=$(mktree g23); KHOME="$W/home23"; mkdir -p "$KHOME"; echo a-file > "$KHOME/dev"; b=$(snapd "$t"); run "$t" dev
  chk "g23 exit 1, the tree root untouched, no tool run" '[ "$RC" = 1 ] && [ "$(snapd "$t")" = "$b" ] && [ -z "$CALLS_N" ]'

  # g24 the home's dev EXISTS but cannot be entered (mode 000): mkdir -p succeeds and cd fails, so only the cd guard
  # keeps every key out of the tree root. Root ignores the mode, so the case is skipped there, and says so.
  if [ "$(id -u)" = 0 ]; then
    printf '  info  g24 skipped: root ignores the directory mode the case relies on\n'
  else
    t=$(mktree g24); KHOME="$W/home24"; mkdir -p "$KHOME/dev"; chmod 000 "$KHOME/dev"; b=$(snapd "$t"); run "$t" dev
    chmod 700 "$KHOME/dev"
    chk "g24 the dir cannot be entered: exit 1, the tree root untouched, no tool run" '[ "$RC" = 1 ] && [ "$(snapd "$t")" = "$b" ] && [ -z "$CALLS_N" ]'
  fi

  # g25 the home path is a dangling link: refused as not a directory, nothing created
  t=$(mktree g25); KHOME="$W/home25"; ln -s "$W/gone25" "$KHOME"; run "$t" dev
  chk "g25 a dangling-link home: exit 3, nothing created" '[ "$RC" = 3 ] && [ ! -e "$t/keys" ] && [ -z "$CALLS_N" ]'
  KHOME=""

  [ "$x" = 0 ]
}

selfcheck || { echo "FAILED (self-check)"; exit 1; }

if [ "$MUTATE" = 0 ]; then
  out=$(cases ""); rc=$?
  printf '%s\n' "$out"
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
  out=$(SUT="$m" bash "$0" "$m" 2>&1) || true
  for c in $want; do
    if grep -q -- "^  FAIL  $c " <<<"$out"; then echo "  ok    $name convicted by $c"
    else echo "  FAIL  $name NOT convicted by $c"; FAILS=$((FAILS+1)); fi
  done
}

out=$(cases ""); rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || { echo "FAILED (plain run)"; exit 1; }

mutant G1 "g3"     '/^if \[ -d "\$KD" \] && \[ ! -f "\$KD\/avb.pem" \]; then$/s/.*/if false; then/'
mutant G2 "g4"     's/ "\$KD\/avb_pkmd.bin" "\$KD\/id_ed25519"; do/ "$KD\/id_ed25519"; do/'
mutant G3 "g5"     's/ "\$KD\/id_ed25519"; do/; do/'
mutant G4 "g8"     's/if \[ "\$NEW_ROOT" = 0 \]; then/if true; then/'
mutant G5 "g3"     '/REFUSING/,/exit 3/s/exit 3/exit 0/'
mutant G6 "g8"     '/mv "\$KD\/avb_pkmd.bin" /d'
mutant G7 "g2 g7"  's/^if \[ -d "\$KD" \] && \[ ! -f "\$KD\/avb.pem" \]; then$/if [ -d "$KD" ]; then/'
mutant G8 "g11 g13" '/avb_pkmd.bin.old" \]; then$/,/fi$/{/exit 3/d}'
mutant G9 "g14"    's/ || { echo "gen-keys.sh: could not move.*$//'
mutant G10 "g12"   's/^DEV="\$1"$/DEV="${1:-}"/;s/^case "\$DEV" in ""|-\*)/case "$DEV" in "")/'
mutant G11 "g3 g4 g5" '/^ *echo "  Restore avb.pem from the offline backup/s/Restore avb.pem from the offline backup/Fetch avb.pem from the offline copy/'
# NWP-20261105-19, the keys home
mutant G12 "g15"   's/^if \[ -e "\$KH" \] || \[ -L "\$KH" \]; then$/if false; then/'
mutant G13 "g17"   's/^    if \[ "\$(readlink -f keys 2>\/dev\/null)" != "\$(readlink -f "\$KH")" \]; then$/    if false; then/'
mutant G14 "g15"   '/^  KD="\$KH\/\$DEV"$/d'
mutant G15 "g20"   '/^case "\$KH" in /d'
mutant G16 "g21"   's/^  if \[ ! -d "\$KH" \]; then$/  if false; then/'
mutant G17 "g23"   's/^mkdir -p "\$KD" || .*$/mkdir -p "$KD"/;s/^cd "\$KD" || .*$/cd "$KD"/'
if [ "$(id -u)" = 0 ]; then
  echo "  info  G18 skipped: its case g24 does not run under root"
else
  mutant G18 "g24" 's/^cd "\$KD" || .*$/cd "$KD"/'
fi
mutant G19 "g25"   's/^if \[ -e "\$KH" \] || \[ -L "\$KH" \]; then$/if [ -e "$KH" ]; then/'

if [ "$FAILS" = 0 ]; then echo "PASS (all mutants convicted)"; else echo "FAILED ($FAILS)"; exit 1; fi
