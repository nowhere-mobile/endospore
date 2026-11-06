package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261010-16 (docs/product-decisions.md, 2026-10-10): while a cold-locked session is parked, CREATE and
// CREATE-CODE refuse with ERR-COLDLOCK, before anything is charged, drained, staged or wiped.

const ccMarker = "alice\n12\n\nnokey\nnopin\nWRAP\n\n" // a cold-locked session of user 12

// parkColdLock writes ccMarker plus another piece of session state the create's wipe would remove, and returns a
// check that both are still there, byte for byte.
func parkColdLock(t *testing.T, dest string) func(after string) {
	t.Helper()
	other := filepath.Join(dest, "headblobs", "x")
	if err := os.MkdirAll(filepath.Dir(other), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, []byte("session state"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte(ccMarker), 0o600); err != nil {
		t.Fatal(err)
	}
	return func(after string) {
		t.Helper()
		if b, err := os.ReadFile(filepath.Join(dest, ".coldlock")); err != nil || string(b) != ccMarker {
			t.Errorf("after %s the parked session's .coldlock is %q (err %v) -- it can no longer resume", after, b, err)
		}
		if _, err := os.Stat(other); err != nil {
			t.Errorf("after %s the session state was wiped: %v", after, err)
		}
	}
}

func TestCreateIsRefusedWhileAColdLockIsParked(t *testing.T) {
	dest, wpath := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	users := useTempUsersDir(t)
	if err := os.MkdirAll(filepath.Join(users, "12"), 0o700); err != nil {
		t.Fatal(err)
	}
	fundWallet(t, wpath, 4)
	walletBefore, _ := os.ReadFile(wpath)
	gen := walletGeneration(wpath)
	intact := parkColdLock(t, dest)
	t.Setenv("NOWHERE_ENROLL_MAX", "1") // one enrollment in the bucket: a refused create must not spend it

	for _, c := range []struct {
		verb string
		run  func(net.Conn)
	}{
		{"CREATE", func(c net.Conn) { handleCreate(c, dest, stName, stPass) }},
		{"CREATE-CODE", func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") }},
		// Ahead of the input checks too: an empty code, a blank name.
		{"CREATE-CODE with no code", func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "") }},
		{"CREATE with no name", func(c net.Conn) { handleCreate(c, dest, "", stPass) }},
	} {
		if got := verb(c.run); got != "ERR-COLDLOCK" {
			t.Errorf("%s over a parked cold lock replied %q, want ERR-COLDLOCK", c.verb, got)
		}
		intact(c.verb)
	}
	if getRef("s3", headKey("s3", stName, stPass)) != "" {
		t.Error("a refused create enrolled the profile")
	}
	if _, err := os.Stat(createStagingPath(stName, stPass)); err == nil {
		t.Error("a refused CREATE-CODE staged a claim -- the code was drained")
	}
	if b, err := os.ReadFile(wpath); err != nil || string(b) != string(walletBefore) || walletGeneration(wpath) != gen {
		t.Errorf("a refused create touched the parked session's wallet (err %v)", err)
	}

	// The session resumes (its marker goes), and the same code creates the profile with every token it carried: the
	// refusals redeemed nothing and charged no enrollment.
	os.Remove(filepath.Join(dest, ".coldlock"))
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE-CODE once the cold lock is gone replied %q, want OK", got)
	}
	if w := storedWallet(t, stName, stPass); w == nil || len(w.BlindTokens) != 3 {
		t.Errorf("the profile created after the refusals holds %v, want the code's 3 tokens", w)
	}
}

// Without a cold lock both verbs create, as before.
func TestCreateIsAllowedWithoutAColdLock(t *testing.T) {
	dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	useTempUsersDir(t)
	if got := verb(func(c net.Conn) { handleCreate(c, dest, "dave", "another arriving passphrase") }); !strings.HasPrefix(got, "OK ") {
		t.Errorf("CREATE with no cold lock replied %q, want OK", got)
	}
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") }); !strings.HasPrefix(got, "OK ") {
		t.Errorf("CREATE-CODE with no cold lock replied %q, want OK", got)
	}
}

// A marker whose user is gone parks nothing: both verbs create (and the create's wipe then removes the marker). A
// marker whose user cannot be decided -- no users dir to look in -- still refuses: only a definite ENOENT counts.
func TestCreateOverAColdLockMarkerOfAGoneUser(t *testing.T) {
	for _, v := range []string{"CREATE", "CREATE-CODE"} {
		t.Run(v, func(t *testing.T) {
			dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
			useTempUsersDir(t) // user 0 only: user 12 is gone
			parkColdLock(t, dest)
			var got string
			if v == "CREATE" {
				got = verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) })
			} else {
				got = verb(func(c net.Conn) { handleCreateCode(c, dest, stName, stPass, "PAIDCODEPAIDCODEPAIDCODE") })
			}
			if !strings.HasPrefix(got, "OK ") {
				t.Fatalf("%s over the marker of a gone user replied %q, want OK", v, got)
			}
			if _, err := os.Stat(filepath.Join(dest, ".coldlock")); err == nil {
				t.Error("the gone user's marker outlived the create")
			}
		})
	}
	t.Run("undecidable", func(t *testing.T) {
		dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
		old := androidUsersDir
		androidUsersDir = filepath.Join(t.TempDir(), "absent")
		t.Cleanup(func() { androidUsersDir = old })
		intact := parkColdLock(t, dest)
		if got := verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) }); got != "ERR-COLDLOCK" {
			t.Errorf("CREATE with no users dir to decide from replied %q, want ERR-COLDLOCK", got)
		}
		intact("CREATE")
	})
}

// A malformed marker is no cold lock (readColdLock), here as everywhere else.
func TestCreateOverAMalformedColdLockMarker(t *testing.T) {
	dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := verb(func(c net.Conn) { handleCreate(c, dest, stName, stPass) }); !strings.HasPrefix(got, "OK ") {
		t.Errorf("CREATE over a malformed marker replied %q, want OK", got)
	}
}
