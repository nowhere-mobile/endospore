package main

// build_warning_fetch.go -- the build warning's fetch and its durable seq floor (NWP-20261113-23, Q098 in
// docs/product-decisions.md).
//
// The phone reads one signed envelope from ref/ota/build-warning, checks the blob against its name, and holds it to
// the highest seq it has accepted, kept on plain /data so a reboot cannot reset it. The one rule: the SAME object (by
// hash) as the floor's re-verifies at every refresh, still held to freshness and expiry; any other object must be
// strictly above the floor, so an older one, or a different one at the floor's seq, is a replay. Any error means no
// notice; a warning never blocks anything. The daemon's cache is at the end of this file (NWP-20261113-27), with
// GET-BUILD-WARNING, the lock-free verb the gate's notice asks (NWP-20261120-03).

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"time"
)

// buildWarningRefName is where the envelope is published: ref/ota/build-warning, beside the OTA markers. One object
// for every device, since the notice is the same for everyone. Read anonymously (a free read cap in cap mode); written
// only by the operator's build-warning-put (NOWHERE-1143).
const buildWarningRefName = "ota/build-warning"

// buildWarningEnvMax bounds the envelope: a body of at most buildWarningMaxBytes plus the magic and the signature line.
const buildWarningEnvMax = buildWarningMaxBytes + 512

// Fixed texts: a store error is never wrapped, since a cap error can carry a presigned URL.
var (
	errBuildWarningStore        = errors.New("build warning: store error")
	errBuildWarningMissing      = errors.New("build warning: blob missing")
	errBuildWarningTooBig       = errors.New("build warning: blob over the cap")
	errBuildWarningHash         = errors.New("build warning: blob does not match its name")
	errBuildWarningFloorRead    = errors.New("build warning: floor unreadable")
	errBuildWarningFloorDamaged = errors.New("build warning: floor damaged")
	errBuildWarningFloorSeq     = errors.New("build warning: the floor's object carries another seq")
)

// fetchBuildWarningEnvelope returns the published envelope's bytes, checked against the blob's name but NOT verified,
// or (nil, nil) when nothing is published.
func fetchBuildWarningEnvelope(base string) (env []byte, err error) {
	defer func() {
		if p := recover(); p != nil {
			env, err = nil, errBuildWarningStore // never the panic's text: it can hold a URL
		}
	}()
	h := getRef(base, buildWarningRefName)
	if h == "" {
		return nil, nil
	}
	// Bounded read: one byte past the cap, so a larger blob is refused WITHOUT being held whole.
	b, ok := getBlobSoftMax(base, h, buildWarningEnvMax+1)
	if !ok {
		return nil, errBuildWarningMissing
	}
	if len(b) > buildWarningEnvMax {
		return nil, errBuildWarningTooBig
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != h {
		return nil, errBuildWarningHash
	}
	return b, nil
}

// --- the floor: the highest seq this phone has accepted, and the hash of that envelope ---
//
// Kept on plain /data beside ota-seen, NOT in $NOWHERE_STATE: that is tmpfs, so a reboot would reset the anti-replay
// floor to nothing, and a captured older warning (or one a later seq lifted) would be shown again until its own
// expiry (Q098). One line, "<seq> <sha256 hex of the accepted envelope>\n", 0600, written by temp + rename. It names a
// seq and a hash only: device-level, and nothing about who uses the phone or which build it runs.
var buildWarningSeqPath = "/data/nowhere/build-warning-seq" // var so tests point it at a temp file

var buildWarningFloorRe = regexp.MustCompile(`\A([1-9][0-9]*) ([0-9a-f]{64})\n\z`)

// readBuildWarningFloor returns the floor; an absent file is floor 0 with no hash. Content that is not exactly one
// line of a positive seq and a lower-case hash is errBuildWarningFloorDamaged; any other read error is
// errBuildWarningFloorRead. It reports damage and never rewrites the file: acceptBuildWarning reads a damaged floor as
// an absent one and the next accepted object replaces it (h54 #4, docs/product-decisions.md, "five answers to harvest
// 54 ..."). An unreadable file stays an error that refuses.
func readBuildWarningFloor(path string) (int64, string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, "", nil
	}
	if err != nil {
		return 0, "", errBuildWarningFloorRead
	}
	m := buildWarningFloorRe.FindSubmatch(b)
	var seq int64
	if m != nil {
		seq, err = strconv.ParseInt(string(m[1]), 10, 64)
	}
	if m == nil || err != nil || seq <= 0 {
		return 0, "", errBuildWarningFloorDamaged
	}
	return seq, string(m[2]), nil
}

// buildWarningFloorSync syncs the floor's temp file before the rename; a var so tests can fail or count it, as
// confFileSync (NWP-20261123-30).
var buildWarningFloorSync = func(f *os.File) error { return f.Sync() }

