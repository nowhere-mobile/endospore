package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/minio/minio-go/v7"
	"golang.org/x/sys/unix"
)

// h51 #2 (docs/product-decisions.md, 2026-11-01, "a store restored short of some deferred pieces: check after landing,
// and hold the first save until the check is done"; NWP-20261207-02). The sign-in used to SEED every deferred chunk
// of the head into the known-present blob cache, on the belief that a chunk the live head names is in the store. A
// store filled by the restore page, or copied by another tool, can be short of some of them: the seal's carry then
// passed (deferredChunksKnown) for objects nobody checked, and the seal published a head naming objects the store
// does not hold. Now:
//
//  1. The restore LISTS the head's deferred chunks in the pending file (writeDeferredPending) and marks none of them.
//  2. After the user lands, the daemon's late sign-in work asks the store about each, in the background
//     (settleSignInPresence), notes as stored only the ones that exist, and drops those from the list.
//  3. A seal whose stored head names a deferred chunk still on the list (or any of them, when there is no list at
//     all) checks those itself before the walk (sealDeferredGuard), and refuses while one is missing or unanswered.
//
// The check runs at every sign-in: a copy made by another tool leaves no mark this build could read.
//
// THE PENDING FILE, in $NOWHERE_STATE (root-only tmpfs, wiped at power-off), one per profile and scope:
//   - absent: no restore listed this head this boot, so nothing proved its deferred chunks: the seal checks them all;
//   - present: each line is a chunk hash nobody has proved present yet;
//   - empty: every listed hash is proved, or the head had none.
//
// Beside it, <file>.gen names the list's generation: each restore (and a seal that lists a head no restore listed)
// starts a new one, and a check publishes its results only into the generation it read, so a check left over from an
// earlier sign-in never clears a later one's list. <file>.lock serialises the rewrites.
//
// No log line here names a profile, an app or a chunk hash: counts and fixed reason tokens only.

// deferredPresenceFile names the scope's pending file: the shape of healListFile, a hash of the scope's store ref, so
// neither the profile name nor the ref itself sits in the state dir. Every scope has one (no scopeDefersMedia
// exemption: the vault's own head can still carry deferred entries an older handset wrote).
func deferredPresenceFile(profile, pass string) string {
	sum := sha256.Sum256([]byte(profileRefV2(profile, pass)))
	return "deferred-presence-" + hex.EncodeToString(sum[:8])
}

// deferredPresenceScopes are the suffixes one sign-in restores; settleSignInPresence settles each one's file.
var deferredPresenceScopes = []string{"", "#de", "#media", "#apps", "#sys", "#keys"}

// deferredPresencePaths is the pending file of every scope of profile, in deferredPresenceScopes's order.
func deferredPresencePaths(stateDir, profile, pass string) []string {
	out := make([]string, 0, len(deferredPresenceScopes))
	for _, s := range deferredPresenceScopes {
		out = append(out, filepath.Join(stateDir, deferredPresenceFile(profile+s, pass)))
	}
	return out
}

// deferredPresenceBudget bounds one settle: no probe starts after it, and every hash not probed counts as unknown,
// which a seal refuses as deferred-unchecked. A var so tests shrink it.
var deferredPresenceBudget = 10 * time.Minute

// deferredPresenceWorkers is how many probes run at once.
const deferredPresenceWorkers = 8

// deferredChunkProbe asks the store whether the sealed chunk h exists. An error is a store that could not answer,
// never an answer: a 403 on a fresh cap is an error (capRefExists's rule), never absence. A var so tests stub the
// store. Every arm logs and returns only fixed tokens: the shared helpers (capRefExists, s3ExistsErr) put the key,
// and so the chunk hash, into their retry lines and their errors (logSafeWhat keeps a blob hash on purpose), and
// this path's rule is counts and fixed reason tokens only.
var deferredChunkProbe = func(base, h string) (bool, error) {
	key := "blob/" + h
	if isS3(base) && capMode() {
		return presenceCapExists(key)
	}
	if isS3(base) {
		return presenceS3Exists(key)
	}
	resp, err := storeHTTP.Get(base + "/" + key)
	if err != nil {
		return false, presenceErr("transport", false)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<10)) // the answer is the status: stop reading early
	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound:
		return false, nil
	}
	return false, presenceErr(fmt.Sprintf("status %d", resp.StatusCode), false)
}

