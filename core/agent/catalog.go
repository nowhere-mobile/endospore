package main

// App-store catalog (Phase 2, DIA-20260730). The catalog is a signed JSON manifest of the apps Nowhere
// OFFERS -- the SOURCE the storefront (#2, a later phase) renders and FETCH-APP (#3 fetch) installs from.
// Decision (2026-07-30): a custom signed JSON manifest served over the existing "nowhere_login" AF_UNIX socket
// (GET-CATALOG), NOT a hosted F-Droid-format repo -- keeps the Chooser unprivileged + offline-safe.
//
// Trust model: the baked /system copy is authoritative (it rides verified boot). A mutable /data override is
// honored ONLY if its detached ed25519 signature verifies against the baked catalogPubKey -- so a later dynamic
// catalog push (Phase 4) can update the offer set without an OTA, but an untrusted drop into /data is refused.
// The signature is over the EXACT manifest bytes (not a re-serialization), so formatting is irrelevant.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const catalogSchema = 1

// Paths are var so tests can point them at a temp dir (same trick as storeConfPath).
var (
	catalogSystemPath = "/system/etc/nowhere/catalog.json" // baked, trusted via verified boot
	catalogDataPath   = "/data/nowhere/catalog.json"       // mutable override; honored only if signed (Phase 4)
)

// catalogPubKey is the base64 raw (32-byte) ed25519 public key that signs the catalog manifest. It is baked, so
// every catalog change is re-signed and its .sig committed (sign-catalog.sh; the procedure is in
// docs/app-store-design.md). Were it ever empty, the baked /system manifest would be served on the trust of verified
// boot and any /data override would be refused (unverifiable).
var catalogPubKey = "txRDdf9TYhUQ3wUkjbvnXYeIyTggbkV8OAZMDbo3v2k=" // ed25519 catalog-signing public key (base64, 32 raw bytes); private key held by Chester

// catalogAPK is one installable artifact of an offer (base or a split). FETCH-APP (Phase 2b) downloads url,
// checks sha256, and hands it to installApkSet / installArchivedPlaceholder.
type catalogAPK struct {
	Name   string `json:"name"`           // basename: base.apk / split_config.*.apk
	URL    string `json:"url"`            // download URL (curated F-Droid mirror for the Phase-2 subset)
	Sha256 string `json:"sha256"`         // hex sha256, verified after download (fail-closed)
	Size   int64  `json:"size,omitempty"` // bytes, for the UI + a pre-flight size check
}

// catalogEntry is one app Nowhere offers.
type catalogEntry struct {
	Pkg         string `json:"pkg"`
	VersionCode int64  `json:"versionCode"`
	VersionName string `json:"versionName,omitempty"`
	Label       string `json:"label"`
	Category    string `json:"category,omitempty"`
	Description string `json:"description,omitempty"`
	SizeBytes   int64  `json:"sizeBytes,omitempty"`   // total install size, for the UI
	Source      string `json:"source"`                // "fdroid" | "nowhere" | ... (provenance badge + gate)
	SigningCert string `json:"signingCert,omitempty"` // hex SHA-256 of the expected APK signing cert (matches Android's signing-cert digest; install-time gate)
	IconRef     string `json:"iconRef,omitempty"`     // icon URL / embedded data: ref / (in search results) the pkg -> local icon pack
	// Carried by the full trimmed F-Droid index (index.go) for search: compatibility filtering + anti-feature
	// badges. Absent (omitempty) from the curated catalog.
	MinSdk       int          `json:"minSdk,omitempty"`
	Nativecode   []string     `json:"nativecode,omitempty"`
	AntiFeatures []string     `json:"antiFeatures,omitempty"`
	APKs         []catalogAPK `json:"apks"`
}

// catalog is the top-level manifest.
type catalog struct {
	Schema    int            `json:"schema"`
	Generated int64          `json:"generated,omitempty"` // unix seconds (stamped by the signer)
	Ring      string         `json:"ring,omitempty"`      // "stable" | "beta"
	Entries   []catalogEntry `json:"entries"`
}

// verifyCatalogSig reports whether sig is a valid ed25519 signature over manifest by catalogPubKey (sig may be the
// raw 64 bytes OR their base64). False if no pubkey is baked. Shares verifyEd25519 with the index (index.go).
func verifyCatalogSig(manifest, sig []byte) bool { return verifyEd25519(catalogPubKey, manifest, sig) }

