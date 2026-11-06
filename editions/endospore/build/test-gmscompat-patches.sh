#!/usr/bin/env bash
# test-gmscompat-patches.sh [--mutate] -- NWP-20261026-25.
#
# WHY THIS IS COMMITTED. endospore-gmscompat-chooser-exempt.sh (services.jar) and
# endospore-gmscompat-incremental-hide.sh (framework.jar) are applied to every Endospore build by build-device.sh's
# patches glob, are exempt from the artifact check (patch-markers.tsv), and were executed by no test. Both are silent
# when absent (AGENTS.md): without the first, Play-stack installs into a roamed user are "blocked to prevent breaking
# gmscompat"; without the second, a big Play install after a roam fails at session creation (errorCode=5402). An edit
# that writes the wrong text, a skip marker that no longer matches what the script writes, or an arm that writes
# nothing and exits 0 would ship in every image with no build break and no log line.
#
# Each script runs against a synthetic tree whose target file is built from the script's OWN anchor literals (read out
# of the script text, so the fixture cannot drift from it) with context lines either side.
#   chooser-exempt: (a) pristine -> exit 0, all three exemptions once, the pristine arm named; (b) the #531-patched
#     block -> exit 0, installer + archived exemptions added, the initiator line still once; (c) a re-run on (a)'s and on
#     (b)'s output -> exit 0, `already applied`, byte-identical; (d) neither anchor -> exit 2, byte-identical;
#     (e) missing file -> exit 1.
#   incremental-hide: (f) pristine -> exit 0, both overrides once, the original block still once; (g) a re-run -> exit 0,
#     byte-identical; (h) a drifted anchor -> exit 2, byte-identical; (i) missing file -> exit 1.
# An anchor that cannot be read out of a script is EXTRACTION FAILED, exit 2.
#
# SCOPE. This proves the scripts against SYNTHETIC trees only. Whether the anchors match the real GrapheneOS tree is
# the build host's: build-device.sh fails the build when a script exits 2. The scripts are bash (`bash "$p"`), so this
# suite runs them under bash only; dash and mksh cannot parse them.
#
# --mutate: six broken copies of the scripts, each of which must turn the suite red AND name the expected case:
#   G1 chooser-exempt skip-marker check removed -> (c); G2 its pristine arm writes nothing -> (a);
#   G3 its neither-anchor exit becomes 0 -> (d); G4 incremental-hide's anchor-miss exit becomes 0 -> (h);
#   G5 incremental-hide's skip-marker check removed -> (g); G6 its feature branch returns true -> (f). A mutant that does not change the text is an error.
# Usage: test-gmscompat-patches.sh | test-gmscompat-patches.sh --mutate
set -uo pipefail

MODE=plain
case "${1:-}" in
  '') ;;
  --mutate) MODE=mutate ;;
  *) echo "usage: $0 [--mutate]" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CE0="$HERE/patches/endospore-gmscompat-chooser-exempt.sh"
IH0="$HERE/patches/endospore-gmscompat-incremental-hide.sh"
CE="$CE0"
IH="$IH0"
CE_REL=frameworks/base/services/core/java/com/android/server/pm/PackageInstallerSession.java
IH_REL=frameworks/base/core/java/com/android/internal/gmscompat/sysservice/GmcPackageManager.java
for f in "$CE0" "$IH0"; do
  [ -f "$f" ] || { echo "EXTRACTION FAILED: $f is missing" >&2; exit 2; }
done

