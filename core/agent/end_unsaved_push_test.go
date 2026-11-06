package main

// NWP-20261101-05 (Q070, docs/product-decisions.md, 2026-10-20): two sign-outs in a row that could not reach the store
// and saved nothing license END-UNSAVED, which then ends without a wallet publish.

import (
	"net"
	"os"
	"strings"
	"testing"
)

const pushUnreachable = "ERR-PUSH"

// pushDown is roamd's verdict for an unreachable store: _push notes EVERY scope whose push failed, so none is saved.
const pushDown = "ERR-PUSH PARTIAL:vault=failed,de=failed,media=failed,sys=failed,apps=failed"

// pushSetup is euSetupAs for its own profile, with the push run cleared before and after.
func pushSetup(t *testing.T, name string) *euFixture {
	t.Helper()
	f := euSetupAs(t, t.TempDir(), name, "pw-"+name)
	resetPushStuck()
	t.Cleanup(resetPushStuck)
	return f
}

// signOutFails is handleLogout's failed-seal route for a verdict, its two steps in the route's order (the source check
// below pins that order): logoffSealFailed's recordSeal first, then the push count.
func (f *euFixture) signOutFails(out string) {
	recordSeal(out)
	if sealVerb(out) == pushUnreachable {
		notePushFailed(f.name, euUID)
	}
}

func TestEndUnsavedPush_OneUnreachableSignOutDoesNotLicense(t *testing.T) {
	f := pushSetup(t, "pushone")
	f.signOutFails(pushDown)
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED after one failed sign-out", got)
	}
	f.untouched("one ERR-PUSH")
}

func TestEndUnsavedPush_TwoInARowLicenseAndPublishNoWallet(t *testing.T) {
	f := pushSetup(t, "pushtwo")
	f.signOutFails(pushDown)
	f.signOutFails(pushDown)
	if got := f.end(); got != "OK" {
		t.Fatalf("got %q, want OK", got)
	}
	if f.wallets != 0 {
		t.Errorf("endUnsavedWallet called %d times -- the push-licensed end publishes no wallet", f.wallets)
	}
	if f.sweeps != 1 || len(f.fallbacks) != 1 {
		t.Errorf("sweeps %d, fallbacks %v -- the rest of the end must run unchanged", f.sweeps, f.fallbacks)
	}
	if roamSessionExists(f.dest) {
		t.Error("the session marker survived the end")
	}
	if n := pushStuckCount(f.name, euUID); n != 0 {
		t.Errorf("the run is %d after the committed end, want 0", n)
	}
	if d := f.dropCalls(); len(d) != 0 {
		t.Errorf("a wallet drop ran with no wallet save: %v", d)
	}
}

func TestEndUnsavedPush_AnOKSealBetweenResetsTheRun(t *testing.T) {
	f := pushSetup(t, "pushok")
	f.signOutFails(pushDown)
	recordSeal("OK")
	f.signOutFails(pushDown)
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED -- a save landed between the failures", got)
	}
	f.untouched("ERR-PUSH, OK, ERR-PUSH")
}

func TestEndUnsavedPush_APartlySavedVerdictNeverLicenses(t *testing.T) {
	f := pushSetup(t, "pushpart")
	f.signOutFails("ERR-PUSH PARTIAL:de=failed")
	f.signOutFails("ERR-PUSH PARTIAL:de=failed")
	if n := pushStuckCount(f.name, euUID); n != 1 {
		t.Errorf("run is %d, want 1: each partly saved verdict resets, then counts itself", n)
	}
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED", got)
	}
	f.untouched("partly saved ERR-PUSH twice")
}

func TestEndUnsavedPush_AnotherSessionsFailuresDoNotCount(t *testing.T) {
	f := pushSetup(t, "pushmine")
	notePushFailed("pushtheirs", "11")
	notePushFailed("pushtheirs", "11")
	if n := pushStuckCount(f.name, euUID); n != 0 {
		t.Errorf("another session's run counts %d for this one", n)
	}
	if n := notePushFailed(f.name, euUID); n != 1 {
		t.Errorf("this session's first failure counts %d, want 1 -- another session's count starts over", n)
	}
	if got := f.end(); got != "ERR-NOTREFUSED" {
		t.Fatalf("got %q, want ERR-NOTREFUSED", got)
	}
	if pushStuckCount("", "") != 0 || pushStuckCount(f.name, "") != 0 {
		t.Error("an empty name or uid must count 0")
	}
}

