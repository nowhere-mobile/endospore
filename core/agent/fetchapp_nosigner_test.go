package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

// NWP-20261030-04 (decided 2026-10-20, docs/product-decisions.md item 4): FETCH-APP refuses an entry that does not
// carry a 64-hex signingCert with ERR-NOSIGNER, before the plan gate, the stage dir or any request, so a
// hand-edited catalog can no longer get an app installed with no signer pin.
//
// Every APK below names a sha256 that does NOT match the bytes the server serves. Any entry that gets past the
// refusal therefore stops at ERR-UNVERIFIED after exactly one request and never reaches the stageapp worker lane
// (which would wait out the roam stall budget in a test).

const noSignerLog = "[fetchapp] refused: the entry names no signing cert, so its install could not be pinned (NWP-20261030-04)"

// noSignerFixture points the catalog at a temp file holding entries, the stage base at a temp dir and every APK URL
// at a counting server, and marks a roam session for profile in a temp dest.
func noSignerFixture(t *testing.T, profile string, entries []catalogEntry) (dest string, hits *int32, stageBase string) {
	t.Helper()
	t.Setenv("GATEWAY_URL", "")
	oldPub, oldSys, oldData := catalogPubKey, catalogSystemPath, catalogDataPath
	oldISys, oldIData, oldStage := indexSystemPath, indexDataPath, fetchAppStageBase
	t.Cleanup(func() {
		catalogPubKey, catalogSystemPath, catalogDataPath = oldPub, oldSys, oldData
		indexSystemPath, indexDataPath, fetchAppStageBase = oldISys, oldIData, oldStage
	})
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

	hits = new(int32)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(hits, 1)
		io.WriteString(w, "not-the-apk")
	}))
	t.Cleanup(srv.Close)
	for i := range entries {
		entries[i].APKs = []catalogAPK{{Name: "base.apk", URL: srv.URL + "/" + entries[i].Pkg + ".apk",
			Sha256: strings.Repeat("ab", 32)}}
	}
	b, err := json.Marshal(catalog{Schema: 1, Entries: entries})
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
	return dest, hits, stageBase
}

// noSignerReply drives handleFetchApp over a pipe and returns the trimmed reply and what it wrote to stderr.
func noSignerReply(t *testing.T, dest, arg string) (reply, stderr string) {
	t.Helper()
	stderr = captureStderr(t, func() {
		cli, srv := net.Pipe()
		go func() { handleFetchApp(srv, dest, arg); srv.Close() }()
		b, _ := io.ReadAll(cli)
		reply = strings.TrimSpace(string(b))
	})
	return reply, stderr
}

// assertNoSignerRefusal pins the four facts of a refusal: the reply, no request, nothing staged, the log line
// without the package.
func assertNoSignerRefusal(t *testing.T, reply, stderr string, hits *int32, stageBase, pkg string) {
	t.Helper()
	if reply != "ERR-NOSIGNER" {
		t.Errorf("reply = %q, want ERR-NOSIGNER", reply)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Errorf("%d HTTP request(s) made, want 0", n)
	}
	if ents, _ := os.ReadDir(stageBase); len(ents) != 0 {
		t.Errorf("stage base holds %d entr(ies), want none", len(ents))
	}
	if !strings.Contains(stderr, noSignerLog) {
		t.Errorf("log line missing; stderr = %q", stderr)
	}
	if strings.Contains(stderr, pkg) {
		t.Errorf("log names the package %q: %q", pkg, stderr)
	}
}

func TestFetchAppNoSigner_FdroidEntryRefused(t *testing.T) {
	const pkg = "org.example.nosignera"
	dest, hits, stageBase := noSignerFixture(t, "nosigner-a",
		[]catalogEntry{{Pkg: pkg, VersionCode: 3, Source: "fdroid"}})
	reply, stderr := noSignerReply(t, dest, pkg+" 3")
	assertNoSignerRefusal(t, reply, stderr, hits, stageBase, pkg)
}

func TestFetchAppNoSigner_MalformedCertsRefused(t *testing.T) {
	good63 := strings.Repeat("a1", 31) + "b"
	cases := []struct{ name, source, cert string }{
		{"nowhere-no-cert", "nowhere", ""},
		{"short-63", "fdroid", good63},
		{"non-hex-64", "fdroid", good63 + "g"},
		{"whitespace-only", "nowhere", "   \t "},
	}
	for i, c := range cases {
		c := c
		pkg := fmt.Sprintf("org.example.nosignerb%d", i)
		t.Run(c.name, func(t *testing.T) {
			dest, hits, stageBase := noSignerFixture(t, "nosigner-b-"+c.name,
				[]catalogEntry{{Pkg: pkg, VersionCode: 3, Source: c.source, SigningCert: c.cert}})
			reply, stderr := noSignerReply(t, dest, pkg+" 3")
			assertNoSignerRefusal(t, reply, stderr, hits, stageBase, pkg)
		})
	}
}

func TestFetchAppNoSigner_UpperCaseCertPassesRefusal(t *testing.T) {
	const pkg = "org.example.nosignerc"
	cert := strings.ToUpper(strings.Repeat("0123456789abcdef", 4))
	entry := catalogEntry{Pkg: pkg, VersionCode: 3, Source: "fdroid", SigningCert: cert}
	dest, hits, _ := noSignerFixture(t, "nosigner-c", []catalogEntry{entry})
	reply, _ := noSignerReply(t, dest, pkg+" 3")
	if reply != "ERR-UNVERIFIED" {
		t.Errorf("reply = %q, want ERR-UNVERIFIED (past the refusal, stopped by the sha mismatch)", reply)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Errorf("%d HTTP request(s), want exactly 1", n)
	}
	if got, want := fetchAppSigner(&entry), strings.ToLower(cert); got != want {
		t.Errorf("fetchAppSigner = %q, want %q", got, want)
	}
}

func TestEntrySignerPin(t *testing.T) {
	lower := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	upper := strings.ToUpper(lower)
	cases := []struct {
		name, cert string
		want       string
		ok         bool
	}{
		{"lower", lower, lower, true},
		{"upper", upper, lower, true},
		{"surrounding whitespace", " \t" + upper + "\n ", lower, true},
		{"empty", "", "", false},
		{"whitespace only", "   \t ", "", false},
		{"63", lower[:63], "", false},
		{"65", lower + "a", "", false},
		{"non-hex g", lower[:63] + "g", "", false},
		{"non-ASCII", lower[:62] + "é", "", false},
		{"old dash token", "-", "", false},
	}
	for _, c := range cases {
		got, ok := entrySignerPin(&catalogEntry{SigningCert: c.cert})
		if got != c.want || ok != c.ok {
			t.Errorf("%s: entrySignerPin(%q) = (%q, %v), want (%q, %v)", c.name, c.cert, got, ok, c.want, c.ok)
		}
	}
}
