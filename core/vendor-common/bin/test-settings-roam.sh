#!/usr/bin/env bash
# test-settings-roam.sh [--mutate] -- NWP-20261130-12 (Q012, #70): the curated settings allowlist, with one row, Secure
# sysui_qs_tiles. Roamd captures it at seal into the sibling file nowhere-settings-roam, and the chooser replays it
# through the live provider at sign-in.
#
# Three halves. The shell cases (S) run roamd's functions, extracted by anchor, under each shell found, with `settings`
# stubbed: the capture is shell, because only roamd runs at every seal. The Java cases (J) run SettingsRoam.java as is
# under javac (core/chooser/tests/settings-roam/). The chain cases (E, P) cross both halves. Source pins hold the wiring
# that neither half can run: ChooserActivity and SettingsRoamLive do not compile off the build host.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS.
#
#   bash test-settings-roam.sh            # the cases and the pins
#   bash test-settings-roam.sh --mutate   # ... plus broken copies that must each be CONVICTED by the case they name
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SRC="$ROOT/core/chooser/src/com/nowhere/chooser"
ROAMD="$ROOT/core/vendor-common/bin/nowhere_roamd.sh"
JSUT="$SRC/SettingsRoam.java"
CASES="$ROOT/core/chooser/tests/settings-roam/SettingsRoamCases.java"
LIST="$ROOT/core/vendor-common/etc/settings-roam.list"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
INNER='a,custom(com.x/.Outer$Tile),b'
# The architecture's set, 70 characters. P1 builds the expected table from it.
SET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./(),-$'

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip." >&2
  exit 2
fi
# The cases run under every shell found (the device's /system/bin/sh is mksh); ROAM_SHELLS overrides.
SHELLS=""
if [ -n "${ROAM_SHELLS:-}" ]; then SHELLS="$ROAM_SHELLS"
else for s in bash sh dash mksh; do command -v "$s" >/dev/null 2>&1 && SHELLS="$SHELLS $s"; done; fi
[ -n "$SHELLS" ] || { echo "no shell found" >&2; exit 2; }
echo "shells:$SHELLS"

# --- the expected verdict table ------------------------------------------------------------------------------------
expected_table() {
  local i c v
  for ((i = 32; i <= 126; i++)); do
    printf -v c "\\$(printf '%03o' "$i")"
    v=0; case "$SET" in *"$c"*) v=1 ;; esac
    printf '%02x %s\n' "$i" "$v"
  done
  printf 'len8192 1\nlen8193 0\nempty 0\n'
}

# --- the shell half ------------------------------------------------------------------------------------------------
FNS="sroam_list_path sroam_row_ok sroam_tiles_valid sroam_record_line sroam_merge_tiles sroam_seal_capture sroam_surface"

# make_lib <roamd> <dest>: the functions by anchor, and the settings stub. Its directory holds <scope>.<key> files, an
# absent file reads as `null`, as `settings get` prints for a row never set, and each read is recorded.
make_lib() {
  local f="$1" dest="$2" fn body
  : > "$dest"
  for fn in $FNS; do
    body=$(sed -n "/^$fn() {\$/,/^}\$/p" "$f")
    [ -n "$body" ] || { echo "FAIL EXTRACTION $fn is not in $f"; return 1; }
    printf '%s\n' "$body" >> "$dest"
  done
  cat >> "$dest" <<'EOS'
settings() {
  [ "$1" = get ] || return 1
  printf '%s %s %s\n' "$3" "$4" "$5" >> "$SETDIR/reads"
  if [ -f "$SETDIR/$4.$5" ]; then cat "$SETDIR/$4.$5"; else echo null; fi
}
EOS
}

