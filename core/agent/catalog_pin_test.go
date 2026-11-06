package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// CATALOG-PIN (Q050, NWP-20261112-05): the versionCode and signer FETCH-APP would install for one package, so the
// chooser's tap can update an on-demand app when the catalog pins a newer version from the same signer.

// catPinFixture points the catalog AND the index at fresh signed files in a temp dir, holding curated and index as
// their entries, and restores every global it changes (plus the index caches) when the test ends.
func catPinFixture(t *testing.T, curated, index []catalogEntry) {
	t.Helper()
	cPub, cPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	iPub, iPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	ck, cs, cd := catalogPubKey, catalogSystemPath, catalogDataPath
	ik, is, id := indexPubKey, indexSystemPath, indexDataPath
	t.Cleanup(func() {
		catalogPubKey, catalogSystemPath, catalogDataPath = ck, cs, cd
		indexPubKey, indexSystemPath, indexDataPath = ik, is, id
		resetIndexCaches()
	})
	dir := t.TempDir()
	catalogPubKey = base64.StdEncoding.EncodeToString(cPub)
	catalogSystemPath = filepath.Join(dir, "catalog.json")
	catalogDataPath = filepath.Join(dir, "catalog-data.json") // absent: the baked copy is served
	indexPubKey = base64.StdEncoding.EncodeToString(iPub)
	indexSystemPath = filepath.Join(dir, "index.json")
	indexDataPath = filepath.Join(dir, "index-data.json") // absent
	catPinWriteSigned(t, catalogSystemPath, cPriv, curated)
	catPinWriteSigned(t, indexSystemPath, iPriv, index)
	resetIndexCaches()
}

func catPinWriteSigned(t *testing.T, path string, priv ed25519.PrivateKey, entries []catalogEntry) {
	t.Helper()
	if entries == nil {
		entries = []catalogEntry{}
	}
	b, err := json.Marshal(catalog{Schema: 1, Entries: entries})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", ed25519.Sign(priv, b), 0o644); err != nil {
		t.Fatal(err)
	}
}

// catPinEntry is a store entry with apks base APKs, each with a 64-hex sha256.
func catPinEntry(pkg string, vc int64, cert string, apks int) catalogEntry {
	e := catalogEntry{Pkg: pkg, VersionCode: vc, Label: pkg, Source: "fdroid", SigningCert: cert}
	for i := 0; i < apks; i++ {
		e.APKs = append(e.APKs, catalogAPK{Name: "base.apk", URL: "https://f-droid.org/repo/" + pkg + ".apk",
			Sha256: strings.Repeat("e", 64), Size: 100})
	}
	return e
}

// catPinAsk runs handleCatalogPin over a pipe and returns the RAW reply, newline included.
func catPinAsk(t *testing.T, arg string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go func() {
		handleCatalogPin(srv, arg)
		srv.Close()
	}()
	b, err := io.ReadAll(cli)
	cli.Close()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(b)
}

// catPinMatchesFetch checks that an OK reply names exactly what FETCH-APP resolves: its versionCode is
// findAppEntry(pkg, 0)'s, and "FETCH-APP <pkg> <versionCode>" resolves an entry with that versionCode and signer.
func catPinMatchesFetch(t *testing.T, pkg, reply string) {
	t.Helper()
	f := strings.Fields(strings.TrimSuffix(reply, "\n"))
	if len(f) != 3 || f[0] != "OK" {
		t.Fatalf("%s: want an OK reply, got %q", pkg, reply)
	}
	vc, err := strconv.ParseInt(f[1], 10, 64)
	if err != nil {
		t.Fatalf("%s: versionCode %q: %v", pkg, f[1], err)
	}
	latest := findAppEntry(pkg, 0)
	if latest == nil || latest.VersionCode != vc {
		t.Fatalf("%s: answered versionCode %d, findAppEntry(pkg, 0) resolves %+v", pkg, vc, latest)
	}
	pinned := findAppEntry(pkg, vc)
	if pinned == nil || pinned.VersionCode != vc {
		t.Fatalf("%s: FETCH-APP %d would resolve %+v", pkg, vc, pinned)
	}
	if pin, ok := entrySignerPin(pinned); !ok || pin != f[2] {
		t.Fatalf("%s: answered signer %q, FETCH-APP %d pins %q (ok=%v)", pkg, f[2], vc, pin, ok)
	}
}

// P1: a curated entry FETCH-APP would install answers its versionCode and its cert lower-cased.
func TestCatalogPin_curatedPin(t *testing.T) {
	pkg := "org.example.pin"
	catPinFixture(t, []catalogEntry{catPinEntry(pkg, 42, strings.Repeat("AB", 32), 1)}, nil)
	want := "OK 42 " + strings.Repeat("ab", 32) + "\n"
	got := catPinAsk(t, pkg)
	if got != want {
		t.Fatalf("CATALOG-PIN %s = %q, want %q", pkg, got, want)
	}
	catPinMatchesFetch(t, pkg, got)
}

