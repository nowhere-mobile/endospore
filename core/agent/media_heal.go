package main

// NWP-20260923-02: the on-demand media split runs on #media only. The CE vault and #de stop deferring, and any
// deferred entries their heads still carry are fetched onto the phone at sign-in -- the "heal".
//
// The decision and its reasoning are in docs/product-decisions.md ("the media split runs on #media only", and
// "Answered 2026-09-25"). Every recorded harm of a deferred APP-PRIVATE file was a CE one: a stub is only safe
// for a file nothing needs synchronously, and an app's own files/ can mean anything (WhatsApp's .so and its
// files/Logs, Play's in-progress downloads, AliExpress's write-ahead logs). A deferred CE dir is served
// through a read-only mediad overlay, so roamd cannot even hand an on-demand app's data back through it.
//
// Three parts, each silent when missing:
//   1. scopeDefersMedia gates the seal walk's heuristic. It is written as "the vault and #de do not defer",
//      never "only #media defers": #apps defers on-demand APKs through NOWHERE_DEFER_LIST with the heuristic
//      off, and that must not change.
//   2. The carry stays armed for those two scopes while their heads hold deferred entries (main.go), so an
//      entry the heal could not fetch is carried, never dropped.
//   3. healDeferred, at the restore, writes every deferred file it can fetch into place before roamd's
//      reown -- through the same per-entry rules untarFrom applies (no links followed, the recorded mode and
//      mtime, the package dir's MCS level). It runs at EVERY sign-in whose head carries deferred entries, so
//      the heal is standing, not a one-time migration: a #58 rollback, a web clone, /profile-restore,
//      repoint-scope or an older handset can each put entries back.
//      NWP-20261202-17 (docs/product-decisions.md 2026-10-26, #2: the vault heal may run after landing) moves
//      part of it. Where each scope heals now:
//        - #de: in the sign-in, always. mediad does not serve #de, so an entry left for later would be a file
//          its app cannot read.
//        - the vault, an app in the keep set (nowhere-appkeep): in the sign-in, as before. hold_ondemand parks
//          every kept app's data, in any mode, before any install; an entry landed later would go into the
//          app's placeholder skeleton instead of parking with its data.
//        - the vault, every other app: with NOWHERE_HEAL_AFTER_LANDING=1 (roamd `in`), the sign-in fetches
//          nothing for it. mediad serves each entry on demand and lands it in the background after landing
//          (media_heal_late.go). The entry is not on the heal list, so the carry keeps it until it lands.
//
// Chester's answers of 2026-09-25 shape the heal: existing #de entries are fetched, never dropped; the first
// sign-in's download has no time cap of its own (but must stop cleanly before the login daemon's limits, so
// it reports progress per chunk and stops at healDeadline); and a file that cannot be fetched is carried and
// served on demand forever. The heal publishes what it HANDLED (healListFile): mediad stops serving those and
// the carry stops carrying them, so what it could not fetch keeps its pre-heal treatment. mediad serves only
// the vault (and #media), so a #de file that cannot be fetched is carried with no serve path, as before.

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// scopeDefersMedia reports whether a seal of this profile scope may move files into the Deferred index by
// the on-demand media heuristic. False for the CE vault (a bare name) and #de; true for every other scope.
func scopeDefersMedia(profile string) bool {
	i := strings.LastIndex(profile, "#")
	if i < 0 {
		return false // the CE vault
	}
	return profile[i:] != "#de"
}

// sealScopeDefers is the seal walk's copy of scopeDefersMedia, and the walk's ONLY one: a test swaps it to
// produce the heads an older handset wrote (a vault or #de that still defers), which is what the heal and the
// carry exist to handle. Nothing else reads it -- the carry, the heal and mediad call scopeDefersMedia.
var sealScopeDefers = scopeDefersMedia

// odHoldRelFor maps a canonical per-app rel ("<pkg>/files/x") to where hold_ondemand parks the same file
// ("com.nowhere.chooser/.nowhere-odhold/<pkg>/files/x"). Both CE and DE keep their hold at that path under
// their own volume root.
func odHoldRelFor(rel string) string {
	return chooserPkg + "/" + odHoldDirName + "/" + rel
}

