#!/usr/bin/env bash
# test-safe-edit.sh [--mutate] -- no bare EditText is constructed in the chooser (NWP-20261019-13).
#
# SafeEdit exists because this app has no reachable ClipboardManager: a long-press, cursor-handle tap or
# accessibility traversal on a plain EditText reaches TextView.canPaste() and kills the process. Every field
# must be a SafeEdit. Scans every .java under BOTH source roots NowhereChooser compiles (src and mms) for
#   * a bare construction: new [android.widget.]EditText (  -- `new EditText[]` is an array, not a match;
#   * a class that extends EditText other than SafeEdit.
# NWP-20261114-21 (Q041): `SafeEdit.withPaste(` (the box that offers paste while ClipboardManager is reachable)
# appears exactly twice, both in ProfileActivity.java, one on the line constructing the report `note` and one on
# the line constructing the claim-code `codeF`, and never in ChooserActivity.java (the gate) or under mms.
# CONTROL: at least one `new SafeEdit(` must be found outside SafeEdit.java (its own factory holds one), so a
# moved or empty tree fails rather than reads clean.
# Only SafeEdit's own `class SafeEdit extends EditText` text is exempt (stripped before matching), not the rest
# of its file or of its line.
# --mutate re-runs against temp copies with ten faults; each must fail.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MUTATE=no
for a in "$@"; do
  case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]"; exit 2 ;; esac
done

scan() { # $1 = chooser dir; prints problems, returns 1 if any
  local d="$1" bare ext safe paste n rc=0
  bare=$(grep -rnE --include='*.java' 'new[[:space:]]+(android\.widget\.)?EditText[[:space:]]*\(' "$d/src" "$d/mms" 2>/dev/null) || true
  ext=$(grep -rnE --include='*.java' 'extends[[:space:]]+(android\.widget\.)?EditText\b' "$d/src" "$d/mms" 2>/dev/null \
    | sed -E 's/class[[:space:]]+SafeEdit[[:space:]]+extends[[:space:]]+(android\.widget\.)?EditText\b//' \
    | grep -E 'extends[[:space:]]+(android\.widget\.)?EditText\b') || true
  safe=$(grep -rnE --include='*.java' --exclude=SafeEdit.java 'new[[:space:]]+SafeEdit[[:space:]]*\(' "$d/src" "$d/mms" 2>/dev/null) || true
  paste=$(grep -rnE --include='*.java' 'SafeEdit[[:space:]]*\.[[:space:]]*withPaste[[:space:]]*\(' "$d/src" "$d/mms" 2>/dev/null) || true
  n=$(grep -c . <<<"$paste" || true)
  if [ -n "$bare" ]; then echo "bare EditText construction:"; echo "$bare"; rc=1; fi
  if [ -n "$ext" ]; then echo "class extends EditText besides SafeEdit:"; echo "$ext"; rc=1; fi
  if [ -z "$safe" ]; then echo "control: no 'new SafeEdit(' found under $d/src or $d/mms"; rc=1; fi
  if [ "$n" != 2 ]; then echo "SafeEdit.withPaste( appears $n times, not 2:"; echo "$paste"; rc=1; fi
  if [ -n "$(grep -v '/src/com/nowhere/chooser/ProfileActivity\.java:' <<<"$paste" | grep . || true)" ]; then
    echo "SafeEdit.withPaste( outside ProfileActivity.java:"; grep -v '/src/com/nowhere/chooser/ProfileActivity\.java:' <<<"$paste"; rc=1
  fi
  if [ -n "$(grep '/ChooserActivity\.java:' <<<"$paste" || true)" ]; then echo "SafeEdit.withPaste( in the gate (ChooserActivity.java)"; rc=1; fi
  if [ -n "$(grep "^$d/mms/" <<<"$paste" || true)" ]; then echo "SafeEdit.withPaste( under mms"; rc=1; fi
  if [ "$(grep -cE '/ProfileActivity\.java:[0-9]+:.*\bnote[[:space:]]*=[[:space:]]*SafeEdit\.withPaste\(' <<<"$paste" || true)" != 1 ]; then
    echo "SafeEdit.withPaste( does not construct the report note exactly once"; rc=1
  fi
  if [ "$(grep -cE '/ProfileActivity\.java:[0-9]+:.*\bcodeF[[:space:]]*=[[:space:]]*SafeEdit\.withPaste\(' <<<"$paste" || true)" != 1 ]; then
    echo "SafeEdit.withPaste( does not construct the claim-code codeF exactly once"; rc=1
  fi
  return $rc
}

