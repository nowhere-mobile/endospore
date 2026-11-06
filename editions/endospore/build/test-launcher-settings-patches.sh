#!/usr/bin/env bash
# test-launcher-settings-patches.sh [--mutate] [<patch script>...] -- NWP-20261026-29.
#
# WHY THIS IS COMMITTED. launcher3-no-autoadd-home.sh (Launcher3QuickStep.apk) and settings-fallbackhome-resume.sh
# (Settings.apk) are applied to every Endospore build by build-device.sh's patch glob and are exempt from the
# artifact check (patch-markers.tsv), yet no suite executed either. launcher3's only guard against a sed that
# matched nothing is its own end-state check (exit 1); fallbackhome's only guard against a double patch is its
# marker, and its two anchors are required exactly once. An edit to either shipped green until now.
#
# These cases run each script on SYNTHETIC trees built from the script's own anchor text (extracted from the script
# under test, so a mutant copy extracts from itself): apply, idempotent re-run and every refusal. They cannot show
# that the anchors still match the real GrapheneOS tree -- that is checked on the build host
# (docs/framework-patches.md). Bash only: both scripts are bash, run by build-device.sh as `bash "$p"` and never on
# the device, so the dash/mksh loop does not apply. Needs python3. CI runs it plain and with --mutate.
#
#   bash test-launcher-settings-patches.sh              # both scripts under editions/endospore/build/patches
#   bash test-launcher-settings-patches.sh --mutate     # ... plus mutants that must each CONVICT the suite
#   bash test-launcher-settings-patches.sh <script>...  # just those (the kind is inferred from the basename)
set -uo pipefail

MUTATE=no; SUTS=()
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) SUTS+=("$a") ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
PDIR="$HERE/patches"
if [ ${#SUTS[@]} = 0 ]; then SUTS=("$PDIR/launcher3-no-autoadd-home.sh" "$PDIR/settings-fallbackhome-resume.sh"); fi

command -v python3 >/dev/null || { echo "python3 is required"; exit 2; }
python3 --version

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
# ⚠ Every match reads its input to the end: `grep -c ... >/dev/null`, never `grep -q` (see test-owner-key.sh).
kind(){ case "$(basename "$1")" in launcher3-no-autoadd-home.sh) echo launcher ;; settings-fallbackhome-resume.sh) echo fallback ;; *) echo unknown ;; esac; }
said(){ grep -cF -- "$2" "$W/$1.out" >/dev/null; }
has(){ grep -cF -- "$2" "$1" >/dev/null; }
lacks(){ ! grep -cF -- "$2" "$1" >/dev/null; }
same(){ cmp -s "$1" "$2"; }
# run <sut> <tree>: run the script on $W/<tree>, output to $W/<tree>.out, echo its exit code.
run(){ bash "$1" "$W/$2" > "$W/$2.out" 2>&1; echo $?; }
# check <label> <rc> <want rc> <output needle>: one case line.
check(){ if [ "$2" = "$3" ] && { [ -z "$4" ] || said "$5" "$4"; }; then ok "$1"; else no "$1 (exit $2, want $3)"; fi; }

KT=packages/apps/Launcher3/src/com/android/launcher3/util/DefaultsValueProvider.kt
XML=packages/apps/Launcher3/res/xml/launcher_preferences.xml
FH=packages/apps/Settings/src/com/android/settings/FallbackHome.java

