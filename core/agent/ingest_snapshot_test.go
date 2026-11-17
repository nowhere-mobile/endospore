package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// GET-INGEST reads an overlaid staging dir through the overlay, only for the names kickMediad's snapshot
// recorded before it asked mediad to start, size-checked; the hidden .under path is never read; every NONE
// other than "nothing staged" logs its reason class (NWP-20261203-15).

const ingestSnapPeer12 = 12*100000 + 10001

// ingestOverlayFixture redirects ingestMediaBase to a fresh tree and clears the snapshot record. plain is user
// 12's staging dir; hidden is a .under stand-in outside the media base. mapOn injects the mountpoint -> hidden
// map (keyed on plain, or on its parent when viaParent). Every seam is restored in t.Cleanup.
func ingestOverlayFixture(t *testing.T, viaParent bool) (plain, hidden string, mapOn func()) {
	t.Helper()
	oldBase, oldFn, oldRead, oldLog := ingestMediaBase, ingestUndersFn, ingestReadFn, ingestLogf
	ingestSnapMu.Lock()
	oldRec := ingestSnapRec
	ingestSnapRec = nil
	ingestSnapMu.Unlock()
	t.Cleanup(func() {
		ingestMediaBase, ingestUndersFn, ingestReadFn, ingestLogf = oldBase, oldFn, oldRead, oldLog
		ingestSnapMu.Lock()
		ingestSnapRec = oldRec
		ingestSnapMu.Unlock()
	})
	root := t.TempDir()
	ingestMediaBase = filepath.Join(root, "media")
	ingestUndersFn = func() map[string]string { return nil }
	ingestLogf = func(string, ...any) {}
	plain = filepath.Join(ingestMediaBase, "12", ingestDir)
	hidden = filepath.Join(root, "under", "Imported")
	for _, d := range []string{plain, hidden} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	key, val := plain, hidden
	if viaParent {
		key, val = filepath.Dir(plain), filepath.Dir(hidden)
	}
	mapOn = func() { ingestUndersFn = func() map[string]string { return map[string]string{key: val} } }
	return plain, hidden, mapOn
}

func ingestWrite(t *testing.T, p string, b []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// ingestRecordReads wraps the read seam and returns every path GET-INGEST asked it to open.
func ingestRecordReads(t *testing.T) func() []string {
	t.Helper()
	var mu sync.Mutex
	var paths []string
	ingestReadFn = func(p string, max int64) ([]byte, bool) {
		mu.Lock()
		paths = append(paths, p)
		mu.Unlock()
		return ingestReadStaged(p, max)
	}
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), paths...)
	}
}

// ingestCaptureLog replaces the log seam and returns the lines written through it.
func ingestCaptureLog(t *testing.T) func() []string {
	t.Helper()
	var mu sync.Mutex
	var lines []string
	ingestLogf = func(format string, a ...any) {
		mu.Lock()
		lines = append(lines, fmt.Sprintf(format, a...))
		mu.Unlock()
	}
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), lines...)
	}
}

func ingestAsk(t *testing.T, peer int) string {
	t.Helper()
	return ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, peer) })
}

func TestGetIngestOverlayServesOnlySnapshotNames(t *testing.T) {
	plain, _, mapOn := ingestOverlayFixture(t, false)
	ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("BEGIN:VCARD\nEND:VCARD\n"))
	ingestSnapshotStaged("12")
	mapOn()
	// the deferred stub appears once mediad mounts; zero bytes, so only the name filter keeps it out
	ingestWrite(t, filepath.Join(plain, "big.vcf"), nil)
	reads := ingestRecordReads(t)
	got := ingestReplyFiles(t, ingestAsk(t, ingestSnapPeer12))
	if len(got) != 1 || got["small.vcf"] != "BEGIN:VCARD\nEND:VCARD\n" {
		t.Fatalf("want only the snapshot's small.vcf, got %q", got)
	}
	for _, p := range reads() {
		if filepath.Base(p) == "big.vcf" {
			t.Fatalf("the deferred stub was opened: %q", p)
		}
	}
}

