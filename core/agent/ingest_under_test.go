package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

// GET-INGEST never reads the .under dir of a mapped staging dir: the daemon's MLS level cannot reach it on a
// device. It reads the overlay mountpoint, for the snapshot's names only (NWP-20261203-15; was NWP-20261013-30).
// The fixture is ingestOverlayFixture (ingest_snapshot_test.go).

func TestGetIngestMappedReadsOverlayNotUnder(t *testing.T) {
	for _, viaParent := range []bool{false, true} {
		plain, hidden, mapOn := ingestOverlayFixture(t, viaParent)
		ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("BEGIN:VCARD\nEND:VCARD\n"))
		ingestSnapshotStaged("12")
		mapOn()
		ingestWrite(t, filepath.Join(plain, "big.vcf"), []byte("stub"))
		ingestWrite(t, filepath.Join(hidden, "other.vcf"), []byte("under"))
		reply := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000+10001) })
		got := ingestReplyFiles(t, reply)
		if len(got) != 1 || got["small.vcf"] != "BEGIN:VCARD\nEND:VCARD\n" {
			t.Fatalf("viaParent=%v: want only the snapshot's file from the overlay path, got %q", viaParent, got)
		}
	}
}

func TestGetIngestMappedButUnreadableIsNone(t *testing.T) {
	plain, hidden, mapOn := ingestOverlayFixture(t, false)
	ingestWrite(t, filepath.Join(plain, "small.vcf"), []byte("x"))
	ingestSnapshotStaged("12")
	mapOn()
	// a dead mountpoint: the plain dir is gone, and the hidden dir still holds the file. It must NOT be served.
	if err := os.RemoveAll(plain); err != nil {
		t.Fatal(err)
	}
	ingestWrite(t, filepath.Join(hidden, "small.vcf"), []byte("x"))
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
