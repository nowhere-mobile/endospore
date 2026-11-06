package main

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// #52 keystone: a media export is ONE ref pinning the existing (content-addressed) media manifest -- fetching
// it back yields the byte-identical tree with deferred files MATERIALIZED, and the export ref is NEVER part of
// the paid footprint (renewals never extend it; its own lease is marked for about 7 days, NWP-20261010-02).
func TestExportMediaRoundTrip(t *testing.T) {
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	t.Setenv("NOWHERE_MEDIA_MIN", "4096")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")

	base := newHTTPStore(t)
	name, pass := "expmedia", "export horse battery staple"

	// Seal a media tree under name#media (lazy-creates on first seal, like roamd's media phase): one bulk
	// (deferred) file + one small essential file.
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "Pictures"), 0o755); err != nil {
		t.Fatal(err)
	}
	big := prBytes(9 << 20) // multi-chunk deferred media
	if err := os.WriteFile(filepath.Join(src, "Pictures", "trip.jpg"), big, 0o644); err != nil {
		t.Fatal(err)
	}
	small := []byte("holiday notes: remember the lighthouse\n")
	if err := os.WriteFile(filepath.Join(src, "notes.txt"), small, 0o644); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#media", pass, src)

	// EXPORT: resolve the media head manifest + pin it under the export's media pointer (handleExportMedia's work).
	_, m, st := mediaHeadManifest(base, name, pass, nil)
	if st != mediaHeadOpen {
		t.Fatal("mediaHeadManifest: no media head after a seal")
	}
	if len(m.Deferred) != 1 {
		t.Fatalf("expected 1 deferred media file, got %d", len(m.Deferred))
	}
	files, bTotal, _, err := exportMedia(base, name, pass, nil)
	if err != nil || files != 1 || bTotal < int64(len(big)) {
		t.Fatalf("exportMedia: files=%d bytes=%d err=%v (want 1 file, >= %d bytes)", files, bTotal, err, len(big))
	}

	// FETCH: the website reference path -- full tree, deferred materialized, byte-identical.
	out := t.TempDir()
	if err := exportFetchMedia(base, name, pass, out); err != nil {
		t.Fatalf("exportFetchMedia: %v", err)
	}
	gotBig, err := os.ReadFile(filepath.Join(out, "Pictures", "trip.jpg"))
	if err != nil || !bytes.Equal(gotBig, big) {
		t.Fatalf("deferred media not materialized byte-identical: %d bytes err=%v", len(gotBig), err)
	}
	gotSmall, err := os.ReadFile(filepath.Join(out, "notes.txt"))
	if err != nil || !bytes.Equal(gotSmall, small) {
		t.Fatalf("essential file mismatch: %q err=%v", gotSmall, err)
	}

	// BILLING: the export ref must NOT be in the paid footprint -- it is transient by design; only the
	// profile's own objects (head/manifest/chunks) stay leased, so renewals never extend the export, whose
	// lease is marked to go about 7 days after it is made (NWP-20261010-02).
	fp, _ := profileFootprint(base, name+"#media", pass, nil)
	if len(fp) == 0 {
		t.Fatal("footprint unexpectedly empty for the media profile")
	}
	mediaPtr := exportMediaRef(deriveKey(name, pass))
	for ref := range fp {
		if strings.Contains(ref, "export/") || strings.Contains(ref, mediaPtr.name()) {
			t.Fatalf("footprint leases the export ref %q -- exports must never be paid footprint", ref)
		}
	}
}

// The daemon verb's guard paths: no session -> NONE; a local/offline session -> LOCAL (no store to export from).
func TestExportMediaGuards(t *testing.T) {
	dest := t.TempDir()
	cli, srv := net.Pipe()
	go func() { handleExportMedia(srv, dest); srv.Close() }()
	b, _ := io.ReadAll(cli)
	if got := strings.TrimSpace(string(b)); got != "NONE" {
		t.Fatalf("no session: got %q want NONE", got)
	}

	markRoamSession(dest, "x", "y", "12", "")
	markLocalSession(dest)
	cli2, srv2 := net.Pipe()
	go func() { handleExportMedia(srv2, dest); srv2.Close() }()
	b2, _ := io.ReadAll(cli2)
	if got := strings.TrimSpace(string(b2)); got != "LOCAL" {
		t.Fatalf("local session: got %q want LOCAL", got)
	}
}
