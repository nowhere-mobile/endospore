#!/usr/bin/env bash
# test-sub-user-filter.sh [--mutate] -- NWP-20261016-22.
#
# subscription-user-filter.sh (#176 SIM-picker parity) edits a tree we do not own and is silent when absent: the roamed
# SMS picker lists the unbound SIM again. Two of its guards were weaker than docs/framework-patches.md said:
#   - the "already applied" test keyed on a plain Java statement (`if (userId == UserHandle.USER_SYSTEM || ...`), so a
#     tree holding that line anywhere printed "already applied -- skipped" and exited 0 with the filter never applied;
#   - `s.replace(old, new, 1)` with no count check patched the first of a duplicated anchor and exited 0.
# This runs the script against a synthetic SubscriptionManagerService.java built from the script's OWN `old` text with
# context lines either side (read out of the script; EXTRACTION FAILED, exit 2, when it cannot be), and pins:
#   - pristine -> exit 0, the tag and the full block present once, the old short-circuit gone;
#   - a re-run -> exit 0, byte-identical, says already applied;
#   - a pristine tree that ALSO holds the generic `userId == USER_SYSTEM || ...` line in another method -> patched;
#   - a duplicated anchor -> exit 2, byte-identical; a drifted anchor -> exit 2, unchanged;
#   - the tag present without the full block -> exit 2, unchanged; a missing target file -> exit 1.
# It cannot show that the anchor still matches the real GrapheneOS tree; the build host checks that (a drifted anchor
# fails build-device.sh). Needs python3, as the patch does: absent is a FAILURE, not a skip.
#
#   bash test-sub-user-filter.sh            # the invariants
#   bash test-sub-user-filter.sh --mutate   # ... plus mutations of the script that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done
command -v python3 >/dev/null || { echo "python3 not found: the patch needs it" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT0="$HERE/patches/subscription-user-filter.sh"
REL=frameworks/opt/telephony/src/java/com/android/internal/telephony/subscription/SubscriptionManagerService.java
GENERIC='        if (userId == UserHandle.USER_SYSTEM || userId == UserHandle.USER_ALL) {'

# extract_blocks <script>: writes $2 (old) and $3 (new) read out of the script's python heredoc.
extract_blocks(){
python3 - "$1" "$2" "$3" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m_old = re.search(r"^old = '''(.*?)'''\n", s, re.S | re.M)
m_new = re.search(r"^new = '''(.*?)'''\n", s, re.S | re.M)
if not m_old or not m_new or not m_old.group(1).strip() or not m_new.group(1).strip():
    print("EXTRACTION FAILED: old/new block not readable from %s" % sys.argv[1], file=sys.stderr); sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write(m_old.group(1))
open(sys.argv[3], "w", encoding="utf-8").write(m_new.group(1))
PY
}

# tree <dir> <variant> <oldfile> <newfile>: pristine|generic|dup|drift|tagonly|applied
tree(){
  local f="$1/$REL"; mkdir -p "$(dirname "$f")"
  local old; old="$(cat "$3")"
  local tag; tag="$(head -1 "$4")"
  {
    echo 'package com.android.internal.telephony.subscription;'; echo
    echo 'public class SubscriptionManagerService extends ISub.Stub {'
    echo '    private boolean isSubscriptionAssociatedWithUserInternal(int subId, @UserIdInt int userId) {'
    case "$2" in
      drift) echo "${old/enforceSubscriptionUserFilter/enforceOtherFilter}" ;;
      applied) cat "$4" ;;
      tagonly) echo "$tag"; echo '        return true;' ;;
      *) echo "$old" ;;
    esac
    echo '        return mSubscriptionDatabaseManager.isAssociated(subId, userId);'
    echo '    }'; echo
    if [ "$2" = dup ]; then
      echo '    private boolean isSubscriptionAssociatedWithUserNoCheck(int subId, @UserIdInt int userId) {'
      echo "$old"
      echo '        return false;'
      echo '    }'; echo
    fi
    if [ "$2" = generic ]; then
      echo '    private boolean isOtherUser(int userId) {'
      echo "$GENERIC"
      echo '            return true;'
      echo '        }'
      echo '        return false;'
      echo '    }'; echo
    fi
    echo '}'
  } > "$f"
}

