package main

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// NWP-20261117-07 (decision #30, backlog §B "Nothing checks that `/data/nowhere/state` is a tmpfs"): when the state dir
// is DEFINITELY not a tmpfs, the sign-in, create and resume verbs answer ERR-NOTMPFS at their dispatch, before anything
// is written; a statfs that fails is unknown and never refuses. The hook and the seams are package-global, so nothing
// here is parallel.

// sttF2fs is F2FS_SUPER_MAGIC: the durable filesystem a failed tmpfs mount leaves the state dir on.
const sttF2fs = int64(0xF2F52010)

func sttAnswer(ft int64, err error) func(string) (int64, error) {
	return func(string) (int64, error) { return ft, err }
}

// A test's temp dir is not a tmpfs on the build box (nor on most hosts), so without this default every existing test
// that drives one of the guarded verbs through handleLogin would answer ERR-NOTMPFS. Every test runs as before unless it
// sets the hook itself through sttSet.
func init() { stateStatfs = sttAnswer(unix.TMPFS_MAGIC, nil) }

// sttSet makes the hook answer (ft, err) and restores the tmpfs answer when the test ends.
func sttSet(t *testing.T, ft int64, err error) {
	t.Helper()
	stateStatfs = sttAnswer(ft, err)
	t.Cleanup(func() { stateStatfs = sttAnswer(unix.TMPFS_MAGIC, nil) })
}

// sttEnv is a fake init with every state path the verbs could write inside its dest, a store and a gateway that count
// every request, and empty caches. It returns the fake and the request counter.
func sttEnv(t *testing.T) (*abInit, *int32) {
	t.Helper()
	var plan []abPlan
	for i := 0; i < 8; i++ { // a mutant that reaches a worker records a start and gets an answer at once
		plan = append(plan, abPlan{lane: laneRW, text: "BLANK"}, abPlan{lane: laneRO, text: "BLANK"})
	}
	f := abFakeInit(t, plan)
	resetAbandoned(t, nil)
	t.Setenv("NOWHERE_STATE", f.dest)
	t.Setenv("NOWHERE_WALLET", walletPathFor(f.dest))
	t.Setenv("NOWHERE_ENROLL_STATE", filepath.Join(t.TempDir(), "enroll")) // never the host's /data (enroll_test.go)
	var n int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&n, 1)
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	t.Setenv("S3_ENDPOINT", srv.URL)
	t.Setenv("S3_BUCKET", "b")
	t.Setenv("S3_ACCESS_KEY", "k")
	t.Setenv("S3_SECRET_KEY", "s")
	t.Setenv("GATEWAY_URL", srv.URL)
	capReadCache = map[string]capEntry{}
	blobCache, contentCache = nil, nil
	gatePeer(t, 10123) // the user-0 gate: SEED-SSAID is gate-only
	return f, &n
}

// sttListing is every file under dir with its size and sha256, sorted.
func sttListing(t *testing.T, dir string) string {
	t.Helper()
	var out []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		if d.IsDir() {
			out = append(out, rel+"/")
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		out = append(out, fmt.Sprintf("%s %d %x", rel, len(b), sha256.Sum256(b)))
		return nil
	})
	if err != nil {
		t.Fatalf("list %s: %v", dir, err)
	}
	sort.Strings(out)
	return strings.Join(out, "\n")
}

// sttRequest is one verb's request: the first line, then the rest. A legacy login's first line is the profile name.
func sttRequest(verb, name, pass string) (first, rest string) {
	switch verb {
	case "CREATE", "FIDO2-NFC-ASSERT", "FIDO2-NFC-RESUME":
		return verb, name + "\n" + pass + "\n"
	case "CREATE-CODE":
		return verb, name + "\n" + pass + "\nSTT-CODE-1\n"
	case "ROAM-IN":
		return verb, name + "\n" + pass + "\n12\n\n\n"
	case "ROAM-IN-OFFLINE", "SEED-SSAID":
		return verb, name + "\n" + pass + "\n12\n"
	case "RESUME":
		return verb, pass + "\n"
	}
	return name, pass + "\n" // legacy
}

