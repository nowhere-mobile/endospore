package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

// GET-INGEST reads the .under real dir of a mapped staging dir, never the media overlay (NWP-20261013-30).

// ingestUnderTree builds an overlay dir holding a stub that fails any open (mode 000) and a .under dir of
// real files, and injects a map pointing the overlay (or its parent, when viaParent) at the .under dir.
func ingestUnderTree(t *testing.T, viaParent bool, real map[string][]byte) (overlay, under string) {
	t.Helper()
	old, oldFn := ingestMediaBase, ingestUndersFn
	ingestMediaBase = t.TempDir()
	t.Cleanup(func() { ingestMediaBase, ingestUndersFn = old, oldFn })
	overlay = filepath.Join(ingestMediaBase, "12", ingestDir)
	if err := os.MkdirAll(overlay, 0o755); err != nil {
		t.Fatal(err)
	}
	stub := filepath.Join(overlay, "big.vcf")
	if err := os.WriteFile(stub, []byte("stub"), 0o000); err != nil {
		t.Fatal(err)
	}
	under = filepath.Join(t.TempDir(), "under")
	if err := os.MkdirAll(under, 0o755); err != nil {
		t.Fatal(err)
	}
	for n, b := range real {
		if err := os.WriteFile(filepath.Join(under, n), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	key, val := overlay, under
	if viaParent {
		key = filepath.Dir(overlay)
		val = filepath.Dir(under)
		if err := os.Rename(under, filepath.Join(val, "Imported")); err != nil {
			t.Fatal(err)
		}
		under = filepath.Join(val, "Imported")
	}
	ingestUndersFn = func() map[string]string { return map[string]string{key: val} }
	return overlay, under
}

func TestGetIngestReadsUnderNotOverlay(t *testing.T) {
	for _, viaParent := range []bool{false, true} {
		ingestUnderTree(t, viaParent, map[string][]byte{"small.vcf": []byte("BEGIN:VCARD\nEND:VCARD\n")})
		reply := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000+10001) })
		got := ingestReplyFiles(t, reply)
		if len(got) != 1 || got["small.vcf"] != "BEGIN:VCARD\nEND:VCARD\n" {
			t.Fatalf("viaParent=%v: want only the real file, got %q", viaParent, got)
		}
	}
}

func TestGetIngestMappedButUnreadableIsNone(t *testing.T) {
	_, under := ingestUnderTree(t, false, map[string][]byte{"small.vcf": []byte("x")})
	if err := os.RemoveAll(under); err != nil {
		t.Fatal(err)
	}
	// the overlay path still holds a readable file: it must NOT be served as a fallback
	if err := os.Chmod(filepath.Join(ingestMediaBase, "12", ingestDir, "big.vcf"), 0o644); err != nil {
		t.Fatal(err)
	}
	reply := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000+10001) })
	if reply != "NONE\n" {
		t.Fatalf("want NONE, got %q", reply)
	}
}

func TestGetIngestNoMapReadsPlainPath(t *testing.T) {
	ingestTestTree(t, "12", map[string][]byte{"a.vcf": []byte("plain")})
	old := ingestUndersFn
	ingestUndersFn = func() map[string]string { return nil }
	t.Cleanup(func() { ingestUndersFn = old })
	reply := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000+10001) })
	if got := ingestReplyFiles(t, reply); got["a.vcf"] != "plain" || len(got) != 1 {
		t.Fatalf("got %q", got)
	}
}
