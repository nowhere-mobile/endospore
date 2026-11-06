package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

// DELETE-SNAPSHOT (NWP-20261027-04): the user removes ONE retained snapshot from "Restore a snapshot"
// (docs/product-decisions.md, 2026-10-19, "a user can delete the backups (snapshots) they pick, and a deleted one
// is gone at once"). The verb names exactly one History entry by version: never the current state (the live head
// is not in History), and there is no "delete all".
//
// "Gone at once" is met for the list (the vault is resealed without the entry before OK) and for GET-USAGE
// (profileFootprint no longer counts or leases the entry's manifest or any chunk only it referenced).
//
// The store objects only that entry referenced are then RELEASED for the gateway's next collection, not left to
// their lease (docs/product-decisions.md 2026-10-19: "released soon -- at the gateway's next collection after the
// delete, not on the lease schedule of up to about 60 days"; 2026-10-20: on proof of a per-blob release secret,
// docs/store-write-authorization.md R5). [Superseded: this comment used to say the release "needs a gateway path
// that drops a held lease, which does not exist (the decision's inference, to confirm)"; that path is POST
// /release and releaseDeletedSnapshot calls it.] The release happens only AFTER the new head landed and was read
// back as the one this delete published, and never under per-unit heads, where another unit's bare head can name
// the same chunks under the same key and this verb does not read it. A blob first leased before its commitment
// existed, or under another key, is not released and keeps the lease schedule.
//
// Every delete bumps vault.ReleaseGen, released or not: any delete may release, and a generation that moves
// without a release costs the other handsets one cold seal (they drop a blob cache filled under the older
// generation, release_gen.go), never data.

// deleteSnapshot is a var so the handler tests can stub the store round trip.
var deleteSnapshot = deleteSnapshotStore

// deleteSnapshotStore removes the History entry with the given version and republishes the vault. It is a vault
// edit like the re-tag clear (dropBillRetag), not a new head version: Version, Manifest, HeadKind and LastSeal
// are left as they were. A version no entry carries answers errNoSnapshot (a stale list). Cap-mode writes ride a
// lease via capWrite.
func deleteSnapshotStore(base, name, pass string, version uint64, se []byte) error {
	hd, v, isV := readVaultHead(base, name, pass) // to open the DK and check the target: re-read in the bracket
	if hd.val == "" {
		return errors.New("no profile / wrong passphrase")
	}
	if !isV {
		return errors.New("legacy head has no snapshot history")
	}
	dk := openVaultDKSE(v, name, pass, se) // pass -> secure element -> fido2 (#81)
	if dk == nil {
		// ⚠ NOT "wrong passphrase" (NWP-20260915-15): the caller resolved the head with (name, pass), so the
		// passphrase is known good here, and a hardened vault has no pass slot to open without its secret.
		return errors.New("no slot opens for this profile on this device")
	}
	if !verifyVault(v, dk) {
		return errors.New("head signature invalid -- refusing to trust its snapshot list")
	}
	findEntry := func(v *vault) (int, error) {
		if version == v.Version {
			// The live head is never in a well-formed History, so it cannot be named. A malformed head that
			// lists its own version must not lose the current state's entry through this verb either.
			return -1, errNoSnapshot
		}
		for i := range v.History {
			if v.History[i].Version == version {
				return i, nil
			}
		}
		return -1, errNoSnapshot // the version churned out of the window, or the list was stale
	}
	if _, err := findEntry(v); err != nil {
		return err
	}
	// The entry is found again in the head read INSIDE the bracket, never by the index from the read above: a
	// re-key batch or another device's seal may have prepended or pruned entries in between, and the edit lands
	// on that head instead of putting the vault read above back over it.
	var perr error
	var removed headSnap     // the entry this delete took out of History
	var published *vault     // the vault the bracket posted, after the delete
	var publishedHead string // the head value it put: what the read-back must still find
	vd := capWrite(name, pass, dk, func() {
		cur, err := capReadVaultForEdit(base, "snapshot delete", name, pass, dk, true) // strict, as the check above
		i := -1
		if err == nil {
			i, err = findEntry(cur)
		}
		if err != nil {
			perr = err
			capAbort()
			return
		}
		// An entry whose Manifest equals the live head's (a rollback leaves one) is removed from the LIST only:
		// its manifest and chunks stay leased by the live head, and chunks shared with a kept entry stay leased by
		// that entry (profileFootprint is keyed by blob).
		removed = cur.History[i]
		cur.History = append(cur.History[:i:i], cur.History[i+1:]...)
		if len(cur.History) == 0 {
			cur.History = nil // omitempty drops the key, as for a vault that never had history
		}
		cur.ReleaseGen++ // NWP-20261029-10: every delete, released or not (see the header)
		signVault(cur, dk)
		vh := postBlob(base, serializeVault(cur))
		putHead(base, name, pass, vh)
		if cur.RecoveryRef != "" {
			putRef(base, cur.RecoveryRef, vh)
		}
		pub := *cur
		published, publishedHead = &pub, vh
	})
	// A head that did not land is never followed by a release: its old version still names the chunks. The
	// release's result never changes the reply -- the snapshot is gone from the list either way, and a release
	// that does not happen leaves the chunks on the lease schedule.
	if perr == nil && !vd.Refused() && published != nil {
		releaseDeletedSnapshotFn(base, name, pass, dk, removed, published, publishedHead)
	}
	if vd.Refused() {
		return errors.New("snapshot delete refused at publish: the store did not accept the new head")
	}
	return perr
}

