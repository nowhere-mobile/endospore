package main

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261120-06 (Q167): CREATE and CREATE-CODE stream "PROGRESS create <done> 20" lines before the verdict, the
// purge of a deleted name included, and a fresh create streams the same first and last lines (create_progress.go).

// dropCreateProgress removes the leading lines of a reply that start with exactly "PROGRESS create ", so a test
// that reads a whole CREATE / CREATE-CODE reply sees its verdict as before. Any other reply comes back unchanged.
func dropCreateProgress(s string) string {
	for strings.HasPrefix(s, "PROGRESS create ") {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			return ""
		}
		s = s[i+1:]
	}
	return s
}

// createProgStream runs fn on one end of a pipe and returns every line the other end read, in order. It fails the
// test when fn has not finished in 30 s.
func createProgStream(t *testing.T, fn func(net.Conn)) []string {
	t.Helper()
	cli, srv := net.Pipe()
	go func() { fn(srv); srv.Close() }()
	got := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		got <- string(b)
	}()
	select {
	case raw := <-got:
		return strings.Split(strings.TrimSuffix(raw, "\n"), "\n")
	case <-time.After(30 * time.Second):
		cli.Close()
		t.Fatal("the create did not finish its reply in 30 s")
		return nil
	}
}

// createProgEnv is the cap-mode store createAndReply writes to ("s3"), with its state on temp dirs.
func createProgEnv(t *testing.T) {
	t.Helper()
	capLockEnv(t)
	fenceTestEnv(t)
	t.Cleanup(clearStaleHit)
	t.Setenv("NOWHERE_ENROLL_STATE", filepath.Join(t.TempDir(), "enroll"))
	t.Setenv("NOWHERE_PROGRESS", "")
}

var createProgOK = regexp.MustCompile(`^OK 0 RECOVERY (\S+ ){11}\S+$`)

// createProgNoLeak fails t when a line names the profile, its passphrase, a purge or a delete.
func createProgNoLeak(t *testing.T, lines []string, name, pass string) {
	t.Helper()
	for _, l := range lines {
		low := strings.ToLower(l)
		if strings.Contains(l, name) || strings.Contains(l, pass) || strings.Contains(low, "purg") || strings.Contains(low, "delet") {
			t.Errorf("a create reply line gives something away: %q", l)
		}
	}
}

func TestCreateProgressFreshCreateStreamsTheBar(t *testing.T) {
	createProgEnv(t)
	const name, pass = "createprogfresh", "a fresh create streams its bar"
	dest := t.TempDir()
	lines := createProgStream(t, func(c net.Conn) { createAndReply(c, dest, name, pass) })
	if len(lines) != 3 || lines[0] != "PROGRESS create 0 20" || lines[1] != "PROGRESS create 20 20" || !createProgOK.MatchString(lines[2]) {
		t.Fatalf("a fresh create streamed %q, want PROGRESS create 0 20, PROGRESS create 20 20, then OK 0 RECOVERY <12 words>", lines)
	}
	createProgNoLeak(t, lines, name, pass)
}

func TestCreateProgressRecreateStreamsThePurge(t *testing.T) {
	createProgEnv(t)
	const name, pass = "createprogrecreate", "a re-create streams the purge"
	if createVault("s3", name, pass) == "" {
		t.Fatal("precondition: the first create returned no recovery code")
	}
	if got := deleteProfile("s3", name, pass); got != "deleted" {
		t.Fatalf("precondition: deleteProfile = %q, want deleted", got)
	}
	capReadCache = map[string]capEntry{}
	dest := t.TempDir()
	lines := createProgStream(t, func(c net.Conn) { createAndReply(c, dest, name, pass) })
	n := len(lines)
	if n <= 3 {
		t.Fatalf("a re-create streamed %q: no purge tick reached the gate", lines)
	}
	if lines[0] != "PROGRESS create 0 20" {
		t.Errorf("the first line is %q, want PROGRESS create 0 20", lines[0])
	}
	if lines[n-2] != "PROGRESS create 20 20" || !createProgOK.MatchString(lines[n-1]) {
		t.Errorf("the stream ends %q, want PROGRESS create 20 20 then OK 0 RECOVERY <12 words>", lines[n-2:])
	}
	tick := regexp.MustCompile(`^PROGRESS create (\d+) 20$`)
	prev := -1
	for _, l := range lines[:n-1] {
		m := tick.FindStringSubmatch(l)
		if m == nil {
			t.Errorf("a progress line is %q, want PROGRESS create <d> 20", l)
			continue
		}
		d, _ := strconv.Atoi(m[1])
		if d < prev {
			t.Errorf("the bar went back from %d to %d: %q", prev, d, lines)
		}
		prev = d
	}
	createProgNoLeak(t, lines, name, pass)
}