# fixture <sut-script> <kind> <treedir> -- writes the kind's target file under <treedir>. Literals are read out of
# the script text; any failure is EXTRACTION FAILED, exit 2.
fixture() {
  python3 - "$1" "$2" "$3" "$CE_REL" "$IH_REL" <<'PY'
import os, re, sys
sut, kind, tree, ce_rel, ih_rel = sys.argv[1:6]

def die(msg):
    print("EXTRACTION FAILED: " + msg, file=sys.stderr)
    sys.exit(2)

text = open(sut, encoding='utf-8').read()

def lit(name):
    m = re.findall(r"^" + name + r" = '''(.*?)'''", text, re.DOTALL | re.MULTILINE)
    if len(m) != 1 or not m[0].strip():
        die("%s in %s" % (name, sut))
    return m[0]

def put(rel, body):
    path = os.path.join(tree, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'w', encoding='utf-8').write(body)

ce_head = ("package com.android.server.pm;\n\npublic class PackageInstallerSession {\n"
           "    private void checkInstall() throws PackageManagerException {\n"
           "        final boolean gms = isGmsCompatPackage(mPackageName);\n"
           "        if (gms\n")
ce_tail = ("\n            throw new PackageManagerException(INSTALL_FAILED_INTERNAL_ERROR,\n"
           "                    \"blocked to prevent breaking gmscompat\");\n        }\n    }\n}\n")
iw_head = ("package com.android.internal.gmscompat.sysservice;\n\npublic class GmcPackageManager {\n"
           "    public int getPackageUid(String pkg) {\n        return 0;\n    }\n\n")
iw_tail = "\n\n    public Object getPackageInfo(String pkg) {\n        return null;\n    }\n}\n"

if kind == 'ce-pristine':
    put(ce_rel, ce_head + lit('anchor_pristine') + ce_tail)
elif kind == 'ce-p531':
    pristine = lit('anchor_pristine')
    suffix = ".equals(initiatingPackageName)) {"
    if pristine.count(suffix) != 1:
        die("anchor_pristine suffix in " + sut)
    body = pristine.replace(suffix, ".equals(initiatingPackageName)\n" + lit('anchor_531'), 1)
    put(ce_rel, ce_head + body + ce_tail)
elif kind == 'ce-neither':
    pristine = lit('anchor_pristine')
    drift = pristine.replace("getFirstPartyAppSourcePackageName", "getFirstPartyAppSourcePackageNames")
    if drift == pristine:
        die("anchor_pristine drift in " + sut)
    put(ce_rel, ce_head + drift + ce_tail)
elif kind == 'ih-pristine':
    put(ih_rel, iw_head + lit('old') + iw_tail)
elif kind == 'ih-drift':
    old = lit('old')
    drift = old.replace('"android.hardware.uwb"', '"android.hardware.uwb2"')
    if drift == old:
        die("old drift in " + sut)
    put(ih_rel, iw_head + drift + iw_tail)
else:
    die("unknown kind " + kind)
PY
}

# pycount_re <file> <regex> -- number of non-overlapping matches of a regex in the file.
pycount_re() {
  python3 - "$1" "$2" <<'PY'
import re, sys
print(len(re.findall(sys.argv[2], open(sys.argv[1], encoding='utf-8').read())))
PY
}

# literal <sut-script> <name> <outfile> -- writes one literal read from the script text to <outfile>.
literal() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
sut, name, out = sys.argv[1:4]
m = re.findall(r"^" + name + r" = '''(.*?)'''", open(sut, encoding='utf-8').read(), re.DOTALL | re.MULTILINE)
if len(m) != 1 or not m[0].strip():
    print("EXTRACTION FAILED: %s in %s" % (name, sut), file=sys.stderr)
    sys.exit(2)
open(out, 'w', encoding='utf-8').write(m[0])
PY
}

# pycount <file> <needlefile> -- occurrences of the (multi-line) needle in the file.
pycount() {
  python3 - "$1" "$2" <<'PY'
import sys
print(open(sys.argv[1], encoding='utf-8').read().count(open(sys.argv[2], encoding='utf-8').read()))
PY
}

