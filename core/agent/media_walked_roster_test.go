package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261025-01: A #MEDIA FILE THIS SESSION CREATED, SEALED AND DELETED MUST NOT BE CARRIED BACK.
//
// The essential carry told "ours" from "another handset's" by the LOGIN roster alone, so a rel this session
// itself walked and published was not in it: deleted before the next seal, it read as another lineage's file,
// was carried by hash, and materializeCarried wrote it back within one periodic cycle. The walked roster
// (restore_receipt.go) is the second half of "ours". The existing deletion tests all delete a file the session
// RESTORED, which is why nothing saw it.

func walkedRosterPath(h *handset, ref string) string {
	return filepath.Join(h.state, "restore-receipts", "walked."+ref)
}

func TestMediaWalked_ASmallFileCreatedSealedAndDeletedIsNotCarriedBack(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "walkdel", "correct horse battery staple")
	ref := profileRefV2("walkdel#media", "correct horse battery staple")
	const rel = "DCIM/shot.png"

	a.put("Documents/shared.txt", "restored at login")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.as(func() { loginArrived(ref, a.head("#media")) })

	a.put(rel, "a screenshot, far below the deferral floor")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("seal that publishes the screenshot: %s", msg)
	}
	if _, ok := headManifestOf(t, a.base, a.name+"#media", a.pass).Ess[rel]; !ok {
		t.Fatal("the fixture did not publish the screenshot, so nothing below is exercised")
	}

	a.rm(rel)
	out := captureStdout(t, func() {
		if msg := a.seal("#media"); msg != "" {
			t.Fatalf("seal after the delete: %s", msg)
		}
	})
	m := headManifestOf(t, a.base, a.name+"#media", a.pass)
	if _, ok := m.Ess[rel]; ok {
		t.Errorf("the deleted screenshot is still in the head's index %v: the carry took the session's own file for another handset's", keysOfEss(m.Ess))
	}
	if !strings.Contains(out, "1 deleted-here") {
		t.Errorf("the carry line does not count the delete as deleted-here:\n%s", out)
	}
	if _, err := os.Lstat(filepath.Join(a.work, filepath.FromSlash(rel))); err == nil {
		t.Error("materializeCarried wrote the deleted screenshot back onto the phone")
	}
}

func TestMediaWalked_AFileOnlyACarryBroughtIsNotInTheWalkedRoster(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, b := twoWriters(t, "walkcarry", "correct horse battery staple")
	ref := profileRefV2("walkcarry#media", "correct horse battery staple")
	const rel = "DCIM/from-a.png"

	a.put("Documents/shared.txt", "both hold this")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	atLogin := a.head("#media")
	b.put("Documents/shared.txt", "both hold this")
	b.as(func() { loginArrived(ref, atLogin) })

	a.put(rel, "a small image only A has")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("A's seal: %s", msg)
	}
	dk := resolveDK(b.base, b.name+"#media", b.pass, nil)
	for i := 1; i <= 2; i++ {
		if msg := b.seal("#media"); msg != "" {
			t.Fatalf("B's seal %d: %s", i, msg)
		}
		if _, ok := headManifestOf(t, b.base, b.name+"#media", b.pass).Ess[rel]; !ok {
			t.Fatalf("the carried file left B's head at seal %d", i)
		}
		if i == 1 {
			var has func(string) bool
			b.as(func() { has = loadWalkedRoster(ref, dk) })
			if has(rel) {
				t.Error("B's walked roster names a file only a carry brought: its next seal would call the absence a deletion")
			}
			if !has("Documents/shared.txt") {
				t.Error("B's walked roster lacks the file B itself walked: the record is not running")
			}
		}
	}
}

