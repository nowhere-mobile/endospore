#!/usr/bin/env bash
# test-preset-picker-java.sh [--mutate] -- the preset picker, run under javac (NWP-20261122-02); since NWP-20261126-09
# it is the Privacy level card on Profile home (docs/product-decisions.md 2026-11-03).
#
# WHY THIS IS COMMITTED. ProfilePresets (NWP-20261119-12) held the table and nothing called it: a user who wanted
# Hardened set ten values on four screens by hand, and a saved Custom could not exist. The picker now offers the five
# presets and Custom, previews each change with the preset's two consent links, applies through the screens' own
# writers, and every hand-change write path asks before it replaces a different saved Custom (docs/product-decisions.md
# 2026-10-31, 2026-10-26 and 2026-11-01 h50 #8; docs/profile-presets.md (b), (d), Custom). NWP-20261126-09 moved it
# out of Preferences to a card on Profile home: a five-step scale, a dropdown with one line per preset, and the number
# of settings a pick changes before the preview (2026-11-03). PresetPicker is pure
# java.util and is compiled here with ProfilePresets, WipeChoice, WipeOnSave, SettingsText, ProfileActivity.prefValueIn
# (lifted by signature) and its cases. Source pins (comments stripped) hold what the cases cannot:
#   P1 the throwaway branch of showPreferences has no Preset row;  P2 no branch of showPreferences has it;
#   P3 each hand-change write path calls presetGuard before its writer;
#   P4 the picker never writes netloc=, geocoder= or a tie (SE-TIE / SE-UNTIE), and never calls presetGuard;
#   P5 applyPreset sends the live prefs to the gate;
#   P6 PresetPicker's file names and defaults equal ProfileActivity's;  P7 its screen-value lists equal the ternaries;
#   P8 presetGuard only switches on PresetPicker.guardAction, and its WRITE_ONLY arm saves no Custom;
#   P9 showConfirm adds the Privacy level card once, only under PresetPicker.cardShown(local, offline), after the
#      Update card and before the menu, built from its own views (no sectionCard);
#   P10 showPresetPicker shows PresetSheet.picker over dropdownNames and goes to pickPreset;
#   P11 pickPreset shows PresetSheet.count before it opens showPresetPreview;
#   P12 applyPreset returns to Profile home (showConfirm), never to Preferences;
#   P13 the preview's consent links and its "Apply " + picked button, byte for byte.
#
# ⚠ IT FAILS WHEN THERE IS NO JAVAC, IT NEVER SKIPS. javac comes from PATH, else from the build host's JDK below;
# the version is printed first so the log proves which compiler ran.
#
#   bash test-preset-picker-java.sh            # the cases + the pins
#   bash test-preset-picker-java.sh --mutate   # ... plus broken copies that must each FAIL
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
SRC="$root/core/chooser/src/com/nowhere/chooser"
SUT="$SRC/PresetPicker.java"
PA="$SRC/ProfileActivity.java"
PS="$SRC/PresetSheet.java"
CASES="$root/core/chooser/tests/preset-picker/PresetPickerCases.java"
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
for f in "$CASES" "$PA" "$PS" "$SRC/ProfilePresets.java" "$SRC/WipeChoice.java" "$SRC/WipeOnSave.java" "$SRC/SettingsText.java"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 2; }
done