# shell_cases <lib> <shell>: prints `ok <id> [<shell>] ...` or `FAIL <id> [<shell>] ...`. Own temp dir under $W.
shell_cases() {
  local lib="$1" sh="$2" t ud rec sd lg pf got want x big
  t=$(mktemp -d -p "$W") || return 2
  ud="$t/user"; rec="$ud/com.nowhere.chooser/files/nowhere-settings-roam"; sd="$t/set"; lg="$t/roam.log"; pf="$t/prefs.out"

  fresh() { rm -rf "$ud" "$sd"; mkdir -p "$ud/com.nowhere.chooser/files" "$sd"; : > "$lg"; : > "$pf"; }
  setv() { printf '%s' "$2" > "$sd/$1"; }
  marked() { setv secure.nowhere_sroam_applied 1; }
  # sc [SROAM_LIST=<file>] fn args: one function call under the shell under test.
  sc() {
    local l="$LIST"
    case "$1" in SROAM_LIST=*) l=${1#SROAM_LIST=}; shift ;; esac
    LOG="$lg" SETDIR="$sd" SROAM_LIST="$l" "$sh" -c '. "$1"; shift; "$@"' x "$lib" "$@"
  }
  res() {  # res <id> <cond rc> <text>
    if [ "$2" = 0 ]; then printf 'ok %s [%s] %s\n' "$1" "$sh" "$3"; else printf 'FAIL %s [%s] %s\n' "$1" "$sh" "$3"; fi
  }
  eq() {  # eq <id> <got> <want> <text>
    if [ "$2" = "$3" ]; then res "$1" 0 "$4"; else res "$1" 1 "$4 (got '$2')"; fi
  }

  # S1: the capture writes the row.
  fresh; marked; setv secure.sysui_qs_tiles 'wifi,bt'
  sc sroam_seal_capture "$ud" 10
  eq S1 "$(cat "$rec" 2>/dev/null)" 'secure sysui_qs_tiles wifi,bt' "the capture writes the row"
  case "$(cat "$sd/reads" 2>/dev/null)" in *'10 secure sysui_qs_tiles'*) res S1 0 "the read is for the session's user" ;; *) res S1 1 "the read is not for the user" ;; esac
  [ ! -e "$rec.tmp" ]; res S1 $? "no .tmp stays"
  # S1d: the same with a $ in the class, over an old row.
  fresh; marked; setv secure.sysui_qs_tiles "$INNER"; printf 'secure sysui_qs_tiles old\n' > "$rec"
  sc sroam_seal_capture "$ud" 10
  eq S1d "$(cat "$rec")" "secure sysui_qs_tiles $INNER" "a \$ in the class is captured byte for byte"
  # S1m: a tile that still waits stays in the record (a custom tile is not dropped from storage).
  fresh; marked; setv secure.sysui_qs_tiles 'a,b'; setv secure.nowhere_sroam_tiles 'a,?custom(x/y),b'
  sc sroam_seal_capture "$ud" 10
  eq S1m "$(cat "$rec")" 'secure sysui_qs_tiles a,custom(x/y),b' "a waiting tile stays in the record, at its position"

  # S2: no marker, the record stays byte for byte.
  fresh; setv secure.sysui_qs_tiles 'default,list'; printf 'secure sysui_qs_tiles kept\nodd bytes\n' > "$rec"
  sc sroam_seal_capture "$ud" 10
  eq S2 "$(cat "$rec")" "$(printf 'secure sysui_qs_tiles kept\nodd bytes')" "no marker: the record stays byte for byte"
  x=$(cat "$lg"); case "$x" in *'not applied this session'*) res S2 0 "the keep is logged" ;; *) res S2 1 "the keep is not logged" ;; esac
  x=$(cat "$sd/reads"); case "$x" in *sysui_qs_tiles*) res S2 1 "the row was read before the apply" ;; *) res S2 0 "the row is not read" ;; esac

  # S3: null, empty and multi-line reads carry the old row.
  fresh; marked; printf 'secure sysui_qs_tiles old\n' > "$rec"
  sc sroam_seal_capture "$ud" 10
  eq S3 "$(cat "$rec")" 'secure sysui_qs_tiles old' "a null read carries the old row"
  fresh; marked; setv secure.sysui_qs_tiles ''; printf 'secure sysui_qs_tiles old\n' > "$rec"
  sc sroam_seal_capture "$ud" 10
  eq S3 "$(cat "$rec")" 'secure sysui_qs_tiles old' "an empty read carries the old row"
  fresh; marked; setv secure.sysui_qs_tiles "$(printf 'a\nb')"; printf 'secure sysui_qs_tiles old\n' > "$rec"
  sc sroam_seal_capture "$ud" 10
  eq S3 "$(cat "$rec")" 'secure sysui_qs_tiles old' "a multi-line read carries the old row"
  fresh; marked
  sc sroam_seal_capture "$ud" 10
  [ ! -e "$rec" ]; res S3 $? "no value and no record: no file"

  # S3r: a value outside the set or over the cap carries the old row and counts as refused.
  big=$(printf '%8193s' '' | tr ' ' a)
  for x in 'a b' 'a?b' "$big"; do
    fresh; marked; setv secure.sysui_qs_tiles "$x"; printf 'secure sysui_qs_tiles old\n' > "$rec"
    sc sroam_seal_capture "$ud" 10
    eq S3r "$(cat "$rec")" 'secure sysui_qs_tiles old' "a value outside the set carries the old row (length ${#x})"
    got=$(cat "$lg"); case "$got" in *'refused=1'*) res S3r 0 "refused is counted" ;; *) res S3r 1 "refused is not counted" ;; esac
  done

  # S4: the list gates which keys are read.
  local tl="$t/list" ofs
  { printf '# comment\nsecure on_list\nsecure bad-key\nglobal glob_key\nsecure odd_kind weird\nsystem also_on\n\nsecure extra tiles field\n'
    printf 'system last_row'; } > "$tl"
  fresh; marked; setv secure.on_list 'one two'; setv secure.off_list v; setv global.glob_key v; setv system.also_on 3; setv system.last_row 4
  printf 'secure off_list stale\n' > "$rec"
  sc SROAM_LIST="$tl" sroam_seal_capture "$ud" 10
  got=$(sed 's/^10 //' "$sd/reads" | tr '\n' ';')
  eq S4 "$got" 'secure nowhere_sroam_applied;secure on_list;system also_on;system last_row;' "only listed keys are read"
  eq S4 "$(cat "$rec")" "$(printf 'secure on_list one two\nsystem also_on 3\nsystem last_row 4')" "only listed rows reach the record"
  fresh; marked; setv secure.sysui_qs_tiles a; setv secure.other b
  sc sroam_seal_capture "$ud" 10
  got=$(sed 's/^10 //' "$sd/reads" | sort | tr '\n' ';')
  eq S4 "$got" 'secure nowhere_sroam_applied;secure nowhere_sroam_tiles;secure sysui_qs_tiles;' "the real list reads its one row"
  # S4z: a list with no usable row, or no list, keeps the record.
  printf '# nothing\nglobal x\n' > "$tl"
  fresh; marked; printf 'secure sysui_qs_tiles kept\n' > "$rec"
  sc SROAM_LIST="$tl" sroam_seal_capture "$ud" 10
  eq S4z "$(cat "$rec")" 'secure sysui_qs_tiles kept' "a list with no usable row keeps the record"
  fresh; marked; printf 'secure sysui_qs_tiles kept\n' > "$rec"
  sc SROAM_LIST="$t/no-such-list" sroam_seal_capture "$ud" 10
  eq S4z "$(cat "$rec")" 'secure sysui_qs_tiles kept' "no list keeps the record"
  rm -rf "$ud"; mkdir -p "$ud"; sc sroam_seal_capture "$ud" 10; res S4z $? "no chooser dir returns 0"

  # S5: the merge.
  fresh
  eq S5 "$(sc sroam_merge_tiles 'a,b,c' 'a,?custom(x/y),b')" 'a,custom(x/y),b,c' "a waiting tile goes back after its predecessor"
  eq S5 "$(sc sroam_merge_tiles 'a,b' '?custom(x/y),a,b')" 'custom(x/y),a,b' "a first-position tile stays first"
  eq S5 "$(sc sroam_merge_tiles 'a,custom(x/y),b' 'a,?custom(x/y),b')" 'a,custom(x/y),b' "a tile already live is not doubled"
  eq S5 "$(sc sroam_merge_tiles 'b,c' 'gone,b,?custom(x/y),?custom(z/y),c')" 'b,custom(x/y),custom(z/y),c' "two waiting tiles keep their order"
  eq S5 "$(sc sroam_merge_tiles 'c' 'gone,?custom(x/y),c')" 'custom(x/y),c' "a predecessor the user removed: first"
  eq S5 "$(sc sroam_merge_tiles 'a' 'a,gone,b')" 'a' "a stored tile with no mark is not put back"
  # S5d: the merge with a $.
  x=$(sc sroam_merge_tiles 'a,b' 'a,?custom(com.x/.Outer$Tile),b'); res S5d $? "the merge with \$ exits 0"
  eq S5d "$x" "$INNER" "the merge keeps \$ byte for byte"
  x=$(sc sroam_merge_tiles "$INNER" ''); res S5d $? "an empty annotated row exits 0"
  eq S5d "$x" "$INNER" "an empty annotated row returns the live value"
  # S5r: the merge refuses a value outside the set.
  for x in 'a b|' 'a?b|' 'a|a b' 'a|x?y' 'a|??a'; do
    got=$(sc sroam_merge_tiles "${x%%|*}" "${x#*|}"); want=$?
    if [ "$want" != 0 ] && [ -z "$got" ]; then res S5r 0 "refused"; else res S5r 1 "accepted '$x' (rc $want, '$got')"; fi
  done
  fresh; marked; setv secure.sysui_qs_tiles 'a,b'; setv secure.nowhere_sroam_tiles 'a,?bad tile'; printf 'secure sysui_qs_tiles old\n' > "$rec"
  sc sroam_seal_capture "$ud" 10
  eq S5r "$(cat "$rec")" 'secure sysui_qs_tiles old' "a refused merge carries the old row"

  # S6: the surface.
  fresh; printf 'idle=5' > "$pf"; printf 'secure sysui_qs_tiles a,b\nsecure off_list v\nglobal sysui_qs_tiles v\n' > "$rec"
  sc sroam_surface "$ud" "$pf"
  eq S6 "$(cat "$pf")" "$(printf 'idle=5\nsroam=secure sysui_qs_tiles a,b')" "only listed rows become sroam= lines, on a line of their own"
  fresh; printf 'idle=5\n' > "$pf"; sc sroam_surface "$ud" "$pf"
  eq S6 "$(cat "$pf")" 'idle=5' "an absent record adds nothing"
  fresh; : > "$rec"; sc sroam_surface "$ud" "$pf"
  eq S6 "$(cat "$pf")" '' "an empty record adds nothing"
  fresh; printf 'secure sysui_qs_tiles a b?\n' > "$rec"; sc sroam_surface "$ud" "$pf"
  eq S6 "$(cat "$pf")" 'sroam=secure sysui_qs_tiles a b?' "a malformed listed row is still surfaced"
  fresh; printf 'secure sysui_qs_tiles a,b\n' > "$rec"; sc SROAM_LIST="$t/no-such-list" sroam_surface "$ud" "$pf"
  eq S6 "$(cat "$pf")" '' "no list surfaces nothing"

  # S7: logs carry counts only.
  fresh; marked; setv secure.sysui_qs_tiles "secretwifi,$INNER"; setv secure.nowhere_sroam_tiles 'a,?custom(secretpkg/y)'
  sc sroam_seal_capture "$ud" 10; sc sroam_surface "$ud" "$pf"
  x=$(cat "$lg")
  case "$x" in *secret*|*custom*|*com.x*|*Outer*) res S7 1 "a tile reached the log" ;; *) res S7 0 "no tile text in the log" ;; esac
  case "$x" in *'rows=1 captured=1'*) res S7 0 "the seal logs counts" ;; *) res S7 1 "the seal logs no counts" ;; esac
  fresh; marked; setv secure.sysui_qs_tiles 'secret tile'
  sc sroam_seal_capture "$ud" 10
  x=$(cat "$lg"); case "$x" in *secret*) res S7 1 "a refused value reached the log" ;; *) res S7 0 "a refused value stays out of the log" ;; esac

  # S9: the set table.
  got=$(LONG=$(printf '%8192s' '' | tr ' ' a) "$sh" -c '. "$1"
    i=32
    while [ "$i" -le 126 ]; do
      c=$(printf "%b" "\\0$(printf %o "$i")")
      if sroam_tiles_valid "$c"; then v=1; else v=0; fi
      printf "%02x %s\n" "$i" "$v"
      i=$((i+1))
    done
    if sroam_tiles_valid "$LONG"; then echo "len8192 1"; else echo "len8192 0"; fi
    if sroam_tiles_valid "${LONG}a"; then echo "len8193 1"; else echo "len8193 0"; fi
    if sroam_tiles_valid ""; then echo "empty 1"; else echo "empty 0"; fi' x "$lib")
  eq S9 "$got" "$(expected_table)" "the shell set is exactly the 70 characters and the 8192 cap"
  printf '%s\n' "$got" > "$W/table.$(basename "$sh")"

  rm -rf "$t"
}

