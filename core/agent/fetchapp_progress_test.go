package main

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261122-14: FETCH-APP with the `progress` opt-in streams "PROGRESS <got> <total>" lines before its one verdict
// line, so the add's notification can show a real bar. Without the opt-in the reply is the verdict line only. Every
// fixture's second APK has a wrong sha256: the whole entry downloads and the handler answers ERR-UNVERIFIED before
// the stageapp worker lane, so no test reaches triggerRoamWorkerKind.

const fapChunks, fapChunk = 40, 512

// fapFixture serves a two-APK entry (base.apk with its right sha256, split.apk with a wrong one) in small flushed
// chunks, so the copy loop makes many reads. It returns the session dest, the entry total and the server URL.
func fapFixture(t *testing.T, profile string) (dest string, total int64, srvURL string) {
	t.Helper()
	body := make([]byte, fapChunks*fapChunk)
	for i := range body {
		body[i] = byte(i * 7)
	}
	serve := func(w http.ResponseWriter, r *http.Request) {
		for i := 0; i < fapChunks; i++ {
			w.Write(body[i*fapChunk : (i+1)*fapChunk])
			w.(http.Flusher).Flush()
			time.Sleep(time.Millisecond)
		}
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/apk/fap-base.apk", serve)
	mux.HandleFunc("/apk/fap-split.apk", serve)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	n := int64(len(body))
	dest = falFixture(t, profile, []catalogAPK{
		{Name: "base.apk", URL: srv.URL + "/apk/fap-base.apk", Sha256: fabSha(body), Size: n},
		{Name: "split.apk", URL: srv.URL + "/apk/fap-split.apk", Sha256: fabSha([]byte("other bytes")), Size: n},
	}, time.Hour)
	oldLine := fetchAppProgressLineEvery
	t.Cleanup(func() { fetchAppProgressLineEvery = oldLine })
	fetchAppProgressLineEvery = 0
	return dest, 2 * n, srv.URL
}

func fapLines(reply string) []string {
	var out []string
	for _, l := range strings.Split(reply, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// With the opt-in: PROGRESS 0 <total> first, then PROGRESS lines with a non-decreasing running total that ends at
// the entry total, then exactly one verdict line. No line holds the package, the label or the URL.
func TestFetchAppProgress_StreamsOnOptIn(t *testing.T) {
	dest, total, srvURL := fapFixture(t, "fap-stream")
	reply, _ := noSignerReply(t, dest, falPkg+" 0 progress")
	lines := fapLines(reply)
	if len(lines) < 3 {
		t.Fatalf("reply = %q, want a start PROGRESS line, more PROGRESS lines and a verdict", lines)
	}
	if want := fmt.Sprintf("PROGRESS 0 %d", total); lines[0] != want {
		t.Errorf("first line = %q, want %q", lines[0], want)
	}
	re := regexp.MustCompile(fmt.Sprintf(`^PROGRESS (\d+) %d$`, total))
	var prev, last int64 = -1, -1
	for _, l := range lines[:len(lines)-1] {
		m := re.FindStringSubmatch(l)
		if m == nil {
			t.Errorf("line %q is not PROGRESS <got> %d", l, total)
			continue
		}
		g, _ := strconv.ParseInt(m[1], 10, 64)
		if g < prev {
			t.Errorf("got went down: %d after %d", g, prev)
		}
		prev, last = g, g
	}
	if last != total {
		t.Errorf("last PROGRESS got = %d, want the entry total %d", last, total)
	}
	if v := lines[len(lines)-1]; v != "ERR-UNVERIFIED" {
		t.Errorf("verdict = %q, want ERR-UNVERIFIED", v)
	}
	for _, l := range lines {
		for _, s := range []string{falPkg, falLabel, srvURL, "/apk/"} {
			if strings.Contains(l, s) {
				t.Errorf("reply line %q holds %q", l, s)
			}
		}
	}
}

// Without the opt-in (no third field, or no versionCode either) the reply is today's single verdict line.
func TestFetchAppProgress_NoneWithoutOptIn(t *testing.T) {
	for _, arg := range []string{falPkg + " 0", falPkg, falPkg + " 0 progressx"} {
		dest, _, _ := fapFixture(t, "fap-plain")
		reply, _ := noSignerReply(t, dest, arg)
		if reply != "ERR-UNVERIFIED" {
			t.Errorf("arg %q: reply = %q, want exactly ERR-UNVERIFIED", arg, reply)
		}
		for _, l := range fapLines(reply) {
			if strings.HasPrefix(l, "PROGRESS") {
				t.Errorf("arg %q: PROGRESS line %q without the opt-in", arg, l)
			}
		}
	}
}

// A chooser that reads the start line and then goes away never holds the handler: the download runs to its end and
// the done line shows the same verdict. The wait is bounded by the test binary's own timeout only.
func TestFetchAppProgress_ClosedReaderDoesNotHang(t *testing.T) {
	dest, total, _ := fapFixture(t, "fap-closed")
	var first string
	var rerr error
	stderr := captureStderr(t, func() {
		cli, srv := net.Pipe()
		done := make(chan struct{})
		go func() { handleFetchApp(srv, dest, falPkg+" 0 progress"); srv.Close(); close(done) }()
		first, rerr = bufio.NewReader(cli).ReadString('\n')
		cli.Close()
		<-done
	})
	if want := fmt.Sprintf("PROGRESS 0 %d\n", total); rerr != nil || first != want {
		t.Errorf("first line = %q (%v), want %q", first, rerr, want)
	}
	doneRe := regexp.MustCompile(fmt.Sprintf(`^\[fetchapp\] done: %d bytes in \d+s -> ERR-UNVERIFIED$`, total))
	var dones []string
	for _, l := range strings.Split(stderr, "\n") {
		if falDoneRe.MatchString(l) {
			dones = append(dones, l)
		}
	}
	if len(dones) != 1 || !doneRe.MatchString(dones[0]) {
		t.Errorf("done lines = %q, want exactly one matching %s", dones, doneRe)
	}
}

// Each PROGRESS write is bounded at 2 s and then goes back to connDL, the handler's own bound, which is taken just
// before the unchanged SetDeadline line. A behavioural case would need a reader that blocks at a chosen write.
func TestFetchAppProgress_WriteDeadlineSource(t *testing.T) {
	b, err := os.ReadFile("catalog.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	i := strings.Index(src, "\nfunc handleFetchApp(")
	if i < 0 {
		t.Fatal("handleFetchApp not found in catalog.go")
	}
	body := src[i+1:]
	if j := strings.Index(body, "\nfunc "); j >= 0 {
		body = body[:j]
	}
	const set, write, restore = "conn.SetWriteDeadline(now.Add(2 * time.Second))",
		"fetchAppProgressLine(n, total)", "conn.SetWriteDeadline(connDL)"
	if c := strings.Count(body, set); c != 1 {
		t.Fatalf("%q occurs %d times in handleFetchApp, want 1", set, c)
	}
	si, wi := strings.Index(body, set), strings.Index(body, write)
	ri := strings.Index(body, restore)
	if wi < 0 || si > wi || ri < wi {
		t.Errorf("want %q, then %q, then %q in handleFetchApp (at %d, %d, %d)", set, write, restore, si, wi, ri)
	}
	dl := regexp.MustCompile(`\n\t+connDL := time\.Now\(\)\.Add\(fetchAppBudget \+ fetchAppStageAllowance\)\n` +
		`\t+conn\.SetDeadline\(time\.Now\(\)\.Add\(fetchAppBudget \+ fetchAppStageAllowance\)\) //`)
	if c := len(dl.FindAllString(body, -1)); c != 1 {
		t.Errorf("the connDL line followed by the handler's SetDeadline line occurs %d times, want 1", c)
	}
}
