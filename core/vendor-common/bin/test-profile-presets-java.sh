#!/usr/bin/env bash
# test-profile-presets-java.sh [--mutate] -- the profile presets table as code, run under javac (NWP-20261119-12).
#
# WHY THIS IS COMMITTED. Q080 (DECIDED 2026-10-20, docs/product-decisions.md) asks for "a test that fails when a
# qualifying setting has no value in every preset"; the table was approved 2026-10-31 (docs/profile-presets.md
# section (b)). Without a pin, the picker hand-copies fifty values out of a markdown table, one drifts (Zero's nApps
# left at On-demand, Standard's wipe at 6 h), and a "Standard" profile is no longer today's defaults. ProfilePresets is
# a pure class with no android.* import, compiled here with its cases. Three source checks pin what the cases cannot:
#   DOC PIN       every row of section (b) -- label, options, today's default, the five columns -- equals the class,
#                 row for row, and the class has no row the doc lacks;
#   DEFAULTS PIN  Standard equals the code's defaults (IDLE_LOGOFF_MS, WipeChoice DEFAULT, RECLAIM_DEFAULT_MS, the
#                 cfg/cfgStatic fallbacks, holdlock and holdaudio each on unless "0");
#   STORAGE PIN   each row's stored values are what the screens write (showIdlePicker's mins, the RECLAIM_* values,
#                 WipeChoice.LABELS, appDefaultRow's and showConfiguration's label -> value pairs, the CFG_* keys).
# Comment lines (//, *, /*) and trailing // comments never count as code.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-profile-presets-java.sh            # the cases + the three pins
#   bash test-profile-presets-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/ProfilePresets.java"
CHA="$SRC/ChooserActivity.java"
PA="$SRC/ProfileActivity.java"
WC="$SRC/WipeChoice.java"
RP="$SRC/RoamedPrefs.java"   # NWP-20261119-21: the gate's lock prefs are parsed here, holdlock and holdaudio included
DOC="$root/docs/profile-presets.md"
CASES="$root/core/chooser/tests/profile-presets/ProfilePresetsCases.java"
HOST_JDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$HOST_JDK/javac" ] && [ -x "$HOST_JDK/java" ]; then
  JAVAC="$HOST_JDK/javac"; JAVA="$HOST_JDK/java"
else
  echo "FAIL: no javac -- not on PATH and not at $HOST_JDK. This suite does not skip: install a JDK or run it on the" \
       "build VM." >&2
  exit 2
fi
"$JAVAC" -version || { echo "FAIL: $JAVAC does not run" >&2; exit 2; }
for f in "$CASES" "$CHA" "$PA" "$WC" "$RP" "$DOC"; do [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }; done

