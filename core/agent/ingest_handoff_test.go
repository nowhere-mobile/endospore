package main

import (
	"bufio"
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// GET-INGEST (NWP-20260827-18, reduced to serve-only by NWP-20260827-21): discovery, the wire shape, the
// caps, and the name gate that keeps a hostile chooser inside the user's own staging dir while accepting
// any-script user file names.
//
// There is no "mark it done" verb any more: the daemon holds READ-ONLY policy on the media tree, so the
// rename it used to attempt always failed. The record is the chooser's own CE receipt, so this side
// simply serves every staged file on every login.

func ingestTestTree(t *testing.T, userID string, files map[string][]byte) {
	t.Helper()
	old := ingestMediaBase
	ingestMediaBase = t.TempDir()
	t.Cleanup(func() { ingestMediaBase = old })
	dir := filepath.Join(ingestMediaBase, userID, ingestDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, b := range files {
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// ingestRoundTrip runs a handler over an in-memory socket pair and returns the full reply.
func ingestRoundTrip(t *testing.T, fn func(conn net.Conn)) string {
	t.Helper()
	a, b := net.Pipe()
	go func() { fn(a); a.Close() }()
	var sb strings.Builder
	sc := bufio.NewScanner(b)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		sb.WriteString(sc.Text())
		sb.WriteByte('\n')
	}
	b.Close()
	return sb.String()
}

// ingestReplyFiles decodes a GET-INGEST reply into name -> body.
func ingestReplyFiles(t *testing.T, reply string) map[string]string {
	t.Helper()
	lines := strings.Split(strings.TrimRight(reply, "\n"), "\n")
	if lines[0] != "OK" {
		t.Fatalf("reply shape: %q", reply)
	}
	got := map[string]string{}
	for _, l := range lines[1:] {
		f := strings.Fields(l)
		if len(f) != 3 || f[0] != "F" {
			t.Fatalf("file line shape: %q", l)
		}
		name, _ := base64.StdEncoding.DecodeString(f[1])
		body, _ := base64.StdEncoding.DecodeString(f[2])
		got[string(name)] = string(body)
	}
	return got
}

func TestGetIngestServesStagedFiles(t *testing.T) {
	ingestTestTree(t, "12", map[string][]byte{
		"contacts.vcf":          []byte("BEGIN:VCARD\nEND:VCARD\n"),
		"calendar.ics":          []byte("BEGIN:VCALENDAR\nEND:VCALENDAR\n"),
		"Kontakte für Anna.VCF": []byte("unicode + case"),
		"notes.txt":             []byte("not ours"),
		".hidden.vcf":           []byte("dotfile"),
	})
	got := ingestReplyFiles(t, ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000+10195) }))
	if got["contacts.vcf"] != "BEGIN:VCARD\nEND:VCARD\n" || got["calendar.ics"] == "" {
		t.Fatalf("staged files wrong: %v", got)
	}
	// a non-ASCII, case-mixed user file name is served -- the page stages the user's own names verbatim
	if got["Kontakte für Anna.VCF"] != "unicode + case" {
		t.Fatalf("unicode name not served: %v", got)
	}
	if _, bad := got["notes.txt"]; bad {
		t.Fatalf("a non-vcf/ics file was served")
	}
	if _, bad := got[".hidden.vcf"]; bad {
		t.Fatalf("a dotfile was served")
	}
}

// The daemon has no memory of what has been ingested -- that lives in the chooser's receipt -- so the
// same file is served again on the next login. This is the behaviour the receipt-only model depends on.
func TestGetIngestKeepsServingTheSameFile(t *testing.T) {
	ingestTestTree(t, "12", map[string][]byte{"contacts.vcf": []byte("x")})
	for i := 0; i < 3; i++ {
		got := ingestReplyFiles(t, ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000) }))
		if got["contacts.vcf"] != "x" {
			t.Fatalf("serve %d: %v", i, got)
		}
	}
}

func TestGetIngestEmptyAndWrongUser(t *testing.T) {
	ingestTestTree(t, "12", map[string][]byte{"contacts.vcf": []byte("x")})
	// another user's session sees nothing: the peer uid names user 13, whose dir does not exist
	if r := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 13*100000+10195) }); r != "NONE\n" {
		t.Fatalf("cross-user read: %q", r)
	}
	// no peer credential -> nothing (this is also why a root caller, uid 0, gets NONE)
	if r := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 0) }); r != "NONE\n" {
		t.Fatalf("no peer: %q", r)
	}
}

func TestGetIngestCaps(t *testing.T) {
	big := make([]byte, ingestMaxFileBytes+1)
	ingestTestTree(t, "12", map[string][]byte{
		"huge.vcf": big,
		"ok.vcf":   []byte("fine"),
	})
	reply := ingestRoundTrip(t, func(c net.Conn) { handleGetIngest(c, 12*100000) })
	if !strings.Contains(reply, base64.StdEncoding.EncodeToString([]byte("ok.vcf"))) {
		t.Fatalf("small file not served: %.120q", reply)
	}
	if strings.Contains(reply, base64.StdEncoding.EncodeToString([]byte("huge.vcf"))) {
		t.Fatalf("oversized file was served")
	}
}

// The name gate is structural, not an ASCII allowlist: it must accept any-script user file names while
// refusing anything that could escape the user's own staging directory.
func TestIngestNameGate(t *testing.T) {
	for _, ok := range []string{"contacts.vcf", "phone-calendar.ics", "Kontakte für Anna.VCF",
		"联系人.ics", "a b (2).vcf"} {
		if !ingestNameRe.MatchString(ok) {
			t.Errorf("should accept %q", ok)
		}
	}
	for _, bad := range []string{"../escape.vcf", "a/b.vcf", ".hidden.vcf", "notes.txt",
		"contacts.vcf.imported", "", "no-extension"} {
		if ingestNameRe.MatchString(bad) {
			t.Errorf("should refuse %q", bad)
		}
	}
}
