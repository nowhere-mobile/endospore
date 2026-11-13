package main

// NWP-20261130-03: THE PER-PACKAGE FETCH of parked app data. The 2026-10-26 decision's #2 (docs/product-decisions.md, "a
// sign-in waits only for what must be on the phone when the user lands ...") lets a sign-in skip the CE/DE data of an
// On-demand or Auto app until it is materialised. This file is the two halves that make the skip real:
//
//   - restoreSkippingParked: the sign-in's bare vault and #de restores stream every chunk EXCEPT the spans
//     (pkg_span.go) of packages the session will park, and record those packages in this scope's list, the file
//     NOWHERE_UNFETCHED_LIST names. The vault restore runs in two passes, because the parked set is the chooser's
//     nowhere-appkeep, which the vault itself holds: pass 1 streams everything that is not a candidate span (the
//     chooser's data never has one), pass 2 the candidate spans of packages that are not parked.
//   - fetchOdData (verb fetch-oddata): when a package is materialised, roamd fetches its spans from the plan this
//     sign-in wrote, places the data where hold_ondemand would have parked it, and takes the package off the list. The
//     fetch comes before the APK can be installed on every Nowhere path: materializeapp (a tap, the Auto sweep) and
//     stageapp (a store Get or Update). A failed fetch stages nothing, so nothing is installed.
//
// The seal side is in pushProfile: the walk excludes a listed package's directories whatever they hold, the carry
// re-emits its stored span (unfetched_carry.go), and the guard refuses a seal that would drop it or carry it other than
// by its stored span (unfetched_guard.go). All three read one list, read once (sealUnfetchedList). While a package is
// listed, its stored data is the only copy that counts: what the phone holds of it is an empty skeleton, or what an app
// wrote on fresh data before its fetch (roamd blocks that app, od_block_app), and neither may replace the stored span.
//
// The session state lives in roamd's $STATE/odfetch.<uid>/ (RAM, per uid, removed by the reap): one list and one plan
// per scope. roamd creates both lists empty at the sign-in's commit; a restore never creates a missing list, it turns
// the skip OFF instead, and a push always names its scope's list, so a lost file refuses the seal (unfetched-unknown)
// rather than sealing unguarded. No key, passphrase or profile name is written there; package names are, as they are in
// nowhere-appkeep.
//
// The #72 receipt: finishRestore earns it when skipped == 0, and skipped counts tar entries that could not be written.
// A span that is never streamed adds nothing to it, so a restore that skipped parked spans still earns the receipt, and
// the walk exclusion, the carry and the guard cover what it did not write.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"
)

// The four file names of one session's odfetch dir, beside the done markers (odDonePath). roamd names the lists only in
// od_unf_path; TestOdListNamesMatchRoamd pins that its names equal these.
const (
	odUnfetchedCE = "unfetched.ce"
	odUnfetchedDE = "unfetched.de"
	odPlanCE      = "plan.ce"
	odPlanDE      = "plan.de"
)

// odScopeOf maps a profile scope to its odfetch scope: the bare vault is "ce", #de is "de"; no other scope skips.
func odScopeOf(profile string) (string, bool) {
	switch {
	case strings.IndexByte(profile, '#') < 0:
		return "ce", true
	case strings.HasSuffix(profile, "#de") && strings.Count(profile, "#") == 1:
		return "de", true
	}
	return "", false
}

// odScopeFiles is the ONE place that maps an odfetch scope to its list and plan file names in dir.
func odScopeFiles(dir, scope string) (list, plan string) {
	if scope == "de" {
		return filepath.Join(dir, odUnfetchedDE), filepath.Join(dir, odPlanDE)
	}
	return filepath.Join(dir, odUnfetchedCE), filepath.Join(dir, odPlanCE)
}

// odBarrierWorker runs the `odblock` worker op on the read-only lane. Tests replace it.
var odBarrierWorker = triggerRoamWorkerKind