// presenceWhat is the retry label of every presence probe: fixed, so a retry line never carries the chunk hash.
const presenceWhat = "presence probe blob/<chunk>"

// presenceProbeErr is a probe failure as a fixed token. A permanent one unwraps to errStorePermanent, so retryStore
// stops there and the give-up clock counts it as an answer, as capRefExists's fresh-403 error does.
type presenceProbeErr struct {
	token string
	perm  bool
}

func (e *presenceProbeErr) Error() string { return "presence probe: " + e.token }

func (e *presenceProbeErr) Unwrap() error {
	if e.perm {
		return errStorePermanent
	}
	return nil
}

func presenceErr(token string, perm bool) error { return &presenceProbeErr{token: token, perm: perm} }

// presenceCapExists is capRefExists with fixed-token errors and label: a one-byte GET through a free read cap. 200,
// 206 and 416 (an empty object) are present, 404 absent; the first 403 drops the cap and retries, a 403 on a fresh cap
// is permanent and never absence; anything else retries, then is returned.
func presenceCapExists(key string) (bool, error) {
	var exists bool
	fresh403 := false
	err := retryStore(presenceWhat, func() error {
		exists = false
		u, err := capReadURL(key)
		if err != nil {
			return presenceErr("no read cap", false)
		}
		req, err := http.NewRequest(http.MethodGet, u, nil)
		if err != nil {
			return presenceErr("bad read cap", true)
		}
		req.Header.Set("Range", "bytes=0-0")
		resp, err := storeHTTP.Do(req)
		if err != nil {
			capInvalidate(key)
			return presenceErr("transport", false)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<10)) // a store that ignores Range sends it all: stop
		switch resp.StatusCode {
		case http.StatusOK, http.StatusPartialContent, http.StatusRequestedRangeNotSatisfiable:
			exists = true
			return nil
		case http.StatusNotFound:
			return nil
		case http.StatusForbidden:
			if !fresh403 {
				fresh403 = true
				capInvalidate(key)
				return presenceErr("403 on a possibly-stale cap (refetching)", false)
			}
			return presenceErr("403 on a fresh cap", true)
		}
		capInvalidate(key)
		return presenceErr(fmt.Sprintf("status %d", resp.StatusCode), false)
	})
	return exists, err
}

// presenceS3Exists is s3ExistsErr with fixed-token errors and label: a minio error carries the key in its text and in
// its request URL.
func presenceS3Exists(key string) (bool, error) {
	cl, bk := s3Init()
	exists := false
	err := retryStore(presenceWhat, func() error {
		_, err := cl.StatObject(context.Background(), bk, key, minio.StatObjectOptions{})
		if err != nil {
			er := minio.ToErrorResponse(err)
			if er.Code == "NoSuchKey" || er.StatusCode == 404 {
				return nil
			}
			if er.StatusCode != 0 {
				return presenceErr(fmt.Sprintf("status %d", er.StatusCode), false)
			}
			return presenceErr("transport", false)
		}
		exists = true
		return nil
	})
	return exists, err
}

// clearDeferredPending removes the scope's pending file, so a restore that dies before it lists the head leaves no
// list from an earlier sign-in of the same profile this boot (the seal then checks the whole head).
func clearDeferredPending(stateDir, profile, pass string) {
	if stateDir != "" {
		path := filepath.Join(stateDir, deferredPresenceFile(profile, pass))
		os.Remove(path)
		os.Remove(path + ".gen")
	}
}

// writeDeferredPending lists m's deferred chunks, distinct and sorted, as nobody-has-proved-them-yet. Written even
// when empty: an empty list says the restore ran and the head names no deferred chunk, which differs from no list.
// No-op off-device (no state dir).
func writeDeferredPending(stateDir, profile, pass string, m chunkManifest) error {
	if stateDir == "" {
		return nil
	}
	set := map[string]bool{}
	for _, d := range m.Deferred {
		for _, h := range d.Chunks {
			set[h] = true
		}
	}
	path := filepath.Join(stateDir, deferredPresenceFile(profile, pass))
	return withPendingLock(path, func() error { return startPendingList(path, set) })
}

