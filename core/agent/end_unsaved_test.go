package main

// NWP-20261010-10: the refusal classes, the GET-LOGOFF-REFUSAL wire, and END-UNSAVED's gates. See end_unsaved.go.

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// ---- the classification ----

func TestRefusalReasonFinal_EachGuardIsClassed(t *testing.T) {
	for reason, final := range map[string]bool{
		// deterministic for the session: a retry of the same seal reproduces it
		"shrink": true, "no-receipt": true, "stale-base": true, "blind": true, "deleted": true,
		"apps-vanished": true,
		"locks-changed": true, "locks-changed-key": true, "unlock-lost": true, "unlock-lost-key": true,
		// a retry can clear it, or this build cannot say
		"stale": false, "fence": false, "unreadable-head": false, "unknown": false, "": false, "something-new": false,
	} {
		if got := refusalReasonFinal(reason); got != final {
			t.Errorf("refusalReasonFinal(%q) = %v, want %v", reason, got, final)
		}
	}
}

func TestSealRefusalReasons_NamesEveryRefusalThePushVerbFoldsIn(t *testing.T) {
	for _, c := range []struct {
		refused      bool
		why          string
		fence, stale bool
		want         string
	}{
		{true, "shrink", false, false, "shrink"},
		{true, "", false, false, "unknown"}, // a guard that forgot to name itself reads as RETRY
		{false, "", true, false, "fence"},
		{false, "", false, true, "stale"},
		{true, "no-receipt", false, true, "no-receipt,stale"},
		{false, "shrink", false, false, ""}, // a stale reason without the flag is not a refusal
	} {
		if got := strings.Join(sealRefusalReasons(c.refused, c.why, c.fence, c.stale), ","); got != c.want {
			t.Errorf("sealRefusalReasons(%v, %q, %v, %v) = %q, want %q", c.refused, c.why, c.fence, c.stale, got, c.want)
		}
	}
}

func TestLogoffRefusalFinal_OnlyAFinalGuardOnABlockingScopeCounts(t *testing.T) {
	for _, c := range []struct {
		parts   string
		reasons map[string][]string
		want    bool
	}{
		{"de=refused", map[string][]string{"de": {"shrink"}}, true}, // NW-db441ee766cb
		{"vault=refused", map[string][]string{"vault": {"no-receipt"}}, true},
		{"media=refused,sys=refused", map[string][]string{"media": {"stale-base"}}, true},
		{"de=refused", map[string][]string{"de": {"stale"}}, false},          // transient
		{"de=refused", map[string][]string{"de": {"stale", "shrink"}}, true}, // the shrink still holds
		{"de=refused", nil, false}, // an agent that names nothing
		{"apps=refused", map[string][]string{"apps": {"apps-vanished"}}, false},                // #apps never blocks
		{"de=refused,media=failed", map[string][]string{"de": {"shrink"}}, true},               // one final scope is enough
		{"media=failed", map[string][]string{"media": {"shrink"}}, false},                      // not a refusal at all
		{"de=refused", map[string][]string{"media": {"shrink"}}, false},                        // the reason is another scope's
		{"", map[string][]string{"de": {"shrink"}}, false},                                     // roamd named nothing
		{"de=timeout,vault=refused", map[string][]string{"vault": {"unreadable-head"}}, false}, // retry says retry
	} {
		if got := logoffRefusalFinal(c.parts, c.reasons); got != c.want {
			t.Errorf("logoffRefusalFinal(%q, %v) = %v, want %v", c.parts, c.reasons, got, c.want)
		}
	}
}

// ---- each guard names itself, driven through the real pushProfile ----

func TestPushGuard_NoReceiptNamesItself(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "euwhy", "receipt horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	big := make([]byte, 2<<20)
	if _, err := rand.Read(big); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "one.bin"), big, 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if sealRefused {
		t.Fatal("fixture: the first seal was refused")
	}
	os.RemoveAll(restoreReceiptDir()) // a session that never completed the restore
	src2 := t.TempDir()
	if err := os.WriteFile(filepath.Join(src2, "two.txt"), []byte("partial session"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src2)
	if !sealRefused || sealRefusedWhy != "no-receipt" {
		t.Fatalf("refused=%v why=%q, want the #72 keystone to name itself no-receipt", sealRefused, sealRefusedWhy)
	}
}

func TestPushGuard_UnreadableHeadNamesItself(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "euwhy#media", "correct horse battery staple"
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "note.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	putHead(base, name, pass, sealedManifestBlob(t, base, deriveKey(name, "river maple stone cloud"), []string{"aa", "bb", "cc", "dd"}))
	pushProfile(base, name, pass, src)
	if !sealRefused || sealRefusedWhy != "unreadable-head" {
		t.Fatalf("refused=%v why=%q, want unreadable-head (a RETRY class)", sealRefused, sealRefusedWhy)
	}
}

func TestPushGuard_ShrinkNamesItself(t *testing.T) {
	a := alignedFixture(t, "euwhyshrink")
	for _, n := range []string{"01", "02", "03", "04", "05", "06", "07", "08", "09", "10",
		"11", "12", "13", "14", "15", "16", "17", "18", "19"} {
		a.rm("DCIM/album/" + n + ".jpg")
	}
	t.Setenv("NOWHERE_CARRY_ESSENTIAL_MEDIA", "0")
	if msg := a.seal("#media"); msg == "" {
		t.Fatal("fixture: the shrink was not refused")
	}
	if sealRefusedWhy != "shrink" {
		t.Fatalf("sealRefusedWhy = %q, want shrink -- the guard on NW-db441ee766cb must name itself", sealRefusedWhy)
	}
}

func TestPushGuard_AppsVanishedNamesItself(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "euwhyapps", "correct horse battery staple"
	createVault(base, name, pass)
	if sealApps(t, base, name, pass, stageApps(t, "com.example.keep", "com.example.aegis")) {
		t.Fatal("fixture: the first #apps seal was refused")
	}
	if !sealApps(t, base, name, pass, stageApps(t, "com.example.keep")) || sealRefusedWhy != "apps-vanished" {
		t.Fatalf("why=%q, want apps-vanished", sealRefusedWhy)
	}
}

func TestPushGuard_AHealthySealNamesNothing(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	base := newHTTPStore(t)
	name, pass := "euwhyok", "correct horse battery staple"
	createVault(base, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	sealRefusedWhy = "shrink" // poison, as a refused scope before it would leave it
	pushProfile(base, name, pass, src)
	if sealRefused || sealRefusedWhy != "" {
		t.Fatalf("refused=%v why=%q after a healthy seal -- the reason must reset with the verdict", sealRefused, sealRefusedWhy)
	}
}

// The guards a cheap fixture cannot reach (the #144 fence at entry, sealBlind, the sequential guard) are pinned in
// the source: every `sealRefused = true` in pushProfile is preceded, inside its block, by a reason.
func TestPushGuard_EveryRefusalInPushProfileNamesAReason(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "pushProfile"))
	set := regexp.MustCompile(`^sealRefusedWhy = "([a-z-]+)"$`)
	found := map[string]int{}
	refusals := 0
	for i, l := range body {
		if !strings.HasPrefix(strings.TrimSpace(l), "sealRefused = true") {
			continue
		}
		refusals++
		why := ""
		for j := i - 1; j >= 0 && j >= i-4; j-- {
			if m := set.FindStringSubmatch(strings.TrimSpace(body[j])); m != nil {
				why = m[1]
				break
			}
		}
		if why == "" {
			t.Errorf("pushProfile line %q sets sealRefused with no sealRefusedWhy just before it -- it would reach "+
				"the daemon as \"unknown\", a RETRY, and a deterministic refusal would never offer the exit", strings.TrimSpace(l))
			continue
		}
		if !refusalReasonFinal(why) && why != "unreadable-head" && why != "aftergate-no-carry" && why != "mounts-unread" &&
			why != "unfetched-unknown" && why != "unfetched-dropped" {
			t.Errorf("reason %q is classed RETRY by accident -- classify it in refusalReasonFinal", why)
		}
		found[why]++
	}
	want := map[string]int{"deleted": 1, "unreadable-head": 1, "blind": 1, "stale-base": 2, "no-receipt": 2, "shrink": 2, "apps-vanished": 1,
		"mounts-unread": 1, "locks-changed": 1, "locks-changed-key": 1, "unlock-lost": 1, "unlock-lost-key": 1,
		"unfetched-unknown": 1, "unfetched-dropped": 2, "aftergate-no-carry": 1}
	if refusals != 19 {
		t.Errorf("pushProfile has %d refusal sites, want 19 -- a new guard needs a reason and a class", refusals)
	}
	for k, n := range want {
		if found[k] != n {
			t.Errorf("reason %q set at %d site(s), want %d (found %v)", k, found[k], n, found)
		}
	}
}

// ---- the stash: the bridge from the seal process to the daemon ----

func TestRefusalStash_CarriesTheScopeNeverTheProfile(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	stashRefusalReasons("alice#de", []string{"shrink"})
	stashRefusalReasons("alice", []string{"stale"})
	stashRefusalReasons("alice#de", []string{"shrink"}) // a second push of the scope says it once
	raw, err := os.ReadFile(filepath.Join(st, refusalReasonsFile))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), "alice") {
		t.Fatalf("the stash carries the profile name: %q", raw)
	}
	// a damaged line can lose certainty, never inject a reason
	f, _ := os.OpenFile(filepath.Join(st, refusalReasonsFile), os.O_WRONLY|os.O_APPEND, 0o600)
	f.WriteString("de shrink extra\nmedia SHRINK\nmedia\n")
	f.Close()
	got := takeRefusalReasons()
	if strings.Join(got["de"], "+") != "shrink" || strings.Join(got["vault"], "+") != "stale" || len(got) != 2 {
		t.Fatalf("takeRefusalReasons = %v, want de=[shrink] vault=[stale] only", got)
	}
	if _, err := os.Stat(filepath.Join(st, refusalReasonsFile)); !os.IsNotExist(err) {
		t.Error("the stash survived being taken -- the next verdict would inherit it")
	}
}

// ---- the daemon's per-scope save times ----

func TestNoteScopesSaved_OnlyRoamdsSealVerbsAndOnlyUnnamedScopes(t *testing.T) {
	resetScopeSavedAt()
	t.Cleanup(resetScopeSavedAt)
	noteScopesSaved("OK", 100)
	noteScopesSaved("ERR-REFUSED PARTIAL:de=refused,apps=refused", 200)
	noteScopesSaved("ERR-TIMEOUT", 300) // says nothing about any scope
	noteScopesSaved("SKIP-REAPING", 300)
	noteScopesSaved("BUSY", 300)
	got := scopeSavedSnapshot()
	for s, want := range map[string]int64{"vault": 200, "de": 100, "media": 200, "sys": 200, "apps": 100} {
		if got[s] != want {
			t.Errorf("scope %s saved at %d, want %d (all %v)", s, got[s], want, got)
		}
	}
	noteScopesSaved("OK PARTIAL:sys=pending-placement", 500) // benign: sealPartsOf drops it, so sys counts as saved
	noteScopesSaved("ERR-PUSH PARTIAL:vault=failed", 600)
	if got := scopeSavedSnapshot(); got["vault"] != 500 || got["de"] != 600 || got["sys"] != 600 {
		t.Errorf("after OK(benign sys) then ERR-PUSH naming vault: %v", got)
	}
}

// ---- END-UNSAVED ----

type euFixture struct {
	t          *testing.T
	dest       string
	name, pass string
	wallets    int
	walletEr   error
	sweeps     int
	sweepReply string
	fallbacks  []string
	deleted    bool // what the store says about the profile (logoffProfileDeleted)
	storeAsks  atomic.Int32
	kicks      int
	rebootMu   sync.Mutex
	reboots    []string
	watch      chan struct{} // closed to end RESTART-UNSAVED's watchdog wait
	dropMu     sync.Mutex
	drops      []euDrop      // every endUnsavedWalletDrop call (NWP-20261021-01)
	dropDone   chan struct{} // closed by the first one
	dropOnce   sync.Once
}

// euDrop is one endUnsavedWalletDrop call: its arguments, with the se as hex, and the reap queue as the call saw it.
type euDrop struct{ dest, name, pass, gen, uid, se, sw, rp string }

// euDropGrace bounds how long euSetup's cleanup waits for a drop goroutine a committed test left behind, so the
// goroutine reads the seam before the cleanup puts the real one back.
const euDropGrace = 500 * time.Millisecond

const euUID = "10"

// euSetup is a live roamed session "alice" on user 10, asked about by its own chooser, with every global the
// verb reads put back afterwards. The wallet, the media sweep, the reboot backstop and the store's deletion answer
// are stubbed and counted; nothing here can reach a store, a worker or a reboot.
func euSetup(t *testing.T) *euFixture { return euSetupAs(t, t.TempDir(), "alice", "pw") }

