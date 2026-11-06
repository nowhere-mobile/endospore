#!/usr/bin/env bash
# test-safe-edit-paste-java.sh [--mutate] -- NWP-20261114-21 (Q041, docs/product-decisions.md 2026-10-20): paste
# comes back in the Profile app's report and claim-code boxes, and only there, and only while ClipboardManager is
# reachable. SafeEdit.pasteAllowed is compiled and EXECUTED (core/chooser/tests/safe-edit-paste/run.sh says how);
# the rest of SafeEdit is Android code, so it is pinned at the source.
#
# WHY THIS IS COMMITTED. The clipboard_service find for nowhere_chooser (nowhere.te) is a separate slice, so this
# class ships first, on images where a denied find makes getSystemService(ClipboardManager.class) return null and
# TextView.canPaste() dies on that null. So a withPaste box must offer paste only while the manager is non-null,
# asked at each call and never cached; and every other SafeEdit must also refuse the keyboard and IME paths
# (onKeyShortcut Ctrl+V/X/C, onKeyDown KEYCODE_PASTE/CUT/COPY, onTextContextMenuItem paste/pasteAsPlainText/cut/
# copy) before super, which no SafeEdit closed before this slice (inferred from AOSP source, not seen on a device).
#
# The pins read SafeEdit.java with /* */ and // comments stripped; a control pin asserts the stripped file holds no
# string literal, so a // inside a literal cannot fool the stripper.
#
# It needs a JDK, and it FAILS when there is none. javac/java come from PATH, then the build VM's prebuilt JDK 21.
# --mutate re-runs it against deliberately broken copies, each of which must fail a CASE or a PIN.
#
#   bash test-safe-edit-paste-java.sh            # the cases and the pins
#   bash test-safe-edit-paste-java.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail
MUTATE=no; for a in "$@"; do [ "$a" = --mutate ] && MUTATE=yes; done
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
CH="$ROOT/core/chooser"
RUN="$CH/tests/safe-edit-paste/run.sh"
SE="$CH/src/com/nowhere/chooser/SafeEdit.java"
VMJDK=/mnt/build/lineage/prebuilts/jdk/jdk21/linux-x86/bin
if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
  JAVAC=$(command -v javac); JAVA=$(command -v java)
elif [ -x "$VMJDK/javac" ] && [ -x "$VMJDK/java" ]; then
  JAVAC=$VMJDK/javac; JAVA=$VMJDK/java
else
  echo "test-safe-edit-paste-java: FAIL -- no javac/java on PATH or in $VMJDK; this suite did NOT run" >&2
  exit 2
fi
"$JAVAC" -version 2>&1 | sed 's/^/using /' # proves which compiler ran
export JAVAC JAVA
# One root: every temp of this suite lives inside $W (run.sh makes and removes its own inside it).
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export W

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# strip_comments <file>: the file with /* ... */ (across lines) and // to end of line removed
strip_comments(){
  awk '
    { out=""; i=1; L=$0; n=length(L)
      while (i <= n) {
        if (inc) { j=index(substr(L, i), "*/"); if (j == 0) i=n+1; else { i+=j+1; inc=0 } }
        else { two=substr(L, i, 2)
          if (two == "/*") { inc=1; i+=2 } else if (two == "//") break; else { out=out substr(L, i, 1); i++ } }
      }
      print out }
  ' "$1"
}
# brace_block <file> <signature prefix>: from the line that starts with it to the brace that closes it, joined
brace_block(){
  awk -v sig="$2" '
    !on && index($0, sig) == 1 { on=1; depth=0 }
    on { print; n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c; if (depth==0 && n+c>0) exit }
  ' "$1" | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
}
# class_decls <file>: the statements at class depth 1 (fields), trimmed
class_decls(){
  awk '
    { l=$0; if (depth == 1 && l ~ /;[[:space:]]*$/) { sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]+$/, "", l); print l }
      n=gsub(/\{/,"{"); c=gsub(/\}/,"}"); depth+=n-c }
  ' "$1"
}
S_SAM1='    @Override public android.view.ActionMode startActionMode(android.view.ActionMode.Callback cb) {'
S_SAM2='    @Override public android.view.ActionMode startActionMode(android.view.ActionMode.Callback cb, int type) {'
S_A11YI='    @Override public void onInitializeAccessibilityNodeInfo(android.view.accessibility.AccessibilityNodeInfo info) {'
S_A11YP='    @Override public boolean performAccessibilityAction(int action, android.os.Bundle args) {'
S_KS='    @Override public boolean onKeyShortcut(int keyCode, KeyEvent e) {'
S_KD='    @Override public boolean onKeyDown(int keyCode, KeyEvent e) {'
S_TM='    @Override public boolean onTextContextMenuItem(int id) {'
S_CTOR='    public SafeEdit(Context c) {'
S_ALLOWED='    private boolean allowed() {'
S_REACH='    private boolean clipboardReachable() {'
S_WITH='    static SafeEdit withPaste(Context c) {'

