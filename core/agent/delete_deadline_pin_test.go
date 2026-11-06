package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// NWP-20261011-37 (#744). handleLogin sets one 60s conn deadline at entry, and DELETE used to inherit it while
// the chooser's sendDaemon read waits 90s. A delete that took 60-90s (14 Argon2 derivations plus per-ref store
// round trips) completed, its reply write failed on the expired deadline, and the chooser read EOF and showed
// "the phone didn't answer". This pins both sides: the DELETE arm raises its own deadline before handleDelete,
// that deadline is longer than the chooser's read, and the chooser's read is still the 90s it was priced
// against -- so changing either side alone fails here instead of on a slow network.
//
// A source pin rather than a behavioural test: the failure needs a delete that runs longer than the entry
// deadline, which means a minute of real Argon2 and store latency per run.

var deleteDeadlineLine = regexp.MustCompile(`conn\.SetDeadline\(time\.Now\(\)\.Add\((\d+) \* time\.Second\)\)`)

// chooserDeleteReadMillis is the chooser's sendDaemon read cap that the daemon's DELETE deadline must outlast.
const chooserDeleteReadMillis = 90000

func TestDeleteDeadlineOutlastsChooserRead(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	h := stripComments(funcBody(t, string(b), "handleLogin"))
	start := -1
	for i, l := range h {
		if strings.TrimSpace(l) == `if name == "DELETE" {` {
			start = i
			break
		}
	}
	if start < 0 {
		t.Fatal(`handleLogin has no "if name == \"DELETE\" {" arm -- this test is stale, not the code`)
	}
	secs := -1
	for _, l := range h[start+1:] {
		if strings.Contains(l, "handleDeleteFn(") {
			break
		}
		if strings.TrimSpace(l) == "}" {
			t.Fatal("the DELETE arm closes without calling handleDelete -- this test is stale, not the code")
		}
		if m := deleteDeadlineLine.FindStringSubmatch(l); m != nil {
			secs, _ = strconv.Atoi(m[1])
		}
	}
	if secs < 0 {
		t.Fatal("the DELETE arm calls handleDelete without raising handleLogin's 60s entry deadline (#744)")
	}
	if secs*1000 <= chooserDeleteReadMillis {
		t.Fatalf("the DELETE arm's deadline is %ds, not longer than the chooser's %dms read: a delete that "+
			"completes inside the read window can still lose its reply (#744)", secs, chooserDeleteReadMillis)
	}

	jb, err := os.ReadFile(filepath.Join("..", "chooser", "src", "com", "nowhere", "chooser", "ProfileActivity.java"))
	if err != nil {
		t.Fatal(err)
	}
	java := string(jb)
	if !strings.Contains(java, `sendDaemon("DELETE\n"`) {
		t.Fatal("ProfileActivity no longer sends DELETE through sendDaemon -- re-price the daemon's DELETE deadline against the new caller")
	}
	i := strings.Index(java, "private String sendDaemon(String msg) {")
	if i < 0 {
		t.Fatal("ProfileActivity.sendDaemon not found -- this test is stale, not the code")
	}
	m := regexp.MustCompile(`setSoTimeout\((\d+)\)`).FindStringSubmatch(java[i:])
	if m == nil {
		t.Fatal("ProfileActivity.sendDaemon sets no read timeout")
	}
	if got, _ := strconv.Atoi(m[1]); got != chooserDeleteReadMillis {
		t.Fatalf("ProfileActivity.sendDaemon reads for %dms, the DELETE deadline was priced against %dms: "+
			"re-check the daemon's DELETE deadline and update this pin together (#744)", got, chooserDeleteReadMillis)
	}
}