// euSetupAs is euSetup for a session of (name, pass) whose state dir is dest: the wallet integration cases run it on
// walletFailSetup's store.
func euSetupAs(t *testing.T, dest, name, pass string) *euFixture {
	t.Helper()
	f := &euFixture{t: t, dest: dest, name: name, pass: pass, sweepReply: "OK", dropDone: make(chan struct{})}
	t.Setenv("NOWHERE_STATE", f.dest)
	if err := markRoamSession(f.dest, f.name, f.pass, euUID, ""); err != nil {
		t.Fatal(err)
	}
	ropReapReset(t)
	oldPeer, oldWallet, oldWait := sessionPeerUID, endUnsavedWallet, endUnsavedSlotWait
	oldSweep, oldFallback, oldDel := endUnsavedSweep, endUnsavedFallback, logoffProfileDeleted
	oldSweepBy, oldCommitBy := endUnsavedSweepBy, endUnsavedCommitBy
	oldKick, oldReboot, oldWait2 := endUnsavedKickMediad, restartUnsavedReboot, restartUnsavedWait
	oldRestartNotice, oldDrop := restartCreditLostPath, endUnsavedWalletDrop
	restartCreditLostPath = filepath.Join(t.TempDir(), "restart-credit-lost") // NWP-20261016-47: never /data/nowhere
	f.watch = make(chan struct{})
	restartUnsavedWait = func() { <-f.watch }
	sessionPeerUID = func(net.Conn) int { return 10*100000 + 10123 }
	endUnsavedWallet = func(dest, name, pass string, se []byte, gen string) error {
		f.wallets++
		if name != f.name || pass != f.pass || dest != f.dest {
			t.Errorf("wallet saved for (%q, %q, %q)", dest, name, pass)
		}
		return f.walletEr
	}
	// Never calls t.*: it can run after its test has returned.
	endUnsavedWalletDrop = func(dest, name, pass string, se []byte, gen, uid string) (bool, error) {
		pendingReapMu.Lock()
		sw, rp := pendingSwitchUID, pendingReapUID
		pendingReapMu.Unlock()
		f.dropMu.Lock()
		f.drops = append(f.drops, euDrop{dest, name, pass, gen, uid, hex.EncodeToString(se), sw, rp})
		f.dropMu.Unlock()
		f.dropOnce.Do(func() { close(f.dropDone) })
		return true, nil
	}
	endUnsavedSweep = func(dest, name, pass, uid string) string {
		f.sweeps++
		if !isLocalSession(dest) {
			t.Error("the media sweep ran before the session was marked local -- a periodic seal's kick could re-mount")
		}
		if f.sweepReply == "OK" {
			os.WriteFile(filepath.Join(dest, ".btlogoff"), nil, 0o600) // what a verified sweepmedia leaves
		}
		return f.sweepReply
	}
	endUnsavedFallback = func(uid string) { f.fallbacks = append(f.fallbacks, uid) }
	logoffProfileDeleted = func(name, pass string) bool { f.storeAsks.Add(1); return f.deleted }
	endUnsavedKickMediad = func(string) { f.kicks++ }
	restartUnsavedReboot = func(uid string) { f.rebootMu.Lock(); f.reboots = append(f.reboots, uid); f.rebootMu.Unlock() }
	endUnsavedSlotWait = 200 * time.Millisecond
	t.Cleanup(func() {
		pendingReapMu.Lock()
		committed := pendingReapUID == euUID
		pendingReapMu.Unlock()
		if committed { // a drop goroutine may still be starting: let it read the seam before it is put back
			select {
			case <-f.dropDone:
			case <-time.After(euDropGrace):
			}
		}
		endUnsavedWalletDrop = oldDrop
		sessionPeerUID, endUnsavedWallet, endUnsavedSlotWait = oldPeer, oldWallet, oldWait
		endUnsavedSweep, endUnsavedFallback, logoffProfileDeleted = oldSweep, oldFallback, oldDel
		endUnsavedSweepBy, endUnsavedCommitBy = oldSweepBy, oldCommitBy
		f.endWatchdog()       // a restart that "did not happen" gives the RW slot back before the next test needs it
		waitRestartReboots(t) // and no reboot goroutine outlives this test, to call the next test's hook (round 7)
		endUnsavedKickMediad, restartUnsavedReboot, restartUnsavedWait = oldKick, oldReboot, oldWait2
		resetMediaStuck()
		resetRestartState()
		disarmLogoffRefusal()
		pendingReapMu.Lock()
		sealInFlight, sealRunKind, pendingLockUID = false, "", ""
		pendingReapMu.Unlock()
		coldLockMu.Lock()
		coldLockRunning = false
		coldLockMu.Unlock()
		restartCreditLostPath = oldRestartNotice // last: the watchdog's give-back above may still take its notice back
	})
	// roamd's `out` wrote the keystore-push stash for this session
	if err := os.WriteFile(filepath.Join(f.dest, ksLogoffCredsFile), []byte(f.name+"\n"+f.pass+"\n10\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

// refuse records a refused sign-out for the live session the way handleLogout does: the seal process stashes
// its guards, roamd answers the verdict, noteLogoffRefusal records it and logoffSealFailed's recordSeal judges the
// same verdict against the same guards (consuming them).
func (f *euFixture) refuse(verdict string, scopeGuards ...string) {
	clearRefusalReasons()
	for _, sg := range scopeGuards {
		s, g, _ := strings.Cut(sg, "=")
		prof := f.name + "#" + s
		if s == "vault" {
			prof = f.name
		}
		stashRefusalReasons(prof, []string{g})
	}
	noteLogoffRefusal(verdict, f.name, f.pass, euUID)
	recordSeal(verdict)
}

// dropCalls is every endUnsavedWalletDrop call so far.
func (f *euFixture) dropCalls() []euDrop {
	f.dropMu.Lock()
	defer f.dropMu.Unlock()
	return append([]euDrop(nil), f.drops...)
}

// waitDrop waits, bounded, for the drop goroutine to call the seam.
func (f *euFixture) waitDrop(t *testing.T, d time.Duration) {
	t.Helper()
	select {
	case <-f.dropDone:
	case <-time.After(d):
		t.Fatal("the saved wallet was never handed to the drop step")
	}
}

// noDrop asserts the drop step is not called. ropReply returns only once the handler has, so the goSafe would
// already have been issued; the wait is for the goroutine to reach the seam.
func (f *euFixture) noDrop(t *testing.T, why string) {
	t.Helper()
	select {
	case <-f.dropDone:
		t.Errorf("%s: the wallet was taken out of the state tmpfs (%d call(s))", why, len(f.dropCalls()))
	case <-time.After(300 * time.Millisecond):
	}
}

// waitDeletion waits for the store's background answer on the refusal on record (noteLogoffRefusal asks off the
// FAILED path, on a goroutine).
func (f *euFixture) waitDeletion(t *testing.T) {
	t.Helper()
	r := currentLogoffRefusal()
	if r == nil {
		t.Fatal("no refusal on record")
	}
	for i := 0; i < 200; i++ {
		if _, known := r.deletion(); known {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the store's deletion answer never arrived")
}

func (f *euFixture) end() string {
	return ropReply(f.t, func(c net.Conn) { handleEndUnsaved(c, f.dest) })
}

// untouched asserts END-UNSAVED changed nothing: the session is live, roamed, still stashes its keystore creds,
// and no teardown is queued.
func (f *euFixture) untouched(why string) {
	f.t.Helper()
	if !roamSessionExists(f.dest) || isLocalSession(f.dest) {
		f.t.Errorf("%s: the session marker changed", why)
	}
	if _, err := os.Stat(filepath.Join(f.dest, ksLogoffCredsFile)); err != nil {
		f.t.Errorf("%s: the keystore-push stash was removed", why)
	}
	pendingReapMu.Lock()
	q := pendingReapUID + pendingSwitchUID
	pendingReapMu.Unlock()
	if q != "" {
		f.t.Errorf("%s: a teardown was queued", why)
	}
}

func TestEndUnsaved_RefusedWithNoRefusalOnRecord(t *testing.T) {
	f := euSetup(t)
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED -- nothing was refused, so nothing licenses discarding the session", got)
	}
	f.untouched("no refusal")
	if f.wallets != 0 {
		t.Error("the wallet was published for a request that was refused")
	}
}

func TestEndUnsaved_RefusedAfterATransientRefusal(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=stale")
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED -- a stale-publish refusal clears on a retry", got)
	}
	f.untouched("transient refusal")
}

func TestEndUnsaved_RefusedWhenTheAgentNamedNoGuard(t *testing.T) {
	// An agent older than the stash (or a lost stash line): roamd still says refused, but nothing says which
	// guard. That must read as RETRY.
	f := euSetup(t)
	noteLogoffRefusal("ERR-REFUSED PARTIAL:de=refused", "alice", "pw", euUID)
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED", got)
	}
	f.untouched("unnamed guard")
}

func TestEndUnsaved_RefusedForALocalSession(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink") // armed, so only the LOCAL gate can refuse
	markLocalSession(f.dest)
	if got := f.end(); got != "ERR-LOCAL" {
		t.Fatalf("got %q, want ERR-LOCAL -- a throwaway's ordinary sign-out already discards it", got)
	}
	pendingReapMu.Lock()
	q := pendingReapUID
	pendingReapMu.Unlock()
	if q != "" || !roamSessionExists(f.dest) {
		t.Error("a LOCAL session was torn down by END-UNSAVED")
	}
}

func TestEndUnsaved_RefusedFromAnotherUsersChooser(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	for _, puid := range []int{11*100000 + 10123, 10123, 0, -1} {
		sessionPeerUID = func(net.Conn) int { return puid }
		if got := f.end(); got != "NONE" {
			t.Errorf("peer uid %d: got %q, want NONE", puid, got)
		}
	}
	f.untouched("wrong caller")
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); got != "NONE" {
		t.Errorf("GET-LOGOFF-REFUSAL to another user = %q, want NONE", got)
	}
}

func TestEndUnsaved_RefusedForAnotherSession(t *testing.T) {
	f := euSetup(t)
	for _, who := range [][2]string{{"alice", "12"}, {"bob", euUID}} { // another user id; another profile, same uid
		stashRefusalReasons(who[0]+"#de", []string{"shrink"})
		noteLogoffRefusal("ERR-REFUSED PARTIAL:de=refused", who[0], "pw", who[1])
		if currentLogoffRefusal() == nil || !currentLogoffRefusal().final {
			t.Fatal("fixture: the foreign refusal was not recorded as final")
		}
		if got := f.end(); got != "ERR-NOTREFUSED" {
			t.Fatalf("%v: got %q, want ERR-NOTREFUSED -- another session's refusal must not end this one", who, got)
		}
	}
	f.untouched("another session")
	// A NEW session on the same uid starts disarmed (markRoamSession -> resetSealStatus).
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	if err := markRoamSession(f.dest, "alice", "pw", euUID, ""); err != nil {
		t.Fatal(err)
	}
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("after a new session started: got %q, want ERR-NOTREFUSED", got)
	}
}

// REVIEW 1: the licence lives only while its premise does. Every later seal re-tests it (reviewLogoffRefusal).
func TestEndUnsaved_ALaterSealThatNoLongerRefusesTheScopeWithdrawsTheLicence(t *testing.T) {
	for _, c := range []struct {
		name    string
		verdict string
		guards  []string // "<scope>=<guard>" the later seal's pushes named
		keep    bool
	}{
		// The review's probe: #de and the vault sealed, #media failed on the network. A retry would save #media.
		{"de sealed, media failed", "ERR-PUSH PARTIAL:media=failed", nil, false},
		{"everything landed", "OK", nil, false},
		{"de refused again, only transiently", "ERR-REFUSED PARTIAL:de=refused", []string{"de=stale"}, false},
		{"de refused again, no guard named", "ERR-REFUSED PARTIAL:de=refused", nil, false},
		{"de refused again for the same final reason", "ERR-REFUSED PARTIAL:de=refused", []string{"de=shrink"}, true},
		{"de still final, media failed beside it", "ERR-REFUSED PARTIAL:de=refused,media=failed", []string{"de=shrink"}, true},
		{"a seal that timed out says nothing it can stand behind", "ERR-TIMEOUT", nil, false},
		{"a skipped cycle ran no seal", "SKIP-SUPERSEDED", nil, true},
		{"a busy slot ran no seal", workerBusy, nil, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := euSetup(t)
			f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink") // NW-db441ee766cb
			if currentLogoffRefusal() == nil {
				t.Fatal("fixture: the refusal did not survive its own verdict")
			}
			clearRefusalReasons()
			for _, sg := range c.guards {
				s, g, _ := strings.Cut(sg, "=")
				stashRefusalReasons("alice#"+s, []string{g})
			}
			recordSeal(c.verdict) // a periodic seal answering later
			if kept := currentLogoffRefusal() != nil; kept != c.keep {
				t.Fatalf("after %q the licence is kept=%v, want %v", c.verdict, kept, c.keep)
			}
			want := "ERR-NOTREFUSED"
			if c.keep {
				want = "OK"
			}
			if got := f.end(); got != want {
				t.Errorf("END-UNSAVED after %q = %q, want %q", c.verdict, got, want)
			}
		})
	}
}