// P2: what FETCH-APP would refuse (ERR-NOENTRY / ERR-NOSIGNER) is never offered.
func TestCatalogPin_refusedEntriesAreNone(t *testing.T) {
	pkg := "org.example.refused"
	for _, c := range []struct {
		name string
		e    catalogEntry
	}{
		{"no cert", catPinEntry(pkg, 42, "", 1)},
		{"63-char cert", catPinEntry(pkg, 42, strings.Repeat("a", 63), 1)},
		{"non-hex cert", catPinEntry(pkg, 42, strings.Repeat("g", 64), 1)},
		{"no APKs", catPinEntry(pkg, 42, strings.Repeat("a", 64), 0)},
		{"versionCode 0", catPinEntry(pkg, 0, strings.Repeat("a", 64), 1)},
	} {
		t.Run(c.name, func(t *testing.T) {
			catPinFixture(t, []catalogEntry{c.e}, nil)
			if got := catPinAsk(t, pkg); got != "NONE\n" {
				t.Fatalf("CATALOG-PIN for an entry with %s = %q, want %q", c.name, got, "NONE\n")
			}
		})
	}
	if got := catalogPinLine(nil); got != "NONE" {
		t.Fatalf("catalogPinLine(nil) = %q, want NONE", got)
	}
}

// P3: an unknown package, an empty store and a bad package name.
func TestCatalogPin_unknownAndBadPkg(t *testing.T) {
	catPinFixture(t, []catalogEntry{catPinEntry("org.example.known", 42, strings.Repeat("a", 64), 1)},
		[]catalogEntry{catPinEntry("org.example.indexed", 7, strings.Repeat("c", 64), 1)})
	if got := catPinAsk(t, "org.example.unknown"); got != "NONE\n" {
		t.Fatalf("unknown package: %q, want NONE", got)
	}
	for _, bad := range []string{"../x", "", "  "} {
		if got := catPinAsk(t, bad); got != "ERR-PKG\n" {
			t.Fatalf("package %q: %q, want ERR-PKG", bad, got)
		}
	}
	t.Run("empty catalog and index", func(t *testing.T) {
		catPinFixture(t, nil, nil)
		if got := catPinAsk(t, "org.example.known"); got != "NONE\n" {
			t.Fatalf("empty store: %q, want NONE", got)
		}
	})
}

// P4: an index-only package answers its index entry; a package in both answers the curated entry, as
// findAppEntry resolves it.
func TestCatalogPin_indexAndPrecedence(t *testing.T) {
	only, both := "org.example.indexonly", "org.example.both"
	catPinFixture(t,
		[]catalogEntry{catPinEntry(both, 42, strings.Repeat("ab", 32), 1)},
		[]catalogEntry{catPinEntry(only, 7, strings.Repeat("cd", 32), 1), catPinEntry(both, 50, strings.Repeat("ef", 32), 1)})
	if got, want := catPinAsk(t, only), "OK 7 "+strings.Repeat("cd", 32)+"\n"; got != want {
		t.Fatalf("index-only package: %q, want %q", got, want)
	} else {
		catPinMatchesFetch(t, only, got)
	}
	if got, want := catPinAsk(t, both), "OK 42 "+strings.Repeat("ab", 32)+"\n"; got != want {
		t.Fatalf("package in both (curated 42, index 50): %q, want the curated %q", got, want)
	} else {
		catPinMatchesFetch(t, both, got)
	}
}

// P5: every reply is exactly one line.
func TestCatalogPin_oneLine(t *testing.T) {
	pkg := "org.example.oneline"
	catPinFixture(t, []catalogEntry{catPinEntry(pkg, 3, strings.Repeat("a", 64), 1)}, nil)
	for _, arg := range []string{pkg, "org.example.absent", "../x"} {
		got := catPinAsk(t, arg)
		if strings.Count(got, "\n") != 1 || !strings.HasSuffix(got, "\n") {
			t.Fatalf("CATALOG-PIN %q: reply %q is not exactly one line", arg, got)
		}
	}
}

// P6: the verb is dispatched, ungated, and its handler logs nothing.
func TestCatalogPin_sourceWiring(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	h := stripComments(funcBody(t, string(b), "handleLogin"))
	arm := -1
	for i, l := range h {
		if strings.TrimSpace(l) == `if name == "CATALOG-PIN" {` {
			arm = i
			break
		}
	}
	if arm < 0 {
		t.Fatal(`handleLogin has no "CATALOG-PIN" dispatch arm`)
	}
	indent := h[arm][:len(h[arm])-len(strings.TrimLeft(h[arm], "\t"))]
	dispatched := false
	for _, l := range h[arm+1:] {
		if l == indent+"}" {
			break
		}
		if strings.Contains(l, "handleCatalogPin(") {
			dispatched = true
		}
	}
	if !dispatched {
		t.Fatal(`the "CATALOG-PIN" arm does not call handleCatalogPin`)
	}
	if gateOnlyCmd("CATALOG-PIN") {
		t.Fatal("CATALOG-PIN is gate-only, but the roamed session's chooser sends it")
	}
	c, err := os.ReadFile("catalog.go")
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(c), "handleCatalogPin"))
	for _, l := range body {
		for _, bad := range []string{"os.Stderr", "log.", "logf(", "Println(", "Printf("} {
			if strings.Contains(l, bad) {
				t.Fatalf("handleCatalogPin logs (%q): a package name in the daemon log is the user's app choice", l)
			}
		}
	}
	if !strings.Contains(strings.Join(body, "\n"), "findAppEntry(pkg, 0)") {
		t.Fatal("handleCatalogPin does not resolve findAppEntry(pkg, 0), the entry FETCH-APP installs by default")
	}
}
