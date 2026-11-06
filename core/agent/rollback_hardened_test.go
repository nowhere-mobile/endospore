package main

import (
	"os"
	"strings"
	"testing"
)

// NWP-20261005-05: "Restore a snapshot" failed on every hardened (secure-element) profile with "no slot opens
// for this profile on this device" (lynx 2026-10-05, odtest57). handleRollback captured the session's secret
// before removing the .roamsession marker -- the comment says so, "capture before clearing markers (hardened
// vaults)" -- and then handed rollbackHead seFromSession(dest), which re-reads the marker it had just removed.

// The behaviour the fix relies on: with the secret, rollbackHead opens a hardened vault and rolls it.
func TestRollbackHeadOpensAHardenedVaultWithItsSecret(t *testing.T) {
	base := newHTTPStore(t)
	const name, pass = "rollse", "horse battery staple correct"
	se := hardenedWithData(t, base, name, pass) // a data seal, then the enrolment: two versions in the history
	if _, err := rollbackHead(base, name, pass, 0, nil); err == nil {
		t.Fatal("rollbackHead opened a hardened vault with no secret -- then this test proves nothing")
	}
	if _, err := rollbackHead(base, name, pass, 0, se); err != nil {
		t.Fatalf("rollbackHead could not roll a hardened vault WITH its secret: %v", err)
	}
}

// The wiring, which a behavioural test cannot reach: handleRollback hardcodes the "s3" store. The defect was an
// argument, so pin the argument and the order it depends on.
func TestHandleRollbackPassesTheSecretItCapturedBeforeClearingTheMarker(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "handleRollback"))
	capture, clear, call := -1, -1, -1
	for i, l := range body {
		s := strings.TrimSpace(l)
		switch {
		case s == "seSecret := readRoamSessionSE(dest) // capture before clearing markers (hardened vaults)":
			capture = i
		case s == `os.Remove(filepath.Join(dest, ".roamsession"))`:
			clear = i
		case strings.HasPrefix(s, "nv, err = rollbackHead("):
			call = i
			if s != `nv, err = rollbackHead("s3", name, pass, ver, seFromHex(seSecret))` {
				t.Errorf("rollbackHead is not handed the captured secret: %s", s)
			}
		}
	}
	if capture < 0 || clear < 0 || call < 0 {
		t.Fatalf("handleRollback changed shape (capture %d, clear %d, call %d) -- this test is stale, not the code", capture, clear, call)
	}
	if !(capture < clear && clear < call) {
		t.Errorf("order is capture %d, clear %d, call %d; the secret must be read before the marker goes", capture, clear, call)
	}
	for _, l := range body[clear:] {
		if strings.Contains(l, "seFromSession(dest)") {
			t.Errorf("after the marker is removed, handleRollback still re-reads it: %s", strings.TrimSpace(l))
		}
	}
}