// writeBuildWarningFloor records seq and hash through a synced temp file and a rename, then syncs the directory
// (NWP-20261123-30), as writeConfDurable publishes the conf. Why the sync: on f2fs the rename can reach the disk
// before the new file's data, so a power cut soon after an accept can leave the floor empty or short. A torn floor
// reads as damaged, which acceptBuildWarning treats as absent (h54 #4), so a torn write costs the replay floor until
// the next accept replaces it. A failed write, sync or close removes the temp and leaves the old floor;
// so does a failed rename. There is no MkdirAll: at a missing directory the write fails and creates nothing. A
// failed write still shows the warning (acceptBuildWarning). The directory sync is best effort: by then the new floor
// has landed.
func writeBuildWarningFloor(path string, seq int64, hash string) error {
	tmp := path + ".tmp"
	fh, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, werr := fh.Write([]byte(fmt.Sprintf("%d %s\n", seq, hash)))
	serr := buildWarningFloorSync(fh)
	cerr := fh.Close()
	if err := errors.Join(werr, serr, cerr); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	if d, err := os.Open(filepath.Dir(path)); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

// acceptBuildWarning verifies env against the floor at path and advances the floor when env is a new object.
//
// A damaged floor is read as an absent one (h54 #4, docs/product-decisions.md, "five answers to harvest 54 ..."):
// the object is verified above floor 0 with no stored hash, and once it is accepted its seq and hash replace the
// damaged file, with a log line. The cost accepted: over a damaged floor, as over an absent one, a replayed older
// object that is still fresh and unexpired is accepted once. A damaged floor plus an object that does not verify is
// refused and the file is left as it is. Only damage reads as absent: a read that cannot complete
// (errBuildWarningFloorRead, an unreadable file or a directory) still refuses, since h54 #4 settles damaged content,
// not a floor the agent cannot read.
func acceptBuildWarning(path string, env []byte, now int64) (*buildWarning, error) {
	seq, stored, err := readBuildWarningFloor(path)
	damaged := errors.Is(err, errBuildWarningFloorDamaged)
	if damaged {
		fmt.Fprintln(os.Stderr, "[build-warning] floor damaged; treated as absent")
		seq, stored, err = 0, "", nil
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[build-warning] not shown: %v\n", err)
		return nil, err
	}
	sum := sha256.Sum256(env)
	h := hex.EncodeToString(sum[:])
	if h == stored {
		// The SAME object re-verifies at every refresh (else it would be shown once and then refused as a replay),
		// still held to freshness and expiry. It must carry the floor's own seq. Nothing is written.
		w, err := verifyBuildWarning(buildWarningKey, env, now, seq-1)
		if err == nil && w.Seq != seq {
			w, err = nil, errBuildWarningFloorSeq
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "[build-warning] the accepted object (seq %d) not shown: %v\n", seq, err)
			return nil, err
		}
		return w, nil
	}
	// Any other object must be strictly above the floor: an older one, or a different one at the same seq, is refused.
	w, err := verifyBuildWarning(buildWarningKey, env, now, seq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[build-warning] refused at floor %d: %v\n", seq, err)
		return nil, err
	}
	// A failed write still shows the warning (it is a warning, never a block); the next refresh re-tries it.
	if err := writeBuildWarningFloor(path, w.Seq, h); err != nil {
		fmt.Fprintf(os.Stderr, "[build-warning] floor not kept for seq %d (was %d)\n", w.Seq, seq)
	} else if damaged {
		fmt.Fprintf(os.Stderr, "[build-warning] damaged floor replaced by seq %d\n", w.Seq)
	}
	return w, nil
}

// fetchBuildWarning fetches the published warning and holds it to the device's floor. (nil, nil) when nothing is
// published.
func fetchBuildWarning(base string, now int64) (*buildWarning, error) {
	env, err := fetchBuildWarningEnvelope(base)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[build-warning] not fetched: %s\n", logSafeErrText(err))
		return nil, err
	}
	if env == nil {
		return nil, nil
	}
	return acceptBuildWarning(buildWarningSeqPath, env, now)
}

// --- the daemon's cache (NWP-20261113-27): refreshed beside each completed OTA check, read from memory ---
//
// The gate must never wait on the store for this (IdleLogoffReceiver.java records the 60 s ANR a blocking daemon
// call cost it), so the fetch runs in refreshOtaCache, on kickOtaRefresh's single-flighted goroutine, and a reader
// only reads bwCurrent. Not kept across a reboot: the durable state is the seq floor, and the next completed check
// fills the cache again.
var (
	bwMu      sync.Mutex
	bwCurrent *buildWarning // nil = no notice
)

// refreshBuildWarning replaces the cached warning with what fetch returns. ANY error clears it, never keeps the last
// one: "any fetch or verify error means no notice" (Q098). The accepted cost: whoever can block the fetch can hide the
// warning, the price of a warning that never blocks. A warning already expired at now is not kept either.
func refreshBuildWarning(now int64, fetch func() (*buildWarning, error)) {
	w, err := fetch()
	if err != nil {
		// A fixed line: the fetch already logged the cause, and an error text can hold a URL.
		fmt.Fprintln(os.Stderr, "[build-warning] no notice: the fetch or the check failed")
		w = nil
	}
	if w != nil && now >= w.Expires {
		w = nil
	}
	bwMu.Lock()
	bwCurrent = w
	bwMu.Unlock()
}

// buildWarningAffects reports whether the cached warning names version and has not expired at now. Memory only: no
// I/O, no store call. It is what a gate-side reader calls: handleGetBuildWarning, below.
func buildWarningAffects(version string, now int64) bool {
	bwMu.Lock()
	defer bwMu.Unlock()
	return bwCurrent != nil && now < bwCurrent.Expires && bwCurrent.affects(version)
}

// buildWarningVersion is the running build's version, the one GET-BUILD-WARNING checks. Tests replace it.
var buildWarningVersion = runningOtaVersion

// handleGetBuildWarning answers GET-BUILD-WARNING (NWP-20261120-03): "WARN" when the cached warning names this build
// and has not expired, "NONE" otherwise (no cache, an expired or non-matching warning, an empty version). Memory and the
// baked version file only: no store, no session lock, no log line. Lock-free (concurrentSafeCmd). The verdict takes no
// argument and is the same for everyone at this phone, so it tells nothing about any profile.
func handleGetBuildWarning(w io.Writer) {
	if buildWarningAffects(buildWarningVersion(), time.Now().Unix()) {
		fmt.Fprint(w, "WARN\n")
		return
	}
	fmt.Fprint(w, "NONE\n")
}
