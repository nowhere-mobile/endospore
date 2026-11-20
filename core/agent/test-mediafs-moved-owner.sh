#!/usr/bin/env bash
# test-mediafs-moved-owner.sh [--mutate] -- NWP-20261209-01: a file moved into an overlaid media folder could not be
# opened until the next seal (frankel, kernel 6.18). The move crossed a mount, the app copied the file in through
# MediaProvider, and mediad gave the copy MediaProvider's owner and a 0600 mode. The fix (mediafs.go): one overlay per
# app media root (mediaMountAnchors), so the move stays a rename; every new entry takes the tree's owner and the mode
# its caller asked for (fixNew), through one descriptor confined to the overlay's tree (openat2 RESOLVE_BENEATH |
# RESOLVE_NO_SYMLINKS). This suite runs the Go tests and source pins. --mutate applies each mutant to a pristine copy
# of mediafs.go (restored on exit) and requires a convicting `--- FAIL` or pin failure: a mutant that does not apply,
# or does not compile, is a failure, never a conviction. The stat-based owner assertions need root or a usable
# supplementary group; the owner mutants (M1, M2, M4) are convicted by TestMovedInEntryRequestsTreeOwner, which
# records the owner fixNew asks for through fixNewChown, so they need neither.
set -uo pipefail
cd "$(dirname "$0")" || exit 2
. ./suite-report.sh
W=$(mktemp -d) || exit 2
cp mediafs.go "$W/mediafs.orig" || exit 2
trap 'cp "$W/mediafs.orig" mediafs.go; rm -rf "$W"' EXIT
export GOTMPDIR="$W" TMPDIR="$W"

RUN='^(TestMediaMountAnchorsWidenAppMediaRoot|TestMediaMountAnchorsRenameIsOneMount|TestMovedInEntryTakesTreeOwnerAndMode|TestMovedInEntryRequestsTreeOwner|TestFixNewStaysInsideTheTree|TestMediaTreeOwnerFollowsRemapTree|TestNewEntryLogCarriesNoName|TestOverlayMountMoveIsRename|TestEveryGoroutineGoesThroughGoSafe)$'

# body <file> <func-head>: the function from the line that starts with <func-head> to the first line that is exactly `}`.
body() {
  HEAD="$2" awk 'index($0, ENVIRON["HEAD"]) == 1 {p=1} p {print} p && /^}$/ {exit}' "$1"
}
# has <text> <fixed-string>: true when the text holds the string (no pipe, no grep -q under pipefail).
has() { [[ "$1" == *"$2"* ]]; }

# pins <file>: prints the first broken pin and returns 1, or returns 0.
pins() {
  local f="$1" b n s
  for n in Create Mkdir Mknod; do
    b=$(body "$f" "func (r *mediaRoot) $n(")
    has "$b" 'r.fixNew(name, out.Attr.Ino, mode, true, &out.Attr)' || { echo "PIN $n: mediaRoot.$n must call fixNew with its mode"; return 1; }
  done
  b=$(body "$f" 'func (r *mediaRoot) fixNew(')
  has "$b" 'unix.Openat2(rootFd, rel,' || { echo "PIN fixNew-confined: fixNew must open the entry beneath the overlay root"; return 1; }
  has "$b" 'unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS' || { echo "PIN fixNew-resolve: no symlink in any component"; return 1; }
  has "$b" 'syscall.Chmod(' && { echo "PIN fixNew-path: fixNew must not chmod a path"; return 1; }
  has "$b" 'Lchown(' && { echo "PIN fixNew-path: fixNew must not chown a path"; return 1; }
  has "$b" 'fixNewChown(fd, int(r.newOwner.Uid), int(r.newOwner.Gid))' || { echo "PIN fixNew-chown: fixNew must re-own through its descriptor"; return 1; }
  b=$(body "$f" 'var fixNewChown = ')
  has "$b" 'return unix.Fchownat(fd, "", uid, gid, unix.AT_EMPTY_PATH)' || { echo "PIN fixNewChown: the chown must be Fchownat on the descriptor"; return 1; }
  b=$(body "$f" 'func (r *mediaRoot) Symlink(')
  has "$b" 'r.fixNew(name, out.Attr.Ino, 0, false, &out.Attr)' || { echo "PIN Symlink: Symlink must re-own only"; return 1; }
  b=$(body "$f" 'func (r *mediaRoot) Rename(')
  has "$b" 'nr.fixNew(newName, 0, 0, false, &fuse.Attr{})' || { echo "PIN Rename: Rename must re-own the destination, never chmod it"; return 1; }
  b=$(body "$f" 'func serveMediaScope(')
  s="${b%%mediaMountRoots(dirs)*}"
  { [ "$s" != "$b" ] && has "$s" 'mediaMountAnchors(dirs, userDir, isSharedMediaScope(name))'; } ||
    { echo "PIN serveMediaScope: mediaMountAnchors must run before mediaMountRoots"; return 1; }
  has "$b" 'root.newOwner = mediaTreeOwner(' || { echo "PIN serveMediaScope: the #media overlay must get the tree owner"; return 1; }
  has "$b" 'root.newOwner = nil' || { echo "PIN serveMediaScope: the CE scope keeps go-fuse's owner"; return 1; }
  b=$(body "$f" 'func mediaMountOptions(')
  has "$b" 'DisabledCapabilities |= fuse.CAP_PASSTHROUGH' || { echo "PIN passthrough: NWP-20261113-44 must stay"; return 1; }
  return 0
}

