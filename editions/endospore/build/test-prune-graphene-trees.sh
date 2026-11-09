#!/bin/bash
# test-prune-graphene-trees.sh [<script-dir>] [--mutate] -- prune-graphene-trees.sh removes only the GrapheneOS trees
# the release no longer needs (NWP-20261105-37).
#
#   bash test-prune-graphene-trees.sh            # the suite against editions/endospore/build/prune-graphene-trees.sh
#   bash test-prune-graphene-trees.sh --mutate   # ... plus mutants that must each CONVICT the suite
#
# Every case runs the real script against a fixture root under mktemp, with a fixture build-device.sh (its TREE= line
# names the default), a stub keys-home.sh, a fixture /proc and a fixed "today". Nothing outside the mktemp root is read
# or written.
MUTATE=no; DIR=""
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; -*) echo "usage: $0 [<script-dir>] [--mutate]" >&2; exit 2 ;; *) DIR="$a" ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${DIR:-$HERE}"
SCRIPT="$DIR/prune-graphene-trees.sh"
[ -f "$SCRIPT" ] || { echo "no such file: $SCRIPT" >&2; exit 2; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
W=$(mktemp -d) || exit 2; trap 'rm -rf "$W"' EXIT

# fixture <name> [default-tree-name] -- a root with: the default (2026110200), the previous release tree (2026061600,
# releases/2026110601), a never-released tree (2026110100), an older released tree (2026050100), vendor/, a dir that
# is not a tree, and a too-short grapheneos- name.
fixture() {
  F="$W/$1"; rm -rf "$F"; mkdir -p "$F/root" "$F/proc"
  R="$F/root"
  mkdir -p "$R/grapheneos-2026110200/out-lynx" "$R/grapheneos-2026061600/releases/2026110601" \
           "$R/grapheneos-2026110100/out-lynx" "$R/grapheneos-2026050100/releases/2026060101" \
           "$R/vendor/x" "$R/notatree" "$R/grapheneos-2026"
  for t in "$R"/*/; do head -c 4096 /dev/zero > "$t/blob"; done
  printf 'TREE="${ENDOSPORE_TREE:-%s/%s}"\n' "$R" "${2:-grapheneos-2026110200}" > "$F/build-device.sh"
  printf '#!/bin/sh\nexit ${KEYS_RC:-0}\n' > "$F/keys-home.sh"
}
# run <case-dir> [args...] -- sets OUT, RC
run() {
  local F="$W/$1"; shift
  OUT=$(PRUNE_BUILD_DEVICE="$F/build-device.sh" PRUNE_KEYS_HOME_SH="$F/keys-home.sh" PRUNE_PROC="$F/proc" \
        PRUNE_TODAY=2026-11-20 bash "$SCRIPT" --root "$F/root" "$@" 2>&1); RC=$?
}
has()  { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
line() { printf '%s\n' "$OUT" | grep -E "^  (kept  |REMOVE) $1 " | head -1; }
kept() { line "$1" | grep -q '^  kept'; }
rem()  { line "$1" | grep -q '^  REMOVE'; }
exists() { [ -d "$W/$1/root/$2" ]; }

cases() {
  # 1. the dry run: what is kept, what is removable, nothing removed
  fixture c1; run c1
  [ "$RC" = 0 ] && ok "dry run exits 0" || no "dry run exits $RC"
  kept grapheneos-2026110200 && ok "the default tree is kept" || no "the default tree is not kept: $(line grapheneos-2026110200)"
  kept grapheneos-2026061600 && ok "the previous release tree is kept with no --previous-retired" || no "previous tree not kept: $(line grapheneos-2026061600)"
  rem grapheneos-2026110100 && ok "a never-released tree is removable" || no "never-released tree not removable: $(line grapheneos-2026110100)"
  rem grapheneos-2026050100 && ok "an older released tree is removable" || no "older released tree not removable: $(line grapheneos-2026050100)"
  kept vendor && kept notatree && kept grapheneos-2026 && ok "vendor/, a non-tree and a short name are never removable" || no "path guard: $(printf '%s\n' "$OUT" | grep -E 'vendor|notatree|grapheneos-2026 ')"
  has "dry run -- nothing removed" && ok "dry run says nothing was removed" || no "dry run line missing"
  local d all=1; for d in grapheneos-2026110200 grapheneos-2026061600 grapheneos-2026110100 grapheneos-2026050100 vendor notatree grapheneos-2026; do exists c1 "$d" || all=0; done
  [ "$all" = 1 ] && ok "a dry run deletes nothing" || no "a dry run deleted something"

  # 2. --apply with no --previous-retired removes only the removable trees
  fixture c2; run c2 --apply
  [ "$RC" = 0 ] && ok "--apply exits 0" || no "--apply exits $RC: $OUT"
  ! exists c2 grapheneos-2026110100 && ! exists c2 grapheneos-2026050100 && ok "--apply removed the never-released and the older tree" || no "--apply did not remove them"
  exists c2 grapheneos-2026110200 && exists c2 grapheneos-2026061600 && exists c2 vendor && exists c2 notatree && exists c2 grapheneos-2026 \
    && ok "--apply kept the default, the previous tree and every non-tree" || no "--apply removed something it must keep"

  # 3. the overlap: the previous tree stays until the default tree's first release has been published 7 days
  fixture c3; mkdir -p "$W/c3/root/grapheneos-2026110200/releases/2026110901"
  run c3 --previous-retired 2026-11-17
  kept grapheneos-2026061600 && ok "3 days after the first release: the previous tree is kept" || no "previous tree removable inside 7 days: $(line grapheneos-2026061600)"
  run c3 --previous-retired 2026-11-14
  kept grapheneos-2026061600 && ok "6 days after: still kept" || no "previous tree removable at 6 days"
  run c3 --previous-retired 2026-11-13
  rem grapheneos-2026061600 && ok "7 days after: the previous tree is removable" || no "previous tree not removable at 7 days: $(line grapheneos-2026061600)"
  fixture c3b; run c3b --previous-retired 2026-11-01
  kept grapheneos-2026061600 && ok "the default tree has no releases/ yet: the previous tree is kept whatever the date" || no "previous tree removable before the default has released"
  fixture c3c; mkdir -p "$W/c3c/root/grapheneos-2026110200/releases/2026110901"; run c3c --previous-retired 2026-11-17 --apply
  exists c3c grapheneos-2026061600 && ok "--apply inside the 7 days keeps the previous tree" || no "--apply removed the previous tree inside the 7 days"

  # 4. a busy tree is kept, even under --apply
  fixture c4; mkdir -p "$W/c4/proc/4242/fd"; ln -s "$W/c4/root/grapheneos-2026110100/out-lynx" "$W/c4/proc/4242/cwd"; : > "$W/c4/proc/4242/cmdline"
  run c4 --apply
  kept grapheneos-2026110100 && exists c4 grapheneos-2026110100 && ok "a tree a process has as its cwd is kept and not removed" || no "a busy tree was removed: $(line grapheneos-2026110100)"
  fixture c4b; mkdir -p "$W/c4b/proc/77/fd"; ln -s "$W/c4b/root/grapheneos-2026050100/blob" "$W/c4b/proc/77/fd/3"; : > "$W/c4b/proc/77/cmdline"
  run c4b; kept grapheneos-2026050100 && ok "a tree with an open file is kept" || no "open-file tree not kept"
  fixture c4c; mkdir -p "$W/c4c/proc/88/fd"; printf 'make\0-C\0%s/\0' "$W/c4c/root/grapheneos-2026110100" > "$W/c4c/proc/88/cmdline"
  run c4c; kept grapheneos-2026110100 && ok "a tree on a running command line is kept" || no "command-line tree not kept"

  # 5. a tree with its own keys/ is kept unless keys-home.sh confirms every device, with no warning
  fixture c5; mkdir -p "$W/c5/root/grapheneos-2026110100/keys/lynx"
  KEYS_RC=3 run c5; kept grapheneos-2026110100 && ok "own keys/ refused by keys-home.sh: kept" || no "own keys/ refused but removable"
  printf '#!/bin/sh\necho "keys-home: WARNING the tree copy may be the only one" >&2\nexit 0\n' > "$W/c5/keys-home.sh"
  run c5; kept grapheneos-2026110100 && ok "own keys/ with a keys-home warning: kept" || no "own keys/ with a warning but removable"
  printf '#!/bin/sh\nexit 0\n' > "$W/c5/keys-home.sh"
  run c5; rem grapheneos-2026110100 && ok "own keys/ confirmed by keys-home.sh: removable" || no "confirmed keys/ but kept: $(line grapheneos-2026110100)"
  fixture c5b; ln -s "$W/c5b/root/vendor" "$W/c5b/root/grapheneos-2026110100/keys"; KEYS_RC=3 run c5b
  rem grapheneos-2026110100 && ok "keys/ that is a link (to the keys home) does not hold the tree" || no "a keys link held the tree"

  # 6. the default is read from build-device.sh, not hard-coded
  fixture c6 grapheneos-2026110100; run c6
  kept grapheneos-2026110100 && rem grapheneos-2026110200 && ok "the default follows build-device.sh's TREE= line" || no "default not read from build-device.sh: $(line grapheneos-2026110100) / $(line grapheneos-2026110200)"
  fixture c6b; printf 'nothing here\n' > "$W/c6b/build-device.sh"; run c6b
  [ "$RC" = 2 ] && has "cannot read the default tree" && ok "no TREE= line: refused (exit 2)" || no "no TREE= line: exit $RC"

  # 7. bad arguments
  fixture c7; run c7 --previous-retired 2026-02-30; [ "$RC" = 2 ] && ok "a date off the calendar: exit 2" || no "bad date: exit $RC"
  run c7 --nonsense; [ "$RC" = 2 ] && ok "an unknown argument: exit 2" || no "unknown argument: exit $RC"
}

if [ "$MUTATE" = yes ]; then
  M=$(mktemp -d -p "$W"); BAD=0
  mut() {
    local id="$1" sc="$2"
    sed -E "$sc" "$SCRIPT" > "$M/prune-graphene-trees.sh"
    if cmp -s "$SCRIPT" "$M/prune-graphene-trees.sh"; then echo "  FAIL  MUTANT DID NOT APPLY: $id"; BAD=$((BAD+1)); return; fi
    if bash "$0" "$M" >/dev/null 2>&1; then echo "  FAIL  NOT CONVICTED $id"; BAD=$((BAD+1)); else echo "  ok    convicted $id"; fi
  }
  mut P1-default-not-kept '/the default tree \(build-device\.sh\)"; continue; fi$/d'
  mut P2-previous-deleted-inside-7-days 's/^OVERLAP_DAYS=7$/OVERLAP_DAYS=0/'
  mut P3-overlap-ignored 's/^overlap_over\(\) \{$/overlap_over() { return 0/'
  mut P4-busy-ignored 's/^busy\(\) \{$/busy() { return 1/'
  mut P5-dry-run-deletes 's/^\[ "\$APPLY" = 1 \] \|\| \{/[ 1 = 1 ] || {/'
  mut P6-path-guard-dropped 's/^name_ok\(\) \{ .*$/name_ok() { return 0; }/'
  mut P7-keys-ignored 's/^keys_unconfirmed\(\) \{$/keys_unconfirmed() { return 1/'
  mut P8-default-not-released-ignored 's/^  \[ -n "\$\(newest_bn "\$ROOT\/\$DEFAULT_NAME"\)" \] \|\| return 1$/  true/'
  [ "$BAD" = 0 ] && echo "all mutants convicted" || echo "$BAD mutant problem(s)"
  [ "$BAD" = 0 ]; exit $?
fi

cases
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