var sttVerbs = []string{"CREATE", "CREATE-CODE", "ROAM-IN", "ROAM-IN-OFFLINE", "RESUME", "SEED-SSAID", "FIDO2-NFC-ASSERT", "FIDO2-NFC-RESUME", "legacy"}

func TestStateTmpfs_EveryVerbRefusesWhenNotTmpfs(t *testing.T) {
	for _, verb := range sttVerbs {
		t.Run(verb, func(t *testing.T) {
			defer waitGateOnly(t)
			sttSet(t, sttF2fs, nil)
			f, n := sttEnv(t)
			if err := os.WriteFile(filepath.Join(f.dest, "keep.txt"), []byte("planted\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(f.dest, "tel"), 0o700); err != nil {
				t.Fatal(err)
			}
			before := sttListing(t, f.dest)
			slug := strings.ToLower(verb)
			var replies []string
			for _, cr := range [][2]string{{"stt-" + slug + "-a", "a long first passphrase for " + slug}, {"stt-" + slug + "-b", "pw"}} {
				first, rest := sttRequest(verb, cr[0], cr[1])
				got, unread, answered := gateOnlyDrive(t, f.dest, first, rest, 10*time.Second)
				if !answered {
					t.Fatalf("%s: no reply within 10 s", verb)
				}
				if got != "ERR-NOTMPFS" {
					t.Errorf("%s: reply %q, want ERR-NOTMPFS", verb, got)
				}
				if verb != "legacy" && !unread {
					t.Errorf("%s: the request lines were read before the refusal", verb)
				}
				replies = append(replies, got)
			}
			if replies[0] != replies[1] {
				t.Errorf("%s: the reply differs between credentials: %q vs %q", verb, replies[0], replies[1])
			}
			if after := sttListing(t, f.dest); after != before {
				t.Errorf("%s: the state dir changed:\nbefore:\n%s\nafter:\n%s", verb, before, after)
			}
			if s := f.snapshot(); len(s) != 0 {
				t.Errorf("%s: %d worker start(s), want none: %+v", verb, len(s), s)
			}
			if c := atomic.LoadInt32(n); c != 0 {
				t.Errorf("%s: %d store/gateway request(s), want none", verb, c)
			}
		})
	}
}

// sttControls drives each guarded verb with an input its own handler answers at once, before any worker lane, and
// checks that answer. A legacy login over a live marker answers BLANK (TestLegacyLoginRefusedWhileMarkerExists).
func sttControls(t *testing.T) {
	t.Helper()
	for _, c := range []struct{ verb, rest, want string }{
		{"CREATE", "\nstt-ctl-create-pass\n", "BLANK"},
		{"CREATE-CODE", "\n\n\n", "BLANK"},
		{"ROAM-IN", "\nstt-ctl-roam-pass\n12\n\n\n", "BLANK"},
		{"ROAM-IN-OFFLINE", "\nstt-ctl-offline-pass\n12\n", "BLANK"},
		{"SEED-SSAID", "\n\n\n", "ERR-ARGS"},
		{"RESUME", "stt-ctl-resume-pass\n", "NONE"},               // no .coldlock
		{"FIDO2-NFC-RESUME", "stt-ctl-fido\nstt-ctl-pw\n", "ERR"}, // no .coldlock: no slot spec
		{"stt-ctl-legacy", "stt-ctl-legacy-pass\n", "BLANK"},      // a live marker refuses the legacy login
	} {
		f, _ := sttEnv(t)
		if c.verb == "stt-ctl-legacy" {
			writeMarker(t, f.dest, "stt-ctl-live\nstt-ctl-live-pass\n11\n\n")
		}
		got, _, answered := gateOnlyDrive(t, f.dest, c.verb, c.rest, 10*time.Second)
		if !answered {
			t.Fatalf("%s: no reply within 10 s", c.verb)
		}
		if got != c.want {
			t.Errorf("%s: reply %q, want its own %q (never ERR-NOTMPFS)", c.verb, got, c.want)
		}
		if s := f.snapshot(); len(s) != 0 {
			t.Errorf("%s: %d worker start(s), want none", c.verb, len(s))
		}
	}
	waitGateOnly(t)
}

func TestStateTmpfs_ControlsWhenTmpfs(t *testing.T) {
	sttSet(t, unix.TMPFS_MAGIC, nil)
	sttControls(t)
}

// The mounted state tmpfs on an enforcing build: the daemon may not getattr its superblock, so statfs fails EACCES.
func TestStateTmpfs_StatfsErrorNeverRefuses(t *testing.T) {
	sttSet(t, 0, unix.EACCES)
	sttControls(t)
	t.Setenv("NOWHERE_DIR", t.TempDir())
	t.Setenv("NOWHERE_STATE", t.TempDir())
	for _, scope := range []bool{true, false} {
		if got := buildIssueReport("", scope, "", nil, nil).Status["state_tmpfs"]; got != "unknown" {
			t.Errorf("deviceScope=%v: state_tmpfs = %q, want unknown", scope, got)
		}
	}
}

func TestStateTmpfs_ReportCarriesTheAnswer(t *testing.T) {
	t.Setenv("NOWHERE_DIR", t.TempDir())
	t.Setenv("NOWHERE_STATE", t.TempDir())
	for _, c := range []struct {
		ft   int64
		want string
	}{{sttF2fs, "no"}, {unix.TMPFS_MAGIC, "yes"}} {
		sttSet(t, c.ft, nil)
		for _, scope := range []bool{true, false} {
			name := ""
			if !scope {
				name = "stt-report"
			}
			if got, ok := buildIssueReport(name, scope, "", nil, nil).Status["state_tmpfs"]; !ok || got != c.want {
				t.Errorf("f_type 0x%x deviceScope=%v: state_tmpfs = %q (present=%v), want %q", c.ft, scope, got, ok, c.want)
			}
		}
	}
}

func TestStateTmpfs_StartLine(t *testing.T) {
	const d = "/data/nowhere/state"
	for _, c := range []struct {
		ft   int64
		err  error
		want string
	}{
		{unix.TMPFS_MAGIC, nil, "[logind] state dir /data/nowhere/state: tmpfs"},
		{sttF2fs, nil, "[logind] state dir /data/nowhere/state: NOT a tmpfs (f_type 0xf2f52010) -- sign-in, create and resume answer ERR-NOTMPFS (#30)"},
		{0, unix.EACCES, "[logind] state dir /data/nowhere/state: tmpfs check unknown (permission denied) -- not refusing (#30)"},
	} {
		sttSet(t, c.ft, c.err)
		if got := stateTmpfsStartLine(d); got != c.want {
			t.Errorf("f_type 0x%x err %v: start line\n%q, want\n%q", c.ft, c.err, got, c.want)
		}
	}
}

func TestStateTmpfs_AnswerTable(t *testing.T) {
	for _, c := range []struct {
		ft     int64
		err    error
		want   tmpfsAnswer
		refuse bool
	}{
		{unix.TMPFS_MAGIC, nil, tmpfsYes, false},
		{sttF2fs, nil, tmpfsNo, true},
		{0, unix.EACCES, tmpfsUnknown, false},
		{0, errors.New("statfs: no such file"), tmpfsUnknown, false},
	} {
		sttSet(t, c.ft, c.err)
		if got, _, _ := stateTmpfs("/x"); got != c.want {
			t.Errorf("f_type 0x%x err %v: answer %s, want %s", c.ft, c.err, got.word(), c.want.word())
		}
		var refused bool
		reply := gateAsk(t, func(conn net.Conn) { refused = refuseNoTmpfs(conn, "/x") })
		if refused != c.refuse {
			t.Errorf("f_type 0x%x err %v: refused=%v, want %v", c.ft, c.err, refused, c.refuse)
		}
		if want := map[bool]string{true: "ERR-NOTMPFS\n", false: ""}[c.refuse]; reply != want {
			t.Errorf("f_type 0x%x err %v: wrote %q, want %q", c.ft, c.err, reply, want)
		}
	}
}