# chain_cases <lib> <shell> <class dir>: E, a value with a $ in its class crosses the capture, the surface and the apply.
chain_cases() {
  local lib="$1" sh="$2" cls="$3" t ud rec sd lg pf
  t=$(mktemp -d -p "$W") || return 2
  ud="$t/user"; rec="$ud/com.nowhere.chooser/files/nowhere-settings-roam"; sd="$t/set"; lg="$t/roam.log"; pf="$t/prefs.out"
  mkdir -p "$ud/com.nowhere.chooser/files" "$sd"; : > "$lg"; : > "$pf"
  sc() { LOG="$lg" SETDIR="$sd" SROAM_LIST="$LIST" "$sh" -c '. "$1"; shift; "$@"' x "$lib" "$@"; }
  jr() { "$JAVA" -Djava.io.tmpdir="$W" -cp "$cls" com.nowhere.chooser.SettingsRoamCases "$@"; }
  eq() { if [ "$2" = "$3" ]; then printf 'ok %s [%s] %s\n' "$1" "$sh" "$4"; else printf "FAIL %s [%s] %s (got '%s')\n" "$1" "$sh" "$4" "$2"; fi; }

  # E1: seal, surface, apply. A next seal of the live value leaves the record unchanged.
  printf 1 > "$sd/secure.nowhere_sroam_applied"; printf '%s' "$INNER" > "$sd/secure.sysui_qs_tiles"
  sc sroam_seal_capture "$ud" 10; sc sroam_surface "$ud" "$pf"
  eq E1 "$(cat "$pf")" "sroam=secure sysui_qs_tiles $INNER" "the record surfaces byte for byte"
  rm -f "$sd"/secure.*
  jr --apply "$pf" "$LIST" com.x "$sd"
  eq E1 "$(cat "$sd/secure.sysui_qs_tiles" 2>/dev/null)" "$INNER" "the put value is the captured value"
  eq E1 "$(cat "$sd/secure.nowhere_sroam_applied" 2>/dev/null)" 1 "the marker is set"
  sc sroam_seal_capture "$ud" 10
  eq E1 "$(cat "$rec")" "secure sysui_qs_tiles $INNER" "a next seal leaves the record unchanged"

  # E2: the same with the package missing: dropped from live, kept stored, back in live when it lands.
  rm -f "$sd"/secure.*
  jr --apply "$pf" "$LIST" - "$sd"
  eq E2 "$(cat "$sd/secure.sysui_qs_tiles" 2>/dev/null)" 'a,b' "the live value lacks the missing package's tile"
  sc sroam_seal_capture "$ud" 10
  eq E2 "$(cat "$rec")" "secure sysui_qs_tiles $INNER" "the seal keeps it stored, at its position"
  jr --reconcile "$LIST" com.x "$sd"
  eq E2 "$(cat "$sd/secure.sysui_qs_tiles" 2>/dev/null)" "$INNER" "the landing puts it back in the live value"
  eq E2 "$(cat "$sd/secure.nowhere_sroam_tiles" 2>/dev/null)" '' "nothing waits after the landing"
  sc sroam_seal_capture "$ud" 10
  eq E2 "$(cat "$rec")" "secure sysui_qs_tiles $INNER" "a seal after the landing leaves the record unchanged"
  rm -rf "$t"
}

