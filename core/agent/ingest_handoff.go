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
// media_server.go). A read THROUGH that FUSE overlay lists the deferred stub beside the real files and makes
// mediad fetch it from the store inside this socket handler. So the staging dir is resolved first
// (ingestResolveDir): when the published mountpoint -> hidden map (publishedMediaUnders) names the dir, or an
// ancestor of it, every ReadDir, Stat and ReadFile goes to the hidden .under path, which holds only real
// on-disk files -- exactly the non-deferred ones -- and never fetches. A deferred file is simply not served
// (the chooser has nothing to ingest from it at login). If the map names the dir but the hidden path is
// unreadable (a torn-down bind), the answer is NONE: falling back to the overlay path would be the very fetch
// this avoids. With no map entry the plain path is read, as before (NWP-20260827-26).

var ingestMediaBase = "/data/media" // var so tests can redirect

// ingestUndersFn supplies the mountpoint -> hidden map; var so tests can inject one.
var ingestUndersFn = publishedMediaUnders

// ingestResolveDir maps dir to the hidden .under path when the map names dir or its nearest mapped ancestor,
// and reports whether it did. A mapped dir is never read in place.
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
// login is cheap next to the round trip; dir is the resolved real dir, so a deferred one is not listed (see
// the header). A mapped dir that does not exist is an error, not "nothing staged".
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
// planted at any component would redirect the read, as root, to a tree the user does not own.
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
// staged file.
func handleGetIngest(conn net.Conn, peerUID int) {
	if peerUID <= 0 {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	userID := strconv.Itoa(peerUID / 100000)
	dir, mapped := ingestResolveDir(filepath.Join(ingestMediaBase, userID, ingestDir))
	if !ingestStagingDirOK(dir, mapped) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	names, err := ingestList(dir, mapped)
	if err != nil || len(names) == 0 {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	var out strings.Builder
	out.WriteString("OK\n")
	total := 0
	emit := func(name string) {
		b, ok := ingestReadStaged(filepath.Join(dir, name), ingestMaxFileBytes)
		if !ok || total+len(b) > ingestMaxTotal {
			return
		}
		total += len(b)
		out.WriteString("F ")
		out.WriteString(base64.StdEncoding.EncodeToString([]byte(name)))
		out.WriteByte(' ')
		out.WriteString(base64.StdEncoding.EncodeToString(b))
		out.WriteByte('\n')
	}
	for _, n := range names {
		emit(n)
	}
	if out.Len() <= len("OK\n") {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprint(conn, out.String())
}
