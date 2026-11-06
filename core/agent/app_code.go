package main

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// On-demand apps (#204): materialise ONE app's APK bytes on tap.
//
// At logoff the worker seals the opted-in app CODE into the name#apps scope (app-persistence #199). An app kept
// as ON-DEMAND has its APK bytes staged like any other, but the worker lists them in NOWHERE_DEFER_LIST so the
// seal walk puts them in the manifest's DEFERRED index (incremental_seal.go) -- excluded from the login restore,
// exactly like Tier-3 bulk media. Only the essential region (manifest.tsv + each on-demand app's _meta
// placeholder snapshot) rides the login restore, so the chooser installs an ARCHIVED placeholder icon without
// downloading the APK. When the user taps it, the framework's unarchive intent reaches the chooser (the
// installer of record, #200), which asks the login daemon to materialise the bytes: restoreAppCode fetches ONLY
// that package's deferred chunks -- never the whole scope -- and writes the APK set for PackageInstaller.
//
// The footprint needs no change: scopeFootprint -> addCDCChunks already leases a scope's DEFERRED chunks
// alongside its essential ones (billing.go), so an on-demand app's bytes are leased against the gateway GC for
// free (they live in the already-leased name#apps scope). That is why on-demand apps stay INSIDE name#apps
// rather than a per-app sibling scope: a sibling would need profileFootprint to fan out over a device-side list,
// re-introducing the un-leased-scope GC-reap data-loss the fixed 4-scope footprint was hardened against (#185).

