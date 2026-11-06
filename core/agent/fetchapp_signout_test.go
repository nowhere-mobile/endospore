package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// NWP-20261109-14 (Q116, docs/product-decisions.md, 2026-10-20): a sign-out cancels a store install's FETCH-APP at its
// next safe point, the download. LOGOUT waiting for sessionMu raises signOutWaiting(); handleFetchApp cuts the body in
// flight, checks before each APK's download (the first included) and on a failed one, removes the stage and answers
// ERR-CANCELLED. Every fixture ends before the stageapp worker lane: a body that blocks, a cut, or a wrong sha256.

const fsoSigner = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// fsoServer counts the requests per path; a blocking route writes part of a body, then waits for release or for the
// client to go away.
type fsoServer struct {
	srv     *httptest.Server
	hits    map[string]*atomic.Int32
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (s *fsoServer) releaseAll() { s.once.Do(func() { close(s.release) }) }

func (s *fsoServer) blocking(w http.ResponseWriter, r *http.Request) {
	w.Write(make([]byte, 1024))
	w.(http.Flusher).Flush()
	select {
	case s.started <- struct{}{}:
	default:
	}
	select {
	case <-s.release:
	case <-r.Context().Done():
	}
}

// fsoServe starts a server with one handler per path. srv.Close's cleanup is registered before the release's, so the
// release runs first and no handler holds srv.Close.
func fsoServe(t *testing.T, routes map[string]http.HandlerFunc) *fsoServer {
	t.Helper()
	s := &fsoServer{hits: map[string]*atomic.Int32{}, started: make(chan struct{}, 1), release: make(chan struct{})}
	mux := http.NewServeMux()
	for path, h := range routes {
		n := new(atomic.Int32)
		s.hits[path] = n
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) { n.Add(1); h(w, r) })
	}
	s.srv = httptest.NewServer(mux)
	t.Cleanup(s.srv.Close)
	t.Cleanup(s.releaseAll)
	return s
}

func (s *fsoServer) totalHits() int32 {
	var n int32
	for _, h := range s.hits {
		n += h.Load()
	}
	return n
}

