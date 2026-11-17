package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/sys/unix"
)

// Web-import ingestion hand-off (NWP-20260827-18, docs/web-import.md slice II). A web-created profile's
// contacts/calendar arrive as FILES -- Documents/Imported/*.vcf|*.ics in the #media scope, on disk in
// /data/media/<userId> before the user switch (the writer stages them essential; the login's `in` op
// restores #media before grant acks). Turning them into LIVE rows in the roamed user's contacts/calendar
// providers is the chooser-side Ingest step, which runs IN the roamed user (the TelIngest shape: a normal
// app in the target user can query-back verify its own inserts, which the su:s0 worker structurally
// cannot -- DIA-56). These two verbs are the daemon's half of that hand-off:
//
//	GET-INGEST\n -> "OK\n" + one "F <name_b64> <bytes_b64>" line per staged file | "NONE\n"
//
// GET-INGEST exists because scoped storage denies the roamed chooser the read: Documents/ is not a media
// collection, so a normal app cannot open another app's staged .vcf there (READ_MEDIA_* covers
// images/video/audio only). The daemon reads the real tree as root and hands the bytes over the already
// peer-authenticated socket -- the exact GET-TELINGEST posture, SO_PEERCRED uid/100000 = userId, so a
// session only ever reads files staged FOR it.
//
// There is deliberately NO "mark it done" verb. The first cut renamed a finished file to *.imported as a
// second, cross-scope signal, and it could never work: this daemon holds READ-ONLY policy on the media
// tree (sepolicy nowhere.te grants r_dir_perms/r_file_perms and dac_read_search, not dac_override), so
// os.Rename always failed with EACCES and the chooser's INGEST-DONE always got ERR. Granting a root
// daemon write access to every photo on the device to leave a cosmetic marker is not a trade worth
// making (NWP-20260827-21), so the record lives entirely in the chooser's own CE receipt, which seals
// and restores with the profile. This side just serves the bytes, every login, and lets the chooser
// decide what it has already done.
//
// Files >= 1 MiB are DEFERRED by the web writer and not on disk at login, and a deferred file makes mediad
// overlay its dir: the overlay set is every dir holding a deferred entry, whatever its path (deferredDirs,
// media_server.go). A read THROUGH that FUSE overlay lists the deferred stub beside the real files, and an open
// of the stub makes mediad fetch it from the store inside this socket handler. Until NWP-20261203-15 a mapped
// dir was read at its hidden .under path instead (NWP-20261013-30), and on an enforcing device that read can
// never work: mediad makes .under inside the chooser's files dir in /data/user/<N> (serveMediaScope), vold makes
// /data/user/<N> at user N's MLS level, and dir search there needs a subject that dominates it. This daemon runs
// at s0, so every Lstat under .under was denied and the answer was NONE, silently (S7, lynx 2026111001). That is
// MLS, not type enforcement: a sepolicy allow changes nothing, and mlstrustedsubject would lift the barrier for
// the whole network-facing login daemon. The precedent is the backlog row "The daemon is denied `search` on one
// of the session user's system directories every 30 seconds, on a user build" (NWP-20261005-08): stop reading
// /data/user from the daemon. So GET-INGEST never reads the .under path. For a mapped dir it reads the PLAIN
// mountpoint (the daemon holds fuse dir/file read, nowhere.te), but only the names in the snapshot kickMediad
// takes before it asks mediad to start (ingestSnapshotStaged), each with the size it had then. A real name falls
// through mediad's loopback without a fetch (mediaRoot.Lookup, mediafs.go). A deferred name was not on disk when
// the snapshot was taken, so it is never named, opened or fetched. No snapshot for the peer's user means NONE.
// Each NONE other than "nothing staged" and each serve writes one count-only line to login.log: never a file
// name, a size or a path. With no map entry the plain path is read, as before (NWP-20260827-26).

var ingestMediaBase = "/data/media" // var so tests can redirect

// ingestUndersFn supplies the mountpoint -> hidden map; var so tests can inject one.
var ingestUndersFn = publishedMediaUnders

// ingestReadFn reads one staged file; var so tests can record every path GET-INGEST opens.
var ingestReadFn = ingestReadStaged

// ingestLogf writes GET-INGEST's evidence line; var so tests can capture it. os.Stderr is what login.log carries.
var ingestLogf = func(format string, a ...any) { fmt.Fprintf(os.Stderr, format, a...) }

// ingestSnap is what the plain staging dir held when the daemon last asked mediad to start: the staged names
// that were real files then, with their Lstat sizes. In memory only: never written to disk, never logged.
type ingestSnap struct {
	uid   string
	names map[string]int64
}

