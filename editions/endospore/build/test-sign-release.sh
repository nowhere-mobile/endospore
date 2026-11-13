#!/usr/bin/env bash
# test-sign-release.sh [--mutate] -- one signing sitting signs N devices with one prompt (NWP-20261122-01).
#
# Runs COPIES of sign-release.sh and sitting-guard.sh in a scratch world: a git repo holding them beside copies of the
# real verified-commit-guard.sh, ring-for-build.sh, ring-record.tsv, assert-baked-ring.sh, keys-home.sh and rings/*.conf
# (NOWHERE_KEYS_HOME is the world's own keyshome/, never the host's), plus recording
# stubs of make-web-package.sh, ota-field-guard.sh and check-patch-markers.py; and a tree holding stub build/envsetup.sh,
# script/finalize.sh, script/decrypt-keys, script/generate-release.sh, fixture keys and target-files zips (python3
# zipfile). Stub openssl, tmux and ps come first on PATH. The ps stub prints ONLY a fabricated table: its own row, its
# caller's real ancestor chain and the rows a case plants, never the runner's other processes. The guard cases run under
# every shell found (bash, sh, dash, mksh). No real key, no real passphrase.
#
#   bash test-sign-release.sh             # the cases
#   bash test-sign-release.sh --mutate    # ... plus mutants, each CONVICTED by its own signature case and evidence
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
for t in git unzip python3; do command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required" >&2; exit 1; }; done
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SIGN="$HERE/sign-release.sh"; GUARD="$HERE/sitting-guard.sh"
for f in "$SIGN" "$GUARD"; do [ -s "$f" ] || { echo "FAIL: $f does not exist or is empty" >&2; exit 1; }; done

PASS=0; FAIL=0; RC=0; PFRC=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
SHELLS=""
for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done

BN=2026112201
FXPW='fixture-pass-7Q'
PROMPT='passphrase for the release keys'
TERMLINE='sign-release: TERM: signing child ended, key dirs swept'
BDT=$(( $(date -u -d '2026-11-22 00:00:00' +%s) + 1 ))

# ---- the stubs --------------------------------------------------------------------------------------------------------
# pwenv: "yes" when the fixture passphrase is anywhere in the caller's environment. FX_PWFILE names a file, so the
# passphrase itself never reaches a stub through the environment unless the wrapper leaks it.
PWENV='pwenv() { e=$(env); p=$(cat "$FX_PWFILE"); case "$e" in *"$p"*) echo yes ;; *) echo no ;; esac; }
pwset() { if [ "${password+x}" = x ]; then echo yes; else echo no; fi; }'

write_stubs() {   # <X>
  local X="$1" RB="$1/repo/editions/endospore/build"
  mkdir -p "$X/bin" "$X/tree/build" "$X/tree/script" "$X/shm"
  cat > "$RB/make-web-package.sh" <<EOF
#!/usr/bin/env bash
$PWENV
echo "mwp \$2 \$3 pw-env=\$(pwenv) password-set=\$(pwset) rel=\$1" >> "\$FX_LOG"
exit 0
EOF
  cat > "$RB/ota-field-guard.sh" <<'EOF'
#!/usr/bin/env bash
echo "ofg $1 $2" >> "$FX_LOG"
[ "$1" = "${FX_OFG_FAIL:-}" ] && { echo "ota-field-guard: stamp $2 is not above the field" >&2; exit 1; }
exit 0
EOF
  cat > "$RB/check-patch-markers.py" <<'EOF'
#!/usr/bin/env python3
import os, sys
z = sys.argv[sys.argv.index("--zip") + 1]
open(os.environ["FX_LOG"], "a").write("cpm %s\n" % z)
f = os.environ.get("FX_CPM_FAIL", "")
sys.exit(1 if f and f in z else 0)
EOF
  : > "$RB/patch-markers.tsv"
  cat > "$X/tree/build/envsetup.sh" <<'EOF'
# Mirrors the real resolution order: an exported value wins, else the out dir's pinned file.
export BUILD_DATETIME=${BUILD_DATETIME:-$(cat $OUT_DIR/build_date.txt 2>/dev/null || date -u +%s)}
export BUILD_NUMBER=${BUILD_NUMBER:-$(cat $OUT_DIR/soong/build_number.txt 2>/dev/null || echo 1999010100)}
case "$OUT_DIR" in *"${FX_ENVSETUP_BAD:-@none@}"*) export BUILD_NUMBER=1999010100 ;; esac
echo "envsetup out=$OUT_DIR" >> "$FX_LOG"
lunch() { echo "lunch $1" >> "$FX_LOG"; }
get_build_var() { echo x; }
EOF
  cat > "$X/tree/script/finalize.sh" <<EOF
#!/usr/bin/env bash
$PWENV
echo "fin pw-env=\$(pwenv) password-set=\$(pwset) out=\$OUT_DIR" >> "\$FX_LOG"
EOF
  printf '#!/bin/bash\n# stub\nif [[ ! -v password ]]; then\n  read -rsp "Enter key passphrase: " password\nfi\n' > "$X/tree/script/decrypt-keys"
  cat > "$X/tree/script/generate-release.sh" <<'EOF'
#!/usr/bin/env bash
# stub of script/generate-release.sh; the real one decrypts into /dev/shm/release_keys.XXXXXXXXXX
DEV=$1; BN=$2
pwset=no; [ "${password+x}" = x ] && pwset=yes
pwok=no; [ "${password:-}" = "$(cat "$FX_PWFILE")" ] && pwok=yes
stale=$(find "$SIGN_SHM_DIR" -mindepth 1 -maxdepth 1 -name 'release_keys.*' | wc -l)
echo "gen $DEV $BN password-set=$pwset password-ok=$pwok out=$OUT_DIR bdt=$BUILD_DATETIME gen-start-stale=$stale" >> "$FX_LOG"
K=$(mktemp -d "$SIGN_SHM_DIR/release_keys.XXXXXXXX") || exit 1
R="releases/$BN/release-$DEV-$BN"; mkdir -p "$R"
printf '{"device":"%s"}\n' "$DEV" > "$R/$DEV-manifest-$BN.json"
[ "$DEV" = "${FX_GEN_FAIL:-}" ] && exit 1
if [ "$DEV" = "${FX_GEN_HOLD:-}" ]; then
  echo $$ > "$FX_HOLD_PID"; touch "$FX_READY"
  sleep 60 & echo $! > "$FX_SLEEP_PID"; wait
  exit 1
fi
rm -rf "$K"
EOF
  cat > "$X/bin/openssl" <<'EOF'
