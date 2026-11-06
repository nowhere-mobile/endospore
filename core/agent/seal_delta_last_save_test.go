package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261117-18, #55, backlog row 'Your data's "That save captured ~X across N areas" can describe a different save
// from the "Last saved <ago>" above it': SEAL-DELTA sends lastSaveB / lastSaveN only while the manual save they describe
// is still the last seal to land. Every assertion reads the handler's JSON. The session is a local one, so SEAL-DELTA
// reads no store and starts no refresh.

// sdlsComp1 is 1800 bytes across 2 areas; sdlsComp2 is 4600 bytes across 3.
var (
	sdlsComp1 = map[string]int64{"vault": 1500, "media": 300}
	sdlsComp2 = map[string]int64{"vault": 4000, "media": 500, "de": 100}
)

// sdlsEnv starts a local session of the test's own profile with an empty $NOWHERE_STATE and no save summary.
func sdlsEnv(t *testing.T, profile string) string {
	t.Helper()
	siresetEnv(t)
	seq := lastSaveSeq.Load()
	t.Cleanup(func() { lastSaveSeq.Store(seq) })
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Cleanup(func() { resetSealStatus(); resetSealSignals() })
	dest := t.TempDir()
	if err := markRoamSession(dest, profile, "pw-"+profile, "33", ""); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".localsession"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	resetSealStatus()
	resetSealSignals()
	return dest
}

// sdlsManual is the manual seal's bookkeeping once its worker returned out, with the test's own composition.
func sdlsManual(out string, comp map[string]int64) {
	manualSaveDone(out, comp, time.Now().Unix())
}

// sdlsReply asks SEAL-DELTA and returns lastSaveB and lastSaveN, and whether each key is present at all.
func sdlsReply(t *testing.T, dest string) (b, n float64, hasB, hasN bool) {
	t.Helper()
	reply := ropReply(t, func(c net.Conn) { handleSealDelta(c, dest) })
	nl := strings.IndexByte(reply, '\n')
	if nl < 0 || !strings.HasPrefix(reply, "OK ") {
		t.Fatalf("SEAL-DELTA reply %q", reply)
	}
	body := reply[nl+1:]
	if want := fmt.Sprintf("OK %d", len(body)); reply[:nl] != want {
		t.Fatalf("frame %q for a %d-byte body", reply[:nl], len(body))
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(body), &m); err != nil {
		t.Fatal(err)
	}
	if m["session"] != "local" {
		t.Fatalf("session = %v, want local (no store read)", m["session"])
	}
	vb, hasB := m["lastSaveB"]
	vn, hasN := m["lastSaveN"]
	if hasB {
		b, _ = vb.(float64)
	}
	if hasN {
		n, _ = vn.(float64)
	}
	return b, n, hasB, hasN
}

func sdlsWant(t *testing.T, dest string, wantB, wantN float64) {
	t.Helper()
	b, n, hasB, hasN := sdlsReply(t, dest)
	if !hasB || !hasN || b != wantB || n != wantN {
		t.Fatalf("SEAL-DELTA lastSaveB=%v (present %v) lastSaveN=%v (present %v), want %v and %v", b, hasB, n, hasN, wantB, wantN)
	}
}

func sdlsWantNone(t *testing.T, dest string) {
	t.Helper()
	if b, n, hasB, hasN := sdlsReply(t, dest); hasB || hasN {
		t.Fatalf("SEAL-DELTA lastSaveB=%v (present %v) lastSaveN=%v (present %v), want neither key", b, hasB, n, hasN)
	}
}

// (a) A landed manual save: the line describes it.
func TestSealDeltaLastSaveManualLanded(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-a")
	sdlsManual("OK", sdlsComp1)
	sdlsWant(t, dest, 1800, 2)
}

// (b) The row's CLOSES WHEN: a periodic seal lands after the manual one, so "Last saved" is the periodic one and the
// line, which describes the manual one, is dropped.
func TestSealDeltaLastSaveDroppedByLaterPeriodic(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-b")
	sdlsManual("OK", sdlsComp1)
	recordSeal("OK")
	sdlsWantNone(t, dest)
}

// (c) A periodic seal that did not land does not move "Last saved", so the line stays.
func TestSealDeltaLastSaveKeptByFailedPeriodic(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-c1")
	sdlsManual("OK", sdlsComp1)
	recordSeal("ERR-PUSH")
	sdlsWant(t, dest, 1800, 2)
}

func TestSealDeltaLastSaveKeptBySupersededPeriodic(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-c2")
	sdlsManual("OK", sdlsComp1)
	recordSeal("SKIP-SUPERSEDED")
	sdlsWant(t, dest, 1800, 2)
}

// (d) A second landed manual save: the line describes the second one.
func TestSealDeltaLastSaveSecondManual(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-d")
	sdlsManual("OK", sdlsComp1)
	sdlsManual("OK", sdlsComp2)
	sdlsWant(t, dest, 4600, 3)
}

// (e) A manual save that fails after a landed one: the landed one is still the last to land.
func TestSealDeltaLastSaveFailedManualKeepsLanded(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-e")
	sdlsManual("OK", sdlsComp1)
	sdlsManual("ERR-PUSH", sdlsComp2)
	sdlsWant(t, dest, 1800, 2)
}

// (f) No summary yet, and a manual save that fails: nothing to describe.
func TestSealDeltaLastSaveFailedManualAlone(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-f")
	sdlsManual("ERR-PUSH", sdlsComp1)
	sdlsWantNone(t, dest)
}

// (g) A landed manual save, a periodic landing, then a failed manual save: the older summary is not revived.
func TestSealDeltaLastSaveNotRevived(t *testing.T) {
	dest := sdlsEnv(t, "sdlast-g")
	sdlsManual("OK", sdlsComp1)
	recordSeal("OK")
	sdlsManual("ERR-PUSH", sdlsComp2)
	sdlsWantNone(t, dest)
}
