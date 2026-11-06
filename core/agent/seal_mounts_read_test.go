package main

// NWP-20261109-17: A SEAL REFUSES WHEN THE MOUNT TABLE CANNOT BE READ WHOLE.
//
// mediaOverlayUnders returned nil when /proc/self/mounts would not open, and parseMediaOverlayUndersPub read the
// table with a 64 KiB-line Scanner and never looked at sc.Err(), so a read error or one over-long line ended the
// scan with every later overlay missing. pushProfile then walked each unlisted live fuse.nowheremedia mount as a
// plain directory: a fetch storm through a live overlay, or a "blind" refusal (a FINAL class) through a dead one.
// An unreadable or partly read table is now an error and the seal refuses, RETRY class, before it walks anything.

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

const mountsReadOverlayLine = "nowhere_media /data/media/11/Android/data/com.example.app/files/Big fuse.nowheremedia rw 0 0\n"

// mountsReadFailingReader serves its text, then fails instead of reporting EOF.
type mountsReadFailingReader struct {
	text string
	done bool
}

func (r *mountsReadFailingReader) Read(p []byte) (int, error) {
	if r.done {
		return 0, errors.New("boom")
	}
	r.done = true
	return copy(p, r.text), nil
}

func TestSealMountsRead_ReadErrorIsAnError(t *testing.T) {
	m, err := parseMediaOverlayUndersPub(&mountsReadFailingReader{text: mountsReadOverlayLine}, "/data/media/11", nil)
	if err == nil {
		t.Fatalf("a read error after the first overlay line answered no error (map %v): the rest of the table is unknown", m)
	}
	if m != nil {
		t.Errorf("an error came with a partial map %v", m)
	}
}

func TestSealMountsRead_LongLine(t *testing.T) {
	huge := strings.Repeat("a", 2<<20) + "\n"
	if m, err := parseMediaOverlayUndersPub(strings.NewReader(huge+mountsReadOverlayLine), "/data/media/11", nil); err == nil {
		t.Errorf("a 2 MiB line answered no error (map %v): the overlay after it was silently dropped", m)
	}

	long := "x " + strings.Repeat("b", 70<<10) + " ext4 rw 0 0\n"
	under := "/dev/block/dm-1 /data/user/11/com.nowhere.chooser/files/.nowhere-media-ext/.under/" +
		underLeaf("Android/data/com.example.app/files/Big") + " f2fs rw 0 0\n"
	m, err := parseMediaOverlayUndersPub(strings.NewReader(long+mountsReadOverlayLine+under), "/data/media/11", nil)
	if err != nil {
		t.Fatalf("a 70 KiB line is legal and answered %v", err)
	}
	ov := "/data/media/11/Android/data/com.example.app/files/Big"
	if _, ok := m[ov]; !ok {
		t.Errorf("the overlay after a 70 KiB line is missing from %v", m)
	}
}

func TestSealMountsRead_ProcMountsOpen(t *testing.T) {
	t.Setenv("NOWHERE_STATE", "")
	prev := procSelfMounts
	t.Cleanup(func() { procSelfMounts = prev })
	d := t.TempDir()

	procSelfMounts = filepath.Join(d, "no-such-table")
	if m, err := mediaOverlayUnders("/data/media/11"); m != nil || err != nil {
		t.Errorf("a nonexistent table (no procfs) answered (%v, %v), want (nil, nil)", m, err)
	}

	file := filepath.Join(d, "afile")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	procSelfMounts = filepath.Join(file, "mounts") // ENOTDIR: an open error that is not "does not exist"
	if _, err := mediaOverlayUnders("/data/media/11"); err == nil {
		t.Error("a table that cannot be opened answered no error")
	}

	procSelfMounts = d // opens, then every read fails with EISDIR
	if _, err := mediaOverlayUnders("/data/media/11"); err == nil {
		t.Error("a table that cannot be read answered no error")
	}
}

func TestSealMountsRead_PushRefusesBeforeAnythingIsSpent(t *testing.T) {
	for _, force := range []bool{false, true} {
		name, pass := "mountsread-a", "mounts read horse staple"
		if force {
			name = "mountsread-b"
			t.Setenv("NOWHERE_SEAL_FORCE", "1")
		}
		t.Setenv("NOWHERE_STATE", t.TempDir())
		resetSealCaches()
		rs := newRecordingStore(t)
		createVault(rs.URL, name, pass)
		h := newHandset(t, rs.URL, name, pass)

		prev := mediaUndersFn
		t.Cleanup(func() { mediaUndersFn = prev })
		mediaUndersFn = func(string) (map[string]string, error) { return nil, nil }
		h.put("keep.txt", "first")
		if msg := h.seal(""); msg != "" {
			t.Fatalf("force=%v setup seal: %s", force, msg)
		}
		base := h.head("")

		mediaUndersFn = func(string) (map[string]string, error) {
			return nil, &fs.PathError{Op: "open", Path: "/proc/self/mounts", Err: syscall.EMFILE}
		}
		writeRandom(t, h.work, "big.bin", 3<<20)
		rs.mark()
		sealRefused, sealRefusedWhy = false, ""
		var refused string
		out := captureStdout(t, func() { refused = h.seal("") })
		if refused == "" || !sealRefused || sealRefusedWhy != "mounts-unread" {
			t.Fatalf("force=%v refused=%q sealRefused=%v why=%q, want a mounts-unread refusal", force, refused, sealRefused, sealRefusedWhy)
		}
		if got := h.head(""); got != base {
			t.Errorf("force=%v the head moved: %s -> %s", force, base, got)
		}
		rs.assertNothingSpent(t, "mounts-unread")
		if !strings.Contains(out, "SEAL REFUSED") {
			t.Errorf("force=%v no refusal line in %q", force, out)
		}
		if strings.Contains(out, "/proc/self/mounts") || strings.Contains(out, name+" ") {
			t.Errorf("force=%v the refusal line leaks a path or an unquoted profile name: %q", force, out)
		}
	}
}

func TestSealMountsRead_ReasonIsRetry(t *testing.T) {
	if refusalReasonFinal("mounts-unread") {
		t.Error("mounts-unread is transient (a retry re-reads the table) but is classed FINAL")
	}
}
