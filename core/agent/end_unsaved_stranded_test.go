package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
)

// NWP-20261114-06, #19 of the 2026-10-22 entry in docs/product-decisions.md (Q016): END-UNSAVED for a session stranded
// by a security key enrolled on another phone (or by this phone losing its unlock) proceeds, and warns that credit
// added this session is lost. Before this slice publishWalletBeforeDiscard's key resolution found no slot, the plain
// error answered ERR-WALLET, and the session could not end from this phone. The publish is skipped ONLY when a vault
// head was read and no slot opens it AND the refusal on record is a stranded one; every other END-UNSAVED keeps
// today's order.

// strandedTokens are the four refusal reasons of a stranded seal (strandedReason).
var strandedTokens = []string{"locks-changed", "locks-changed-key", "unlock-lost", "unlock-lost-key"}

func TestEndUnsaved_AStrandedSessionEndsWithTheCreditLostReply(t *testing.T) {
	type tc struct {
		tok     string
		err     error
		verdict string
	}
	var cases []tc
	for _, tok := range strandedTokens {
		cases = append(cases, tc{tok, errWalletNoSlot, "ERR-REFUSED PARTIAL:vault=refused"})
	}
	// errors.Is, not ==: a wrapped sentinel still ends the session.
	cases = append(cases, tc{"locks-changed-key", fmt.Errorf("%w (wrapped)", errWalletNoSlot), "ERR-REFUSED PARTIAL:vault=refused"})
	for _, c := range cases {
		t.Run(c.tok+"/"+c.err.Error(), func(t *testing.T) {
			f := euSetup(t)
			f.refuse(c.verdict, "vault="+c.tok)
			f.walletEr = c.err
			if err := appendTokens(walletPathFor(f.dest), newBlindTokens()); err != nil {
				t.Fatal(err)
			}
			var got string
			log := captureStderr(t, func() { got = f.end() })
			if got != endUnsavedCreditLost {
				t.Fatalf("got %q, want %s -- a stranded session must end from this phone (#19, Q016)", got, endUnsavedCreditLost)
			}
			pendingReapMu.Lock()
			rp := pendingReapUID
			pendingReapMu.Unlock()
			if rp != euUID || roamSessionExists(f.dest) {
				t.Fatalf("the session was not ended (reap %q, marker present %v)", rp, roamSessionExists(f.dest))
			}
			if f.wallets != 1 {
				t.Errorf("the wallet step ran %d times, want 1", f.wallets)
			}
			if _, err := os.Stat(walletPathFor(f.dest)); err != nil {
				t.Errorf("the wallet file is gone (%v): an unsaved wallet must stay where it is", err)
			}
			f.noDrop(t, "nothing saved the wallet, so the file is the only copy of what it held")
			if !strings.HasPrefix(creditLostReply(f.dest), "NOTICE ") {
				t.Error("a stranded END over a wallet holding credit recorded no gate notice")
			}
			var lines []string
			for _, l := range strings.Split(log, "\n") {
				if strings.Contains(l, "NWP-20261114-06") && strings.Contains(l, "ending anyway") {
					lines = append(lines, l)
				}
			}
			if len(lines) != 1 || !strings.Contains(lines[0], endUnsavedCreditLost) || !strings.Contains(lines[0], "user "+euUID) {
				t.Fatalf("want one log line naming the uid, %s and NWP-20261114-06, got %q", endUnsavedCreditLost, lines)
			}
			for _, leak := range []string{f.name, f.pass} {
				if strings.Contains(lines[0], leak) {
					t.Errorf("the log line leaks %q: %s", leak, lines[0])
				}
			}
		})
	}
}

func TestEndUnsaved_ANoSlotWalletWithoutAStrandedRefusalKeepsTheSession(t *testing.T) {
	for _, c := range []struct{ verdict, guard string }{
		{"ERR-REFUSED PARTIAL:vault=refused", "vault=shrink"},
		{"ERR-REFUSED PARTIAL:de=refused", "de=no-receipt"},
	} {
		t.Run(c.guard, func(t *testing.T) {
			f := euSetup(t)
			f.refuse(c.verdict, c.guard)
			f.walletEr = errWalletNoSlot
			if got := f.end(); got != "ERR-WALLET" {
				t.Fatalf("got %q, want ERR-WALLET -- only a stranded refusal may skip the wallet publish", got)
			}
			f.untouched("a no-slot wallet without a stranded refusal")
			f.noDrop(t, "the session is kept")
		})
	}
}

func TestEndUnsaved_AStrandedSessionWhoseWalletSavesStillAnswersOK(t *testing.T) {
	f := euSetup(t)
	f.refuse("ERR-REFUSED PARTIAL:vault=refused", "vault=locks-changed-key")
	if got := f.end(); got != "OK" {
		t.Fatalf("got %q, want OK -- a stranded session whose wallet saved has lost no credit", got)
	}
	f.waitDrop(t, waitDropBound)
	if got := creditLostReply(f.dest); got != "NONE" {
		t.Errorf("a saved stranded END recorded a gate notice (%q)", got)
	}
}