// startPendingList publishes set as a NEW list at path: a new generation first, then the list. A settle that read an
// older generation then publishes nothing (settleDeferredPresenceGuarded), so a check left over from an earlier
// sign-in never clears what a later restore listed. The caller holds the path's lock.
func startPendingList(path string, set map[string]bool) error {
	var g [8]byte
	if _, err := rand.Read(g[:]); err != nil {
		return err
	}
	if err := writeFileAtomic(path+".gen", hex.EncodeToString(g[:])+"\n"); err != nil {
		return err
	}
	return writePendingSet(path, set)
}

// pendingGen is the generation of the list at path, "" when it has none. The caller holds the path's lock.
func pendingGen(path string) string {
	b, _ := os.ReadFile(path + ".gen")
	return strings.TrimSpace(string(b))
}

// readDeferredPending reads a pending file. An absent file is exists == false with no error.
func readDeferredPending(path string) (set map[string]bool, exists bool, err error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	set = map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			set[line] = true
		}
	}
	return set, true, nil
}

// writePendingSet publishes set at path, sorted, one per line, 0600, through a temp file and a rename. The caller
// holds the path's lock.
func writePendingSet(path string, set map[string]bool) error {
	hs := make([]string, 0, len(set))
	for h := range set {
		hs = append(hs, h)
	}
	sort.Strings(hs)
	var b strings.Builder
	for _, h := range hs {
		b.WriteString(h)
		b.WriteByte('\n')
	}
	return writeFileAtomic(path, b.String())
}