# refuses <body> <refusal> <super call> <regex...>: the text before the first <refusal> matches every regex, names
# allowed(), and <refusal> comes before <super call>
refuses(){
  local body=$1 refusal=$2 sup=$3 pre re
  shift 3
  [[ $body == *"$refusal"* ]] || return 1
  pre=${body%%"$refusal"*}
  [[ $pre =~ (^|[^A-Za-z0-9_])allowed\(\) ]] || return 1
  [[ $pre == *"$sup"* ]] && return 1
  [[ $body == *"$sup"* ]] || return 1
  for re in "$@"; do [[ $pre =~ $re ]] || return 1; done
  return 0
}
# pins <file>: prints one "ok|no <label>" per pin
pins(){
  local s label sig body decls
  s=$(mktemp -p "$W")
  strip_comments "$1" > "$s"
  if [[ $(<"$s") == *'"'* ]]; then echo "no control: SafeEdit.java holds a string literal"; else echo "ok control: SafeEdit.java holds no string literal"; fi
  for label in "startActionMode(Callback):$S_SAM1" "startActionMode(Callback, int):$S_SAM2" \
      "onInitializeAccessibilityNodeInfo:$S_A11YI" "performAccessibilityAction:$S_A11YP" \
      "onKeyShortcut:$S_KS" "onKeyDown:$S_KD" "onTextContextMenuItem:$S_TM"; do
    sig=${label#*:    }; sig="    $sig"; label=${label%%:    *}
    body=$(brace_block "$s" "$sig")
    if [ -n "$body" ] && [[ $body =~ (^|[^A-Za-z0-9_])allowed\(\) ]]; then echo "ok $label consults allowed()"; else echo "no $label does not extract or does not consult allowed()"; fi
  done
  body=$(brace_block "$s" "$S_KS")
  if refuses "$body" 'return true;' 'super.onKeyShortcut(' 'KeyEvent\.KEYCODE_V([^A-Za-z0-9_]|$)' 'KeyEvent\.KEYCODE_X([^A-Za-z0-9_]|$)' \
      'KeyEvent\.KEYCODE_C([^A-Za-z0-9_]|$)' 'isCtrlPressed\(\)'; then
    echo "ok onKeyShortcut refuses Ctrl+V, X and C before super"
  else echo "no onKeyShortcut does not refuse Ctrl+V, X and C before super"; fi
  body=$(brace_block "$s" "$S_KD")
  if refuses "$body" 'return true;' 'super.onKeyDown(' 'KeyEvent\.KEYCODE_PASTE([^A-Za-z0-9_]|$)' 'KeyEvent\.KEYCODE_CUT([^A-Za-z0-9_]|$)' \
      'KeyEvent\.KEYCODE_COPY([^A-Za-z0-9_]|$)'; then
    echo "ok onKeyDown refuses KEYCODE_PASTE, CUT and COPY before super"
  else echo "no onKeyDown does not refuse KEYCODE_PASTE, CUT and COPY before super"; fi
  body=$(brace_block "$s" "$S_TM")
  if refuses "$body" 'return false;' 'super.onTextContextMenuItem(' 'android\.R\.id\.paste([^A-Za-z0-9_]|$)' \
      'android\.R\.id\.pasteAsPlainText([^A-Za-z0-9_]|$)' 'android\.R\.id\.cut([^A-Za-z0-9_]|$)' 'android\.R\.id\.copy([^A-Za-z0-9_]|$)'; then
    echo "ok onTextContextMenuItem refuses paste, pasteAsPlainText, cut and copy before super"
  else echo "no onTextContextMenuItem does not refuse paste, pasteAsPlainText, cut and copy before super"; fi
  decls=$(class_decls "$s")
  if [ "$decls" = 'private final boolean pasteWanted;' ]; then echo "ok the one field is pasteWanted (no ClipboardManager, no reachability boolean)"
  else echo "no the class fields are not exactly pasteWanted: $(tr '\n' ' ' <<<"$decls")"; fi
  body=$(brace_block "$s" "$S_CTOR")
  if [ "$body" = 'public SafeEdit(Context c) { this(c, false); }' ]; then echo "ok the public constructor leaves pasteWanted false"; else echo "no the public constructor is not this(c, false): $body"; fi
  body=$(brace_block "$s" "$S_WITH")
  if [[ $body == *'new SafeEdit(c, true);'* ]] && [ "$(grep -c 'new SafeEdit(c, true)' "$s" || true)" = 1 ]; then echo "ok only withPaste builds a box that wants paste"
  else echo "no withPaste is not the one builder of new SafeEdit(c, true)"; fi
  body=$(brace_block "$s" "$S_ALLOWED")
  if [ "$body" = 'private boolean allowed() { return pasteAllowed(pasteWanted, clipboardReachable()); }' ]; then echo "ok allowed() decides through pasteAllowed and a fresh reachability check"
  else echo "no allowed() is not pasteAllowed(pasteWanted, clipboardReachable()): $body"; fi
  body=$(brace_block "$s" "$S_REACH")
  if [[ $body == *'try { return getContext().getSystemService(android.content.ClipboardManager.class) != null; } catch (Throwable t) { return false; }'* ]]; then
    echo "ok clipboardReachable asks getSystemService each call, and a throw is unreachable"
  else echo "no clipboardReachable does not ask getSystemService(ClipboardManager.class) under try/catch"; fi
}
run_pins(){ # run_pins <file>: ok/no lines to the counters; returns 1 if any pin failed
  local line bad=0
  while IFS= read -r line; do
    case "$line" in ok\ *) ok "${line#ok }" ;; *) no "${line#no }"; bad=1 ;; esac
  done < <(pins "$1")
  return $bad
}
any_no(){ # any_no <file>: true when a pin fails
  local out
  out=$(pins "$1")
  [[ $'\n'$out == *$'\n'no\ * ]]
}

