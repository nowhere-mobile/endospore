#!/usr/bin/env bash
# test-passreveal-remask.sh [<chooser src root>] [--mutate] -- a revealed credential never survives losing the foreground
# or a content-view swap (NWP-20261113-35).
#
# WHY THIS IS COMMITTED. The rule is #81's and DIA-20260817-03's (#730; Chester: "i made the wifi password visible and
# clicked next and i could see it until it went to next screen"). It holds only because every screen that wraps a field
# with PassReveal.wrap masks from the DECOR view in onPause and in its setContentView(View) override, and because
# PassReveal's own re-mask paths (maskAll, setToggleEnabled, setToggleVisible, setFieldVisible, the masked initial state)
# stay in place. No suite read any of it: drop the maskAll from ProfileActivity's setContentView override, or switch
# ChooserActivity's onPause back to masking gateView (which misses the owner-enrol, SIM-PIN and Wi-Fi screens), and every
# build step passes while a revealed passphrase stays painted for the next person who picks up the phone. The chooser
# has no unit-test harness, so these are source-level checks; CI executes this suite and its --mutate run.
#
# HOW IT CHECKS. The screens are FOUND BY GREP (every .java anywhere under the source root, core/chooser/src, holding
# `PassReveal.wrap(`), not listed, so a new screen is covered the day it wraps a field, in whatever directory it lands; the number of wrap sites is never counted, only "> 0". Each rule
# is a fixed-string match inside an extracted member with comment-only lines dropped, every extraction has a control
# that it is non-empty and starts at its signature, and each rule has a mutation that must convict the suite.
#
#   bash test-passreveal-remask.sh            # the invariants
#   bash test-passreveal-remask.sh --mutate   # ... plus mutations that must each CONVICT the suite
set -uo pipefail

