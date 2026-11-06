package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A test key + a signed manifest, restoring the package globals after.
func withCatalogKey(t *testing.T) (priv ed25519.PrivateKey, restore func()) {
	t.Helper()
	pub, pk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("keygen: %v", err)
	}
	savedKey, savedSys, savedData := catalogPubKey, catalogSystemPath, catalogDataPath
	catalogPubKey = base64.StdEncoding.EncodeToString(pub)
	return pk, func() { catalogPubKey, catalogSystemPath, catalogDataPath = savedKey, savedSys, savedData }
}

func TestVerifyCatalogSig(t *testing.T) {
	priv, restore := withCatalogKey(t)
	defer restore()
	manifest := []byte(`{"schema":1,"entries":[]}`)
	sig := ed25519.Sign(priv, manifest)

	if !verifyCatalogSig(manifest, sig) {
		t.Fatal("valid signature rejected")
	}
	// base64-encoded sig file is also accepted
	if !verifyCatalogSig(manifest, []byte(base64.StdEncoding.EncodeToString(sig))) {
		t.Fatal("valid base64 signature rejected")
	}
	// tampered manifest
	if verifyCatalogSig([]byte(`{"schema":1,"entries":[{"pkg":"evil"}]}`), sig) {
		t.Fatal("signature verified over TAMPERED manifest")
	}
	// wrong key
	otherPub, _, _ := ed25519.GenerateKey(rand.Reader)
	catalogPubKey = base64.StdEncoding.EncodeToString(otherPub)
	if verifyCatalogSig(manifest, sig) {
		t.Fatal("signature verified under the WRONG key")
	}
	// no key baked -> never trusts
	catalogPubKey = ""
	if verifyCatalogSig(manifest, sig) {
		t.Fatal("signature verified with NO key baked")
	}
}

func TestLoadCatalogBytes(t *testing.T) {
	priv, restore := withCatalogKey(t)
	defer restore()
	dir := t.TempDir()
	catalogSystemPath = filepath.Join(dir, "sys.json")
	catalogDataPath = filepath.Join(dir, "data.json")
	sysManifest := []byte(`{"schema":1,"ring":"stable","entries":[]}`)

	// No pubkey baked: the read-only /system copy is trusted directly (verified boot); /data is ignored.
	catalogPubKey = ""
	os.WriteFile(catalogSystemPath, sysManifest, 0o644)
	if got := loadCatalogBytes(); string(got) != string(sysManifest) {
		t.Fatalf("dev mode: want system manifest, got %q", got)
	}
	os.WriteFile(catalogDataPath, []byte(`{"schema":1,"entries":[{"pkg":"unsigned"}]}`), 0o644)
	if got := loadCatalogBytes(); string(got) != string(sysManifest) {
		t.Fatal("dev mode: an UNSIGNED /data override must be ignored")
	}

	// Pubkey baked: /system needs a matching .sig.
	pub := ed25519.PrivateKey(priv).Public().(ed25519.PublicKey)
	catalogPubKey = base64.StdEncoding.EncodeToString(pub)
	if got := loadCatalogBytes(); got != nil {
		t.Fatal("baked-key mode: /system with NO sig must be refused")
	}
	os.WriteFile(catalogSystemPath+".sig", ed25519.Sign(priv, sysManifest), 0o644)
	if got := loadCatalogBytes(); string(got) != string(sysManifest) {
		t.Fatal("baked-key mode: correctly-signed /system must be served")
	}

	// A correctly-signed /data override WINS.
	dataManifest := []byte(`{"schema":1,"ring":"beta","entries":[{"pkg":"org.example"}]}`)
	os.WriteFile(catalogDataPath, dataManifest, 0o644)
	os.WriteFile(catalogDataPath+".sig", ed25519.Sign(priv, dataManifest), 0o644)
	if got := loadCatalogBytes(); string(got) != string(dataManifest) {
		t.Fatal("baked-key mode: a SIGNED /data override must win")
	}
	// A badly-signed /data override falls back to /system.
	os.WriteFile(catalogDataPath+".sig", ed25519.Sign(priv, []byte("something else")), 0o644)
	if got := loadCatalogBytes(); string(got) != string(sysManifest) {
		t.Fatal("baked-key mode: a BADLY-signed /data override must fall back to /system")
	}
}

