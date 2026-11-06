package main

import "testing"

// NWP-20261008-08. Chester, 2026-10-08, answering the open question at the end of backlog row NWP-20260913-04: a
// session whose ONLY partial detail is sys=pending-placement counts as SAVED for the cold-lock wipe ("Wipe unless
// unsaved", 2026-10-04). The Google account is waiting in its hold for an on-demand Play services, so it is not in
// Android and nothing in the session can have changed it; the store holds the real account. NWP-20261008-07 made
// sealPartsOf drop the detail, and with it this branch went from KEEP to WIPE -- decided after the fact, so it is
// pinned here end to end: each seal verdict goes through recordSeal, and EVICT-RECHECK through the real dispatcher.
// A real partial still keeps the session.
func TestColdLockWipeCountsAPendingPlacementAsSaved(t *testing.T) {
	dest, calls := evictSetup(t, "ERR-EVICT-INCOMPLETE /data/system_ce/15/accounts_ce.db(PLAINTEXT)")
	sealMu.Lock()
	oldReason := sealReason
	sealMu.Unlock()
	t.Cleanup(func() {
		sealMu.Lock()
		sealReason = oldReason
		sealMu.Unlock()
	})
	t.Setenv("NOWHERE_STATE", t.TempDir()) // recordSeal takes the stashed gateway reason from here
	for _, c := range []struct{ verdict, want, what string }{
		{"OK PARTIAL:sys=pending-placement", "WIPE 15",
			"a save whose only detail is a pending account placement (decided 2026-10-08: nothing is unsaved)"},
		{"OK PARTIAL:apps=refused,sys=pending-placement", "KEEP UNSAVED last-save-partial",
			"a save that left #apps unstored"},
		{"OK", "WIPE 15", "a clean save"},
	} {
		recordSeal(c.verdict)
		if got := evictConn(t, dest, "EVICT-RECHECK\n15\n"); got != c.want {
			t.Errorf("a failed eviction after %s (%q) -> %q, want %q", c.what, c.verdict, got, c.want)
		}
	}
	if *calls != 3 {
		t.Errorf("evictcheck ran %d times, want 3", *calls)
	}
}
