package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
)

// NWP-20260919-08: THE COMPLETENESS INDEX. An export is a copy of a content-addressed store, and
// `sha256(bytes) == key` verifies every object that IS there while saying nothing about the ones that are
// not. profile-export-restore.md §5 has asked for this artifact since the design was written; nothing wrote
// or read one, and three separate failures all resolve to its absence:
//
//   - NWP-20260919-05: the DEFERRED chunks are seeded as present and never fetched at login, so a folder
//     missing them yields a green login, a green seal, and a head naming objects that are not in the store.
//     Nothing downstream can notice, and the gateway cannot either -- postBlob returns on blobCacheKnown
//     BEFORE capBufferPut, so a falsely-present chunk is never leased and the GC reaps it.
//   - NWP-20260918-01: a SHORT footprint (a scope that no keyslot opened) reads exactly like a small
//     profile. The verb refuses on !measured now; nothing carried that refusal into the copy.
//   - Tombstones: a deleted profile leaves a ref that EXISTS with an EMPTY value, which is a different
//     state from absent. Copy one and the identity is dead on arrival, with blind login rendering that
//     identically to a wrong passphrase.
//
// ⚠ REFS ARE NOT CONTENT-ADDRESSED AND THAT IS THE WHOLE REASON THIS FILE EXISTS. A blob's key IS its
// hash, so presence is almost the whole story. A ref is a MUTABLE 64-byte pointer whose name says nothing
// about its value -- so a ref can arrive present, well-formed, and WRONG (stale head, another profile's
// head, tombstone) and no content check anywhere can see it. The manifest therefore records a blob's SIZE
// and a ref's VALUE, and they are different columns because they are different guarantees.
//
// ⚠ IT NAMES NOTHING THAT IS NOT ALREADY A FILENAME IN THE FOLDER. No profile name, no passphrase, no
// scope labels: object keys and head values only, all of which are the names and contents of files the copy
// already carries. The manifest adds no disclosure surface to an export that did not already have.
const exportManifestVersion = 1

// The refusals buildExportManifest can return. They are SENTINELS rather than error strings because the
// daemon verb branches on them to choose a wire reply, and matching on prose is how a reply silently stops
// matching the day someone rewords a message.
var (
	// errExportNothingStored is the blank-login shape: an unknown profile and a wrong passphrase are the
	// same answer, deliberately.
	errExportNothingStored = errors.New("nothing stored (unknown profile, wrong passphrase, or never sealed)")
	// errExportUnmeasured is a scope that resolved to a vault no keyslot opened -- the index would be SHORT.
	errExportUnmeasured = errors.New("a scope resolved to a vault that no keyslot opened, so this index " +
		"would be SHORT -- refusing rather than certifying an incomplete copy")
)

// ExportManifest is the index an export writes and a restore verifies against.
type ExportManifest struct {
	Version int `json:"version"`
	// Blobs are content-addressed: the key IS the sha256, so the key is the integrity check and size is a
	// cheap corroboration. Sorted by key, so two exports of the same profile diff cleanly.
	Blobs []ManifestBlob `json:"blobs"`
	// Refs are pointers. The VALUE is the load-bearing field -- see the file header.
	Refs []ManifestRef `json:"refs"`
}

// ManifestBlob is one content-addressed object: "blob/<sha256>" and its stored size.
type ManifestBlob struct {
	Key  string `json:"key"`
	Size int64  `json:"size"`
}