// odBarrierNeeded reports whether this session's unfetched lists name pkg. A list that cannot be read counts as naming
// it, as roamd's od_listed does: an unknown state never leaves an installed app launchable. With no odfetch dir at all
// (a local session, or a sign-in that failed before its commit) there is nothing to skip and the answer is false.
func odBarrierNeeded(dest, uid, pkg string) bool {
	dir := filepath.Join(dest, "odfetch."+uid)
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return false
	}
	for _, scope := range []string{"ce", "de"} {
		list, _ := odScopeFiles(dir, scope)
		b, err := os.ReadFile(list)
		if err != nil {
			return true
		}
		for _, l := range strings.Split(string(b), "\n") {
			if strings.TrimSpace(l) == pkg {
				return true
			}
		}
	}
	return false
}

// Reply of OD-DATA-PENDING, the chooser's question at a package-added event: is this package's data still out?
// YES: a list names it, or roamd fetched it and its odrestore has not finished. NO: its data is back or never was out.
// UNKNOWN: a list could not be read. The chooser treats everything except NO as data out.
const (
	odPendingYes     = "YES"
	odPendingNo      = "NO"
	odPendingUnknown = "UNKNOWN"
)

// odPendingName is the marker roamd writes before a fetch and removes at odrestore's OK reply, one file per package in
// the session's odfetch dir. It covers the span the lists cannot: nApps fetches BEFORE it installs, so the list no longer
// names the package while its data waits in the hold for an odrestore a busy RW lane can delay. Its name is roamd's
// od_pending_path; TestOdListNamesMatchRoamd pins the two.
func odPendingName(pkg string) string { return "pending." + pkg }

// odDataPending answers OD-DATA-PENDING. It reads tmpfs files only and takes no worker lane, so a seal on the RW lane and
// a storage walk on the RO lane cannot delay the barrier. With no odfetch dir (a local session, or a sign-in that failed
// before its commit) there is nothing to skip and the answer is NO; any other stat failure is UNKNOWN.
func odDataPending(dest, uid, pkg string) string {
	dir := filepath.Join(dest, "odfetch."+uid)
	if _, err := os.Stat(dir); err != nil {
		if os.IsNotExist(err) {
			return odPendingNo
		}
		return odPendingUnknown
	}
	if _, err := os.Lstat(filepath.Join(dir, odPendingName(pkg))); err == nil {
		return odPendingYes
	} else if !os.IsNotExist(err) {
		return odPendingUnknown
	}
	reply := odPendingNo
	for _, scope := range []string{"ce", "de"} {
		list, _ := odScopeFiles(dir, scope)
		b, err := os.ReadFile(list)
		if err != nil {
			reply = odPendingUnknown
			continue
		}
		if parseUnfetched(b)[pkg] {
			return odPendingYes
		}
	}
	return reply
}

// handleOdDataPending is the OD-DATA-PENDING verb: "OD-DATA-PENDING\n<pkg>\n" -> YES | NO | UNKNOWN | ERR-PKG. NO when
// nobody is signed in or the session is local (neither has a restore that skipped anything). No log line: the caller
// asks at every install and the answer names nothing a log needs.
func handleOdDataPending(conn net.Conn, dest, pkg string) {
	if !validPkgName(pkg) {
		fmt.Fprint(conn, "ERR-PKG\n")
		return
	}
	name, _, uid := readRoamSession(dest)
	if name == "" || isLocalSession(dest) {
		fmt.Fprint(conn, odPendingNo+"\n")
		return
	}
	fmt.Fprint(conn, odDataPending(dest, uid, pkg)+"\n")
}

// odBarrierRetryEvery is the wait between the tries of a barrier the RO lane answered busy. Tests shorten it.
var odBarrierRetryEvery = 2 * time.Second

