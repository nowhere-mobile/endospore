package main

import (
	"testing"
	"time"
)

// NWP-20260901-26 (#145 S2): the under-slot supersede check. Every syncLoop guard is an ENTRY guard, so a
// periodic tick that passed it microseconds before a logoff arrived still ran a full redundant cycle --
// measured on lynx as EVERY logoff running the entire seal twice, the second byte-identical
// (NWP-20260829-32). By slot-time the periodic run is redundant iff its announce is no longer its own.
func TestSealSuperseded(t *testing.T) {
	resetSealState(t)
	cases := []struct {
		name   string
		intent string
		kind   string // the announce at slot-time
		want   bool
	}{
		{"periodic overwritten by a logoff", "periodic", "logoff", true},
		{"periodic overwritten by a manual", "periodic", "manual", true},
		// "" = another seal seized the announce AND ran to completion while we queued: re-sealing the
		// identical tree is the -32 double. This case IS the double-logoff fix.
		{"periodic after the superseder finished", "periodic", "", true},
		{"periodic still owns its announce", "periodic", "periodic", false},
		// User-initiated seals always run: a human asked, and the answer to "again?" is yes.
		{"manual never supersedes", "manual", "logoff", false},
		{"unannounced legacy caller never supersedes", "", "logoff", false},
	}
	for _, c := range cases {
		pendingReapMu.Lock()
		sealRunKind = c.kind
		pendingReapMu.Unlock()
		if got := sealSuperseded(c.intent); got != c.want {
			t.Errorf("%s: sealSuperseded(%q) with kind=%q = %v, want %v", c.name, c.intent, c.kind, got, c.want)
		}
	}
}

// clearSealRunIf must be compare-and-clear: a finishing periodic seal must not erase a logoff's announce
// that overwrote it mid-run -- that erasure is what turned the supersede signal back off.
func TestClearSealRunIf(t *testing.T) {
	resetSealState(t)
	setSealRun("periodic")
	pendingReapMu.Lock()
	sealRunKind = "logoff" // a logoff seized the announce while the periodic ran
	pendingReapMu.Unlock()
	clearSealRunIf("periodic") // the periodic finishes and releases only what is its own
	pendingReapMu.Lock()
	k := sealRunKind
	pendingReapMu.Unlock()
	if k != "logoff" {
		t.Fatalf("clearSealRunIf erased another run's announce: kind=%q, want logoff", k)
	}
	clearSealRunIf("logoff")
	pendingReapMu.Lock()
	k = sealRunKind
	pendingReapMu.Unlock()
	if k != "" {
		t.Fatalf("clearSealRunIf failed to clear its own announce: kind=%q", k)
	}
}

// The expiry: a wedged (announced, never finished) seal stops suppressing after sealRunExpiry -- on an
// amnesiac device, silently ceasing to seal is the worst outcome there is. The same term gates the BUSY
// answer, so a wedged run cannot refuse "Back up now" forever either.
func TestSealRunExpiryUnsuppresses(t *testing.T) {
	resetSealState(t)
	pendingReapMu.Lock()
	sealInFlight = true
	sealRunKind, sealRunAt = "manual", time.Now().Add(-sealRunExpiry-time.Minute)
	inFlEff := sealInFlight && (sealRunAt.IsZero() || time.Since(sealRunAt) <= sealRunExpiry)
	busyTerm := sealRunKind != "" && (sealRunAt.IsZero() || time.Since(sealRunAt) <= sealRunExpiry)
	pendingReapMu.Unlock()
	if inFlEff {
		t.Fatal("expired run still suppresses the periodic loop")
	}
	if busyTerm {
		t.Fatal("expired run still refuses a manual tap")
	}
	pendingReapMu.Lock()
	sealRunAt = time.Now().Add(-5 * time.Minute)
	inFlEff = sealInFlight && (sealRunAt.IsZero() || time.Since(sealRunAt) <= sealRunExpiry)
	pendingReapMu.Unlock()
	if !inFlEff {
		t.Fatal("a healthy 5-minute-old run must still suppress")
	}
}
