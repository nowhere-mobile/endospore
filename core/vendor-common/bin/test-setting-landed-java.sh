#!/usr/bin/env bash
# test-setting-landed-java.sh [--mutate] -- Configuration defaults and Auto-wipe say when a change was not saved, run
# under javac (NWP-20261125-22).
#
# WHY THIS IS COMMITTED. Profile > Preferences > Configuration's media and app defaults write through cfgPut, which is
# void (cfgPutStatic logs a failed StoreInstaller.writeAtomic and returns), and nothing read the file back: on a full
# /data the segment kept the new choice while nowhere-config kept the old one. The Auto-wipe picker toasted "Auto-wipe
# <choice> — applies next sign-in" after a failed write too. presetGuard ran `write.run(); presetSaveCustom(g.save);`
# in WRITE_AND_SAVE and on Replace, so a failed write still saved (or replaced) the Custom preset with a value the
# profile did not have. Each write is now read back through presetCurrent and SettingLanded.landed.
#
# SettingLanded is pure java.util and is compiled here with PresetPicker, ProfilePresets, WipeChoice, WipeOnSave,
# SettingsText and its cases (L1-L8: landed's rule, NOT_SAVED's words, and its agreement with PresetPicker.unchanged
# for every option of every ProfilePresets.ROWS row read back through PresetPicker.current). Source pins (comments
# stripped) hold what the cases cannot:
#   S1 presetGuard's WRITE_AND_SAVE and ASK arms call presetSaveCustom only under SettingLanded.landed(, after
#      write.run();
#   S2 showConfiguration's media lambda reads back after its cfgPut and, on false, toasts NOT_SAVED and redraws;
#   S3 appDefaultRow's lambda does the same;
#   S4 showWipePicker toasts NOT_SAVED on a failed read-back and reaches "applies next sign-in" only when saved.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-setting-landed-java.sh            # the cases + the pins
#   bash test-setting-landed-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/SettingLanded.java"
PA="$SRC/ProfileActivity.java"
CASES="$root/core/chooser/tests/setting-landed/SettingLandedCases.java"
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
for f in "$CASES" "$PA" "$SRC/PresetPicker.java" "$SRC/ProfilePresets.java" "$SRC/WipeChoice.java" \
         "$SRC/WipeOnSave.java" "$SRC/SettingsText.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <SettingLanded.java> -> 0 pass, 1 a case failed or the class is missing (the only codes that convict a