// loadCatalogBytes returns the trusted raw manifest bytes, or nil if none is present/valid. A /data override wins
// ONLY when signed + verified against catalogPubKey AND no older than the baked manifest (generated >= baked, the
// index's rollback guard: an OTA that bakes a newer catalog must not be shadowed by an older signed copy in /data);
// otherwise the baked /system manifest is used. When a pubkey IS baked, the /system copy must ALSO carry a matching
// .sig (defense in depth); when none is baked, the read-only /system copy is trusted directly (verified boot). Bytes
// are returned verbatim so the caller can serve exactly what was signed.
func loadCatalogBytes() []byte {
	baked, bakedErr := os.ReadFile(catalogSystemPath)
	if catalogPubKey != "" {
		if b, err := os.ReadFile(catalogDataPath); err == nil {
			if sig, e := os.ReadFile(catalogDataPath + ".sig"); e == nil && verifyCatalogSig(b, sig) {
				if indexGeneratedOf(b) >= indexGeneratedOf(baked) {
					return b
				}
				fmt.Fprintln(os.Stderr, "[catalog] /data override is older than the baked catalog -- ignoring (rollback guard)")
			} else {
				fmt.Fprintln(os.Stderr, "[catalog] /data override present but signature invalid -- ignoring")
			}
		}
	}
	if bakedErr != nil {
		return nil
	}
	if catalogPubKey == "" {
		return baked // dev / pre-release: the read-only baked copy is trusted via verified boot
	}
	if sig, e := os.ReadFile(catalogSystemPath + ".sig"); e == nil && verifyCatalogSig(baked, sig) {
		return baked
	}
	fmt.Fprintln(os.Stderr, "[catalog] baked /system manifest signature missing/invalid -- refusing")
	return nil
}

// handleGetCatalog serves the trusted catalog manifest to the Chooser. Length-prefixed so a manifest of any
// formatting/size round-trips intact (the storefront reads exactly nbytes, then parses):
//
//	"OK <nbytes>\n" <nbytes of JSON>   -- a trusted manifest
//	"NONE\n"                            -- no catalog on this device
//	"ERR-SIG\n"                         -- a catalog is present but not trusted (bad/absent signature)
func handleGetCatalog(conn net.Conn) {
	b := loadCatalogBytes()
	if b == nil {
		if _, err := os.Stat(catalogSystemPath); err == nil {
			fmt.Fprint(conn, "ERR-SIG\n") // present but untrusted
		} else {
			fmt.Fprint(conn, "NONE\n")
		}
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(b))
	conn.Write(b)
}

// --- FETCH-APP (Phase 2b): install an app the user does NOT already have, from the catalog. The download + the
// sha256 gate happen HERE (Go/daemon: network + crypto); the su:s0 worker's `stageapp` op does the privileged
// half -- move the verified APKs into the ROAMED user's chooser .appcode/<pkg> + chown -- exactly as
// `materializeapp` does for name#apps, so the storefront/chooser PackageInstaller-installs it. ---

// fetchAppHTTP + fetchAppStageBase are var so tests can swap the client + a temp dir.
var fetchAppHTTP = storeHTTP                     // the store client: FETCH-ICON, REFRESH-* keep its 60s; the APK download takes only its Transport
var fetchAppStageBase = "/data/nowhere/fetchapp" // ON DISK (APKs are large), daemon-owned; the worker moves + rms it

// The APK download's bounds (NWP-20261107-03). The store client's 60 s Timeout covers the whole body, so an 80 MB
// app on an 8 Mbit/s link died at 60 s on every retry. Instead: a stall bound (no body byte for fetchAppStall ends
// a download), a budget for all of one FETCH-APP's downloads, and a size bound. Budget + allowance (480 s) stays
// under StoreService.FETCH_APP_CAP_MS (600 s) with room for the plan gate before it (gwProbe-bounded), so the reply
// reaches a chooser that is still waiting. A catalog entry's size is the producer's exact file size
// (curate-catalog.py, trim-fdroid-index.py, publish-nowhere-app.py), so a body past it could never match the
// sha256 anyway: the bound only stops the download early. Vars so tests can shrink them.
var (
	fetchAppBudget                = 7 * time.Minute  // all of one FETCH-APP's downloads
	fetchAppStall                 = 30 * time.Second // no body byte for this long ends a download
	fetchAppMaxBytes        int64 = 1 << 30          // the bound when an entry states no size
	fetchAppStageAllowance        = 60 * time.Second // after the downloads: stageapp + the reply
	fetchAppOdDataAllowance       = 9 * time.Minute  // a parked package's data fetch inside stageapp (NWP-20261130-03)
)

// errFetchStall is the cancel cause of a download that went fetchAppStall without a byte.
var errFetchStall = errors.New("download stalled")

// errSignOutCancel is the cancel cause of a FETCH-APP whose downloads a sign-out stopped (Q116, NWP-20261109-14).
var errSignOutCancel = errors.New("cancelled for a sign-out")

// FETCH-APP's log lines (NWP-20261113-26). login.log survives the boot-wipe (#39), so they carry counts and times only:
// no package, label, URL or APK name. fetchAppProgressEvery is the shortest gap between two progress lines.
// fetchAppProgressLineEvery is the shortest gap between two PROGRESS reply lines after the start one (the chooser's
// bar, NWP-20261122-14).
// fetchAppOnBytes is the running FETCH-APP's byte counter: fetchAndVerify's copy loop calls it with each read's count.
// FETCH-APP runs under sessionMu, so at most one is set; nil (no FETCH-APP running) counts nothing. Vars so tests
// shrink the interval.
var (
	fetchAppProgressEvery     = 30 * time.Second
	fetchAppProgressLineEvery = time.Second
	fetchAppOnBytes           func(n int)
)