// odLaunchBarrier blocks an installed package whose data is still in the store, on the read-only lane, so a seal holding
// the RW lane cannot delay it. Every install Nowhere itself makes (a tap, the Auto sweep, a store Get) has fetched before
// it installs (materializeapp, stageapp), so its package is not listed here; this is for an install outside Nowhere
// (Aurora, Play, sideload), which reaches RESTORE-ODDATA with its data unfetched.
//
// A busy RO lane does not end the barrier. The first try runs here, so the normal case blocks before odrestore queues;
// on a busy answer the tries go on in the background while odrestore waits for the RW lane, and whichever lane comes free
// first blocks the app (odrestore blocks it itself before it fetches, and refuses if it cannot). The returned func ends
// the tries; the caller runs it when the op returns. A try still in flight then is harmless: odblock lifts a block it set
// once the package is off the lists. A refusal is not retried, because PackageManager gives the same answer every time.
// The log lines name the uid only, never the package.
func odLaunchBarrier(dest, name, uid, pkg string) func() {
	if !odBarrierNeeded(dest, uid, pkg) {
		return func() {}
	}
	// Read once, here: the tries outlive this call and must not touch a test's restored globals.
	try, every := odBarrierWorker, odBarrierRetryEvery
	attempt := func() string {
		return strings.TrimSpace(try(dest, "odblock", name, "", uid, "", "", pkg, "", nil))
	}
	out := attempt()
	if out != "OK BLOCKED" && out != "OK NONE" {
		dlog("odblock uid=%s -> %s: odrestore tries the block again (NWP-20261130-03)", uid, out)
	}
	if out != workerBusy {
		return func() {}
	}
	stopped := make(chan struct{})
	goSafe("od-barrier-retry", func() {
		for {
			select {
			case <-stopped:
				return
			case <-time.After(every):
			}
			if out := attempt(); out != workerBusy {
				dlog("odblock uid=%s -> %s after a busy lane (NWP-20261130-03)", uid, out)
				return
			}
		}
	})
	return func() { close(stopped) }
}

// odDonePath is the done marker of pkg's placement in scope: done.<scope>.<pkg> in dir. It lives in the session's odfetch
// dir, never in the hold, so no crash can leave it inside data that odrestore moves into the app.
func odDonePath(dir, scope, pkg string) string {
	return filepath.Join(dir, "done."+scope+"."+pkg)
}

// isOdFetchStagePath is com.nowhere.chooser/.nowhere-odfetch: fetch-oddata's stage. A stage a killed fetch left is
// never sealed (both seal walks and the delta estimate skip it).
func isOdFetchStagePath(rel string) bool {
	return filepath.ToSlash(rel) == chooserPkg+"/"+odFetchStageName
}

// odPlan is what one scope's restore skipped: per package, the span's chunk hashes and sealed sizes, and its Pkg bytes.
// Hashes and sizes only; the fetch resolves the key at run time.
type odPlan struct {
	V      int                  `json:"v"`
	Footer string               `json:"footer"`
	FSize  int64                `json:"fsize,omitempty"`
	Pkgs   map[string]odPlanPkg `json:"pkgs"`
}

type odPlanPkg struct {
	Chunks []string `json:"chunks"`
	Sizes  []int64  `json:"sizes,omitempty"`
	Bytes  int64    `json:"bytes"`
}

func readOdPlan(path string) (odPlan, error) {
	var p odPlan
	b, err := os.ReadFile(path)
	if err != nil {
		return p, err
	}
	if err := json.Unmarshal(b, &p); err != nil {
		return p, err
	}
	return p, nil
}

func writeOdPlan(path string, p odPlan) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	return publishReceiptFile(path, b)
}

// parseUnfetched is loadUnfetchedList's line rule: one package per line, blank and '#' lines ignored, a name that
// fails validPkgName ignored.
func parseUnfetched(b []byte) map[string]bool {
	m := map[string]bool{}
	for _, ln := range strings.Split(string(b), "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		if validPkgName(ln) {
			m[ln] = true
		}
	}
	return m
}

func writeUnfetched(path string, set map[string]bool) error {
	names := make([]string, 0, len(set))
	for p, on := range set {
		if on {
			names = append(names, p)
		}
	}
	sort.Strings(names)
	body := ""
	if len(names) > 0 {
		body = strings.Join(names, "\n") + "\n"
	}
	return publishReceiptFile(path, []byte(body))
}

// addUnfetched adds pkgs to the list at path. It refuses a missing file: only roamd creates a list.
func addUnfetched(path string, pkgs map[string]bool) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	set := parseUnfetched(b)
	for p := range pkgs {
		set[p] = true
	}
	return writeUnfetched(path, set)
}

// removeUnfetched takes pkg off the list at path. The file stays when it becomes empty.
func removeUnfetched(path, pkg string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	set := parseUnfetched(b)
	if !set[pkg] {
		return nil
	}
	delete(set, pkg)
	return writeUnfetched(path, set)
}