// The seed manifest that ships in the image must parse + be well-formed.
func TestSeedCatalogParses(t *testing.T) {
	b, err := os.ReadFile("../vendor-common/etc/catalog.json")
	if err != nil {
		t.Skipf("no seed manifest to check (not in this tree slice): %v", err)
	}
	var c catalog
	if err := json.Unmarshal(b, &c); err != nil {
		t.Fatalf("seed catalog is not valid JSON: %v", err)
	}
	if c.Schema != catalogSchema {
		t.Fatalf("seed schema = %d, want %d", c.Schema, catalogSchema)
	}
	if len(c.Entries) == 0 {
		t.Fatal("seed catalog has no entries")
	}
	for i, e := range c.Entries {
		if e.Pkg == "" || e.Label == "" || e.Source == "" {
			t.Errorf("entry %d (%q) missing pkg/label/source", i, e.Pkg)
		}
		// "play" entries are delegated to Aurora (no static URL/hash) -> no apks; every other source needs them.
		if e.Source == "play" {
			if len(e.APKs) != 0 {
				t.Errorf("entry %d (%q) is source=play but carries apks", i, e.Pkg)
			}
			continue
		}
		if len(e.APKs) == 0 {
			t.Errorf("entry %d (%q) missing apks", i, e.Pkg)
		}
		for j, a := range e.APKs {
			if a.Name == "" || a.URL == "" {
				t.Errorf("entry %d apk %d missing name/url", i, j)
			}
		}
	}
}

// The seed manifest must carry a signature that verifies against the BAKED catalogPubKey: with a key baked,
// loadCatalogBytes refuses an unsigned /system copy (ERR-SIG), so an edit that is not re-signed ships an image
// that rejects its own catalog. Nothing else catches that before an image build.
func TestSeedCatalogSignatureVerifies(t *testing.T) {
	manifest, err := os.ReadFile("../vendor-common/etc/catalog.json")
	if err != nil {
		t.Skipf("no seed manifest to check (not in this tree slice): %v", err)
	}
	if catalogPubKey == "" {
		t.Skip("no catalogPubKey baked: the /system manifest is trusted via verified boot and needs no .sig")
	}
	const fix = "re-sign with core/vendor-common/prebuilts/sign-catalog.sh sign core/vendor-common/etc/catalog.json <KEYFILE> " +
		"(maintainer-held key) and commit the .sig; never reformat catalog.json after signing"
	sig, err := os.ReadFile("../vendor-common/etc/catalog.json.sig")
	if err != nil {
		t.Fatalf("seed catalog has no signature (%v): %s", err, fix)
	}
	if !verifyCatalogSig(manifest, sig) {
		t.Fatalf("seed catalog.json.sig does not verify against catalogPubKey -- the image would refuse its own catalog (ERR-SIG): %s", fix)
	}
}

