#!/usr/bin/env bash
# test-publish-fdroid-index.sh [--mutate] -- publish-fdroid-index.sh refuses an index key that is not the agent's
# indexPubKey BEFORE it trims, signs or uploads anything, and refuses an R2_DEST without rclone (NWP-20261103-08).
#
# WHY. Step 3 verified the signatures against the key's OWN public half and step 5 uploaded with nothing comparing
# it to index.go's indexPubKey (only the Endospore stage checked the baked set), so a cron run with the wrong key
# published a set every phone rejects on read and printed DONE. And R2_DEST set with rclone missing printed
# SKIPPED, exit 0: the operator asked for an upload, none happened, the run looked green.
#
# Each case copies the script under test beside STUB trim/icon/sign scripts and runs it with a PATH holding only the
# tools it needs (never the host's rclone). Python and sha256sum are required: the suite FAILS without them.
#
#   bash test-publish-fdroid-index.sh [<publish-script>]   # the cases (default: the real script)
#   bash test-publish-fdroid-index.sh --mutate             # ... plus broken copies that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SUT=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUT="$a" ;; esac; done
HERE=$(cd "$(dirname "$0")" && pwd)
SUT="${SUT:-$HERE/publish-fdroid-index.sh}"
[ -f "$SUT" ] || { echo "no script under test: $SUT" >&2; exit 2; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

command -v python3 >/dev/null && command -v sha256sum >/dev/null \
  || { echo "FAIL python3 and sha256sum are required" >&2; exit 1; }
python3 --version; sha256sum --version | sed -n 1p

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf "  ok    %s\n" "$1"; }
no(){ FAIL=$((FAIL+1)); printf "  FAIL  %s\n" "$1"; }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1 -- got [$2] want [$3]"; }
has(){ case "$2" in *"$3"*) ok "$1" ;; *) no "$1 -- [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1 -- [$3] found in: $2" ;; *) ok "$1" ;; esac; }

AGENT_PUB="AGENTPUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
OTHER_PUB="OTHERPUBKEYBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="

# a PATH dir of symlinks to exactly the tools the script needs
BIN="$W/bin"; mkdir -p "$BIN"
for t in bash python3 sha256sum cut sed mkdir cat ls awk dirname printf grep; do
  p=$(command -v "$t") || { echo "FAIL host has no $t" >&2; exit 1; }
  ln -s "$p" "$BIN/$t"