checks() {
  local T out rc F1 tree k tree_a tree_b
  T=$(mktemp -d -p "$W") || return 2
  ok() { printf '  ok    %s\n' "$1"; }
  no() { printf '  FAIL  %s\n' "$1"; }
  chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi; }
  # cnt <file> <literal> -- literal occurrences (not matching lines: two copies on one line count twice)
  cnt() { python3 -c 'import sys; print(open(sys.argv[1], encoding="utf-8", errors="replace").read().count(sys.argv[2]))' "$1" "$2" 2>/dev/null || echo 0; }
  # run <sut> <tree> -- output to $out, exit code to rc
  run() { out=$(mktemp -p "$T") || return 2; bash "$1" "$2" >"$out" 2>&1; rc=$?; }
  # mk <kind> <label> -- builds a tree for <kind> into $tree; EXTRACTION FAILED aborts the whole pass
  mk() {
    local sut=$CE
    case "$1" in ih-*) sut=$IH ;; esac
    tree=$(mktemp -d -p "$T") || return 2
    fixture "$sut" "$1" "$tree" 2>"$T/err" || {
      printf '  FAIL  %s: %s\n' "$2" "$(cat "$T/err")"
      return 2
    }
  }

  local INIT='!"com.nowhere.chooser".equals(initiatingPackageName)'
  local INST='!"com.nowhere.chooser".equals(mInstallSource.mInstallerPackageName)'
  local ARCH='!isArchivedInstallation()'

  # ---- chooser-exempt ----
  mk ce-pristine '(a) chooser-exempt: fixture' || return 2
  tree_a=$tree; F1=$tree_a/$CE_REL
  chk "(a) chooser-exempt: pristine fixture lacks the skip marker" "$(cnt "$F1" "$INST")" 0
  run "$CE" "$tree_a" || return 2
  chk "(a) chooser-exempt: pristine -> exit 0" "$rc" 0
  chk "(a) chooser-exempt: initiator exemption present once" "$(cnt "$F1" "$INIT")" 1
  chk "(a) chooser-exempt: installer exemption present once" "$(cnt "$F1" "$INST")" 1
  chk "(a) chooser-exempt: archived exemption present once" "$(cnt "$F1" "$ARCH")" 1
  chk "(a) chooser-exempt: output names the pristine arm" "$(cnt "$out" '(pristine tree)')" 1
  local A_OUT=$T/a.out; cp "$F1" "$A_OUT"

  mk ce-p531 '(b) chooser-exempt: fixture' || return 2
  tree_b=$tree; F1=$tree_b/$CE_REL
  chk "(b) chooser-exempt: #531 fixture lacks the installer exemption" "$(cnt "$F1" "$INST")" 0
  chk "(b) chooser-exempt: #531 fixture carries the initiator line once" "$(cnt "$F1" "$INIT")" 1
  run "$CE" "$tree_b" || return 2
  chk "(b) chooser-exempt: #531-patched -> exit 0" "$rc" 0
  chk "(b) chooser-exempt: installer exemption present once" "$(cnt "$F1" "$INST")" 1
  chk "(b) chooser-exempt: archived exemption present once" "$(cnt "$F1" "$ARCH")" 1
  chk "(b) chooser-exempt: initiator line present exactly once" "$(cnt "$F1" "$INIT")" 1
  chk "(b) chooser-exempt: output names the #531 arm" "$(cnt "$out" '#531-patched block')" 1
  local B_OUT=$T/b.out; cp "$F1" "$B_OUT"

  for k in a b; do
    local tr=$tree_a snap=$A_OUT
    [ "$k" = b ] && { tr=$tree_b; snap=$B_OUT; }
    run "$CE" "$tr" || return 2
    chk "(c) chooser-exempt: re-run on ($k)'s output -> exit 0" "$rc" 0
    chk "(c) chooser-exempt: re-run on ($k)'s output says already applied" "$(cnt "$out" 'already applied')" 1
    if cmp -s "$snap" "$tr/$CE_REL"; then ok "(c) chooser-exempt: re-run on ($k)'s output is byte-identical"
    else no "(c) chooser-exempt: re-run on ($k)'s output is byte-identical"; fi
  done

  mk ce-neither '(d) chooser-exempt: fixture' || return 2
  local tree_d=$tree; F1=$tree_d/$CE_REL
  cp "$F1" "$T/d.before"
  run "$CE" "$tree_d" || return 2
  chk "(d) chooser-exempt: neither anchor -> exit 2" "$rc" 2
  chk "(d) chooser-exempt: neither anchor names the missing anchor" "$(cnt "$out" 'PATCH ANCHOR NOT FOUND')" 1
  if cmp -s "$T/d.before" "$F1"; then ok "(d) chooser-exempt: neither anchor leaves the file byte-identical"
  else no "(d) chooser-exempt: neither anchor leaves the file byte-identical"; fi

  tree=$(mktemp -d -p "$T") || return 2
  run "$CE" "$tree" || return 2
  chk "(e) chooser-exempt: missing file -> exit 1" "$rc" 1
  if [ -e "$tree/$CE_REL" ]; then no "(e) chooser-exempt: missing file creates nothing"; else ok "(e) chooser-exempt: missing file creates nothing"; fi

  # ---- incremental-hide ----
  mk ih-pristine '(f) incremental-hide: fixture' || return 2
  local tree_f=$tree; F1=$tree_f/$IH_REL
  literal "$IH" old "$T/old.txt" || { echo '  FAIL  (f) incremental-hide: EXTRACTION FAILED old'; return 2; }
  chk "(f) incremental-hide: pristine fixture lacks the marker" "$(cnt "$F1" FEATURE_INCREMENTAL_DELIVERY)" 0
  run "$IH" "$tree_f" || return 2
  chk "(f) incremental-hide: pristine -> exit 0" "$rc" 0
  chk "(f) incremental-hide: hasSystemFeature(name, version) override present once" \
    "$(cnt "$F1" 'public boolean hasSystemFeature(String name, int version) {')" 1
  chk "(f) incremental-hide: getSystemAvailableFeatures override present once" \
    "$(cnt "$F1" 'public android.content.pm.FeatureInfo[] getSystemAvailableFeatures() {')" 1
  chk "(f) incremental-hide: the incremental feature branch of the 2-arg override returns false" \
    "$(pycount_re "$F1" 'FEATURE_INCREMENTAL_DELIVERY\.equals\(name\)\) \{\s*return false;\s*\}\s*return super\.hasSystemFeature\(name, version\);')" 1
  chk "(f) incremental-hide: the enumeration override skips the incremental feature and returns the rest" \
    "$(pycount_re "$F1" 'FEATURE_INCREMENTAL_DELIVERY\.equals\(fi\.name\)\) \{\s*continue;\s*\}\s*out\.add\(fi\);')" 1
  chk "(f) incremental-hide: the original block is still present exactly once" "$(pycount "$F1" "$T/old.txt")" 1
  cp "$F1" "$T/f.after"

  run "$IH" "$tree_f" || return 2
  chk "(g) incremental-hide: re-run -> exit 0" "$rc" 0
  chk "(g) incremental-hide: re-run says already applied" "$(cnt "$out" 'already applied')" 1
  if cmp -s "$T/f.after" "$F1"; then ok "(g) incremental-hide: re-run is byte-identical"
  else no "(g) incremental-hide: re-run is byte-identical"; fi

  mk ih-drift '(h) incremental-hide: fixture' || return 2
  local tree_h=$tree; F1=$tree_h/$IH_REL
  cp "$F1" "$T/h.before"
  run "$IH" "$tree_h" || return 2
  chk "(h) incremental-hide: drifted anchor -> exit 2" "$rc" 2
  chk "(h) incremental-hide: drifted anchor names the missing anchor" "$(cnt "$out" 'PATCH ANCHOR NOT FOUND')" 1
  if cmp -s "$T/h.before" "$F1"; then ok "(h) incremental-hide: drifted anchor leaves the file byte-identical"
  else no "(h) incremental-hide: drifted anchor leaves the file byte-identical"; fi

  tree=$(mktemp -d -p "$T") || return 2
  run "$IH" "$tree" || return 2
  chk "(i) incremental-hide: missing file -> exit 1" "$rc" 1
  if [ -e "$tree/$IH_REL" ]; then no "(i) incremental-hide: missing file creates nothing"; else ok "(i) incremental-hide: missing file creates nothing"; fi

  rm -rf "$T"
  return 0
}

