package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// NWP-20261014-28: a create made while a session is live or cold-locked never takes that session's wallet
// (NWP-20261010-04). The rule rests on wipeAfterCreate's live branch, on wipeSessionStateWallet's wallet-prefix
// skip, and on how createAndReply computes live; each is pinned here.

func seedCreateDest(t *testing.T) (dest string, files map[string]string) {
	t.Helper()
	dest = t.TempDir()
	wp := walletPathFor(dest)
	files = map[string]string{
		wp:                                  "wallet-body",
		wp + ".tmp":                         "tmp-body",
		wp + ".lock":                        "lock-body",
		wp + ".gen":                         "gen-body",
		filepath.Join(dest, ".coldlock"):    "a\n1\n",
		filepath.Join(dest, ".roamsession"): "x",
		filepath.Join(dest, "other.state"):  "o",
	}
	for f, c := range files {
		if err := os.WriteFile(f, []byte(c), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	tel := filepath.Join(dest, telStateSubdir)
	if err := os.MkdirAll(tel, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(tel, "pending"), []byte("t"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dest, files
}

func TestCreateKeepWallet_LiveKeepsEveryWalletFile(t *testing.T) {
	dest, files := seedCreateDest(t)
	wp := walletPathFor(dest)
	wipeAfterCreate(dest, true)
	for _, f := range []string{wp, wp + ".tmp", wp + ".lock", wp + ".gen"} {
		b, err := os.ReadFile(f)
		if err != nil || string(b) != files[f] {
			t.Errorf("live create: %s = %q, %v; want it kept with %q", filepath.Base(f), b, err, files[f])
		}
	}
	for _, n := range []string{".coldlock", ".roamsession", "other.state"} {
		if _, err := os.Stat(filepath.Join(dest, n)); err == nil {
			t.Errorf("live create: %s survived; the session must not be resumable", n)
		}
	}
	if _, err := os.Stat(filepath.Join(dest, telStateSubdir, "pending")); err != nil {
		t.Errorf("live create: the tel/ subdir did not survive: %v", err)
	}
}

func TestCreateKeepWallet_NotLiveRemovesTheWalletThroughRemoveWallet(t *testing.T) {
	dest, _ := seedCreateDest(t)
	wp := walletPathFor(dest)
	before := walletGeneration(wp)
	wipeAfterCreate(dest, false)
	if after := walletGeneration(wp); after == before || after == "" {
		t.Errorf("generation %q -> %q; removeWallet must bump it", before, after)
	}
	for _, f := range []string{wp, wp + ".tmp"} {
		if _, err := os.Stat(f); err == nil {
			t.Errorf("not-live create: %s survived", filepath.Base(f))
		}
	}
	if _, err := os.Stat(wp + ".lock"); err != nil {
		t.Errorf("not-live create: the wallet lock file was removed: %v", err)
	}
	for _, n := range []string{".coldlock", ".roamsession", "other.state"} {
		if _, err := os.Stat(filepath.Join(dest, n)); err == nil {
			t.Errorf("not-live create: %s survived", n)
		}
	}
	if _, err := os.Stat(filepath.Join(dest, telStateSubdir, "pending")); err != nil {
		t.Errorf("not-live create: the tel/ subdir did not survive: %v", err)
	}
}

func TestCreateKeepWallet_CreateAndReplyComputesLiveFromBothMarkers(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	i := strings.Index(body, "func createAndReply(")
	if i < 0 {
		t.Fatal("createAndReply not found")
	}
	body = body[i:]
	if j := strings.Index(body, "\n}\n"); j > 0 {
		body = body[:j]
	}
	re := regexp.MustCompile(`live := roamSessionExists\(dest\) \|\| coldLockedUID\(dest\) != ""`)
	if !re.MatchString(body) {
		t.Error("createAndReply must compute live from BOTH roamSessionExists(dest) and coldLockedUID(dest)")
	}
	if !strings.Contains(body, "wipeAfterCreate(dest, live)") {
		t.Error("createAndReply must hand live to wipeAfterCreate")
	}
}