MUTATE=no; SRC=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SRC="$a" ;; esac; done
SRC="${SRC:-$(dirname "$0")/src}"
[ -d "$SRC" ] || { echo "no such directory: $SRC" >&2; exit 2; }
# rel <basename>: the one file of that name under the source root, relative to it (the mutations reuse the path).
rel(){
    local hits
    hits=$(cd "$SRC" && find . -type f -name "$1" | sed 's|^\./||')
    [ -n "$hits" ] && [ "$(printf '%s\n' "$hits" | awk 'END { print NR }')" = 1 ] || { echo "not exactly one $1 under $SRC" >&2; exit 2; }
    printf '%s\n' "$hits"
}
PRR=$(rel PassReveal.java) || exit 2; CAR=$(rel ChooserActivity.java) || exit 2; PAR=$(rel ProfileActivity.java) || exit 2
QSR=$(rel QrScanActivity.java) || exit 2
PR="$SRC/$PRR"; CA="$SRC/$CAR"
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c`, `awk` without an early exit on a pipe, never `grep -q`.

# body <file> <signature fragment> <indent>: the member's lines, from its signature to the first line that is exactly
# "<indent>}" -- or a marker that fails every check when the signature does not occur exactly once.
body(){
    local f="$1" sig="$2" ind="$3"
    [ "$(grep -cF -- "$sig" "$f")" = 1 ] || { echo "<signature not exactly once: $sig>"; return; }
    awk -v sig="$sig" -v end="$ind}" 'index($0, sig) { on = 1 } on { print } on && $0 == end { exit }' "$f"
}
# code <text>: the text without its comment-only lines.
code(){ printf '%s\n' "$1" | grep -v '^[[:space:]]*//'; }
# line <text> <fixed string>: the 1-based line of its first match, or 0.
line(){ printf '%s\n' "$1" | awk -v s="$2" 'index($0, s) && !n { n = NR } END { print n + 0 }'; }
# count <text> <fixed string>: how many lines contain it.
count(){ printf '%s\n' "$1" | grep -cF -- "$2"; }
# both <text> <s1> <s2>: how many lines contain both fixed strings.
both(){ printf '%s\n' "$1" | awk -v a="$2" -v b="$3" 'index($0, a) && index($0, b) { n++ } END { print n + 0 }'; }
# extracted <name> <text> <signature>: the control -- the extraction is non-empty and its first line is the signature.
extracted(){
    local first
    first=$(printf '%s\n' "$2" | awk 'NR == 1')
    if [ -n "$2" ] && [ "$(count "$first" "$3")" = 1 ] && [ "$(printf '%s\n' "$2" | awk 'END { print NR }')" -gt 1 ]; then
        ok "control: $1 extracted"
    else
        no "control: $1 not extracted"
    fi
}

echo "== every screen that wraps a field is found =="
FILES=$(grep -rlF --include='*.java' 'PassReveal.wrap(' "$SRC" | grep -v '/PassReveal\.java$')
NAMES=$(printf '%s\n' "$FILES" | awk -F/ 'NF { print $NF }')
for n in ChooserActivity.java ProfileActivity.java; do
    if [ "$(printf '%s\n' "$NAMES" | grep -cxF -- "$n")" = 1 ]; then ok "control: $n wraps a field and is checked"; else no "control: $n is not found by the PassReveal.wrap( grep"; fi
done

echo "== each such screen masks from the decor view on pause and before every content-view swap =="
check_screen(){
    local f="$1" n op opc sc scc m s
    n=$(basename "$f")
    if [ "$(grep -cF 'PassReveal.wrap(' "$f")" -gt 0 ]; then ok "control: $n has a PassReveal.wrap( site"; else no "control: $n has no PassReveal.wrap( site"; fi
    op=$(body "$f" 'protected void onPause() {' '    ')
    extracted "$n onPause" "$op" 'protected void onPause() {'
    opc=$(code "$op")
    if [ "$(both "$opc" 'PassReveal.maskAll(' 'getWindow().getDecorView()')" -ge 1 ]; then
        ok "$n onPause masks from getWindow().getDecorView()"
    else
        no "$n onPause has no PassReveal.maskAll( from getWindow().getDecorView() -- a revealed credential survives losing the foreground"
    fi
    sc=$(body "$f" 'public void setContentView(android.view.View view) {' '    ')
    extracted "$n setContentView(View) override" "$sc" 'public void setContentView(android.view.View view) {'
    scc=$(code "$sc")
    m=$(line "$scc" 'PassReveal.maskAll(getWindow().getDecorView())'); s=$(line "$scc" 'super.setContentView(view);')
    if [ "$m" -gt 0 ] && [ "$s" -gt 0 ] && [ "$m" -lt "$s" ]; then
        ok "$n setContentView(View) masks the outgoing tree before super.setContentView(view)"
    else
        no "$n setContentView(View) does not mask from the decor view before super.setContentView(view) (mask $m, super $s)"
    fi
    if [ "$(grep -cF 'setContentView(R.' "$f")" = 0 ]; then
        ok "$n never sets a layout id, so the View override is complete coverage"
    else
        no "$n calls setContentView(R.…) -- that swap bypasses the View override's mask"
    fi
}
while IFS= read -r F; do
    [ -n "$F" ] && check_screen "$F"
done <<EOF_FILES
$FILES
EOF_FILES

echo "== ChooserActivity's onPause masks the decor view, not gateView alone =="
if [ "$(grep -cF 'PassReveal.maskAll(gateView)' "$CA")" = 0 ]; then ok "no gateView-only maskAll"; else no "PassReveal.maskAll(gateView) misses the owner-enrol, SIM-PIN and Wi-Fi screens"; fi

echo "== PassReveal's re-mask paths =="
# pr_has <name> <signature> <indent> <fixed string> <why it matters>
pr_has(){
    local b
    b=$(body "$PR" "$2" "$3")
    extracted "PassReveal $1" "$b" "$2"
    if [ "$(count "$(code "$b")" "$4")" -ge 1 ]; then ok "PassReveal $1 holds: $4"; else no "PassReveal $1 lost: $4 -- $5"; fi
}
pr_has maskAll 'static void maskAll(View root) {' '    ' \
    'if (root instanceof RevealBox) { ((RevealBox) root).setRevealed(false); return; }' 'a wrapped field is never re-masked'
pr_has maskAll 'static void maskAll(View root) {' '    ' \
    'for (int i = 0; i < g.getChildCount(); i++) maskAll(g.getChildAt(i));' 'a field below the root is never reached'
pr_has 'RevealBox.setToggleEnabled' 'void setToggleEnabled(boolean enabled, float alpha) {' '        ' \
    'if (!enabled && revealed) setRevealed(false);' 'lockGateForm greys the toggle and leaves the credential painted'
pr_has 'RevealBox.setToggleVisible' 'void setToggleVisible(boolean visible) {' '        ' \
    'if (!visible && revealed) setRevealed(false);' 'a hidden toggle leaves the credential revealed with no way to hide it'
pr_has setFieldVisible 'static void setFieldVisible(EditText f, boolean visible) {' '    ' \
    'if (!visible && b != null) b.setRevealed(false);' 'a hidden field comes back revealed on its next show'
pr_has applyState 'private void applyState() {' '        ' \
    'TransformationMethod tm = revealed ? null : PasswordTransformationMethod.getInstance();' 'a masked box shows plain text'
if [ "$(grep -cF 'private boolean revealed = false;' "$PR")" = 1 ]; then ok "a RevealBox starts masked"; else no "RevealBox does not start masked (private boolean revealed = false;)"; fi

if [ "$MUTATE" = yes ]; then
    echo "== mutations (each must CONVICT the suite) =="
    # mutate <label> <file path under the root> <sed script>: a copy of the whole source root under $W with one file
    # mutated; the suite run on it must exit 1. A mutation that does not change its file, or a child that errors out,
    # is a FAILURE.
    mutate(){
        local label="$1" file="$2" script="$3" d
        d=$(mktemp -d -p "$W") || { no "MUTATION BROKEN (mktemp): $label"; return; }
        if ! cp -R "$SRC/." "$d/" || ! sed -i "$script" "$d/$file"; then no "MUTATION BROKEN (copy/sed): $label"; rm -rf "$d"; return; fi
        if cmp -s "$d/$file" "$SRC/$file"; then no "MUTATION DID NOT APPLY: $label"; rm -rf "$d"; return; fi
        convict "$label" "$d"
    }
    # convict <label> <mutated root>: run the suite on it, which must exit 1, then remove it.
    convict(){
        local label="$1" d="$2" rc
        bash "$0" "$d" >/dev/null 2>&1; rc=$?
        case $rc in
            1) ok "convicted: $label" ;;
            0) no "NOT CONVICTED: $label -- the suite passes on broken code" ;;
            *) no "MUTATION BROKEN (child exit $rc): $label" ;;
        esac
        rm -rf "$d"
    }
    mutate "M1 ProfileActivity setContentView(View) loses its maskAll" "$PAR" \
        '/public void setContentView(android.view.View view) {/,/^    }$/{/PassReveal.maskAll(/d}'
    mutate "M2 ChooserActivity onPause masks gateView instead of the decor view" "$CAR" \
        's/PassReveal.maskAll(getWindow() != null ? getWindow().getDecorView() : gateView);/PassReveal.maskAll(gateView);/'
    mutate "M3 ChooserActivity setContentView(View) masks after super.setContentView" "$CAR" \
        '/public void setContentView(android.view.View view) {/,/^    }$/{/PassReveal.maskAll(/d;s/^\(        \)super.setContentView(view);$/&\n\1if (getWindow() != null) PassReveal.maskAll(getWindow().getDecorView());/}'
    mutate "M4 setToggleEnabled loses its re-mask" "$PRR" '/if (!enabled && revealed) setRevealed(false);/d'
    mutate "M5 setToggleVisible loses its re-mask" "$PRR" '/if (!visible && revealed) setRevealed(false);/d'
    mutate "M6 setFieldVisible loses its re-mask" "$PRR" '/if (!visible && b != null) b.setRevealed(false);/d'
    mutate "M7 a RevealBox starts revealed" "$PRR" 's/private boolean revealed = false;/private boolean revealed = true;/'
    mutate "M8 maskAll stops recursing into ViewGroups" "$PRR" \
        '/for (int i = 0; i < g.getChildCount(); i++) maskAll(g.getChildAt(i));/d'
    mutate "M9 a new screen (QrScanActivity) wraps a field and never masks" "$QSR" \
        's/^\(        \)setContentView(root);$/&\n\1android.view.View nwpRevealProbe = PassReveal.wrap(new android.widget.EditText(this), 0);/'
    # M10: the same kind of new screen, in a directory of its own outside com/nowhere/chooser (Java takes the package
    # from the file, not its path), so the grep must search the whole source root.
    m10="M10 a new screen outside the package directory wraps a field and never masks"
    d=$(mktemp -d -p "$W") || d=""
    if [ -z "$d" ] || ! cp -R "$SRC/." "$d/" || ! mkdir -p "$d/extra" || [ -e "$d/extra/NwpRevealProbeActivity.java" ]; then
        no "MUTATION BROKEN (copy): $m10"; [ -z "$d" ] || rm -rf "$d"
    else
        cat > "$d/extra/NwpRevealProbeActivity.java" <<'EOF_PROBE'
package com.nowhere.chooser;

public class NwpRevealProbeActivity extends android.app.Activity {
    @Override
    protected void onCreate(android.os.Bundle b) {
        super.onCreate(b);
        setContentView(PassReveal.wrap(new android.widget.EditText(this), 0));
    }
}
EOF_PROBE
        convict "$m10" "$d"
    fi
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ] || exit 1
