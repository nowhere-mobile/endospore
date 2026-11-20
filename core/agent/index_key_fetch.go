package main

// index_key_fetch.go -- the index-key object's fetch, its durable seq floor, the held copy and the key selector
// (NWP-20261126-14, decision #8 of 2026-11-02 in docs/product-decisions.md, "twenty-four answers to the open-decisions
// list ...").
//
// The model is build_warning_fetch.go: the phone reads one signed envelope from ref/ota/index-key, checks the blob
// against its name, and holds it to the highest seq it has accepted, on plain /data so a reboot cannot reset it. The
// same rule: the SAME object (by hash) as the floor's re-verifies at floor-1 and must carry the floor's seq; any other
// object must be strictly above the floor, so an older one, or a different one at the floor's seq, is a replay.
//
// Three differences from the build warning:
//   - The phone also keeps the accepted envelope verbatim (indexKeyHeldPath): the selected key must hold after a
//     reboot with no network, and the floor names a hash, not a key.
//   - A failed durable write is an error and the object is not used: a rollover the phone did not keep would be lost
//     at the next reboot. The next fetch retries.
//   - A damaged floor is rebuilt from the held envelope (h57 #7, docs/product-decisions.md 2026-11-04, "nine answers to
//     harvest 57"; NWP-20261210-18): when the held copy verifies, its seq and hash become the floor, which
//     acceptIndexKey rewrites with one log line, so an object at or below that seq is still refused. currentIndexKey
//     answers from the held object and writes nothing. Only when the held copy is damaged too (absent, unreadable or
//     not verifying) does the phone fail closed: every object is refused and currentIndexKey answers "". A damaged
//     floor is NEVER read as absent: floor 0 would let a replayed older rollover restore a revoked key. An unreadable
//     floor (an I/O error, not bad content) refuses every object, as before. Failing closed is safe because the phone
//     always keeps the baked /system index, which rides verified boot, so a refused /data refresh costs freshness only.
//
// NWP-20261129-18 built the calls: refreshOtaCache calls fetchIndexKey beside the build-warning refresh, and index.go
// calls currentIndexKey. The operator's put command is a later slice. No goroutine.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
)

// indexKeyRefName is where the envelope is published: ref/ota/index-key, beside ota/build-warning. One object for
// every device. Read anonymously, as the build warning is.
const indexKeyRefName = "ota/index-key"

// indexKeyEnvMax bounds the envelope: a body of at most indexKeyMaxBytes plus the magic and the signature line.
const indexKeyEnvMax = indexKeyMaxBytes + 512

// Fixed texts: a store error is never wrapped, since a cap error can carry a presigned URL.
var (
	errIndexKeyStore        = errors.New("index key: store error")
	errIndexKeyMissing      = errors.New("index key: blob missing")
	errIndexKeyTooBig       = errors.New("index key: blob over the cap")
	errIndexKeyHash         = errors.New("index key: blob does not match its name")
	errIndexKeyFloorRead    = errors.New("index key: floor unreadable")
	errIndexKeyFloorDamaged = errors.New("index key: floor damaged")
	errIndexKeyFloorSeq     = errors.New("index key: the floor's object carries another seq")
	errIndexKeyHeldMissing  = errors.New("index key: the held copy and the floor disagree")
)

// fetchIndexKeyEnvelope returns the published envelope's bytes, checked against the blob's name but NOT verified, or
// (nil, nil) when nothing is published.
func fetchIndexKeyEnvelope(base string) (env []byte, err error) {
	defer func() {
		if p := recover(); p != nil {
			env, err = nil, errIndexKeyStore // never the panic's text: it can hold a URL
		}
	}()
	h := getRef(base, indexKeyRefName)
	if h == "" {
		return nil, nil
	}
	// Bounded read: one byte past the cap, so a larger blob is refused WITHOUT being held whole.
	b, ok := getBlobSoftMax(base, h, indexKeyEnvMax+1)
	if !ok {
		return nil, errIndexKeyMissing
	}
	if len(b) > indexKeyEnvMax {
		return nil, errIndexKeyTooBig
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != h {
		return nil, errIndexKeyHash
	}
	return b, nil
}

// --- the durable pair: the floor and the held envelope ---
//
// Both on plain /data beside build-warning-seq, NOT in $NOWHERE_STATE: that is tmpfs, so a reboot would reset the
// anti-replay floor and a captured older rollover would replay, and the selected key would not hold offline. Both
// 0600, written by a synced temp + rename (writeIndexKeyFile). They hold a seq, a hash and a public, release-signed
// envelope that is the same for every device: nothing about who uses the phone. Vars so tests point them at a temp dir.

// indexKeySeqPath is the floor: one line, "<seq> <sha256 hex of the accepted envelope>\n".
var indexKeySeqPath = "/data/nowhere/index-key-seq"

// indexKeyHeldPath is the accepted envelope verbatim.
var indexKeyHeldPath = "/data/nowhere/index-key"

var indexKeyFloorRe = regexp.MustCompile(`\A([1-9][0-9]*) ([0-9a-f]{64})\n\z`)

// readIndexKeyFloor returns the floor; an absent file is floor 0 with no hash. Any other read error, or content that is
// not exactly one line of a positive seq and a lower-case hash, is an error. It never rewrites a damaged file: only a
// rename writes it, so damage is interference from outside the agent.
func readIndexKeyFloor(path string) (int64, string, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0, "", nil
	}
	if err != nil {
		return 0, "", errIndexKeyFloorRead
	}
	m := indexKeyFloorRe.FindSubmatch(b)
	var seq int64
	if m != nil {
		seq, err = strconv.ParseInt(string(m[1]), 10, 64)
	}
	if m == nil || err != nil || seq <= 0 {
		return 0, "", errIndexKeyFloorDamaged
	}
	return seq, string(m[2]), nil
}