#!/usr/bin/env bash
sub=$1; k=""; prev=""
for a in "$@"; do [ "$prev" = -in ] && k=$a; prev=$a; done
case "$sub" in pkcs8 | pkey) ;; *) exit 0 ;; esac
set=no; [ "${password+x}" = x ] && set=yes
echo "ossl $k password-set=$set" >> "$FX_LOG"
want=$(sed -n 's/^pw=//p' "$k" | head -1)
[ -n "${password:-}" ] && [ "$want" = "$password" ]
EOF
  cat > "$X/bin/tmux" <<'EOF'
#!/bin/sh
[ "$1" = list-clients ] || exit 0
[ -f "${FX_TMUX_CLIENTS:-/nonexistent}" ] && cat "$FX_TMUX_CLIENTS"
exit 0
EOF
  cat > "$X/bin/ps" <<'EOF'
#!/usr/bin/env python3
# A fabricated table: this process's own row, its caller's real ancestor chain, and the rows a case plants.
import os, sys
if os.environ.get("FX_PS_FAIL") == "1":
    sys.exit(1)
mode = "u" if "-u" in sys.argv else "e"
log = os.environ.get("FX_PS_LOG")
if log:
    open(log, "a").write("%s %d\n" % (mode, os.getpid()))
rows = [(os.getpid(), os.getppid(), "ps")]
p = os.getppid()
while p > 0:
    try:
        s = open("/proc/%d/stat" % p).read()
    except OSError:
        break
    comm = s[s.index("(") + 1:s.rindex(")")]
    pp = int(s[s.rindex(")") + 2:].split()[1])
    rows.append((p, pp, comm))
    p = pp
plant = os.environ.get("FX_PS_PLANT", "")
if plant and os.path.exists(plant):
    for line in open(plant):
        f = line.split(None, 2)
        if len(f) == 3:
            rows.append((int(f[0]), int(f[1]), f[2].rstrip("\n")))
for pid, ppid, comm in rows:
    if mode == "u":
        print("%7d %7d %s" % (pid, ppid, comm))
    else:
        print("%7d %7d" % (pid, ppid))
