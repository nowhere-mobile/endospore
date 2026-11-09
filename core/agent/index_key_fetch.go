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
//   - A damaged or unreadable floor refuses every object. This keeps the fail-closed rule for this channel. It is an
//     inference by analogy, not a decision (h54 #4 relaxed the rule only for build warnings, "a warning never
//     blocks"); it is safe here because the phone always keeps the baked /system index, which rides verified boot, so
//     a refused /data refresh costs freshness only.
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
func acceptIndexKey(seqPath, heldPath string, env []byte, now int64) (*indexKeyObject, error) {
	seq, stored, err := readIndexKeyFloor(seqPath)
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
// file without the other, a hash mismatch, a damaged or unreadable floor, a held object that no longer verifies).
//
// "" means "no /data refresh is accepted", NEVER "unsigned": the baked /system copy still serves. In index.go the
// selected key replaces indexPubKey ONLY for loadIndexBytesWith's /data branch and refreshIndex's checks; the
// `indexPubKey == ""` branches trust the baked copy unsigned, so an "" from here must never reach them.
func currentIndexKey(now int64) string {
	seq, stored, err := readIndexKeyFloor(indexKeySeqPath)
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