// stallResetReader restarts the stall timer after every Read that returned bytes, and hands the count to on (if set).
type stallResetReader struct {
	r  io.Reader
	t  *time.Timer
	d  time.Duration
	on func(int)
}

func (s stallResetReader) Read(p []byte) (int, error) {
	n, err := s.r.Read(p)
	if n > 0 {
		s.t.Reset(s.d)
		if s.on != nil {
			s.on(n)
		}
	}
	return n, err
}

// findCatalogEntry returns the catalog entry for pkg (matching versionCode too when vc>0), or nil.
func findCatalogEntry(pkg string, vc int64) *catalogEntry {
	b := loadCatalogBytes()
	if b == nil {
		return nil
	}
	var c catalog
	if json.Unmarshal(b, &c) != nil {
		return nil
	}
	for i := range c.Entries {
		if c.Entries[i].Pkg == pkg && (vc == 0 || c.Entries[i].VersionCode == vc) {
			return &c.Entries[i]
		}
	}
	return nil
}

// fetchAndVerify downloads url to out, requiring its sha256 to equal wantHex (64 lowercase hex chars). FAIL-CLOSED:
// an empty/short wantHex (an uncurated catalog entry) or a mismatch is an error and no file is left behind -- so a
// not-yet-curated or tampered app can never be installed.
func fetchAndVerify(ctx context.Context, url, wantHex, out string, maxBytes int64) error {
	if len(wantHex) != 64 {
		return fmt.Errorf("unverifiable apk (sha256=%q) -- refusing", wantHex)
	}
	// A COPY of the shared client with no total timeout (it would cover the whole body): a test that swaps
	// fetchAppHTTP keeps its Transport. The stall timer and ctx bound the download instead.
	c := *fetchAppHTTP
	c.Timeout = 0
	rctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	t := time.NewTimer(fetchAppStall) // started before the request, so it also bounds the wait for headers
	done := make(chan struct{})
	defer func() { t.Stop(); close(done) }()
	goSafe("fetchapp-stall", func() {
		select {
		case <-t.C:
			cancel(errFetchStall)
		case <-done:
		}
	})
	// why names a failed read: a sign-out, the spent budget, a stall, or the raw error.
	why := func(err error) error {
		if errors.Is(context.Cause(ctx), errSignOutCancel) {
			return fmt.Errorf("%w: %w", errSignOutCancel, err)
		}
		if ctx.Err() != nil {
			return fmt.Errorf("download budget of %s spent: %w", fetchAppBudget, err)
		}
		if errors.Is(context.Cause(rctx), errFetchStall) {
			return fmt.Errorf("no data for %s: %w", fetchAppStall, err)
		}
		return err
	}
	req, err := http.NewRequestWithContext(rctx, "GET", url, nil)
	if err != nil {
		return err
	}
	resp, err := c.Do(req)
	if err != nil {
		return why(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s -> HTTP %d", url, resp.StatusCode)
	}
	tmp := out + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	limit := maxBytes
	if limit <= 0 {
		limit = fetchAppMaxBytes
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(stallResetReader{resp.Body, t, fetchAppStall, fetchAppOnBytes}, limit+1))
	if err != nil {
		f.Close()
		os.Remove(tmp)
		return why(err)
	}
	if n > limit {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("size mismatch: more than %d bytes", limit)
	}
	if err = f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); !strings.EqualFold(got, wantHex) {
		os.Remove(tmp)
		return fmt.Errorf("sha256 mismatch (want %s got %s)", wantHex, got)
	}
	return os.Rename(tmp, out)
}

// overPlanReply is FETCH-APP's storage-gate refusal, without the newline: the exact text nApps shows and the
// daemon log records. Byte-stable -- see the ⚠ at its call site before changing it.
func overPlanReply(short, used, covered, add int64) string {
	return fmt.Sprintf("ERR-OVERPLAN short=%d used=%d covered=%d add=%d", short, used, covered, add)
}

// fetchAppEndLine is FETCH-APP's done line, without the newline: the bytes read across all of the entry's APKs, the
// whole seconds since the start line, and the reply's first token only (the OK reply's second token is the package).
// Pure.
func fetchAppEndLine(bytes int64, d time.Duration, reply string) string {
	tok := "(empty)"
	if f := strings.Fields(reply); len(f) > 0 {
		tok = f[0]
	}
	return fmt.Sprintf("[fetchapp] done: %d bytes in %ds -> %s", bytes, int64(d/time.Second), tok)
}

// fetchAppProgressLine is one PROGRESS reply line of a FETCH-APP that opted in (NWP-20261122-14): the bytes read so far
// across all of the entry's APKs and the entry's total. Two counts only: no package, label or URL. Pure.
func fetchAppProgressLine(got, total int64) string {
	return fmt.Sprintf("PROGRESS %d %d\n", got, total)
}