// The logoff's own verdict must not withdraw the licence it just granted: noteLogoffRefusal PEEKS at the guards and
// the recordSeal inside logoffSealFailed consumes them for the very same verdict.
func TestEndUnsaved_TheRefusingLogoffKeepsItsOwnLicence(t *testing.T) {
	f := euSetup(t)
	clearRefusalReasons()
	stashRefusalReasons("alice#de", []string{"shrink"})
	const out = "ERR-REFUSED PARTIAL:de=refused"
	noteLogoffRefusal(out, "alice", "pw", euUID)
	logoffSealFailed(out)
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealFail, sealFailWhy = false, ""
		pendingReapMu.Unlock()
	})
	if currentLogoffRefusal() == nil {
		t.Fatal("logoffSealFailed withdrew the licence noteLogoffRefusal had just recorded")
	}
	if _, err := os.Stat(filepath.Join(f.dest, refusalReasonsFile)); !os.IsNotExist(err) {
		t.Error("the guard stash outlived the verdict that named it")
	}
}

// REVIEW 2: a guard's token is not a delete. Only the STORE decides, and when it says no the wallet is saved and
// nothing claims the profile is gone.
func TestEndUnsaved_DeletionIsTheStoresToSay(t *testing.T) {
	t.Run("the fence alone is a retry, not a licence", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:media=refused", "media=fence") // the review's probe
		if got := f.end(); got != "ERR-NOTREFUSED" {
			t.Fatalf("got %q, want ERR-NOTREFUSED -- a fence that moved mid-push clears on a retry", got)
		}
		if f.wallets != 0 {
			t.Error("the wallet was touched for a refused request")
		}
	})
	t.Run("deleted token, live profile: the wallet is saved and nothing says deleted", func(t *testing.T) {
		f := euSetup(t)
		f.deleted = false
		f.refuse("ERR-REFUSED PARTIAL:de=refused,media=refused", "de=shrink", "media=deleted")
		f.waitDeletion(t)
		if n := f.storeAsks.Load(); n != 1 {
			t.Errorf("the store was asked %d times, want once", n)
		}
		if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); strings.Contains(got, "DELETED") {
			t.Errorf("GET-LOGOFF-REFUSAL says DELETED for a live profile: %q", got)
		}
		if got := f.end(); got != "OK" || f.wallets != 1 {
			t.Fatalf("got %q with %d wallet save(s), want OK with 1 -- never skip the wallet on a token", got, f.wallets)
		}
	})
	t.Run("deleted token, and the store agrees: no wallet head to save, DELETED on the wire", func(t *testing.T) {
		f := euSetup(t)
		f.deleted = true
		f.walletEr = errors.New("would publish into a deleted profile")
		f.refuse("ERR-REFUSED PARTIAL:vault=refused,de=refused", "vault=deleted", "de=deleted")
		f.waitDeletion(t)
		if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); !strings.HasSuffix(got, "\nDELETED") {
			t.Errorf("GET-LOGOFF-REFUSAL = %q, want a DELETED line", got)
		}
		if got := f.end(); got != "OK" || f.wallets != 0 {
			t.Fatalf("got %q with %d wallet save(s), want OK with none", got, f.wallets)
		}
	})
	t.Run("no deletion token: the store is not asked", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		if n := f.storeAsks.Load(); n != 0 {
			t.Errorf("the store was asked %d times for a refusal that named no delete", n)
		}
	})
}

// REVIEW 3: no teardown over a media mount. The sweep runs, verified, after the session is marked local and before
// anything is queued; a sweep that leaves a mount keeps the session.
func TestEndUnsaved_AnUnverifiedMediaSweepKeepsTheSession(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	f.sweepReply = "ERR-MEDIA-SWEEP 1"
	if got := f.end(); got != "ERR-MEDIA" {
		t.Fatalf("got %q, want ERR-MEDIA", got)
	}
	if f.sweeps != 1 {
		t.Errorf("swept %d times, want 1", f.sweeps)
	}
	if !roamSessionExists(f.dest) || isLocalSession(f.dest) {
		t.Error("the session was not restored after the sweep failed -- it would be left local, unsealed by the periodic seal")
	}
	pendingReapMu.Lock()
	q := pendingReapUID + pendingSwitchUID
	pendingReapMu.Unlock()
	if q != "" || len(f.fallbacks) != 0 {
		t.Error("a teardown was queued over a media mount")
	}
	if currentLogoffRefusal() == nil {
		t.Error("ERR-MEDIA consumed the refusal; the user could not try again")
	}
	// A retry once the mount is gone goes through.
	f.sweepReply = "OK"
	if got := f.end(); got != "OK" {
		t.Fatalf("retry after the mount cleared: %q, want OK", got)
	}
}

// REVIEW 6: the daemon never tears down after the chooser gave up. Past either budget it undoes and answers ERR-SLOW.
func TestEndUnsaved_TheTimeBudgetIsCheckedBeforeEachIrreversibleStep(t *testing.T) {
	t.Run("spent before the sweep: nothing changes", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		endUnsavedSweepBy = -time.Second
		if got := f.end(); got != "ERR-SLOW" {
			t.Fatalf("got %q, want ERR-SLOW", got)
		}
		f.untouched("budget spent before the sweep")
		if f.sweeps != 0 || f.wallets != 1 || currentLogoffRefusal() == nil {
			t.Errorf("sweeps=%d wallets=%d armed=%v, want 0, 1 (the save stands), true", f.sweeps, f.wallets, currentLogoffRefusal() != nil)
		}
	})
	t.Run("spent by the end of the sweep: undone, nothing queued", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		endUnsavedCommitBy = -time.Second
		if got := f.end(); got != "ERR-SLOW" {
			t.Fatalf("got %q, want ERR-SLOW", got)
		}
		if !roamSessionExists(f.dest) || isLocalSession(f.dest) {
			t.Error("the session was left local after the budget ran out")
		}
		if _, err := os.Stat(filepath.Join(f.dest, ".btlogoff")); !os.IsNotExist(err) {
			t.Error("the verified sweep's #154 marker survived -- the next periodic seal would wipe a live user's Bluetooth")
		}
		pendingReapMu.Lock()
		q := pendingReapUID + pendingSwitchUID
		pendingReapMu.Unlock()
		if q != "" || len(f.fallbacks) != 0 || currentLogoffRefusal() == nil {
			t.Errorf("queued=%q fallbacks=%v armed=%v after ERR-SLOW", q, f.fallbacks, currentLogoffRefusal() != nil)
		}
	})
	t.Run("the budget nests inside the socket deadline and the chooser's read", func(t *testing.T) {
		if !(endUnsavedSweepBy < endUnsavedCommitBy && endUnsavedCommitBy < endUnsavedDeadline && endUnsavedDeadline < 90*time.Second) {
			t.Errorf("sweepBy %v, commitBy %v, deadline %v: must nest inside the chooser's 90 s read", endUnsavedSweepBy,
				endUnsavedCommitBy, endUnsavedDeadline)
		}
		prof := chooserCode(t, "ProfileActivity.java")
		if !strings.Contains(prof, "s.setSoTimeout(90000);") || !strings.Contains(prof, `sendDaemon("END-UNSAVED\n")`) {
			t.Error("the chooser no longer reads END-UNSAVED through sendDaemon's 90 s timeout")
		}
	})
}

// REVIEW 9: every arm of endUnsavedBlocked refuses, untouched.
func TestEndUnsaved_BusyWhileSomethingElseEndsTheSession(t *testing.T) {
	for _, c := range []struct {
		name string
		set  func() func()
	}{
		{"a teardown is queued", func() func() {
			pendingReapMu.Lock()
			pendingLockUID = euUID
			pendingReapMu.Unlock()
			return func() {}
		}},
		{"this session's sign-out is still running", func() func() {
			seq := setLogoffInFlight(euUID)
			return func() { clearLogoffInFlight(euUID, seq) }
		}},
		{"a cold lock is running", func() func() {
			coldLockMu.Lock()
			coldLockRunning = true
			coldLockMu.Unlock()
			return func() {}
		}},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := euSetup(t)
			f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
			done := c.set()
			got := f.end()
			done()
			if got != "BUSY teardown" {
				t.Fatalf("got %q, want BUSY teardown", got)
			}
			f.untouched(c.name)
			if f.wallets != 0 || f.sweeps != 0 {
				t.Errorf("wallets=%d sweeps=%d for a request that was refused", f.wallets, f.sweeps)
			}
		})
	}
}

// REVIEW 4: the blind package list survives the later pushes of the same `out`, and adds up across them.
func TestSealBlindPkgs_SurviveTheLaterPushesOfTheSameOut(t *testing.T) {
	st := t.TempDir()
	t.Setenv("NOWHERE_STATE", st)
	// A data scope's push was refused blind and published its app...
	resetSealBlindPkgs()
	sealBlindPkgMu.Lock()
	sealBlindPkgSet["com.example.tesla"] = true
	sealBlindPkgMu.Unlock()
	publishSealBlindPkgs()
	// ...then a later push in the same `out` (here a healthy one) runs, as #sys and #apps do.
	base := newHTTPStore(t)
	createVault(base, "blindkeep", "correct horse battery staple")
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "a.txt"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, "blindkeep#sys", "correct horse battery staple", src)
	// ...and a second blind scope adds to it rather than replacing it.
	sealBlindPkgMu.Lock()
	sealBlindPkgSet["com.example.ali"] = true
	sealBlindPkgMu.Unlock()
	publishSealBlindPkgs()
	b, err := os.ReadFile(sealBlindPkgPath())
	if err != nil || string(b) != "com.example.ali\ncom.example.tesla\n" {
		t.Fatalf("published list = %q (%v), want both apps -- the chooser asks only after the whole `out`", b, err)
	}
	// The daemon clears it once per `out` and at every session start.
	clearSealBlindPkgs()
	if _, err := os.Stat(sealBlindPkgPath()); !os.IsNotExist(err) {
		t.Error("clearSealBlindPkgs left the list")
	}
}

// REVIEW 5 (daemon half): a logoff whose sweep did not verify seals nothing and says MEDIA, without recording a
// seal verdict -- no seal ran.
func TestLogoffSweepFailed_SaysMediaAndRecordsNoSeal(t *testing.T) {
	sealMu.Lock()
	oldStatus := sealStatus
	sealStatus = "ok"
	sealMu.Unlock()
	pendingReapMu.Lock()
	oldF, oldW, oldI, oldK, oldP := sealFail, sealFailWhy, sealInFlight, sealRunKind, sealPartial
	sealInFlight, sealRunKind, sealPartial = true, "logoff", ""
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		sealMu.Lock()
		sealStatus = oldStatus
		sealMu.Unlock()
		pendingReapMu.Lock()
		sealFail, sealFailWhy, sealInFlight, sealRunKind, sealPartial = oldF, oldW, oldI, oldK, oldP
		pendingReapMu.Unlock()
	})
	logoffSweepFailed("alice", euUID)
	t.Cleanup(resetMediaStuck)
	if mediaStuckCount("alice", euUID) != 1 {
		t.Error("a failed sweep did not count toward RESTART-UNSAVED")
	}
	if got := strings.Join(composeSealStatus(t.TempDir()), "|"); got != "FAILED MEDIA" {
		t.Errorf("SEAL-STATUS = %q, want FAILED MEDIA (an older chooser reads FAILED)", got)
	}
	if sealStatusGet() != "ok" {
		t.Errorf("sealStatus = %q -- a sweep failure is not a seal verdict and must not overwrite the last one", sealStatusGet())
	}
}

func TestEndUnsaved_BusyWhileASealIsAnnounced(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	for _, set := range []func(){
		func() { sealRunKind = "periodic" },
		func() { sealInFlight = true },
	} {
		pendingReapMu.Lock()
		sealInFlight, sealRunKind = false, ""
		set()
		pendingReapMu.Unlock()
		if got := f.end(); got != "BUSY seal" {
			t.Errorf("got %q, want BUSY seal while a seal is announced", got)
		}
	}
	f.untouched("seal announced")
	if f.wallets != 0 {
		t.Error("the wallet was published while a seal was running")
	}
}

func TestEndUnsaved_BusyWhileTheWorkerSlotIsHeld(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	laneRW.slot <- struct{}{} // a seal holds the slot
	got := f.end()
	<-laneRW.slot
	if got != "BUSY slot" {
		t.Fatalf("got %q, want BUSY slot -- the slot is what proves no seal is running", got)
	}
	f.untouched("slot held")
	if currentLogoffRefusal() == nil {
		t.Error("a BUSY answer consumed the refusal")
	}
}

func TestEndUnsaved_AWalletThatCannotBeSavedKeepsTheSession(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	f.walletEr = errors.New("store unreachable")
	if got := f.end(); got != "ERR-WALLET" {
		t.Fatalf("got %q, want ERR-WALLET -- bearer tokens in the tmpfs must not die with the session", got)
	}
	f.untouched("wallet failed")
	if currentLogoffRefusal() == nil {
		t.Error("ERR-WALLET consumed the refusal; the user could not try again")
	}
}