# mutant), 3 it did not compile.
suite() {
  local src="$1" d out rc f
  [ -f "$src" ] || { echo "  FAIL  SettingLanded.java does not exist (no write is read back)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/SettingLanded.java"
  for f in PresetPicker ProfilePresets WipeChoice WipeOnSave SettingsText; do
    cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/"
  done
  cp "$CASES" "$d/src/com/nowhere/chooser/SettingLandedCases.java"
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.SettingLandedCases 2>&1)
  rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  SettingLandedCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# count <text> <fixed string> -> the number of lines holding it.
count() { printf '%s\n' "$1" | grep -cF -- "$2"; }
# first_line <text> <fixed string> -> the first line number holding it, empty when none.
first_line() { printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1; }
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# block <text> <fixed string> -> from the first line holding it to the next line that is only "}" (indent allowed).
block() { printf '%s\n' "$1" | awk -v s="$2" '!f && index($0, s) { f = 1 } f { print } f && /^ *}$/ { exit }'; }

GUARDED='if (SettingLanded.landed(change, presetCurrent())) presetSaveCustom(g.save);'

# readback <code file> <method> <writer> <read-back if> <screen value> <label> -> 0 when the method reads back after
# its writer and, on false, toasts NOT_SAVED and redraws.
readback() {
  local b w r blk bad=0 k
  b=$(meth "$1" "$2")
  [ -n "$b" ] || { echo "  FAIL  $6 $2( not found" >&2; return 1; }
  w=$(first_line "$b" "$3"); r=$(first_line "$b" "$4")
  if [ -z "$w" ] || [ -z "$r" ] || [ "$r" -le "$w" ]; then
    echo "  FAIL  $6 $2 does not read back with $4 after $3" >&2; return 1
  fi
  blk=$(block "$b" "$4")
  for k in "$5" "presetCurrent()" "SettingLanded.NOT_SAVED" "showConfiguration();"; do
    has "$blk" "$k" || { echo "  FAIL  $6 $2's read-back block does not hold $k" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

# pins <ProfileActivity.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local paf bad=0 b arm a wr sv n e s ok
  paf=$(mktemp -p "$W") || return 1
  code "$1" > "$paf"

  # S1: presetGuard saves a Custom only from a change that landed, read back after the write.
  b=$(meth "$paf" presetGuard)
  [ -n "$b" ] || { echo "  FAIL  S1 presetGuard( not found" >&2; return 1; }
  [ "$(count "$b" "presetSaveCustom(")" -eq 2 ] && [ "$(count "$b" "PresetPicker.guardAction(")" -eq 1 ] \
    || { echo "  FAIL  S1 presetGuard does not hold two presetSaveCustom( and one PresetPicker.guardAction(" >&2; bad=1; }
  for a in WRITE_AND_SAVE ASK; do
    case "$a" in
      WRITE_AND_SAVE) arm=$(printf '%s\n' "$b" | awk '/case WRITE_AND_SAVE:/ { f = 1 } f { print } f && /break;/ { exit }') ;;
      ASK) arm=$(printf '%s\n' "$b" | awk '/case ASK:/ { f = 1 } f { print } f && /\.setNegativeButton\(/ { exit }') ;;
    esac
    wr=$(first_line "$arm" "write.run();"); sv=$(first_line "$arm" "$GUARDED")
    if [ "$(count "$arm" "presetSaveCustom(")" -ne 1 ] || [ "$(count "$arm" "$GUARDED")" -ne 1 ] \
       || [ -z "$wr" ] || [ -z "$sv" ] || [ "$sv" -le "$wr" ]; then
      echo "  FAIL  S1 presetGuard's $a arm does not save the Custom only under SettingLanded.landed(, after write.run();" >&2
      bad=1
    fi
  done

  # S2 / S3: both Configuration lambdas read back after cfgPut and redraw on a write that did not land.
  readback "$paf" showConfiguration "cfgPut(CFG_MEDIA_DEFAULT, idx == 0 ? " \
    "if (!SettingLanded.landed(PresetPicker.change(CFG_MEDIA_DEFAULT," "PresetPicker.MEDIA_SCREEN_VALUES.get(idx)" S2 \
    || bad=1
  readback "$paf" appDefaultRow "cfgPut(key, i == 0 ? " \
    "if (!SettingLanded.landed(PresetPicker.change(key," "PresetPicker.APPDEF_SCREEN_VALUES.get(i)" S3 || bad=1

  # S4: the Auto-wipe toast follows the read-back.
  b=$(meth "$paf" showWipePicker)
  [ -n "$b" ] || { echo "  FAIL  S4 showWipePicker( not found" >&2; return 1; }
  ok=1
  s='final boolean saved = SettingLanded.landed(PresetPicker.change("wipe", String.valueOf(idx)),'
  wr=$(first_line "$b" "if (writeWipePref(idx)) live = sendLivePrefs();"); sv=$(first_line "$b" "$s")
  { [ "$(count "$b" "$s")" -eq 1 ] && [ -n "$wr" ] && [ -n "$sv" ] && [ "$sv" -gt "$wr" ]; } || ok=0
  n=$(printf '%s\n' "$b" | grep -nE '^ *if \(!saved\) ' | grep -F -- "SettingLanded.NOT_SAVED" | cut -d: -f1)
  [ "$(printf '%s\n' "$n" | grep -c .)" -eq 1 ] && [ "$n" -gt "${sv:-0}" ] || ok=0
  e=$(printf '%s\n' "$b" | grep -nF -- '"Auto-wipe "')
  if [ "$(printf '%s\n' "$e" | grep -c .)" -ne 1 ] || ! [[ "$e" =~ ^[0-9]+:\ *else\  ]]; then
    ok=0
  else
    e=${e%%:*}
    [ -n "$n" ] && [ "$e" -gt "$n" ] || ok=0
    has "$(printf '%s\n' "$b" | sed -n "${e},$((e + 1))p")" "applies next sign-in" || ok=0
    s=$(printf '%s\n' "$b" | sed -n "$((e + 1)),\$p" | grep -nE '^ *showSecurity\(\);$' | head -1)
    [ -n "$s" ] || ok=0
  fi
  [ "$ok" -eq 1 ] || {
    echo "  FAIL  S4 showWipePicker does not toast NOT_SAVED on a failed read-back and the Auto-wipe text only when saved" >&2
    bad=1
  }
  [ "$bad" -eq 0 ]
}

# check_all <SettingLanded.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails, 3
# when the class did not compile.
check_all() {
  local rc
  suite "$1"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  pins "$2" || rc=1
  return "$rc"
}

echo "== $SUT"
check_all "$SUT" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases L1-L8 + pins S1-S4"
[ "$MUTATE" = yes ] || exit 0

command -v perl >/dev/null 2>&1 || { echo "FAIL: --mutate needs perl, and there is none -- refusing to report" >&2; exit 1; }
echo "== mutations (each must be CONVICTED -- a mutant that does not compile or does not apply proves nothing)"
mut() { # mut <label> <class|pa> <perl-expr>
  local d c rc orig out why
  d=$(mktemp -d -p "$W") || return 1
  case "$2" in class) orig="$SUT" ;; *) orig="$PA" ;; esac
  c="$d/$(basename "$orig")"
  cp "$orig" "$c"
  if ! perl -0pi -e "$3" "$c"; then echo "  ERROR     $1 -- perl failed on the mutation"; rm -rf "$d"; return 1; fi
  if cmp -s "$orig" "$c"; then echo "  INERT     $1 -- the mutation changed nothing"; rm -rf "$d"; return 1; fi
  case "$2" in
    class) out=$(check_all "$c" "$PA" 2>&1); rc=$? ;;
    *) out=$(pins "$c" 2>&1); rc=$? ;;
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
mut "K1 landed is true for a missing key"            class 's/if \(!after\.containsKey\(e\.getKey\(\)\)\) return false;/if (!after.containsKey(e.getKey())) continue;/' || fails=$((fails+1))
mut "K2 the ASK arm saves unconditionally"           pa    's/(case ASK:.*?)if \(SettingLanded\.landed\(change, presetCurrent\(\)\)\) (presetSaveCustom\(g\.save\);)/$1$2/s' || fails=$((fails+1))
mut "K3 WRITE_AND_SAVE checks before write.run()"    pa    's/(case WRITE_AND_SAVE:\n)( *write\.run\(\);\n)( *if \(SettingLanded\.landed[^\n]*\n)/$1$3$2/' || fails=$((fails+1))
mut "K4 appDefaultRow without the read-back"         pa    's/(cfgPut\(key, i == 0 \?[^\n]*\n) *if \(!SettingLanded\.landed\(PresetPicker\.change\(key,.*?\n *\}\n/$1/s' || fails=$((fails+1))
mut "K5 the media lambda without the redraw"         pa    's/(cfgPut\(CFG_MEDIA_DEFAULT, idx == 0[^\n]*\n.*?)\n *showConfiguration\(\);/$1/s' || fails=$((fails+1))
mut "K6 the wipe toast regardless of saved"          pa    's/(\n *)else (android\.widget\.Toast\.makeText\(this, "Auto-wipe ")/$1$2/' || fails=$((fails+1))
mut "K7 the WRITE_AND_SAVE arm saves unconditionally" pa   's/(case WRITE_AND_SAVE:\n *write\.run\(\);\n *)if \(SettingLanded\.landed\(change, presetCurrent\(\)\)\) /$1/' || fails=$((fails+1))
mut "K8 landed is true on a null after"              class 's/if \(change == null \|\| after == null\) return false;/if (change == null) return false; if (after == null) return true;/' || fails=$((fails+1))
mut "K9 NOT_SAVED says it applies"                   class 's/static final String NOT_SAVED = "[^"]*";/static final String NOT_SAVED = "Saved — applies next sign-in.";/' || fails=$((fails+1))
mut "K10 landed ignores a differing value"           class 's/if \(!Objects\.equals\(e\.getValue\(\), after\.get\(e\.getKey\(\)\)\)\) return false;//' || fails=$((fails+1))
mut "K11 the wipe read-back is gone"                 pa    's/(\n *)final boolean saved = SettingLanded\.landed\(PresetPicker\.change\("wipe", String\.valueOf\(idx\)\),\n *presetCurrent\(\)\);/$1final boolean saved = true;/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 11 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