# roamd_pins <roamd>: S8.
roamd_pins() {
  local f="$1" n prev fn body
  n=$(grep -c '^ *sroam_seal_capture "\$USERDIR" "\$uid"' "$f")
  [ "$n" = 1 ] && echo "ok S8 one capture call" || echo "FAIL S8 capture call count $n"
  prev=$(grep -B1 '^ *sroam_seal_capture "\$USERDIR" "\$uid"' "$f" | head -1)
  case "$prev" in *'sync_seal_capture "$USERDIR" "$uid"'*) echo "ok S8 the capture follows sync_seal_capture" ;; *) echo "FAIL S8 the capture does not follow sync_seal_capture" ;; esac
  n=$(sed -n '/^  out)$/,$p' "$f" | grep -c '^ *sroam_seal_capture "\$USERDIR" "\$uid"')
  [ "$n" = 1 ] && echo "ok S8 the capture call is in out" || echo "FAIL S8 the capture call is not in out"
  n=$(grep -c '^ *sroam_surface "\$USERDIR" "\$STATE/prefs.out"' "$f")
  [ "$n" = 1 ] && echo "ok S8 one surface call" || echo "FAIL S8 surface call count $n"
  n=$(sed -n '/^  in)$/,/^  out)$/p' "$f" | grep -c '^ *sroam_surface "\$USERDIR" "\$STATE/prefs.out"')
  [ "$n" = 1 ] && echo "ok S8 the surface call is in in" || echo "FAIL S8 the surface call is not in in"
  prev=$(grep -B1 '^ *sroam_surface "\$USERDIR" "\$STATE/prefs.out"' "$f" | head -1)
  case "$prev" in *'tz_surface "$USERDIR" "$STATE/prefs.out"'*) echo "ok S8 the surface follows tz_surface" ;; *) echo "FAIL S8 the surface does not follow tz_surface" ;; esac
  n=$(grep -cF '_./(),$-]*' "$f")
  [ "$n" = 1 ] && echo "ok S8 one function holds the set" || echo "FAIL S8 the set pattern occurs $n times"
  for fn in sroam_seal_capture sroam_merge_tiles; do
    body=$(sed -n "/^$fn() {\$/,/^}\$/p" "$f")
    case "$body" in
      *sroam_tiles_valid*|*sroam_merge_tiles*) echo "ok S8 $fn reaches sroam_tiles_valid" ;;
      *) echo "FAIL S8 $fn does not reach sroam_tiles_valid" ;;
    esac
  done
}