var (
	ingestSnapMu  sync.Mutex
	ingestSnapRec *ingestSnap
)

// ingestSnapshotStaged records the regular files staged for user uid, for kickMediad to call before it requests
// a mediad start (so before mediad can mount an overlay there). When the dir is mapped already (overlaid, or its
// mounts are dead after a SIGKILL'd mediad) a read now would go through FUSE, so the record is kept as it is.
func ingestSnapshotStaged(uid string) {
	dir := filepath.Join(ingestMediaBase, uid, ingestDir)
	if _, mapped := ingestResolveDir(dir); mapped {
		return
	}
	rec := &ingestSnap{uid: uid, names: map[string]int64{}}
	if ingestStagingDirOK(dir, false) {
		if names, err := ingestList(dir, false); err == nil {
			for _, n := range names {
				if st, err := os.Lstat(filepath.Join(dir, n)); err == nil && st.Mode().IsRegular() {
					rec.names[n] = st.Size()
				}
			}
		}
	}
	ingestSnapMu.Lock()
	ingestSnapRec = rec
	ingestSnapMu.Unlock()
}

// ingestSnapshotFor returns the snapshot recorded for user uid, and false when the record is for another user or
// there is none. The map is never written after it is published, so the caller may read it unlocked.
func ingestSnapshotFor(uid string) (map[string]int64, bool) {
	ingestSnapMu.Lock()
	defer ingestSnapMu.Unlock()
	if ingestSnapRec == nil || ingestSnapRec.uid != uid {
		return nil, false
	}
	return ingestSnapRec.names, true
}

// ingestNone answers NONE and logs its reason class (counts and fixed words only).
func ingestNone(conn net.Conn, userID, reason string) {
	fmt.Fprint(conn, "NONE\n")
	ingestLogf("[logind] ingest: user %s: NONE (%s) (NWP-20261203-15)\n", userID, reason)
}

// ingestResolveDir maps dir to the hidden .under path when the map names dir or its nearest mapped ancestor,
// and reports whether it did. GET-INGEST uses only the report: the hidden path is not a read path there (see
// the header).
func ingestResolveDir(dir string) (string, bool) {
	m := ingestUndersFn()
	for d := dir; len(m) > 0 && d != "/" && d != "."; d = filepath.Dir(d) {
		if h, ok := m[d]; ok {
			rel, err := filepath.Rel(d, dir)
			if err != nil {
				return "", true
			}
			return filepath.Join(h, rel), true
		}
	}
	return dir, false
}

const (
	ingestDir          = "Documents/Imported"
	ingestMaxFileBytes = 8 << 20  // a single vcf/ics beyond this is skipped, not truncated
	ingestMaxTotal     = 16 << 20 // whole hand-off cap: the reply is built in memory
)

// ingestNameRe accepts the file names the web import page stages -- which are the USER'S OWN file names,
// verbatim, in any script ("Kontakte fur Anna.vcf", Cyrillic, CJK; the page does no renaming). So the gate
// is structural, not an ASCII allowlist: no path separators, no NUL, no leading dot, a case-insensitive
// .vcf/.ics suffix, bounded length. The name is re-joined under the user's media tree and must never
// escape it -- with '/' excluded, a ".." can only be an ordinary (weird) file name, not a traversal.
var ingestNameRe = regexp.MustCompile(`^(?i)[^/\x00.][^/\x00]{0,250}\.(vcf|ics)$`)