# suite <PresetPicker.java> <ProfileActivity.java> -> 0 pass, 1 a case failed or the class is missing (the only codes
# that convict a mutant), 3 it did not compile or prefValueIn could not be lifted.
suite() {
  local src="$1" pa="$2" d out rc f
  [ -f "$src" ] || { echo "  FAIL  PresetPicker.java does not exist (no screen offers a preset)" >&2; return 1; }
  d=$(mktemp -d -p "$W") || return 3
  mkdir -p "$d/src/com/nowhere/chooser"
  cp "$src" "$d/src/com/nowhere/chooser/PresetPicker.java"
  for f in ProfilePresets WipeChoice WipeOnSave SettingsText; do cp "$SRC/$f.java" "$d/src/com/nowhere/chooser/"; done
  cp "$CASES" "$d/src/com/nowhere/chooser/PresetPickerCases.java"
  {
    echo "package com.nowhere.chooser;"
    echo "final class Lifted {"
    awk '!on && index($0, "    static ") == 1 && index($0, " prefValueIn(") { on=1; depth=0 }
         on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }' "$pa"
    echo "}"
  } > "$d/src/com/nowhere/chooser/Lifted.java"
  [ "$(grep -cE '^    static String prefValueIn\(' "$d/src/com/nowhere/chooser/Lifted.java")" = 1 ] \
    || { echo "  FAIL  extraction: prefValueIn" >&2; rm -rf "$d"; return 3; }
  if ! "$JAVAC" -encoding UTF-8 -d "$d/out" "$d"/src/com/nowhere/chooser/*.java; then rm -rf "$d"; return 3; fi
  out=$("$JAVA" -Djava.io.tmpdir="$W" -Dfile.encoding=UTF-8 -cp "$d/out" com.nowhere.chooser.PresetPickerCases 2>&1); rc=$?
  echo "$out"
  rm -rf "$d"
  [ "$rc" -eq 0 ] && return 0
  echo "  FAIL  PresetPickerCases" >&2
  return 1
}

# code <file> -> the file without comment lines and trailing // comments.
code() { sed -E -e '/^[[:space:]]*(\/\/|\*|\/\*)/d' -e 's/[[:space:]]+\/\/[[:space:]].*$//' "$1"; }
# meth <code file> <name> -> the method's lines, from its 4-space declaration to its 4-space closing brace.
meth() {
  awk -v n="$2" '$0 ~ ("^    [a-zA-Z].* " n "\\(") && !f { f = 1 } f { print } f && /^    }$/ { exit }' "$1"
}
# has <text> <fixed string> -> 0 when the text holds it.
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# count <text> <fixed string> -> the number of lines holding it.
count() { printf '%s\n' "$1" | grep -cF -- "$2"; }
# first_line <text> <fixed string> -> the first line number holding it, empty when none.
first_line() { printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1; }
# strarr <text> -> the "..." literals of the text, joined by ",".
strarr() { printf '%s\n' "$1" | grep -oE '"[^"]*"' | sed -E 's/^"|"$//g' | paste -sd, -; }
# sconst <code> <NAME> -> the value of `static final String NAME = "...";`.
sconst() { printf '%s\n' "$1" | sed -nE "s/^ *(private )?static final String $2 *= \"([^\"]*)\";.*/\2/p" | head -1; }