if [ "$MUTATE" = no ]; then
  out=$(scan "$HERE"); rc=$?
  if [ $rc -ne 0 ]; then echo "$out"; echo "FAIL"; exit 1; fi
  echo "PASS: no bare EditText in core/chooser/src or core/chooser/mms"
  exit 0
fi

out=$(scan "$HERE") || { echo "$out"; echo "FAIL: baseline tree is not clean"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0
mutant() { # $1 = name, $2 = mutation function
  local w="$TMP/$1"; mkdir -p "$w"
  cp -r "$HERE/src" "$w/src"; [ -d "$HERE/mms" ] && cp -r "$HERE/mms" "$w/mms"
  mkdir -p "$w/mms"
  "$2" "$w"
  if diff -rq "$HERE/src" "$w/src" >/dev/null && diff -rq "$HERE/mms" "$w/mms" >/dev/null 2>&1; then
    echo "FAIL: mutant $1 left the tree unchanged"; fail=1; return
  fi
  if scan "$w" >/dev/null 2>&1; then echo "FAIL: mutant $1 NOT convicted"; fail=1
  else echo "ok: mutant $1 convicted"; fi
}
m_profile() { printf 'class MutProfile { Object f(android.content.Context ctx) { return new EditText(this); } }\n' >> "$1/src/com/nowhere/chooser/ProfileActivity.java"; }
m_space()   { printf 'class MutSpace { Object f(android.content.Context ctx) { return new android.widget.EditText (ctx); } }\n' >> "$1/src/com/nowhere/chooser/ChooserActivity.java"; }
m_extends() { printf 'package com.nowhere.chooser;\nclass MutField extends android.widget.EditText { MutField(android.content.Context c) { super(c); } }\n' > "$1/src/com/nowhere/chooser/MutField.java"; }
m_sibling() { printf 'class MutSibling extends EditText { MutSibling(android.content.Context c) { super(c); } }\n' >> "$1/src/com/nowhere/chooser/SafeEdit.java"; }
m_sameline() { sed -i -E 's/^(public class SafeEdit extends EditText \{)/\1 } class MutSame extends EditText { MutSame() { super(null); }/' "$1/src/com/nowhere/chooser/SafeEdit.java"; }
m_mms()     { mkdir -p "$1/mms/com/mut"; printf 'class MutMms { Object f(android.content.Context c) { return new android.widget.EditText(c); } }\n' > "$1/mms/com/mut/MutMms.java"; }
m_control() { grep -rlE --exclude=SafeEdit.java 'new[[:space:]]+SafeEdit[[:space:]]*\(' "$1/src" "$1/mms" | xargs sed -i -E 's/new[[:space:]]+SafeEdit[[:space:]]*\(/new Other(/g'; }
m_paste_gate()  { printf 'class MutPasteGate { Object f(android.content.Context c) { return SafeEdit.withPaste(c); } }\n' >> "$1/src/com/nowhere/chooser/ChooserActivity.java"; }
m_paste_third() { printf 'class MutPasteThird { Object f(android.content.Context c) { return SafeEdit.withPaste(c); } }\n' >> "$1/src/com/nowhere/chooser/ProfileActivity.java"; }
m_paste_mms()   { mkdir -p "$1/mms/com/mut"; printf 'class MutPaste { Object f(android.content.Context c) { return SafeEdit.withPaste(c); } }\n' > "$1/mms/com/mut/MutPaste.java"; }
mutant profile m_profile
mutant space m_space
mutant extends m_extends
mutant sibling m_sibling
mutant sameline m_sameline
mutant mms m_mms
mutant control m_control
mutant paste_gate m_paste_gate
mutant paste_third m_paste_third
mutant paste_mms m_paste_mms
[ $fail -eq 0 ] && echo "PASS: all mutants convicted" || { echo "FAIL"; exit 1; }