func TestCreateProgressRefusedHeadStreamsOnlyTheStart(t *testing.T) {
	createProgEnv(t)
	const name, pass = "createprogfenced", "a head fenced at the flush"
	fenceCreateHeadAtFlush(name, pass)
	t.Cleanup(func() { capStorePutHook = nil })
	dest := t.TempDir()
	lines := createProgStream(t, func(c net.Conn) { createAndReply(c, dest, name, pass) })
	if len(lines) != 2 || lines[0] != "PROGRESS create 0 20" || lines[1] != "BLANK" {
		t.Fatalf("a create over a refused head streamed %q, want PROGRESS create 0 20 then BLANK", lines)
	}
}

// createProgCaptureOut runs fn with os.Stdout and os.Stderr on one pipe and returns what fn wrote to either.
func createProgCaptureOut(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = w, w
	var buf bytes.Buffer
	done := make(chan struct{})
	go func() { io.Copy(&buf, r); close(done) }()
	func() {
		defer func() { os.Stdout, os.Stderr = oldOut, oldErr }()
		fn()
	}()
	w.Close()
	<-done
	r.Close()
	return buf.String()
}

// DELETE and the CLI are unchanged: deleteProfileSE (and a nil prog) tick through writeProg, which writes the
// NOWHERE_PROGRESS file only, never a PROGRESS line on stdout or stderr.
func TestCreateProgressDeleteWithNilProgWritesNothing(t *testing.T) {
	base := newHTTPStore(t)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_PROGRESS", "")
	const name, pass = "createprogdelnil", "a delete with no relay"
	createVault(base, name, pass)
	var got string
	out := createProgCaptureOut(t, func() { got = deleteProfileSE(base, name, pass, nil) })
	if got != "deleted" {
		t.Fatalf("deleteProfileSE = %q, want deleted", got)
	}
	if strings.Contains(out, "PROGRESS") {
		t.Errorf("deleteProfileSE with no relay wrote a PROGRESS line:\n%s", out)
	}

	const name2, pass2 = "createprogdelnil2", "a delete with no relay, the file set"
	createVault(base, name2, pass2)
	pf := filepath.Join(t.TempDir(), "progress")
	t.Setenv("NOWHERE_PROGRESS", pf)
	out = createProgCaptureOut(t, func() { got = deleteProfileSEProg(base, name2, pass2, nil, nil) })
	if got != "deleted" {
		t.Fatalf("deleteProfileSEProg = %q, want deleted", got)
	}
	if strings.Contains(out, "PROGRESS") {
		t.Errorf("deleteProfileSEProg with a nil prog wrote a PROGRESS line:\n%s", out)
	}
	if b, err := os.ReadFile(pf); err != nil || !strings.Contains(string(b), " 20 20") {
		t.Errorf("a nil prog did not tick writeProg's file to 20 of 20: %q (err %v)", b, err)
	}
}

func TestCreateProgressDropKeepsOtherReplies(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"BLANK", "BLANK"},
		{"OK 0 RECOVERY a b", "OK 0 RECOVERY a b"},
		{"PROGRESS create 0 20\nPROGRESS create 20 20\nOK 0 RECOVERY a b", "OK 0 RECOVERY a b"},
		{"PROGRESS create 0 20\nBLANK\n", "BLANK\n"},
		{"PROGRESS restore 1 2\nOK", "PROGRESS restore 1 2\nOK"},
		{"OK\nPROGRESS create 1 20", "OK\nPROGRESS create 1 20"},
		{"PROGRESS created 1 2\nX", "PROGRESS created 1 2\nX"},
		{"", ""},
	} {
		if got := dropCreateProgress(c.in); got != c.want {
			t.Errorf("dropCreateProgress(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
