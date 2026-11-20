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
	// NWP-20261210-14: sendDaemon takes its read cap from DaemonReadCap by verb. DELETE (and ROLLBACK, which
	// TestStoreVerbDeadlinesOutlastChooserRead prices against the same read) must get LONG_MS, the 90s priced here.
	if !strings.Contains(chooserMethodBody(t, java, "private String sendDaemon(String msg) {"),
		"setSoTimeout(DaemonReadCap.forRequest(msg))") {
		t.Fatal("ProfileActivity.sendDaemon no longer takes its read cap from DaemonReadCap.forRequest(msg) -- " +
			"re-price the daemon's DELETE deadline against the new read cap (#744)")
	}
	long, quick := chooserDaemonReadCap(t)
	if long != chooserDeleteReadMillis {
		t.Fatalf("DaemonReadCap.LONG_MS is %dms, the DELETE deadline was priced against %dms: "+
			"re-check the daemon's DELETE deadline and update this pin together (#744)", long, chooserDeleteReadMillis)
	}
	for _, v := range []string{"DELETE", "ROLLBACK"} {
		if quick[v] {
			t.Errorf("DaemonReadCap.QUICK holds %s: its read is no longer the %dms its daemon deadline outlasts (#744)",
				v, chooserDeleteReadMillis)
		}
	}
}

// chooserMethodBody returns the Java method whose signature line is sig, through its balanced closing brace.
func chooserMethodBody(t *testing.T, java, sig string) string {
	t.Helper()
	i := strings.Index(java, sig)
	if i < 0 {
		t.Fatalf("%q not found -- this test is stale, not the code", sig)
	}
	depth := 0
	for k := i + strings.Index(java[i:], "{"); k < len(java); k++ {
		switch java[k] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return java[i : k+1]
			}
		}
	}
	t.Fatalf("%q has no closing brace", sig)
	return ""
}

// chooserDaemonReadCap reads the chooser's DaemonReadCap.java (NWP-20261210-14), comments stripped: LONG_MS, and the
// verbs of the QUICK set, which read for SHORT_MS instead.
func chooserDaemonReadCap(t *testing.T) (longMillis int, quick map[string]bool) {
	t.Helper()
	src := chooserCode(t, "DaemonReadCap.java")
	m := regexp.MustCompile(`static final int LONG_MS = (\d+);`).FindStringSubmatch(src)
	if m == nil {
		t.Fatal("DaemonReadCap.java declares no LONG_MS -- this test is stale, not the code")
	}
	longMillis, _ = strconv.Atoi(m[1])
	set := regexp.MustCompile(`(?s)Set<String> QUICK = [^;]*;`).FindString(src)
	if set == "" {
		t.Fatal("DaemonReadCap.java declares no QUICK set -- this test is stale, not the code")
	}
	quick = map[string]bool{}
	for _, v := range regexp.MustCompile(`"([^"]+)"`).FindAllStringSubmatch(set, -1) {
		quick[v[1]] = true
	}
	if len(quick) == 0 {
		t.Fatal("DaemonReadCap.QUICK parsed empty -- the parse is wrong, not the code")
	}
	return longMillis, quick
}