# suite <ProfilePresets.java> <doc-dump out> <store-dump out> -> 0 pass, 1 a case failed or the class is missing (the
# only codes that convict a mutant), 3 the class or the cases did not compile. The two dumps feed the pins.
suite() {
  local src="$1" ddump="$2" sdump="$3" d out rc
  : > "$ddump"; : > "$sdump"
  [ -f "$src" ] || { echo "  FAIL  ProfilePresets.java does not exist (the presets table is not code)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/ProfilePresets.java"
  cp "$CASES" "$d/src/com/nowhere/chooser/ProfilePresetsCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ProfilePresetsCases 2>&1); rc=$?
  echo "$out"
  if [ "$rc" -eq 0 ]; then
    "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ProfilePresetsCases --dump-doc > "$ddump" || rc=1
    "$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.ProfilePresetsCases --dump-store > "$sdump" || rc=1
  fi
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  ProfilePresetsCases" >&2
  return 1
}

# doctable <profile-presets.md> -> section (b)'s rows as TSV: label, options, today's default, then the five presets
# (the Source column is dropped). Rows run from after the header's |--- line to the first blank line. Exit 1 when the
# header is missing, no row is found, or a row does not have exactly nine cells.
doctable() {
  awk '
    /^## \(b\) The table/ { s = 1; next }
    s == 1 && /^\| Screen > label \|/ { s = 2; next }
    s == 2 && /^\|---/ { s = 3; next }
    s == 3 && /^[[:space:]]*$/ { exit }
    s == 3 {
      n = split($0, c, "|")
      if (n != 11 || c[1] != "" || c[11] != "") { bad = 1; exit }
      for (i = 2; i <= 10; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", c[i]) }
      print c[2] "\t" c[3] "\t" c[4] "\t" c[6] "\t" c[7] "\t" c[8] "\t" c[9] "\t" c[10]
      rows++
    }
    END { if (bad || !rows) exit 1 }' "$1"
}

# docpin <profile-presets.md> <doc-dump> -> 0 when the class equals section (b) row for row, 1 (with the diff) when not.
docpin() {
  local doc="$1" dump="$2" t dif
  t=$(mktemp -p "$W") || return 1
  doctable "$doc" > "$t" || { echo "  FAIL  DOC PIN: no well-formed section (b) table in $doc" >&2; return 1; }
  [ -s "$dump" ] || { echo "  FAIL  DOC PIN: the class gave no rows" >&2; return 1; }
  local rc
  dif=$(diff "$t" "$dump"); rc=$?
  [ "$rc" -eq 0 ] || { echo "  FAIL  DOC PIN: ProfilePresets differs from docs/profile-presets.md section (b) (< doc, > class):" >&2
                       printf '%s\n' "$dif" >&2; return 1; }
  return 0
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }

# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}

# sv <store-dump> <key> <field> -> a field of the class's row (2 values, 3 labels, 4 Standard); exit 1 when no row.
sv() { awk -F'\t' -v k="$2" -v n="$3" '$1 == k { print $n; f = 1 } END { exit !f }' "$1"; }

# has <text> <fixed string> -> 0 when the text holds the line fragment.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# hasre <text> <ERE> -> 0 when a line of the text matches (grep -c reads all of its input, so no pipe is cut short).
hasre() { local c; c=$(printf '%s\n' "$1" | grep -cE -- "$2"); [ "${c:-0}" -gt 0 ]; }

# strarr <text> -> the "..." literals of the text, joined by "; ".
strarr() { printf '%s\n' "$1" | grep -oE '"[^"]*"' | sed -E 's/^"|"$//g' | awk '{ printf "%s%s", (NR > 1 ? "; " : ""), $0 } END { print "" }'; }

# reclaim_ms <ProfileActivity code> <NAME> -> the evaluated RECLAIM_<NAME> value; exit 1 when it is not a plain
# product of numbers and RECLAIM_1D.
reclaim_ms() {
  local e one
  e=$(printf '%s\n' "$1" | sed -nE "s/^ *static final long RECLAIM_$2 = ([^;]*);.*/\1/p" | head -1)
  [ -n "$e" ] || return 1
  if has "$e" RECLAIM_1D; then one=$(reclaim_ms "$1" 1D) || return 1; e=${e//RECLAIM_1D/$one}; fi
  e=${e//L/}
  [[ "$e" =~ ^[0-9\ *]+$ ]] || return 1
  echo $(( e ))
}

# codepin <store-dump> <ChooserActivity.java> <ProfileActivity.java> <WipeChoice.java> -> 0 when the DEFAULTS PIN and
# the STORAGE PIN hold, 1 (with the first reason) when not. An extraction that finds nothing is a FAIL.
codepin() {
  local st="$1" cha pa wc v want n cfgb cfgsb sip rcd conf adr k name const key
  cha=$(code "$2"); pa=$(code "$3"); wc=$(code "$4")
  local paf; paf=$(mktemp -p "$W") || return 1
  printf '%s\n' "$pa" > "$paf"
  fail() { echo "  FAIL  $*" >&2; return 1; }

  # DEFAULTS.
  n=$(printf '%s\n' "$cha" | sed -nE 's/.*(private )?static final long IDLE_LOGOFF_MS = ([0-9]+) \* 60 \* 1000L;.*/\2/p')
  [ -n "$n" ] || { fail "DEFAULTS PIN: no IDLE_LOGOFF_MS = <N> * 60 * 1000L; in ChooserActivity"; return 1; }
  v=$(sv "$st" idle 4); [ "$v" = "$n" ] || { fail "DEFAULTS PIN: Standard idle is '$v', IDLE_LOGOFF_MS is $n minutes"; return 1; }
  n=$(printf '%s\n' "$wc" | sed -nE 's/^ *private static final int DEFAULT = ([0-9]+);.*/\1/p')
  [ -n "$n" ] || { fail "DEFAULTS PIN: no DEFAULT = <N>; in WipeChoice"; return 1; }
  v=$(sv "$st" wipe 4); [ "$v" = "$n" ] || { fail "DEFAULTS PIN: Standard wipe is '$v', WipeChoice DEFAULT is $n"; return 1; }
  has "$pa" "static final long RECLAIM_DEFAULT_MS = RECLAIM_3D;" || { fail "DEFAULTS PIN: RECLAIM_DEFAULT_MS is not RECLAIM_3D"; return 1; }
  want=$(reclaim_ms "$pa" 3D) || { fail "DEFAULTS PIN: RECLAIM_3D does not evaluate"; return 1; }
  v=$(sv "$st" reclaim 4); [ "$v" = "$want" ] || { fail "DEFAULTS PIN: Standard reclaim is '$v', RECLAIM_DEFAULT_MS is $want"; return 1; }
  cfgb=$(meth "$paf" cfg); cfgsb=$(meth "$paf" cfgStatic)
  [ -n "$cfgb" ] && [ -n "$cfgsb" ] || { fail "DEFAULTS PIN: cfg( or cfgStatic( not found in ProfileActivity"; return 1; }
  for k in "$cfgb" "$cfgsb"; do
    hasre "$k" '^ *if \(CFG_MEDIA_DEFAULT\.equals\(key\)\) +return "ondemand";$' \
      || { fail "DEFAULTS PIN: cfg/cfgStatic do not fall back to \"ondemand\" for media.default"; return 1; }
    hasre "$k" '^ *if \(CFG_APPS_NAPPS\.equals\(key\)\) +return MODE_AUTO;$' \
      || { fail "DEFAULTS PIN: cfg/cfgStatic do not fall back to MODE_AUTO for nApps"; return 1; }
    hasre "$k" '^ *return APPDEF_OFF;$' \
      || { fail "DEFAULTS PIN: cfg/cfgStatic do not fall back to APPDEF_OFF for the other stores"; return 1; }
  done
  v=$(sv "$st" media.default 4); [ "$v" = ondemand ] || { fail "DEFAULTS PIN: Standard media.default is '$v', the fallback is ondemand"; return 1; }
  has "$pa" 'static final String MODE_AUTO      = "auto";' || { fail "STORAGE PIN: MODE_AUTO is not \"auto\""; return 1; }
  has "$pa" 'static final String MODE_ONDEMAND  = "ondemand";' || { fail "STORAGE PIN: MODE_ONDEMAND is not \"ondemand\""; return 1; }
  has "$pa" 'static final String MODE_INSTALLED = "installed";' || { fail "STORAGE PIN: MODE_INSTALLED is not \"installed\""; return 1; }
  has "$pa" 'static final String APPDEF_OFF = "off";' || { fail "STORAGE PIN: APPDEF_OFF is not \"off\""; return 1; }
  v=$(sv "$st" apps.default.napps 4); [ "$v" = auto ] || { fail "DEFAULTS PIN: Standard nApps is '$v', the fallback is MODE_AUTO"; return 1; }
  for k in play aurora gos other; do
    v=$(sv "$st" "apps.default.$k" 4); [ "$v" = off ] || { fail "DEFAULTS PIN: Standard apps.default.$k is '$v', the fallback is APPDEF_OFF"; return 1; }
  done
  has "$pa" 'holdBox.setChecked(!"0".equals(readPrefValue("holdlock")));' || { fail "DEFAULTS PIN: the install wait is not on unless holdlock=0 (ProfileActivity)"; return 1; }
  has "$(code "$RP")" 'return new Values(idleMs, wipeMs, WipeOnSave.on(wipesaved), !"0".equals(holdlock), !"0".equals(holdaudio));' || { fail "DEFAULTS PIN: the gate does not hold unless holdlock=0 / holdaudio=0 (RoamedPrefs.parse)"; return 1; }
  has "$cha" 'sHoldLockForInstalls = rp.holdLock;' || { fail "DEFAULTS PIN: the gate does not take holdlock from RoamedPrefs.parse (ChooserActivity)"; return 1; }
  has "$pa" 'setPref("holdlock", holdBox.isChecked() ? "" : "0");' || { fail "STORAGE PIN: the install wait does not write \"\" for On and \"0\" for Off"; return 1; }
  v=$(sv "$st" holdlock 2); [ "$v" = ",0" ] || { fail "STORAGE PIN: holdlock's values are '$v', want ',0' (On, Off)"; return 1; }
  v=$(sv "$st" holdlock 4); [ "$v" = "" ] || { fail "DEFAULTS PIN: Standard holdlock is '$v', the default is On (\"\")"; return 1; }
  # NWP-20261124-17: the audio wait, the same rule.
  has "$pa" 'audioBox.setChecked(!"0".equals(readPrefValue("holdaudio")));' || { fail "DEFAULTS PIN: the audio wait is not on unless holdaudio=0 (ProfileActivity)"; return 1; }
  has "$cha" 'sHoldLockForAudio = rp.holdAudio;' || { fail "DEFAULTS PIN: the gate does not take holdaudio from RoamedPrefs.parse (ChooserActivity)"; return 1; }
  has "$pa" 'setPref("holdaudio", audioBox.isChecked() ? "" : "0");' || { fail "STORAGE PIN: the audio wait does not write \"\" for On and \"0\" for Off"; return 1; }
  v=$(sv "$st" holdaudio 2); [ "$v" = ",0" ] || { fail "STORAGE PIN: holdaudio's values are '$v', want ',0' (On, Off)"; return 1; }
  v=$(sv "$st" holdaudio 4); [ "$v" = "" ] || { fail "DEFAULTS PIN: Standard holdaudio is '$v', the default is On (\"\")"; return 1; }

  # STORAGE.
  sip=$(meth "$paf" showIdlePicker)
  [ -n "$sip" ] || { fail "STORAGE PIN: showIdlePicker( not found"; return 1; }
  want=$(printf '%s\n' "$sip" | sed -nE 's/^ *final int\[\] mins = \{ *([0-9, ]*) *\};$/\1/p' | tr -d ' ')
  [ -n "$want" ] || { fail "STORAGE PIN: no mins array in showIdlePicker"; return 1; }
  v=$(sv "$st" idle 2); [ "$v" = "$want" ] || { fail "STORAGE PIN: idle's values are '$v', showIdlePicker's mins are '$want'"; return 1; }
  want=$(strarr "$(printf '%s\n' "$sip" | grep -E '^ *final String\[\] labels = \{')")
  v=$(sv "$st" idle 3); [ -n "$want" ] && [ "$v" = "$want" ] || { fail "STORAGE PIN: idle's labels are '$v', showIdlePicker's are '$want'"; return 1; }
  want=""
  for n in NEVER 1D 3D 1W; do
    k=$(reclaim_ms "$pa" "$n") || { fail "STORAGE PIN: RECLAIM_$n does not evaluate"; return 1; }
    want="$want${want:+,}$k"
  done
  v=$(sv "$st" reclaim 2); [ "$v" = "$want" ] || { fail "STORAGE PIN: reclaim's values are '$v', the RECLAIM_* values are '$want'"; return 1; }
  rcd=$(meth "$paf" showReclaimDialog)
  hasre "$rcd" '^ *final long\[\] opts = \{ RECLAIM_NEVER, RECLAIM_1D, RECLAIM_3D, RECLAIM_1W \};$' \
    || { fail "STORAGE PIN: showReclaimDialog's opts are not NEVER, 1D, 3D, 1W"; return 1; }
  want=$(strarr "$(printf '%s\n' "$rcd" | grep -E '^ *final CharSequence\[\] items = \{')")
  v=$(sv "$st" reclaim 3); [ -n "$want" ] && [ "$v" = "$want" ] || { fail "STORAGE PIN: reclaim's labels are '$v', showReclaimDialog's are '$want'"; return 1; }
  want=$(strarr "$(printf '%s\n' "$wc" | awk '/static final String\[\] LABELS = \{/ { f = 1; next } f && /\};/ { exit } f')")
  v=$(sv "$st" wipe 3); [ -n "$want" ] && [ "$v" = "$want" ] || { fail "STORAGE PIN: wipe's labels are '$v', WipeChoice.LABELS are '$want'"; return 1; }
  n=$(printf '%s\n' "$want" | awk -F'; ' '{ print NF }')
  want=$(awk -v n="$n" 'BEGIN { for (i = 0; i < n; i++) printf "%s%d", (i ? "," : ""), i; print "" }')
  v=$(sv "$st" wipe 2); [ "$v" = "$want" ] || { fail "STORAGE PIN: wipe's values are '$v', want the WipeChoice indexes '$want'"; return 1; }
  conf=$(meth "$paf" showConfiguration)
  has "$conf" 'segmented(new String[]{"Essential", "Auto", "On-demand"}, mi,' \
    && has "$conf" 'cfgPut(CFG_MEDIA_DEFAULT, idx == 0 ? "essential" : idx == 1 ? "prefetch" : "ondemand")' \
    || { fail "STORAGE PIN: showConfiguration's Offline media is not Essential=essential, Auto=prefetch, On-demand=ondemand"; return 1; }
  v="$(sv "$st" media.default 3)|$(sv "$st" media.default 2)"
  [ "$v" = "Auto; Essential; On-demand|prefetch,essential,ondemand" ] \
    || { fail "STORAGE PIN: media.default's labels|values are '$v', showConfiguration pairs Auto=prefetch, Essential=essential, On-demand=ondemand"; return 1; }
  has "$pa" 'static final String CFG_MEDIA_DEFAULT = "media.default";' || { fail "STORAGE PIN: CFG_MEDIA_DEFAULT is not \"media.default\""; return 1; }
  adr=$(meth "$paf" appDefaultRow)
  has "$adr" 'segmented(new String[]{"Off", "On-demand", "Auto", "Installed"}, idx,' \
    && has "$adr" 'cfgPut(key, i == 0 ? APPDEF_OFF : i == 1 ? MODE_ONDEMAND : i == 2 ? MODE_AUTO : MODE_INSTALLED)' \
    || { fail "STORAGE PIN: appDefaultRow is not Off=APPDEF_OFF, On-demand, Auto, Installed in that order"; return 1; }
  for k in "napps nApps NAPPS" "play Play Store PLAY" "aurora Aurora Store AURORA" \
           "gos GrapheneOS App Store GOS" "other Everything else OTHER"; do
    key=${k%% *}; const=${k##* }; name=${k#* }; name=${name% *}
    v="$(sv "$st" "apps.default.$key" 3)|$(sv "$st" "apps.default.$key" 2)"
    [ "$v" = "Off; On-demand; Auto; Installed|off,ondemand,auto,installed" ] \
      || { fail "STORAGE PIN: apps.default.$key's labels|values are '$v'"; return 1; }
    hasre "$pa" "^ *static final String CFG_APPS_$const += \"apps\\.default\\.$key\";\$" \
      || { fail "STORAGE PIN: CFG_APPS_$const is not \"apps.default.$key\""; return 1; }
    has "$conf" "appDefaultRow(ll, \"$name\", CFG_APPS_$const);" \
      || { fail "STORAGE PIN: showConfiguration has no \"$name\" row for CFG_APPS_$const"; return 1; }
  done
  return 0
}

# check_all <ProfilePresets.java> <doc> <ChooserActivity> <ProfileActivity> <WipeChoice> -> 0 when the cases and every
# pin pass, 1 when one fails, 3 when the class did not compile.
check_all() {
  local dd sd rc
  dd=$(mktemp -p "$W") || return 1; sd=$(mktemp -p "$W") || return 1
  suite "$1" "$dd" "$sd"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  docpin "$2" "$dd" || rc=1
  codepin "$sd" "$3" "$4" "$5" || rc=1
  return "$rc"
}

echo "== $SUT"
check_all "$SUT" "$DOC" "$CHA" "$PA" "$WC"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + doc pin + defaults pin + storage pin"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
DUMP_DOC=$(mktemp -p "$W") || exit 1; DUMP_STORE=$(mktemp -p "$W") || exit 1
suite "$SUT" "$DUMP_DOC" "$DUMP_STORE" >/dev/null 2>&1 || { echo "FAIL: the unmutated class did not dump" >&2; exit 1; }
mut() { # mut <label> <file: class|doc|pa|cha> <perl-expr>
  local d c rc orig out why
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in
    class) orig="$SUT" ;;
    doc) orig="$DOC" ;;
    pa) orig="$PA" ;;
    *) orig="$CHA" ;;
  esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    class) out=$(check_all "$c" "$DOC" "$CHA" "$PA" "$WC" 2>&1); rc=$? ;;
    doc) out=$(docpin "$c" "$DUMP_DOC" 2>&1); rc=$? ;;
    pa) out=$(codepin "$DUMP_STORE" "$CHA" "$c" "$WC" 2>&1); rc=$? ;;
    *) out=$(codepin "$DUMP_STORE" "$c" "$PA" "$WC" 2>&1); rc=$? ;;
  esac
  rm -rf "$d"
  why=$(printf '%s\n' "$out" | awk '/FAIL/ { sub(/^ +/, ""); print; exit }')
  case "$rc" in
    0) echo "  SURVIVED  $1"; return 1 ;;
    1) echo "  convicted $1 -- $why"; return 0 ;;
    *) echo "  BROKEN    $1 -- the mutant did not compile (rc=$rc)"; return 1 ;;
  esac
}
fails=0
mut "M1 Zero's nApps is On-demand"              class 's/("auto", "auto", "ondemand", "ondemand", )"off"\)/$1"ondemand")/' || fails=$((fails+1))
mut "M2 Unshielded's Offline media is Essential" class 's/"prefetch", ("ondemand", "ondemand", "ondemand", "ondemand"\))/"essential", $1/' || fails=$((fails+1))
mut "M3 Standard's wipe is 6 hours"             class 's/"5", "3", "2", "1", "0"\)/"5", "2", "2", "1", "0")/' || fails=$((fails+1))
mut "M4 the reclaim row is deleted"             class 's/\n *new Row\("reclaim",.*?\),(?=\n *new Row\()//s' || fails=$((fails+1))
mut "M5 match takes a partial match"            class 's/if \(!e\.getValue\(\)\.equals\(current\.get\(e\.getKey\(\)\)\)\) return false;/if (e.getValue().equals(current.get(e.getKey()))) return true;/' || fails=$((fails+1))
mut "M6 leaving Custom does not save it"        class 's/if \(now != null\) saved = now;//' || fails=$((fails+1))
mut "M7 handChange never asks"                  class 's/return new HandChange\(true, savedCustom, now\);/return new HandChange(false, now, null);/' || fails=$((fails+1))
mut "M8 parseCustom returns a partial map"      class 's/return tableValues\(seen\);/return Collections.unmodifiableMap(seen);/' || fails=$((fails+1))
mut "M9 showIdlePicker's mins drift"            pa    's/final int\[\] mins = \{ 5, 15, 30, 60, 0 \};/final int[] mins = { 5, 10, 30, 60, 0 };/' || fails=$((fails+1))
mut "M10 the gate's idle default moves"         cha   's/IDLE_LOGOFF_MS = 15 \* 60 \* 1000L;/IDLE_LOGOFF_MS = 30 * 60 * 1000L;/' || fails=$((fails+1))
mut "D1 the doc's Hardened idle is 30 minutes"  doc   's/^(\| Security > Auto standby when idle \|[^\n]*\| Never \| After 15 minutes \| )After 5 minutes/${1}After 30 minutes/m' || fails=$((fails+1))
mut "H1 the class's Hardened install wait is On"  class 's/(new Row\("holdlock",\n[^\n]*\n[^\n]*\n\s*new String\[\]\{ "", "0" \},\n\s*"", "", )"0"(, "0", "0"\),)/$1""$2/' || fails=$((fails+1))
mut "H2 the doc's Hardened install wait is On"    doc   's/^(\| Security > Auto standby when idle > "Before standby, wait for:" > "app installs"[^\n]*\| On \(checked\) \| On \(checked\) \| )Off \(unchecked\)( \| Off \(unchecked\) \| Off \(unchecked\) \|)$/${1}On (checked)$2/m' || fails=$((fails+1))
mut "A1 the class's Hardened audio wait is On"    class 's/(new Row\("holdaudio",\n[^\n]*\n[^\n]*\n\s*new String\[\]\{ "", "0" \},\n\s*"", "", )"0"(, "0", "0"\),)/$1""$2/' || fails=$((fails+1))
mut "A2 the doc's Hardened audio wait is On"      doc   's/^(\| Security > Auto standby when idle > "Before standby, wait for:" > "audio playing"[^\n]*\| On \(checked\) \| On \(checked\) \| )Off \(unchecked\)( \| Off \(unchecked\) \| Off \(unchecked\) \|)$/${1}On (checked)$2/m' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
