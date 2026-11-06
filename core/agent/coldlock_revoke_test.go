package main

import "testing"

// NWP-20260902-04. The cold-lock revocation rule, table-tested, because it is the whole safety argument for
// making a committed cold lock revocable and it is exercised across two goroutines and a socket.
//
// The rule: an IDLE cold lock carries the elapsedRealtime it was DECIDED at; an authenticated unlock
// publishes the elapsedRealtime it happened at; the lock is revoked iff the unlock is at or after the
// decision. decidedAt == 0 means NOT abortable -- a plain COLD-LOCK ("lock now") or any older chooser -- and
// nothing may ever revoke it.
//
// Why a monotonic stamp and not an edge counter: the daemon can process the abort BEFORE the lock request it
// should revoke (COLD-LOCK-IDLE takes sessionMu, COLD-LOCK-ABORT is allowlisted and does not), and a counter
// sampled at request time cannot express that ordering. The "abort processed first" case below is exactly it.
func TestColdLockRevoked(t *testing.T) {
	for _, c := range []struct {
		name                 string
		decidedAt, presentAt int64
		want                 bool
	}{
		{"not abortable: explicit lock now, unlock after", 0, 9999, false},
		{"not abortable: explicit lock now, no unlock", 0, 0, false},
		{"no unlock at all", 5000, 0, false},
		{"unlock BEFORE the decision does not revoke", 5000, 4999, false},
		{"unlock exactly AT the decision revokes", 5000, 5000, true},
		{"unlock after the decision revokes", 5000, 5001, true},
		{"abort processed FIRST still revokes a later-sampled lock", 5000, 6000, true},
		{"a NEWER lock decided after the unlock survives", 7000, 6000, false},
	} {
		if got := coldLockRevoked(c.decidedAt, c.presentAt); got != c.want {
			t.Errorf("%s: coldLockRevoked(%d, %d) = %v, want %v", c.name, c.decidedAt, c.presentAt, got, c.want)
		}
	}
}