// fsoFixture points the catalog at a temp file holding one entry for pkg with apks, the stage base at its own temp dir,
// and marks a roam session for profile in a temp dest. raiseDest is the dest signOutRaise writes its marker into; the
// signal is lowered when the test ends.
func fsoFixture(t *testing.T, profile, pkg string, apks []catalogAPK, stall time.Duration) (dest, stageBase, raiseDest string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	oldPub, oldSys, oldData := catalogPubKey, catalogSystemPath, catalogDataPath
	oldISys, oldIData, oldStage := indexSystemPath, indexDataPath, fetchAppStageBase
	t.Cleanup(func() {
		catalogPubKey, catalogSystemPath, catalogDataPath = oldPub, oldSys, oldData
		indexSystemPath, indexDataPath, fetchAppStageBase = oldISys, oldIData, oldStage
	})
	fabSetVars(t, stall, fetchAppMaxBytes)
	tmp := t.TempDir()
	catalogPubKey = ""
	catalogSystemPath = filepath.Join(tmp, "sys.json")
	catalogDataPath = filepath.Join(tmp, "data.json")
	indexSystemPath = filepath.Join(tmp, "index-sys.json")
	indexDataPath = filepath.Join(tmp, "index-data.json")
	stageBase = filepath.Join(tmp, "stage")
	if err := os.MkdirAll(stageBase, 0o700); err != nil {
		t.Fatal(err)
	}
	fetchAppStageBase = stageBase
	b, err := json.Marshal(catalog{Schema: 1, Entries: []catalogEntry{{Pkg: pkg, VersionCode: 3, Source: "fdroid",
		SigningCert: fsoSigner, APKs: apks}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(catalogSystemPath, b, 0o600); err != nil {
		t.Fatal(err)
	}
	dest = t.TempDir()
	if err := markRoamSession(dest, profile, "pw-"+profile, "10", ""); err != nil {
		t.Fatalf("markRoamSession: %v", err)
	}
	raiseDest = t.TempDir()
	signOutLower(raiseDest) // an earlier test's raise must not leak into this one
	t.Cleanup(func() { signOutLower(raiseDest) })
	return dest, stageBase, raiseDest
}

// fsoStart drives handleFetchApp over a pipe; the channel gets the trimmed reply once the handler has returned.
func fsoStart(dest, arg string) <-chan string {
	ch := make(chan string, 1)
	cli, srv := net.Pipe()
	go func() { handleFetchApp(srv, dest, arg); srv.Close() }()
	go func() {
		b, _ := io.ReadAll(cli)
		ch <- strings.TrimSpace(string(b))
	}()
	return ch
}

// fsoAwait returns the reply; past limit it records an error, releases the server so the handler can end, and keeps
// waiting.
func fsoAwait(t *testing.T, ch <-chan string, s *fsoServer, limit time.Duration) string {
	t.Helper()
	select {
	case r := <-ch:
		return r
	case <-time.After(limit):
		t.Errorf("no reply within %v of the sign-out (fetchAppStall %v)", limit, fetchAppStall)
		s.releaseAll()
		return <-ch
	}
}

// fsoJoin joins every goSafe job the handler started (the sign-out watcher and the stall timer) and only then reads
// the watcher's count: its exit is asynchronous to the reply.
func fsoJoin(t *testing.T, tr *goSafeTracker) {
	t.Helper()
	tr.wait(t, 5*time.Second)
	if n := tr.count("fetchapp-signout"); n != 0 {
		t.Errorf("%d fetchapp-signout watcher(s) outlived FETCH-APP", n)
	}
}

func fsoStageGone(t *testing.T, stageBase, pkg string) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(stageBase, pkg)); err == nil {
		t.Errorf("the stage %s was left behind", filepath.Join(stageBase, pkg))
	}
}

func fsoCancelLine(pkg string) string {
	return "[fetchapp] " + pkg + ": cancelled for a sign-out (Q116)"
}

// F1: a raise while the body is coming in cuts it at once, long before the stall bound.
func TestFetchAppSignout_CutsTheBody(t *testing.T) {
	tr := trackGoSafe(t)
	t.Cleanup(func() { tr.wait(t, 5*time.Second) })
	const pkg = "org.example.fsoa"
	var s *fsoServer
	s = fsoServe(t, map[string]http.HandlerFunc{"/a.apk": func(w http.ResponseWriter, r *http.Request) { s.blocking(w, r) }})
	dest, stageBase, raiseDest := fsoFixture(t, "fso-f1", pkg,
		[]catalogAPK{{Name: "base.apk", URL: s.srv.URL + "/a.apk", Sha256: fabSha(bytes.Repeat([]byte("x"), 64<<10)), Size: 64 << 10}},
		3*time.Second)
	var reply string
	stderr := captureStderr(t, func() {
		ch := fsoStart(dest, pkg+" 3")
		select {
		case <-s.started:
		case <-time.After(2 * time.Second):
			s.releaseAll()
			reply = "the download never started: " + <-ch
			return
		}
		signOutRaise(raiseDest)
		reply = fsoAwait(t, ch, s, 1500*time.Millisecond)
	})
	fsoJoin(t, tr)
	if reply != "ERR-CANCELLED" {
		t.Errorf("reply = %q, want ERR-CANCELLED", reply)
	}
	if strings.Contains(reply, "mismatch") || strings.Contains(reply, "UNVERIFIED") {
		t.Errorf("a body the sign-out cut was reported as a mismatch: %q", reply)
	}
	fsoStageGone(t, stageBase, pkg)
	if !strings.Contains(stderr, fsoCancelLine(pkg)) {
		t.Errorf("the cancel line is missing; stderr = %q", stderr)
	}
	for _, ln := range strings.Split(stderr, "\n") {
		if strings.Contains(ln, "cancelled for a sign-out (Q116)") && (strings.Contains(ln, "http") || strings.Contains(ln, "fso-f1")) {
			t.Errorf("the cancel line names a URL or the profile: %q", ln)
		}
	}
}

// F2: a raise that lands while the first APK finishes stops FETCH-APP before the second is requested.
func TestFetchAppSignout_BetweenAPKs(t *testing.T) {
	tr := trackGoSafe(t)
	t.Cleanup(func() { tr.wait(t, 5*time.Second) })
	const pkg = "org.example.fsob"
	body := bytes.Repeat([]byte("y"), 4<<10)
	var s *fsoServer
	var raiseDest string
	s = fsoServe(t, map[string]http.HandlerFunc{
		"/a.apk": func(w http.ResponseWriter, r *http.Request) {
			w.Write(body)
			w.(http.Flusher).Flush()
			signOutRaise(raiseDest)
		},
		"/b.apk": func(w http.ResponseWriter, r *http.Request) { s.blocking(w, r) },
	})
	dest, stageBase, rd := fsoFixture(t, "fso-f2", pkg, []catalogAPK{
		{Name: "base.apk", URL: s.srv.URL + "/a.apk", Sha256: fabSha(body), Size: int64(len(body))},
		{Name: "split.apk", URL: s.srv.URL + "/b.apk", Sha256: fabSha(bytes.Repeat([]byte("z"), 4<<10)), Size: 4 << 10},
	}, 3*time.Second)
	raiseDest = rd
	var reply string
	stderr := captureStderr(t, func() {
		reply = fsoAwait(t, fsoStart(dest, pkg+" 3"), s, 2*time.Second)
		fsoJoin(t, tr)
	})
	if reply != "ERR-CANCELLED" {
		t.Errorf("reply = %q, want ERR-CANCELLED", reply)
	}
	if n := s.hits["/b.apk"].Load(); n != 0 {
		t.Errorf("the second APK was requested %d time(s) after the sign-out, want 0", n)
	}
	if strings.Contains(stderr, "split.apk") {
		t.Errorf("a download of the second APK was attempted; stderr = %q", stderr)
	}
	fsoStageGone(t, stageBase, pkg)
}

// F3: with no sign-out, FETCH-APP answers as it always did (here: the sha256 does not match, ERR-UNVERIFIED).
func TestFetchAppSignout_NoRaiseKeepsTheNormalAnswer(t *testing.T) {
	tr := trackGoSafe(t)
	t.Cleanup(func() { tr.wait(t, 5*time.Second) })
	const pkg = "org.example.fsoc"
	s := fsoServe(t, map[string]http.HandlerFunc{"/a.apk": func(w http.ResponseWriter, r *http.Request) {
		w.Write(bytes.Repeat([]byte("w"), 4<<10))
	}})
	dest, stageBase, _ := fsoFixture(t, "fso-f3", pkg,
		[]catalogAPK{{Name: "base.apk", URL: s.srv.URL + "/a.apk", Sha256: strings.Repeat("ab", 32), Size: 4 << 10}},
		3*time.Second)
	var reply string
	stderr := captureStderr(t, func() {
		reply = fsoAwait(t, fsoStart(dest, pkg+" 3"), s, 5*time.Second)
		fsoJoin(t, tr)
	})
	if reply != "ERR-UNVERIFIED" {
		t.Errorf("reply = %q, want the normal ERR-UNVERIFIED", reply)
	}
	if strings.Contains(stderr, "cancelled for a sign-out") {
		t.Errorf("a FETCH-APP no sign-out touched logged a cancel: %q", stderr)
	}
	select {
	case <-signOutWaiting():
		t.Error("the sign-out signal is raised after a FETCH-APP with no sign-out")
	default:
	}
	fsoStageGone(t, stageBase, pkg)
}

// F4: a sign-out raised before FETCH-APP started stops it before the first download. Repeated: the channel read, not
// the watcher's asynchronous cancel, is what must decide the first check.
func TestFetchAppSignout_RaisedBeforeFetch(t *testing.T) {
	tr := trackGoSafe(t)
	t.Cleanup(func() { tr.wait(t, 5*time.Second) })
	var s *fsoServer
	s = fsoServe(t, map[string]http.HandlerFunc{"/a.apk": func(w http.ResponseWriter, r *http.Request) { s.blocking(w, r) }})
	for round := 0; round < 5; round++ {
		pkg := fmt.Sprintf("org.example.fsod%d", round)
		dest, stageBase, raiseDest := fsoFixture(t, fmt.Sprintf("fso-f4-%d", round), pkg,
			[]catalogAPK{{Name: "base.apk", URL: s.srv.URL + "/a.apk", Sha256: strings.Repeat("cd", 32), Size: 4 << 10}},
			3*time.Second)
		signOutRaise(raiseDest)
		var reply string
		stderr := captureStderr(t, func() {
			reply = fsoAwait(t, fsoStart(dest, pkg+" 3"), s, 1500*time.Millisecond)
			fsoJoin(t, tr)
		})
		if reply != "ERR-CANCELLED" {
			t.Errorf("round %d: reply = %q, want ERR-CANCELLED", round, reply)
		}
		if n := s.totalHits(); n != 0 {
			t.Errorf("round %d: the server got %d request(s), want 0", round, n)
		}
		if strings.Contains(stderr, "base.apk") {
			t.Errorf("round %d: a download was attempted; stderr = %q", round, stderr)
		}
		fsoStageGone(t, stageBase, pkg)
		signOutLower(raiseDest)
	}
}