// ManifestRef is one pointer: "ref/<name>" and its contents at export time. Value is NEVER empty -- an
// empty one is a tombstone and buildExportManifest refuses to emit it.
type ManifestRef struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// buildExportManifest enumerates a profile and records what a complete copy must contain.
//
// It REFUSES rather than emitting a partial index, because a partial index is worse than none: it would
// make a short copy look verified. The three refusals are the three ways the enumeration can be wrong.
func buildExportManifest(base, profile, pass string, se, recEntropy []byte) (*ExportManifest, error) {
	refs, measured := profileFootprintRec(base, profile, pass, se, recEntropy)
	if len(refs) == 0 {
		// Blank-login shape, preserved deliberately: an unknown profile and a wrong passphrase are the
		// same answer here as they are everywhere else.
		return nil, errExportNothingStored
	}
	if !measured {
		// The same rule the footprint verb and handleGetFootprint both state. A copy recipe built from a
		// short list silently loses whatever that scope held.
		return nil, errExportUnmeasured
	}
	m := &ExportManifest{Version: exportManifestVersion}
	keys := make([]string, 0, len(refs))
	for k := range refs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		name, isRef := strings.CutPrefix(k, "ref/")
		if !isRef {
			m.Blobs = append(m.Blobs, ManifestBlob{Key: k, Size: refs[k]})
			continue
		}
		v := strings.TrimSpace(getRef(base, name))
		if v == "" {
			// ⚠ A TOMBSTONE, OR A REF THAT VANISHED BETWEEN THE WALK AND NOW. Both must stop the export.
			// §6 asks the exporter to refuse to emit an empty-valued ref so a tombstone can never travel;
			// this is that refusal, and HERE is the only place it can be made -- at the destination a
			// tombstone and a ref that simply has not arrived are the same observation.
			return nil, fmt.Errorf("%s is present but EMPTY (a tombstone, or deleted mid-export) -- "+
				"refusing: copying it produces an identity that is dead on arrival, and blind login "+
				"renders that identically to a wrong passphrase", k)
		}
		m.Refs = append(m.Refs, ManifestRef{Key: k, Value: v})
	}
	return m, nil
}

// VerifyReport is what verifyExportManifest found. Every slice in it is a reason to REFUSE; an empty
// report is the only pass.
type VerifyReport struct {
	MissingBlobs []string // named in the manifest, absent from the store
	MissingRefs  []string // ditto, or present-but-empty at the destination
	WrongRefs    []string // present with a value the manifest does not name
	CorruptBlobs []string // deep verify only: the fetched bytes do not hash to the key
	Unreadable   []string // the store did not answer this read; never evidence the object is there or not
	CheckedBlobs int
	CheckedRefs  int
	DeepVerified bool
}

func (r *VerifyReport) ok() bool {
	return len(r.MissingBlobs) == 0 && len(r.MissingRefs) == 0 &&
		len(r.WrongRefs) == 0 && len(r.CorruptBlobs) == 0 && len(r.Unreadable) == 0
}

// verifyExportManifest proves a store contains everything the manifest names.
//
// ⚠ THE DEFAULT IS PRESENCE, NOT CONTENT, AND THAT IS DELIBERATE RATHER THAN LAZY. The failure this exists
// to catch is a MISSING object; corruption on the read path is already covered, where getChunk hashes every
// fetch and retries (#207). Presence is a cheap size probe, so a ~12,317-object profile stays verifiable
// instead of becoming a full re-download. `deep` re-hashes every blob for when the transfer itself is under
// suspicion -- the same question, paid for at a different price.
//
// Refs are ALWAYS compared by value. There is no cheap half for a pointer.
func verifyExportManifest(base string, m *ExportManifest, deep bool) *VerifyReport {
	rep := &VerifyReport{DeepVerified: deep}
	if m == nil {
		return rep
	}
	for _, r := range m.Refs {
		name, ok := strings.CutPrefix(r.Key, "ref/")
		if !ok {
			rep.WrongRefs = append(rep.WrongRefs, r.Key+" (not a ref key)")
			continue
		}
		rep.CheckedRefs++
		// NWP-20261120-20: getRef panics on a transport failure in every mode, and the CLI arm has no recover,
		// so one dropped read used to lose the whole report. It is listed UNREADABLE and the loop goes on.
		// The error is dropped, never printed: a transport error can carry a presigned URL.
		var got string
		if err := recovered(func() { got = strings.TrimSpace(getRef(base, name)) }); err != nil {
			rep.Unreadable = append(rep.Unreadable, r.Key)
			continue
		}
		switch {
		case got == "":
			// Absent and tombstoned are the same answer here, and both are fatal to the copy.
			rep.MissingRefs = append(rep.MissingRefs, r.Key)
		case got != r.Value:
			rep.WrongRefs = append(rep.WrongRefs, r.Key)
		}
	}
	for _, b := range m.Blobs {
		hash, ok := strings.CutPrefix(b.Key, "blob/")
		if !ok {
			rep.MissingBlobs = append(rep.MissingBlobs, b.Key+" (not a blob key)")
			continue
		}
		rep.CheckedBlobs++
		if deep {
			// NWP-20261120-20: getBlobSoft panics in S3 and cap mode (see its comment); same rule as the ref read.
			var data []byte
			var found bool
			if err := recovered(func() { data, found = getBlobSoft(base, hash) }); err != nil {
				rep.Unreadable = append(rep.Unreadable, b.Key)
				continue
			}
			if !found {
				rep.MissingBlobs = append(rep.MissingBlobs, b.Key)
				continue
			}
			sum := sha256.Sum256(data)
			if hex.EncodeToString(sum[:]) != hash {
				rep.CorruptBlobs = append(rep.CorruptBlobs, b.Key)
			}
			continue
		}
		if !blobPresent(base, hash) {
			rep.MissingBlobs = append(rep.MissingBlobs, b.Key)
		}
	}
	return rep
}