// heldIndexKeyFloor is the floor a damaged one is rebuilt from (h57 #7): the held envelope at heldPath, verified as a
// fresh object (floor 0: any seq >= 1, no expiry by design), and the envelope's hash. An absent, unreadable or
// unverifiable held copy means both files are damaged: errIndexKeyFloorDamaged. It writes nothing and logs nothing.
func heldIndexKeyFloor(heldPath string, now int64) (*indexKeyObject, string, error) {
	held, err := os.ReadFile(heldPath)
	if err != nil {
		return nil, "", errIndexKeyFloorDamaged
	}
	obj, err := verifyIndexKeyObject(indexKeyObjectKey, held, now, 0)
	if err != nil {
		return nil, "", errIndexKeyFloorDamaged
	}
	sum := sha256.Sum256(held)
	return obj, hex.EncodeToString(sum[:]), nil
}

// indexKeyFileSync syncs a temp file before its rename; a var so tests can fail or count it.
var indexKeyFileSync = func(f *os.File) error { return f.Sync() }

// writeIndexKeyFile writes data to path through a synced temp file and a rename, then syncs the directory, as
// writeBuildWarningFloor does (on f2fs the rename can reach the disk before the data, and a torn floor reads as damaged
// and refuses every later object). A failed write, sync, close or rename removes the temp and leaves the old file.
// There is no MkdirAll: at a missing directory the write fails and creates nothing. The directory sync is best effort:
// by then the new file has landed.
func writeIndexKeyFile(path string, data []byte) error {
	tmp := path + ".tmp"
	fh, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	_, werr := fh.Write(data)
	serr := indexKeyFileSync(fh)
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

// acceptIndexKey verifies env against the floor at seqPath and, for a new object, keeps it: the held envelope at
// heldPath FIRST, then the floor. A crash between the two leaves a new held copy and the old floor, which
// currentIndexKey reads as a mismatch (no /data refresh) until the next fetch writes both; the reverse order would
// leave a floor naming an envelope the phone does not hold. A failed write returns an error and no object.
//
// A damaged floor (h57 #7) is rewritten FIRST from a held copy that verifies, and env is then judged against the
// rebuilt floor. acceptIndexKey stays the only writer of the floor. Both damaged, or the floor unreadable: refused, and
// nothing is written.
func acceptIndexKey(seqPath, heldPath string, env []byte, now int64) (*indexKeyObject, error) {
	seq, stored, err := readIndexKeyFloor(seqPath)
	if err == errIndexKeyFloorDamaged {
		hobj, hh, herr := heldIndexKeyFloor(heldPath, now)
		if herr != nil {
			fmt.Fprintln(os.Stderr, "[index-key] refused: the floor and the held copy are both damaged")
			return nil, herr
		}
		if werr := writeIndexKeyFile(seqPath, []byte(fmt.Sprintf("%d %s\n", hobj.Seq, hh))); werr != nil {
			fmt.Fprintf(os.Stderr, "[index-key] damaged floor not rebuilt at seq %d: the object is not used\n", hobj.Seq)
			return nil, werr
		}
		fmt.Fprintf(os.Stderr, "[index-key] damaged floor rebuilt at seq %d from the held copy\n", hobj.Seq)
		seq, stored, err = hobj.Seq, hh, nil
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] refused: %v\n", err)
		return nil, err
	}
	sum := sha256.Sum256(env)
	h := hex.EncodeToString(sum[:])
	if h == stored {
		// The SAME object re-verifies at every fetch (else it would be accepted once and then refused as a replay).
		// It must carry the floor's own seq. Nothing is written.
		obj, err := verifyIndexKeyObject(indexKeyObjectKey, env, now, seq-1)
		if err == nil && obj.Seq != seq {
			obj, err = nil, errIndexKeyFloorSeq
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "[index-key] the accepted object (seq %d) refused: %v\n", seq, err)
			return nil, err
		}
		return obj, nil
	}
	// Any other object must be strictly above the floor: an older one, or a different one at the same seq, is refused.
	obj, err := verifyIndexKeyObject(indexKeyObjectKey, env, now, seq)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] refused at floor %d: %v\n", seq, err)
		return nil, err
	}
	if err := writeIndexKeyFile(heldPath, env); err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] held copy not kept for seq %d: the object is not used\n", obj.Seq)
		return nil, err
	}
	if err := writeIndexKeyFile(seqPath, []byte(fmt.Sprintf("%d %s\n", obj.Seq, h))); err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] floor not kept for seq %d (was %d): the object is not used\n", obj.Seq, seq)
		return nil, err
	}
	return obj, nil
}