done
RBIN="$W/rbin"; mkdir -p "$RBIN"
for t in "$BIN"/*; do ln -s "$(readlink "$t")" "$RBIN/$(basename "$t")"; done
cat > "$RBIN/rclone" <<'S'
#!/bin/bash
echo "rclone $*" >> "$RCLONE_LOG"
S
chmod +x "$RBIN/rclone"

# newtree <script> -> a scratch tree with the script and its stubs; prints its root
newtree(){
  local t d; t=$(mktemp -d -p "$W"); d="$t/core/vendor-common/prebuilts"
  mkdir -p "$d" "$t/core/agent"
  cp "$1" "$d/publish-fdroid-index.sh"
  cat > "$d/trim-fdroid-index.py" <<'S'
import sys, os
open(sys.argv[1], "w").write("index\n")
open(os.environ["CALLS"], "a").write("trim\n")
S
  cat > "$d/build-icon-pack.py" <<'S'
import sys, os
open(sys.argv[2], "w").write("icons\n")
open(os.environ["CALLS"], "a").write("icons\n")
S
  cat > "$d/sign-catalog.sh" <<'S'
#!/bin/bash
case "$1" in
  pubkey) echo "$STUB_PUB" ;;
  sign) echo "signed $2"; echo sig > "$2.sig" ;;
  verify) exit 0 ;;
esac
S
  printf 'package main\n\nvar indexPubKey = "%s"\n' "$AGENT_PUB" > "$t/core/agent/index.go"
  printf '%s' "$t"
}

# run <tree> <pubkey> <path-dir> [VAR=val ...] -> RC, OUTP (stdout+stderr), CALLS_F, RCLONE_F, OUT
run(){
  local t="$1" pub="$2" pd="$3"; shift 3
  OUT="$t/out"; CALLS_F="$t/calls"; RCLONE_F="$t/rclone.log"; : > "$CALLS_F"; : > "$RCLONE_F"
  echo k > "$t/key"
  OUTP=$(env -i PATH="$pd" HOME="$t" CALLS="$CALLS_F" RCLONE_LOG="$RCLONE_F" STUB_PUB="$pub" \
      INDEX_SIGNING_KEY="$t/key" "$@" \
      bash "$t/core/vendor-common/prebuilts/publish-fdroid-index.sh" "$OUT" 2>&1); RC=$?
}

cases(){
  local script="$1" t n c r
  # p1: the right key, no R2_DEST
  t=$(newtree "$script"); run "$t" "$AGENT_PUB" "$BIN"
  is "p1 exit 0" "$RC" 0
  has "p1 lock pubkey" "$(cat "$OUT/fdroid-index.lock" 2>/dev/null)" "# index-pubkey: $AGENT_PUB"
  has "p1 SKIPPED" "$OUTP" "SKIPPED"
  is "p1 no rclone call" "$(cat "$RCLONE_F")" ""

  # p2: a key that is not indexPubKey
  t=$(newtree "$script"); run "$t" "$OTHER_PUB" "$RBIN" R2_DEST=r:b/f
  is "p2 exit 1" "$RC" 1
  has "p2 FATAL" "$OUTP" "FATAL the index key's public half is not index.go's indexPubKey -- nothing trimmed, signed or uploaded"
  is "p2 nothing ran" "$(cat "$CALLS_F")" ""
  [ ! -e "$OUT/fdroid-index.lock" ] && ok "p2 no lock" || no "p2 no lock -- lock written"
  is "p2 no rclone call" "$(cat "$RCLONE_F")" ""

  # p3: index.go missing, and with two keys
  t=$(newtree "$script"); rm "$t/core/agent/index.go"; run "$t" "$AGENT_PUB" "$BIN"
  is "p3 missing exit 1" "$RC" 1
  has "p3 missing FATAL" "$OUTP" "FATAL cannot read indexPubKey from"
  is "p3 missing nothing trimmed" "$(cat "$CALLS_F")" ""
  t=$(newtree "$script"); printf 'var indexPubKey = "%s"\n' "$OTHER_PUB" >> "$t/core/agent/index.go"; run "$t" "$AGENT_PUB" "$BIN"
  is "p3 two keys exit 1" "$RC" 1
  has "p3 two keys FATAL" "$OUTP" "FATAL cannot read indexPubKey from"
  is "p3 two keys nothing trimmed" "$(cat "$CALLS_F")" ""

  # p4: R2_DEST set, no rclone
  t=$(newtree "$script"); run "$t" "$AGENT_PUB" "$BIN" R2_DEST=r:b/f
  is "p4 exit 1" "$RC" 1
  has "p4 FATAL" "$OUTP" "FATAL R2_DEST is set but rclone is not installed -- nothing uploaded"
  hasnt "p4 not DONE" "$OUTP" "DONE"

  # p5: R2_DEST set, rclone present
  t=$(newtree "$script"); run "$t" "$AGENT_PUB" "$RBIN" R2_DEST=r:b/f
  is "p5 exit 0" "$RC" 0
  n=$(grep -c ' copyto ' "$RCLONE_F"); is "p5 four copyto calls" "$n" 4
  c=$(awk '{n=split($3,a,"/"); printf "%s ", a[n]}' "$RCLONE_F"); is "p5 sources in order" "$c" "index.json index.json.sig icons.pack icons.pack.sig "
  c=$(awk '{print $4}' "$RCLONE_F" | sed 's|.*/||' | cut -c1-40 | awk '{printf "%s ", $0}'); is "p5 destinations in order" "$c" "index.json index.json.sig icons.pack icons.pack.sig "

  # p6: INDEX_GO elsewhere, the default path absent
  t=$(newtree "$script"); mkdir -p "$t/elsewhere"; mv "$t/core/agent/index.go" "$t/elsewhere/index.go"
  run "$t" "$AGENT_PUB" "$BIN" INDEX_GO="$t/elsewhere/index.go"
  is "p6 exit 0" "$RC" 0
}

echo "== cases against $SUT"
cases "$SUT"

if [ "$MUTATE" = yes ]; then
  # mutant <name> <python-expr-on-s> <expected-failing-label-prefix>
  mutant(){
    local name="$1" edit="$2" want="$3" m res
    m="$W/mutant-$name.sh"
    SRC="$SUT" DST="$m" python3 -I -c '
import os
s = open(os.environ["SRC"]).read()
o = s
'"$edit"'
if s == o:
    raise SystemExit(3)
open(os.environ["DST"], "w").write(s)' || { no "$name mutant did not apply"; return; }
    res=$(bash "$0" "$m" 2>&1 | grep '^  FAIL' || true)
    case "$res" in *"$want"*) ok "$name convicted by $want" ;; *) no "$name NOT convicted by $want -- got: $res" ;; esac
  }
  echo "== mutants"
  mutant F1 's = s.replace("if [ \"$PUB\" != \"$AGENT_PUB\" ]; then", "if false; then")' "p2 exit 1"
  mutant F2 'a = s.index("PUB=$(bash \"$HERE/sign-catalog.sh\" pubkey"); b = s.index("mkdir -p \"$OUT\"\n"); blk = s[a:b]; s = s[:a] + s[b:]; i = s.index("echo \"=== [5/5]"); s = s[:i] + blk + s[i:]' "p2 nothing ran"
  mutant F3 's = s.replace("\"\"|*$\x27\\n\x27*) echo \"FATAL cannot read indexPubKey from $INDEX_GO\" >&2; exit 1 ;;", "\"\"|*$\x27\\n\x27*) ;;")' "p3 missing FATAL"
  mutant F4 's = s.replace("if [ -n \"${R2_DEST:-}\" ]; then\n  command -v rclone >/dev/null || { echo \"FATAL R2_DEST is set but rclone is not installed -- nothing uploaded\" >&2; exit 1; }\n", "if [ -n \"${R2_DEST:-}\" ] && command -v rclone >/dev/null; then\n")' "p4 exit 1"
  mutant F5 's = s.replace("for f in index.json index.json.sig icons.pack icons.pack.sig; do\n    rclone", "for f in index.json index.json.sig icons.pack; do\n    rclone")' "p5 four copyto calls"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