func TestGetIngestMappedNeverReadsUnder(t *testing.T) {
	for _, viaParent := range []bool{false, true} {
		t.Run(fmt.Sprintf("viaParent=%v", viaParent), func(t *testing.T) {
			plain, hidden, mapOn := ingestOverlayFixture(t, viaParent)
			ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("real"))
			ingestSnapshotStaged("12")
			ingestWrite(t, filepath.Join(hidden, "small.vcf"), []byte("real"))
			ingestWrite(t, filepath.Join(hidden, "hidden-only.vcf"), []byte("under"))
			mapOn()
			reads := ingestRecordReads(t)
			got := ingestReplyFiles(t, ingestAsk(t, ingestSnapPeer12))
			if len(got) != 1 || got["small.vcf"] != "real" {
				t.Fatalf("want only small.vcf from the plain path, got %q", got)
			}
			for _, p := range reads() {
				if p == hidden || strings.HasPrefix(p, hidden+string(filepath.Separator)) {
					t.Fatalf("GET-INGEST opened the hidden path: %q", p)
				}
			}
		})
	}
}

func TestIngestSnapshotSkippedWhenMapped(t *testing.T) {
	plain, _, mapOn := ingestOverlayFixture(t, false)
	ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("12345"))
	ingestSnapshotStaged("12")
	mapOn()
	ingestWrite(t, filepath.Join(plain, "big.vcf"), []byte("stub"))
	ingestSnapshotStaged("12")
	snap, ok := ingestSnapshotFor("12")
	if !ok || len(snap) != 1 || snap["small.vcf"] != 5 {
		t.Fatalf("want the pre-mount snapshot {small.vcf: 5}, got %v (ok=%v)", snap, ok)
	}
}

func TestGetIngestSnapshotOtherUidIsNone(t *testing.T) {
	plain, _, _ := ingestOverlayFixture(t, false)
	ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("12345"))
	ingestSnapshotStaged("12")
	plain13 := filepath.Join(ingestMediaBase, "13", ingestDir)
	ingestWrite(t, filepath.Join(plain13, "small.vcf"), []byte("abcde"))
	hidden13 := filepath.Join(t.TempDir(), "Imported")
	ingestUndersFn = func() map[string]string { return map[string]string{plain13: hidden13} }
	logs := ingestCaptureLog(t)
	if r := ingestAsk(t, 13*100000+10001); r != "NONE\n" {
		t.Fatalf("user 13 has no snapshot of its own: want NONE, got %q", r)
	}
	l := logs()
	if len(l) != 1 || !strings.Contains(l[0], "user 13: NONE (mapped-no-snapshot)") {
		t.Fatalf("want one mapped-no-snapshot line for user 13, got %q", l)
	}
}

func TestGetIngestOverlaySizeMismatchSkipped(t *testing.T) {
	plain, _, mapOn := ingestOverlayFixture(t, false)
	ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("12345"))
	ingestSnapshotStaged("12")
	mapOn()
	ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("123456"))
	if r := ingestAsk(t, ingestSnapPeer12); r != "NONE\n" {
		t.Fatalf("a name whose size changed since the snapshot must not be served, got %q", r)
	}
}

