package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// #52 -- media/file export via the chunked store, consistent with CDC roaming.
//
// The user's media ALREADY roams as convergent-sealed, content-addressed chunks under the profile's own key
// (the "name#media" ref) -- so a media export needs NO re-reading of the device tree and NO re-upload: the
// current media head's manifest blob is immutable (content-addressed), and pinning it under the export's media
// pointer IS the export. One tiny ref write total. Since NWP-20261010-02 that pointer is key(proof(media)), derived
// from the name AND the passphrase (export_rekey.go); it was ref/export/<name>#media, keyed by the name alone.
//
// Billing/TTL (decided #52): an export is a temporary downloadable COPY, not permanent footprint.
// profileFootprint never enumerates export refs, so maybePayRent never renews them. The pointer's lease is marked
// "export" (capMarkExpire), so a gateway that honours `expire` collects it about 7 days after it is made; an older
// gateway ignores the mark and the pointer lives out its ordinary lease. The phone promises the 7 days only when the
// gateway's reply says it applied them. The manifest and chunks it names are never marked: they are the profile's
// own live media, kept by its footprint.

// mediaHeadState is what mediaHeadManifest found at the #media head.
type mediaHeadState int

const (
	mediaHeadNone       mediaHeadState = iota // no head, or a delete tombstone: nothing sealed
	mediaHeadOpen                             // opened: manHash and m describe it
	mediaHeadUnopenable                       // a head exists, but no key this session holds opens it
)

// mediaHeadManifest resolves the live media head for (name#media, pass) with the session's secure-element secret
// se, and returns the manifest's BLOB HASH (its content address in the store) plus the parsed manifest for counts.
//
// NWP-20261010-02: se is what opens a TIED profile's #media head -- a tie's re-key moves the scope to a key only the
// chip and the index hold -- so without it a tied profile's media export was silently not made (resolveKey reaches
// the `se` slot only through NOWHERE_SE_SECRET, which the login daemon never carries; NWP-20260916-01 found the same
// for LIST-MEDIA-APPS). And a head that EXISTS but does not open is mediaHeadUnopenable, never "nothing sealed": the
// phone would otherwise say there was nothing to export about a profile whose photos are in the store.
func mediaHeadManifest(base, name, pass string, se []byte) (manHash string, m chunkManifest, st mediaHeadState) {
	key, manifestBlob, ok := resolveKeySession(base, name+"#media", pass, se)
	if !ok {
		ref, val, have := headRef(base, name+"#media", pass)
		if !have {
			val = getRef(base, ref)
		}
		if val == "" {
			return "", m, mediaHeadNone
		}
		return "", m, mediaHeadUnopenable
	}
	sum := sha256.Sum256(manifestBlob)
	manHash = hex.EncodeToString(sum[:])
	var pt []byte
	if recovered(func() { pt = unseal(key, manifestBlob) }) != nil {
		return "", m, mediaHeadUnopenable
	}
	if len(pt) >= len(cdcMagic) && string(pt[:len(cdcMagic)]) == string(cdcMagic) {
		if json.Unmarshal(pt[len(cdcMagic):], &m) != nil {
			return "", m, mediaHeadUnopenable
		}
		return manHash, m, mediaHeadOpen
	}
	// Legacy single-tar media head: still exportable (the fetch side falls back the same way), no chunk stats.
	return manHash, m, mediaHeadOpen
}

// exportMediaTotals sums what the export contains, for the UI: deferred (bulk media) files + bytes, plus the
// sealed size of the essential chunk region (small files, thumbnails, DBs that ride the media tree).
func exportMediaTotals(m chunkManifest) (files int, bytes int64) {
	for _, d := range m.Deferred {
		files++
		bytes += d.Size
	}
	for _, sz := range m.Sizes {
		bytes += sz
	}
	return files, bytes
}

// errExportNoMedia is "nothing sealed under #media yet"; errExportMediaLocked is a #media head this session cannot
// open. The first is NOMEDIA, which the phone does not report as a failure; the second is an error it does.
var (
	errExportNoMedia     = errors.New("no media sealed yet")
	errExportMediaLocked = errors.New("the #media head does not open with this session's keys")
	errExportVaultLocked = errors.New("the profile's vault does not open with this session's keys")
)

// exportMedia pins the current #media manifest as the media export of (name, pass): the media pointer names its hash,
// marked "export" (docs/data-export-rekey.md §4). se is the session's secure-element secret. It returns the totals for
// the reply and the outcome flags; it panics on a store failure, as every bracket does.
func exportMedia(base, name, pass string, se []byte) (files int, bytes int64, out exportOutcome, err error) {
	manHash, m, st := mediaHeadManifest(base, name, pass, se)
	switch st {
	case mediaHeadNone:
		return 0, 0, out, errExportNoMedia
	case mediaHeadUnopenable:
		return 0, 0, out, errExportMediaLocked
	}
	// The bare vault: its key folds the wallet into the bracket and opens the !bill-retag record (exportPrior), and
	// its slots give the 12-words flag. A session whose keys open the #media head but not the vault is one whose chip
	// secret is missing or wrong -- the docs export refuses that as ERR-KEY, and so does this, rather than write a
	// pointer with no record behind its lease. (No bare head at all, v == nil, is not a vault refusing: nothing is
	// lost by writing the pointer, as before.)
	dk, v := resolveDKVault(base, name, pass, se)
	if v != nil && dk == nil {
		return 0, 0, out, errExportVaultLocked
	}
	r := exportMediaRef(deriveKey(name, pass))
	prior := exportPrior(v, dk) // the !bill-retag record, as the docs export names it (exportPrior says why)
	verdict := capWrite(name, pass, dk, func() {
		capSetSessionPrior(prior)
		putRef(base, r.name(), manHash)
		capMarkExpire(r.key, r.proof, expireExport)
	})
	if verdict.Refused() {
		return 0, 0, out, errors.New("the store refused the media export's pointer")
	}
	files, bytes = exportMediaTotals(m)
	return files, bytes, exportOutcome{words: vaultNeedsWords(v), managed: exportViaLease(base),
		expires: containsAll(verdict.ExpireApplied, r.key)}, nil
}