// sealUnfetchedList is pushProfile's one read of this scope's list (NOWHERE_UNFETCHED_LIST), for the bare vault and #de
// only: the set the carry and the guard judge, its ok, and the walk's exclusion (the set minus the drop list). Other
// scopes get (nil, true, nil): no list, today's seal.
func sealUnfetchedList(profile string) (unf map[string]bool, ok bool, excl map[string]bool) {
	if _, scoped := odScopeOf(profile); !scoped {
		return nil, true, nil
	}
	unf, ok = loadUnfetchedList()
	if !ok || len(unf) == 0 {
		return unf, ok, nil
	}
	drop := loadDropList()
	for p, on := range unf {
		if on && !dropPkgForFileRel(p+"/x", drop) {
			if excl == nil {
				excl = map[string]bool{}
			}
			excl[p] = true
		}
	}
	return unf, ok, excl
}

// unfetchedRestorePlan is the sign-in skip's gate and its candidates: every package whose span pkgSpanChunks trusts in
// this head. ok is false -- the restore is today's single pass -- when the scope is not the bare vault or #de, when
// NOWHERE_PARK_KEEP, NOWHERE_PARK_SHIPPED or NOWHERE_UNFETCHED_LIST is unset, when the list file does not exist or is
// not this scope's list, when the head has no span index, when a candidate range holds the footer chunk, or when no
// package is a candidate.
func unfetchedRestorePlan(profile string, m chunkManifest) (cands map[string][][2]int, list, plan string, ok bool) {
	scope, scoped := odScopeOf(profile)
	if !scoped || len(m.PkgSpan) == 0 || len(m.Chunks) == 0 {
		return nil, "", "", false
	}
	list = os.Getenv("NOWHERE_UNFETCHED_LIST")
	if list == "" || os.Getenv("NOWHERE_PARK_KEEP") == "" || os.Getenv("NOWHERE_PARK_SHIPPED") == "" {
		return nil, "", "", false
	}
	wantList, wantPlan := odScopeFiles(filepath.Dir(list), scope)
	if filepath.Clean(list) != wantList {
		fmt.Printf("restore: profile %s unfetched: the list is not this scope's -> nothing skipped (NWP-20261130-03)\n", logProfile(profile))
		return nil, "", "", false
	}
	if fi, err := os.Stat(list); err != nil || !fi.Mode().IsRegular() {
		return nil, "", "", false // only roamd creates a list; a missing one turns the skip OFF
	}
	footer := len(m.Chunks) - 1
	for p := range m.PkgSpan {
		if _, _, trusted := pkgSpanChunks(m, p); !trusted || !validPkgName(p) {
			continue
		}
		for _, r := range m.PkgSpan[p] {
			if r[0] <= footer && footer < r[1] {
				return nil, "", "", false
			}
		}
		if cands == nil {
			cands = map[string][][2]int{}
		}
		cands[p] = m.PkgSpan[p]
	}
	if len(cands) == 0 {
		return nil, "", "", false
	}
	return cands, wantList, wantPlan, true
}

// parkedFromKeep is the set hold_ondemand parks: the keep file's ondemand and auto packages, minus the ones the image
// ships (the file NOWHERE_PARK_SHIPPED names, NWP-20261129-27). ok is false when either file cannot be read.
func parkedFromKeep(keepPath, shippedPath string) (map[string]bool, bool) {
	kb, err := os.ReadFile(keepPath)
	if err != nil {
		return nil, false
	}
	sb, err := os.ReadFile(shippedPath)
	if err != nil {
		return nil, false
	}
	shipped := parseUnfetched(sb)
	out := map[string]bool{}
	for p, mode := range parseKeepModes(kb) {
		if (mode == "ondemand" || mode == "auto") && validPkgName(p) && !shipped[p] {
			out[p] = true
		}
	}
	return out, true
}

// chunkSel is the sub-manifest of m whose chunk indices keep says yes to, in index order: a fresh slice, never an
// alias of m.Chunks. Sizes follow when m has them.
func chunkSel(m chunkManifest, keep func(int) bool) chunkManifest {
	out := chunkManifest{Version: m.Version}
	sized := len(m.Sizes) == len(m.Chunks)
	for i, h := range m.Chunks {
		if !keep(i) {
			continue
		}
		out.Chunks = append(out.Chunks, h)
		if sized {
			out.Sizes = append(out.Sizes, m.Sizes[i])
		}
	}
	return out
}