# run_checks -- sets OUT, NFAIL, CASES (sorted unique case letters of the FAIL lines), CRC.
run_checks() {
  local rc
  OUT=$(checks 2>&1); rc=$?
  NFAIL=$(printf '%s\n' "$OUT" | grep -c '^  FAIL')
  CASES=$(printf '%s\n' "$OUT" | grep '^  FAIL' | grep -o '^  FAIL  ([a-i])' | grep -o '[a-i]' | sort -u | tr -d '\n')
  CRC=$rc
  [ "$rc" -ne 0 ] && NFAIL=$((NFAIL + 1))
  return 0
}

if [ "$MODE" = plain ]; then
  run_checks
  printf '%s\n' "$OUT"
  PASSED=$(printf '%s\n' "$OUT" | grep -c '^  ok')
  echo "== $PASSED passed, $NFAIL failed"
  [ "$CRC" -eq 2 ] && exit 2
  [ "$NFAIL" -eq 0 ] || exit 1
  exit 0
fi

# ---- --mutate ----
MD=$(mktemp -d -p "$W") || exit 2
LOST=0

# mutant <id> <CE|IH> <expected-case> <old> <new> <label>
mutant() {
  local id=$1 which=$2 want=$3 old=$4 new=$5 label=$6 src dst rc
  if [ "$which" = CE ]; then src=$CE0; else src=$IH0; fi
  dst=$MD/$id.sh
  python3 - "$src" "$dst" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
t = open(src, encoding='utf-8').read()
if t.count(old) != 1:
    sys.exit(3)
m = t.replace(old, new, 1)
if m == t:
    sys.exit(3)
open(dst, 'w', encoding='utf-8').write(m)
PY
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL  mutant did not apply: $id $label"; LOST=$((LOST + 1)); return 0
  fi
  CE=$CE0; IH=$IH0
  if [ "$which" = CE ]; then CE=$dst; else IH=$dst; fi
  run_checks
  CE=$CE0; IH=$IH0
  case "$CASES" in
    *"$want"*)
      if [ "$NFAIL" -gt 0 ]; then
        echo "  ok    convicted: $id $label by ($want) [cases: $CASES]"
      else
        echo "  FAIL  NOT convicted: $id $label"; LOST=$((LOST + 1))
      fi ;;
    *) echo "  FAIL  NOT convicted by ($want): $id $label [cases: ${CASES:-none}]"; LOST=$((LOST + 1)) ;;
  esac
  return 0
}

