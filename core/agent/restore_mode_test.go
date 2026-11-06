package main

// NWP-20260910-09: a file's MODE must survive seal -> restore -> re-seal unchanged.
//
// ⚠ WHY THIS IS A SEAL TEST AND NOT A PERMISSIONS TEST. The seal writes info.Mode() straight into the ustar
// header (incremental_seal.go, tar.FileInfoHeader), so a mode that changes across the round trip changes the
// header, the chunk plaintext, and every content hash in that file's region. Nothing reports it: the restore
// succeeds, the files are all present and correct, and the next seal simply re-uploads them. That is exactly
// what NWP-20260829-01 found for mtime -- "62 of 1453 chunks skipped and ~1.8 GB pushed on FOUR consecutive
// login/logoff cycles" -- and the mode sat in the same function, unfixed, because only mtime was looked at.
//
// Device-proven on lynx 2026-09-10, profile `cm5`, one web import: the manifest recorded 0644, the restore
// left 0640 on disk, and the first seal re-uploaded the whole essential region (24,970 KiB; 10 of 145 chunks
// skipped) while the deferred tier -- byte-identical at 764,609,260 B -- deduped completely. The difference
// between the two tiers is that mediad chmods a materialised deferred file EXPLICITLY, and an explicit chmod
// is not umask-filtered.

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

// sealOneFile is what the incremental seal actually emits for one file: its own self-contained fragment.
func sealOneFile(t *testing.T, path, rel string) []byte {
	t.Helper()
	fi, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("lstat %s: %v", path, err)
	}
	var b bytes.Buffer
	if err := writeEntryTar(&b, path, fi, rel); err != nil {
		t.Fatalf("writeEntryTar %s: %v", rel, err)
	}
	return b.Bytes()
}

// THE CONTRACT: seal -> restore -> re-seal is a fixed point. If it is not, every restored file re-uploads.
func TestRestoredModeSurvivesTheRoundTrip(t *testing.T) {
	// A umask that clears the "other" bits, which is what turned 0644 into 0640 on lynx. Set it explicitly
	// rather than trusting the test runner's: the whole defect is invisible under a umask of 0.
	old := unix.Umask(0o027)
	defer unix.Umask(old)

	for _, mode := range []os.FileMode{0o644, 0o660, 0o600, 0o755} {
		src := t.TempDir()
		dst := t.TempDir()
		const rel = "DCIM/Camera/IMG_0001.jpg"
		p := filepath.Join(src, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("imported photo bytes"), 0o600); err != nil {
			t.Fatal(err)
		}
		// Chmod explicitly so the FIXTURE carries the mode we mean, whatever the umask above would have
		// masked out of WriteFile's argument.
		if err := os.Chmod(p, mode); err != nil {
			t.Fatal(err)
		}

		sealed := sealOneFile(t, p, rel)
		if skipped := untarFrom(dst, bytes.NewReader(sealed)); skipped != 0 {
			t.Fatalf("mode %o: restore skipped %d entr(ies)", mode, skipped)
		}

		got, err := os.Lstat(filepath.Join(dst, rel))
		if err != nil {
			t.Fatalf("mode %o: restored file missing: %v", mode, err)
		}
		if got.Mode().Perm() != mode.Perm() {
			t.Errorf("mode %o: restored as %o -- O_CREATE's mode is a REQUEST and the umask masked it; "+
				"the re-seal will write %o into the header where %o was sealed, so this file's whole region "+
				"re-uploads", mode, got.Mode().Perm(), got.Mode().Perm(), mode.Perm())
		}

		// The assertion that actually matters: the bytes the NEXT seal produces are the bytes this one did.
		resealed := sealOneFile(t, filepath.Join(dst, rel), rel)
		if !bytes.Equal(sealed, resealed) {
			t.Errorf("mode %o: the re-seal fragment differs from the sealed one (%d vs %d bytes) -- every "+
				"content hash in this file's region moves, and the next logoff re-uploads it with no error "+
				"anywhere", mode, len(sealed), len(resealed))
		}
	}
}

// The directory case is deliberately NOT fixed, and this pins that so nobody "completes" the fix by adding
// it. Dirs are restored 0o700 and roamd widens them to group-traversable at every login on purpose
// (nowhere_roamd.sh, chmod-media-dirs, after a restore left Documents/markor listing EMPTY through the
// FUSE); forcing the sealed dir mode here would fight that, every login, and dir entries carry no file's
// chunks. So a dir's mode is expected NOT to round-trip.
func TestDirectoryModeIsDeliberatelyNotRestored(t *testing.T) {
	old := unix.Umask(0o027)
	defer unix.Umask(old)

	src, dst := t.TempDir(), t.TempDir()
	const rel = "DCIM/Camera"
	p := filepath.Join(src, rel)
	if err := os.MkdirAll(p, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, 0o2770); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	if err := writeEntryTar(&b, p, fi, rel); err != nil {
		t.Fatal(err)
	}
	if skipped := untarFrom(dst, bytes.NewReader(b.Bytes())); skipped != 0 {
		t.Fatalf("restore skipped %d entr(ies)", skipped)
	}
	got, err := os.Lstat(filepath.Join(dst, rel))
	if err != nil {
		t.Fatal(err)
	}
	if got.Mode().Perm() != 0o700 {
		t.Errorf("restored dir mode is %o, want 0700 -- if this changed, the fix grew to cover directories "+
			"and it now fights roamd's per-login chmod-media-dirs", got.Mode().Perm())
	}
}
