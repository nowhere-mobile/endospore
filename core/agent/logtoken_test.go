package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261116-24: a verdict prints in brackets with no double quote, so the sign-out scrub (rule 2 redacts every
// quoted token) leaves it readable, and nothing in it can pair with a quote elsewhere on the line.
func TestLogVal(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"PARTIAL 189 2", "[PARTIAL 189 2]"},
		{"OK", "[OK]"},
		{"", "[-]"},
		{`a"b`, "[a?b]"},
		{"a\nb", "[a?b]"},
		{`a\b`, "[a?b]"},
		{"é", "[??]"},
		{"a\x7fb\tc", "[a?b?c]"},
	} {
		got := logVal(c.in)
		if got != c.want {
			t.Errorf("logVal(%q) = %q, want %q", c.in, got, c.want)
		}
		for i := 0; i < len(got); i++ {
			if b := got[i]; b < 0x20 || b > 0x7e || b == '"' || b == '\\' {
				t.Errorf("logVal(%q) = %q keeps byte %#x", c.in, got, b)
			}
		}
	}
}

// A platform interface prints bare and survives the scrub; any other name may be the user's (a WireGuard interface
// named for its tunnel, NOWHERE-982's class) and stays quoted so the scrub still replaces it.
func TestIfaceTok(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"wlan0", "wlan0"},
		{"rmnet_data3", "rmnet_data3"},
		{"tun0", "tun0"},
		{"v4-rmnet_data0", "v4-rmnet_data0"},
		{"wg-home", `"wg-home"`},
		{"my tunnel", `"my tunnel"`},
		{"wlan", `"wlan"`},
		{"wlan0x", `"wlan0x"`},
		{"", `""`},
	} {
		if got := ifaceTok(c.in); got != c.want {
			t.Errorf("ifaceTok(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestEgressLineIface(t *testing.T) {
	line := egressLine("wlan0", nil, "discovered", "")
	if !strings.Contains(line, " iface=wlan0 ") || strings.Contains(line, `"`) {
		t.Errorf("a platform interface must print bare: %q", line)
	}
	if line := egressLine("wg-home", nil, "discovered", ""); !strings.Contains(line, ` iface="wg-home" `) {
		t.Errorf("a user-named interface must stay quoted: %q", line)
	}
}

// The cutoff line carries roamd's verdict in brackets, not in quotes the scrub would take for a name.
func TestLogoffCutoffLine(t *testing.T) {
	dest := cutoffSession(t, "73")
	cutoffWorker(t, dest, map[string]string{"cutoff": "PARTIAL 189 2"}, nil)
	var r string
	out := captureStderr(t, func() { r = logoffCutoff(dest, "zqcutofftok", "73") })
	if r != "PARTIAL 189 2" {
		t.Fatalf("logoffCutoff returned %q, want roamd's verdict unchanged", r)
	}
	if !strings.Contains(out, "cutoff [PARTIAL 189 2] in ") || strings.Contains(out, `cutoff "`) {
		t.Fatalf("the cutoff line does not carry the verdict in brackets:\n%s", out)
	}
}

// grantPermsRequest drives GRANT-PERMS for uid through a stand-in worker and returns the grant request roamd was
// handed. setup seats (or not) a session marker. The tail ops (seed-home, bootwake) are stubbed and waited for, and a
// .localsession marker keeps kickMediad and the tie finish out of the worker.
func grantPermsRequest(t *testing.T, uid string, setup func(dest string)) []string {
	t.Helper()
	calls := bootWakeFakes(t)
	old := tieFinishDelay
	tieFinishDelay = 0
	t.Cleanup(func() { tieFinishDelay = old })
	f, reqs := dropSsaidFixture(t, []abPlan{{lane: laneRW, text: "OK"}})
	if setup != nil {
		setup(f.dest)
	}
	if err := os.WriteFile(filepath.Join(f.dest, ".localsession"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := ropReply(t, func(c net.Conn) { handleGrantPerms(c, f.dest, uid) }); got != "OK" {
		t.Fatalf("GRANT-PERMS replied %q", got)
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(calls()) < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("the grant tail did not run: %v", calls())
		}
		time.Sleep(10 * time.Millisecond)
	}
	got := reqs()
	if len(got) != 1 {
		t.Fatalf("%d worker request(s), want 1: %q", len(got), got)
	}
	lines := strings.Split(got[0], "\n")
	if len(lines) < 4 || lines[0] != "grant" {
		t.Fatalf("the request is %q, want a grant op", got[0])
	}
	return lines
}

// roamd prints the grant op's name slot only in acct_reload's GRANT lines: it must be the session's profile name,
// like the OUT lines, and the uid stays in its own slot. With no marker for this uid the name slot is the uid.
func TestGrantPermsName(t *testing.T) {
	seat := func(name, uid string) func(string) {
		return func(dest string) {
			if err := markRoamSession(dest, name, "pw", uid, ""); err != nil {
				t.Fatal(err)
			}
		}
	}
	t.Run("session", func(t *testing.T) {
		l := grantPermsRequest(t, "31", seat("zqgrantname", "31"))
		if l[1] != "zqgrantname" || l[3] != "31" {
			t.Errorf("name slot %q, uid slot %q; want the session's name and 31", l[1], l[3])
		}
	})
	t.Run("no session", func(t *testing.T) {
		l := grantPermsRequest(t, "31", nil)
		if l[1] != "31" || l[3] != "31" {
			t.Errorf("name slot %q, uid slot %q; want the uid in both", l[1], l[3])
		}
	})
	t.Run("another uid's session", func(t *testing.T) {
		l := grantPermsRequest(t, "31", seat("zqgrantother", "32"))
		if l[1] != "31" || l[3] != "31" {
			t.Errorf("name slot %q, uid slot %q; another session's name must not reach this uid's grant", l[1], l[3])
		}
	})
}
