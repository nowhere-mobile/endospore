package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261005-16: the legacy .session marker holds a plaintext name and passphrase. CREATE wrote it, the gate then
// signed in with ROAM-IN, and nothing read or removed it until the reboot. CREATE must take only the signal reset,
// and both roam-in paths must remove a marker they find.
func TestCreateWritesNoSessionMarker(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	create := strings.Join(stripComments(funcBody(t, src, "createAndReply")), "\n") // CREATE's and CREATE-CODE's create (NWP-20261010-04)
	if !strings.Contains(create, "resetSessionSignals()") {
		t.Fatal("handleCreate no longer resets the session signals (control): the next profile would see the last one's save time")
	}
	if strings.Contains(create, "markSession(") || strings.Contains(create, `".session"`) {
		t.Fatal("handleCreate writes the .session marker -- the new profile's passphrase would sit in the tmpfs until the reboot")
	}
	for _, fn := range []string{"handleRoamIn", "handleRoamInOffline"} {
		body := strings.Join(stripComments(funcBody(t, src, fn)), "\n")
		if !strings.Contains(body, `os.Remove(filepath.Join(dest, ".session"))`) {
			t.Errorf("%s does not remove a .session marker it finds", fn)
		}
	}
}

func TestResetSessionSignalsWritesNothing(t *testing.T) {
	dest := t.TempDir()
	lastSealOKAt.Store(42)
	resetSessionSignals()
	if lastSealOKAt.Load() != 0 {
		t.Fatal("resetSessionSignals left the previous session's seal signal")
	}
	if _, err := os.Stat(filepath.Join(dest, ".session")); !os.IsNotExist(err) {
		t.Fatalf("a .session marker exists (err %v)", err)
	}
	// markSession, the legacy login's, still writes it: the legacy LOGOFF reads it back.
	markSession(dest, "alice", "pw")
	if n, p := readSession(dest); n != "alice" || p != "pw" {
		t.Fatalf("legacy marker round-trip = %q %q", n, p)
	}
}