// restoreAppCode materialises one on-demand app's APK bytes from an already-sealed app-code scope into destDir.
// `scope` is the FULL sealed scope (e.g. "alice#apps"), used verbatim -- symmetric with the `restore`/`push`
// verbs, which never re-append a suffix (the worker + CLI pass the complete "${name}#apps"). The deferred files
// are staged as "<pkg>/<basename>.apk", so they land at destDir/<pkg>/<basename>.apk -- the same layout #200's
// login restore uses, so the chooser installs an on-demand app through the SAME path as a kept-installed one. It
// fetches ONLY <pkg>'s deferred entries (the selective single-app fetch), verifying each reconstructed file
// against its manifest size. Returns the number of APK files written. An error leaves any partial output for the
// caller to discard (the chooser materialises into a fresh dir).
//
// NWP-20261011-01: at LOGIN SPEED. This fetched one chunk at a time and paid a gateway round trip for each
// chunk's read cap, where the login restore batches the caps and keeps downloadWorkers() chunks in flight. It now
// uses the same machinery: one batched read-cap prefetch for every chunk of the APK set (prefetchReadCaps), then
// ONE ordered window across all of the set's files (healFetchOrdered, the window cdcRestore uses, already shared
// by the deferred-file heal), so the window does not drain at each file boundary. Every chunk still goes through
// getChunk (hash-verified and retried, #207), at most downloadWorkers() chunks are held in memory, and the files
// are written strictly in order.
//
// NWP-20261109-11 (Q116, DECIDED 2026-10-20: a sign-out cancels a download at its next safe point): the safe point
// is BETWEEN CHUNKS. Nothing is installed until the chooser commits the whole set, and roamd's materializeapp
// failure branch removes the partial set, so a cut there leaves nothing. NOWHERE_OD_CANCEL names a marker the login
// daemon writes while LOGOUT waits for the session lock (NOWHERE-968); it lives in the tmpfs $STATE. A marker
// already present fetches nothing; otherwise the writer asks before each chunk and healFetchOrdered dispatches no
// more once write errors, so at most downloadWorkers() fetches already in flight finish after the marker appears.
func restoreAppCode(base, scope, pass, pkg, destDir string) (int, error) {
	if pkg == "" || strings.ContainsAny(pkg, "/\\") {
		return 0, fmt.Errorf("invalid package %q", pkg)
	}
	key, manifestBlob, ok := resolveKey(base, scope, pass)
	if !ok {
		return 0, fmt.Errorf("no app-code scope %q (nothing sealed or wrong pass)", scope)
	}
	pt := unseal(key, manifestBlob)
	if len(pt) < len(cdcMagic) || string(pt[:len(cdcMagic)]) != string(cdcMagic) {
		return 0, fmt.Errorf("app-code scope %q is not a CDC manifest", scope)
	}
	var m chunkManifest
	if err := json.Unmarshal(pt[len(cdcMagic):], &m); err != nil {
		return 0, fmt.Errorf("#apps manifest parse: %w", err)
	}
	// Only THIS package's own APK files: a direct child of <pkg>/ (base.apk, split_*.apk). _meta rides the
	// essential region (never deferred), so it never appears here; the nested-path guard is belt-and-suspenders.
	// Sorted, so every attempt fetches (and reports progress) in the same order.
	var rels []string
	for rel := range m.Deferred {
		if isPkgApkRel(rel, pkg) {
			rels = append(rels, rel)
		}
	}
	if len(rels) == 0 {
		return 0, fmt.Errorf("no on-demand APK bytes for %q in scope %q", pkg, scope)
	}
	sort.Strings(rels)
	// DIA-20260803-03: sum this package's bytes up front so the fetch below can report MOVEMENT. The worker
	// wait is deliberately adaptive -- waitWorker gives up only after stallTicks (150s) with no NEW progress,
	// under a generous ceiling -- but that only works if the op actually writes progress. This fetch was the
	// one long path that never did, so a big app read as a 150s flat line and tripped a FALSE ERR-TIMEOUT while
	// it was downloading perfectly well (proven odtest4: gms tripped at exactly 150s and completed at 200s, into
	// a .appcode dir the chooser had already given up on -- so the whole Play stack silently failed to install).
	// #84 (DIA-20260813-15): the units are BYTES now, not chunk counts -- the same lines feed the chooser's
	// download notification through the streaming MATERIALIZE-APP-PROG verb, and a byte figure is the honest
	// instrument there (the #113 principle: real bytes, named, beat an abstract count).
	parts := make([]apkPart, len(rels))
	var chunks []string
	var totalB int64
	for i, rel := range rels {
		d := m.Deferred[rel]
		parts[i] = apkPart{rel: rel, d: d, out: filepath.Join(destDir, filepath.FromSlash(rel))}
		chunks = append(chunks, d.Chunks...)
		totalB += d.Size
	}
	keys := make([]string, len(chunks))
	for i, h := range chunks {
		keys[i] = "blob/" + h
	}
	if odCancelRequested() { // Q116: a sign-out already asked -- fetch nothing, not even the caps
		return 0, fmt.Errorf("materialise %s: %w", pkg, errMaterializeCancelled)
	}
	appCodePrefetchCaps(keys) // prefetchReadCaps: best-effort, falls back per chunk, a no-op off cap mode
	if err := os.MkdirAll(filepath.Join(destDir, pkg), 0o755); err != nil {
		return 0, err
	}
	var doneB int64
	writeProg(0, int(totalB))
	w := &apkSetWriter{parts: parts, i: -1, cancelled: odCancelRequested, onChunk: func(nw int) {
		doneB += int64(nw)
		writeProg(int(doneB), int(totalB))
	}}
	defer w.abort()
	err := healFetchOrdered(base, key, m.Version, chunks, w.write)
	if err == nil {
		err = w.finish()
	}
	if err != nil {
		return w.done, fmt.Errorf("materialise %s: %w", pkg, err)
	}
	return w.done, nil
}

// isPkgApkRel reports whether rel is one of pkg's own APK files in an #apps manifest: a direct child of <pkg>/
// (base.apk, split_*.apk). restoreAppCode fetches exactly these rels and appFetchBytes sizes exactly these, so the
// size the chooser shows before a tap (APP-FETCH-SIZE) describes the set the tap then fetches.
func isPkgApkRel(rel, pkg string) bool {
	prefix := pkg + "/"
	return strings.HasPrefix(rel, prefix) && !strings.Contains(rel[len(prefix):], "/")
}

// appFetchBytes is the size of the on-demand fetch of pkgs (NWP-20261114-16, dn-1023 #5): the bytes and the count
// of every Deferred APK file a materialise of each package would fetch (isPkgApkRel). A package listed twice
// counts once; a name validPkgName refuses counts nothing.
func appFetchBytes(m chunkManifest, pkgs []string) (bytes int64, files int) {
	seen := map[string]bool{}
	for _, pkg := range pkgs {
		if !validPkgName(pkg) || seen[pkg] {
			continue
		}
		seen[pkg] = true
		for rel, d := range m.Deferred {
			if isPkgApkRel(rel, pkg) {
				bytes += d.Size
				files++
			}
		}
	}
	return bytes, files
}