out=$(go test -count=1 -v -run "$RUN" . 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
skipped=$(grep -- '--- SKIP' <<<"$out" || true)
[ -z "$skipped" ] || echo "NOTE: skipped here (no usable FUSE; the CI runner must not skip it): $skipped"
if has "$out" 'the owner half is not checked by stat here'; then echo "NOTE: no root and no usable supplementary group: the stat-based owner assertions did not run (TestMovedInEntryRequestsTreeOwner did)"; fi
if ! pmsg=$(pins mediafs.go); then echo "FAIL: $pmsg"; exit 1; fi
echo "ok: the source pins hold"
[ "${1:-}" = "--mutate" ] || exit 0

FAILS=0
# apply <old> <new>: replace the first <old> in a pristine mediafs.go; 1 when it does not apply.
apply() {
  cp "$W/mediafs.orig" mediafs.go
  OLD="$1" NEW="$2" python3 -c "
import os
s = open('mediafs.go').read()
t = s.replace(os.environ['OLD'], os.environ['NEW'], 1)
if t == s: raise SystemExit('mutant did not apply')
open('mediafs.go','w').write(t)"
}
# mutate <label> <test-name> <old> <new>: the named Go test must FAIL on the mutant.
mutate() {
  local lbl="$1" tst="$2" old="$3" new="$4" res rc
  if ! apply "$old" "$new"; then echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return; fi
  res=$(go test -count=1 -v -run "^$tst\$" . 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && has "$res" "--- FAIL: $tst"; then echo "  convicted $lbl ($tst)"
  else score_mutant "$lbl" "$rc" "$res" >/dev/null; echo "  NOT CONVICTED $lbl (want --- FAIL: $tst)"; tail -n 15 <<<"$res"; FAILS=$((FAILS+1)); fi
}
# pinmut <label> <pin-prefix> <old> <new>: the mutant must compile and the named source pin must fail on it.
pinmut() {
  local lbl="$1" pin="$2" old="$3" new="$4" res msg
  if ! apply "$old" "$new"; then echo "  INERT     $lbl -- the mutation did not apply"; FAILS=$((FAILS+1)); return; fi
  if ! res=$(go vet . 2>&1); then echo "  BROKEN    $lbl -- the mutant did not compile"; echo "$res" | tail -5; FAILS=$((FAILS+1)); return; fi
  if ! msg=$(pins mediafs.go) && has "$msg" "$pin"; then echo "  convicted $lbl ($msg)"
  else echo "  NOT CONVICTED $lbl (want $pin; got: ${msg:-all pins hold})"; FAILS=$((FAILS+1)); fi
}

mutate "M1 fixNew drops the chown" TestMovedInEntryRequestsTreeOwner \
  'if err := fixNewChown(fd, int(r.newOwner.Uid), int(r.newOwner.Gid)); err != nil {' \
  'if err := error(nil); err != nil {'
mutate "M2 fixNew does not report the owner" TestMovedInEntryRequestsTreeOwner \
  '			a.Owner = *r.newOwner' '			_ = a'
mutate "M3 Create loses its fixNew" TestMovedInEntryTakesTreeOwnerAndMode \
  '	if errno == 0 {
		r.fixNew(name, out.Attr.Ino, mode, true, &out.Attr)
	}
	return inode, fh, fuseFlags, errno' '	return inode, fh, fuseFlags, errno'
mutate "M4 Rename loses its fixNew" TestMovedInEntryRequestsTreeOwner \
  '		nr.fixNew(newName, 0, 0, false, &fuse.Attr{})' '		_ = nr'
mutate "M5 mediaMountAnchors adds no anchor" TestMediaMountAnchorsWidenAppMediaRoot \
  '		out[anchor] = nil
		added++' '		_ = anchor'
mutate "M6 mediaMountAnchors anchors Android/data too" TestMediaMountAnchorsWidenAppMediaRoot \
  'parts[0] != "Android" || parts[1] != "media" || parts[2] == ""' \
  'parts[0] != "Android" || (parts[1] != "media" && parts[1] != "data") || parts[2] == ""'
mutate "M7 mediaTreeOwner returns the root's owner for every dir" TestMediaTreeOwnerFollowsRemapTree \
  'if len(parts) >= 3 && parts[0] == "Android" && (parts[1] == "data" || parts[1] == "obb") {' \
  'if len(parts) >= 0 {'
mutate "M8 the confined-open log prints the name" TestNewEntryLogCarriesNoName \
  'dlog("mediad: new entry not fixed, confined open: %v", errCode(err))' \
  'dlog("mediad: new entry not fixed, confined open: %v %q", errCode(err), rel)'
mutate "M9 fixNew drops the chmod" TestMovedInEntryTakesTreeOwnerAndMode \
  'if err := unix.Fchmodat(unix.AT_FDCWD, "/proc/self/fd/"+strconv.Itoa(fd), mode&0o7777, 0); err != nil {' \
  'if err := error(nil); err != nil {'
mutate "M10 Mkdir loses its fixNew" TestMovedInEntryTakesTreeOwnerAndMode \
  '	inode, errno := r.LoopbackNode.Mkdir(ctx, name, mode, out)
	if errno == 0 {
		r.fixNew(name, out.Attr.Ino, mode, true, &out.Attr)' \
  '	inode, errno := r.LoopbackNode.Mkdir(ctx, name, mode, out)
	if errno == 0 {
		_ = name'
mutate "M11 Mknod loses its fixNew" TestMovedInEntryTakesTreeOwnerAndMode \
  '	inode, errno := r.LoopbackNode.Mknod(ctx, name, mode, rdev, out)
	if errno == 0 {
		r.fixNew(name, out.Attr.Ino, mode, true, &out.Attr)' \
  '	inode, errno := r.LoopbackNode.Mknod(ctx, name, mode, rdev, out)
	if errno == 0 {
		_ = name'
mutate "M12 fixNew opens the entry by its path (the RF-001 escape)" TestFixNewStaysInsideTheTree \
  '	fd, err := unix.Openat2(rootFd, rel, &unix.OpenHow{
		Flags:   unix.O_PATH | unix.O_NOFOLLOW | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS,
	})' \
  '	_ = rel
	fd, err := unix.Open(filepath.Join(r.realPath(), name), unix.O_PATH|unix.O_CLOEXEC, 0)'
mutate "M13 fixNew resolves symlinks in the path" TestFixNewStaysInsideTheTree \
  '		Flags:   unix.O_PATH | unix.O_NOFOLLOW | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS,' \
  '		Flags:   unix.O_PATH | unix.O_CLOEXEC,
		Resolve: 0,'
mutate "M14 fixNew drops the inode check" TestFixNewStaysInsideTheTree \
  'if ino != 0 && st.Ino != ino {' 'if ino != 0 && st.Ino != st.Ino {'
pinmut "M15 Symlink chmods its link" "PIN Symlink" \
  '		r.fixNew(name, out.Attr.Ino, 0, false, &out.Attr)' \
  '		r.fixNew(name, out.Attr.Ino, 0o777, true, &out.Attr)'
pinmut "M16 fixNewChown chowns nothing" "PIN fixNewChown" \
  '	return unix.Fchownat(fd, "", uid, gid, unix.AT_EMPTY_PATH)' \
  '	_, _, _ = fd, uid, gid
	return nil'
cp "$W/mediafs.orig" mediafs.go
if [ "$FAILS" -ne 0 ]; then echo "== $FAILS mutation(s) not convicted"; exit 1; fi
echo "== all mutations convicted"