EOF
  chmod +x "$RB"/*.sh "$RB/check-patch-markers.py" "$X/tree/script/"* "$X/bin/"*
}

mkzip() {   # <X> <dev> [key=value ...]: bn= type= osref= commit= ring= (ring "-" bakes no conf)
  local X="$1" DEV="$2"; shift 2
  local Z="$X/tree/out-$DEV/target/product/$DEV/obj/PACKAGING/target_files_intermediates/$DEV-target_files.zip"
  local RING; RING=$(sh "$X/repo/editions/endospore/build/ring-for-build.sh" "$DEV" release)
  mkdir -p "$(dirname "$Z")" "$X/tree/out-$DEV/soong"
  echo 1999010100 > "$X/tree/out-$DEV/soong/build_number.txt"; echo 1 > "$X/tree/out-$DEV/build_date.txt"
  python3 -I - "$Z" "$DEV" "$BN" "$(git -C "$X/repo" rev-parse HEAD)" "$RING" "$X/repo/core/vendor-common/etc/rings" "$@" <<'PY'
import sys, zipfile
z, dev, bn, commit, ring, rings = sys.argv[1:7]
o = dict(a.split("=", 1) for a in sys.argv[7:])
bn = o.get("bn", bn); ring = o.get("ring", ring)
with zipfile.ZipFile(z, "w") as f:
    f.writestr("VENDOR/build.prop", "ro.vendor.build.fingerprint=google/%s/%s:15/AP4A/%s:user/release-keys\n" % (dev, dev, bn))
    f.writestr("SYSTEM/build.prop", "ro.build.type=%s\n" % o.get("type", "user"))
    f.writestr("SYSTEM/etc/nowhere/os-ref", o.get("osref", "os-" + dev) + "\n")
    f.writestr("SYSTEM/etc/nowhere/source-commit", o.get("commit", commit) + "\n")
    if ring and ring != "-":
        f.writestr("SYSTEM/etc/nowhere/nowhere.conf", open("%s/%s.conf" % (rings, ring)).read())
PY
}

mkkeys() {  # <X> <dev>
  local K="$1/tree/keys/$2"
  mkdir -p "$K"
  printf 'pw=%s\n' "$FXPW" > "$K/releasekey.pk8"; printf 'pw=%s\n' "$FXPW" > "$K/platform.pk8"
  printf -- '-----BEGIN ENCRYPTED PRIVATE KEY-----\npw=%s\n' "$FXPW" > "$K/avb.pem"
  : > "$K/avb_pkmd.bin"; : > "$K/id_ed25519"
}

# world <sign-src> <guard-src> <dev>...: a fresh fixture; prints its dir.
world() {
  local S="$1" G="$2" X RB d; shift 2
  X=$(mktemp -d -p "$W" world.XXXXXX) || return 1
  RB="$X/repo/editions/endospore/build"
  mkdir -p "$RB" "$X/repo/core/vendor-common/etc/rings"
  cp "$S" "$RB/sign-release.sh"; cp "$G" "$RB/sitting-guard.sh"
  for d in verified-commit-guard.sh ring-for-build.sh ring-record.tsv assert-baked-ring.sh support-guard.sh keys-home.sh; do cp "$HERE/$d" "$RB/$d"; done
  # NWP-20261124-19: the guard's directory, with only its README (never the committed markers: a real one for
  # lynx would refuse every case here).
  mkdir -p "$X/repo/editions/endospore/support-ended"; cp "$HERE/../support-ended/README" "$X/repo/editions/endospore/support-ended/"
  cp "$ROOT"/core/vendor-common/etc/rings/*.conf "$X/repo/core/vendor-common/etc/rings/"
  echo 0.9.9 > "$X/repo/core/vendor-common/etc/nowhere-ota-version"
  write_stubs "$X"
  git -C "$X/repo" init -q && git -C "$X/repo" add -A \
    && git -C "$X/repo" -c user.name=fx -c user.email=fx@invalid commit -qm fixture || return 1
  printf '%s' "$FXPW" > "$X/pwref"; printf '%s\n' "$FXPW" > "$X/pw"
  : > "$X/conf"; printf '#!/bin/sh\nexit 0\n' > "$X/agent"; chmod +x "$X/agent"
  for d in "$@"; do mkzip "$X" "$d"; mkkeys "$X" "$d"; done
  printf '%s\n' "$X"
}

XENV=()
# run <X> <stdin-file> <args...>: runs the wrapper; RC, and $X/out, $X/err, $X/log.
run() {
  local X="$1" IN="$2"; shift 2
  : > "$X/log"
  env -u TMUX -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE -u BUILD_DATETIME -u BUILD_NUMBER -u OUT_DIR -u password \
    PATH="$X/bin:$PATH" ENDOSPORE_TREE="$X/tree" ENDOSPORE_REPO="$X/repo" SIGN_SHM_DIR="$X/shm" TMPDIR="$TMPDIR" \
    SIGN_MIN_TMP_GIB=0 NOWHERE_OTA_STORE_CONF="$X/conf" NOWHERE_AGENT="$X/agent" FX_LOG="$X/log" FX_PWFILE="$X/pwref" \
    FX_PS_PLANT="$X/plant" NOWHERE_KEYS_HOME="$X/keyshome" "${XENV[@]}" \
    bash "$X/repo/editions/endospore/build/sign-release.sh" "$@" < "$IN" > "$X/out" 2> "$X/err"
  RC=$?
}
has()   { grep -sqF -- "$2" "$1"; }          # <file> <text>
lacks() { ! grep -sqF -- "$2" "$1"; }
noprompt() { lacks "$1/err" "$PROMPT" && ! grep -qE '^(ossl|gen) ' "$1/log"; }
shm_empty() { [ -z "$(ls -A "$1/shm")" ]; }
head7() { git -C "$1/repo" rev-parse --short=7 HEAD; }

# ---- the cases; each sets WHY (empty = pass) and leaves its world in CX -------------------------------------------
CX=""; WHY=""
chk() { [ -n "$WHY" ] || { "$@" || WHY="$*"; }; }   # first failed assertion wins

case_usage() {   # <S> <G>
  local X a
  X=$(world "$1" "$2" husky) || { WHY="world"; return; }; CX="$X"
  for a in "" "20261122 abcdef1 husky" "$BN abcdef1 Husky" "$BN abcdef1 husky husky" "$BN abcdef1 husky:"; do
    # shellcheck disable=SC2086 -- each line is a deliberate word list
    run "$X" "$X/pw" $a
    [ "$RC" = 2 ] || { WHY="usage '$a' exit $RC, not 2"; return; }
    noprompt "$X" || { WHY="usage '$a' prompted"; return; }
  done
}
case_S1() {      # two devices, one prompt, the passphrase only in generate-release's environment
  local X n before
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  before=$(ls -A "$TMPDIR")
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 0
  n=$(grep -c -F "$PROMPT" "$X/err"); chk test "$n" = 1
  chk has "$X/log" "gen husky $BN password-set=yes password-ok=yes out=out-husky bdt=$BDT gen-start-stale=0"
  chk has "$X/log" "gen frankel $BN password-set=yes password-ok=yes out=out-frankel bdt=$BDT gen-start-stale=0"
  n=$(grep -cE '^(fin|mwp) ' "$X/log"); chk test "$n" = 4
  n=$(grep -E '^(fin|mwp) ' "$X/log" | grep -cv 'pw-env=no password-set=no'); chk test "$n" = 0
  chk has "$X/log" "lunch husky-cur-user"
  chk has "$X/log" "lunch frankel-cur-user"
  n=$(tar -tf "$X/tree/releases/$BN/manifests-$BN.tar" 2>/dev/null | sort | tr '\n' ' ')
  chk test "$n" = "frankel-manifest-$BN.json husky-manifest-$BN.json "
  chk shm_empty "$X"
  chk lacks "$X/err" "$FXPW"
  chk lacks "$X/out" "$FXPW"
  chk test "$(ls -A "$TMPDIR")" = "$before"
}
case_S3() {      # an inherited exported PW (and password) never carries the passphrase to a child (RF-001)
  local X n
  X=$(world "$1" "$2" husky) || { WHY="world"; return; }; CX="$X"
  XENV=(PW=inherited-sentinel password=inherited-sentinel)
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky
  XENV=()
  chk test "$RC" = 0
  chk has "$X/log" "gen husky $BN password-set=yes password-ok=yes out=out-husky "
  n=$(grep -cE '^(fin|mwp) ' "$X/log"); chk test "$n" = 2
  n=$(grep -E '^(fin|mwp) ' "$X/log" | grep -cv 'pw-env=no password-set=no'); chk test "$n" = 0
}
case_S2() {      # an explicit out dir
  local X
  X=$(world "$1" "$2" husky) || { WHY="world"; return; }; CX="$X"
  mkdir -p "$X/tree/out-husky-user"; mv "$X/tree/out-husky/target" "$X/tree/out-husky-user/"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky:out-husky-user
  chk test "$RC" = 0
  chk has "$X/log" "gen husky $BN password-set=yes password-ok=yes out=out-husky-user "
}
case_P1() {      # a wrong passphrase on the second device's key: nothing is signed
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  printf 'pw=another\n' > "$X/tree/keys/frankel/platform.pk8"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 1
  chk test "$(grep -c '^gen ' "$X/log")" = 0
  chk has "$X/err" "does not open $X/tree/keys/frankel/platform.pk8"
  chk lacks "$X/err" "$FXPW"
}
case_P2() {      # an empty passphrase
  local X
  X=$(world "$1" "$2" husky) || { WHY="world"; return; }; CX="$X"
  printf '\n' > "$X/empty"
  run "$X" "$X/empty" "$BN" "$(head7 "$X")" husky
  chk test "$RC" = 1
  chk has "$X/err" "empty passphrase -- refusing"
  chk test "$(grep -cE '^(ossl|gen) ' "$X/log")" = 0
}
refusal() {      # <S> <G> <name-in-err> <setup-fn> [devs...]: a preflight refusal, no prompt
  local S="$1" G="$2" NAME="$3" SETUP="$4" X; shift 4
  [ "$#" -gt 0 ] || set -- husky frankel
  X=$(world "$S" "$G" "$@") || { WHY="world"; return; }; CX="$X"
  "$SETUP" "$X"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" "$@"
  chk test "$RC" = 1
  chk has "$X/err" "$NAME"
  chk noprompt "$X"
  chk test "$(grep -c '^gen ' "$X/log")" = 0
}
su_R1() { mkzip "$1" husky bn=2026112202; }
su_R2() { mkzip "$1" husky type=userdebug; }
su_R3() { mkzip "$1" husky osref=os-frankel; }
su_R4() { mkzip "$1" husky commit=0123456789abcdef0123456789abcdef01234567; }
su_R5() { XENV=(FX_CPM_FAIL=out-husky/); }
su_R6() { mkzip "$1" lynx ring=beta; }
su_R7() { rm -f "$1/tree/out-husky/target/product/husky/obj/PACKAGING/target_files_intermediates/husky-target_files.zip"; }
su_K1() { rm -f "$1/tree/keys/frankel/avb_pkmd.bin"; }
su_O1() { XENV=(NOWHERE_OTA_STORE_CONF=); }
su_O2() { XENV=(FX_OFG_FAIL=frankel); }
su_T1() { XENV=(SIGN_MIN_TMP_GIB=999999999); }
su_F1() { mkdir -p "$1/shm/release_keys.stale1"; }
su_G1() { printf '#!/bin/bash\nread -rsp "Enter key passphrase: " password\n' > "$1/tree/script/decrypt-keys"; }
su_G2() { sed -i 's#/dev/shm/release_keys\.#/run/keys.#' "$1/tree/script/generate-release.sh"; }
su_V1() { printf '900003 1 claude\n' > "$1/plant"; }
su_KH2() { rm -rf "$1/tree/keys"; }
su_KH3() { mkdir -p "$1/keyshome"; cp -a "$1/tree/keys/husky" "$1/keyshome/"; printf 'another-root\n' > "$1/keyshome/husky/avb_pkmd.bin"; }
case_R() {       # <S> <G> <id>
  local id="$3"
  case "$id" in
    R1) refusal "$1" "$2" "husky: image baked build number '2026112202', not $BN" su_R1 ;;
    R2) refusal "$1" "$2" "husky: image is a 'userdebug' build, not user" su_R2 ;;
    R3) refusal "$1" "$2" "husky: image os-ref is 'os-frankel', not os-husky" su_R3 ;;
    R4) refusal "$1" "$2" "husky: image was staged from '0123456789abcdef0123456789abcdef01234567'" su_R4 ;;
    R5) refusal "$1" "$2" "husky: a framework patch's artifact literal is missing" su_R5 ;;
    R6) refusal "$1" "$2" "NOWHERE_RING=beta-setup NOWHERE_RING_OVERRIDE=1" su_R6 lynx ;;
    R7) refusal "$1" "$2" "husky: no target-files at" su_R7 ;;
    K1) refusal "$1" "$2" "frankel: keys/frankel/avb_pkmd.bin is MISSING" su_K1 ;;
    O1) refusal "$1" "$2" "the OTA version check needs NOWHERE_OTA_STORE_CONF" su_O1 ;;
    O2) refusal "$1" "$2" "frankel: the OTA stamp 0.9.9 is not above the field's" su_O2 ;;
    T1) refusal "$1" "$2" "the sitting needs 999999999" su_T1 ;;
    F1) refusal "$1" "$2" "release_keys.stale1" su_F1 ;;
    G1) refusal "$1" "$2" "an upstream sync changed the password gate or the key dir" su_G1 ;;
    G2) refusal "$1" "$2" "an upstream sync changed the password gate or the key dir" su_G2 ;;
    V1) refusal "$1" "$2" "pid 900003 claude" su_V1 ;;
    KH2) refusal "$1" "$2" "husky: no usable keys/husky (keys-home.sh, above)" su_KH2 ;;
    KH3) refusal "$1" "$2" "keys/husky/avb_pkmd.bin differs from the keys home's" su_KH3 ;;
  esac
  XENV=()
}
case_KH1() {     # NWP-20261105-19: a tree with no keys/ and a keys home holding both devices: linked, and both sign
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  mv "$X/tree/keys" "$X/keyshome"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 0
  chk test -L "$X/tree/keys"
  chk test "$(readlink "$X/tree/keys")" = "$X/keyshome"
  chk has "$X/err" "linked $X/tree/keys -> $X/keyshome"
  chk has "$X/log" "gen husky $BN password-set=yes password-ok=yes"
  chk has "$X/log" "gen frankel $BN password-set=yes password-ok=yes"
}
case_K2() {      # a missing id_ed25519 warns and still signs
  local X
  X=$(world "$1" "$2" husky) || { WHY="world"; return; }; CX="$X"
  rm -f "$X/tree/keys/husky/id_ed25519"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky
  chk test "$RC" = 0
  chk has "$X/err" "WARNING: keys/husky/id_ed25519 is MISSING"
}
case_X1() {      # a failing device: the other still signs, its key dir swept first
  local X n
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  XENV=(FX_GEN_FAIL=husky)
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  XENV=()
  chk test "$RC" = 1
  chk has "$X/log" "gen frankel $BN password-set=yes password-ok=yes"
  chk has "$X/log" "gen-start-stale=0"
  n=$(grep '^gen frankel' "$X/log" | grep -c 'gen-start-stale=0'); chk test "$n" = 1
  chk shm_empty "$X"
  chk has "$X/out" "  husky FAILED"
  chk has "$X/out" "  frankel signed"
  n=$(tar -tf "$X/tree/releases/$BN/manifests-$BN.tar" 2>/dev/null | tr '\n' ' ')
  chk test "$n" = "frankel-manifest-$BN.json "
}
case_X2() {      # envsetup pins another build number: that device fails, nothing reaches generate-release
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  XENV=(FX_ENVSETUP_BAD=out-husky)
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  XENV=()
  chk test "$RC" = 1
  chk test "$(grep -c '^gen husky' "$X/log")" = 0
  chk has "$X/log" "gen frankel"
  chk has "$X/err" "husky: BUILD_NUMBER is '1999010100' after envsetup"
}
case_H1() {      # TERM to the wrapper while generate-release holds: child gone, key dirs swept, the TERM line
  local X WPID i hp sp
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  : > "$X/log"
  ( exec env -u TMUX -u NOWHERE_RING -u NOWHERE_RING_OVERRIDE -u BUILD_DATETIME -u BUILD_NUMBER -u OUT_DIR -u password \
      PATH="$X/bin:$PATH" ENDOSPORE_TREE="$X/tree" ENDOSPORE_REPO="$X/repo" SIGN_SHM_DIR="$X/shm" TMPDIR="$TMPDIR" \
      SIGN_MIN_TMP_GIB=0 NOWHERE_OTA_STORE_CONF="$X/conf" NOWHERE_AGENT="$X/agent" FX_LOG="$X/log" FX_PWFILE="$X/pwref" \
      FX_PS_PLANT="$X/plant" FX_GEN_HOLD=husky FX_READY="$X/ready" FX_HOLD_PID="$X/hold.pid" FX_SLEEP_PID="$X/sleep.pid" \
      NOWHERE_KEYS_HOME="$X/keyshome" \
      bash "$X/repo/editions/endospore/build/sign-release.sh" "$BN" "$(head7 "$X")" husky frankel \
      < "$X/pw" > "$X/out" 2> "$X/err" ) &
  WPID=$!
  for i in $(seq 1 300); do [ -f "$X/ready" ] && break; sleep 0.1; done   # the bound only stops a hang
  [ -f "$X/ready" ] || { kill -TERM "$WPID" 2>/dev/null; wait "$WPID"; WHY="generate-release never reached its hold"; return; }
  sleep 0.2
  kill -TERM "$WPID"; wait "$WPID"; RC=$?
  hp=$(cat "$X/hold.pid" 2>/dev/null); sp=$(cat "$X/sleep.pid" 2>/dev/null)
  for i in $(seq 1 100); do kill -0 "$hp" 2>/dev/null || kill -0 "$sp" 2>/dev/null || break; sleep 0.1; done
  local alive=no
  { kill -0 "$hp" 2>/dev/null || kill -0 "$sp" 2>/dev/null; } && alive=yes
  # Whatever the verdict, no planted sleep outlives the suite.
  [ -n "$hp" ] && kill -TERM "$hp" 2>/dev/null; [ -n "$sp" ] && kill -TERM "$sp" 2>/dev/null
  chk test "$RC" = 143
  chk has "$X/err" "$TERMLINE"
  chk shm_empty "$X"
  chk test "$alive" = no
  chk test "$(grep -c '^gen frankel' "$X/log")" = 0
}

# ---- --preflight-only (NWP-20261202-14): the PREFLIGHT line grammar the Release Desk reads ----------------------------
PFIDS='commit|ota-conf|image|build-number|build-type|os-ref|source-commit|patch-markers|ring|keys|signer-key|support|ota-stamp|tmpdir|stale-keys|upstream-gate|session'
PFDEV='image build-number build-type os-ref source-commit patch-markers ring keys signer-key support ota-stamp'
PFONCE='commit ota-conf tmpdir stale-keys upstream-gate session'
TAB=$'\t'
pf_grammar() {   # <file>: every line a result line, OK text empty, FAIL/WARN text not, and only the last a verdict
  python3 -I - "$1" "$PFIDS" <<'PY2'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
if not lines or lines[-1] != "":
    sys.exit(1)
lines = lines[:-1]
row = re.compile(r"PREFLIGHT\t(OK|FAIL|WARN)\t(-|[a-z0-9]+)\t(%s)\t([^\t]*)" % sys.argv[2])
if not lines or not re.fullmatch(r"PREFLIGHT\t(PASS|REFUSED\t[1-9][0-9]*)", lines[-1]):
    sys.exit(1)
for l in lines[:-1]:
    m = row.fullmatch(l)
    if not m or (m.group(1) == "OK") != (m.group(4) == ""):
        sys.exit(1)
PY2
}
pf_count() {     # <file> <status|*> <dev|-> <check>: how many such PREFLIGHT lines
  awk -F'\t' -v s="$2" -v d="$3" -v c="$4" '$1=="PREFLIGHT" && (s=="*" || $2==s) && $3==d && $4==c' "$1" | wc -l | tr -d ' '
}
pf_has() { [ "$(pf_count "$@")" -ge 1 ]; }
pf_text() { awk -F'\t' -v s="$2" -v d="$3" -v c="$4" '$1=="PREFLIGHT" && $2==s && $3==d && $4==c {print $5; exit}' "$1"; }
pf_last() { tail -n 1 "$1"; }
pf_allok() {     # <file> <dev>...: one OK line for every per-device id of each device
  local f="$1" d c; shift
  for d in "$@"; do for c in $PFDEV; do [ "$(pf_count "$f" OK "$d" "$c")" = 1 ] || return 1; done; done
}
nosign() { ! grep -qE '^(ossl|fin|gen|mwp) ' "$1/log" && shm_empty "$1" && [ ! -e "$1/tree/releases" ]; }
case_PF1() {     # all pass: one OK line per check, PASS, exit 0, nothing but PREFLIGHT lines on stdout, nothing signed
  local X c n
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  run "$X" "$X/pw" --preflight-only "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 0
  chk pf_grammar "$X/out"
  for c in $PFONCE; do chk test "$(pf_count "$X/out" OK - "$c")" = 1; done
  chk pf_allok "$X/out" husky frankel
  n=$(wc -l < "$X/out"); chk test "$n" = 29
  chk test "$(pf_last "$X/out")" = "PREFLIGHT${TAB}PASS"
  chk lacks "$X/err" "$PROMPT"
  chk nosign "$X"
  chk lacks "$X/out" "preflight passed"
  chk lacks "$X/out" "verified commit"
  chk has "$X/err" "sign-release: preflight passed for husky frankel"
  chk has "$X/err" "verified commit"
}
case_PF2() {     # one device bakes a wrong build number: exactly one FAIL line, the other device all OK, REFUSED 1
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  mkzip "$X" husky bn=2026112202
  run "$X" "$X/pw" --preflight-only "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 1
  chk pf_grammar "$X/out"
  chk test "$(pf_count "$X/out" FAIL husky build-number)" = 1
  chk test "$(grep -c "^PREFLIGHT${TAB}FAIL${TAB}" "$X/out")" = 1
  chk test "$(pf_text "$X/out" FAIL husky build-number)" = "husky: image baked build number '2026112202', not $BN"
  chk pf_allok "$X/out" frankel
  chk test "$(pf_last "$X/out")" = "PREFLIGHT${TAB}REFUSED${TAB}1"
  chk noprompt "$X"
  chk nosign "$X"
}
case_PF3() {     # a wrong verified commit: FAIL - commit and the run goes on; normal mode still exits with the guard's code
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  run "$X" "$X/pw" --preflight-only "$BN" deadbee husky frankel
  PFRC=$RC; cp "$X/out" "$X/pf.out"; cp "$X/log" "$X/pf.log"
  chk test "$PFRC" = 1
  chk pf_grammar "$X/pf.out"
  chk pf_has "$X/pf.out" FAIL - commit
  chk test "$(pf_count "$X/pf.out" OK - commit)" = 0
  case "$(pf_text "$X/pf.out" FAIL - commit)" in *"unknown to"*) ;; *) chk false commit-text ;; esac
  chk pf_has "$X/pf.out" FAIL husky source-commit
  chk pf_has "$X/pf.out" FAIL frankel source-commit
  chk pf_has "$X/pf.out" OK husky build-number
  chk pf_has "$X/pf.out" OK frankel patch-markers
  chk noprompt "$X"
  run "$X" "$X/pw" "$BN" deadbee husky frankel
  chk test "$RC" = 2
  chk lacks "$X/out" PREFLIGHT
  chk test "$(grep -c '^cpm ' "$X/log")" = 0
  chk noprompt "$X"
}
case_PF4() {     # another process of the signing user: FAIL - session, the guard's names on stderr only
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  printf '900003 1 claude\n' > "$X/plant"
  run "$X" "$X/pw" --preflight-only "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 1
  chk pf_grammar "$X/out"
  chk pf_has "$X/out" FAIL - session
  chk has "$X/err" "pid 900003 claude"
  chk lacks "$X/out" "pid 900003"
  chk test "$(pf_last "$X/out")" = "PREFLIGHT${TAB}REFUSED${TAB}1"
  chk noprompt "$X"
}
case_PF7() {     # the guard cannot read the process table: FAIL - session carries the guard's own words
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  XENV=(FX_PS_FAIL=1)
  run "$X" "$X/pw" --preflight-only "$BN" "$(head7 "$X")" husky frankel
  XENV=()
  chk test "$RC" = 1
  chk pf_grammar "$X/out"
  chk test "$(pf_text "$X/out" FAIL - session)" = "sitting-guard: ps -u $(id -u) failed -- refusing"
  chk has "$X/err" "sitting-guard: ps -u $(id -u) failed -- refusing"
  chk test "$(pf_last "$X/out")" = "PREFLIGHT${TAB}REFUSED${TAB}1"
  chk noprompt "$X"
}
case_PF5() {     # keys refused: FAIL keys and no signer-key line; a missing id_ed25519 alone: WARN and still PASS
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  rm -rf "$X/tree/keys"
  run "$X" "$X/pw" --preflight-only "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 1
  chk pf_grammar "$X/out"
  chk pf_has "$X/out" FAIL husky keys
  chk test "$(pf_count "$X/out" '*' husky signer-key)" = 0
  [ -n "$WHY" ] && return
  X=$(world "$1" "$2" husky) || { WHY="world"; return; }; CX="$X"
  rm -f "$X/tree/keys/husky/id_ed25519"
  run "$X" "$X/pw" --preflight-only "$BN" "$(head7 "$X")" husky
  chk test "$RC" = 0
  chk pf_grammar "$X/out"
  chk test "$(pf_count "$X/out" WARN husky signer-key)" = 1
  chk test "$(pf_count "$X/out" OK husky signer-key)" = 0
  case "$(pf_text "$X/out" WARN husky signer-key)" in *"id_ed25519 is MISSING"*) ;; *) chk false warn-text ;; esac
  chk test "$(pf_last "$X/out")" = "PREFLIGHT${TAB}PASS"
}
case_PF6() {     # normal mode prints no PREFLIGHT line, on a pass or a refusal
  local X
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 0
  chk lacks "$X/out" PREFLIGHT
  chk lacks "$X/err" PREFLIGHT
  X=$(world "$1" "$2" husky frankel) || { WHY="world"; return; }; CX="$X"
  su_R1 "$X"
  run "$X" "$X/pw" "$BN" "$(head7 "$X")" husky frankel
  chk test "$RC" = 1
  chk lacks "$X/out" PREFLIGHT
  chk lacks "$X/err" PREFLIGHT
  chk has "$X/err" "REFUSING: husky: image baked build number"
}

# ---- the guard alone, under one shell -------------------------------------------------------------------------------
GDBIN=""
# gd <S> <G> <shell> <plant-rows> <clients|-> <TMUX value|-> [awk-broken]: GRC, and $X/gout, $X/gerr, $X/pslog.
gd() {
  local X SH="$3" PL="$4" CLI="$5" TM="$6" BROKEN="${7:-}" P
  X=$(mktemp -d -p "$W" gd.XXXXXX) || return 1; CX="$X"
  mkdir -p "$X/bin" "$X/awkbin"
  cp "$2" "$X/sitting-guard.sh"
  # the ps and tmux stubs of one device-less world, built once
  [ -n "$GDBIN" ] || { GDBIN=$(world "$1" "$2") || return 1; GDBIN="$GDBIN/bin"; }
  cp "$GDBIN/ps" "$GDBIN/tmux" "$X/bin/"
  printf '%b' "$PL" > "$X/plant"
  [ "$CLI" = - ] || printf '%b' "$CLI" > "$X/clients"
  printf '#!/bin/sh\necho "awk: syntax error at source line 1" >&2\nexit 1\n' > "$X/awkbin/awk"; chmod +x "$X/awkbin/awk"
  P="$X/bin:$PATH"; [ -z "$BROKEN" ] || P="$X/awkbin:$P"
  if [ "$TM" = - ]; then
    env -u TMUX PATH="$P" FX_PS_PLANT="$X/plant" FX_TMUX_CLIENTS="$X/clients" FX_PS_LOG="$X/pslog" ${FX_PS_FAIL:+FX_PS_FAIL=$FX_PS_FAIL} \
      "$SH" "$X/sitting-guard.sh" 900001 > "$X/gout" 2> "$X/gerr"
  else
    env TMUX="$TM" PATH="$P" FX_PS_PLANT="$X/plant" FX_TMUX_CLIENTS="$X/clients" FX_PS_LOG="$X/pslog" \
      "$SH" "$X/sitting-guard.sh" 900001 > "$X/gout" 2> "$X/gerr"
  fi
  GRC=$?
}
WRAP='900001 1 bash\n900002 900001 sleep\n'
FOREIGN='900003 1 claude\n'
TMUXCHAIN='900010 900011 tmux\n900011 1 sshd\n'
UM='900020 1 systemd\n900021 900020 (sd-pam)\n'
awk_clean() { lacks "$1/gerr" "awk:" && lacks "$1/gerr" "syntax error" && lacks "$1/gerr" "the process-table judge failed"; }
case_GD() {      # <S> <G> <id> <shell>
  local S="$1" G="$2" id="$3" sh="$4" up
  case "$id" in
    GD1) gd "$S" "$G" "$sh" "$WRAP" - -;                    chk test "$GRC" = 0; chk lacks "$CX/gerr" "pid " ;;
    GD2) gd "$S" "$G" "$sh" "$WRAP$FOREIGN" - -;            chk test "$GRC" = 1; chk has "$CX/gerr" "pid 900003 claude"
         chk has "$CX/gerr" "end these (an agent session included) and run again"; chk test "$(grep -c '^pid ' "$CX/gerr")" = 1 ;;
    GD3) gd "$S" "$G" "$sh" "$WRAP$TMUXCHAIN" '900010\n' x; chk test "$GRC" = 0 ;;
    GD4) gd "$S" "$G" "$sh" "$WRAP$TMUXCHAIN" '900010\n' -; chk test "$GRC" = 1; chk has "$CX/gerr" "pid 900010 tmux"; chk has "$CX/gerr" "pid 900011 sshd" ;;
    GD5) gd "$S" "$G" "$sh" "$WRAP$UM" - -;                 chk test "$GRC" = 0 ;;
    GD6) gd "$S" "$G" "$sh" "${WRAP}900020 77 systemd\n900021 900020 (sd-pam)\n" - -
         chk test "$GRC" = 1; chk has "$CX/gerr" "pid 900020 systemd"; chk has "$CX/gerr" "pid 900021 (sd-pam)" ;;
    GD6b) FX_PS_FAIL=1 gd "$S" "$G" "$sh" "$WRAP" - -;      chk test "$GRC" = 2 ;;
    GD7) gd "$S" "$G" "$sh" "$WRAP" - -
         chk test "$GRC" = 0; chk lacks "$CX/gerr" "pid "
         up=$(sed -n 's/^u //p' "$CX/pslog" 2>/dev/null | head -1)
         chk test -n "$up"
         # the trap it guards is live: the -u call's own process is absent from the -e table
         chk test "$(grep -sc '^e ' "$CX/pslog")" = 1
         chk test "$(sed -n 's/^e //p' "$CX/pslog" 2>/dev/null)" != "$up" ;;
    GD8) gd "$S" "$G" "$sh" "$WRAP$FOREIGN" - - broken
         chk test "$GRC" = 2; chk has "$CX/gerr" "the process-table judge failed"; chk lacks "$CX/gerr" "pid " ;;
  esac
}

# ---- plain run --------------------------------------------------------------------------------------------------
report() { if [ -z "$WHY" ]; then ok "$1"; else no "$1 -- $WHY"; fi; WHY=""; }
plain() {
  local c sh
  WHY=""; case_usage "$SIGN" "$GUARD"; report "U1-U5 usage errors exit 2 with no prompt"
  WHY=""; case_S1 "$SIGN" "$GUARD"; report "S1 two devices: one prompt, password only for generate-release, one bundle, key dirs swept"
  WHY=""; case_S3 "$SIGN" "$GUARD"; report "S3 an inherited exported PW or password reaches no child"
  WHY=""; case_S2 "$SIGN" "$GUARD"; report "S2 an explicit out dir is the one signed"
  WHY=""; case_P1 "$SIGN" "$GUARD"; report "P1 a wrong passphrase on the second device's key: nothing signed, the key named"
  WHY=""; case_P2 "$SIGN" "$GUARD"; report "P2 an empty passphrase is refused before any key is tried"
  for c in R1 R2 R3 R4 R5 R6 R7 K1 KH2 KH3 O1 O2 T1 F1 G1 G2 V1; do
    WHY=""; case_R "$SIGN" "$GUARD" "$c"; report "$c preflight refusal, named, no prompt"
  done
  WHY=""; case_K2 "$SIGN" "$GUARD"; report "K2 a missing id_ed25519 warns and still signs"
  WHY=""; case_KH1 "$SIGN" "$GUARD"; report "KH1 a tree with no keys/ is linked to the keys home and both devices sign"
  WHY=""; case_X1 "$SIGN" "$GUARD"; report "X1 a failing device: the other signs after its key dir is swept; exit 1"
  WHY=""; case_X2 "$SIGN" "$GUARD"; report "X2 envsetup pinning another BN fails that device before generate-release"
  WHY=""; case_H1 "$SIGN" "$GUARD"; report "H1 TERM mid-signing: child gone, key dirs swept, the TERM line"
  WHY=""; case_PF1 "$SIGN" "$GUARD"; report "PF1 --preflight-only, all pass: one OK line per check, PASS, exit 0, no prompt, nothing signed"
  WHY=""; case_PF2 "$SIGN" "$GUARD"; report "PF2 --preflight-only, one wrong build number: one FAIL line, REFUSED 1, exit 1"
  WHY=""; case_PF3 "$SIGN" "$GUARD"; report "PF3 --preflight-only, a wrong commit: FAIL - commit, the run goes on; normal mode exits 2 first"
  WHY=""; case_PF4 "$SIGN" "$GUARD"; report "PF4 --preflight-only, another process of the user: FAIL - session, its name on stderr"
  WHY=""; case_PF5 "$SIGN" "$GUARD"; report "PF5 --preflight-only: refused keys print no signer-key; a missing id_ed25519 is WARN and PASS"
  WHY=""; case_PF6 "$SIGN" "$GUARD"; report "PF6 normal mode prints no PREFLIGHT line"
  WHY=""; case_PF7 "$SIGN" "$GUARD"; report "PF7 --preflight-only, an unreadable process table: FAIL - session carries the guard's own words"
  for sh in $SHELLS; do
    for c in GD1 GD2 GD3 GD4 GD5 GD6 GD6b GD7 GD8; do
      WHY=""; case_GD "$SIGN" "$GUARD" "$c" "$sh"; report "$c sitting-guard under $sh"
    done
  done
}

# ---- mutants: each runs ONLY its signature case and needs that case's own evidence -------------------------------
mutate_file() {  # <src> <dst> <anchor-line> <replacement> ("@LINE@" = the original line)
  python3 -I - "$@" <<'PY'
import sys
src, dst, anchor, rep = sys.argv[1:5]
lines = open(src).read().split("\n")
hits = [i for i, l in enumerate(lines) if l.strip() == anchor]
if len(hits) != 1:
    sys.exit(3)
i = hits[0]; ind = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
lines[i] = "" if rep == "" else (lines[i] + rep[6:] if rep.startswith("@LINE@") else ind + rep)
open(dst, "w").write("\n".join(lines))
PY
}
VERDICT=""
convict() {      # <id> <sign-src> <guard-src>: runs the signature case and sets VERDICT
  local M="$1" S="$2" G="$3" sh up c bad=""
  WHY=""
  case "$M" in
    M1) case_P2 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif lacks "$CX/err" "empty passphrase -- refusing" && grep -q '^ossl ' "$CX/log"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M2) case_S1 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif grep -E '^(fin|mwp) ' "$CX/log" | grep -q 'pw-env=yes'; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M12) case_S3 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif grep -E '^(fin|mwp) ' "$CX/log" | grep -q 'pw-env=yes'; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M3) case_P1 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif grep -q '^gen ' "$CX/log"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M4|M9|M7|M8|M10)
        case "$M" in M4) c=F1 ;; M9) c=G1 ;; M7) c=R1 ;; M8) c=R5 ;; M10) c=R4 ;; esac
        case_R "$S" "$G" "$c"
        if [ -z "$WHY" ]; then VERDICT=SURVIVED
        elif has "$CX/err" "$PROMPT" || grep -q '^gen husky' "$CX/log"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M6) case_H1 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif lacks "$CX/err" "$TERMLINE"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M13) case_KH1 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif has "$CX/err" "keys/husky/*.pk8 is MISSING"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M15) case_PF1 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif has "$CX/err" "$PROMPT" || grep -q '^ossl ' "$CX/log"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M16) case_PF4 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif [ "$RC" = 0 ] && pf_has "$CX/out" OK - session; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M21) case_PF7 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED
         elif [ "$RC" = 1 ] && [ "$(pf_text "$CX/out" FAIL - session)" = "sitting-guard.sh refused (exit 2) and printed no reason" ]; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M17) case_PF3 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif [ "$PFRC" = 2 ] && ! pf_has "$CX/pf.out" FAIL - commit && ! grep -q '^cpm ' "$CX/pf.log"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M18) case_PF2 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED
         elif [ -n "$(pf_text "$CX/out" OK husky build-number)" ] && ! grep -q "^PREFLIGHT${TAB}FAIL${TAB}" "$CX/out"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M19) case_PF2 "$S" "$G"; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif [ "$RC" = 1 ] && [ "$(pf_last "$CX/out")" = "PREFLIGHT${TAB}PASS" ]; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M20) case_R "$S" "$G" R1; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif [ "$RC" = 1 ] && lacks "$CX/err" "REFUSING:"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M14) case_R "$S" "$G" KH3; if [ -z "$WHY" ]; then VERDICT=SURVIVED; elif has "$CX/err" "$PROMPT" || grep -q '^gen husky' "$CX/log"; then VERDICT=CONVICTED; else VERDICT=BROKEN; fi ;;
    M5|M11)
        VERDICT=CONVICTED
        for sh in $SHELLS; do
          WHY=""
          if [ "$M" = M5 ]; then
            case_GD "$S" "$G" GD2 "$sh"
            if [ -z "$WHY" ]; then bad=SURVIVED
            elif ! { [ "$GRC" = 0 ] && lacks "$CX/gerr" "pid 900003"; }; then bad=BROKEN; fi
          else
            case_GD "$S" "$G" GD7 "$sh"
            up=$(sed -n 's/^u //p' "$CX/pslog" 2>/dev/null | head -1)
            if [ -z "$WHY" ]; then bad=SURVIVED
            elif ! { [ "$GRC" = 1 ] && [ -n "$up" ] && grep -qE "^pid $up ps\$" "$CX/gerr" && awk_clean "$CX"; }; then bad=BROKEN; fi
          fi
          [ -z "$bad" ] || { VERDICT="$bad (under $sh)"; break; }
        done ;;
  esac
  WHY=""
}
mutant() {       # <id> <sign|guard> <anchor-line> <replacement>
  local M="$1" F="$2" A="$3" R="$4" src dst rc sh
  if [ "$F" = sign ]; then src="$SIGN"; else src="$GUARD"; fi
  dst=$(mktemp -p "$W" "mut-$M.XXXXXX")
  mutate_file "$src" "$dst" "$A" "$R"; rc=$?
  if [ "$rc" != 0 ] || cmp -s "$src" "$dst"; then no "DID NOT APPLY $M"; return; fi
  rc=0
  if [ "$F" = sign ]; then bash -n "$dst" 2>/dev/null || rc=1
  else for sh in $SHELLS; do "$sh" -n "$dst" 2>/dev/null || rc=1; done; fi
  [ "$rc" = 0 ] || { no "BROKEN $M (does not parse)"; return; }
  if [ "$F" = sign ]; then convict "$M" "$dst" "$GUARD"; else convict "$M" "$SIGN" "$dst"; fi
  if [ "$VERDICT" = CONVICTED ]; then ok "CONVICTED $M"; else no "$VERDICT $M"; fi
}
mutants() {
  mutant M1 sign '[ -n "$PW" ] || { echo "empty passphrase -- refusing (an empty-but-defined password makes decrypt-keys prompt per key on /dev/tty)" >&2; exit 1; }' ':'
  mutant M2 sign 'IFS= read -rs PW' '@LINE@; export PW'
  mutant M3 sign 'prove_keys || exit 1' ':'
  mutant M4 sign 'check_stale_key_dirs' ':'
  mutant M5 guard 'set -u' 'set -u; exit 0'
  mutant M6 sign "trap 'sweep 143 TERM' TERM" ':'
  mutant M7 sign '[ "$IMG_BN" = "$BN" ] || refuse "$DEV" build-number "$DEV: image baked build number '"'"'$IMG_BN'"'"', not $BN"' ':'
  mutant M8 sign 'python3 "$B/check-patch-markers.py" --table "$B/patch-markers.tsv" --zip "$TFI" >&2 || refuse "$DEV" patch-markers "$DEV: a framework patch'"'"'s artifact literal is missing"' ':'
  mutant M9 sign 'check_upstream_gate' ':'
  mutant M10 sign '[ -n "$FULL" ] && [ "$IMG_COMMIT" = "$FULL" ] || refuse "$DEV" source-commit "$DEV: image was staged from '"'"'$IMG_COMMIT'"'"', not the verified commit ${FULL:-<unresolved>}"' ':'
  # inside the awk program: an EMPTY line, a valid awk no-op (a bare ':' is an awk syntax error)
  mutant M11 guard 'if (!(p in par)) par[p] = pp' ''
  mutant M12 sign 'unset PW password' ':'
  # NWP-20261105-19: the keys home
  mutant M13 sign 'if ! sh "$B/keys-home.sh" "$TREE" "$DEV" >&2; then' 'if false; then'
  mutant M14 sign 'refuse "$DEV" keys "$DEV: no usable keys/$DEV (keys-home.sh, above)"' ':'
  # NWP-20261202-14: --preflight-only
  mutant M15 sign 'exit "$(( NFAIL > 0 ))"' ':'
  mutant M16 sign 'if sh "$B/sitting-guard.sh" "$$" 2> "$T/session.err"; then rc=0; else rc=$?; fi' 'rc=0; : > "$T/session.err"'
  mutant M17 sign 'if [ -z "$PF" ]; then   # normal mode: a commit refusal ends the run here' 'if true; then'
  mutant M18 sign 'pf_fail() { PFF["$1 $2"]=1; NFAIL=$((NFAIL+1)); pf_line FAIL "$1" "$2" "$3"; }' 'pf_fail() { PFF["$1 $2"]=1; NFAIL=$((NFAIL+1)); pf_line OK "$1" "$2" "$3"; }'
  mutant M19 sign "$(cat <<'EOF'
if [ "$NFAIL" = 0 ]; then printf 'PREFLIGHT\tPASS\n' >&3; else printf 'PREFLIGHT\tREFUSED\t%d\n' "$NFAIL" >&3; fi
EOF
)" "printf 'PREFLIGHT\\tPASS\\n' >&3"
  mutant M20 sign 'refuse() { echo "REFUSING: $3" >&2; REFUSED=1; pf_fail "$1" "$2" "$3"; }   # <dev|-> <check> <text>' 'refuse() { REFUSED=1; pf_fail "$1" "$2" "$3"; }'
  mutant M21 sign "$(cat <<'EOF'
REFUSED=1; why=$(grep -v '^pid [0-9]' "$T/session.err" | tr '\n' ' ' | sed 's/ *$//')
EOF
)" 'REFUSED=1; why=""'
}

echo "test-sign-release.sh (shells:$SHELLS)"
plain
[ "$MUTATE" = yes ] && { echo "mutants:"; mutants; }
echo "$PASS passed, $FAIL failed"
[ -z "$(ls -A "$TMPDIR")" ] || { echo "FAIL: the suite left files in its TMPDIR"; exit 1; }
[ "$FAIL" = 0 ]