// errMaterializeCancelled is restoreAppCode's answer to a sign-out (Q116).
var errMaterializeCancelled = errors.New("cancelled for a sign-out")

// odCancelRequested reports whether the sign-out marker named by NOWHERE_OD_CANCEL exists (roamd passes
// $STATE/od-cancel). Unset or empty never cancels. Lstat: a link at the path counts as present and is never followed.
func odCancelRequested() bool {
	p := os.Getenv("NOWHERE_OD_CANCEL")
	if p == "" {
		return false
	}
	_, err := os.Lstat(p)
	return err == nil
}

// appCodePrefetchCaps is restoreAppCode's batched read-cap prefetch; a seam for tests.
var appCodePrefetchCaps = prefetchReadCaps

// handleMaterializeApp backs the chooser's on-demand unarchive (#204): when the user taps an archived
// placeholder, the chooser (installer of record) asks the login daemon to fetch that package's deferred APK
// bytes. We recover the live session creds (like handleExportMedia) and hand off to the su:s0 worker -- it
// alone can write + chown into the user-0 chooser's CE dir -- which runs `restore-app` to materialise JUST
// <pkg> from name#apps into .appcode/<pkg>, then the chooser PackageInstaller-completes the unarchive. Replies
// "OK <pkg>" | NONE (nobody signed in) | LOCAL (a throwaway has no store) | ERR-PKG | ERR-<worker>. The
// passphrase never leaves the daemon: the worker reads it from roam.req in the RAM tmpfs, like every roam op.
// stream (#84, DIA-20260813-15): the MATERIALIZE-APP-PROG variant additionally writes interim
// "PROG <phase> <done> <total>[ <scope>]" lines to the connection on every progress tick -- real BYTES from
// restoreAppCode -- before the single final reply. The chooser's download notification renders them as a
// determinate per-app bar. A NEW verb rather than a behavior change so the plain MATERIALIZE-APP contract is
// byte-identical for any older caller; agent and chooser pair-ship in one image, the split verb is belt-and-braces.
func handleMaterializeApp(conn net.Conn, dest, pkg string, stream bool) {
	if !validPkgName(pkg) {
		fmt.Fprint(conn, "ERR-PKG\n")
		return
	}
	name, pass, uid := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody logged in
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "LOCAL\n") // a throwaway/offline session has no store to fetch from
		return
	}
	// ⚠ NOT because name#apps is SE-bound -- it is not, and the comment here said it was until
	// NWP-20260915-10. A scope head is a BARE manifest sealed under deriveKey(name#scope, pass), and
	// after a rotation or recovery re-points it, buildScopeVault gives it a single `pass` slot
	// (scope_repoint.go). Neither shape has ever carried an `se` slot: hardening protects the bare
	// vault head, not the scopes (docs/profile-export-restore.md section 4). The secret is passed through
	// because the worker exports it for whatever the op touches, including the bare vault.
	seSecret := readRoamSessionSE(dest)
	// #204 (DIA-20260726-08): open the "materialising" window so syncLoop suppresses periodic seals until the
	// follow-up RESTORE-ODDATA lands its perm grant -- else a seal that grabs workerMu during installApks delays the
	// grant past the framework's unarchive auto-launch and the app re-prompts. Opened BEFORE triggerRoamWorkerKind so
	// it also covers this op's own wait on workerMu. NWP-20261011-01: the window is now a lease per package, and
	// this one no longer self-expires 90s after this point. It is renewed for as long as the worker op is in
	// flight, held for the install once OK reaches the chooser, and ended at once on a failure or an unread reply
	// -- the lifecycle and its bound are in od_window.go.
	epoch := beginOdMaterialise(pkg, time.Now())
	outcome := odAbandoned // until the reply is written: a panic below must still settle the lease
	defer func() { settleOdMaterialise(pkg, epoch, outcome, time.Now()) }()
	renewAutoSweep(time.Now()) // NWP-20261005-01: a live auto sweep's lease runs from its latest app
	// pkg rides the srcUnit slot (roam.req line 7); the worker reads it and runs restore-app for that one package.
	// DIA-20260803-03: ROLL the connection deadline on every progress tick instead of leaving the flat 180s set by
	// the caller. Now that the fetch reports movement (restoreAppCode), the worker wait is honestly adaptive -- but a
	// fixed 180s conn deadline would still guillotine a healthy long download before waitWorker's own 20-minute
	// ceiling, which is the same class of bug (a large app is SLOW, not hung: gms measured 200s on odtest4). The
	// stall watchdog remains the thing that ends a genuinely wedged fetch, so this cannot hang forever.
	out := func() string {
		stop, done := make(chan struct{}), make(chan struct{})
		goSafe("od-renew", func() {
			defer close(done)
			renewOdWhile(pkg, epoch, stop)
		})
		// The renewal ends with the op, whichever way it returns -- and has EXITED before the lease is settled
		// below, so a tick already in flight cannot re-open a lease that settling ends.
		defer func() {
			close(stop)
			<-done
		}()
		return triggerRoamWorkerKind(dest, "materializeapp", name, pass, uid, seSecret, "", pkg, "", func(line string) {
			conn.SetDeadline(time.Now().Add(180 * time.Second))
			if stream {
				// #84: interim progress on the SAME socket the reply rides -- direct causality (the worker running
				// is OUR op), no second connection, no staleness. A failed write is ignored: the final reply's own
				// write reports the dead peer, and the fetch itself must not die because the notification did.
				fmt.Fprintf(conn, "PROG %s\n", line)
			}
		})
	}()
	// B4/DIA-20260727-01 re-armed the window here, for 90s from completion, because the 90s armed above could be
	// eaten by the wait and the fetch. NWP-20261011-01: the renewal above kept it live through both, so what is left
	// to cover is the install, and only if the chooser is still there to do it. The reply is written FIRST and its
	// write decides: a chooser that timed out or died closed the socket, and nobody is going to install. The window
	// is still live while we write (the last renewal was at most odRenewEvery ago), so the chooser never starts its
	// install with the window closed.
	reply := strings.TrimSpace(out)
	_, werr := fmt.Fprintf(conn, "%s\n", reply) // "OK <pkg>" | ERR-...
	switch {
	case werr != nil:
		outcome = odAbandoned
	case strings.HasPrefix(reply, "OK"):
		outcome = odInstalling
	default:
		outcome = odFailed
	}
}