func TestGetIngestNoneReasonLogged(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T) int // returns the peer uid
		want  string                 // "" = no line at all
	}{
		{"no-peer", func(t *testing.T) int {
			ingestOverlayFixture(t, false)
			return 0
		}, "user ?: NONE (no-peer)"},
		{"dir-refused", func(t *testing.T) int {
			plain, _, _ := ingestOverlayFixture(t, false)
			real := filepath.Join(t.TempDir(), "elsewhere")
			ingestWrite(t, filepath.Join(real, "Imported", "a.vcf"), []byte("x"))
			if err := os.RemoveAll(filepath.Dir(plain)); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(real, filepath.Dir(plain)); err != nil {
				t.Fatal(err)
			}
			return ingestSnapPeer12
		}, "user 12: NONE (dir-refused)"},
		{"list-failed", func(t *testing.T) int {
			if os.Geteuid() == 0 {
				t.Skip("root ignores the dir mode")
			}
			plain, _, mapOn := ingestOverlayFixture(t, false)
			ingestWrite(t, filepath.Join(plain, "a.vcf"), []byte("x"))
			ingestSnapshotStaged("12")
			mapOn()
			if err := os.Chmod(plain, 0o000); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { os.Chmod(plain, 0o755) })
			return ingestSnapPeer12
		}, "user 12: NONE (list-failed)"},
		{"mapped-no-snapshot", func(t *testing.T) int {
			plain, _, mapOn := ingestOverlayFixture(t, false)
			ingestWrite(t, filepath.Join(plain, "a.vcf"), []byte("x"))
			mapOn()
			return ingestSnapPeer12
		}, "user 12: NONE (mapped-no-snapshot)"},
		{"none-readable", func(t *testing.T) int {
			plain, _, mapOn := ingestOverlayFixture(t, false)
			ingestWrite(t, filepath.Join(plain, "a.vcf"), []byte("x"))
			ingestSnapshotStaged("12")
			mapOn()
			ingestWrite(t, filepath.Join(plain, "a.vcf"), []byte("xy"))
			return ingestSnapPeer12
		}, "user 12: NONE (none-readable)"},
		{"served-overlay", func(t *testing.T) int {
			plain, _, mapOn := ingestOverlayFixture(t, false)
			ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("x"))
			ingestSnapshotStaged("12")
			mapOn()
			ingestWrite(t, filepath.Join(plain, "big.vcf"), []byte("stub"))
			return ingestSnapPeer12
		}, "user 12: served 1 of 1 staged file(s) via overlay"},
		{"served-plain", func(t *testing.T) int {
			plain, _, _ := ingestOverlayFixture(t, false)
			ingestWrite(t, filepath.Join(plain, "a.vcf"), []byte("x"))
			return ingestSnapPeer12
		}, "user 12: served 1 of 1 staged file(s) via plain"},
		{"unmapped-empty", func(t *testing.T) int {
			ingestOverlayFixture(t, false)
			return ingestSnapPeer12
		}, ""},
		{"unmapped-absent", func(t *testing.T) int {
			ingestOverlayFixture(t, false)
			if err := os.RemoveAll(filepath.Join(ingestMediaBase, "12")); err != nil {
				t.Fatal(err)
			}
			return ingestSnapPeer12
		}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			peer := c.setup(t)
			logs := ingestCaptureLog(t)
			ingestAsk(t, peer)
			l := logs()
			if c.want == "" {
				if len(l) != 0 {
					t.Fatalf("nothing staged must stay silent, got %q", l)
				}
				return
			}
			if len(l) != 1 || !strings.Contains(l[0], c.want) || !strings.Contains(l[0], "(NWP-20261203-15)") {
				t.Fatalf("want one line with %q, got %q", c.want, l)
			}
			for _, bad := range []string{"a.vcf", "small", "big", ingestMediaBase, string(filepath.Separator)} {
				if strings.Contains(l[0], bad) {
					t.Fatalf("log line leaks %q: %q", bad, l[0])
				}
			}
		})
	}
}

func TestKickMediadSnapshotsBeforeStart(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", src, 0)
	if err != nil {
		t.Fatal(err)
	}
	var body string
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == "kickMediad" && fd.Recv == nil {
			body = string(src[fset.Position(fd.Body.Pos()).Offset:fset.Position(fd.Body.End()).Offset])
		}
	}
	if body == "" {
		t.Fatal("kickMediad not found in main.go")
	}
	call := "ingestSnapshotStaged(uid)"
	if n := strings.Count(body, call); n != 1 {
		t.Fatalf("kickMediad must call %s exactly once, found %d", call, n)
	}
	at := strings.Index(body, call)
	for _, before := range []string{"if coldLockInFlight() {", "isLocalSession(dest) {"} {
		i := strings.Index(body, before)
		if i < 0 || i > at {
			t.Fatalf("%s must come after %q (every early return), body:\n%s", call, before, body)
		}
	}
	if i := strings.Index(body, `"mediad.req.tmp"`); i < 0 || i < at {
		t.Fatalf("%s must come before the mediad.req write", call)
	}
}
