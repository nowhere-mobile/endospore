#!/usr/bin/env bash
# test-media-lander.sh [--mutate] -- runs media_lander_test.go (NWP-20261129-08, backlog "A 179-second login, 95% of it
# bulk media restored INLINE before the gate opens", Q106 slice S4a: the lander, docs/media-after-gate.md §8). --mutate
# re-runs it against a COPY of the package with one rule broken in turn. Each mutant must be CONVICTED by a `--- FAIL`;
# one that fails to apply, or fails to compile, counts as a failure.
# NWP-20261130-17 adds L12 (media_lander_corrupt_test.go): a corrupt rel is not fetched again after a restart of mediad;
# and L13 (media_lander_persist_test.go) with a new L10: each landing's digest is written before the next fetch.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
RUN=(go test -count=1 -run 'TestMediaLander' .)

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
export TMPDIR="$W" GOTMPDIR="$W"

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

P="$W/pkg"; mkdir -p "$P" || exit 2
cp ./*.go go.mod go.sum "$P"/ && cp -r blindrsa third_party "$P"/ || exit 2
fails=0
# mut <label> <file> <python-regex> <replacement>: apply to the copy, run the suite there, then restore the file.
mut() {
  local label="$1" f="$2" res rc
  cp "$P/$f" "$W/orig.go" || exit 2
  if python3 - "$P/$f" "$3" "$4" <<'PY'
import re,sys
p,pat,rep=sys.argv[1:4]
s=open(p).read()
n,c=re.subn(pat,rep,s,count=1,flags=re.S)
if c!=1 or len(re.findall(pat,s,flags=re.S))!=1 or n==s: sys.exit(1)
open(p,'w').write(n)
PY
  then
    res=$(cd "$P" && "${RUN[@]}" 2>&1); rc=$?
    score_mutant "$label" "$rc" "$res" || fails=$((fails+1))
  else
    echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1))
  fi
  cp "$W/orig.go" "$P/$f"
}
L=media_lander.go
mut "M1 the roster check is removed" $L \
  'if !held\(rel\) \{' 'if !held(rel) || true {'
mut "M2 the present-skip is removed" $L \
  'os\.Lstat\(target\); err == nil \{' 'os.Lstat(target); err == nil && false {'
mut "M3 renameNoReplace is replaced by os.Rename" $L \
  'hdr, data, renameNoReplace\)' 'hdr, data, os.Rename)'
mut "M4 the fallback is replaced by os.Rename" $L \
  'os\.Link\(tmp, target\)' 'os.Rename(tmp, target)'
mut "M5 the unders resolution is removed" $L \
  'if best == "" \{' 'if true {'
mut "M6 the hidden write passes root \"\"" $L \
  'filepath\.Join\(hidden, rest\), hidden' 'filepath.Join(hidden, rest), ""'
mut "M7 the wait no longer doubles" $L \
  'min\(wait\*2, landerWaitMax\)' 'min(wait, landerWaitMax)'
mut "M8 the cap is removed" $L \
  'wait = min\(wait\*2, landerWaitMax\)' 'wait = wait * 2'
mut "M9 corrupt rels are retried" $L \
  'if isCorruptErr\(err\) \{' 'if false {'
mut "M10 landerOrder is reversed: oldest first" $L \
  'cmp\.Compare\(m\.Ess\[b\]\.MT, m\.Ess\[a\]\.MT\)' 'cmp.Compare(m.Ess[a].MT, m.Ess[b].MT)'
mut "M11 landerOrder is reversed: other folders first" $L \
  'cmp\.Compare\(group\(a\), group\(b\)\)' 'cmp.Compare(group(b), group(a))'
mut "M12 the link guard before the present check is removed" $L \
  'noLinkBelow\(root, filepath\.Dir\(target\)\); err != nil \{' 'noLinkBelow(root, filepath.Dir(target)); err != nil && false {'
mut "M13 a mountpoint covers a sibling with its prefix" $L \
  'strings\.HasPrefix\(dir, mp\+string\(filepath\.Separator\)\)' 'strings.HasPrefix(dir, mp)'
mut "M14 the header-name check is removed" $L \
  'filepath\.ToSlash\(hdr\.Name\) != rel' 'false'
mut "M15 the shortest mountpoint wins" $L \
  'covers && len\(mp\) > len\(best\)' 'covers && (best == "" || len(mp) < len(best))'
mut "M16 the one-entry check is removed" $L \
  ' \|\| !spanIsOneEntry\(frag\)' ''
mut "M17 a .. rel is not refused" $L \
  '!landerRelOK\(rel\)' 'false'
mut "M18 digests wait for the function's return (NWP-20261130-17; L10: the roster at each fetch)" $L \
  'record := func\(rel string\) \{ appendLandedRoster\(in\.ref, in\.dk, rel\) \}' \
  'var late []string; record := func(rel string) { late = append(late, rel) }; defer func() { recordLandedRoster(in.ref, in.dk, late) }()'
mut "M19 a pass that landed does not reset the wait" $L \
  'if c\.landed > before \{' 'if c.landed > before && false {'
mut "M20 any rename error takes the fallback" $L \
  'if !errors\.Is\(err, unix\.EINVAL\) && !errors\.Is\(err, unix\.ENOSYS\) \{' 'if err == nil {'
mut "M21 a dropped copy records no digest" $L \
  '(errors\.Is\(err, os\.ErrExist\) \{\n\t+c\.skipped\+\+)\n\t+record\(rel\)' '\1'
mut "M22 a present-skip records no digest" $L \
  '(err == nil \{\n\t+c\.skipped\+\+)\n\t+record\(rel\)' '\1'
mut "M23 main's batch of 32 returns, with no flush on a kill (NWP-20261130-17; L13a: the restart's fetches)" $L \
  'record := func\(rel string\) \{ appendLandedRoster\(in\.ref, in\.dk, rel\) \}' \
  'var b32 []string; record := func(rel string) { b32 = append(b32, rel); if len(b32) >= landerBatch { recordLandedRoster(in.ref, in.dk, b32); b32 = nil } }; defer recordLandedRoster(in.ref, in.dk, nil)'
mut "M24 stop is ignored" $L \
  'if in\.stop\(\) \{' 'if false {'
mut "M25 only a second tar Next that succeeds refuses a span" $L \
  'return len\(bytes\.Trim\(frag\[len\(frag\)-rd\.Len\(\):\], "\\x00"\)\) == 0' '_, err := tr.Next(); return err != nil'
mut "M26 a tail of zero bytes is refused too" $L \
  'bytes\.Trim\(frag\[len\(frag\)-rd\.Len\(\):\], "\\x00"\)' 'frag[len(frag)-rd.Len():]'
# NWP-20261130-17: the corrupt roster (TestMediaLander_L12, media_lander_corrupt_test.go).
mut "M27 the corrupt roster is ignored on a restart (L12a: the restart's fetches)" $L \
  '!landerRelOK\(rel\) \|\| wasCorrupt\(rel\)' '!landerRelOK(rel)'
mut "M28 the corrupt roster is never written (L12a: the corrupt roster after the first run)" $L \
  'recordCorruptRoster\(in\.ref, in\.dk, \[\]string\{rel\}\)' '_ = rel'
mut "M29 a restart does not report a corrupt rel again (L12a: the restart's onDamaged)" $L \
  'if !landerRelOK\(rel\) \|\| wasCorrupt\(rel\) \{' 'if wasCorrupt(rel) { continue }; if !landerRelOK(rel) {'
mut "M30 a corrupt digest goes to the landed roster (L12a: a corrupt rel's digest is in the landed roster)" $L \
  'recordCorruptRoster\(in\.ref, in\.dk, \[\]string\{rel\}\)' 'recordCorruptRoster(in.ref, in.dk, []string{rel}); recordLandedRoster(in.ref, in.dk, []string{rel})'
mut "M31 a transient error is recorded as corrupt (L12b: the corrupt roster after a transient error)" $L \
  '\} else \{\n(\t+)next = append\(next, rel\)' '} else {\n\1recordCorruptRoster(in.ref, in.dk, []string{rel})\n\1next = append(next, rel)'
mut "M32 a restart drops a corrupt rel from the pending set (L12a: the restart's pending set)" $L \
  'if !held\(rel\) \{' 'if !held(rel) && !wasCorrupt(rel) {'
# NWP-20261130-17: the landed roster is written per landing (TestMediaLander_L13, media_lander_persist_test.go).
G=media_after_gate.go
mut "M33 the append follows a link at the roster's path (L13c: the append followed a link)" $G \
  'os\.O_CREATE\|unix\.O_NOFOLLOW' 'os.O_CREATE|0*unix.O_NOFOLLOW'
mut "M34 the append truncates the roster (L13c: the appended roster)" $G \
  'os\.O_WRONLY\|os\.O_APPEND\|' 'os.O_WRONLY|os.O_TRUNC|'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
