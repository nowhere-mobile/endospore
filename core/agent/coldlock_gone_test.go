package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261123-29: "a marker whose user no longer exists parks nothing" has one rule, androidUserGone, and
// GET-COLDLOCK applies it as CREATE does. The gate reads GET-COLDLOCK and keeps no user test of its own, so the gate
// and the daemon cannot disagree on whether the parked user is gone. GET-COLDLOCK is a read verb: it never removes
// the marker.

const goneRuleMarker = "gonerule\n31\n\nnokey\nnopin\nWRAP\n\n" // a cold-locked session of user 31
const goneRuleReply = "COLDLOCK 31 nokey nopin gonerule"

// goneRuleState makes a create environment with goneRuleMarker parked, and user 31 in the given state: "present"
// (its users dir exists), "gone" (users/0 only) or "nousersdir" (no users dir to decide from).
func goneRuleState(t *testing.T, state string) string {
	t.Helper()
	dest, _ := createCodeEnv(t, "PAIDCODEPAIDCODEPAIDCODE", 3)
	switch state {
	case "present":
		users := useTempUsersDir(t)
		if err := os.MkdirAll(filepath.Join(users, "31"), 0o700); err != nil {
			t.Fatal(err)
		}
	case "gone":
		useTempUsersDir(t)
	case "nousersdir":
		old := androidUsersDir
		androidUsersDir = filepath.Join(t.TempDir(), "absent")
		t.Cleanup(func() { androidUsersDir = old })
	default:
		t.Fatalf("unknown state %q", state)
	}
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), []byte(goneRuleMarker), 0o600); err != nil {
		t.Fatal(err)
	}
	return dest
}

// goneRuleMarkerIntact fails the test unless the marker is still on disk, byte for byte.
func goneRuleMarkerIntact(t *testing.T, dest, after string) {
	t.Helper()
	if b, err := os.ReadFile(filepath.Join(dest, ".coldlock")); err != nil || string(b) != goneRuleMarker {
		t.Errorf("after %s the .coldlock marker is %q (err %v), want it unchanged", after, b, err)
	}
}

func TestGetColdLockNamesAParkedUserThatExists(t *testing.T) {
	dest := goneRuleState(t, "present")
	if got := getColdLockReply(t, dest); got != goneRuleReply {
		t.Errorf("GET-COLDLOCK for a parked user that exists replied %q, want %q", got, goneRuleReply)
	}
	goneRuleMarkerIntact(t, dest, "GET-COLDLOCK")
}

func TestGetColdLockAnswersNoneForAGoneUser(t *testing.T) {
	dest := goneRuleState(t, "gone")
	if got := getColdLockReply(t, dest); got != "NONE" {
		t.Errorf("GET-COLDLOCK for a parked user that is gone replied %q, want NONE", got)
	}
	goneRuleMarkerIntact(t, dest, "GET-COLDLOCK")
}

func TestGetColdLockWithNoUsersDirNamesTheMarker(t *testing.T) {
	dest := goneRuleState(t, "nousersdir")
	if got := getColdLockReply(t, dest); got != goneRuleReply {
		t.Errorf("GET-COLDLOCK with no users dir to decide from replied %q, want %q", got, goneRuleReply)
	}
	goneRuleMarkerIntact(t, dest, "GET-COLDLOCK")
}

// TestGetColdLockAndCreateUseOneRule: GET-COLDLOCK names the marker exactly when CREATE refuses with ERR-COLDLOCK.
func TestGetColdLockAndCreateUseOneRule(t *testing.T) {
	for _, c := range []struct {
		state, get, create string
	}{
		{"present", goneRuleReply, "ERR-COLDLOCK"},
		{"gone", "NONE", "OK "},
		{"nousersdir", goneRuleReply, "ERR-COLDLOCK"},
	} {
		t.Run(c.state, func(t *testing.T) {
			dest := goneRuleState(t, c.state)
			get := getColdLockReply(t, dest)
			goneRuleMarkerIntact(t, dest, "GET-COLDLOCK")
			create := verb(func(conn net.Conn) {
				handleCreate(conn, dest, "gonerule-arrival-"+c.state, "the gone-rule arrival passphrase")
			})
			if get != c.get {
				t.Errorf("GET-COLDLOCK replied %q, want %q", get, c.get)
			}
			if !strings.HasPrefix(create, c.create) {
				t.Errorf("CREATE replied %q, want a reply starting %q", create, c.create)
			}
			if strings.HasPrefix(get, "COLDLOCK ") != (create == "ERR-COLDLOCK") {
				t.Errorf("two rules: GET-COLDLOCK replied %q but CREATE replied %q", get, create)
			}
		})
	}
}
