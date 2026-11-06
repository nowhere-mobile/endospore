package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// NWP-20261114-16 (DECIDED 2026-10-24, dn-1023 #5): the first tap on an on-demand app that needs Play shows the size
// and asks before the fetch starts. These tests pin the size APP-FETCH-SIZE answers, and that it is the size of the
// set restoreAppCode then fetches.

// TestAppFetchBytes: the bytes and the count of each package's own deferred APK files, nothing nested, nothing of
// another package, a duplicate package once, and an invalid name not at all.
func TestAppFetchBytes(t *testing.T) {
	m := chunkManifest{Deferred: map[string]deferredFile{
		"com.alpha/base.apk":       {Size: 1000},
		"com.alpha/split_a.apk":    {Size: 200},
		"com.beta/base.apk":        {Size: 30000},
		"com.beta/split_b.apk":     {Size: 4},
		"com.alpha/lib/arm64/x.so": {Size: 7},      // nested under com.alpha: the fetch never takes it
		"com.alpha/lib/y.so":       {Size: 9},      // nested too; a direct child only of the invalid "com.alpha/lib"
		"com.other/base.apk":       {Size: 500000}, // another package
		"com.alphax/base.apk":      {Size: 60000},  // shares com.alpha's prefix without the slash
	}}
	for _, tc := range []struct {
		pkgs  []string
		bytes int64
		files int
	}{
		{[]string{"com.alpha", "com.beta", "com.alpha", "../x"}, 31204, 4},
		{[]string{"com.alpha"}, 1200, 2},
		{[]string{"com.alpha", "com.alpha"}, 1200, 2},
		{[]string{"../x", "com.alpha/lib"}, 0, 0},
		{nil, 0, 0},
	} {
		b, n := appFetchBytes(m, tc.pkgs)
		if b != tc.bytes || n != tc.files {
			t.Errorf("appFetchBytes(%q) = %d bytes, %d files, want %d bytes, %d files", tc.pkgs, b, n, tc.bytes, tc.files)
		}
	}
}