func TestFetchAndVerify(t *testing.T) {
	body := []byte("fake apk bytes for the test")
	sum := sha256.Sum256(body)
	good := hex.EncodeToString(sum[:])
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/missing" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Write(body)
	}))
	defer srv.Close()
	saved := fetchAppHTTP
	fetchAppHTTP = srv.Client()
	defer func() { fetchAppHTTP = saved }()
	dir := t.TempDir()

	// correct hash -> file written with the exact bytes
	out := filepath.Join(dir, "ok.apk")
	if err := fetchAndVerify(context.Background(), srv.URL+"/app.apk", good, out, 0); err != nil {
		t.Fatalf("valid download rejected: %v", err)
	}
	if b, _ := os.ReadFile(out); string(b) != string(body) {
		t.Fatal("wrong bytes written")
	}
	// wrong hash -> error, and NO file left behind (fail-closed)
	bad := filepath.Join(dir, "bad.apk")
	if err := fetchAndVerify(context.Background(), srv.URL+"/app.apk", strings.Repeat("0", 64), bad, 0); err == nil {
		t.Fatal("sha256 mismatch was ACCEPTED")
	}
	if _, err := os.Stat(bad); !os.IsNotExist(err) {
		t.Fatal("a mismatched download was left on disk")
	}
	// empty hash (uncurated entry) -> fail-closed, never fetched
	if err := fetchAndVerify(context.Background(), srv.URL+"/app.apk", "", filepath.Join(dir, "e.apk"), 0); err == nil {
		t.Fatal("empty sha256 was ACCEPTED (must fail-closed)")
	}
	// HTTP error -> error
	if err := fetchAndVerify(context.Background(), srv.URL+"/missing", good, filepath.Join(dir, "m.apk"), 0); err == nil {
		t.Fatal("HTTP 404 was ACCEPTED")
	}
}

func TestFindCatalogEntry(t *testing.T) {
	_, restore := withCatalogKey(t)
	defer restore()
	dir := t.TempDir()
	catalogSystemPath = filepath.Join(dir, "sys.json")
	catalogDataPath = filepath.Join(dir, "data.json")
	catalogPubKey = "" // dev-trust the /system copy
	os.WriteFile(catalogSystemPath, []byte(`{"schema":1,"entries":[
		{"pkg":"org.a","versionCode":5,"label":"A","source":"fdroid","apks":[{"name":"base.apk","url":"u","sha256":""}]},
		{"pkg":"org.b","versionCode":9,"label":"B","source":"fdroid","apks":[{"name":"base.apk","url":"u2","sha256":""}]}
	]}`), 0o644)

	if e := findCatalogEntry("org.a", 0); e == nil || e.Label != "A" {
		t.Fatal("org.a (any version) not found")
	}
	if e := findCatalogEntry("org.b", 9); e == nil || e.Label != "B" {
		t.Fatal("org.b@9 not found")
	}
	if e := findCatalogEntry("org.b", 99); e != nil {
		t.Fatal("a WRONG versionCode matched")
	}
	if e := findCatalogEntry("org.unknown", 0); e != nil {
		t.Fatal("an unknown pkg matched")
	}
}

func TestRefreshCatalog(t *testing.T) {
	priv, restore := withCatalogKey(t)
	defer restore()
	dir := t.TempDir()
	catalogSystemPath = filepath.Join(dir, "sys.json")
	catalogDataPath = filepath.Join(dir, "data.json")

	fresh := []byte(fmt.Sprintf(`{"schema":1,"generated":%d,"ring":"stable","entries":[{"pkg":"org.new","label":"New","source":"fdroid","apks":[{"name":"base.apk","url":"u","sha256":""}]}]}`, time.Now().Unix()))
	freshSig := ed25519.Sign(priv, fresh)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/catalog.json":
			w.Write(fresh)
		case "/catalog.json.sig":
			w.Write(freshSig) // reassigned below to test a bad signature
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	saved := fetchAppHTTP
	fetchAppHTTP = srv.Client()
	defer func() { fetchAppHTTP = saved }()
	t.Setenv("CATALOG_URL", srv.URL+"/catalog.json")

	// happy path: a correctly-signed fetch installs the /data override, and loadCatalogBytes serves it.
	if err := refreshCatalog(); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if b, _ := os.ReadFile(catalogDataPath); string(b) != string(fresh) {
		t.Fatal("refresh did not install the fetched catalog at /data")
	}
	if got := loadCatalogBytes(); string(got) != string(fresh) {
		t.Fatal("loadCatalogBytes did not serve the refreshed /data catalog")
	}

	// no baked key -> benign "disabled" no-op (never fetches).
	savedKey := catalogPubKey
	catalogPubKey = ""
	if err := refreshCatalog(); err == nil || !strings.Contains(err.Error(), "disabled") {
		t.Fatalf("no-key refresh should be a benign 'disabled' no-op, got %v", err)
	}
	catalogPubKey = savedKey

	// tampered signature -> refuse, and DON'T touch /data.
	freshSig = ed25519.Sign(priv, []byte("not the catalog"))
	os.Remove(catalogDataPath)
	if err := refreshCatalog(); err == nil {
		t.Fatal("refresh accepted an invalid signature")
	}
	if _, err := os.Stat(catalogDataPath); !os.IsNotExist(err) {
		t.Fatal("refresh wrote /data despite a bad signature")
	}
}