// The wallet publish takes seconds, and a periodic seal can LAND in them. Under the slot the verb re-checks, so a
// refusal that a landed seal disproved cannot end the session after all.
func TestEndUnsaved_RecheckUnderSlotCatchesASealThatLandedMeanwhile(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	endUnsavedWallet = func(dest, name, pass string, se []byte, gen string) error {
		f.wallets++
		recordSeal("OK") // a periodic seal landed while the wallet was being saved
		return nil
	}
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED -- the refusal was disproved before the session was touched", got)
	}
	f.untouched("seal landed during the wallet publish")
}

func TestEndUnsaved_AcceptedAfterAFinalRefusal_ReapsWithoutASealOrAKeysPush(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink") // NW-db441ee766cb
	if got := f.end(); got != "OK" {
		t.Fatalf("got %q, want OK", got)
	}
	if roamSessionExists(f.dest) || isLocalSession(f.dest) {
		t.Error("the session markers survived -- the periodic seal would keep sealing a session being reaped")
	}
	pendingReapMu.Lock()
	sw, rp := pendingSwitchUID, pendingReapUID
	pendingReapMu.Unlock()
	if sw != euUID || rp != euUID {
		t.Errorf("switch/reap queued for %q/%q, want %s/%s", sw, rp, euUID, euUID)
	}
	// #keys: the stash cleanstorage would adopt to push this session's keystore dump is gone.
	if _, err := os.Stat(filepath.Join(f.dest, ksLogoffCredsFile)); !os.IsNotExist(err) {
		t.Error("the keystore-push stash survived: the reap would seal THIS session's keys over the stored #keys")
	}
	// No seal: no worker op was dispatched at all (every seal is an `out` through roam.req; the sweep is stubbed).
	for _, lane := range []string{laneRW.req, laneRO.req, laneCred.req} {
		if _, err := os.Stat(filepath.Join(f.dest, lane)); err == nil {
			t.Errorf("a worker request (%s) was written -- END-UNSAVED must dispatch no seal", lane)
		}
	}
	if f.wallets != 1 {
		t.Errorf("the wallet was published %d times, want exactly 1 (before the session ended)", f.wallets)
	}
	if f.sweeps != 1 {
		t.Errorf("the media sweep ran %d times, want exactly 1 -- the reap must not delete through a mount", f.sweeps)
	}
	if len(f.fallbacks) != 1 || f.fallbacks[0] != euUID {
		t.Errorf("reboot backstop armed for %v, want [%s] -- a reap nobody performs must not leave the user's plaintext", f.fallbacks, euUID)
	}
	if currentLogoffRefusal() != nil {
		t.Error("the refusal was not consumed")
	}
	select { // the slot was released
	case laneRW.slot <- struct{}{}:
		<-laneRW.slot
	default:
		t.Error("END-UNSAVED left the RW worker slot held -- every later seal and login would wedge")
	}
}

// NWP-20261021-01: an END-UNSAVED whose wallet save landed starts the landed sign-out's publish-and-drop step once the
// reap is queued, and every other way out keeps wallet.json. The stub (euSetup) records the call; the real step is
// driven in end_unsaved_wallet_test.go.
func TestEndUnsaved_ASavedWalletLeavesTheStateTmpfsAfterTheCommit(t *testing.T) {
	f := euSetup(t)
	tr := trackGoSafe(t) // NWP-20261128-14: the wallet job's own lines are written before captureStderr restores
	const se = "a1b2c3d4e5f6"
	if err := markRoamSession(f.dest, "alice", "pw", euUID, se); err != nil {
		t.Fatal(err)
	}
	wp := walletPathFor(f.dest)
	if err := os.WriteFile(wp, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := bumpWalletGeneration(wp); err != nil {
		t.Fatal(err)
	}
	wantGen := walletGeneration(wp) // what the handler reads BEFORE the session
	if wantGen == "" {
		t.Fatal("the fixture's wallet has no generation")
	}
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	var got string
	log := captureStderr(t, func() { got = f.end(); tr.wait(t, 5*time.Second) })
	if got != "OK" {
		t.Fatalf("got %q, want OK", got)
	}
	f.waitDrop(t, 5*time.Second)
	time.Sleep(100 * time.Millisecond) // a second call would have landed by now
	calls := f.dropCalls()
	if len(calls) != 1 {
		t.Fatalf("the drop step ran %d times, want exactly once: %+v", len(calls), calls)
	}
	want := euDrop{dest: f.dest, name: "alice", pass: "pw", gen: wantGen, uid: euUID, se: se, sw: euUID, rp: euUID}
	if calls[0] != want {
		t.Errorf("drop called with %+v, want %+v -- the reap must be queued and the session's own se and pre-session generation passed", calls[0], want)
	}
	if !strings.Contains(log, "end-unsaved user 10: the saved wallet now leaves the state tmpfs") {
		t.Errorf("no log line for the drop; stderr:\n%s", log)
	}
	for _, line := range strings.Split(log, "\n") { // handleLogout's own line names the profile; the new one must not
		if !strings.Contains(line, "NWP-20261021-01") {
			continue
		}
		for _, leak := range []string{"alice", "pw", se} {
			if strings.Contains(line, leak) {
				t.Errorf("the new log line leaks %q: %s", leak, line)
			}
		}
	}
}

func TestEndUnsaved_CreditLostKeepsTheWallet(t *testing.T) {
	f := euSetup(t)
	f.walletEr = fmt.Errorf("%w (test)", errWalletNotRestored)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	if got := f.end(); got != endUnsavedCreditLost {
		t.Fatalf("got %q, want %s", got, endUnsavedCreditLost)
	}
	f.noDrop(t, "the session never read its stored wallet, so the file is the only copy of what it held")
}

func TestEndUnsaved_ADeletedProfileKeepsTheWallet(t *testing.T) {
	f := euSetup(t)
	f.deleted = true
	f.refuse("ERR-REFUSED PARTIAL:vault=refused,de=refused", "vault=deleted", "de=deleted")
	f.waitDeletion(t)
	if got := f.end(); got != "OK" || f.wallets != 0 {
		t.Fatalf("got %q with %d wallet save(s), want OK with none", got, f.wallets)
	}
	f.noDrop(t, "nothing was saved, so there is no head to publish to")
}

func TestEndUnsaved_AKeptSessionKeepsItsWallet(t *testing.T) {
	cases := []struct {
		name, reply string
		arrange     func(f *euFixture)
	}{
		{"wallet", "ERR-WALLET", func(f *euFixture) { f.walletEr = errors.New("the store is down") }},
		{"busy", "BUSY seal", func(f *euFixture) {
			pendingReapMu.Lock()
			sealInFlight = true
			pendingReapMu.Unlock()
		}},
		{"media", "ERR-MEDIA", func(f *euFixture) { f.sweepReply = "ERR-MEDIA mount left" }},
		{"slow", "ERR-SLOW", func(f *euFixture) { endUnsavedSweepBy = -time.Second }},
		{"keys", "ERR-KEYS", func(f *euFixture) { nonEmptyKSStash(t, f.dest) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := euSetup(t)
			f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
			c.arrange(f)
			if got := f.end(); got != c.reply {
				t.Fatalf("got %q, want %s", got, c.reply)
			}
			f.noDrop(t, c.reply+" keeps the session")
		})
	}
}

// The handler makes no store write of its own: exactly two store paths are allowed, endUnsavedWallet before the commit
// and endUnsavedWalletDrop after it (NWP-20261021-01), and the drop goes through its seam only.
func TestEndUnsaved_HandlerCallsNoSealOrStoreWriter(t *testing.T) {
	b, err := os.ReadFile("end_unsaved.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "handleEndUnsaved")), "\n")
	for _, bad := range []string{"triggerRoamWorker", "runWorkerHeld", "pushProfile", "putHead", "postBlob", "capFlush", "sealWallet", "sealLogoutWalletAndDrop"} {
		if strings.Contains(body, bad) {
			t.Errorf("handleEndUnsaved calls %s -- it must end the session without writing the store (the wallet goes through endUnsavedWallet)", bad)
		}
	}
	if !strings.Contains(body, "endUnsavedWallet(") || !strings.Contains(body, "handleLogout(reply, dest)") {
		t.Error("handleEndUnsaved no longer saves the wallet first, or no longer ends through handleLogout's throwaway branch")
	}
	// ORDER: marked local, then the verified sweep, then the reap, then the reboot backstop.
	at := func(s string) int { return strings.Index(body, s) }
	mark, sweep, reap, backstop := at("markLocalSession(dest)"), at("endUnsavedSweep(dest, name, pass, uid)"),
		at("handleLogout(reply, dest)"), at("endUnsavedFallback(uid)")
	if mark < 0 || sweep < 0 || reap < 0 || backstop < 0 || !(mark < sweep && sweep < reap && reap < backstop) {
		t.Errorf("order mark %d, sweep %d, reap %d, backstop %d -- want mark < sweep < reap < backstop", mark, sweep, reap, backstop)
	}
	// NWP-20261021-01: the wallet is saved, then the commit, then the drop -- never the drop first, which would take
	// the file out from under a session an abort below keeps -- and only under the walletSaved guard.
	save, drop := at("endUnsavedWallet("), at("endUnsavedWalletDrop(")
	if save < 0 || drop < 0 || !(save < reap && reap < drop) {
		t.Errorf("order save %d, commit %d, drop %d -- want endUnsavedWallet( < handleLogout(reply, dest) < endUnsavedWalletDrop(", save, reap, drop)
	}
	if n := strings.Count(body, "endUnsavedWalletDrop("); n != 1 {
		t.Errorf("endUnsavedWalletDrop( appears %d times, want once", n)
	}
	if g := at("if walletSaved {"); g < 0 || drop < 0 || !(reap < g && g < drop) || strings.Contains(body[g:drop], "}") {
		t.Errorf("the drop is not the first thing under `if walletSaved {` after the commit (guard at %d, drop at %d)", g, drop)
	}
	// The production hooks are the logoff's own sweep (in the held slot) and #86 Fix B.
	src := string(b)
	if !strings.Contains(src, `return runWorkerHeld(laneRW, dest, "sweepmedia", name, pass, uid, "", "", "", "", nil)`) {
		t.Error("endUnsavedSweep no longer runs roamd's sweepmedia inside the held RW slot")
	}
	if !strings.Contains(src, "var endUnsavedWalletDrop = sealLogoutWalletAndDrop\n") {
		t.Error("endUnsavedWalletDrop is no longer the landed sign-out's step")
	}
	if !strings.Contains(src, `var endUnsavedFallback = func(uid string) { goSafe("reap-or-reboot", func() { reapOrReboot(uid) }) }`) {
		t.Error("endUnsavedFallback no longer arms #86 Fix B's reboot backstop")
	}
	if !strings.Contains(src, "\treturn profileDeleted(\"s3\", name, pass)\n") {
		t.Error("logoffProfileDeleted no longer asks the store")
	}
}

// The stash END-UNSAVED removes must be the one roamd writes and cleanstorage adopts, and without it cleanstorage
// must take the credless arm (keys=notsealed: the dump is destroyed, nothing is pushed).
func TestEndUnsaved_KsCredsPathIsRoamds(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Skipf("roamd not readable here: %v", err)
	}
	src := string(b)
	for _, want := range []string{
		`KS_CREDS="$STATE/` + ksLogoffCredsFile + `"`,
		`if { [ -z "$name" ] || [ -z "$pass" ]; } && [ -f "$KS_CREDS" ]; then`,
		"KS_VERDICT=notsealed\n    echo \"[roamd] keystore_push deferred (no creds on this op) $(date)\" >> \"$LOG\"; return 0",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("roamd no longer contains %q -- END-UNSAVED's #keys rule rests on it", want)
		}
	}
	if stateDirDefault != "/data/nowhere/state" || !strings.Contains(src, "\nSTATE=/data/nowhere/state\n") {
		t.Error("the daemon's state dir and roamd's $STATE differ -- the stash removal would miss")
	}
}

// ---- the wire ----