// fetchAppAddBytes is the size FETCH-APP's storage gate adds to the profile's footprint. `used` already counts
// whatever #apps holds for an installed package, so an UPDATE is gated on estAdd minus that stored size (floored
// at 0), not on a whole second copy. stored/measured are storedAppsCached's answer: measured=false (or a nil map,
// or no positive entry for pkg) is UNKNOWN and never read as "nothing stored" nor as a size -- the full estAdd is
// charged, exactly as a fresh install is. The refusal's add= field carries this value (NWP-20261017-22); before
// it carried the raw APK size. No chooser parses the field: showOverPlanDialog routes on OVERPLAN only.
func fetchAppAddBytes(estAdd int64, stored map[string]int64, measured bool, pkg string) int64 {
	if !measured {
		return estAdd
	}
	have := stored[pkg]
	if have <= 0 {
		return estAdd
	}
	if d := estAdd - have; d > 0 {
		return d
	}
	return 0
}

// handleFetchApp fetches a catalog app's APK(s) into a disk stage, sha256-verifies each, then hands them to the
// `stageapp` worker to land in the roamed user's .appcode/<pkg> (chowned so the chooser can install). Arg:
// "<pkg> [versionCode [progress]]". With the `progress` opt-in (NWP-20261122-14) the reply starts, once the downloads
// begin, with "PROGRESS 0 <total>" and then at most one "PROGRESS <got> <total>" per fetchAppProgressLineEvery, before
// the one verdict line; without it the reply is the verdict line only. Reply: "OK <pkg> <signer>" | NONE (no session) | ERR-NOENTRY | ERR-NOSIGNER |
// ERR-UNVERIFIED | ERR-FETCH | ERR-STAGE | ERR-CANCELLED (a sign-out stopped the download, Q116). Cleartext lives only in the stage (rm'd by the worker / on error here) + the roamed CE dir (the
// chooser deletes it after install) -- amnesia preserved, exactly like MATERIALIZE-APP. Once the downloads begin it
// logs a start line, a progress line at most every fetchAppProgressEvery and one done line on every exit, with counts
// and times only (login.log survives the boot-wipe, #39; NWP-20261113-26). From the entry check to its reply it holds
// pkg's materialise lease, so a periodic seal cannot take the RW slot ahead of its stageapp (#53, NWP-20261117-20).
func handleFetchApp(conn net.Conn, dest, arg string) {
	fields := strings.Fields(arg)
	if len(fields) == 0 || !validPkgName(fields[0]) {
		fmt.Fprint(conn, "ERR-PKG\n")
		return
	}
	pkg := fields[0]
	var vc int64
	if len(fields) > 1 {
		vc, _ = strconv.ParseInt(fields[1], 10, 64)
	}
	progressOn := len(fields) > 2 && fields[2] == "progress"
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n") // nobody logged in -> no roamed user to install into
		return
	}
	e := findAppEntry(pkg, vc) // curated catalog first, then the full trimmed F-Droid index (index.go)
	if e == nil || len(e.APKs) == 0 {
		fmt.Fprint(conn, "ERR-NOENTRY\n")
		return
	}
	// Decided 2026-10-20 (docs/product-decisions.md, item 4): an entry that does not carry a 64-hex signing cert is
	// refused here, before the plan gate, the stage dir or any download, so its install can never go unpinned. The
	// producers refuse such an entry (NWP-20261029-13), so only a hand-edited catalog or index reaches this. Logged
	// without the package, as the over-plan refusal is. ⚠ The chooser routes on ERR-NOSIGNER byte for byte.
	if _, ok := entrySignerPin(e); !ok {
		fmt.Fprint(os.Stderr, "[fetchapp] refused: the entry names no signing cert, so its install could not be pinned (NWP-20261030-04)\n")
		fmt.Fprint(conn, "ERR-NOSIGNER\n")
		return
	}
	// NWP-20261117-20 (#53, decided 2026-10-22): a store Get holds periodic seals back from the tap until its
	// stageapp replies, with the per-package lease MATERIALIZE-APP takes (od_window.go): opened here, renewed while
	// the handler runs, held for the install after an OK the chooser read, ended on any other exit. The chooser's
	// install-heal RESTORE-ODDATA ends the install lease; a failed install leaves it to lapse at odInstallLease. No
	// renewAutoSweep: a store Get is not one of the Auto sweep's apps.
	epoch := beginOdMaterialise(pkg, time.Now())
	outcome := odAbandoned // until a reply is written: a panic below must still settle the lease
	stopRenew, renewDone := make(chan struct{}), make(chan struct{})
	goSafe("fetchapp-od-renew", func() {
		defer close(renewDone)
		renewOdWhile(pkg, epoch, stopRenew)
	})
	// The renewal has EXITED before the lease is settled, so a tick in flight cannot re-open an ended lease.
	settle := func() {
		close(stopRenew)
		<-renewDone
		settleOdMaterialise(pkg, epoch, outcome, time.Now())
	}
	defer settle()
	// answer writes a reply and decides the lease from it: held for the install only when an OK reached the chooser.
	answer := func(r string) {
		_, werr := fmt.Fprintf(conn, "%s\n", r)
		switch {
		case werr != nil:
			outcome = odAbandoned
		case strings.HasPrefix(r, "OK"):
			outcome = odInstalling
		default:
			outcome = odFailed
		}
	}
	// Phase 5 storage gate: refuse an install that would push the profile past its plan (free + entitled) with no
	// tokens to cover the excess -- it would only 402 at the next lease (and risk a failed seal). Gated BEFORE the
	// download so an over-plan app never wastes bytes. Skipped when no gateway is configured (an unmanaged device
	// has no plan); installHeadroom fail-opens on any gateway/footprint hiccup (the gateway's own 402 backstops).
	addBytes := e.SizeBytes
	if addBytes == 0 {
		for _, a := range e.APKs {
			addBytes += a.Size
		}
	}
	if gwURL := os.Getenv("GATEWAY_URL"); gwURL != "" {
		gw := newGatewayClient(gwURL, gwProbe) // fail-open check: see gwProbe
		// Project a CONSERVATIVE fraction of the raw APK size: the sealed, CDC-chunked, cross-scope-deduped
		// footprint the gateway actually bills is <= the download, so charging the full raw size would false-block
		// near the plan edge. Err toward allowing -- the gateway's own 402 at the next lease is the true backstop.
		estAdd := addBytes - addBytes/4 // ~25% seal/dedup allowance
		// An update is charged only for its growth over what #apps already holds (see fetchAppAddBytes). The
		// cached read answers unknown on the first call after sign-in (it kicks an async fetch), so that first
		// attempt is gated on the full size; a retry a moment later gets the delta.
		se := seFromSession(dest)
		stored, measured := storedAppsCached(name, pass, se)
		gateAdd := fetchAppAddBytes(estAdd, stored, measured, pkg)
		if fits, short, used, covered := installHeadroom(gw, "s3", name, pass, capWalletPath(), gateAdd, se); !fits {
			// `short` is BYTES over the plan, not a token count -- the line is now unit-homogeneous, and the
			// remedy it implies is delete-or-upsize rather than buy-more-tokens. Renamed from `need=` so a
			// half-updated parser cannot silently read bytes as tokens.
			//
			// ⚠ The literal substring OVERPLAN must survive: chooser v44 routes on it
			// (ProfileActivity.java) and its fall-through is ORDER-SENSITIVE, ending in "its signature
			// didn't match the catalog". A reply containing FETCH, UNVERIFIED, NOENTRY or NONE would show a
			// false security accusation on a build that is not being reflashed. v44 parses no field here,
			// so the rename is invisible to it.
			//
			// Logged as well as replied: an issue report carries the daemon log, not the screenshot, and nApps
			// logs nothing. The four numbers only -- no profile name or ref, and no pkg, which would put the
			// user's app choice into a report.
			reply := overPlanReply(short, used, covered, gateAdd)
			fmt.Fprintf(os.Stderr, "[fetchapp] refused: %s\n", reply)
			answer(reply)
			return
		}
	}
	stage := filepath.Join(fetchAppStageBase, pkg)
	os.RemoveAll(stage)
	if err := os.MkdirAll(stage, 0o700); err != nil {
		answer("ERR-STAGE")
		return
	}
	// connDL: the write bound sendProgress restores after each PROGRESS line.
	connDL := time.Now().Add(fetchAppBudget + fetchAppStageAllowance)
	conn.SetDeadline(time.Now().Add(fetchAppBudget + fetchAppStageAllowance)) // the downloads' budget plus the stage + reply
	// Q116 (docs/product-decisions.md, 2026-10-20): a sign-out always wins over a store install. LOGOUT waiting for
	// sessionMu raises signOutWaiting() (lockSessionForLogout); the watcher cancels the downloads with
	// errSignOutCancel, and signedOut is checked before each APK's download and on a failed one. The safe point is the
	// download, before stageapp: nothing is staged into the roamed user or installed, and the stage is removed. The
	// chooser reads ERR-CANCELLED as a failed install, which is right while it is being signed out. The channel is
	// read once, here: signOutLower installs a fresh one, and a raise before FETCH-APP took the lock is already closed.
	so := signOutWaiting()
	bctx, bcancel := context.WithTimeout(context.Background(), fetchAppBudget)
	defer bcancel()
	ctx, cancel := context.WithCancelCause(bctx)
	defer cancel(nil) // ends the watcher with the handler
	goSafe("fetchapp-signout", func() {
		select {
		case <-so:
			cancel(errSignOutCancel)
		case <-ctx.Done():
		}
	})
	// signedOut reads the channel first: the watcher's cancel is asynchronous, the closed channel is not.
	signedOut := func() bool {
		select {
		case <-so:
			return true
		default:
		}
		return errors.Is(context.Cause(ctx), errSignOutCancel)
	}
	// NWP-20261113-26: the start, progress and done lines. Counts across all of the entry's APKs, totals from the
	// entry (an APK with no stated size adds 0). The progress line comes from the copy loop's reads, so no goroutine;
	// a stalled body prints none, and the stall bound ends it. endReply logs the done line BEFORE the reply.
	var total int64
	for _, a := range e.APKs {
		total += a.Size
	}
	fmt.Fprintf(os.Stderr, "[fetchapp] start: %d apk(s), %d bytes (NWP-20261113-26)\n", len(e.APKs), total)
	start := time.Now()
	last := start
	var got int64
	// NWP-20261122-14: the PROGRESS lines of the opt-in, written from the same copy loop on this goroutine. Each write
	// has a 2 s bound, so a chooser that stops reading cannot hold the copy loop; the bound then goes back to connDL,
	// so the verdict keeps the handler's own. The first failed write ends the PROGRESS lines and never the download.
	progressDead := false
	var lastLine time.Time
	sendProgress := func(now time.Time, n int64) {
		if !progressOn || progressDead {
			return
		}
		lastLine = now
		conn.SetWriteDeadline(now.Add(2 * time.Second))
		_, err := io.WriteString(conn, fetchAppProgressLine(n, total))
		conn.SetWriteDeadline(connDL)
		if err != nil {
			progressDead = true
		}
	}
	sendProgress(start, 0)
	fetchAppOnBytes = func(k int) {
		got += int64(k)
		if now := time.Now(); now.Sub(last) >= fetchAppProgressEvery {
			last = now
			fmt.Fprintf(os.Stderr, "[fetchapp] progress: %d of %d bytes, %ds\n", got, total, int64(now.Sub(start)/time.Second))
		}
		if now := time.Now(); now.Sub(lastLine) >= fetchAppProgressLineEvery {
			sendProgress(now, got)
		}
	}
	defer func() { fetchAppOnBytes = nil }()
	endReply := func(r string) {
		fmt.Fprintf(os.Stderr, "%s\n", fetchAppEndLine(got, time.Since(start), r))
		answer(r)
	}
	cancelled := func() {
		fmt.Fprintf(os.Stderr, "[fetchapp] %s: cancelled for a sign-out (Q116)\n", pkg)
		os.RemoveAll(stage)
		endReply("ERR-CANCELLED")
	}
	var names []string
	for _, a := range e.APKs {
		nm := filepath.Base(strings.TrimSpace(a.Name))
		if nm == "" || nm == "." || strings.ContainsAny(nm, "/\\") || !strings.HasSuffix(nm, ".apk") {
			os.RemoveAll(stage)
			endReply("ERR-STAGE")
			return
		}
		if signedOut() {
			cancelled()
			return
		}
		if err := fetchAndVerify(ctx, a.URL, strings.ToLower(strings.TrimSpace(a.Sha256)), filepath.Join(stage, nm), a.Size); err != nil {
			fmt.Fprintf(os.Stderr, "[fetchapp] %s %s: %v\n", pkg, nm, err)
			os.RemoveAll(stage)
			if signedOut() { // a body the sign-out cut is never reported as a mismatch
				cancelled()
				return
			}
			if strings.Contains(err.Error(), "unverifiable") || strings.Contains(err.Error(), "mismatch") {
				endReply("ERR-UNVERIFIED")
			} else {
				endReply("ERR-FETCH")
			}
			return
		}
		names = append(names, nm)
	}
	// The manifest line the worker appends to .appcode/manifest.tsv -- same format installRoamedAppCode reads:
	// pkg \t versionCode \t sideloaded(0) \t mode(installed) \t apk1 [\t apk2 ...]
	var mb strings.Builder
	fmt.Fprintf(&mb, "%s\t%d\t0\tinstalled", pkg, e.VersionCode)
	for _, nm := range names {
		mb.WriteByte('\t')
		mb.WriteString(nm)
	}
	mb.WriteByte('\n')
	if err := os.WriteFile(filepath.Join(stage, "manifest.line"), []byte(mb.String()), 0o600); err != nil {
		os.RemoveAll(stage)
		endReply("ERR-STAGE")
		return
	}
	// NWP-20261130-03: stageapp fetches a parked package's data before it stages the APK, so the reply can come well after
	// the downloads' deadline. The chooser's own FETCH-APP cap still bounds the wait.
	if odBarrierNeeded(dest, uid, pkg) {
		conn.SetDeadline(time.Now().Add(fetchAppOdDataAllowance))
	}
	// Privileged move into the roamed user's chooser .appcode (pkg on the srcUnit slot), mirroring materializeapp.
	out := triggerRoamWorkerKind(dest, "stageapp", name, pass, uid, readRoamSessionSE(dest), "", pkg, "", nil)
	if !strings.HasPrefix(strings.TrimSpace(out), "OK") {
		os.RemoveAll(stage)
		endReply(strings.TrimSpace(out))
		return
	}
	// NWP-20260819-03 review (P1): the signer pin must NOT cross the binder boundary caller-supplied -- a
	// hostile binder client passed "" and stripped the provenance gate entirely. The daemon resolved the
	// entry from the SIGNED catalog/index (findAppEntry above), so IT is the authority: the OK line carries
	// the resolved entry's signingCert, and the chooser pins on that. The reply is always "OK <pkg> <64 hex>":
	// both producers refuse an entry without a cert since NWP-20261029-13 (curate-catalog.py entry_for,
	// trim-fdroid-index.py trim_entry), and a catalog edited by hand to omit one is refused above with
	// ERR-NOSIGNER, before the download (decided 2026-10-20, NWP-20261030-04).
	endReply(fmt.Sprintf("OK %s %s", pkg, fetchAppSigner(e)))
}