echo "== the cases =="
bash "$RUN" "$SE"; rc=$?
if [ "$rc" = 0 ]; then ok "every case passes"; else no "the suite did not pass (run.sh exit $rc: 1 a case, 2 cannot run, 3 no compile)"; fi
echo "== the SafeEdit pins =="
run_pins "$SE"; prc=$?
# a comment line added inside onKeyShortcut changes no pinned code
cp "$SE" "$W/probe.java"
sed -i "s|^$S_KS\$|&\n        // probe: a comment inside onKeyShortcut, return true; super.onKeyShortcut(|" "$W/probe.java"
if cmp -s "$W/probe.java" "$SE"; then no "probe copy is inert"; elif any_no "$W/probe.java"; then no "a comment inside onKeyShortcut broke a pin"; else ok "a comment added inside onKeyShortcut leaves the pins green"; fi

if [ "$MUTATE" = yes ] && [ "$rc" = 0 ] && [ "$prc" = 0 ]; then
  echo
  echo "== mutations (each MUST be convicted by a case or a pin) =="
  mutate(){ # mutate <kind case|pin> <label> <sed script>
    local kind=$1 label=$2 script=$3 r
    rm -rf "$W/c"; mkdir -p "$W/c"
    cp "$SE" "$W/c/SafeEdit.java"
    if ! sed -i "$script" "$W/c/SafeEdit.java" 2>"$W/err"; then no "MUTATION BROKEN (sed): $label"; return; fi
    if cmp -s "$W/c/SafeEdit.java" "$SE"; then no "MUTATION INERT: $label"; return; fi
    if [ "$kind" = case ]; then
      bash "$RUN" "$W/c/SafeEdit.java" >/dev/null 2>&1; r=$?
      case "$r" in
        1) ok "convicted: $label" ;;
        0) no "NOT CONVICTED: $label -- suite passes on broken code" ;;
        *) no "MUTATION BROKEN (run.sh exit $r, not a case): $label" ;;
      esac
    else
      if any_no "$W/c/SafeEdit.java"; then ok "convicted: $label"; else no "NOT CONVICTED: $label -- the pins pass on broken code"; fi
    fi
  }
  mutate case "pasteAllowed returns pasteWanted alone" 's/return pasteWanted && clipboardReachable;/return pasteWanted;/'
  mutate case "pasteAllowed returns reachability alone" 's/return pasteWanted && clipboardReachable;/return clipboardReachable;/'
  mutate pin "reachability cached in a field" 's/^    private final boolean pasteWanted;$/&\n    private boolean reachable = true;/'
  mutate pin "a ClipboardManager held in a field" 's/^    private final boolean pasteWanted;$/&\n    private android.content.ClipboardManager cm;/'
  mutate pin "onTextContextMenuItem calls super for paste when not allowed" "/^$S_TM\$/,/^    }\$/ s/return false;/return super.onTextContextMenuItem(id);/"
  mutate pin "onKeyShortcut's KEYCODE_V refusal removed" 's/keyCode == KeyEvent.KEYCODE_V || //'
  mutate pin "onKeyDown's KEYCODE_PASTE refusal removed" 's/keyCode == KeyEvent.KEYCODE_PASTE || //'
  mutate pin "the public constructor wants paste" 's/this(c, false);/this(c, true);/'
  mutate pin "startActionMode returns super unconditionally" 's/return allowed() ? super.startActionMode(cb) : null;/return super.startActionMode(cb);/'
  mutate pin "the accessibility strip skipped for every box" 's/^        if (allowed()) return;$/        if (true) return;/'
  mutate pin "onKeyShortcut calls super before refusing" "/^$S_KS\$/a\\        super.onKeyShortcut(keyCode, e);"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