func TestGetLogoffRefusal_Wire(t *testing.T) {
	f := euSetup(t)
	resetScopeSavedAt()
	noteScopesSaved("OK", 1728550000) // 09:10, the last seal that passed
	// Recorded as handleLogout records it, WITHOUT the recordSeal that follows, so the save times stay the fixture's.
	clearRefusalReasons()
	stashRefusalReasons("alice#de", []string{"stale"})
	stashRefusalReasons("alice#de", []string{"shrink"})
	stashRefusalReasons("alice#apps", []string{"apps-vanished"})
	noteLogoffRefusal("ERR-REFUSED PARTIAL:de=refused,apps=refused", "alice", "pw", euUID)
	got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) })
	lines := strings.Split(got, "\n")
	if len(lines) != 4 || !regexp.MustCompile(`^REFUSED FINAL [1-9][0-9]+$`).MatchString(lines[0]) {
		t.Fatalf("reply %q", got)
	}
	if lines[1] != "SCOPE de refused:shrink 1728550000" {
		t.Errorf("line 2 = %q -- the FINAL guard is named even when a retryable one came first", lines[1])
	}
	if lines[2] != "SCOPE apps refused:apps-vanished 1728550000" {
		t.Errorf("line 3 = %q", lines[2])
	}
	if lines[3] != "SAVED 1728550000" {
		t.Errorf("line 4 = %q, want everything roamd did not name saved at 1728550000", lines[3])
	}
	// The times are read when ASKED: the session kept running, and the next periodic seal stored everything but
	// the refused scopes. The refused scopes still say 09:10; everything else moves on.
	noteScopesSaved("ERR-REFUSED PARTIAL:de=refused,apps=refused", 1728551000)
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); !strings.HasSuffix(got,
		"SCOPE de refused:shrink 1728550000\nSCOPE apps refused:apps-vanished 1728550000\nSAVED 1728551000") {
		t.Errorf("after a later periodic seal: %q", got)
	}
	// A scope with no save on record makes SAVED 0: no time the daemon cannot back.
	scopeSavedMu.Lock()
	delete(scopeSavedAt, "vault") // the FIRST scope checked: a 0 there must not be overwritten by a later time
	scopeSavedMu.Unlock()
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); !strings.HasSuffix(got, "\nSAVED 0") {
		t.Errorf("with vault unrecorded: %q, want SAVED 0", got)
	}
	if strings.Contains(got, "alice") {
		t.Error("the reply names the profile")
	}

	// RETRY when no blocking scope has a final guard.
	f.refuse("ERR-REFUSED PARTIAL:media=refused", "media=stale")
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); !strings.HasPrefix(got, "REFUSED RETRY ") ||
		!strings.Contains(got, "\nSCOPE media refused:stale ") {
		t.Errorf("transient reply %q", got)
	}
	// No record at all answers NONE.
	disarmLogoffRefusal()
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); got != "NONE" {
		t.Errorf("with nothing on record: %q, want NONE", got)
	}
}

// BACK-COMPATIBILITY, both ways. The new verbs are additive; nothing an older chooser reads changed shape.
func TestEndUnsaved_WireIsBackCompatible(t *testing.T) {
	// An older chooser reads SEAL-STATUS's first line and splits off field 1. A refused logoff still says exactly
	// "FAILED REFUSED" -- the class rides only the new verb.
	pendingReapMu.Lock()
	oldF, oldW, oldP, oldI, oldK := sealFail, sealFailWhy, sealPartial, sealInFlight, sealRunKind
	sealFail, sealFailWhy, sealPartial, sealInFlight, sealRunKind = true, "ERR-REFUSED PARTIAL:de=refused", "", false, ""
	pendingReapMu.Unlock()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealFail, sealFailWhy, sealPartial, sealInFlight, sealRunKind = oldF, oldW, oldP, oldI, oldK
		pendingReapMu.Unlock()
	})
	if got := strings.Join(composeSealStatus(t.TempDir()), "|"); got != "FAILED REFUSED" {
		t.Errorf("SEAL-STATUS = %q, want FAILED REFUSED byte for byte", got)
	}
	// The verdict an older reader parses is roamd's, which this slice does not touch: the PARTIAL list keeps
	// "scope=cause" and the guard never enters it.
	if got := sealPartsOf("ERR-REFUSED PARTIAL:de=refused"); got != "de=refused" {
		t.Errorf("sealPartsOf = %q", got)
	}
	// The new verbs are routed, lock-free and serialised as intended.
	if !concurrentSafeCmd("GET-LOGOFF-REFUSAL") {
		t.Error("GET-LOGOFF-REFUSAL must run outside sessionMu: it is asked the instant a sign-out is refused")
	}
	if concurrentSafeCmd("END-UNSAVED") {
		t.Error("END-UNSAVED mutates the session and must hold sessionMu")
	}
	if !rekeyHoldingVerb("END-UNSAVED") {
		t.Error("END-UNSAVED opens a wallet bracket with a client waiting, so it must hold the background re-key off")
	}
}

// Through handleLogin: both verbs are dispatched, not swallowed by the legacy login fallthrough (which would block
// for a passphrase line and answer BLANK).
func TestEndUnsaved_VerbsAreDispatched(t *testing.T) {
	f := euSetup(t)
	for verb, want := range map[string]string{"GET-LOGOFF-REFUSAL": "NONE", "END-UNSAVED": "ERR-NOTREFUSED"} {
		cli, srv := net.Pipe()
		go handleLogin(srv, f.dest)
		cli.SetDeadline(time.Now().Add(5 * time.Second))
		if _, err := cli.Write([]byte(verb + "\n")); err != nil {
			t.Fatalf("%s: write: %v", verb, err)
		}
		line, err := bufio.NewReader(cli).ReadString('\n')
		cli.Close()
		if got := strings.TrimSpace(line); err != nil || got != want {
			t.Errorf("%s through handleLogin: %q (%v), want %q", verb, got, err, want)
		}
	}
}

// ---- the wiring a behavioural test cannot reach ----

func TestEndUnsaved_Wiring(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	lo := stripComments(funcBody(t, src, "handleLogout"))
	note, failed, disarm, sealing := -1, -1, -1, -1
	for i, l := range lo {
		s := strings.TrimSpace(l)
		switch {
		case s == "noteLogoffRefusal(out, name, pass, uid)":
			note = i
		case strings.HasPrefix(s, "logoffSealFailed(out)"):
			failed = i
		case strings.HasPrefix(s, "disarmLogoffRefusal()"):
			disarm = i
		case strings.Contains(s, `"[logind] logout %q user %s: sealing in background`):
			sealing = i
		}
	}
	if note < 0 || failed < 0 || note > failed {
		t.Errorf("handleLogout must record the refusal BEFORE logoffSealFailed publishes FAILED (note %d, failed %d): "+
			"the chooser asks the moment it reads FAILED", note, failed)
	}
	_ = sealing
	if disarm >= 0 {
		t.Errorf("handleLogout disarms the licence at line %d -- round 3: a fresh sign-out must leave it for its own verdict "+
			"to replace or withdraw, or a FAILED MEDIA attempt loses an offer the user already had", disarm)
	}
	pv := stripComments(funcBody(t, src, "runWorkerHeld"))
	if !strings.Contains(strings.Join(pv, "\n"), "clearCreditReason()\n\t\tclearRefusalReasons()") {
		t.Error("runWorkerHeld no longer clears the refusal stash beside the credit stash at the start of an `out`")
	}
	rs := strings.Join(stripComments(funcBody(t, src, "resetSealStatus")), "\n")
	for _, c := range []string{"clearRefusalReasons()", "resetScopeSavedAt()", "disarmLogoffRefusal()"} {
		if !strings.Contains(rs, c) {
			t.Errorf("resetSealStatus no longer calls %s -- a new session could inherit the last one's refusal", c)
		}
	}
	rec := strings.Join(stripComments(funcBody(t, src, "recordSealLanded")), "\n")
	if !strings.Contains(rec, "noteScopesSaved(out, time.Now().Unix())") || !strings.Contains(rec, "reviewLogoffRefusal(out, guards)") ||
		!strings.Contains(rec, "guards := takeRefusalReasons()") {
		t.Error("recordSealLanded no longer records scope save times, or no longer re-tests the licence against its own guards")
	}
	// REVIEW 4: the blind list is cleared once per `out` and per session, never per push.
	if !strings.Contains(strings.Join(pv, "\n"), "clearSealBlindPkgs()") || !strings.Contains(rs, "clearSealBlindPkgs()") {
		t.Error("the blind-package list is no longer cleared once per `out` and at every session start")
	}
	if pp := strings.Join(stripComments(funcBody(t, src, "pushProfile")), "\n"); strings.Contains(pp, "os.Remove(sealBlindPkgPath())") {
		t.Error("pushProfile clears the blind-package list again -- the #sys and #apps pushes would wipe a data scope's list")
	}
	// REVIEW 5: the logoff seals only after a VERIFIED sweep; otherwise it keeps the session and says MEDIA.
	lj := strings.Join(lo, "\n")
	sw, run, chk, sf, seal := strings.Index(lj, `swept := logoffSweepWithRetries(uid, logoffClaim, name, func() string {`),
		strings.Index(lj, `return triggerRoamWorker(dest, "sweepmedia", name, pass, uid, "", func(string) {`),
		strings.Index(lj, `if swept != "OK" {`), strings.Index(lj, "logoffSweepFailed(name, uid)"),
		strings.Index(lj, `out := triggerRoamWorkerKind(dest, "out", name, pass, uid, seSecret, outKind,`)
	if sw < 0 || run < 0 || chk < 0 || sf < 0 || seal < 0 || !(sw < run && run < chk && chk < sf && sf < seal) {
		t.Errorf("handleLogout: sweep loop %d, sweep %d, check %d, sweep-failed arm %d, seal %d -- the seal must follow "+
			"a verified sweep", sw, run, chk, sf, seal)
	}
	if ok := strings.Index(lj, "noteMediaSweepOK(name, uid)"); ok < 0 || ok < chk {
		t.Error("handleLogout no longer ends a run of failed sweeps when its own sweep verifies")
	}
	if sealFailSuffix(errMediaSweep) != "MEDIA" {
		t.Error("a sweep failure no longer reaches SEAL-STATUS as FAILED MEDIA")
	}
	// REVIEW 7: the landed logoff and END-UNSAVED share #86 Fix B.
	if !strings.Contains(lj, "reapOrReboot(uid)") {
		t.Error("handleLogout no longer arms reapOrReboot after the seal lands")
	}
	rr := strings.Join(stripComments(funcBody(t, src, "reapOrReboot")), "\n")
	if strings.Count(rr, "rebootNow(") != 2 {
		t.Error("reapOrReboot no longer reboots on BOTH an unconsumed switch and an unconsumed remove")
	}
	if !strings.Contains(src, "stashRefusalReasons(os.Args[3], sealRefusalReasons(sealRefused, sealRefusedWhy, sealFenceHit, sealStaleHit))\n\t\t\tos.Exit(exitSealRefused)") {
		t.Error("the push verb no longer stashes its reasons right before exiting 4")
	}
	if !regexp.MustCompile(`name == "DELETE-BINDING" \|\|[^\n]*\n\t\tname == "END-UNSAVED" \|\| name == "RESTART-UNSAVED" \{`).MatchString(src) {
		t.Error("END-UNSAVED is no longer on the TryLock (BUSY-now) list")
	}
}

// ---- round 3 ----

// R3-1(i): a sign-out whose media sweep fails reaches no verdict, so it must leave the licence the user already had.
func TestEndUnsaved_AFailedMediaSignOutKeepsTheEarlierLicence(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink") // the offer the user had, and chose Stay
	// The second sign-out: handleLogout's sweep arm (logoffSweepFailed, no recordSeal).
	logoffSweepFailed("alice", euUID)
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealFail, sealFailWhy = false, ""
		pendingReapMu.Unlock()
	})
	if currentLogoffRefusal() == nil {
		t.Fatal("a FAILED MEDIA sign-out withdrew the earlier licence")
	}
	// A verdict that is not a refusal does not replace it in noteLogoffRefusal either; recordSeal's review decides.
	noteLogoffRefusal("ERR-PUSH PARTIAL:media=failed", "alice", "pw", euUID)
	if currentLogoffRefusal() == nil {
		t.Fatal("noteLogoffRefusal withdrew a licence on a non-refusal verdict -- that is recordSeal's to judge")
	}
	if got := f.end(); got != "OK" {
		t.Fatalf("END-UNSAVED after a FAILED MEDIA sign-out = %q, want OK", got)
	}
}