func inRanges(i int, rs [][2]int) bool {
	for _, r := range rs {
		if r[0] <= i && i < r[1] {
			return true
		}
	}
	return false
}

func sumSizes(m chunkManifest) int64 {
	var n int64
	for _, s := range m.Sizes {
		n += s
	}
	return n
}

// restoreSkippingParked is the restore verb's essential restore for every scope. Off (unfetchedRestorePlan), it is
// cdcRestore. On, see the file header. It returns the untar's skipped count over both passes.
func restoreSkippingParked(base string, key []byte, profile string, m chunkManifest, dest string) int {
	cands, list, planPath, on := unfetchedRestorePlan(profile, m)
	if !on {
		return cdcRestore(base, key, m, dest)
	}
	var all [][2]int
	for _, rs := range cands {
		all = append(all, rs...)
	}
	p1 := chunkSel(m, func(i int) bool { return !inRanges(i, all) })
	ladder := sumSizes(m)
	skipped := cdcRestoreProg(base, key, p1, dest, 0, ladder, nil)

	skip := map[string]bool{}
	if parked, ok := parkedFromKeep(os.Getenv("NOWHERE_PARK_KEEP"), os.Getenv("NOWHERE_PARK_SHIPPED")); ok {
		for p := range cands {
			if parked[p] {
				skip[p] = true
			}
		}
	} else {
		fmt.Printf("restore: profile %s unfetched: the keep or shipped list could not be read -> nothing skipped (NWP-20261130-03)\n", logProfile(profile))
	}
	var notFetched int64
	nChunks := 0
	if len(skip) > 0 {
		plan, err := readOdPlan(planPath)
		if err != nil {
			plan = odPlan{}
		}
		plan.V, plan.Footer = m.Version, m.Chunks[len(m.Chunks)-1]
		if len(m.Sizes) == len(m.Chunks) {
			plan.FSize = m.Sizes[len(m.Sizes)-1]
		}
		if plan.Pkgs == nil {
			plan.Pkgs = map[string]odPlanPkg{}
		}
		for p := range skip {
			c, s, _ := pkgSpanChunks(m, p)
			plan.Pkgs[p] = odPlanPkg{Chunks: c, Sizes: s, Bytes: m.Pkg[p]}
		}
		// The plan goes first, then the list: a package on the list always has a plan entry to fetch from.
		if err := writeOdPlan(planPath, plan); err != nil {
			fmt.Printf("restore: profile %s unfetched: the plan could not be written (%s) -> nothing skipped (NWP-20261130-03)\n", logProfile(profile), logSafeErrText(err))
			skip = map[string]bool{}
		} else if err := addUnfetched(list, skip); err != nil {
			fmt.Printf("restore: profile %s unfetched: the list could not be written (%s) -> nothing skipped (NWP-20261130-03)\n", logProfile(profile), logSafeErrText(err))
			skip = map[string]bool{}
		}
		for p := range skip {
			notFetched += m.Pkg[p]
			nChunks += len(plan.Pkgs[p].Chunks)
		}
	}
	var rest [][2]int
	for p, rs := range cands {
		if !skip[p] {
			rest = append(rest, rs...)
		}
	}
	if len(rest) > 0 {
		footer := len(m.Chunks) - 1
		p2 := chunkSel(m, func(i int) bool { return i == footer || inRanges(i, rest) })
		done := sumSizes(p1)
		skipped += cdcRestoreProg(base, key, p2, dest, done, done+sumSizes(p2), nil)
	}
	fmt.Printf("restore: profile %s unfetched: %d package(s) skipped, %d B not fetched, %d chunk(s) (NWP-20261130-03)\n",
		logProfile(profile), len(skip), notFetched, nChunks)
	return skipped
}