// summary renders a report for a human. It leads with the counts so a pass is auditable rather than merely
// green -- the same reason verify-release.sh prints what it read.
func (r *VerifyReport) summary() string {
	var b strings.Builder
	mode := "presence"
	if r.DeepVerified {
		mode = "deep (every blob re-hashed)"
	}
	fmt.Fprintf(&b, "checked %d blob(s) and %d ref(s) -- %s\n", r.CheckedBlobs, r.CheckedRefs, mode)
	sect := func(label string, xs []string) {
		if len(xs) == 0 {
			return
		}
		fmt.Fprintf(&b, "%s (%d):\n", label, len(xs))
		for i, x := range xs {
			if i == 12 {
				fmt.Fprintf(&b, "  ... and %d more\n", len(xs)-12)
				break
			}
			fmt.Fprintf(&b, "  %s\n", x)
		}
	}
	sect("MISSING refs", r.MissingRefs)
	sect("WRONG refs (present, but not the value the export recorded)", r.WrongRefs)
	sect("MISSING blobs", r.MissingBlobs)
	sect("CORRUPT blobs", r.CorruptBlobs)
	// Every unreadable key is printed, with no twelve-line cap: it is the list the operator re-reads.
	if len(r.Unreadable) > 0 {
		fmt.Fprintf(&b, "UNREADABLE (%d):\n", len(r.Unreadable))
		for _, k := range r.Unreadable {
			fmt.Fprintf(&b, "  UNREADABLE %s -- the store did not answer; refusing\n", k)
		}
	}
	return b.String()
}

func (m *ExportManifest) encode() ([]byte, error) {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

func decodeExportManifest(b []byte) (*ExportManifest, error) {
	var m ExportManifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("not a readable export manifest: %w", err)
	}
	if m.Version != exportManifestVersion {
		// Refuse an unknown version rather than verifying the subset we recognise and reporting success --
		// the entire value of this file is that a pass means something.
		return nil, fmt.Errorf("export manifest version %d, this agent understands %d",
			m.Version, exportManifestVersion)
	}
	if len(m.Refs) == 0 {
		// A profile with no refs has no head, so it cannot be logged into. An index naming only blobs
		// would verify green and restore nothing.
		return nil, fmt.Errorf("export manifest names no refs -- a copy made from it has no head and " +
			"cannot be logged into")
	}
	return &m, nil
}

// getBlobSoft is getBlob without the fail(). Same backends, same key shape ("blob/<hash>"), same cap/direct
// split. Only the plain-HTTP arm is fully soft: it reports a failed read (transport error, non-200, short
// body) as absent. The S3 and cap arms call s3Get / capGet, which answer a 404 (and in cap mode a fresh-cap
// 403) as absent but retry and then PANIC on a transport failure (checkRead -> storeReadErr). So a caller
// that must not die runs it under recovered, as verifyExportManifest and headVersionOf do.
func getBlobSoft(base, hash string) ([]byte, bool) {
	key := "blob/" + hash
	if isS3(base) {
		if capMode() {
			return capGet(key)
		}
		return s3Get(key)
	}
	resp, err := http.Get(base + "/" + key)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, false
	}
	return b, true
}

// blobPresent answers "is this object in the store" without downloading it.
//
// ⚠ IT MUST DISTINGUISH ABSENT FROM UNKNOWN, AND IT DOES SO BY FAILING TOWARD ABSENT. capSize returns -1
// both for "not there" and for "the presign could not be minted", and a verifier that treated an
// unreachable store as a clean pass would be the exact bug class this whole file exists to close -- a check
// that cannot run printing like one that did. So a negative answer here always REFUSES the copy; the
// operator then sees a long missing list rather than a green tick, which is the correct way round.
func blobPresent(base, hash string) bool {
	key := "blob/" + hash
	if isS3(base) {
		if capMode() {
			return capSize(key) >= 0
		}
		_, ok := s3Size(key)
		return ok
	}
	resp, err := http.Head(base + "/" + key)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