func TestEndUnsavedPush_ParkedCreditAnswersCreditLost(t *testing.T) {
	f := pushSetup(t, "pushcredit")
	if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
		t.Fatal(err)
	}
	f.signOutFails(pushDown)
	f.signOutFails(pushDown)
	if got := f.end(); got != endUnsavedCreditLost {
		t.Fatalf("got %q, want %s -- the session never read its stored wallet and holds credit", got, endUnsavedCreditLost)
	}
	if f.wallets != 0 {
		t.Errorf("endUnsavedWallet called %d times", f.wallets)
	}
}

func TestEndUnsavedPush_ASessionThatChangedUnderTheSlotKeepsItself(t *testing.T) {
	f := pushSetup(t, "pushrace")
	f.signOutFails(pushDown)
	f.signOutFails(pushDown)
	endUnsavedSweep = func(dest, name, pass, uid string) string {
		t.Error("the sweep ran although the licence was withdrawn")
		return "OK"
	}
	// A save landing before the handler's re-check withdraws the run; the handler reads it at the top and again under
	// the slot, so withdraw it from the slot wait's seam: hold the slot, release the run, then free the slot.
	laneRW.slot <- struct{}{}
	done := make(chan string, 1)
	goSafe("push-test-end", func() { done <- f.end() })
	resetPushStuck()
	<-laneRW.slot
	if got := <-done; got != "ERR-NOTREFUSED" && got != "BUSY slot" {
		t.Fatalf("got %q, want the end refused once the run was gone", got)
	}
	f.untouched("run withdrawn")
}

func TestEndUnsavedPush_AFinalRefusalStillPublishesTheWalletFirst(t *testing.T) {
	f := pushSetup(t, "pushfinal")
	f.refuse("ERR-REFUSED PARTIAL:de=refused", "de=shrink")
	if got := f.end(); got != "OK" {
		t.Fatalf("got %q, want OK", got)
	}
	if f.wallets != 1 {
		t.Errorf("endUnsavedWallet called %d times, want 1 for a FINAL refusal", f.wallets)
	}
}

func TestGetLogoffRefusal_PushLine(t *testing.T) {
	f := pushSetup(t, "pushwire")
	resetScopeSavedAt()
	noteScopesSaved("OK", 1728550000)
	disarmLogoffRefusal()
	if got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) }); got != "NONE" {
		t.Fatalf("nothing on record: %q, want NONE", got)
	}
	notePushFailed(f.name, euUID)
	notePushFailed(f.name, euUID)
	got := ropReply(t, func(c net.Conn) { handleGetLogoffRefusal(c, f.dest) })
	if got != "SAVED 1728550000\nPUSH 2" {
		t.Fatalf("got %q, want the SAVED line then PUSH 2", got)
	}
	if s := formatLogoffRefusal(nil, 3, 2, nil); !strings.HasSuffix(s, "MEDIA 3\nPUSH 2\n") {
		t.Errorf("PUSH must follow MEDIA: %q", s)
	}
	if s := formatLogoffRefusal(nil, 0, 0, nil); strings.Contains(s, "PUSH") {
		t.Errorf("PUSH written for a zero run: %q", s)
	}
}

func TestVerdictSavedAny(t *testing.T) {
	for out, want := range map[string]bool{
		"OK":                         true,
		"ERR-PUSH":                   true,
		"ERR-PUSH PARTIAL:de=failed": true,
		"ERR-PUSH PARTIAL:vault=failed,de=failed,media=failed,sys=failed,apps=failed": false,
		"ERR-TIMEOUT": false,
		"SKIP-BUSY":   false,
	} {
		if got := verdictSavedAny(out); got != want {
			t.Errorf("verdictSavedAny(%q) = %v, want %v", out, got, want)
		}
	}
}

// The route's order is the rule: logoffSealFailed (recordSeal inside, which resets the run on a save) comes BEFORE the
// count, so a partly saved ERR-PUSH counts 1 and never licenses.
func TestEndUnsavedPush_RouteCountsAfterLogoffSealFailed(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "handleLogout")), "\n")
	sf, np := strings.Index(body, "logoffSealFailed(out)"), strings.Index(body, "notePushFailed(name, uid)")
	if sf < 0 || np < 0 || sf > np {
		t.Errorf("logoffSealFailed at %d, notePushFailed at %d -- the count must come AFTER logoffSealFailed", sf, np)
	}
	rs := strings.Join(stripComments(funcBody(t, string(b), "recordSealLanded")), "\n")
	if !strings.Contains(rs, "verdictSavedAny(out)") || !strings.Contains(rs, "resetPushStuck()") {
		t.Error("recordSealLanded no longer resets the push run on a save")
	}
	if !strings.Contains(strings.Join(stripComments(funcBody(t, string(b), "resetSealStatus")), "\n"), "resetPushStuck()") {
		t.Error("resetSealStatus no longer resets the push run")
	}
}