// fetchOdData places pkg's data of every scope whose list names it, from that scope's plan, into the scope's on-demand
// hold: <root>/com.nowhere.chooser/.nowhere-odhold/<pkg>, where hold_ondemand would have parked it at sign-in. roamd's
// odrestore then moves the hold into place as it does for a parked package. dir is the session's odfetch dir.
//
// Per scope: place, write the done marker (odDonePath), then take the list line off, then remove the marker and the plan
// entry. Only the marker proves a placement: a hold that exists without it -- hold_ondemand's move of an empty skeleton,
// or what a killed overlay left -- is fetched again and the stored data is laid over it. A failure leaves that scope's
// list line, plan entry and marker as they were, so a later call can finish; it leaves no stage. A sign-out (the
// NOWHERE_OD_CANCEL marker) stops the download between chunks. fetched is false when neither list names pkg.
//
// Both lists are read before anything is placed, and a list that is missing or unreadable is an error: roamd makes both
// at the sign-in's commit, so a lost one is unknown state, which is never the same as "not unfetched".
func fetchOdData(base, name, pass, pkg, ceRoot, deRoot, dir string) (ceB, deB int64, fetched bool, err error) {
	if !validPkgName(pkg) {
		return 0, 0, false, errors.New("bad package name")
	}
	scopes := []struct {
		scope, profile, root string
		bytes                *int64
		lines                []byte
	}{{scope: "ce", profile: name, root: ceRoot, bytes: &ceB}, {scope: "de", profile: name + "#de", root: deRoot, bytes: &deB}}
	for i := range scopes {
		list, _ := odScopeFiles(dir, scopes[i].scope)
		lb, rerr := os.ReadFile(list)
		if rerr != nil {
			return 0, 0, false, &odScopedErr{scope: scopes[i].scope + " list unreadable", err: rerr}
		}
		scopes[i].lines = lb
	}
	for _, sc := range scopes {
		list, planPath := odScopeFiles(dir, sc.scope)
		done := odDonePath(dir, sc.scope, pkg)
		if !parseUnfetched(sc.lines)[pkg] {
			os.Remove(done) // a marker a crash left after the list line came off: the placement is complete
			continue
		}
		fetched = true
		if odFetchCancelled() {
			return ceB, deB, fetched, errOdFetchCancelled
		}
		n, ferr := fetchOdScope(base, sc.profile, pass, pkg, sc.root, list, planPath, done)
		if ferr != nil {
			return ceB, deB, fetched, &odScopedErr{scope: sc.scope, err: ferr}
		}
		*sc.bytes = n
	}
	return ceB, deB, fetched, nil
}

// odScopedErr is a failure in one scope of a fetch. Its text is the scope and the error's code only (errCode, Q001): a
// filesystem error repeats the source and target paths unquoted, the app's own file names among them, and roam.log's
// scrub leaves an unquoted path in place, so the text roamd logs must not hold one.
type odScopedErr struct {
	scope string
	err   error
}

func (e *odScopedErr) Error() string { return e.scope + ": " + errCode(e.err) }
func (e *odScopedErr) Unwrap() error { return e.err }

// errOdFetchCancelled is a fetch a sign-out stopped (odFetchCancelled).
var errOdFetchCancelled = errors.New("cancelled")

// odFetchCancelled is the sign-out check fetch-oddata makes before each scope and between the chunks of its download;
// a seam for tests, which raise the marker part way through a download.
var odFetchCancelled = odCancelRequested

// odDoneToken is what the done marker holds: the package and its span's chunk hashes.
func odDoneToken(pkg string, chunks []string) []byte {
	return []byte(pkg + "\n" + strings.Join(chunks, ",") + "\n")
}

// odPlacedByUs is true when the done marker for pkg is in place and the hold target exists: with the plan entry still
// there, the marker must name its chunks; with the entry gone, the marker must name pkg.
func odPlacedByUs(done, target, pkg string, pp odPlanPkg, had bool) bool {
	b, err := os.ReadFile(done)
	if err != nil {
		return false
	}
	if fi, err := os.Lstat(target); err != nil || !fi.IsDir() {
		return false
	}
	if had {
		return bytes.Equal(b, odDoneToken(pkg, pp.Chunks))
	}
	return strings.HasPrefix(string(b), pkg+"\n")
}