# The unmutated scripts must be green first, or every conviction below would be meaningless.
run_checks
if [ "$NFAIL" -ne 0 ]; then
  printf '%s\n' "$OUT"
  echo "== the unmutated scripts are red; mutants are not meaningful"
  exit 1
fi

EXIT2='aborting"); sys.exit(2)'
EXIT0='aborting"); sys.exit(0)'
mutant G1 CE c 'if '"'"'com.nowhere.chooser".equals(mInstallSource.mInstallerPackageName)'"'"' in s:' 'if False:' \
  "chooser-exempt skip-marker check removed"
mutant G2 CE a '    s = s.replace(anchor_pristine, new_pristine, 1)' '    pass' \
  "chooser-exempt pristine arm writes nothing"
mutant G3 CE d "$EXIT2" "$EXIT0" "chooser-exempt neither-anchor exit changed to 0"
mutant G4 IH h "$EXIT2" "$EXIT0" "incremental-hide anchor-miss exit changed to 0"
mutant G5 IH g "if 'FEATURE_INCREMENTAL_DELIVERY' in s:" 'if False:' "incremental-hide skip-marker check removed"
mutant G6 IH f 'FEATURE_INCREMENTAL_DELIVERY.equals(name)) {
            return false;' 'FEATURE_INCREMENTAL_DELIVERY.equals(name)) {
            return true;' "incremental-hide feature branch returns true"

if [ "$LOST" -ne 0 ]; then
  echo "== $LOST mutant(s) not convicted"
  exit 1
fi
echo "== every mutant convicted"