// ingestList lists the regular vcf/ics files (a link, FIFO, socket or device is not listed) in the user's staging dir, sorted for a deterministic wire order.
// Every match is served on every login; the chooser skips the ones it holds receipts for. A missing dir
// is simply "nothing staged". The web writer stages files under 1 MiB essential, so re-serving them each
// login is cheap next to the round trip. On an overlaid dir a deferred stub IS listed, so the caller keeps only
// the snapshot's names (see the header). A mapped dir that does not exist is an error, not "nothing staged".
func ingestList(dir string, mapped bool) ([]string, error) {
	ents, rerr := os.ReadDir(dir)
	if rerr != nil {
		if os.IsNotExist(rerr) && !mapped {
			return nil, nil
		}
		return nil, rerr
	}
	var names []string
	for _, e := range ents {
		if !e.Type().IsRegular() || !ingestNameRe.MatchString(e.Name()) {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

// ingestStagingDirOK reports whether the staging dir has no linked component. Unmapped, each component below
// ingestMediaBase (<u>, Documents, Imported) is Lstat'd; mapped, the resolved hidden dir itself. A link, a
// non-directory or any Lstat error is false (the answer is NONE; an absent unmapped dir was "nothing staged"
// and an absent mapped one an error, both NONE). ReadDir follows a linked dir, so without this a link
// planted at any component would redirect the read, as root, to a tree the user does not own. GET-INGEST and
// ingestSnapshotStaged both pass mapped=false since NWP-20261203-15, because both read the plain path; on an
// overlaid dir the last component is the FUSE mountpoint, which is a dir, not a link.
func ingestStagingDirOK(dir string, mapped bool) bool {
	paths := []string{dir}
	if !mapped {
		rel, err := filepath.Rel(ingestMediaBase, dir)
		if err != nil {
			return false
		}
		paths = nil
		p := ingestMediaBase
		for _, c := range strings.Split(rel, string(filepath.Separator)) {
			p = filepath.Join(p, c)
			paths = append(paths, p)
		}
	}
	for _, p := range paths {
		st, err := os.Lstat(p)
		if err != nil || !st.IsDir() {
			return false
		}
	}
	return true
}

// ingestReadStaged reads one staged file the way root must read a user-writable tree: Lstat says regular (not a
// link), the open refuses a link (O_NOFOLLOW) and cannot block on a FIFO (O_NONBLOCK), the opened file is the
// same regular file the Lstat saw, and the bytes actually read are the one bound -- more than max, or none,
// is refused. ok is false for anything refused.
func ingestReadStaged(p string, max int64) ([]byte, bool) {
	lst, err := os.Lstat(p)
	if err != nil || !lst.Mode().IsRegular() {
		return nil, false
	}
	f, err := os.OpenFile(p, os.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	fst, err := f.Stat()
	if err != nil || !fst.Mode().IsRegular() || !os.SameFile(lst, fst) {
		return nil, false
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil || len(b) == 0 || int64(len(b)) > max {
		return nil, false
	}
	return b, true
}

// handleGetIngest serves GET-INGEST for the peer's own user: one "F <name_b64> <bytes_b64>" line per
// staged file. A mapped dir is read through the overlay, for the snapshot's names only (see the header).
func handleGetIngest(conn net.Conn, peerUID int) {
	if peerUID <= 0 {
		ingestNone(conn, "?", "no-peer")
		return
	}
	userID := strconv.Itoa(peerUID / 100000)
	plain := filepath.Join(ingestMediaBase, userID, ingestDir)
	_, mapped := ingestResolveDir(plain)
	dir := plain
	var snap map[string]int64
	if mapped {
		var ok bool
		if snap, ok = ingestSnapshotFor(userID); !ok {
			ingestNone(conn, userID, "mapped-no-snapshot")
			return
		}
	}
	if !ingestStagingDirOK(dir, false) {
		if _, err := os.Lstat(dir); !mapped && os.IsNotExist(err) {
			fmt.Fprint(conn, "NONE\n") // nothing staged: an ordinary sign-in stays silent
			return
		}
		ingestNone(conn, userID, "dir-refused")
		return
	}
	names, err := ingestList(dir, mapped)
	if err != nil {
		ingestNone(conn, userID, "list-failed")
		return
	}
	if mapped {
		var known []string
		for _, n := range names {
			if _, inSnap := snap[n]; inSnap {
				known = append(known, n)
			}
		}
		names = known
	}
	if len(names) == 0 && !mapped {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	var out strings.Builder
	out.WriteString("OK\n")
	total, served := 0, 0
	emit := func(name string) {
		p := filepath.Join(dir, name)
		if mapped {
			if st, err := os.Lstat(p); err != nil || !st.Mode().IsRegular() || st.Size() != snap[name] {
				return
			}
		}
		b, ok := ingestReadFn(p, ingestMaxFileBytes)
		if !ok || total+len(b) > ingestMaxTotal {
			return
		}
		total += len(b)
		served++
		out.WriteString("F ")
		out.WriteString(base64.StdEncoding.EncodeToString([]byte(name)))
		out.WriteByte(' ')
		out.WriteString(base64.StdEncoding.EncodeToString(b))
		out.WriteByte('\n')
	}
	for _, n := range names {
		emit(n)
	}
	if served == 0 {
		ingestNone(conn, userID, "none-readable")
		return
	}
	via := "plain"
	if mapped {
		via = "overlay"
	}
	ingestLogf("[logind] ingest: user %s: served %d of %d staged file(s) via %s (NWP-20261203-15)\n", userID, served, len(names), via)
	fmt.Fprint(conn, out.String())
}