func fetchOdScope(base, profile, pass, pkg, root, list, planPath, done string) (int64, error) {
	target := filepath.Join(root, chooserPkg, odHoldDirName, pkg)
	plan, perr := readOdPlan(planPath)
	pp, had := plan.Pkgs[pkg]
	if perr == nil && odPlacedByUs(done, target, pkg, pp, had) {
		// A placement whose bookkeeping a crash or a failed write cut: finish the bookkeeping only.
		return pp.Bytes, odFinish(plan, planPath, list, done, pkg, had)
	}
	if perr != nil {
		return 0, fmt.Errorf("plan unreadable: %s", errCode(perr))
	}
	if !had || len(pp.Chunks) == 0 || plan.Footer == "" {
		return 0, errors.New("no plan entry")
	}
	key, _, ok := resolveKey(base, profile, pass)
	if !ok {
		return 0, errors.New("no head")
	}
	stage := filepath.Join(root, chooserPkg, odFetchStageName, pkg)
	os.RemoveAll(stage)
	defer os.RemoveAll(stage)
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return 0, err
	}
	m := chunkManifest{Version: plan.V, Chunks: append(append([]string{}, pp.Chunks...), plan.Footer)}
	if len(pp.Sizes) == len(pp.Chunks) {
		m.Sizes = append(append([]int64{}, pp.Sizes...), plan.FSize)
	}
	if skipped, err := odDownload(base, key, m, stage); err != nil {
		return 0, err
	} else if skipped != 0 {
		return 0, fmt.Errorf("%d entries not written", skipped)
	}
	if err := placeOdStage(stage, root, pkg); err != nil {
		return 0, err
	}
	if err := publishReceiptFile(done, odDoneToken(pkg, pp.Chunks)); err != nil {
		return 0, err
	}
	return pp.Bytes, odFinish(plan, planPath, list, done, pkg, had)
}

// odDownload streams m into stage, stopping between chunks once odFetchCancelled reports a sign-out: then it returns
// errOdFetchCancelled, whatever the cut stream made the untar do. Any other panic goes on to main's recover, which maps
// a store that could not be reached to its own exit code.
func odDownload(base string, key []byte, m chunkManifest, stage string) (skipped int, err error) {
	var stopped atomic.Bool
	cancelled := func() bool {
		if odFetchCancelled() {
			stopped.Store(true)
			return true
		}
		return false
	}
	defer func() {
		if r := recover(); r != nil {
			if !stopped.Load() {
				panic(r)
			}
			skipped, err = 0, errOdFetchCancelled
		}
	}()
	skipped = cdcRestoreProg(base, key, m, stage, 0, 0, cancelled)
	if stopped.Load() {
		return 0, errOdFetchCancelled
	}
	return skipped, nil
}

// odFinish is the bookkeeping after a placement: the list line, then the marker and the plan entry. The list line goes
// first, while the marker still proves the placement: a failure or a crash before it leaves the marker and the plan
// entry, so the next call finishes here without a download. After it, the package is no longer guarded and its hold is
// whole; a marker left behind is removed by the next call (fetchOdData) and is never in the hold.
func odFinish(plan odPlan, planPath, list, done, pkg string, had bool) error {
	if err := removeUnfetched(list, pkg); err != nil {
		return err
	}
	os.Remove(done)
	if had {
		delete(plan.Pkgs, pkg)
		writeOdPlan(planPath, plan) // a stale entry for an unlisted package is never read
	}
	return nil
}