// handleExportMedia backs the Profile app's "Export a copy" media half (#52): pin the CURRENT media head
// manifest under the export's media pointer. The export therefore reflects the LAST media seal (the UI runs a
// Back-up-now first / says so). Replies "OK files=<n> bytes=<n> words=<0|1> expire=<0|1> store=<managed|self>"
// (exportOutcome) | NONE | LOCAL | NOMEDIA (nothing sealed) | ERR-KEY (a #media head this session cannot open) |
// ERR-STORE.
func handleExportMedia(conn net.Conn, dest string) {
	name, pass, _ := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody logged in
		return
	}
	if localOnlySession(dest) {
		fmt.Fprint(conn, "LOCAL\n") // a throwaway/offline session has no store to export from
		return
	}
	loadFido2HmacEnv(dest) // a 2FA vault opens via the enrolled key's cached hmac; self-heal a restarted daemon
	var (
		files int
		bytes int64
		out   exportOutcome
	)
	err := recovered(func() {
		var xerr error
		files, bytes, out, xerr = exportMedia("s3", name, pass, seFromSession(dest))
		check(xerr)
	})
	if errors.Is(err, errExportNoMedia) {
		fmt.Fprint(conn, "NOMEDIA\n") // no media sealed yet -- the docs export can still proceed
		return
	}
	if err != nil {
		// NWP-20261008-09, NWP-20261010-02: the error can carry an export key (redactNameIn takes it out).
		fmt.Fprintf(os.Stderr, "[logind] export-media %q: %s\n", name, redactNameIn(err.Error(), name))
		if errors.Is(err, errExportMediaLocked) || errors.Is(err, errExportVaultLocked) {
			fmt.Fprint(conn, "ERR-KEY\n")
		} else {
			fmt.Fprint(conn, "ERR-STORE\n")
		}
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] export-media %q: pinned manifest (%d files, %d bytes, %s)\n",
		name, files, bytes, out.logNote())
	fmt.Fprintf(conn, "OK files=%d bytes=%d%s\n", files, bytes, out.flags())
}

// exportFetchMedia is the download side (#52) -- the website/storefront reference path, mirroring
// export-fetch: resolve the pinned export manifest, restore its full tree into destDir, and MATERIALIZE the
// deferred (bulk media) files -- off-device there is no mediad to serve stubs, an export must be whole bytes.
// NWP-20261010-02: the re-keyed media pointer first, the legacy ref/export/<name>#media after it, and the manifest
// opened by every key the profile holds (openMediaExportManifest), not only the current #media head's.
func exportFetchMedia(base, name, pass, destDir string) error {
	manHash := exportMediaPointer(base, name, pass)
	if manHash == "" {
		return fmt.Errorf("no media export for %q (expired or never made)", name)
	}
	dk, pt, err := openMediaExportManifest(base, name, pass, getBlob(base, manHash))
	if err != nil {
		return err
	}
	if len(pt) < len(cdcMagic) || string(pt[:len(cdcMagic)]) != string(cdcMagic) {
		// Legacy single-tar media head: restore it whole via the tar path. NWP-20261110-19: untarFrom's skipped
		// count is what tells a partial restore from a whole one (DIA-20260806-10); the reference path must not
		// call a partial export whole, so a count above zero is an error (the count, never a path).
		if n := untarFrom(destDir, bytes.NewReader(pt)); n > 0 {
			return fmt.Errorf("export restore skipped %d entr(y/ies)", n)
		}
		return nil
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		return fmt.Errorf("export manifest parse: %w", err)
	}
	// The essential region (small files) + deferred STUBS. NWP-20261110-19: cdcRestore's count is untarFrom's
	// skipped entries; the reference path must not call a partial export whole, and it stops BEFORE the deferred
	// loop so a partial essential region does not download the bulk files for nothing.
	if n := cdcRestore(base, dk, m, destDir); n > 0 {
		return fmt.Errorf("export restore skipped %d entr(y/ies)", n)
	}
	// Materialize every deferred file over its stub: fetch chunks, unseal, unpack, concatenate (the same
	// contract fetchToCache uses; panics on a corrupt blob are recovered into an error by the caller).
	for rel, d := range m.Deferred {
		out := filepath.Join(destDir, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		f, err := os.OpenFile(out, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
		if err != nil {
			return err
		}
		var written int64
		for i, h := range d.Chunks {
			raw, ue := unpackChunk(unseal(dk, getChunk(base, h)), m.Version)
			if ue != nil {
				f.Close()
				return fmt.Errorf("export chunk %d/%d of %q: %w", i+1, len(d.Chunks), rel, ue)
			}
			n, we := f.Write(raw)
			if we != nil {
				f.Close()
				return we
			}
			written += int64(n)
		}
		if err := f.Close(); err != nil {
			return err
		}
		if written != d.Size {
			return fmt.Errorf("export %q size mismatch: fetched %d, manifest says %d", rel, written, d.Size)
		}
	}
	return nil
}