// fetchSizeStage seals name#apps through the real seal: the files map (rel -> size) is staged, and the rels in
// deferred go into NOWHERE_DEFER_LIST, as the worker's on-demand seal has them. It returns the sealed manifest.
func fetchSizeStage(t *testing.T, base, name, pass string, files map[string]int, deferred []string) chunkManifest {
	t.Helper()
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "0")
	t.Setenv("NOWHERE_SEAL_FILE_THRESHOLD", "4096")
	src := t.TempDir()
	for rel, n := range files {
		p := filepath.Join(src, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, prBytes(n), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	deferPath := filepath.Join(t.TempDir(), "defer")
	if err := os.WriteFile(deferPath, []byte(strings.Join(deferred, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)
	pushProfile(base, name+"#apps", pass, src)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
	key, mb, ok := resolveKey(base, name+"#apps", pass)
	if !ok {
		t.Fatal("no #apps head after push")
	}
	var m chunkManifest
	if err := json.Unmarshal(unseal(key, mb)[len(cdcMagic):], &m); err != nil {
		t.Fatalf("decode #apps manifest: %v", err)
	}
	for _, rel := range deferred {
		if _, ok := m.Deferred[rel]; !ok {
			t.Fatalf("setup: %q is not deferred; deferred set = %v", rel, deferredRels(m.Deferred))
		}
	}
	return m
}

// TestIsPkgApkRelMatchesRestore: the rels restoreAppCode writes for a package are exactly the rels isPkgApkRel
// admits from the manifest, and appFetchBytes is their size, so the size can never describe a different set.
func TestIsPkgApkRelMatchesRestore(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "fetchsize-restore", "fetch size restore staple"
	createVault(base, name, pass)
	files := map[string]int{
		"com.od/base.apk":          300 << 10,
		"com.od/split_x.apk":       70 << 10,
		"com.od/lib/arm64/x.so":    50 << 10, // deferred, but nested: not one of the package's APK files
		"com.od/_meta/meta":        64,
		"com.odx/base.apk":         90 << 10, // shares the com.od prefix without the slash
		"com.keep/base.apk":        40 << 10, // installed: essential
		"com.od.other/split_y.apk": 20 << 10,
	}
	deferred := []string{"com.od/base.apk", "com.od/split_x.apk", "com.od/lib/arm64/x.so", "com.odx/base.apk",
		"com.od.other/split_y.apk"}
	m := fetchSizeStage(t, base, name, pass, files, deferred)

	var admitted []string
	for rel := range m.Deferred {
		if isPkgApkRel(rel, "com.od") {
			admitted = append(admitted, rel)
		}
	}
	sort.Strings(admitted)
	if want := []string{"com.od/base.apk", "com.od/split_x.apk"}; fmt.Sprint(admitted) != fmt.Sprint(want) {
		t.Fatalf("isPkgApkRel admits %v, want %v", admitted, want)
	}

	tap := t.TempDir()
	n, err := restoreAppCode(base, name+"#apps", pass, "com.od", tap)
	if err != nil {
		t.Fatalf("restoreAppCode: %v", err)
	}
	var written []string
	var writtenB int64
	filepath.WalkDir(tap, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(tap, p)
		written = append(written, filepath.ToSlash(rel))
		if fi, err := d.Info(); err == nil {
			writtenB += fi.Size()
		}
		return nil
	})
	sort.Strings(written)
	if fmt.Sprint(written) != fmt.Sprint(admitted) || n != len(admitted) {
		t.Fatalf("restoreAppCode wrote %v (n=%d), isPkgApkRel admits %v", written, n, admitted)
	}
	if b, c := appFetchBytes(m, []string{"com.od"}); b != writtenB || c != len(written) {
		t.Fatalf("appFetchBytes = %d bytes, %d files; the fetch wrote %d bytes, %d files", b, c, writtenB, len(written))
	}
}

// fetchSizeVerb drives handleAppFetchSize over a pipe with one request line and returns the reply.
func fetchSizeVerb(t *testing.T, dest, line string) string {
	t.Helper()
	c1, c2 := net.Pipe()
	go func() {
		// The daemon's recoverConnPanic only logs a handler's panic and closes the connection: the chooser reads
		// EOF. Do the same here, so a panic is an empty reply this test reports, not a dead test binary.
		defer c2.Close()
		defer func() { recover() }()
		handleAppFetchSize(c2, dest, bufio.NewReader(strings.NewReader(line)))
	}()
	raw, err := io.ReadAll(c1)
	if err != nil {
		t.Fatalf("reading the APP-FETCH-SIZE reply: %v", err)
	}
	return strings.TrimSpace(string(raw))
}

// TestAppFetchSizeVerb pins the wire contract in cap mode, the fielded store: OK <bytes> <files> from the session's
// own name#apps head, NONE with no session, LOCAL for a throwaway, ERR when the scope does not open, and ERR-PKG for
// a request it refuses before it reads anything.
func TestAppFetchSizeVerb(t *testing.T) {
	srv, objs, mu := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}

	const name, pass = "fetchsize-verb", "fetch size verb staple"
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	files := map[string]int{
		"com.alpha/base.apk":    200 << 10,
		"com.alpha/split_a.apk": 30 << 10,
		"com.beta/base.apk":     110 << 10,
		"com.keep/base.apk":     40 << 10, // installed: essential, never part of a fetch
	}
	m := fetchSizeStage(t, "s3", name, pass, files, []string{"com.alpha/base.apk", "com.alpha/split_a.apk", "com.beta/base.apk"})
	alphaB := int64(files["com.alpha/base.apk"] + files["com.alpha/split_a.apk"])
	bothB := alphaB + int64(files["com.beta/base.apk"])
	if b, n := appFetchBytes(m, []string{"com.alpha", "com.beta"}); b != bothB || n != 3 {
		t.Fatalf("setup: the sealed manifest sizes the pair at %d bytes, %d files, want %d, 3", b, n, bothB)
	}

	dest := t.TempDir()
	if err := writeRoamSession(dest, name, pass, "10", "", true); err != nil {
		t.Fatal(err)
	}
	// A profile with a vault and no #apps head: the scope does not open.
	const bare, barePass = "fetchsize-bare", "fetch size bare staple"
	if createVault("s3", bare, barePass) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	bareDest := t.TempDir()
	if err := writeRoamSession(bareDest, bare, barePass, "11", "", true); err != nil {
		t.Fatal(err)
	}
	localDest := t.TempDir()
	if err := writeRoamSession(localDest, name, pass, "12", "", true); err != nil {
		t.Fatal(err)
	}
	markLocalSession(localDest)

	// Damaged #apps heads (RF-001): each resolves or unseals into a panic, and the verb must answer ERR, not drop
	// the connection. The head ref names a legacy head blob (the sealed manifest itself), written straight into the
	// store: too short for a nonce, failing GCM, or not matching the hash its ref names.
	damaged := func(label string, uid string, body []byte, served []byte) string {
		dn, dp := "fetchsize-dmg-"+label, "fetch size damaged "+label+" staple"
		href, _, _ := headRef("s3", dn+"#apps", dp)
		sum := sha256.Sum256(body)
		h := hex.EncodeToString(sum[:])
		mu.Lock()
		objs["blob/"+h] = served
		objs["ref/"+href] = []byte(h)
		mu.Unlock()
		capReadCache = map[string]capEntry{}
		d := t.TempDir()
		if err := writeRoamSession(d, dn, dp, uid, "", true); err != nil {
			t.Fatal(err)
		}
		return d
	}
	shortBody := []byte("short")
	badBody := prBytes(4096) // nonce + ciphertext long enough, sealed by nobody: GCM refuses it
	shortDest := damaged("short", "13", shortBody, shortBody)
	gcmDest := damaged("gcm", "14", badBody, badBody)
	hashDest := damaged("hash", "15", badBody, prBytes(4095))

	var many, sixteen []string
	for i := 0; i < 17; i++ {
		many = append(many, fmt.Sprintf("com.p%d", i))
	}
	sixteen = many[:16]

	for _, tc := range []struct{ label, dest, line, want string }{
		{"two packages", dest, "com.alpha com.beta\n", fmt.Sprintf("OK %d 3", bothB)},
		{"a duplicate package", dest, "com.alpha com.alpha\n", fmt.Sprintf("OK %d 2", alphaB)},
		{"CRLF", dest, "com.beta\r\n", fmt.Sprintf("OK %d 1", files["com.beta/base.apk"])},
		{"an installed package", dest, "com.keep\n", "OK 0 0"},
		{"no session", t.TempDir(), "com.alpha\n", "NONE"},
		{"a local session", localDest, "com.alpha\n", "LOCAL"},
		{"no #apps head", bareDest, "com.alpha\n", "ERR"},
		{"a head too short to unseal", shortDest, "com.alpha\n", "ERR"},
		{"a head that fails GCM", gcmDest, "com.alpha\n", "ERR"},
		{"a head blob that does not match its hash", hashDest, "com.alpha\n", "ERR"},
		{"17 packages", dest, strings.Join(many, " ") + "\n", "ERR-PKG"},
		{"16 packages", dest, strings.Join(sixteen, " ") + "\n", "OK 0 0"},
		{"an empty line", dest, "\n", "ERR-PKG"},
		{"no line", dest, "", "ERR-PKG"},
		{"a path", dest, "../x\n", "ERR-PKG"},
		{"one invalid of two", dest, "com.alpha ../x\n", "ERR-PKG"},
	} {
		if got := fetchSizeVerb(t, tc.dest, tc.line); got != tc.want {
			t.Errorf("%s: APP-FETCH-SIZE = %q, want %q", tc.label, got, tc.want)
		}
	}
}