// entrySignerPin is the signer pin a store entry carries: its signingCert trimmed and lower-cased, ok only when
// that is exactly 64 hex characters (a SHA-256 digest). Pure. FETCH-APP refuses an entry it is not ok for before
// any download (ERR-NOSIGNER, decided 2026-10-20), so every OK reply carries a real pin.
func entrySignerPin(e *catalogEntry) (string, bool) {
	s := strings.ToLower(strings.TrimSpace(e.SigningCert))
	if len(s) != 64 {
		return "", false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return "", false
		}
	}
	return s, true
}

// fetchAppSigner is the third token of FETCH-APP's OK reply: the resolved entry's signer pin (entrySignerPin), 64
// lower-case hex. Never "-" and never empty: an entry without a 64-hex cert is refused with ERR-NOSIGNER before its
// download (decided 2026-10-20), so no OK line is ever written for one.
func fetchAppSigner(e *catalogEntry) string {
	pin, _ := entrySignerPin(e)
	return pin
}

// catalogPinLine is CATALOG-PIN's reply line (no newline) for the entry FETCH-APP would resolve: "OK <versionCode>
// <signer>" only for an entry FETCH-APP would install -- at least one APK, a versionCode the chooser can pin
// FETCH-APP to, and a 64-hex signer (entrySignerPin) -- else "NONE". Pure. Q050 (decided 2026-10-20): the chooser
// updates an on-demand app at the tap only when this names a newer version from the same signer.
func catalogPinLine(e *catalogEntry) string {
	if e == nil || len(e.APKs) == 0 || e.VersionCode <= 0 {
		return "NONE"
	}
	pin, ok := entrySignerPin(e)
	if !ok {
		return "NONE"
	}
	return fmt.Sprintf("OK %d %s", e.VersionCode, pin)
}