func TestMediaWalked_TheRosterHoldsNoFileName(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "walkhex", "correct horse battery staple")
	ref := profileRefV2("walkhex#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "x")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.as(func() { loginArrived(ref, a.head("#media")) })
	a.put("DCIM/shot.png", "y")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("seal: %s", msg)
	}
	b, err := os.ReadFile(walkedRosterPath(a, ref))
	if err != nil {
		t.Fatalf("no walked roster written: %v", err)
	}
	hexLine := regexp.MustCompile(`^[0-9a-f]{64}$`)
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) < 2 {
		t.Fatalf("want a line per walked rel, got %d", len(lines))
	}
	for _, ln := range lines {
		if !hexLine.MatchString(ln) {
			t.Errorf("roster line %q is not a 64-hex digest", ln)
		}
	}
	for _, name := range []string{"DCIM", "shot", "shared", "Documents"} {
		if strings.Contains(string(b), name) {
			t.Errorf("the walked roster contains %q: a list of file names in RAM state is the #39 roster shape", name)
		}
	}
}

func TestMediaWalked_ANewLoginRosterResetsIt(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	dk := []byte("0123456789abcdef0123456789abcdef")
	const ref = "aabbccdd"
	recordWalkedRoster(ref, dk, []string{"DCIM/x.png"})
	if !loadWalkedRoster(ref, dk)("DCIM/x.png") {
		t.Fatal("the record did not take, so the reset below proves nothing")
	}
	writeLoginRoster(ref, "somehead")
	if loadWalkedRoster(ref, dk)("DCIM/x.png") {
		t.Error("writeLoginRoster left the previous session's walked roster in place")
	}
}

func TestMediaWalked_ARefusedSealRecordsNothing(t *testing.T) {
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "walkrefused", "correct horse battery staple")
	ref := profileRefV2("walkrefused#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "x")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.as(func() { loginArrived(ref, a.head("#media")) })
	a.put("DCIM/one.png", "one")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("committed seal: %s", msg)
	}
	before, err := os.ReadFile(walkedRosterPath(a, ref))
	if err != nil {
		t.Fatalf("no walked roster after a committed seal: %v", err)
	}

	a.put("DCIM/two.png", "two")
	if err := os.Remove(filepath.Join(a.state, "restore-receipts", ref)); err != nil {
		t.Fatal(err)
	}
	if msg := a.seal("#media"); msg == "" {
		t.Fatal("the #72 guard did not refuse a non-empty head without a receipt, so the fixture is not exercising a refusal")
	}
	after, err := os.ReadFile(walkedRosterPath(a, ref))
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Error("a seal that did not commit changed the walked roster")
	}
}

// NWP-20261101-09 refuses a no-receipt seal BEFORE the walk, so the case above no longer reaches the carry or the
// commit. This one is refused AFTER the carry has run -- the walk cannot read a directory, so the blind guard, which
// needs the walk, refuses -- which is where a record made ahead of the commit guards would land.
func TestMediaWalked_ARefusalAfterTheCarryRecordsNothing(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("chmod-000 does not deny root; this test needs an unprivileged runner")
	}
	essentialMediaEnv(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	a, _ := twoWriters(t, "walkblind", "correct horse battery staple")
	ref := profileRefV2("walkblind#media", "correct horse battery staple")

	a.put("Documents/shared.txt", "x")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("setup seal: %s", msg)
	}
	a.as(func() { loginArrived(ref, a.head("#media")) })
	a.put("DCIM/one.png", "one")
	if msg := a.seal("#media"); msg != "" {
		t.Fatalf("committed seal: %s", msg)
	}
	before, err := os.ReadFile(walkedRosterPath(a, ref))
	if err != nil {
		t.Fatalf("no walked roster after a committed seal: %v", err)
	}

	a.put("DCIM/two.png", "two")
	locked := filepath.Join(a.work, "Pictures", "locked")
	a.put("Pictures/locked/secret.png", "unreadable")
	if err := os.Chmod(locked, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o700) }) // or TempDir cleanup fails
	var msg string
	out := captureStdout(t, func() { msg = a.seal("#media") })
	if msg == "" || !strings.Contains(out, "SEAL REFUSED -- the walk could not read") {
		t.Fatalf("the blind guard did not refuse an unreadable directory (%q), so the fixture is not exercising a refusal:\n%s", msg, out)
	}
	if !strings.Contains(out, " carry: the head indexes ") {
		t.Fatalf("the carry did not run before the refusal, so this does not reach the arm it is for:\n%s", out)
	}
	after, err := os.ReadFile(walkedRosterPath(a, ref))
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Error("a seal refused after the carry changed the walked roster")
	}
}