// waitDropBound bounds the wait for the saved wallet's drop goroutine.
const waitDropBound = 2 * euDropGrace

// The `final` term of the stranded arm cannot be reached false today (push takes the first arm, and a refusal that
// is neither final nor push returns ERR-NOTREFUSED), so no behaviour test can convict its removal. It stays as a
// guard for a later change that lets a push-licensed end reach the wallet step; this pin keeps it there.
func TestEndUnsaved_TheStrandedArmNeedsAFinalRefusal(t *testing.T) {
	b, err := os.ReadFile("end_unsaved.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "handleEndUnsaved")), "\n")
	if want := "} else if errors.Is(err, errWalletNoSlot) && final && r.stranded() {"; !strings.Contains(body, want) {
		t.Fatalf("handleEndUnsaved no longer holds %q", want)
	}
}

func TestWalletNoDKErr(t *testing.T) {
	for _, c := range []struct {
		notRestored   bool
		v             *vault
		wantNR, wantS bool
	}{
		{true, &vault{}, true, false},
		{true, nil, true, false},
		{false, &vault{}, false, true},
		{false, nil, false, false},
	} {
		err := walletNoDKErr(c.notRestored, c.v)
		if err == nil {
			t.Fatalf("walletNoDKErr(%v, vault=%v) = nil", c.notRestored, c.v != nil)
		}
		if errors.Is(err, errWalletNotRestored) != c.wantNR || errors.Is(err, errWalletNoSlot) != c.wantS {
			t.Errorf("walletNoDKErr(%v, vault=%v) = %v, want notRestored=%v noSlot=%v",
				c.notRestored, c.v != nil, err, c.wantNR, c.wantS)
		}
	}
}

// The real call: a vault head whose pass slot a security-key enrolment dropped, on a session whose restore landed.
// walletFailSetup gives a legacy bare head (enrollFido2 refuses one), so it is migrated to a vault in place first.
// walletFailSetup resets capReadCache and blobCache and gives the test its own mock store. The stored wallet must be
// what it was before the call: nothing is published.
func TestPublishWalletBeforeDiscard_ASlotlessHeadIsErrWalletNoSlot(t *testing.T) {
	f := walletFailSetup(t)
	f.signIn(t)
	f.appendTwo(t)
	if _, ok := migrateVault("s3", walletFailName, walletFailPass); !ok {
		t.Fatal("fixture: the legacy head did not migrate to a vault")
	}
	t.Setenv("NOWHERE_FIDO2_HMAC", "")
	t.Setenv("NOWHERE_SE_SECRET", "")
	strandedEnrollKey(t, "s3", walletFailName, walletFailPass) // 2FA: the pass slot is dropped
	capReadCache = map[string]capEntry{}
	blobCache = nil
	before := f.storedBalance(t) // the migration's capWrite folded the session's wallet into the store
	if dk, v := resolveDKVault("s3", walletFailName, walletFailPass, nil); dk != nil || v == nil {
		t.Fatalf("fixture: want a vault head no slot opens, got dk=%v vault=%v", dk != nil, v != nil)
	}
	err := publishWalletBeforeDiscard(f.dest, walletFailName, walletFailPass, nil, f.gen())
	if !errors.Is(err, errWalletNoSlot) || errors.Is(err, errWalletNotRestored) {
		t.Fatalf("publishWalletBeforeDiscard over a slotless head = %v, want errWalletNoSlot", err)
	}
	f.assertStored(t, before, "a slotless head")
}

func TestLogoffRefusalStranded(t *testing.T) {
	rec := func(scope string, guards ...string) *logoffRefusalRec {
		return &logoffRefusalRec{reasons: map[string][]string{scope: guards}}
	}
	for _, tok := range strandedTokens {
		if !rec("vault", tok).stranded() {
			t.Errorf("vault=%s is not stranded", tok)
		}
		if !rec("de", "shrink", tok).stranded() {
			t.Errorf("de=shrink,%s is not stranded", tok)
		}
		if rec("sys", tok).stranded() || rec("apps", tok).stranded() {
			t.Errorf("a non-blocking scope's %s counts as stranded", tok)
		}
	}
	if rec("vault", "shrink", "no-receipt").stranded() {
		t.Error("a shrink refusal counts as stranded")
	}
	if (&logoffRefusalRec{}).stranded() {
		t.Error("a record with no reasons counts as stranded")
	}
	if (*logoffRefusalRec)(nil).stranded() {
		t.Error("a nil record counts as stranded")
	}
}