// currentIndexKey returns the key the /data index refresh is to be checked against, from the durable pair: the baked
// indexPubKey when the phone holds no object; activeIndexKey(indexPubKey, obj) when the floor and the held envelope
// agree (same hash) and the held object re-verifies at floor-1 with the floor's seq; else "" with one log line (one
// file without the other, a hash mismatch, an unreadable floor, a held object that no longer verifies).
//
// A damaged floor (h57 #7): the held object, when it verifies, selects the key; when it does not, "". This path WRITES
// NOTHING: it runs from getIndex, concurrently with refreshOtaCache's acceptIndexKey, and a second writer could roll
// the floor back below a seq the accept just wrote (writeIndexKeyFile uses one fixed temp name). The next fetch's
// acceptIndexKey rewrites the floor.
//
// "" means "no /data refresh is accepted", NEVER "unsigned": the baked /system copy still serves. In index.go the
// selected key replaces indexPubKey ONLY for loadIndexBytesWith's /data branch and refreshIndex's checks; the
// `indexPubKey == ""` branches trust the baked copy unsigned, so an "" from here must never reach them.
func currentIndexKey(now int64) string {
	seq, stored, err := readIndexKeyFloor(indexKeySeqPath)
	if errors.Is(err, errIndexKeyFloorDamaged) {
		hobj, _, herr := heldIndexKeyFloor(indexKeyHeldPath, now)
		if herr != nil {
			fmt.Fprintln(os.Stderr, "[index-key] no /data refresh key: the floor and the held copy are both damaged")
			return ""
		}
		fmt.Fprintf(os.Stderr, "[index-key] floor damaged: the held object (seq %d) selects the key until the next fetch rewrites the floor\n", hobj.Seq)
		return activeIndexKey(indexPubKey, hobj)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] no /data refresh key: %v\n", err)
		return ""
	}
	held, err := os.ReadFile(indexKeyHeldPath)
	heldAbsent := errors.Is(err, fs.ErrNotExist)
	if err != nil && !heldAbsent {
		fmt.Fprintln(os.Stderr, "[index-key] no /data refresh key: the held copy is unreadable")
		return ""
	}
	if seq == 0 && heldAbsent {
		return activeIndexKey(indexPubKey, nil)
	}
	if seq == 0 || heldAbsent {
		fmt.Fprintf(os.Stderr, "[index-key] no /data refresh key: %v\n", errIndexKeyHeldMissing)
		return ""
	}
	sum := sha256.Sum256(held)
	if hex.EncodeToString(sum[:]) != stored {
		fmt.Fprintf(os.Stderr, "[index-key] no /data refresh key: the held copy is not the floor's object (seq %d)\n", seq)
		return ""
	}
	obj, err := verifyIndexKeyObject(indexKeyObjectKey, held, now, seq-1)
	if err == nil && obj.Seq != seq {
		obj, err = nil, errIndexKeyFloorSeq
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] no /data refresh key: the held object (seq %d) fails: %v\n", seq, err)
		return ""
	}
	return activeIndexKey(indexPubKey, obj)
}

// fetchIndexKey fetches the published object and holds it to the device's floor. (nil, nil) when nothing is
// published. The fetch error is returned as it is, never wrapped. refreshOtaCache calls it after each completed check.
func fetchIndexKey(base string, now int64) (*indexKeyObject, error) {
	env, err := fetchIndexKeyEnvelope(base)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[index-key] not fetched: %s\n", logSafeErrText(err))
		return nil, err
	}
	if env == nil {
		return nil, nil
	}
	return acceptIndexKey(indexKeySeqPath, indexKeyHeldPath, env, now)
}
