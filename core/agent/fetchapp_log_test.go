package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261113-26: FETCH-APP logs one start line before its first download, a progress line at most once per
// fetchAppProgressEvery from the copy loop, and one done line on every exit after the start. login.log survives the
// boot-wipe (#39), so the three lines carry counts and times only: no package, label or URL. Every fixture ends before
// the stageapp worker lane (the last APK fails), so no test reaches triggerRoamWorkerKind.

const (
	falPkg   = "org.fal.secretpkg"
	falLabel = "Fal Secret Label"
)

var (
	falStartRe    = regexp.MustCompile(`^\[fetchapp\] start: `)
	falProgressRe = regexp.MustCompile(`^\[fetchapp\] progress: `)
	falDoneRe     = regexp.MustCompile(`^\[fetchapp\] done: `)
)

// falFixture points the catalog at a temp file holding one labelled entry for falPkg with apks, the stage base at its
// own temp dir, and marks a roam session for profile in a temp dest. The progress interval is restored at the end.
func falFixture(t *testing.T, profile string, apks []catalogAPK, every time.Duration) string {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	oldPub, oldSys, oldData := catalogPubKey, catalogSystemPath, catalogDataPath
	oldISys, oldIData, oldStage := indexSystemPath, indexDataPath, fetchAppStageBase
	oldEvery := fetchAppProgressEvery
	t.Cleanup(func() {
		catalogPubKey, catalogSystemPath, catalogDataPath = oldPub, oldSys, oldData
		indexSystemPath, indexDataPath, fetchAppStageBase = oldISys, oldIData, oldStage
		fetchAppProgressEvery = oldEvery
	})
	fabSetVars(t, 2*time.Second, fetchAppMaxBytes)
	fetchAppProgressEvery = every
	tmp := t.TempDir()
	catalogPubKey = ""
	catalogSystemPath = filepath.Join(tmp, "sys.json")
	catalogDataPath = filepath.Join(tmp, "data.json")
	indexSystemPath = filepath.Join(tmp, "index-sys.json")
	indexDataPath = filepath.Join(tmp, "index-data.json")
	fetchAppStageBase = filepath.Join(tmp, "stage")
	if err := os.MkdirAll(fetchAppStageBase, 0o700); err != nil {
		t.Fatal(err)
	}
	b, err := json.Marshal(catalog{Schema: 1, Entries: []catalogEntry{{Pkg: falPkg, Label: falLabel, VersionCode: 3,
		Source: "fdroid", SigningCert: fsoSigner, APKs: apks}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(catalogSystemPath, b, 0o600); err != nil {
		t.Fatal(err)
	}
	dest := t.TempDir()
	if err := markRoamSession(dest, profile, "pw-"+profile, "10", ""); err != nil {
		t.Fatalf("markRoamSession: %v", err)
	}
	raiseDest := t.TempDir()
	signOutLower(raiseDest) // an earlier test's raise must not leak into this one
	t.Cleanup(func() { signOutLower(raiseDest) })
	return dest
}

// falRun drives handleFetchApp for falPkg with stderr captured; elapsed is the wall time of the whole handler run.
func falRun(t *testing.T, dest string) (reply string, lines []string, elapsed time.Duration) {
	t.Helper()
	t0 := time.Now()
	reply, stderr := noSignerReply(t, dest, falPkg)
	elapsed = time.Since(t0)
	for _, l := range strings.Split(stderr, "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	return reply, lines, elapsed
}

func falMatching(lines []string, re *regexp.Regexp) []string {
	var out []string
	for _, l := range lines {
		if re.MatchString(l) {
			out = append(out, l)
		}
	}
	return out
}

// falAssertShape checks exactly one start line equal to wantStart, one done line matching wantDone, the done line
// after the start, and that no new line holds the package, the label or any of the urls.
func falAssertShape(t *testing.T, lines []string, wantStart string, wantDone *regexp.Regexp, urls ...string) {
	t.Helper()
	starts := falMatching(lines, falStartRe)
	if len(starts) != 1 || starts[0] != wantStart {
		t.Errorf("start lines = %q, want exactly [%q]", starts, wantStart)
	}
	dones := falMatching(lines, falDoneRe)
	if len(dones) != 1 || !wantDone.MatchString(dones[0]) {
		t.Errorf("done lines = %q, want exactly one matching %s", dones, wantDone)
	}
	si, di := -1, -1
	for i, l := range lines {
		if falStartRe.MatchString(l) && si < 0 {
			si = i
		}
		if falDoneRe.MatchString(l) {
			di = i
		}
	}
	if si < 0 || di < si {
		t.Errorf("the done line (%d) does not follow the start line (%d): %q", di, si, lines)
	}
	secret := append([]string{falPkg, falLabel}, urls...)
	for _, l := range lines {
		if !falStartRe.MatchString(l) && !falProgressRe.MatchString(l) && !falDoneRe.MatchString(l) {
			continue
		}
		for _, s := range secret {
			if strings.Contains(l, s) {
				t.Errorf("log line %q holds %q", l, s)
			}
		}
	}
}

// (a), (c), (d): a slow body with a wrong sha256 logs one start, at least one progress line but never more than one
// per interval, and one done line ending -> ERR-UNVERIFIED.
func TestFetchAppLog_SlowBodyWrongSha(t *testing.T) {
	const chunks, chunk = 80, 512
	body := make([]byte, chunks*chunk)
	for i := range body {
		body[i] = byte(i)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/apk/slow-base.apk", func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < chunks; i++ {
			w.Write(body[i*chunk : (i+1)*chunk])
			w.(http.Flusher).Flush()
			time.Sleep(5 * time.Millisecond)
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	url := srv.URL + "/apk/slow-base.apk"
	every := 50 * time.Millisecond
	dest := falFixture(t, "fal-unverified", []catalogAPK{{Name: "base.apk", URL: url,
		Sha256: fabSha([]byte("other bytes")), Size: int64(len(body))}}, every)
	reply, lines, elapsed := falRun(t, dest)
	if reply != "ERR-UNVERIFIED" {
		t.Errorf("reply = %q, want ERR-UNVERIFIED", reply)
	}
	n := len(body)
	falAssertShape(t, lines, fmt.Sprintf("[fetchapp] start: 1 apk(s), %d bytes (NWP-20261113-26)", n),
		regexp.MustCompile(fmt.Sprintf(`^\[fetchapp\] done: %d bytes in \d+s -> ERR-UNVERIFIED$`, n)),
		url, "/apk/slow-base.apk", srv.URL)
	progress := falMatching(lines, falProgressRe)
	pr := regexp.MustCompile(fmt.Sprintf(`^\[fetchapp\] progress: \d+ of %d bytes, \d+s$`, n))
	for _, l := range progress {
		if !pr.MatchString(l) {
			t.Errorf("progress line %q does not match %s", l, pr)
		}
	}
	if len(progress) == 0 {
		t.Errorf("no progress line in %v of a slow download (interval %v): %q", elapsed, every, lines)
	}
	if lim := int(elapsed/every) + 1; len(progress) > lim {
		t.Errorf("%d progress lines in %v at an interval of %v, want at most %d", len(progress), elapsed, every, lim)
	}
}

// (b), (c): a server error logs one start and one done line ending -> ERR-FETCH, with no byte counted.
func TestFetchAppLog_ServerError(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/apk/err-base.apk", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	url := srv.URL + "/apk/err-base.apk"
	dest := falFixture(t, "fal-fetch", []catalogAPK{{Name: "base.apk", URL: url,
		Sha256: fabSha([]byte("x")), Size: 4321}}, 5*time.Millisecond)
	reply, lines, _ := falRun(t, dest)
	if reply != "ERR-FETCH" {
		t.Errorf("reply = %q, want ERR-FETCH", reply)
	}
	falAssertShape(t, lines, "[fetchapp] start: 1 apk(s), 4321 bytes (NWP-20261113-26)",
		regexp.MustCompile(`^\[fetchapp\] done: 0 bytes in \d+s -> ERR-FETCH$`),
		url, "/apk/err-base.apk", srv.URL)
}

// (e): the counts run across all of the entry's APKs; the second APK's wrong sha256 ends before stageapp.
func TestFetchAppLog_CountsAcrossApks(t *testing.T) {
	a := []byte(strings.Repeat("a", 3000))
	b := []byte(strings.Repeat("b", 2000))
	mux := http.NewServeMux()
	mux.HandleFunc("/apk/two-base.apk", func(w http.ResponseWriter, r *http.Request) { w.Write(a) })
	mux.HandleFunc("/apk/two-split.apk", func(w http.ResponseWriter, r *http.Request) { w.Write(b) })
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	dest := falFixture(t, "fal-two", []catalogAPK{
		{Name: "base.apk", URL: srv.URL + "/apk/two-base.apk", Sha256: fabSha(a), Size: int64(len(a))},
		{Name: "split_config.arm64_v8a.apk", URL: srv.URL + "/apk/two-split.apk", Sha256: fabSha([]byte("no")),
			Size: int64(len(b))},
	}, time.Hour)
	reply, lines, _ := falRun(t, dest)
	if reply != "ERR-UNVERIFIED" {
		t.Errorf("reply = %q, want ERR-UNVERIFIED", reply)
	}
	n := len(a) + len(b)
	falAssertShape(t, lines, fmt.Sprintf("[fetchapp] start: 2 apk(s), %d bytes (NWP-20261113-26)", n),
		regexp.MustCompile(fmt.Sprintf(`^\[fetchapp\] done: %d bytes in \d+s -> ERR-UNVERIFIED$`, n)),
		srv.URL, "/apk/two-base.apk", "/apk/two-split.apk")
}

func TestFetchAppLog_EndLine(t *testing.T) {
	for _, c := range []struct {
		bytes int64
		d     time.Duration
		reply string
		want  string
	}{
		{46_000_000, 420 * time.Second, "OK com.x ab..", "[fetchapp] done: 46000000 bytes in 420s -> OK"},
		{0, 0, "ERR-FETCH\n", "[fetchapp] done: 0 bytes in 0s -> ERR-FETCH"},
		{7, 1900 * time.Millisecond, "ERR-UNVERIFIED", "[fetchapp] done: 7 bytes in 1s -> ERR-UNVERIFIED"},
		{1, time.Second, "", "[fetchapp] done: 1 bytes in 1s -> (empty)"},
	} {
		if got := fetchAppEndLine(c.bytes, c.d, c.reply); got != c.want {
			t.Errorf("fetchAppEndLine(%d, %v, %q) = %q, want %q", c.bytes, c.d, c.reply, got, c.want)
		}
	}
}

// The OK reply and the stageapp worker's own reply print the done line too. No test drives them (they sit behind the
// stageapp worker lane), so this reads handleFetchApp's source.
func TestFetchAppLog_OKPathPrintsEndLine(t *testing.T) {
	src, err := os.ReadFile("catalog.go")
	if err != nil {
		t.Fatal(err)
	}
	s := string(src)
	i := strings.Index(s, "func handleFetchApp(")
	if i < 0 {
		t.Fatal("EXTRACTION FAILED: func handleFetchApp( not found in catalog.go")
	}
	body := s[i:]
	if j := strings.Index(body[1:], "\nfunc "); j >= 0 {
		body = body[:j+1]
	}
	k := strings.Index(body, "endReply := func(")
	if k < 0 {
		t.Fatal("EXTRACTION FAILED: endReply := func( not found in handleFetchApp")
	}
	def := body[k:]
	if e := strings.Index(def, "\n\t}\n"); e >= 0 {
		def = def[:e]
	}
	if !strings.Contains(def, "fetchAppEndLine(") {
		t.Errorf("endReply does not print fetchAppEndLine: %q", def)
	}
	ok := strings.Index(body, `"OK %s %s"`)
	if ok < 0 {
		t.Fatal("EXTRACTION FAILED: the OK reply format not found in handleFetchApp")
	}
	ls := strings.LastIndex(body[:ok], "\n")
	le := strings.Index(body[ok:], "\n")
	if le < 0 {
		le = len(body) - ok
	}
	if line := body[ls+1 : ok+le]; !strings.Contains(line, "endReply(") {
		t.Errorf("the OK reply does not go through endReply, so it prints no done line: %q", strings.TrimSpace(line))
	}
	w := strings.Index(body, "triggerRoamWorkerKind(")
	if w < 0 || w > ok {
		t.Fatal("EXTRACTION FAILED: triggerRoamWorkerKind( not found before the OK reply")
	}
	if !strings.Contains(body[w:ok], "endReply(") {
		t.Errorf("the stageapp worker's own reply does not go through endReply: %q", body[w:ok])
	}
}