// R3-1(ii): RESTART-UNSAVED, licensed only by the SECOND consecutive failed sweep of THIS session.
func TestRestartUnsaved_LicensedByTwoConsecutiveSweepFailures(t *testing.T) {
	restart := func(f *euFixture) string {
		return ropReply(f.t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) })
	}
	t.Run("no failure, one failure: not licensed", func(t *testing.T) {
		f := euSetup(t)
		if got := restart(f); got != "ERR-NOTSTUCK" {
			t.Fatalf("with no failed sweep: %q, want ERR-NOTSTUCK", got)
		}
		logoffSweepFailed("alice", euUID)
		if got := restart(f); got != "ERR-NOTSTUCK" {
			t.Fatalf("after ONE failed sweep: %q, want ERR-NOTSTUCK -- one may be transient", got)
		}
		// With no refusal on record the chooser still learns the run (a media-only reply).
		if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); got != "SAVED 0\nMEDIA 1" {
			t.Errorf("GET-LOGOFF-REFUSAL with only a failed sweep = %q, want \"SAVED 0\\nMEDIA 1\"", got)
		}
		f.untouched("not licensed")
		if len(f.rebootList()) != 0 || f.wallets != 0 {
			t.Errorf("reboots=%v wallets=%d for a refused request", f.rebootList(), f.wallets)
		}
	})
	t.Run("a verified sweep between two failures resets the run", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		noteMediaSweepOK("alice", euUID)
		logoffSweepFailed("alice", euUID)
		if got := restart(f); got != "ERR-NOTSTUCK" {
			t.Fatalf("got %q, want ERR-NOTSTUCK -- the failures were not consecutive", got)
		}
	})
	t.Run("END-UNSAVED's verified sweep also ends the run", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		logoffSweepFailed("alice", euUID)
		endUnsavedCommitBy = -time.Second // stop after the (verified) sweep, keeping the session
		if got := f.end(); got != "ERR-SLOW" {
			t.Fatalf("got %q, want ERR-SLOW", got)
		}
		if n := mediaStuckCount("alice", euUID); n != 0 {
			t.Errorf("run = %d after a verified sweep, want 0", n)
		}
	})
	t.Run("another session's failures do not count", func(t *testing.T) {
		f := euSetup(t)
		noteMediaSweepFailed("bob", euUID) // the previous session on this uid
		logoffSweepFailed("alice", euUID)  // ONE failure of this one
		if got := restart(f); got != "ERR-NOTSTUCK" {
			t.Fatalf("got %q, want ERR-NOTSTUCK", got)
		}
	})
	t.Run("a new session starts over", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		if err := markRoamSession(f.dest, "alice", "pw", euUID, ""); err != nil {
			t.Fatal(err)
		}
		if got := restart(f); got != "ERR-NOTSTUCK" {
			t.Fatalf("got %q, want ERR-NOTSTUCK after a new sign-in", got)
		}
	})
	t.Run("a failed sign-out then an END-UNSAVED ERR-MEDIA: licensed, and it reboots without a seal", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		logoffSweepFailed("alice", euUID)
		f.sweepReply = "ERR-MEDIA-SWEEP 1"
		if got := f.end(); got != "ERR-MEDIA" {
			t.Fatalf("END-UNSAVED = %q, want ERR-MEDIA", got)
		}
		if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); !strings.HasSuffix(got, "\nMEDIA 2") {
			t.Errorf("GET-LOGOFF-REFUSAL = %q, want a MEDIA 2 line", got)
		}
		// END-UNSAVED dropped the stash; the periodic `out` since would have written it again.
		os.WriteFile(filepath.Join(f.dest, ksLogoffCredsFile), []byte("alice\npw\n10\n\n"), 0o600)
		walletsBefore, sweepsBefore := f.wallets, f.sweeps
		if got := restart(f); got != "OK" {
			t.Fatalf("RESTART-UNSAVED = %q, want OK", got)
		}
		f.waitReboots(t, 1) // the reboot is asked for on a goroutine (round 6)
		if len(f.rebootList()) != 1 || f.rebootList()[0] != euUID {
			t.Fatalf("reboots %v, want [%s]", f.rebootList(), euUID)
		}
		if f.wallets != walletsBefore+1 {
			t.Error("the wallet was not saved before the restart")
		}
		if f.sweeps != sweepsBefore {
			t.Error("RESTART-UNSAVED swept -- the reboot is the teardown, the sweep is what keeps failing")
		}
		if _, err := os.Stat(filepath.Join(f.dest, ksLogoffCredsFile)); !os.IsNotExist(err) {
			t.Error("the keystore-push stash survived into the restart")
		}
		if !isLocalSession(f.dest) {
			t.Error("the session was not marked local -- a periodic seal could still run before the reboot")
		}
		for _, lane := range []string{laneRW.req, laneRO.req, laneCred.req} {
			if _, err := os.Stat(filepath.Join(f.dest, lane)); err == nil {
				t.Errorf("a worker request (%s) was written -- RESTART-UNSAVED must seal nothing", lane)
			}
		}
	})
	t.Run("the wallet cannot be saved: no restart", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		f.walletEr = errors.New("store unreachable")
		if got := restart(f); got != "ERR-WALLET" {
			t.Fatalf("got %q, want ERR-WALLET", got)
		}
		f.untouched("wallet failed")
		if len(f.rebootList()) != 0 {
			t.Error("rebooted with the wallet unsaved -- bearer tokens in the tmpfs would die")
		}
	})
	t.Run("same guards as END-UNSAVED", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		sessionPeerUID = func(net.Conn) int { return 11*100000 + 10123 }
		if got := restart(f); got != "NONE" {
			t.Errorf("another user's chooser: %q, want NONE", got)
		}
		sessionPeerUID = func(net.Conn) int { return 10*100000 + 10123 }
		pendingReapMu.Lock()
		sealRunKind = "periodic"
		pendingReapMu.Unlock()
		if got := restart(f); got != "BUSY seal" {
			t.Errorf("a seal announced: %q, want BUSY seal", got)
		}
		pendingReapMu.Lock()
		sealRunKind = ""
		pendingReapMu.Unlock()
		markLocalSession(f.dest)
		if got := restart(f); got != "ERR-LOCAL" {
			t.Errorf("a local session: %q, want ERR-LOCAL", got)
		}
		if len(f.rebootList()) != 0 {
			t.Errorf("rebooted %v on a refused request", f.rebootList())
		}
	})
}

// The production reboot goes through rebootNow (its reason recorded, the reboot_reason pin's form), and the verb is
// routed, serialised and BUSY-now like END-UNSAVED.
func TestRestartUnsaved_Wiring(t *testing.T) {
	b, err := os.ReadFile("end_unsaved.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "\trebootNow(\"restart without saving: the media sweep failed repeatedly uid=\" + uid)\n") {
		t.Error("restartUnsavedReboot no longer reboots through rebootNow")
	}
	if concurrentSafeCmd("RESTART-UNSAVED") || !rekeyHoldingVerb("RESTART-UNSAVED") {
		t.Error("RESTART-UNSAVED must hold sessionMu and hold the re-key off, as END-UNSAVED does")
	}
	m, _ := os.ReadFile("main.go")
	if !strings.Contains(string(m), `name == "END-UNSAVED" || name == "RESTART-UNSAVED" {`) {
		t.Error("RESTART-UNSAVED is not on the TryLock (BUSY-now) list")
	}
	f := euSetup(t)
	cli, srv := net.Pipe()
	go handleLogin(srv, f.dest)
	cli.SetDeadline(time.Now().Add(5 * time.Second))
	cli.Write([]byte("RESTART-UNSAVED\n"))
	line, _ := bufio.NewReader(cli).ReadString('\n')
	cli.Close()
	if got := strings.TrimSpace(line); got != "ERR-NOTSTUCK" {
		t.Errorf("RESTART-UNSAVED through handleLogin: %q, want ERR-NOTSTUCK", got)
	}
}

// R3-3: the FAILED publish never waits on the store. A guard that pointed at a delete makes the daemon ask the store,
// but on a goroutine; END-UNSAVED asks itself if the answer has not arrived.
func TestEndUnsaved_TheFailedPublishDoesNotWaitOnTheStore(t *testing.T) {
	f := euSetup(t)
	release := make(chan struct{})
	t.Cleanup(func() {
		select {
		case <-release:
		default:
			close(release)
		}
	})
	logoffProfileDeleted = func(name, pass string) bool { f.storeAsks.Add(1); <-release; return false }
	clearRefusalReasons()
	stashRefusalReasons("alice#de", []string{"shrink"})
	stashRefusalReasons("alice#media", []string{"deleted"})
	const out = "ERR-REFUSED PARTIAL:de=refused,media=refused"
	done := make(chan struct{})
	go func() {
		noteLogoffRefusal(out, "alice", "pw", euUID)
		logoffSealFailed(out)
		close(done)
	}()
	t.Cleanup(func() {
		pendingReapMu.Lock()
		sealFail, sealFailWhy = false, ""
		pendingReapMu.Unlock()
	})
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("FAILED was not published while the store lookup hung -- \"Saving…\" would hang with it")
	}
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); strings.Contains(got, "DELETED") {
		t.Errorf("DELETED before the store answered: %q", got)
	}
	close(release)
	f.waitDeletion(t)
	if got := f.end(); got != "OK" || f.wallets != 1 {
		t.Fatalf("END-UNSAVED = %q with %d wallet save(s), want OK with 1 (the store said not deleted)", got, f.wallets)
	}
}

// R3-3, the other half: END-UNSAVED decides the wallet on the store's answer even when the background lookup has not
// arrived -- it asks itself.
func TestEndUnsaved_AsksTheStoreItselfWhenTheAnswerIsNotIn(t *testing.T) {
	f := euSetup(t)
	f.deleted = true
	r := &logoffRefusalRec{uid: euUID, name: "alice", parts: "de=refused", final: true, askDeleted: true,
		reasons: map[string][]string{"de": {"deleted"}}}
	logoffRefusalMu.Lock()
	logoffRefusal = r // armed with no background answer yet
	logoffRefusalMu.Unlock()
	if got := f.end(); got != "OK" || f.wallets != 0 || f.storeAsks.Load() != 1 {
		t.Fatalf("got %q, wallets %d, store asks %d -- want OK, 0, 1", got, f.wallets, f.storeAsks.Load())
	}
}

// R3-4 and R3-5: the commit clears the blind-package list; an undo revives the kept session's media at once.
func TestEndUnsaved_CommitClearsBlindListAndUndoKicksMedia(t *testing.T) {
	t.Run("commit", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		os.WriteFile(sealBlindPkgPath(), []byte("com.example.tesla\n"), 0o600)
		if got := f.end(); got != "OK" {
			t.Fatalf("got %q", got)
		}
		if _, err := os.Stat(sealBlindPkgPath()); !os.IsNotExist(err) {
			t.Error("the blocked apps' names outlived the session END-UNSAVED discarded")
		}
		if f.kicks != 0 {
			t.Error("mediad was kicked for a session being reaped")
		}
	})
	t.Run("ERR-MEDIA undo", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		f.sweepReply = "ERR-MEDIA-SWEEP 1"
		if got := f.end(); got != "ERR-MEDIA" || f.kicks != 1 {
			t.Fatalf("got %q with %d kick(s), want ERR-MEDIA with 1", got, f.kicks)
		}
	})
	t.Run("ERR-SLOW after the sweep", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		endUnsavedCommitBy = -time.Second
		if got := f.end(); got != "ERR-SLOW" || f.kicks != 1 {
			t.Fatalf("got %q with %d kick(s), want ERR-SLOW with 1", got, f.kicks)
		}
	})
	t.Run("ERR-SLOW before the sweep changes nothing to undo", func(t *testing.T) {
		f := euSetup(t)
		f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
		endUnsavedSweepBy = -time.Second
		if got := f.end(); got != "ERR-SLOW" || f.kicks != 0 {
			t.Fatalf("got %q with %d kick(s), want ERR-SLOW with 0", got, f.kicks)
		}
	})
}

// R3-2: a sign-out that did not happen drops the #154 marker, and the logoff's own seal is the only run that may
// honour it (roamd side: test-btlogoff-logoff-only.sh).
func TestLogoff_BTMarkerOnlyForTheLogoffsOwnSeal(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	lo := strings.Join(stripComments(funcBody(t, string(b), "handleLogout")), "\n")
	for _, arm := range []string{
		"logoffSweepFailed(name, uid)\n\t\t\tdropLogoffBTMarker(dest)",
		"rearmRoamSession(dest, name, pass, uid, seSecret, \"logout seal failed, re-arm\")\n\t\t\tdropLogoffBTMarker(dest)",
	} {
		if !strings.Contains(lo, arm) {
			t.Errorf("handleLogout's keep-signed-in arm no longer drops the BT marker: want %q", arm)
		}
	}
	dest := t.TempDir()
	os.WriteFile(filepath.Join(dest, ".btlogoff"), nil, 0o600)
	dropLogoffBTMarker(dest)
	if _, err := os.Stat(filepath.Join(dest, ".btlogoff")); !os.IsNotExist(err) {
		t.Error("dropLogoffBTMarker left the marker")
	}
}

// endWatchdog ends RESTART-UNSAVED's watchdog wait and waits for the RW slot to be free again.
func (f *euFixture) endWatchdog() {
	select {
	case <-f.watch:
	default:
		close(f.watch)
	}
	// BOUNDED both ways (round 5, F7): a watchdog that never lets go, or one that releases a slot nobody holds and so
	// steals the token this puts back, must fail here in seconds, not hang the suite for its 300 s timeout.
	select {
	case laneRW.slot <- struct{}{}:
	case <-time.After(2 * time.Second):
		f.t.Error("the RW slot stayed held after the restart watchdog was released")
		return
	}
	select {
	case <-laneRW.slot:
	case <-time.After(2 * time.Second):
		f.t.Error("the slot token was taken by someone else -- a release without a matching hold")
	}
}

// ---- round 4 ----