// handleDeleteSnapshot answers DELETE-SNAPSHOT: remove the live session's retained snapshot <version>. Reply
// OK | NONE | LOCAL | BUSY | NOSNAP | ERR-ARG | ERR, one line, never a credential-shaped word. Unlike a
// rollback nothing on the phone changes, so the session is not torn down and .roamsession stays.
func handleDeleteSnapshot(conn net.Conn, dest, verStr string) {
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	if localOnlySession(dest) {
		fmt.Fprint(conn, "LOCAL\n") // a throwaway or offline session has no store head / snapshots
		return
	}
	ver, perr := strconv.ParseUint(verStr, 10, 64)
	if perr != nil || ver == 0 {
		fmt.Fprint(conn, "ERR-ARG\n") // 0 is not "newest" here: the verb names exactly one entry
		return
	}
	// The guards handleRollback takes: a seal in flight would race the head edit (and could write the entry
	// back), and a teardown already queued means this session is ending anyway. BUSY changes nothing.
	if sealAnnounced() {
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q user %s: BUSY -- a seal is running or queued\n", name, uid)
		fmt.Fprint(conn, "BUSY\n")
		return
	}
	if why := endUnsavedBlocked(uid); why != "" {
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q user %s: BUSY -- %s\n", name, uid, why)
		fmt.Fprint(conn, "BUSY\n")
		return
	}
	seSecret := readRoamSessionSE(dest)
	// A store read that fails in transport PANICS (checkRead): recovered into an error so the chooser still gets a
	// reply, as handleRollback does.
	var err error
	func() {
		defer func() {
			if r := recover(); r != nil {
				err = recoveredErr("snapshot delete", r)
			}
		}()
		err = deleteSnapshot("s3", name, pass, ver, seFromHex(seSecret))
	}()
	if errors.Is(err, errNoSnapshot) {
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q user %s: NOSNAP (v%d is not a retained snapshot)\n", name, uid, ver)
		fmt.Fprint(conn, "NOSNAP\n") // stale list -> the user picks again
		return
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q user %s FAILED: %s\n", name, uid, logSafeErrText(err))
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q user %s: v%d removed from the snapshot list\n", name, uid, ver)
	fmt.Fprint(conn, "OK\n")
}

// releaseDeletedSnapshotFn is a var so the tests of the bracket can stub the release.
var releaseDeletedSnapshotFn = releaseDeletedSnapshot

// snapshotReleaseWait bounds how long DELETE-SNAPSHOT waits for its POST /release (see releaseDeletedSnapshot); a
// var so a test can shorten it.
var snapshotReleaseWait = gwUI

// releaseDeletedSnapshot hands the blobs only removed referenced to the gateway's next collection. It never
// returns an error and never panics: whatever it cannot do leaves them on the lease schedule. kept is the vault
// the delete published and publishedHead the head value it put.
//
// The request runs on a goSafe job and the verb waits for it at most snapshotReleaseWait (gwUI, 10 s): it holds
// sessionMu, and each batch of the request can ride a client budget of up to 71 s, past the chooser's 90 s read.
// Past the wait one line is written and the request goes on in the background; a blob it does not release keeps
// its lease schedule. The eviction, the generation record and the read-back all happen before the request.
func releaseDeletedSnapshot(base, name, pass string, dk []byte, removed headSnap, kept *vault, publishedHead string) {
	skip := func(format string, a ...any) {
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q: nothing released early -- "+format+"\n", append([]any{name}, a...)...)
	}
	if !capMode() {
		skip("this store has no gateway")
		return
	}
	if multiDeviceEnabled() {
		skip("per-unit heads of other devices are not read")
		return
	}
	set, err := snapshotReleaseSet(base, dk, removed, kept)
	if err != nil {
		skip("a kept version could not be read (%v)", err)
		return
	}
	if len(set) == 0 {
		skip("every object is still named by the current state or a kept version")
		return
	}
	// Evict first: a handset's cache that still believed a released blob present would publish a manifest naming
	// it. The generation is recorded only when the eviction succeeded; otherwise the next seal finds the
	// mismatch and drops the whole cache (release_gen.go), the safe direction.
	hk := relGenHeadKey(base, name, pass)
	cache := workerBlobCachePath()
	evicted, eerr := blobCacheEvict(cache, set)
	if eerr == nil {
		relGenRecord(cache, hk, kept.ReleaseGen)
	}
	// Read back immediately before the request. The publish check is not a compare-and-swap (seal_cas.go), so a
	// head that landed can still be overwritten, within about one round trip, by another handset whose vault
	// lists the deleted version; this read is the record that the effect still stands. A handset that
	// overwrote it in that window is caught here, after the whole set computation, and one that writes later
	// sees this head at its own re-check and is refused.
	var now string
	func() {
		defer func() {
			if p := recover(); p != nil {
				now = ""
			}
		}()
		now = getRef(base, hk)
	}()
	if now != publishedHead {
		skip("the head changed after the delete landed")
		return
	}
	proofs := make(map[string]string, len(set))
	for k := range set {
		proofs[k] = hex.EncodeToString(blobReleaseProof(dk, k))
	}
	// The job captures the proofs and the gateway URL, never dk. done is buffered and the job always sends one
	// result, so it never blocks once the verb has stopped waiting.
	type releaseResult struct {
		released []string
		status   int
		err      error
	}
	done := make(chan releaseResult, 1)
	gw := os.Getenv("GATEWAY_URL")
	goSafe("snapshot-release", func() {
		var r releaseResult
		defer func() {
			if p := recover(); p != nil {
				r = releaseResult{err: recoveredErr("release", p)}
			}
			done <- r
		}()
		r.released, r.status, r.err = newGatewayClient(gw, gwDefault).releaseBlobs(proofs)
	})
	var released []string
	var status int
	select {
	case r := <-done:
		released, status, err = r.released, r.status, r.err
	case <-time.After(snapshotReleaseWait):
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q: the gateway is still taking the release -- not waiting\n", name)
		return
	}
	switch {
	case status == http.StatusNotFound || status == http.StatusMethodNotAllowed:
		skip("the gateway does not release early")
	case err != nil:
		skip("the gateway did not take the request (status %d)", status)
	default:
		fmt.Fprintf(os.Stderr, "[logind] snapshot delete %q: %d of %d unshared object(s) released for the next collection (%d evicted from this phone's cache)\n",
			name, len(released), len(set), evicted)
	}
}