// handleRestoreOdData (#204): after a tap materialises an on-demand app (installApks installs the real APK), move
// that app's held CE+DE data back from .nowhere-odhold into the now-app-owned canonical dir + re-grant its runtime
// perms. Both were skipped at login because the app was an APK-less archived placeholder: its restored data dir
// couldn't be reowned (no packages.list appId yet) so hold_ondemand parked it, and pm grant no-ops without a
// manifest. This is a LOCAL op -- it touches NO store (name/pass are read only so the worker-trigger's non-empty-arg
// gate passes; the `odrestore` worker op moves local dirs + grants perms). "RESTORE-ODDATA\n<pkg>\n".
// NWP-20261125-08 (h53 #1): the payload may also be a list of 2 to odRestoreMaxList names, one space apart. The
// list answers NONE / OK LOCAL / ERR-PKG as one line, or one "<pkg> <reply>" line per package in order, then
// "END <n>" (n = packages run). A sign-out (od-cancel) stops it between packages: each package not run answers
// "<pkg> STOPPED". One name keeps the one-line reply above, byte for byte.
func handleRestoreOdData(conn net.Conn, dest, payload string) {
	pkgs := strings.Split(payload, " ")
	if len(pkgs) == 1 {
		pkg := pkgs[0]
		if !validPkgName(pkg) {
			fmt.Fprint(conn, "ERR-PKG\n")
			return
		}
		name, pass, uid := readRoamSession(dest)
		if name == "" {
			fmt.Fprint(conn, "NONE\n") // nobody logged in
			return
		}
		if isLocalSession(dest) {
			fmt.Fprint(conn, "OK LOCAL\n") // a throwaway/offline session has no roamed on-demand hold to restore
			return
		}
		restoreOdOne(conn, dest, name, pass, uid, readRoamSessionSE(dest), pkg, "", "")
		return
	}
	// NWP-20261125-08 (h53 #1): the list form. Every name is checked BEFORE anything runs: one invalid name, a
	// duplicate or more than odRestoreMaxList names refuses the whole request, so a list never half-runs.
	if len(pkgs) > odRestoreMaxList {
		fmt.Fprint(conn, "ERR-PKG\n")
		return
	}
	seen := make(map[string]bool, len(pkgs))
	for _, p := range pkgs {
		if !validPkgName(p) || seen[p] {
			fmt.Fprint(conn, "ERR-PKG\n")
			return
		}
		seen[p] = true
	}
	name, pass, uid := readRoamSession(dest)
	if name == "" {
		fmt.Fprint(conn, "NONE\n") // nobody logged in
		return
	}
	if isLocalSession(dest) {
		fmt.Fprint(conn, "OK LOCAL\n") // a throwaway/offline session has no roamed on-demand hold to restore
		return
	}
	seSecret := readRoamSessionSE(dest)
	// The batch token rides line 6 (`kind`) of each op: roamd keys one shared `pm list packages -3` read on its
	// b-part, and the op with i = n removes it. The b-part is random per request, so no other list reads it.
	var rb [4]byte
	rand.Read(rb[:])
	base := fmt.Sprintf("b%x", rb[:])
	ran := 0
	for i, pkg := range pkgs {
		// A sign-out began (logout_wait.go): stop BETWEEN packages, never inside one.
		if _, err := os.Stat(filepath.Join(dest, odCancelFile)); err == nil {
			for _, p := range pkgs[i:] {
				fmt.Fprintf(conn, "%s STOPPED\n", p)
			}
			break
		}
		restoreOdOne(conn, dest, name, pass, uid, seSecret, pkg, fmt.Sprintf("%s.%d.%d", base, i+1, len(pkgs)), pkg+" ")
		ran++
	}
	fmt.Fprintf(conn, "END %d\n", ran)
}