// R4-3 and R4-4: nothing seals before the reboot -- a seal announced while the wallet saved answers BUSY, and on OK
// the RW slot stays held -- and if the reboot never comes, the watchdog gives the session back.
func TestRestartUnsaved_NothingSealsBeforeTheRebootAndTheWatchdogUndoes(t *testing.T) {
	restart := func(f *euFixture) string {
		return ropReply(f.t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) })
	}
	t.Run("a seal announced during the wallet save: BUSY", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		endUnsavedWallet = func(dest, name, pass string, se []byte, gen string) error {
			f.wallets++
			pendingReapMu.Lock()
			sealRunKind = "periodic" // syncLoop announced while the store round trip ran
			pendingReapMu.Unlock()
			return nil
		}
		if got := restart(f); got != "BUSY seal" {
			t.Fatalf("got %q, want BUSY seal -- that seal is queued for the slot and would run during shutdown", got)
		}
		if len(f.rebootList()) != 0 || isLocalSession(f.dest) {
			t.Errorf("reboots %v, local %v after BUSY", f.rebootList(), isLocalSession(f.dest))
		}
	})
	t.Run("OK keeps the slot until the watchdog, which gives the session back", func(t *testing.T) {
		f := euSetup(t)
		logoffSweepFailed("alice", euUID)
		logoffSweepFailed("alice", euUID)
		// the reboot hook does nothing: the restart "does not happen"
		if got := restart(f); got != "OK" || len(f.waitReboots(t, 1)) != 1 {
			t.Fatalf("got %q with reboots %v", got, f.rebootList())
		}
		select {
		case laneRW.slot <- struct{}{}:
			<-laneRW.slot
			t.Fatal("the RW slot was free after OK -- a queued seal could run its `out` during shutdown")
		default:
		}
		if !isLocalSession(f.dest) || f.kicks != 0 {
			t.Fatalf("before the watchdog: local %v, kicks %d -- want local, none", isLocalSession(f.dest), f.kicks)
		}
		f.endWatchdog() // the watchdog's wait ends with the process still alive
		if isLocalSession(f.dest) || !roamSessionExists(f.dest) {
			t.Error("the watchdog did not give the session back (it is still marked local, or gone)")
		}
		if f.kicks != 1 {
			t.Errorf("mediad kicked %d times by the watchdog, want 1", f.kicks)
		}
		if len(f.rebootList()) != 2 {
			t.Errorf("reboot asked %d times, want 2 -- the watchdog asks once more before it gives up", len(f.rebootList()))
		}
		if got := ropReply(t, func(c net.Conn) { handleRestartStatus(c, f.dest) }); got != "FAILED" {
			t.Errorf("RESTART-STATUS after the watchdog gave up = %q, want FAILED -- the chooser must learn it", got)
		}
	})
}

// R4-2: the stall watchdog's unstick tells the user the session stays, so the BT marker must go with it -- a logoff
// `out` that lands later would otherwise clear the device's Bluetooth under them.
func TestLogoff_StallUnstickDropsTheBTMarker(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	lo := strings.Join(stripComments(funcBody(t, string(b), "handleLogout")), "\n")
	un := strings.Index(lo, "sealUnstuck = true")
	re := strings.Index(lo, `"logout seal stalled, re-arm"`)
	if un < 0 || re < 0 || un > re {
		t.Fatalf("the stall-unstick block changed shape (unstuck %d, re-arm %d)", un, re)
	}
	if !strings.Contains(lo[un:re], "dropLogoffBTMarker(dest)") {
		t.Error("the stall unstick no longer drops the BT marker before it re-arms the session it says it keeps")
	}
}

// ---- round 5 ----

// stuckAndRestarted is a session whose restart was asked for and answered OK, with the reboot hook doing nothing: the
// restart is pending and "will not happen".
func stuckAndRestarted(t *testing.T) *euFixture {
	t.Helper()
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	if got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }); got != "OK" {
		t.Fatalf("RESTART-UNSAVED = %q, want OK", got)
	}
	return f
}

// F1: the chooser can learn the outcome, and a sign-out while the restart is pending does not reap unsaved.
func TestRestartUnsaved_TheOutcomeIsNeverSilent(t *testing.T) {
	status := func(f *euFixture) string {
		return ropReply(f.t, func(c net.Conn) { handleRestartStatus(c, f.dest) })
	}
	t.Run("NONE before, PENDING while waiting, FAILED once given up", func(t *testing.T) {
		f := euSetup(t)
		if got := status(f); got != "NONE" {
			t.Fatalf("before any restart: %q, want NONE", got)
		}
		f2 := stuckAndRestarted(t)
		if got := status(f2); got != "PENDING" {
			t.Fatalf("after OK: %q, want PENDING", got)
		}
		sessionPeerUID = func(net.Conn) int { return 11*100000 + 10123 }
		if got := status(f2); got != "NONE" {
			t.Errorf("to another user's chooser: %q, want NONE", got)
		}
		sessionPeerUID = func(net.Conn) int { return 10*100000 + 10123 }
		f2.endWatchdog()
		if got := status(f2); got != "FAILED" {
			t.Errorf("after the watchdog gave up: %q, want FAILED", got)
		}
		if err := markRoamSession(f2.dest, "alice", "pw", euUID, ""); err != nil {
			t.Fatal(err)
		}
		if got := status(f2); got != "NONE" {
			t.Errorf("after a new sign-in: %q, want NONE", got)
		}
	})
	t.Run("a sign-out while the restart is pending answers BUSY and reaps nothing", func(t *testing.T) {
		f := stuckAndRestarted(t)
		if got := ropReply(t, func(c net.Conn) { handleLogout(c, f.dest) }); got != "BUSY" {
			t.Fatalf("LOGOUT while the restart is pending = %q, want BUSY -- the local mark would take the throwaway branch", got)
		}
		pendingReapMu.Lock()
		q := pendingReapUID + pendingSwitchUID
		pendingReapMu.Unlock()
		if q != "" || !roamSessionExists(f.dest) || !isLocalSession(f.dest) {
			t.Errorf("queued %q, marker %v, local %v -- nothing may change", q, roamSessionExists(f.dest), isLocalSession(f.dest))
		}
	})
}

// F2: the watchdog gives back only the session the restart was asked for.
func TestRestartUnsaved_TheWatchdogLeavesALaterSessionAlone(t *testing.T) {
	f := stuckAndRestarted(t)
	// The session changed while the restart was pending: a throwaway on the same uid, marked local. Written WITHOUT the
	// session-start reset, so the restart state is still PENDING and only the name scoping can answer NONE.
	if err := writeRoamSession(f.dest, "bob", "pw", euUID, "", false); err != nil {
		t.Fatal(err)
	}
	markLocalSession(f.dest)
	if got := ropReply(t, func(c net.Conn) { handleRestartStatus(c, f.dest) }); got != "NONE" {
		t.Errorf("RESTART-STATUS for a later session on the same uid = %q, want NONE", got)
	}
	f.endWatchdog()
	if !isLocalSession(f.dest) {
		t.Error("the watchdog cleared a later session's local mark (the NWP-20261010-07 hazard)")
	}
	if f.kicks != 0 {
		t.Errorf("mediad kicked %d times for a session the restart was not for", f.kicks)
	}
	if restartPending() {
		t.Error("the restart stayed PENDING for a session that changed -- LOGOUT would stay BUSY for it")
	}
	restartMu.Lock()
	st := restartState
	restartMu.Unlock()
	if st != "" {
		t.Errorf("restart state %q for a session that changed, want none (round 6)", st)
	}
}

// F3: the slot is released on every path after OK, a panicking reboot call included.
func TestRestartUnsaved_APanickingRebootDoesNotWedgeTheSlot(t *testing.T) {
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	restartUnsavedReboot = func(uid string) { panic("reboot failed loudly") }
	got := ropReply(t, func(c net.Conn) {
		defer func() { recover() }() // handleLogin's own recover, in production
		handleRestartUnsaved(c, f.dest)
	})
	if got != "OK" {
		t.Fatalf("got %q, want OK", got)
	}
	f.endWatchdog() // fails if the slot stays held
	if !roamSessionExists(f.dest) || isLocalSession(f.dest) {
		t.Error("the watchdog did not give the session back after the reboot call panicked")
	}
}

// The verb is routed and lock-free.
func TestRestartUnsaved_StatusIsRoutedAndLockFree(t *testing.T) {
	if !concurrentSafeCmd("RESTART-STATUS") {
		t.Error("RESTART-STATUS must run outside sessionMu: it is polled while anything may hold it")
	}
	f := euSetup(t)
	cli, srv := net.Pipe()
	go handleLogin(srv, f.dest)
	cli.SetDeadline(time.Now().Add(5 * time.Second))
	cli.Write([]byte("RESTART-STATUS\n"))
	line, _ := bufio.NewReader(cli).ReadString('\n')
	cli.Close()
	if got := strings.TrimSpace(line); got != "NONE" {
		t.Errorf("RESTART-STATUS through handleLogin: %q, want NONE", got)
	}
}

// rebootList is the reboots asked for so far (the hook runs on goroutines since round 6).
func (f *euFixture) rebootList() []string {
	f.rebootMu.Lock()
	defer f.rebootMu.Unlock()
	return append([]string(nil), f.reboots...)
}

// waitReboots waits, bounded, for at least n reboot requests and returns them.
func (f *euFixture) waitReboots(t *testing.T, n int) []string {
	t.Helper()
	for i := 0; i < 200; i++ {
		if r := f.rebootList(); len(r) >= n {
			return r
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("only %d reboot request(s) arrived, want %d", len(f.rebootList()), n)
	return nil
}

// ---- round 6 ----

// waitRestartReboots waits, bounded, for every reboot goroutine a restart started.
func waitRestartReboots(t *testing.T) {
	t.Helper()
	done := make(chan struct{})
	go func() { restartReboots.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Error("a reboot call was still running when the test ended -- it would call the next test's hook")
	}
}

// The daemon's waits are CLOCK_BOOTTIME (round 7), napping in short steps: a suspend counts toward them and ends them
// within one step of the wake, and a wall-clock set cannot touch them. The production wait is that one.
func TestRestartUnsaved_TheWatchdogWaitsOnBootTime(t *testing.T) {
	oldNow, oldSleep := bootNowMs, restartSleep
	t.Cleanup(func() { bootNowMs, restartSleep = oldNow, oldSleep })
	var mu sync.Mutex
	clk, naps := int64(1_000_000), 0
	bootNowMs = func() int64 { mu.Lock(); defer mu.Unlock(); return clk }
	restartSleep = func(d time.Duration) {
		mu.Lock()
		defer mu.Unlock()
		naps++
		clk += d.Milliseconds()
		if naps == 2 {
			clk += 25_000 // the phone suspends for 25 s inside the second nap; the process sees one ordinary nap
		}
	}
	done := make(chan struct{})
	go func() { sleepBootSteps(30*time.Second, time.Second); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		// The fake naps take no real time: a wait on any clock but bootNowMs never ends here.
		t.Fatal("the wait did not end on the boot clock -- it is counting a clock a suspend freezes, or one a set moves")
	}
	mu.Lock()
	n, elapsed := naps, clk-1_000_000
	mu.Unlock()
	if elapsed < 30_000 {
		t.Errorf("the wait ended after %d ms of boot time, want 30 s", elapsed)
	}
	if n != 5 { // 1 s, 1 s + the 25 s suspend, then 1 s three times: 30 s
		t.Errorf("%d naps, want 5 -- the 25 s suspend must count toward the wait", n)
	}

	t.Run("an unreadable clock falls back to one bounded sleep", func(t *testing.T) {
		bootNowMs = func() int64 { return 0 }
		var got []time.Duration
		restartSleep = func(d time.Duration) { got = append(got, d) }
		sleepBootSteps(30*time.Second, time.Second)
		if len(got) != 1 || got[0] != 30*time.Second {
			t.Errorf("naps %v, want one of 30s", got)
		}
	})

	b, err := os.ReadFile("end_unsaved.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "var restartUnsavedWait = func() { sleepBootSteps(restartUnsavedWatchdog, time.Second) }") {
		t.Error("the restart watchdog no longer waits on the boot clock in short steps")
	}
}

// The give-back comes BEFORE FAILED: restartPending is still true while the local mark is cleared and mediad kicked.
func TestRestartUnsaved_TheSessionIsGivenBackBeforeFailedIsPublished(t *testing.T) {
	f := stuckAndRestarted(t)
	var pendingAtKick, localAtKick bool
	endUnsavedKickMediad = func(string) {
		f.kicks++
		pendingAtKick, localAtKick = restartPending(), isLocalSession(f.dest)
	}
	f.endWatchdog()
	if !pendingAtKick || localAtKick {
		t.Errorf("at the give-back: pending %v, local %v -- want PENDING still published and the mark already gone",
			pendingAtKick, localAtKick)
	}
	if got := ropReply(t, func(c net.Conn) { handleRestartStatus(c, f.dest) }); got != "FAILED" {
		t.Errorf("after the give-back: %q, want FAILED", got)
	}
}

// Neither reboot request can hold anything forever: the handler's is asynchronous (sessionMu is released with the
// reply), and the watchdog's retry is bounded.
func TestRestartUnsaved_ABlockingRebootHoldsNothing(t *testing.T) {
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	never := make(chan struct{})
	t.Cleanup(func() { close(never) })
	restartUnsavedReboot = func(uid string) { <-never } // AOSP's reboot pause()s
	restartRetryBound = 50 * time.Millisecond
	t.Cleanup(func() { restartRetryBound = 10 * time.Second })
	done := make(chan string, 1)
	go func() { done <- ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }) }()
	select {
	case got := <-done:
		if got != "OK" {
			t.Fatalf("got %q, want OK", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("RESTART-UNSAVED did not return while the reboot call blocked -- it would hold sessionMu forever")
	}
	f.endWatchdog() // fails if the bounded retry kept the watchdog from giving up and releasing the slot
	if got := ropReply(t, func(c net.Conn) { handleRestartStatus(c, f.dest) }); got != "FAILED" {
		t.Errorf("after a retry that never returned: %q, want FAILED", got)
	}
}

// A daemon restart while the restart was pending: the marker gives the session back at the next start.
func TestRestartUnsaved_TheMarkerSurvivesADaemonRestart(t *testing.T) {
	f := stuckAndRestarted(t)
	b, err := os.ReadFile(filepath.Join(f.dest, restartMarkerFile))
	if err != nil {
		t.Fatalf("no restart marker after OK: %v", err)
	}
	if strings.Contains(string(b), "alice") || !strings.HasPrefix(string(b), euUID+"\n") {
		t.Errorf("marker = %q: want the uid and a hash, never the name", b)
	}
	t.Run("the daemon starts again: the marked session is given back", func(t *testing.T) {
		// The watchdog died with the old daemon: simulate a new start with the marker and the local mark in place.
		kicks := f.kicks
		recoverRestartMarker(f.dest)
		if isLocalSession(f.dest) {
			t.Error("the session stayed local after a daemon restart -- no seals, and a sign-out would reap it unsaved")
		}
		if f.kicks != kicks+1 {
			t.Error("its media was not revived")
		}
		if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
			t.Error("the marker survived the recovery")
		}
	})
	t.Run("a marker for another session is dropped and touches nothing", func(t *testing.T) {
		writeRestartMarker(f.dest, "bob", euUID)
		markLocalSession(f.dest)
		recoverRestartMarker(f.dest)
		if !isLocalSession(f.dest) {
			t.Error("a marker for another profile cleared this session's local mark")
		}
		if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
			t.Error("the stale marker was kept")
		}
		clearLocalSession(f.dest)
	})
	t.Run("a marker with this profile's name but another uid is dropped and touches nothing", func(t *testing.T) {
		// Same profile, another Android user: the restart was asked for a session that has since been replaced by a
		// new sign-in of the same profile on a new uid. Its local mark is not the restart's.
		writeRestartMarker(f.dest, "alice", "11")
		markLocalSession(f.dest)
		kicks := f.kicks
		recoverRestartMarker(f.dest)
		if !isLocalSession(f.dest) || f.kicks != kicks {
			t.Error("a marker for another uid gave this session back")
		}
		if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
			t.Error("the stale marker was kept")
		}
		clearLocalSession(f.dest)
	})
	t.Run("the watchdog removes it", func(t *testing.T) {
		writeRestartMarker(f.dest, "alice", euUID)
		f.endWatchdog()
		if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
			t.Error("the watchdog left the marker -- the next daemon start would act on a restart already settled")
		}
	})
	m, _ := os.ReadFile("main.go")
	// Before the seal loop starts: a seal of the given-back session must find its local mark already gone.
	if !strings.Contains(string(m), "\trecoverRestartMarker(dest)\n\tgoSafeLoop(\"periodic-seal loop\", func() { syncLoop(dest) })") {
		t.Error("the daemon no longer recovers a pending restart at start, before the seal loop")
	}
}