// placeOdStage checks the stage holds only pkg's two shapes, <pkg>/... and com.nowhere.chooser/.nowhere-odhold/<pkg>/...,
// merges them as hold_ondemand does (when both exist, the canonical copy is laid over the held copy: a file in both
// takes the canonical copy, a file only the hold has survives), and places the result on the hold target: by a rename
// when there is no target, or laid over an existing one (the stored copy wins). The caller writes the done marker after.
func placeOdStage(stage, root, pkg string) error {
	ents, err := os.ReadDir(stage)
	if err != nil {
		return err
	}
	for _, e := range ents {
		if e.Name() != pkg && e.Name() != chooserPkg {
			return errors.New("stage holds another package")
		}
	}
	if sub, err := os.ReadDir(filepath.Join(stage, chooserPkg)); err == nil {
		for _, e := range sub {
			if e.Name() != odHoldDirName {
				return errors.New("stage holds chooser data")
			}
		}
		if hs, err := os.ReadDir(filepath.Join(stage, chooserPkg, odHoldDirName)); err == nil {
			for _, e := range hs {
				if e.Name() != pkg {
					return errors.New("stage holds another held package")
				}
			}
		}
	}
	canon := filepath.Join(stage, pkg)
	held := filepath.Join(stage, chooserPkg, odHoldDirName, pkg)
	_, cerr := os.Lstat(canon)
	_, herr := os.Lstat(held)
	src := ""
	switch {
	case cerr == nil && herr == nil:
		if err := overlayTree(canon, held); err != nil {
			return err
		}
		src = held
	case cerr == nil:
		src = canon
	case herr == nil:
		src = held
	default:
		return errors.New("stage holds no data")
	}
	if fi, err := os.Lstat(src); err != nil || !fi.IsDir() {
		return errors.New("stage data is not a directory")
	}
	holdDir := filepath.Join(root, chooserPkg, odHoldDirName)
	if err := os.MkdirAll(holdDir, 0o700); err != nil {
		return err
	}
	target := filepath.Join(holdDir, pkg)
	ti, terr := os.Lstat(target)
	switch {
	case errors.Is(terr, fs.ErrNotExist):
		return os.Rename(src, target)
	case terr != nil:
		return terr
	case !ti.IsDir():
		return errors.New("the hold is not a directory")
	}
	return overlayTree(src, target)
}

// odRename is overlayTree's rename, a seam for tests: nothing else makes a rename into a held directory fail for root.
var odRename = os.Rename

// overlayTree moves every entry of src over dst: directories are merged, anything else replaces dst's entry.
func overlayTree(src, dst string) error {
	return filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if rel == "." {
			return nil
		}
		to := filepath.Join(dst, rel)
		if info.IsDir() {
			if di, err := os.Lstat(to); err == nil && di.IsDir() {
				return nil
			}
			os.RemoveAll(to)
			if err := odRename(p, to); err != nil {
				return err
			}
			return filepath.SkipDir
		}
		if di, err := os.Lstat(to); err == nil && di.IsDir() {
			os.RemoveAll(to)
		}
		return odRename(p, to)
	})
}

// odFetchFailedLine is the log line of a failed fetch: the package, the scope, the error's code and the time.
func odFetchFailedLine(pkg string, err error, ms int64) string {
	return fmt.Sprintf("fetch-oddata: %q FAILED (%s) after %dms (NWP-20261130-03)", pkg, logSafeErrText(err), ms)
}

// runFetchOdData is the fetch-oddata verb: fetch-oddata <store> <name> <pass> <pkg> <ceRoot> <deRoot>, the odfetch dir
// in NOWHERE_ODFETCH_DIR. Exit 0 when placed or when both lists were read and neither names pkg ("not unfetched"), 1 on a failure,
// exitStoreUnreachable when the bare head could not be read. One log line, never a path inside the app.
func runFetchOdData(args []string) {
	base, name, pass, pkg, ceRoot, deRoot := args[0], args[1], args[2], args[3], args[4], args[5]
	dir := os.Getenv("NOWHERE_ODFETCH_DIR")
	if dir == "" || !validPkgName(pkg) {
		fmt.Println("fetch-oddata: FAILED (usage: NOWHERE_ODFETCH_DIR and a package name) (NWP-20261130-03)")
		os.Exit(1)
	}
	locked, unreadable := scopeOwnerLocked(base, name, pass)
	if unreadable {
		fmt.Printf("fetch-oddata: profile %s: the store could not be read -> refusing (NWP-20261130-03)\n", logProfile(name))
		os.Exit(exitStoreUnreachable)
	}
	if locked {
		fmt.Printf("fetch-oddata: profile %s does not open on this phone -> refusing (NWP-20261130-03)\n", logProfile(name))
		os.Exit(1)
	}
	t0 := time.Now()
	ceB, deB, fetched, err := fetchOdData(base, name, pass, pkg, ceRoot, deRoot, dir)
	if err != nil {
		fmt.Println(odFetchFailedLine(pkg, err, time.Since(t0).Milliseconds()))
		os.Exit(1)
	}
	if !fetched {
		fmt.Printf("fetch-oddata: %q not unfetched (NWP-20261130-03)\n", pkg)
		return
	}
	fmt.Printf("fetch-oddata: %q CE %d B DE %d B in %dms (NWP-20261130-03)\n", pkg, ceB, deB, time.Since(t0).Milliseconds())
}