// healListFile names, under NOWHERE_STATE, the list of deferred rels this sign-in's heal HANDLED: fetched onto
// the phone, or found already there or already in the on-demand hold. "" for a scope that still defers.
//
// From the heal on, each of those is an ordinary file, so two readers act on the list. mediad stops serving
// them (an overlay over a dir whose files are real blocks roamd's chown, the Play hand-back failure), and the
// seal's carry stops carrying them, because a handled file that is now ABSENT was deleted -- carrying it would
// bring the deletion back at the next sign-in. Everything NOT on the list keeps the pre-heal treatment: served
// and carried. That covers what the heal could not fetch, and any entry that reached the head after this
// sign-in (a mid-session rollback), which the NEXT sign-in heals. No list at all (an older agent, a restore
// that died before the heal) means nothing was handled: serve and carry everything, as before this build.
//
// ⚠ KEYED BY THE PROFILE, not just the scope. $NOWHERE_STATE lives for the whole boot and every sign-in shares
// it, and the list is the one input that lets a seal drop a deferred entry its walk did not see -- so one
// profile's list must never be read for another's. The name is a hash of the scope's store ref, so neither
// the profile name nor the ref itself sits in the state dir.
func healListFile(profile, pass string) string {
	if scopeDefersMedia(profile) {
		return ""
	}
	sum := sha256.Sum256([]byte(profileRefV2(profile, pass)))
	return "heal-handled-" + hex.EncodeToString(sum[:8])
}

// errHealDeadline stops a heal, between files or mid-file, at healUntil.
var errHealDeadline = errors.New("past the sign-in's heal deadline")

// healUntil is when the heal must stop. roamd sets NOWHERE_HEAL_UNTIL once for the whole sign-in: the daemon's
// 60-minute ceiling (triggerRoamWorker) covers that whole op, every scope's restore included, and the vault and
// #de heals run in two separate restores, so they share one deadline rather than taking a budget each.
// NOWHERE_HEAL_DEADLINE_S (relative, for tests and the CLI) wins when set; with neither, 20 minutes. A file
// past it is not lost: the vault serves it on demand, #de carries it, and the next sign-in continues.
func healUntil(start time.Time) time.Time {
	if v := strings.TrimSpace(os.Getenv("NOWHERE_HEAL_DEADLINE_S")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 0 {
			return start.Add(time.Duration(n) * time.Second)
		}
	}
	if v := strings.TrimSpace(os.Getenv("NOWHERE_HEAL_UNTIL")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			return time.Unix(n, 0)
		}
	}
	return start.Add(20 * time.Minute)
}

// healReserve is the free space the heal leaves on the volume. A file that would cut into it stays deferred
// and is served on demand: a full /data stops the phone, a stub costs one app a slow first open.
func healReserve() int64 {
	if v := strings.TrimSpace(os.Getenv("NOWHERE_HEAL_RESERVE")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n >= 0 {
			return n
		}
	}
	return 1 << 30
}