// writeFileAtomic writes body to path, 0600, through a temp file and a rename.
func writeFileAtomic(path, body string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o600); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// withPendingLock runs fn under an exclusive flock on path+".lock" (wallet_lock.go's pattern). The daemon's late
// step and a seal worker can settle one file at once; the lock is held only for a re-read and rewrite, never across
// a probe.
func withPendingLock(path string, fn func() error) error {
	f, err := os.OpenFile(path+".lock", os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	for {
		err = unix.Flock(int(f.Fd()), unix.LOCK_EX)
		if !errors.Is(err, unix.EINTR) {
			break
		}
	}
	if err != nil {
		return err
	}
	defer unix.Flock(int(f.Fd()), unix.LOCK_UN)
	return fn()
}

// The verdict of one probe; the zero value is unknown, so a hash no probe reached stays unknown.
const (
	presUnknown = iota
	presPresent
	presMissing
)

// settleDeferredPresence asks the store about every hash in the pending file at path (only those in only, when only
// is not nil), records each present one in the blob cache file at cachePath, and drops it from the pending file. A
// missing or unanswered hash stays listed. onProbe, when not nil, is called after each probe with done of total, one
// call at a time. An empty list returns at once, with no store call and no line. An absent list, or one that cannot be
// read or locked, settles nothing: every hash of only then counts as unknown, so a seal refuses deferred-unchecked
// rather than trusting a blob cache an earlier sign-in filled (RF-003).
func settleDeferredPresence(base, path, cachePath string, only map[string]bool, onProbe func(done, total int)) (present, missing, unknown int) {
	return settleDeferredPresenceGuarded(base, path, cachePath, only, onProbe, nil)
}

// settleDeferredPresenceGuarded is settleDeferredPresence with a late step's guard (nil = always), asked before each
// probe and again, under the list's lock, before any result is published. The results are published only when the
// list still has the generation this settle read: a new restore of the scope (a later sign-in) starts a new
// generation, and an older check's confirmations are then dropped, neither recorded in the blob cache nor cleared
// from the new list. A confirmation not published counts as unknown.
func settleDeferredPresenceGuarded(base, path, cachePath string, only map[string]bool, onProbe func(done, total int), mayWrite func() bool) (present, missing, unknown int) {
	if _, err := os.Stat(path); errors.Is(err, fs.ErrNotExist) {
		return 0, 0, len(only) // no list: nothing to settle, and no lock file is made for it; a seal's set stays unchecked
	}
	var listed map[string]bool
	var exists bool
	var gen string
	err := withPendingLock(path, func() error {
		var err error
		listed, exists, err = readDeferredPending(path)
		gen = pendingGen(path)
		return err
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "[presence] deferred check: the pending list could not be read (%s) (h51 #2)\n", errCode(err))
		return 0, 0, len(only) // nothing probed: a seal's set stays unchecked, never passed on a cached belief
	}
	if !exists {
		return 0, 0, len(only) // the list went away before the lock: the same as no list
	}
	var hs []string
	for h := range listed {
		if only == nil || only[h] {
			hs = append(hs, h)
		}
	}
	if len(hs) == 0 {
		return 0, 0, 0
	}
	sort.Strings(hs)
	start := time.Now()
	deadline := start.Add(deferredPresenceBudget)
	if isS3(base) && capMode() {
		for i := 0; i < len(hs) && time.Now().Before(deadline); i += restoreCapBatch {
			keys := make([]string, 0, restoreCapBatch)
			for _, h := range hs[i:min(i+restoreCapBatch, len(hs))] {
				keys = append(keys, "blob/"+h)
			}
			prefetchReadCaps(keys)
		}
	}
	res := make([]int, len(hs))
	work := make(chan int)
	var wg sync.WaitGroup
	var progMu sync.Mutex
	done := 0
	for w := 0; w < min(deferredPresenceWorkers, len(hs)); w++ {
		wg.Add(1)
		goSafe("deferred-presence-probe", func() {
			defer wg.Done()
			for i := range work {
				if !time.Now().Before(deadline) || !lateMayWrite(mayWrite) {
					continue // past the budget, or the session ended: no new probe, the hash stays unknown
				}
				ok, err := deferredChunkProbe(base, hs[i])
				switch {
				case err != nil:
					res[i] = presUnknown // the store could not answer: never "present"
				case ok:
					res[i] = presPresent
				default:
					res[i] = presMissing
				}
				if onProbe != nil {
					progMu.Lock()
					done++
					onProbe(done, len(hs))
					progMu.Unlock()
				}
			}
		})
	}
	for i := range hs {
		work <- i
	}
	close(work)
	wg.Wait()
	confirmed := map[string]bool{}
	for i, r := range res {
		switch r {
		case presPresent:
			present++
			confirmed[hs[i]] = true
		case presMissing:
			missing++
		default:
			unknown++
		}
	}
	if len(confirmed) > 0 {
		published := false
		if err := withPendingLock(path, func() error {
			cur, exists, err := readDeferredPending(path)
			if err != nil || !exists || pendingGen(path) != gen || !lateMayWrite(mayWrite) {
				return err // a list cleared or replaced meanwhile, or a session that ended, takes none of these results
			}
			recordPresent(cachePath, confirmed)
			for h := range confirmed {
				delete(cur, h)
			}
			if err := writePendingSet(path, cur); err != nil {
				return err
			}
			published = true
			return nil
		}); err != nil {
			fmt.Fprintf(os.Stderr, "[presence] deferred check: the pending list was not updated (%s) (h51 #2)\n", errCode(err))
		}
		if !published {
			fmt.Fprintf(os.Stderr, "[presence] deferred check: %d confirmation(s) dropped: the list was replaced or the session ended (h51 #2)\n", len(confirmed))
			present -= len(confirmed)
			unknown += len(confirmed)
		}
	}
	fmt.Fprintf(os.Stderr, "[presence] deferred check: %d present, %d missing, %d unknown in %dms (h51 #2)\n",
		present, missing, unknown, time.Since(start).Milliseconds())
	return present, missing, unknown
}

// recordPresent appends each confirmed hash to the blob cache file at cachePath. When cachePath is this process's
// own blobCachePath(), blobCacheAdd also marks it in the in-memory set; otherwise (the login daemon writing the file
// its seal workers read) the file is written directly.
func recordPresent(cachePath string, confirmed map[string]bool) {
	hs := make([]string, 0, len(confirmed))
	for h := range confirmed {
		hs = append(hs, h)
	}
	sort.Strings(hs)
	if cachePath == blobCachePath() {
		for _, h := range hs {
			blobCacheAdd(h)
		}
		return
	}
	if cachePath == "" {
		return
	}
	blobCacheMu.Lock()
	defer blobCacheMu.Unlock()
	f, err := os.OpenFile(cachePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	var b strings.Builder
	for _, h := range hs {
		b.WriteString(h)
		b.WriteByte('\n')
	}
	f.WriteString(b.String())
}

// settleSignInPresence is the late sign-in step: it settles the pending file of each of profile's scopes, asking
// mayWrite before each, and stops at the first refusal (the session ended or the job was abandoned). Only this
// profile's files are read: another profile's list is never this session's to settle.
func settleSignInPresence(base, stateDir, cachePath, profile, pass string, mayWrite func() bool) {
	if stateDir == "" {
		return
	}
	paths := deferredPresencePaths(stateDir, profile, pass)
	for _, p := range paths {
		if !lateMayWrite(mayWrite) {
			return
		}
		settleDeferredPresenceGuarded(base, p, cachePath, nil, nil, mayWrite)
	}
}

// sealDeferredGuard is the seal's check before the walk: every deferred chunk the stored head names (oldM) that no
// one has proved present this sign-in is probed now. It returns how many are missing from the store and how many the
// store could not answer; pushProfile refuses on either (deferred-missing, deferred-unchecked). A hash still listed
// that the head does not name is never probed and never refuses. Inert off-device and for a head with no deferred
// entry. Whenever the head names one, the blob cache file is merged into this process's set first, so a hash the
// daemon's late step confirmed passes the carry's deferredChunksKnown.
func sealDeferredGuard(base, profile, pass string, oldM chunkManifest) (missing, unknown int) {
	st := os.Getenv("NOWHERE_STATE")
	if st == "" || len(oldM.Deferred) == 0 {
		return 0, 0
	}
	want := map[string]bool{}
	for _, d := range oldM.Deferred {
		for _, h := range d.Chunks {
			want[h] = true
		}
	}
	if len(want) == 0 {
		return 0, 0
	}
	path := filepath.Join(st, deferredPresenceFile(profile, pass))
	listed, exists, err := readDeferredPending(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[presence] deferred check: the pending list could not be read (%s) (h51 #2)\n", errCode(err))
		return 0, len(want)
	}
	if !exists {
		listed = want // no restore listed this head this sign-in, so nothing proved its deferred chunks
		if err := withPendingLock(path, func() error { return startPendingList(path, want) }); err != nil {
			fmt.Fprintf(os.Stderr, "[presence] deferred check: the pending list was not written (%s) (h51 #2)\n", errCode(err))
			return 0, len(want)
		}
	}
	pending := map[string]bool{}
	for h := range listed {
		if want[h] {
			pending[h] = true
		}
	}
	if len(pending) > 0 {
		// The #87 rule: a changing, labelled frame keeps the daemon's stall watchdog alive through a long check.
		prevPhase, _ := progPhase.Load().(string)
		setProgPhase("sizes")
		_, missing, unknown = settleDeferredPresence(base, path, blobCachePath(), pending, func(done, total int) {
			if done%16 == 0 || done == total {
				writeProg(done, total)
			}
		})
		setProgPhase(prevPhase)
	}
	blobCacheMergeFile()
	return missing, unknown
}

// blobCacheMergeFile adds every hash in the blob cache file to the in-memory set: a union, never a drop. A hash
// another process (the login daemon's late step) recorded after this process loaded the set then counts as known.
func blobCacheMergeFile() {
	blobCacheMu.Lock()
	defer blobCacheMu.Unlock()
	blobCacheInit()
	p := blobCachePath()
	if p == "" {
		return
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		if line = strings.TrimSpace(line); line != "" {
			blobCache[line] = true
		}
	}
}