// The FETCH-APP refusal is parsed by nApps and routed on by chooser v44 (the literal OVERPLAN), and the same text is
// now the daemon log line a report carries -- so its bytes are pinned. Field names, order and units must not drift.
func TestOverPlanReply(t *testing.T) {
	got := overPlanReply(1048576, 5368709120, 4294967296, 41943040)
	want := "ERR-OVERPLAN short=1048576 used=5368709120 covered=4294967296 add=41943040"
	if got != want {
		t.Fatalf("overPlanReply = %q, want %q", got, want)
	}
	if strings.Contains(got, "\n") {
		t.Fatalf("overPlanReply carries a newline; the reply and the log line each add their own: %q", got)
	}
}

// catalogRollbackFixture points the catalog paths at a temp dir and returns a writer for a signed manifest.
func catalogRollbackFixture(t *testing.T) (priv ed25519.PrivateKey, sys, data string, restore func()) {
	t.Helper()
	priv, restore = withCatalogKey(t)
	dir := t.TempDir()
	catalogSystemPath = filepath.Join(dir, "sys.json")
	catalogDataPath = filepath.Join(dir, "data.json")
	return priv, catalogSystemPath, catalogDataPath, restore
}

func writeSignedCatalog(t *testing.T, priv ed25519.PrivateKey, path string, body []byte) {
	t.Helper()
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".sig", ed25519.Sign(priv, body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func catalogWithGenerated(gen int64, pkg string) []byte {
	if gen == 0 {
		return []byte(`{"schema":1,"entries":[{"pkg":"` + pkg + `"}]}`)
	}
	return []byte(fmt.Sprintf(`{"schema":1,"generated":%d,"entries":[{"pkg":"%s"}]}`, gen, pkg))
}

// (a) A signed /data catalog older than the baked one is not served: the OTA's newer catalog stands.
func TestCatalogRollback_olderDataIgnored(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	baked := catalogWithGenerated(200, "org.baked")
	writeSignedCatalog(t, priv, sys, baked)
	writeSignedCatalog(t, priv, data, catalogWithGenerated(100, "org.old"))
	if got := loadCatalogBytes(); string(got) != string(baked) {
		t.Fatalf("an OLDER signed /data catalog shadowed the baked one: served %q", got)
	}
}

// (b) A newer signed /data catalog wins.
func TestCatalogRollback_newerDataWins(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	writeSignedCatalog(t, priv, sys, catalogWithGenerated(100, "org.baked"))
	newer := catalogWithGenerated(200, "org.new")
	writeSignedCatalog(t, priv, data, newer)
	if got := loadCatalogBytes(); string(got) != string(newer) {
		t.Fatalf("a NEWER signed /data catalog was not served: %q", got)
	}
}

// (c) Neither stamped: 0 >= 0, the /data copy still wins (today's behaviour kept).
func TestCatalogRollback_unstampedTieDataWins(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	writeSignedCatalog(t, priv, sys, catalogWithGenerated(0, "org.baked"))
	d := catalogWithGenerated(0, "org.data")
	writeSignedCatalog(t, priv, data, d)
	if got := loadCatalogBytes(); string(got) != string(d) {
		t.Fatalf("two unstamped catalogs: want /data, got %q", got)
	}
}

// (d) A newer but badly signed /data catalog is still refused.
func TestCatalogRollback_badSigStillRefused(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	baked := catalogWithGenerated(100, "org.baked")
	writeSignedCatalog(t, priv, sys, baked)
	writeSignedCatalog(t, priv, data, catalogWithGenerated(200, "org.new"))
	os.WriteFile(data+".sig", ed25519.Sign(priv, []byte("something else")), 0o644)
	if got := loadCatalogBytes(); string(got) != string(baked) {
		t.Fatalf("a badly-signed /data catalog was served: %q", got)
	}
}

// catalogRefreshServer serves body + its signature at CATALOG_URL for the duration of the test.
func catalogRefreshServer(t *testing.T, priv ed25519.PrivateKey, body []byte) {
	t.Helper()
	sig := ed25519.Sign(priv, body)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/catalog.json":
			w.Write(body)
		case "/catalog.json.sig":
			w.Write(sig)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	saved := fetchAppHTTP
	fetchAppHTTP = srv.Client()
	t.Cleanup(func() { fetchAppHTTP = saved })
	t.Setenv("CATALOG_URL", srv.URL+"/catalog.json")
}

// (e) A fetched catalog older than the served one is a no-op: /data is byte-for-byte untouched.
func TestCatalogRollback_refreshOlderIsNoop(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	now := time.Now().Unix()
	writeSignedCatalog(t, priv, sys, catalogWithGenerated(now-1000, "org.baked"))
	served := catalogWithGenerated(now-100, "org.served")
	writeSignedCatalog(t, priv, data, served)
	catalogRefreshServer(t, priv, catalogWithGenerated(now-200, "org.replayed"))
	if err := refreshCatalog(); err != nil {
		t.Fatalf("an older fetch is a no-op, not an error: %v", err)
	}
	if b, _ := os.ReadFile(data); string(b) != string(served) {
		t.Fatalf("an OLDER fetched catalog overwrote /data: %q", b)
	}
}

// (f) A fetched catalog with no stamp, or one stamped two days ahead, is refused and /data is untouched.
func TestCatalogRollback_refreshBadGeneratedRefused(t *testing.T) {
	for name, gen := range map[string]int64{"unstamped": 0, "future": time.Now().Unix() + 2*86400} {
		t.Run(name, func(t *testing.T) {
			priv, sys, data, restore := catalogRollbackFixture(t)
			defer restore()
			now := time.Now().Unix()
			writeSignedCatalog(t, priv, sys, catalogWithGenerated(now-1000, "org.baked"))
			served := catalogWithGenerated(now-100, "org.served")
			writeSignedCatalog(t, priv, data, served)
			catalogRefreshServer(t, priv, catalogWithGenerated(gen, "org.bad"))
			err := refreshCatalog()
			if err == nil || !strings.Contains(err.Error(), "bad generated") {
				t.Fatalf("generated=%d: want a bad-generated error, got %v", gen, err)
			}
			if b, _ := os.ReadFile(data); string(b) != string(served) {
				t.Fatalf("generated=%d: /data was overwritten: %q", gen, b)
			}
		})
	}
}

// (g) A fetched catalog newer than the served one is installed and then served.
func TestCatalogRollback_refreshNewerInstalled(t *testing.T) {
	priv, sys, data, restore := catalogRollbackFixture(t)
	defer restore()
	now := time.Now().Unix()
	writeSignedCatalog(t, priv, sys, catalogWithGenerated(now-1000, "org.baked"))
	writeSignedCatalog(t, priv, data, catalogWithGenerated(now-300, "org.served"))
	newer := catalogWithGenerated(now-10, "org.newer")
	catalogRefreshServer(t, priv, newer)
	if err := refreshCatalog(); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if got := loadCatalogBytes(); string(got) != string(newer) {
		t.Fatalf("the newer fetched catalog was not installed and served: %q", got)
	}
}