// healFreeBytes is the space available to the heal on dest's volume; a seam for tests.
var healFreeBytes = func(dest string) (int64, error) {
	var st unix.Statfs_t
	if err := unix.Statfs(dest, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}

// healFetchChunk returns one chunk's plaintext; a seam for tests. getChunk verifies the content hash (#207)
// and panics on failure, which healFetchOrdered recovers per chunk (so per file here, per APK set in
// restoreAppCode).
var healFetchChunk = func(base string, key []byte, version int, h string) ([]byte, error) {
	return unpackChunk(unseal(key, getChunk(base, h)), version)
}

type healResult struct {
	fetched, held, present, unfetched int
	bytes                             int64
	handledRels                       []string       // fetched, present or held: ordinary files from now on (healListFile)
	reasons                           map[string]int // why a file stayed deferred -> count
	ms                                int64          // restoreHeal's wall clock for healDeferred (signin_heal_ms, NWP-20261130-08)
}

// healDeferred writes every fetchable deferred file of m into dest. It never fails the restore: a file it
// cannot write stays deferred in the head (the carry keeps it), so it costs nothing that was there before.
func healDeferred(base string, key []byte, m chunkManifest, dest string) healResult {
	return healDeferredLate(base, key, m, dest, nil)
}

// healDeferredLate is healDeferred with a late predicate (NWP-20261202-17). nil heals every fetchable file, as
// healDeferred always did. A rel for which late is true and that passes the static checks, is not on the phone
// and is not held stays deferred with the reason "after landing": no fetch, no progress bytes, no read cap, and
// it is NOT handled, so mediad serves it and the carry keeps it until mediad lands it (media_heal_late.go).
func healDeferredLate(base string, key []byte, m chunkManifest, dest string, late func(rel string) bool) healResult {
	res := healResult{reasons: map[string]int{}}
	until := healUntil(time.Now())
	reserve := healReserve()
	isLate := func(rel string) bool { return late != nil && late(rel) }

	rels := make([]string, 0, len(m.Deferred))
	var total int64
	for rel, d := range m.Deferred {
		rels = append(rels, rel)
		if !isLate(rel) {
			total += d.Size
		}
	}
	sort.Strings(rels) // deterministic, so a deadline makes the same progress every sign-in
	writeProg(0, int(total))
	// NWP-20261128-21: the read caps are requested a batch ahead of the files that use them, from one key list for
	// the whole heal (plan, in rels order). A batch of restoreCapBatch keys is asked for only once the files before
	// it are written, so each cap is fresh when its chunk is fetched and the first frame precedes every request.
	// plan holds the keys of every file that passes the loop's static checks; planEnd[rel] is the index just past
	// that file's last key. A file later skipped (present, held, deadline, space) only leaves unused caps in a
	// batch. Best-effort: a failed batch stops the asking and leaves the per-chunk cap. No-op off cap mode.
	var plan []string
	planEnd := map[string]int{}
	for _, rel := range rels {
		d := m.Deferred[rel]
		if d.Size <= 0 || len(d.Chunks) == 0 || isMediaCachePath(rel) || isAppCodeStagePath(rel) ||
			strings.Contains(rel, "/"+odHoldDirName+"/") {
			continue
		}
		if _, ok := safeJoin(dest, rel); !ok || isLate(rel) {
			continue
		}
		for _, h := range d.Chunks {
			plan = append(plan, "blob/"+h)
		}
		planEnd[rel] = len(plan)
	}
	asked := 0
	ask := restoreCapPrefetchOn()
	var done int64
	stay := func(rel, why string) {
		res.unfetched++
		res.reasons[why]++
	}
	for _, rel := range rels {
		d := m.Deferred[rel]
		switch {
		case d.Size <= 0 || len(d.Chunks) == 0:
			// Nothing to fetch: an empty file never needs a stub either.
			stay(rel, "empty")
			continue
		case isMediaCachePath(rel) || isAppCodeStagePath(rel) || strings.Contains(rel, "/"+odHoldDirName+"/"):
			// The carry drops these classes at the next seal; they are never user data to put back.
			stay(rel, "never-restored class")
			continue
		}
		target, ok := safeJoin(dest, rel)
		if !ok {
			stay(rel, "unsafe path")
			continue
		}
		if _, err := os.Lstat(target); err == nil {
			res.present++ // already on the phone (the essential tar carried the same path)
			res.handledRels = append(res.handledRels, rel)
			continue
		}
		if heldSame(filepath.Join(dest, filepath.FromSlash(odHoldRelFor(rel))), d) {
			// Parked by an earlier sign-in's heal: the hold already holds THESE bytes, sealed essential.
			res.held++
			res.handledRels = append(res.handledRels, rel)
			continue
		}
		if isLate(rel) {
			// NWP-20261202-17: mediad lands it after landing. Not handled: served and carried until then.
			stay(rel, "after landing")
			continue
		}
		if !time.Now().Before(until) {
			stay(rel, "deadline")
			continue
		}
		if free, err := healFreeBytes(dest); err != nil || free-d.Size < reserve {
			stay(rel, "space")
			continue
		}
		for ask && asked < planEnd[rel] {
			n := min(asked+restoreCapBatch, len(plan))
			ask = restoreCapPrefetch(plan[asked:n])
			asked = n
		}
		if err := healFile(base, key, m.Version, d, dest, target, until, func(n int64) {
			done += n
			writeProg(int(done), int(total))
		}); err != nil {
			if errors.Is(err, errHealDeadline) {
				stay(rel, "deadline")
				continue
			}
			fmt.Fprintf(os.Stderr, "[heal] a file of %s stays deferred: %s\n", healPkgOf(rel), healErrText(err))
			stay(rel, "fetch")
			continue
		}
		res.fetched++
		res.bytes += d.Size
		res.handledRels = append(res.handledRels, rel)
	}
	writeProg(int(total), int(total))
	return res
}

// heldSame reports whether the on-demand hold already holds the deferred file's OWN bytes: present, the same
// size, and the recorded mtime the heal stamps on every file it writes. Only then may the heal skip the
// fetch. A hold copy that differs is an OLDER one -- a hold stranded by a pre-NWP-20260922-09 handset sealed
// essential while the app's newer canonical copy deferred, and a #58 rollback can bring that pair back. Treating
// it as held would leave the stale copy and let the carry drop the newer one, inverting hold_ondemand's own
// rule (canonical over hold, newest wins). So fetch it into the canonical path and let that merge decide.
func heldSame(holdPath string, d deferredFile) bool {
	fi, err := os.Lstat(holdPath)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() != d.Size {
		return false
	}
	mt := deferredMTimeNanos(d.MTime)
	return mt != 0 && fi.ModTime().UnixNano() == mt
}

// healErrText describes a heal failure WITHOUT its path. os errors carry the full path of the file they hit
// (/data/user/<n>/<pkg>/files/<name>), and an app's file names can carry an account name, while roam.log rides
// issue reports. So keep the operation and the errno only.
func healErrText(err error) string {
	var pe *os.PathError
	var le *os.LinkError
	switch {
	case errors.As(err, &pe):
		return pe.Op + ": " + pe.Err.Error()
	case errors.As(err, &le):
		return le.Op + ": " + le.Err.Error()
	default:
		return logSafeErrText(err) // the heal's own messages, which name chunk numbers and sizes, never a path or a presigned query
	}
}

// healPkgOf names a rel by its first segment only (the package): file names inside an app's data can carry
// an account name, so they are never logged.
func healPkgOf(rel string) string {
	if i := strings.IndexByte(rel, '/'); i > 0 {
		return rel[:i]
	}
	return "?"
}

// healFile streams one deferred file into place: a temporary file in the target's directory, the chunks in
// order, a size check, the recorded mode and mtime, the directory's MCS level, then an atomic rename. A
// failure removes the temporary file, so a short or corrupt copy can never be sealed over the stored one.
func healFile(base string, key []byte, version int, d deferredFile, dest, target string, until time.Time, progress func(int64)) (err error) {
	dir := filepath.Dir(target)
	ctx := map[string]string{}
	if err := healMkdirs(dest, dir, ctx); err != nil {
		return fmt.Errorf("mkdir parent: %w", err)
	}
	// Writing into a directory moves its mtime, and the seal writes directory mtimes into the tar headers
	// (NWP-20260829-01), so put the parent's back afterwards or every heal re-uploads the dir's region.
	var parentMt time.Time
	if fi, e := os.Stat(dir); e == nil {
		parentMt = fi.ModTime()
	}
	tmp := filepath.Join(dir, "."+filepath.Base(target)+".nowhere-heal")
	os.Remove(tmp) // a leftover from an interrupted heal
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	keep := false
	defer func() {
		if !keep {
			f.Close()
			os.Remove(tmp)
		}
	}()
	var wrote int64
	if e := healFetchOrdered(base, key, version, d.Chunks, func(b []byte) error {
		// Checked per chunk, not only between files: one multi-GB file must not carry the sign-in past the
		// daemon's ceiling. Stopping mid-file costs nothing -- the temporary file is removed and the file
		// stays deferred.
		if !time.Now().Before(until) {
			return errHealDeadline
		}
		if _, e := f.Write(b); e != nil {
			return e
		}
		wrote += int64(len(b))
		progress(int64(len(b)))
		return nil
	}); e != nil {
		return e
	}
	if wrote != d.Size {
		return fmt.Errorf("reassembled %d bytes, manifest says %d", wrote, d.Size)
	}
	if e := f.Sync(); e != nil {
		return e
	}
	if e := f.Close(); e != nil {
		return e
	}
	if perm := os.FileMode(d.Mode).Perm(); perm != 0 {
		_ = os.Chmod(tmp, perm) // best-effort, as in untarFrom: a failure costs a re-upload, never data
	}
	if mt := deferredMTimeNanos(d.MTime); mt != 0 {
		t := time.Unix(0, mt)
		_ = os.Chtimes(tmp, t, t)
	}
	inheritSELinuxLevel(tmp, dir, ctx)
	if e := os.Rename(tmp, target); e != nil {
		return e
	}
	keep = true
	if !parentMt.IsZero() {
		_ = os.Chtimes(dir, parentMt, parentMt)
	}
	return nil
}

// healFetchOrdered fetches chunks up to downloadWorkers() ahead and hands them to write IN ORDER, the
// window cdcRestore uses: a deferred file is gigabytes at worst, and one fetch at a time is latency-bound
// (the decision's cost estimate assumes the restore's parallel rate). A panic in a fetch (getChunk fails
// hard) is recovered in its own goroutine and becomes this file's error; the rest of the window is stopped.
// NWP-20261011-01: also the fetch of an on-demand app's APK set (restoreAppCode), which used to be serial.
func healFetchOrdered(base string, key []byte, version int, chunks []string, write func([]byte) error) error {
	type result struct {
		b   []byte
		err error
	}
	n := len(chunks)
	futures := make([]chan result, n)
	for i := range futures {
		futures[i] = make(chan result, 1)
	}
	sem := make(chan struct{}, downloadWorkers())
	done := make(chan struct{})
	defer close(done)
	go func() {
		for i, h := range chunks {
			select {
			case sem <- struct{}{}:
			case <-done:
				return
			}
			go func(i int, h string) {
				var r result
				func() {
					defer func() {
						if p := recover(); p != nil {
							r = result{err: recoveredErr(fmt.Sprintf("chunk %d/%d", i+1, n), p)} // keeps the chain (NWP-20261013-05)
						}
					}()
					b, e := healFetchChunk(base, key, version, h)
					if e != nil {
						e = fmt.Errorf("chunk %d/%d: %w", i+1, n, e)
					}
					r = result{b: b, err: e}
				}()
				futures[i] <- r // buffered: never blocks, even after the reader has stopped
			}(i, h)
		}
	}()
	for i := 0; i < n; i++ {
		r := <-futures[i]
		<-sem
		if r.err != nil {
			return r.err
		}
		if err := write(r.b); err != nil {
			return err
		}
	}
	return nil
}

// healMkdirs creates dir and any missing ancestors below dest, one level at a time, giving each the level of
// its parent (inheritSELinuxLevel) exactly as untarFrom does for a directory entry. A link anywhere on the
// way is refused rather than followed.
func healMkdirs(dest, dir string, ctx map[string]string) error {
	rel, err := filepath.Rel(dest, dir)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return fmt.Errorf("outside the restore root")
	}
	cur := dest
	if rel == "." {
		return nil
	}
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		next := filepath.Join(cur, part)
		fi, err := os.Lstat(next)
		switch {
		case err == nil && fi.Mode()&os.ModeSymlink != 0:
			return fmt.Errorf("a link sits on the path")
		case err == nil && !fi.IsDir():
			return fmt.Errorf("a file sits on the path")
		case err == nil:
		case errors.Is(err, os.ErrNotExist):
			if e := os.Mkdir(next, 0o700); e != nil && !errors.Is(e, os.ErrExist) {
				return e
			}
			inheritSELinuxLevel(next, cur, ctx)
		default:
			return err
		}
		cur = next
	}
	return nil
}