# --- the Java half -------------------------------------------------------------------------------------------------
# compile_java <SettingsRoam.java> <out dir>: rc 0 or prints why.
compile_java() {
  local src="$1" out="$2" d cm
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/com/nowhere/chooser" "$out"
  cp "$src" "$d/com/nowhere/chooser/SettingsRoam.java" || { rm -rf "$d"; return 3; }
  cp "$CASES" "$d/com/nowhere/chooser/SettingsRoamCases.java"
  if ! cm=$("$JAVAC" -J-Djava.io.tmpdir="$W" -encoding UTF-8 -d "$out" "$d"/com/nowhere/chooser/*.java 2>&1); then
    printf '%s\n' "$cm"; rm -rf "$d"; return 3
  fi
  rm -rf "$d"
}

# --- source pins ---------------------------------------------------------------------------------------------------
# pins <dir of copies>: ChooserActivity.java AppInstallReceiver.java NowhereApp.java SettingsRoamLive.java SettingsRoam.java
# settings-roam.list endospore.mk diaspore.mk. Prints `ok <id> ...` or `FAIL <id> ...`.
pin() { if [ "$2" = 0 ]; then echo "ok $1 $3"; else echo "FAIL $1 $3"; fi; }
pins() {
  local d="$1" x n arp
  x=$(grep -A1 '^ *applyRoamedPrefs();' "$d/ChooserActivity.java" | tail -1)
  case "$x" in *'applyRoamedSettings(uid);'*) pin pin-call 0 "applyRoamedSettings(uid) follows applyRoamedPrefs()" ;; *) pin pin-call 1 "applyRoamedSettings(uid) does not follow applyRoamedPrefs()" ;; esac
  n=$(grep -cF 'SettingsRoamLive.applyAtSignIn(this, uid, roamedPrefLines);' "$d/ChooserActivity.java")
  [ "$n" = 1 ]; pin pin-call $? "applyRoamedSettings calls applyAtSignIn with the read's lines"
  arp=$(awk '/private void applyRoamedPrefs\(\)/ { on = 1 } on { print } on && /^    }$/ { exit }' "$d/ChooserActivity.java")
  x=$(printf '%s\n' "$arp" | grep -F 'shown.add(l)' || true)
  case "$x" in *'!l.startsWith(SettingsRoam.PREF_PREFIX)'*) pin pin-shown 0 "the logged raw drops sroam= lines" ;; *) pin pin-shown 1 "a sroam= line reaches the logged raw" ;; esac
  # The field takes the read's result BEFORE the null arm turns a failed read into an empty list.
  x=$(printf '%s\n' "$arp" | grep -nE 'roamedPrefLines = lines;|if \(lines == null\) \{' | cut -d: -f2- | tr -d ' ' | tr '\n' ';')
  [ "$x" = 'roamedPrefLines=lines;;if(lines==null){;' ]; pin pin-lines $? "a failed read stays null for the apply"
  x=$(awk '/ACTION_PACKAGE_REPLACED\.equals\(intent\.getAction\(\)\)/ { on = 1 } on { print } on && /return;$/ && !/getContext|isEmpty/ { exit }' "$d/AppInstallReceiver.java")
  case "$x" in *'SettingsRoamLive.reconcile(context);'*) pin pin-replaced 0 "the REPLACED arm reconciles" ;; *) pin pin-replaced 1 "the REPLACED arm does not reconcile" ;; esac
  x=$(grep -A1 'if (!replacing) recaptureCode(context, pkg, "new");' "$d/AppInstallReceiver.java" | tail -1)
  case "$x" in *'SettingsRoamLive.reconcile(context);'*) pin pin-added 0 "the ADDED arm reconciles" ;; *) pin pin-added 1 "the ADDED arm does not reconcile" ;; esac
  grep -qF 'new Thread(() -> SettingsRoamLive.reconcile(this), "nowhere-settings-roam").start();' "$d/NowhereApp.java"
  pin pin-birth $? "process birth reconciles, off the main thread"
  grep -qF 'vendor/endospore/etc/settings-roam.list:$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere/settings-roam.list' "$d/endospore.mk"
  pin pin-mk $? "endospore bakes the list"
  grep -qF 'vendor/diaspore/etc/settings-roam.list:$(TARGET_COPY_OUT_SYSTEM)/etc/nowhere/settings-roam.list' "$d/diaspore.mk"
  pin pin-mk $? "diaspore bakes the list"
  x=$(grep -vE '^[[:space:]]*(#|$)' "$d/settings-roam.list")
  [ "$x" = 'secure sysui_qs_tiles tiles' ]; pin pin-list $? "the list holds exactly its one row"
  x=$(grep -F 'Log.' "$d/SettingsRoamLive.java" | grep -E '\+ *(waiting|value|lines|st|key)\b' || true)
  [ -z "$x" ]; pin pin-nolog $? "no Log line in SettingsRoamLive carries a value"
  x=$(grep -E 'replaceAll|replaceFirst|appendReplacement' "$d/SettingsRoam.java" || true)
  [ -z "$x" ]; pin pin-noreplace $? "SettingsRoam.java has no regex replacement, where \$ is a group reference"
  grep -qF 'static final String LIST_PATH = "/system/etc/nowhere/settings-roam.list";' "$d/SettingsRoam.java"
  pin pin-path $? "the chooser reads the path the images bake"
  grep -qF '${SROAM_LIST:-/system/etc/nowhere/settings-roam.list}' "$ROAMD"
  pin pin-path $? "roamd reads the path the images bake"
}

copy_pin_tree() {  # copy_pin_tree <dest>
  local d="$1"
  mkdir -p "$d" || return 1
  cp "$SRC/ChooserActivity.java" "$SRC/AppInstallReceiver.java" "$SRC/NowhereApp.java" "$SRC/SettingsRoamLive.java" "$SRC/SettingsRoam.java" \
     "$LIST" "$ROOT/editions/endospore/endospore.mk" "$ROOT/editions/diaspore/diaspore.mk" "$d/"
}

# --- the plain run -------------------------------------------------------------------------------------------------
RC=0
report() {  # report <title> <output>: prints it and counts its FAILs.
  local n
  printf '== %s\n' "$1"
  printf '%s\n' "$2" | grep -E '^FAIL ' || true
  n=$(printf '%s\n' "$2" | grep -c '^ok ' || true)
  printf '   %s ok\n' "$n"
  case "$2" in *'FAIL '*) RC=1 ;; '') echo "FAIL $1 printed nothing"; RC=1 ;; esac
}

LIB="$W/roamd-lib.sh"
if ! make_lib "$ROAMD" "$LIB"; then echo "FAIL EXTRACTION: the settings-roam functions are not in $ROAMD"; exit 1; fi

OUT="$W/classes"
if ! cj=$(compile_java "$JSUT" "$OUT"); then printf '%s\n' "$cj"; echo "FAIL J0 SettingsRoam does not compile"; exit 1; fi

report "Java cases" "$("$JAVA" -Djava.io.tmpdir="$W" -cp "$OUT" com.nowhere.chooser.SettingsRoamCases 2>&1)"
for sh in $SHELLS; do
  report "shell cases under $sh" "$(shell_cases "$LIB" "$sh" 2>&1)"
  report "chain cases under $sh" "$(chain_cases "$LIB" "$sh" "$OUT" 2>&1)"
done
report "roamd pins" "$(roamd_pins "$ROAMD")"
PT="$W/pins"; copy_pin_tree "$PT" || { echo "FAIL pins: a pinned file is missing"; exit 1; }
report "source pins" "$(pins "$PT")"

# P1: every shell's table, the Java table and the expected table are byte-identical.
JT=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$OUT" com.nowhere.chooser.SettingsRoamCases --table)
ET=$(expected_table)
if [ "$JT" = "$ET" ]; then echo "ok P1 the Java table equals the set"; else echo "FAIL P1 the Java table differs from the set"; RC=1; fi
for sh in $SHELLS; do
  if [ "$(cat "$W/table.$(basename "$sh")" 2>/dev/null)" = "$ET" ]; then echo "ok P1 [$sh] the shell table equals the set"; else echo "FAIL P1 [$sh] the shell table differs"; RC=1; fi
done

if [ "$MUTATE" = no ]; then
  [ "$RC" = 0 ] && echo "suite passed" || echo "suite FAILED"
  exit "$RC"
fi
[ "$RC" = 0 ] || { echo "the suite fails on the real code: no mutant run"; exit 1; }

# --- mutants -------------------------------------------------------------------------------------------------------
MRC=0; KILLED=0
applied() {  # applied <orig> <mutant> <label>: 0 when the edit changed the file.
  if [ ! -s "$2" ] || cmp -s "$1" "$2"; then echo "  ⚠ NOT APPLIED  $3 -- the edit changed nothing; NOT a conviction"; MRC=1; return 1; fi
}
verdict() {  # verdict <label> <named case> <output> [<shell>...]: with shells, the case must fail under each one.
  local label="$1" id="$2" out="$3" sh miss=""
  shift 3
  if [ "$#" = 0 ]; then
    case "$out" in *"FAIL $id "*) ;; *) miss=" (no FAIL $id)" ;; esac
  else
    for sh in "$@"; do
      case "$out" in *"FAIL $id [$sh]"*) ;; *) miss="$miss (no FAIL $id under $sh)" ;; esac
    done
  fi
  if [ -z "$miss" ]; then echo "  CONVICTED  $label -- FAIL $id"; KILLED=$((KILLED+1)); else echo "  SURVIVED   $label$miss"; MRC=1; fi
}
# shmut <label> <named case> <sed args...>: a broken roamd, the shell cases under each shell.
shmut() {
  local label="$1" id="$2" m lib sh out=""
  shift 2
  m=$(mktemp -p "$W"); lib=$(mktemp -p "$W")
  sed "$@" "$ROAMD" > "$m"
  applied "$ROAMD" "$m" "$label" || { rm -f "$m" "$lib"; return; }
  if ! make_lib "$m" "$lib"; then echo "  ⚠ NOT APPLIED  $label -- extraction failed; NOT a conviction"; MRC=1; rm -f "$m" "$lib"; return; fi
  for sh in $SHELLS; do out="$out
$(shell_cases "$lib" "$sh" 2>&1)"; done
  verdict "$label" "$id" "$out" $SHELLS
  rm -f "$m" "$lib"
}
# pinmut_roamd <label> <named case> <sed args...>: a broken roamd against S8.
pinmut_roamd() {
  local label="$1" id="$2" m
  shift 2
  m=$(mktemp -p "$W")
  sed "$@" "$ROAMD" > "$m"
  applied "$ROAMD" "$m" "$label" || { rm -f "$m"; return; }
  verdict "$label" "$id" "$(roamd_pins "$m")"
  rm -f "$m"
}
# jmut <label> <named case> <sed args...>: a broken SettingsRoam.java. A mutant that does not compile is a failure.
jmut() {
  local label="$1" id="$2" m cls out
  shift 2
  m=$(mktemp -p "$W"); cls=$(mktemp -d -p "$W")
  sed "$@" "$JSUT" > "$m"
  applied "$JSUT" "$m" "$label" || { rm -rf "$m" "$cls"; return; }
  if ! compile_java "$m" "$cls" >/dev/null; then echo "  ⚠ NO COMPILE  $label -- NOT a conviction"; MRC=1; rm -rf "$m" "$cls"; return; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -cp "$cls" com.nowhere.chooser.SettingsRoamCases 2>&1)
  verdict "$label" "$id" "$out"
  rm -rf "$m" "$cls"
}
# pinmut <label> <named case> <file in the pin tree> <sed args...>
pinmut() {
  local label="$1" id="$2" file="$3" d
  shift 3
  d=$(mktemp -d -p "$W"); copy_pin_tree "$d"
  sed -i "$@" "$d/$file"
  applied "$PT/$file" "$d/$file" "$label" || { rm -rf "$d"; return; }
  verdict "$label" "$id" "$(pins "$d")"
  rm -rf "$d"
}
sf() { printf '/^%s() {$/,/^}$/{%s}' "$1" "$2"; }

echo "== mutants"
shmut "M1 drop \$ from the shell set" S1d -e 's/0123456789_\.\/(),\$-\]\*/0123456789_.\/(),-]*/'
shmut "M1b the same, the merge case" S5d -e 's/0123456789_\.\/(),\$-\]\*/0123456789_.\/(),-]*/'
shmut "M2 no cap in the shell set" S9 -e 's/^  \[ "\${#1}" -le 8192 \]$/  :/'
shmut "M3 ? in the shell set" S3r -e 's/0123456789_\.\/(),\$-\]\*/0123456789_.\/(),?$-]*/'
shmut "M4 allowlist bypassed in the capture" S4 -e "$(sf sroam_seal_capture 's/^    sroam_row_ok .*$/    :/')"
shmut "M5 allowlist bypassed in the surface" S6 -e "$(sf sroam_surface 's/^    sroam_row_ok .*$/    :/; s/^  done < "\$_list"$/  done < "$_f"/')"
shmut "M6 the merge loses a waiting tile (custom tile dropped from storage)" S5 -e "$(sf sroam_merge_tiles 's/^          \[ "\$_w" != "\$_t" \] || continue$/          continue/')"
shmut "M7 the capture skips the merge (custom tile dropped from storage)" S1m -e "$(sf sroam_seal_capture 's/_m=\$(sroam_merge_tiles "\$_v" "\$_ann")/_m=$_v/')"
shmut "M8 the capture ignores the marker" S2 -e "$(sf sroam_seal_capture 's/^  if \[ "\$_v" != 1 \]; then$/  if false; then/')"
shmut "M9 the capture logs the record" S7 -e "$(sf sroam_seal_capture 's/rows=\$_rows captured/rows=$_rows $_new captured/')"
shmut "M10 a null read is captured" S3 -e "$(sf sroam_seal_capture "s/''|null|\*/''|*/")"
shmut "M11 the surface drops a malformed row" S6 -e "$(sf sroam_surface 's/^    \[ -n "\$_l" \] || continue$/    sroam_tiles_valid "${_l##* }" || continue/')"
shmut "M12 a list with no row empties the record" S4z -e "$(sf sroam_seal_capture 's/^  if \[ "\$_rows" -eq 0 \]; then$/  if false; then/')"
shmut "M13 a refused merge writes the live value" S5r -e "$(sf sroam_seal_capture 's/then _v=\$_m; else _v=""; _ref=\$((_ref+1)); fi/then _v=$_m; else _ref=$((_ref+1)); fi/')"
pinmut_roamd "R1 the capture call removed from out" S8 -e '/^ *sroam_seal_capture "\$USERDIR" "\$uid"/d'
pinmut_roamd "R2 the surface call removed from in" S8 -e '/^ *sroam_surface "\$USERDIR" "\$STATE\/prefs.out"/d'
jmut "J-M1 drop \$ from the Java set" J1 -e 's/0-9_\.\/(),\$-\]+/0-9_.\/(),-]+/'
jmut "J-M2 no cap in tilesValid" J10 -e 's/value\.length() <= TILE_VALUE_MAX && //'
jmut "J-M3 A-z in the Java set" J10 -e 's/\[A-Za-z0-9_\.\/(),\$-\]+/[A-z0-9_.\/(),$-]+/'
jmut "J-M4 marker set after a malformed value" J9 -e 's/if (res\.failed == 0 && res\.malformed == 0)/if (res.failed == 0)/'
jmut "J-M5 allowlist bypassed in the apply" J6 -e 's/^            if (row == null) continue;$/            if (row == null) row = new Row(f[0], f[1], null);/'
jmut "J-M6 the apply is skipped" J1 -e 's/^        Result res = new Result();$/        Result res = new Result(); if (res != null) return res;/'
jmut "J-M7 a custom tile dropped from the waiting row" J2 -e 's/out\.add(pkg != null \&\& !installed\.test(pkg) ? "?" + t : t);/if (pkg == null || installed.test(pkg)) out.add(t);/'
jmut "J-M8 marker set after a failed put" J7 -e 's/if (res\.failed == 0 && res\.malformed == 0)/if (res.malformed == 0)/'
jmut "J-M9 marker set on a null read" J5 -e 's/^        if (lines == null || rows == null || rows\.isEmpty()) return res;$/        if (lines == null) { store.put(SECURE, APPLIED_KEY, "1"); return res; }/'
jmut "J-M10 reconcile does not rewrite the row" J3 -e '/^        store\.put(SECURE, TILES_KEY, waiting == 0/d'
jmut "J-M11 an all-waiting list reaches the live row" J8 -e '/^            if (live\.isEmpty()) continue;$/d'
jmut "J-M12 a Global row passes the list" J6 -e '/^            if (!SECURE\.equals(f\[0\]) && !SYSTEM\.equals(f\[0\])) continue;$/d'
pinmut "C1 the apply call removed" pin-call ChooserActivity.java -e '/^ *applyRoamedSettings(uid);/d'
pinmut "C2 the shown filter dropped (tile text logged)" pin-shown ChooserActivity.java -e 's/ \&\& !l\.startsWith(SettingsRoam\.PREF_PREFIX)//'
pinmut "C3 a failed read reaches the apply as empty" pin-lines ChooserActivity.java -e '/^            roamedPrefLines = lines;$/d'
pinmut "C4 the REPLACED-arm call removed" pin-replaced AppInstallReceiver.java -e '/recaptureCode(context, up, "update");/{n;d}'
pinmut "C5 the ADDED-arm call removed" pin-added AppInstallReceiver.java -e '/if (!replacing) recaptureCode(context, pkg, "new");/{n;d}'
pinmut "C6 the process-birth call removed" pin-birth NowhereApp.java -e '/SettingsRoamLive\.reconcile(this)/d'
pinmut "C7 endospore does not bake the list" pin-mk endospore.mk -e '/settings-roam\.list/d'
pinmut "C8 diaspore does not bake the list" pin-mk diaspore.mk -e '/settings-roam\.list/d'
pinmut "C9 a second row on the list" pin-list settings-roam.list -e '$a secure other_row'
pinmut "C10 a value in a Log line" pin-nolog SettingsRoamLive.java -e 's/"settings roam: " + landed/"settings roam: " + waiting/'

# A control that must SURVIVE: a log wording no case reads. A convicted control means the suite fails on anything.
ctl=$(mktemp -p "$W"); ctllib=$(mktemp -p "$W")
sed -e "$(sf sroam_surface 's/surfaced \$_n row(s)/added $_n row(s)/')" "$ROAMD" > "$ctl"
if applied "$ROAMD" "$ctl" "CONTROL" && make_lib "$ctl" "$ctllib"; then
  out=""
  for sh in $SHELLS; do out="$out
$(shell_cases "$ctllib" "$sh" 2>&1)"; done
  case "$out" in
    *'FAIL '*) echo "  CONTROL CONVICTED -- the suite fails on a harmless edit"; MRC=1 ;;
    *) echo "  control survived" ;;
  esac
fi

if [ "$MRC" = 0 ]; then echo "mutants: all $KILLED convicted"; else echo "mutants: FAILED"; fi
exit "$MRC"
