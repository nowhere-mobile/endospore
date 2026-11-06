package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// NWP-20261011-50. The two owned-SIM verbs the chooser calls at sign-in, driven through handleLogin over a pipe on
// every branch: TEL-OWNED-ICCIDS (which SIMs stay visible to the roamed user) and TEL-OWNED-LABELS (which gate
// notices that sign-in clears). Both are multi-line by design -- "OK" then one line per owned SIM -- so a profile
// that owns nothing gets the bare "OK" line, and that is the reply a stranger and a mistyped passphrase must get.

// driveLoginRaw is driveLogin without the TrimSpace, so a reply's trailing space and final newline are asserted too:
// TEL-OWNED-LABELS writes a blank label as "L " and only the untrimmed reply shows it.
func driveLoginRaw(t *testing.T, req string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go cli.Write([]byte(req))
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- string(b)
	}()
	handleLogin(srv, t.TempDir()) // closes srv itself
	got := <-reply
	cli.Close()
	return got
}

// ownedSIMsFixture points bindingsPath (and the state a bind records into) at fresh temp files, via telFixture, and binds
// each SIM to the given owners ("carol", "dave" or "both") with its label.
func ownedSIMsFixture(t *testing.T, sims []struct{ iccid, label, owners string }) {
	t.Helper()
	telFixture(t)
	refs := map[string]string{"carol": profileRefV2("carol", "pw-carol"), "dave": profileRefV2("dave", "pw-dave")}
	for i, s := range sims {
		for _, who := range []string{"carol", "dave"} {
			if s.owners != who && s.owners != "both" {
				continue
			}
			if err := setBindingOwner(i+1, s.iccid, s.label, "open", refs[who], "pub-"+who); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func wantReplies(t *testing.T, cases map[string]string) {
	t.Helper()
	for req, want := range cases {
		if got := driveLoginRaw(t, req); got != want {
			t.Errorf("%q replied %q, want %q", req, got, want)
		}
	}
}

// TestOwnedVerbsOneSIMEach: carol owns a labelled SIM, dave an unlabelled one. Each sees only its own SIM; dave's
// blank label is still a non-empty "L " line; a stranger and carol's name with dave's passphrase own nothing.
func TestOwnedVerbsOneSIMEach(t *testing.T) {
	ownedSIMsFixture(t, []struct{ iccid, label, owners string }{{iccidY, "M", "carol"}, {iccidX, "", "dave"}})
	wantReplies(t, map[string]string{
		"TEL-OWNED-ICCIDS\ncarol\npw-carol\n": "OK\n" + iccidY + "\n",
		"TEL-OWNED-ICCIDS\ndave\npw-dave\n":   "OK\n" + iccidX + "\n",
		"TEL-OWNED-ICCIDS\nstranger\npw\n":    "OK\n",
		"TEL-OWNED-ICCIDS\ncarol\npw-dave\n":  "OK\n",
		"TEL-OWNED-LABELS\ncarol\npw-carol\n": "OK\nL " + b64s("M") + "\n",
		"TEL-OWNED-LABELS\ndave\npw-dave\n":   "OK\nL \n",
		"TEL-OWNED-LABELS\nstranger\npw\n":    "OK\n",
		"TEL-OWNED-LABELS\ncarol\npw-dave\n":  "OK\n",
	})
	// What the chooser's roundTripLines sees after it drops empty lines: the blank label survives as a token.
	if got := driveLogin(t, t.TempDir(), "TEL-OWNED-LABELS\ndave\npw-dave\n"); got != "OK\nL" {
		t.Errorf("trimmed TEL-OWNED-LABELS for dave = %q, want %q", got, "OK\nL")
	}
}

// TestOwnedVerbsCoOwnedSIM: a SIM carol and dave both own appears once in each one's reply, after carol's own SIM.
func TestOwnedVerbsCoOwnedSIM(t *testing.T) {
	ownedSIMsFixture(t, []struct{ iccid, label, owners string }{{iccidY, "M", "carol"}, {iccidZ, "S", "both"}})
	wantReplies(t, map[string]string{
		"TEL-OWNED-ICCIDS\ncarol\npw-carol\n": "OK\n" + iccidY + "\n" + iccidZ + "\n",
		"TEL-OWNED-ICCIDS\ndave\npw-dave\n":   "OK\n" + iccidZ + "\n",
		"TEL-OWNED-LABELS\ncarol\npw-carol\n": "OK\nL " + b64s("M") + "\nL " + b64s("S") + "\n",
		"TEL-OWNED-LABELS\ndave\npw-dave\n":   "OK\nL " + b64s("S") + "\n",
	})
}

// TestOwnedVerbsNoBindingsFile: with no bindings.conf at all nobody owns anything, so both verbs answer the bare "OK".
func TestOwnedVerbsNoBindingsFile(t *testing.T) {
	telFixture(t)
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Fatalf("bindings.conf exists at %s (err %v)", filepath.Base(bindingsPath), err)
	}
	wantReplies(t, map[string]string{
		"TEL-OWNED-ICCIDS\ncarol\npw-carol\n": "OK\n",
		"TEL-OWNED-LABELS\ncarol\npw-carol\n": "OK\n",
	})
}