// odRestoreWorker runs one RESTORE-ODDATA package's `odrestore` worker op. Tests replace it.
var odRestoreWorker = triggerRoamWorkerKind

// odRestoreConnWindow is the conn deadline one package's op gets. The dispatch sets it before the payload read and
// restoreOdOne renews it before each op, because one deadline cannot cover a list of up to odRestoreMaxList ops.
const odRestoreConnWindow = 120 * time.Second

// odRestoreMaxList is the most packages one RESTORE-ODDATA request may carry (h53 #1).
const odRestoreMaxList = 16

// restoreOdOne fully restores one package (data, grants, declines, a11y, autofill, Keystore register: the worker's
// `odrestore` op) and writes its reply line, lead first ("" for the one-package form, "<pkg> " in a list).
// h53 #1's rule: in a list, package i's grants land before package i+1's data moves, because one op runs at a time
// and this reply is written before the caller starts the next package's op.
func restoreOdOne(conn net.Conn, dest, name, pass, uid, seSecret, pkg, kind, lead string) {
	conn.SetDeadline(time.Now().Add(odRestoreConnWindow))
	// NWP-20260903-11: this verb now has a second caller -- the install-heal (AppInstallReceiver), which
	// fires it WITHOUT a preceding MATERIALIZE-APP -- so the #204 seal-suppression window may be unarmed
	// here. Arm it if so (never shorten a live tap-path window); the clear at the end of this op closes it.
	// Without this a periodic seal queued on workerMu ahead of us delays the reunite by a whole seal -- the
	// exact #204 shape, on the new path. NWP-20261011-01: armed AFTER the caller's guards, which used to return
	// with it armed and nothing left to close it.
	armOdLease(pkg, time.Now(), odFetchLease)
	// pkg rides the srcUnit slot; the worker's `odrestore` op restores + reowns the hold and re-grants perms for it.
	out := odRestoreWorker(dest, "odrestore", name, pass, uid, seSecret, kind, pkg, "", nil)
	// #204 (DIA-20260726-08): the grant has landed -- close the materialising window so periodic seals resume
	// immediately (don't wait out the install lease). Paired with the open in handleMaterializeApp.
	// NWP-20261011-01: only THIS package's lease ends. Another tap's fetch or install lease keeps the window open.
	endOdLease(pkg, time.Now())
	reply := strings.TrimSpace(out)
	if lead != "" {
		fmt.Fprint(conn, lead)
	}
	fmt.Fprintf(conn, "%s\n", reply) // "OK <pkg>" | "OK NOSRC" | ERR-...
	// NWP-20261114-05: a restore that lands after GRANT-PERMS (the Auto sweep's install, an on-demand tap, the
	// install-heal) sends its own package the boot broadcasts, at its own confirmed restore. Before GRANT-PERMS (the
	// login's own restores) the gate is unarmed and this does nothing: grantTail's pass covers those packages, and a
	// worker op queued then would hold the sign-in's RW slot. `OK NOSRC`, `OK LOCAL` and ERR-* send nothing: no data
	// landed. The chooser's Wake-for-notifications unstop may already have run by the time roamd reads the package,
	// which is why the op does not skip a non-stopped package. The log line carries the uid only, never the package.
	if bootWakeAfterRestore(reply, pkg, uid) {
		goSafe("bootwake-pkg", func() { bootWakePackage(dest, uid, pkg) })
	}
}