// clearHealList removes the scope's list, so a restore that dies before the heal leaves the pre-heal
// treatment rather than an earlier session's list.
func clearHealList(stateDir, profile, pass string) {
	if f := healListFile(profile, pass); f != "" && stateDir != "" {
		os.Remove(filepath.Join(stateDir, f))
	}
}

// writeHealList publishes the scope's handled rels. Written even when empty: an empty list says the heal ran
// and handled nothing, which is different from no list.
func writeHealList(stateDir, profile, pass string, rels []string) error {
	f := healListFile(profile, pass)
	if f == "" || stateDir == "" {
		return nil
	}
	p := filepath.Join(stateDir, f)
	tmp := p + ".tmp"
	var b strings.Builder
	for _, r := range rels {
		b.WriteString(r)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// readHealList reads the scope's handled rels: (set, true) when the heal ran this session.
func readHealList(stateDir, profile, pass string) (map[string]bool, bool) {
	f := healListFile(profile, pass)
	if f == "" || stateDir == "" {
		return nil, false
	}
	b, err := os.ReadFile(filepath.Join(stateDir, f))
	if err != nil {
		return nil, false
	}
	out := map[string]bool{}
	for _, l := range strings.Split(string(b), "\n") {
		if l != "" {
			out[l] = true
		}
	}
	return out, true
}

// restoreHeal is the restore's whole heal step, called right after cdcRestore and before roamd reowns the
// tree. A scope that still defers is left alone. For the vault and #de it heals what the head carries
// deferred and publishes the handled list -- always, even empty, since an empty list ("ran, handled nothing")
// and no list ("did not run") mean different things to mediad and the carry. Never counted as a skipped
// entry: what the heal cannot write stays deferred in the head and is carried, so the receipt is still earned.
func restoreHeal(base string, key []byte, m chunkManifest, dest, profile, pass, stateDir string) healResult {
	var hr healResult
	if scopeDefersMedia(profile) {
		return hr
	}
	if len(m.Deferred) > 0 {
		hStart := time.Now()
		hr = healDeferredLate(base, key, m, dest, healAfterLanding(profile, dest))
		hr.ms = time.Since(hStart).Milliseconds()
		fmt.Printf("restore: heal %s: fetched %d (%d B), already held %d, already present %d, still deferred %d %v [%dms] (NWP-20260923-02)\n",
			logProfile(profile), hr.fetched, hr.bytes, hr.held, hr.present, hr.unfetched, hr.reasons, hr.ms)
	}
	if err := writeHealList(stateDir, profile, pass, hr.handledRels); err != nil {
		fmt.Fprintf(os.Stderr, "[restore] heal list write failed: %v -- every deferred file keeps the pre-heal treatment\n", err)
	}
	return hr
}

// healAfterLanding is restoreHeal's late predicate (NWP-20261202-17), nil to heal everything in the sign-in.
// Non-nil only when roamd set NOWHERE_HEAL_AFTER_LANDING=1 AND the scope is the bare vault: #de has no serve
// path, so it always heals here. The predicate is true for a rel whose package is NOT in the keep file the
// restore has just put back: hold_ondemand parks a kept app's data before any install, so its entries must be
// on the phone by then. No keep file means no kept apps; a keep file that cannot be read means heal all.
func healAfterLanding(profile, dest string) func(rel string) bool {
	if os.Getenv("NOWHERE_HEAL_AFTER_LANDING") != "1" {
		return nil
	}
	if strings.Contains(profile, "#") {
		return nil
	}
	keep := map[string]string{}
	b, err := os.ReadFile(filepath.Join(dest, chooserPkg, "files", "nowhere-appkeep"))
	switch {
	case err == nil:
		keep = parseKeepModes(b)
	case !errors.Is(err, os.ErrNotExist):
		return nil // present but unreadable: fetch all, as before this build
	}
	return func(rel string) bool {
		_, kept := keep[healPkgOf(rel)]
		return !kept
	}
}

// mediadHealFilter is mediad's half: drop what this sign-in's heal handled from the deferred index it is
// about to serve for one scope. No list (the heal did not run, or the scope still defers) serves everything.
func mediadHealFilter(name, pass, stateDir string, def map[string]deferredFile) map[string]deferredFile {
	handled, ran := readHealList(stateDir, name, pass)
	if !ran {
		return def
	}
	out := healServeFilter(def, handled)
	dlog("mediad: profile %q: the sign-in heal handled %d of %d deferred file(s); serving the other %d", name, len(def)-len(out), len(def), len(out))
	return out
}

// healServeFilter drops the handled rels from the deferred index mediad serves.
func healServeFilter(def map[string]deferredFile, handled map[string]bool) map[string]deferredFile {
	if len(handled) == 0 {
		return def
	}
	out := map[string]deferredFile{}
	for rel, d := range def {
		if !handled[rel] {
			out[rel] = d
		}
	}
	return out
}