checks(){
  local W; W="$(mktemp -d)"
  ok(){ printf '  ok    %s\n' "$1"; }
  no(){ printf '  FAIL  %s\n' "$1"; }
  has(){ grep -cF -- "$2" "$1" >/dev/null; }
  lacks(){ ! grep -cF -- "$2" "$1" >/dev/null; }
  count(){ local n; n=$(grep -cF -- "$2" "$1"); echo "${n:-0}"; }
  chk(){ local d="$1"; shift; if "$@"; then ok "$d"; else no "$d"; fi; }
  run(){ bash "$SUT" "$W/$1" > "$W/$1.out" 2>&1; RC=$?; }
  rc_is(){ [ "$RC" = "$1" ]; }
  extract_blocks "$SUT" "$W/old" "$W/new" || { echo "  FAIL  EXTRACTION FAILED"; rm -rf "$W"; return 2; }
  local tagline; tagline="$(head -1 "$W/new")"
  local shortc='enforceSubscriptionUserFilter()'
  local v f

  tree "$W/p" pristine "$W/old" "$W/new"; f="$W/p/$REL"
  chk "pristine carries the old short-circuit and no tag" lacks "$f" "$tagline"
  run p
  chk "pristine -> exit 0" rc_is 0
  chk "pristine: the tag is present once" test "$(count "$f" "$tagline")" = 1
  chk "pristine: the full new block is present" python3 -c 'import sys;sys.exit(0 if open(sys.argv[1]).read().count(open(sys.argv[2]).read())==1 else 1)' "$f" "$W/new"
  chk "pristine: the old short-circuit is gone" lacks "$f" "$shortc"
  chk "pristine: says patched" has "$W/p.out" 'patched isSubscriptionAssociatedWithUserInternal'
  cp "$f" "$W/p.once"
  run p
  chk "re-run -> exit 0" rc_is 0
  chk "re-run leaves the file byte-identical" cmp -s "$f" "$W/p.once"
  chk "re-run says already applied" has "$W/p.out" 'already applied'

  tree "$W/g" generic "$W/old" "$W/new"; f="$W/g/$REL"
  chk "generic: the tree holds the generic line before" has "$f" "$GENERIC"
  run g
  chk "generic line elsewhere -> exit 0" rc_is 0
  chk "generic line elsewhere -> still patched (not skipped)" lacks "$f" "$shortc"
  chk "generic line elsewhere -> the tag is present" has "$f" "$tagline"
  chk "generic line elsewhere -> not reported as already applied" lacks "$W/g.out" 'already applied'

  for v in dup drift tagonly; do
    tree "$W/$v" "$v" "$W/old" "$W/new"; cp "$W/$v/$REL" "$W/$v.orig"
    run "$v"
    chk "$v -> exit 2" rc_is 2
    chk "$v leaves the file byte-identical" cmp -s "$W/$v/$REL" "$W/$v.orig"
  done
  chk "dup names the count" has "$W/dup.out" '2 TIMES'
  chk "tag without the block says DRIFT" has "$W/tagonly.out" 'DRIFT'

  tree "$W/a" applied "$W/old" "$W/new"; cp "$W/a/$REL" "$W/a.orig"
  run a
  chk "a tree holding the whole block -> exit 0 already applied" rc_is 0
  chk "a tree holding the whole block is left byte-identical" cmp -s "$W/a/$REL" "$W/a.orig"

  mkdir -p "$W/m"; run m
  chk "missing target file -> exit 1" rc_is 1
  rm -rf "$W"
}

run_checks(){ OUT=$(checks 2>&1); local rc=$?; NFAIL=$(grep -c '^  FAIL' <<<"$OUT"); [ "$rc" = 2 ] && NFAIL=$((NFAIL+1)); return 0; }

SUT="$SUT0"
run_checks
printf '%s\n' "$OUT"
NPASS=$(grep -c '^  ok' <<<"$OUT")
echo "== $NPASS passed, $NFAIL failed"
[ "$NFAIL" = 0 ] || exit 1

if [ "$MUTATE" = yes ]; then
  echo "== mutations (each must CONVICT the suite)"
  M="$(mktemp -d)"; trap 'rm -rf "$M"' EXIT
  LOST=0
  mutant(){
    local label="$1" old="$2" new="$3" dst="$M/sut.sh"
    # optional $4/$5: a second replacement applied to the same mutant
    if ! python3 - "$SUT0" "$dst" "$old" "$new" "${4:-}" "${5:-}" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
pairs = [(sys.argv[3], sys.argv[4])] + ([(sys.argv[5], sys.argv[6])] if len(sys.argv) > 5 and sys.argv[5] else [])
for o, n in pairs:
    if s.count(o) != 1:
        sys.exit(1)
    s = s.replace(o, n, 1)
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
    then echo "  FAIL  mutant did not apply: $label"; LOST=$((LOST+1)); return; fi
    SUT="$dst"
    run_checks
    if [ "$NFAIL" -gt 0 ]; then echo "  ok    convicted: $label ($NFAIL checks failed)"
    else echo "  FAIL  NOT convicted: $label"; LOST=$((LOST+1)); fi
  }
  mutant "the line-6 generic marker restored" 'tag = new.splitlines()[0]' 'tag = new.splitlines()[6]'
  mutant "the count check removed" 'if n > 1:' 'if False:'
  # with the count check present, replace-all alone is unreachable for a duplicate; the mutant drops both guards.
  mutant "replace without the count (replaces all, no count check)" 'if n > 1:' 'if False:' 's.replace(old, new, 1)' 's.replace(old, new)'
  mutant "the tag-without-block DRIFT arm removed" 'if new not in s:' 'if False:'
  [ "$LOST" = 0 ] || { echo "== $LOST mutant(s) not convicted"; exit 1; }
  echo "== every mutant convicted"
fi
exit 0
