package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// DIA-20260813-01 (#113/#125). The progress line grows a trailing scope keyword, the seal-status path reads
// the agent's FILE rather than only the relay's last delivery, and the logoff watchdog checks the file's
// mtime before it may reboot. These pin the format and the two liveness properties.
//
// Why they matter, concretely: on 2026-08-12 the relay delivered NOTHING for an entire logoff seal while the
// agent wrote progress the whole time. The bar froze (at the previous scope's 100%), the stall watchdog saw
// six minutes of secondhand silence, and it REBOOTED a healthy ~400MB #apps upload -- destroying the only
// copy of five apps' code. Firsthand evidence of life was one os.Stat away the entire time.

func TestProgScopeOfMapsEveryScope(t *testing.T) {
	// DIA-20260813-02: tokens are DISTINCT per scope and match roamd's PARTIAL vocabulary -- the chooser's
	// segmented bar addresses one segment per token, so a token naming two scopes (the first cut's "files"
	// for both vault and #de) cannot work. Labels are the chooser's job; the wire carries identity.
	for _, c := range []struct{ profile, want string }{
		{"alice", "vault"},
		{"alice#de", "de"},
		{"alice#media", "media"},
		{"alice#sys", "sys"},
		{"alice#apps", "apps"},
		{"alice#keys", "keys"},
		{"alice#wallet", "wallet"},
	} {
		if got := progScopeOf(c.profile); got != c.want {
			t.Errorf("progScopeOf(%q) = %q, want %q", c.profile, got, c.want)
		}
	}
}

func TestWriteProgAppendsTheScopeLast(t *testing.T) {
	// LAST is load-bearing: the chooser's phase parser reads field position 1 and its byte parser scans for
	// the trailing numeric pair, so appending at the end is what keeps old and new lines parseable by both
	// old and new readers. A scope anywhere else breaks one of them.
	dir := t.TempDir()
	f := filepath.Join(dir, "prog")
	t.Setenv("NOWHERE_PROGRESS", f)
	setProgPhase("save")
	defer setProgPhase("")
	setProgScope("apps")
	defer setProgScope("")

	writeProg(1234, 5678)
	b, err := os.ReadFile(f)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(b), "save 1234 5678 apps\n"; got != want {
		t.Fatalf("progress line = %q, want %q", got, want)
	}

	// No scope set (a restore, or host CLI) -> the old 3-field line, byte-identical to before.
	setProgScope("")
	writeProg(9, 10)
	b, _ = os.ReadFile(f)
	if got, want := string(b), "save 9 10\n"; got != want {
		t.Fatalf("scopeless line = %q, want %q", got, want)
	}
}

func TestWriteProgStillSkipsEmptyTotals(t *testing.T) {
	// total<=0 frames are suppressed at the writer (DIA-20260625-04) -- the scope field must not have
	// re-introduced them, or the bar flickers number-less between scopes again.
	dir := t.TempDir()
	f := filepath.Join(dir, "prog")
	t.Setenv("NOWHERE_PROGRESS", f)
	setProgScope("apps")
	defer setProgScope("")
	writeProg(0, 0)
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Fatal("a total<=0 frame was written; the writer's empty-push suppression regressed")
	}
}

func TestWatchdogLivenessAcceptsAFreshFileOverAStaleRelay(t *testing.T) {
	// The watchdog logic distilled: liveness = the LATER of the relay's stamp and the file's mtime. This is
	// the property that makes "reboot on secondhand silence while firsthand evidence exists" impossible.
	dir := t.TempDir()
	f := filepath.Join(dir, "roam.progress")
	if err := os.WriteFile(f, []byte("save 1 2 apps\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	staleRelay := time.Now().Add(-10 * time.Minute) // the 2026-08-12 shape: relay dead since seal start
	last := staleRelay
	if fi, err := os.Stat(f); err == nil && fi.ModTime().After(last) {
		last = fi.ModTime()
	}
	if !last.After(staleRelay) {
		t.Fatal("a fresh progress file did not advance liveness past a dead relay -- the watchdog would still reboot a healthy seal")
	}
	// And with NO file (roamd truly gone), the stale relay stamp stands and the watchdog may act.
	os.Remove(f)
	last2 := staleRelay
	if fi, err := os.Stat(f); err == nil && fi.ModTime().After(last2) {
		last2 = fi.ModTime()
	}
	if !last2.Equal(staleRelay) {
		t.Fatal("liveness advanced with no evidence -- a genuinely hung seal would never be recovered")
	}
}