# extract <sut> <kind> <outdir>: the anchor text the fixtures are built from, read out of the script itself.
extract(){
  python3 -I - "$1" "$2" "$3" <<'PY'
import ast, io, os, re, sys
sut, kind, out = sys.argv[1:4]
s = io.open(sut, encoding='utf-8').read()
os.makedirs(out, exist_ok=True)
def fail(what):
    print("EXTRACTION FAILED: " + what); sys.exit(2)
def one(pat, what):
    m = re.findall(pat, s, re.M)
    if len(m) != 1: fail(what)
    return m[0]
def put(name, text):
    io.open(os.path.join(out, name), 'w', encoding='utf-8', newline='\n').write(text)
if kind == 'launcher':
    put('kt_true', one(r"^if grep -q '([^']+)' \"\$DVP\"; then$", "the .kt TRUE anchor"))
    put('kt_false', one(r"^elif grep -q '([^']+)' \"\$DVP\"; then$", "the .kt FALSE anchor"))
    put('pref', one(r"^if grep -q '([^']+)' \"\$PREFS\"; then$", "the preference key"))
    m = re.findall(r"s/(android:defaultValue=\"true\")/(android:defaultValue=\"false\")/", s)
    if len(m) != 1: fail("the XML default sed")
    put('xml_true', m[0][0]); put('xml_false', m[0][1])
else:
    body = re.findall(r"<<'PY'\n(.*?)\nPY\n", s, re.S)
    if len(body) != 1: fail("the python heredoc")
    # the marker is read from the injected text, not the skip line, so a mutant that drops the skip still extracts
    marker = re.findall(r"// (nowhere-resume \(NWP-\d+-\d+\)):", body[0])
    if len(marker) != 1: fail("the marker in the injected text")
    marker = marker[0]
    try: tree = ast.parse(body[0])
    except SyntaxError: fail("the heredoc does not parse")
    found = {}
    for n in tree.body:
        if isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name) \
                and n.targets[0].id in ('anchor', 'anchor2'):
            try: found[n.targets[0].id] = ast.literal_eval(n.value)
            except Exception: fail("anchor value is not a literal")
    if sorted(found) != ['anchor', 'anchor2']: fail("anchor / anchor2 assignments")
    put('marker', marker); put('a1', found['anchor']); put('a2', found['anchor2'])
PY
}
rd(){ cat "$W/anchors/$1"; }

# --- fixtures -------------------------------------------------------------------------------------------
# tree_kt <name> true|false|drift   /   tree_xml <name> pristine|nopref|spaced
tree_kt(){
  mkdir -p "$W/$1/$(dirname "$KT")"
  {
    echo 'package com.android.launcher3.util'
    echo 'open class BaseDefaultsValueProvider : DefaultsValueProvider {'
    echo '    override val neighbour: Boolean = true'
    case "$2" in
      true) printf '    %s\n' "$(rd kt_true)" ;;
      false) printf '    %s\n' "$(rd kt_false)" ;;
      drift) echo '    override val addIconToHome: Boolean = Flags.addIconToHome()' ;;
    esac
    echo '}'
  } > "$W/$1/$KT"
}
tree_xml(){
  mkdir -p "$W/$1/$(dirname "$XML")"
  local key dv; key="$(rd pref)"; dv="$(rd xml_true)"
  [ "$2" = nopref ] && key="pref_renamed_by_upstream"
  [ "$2" = spaced ] && dv='android:defaultValue = "true"'
  {
    echo '<PreferenceScreen xmlns:android="http://schemas.android.com/apk/res/android">'
    echo '    <SwitchPreference'
    echo "        android:key=\"$key\""
    echo '        android:title="Add icon to Home screen"'
    echo "        $dv"
    echo '        android:persistent="true" />'
    echo '    <SwitchPreference'
    echo '        android:key="pref_allowRotation"'
    echo '        android:defaultValue="true"'
    echo '        android:persistent="true" />'
    echo '</PreferenceScreen>'
  } > "$W/$1/$XML"
}
tree_launcher(){ tree_kt "$1" "$2"; tree_xml "$1" "$3"; }
# pblock <xml>: the target preference block, scoped the way the script scopes its sed.
pblock(){ sed -n "/$(rd pref)/,/\\/>/p" "$1"; }

# tree_fh <name> pristine|a1-missing|a2-missing|a1-dup|a2-dup
tree_fh(){
  mkdir -p "$W/$1/$(dirname "$FH")"
  # $(...) strips trailing newlines, which the anchors end in: append a sentinel and cut it off.
  local a1 a2; a1="$(rd a1; echo x)"; a1="${a1%x}"; a2="$(rd a2; echo x)"; a2="${a2%x}"
  [ "$2" = a1-missing ] && a1='    protected void onCreate(Bundle icicle) {
        super.onCreate(icicle);
'
  [ "$2" = a2-missing ] && a2='    private final Runnable mProgressTimeout = () -> {
'
  {
    echo 'package com.android.settings;'
    echo 'public class FallbackHome extends Activity {'
    printf '%s' "$a2"; echo '        mHandler.removeCallbacks(null);'; echo '    };'
    echo '    @Override'
    printf '%s' "$a1"; echo '        mHandler.post(null);'; echo '    }'
    [ "$2" = a1-dup ] && { echo '    class Helper {'; printf '%s' "$a1"; echo '    }'; echo '    }'; }
    [ "$2" = a2-dup ] && { printf '%s' "$a2"; echo '    };'; }
    echo '}'
  } > "$W/$1/$FH"
}