// handleCatalogPin answers what FETCH-APP would install for one package: catalogPinLine(findAppEntry(pkg, 0)).
// Reads only the local signed catalog and index -- no network, no session check, ungated like GET-CATALOG (the
// roamed session's chooser asks it). Logs nothing: a package name in the daemon log would put the user's app
// choice into an issue report.
func handleCatalogPin(conn net.Conn, arg string) {
	pkg := strings.TrimSpace(arg)
	if !validPkgName(pkg) {
		fmt.Fprint(conn, "ERR-PKG\n")
		return
	}
	fmt.Fprint(conn, catalogPinLine(findAppEntry(pkg, 0))+"\n")
}

// handleFetchIcon fetches a catalog app's ICON bytes for the storefront. The unprivileged chooser has NO INTERNET
// permission (and must not -- it would leak browsing + widen its surface), so the daemon fetches the icon, the
// same daemon-does-the-network split as FETCH-APP. The URL is honored ONLY if it is an iconRef of some entry in
// the current SIGNED catalog -- so a caller can't turn the daemon into an SSRF fetcher for arbitrary URLs. Reply:
// "OK <nbytes>\n<bytes>" | NONE (empty / not a catalog icon) | ERR. Public metadata, no session gate (like
// GET-CATALOG); size-capped since an app icon is a few KB.
func handleFetchIcon(conn net.Conn, arg string) {
	arg = strings.TrimSpace(arg)
	if arg == "" {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	// A non-URL arg is a PACKAGE NAME -> serve the icon from the baked LOCAL icon pack (index.go), NO network,
	// so browsing search results never leaks to f-droid.org. A pkg not in the pack (brand-new app) -> NONE ->
	// the client shows a placeholder. Only an http(s):// URL takes the (SSRF-bounded) fetch path below. (Match the
	// scheme, not a bare "http" prefix -- a package like "httpx.app" is a pkg, not a URL.)
	if !strings.HasPrefix(arg, "http://") && !strings.HasPrefix(arg, "https://") {
		if b := servePackIcon(arg); b != nil {
			fmt.Fprintf(conn, "OK %d\n", len(b))
			conn.Write(b)
			return
		}
		fmt.Fprint(conn, "NONE\n")
		return
	}
	url := arg
	if !catalogHasIconURL(url) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	resp, err := fetchAppHTTP.Get(url)
	if err != nil {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	const iconCap = 1 << 20 // 1 MiB -- an icon is a few KB; the cap defends memory against a hostile mirror
	// Read ONE byte past the cap so an over-cap icon is an ERR, not a silent first-MiB cut served as complete
	// (NWP-20261019-28; read one byte past the cap, so an over-cap body is refused, never cut).
	b, err := io.ReadAll(io.LimitReader(resp.Body, iconCap+1))
	if err != nil || len(b) == 0 || len(b) > iconCap {
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprintf(conn, "OK %d\n", len(b))
	conn.Write(b)
}

// catalogHasIconURL reports whether url is the iconRef of some entry in the current catalog -- the allow-list
// that bounds FETCH-ICON to icons the signed manifest vouches for (no arbitrary-URL SSRF).
func catalogHasIconURL(url string) bool {
	var c catalog
	if json.Unmarshal(loadCatalogBytes(), &c) != nil {
		return false
	}
	for i := range c.Entries {
		if c.Entries[i].IconRef == url {
			return true
		}
	}
	return false
}

// --- Signed catalog publishing (Phase 4c): pull a fresh, SIGNED catalog and cache it to /data, so the offer set
// updates WITHOUT an OTA. loadCatalogBytes already prefers a /data catalog whose detached ed25519 signature
// verifies against the baked catalogPubKey -- this just fetches + installs one. FAIL-SAFE: no baked pubkey or no
// source URL => no-op (the baked /system catalog stays authoritative); a bad fetch/signature leaves /data alone. ---

// catalogRefreshURL: where to fetch a fresh signed catalog -- CATALOG_URL (nowhere.conf) and nothing else; unset =>
// "" and the refresh is off. It no longer derives <GATEWAY_URL>/catalog.json (Q023, docs/product-decisions.md
// 2026-10-20): the gateway serves no such route, so every store open sent a request that 404ed. With it unset the
// baked /system catalog is served, and it changes with each OTA. The detached signature is fetched from URL + ".sig".
func catalogRefreshURL() string {
	return strings.TrimRight(os.Getenv("CATALOG_URL"), "/")
}

func catalogHTTPGet(url string) ([]byte, error) {
	resp, err := fetchAppHTTP.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%s -> HTTP %d", url, resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 8<<20)) // 8 MiB cap, like GET-CATALOG
}

// writeAtomicFile is the synced publish for the files under /data/nowhere that the agent replaces whole: the
// device flags (publishDeviceFlag: ota-auto, notice-number, ota-time), the sync interval (syncIntervalSet) and
// the signed catalog and index with their .sig files (refreshCatalog, refreshIndex). It used to write the temp
// file and rename it with no sync. On f2fs/ext4 a rename can reach the disk before the data it names, so a power
// cut left an empty file and a device flag read back as its default after an OK. writeConfDurable (main.go) is
// the one implementation: the temp file path+".tmp" is synced before the rename, and a failure before the rename
// removes it and leaves path as it was (NWP-20261126-19).
func writeAtomicFile(path string, b []byte) error {
	return writeConfDurable(path, b)
}

// refreshCatalog fetches a fresh signed catalog (+ its detached sig) and, IFF the sig verifies against the baked
// catalogPubKey AND it parses as a schema-N catalog, atomically installs it at catalogDataPath (which
// loadCatalogBytes then serves over /system). Returns nil on a successful refresh; an error wrapping
// errRefreshOff when unconfigured (no key / no CATALOG_URL); a real error on fetch/verify failure (in which case
// /data is left untouched).
func refreshCatalog() error {
	if strings.TrimSpace(catalogPubKey) == "" {
		return fmt.Errorf("catalog refresh disabled: no signing key baked: %w", errRefreshOff)
	}
	url := catalogRefreshURL()
	if url == "" {
		return fmt.Errorf("catalog refresh: no source (CATALOG_URL unset): %w", errRefreshOff)
	}
	body, err := catalogHTTPGet(url)
	if err != nil {
		return err
	}
	sig, err := catalogHTTPGet(url + ".sig")
	if err != nil {
		return err
	}
	if !verifyCatalogSig(body, sig) {
		return fmt.Errorf("catalog refresh: fetched manifest signature invalid -- refusing")
	}
	var c catalog
	if json.Unmarshal(body, &c) != nil || c.Schema != catalogSchema {
		return fmt.Errorf("catalog refresh: fetched manifest is not a valid schema-%d catalog", catalogSchema)
	}
	// Same sanity and anti-rollback as refreshIndex (index.go), minus its staleness bound: a freshness bound for the
	// hand-signed catalog is not built -- Q023 (docs/product-decisions.md 2026-10-20) brings a gateway catalog
	// route back only after refreshCatalog gains refreshIndex's freshness check, together with the F-Droid publish
	// pipeline row.
	now := time.Now().Unix()
	if c.Generated <= 0 || c.Generated > now+86400 {
		return fmt.Errorf("catalog refresh: bad generated=%d", c.Generated)
	}
	if c.Generated <= indexGeneratedOf(loadCatalogBytes()) {
		return nil // already current or older -> no-op (not an error)
	}
	os.MkdirAll(filepath.Dir(catalogDataPath), 0o700)
	if err := writeAtomicFile(catalogDataPath, body); err != nil {
		return err
	}
	return writeAtomicFile(catalogDataPath+".sig", sig)
}

// handleRefreshCatalog pulls a fresh signed catalog. Reply: "OK" (refreshed) | "NONE" (not configured -- no baked
// key / no source, so the baked catalog stands) | "ERR" (fetch/verify failed; the previous catalog is kept).
func handleRefreshCatalog(conn net.Conn) {
	err := refreshCatalog()
	if err == nil {
		fmt.Fprint(conn, "OK\n")
		return
	}
	if errors.Is(err, errRefreshOff) {
		fmt.Fprint(conn, "NONE\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[catalog] refresh: %v\n", err)
	fmt.Fprint(conn, "ERR\n")
}
