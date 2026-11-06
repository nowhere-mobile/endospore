package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A capspill orphaned by a seal killed in a PREVIOUS boot must go; one created during THIS boot must NOT,
// because roamd spawns its own agent for the periodic/logout seal and that process outlives a
// `ctl.restart nowhere_login` -- deleting a spill it is still streaming from would corrupt that seal.
// Found because /data/nowhere/spill held 1.0 GB of files dated 11-13 Aug, still present on the 25th
// (NWP-20260825-12).
func TestSweepStaleSpillsOnlyTakesPreBootFiles(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_SPILL", dir)

	boot, ok := bootStartedAt()
	if !ok {
		t.Skip("sysinfo(2) gave no uptime here")
	}

	write := func(name string, mod time.Time) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mod, mod); err != nil {
			t.Fatal(err)
		}
		return p
	}

	stale := write("capspill-fromlastboot", boot.Add(-2*time.Hour))
	live := write("capspill-thisboot", time.Now())
	other := write("something-else", boot.Add(-2*time.Hour))

	sweepStaleSpills()

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Error("a pre-boot capspill must be swept")
	}
	if _, err := os.Stat(live); err != nil {
		t.Error("a capspill from THIS boot must survive -- another agent may be streaming from it")
	}
	if _, err := os.Stat(other); err != nil {
		t.Error("a non-capspill file must never be touched")
	}
}