# --- cases -----------------------------------------------------------------------------------------------
cases_launcher(){
  local sut="$1" rc t
  # (a) pristine
  tree_launcher a true pristine; rc=$(run "$sut" a)
  if [ "$rc" = 0 ] && has "$W/a/$KT" "$(rd kt_false)" && lacks "$W/a/$KT" "$(rd kt_true)" \
     && pblock "$W/a/$XML" | grep -cF -- "$(rd xml_false)" >/dev/null && ! pblock "$W/a/$XML" | grep -cF -- "$(rd xml_true)" >/dev/null \
     && has "$W/a/$XML" 'android:key="pref_allowRotation"' && said a 'launcher3-no-autoadd-home: OK'; then
    ok "(a) pristine: exit 0, both defaults false, OK"
  else no "(a) pristine: exit $rc, or a default not false, or no OK"; fi
  if [ "$(sed -n '/pref_allowRotation/,/\/>/p' "$W/a/$XML" | grep -cF 'android:defaultValue="true"')" = 1 ]; then
    ok "(a) the neighbouring preference keeps its true default"
  else no "(a) the sed reached beyond the target preference block"; fi
  # (b) re-run
  cp "$W/a/$KT" "$W/b.kt"; cp "$W/a/$XML" "$W/b.xml"; rc=$(run "$sut" a)
  if [ "$rc" = 0 ] && said a 'already false (idempotent)' && same "$W/a/$KT" "$W/b.kt" && same "$W/a/$XML" "$W/b.xml"; then
    ok "(b) re-run: exit 0, already false (idempotent), both files byte-identical"
  else no "(b) re-run: exit $rc, or not idempotent, or a file changed"; fi
  # (c) anchors missing
  tree_launcher c1 drift pristine; cp "$W/c1/$KT" "$W/c1.kt"; cp "$W/c1/$XML" "$W/c1.xml"; rc=$(run "$sut" c1)
  if [ "$rc" = 2 ] && said c1 'addIconToHome anchor not found' && same "$W/c1/$KT" "$W/c1.kt" && same "$W/c1/$XML" "$W/c1.xml"; then
    ok "(c) .kt anchor missing: exit 2, nothing written"
  else no "(c) .kt anchor missing: exit $rc, or a file changed"; fi
  tree_launcher c2 true nopref; cp "$W/c2/$XML" "$W/c2.xml"; rc=$(run "$sut" c2)
  if [ "$rc" = 2 ] && said c2 'pref_add_icon_to_home not found' && same "$W/c2/$XML" "$W/c2.xml"; then
    ok "(c) preference missing: exit 2, the XML untouched"
  else no "(c) preference missing: exit $rc, or the XML changed"; fi
  # (d) default spelled so the sed cannot match: the end-state check is the only guard
  tree_launcher d true spaced; rc=$(run "$sut" d)
  check "(d) switch default unmatchable: exit 1, switch default is still true" "$rc" 1 'switch default is still true' d
  # (e) either file missing
  tree_launcher e1 true pristine; rm "$W/e1/$KT"; cp "$W/e1/$XML" "$W/e1.xml"; rc=$(run "$sut" e1)
  if [ "$rc" = 2 ] && said e1 'upstream moved it' && same "$W/e1/$XML" "$W/e1.xml"; then ok "(e) .kt missing: exit 2, upstream moved it"
  else no "(e) .kt missing: exit $rc"; fi
  tree_launcher e2 true pristine; rm "$W/e2/$XML"; cp "$W/e2/$KT" "$W/e2.kt"; rc=$(run "$sut" e2)
  if [ "$rc" = 2 ] && said e2 'upstream moved it' && same "$W/e2/$KT" "$W/e2.kt"; then ok "(e) .xml missing: exit 2, upstream moved it"
  else no "(e) .xml missing: exit $rc"; fi
}