// apkPart is one file of an on-demand app's APK set: its manifest record and where it is written.
type apkPart struct {
	rel string
	d   deferredFile
	out string
}

// apkSetWriter receives a whole APK set's chunks IN ORDER (healFetchOrdered's write callback) and splits them
// back into the set's files: each file takes exactly len(d.Chunks) chunks and is then closed and checked against
// its manifest size -- the same contract exportFetchMedia uses off-device. getChunk hashes + retries every fetch
// (#207), so a torn/bit-rot blob fails loudly rather than installing a corrupt APK.
type apkSetWriter struct {
	parts   []apkPart
	i       int // index of the open (or last opened) part; -1 before the first
	f       *os.File
	left    int   // chunks the open part is still owed
	wrote   int64 // bytes written to the open part
	done    int   // parts written whole and size-checked
	onChunk func(int)
	// cancelled is asked before each chunk (Q116); true stops the set. Nil never cancels.
	cancelled func() bool
}

func (w *apkSetWriter) open() error {
	p := w.parts[w.i]
	f, err := os.OpenFile(p.out, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	w.f, w.left, w.wrote = f, len(p.d.Chunks), 0
	return nil
}

func (w *apkSetWriter) closeCur() error {
	p := w.parts[w.i]
	err := w.f.Close()
	w.f = nil
	if err != nil {
		return err
	}
	if w.wrote != p.d.Size {
		return fmt.Errorf("%q size mismatch: fetched %d, manifest %d", p.rel, w.wrote, p.d.Size)
	}
	w.done++
	return nil
}

// write appends the set's next chunk to the file it belongs to, first closing any file that is complete. It stops
// at a sign-out (Q116) before it opens a part or writes a byte; healFetchOrdered then dispatches nothing more.
func (w *apkSetWriter) write(b []byte) error {
	if w.cancelled != nil && w.cancelled() {
		return errMaterializeCancelled
	}
	for w.f == nil || w.left == 0 {
		if w.f != nil {
			if err := w.closeCur(); err != nil {
				return err
			}
		}
		if w.i+1 >= len(w.parts) {
			return fmt.Errorf("more chunks than the APK set's files hold")
		}
		w.i++
		if err := w.open(); err != nil {
			return err
		}
	}
	nw, err := w.f.Write(b)
	if err != nil {
		return err
	}
	w.wrote += int64(nw)
	w.left--
	if w.onChunk != nil {
		w.onChunk(nw) // #84: the chunk's byte length, so the caller reports real byte movement
	}
	return nil
}

// finish closes the last file and writes whatever files remain. Once every chunk has been written only a file
// with no chunks can remain; closeCur still checks its size.
func (w *apkSetWriter) finish() error {
	for {
		if w.f != nil {
			if w.left != 0 {
				return fmt.Errorf("%q short: %d chunk(s) never arrived", w.parts[w.i].rel, w.left)
			}
			if err := w.closeCur(); err != nil {
				return err
			}
		}
		if w.i+1 >= len(w.parts) {
			return nil
		}
		w.i++
		if err := w.open(); err != nil {
			return err
		}
	}
}

// abort closes a file a failed fetch left open. The caller discards the partial output.
func (w *apkSetWriter) abort() {
	if w.f != nil {
		w.f.Close()
		w.f = nil
	}
}