// ---- round 7 ----

// The marker is written BEFORE the session is marked local, and a failed write stops the restart with nothing changed:
// a local mark no daemon restart could give back is the one state round 6 exists to prevent.
func TestRestartUnsaved_AnUnwritableMarkerChangesNothing(t *testing.T) {
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	ks := filepath.Join(f.dest, ksLogoffCredsFile)
	if err := os.WriteFile(ks, []byte("stash"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A directory where the marker goes: the write fails as it would on a full or read-only tmpfs.
	if err := os.Mkdir(filepath.Join(f.dest, restartMarkerFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if got := ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }); got != "ERR-STATE" {
		t.Fatalf("RESTART-UNSAVED with an unwritable marker = %q, want ERR-STATE", got)
	}
	// Round 8: whatever the failed write left at the marker's path is removed, so no partial marker lingers for the
	// next daemon start. (An empty directory stands in for it; os.Remove takes either.)
	if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
		t.Error("the failed marker write left something at the marker's path")
	}
	if isLocalSession(f.dest) {
		t.Error("the session was marked local with no marker to give it back after a daemon restart")
	}
	if _, err := os.Stat(ks); err != nil {
		t.Error("the #keys stash was dropped for a restart that did not go ahead")
	}
	if restartPending() {
		t.Error("the restart is PENDING although it was refused")
	}
	time.Sleep(50 * time.Millisecond) // a reboot goroutine, if one had been started, has had its chance
	if r := f.rebootList(); len(r) != 0 {
		t.Errorf("reboot asked for (%v) after a refusal", r)
	}
	// The RW slot is free: no watchdog took it over. (euSetup's cleanup checks this too, bounded.)
	select {
	case laneRW.slot <- struct{}{}:
		<-laneRW.slot
	case <-time.After(time.Second):
		t.Error("the RW slot stayed held after a refusal")
	}
}

// While a restart is pending the session is marked local, but it is a STORED profile: PROMOTE and PROMOTE2 ("Save to
// your store") must not treat it as a throwaway and fork it into a new profile.
func TestRestartUnsaved_APendingRestartIsNotAThrowawayToSave(t *testing.T) {
	f := stuckAndRestarted(t)
	if got := ropReply(t, func(c net.Conn) { handlePromote(c, f.dest) }); got != "BUSY" {
		t.Errorf("PROMOTE while the restart is pending = %q, want BUSY", got)
	}
	if got := ropReply(t, func(c net.Conn) { handlePromote2(c, f.dest, "newpass") }); got != "BUSY" {
		t.Errorf("PROMOTE2 while the restart is pending = %q, want BUSY", got)
	}
	if !isLocalSession(f.dest) || !restartPending() {
		t.Error("a refused save changed the pending restart")
	}
	f.endWatchdog()
	if got := ropReply(t, func(c net.Conn) { handlePromote(c, f.dest) }); got != "ERR-ALREADY" {
		t.Errorf("PROMOTE once the session is given back = %q, want ERR-ALREADY (it is stored)", got)
	}
}

// ---- round 8 ----

// nonEmptyKSStash makes the keystore-push stash unremovable: a non-empty directory where the file goes.
func nonEmptyKSStash(t *testing.T, dest string) string {
	t.Helper()
	ks := filepath.Join(dest, ksLogoffCredsFile)
	os.Remove(ks) // the session's own stash file, which euSetup writes
	if err := os.MkdirAll(filepath.Join(ks, "pinned"), 0o700); err != nil {
		t.Fatal(err)
	}
	return ks
}

// slotFree asserts the RW slot is not held, bounded.
func slotFree(t *testing.T, why string) {
	t.Helper()
	select {
	case laneRW.slot <- struct{}{}:
		<-laneRW.slot
	case <-time.After(time.Second):
		t.Errorf("%s: the RW slot stayed held", why)
	}
}

// RESTART-UNSAVED's ERR-KEYS comes AFTER the marker is written: it must take the marker back with it, change nothing
// else, and say so in the log by uid and reply only.
func TestRestartUnsaved_ERRKEYSTakesTheMarkerBack(t *testing.T) {
	f := euSetup(t)
	logoffSweepFailed("alice", euUID)
	logoffSweepFailed("alice", euUID)
	ks := nonEmptyKSStash(t, f.dest)
	var got string
	log := captureStderr(t, func() { got = ropReply(t, func(c net.Conn) { handleRestartUnsaved(c, f.dest) }) })
	if got != "ERR-KEYS" {
		t.Fatalf("RESTART-UNSAVED with an unremovable #keys stash = %q, want ERR-KEYS", got)
	}
	if _, err := os.Stat(filepath.Join(f.dest, restartMarkerFile)); !os.IsNotExist(err) {
		t.Error("the restart marker outlived the refusal -- the next daemon start would act on a restart never begun")
	}
	if isLocalSession(f.dest) || !roamSessionExists(f.dest) {
		t.Error("the session changed on ERR-KEYS")
	}
	if _, err := os.Stat(filepath.Join(ks, "pinned")); err != nil {
		t.Error("the #keys stash was touched")
	}
	if restartPending() {
		t.Error("PENDING after a refusal")
	}
	slotFree(t, "after ERR-KEYS")
	if !strings.Contains(log, "restart-unsaved user "+euUID+": ERR-KEYS -- ") {
		t.Errorf("the refusal was not logged by uid and reply; log:\n%s", log)
	}
	if strings.Contains(log, "alice") {
		t.Error("the refusal log names the profile")
	}
}

// END-UNSAVED's ERR-KEYS: refused before anything is torn down -- no local mark, no sweep, the stash intact.
func TestEndUnsaved_ERRKEYSChangesNothing(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	ks := nonEmptyKSStash(t, f.dest)
	var got string
	log := captureStderr(t, func() { got = f.end() })
	if got != "ERR-KEYS" {
		t.Fatalf("END-UNSAVED with an unremovable #keys stash = %q, want ERR-KEYS", got)
	}
	// Logged by uid, never by name (round 9).
	if !strings.Contains(log, "end-unsaved user "+euUID+": the keystore-push stash could not be removed") {
		t.Errorf("the refusal was not logged by uid; log:\n%s", log)
	}
	if strings.Contains(log, "alice") {
		t.Error("the refusal log names the profile")
	}
	if isLocalSession(f.dest) || !roamSessionExists(f.dest) {
		t.Error("the session changed on ERR-KEYS")
	}
	if f.sweeps != 0 {
		t.Errorf("%d media sweeps for a refused END-UNSAVED", f.sweeps)
	}
	if _, err := os.Stat(filepath.Join(ks, "pinned")); err != nil {
		t.Error("the #keys stash was touched")
	}
	pendingReapMu.Lock()
	q := pendingReapUID + pendingSwitchUID
	pendingReapMu.Unlock()
	if q != "" {
		t.Errorf("a teardown was queued (%q)", q)
	}
	slotFree(t, "after END-UNSAVED's ERR-KEYS")
}

// Add-credits while a restart is pending: refused BEFORE the gateway is asked, so no token is minted into a wallet
// the reboot wipes (#218), with its own reply: the chooser tells the user to redeem it in the next session.
func TestRestartUnsaved_APendingRestartRedeemsNoCode(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		http.Error(w, "unexpected", http.StatusTeapot)
	}))
	defer srv.Close()
	f := stuckAndRestarted(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	if got := ropReply(t, func(c net.Conn) { handleClaim(c, f.dest, "CODE-1234", false) }); got != "ERR-RESTARTING" {
		t.Errorf("CLAIM while the restart is pending = %q, want ERR-RESTARTING", got)
	}
	if n := hits.Load(); n != 0 {
		t.Errorf("the gateway was asked %d time(s) -- a code was being redeemed into a wallet the reboot wipes", n)
	}
	f.endWatchdog()
	ropReply(t, func(c net.Conn) { handleClaim(c, f.dest, "CODE-1234", false) })
	if hits.Load() == 0 {
		t.Error("CLAIM once the session is given back never reached the gateway -- the guard outlived the restart")
	}
}

// sleepBootSteps says when it cannot use the boot clock, and a clock that fails mid-wait ends the wait.
func TestRestartUnsaved_TheBootClockFailingIsBoundedAndLogged(t *testing.T) {
	oldNow, oldSleep := bootNowMs, restartSleep
	t.Cleanup(func() { bootNowMs, restartSleep = oldNow, oldSleep })
	t.Run("unreadable at the start", func(t *testing.T) {
		bootNowMs = func() int64 { return 0 }
		restartSleep = func(time.Duration) {}
		log := captureStderr(t, func() { sleepBootSteps(30*time.Second, time.Second) })
		if strings.Count(log, "CLOCK_BOOTTIME unreadable") != 1 {
			t.Errorf("want the fallback logged once; log:\n%s", log)
		}
	})
	t.Run("unreadable part-way", func(t *testing.T) {
		var mu sync.Mutex
		clk, naps := int64(1_000_000), 0
		var lastNap time.Duration
		bootNowMs = func() int64 { mu.Lock(); defer mu.Unlock(); return clk }
		park := make(chan struct{}) // never closed
		restartSleep = func(d time.Duration) {
			mu.Lock()
			if naps >= 100 {
				// A wait that does not end: park it, rather than spin (and log) until the test binary exits.
				mu.Unlock()
				<-park
			}
			defer mu.Unlock()
			naps++
			lastNap = d
			if naps == 3 {
				clk = 0 // the clock stops answering
			} else if clk > 0 {
				clk += d.Milliseconds()
			}
		}
		done := make(chan struct{})
		log := captureStderr(t, func() {
			go func() { sleepBootSteps(30*time.Second, time.Second); close(done) }()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Error("a clock that stopped answering mid-wait kept the wait going for ever -- the watchdog would never give up")
			}
		})
		mu.Lock()
		n, ln := naps, lastNap
		mu.Unlock()
		// Two good 1 s naps, the third during which the clock dies, then ONE plain sleep of what was left as of the
		// last good reading (2 s in): 28 s. Ending at the bad reading would let the watchdog give the session back
		// while a real shutdown is still running (round 9).
		if n != 4 || ln != 28*time.Second {
			t.Errorf("%d naps, the last %v -- want 4, the last the 28s still owed", n, ln)
		}
		if strings.Count(log, "became unreadable mid-wait") != 1 {
			t.Errorf("want the mid-wait failure logged once; log:\n%s", log)
		}
	})
}