cases_fallback(){
  local sut="$1" rc t marker n
  marker="$(rd marker)"
  # (f) pristine
  tree_fh f pristine; rc=$(run "$sut" f)
  n=$(grep -cF -- "$marker" "$W/f/$FH")
  if [ "$rc" = 0 ] && [ "$n" = 1 ] \
     && python3 -I - "$W/f/$FH" "$W/anchors" <<'PY'
import io, sys
s = io.open(sys.argv[1], encoding='utf-8').read()
a = lambda n: io.open(sys.argv[2] + '/' + n, encoding='utf-8').read()
m = a('marker')
ok = (s.count(a('a1') + "        // " + m) == 1
      and s.count(a('a2') + "        // nowhere-resume (") == 1
      and s.count("if (true) return;") == 1)
sys.exit(0 if ok else 1)
PY
  then ok "(f) pristine: exit 0, the marker present once, both injections present"
  else no "(f) pristine: exit $rc, marker count $n, or an injection missing"; fi
  # (g) re-run
  cp "$W/f/$FH" "$W/g.java"; rc=$(run "$sut" f)
  if [ "$rc" = 0 ] && said f 'already applied (no change)' && same "$W/f/$FH" "$W/g.java"; then
    ok "(g) re-run: exit 0, already applied (no change), byte-identical"
  else no "(g) re-run: exit $rc, or the file changed"; fi
  # (h) each anchor missing, each duplicated
  for t in a1-missing a2-missing a1-dup a2-dup; do
    tree_fh "h-$t" "$t"; cp "$W/h-$t/$FH" "$W/h-$t.java"; rc=$(run "$sut" "h-$t")
    if [ "$rc" != 0 ] && same "$W/h-$t/$FH" "$W/h-$t.java"; then ok "(h) $t: exit $rc, byte-identical"
    else no "(h) $t: exit $rc (want non-zero), or the file changed"; fi
  done
  # (i) missing file
  mkdir -p "$W/i"; rc=$(run "$sut" i)
  check "(i) FallbackHome.java missing: exit 1" "$rc" 1 'no FallbackHome.java' i
}

# --- run -------------------------------------------------------------------------------------------------
for sut in "${SUTS[@]}"; do
  k=$(kind "$sut")
  if [ "$k" = unknown ] || [ ! -f "$sut" ]; then no "$sut: not a script this suite knows"; continue; fi
  echo "== $(basename "$sut")"
  rm -rf "${W:?}/anchors"
  extract "$sut" "$k" "$W/anchors" || exit 2
  "cases_$k" "$sut"
done

# --- mutants ---------------------------------------------------------------------------------------------
# mutate <script> <label> <case the mutant must fail> <sed expr>
mutate(){
  local src="$1" label="$2" want="$3" expr="$4" M out rc
  M="$W/mut/$label"; mkdir -p "$M"
  cp "$src" "$M/$(basename "$src")"
  if ! sed -i "$expr" "$M/$(basename "$src")"; then no "mutant $label: the sed failed (MUTATION BROKEN)"; return; fi
  if same "$src" "$M/$(basename "$src")"; then no "mutant $label: changed nothing (MUTATION INERT)"; return; fi
  out=$(bash "$0" "$M/$(basename "$src")" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then no "mutant $label: NOT CONVICTED (suite passed)"
  elif printf '%s\n' "$out" | grep -cF -- "FAIL  $want" >/dev/null; then ok "convicted: $label by $want"
  else no "mutant $label: failed, but not at $want"; fi
  rm -rf "$M"
}
if [ "$MUTATE" = yes ]; then
  echo "== mutants"
  L="$PDIR/launcher3-no-autoadd-home.sh"; S="$PDIR/settings-fallbackhome-resume.sh"
  mutate "$L" H1 "(d)" "/grep -c 'android:defaultValue=\"false\"'/,/switch default is still true/d"
  mutate "$L" H2 "(c) .kt anchor missing" "/addIconToHome anchor not found/ s/exit 2\$/exit 0/"
  mutate "$S" H3 "(h) a1-dup" 's/if s.count(anchor) != 1:/if s.count(anchor) < 1:/'
  mutate "$S" H4 "(g)" '/^if grep -q "nowhere-resume (NWP-20260823-05)"/d'
fi

echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