# pins <ProfileActivity.java> <PresetPicker.java> -> 0 when every pin holds, 1 (with each reason) when not.
pins() {
  local pa paf pp bad=0 b tw rest m writer g w k v want consts got arm
  pa=$(code "$1"); pp=$(code "$2")
  paf=$(mktemp -p "$W") || return 1
  printf '%s\n' "$pa" > "$paf"

  # P1 / P2: no branch of Preferences has a Preset row (NWP-20261126-09: it is the card on Profile home).
  b=$(meth "$paf" showPreferences)
  [ -n "$b" ] || { echo "  FAIL  P1 showPreferences( not found" >&2; return 1; }
  tw=$(printf '%s\n' "$b" | awk '/if \("LOCAL"\.equals\(sessionType\) && !offlineSession\) \{/ { f = 1 } f { print } f && /return;/ { exit }')
  [ -n "$tw" ] || { echo "  FAIL  P1 showPreferences has no throwaway branch" >&2; bad=1; }
  if has "$tw" "Preset" || has "$tw" "showPresetPicker"; then
    echo "  FAIL  P1 the throwaway branch of showPreferences offers a Preset row" >&2; bad=1
  fi
  for k in "showPresetPicker" "presetShown(" "Preset"; do
    has "$b" "$k" && { echo "  FAIL  P2 showPreferences holds $k (the Preset row left Preferences)" >&2; bad=1; }
  done

  # P3: each hand-change write path calls the guard before its writer.
  for m in "showIdlePicker writeIdlePref(" "showIdlePicker setPref(\"holdlock\"" "showIdlePicker setPref(\"holdaudio\"" \
           "showWipePicker writeWipePref(" \
           "showConfiguration cfgPut(CFG_MEDIA_DEFAULT" "appDefaultRow cfgPut(key" "showReclaimDialog setReclaimIdleMs("; do
    writer=${m#* }; b=$(meth "$paf" "${m%% *}")
    g=$(first_line "$b" "presetGuard(PresetPicker.change("); w=$(first_line "$b" "$writer")
    if [ -z "$g" ] || [ -z "$w" ] || [ "$g" -gt "$w" ] || [ "$(count "$b" "presetGuard(")" -ne 1 ]; then
      echo "  FAIL  P3 ${m%% *} does not call presetGuard once, before $writer" >&2; bad=1
    fi
  done

  # P4: the picker never writes a consent setting, and never runs the hand-change guard on its own writes.
  for m in presetCurrent presetSavedCustom presetLast presetShown addPrivacyLevelCard presetSaveCustom showPresetPicker \
           pickPreset showPresetPreview presetLine applyPreset presetGuard; do
    b=$(meth "$paf" "$m")
    [ -n "$b" ] || { echo "  FAIL  P4 $m( not found" >&2; bad=1; continue; }
    for k in PREF_NETLOC PREF_GEOCODER '"netloc"' '"geocoder"' 'SE-TIE' 'SE-UNTIE'; do
      has "$b" "$k" && { echo "  FAIL  P4 $m holds $k (a preset never writes a consent setting)" >&2; bad=1; }
    done
  done
  for k in PREF_NETLOC PREF_GEOCODER netloc geocoder 'SE-TIE' 'SE-UNTIE'; do
    has "$pp" "$k" && { echo "  FAIL  P4 PresetPicker.java holds $k" >&2; bad=1; }
  done
  for m in showPresetPicker pickPreset showPresetPreview applyPreset; do
    has "$(meth "$paf" "$m")" "presetGuard(" && { echo "  FAIL  P4 $m calls presetGuard (it is for hand changes)" >&2; bad=1; }
  done

  # P5: Apply tells the gate, as the Security pickers do.
  [ "$(count "$(meth "$paf" applyPreset)" "sendLivePrefs();")" -eq 1 ] \
    || { echo "  FAIL  P5 applyPreset does not send the live prefs to the gate" >&2; bad=1; }

  # P6: file names and defaults.
  [ "$(sconst "$pp" PREFS_FILE)" = "$(sconst "$pa" PREFS_FILE)" ] && [ -n "$(sconst "$pa" PREFS_FILE)" ] \
    || { echo "  FAIL  P6 PresetPicker.PREFS_FILE is not ProfileActivity.PREFS_FILE" >&2; bad=1; }
  [ "$(sconst "$pp" CONFIG_FILE)" = "$(sconst "$pa" CFG_FILE)" ] && [ -n "$(sconst "$pa" CFG_FILE)" ] \
    || { echo "  FAIL  P6 PresetPicker.CONFIG_FILE is not ProfileActivity.CFG_FILE" >&2; bad=1; }
  v=$(sconst "$pp" RECLAIM_FILE)
  { [ -n "$v" ] && has "$(meth "$paf" reclaimIdleMs)" "\"$v\"" && has "$(meth "$paf" setReclaimIdleMs)" "\"$v\""; } \
    || { echo "  FAIL  P6 PresetPicker.RECLAIM_FILE is not the file reclaimIdleMs and setReclaimIdleMs use" >&2; bad=1; }
  [ "$(sconst "$pp" CUSTOM_FILE)" = "nowhere-preset-custom" ] && [ "$(sconst "$pp" LAST_FILE)" = "nowhere-preset-last" ] \
    || { echo "  FAIL  P6 the saved-Custom or last-shown file name changed" >&2; bad=1; }
  want=$(meth "$paf" showIdlePicker | sed -nE 's/^ *int cur = ([0-9]+);$/\1/p')
  [ -n "$want" ] && [ "$(sconst "$pp" IDLE_DEFAULT)" = "$want" ] \
    || { echo "  FAIL  P6 PresetPicker.IDLE_DEFAULT is '$(sconst "$pp" IDLE_DEFAULT)', showIdlePicker's default is '$want'" >&2; bad=1; }
  has "$pa" "static final long RECLAIM_DEFAULT_MS = RECLAIM_3D;" && has "$pa" "static final long RECLAIM_1D = 24L * 60 * 60 * 1000;" \
    && has "$pa" "static final long RECLAIM_3D = 3 * RECLAIM_1D;" && [ "$(sconst "$pp" RECLAIM_DEFAULT)" = "$((3 * 24 * 60 * 60 * 1000))" ] \
    || { echo "  FAIL  P6 PresetPicker.RECLAIM_DEFAULT is not RECLAIM_DEFAULT_MS (RECLAIM_3D)" >&2; bad=1; }
  b=$(meth "$paf" cfg)
  { has "$b" 'if (CFG_MEDIA_DEFAULT.equals(key)) return "ondemand";' && [ "$(sconst "$pp" MEDIA_DEFAULT)" = ondemand ] \
    && has "$b" 'if (CFG_APPS_NAPPS.equals(key))    return MODE_AUTO;' && [ "$(sconst "$pp" NAPPS_DEFAULT)" = "$(sconst "$pa" MODE_AUTO)" ] \
    && has "$b" 'return APPDEF_OFF;' && [ "$(sconst "$pp" STORE_DEFAULT)" = "$(sconst "$pa" APPDEF_OFF)" ]; } \
    || { echo "  FAIL  P6 PresetPicker's config defaults are not cfg's fallbacks" >&2; bad=1; }

  # P7: the screen-value lists equal the pinned ternaries.
  want=$(strarr "$(printf '%s\n' "$pa" | grep -oE 'cfgPut\(CFG_MEDIA_DEFAULT, idx == 0 \? [^)]*\)' | head -1)")
  got=$(strarr "$(perl -0ne 'print "$1\n" if /MEDIA_SCREEN_VALUES =\s*Collections\.unmodifiableList\(Arrays\.asList\(([^)]*)\)\)/' "$2")")
  [ -n "$want" ] && [ "$got" = "$want" ] || { echo "  FAIL  P7 MEDIA_SCREEN_VALUES is '$got', showConfiguration writes '$want'" >&2; bad=1; }
  want=""
  for k in $(printf '%s\n' "$pa" | grep -oE 'cfgPut\(key, i == 0 \? [^)]*\)' | head -1 | grep -oE 'APPDEF_OFF|MODE_[A-Z]+'); do
    want="$want${want:+,}$(sconst "$pa" "$k")"
  done
  got=$(strarr "$(perl -0ne 'print "$1\n" if /APPDEF_SCREEN_VALUES =\s*Collections\.unmodifiableList\(Arrays\.asList\(([^)]*)\)\)/' "$2")")
  [ -n "$want" ] && [ "$got" = "$want" ] || { echo "  FAIL  P7 APPDEF_SCREEN_VALUES is '$got', appDefaultRow writes '$want'" >&2; bad=1; }

  # P8: presetGuard holds no decision of its own.
  b=$(meth "$paf" presetGuard)
  [ "$(count "$b" "PresetPicker.guardAction(")" -eq 1 ] \
    || { echo "  FAIL  P8 presetGuard does not call PresetPicker.guardAction once" >&2; bad=1; }
  for k in "ProfilePresets.handChange(" "PresetPicker.unchanged(" "PresetPicker.with("; do
    has "$b" "$k" && { echo "  FAIL  P8 presetGuard calls $k (the decision is guardAction's)" >&2; bad=1; }
  done
  for k in "case WRITE_ONLY:" "case WRITE_AND_SAVE:" "case ASK:"; do
    has "$b" "$k" || { echo "  FAIL  P8 presetGuard does not switch on $k" >&2; bad=1; }
  done
  arm=$(printf '%s\n' "$b" | awk '/case WRITE_ONLY:/ { f = 1; next } f && /case |break;/ { exit } f')
  has "$arm" "write.run();" || { echo "  FAIL  P8 presetGuard's WRITE_ONLY arm does not write" >&2; bad=1; }
  has "$arm" "presetSaveCustom(" && { echo "  FAIL  P8 presetGuard's WRITE_ONLY arm saves a Custom" >&2; bad=1; }

  # P9: the card on Profile home, guarded, once, between the Update card and the menu.
  b=$(meth "$paf" showConfirm)
  k='if (PresetPicker.cardShown(local, offline)) addPrivacyLevelCard(ll);'
  g=$(first_line "$b" "$k"); w=$(first_line "$b" "addUpdateCard(ll"); v=$(first_line "$b" "sectionCard(ll, null,")
  if [ -z "$g" ] || [ -z "$w" ] || [ -z "$v" ] || [ "$g" -lt "$w" ] || [ "$g" -gt "$v" ] || [ "$(count "$b" "$k")" -ne 1 ] \
     || [ "$(count "$b" "addPrivacyLevelCard(")" -ne 1 ]; then
    echo "  FAIL  P9 showConfirm does not add the card once, under PresetPicker.cardShown(local, offline), after the Update card and before the menu" >&2; bad=1
  fi
  [ "$(count "$pa" "addPrivacyLevelCard(")" -eq 2 ] \
    || { echo "  FAIL  P9 addPrivacyLevelCard is not declared once and called once (from showConfirm)" >&2; bad=1; }
  b=$(meth "$paf" addPrivacyLevelCard)
  for k in "PresetPicker.CARD_TITLE" "PresetPicker.scalePos(shown)" "PresetPicker.SCALE.size()" "PresetPicker.rowOf(shown)" "showPresetPicker()"; do
    has "$b" "$k" || { echo "  FAIL  P9 addPrivacyLevelCard does not use $k" >&2; bad=1; }
  done
  has "$b" "sectionCard(" && { echo "  FAIL  P9 addPrivacyLevelCard calls sectionCard (build the card from its own views)" >&2; bad=1; }

  # P10: the dropdown.
  b=$(meth "$paf" showPresetPicker)
  { has "$b" "PresetSheet.picker(saved, presetShown(), savedValues)" && has "$b" "PresetPicker.dropdownNames(saved)" && has "$b" "pickPreset(names.get(i))" \
    && has "$b" "presetSavedCustom()"; } \
    || { echo "  FAIL  P10 showPresetPicker does not show PresetSheet.picker over dropdownNames and go to pickPreset" >&2; bad=1; }

  # P11: the count before the preview.
  b=$(meth "$paf" pickPreset)
  g=$(first_line "$b" "PresetSheet.count(picked, PresetPicker.changeCount(cur, c.valuesToApply))")
  w=$(first_line "$b" "showPresetPreview(picked, cur, c)")
  if [ -z "$g" ] || [ -z "$w" ] || [ "$g" -gt "$w" ] || [ "$(count "$b" "showPresetPreview(")" -ne 1 ]; then
    echo "  FAIL  P11 pickPreset does not show PresetSheet.count before it opens showPresetPreview" >&2; bad=1
  fi

  # P12: Apply returns to Profile home, where the card redraws.
  b=$(meth "$paf" applyPreset)
  { ! has "$b" "showPreferences()" && [ "$(count "$b" "showConfirm();")" -eq 2 ]; } \
    || { echo "  FAIL  P12 applyPreset does not return to Profile home (showConfirm) on both exits" >&2; bad=1; }

  # P13: the preview's links and Apply, unchanged.
  b=$(meth "$paf" showPresetPreview | awk '/java\.util\.List<String> links = PresetPicker\.links\(picked\);/ { f = 1 } f { print } f && /new Runnable\[\] \{ \(\) -> applyPreset\(picked, cur, c\), null \},/ { exit }')
  want=$(cat <<'PIN'
        java.util.List<String> links = PresetPicker.links(picked);
        boolean[] linkOffered = new boolean[links.size()];
        for (int i = 0; i < links.size(); i++) {
            final boolean tie = i == 0;
            boolean offered = tie ? !"LOCAL".equals(sessionType)
                    : locOffered(sessionType, offlineSession, locServicesAvailable());
            linkOffered[i] = offered;
        }
        SheetDialog.confirm(this, PresetSheet.preview(picked, lines, links, linkOffered),
                new Runnable[] { () -> applyPreset(picked, cur, c), null },
PIN
)
  [ "$b" = "$want" ] || { echo "  FAIL  P13 the preview's consent links or its Apply line changed" >&2; bad=1; }
  has "$(code "$PS")" 'new PopupSheet.Button("Apply " + picked, PopupSheet.Style.GREEN_FILLED)' \
    || { echo "  FAIL  P13 PresetSheet.preview's green button is not \"Apply \" + picked" >&2; bad=1; }
  [ "$bad" -eq 0 ]
}

# check_all <PresetPicker.java> <ProfileActivity.java> -> 0 when the cases and every pin pass, 1 when one fails, 3 when
# the class did not compile.
check_all() {
  local rc
  suite "$1" "$2"; rc=$?
  [ "$rc" -eq 3 ] && return 3
  if [ -f "$1" ]; then pins "$2" "$1" || rc=1; fi
  return "$rc"
}

echo "== $SUT"
check_all "$SUT" "$PA"; rc=$?
[ "$rc" -eq 0 ] || { echo "FAILED"; exit 1; }
echo "ok: cases + pins P1-P13"
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
    *) out=$(pins "$c" "$SUT" 2>&1); rc=$? ;;
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
mut "M1 Standard's location line is on"          class 's/(m\.put\(ProfilePresets\.STANDARD, Arrays\.asList\(TIE_NO, )LOC_OFF\)/${1}LOC_ON)/' || fails=$((fails+1))
mut "M2 Hardened has no tie line"                class 's/(m\.put\(ProfilePresets\.HARDENED, Arrays\.asList\()TIE_YES, /$1/' || fails=$((fails+1))
mut "M3 current defaults idle to 5"              class 's/static final String IDLE_DEFAULT = "15";/static final String IDLE_DEFAULT = "5";/' || fails=$((fails+1))
mut "M4 the reclaim save runs without the guard" pa    's/presetGuard\(PresetPicker\.change\("reclaim", Long\.toString\(opts\[which\]\)\), \(\) -> \{(.*?)\}, null\);/{$1}/s' || fails=$((fails+1))
mut "M5 the Preset row left in the stored branch" pa  's/(\n *)(if \(MobileData\.offered\(sessionType, offlineSession\)\) \{)/$1rows.add(0, "Preset: " + presetShown());$1acts.add(0, () -> showPresetPicker());$1$2/' || fails=$((fails+1))
mut "M6 plan writes unchanged rows"              class 's/if \(to == null \|\| to\.equals\(current\.get\(r\.key\)\)\) continue;/if (to == null) continue;/' || fails=$((fails+1))
mut "M7 current ignores wipesaved"               class 's/prefValue\(prefsText, WipeOnSave\.PREF\)/""/' || fails=$((fails+1))
mut "M8 applyPreset writes netloc"               pa    's/(\n *)(boolean prefs = false;)/$1setPref(PREF_NETLOC, "1");$1$2/' || fails=$((fails+1))
mut "M9 shown ignores LAST"                      class 's/if \(lastText != null && ProfilePresets\.CUSTOM\.equals\(lastText\.trim\(\)\)\) return ProfilePresets\.CUSTOM;//' || fails=$((fails+1))
mut "M10 APPDEF_SCREEN_VALUES swaps two"         class 's/Arrays\.asList\("off", "ondemand", "auto", "installed"\)/Arrays.asList("off", "auto", "ondemand", "installed")/' || fails=$((fails+1))
mut "M11 guardAction asks on a no-op change"     class 's/\n *if \(unchanged\(current, change\)\) return new Guard\(Action\.WRITE_ONLY, null\);//' || fails=$((fails+1))
mut "M12 guardAction re-saves an unchanged Custom" class 's/\n *if \(Objects\.equals\(h\.savedCustomAfter, savedCustom\)\) return new Guard\(Action\.WRITE_ONLY, null\);//' || fails=$((fails+1))
mut "M13 presetGuard decides with handChange"    pa    's/(private void presetGuard\(.*?)PresetPicker\.guardAction\(/${1}ProfilePresets.handChange(/s' || fails=$((fails+1))
mut "M14 presetGuard's WRITE_ONLY arm saves"     pa    's/(case WRITE_ONLY:\n *write\.run\(\);)/$1\n                presetSaveCustom(g.save);/' || fails=$((fails+1))
mut "M15 the idle Save runs without the guard"   pa    's/presetGuard\(PresetPicker\.change\("idle", String\.valueOf\(mins\[idx\]\),\n *"holdlock", holdBox\.isChecked\(\) \? "" : "0",\n *"holdaudio", audioBox\.isChecked\(\) \? "" : "0"\), \(\) -> \{(.*?)\}, \(\) -> showSecurity\(\)\);/{$1}/s' || fails=$((fails+1))
mut "M16 applyPreset does not tell the gate"     pa    's/\n *if \(prefs\) sendLivePrefs\(\);//' || fails=$((fails+1))
mut "M17 the card shown for a throwaway"        class 's/return !local \|\| offline;/return true;/' || fails=$((fails+1))
mut "M18 the card hidden offline"                class 's/return !local \|\| offline;/return !local;/' || fails=$((fails+1))
mut "M19 the count step skipped"                 pa    's/(\n *)SheetDialog\.confirm\(this, PresetSheet\.count\(.*?, null\);/${1}showPresetPreview(picked, cur, c);/s' || fails=$((fails+1))
mut "M20 scalePos off by one"                    class 's/return SCALE\.indexOf\(shown\);/return SCALE.indexOf(shown) + 1;/' || fails=$((fails+1))
mut "M21 Custom placed on the scale"             class 's/(static final List<String> SCALE = Collections\.unmodifiableList\(new ArrayList<>\()ProfilePresets\.PRESETS\)\);/${1}Arrays.asList("Unshielded", "Standard", "Hardened", "Isolated", "Zero", "Custom")));/' || fails=$((fails+1))
mut "M22 the card unguarded on Profile home"     pa    's/if \(PresetPicker\.cardShown\(local, offline\)\) addPrivacyLevelCard\(ll\);/addPrivacyLevelCard(ll);/' || fails=$((fails+1))
mut "M23 Apply returns to Preferences"           pa    's/(private void applyPreset\(.*?)showConfirm\(\);/${1}showPreferences();/s' || fails=$((fails+1))
mut "M24 the dropdown always lists Custom"       class 's/if \(savedCustom\) c\.add\(ProfilePresets\.CUSTOM\);/c.add(ProfilePresets.CUSTOM);/' || fails=$((fails+1))
mut "M25 a preview link line changed"            pa    's/boolean offered = tie \? !"LOCAL"\.equals\(sessionType\)/boolean offered = tie ? true/' || fails=$((fails+1))
mut "M26 Unshielded says every new app is Auto"  class 's/new store apps start on Auto, others On-demand/new apps start on Auto/' || fails=$((fails+1))
[ "$fails" -eq 0 ] && echo "== all 26 mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
