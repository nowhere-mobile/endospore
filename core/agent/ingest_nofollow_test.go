package main

import (
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// GET-INGEST follows no link and opens no FIFO (NWP-20261101-18). The daemon reads the user's staging dir as
// root, so a link named x.vcf must not hand any root-readable file to the session, and a FIFO named x.vcf
// must not block the login daemon. Every fixture lives inside the test's own t.TempDir().

const ingestNoFollowMarker = "NOWHERE-SECRET-MARKER-9f3a"

// ingestNoFollowTree builds <base>/<user>/Documents/Imported with the given files, and returns the base, the
// staging dir and an outside dir (a sibling of the base inside the same TempDir).
func ingestNoFollowTree(t *testing.T, userID string) (base, dir, outside string) {
	t.Helper()
	root := t.TempDir()
	base = filepath.Join(root, "media")
	outside = filepath.Join(root, "outside")
	dir = filepath.Join(base, userID, ingestDir)
	for _, d := range []string{dir, outside} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	old, oldFn := ingestMediaBase, ingestUndersFn
	ingestMediaBase = base
	ingestUndersFn = func() map[string]string { return nil }
	t.Cleanup(func() { ingestMediaBase, ingestUndersFn = old, oldFn })
	return base, dir, outside
}

func ingestNoFollowWrite(t *testing.T, p, body string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// ingestNoFollowGet runs GET-INGEST for user 12 and fails the test if it does not return within 5 s.
func ingestNoFollowGet(t *testing.T) string {
	t.Helper()
	done := make(chan string, 1)
	go func() {
		done <- ingestRoundTrip(t, func(conn net.Conn) { handleGetIngest(conn, 12*100000) })
	}()
	select {
	case r := <-done:
		return r
	case <-time.After(5 * time.Second):
		t.Fatal("GET-INGEST did not return within 5 s")
	}
	return ""
}

func TestIngestNoFollow_FileLink(t *testing.T) {
	_, dir, outside := ingestNoFollowTree(t, "12")
	secret := filepath.Join(outside, "nowhere.conf")
	ingestNoFollowWrite(t, secret, ingestNoFollowMarker)
	ingestNoFollowWrite(t, filepath.Join(dir, "a.vcf"), "BEGIN:VCARD\nEND:VCARD\n")
	if err := os.Symlink(secret, filepath.Join(dir, "b.vcf")); err != nil {
		t.Fatal(err)
	}
	reply := ingestNoFollowGet(t)
	got := ingestReplyFiles(t, reply)
	if _, ok := got["a.vcf"]; !ok || len(got) != 1 {
		t.Fatalf("want exactly a.vcf served, got %v", got)
	}
	if strings.Contains(reply, base64.StdEncoding.EncodeToString([]byte(ingestNoFollowMarker))) {
		t.Fatal("the linked file's bytes were served")
	}
}

func TestIngestNoFollow_ListSkipsNonRegular(t *testing.T) {
	_, dir, outside := ingestNoFollowTree(t, "12")
	ingestNoFollowWrite(t, filepath.Join(outside, "t"), "x")
	ingestNoFollowWrite(t, filepath.Join(dir, "a.vcf"), "x")
	if err := os.Symlink(filepath.Join(outside, "t"), filepath.Join(dir, "b.vcf")); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(filepath.Join(dir, "d.vcf"), 0o644); err != nil {
		t.Fatal(err)
	}
	names, err := ingestList(dir, false)
	if err != nil || !reflect.DeepEqual(names, []string{"a.vcf"}) {
		t.Fatalf("ingestList = %v, %v; want [a.vcf]", names, err)
	}
}

func TestIngestNoFollow_ReadStagedRefusesLink(t *testing.T) {
	_, dir, outside := ingestNoFollowTree(t, "12")
	ingestNoFollowWrite(t, filepath.Join(outside, "t"), ingestNoFollowMarker)
	p := filepath.Join(dir, "b.vcf")
	if err := os.Symlink(filepath.Join(outside, "t"), p); err != nil {
		t.Fatal(err)
	}
	if b, ok := ingestReadStaged(p, ingestMaxFileBytes); ok {
		t.Fatalf("ingestReadStaged followed a link and returned %d bytes", len(b))
	}
}

// ingestNoFollowFIFO makes a FIFO and arranges for a blocked opener to be released at cleanup.
func ingestNoFollowFIFO(t *testing.T, p string) {
	t.Helper()
	if err := unix.Mkfifo(p, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if fd, err := unix.Open(p, unix.O_WRONLY|unix.O_NONBLOCK, 0); err == nil {
			unix.Close(fd)
		}
	})
}

func TestIngestNoFollow_ReadStagedFIFO(t *testing.T) {
	_, dir, _ := ingestNoFollowTree(t, "12")
	p := filepath.Join(dir, "d.vcf")
	ingestNoFollowFIFO(t, p)
	done := make(chan bool, 1)
	go func() { _, ok := ingestReadStaged(p, ingestMaxFileBytes); done <- ok }()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("ingestReadStaged served a FIFO")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ingestReadStaged blocked on a FIFO")
	}
}

func TestIngestNoFollow_FIFOBesideRegular(t *testing.T) {
	_, dir, _ := ingestNoFollowTree(t, "12")
	ingestNoFollowFIFO(t, filepath.Join(dir, "d.vcf"))
	ingestNoFollowWrite(t, filepath.Join(dir, "e.vcf"), "BEGIN:VCARD\nEND:VCARD\n")
	got := ingestReplyFiles(t, ingestNoFollowGet(t))
	if _, ok := got["e.vcf"]; !ok || len(got) != 1 {
		t.Fatalf("want exactly e.vcf served, got %v", got)
	}
}

func TestIngestNoFollow_DirLink(t *testing.T) {
	for _, linkAt := range []string{"Imported", "Documents"} {
		t.Run(linkAt, func(t *testing.T) {
			base, dir, outside := ingestNoFollowTree(t, "12")
			target := filepath.Join(outside, "target")
			if linkAt == "Imported" {
				if err := os.MkdirAll(target, 0o755); err != nil {
					t.Fatal(err)
				}
			} else if err := os.MkdirAll(filepath.Join(target, "Imported"), 0o755); err != nil {
				t.Fatal(err)
			}
			victim := filepath.Join(target, "c.vcf")
			if linkAt == "Documents" {
				victim = filepath.Join(target, "Imported", "c.vcf")
			}
			ingestNoFollowWrite(t, victim, "BEGIN:VCARD\nEND:VCARD\n")
			var at string
			if linkAt == "Imported" {
				at = dir
			} else {
				at = filepath.Join(base, "12", "Documents")
			}
			if err := os.RemoveAll(at); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(target, at); err != nil {
				t.Fatal(err)
			}
			if r := ingestNoFollowGet(t); r != "NONE\n" {
				t.Fatalf("a linked %s answered %q, want NONE", linkAt, r)
			}
		})
	}
}

func TestIngestNoFollow_SizeOnOpenedFile(t *testing.T) {
	_, dir, _ := ingestNoFollowTree(t, "12")
	five, four := filepath.Join(dir, "five.vcf"), filepath.Join(dir, "four.vcf")
	ingestNoFollowWrite(t, five, "12345")
	ingestNoFollowWrite(t, four, "1234")
	if b, ok := ingestReadStaged(five, 4); ok {
		t.Fatalf("a 5-byte file under max 4 returned %q", b)
	}
	if b, ok := ingestReadStaged(four, 4); !ok || string(b) != "1234" {
		t.Fatalf("a 4-byte file under max 4 = %q, %v", b, ok)
	}
}
