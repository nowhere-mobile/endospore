package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261027-09: SEAL-DELTA could not tell a profile with no #apps head (before its first #apps seal) from a store it
// could not read, so Your data said "Apps in your store: unknown right now." for a profile that keeps apps. A head every
// rung of whose ladder is a DEFINITE not-found now reads measured and empty; every other failed read stays unknown.

// sdnhEnv points sealDeltaBase at base and gives the test fresh caches and state.
func sdnhEnv(t *testing.T, base string) {
	t.Helper()
	old := sealDeltaBase
	sealDeltaBase = base
	t.Cleanup(func() { sealDeltaBase = old })
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SE_SECRET", "")
	sdseResetCaches(t)
}

// sdnhSettled waits (5 s at most) for the cache's refresh to land.
func sdnhSettled(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		sealDeltaCache.mu.Lock()
		done := !sealDeltaCache.inFlight && !sealDeltaCache.at.IsZero()
		sealDeltaCache.mu.Unlock()
		if done {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the stored-apps refresh did not land within 5 s")
}

func sdnhRead(t *testing.T, name, pass string) (map[string]int64, bool) {
	t.Helper()
	storedAppsCached(name, pass, nil)
	sdnhSettled(t)
	return storedAppsCached(name, pass, nil)
}

func TestStoredAppsNoHeadReadsMeasuredAndEmpty(t *testing.T) {
	name, pass := "sdnh-absent", "sdnh absent passphrase"
	base := newHTTPStore(t)
	sdnhEnv(t, base)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if _, ok := scopeManifest(base, name+"#apps", pass, nil); ok {
		t.Fatal("control: a #apps head exists, so this test cannot tell the forms apart")
	}
	if !appsHeadAbsent(base, name, pass) {
		t.Fatal("appsHeadAbsent = false for a store that answers a definite not-found on every rung")
	}
	apps, known := sdnhRead(t, name, pass)
	if !known || apps == nil || len(apps) != 0 {
		t.Fatalf("no #apps head: known=%v apps=%#v, want measured and a non-nil empty map", known, apps)
	}
}

func TestSealDeltaNoHeadReplySaysMeasured(t *testing.T) {
	name, pass := "sdnh-reply", "sdnh reply passphrase"
	base := newHTTPStore(t)
	sdnhEnv(t, base)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	dest := t.TempDir()
	if err := markRoamSession(dest, name, pass, "12", ""); err != nil {
		t.Fatal(err)
	}
	old := lastSealStartedAt.Load()
	t.Cleanup(func() { lastSealStartedAt.Store(old) })
	var body string
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		out := ropReply(t, func(c net.Conn) { handleSealDelta(c, dest) })
		i := strings.Index(out, "\n")
		if i < 0 || !strings.HasPrefix(out, "OK ") {
			t.Fatalf("reply = %q, want OK <n> then JSON", out)
		}
		body = out[i+1:]
		if strings.Contains(body, `"storedMeasured":true`) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(body, `"storedMeasured":true`) {
		t.Fatalf("reply %s lacks \"storedMeasured\":true", body)
	}
	if strings.Contains(body, `"storedApps"`) {
		t.Fatalf("reply %s carries a storedApps key for an empty map (omitempty)", body)
	}
}

func TestStoredAppsNoHeadFailedReadStaysUnknown(t *testing.T) {
	name, pass := "sdnh-500", "sdnh 500 passphrase"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	sdnhEnv(t, srv.URL)
	if appsHeadAbsent(srv.URL, name, pass) {
		t.Fatal("appsHeadAbsent = true for a store that answers 500: a failed read must never read as nothing stored")
	}
	apps, known := sdnhRead(t, name, pass)
	if known || apps != nil {
		t.Fatalf("a store answering 500: known=%v apps=%#v, want unknown", known, apps)
	}
}

// A store where one rung of the ladder answers 500 and the rest a definite 404: the strict walk must not skip the
// failed rung and read the 404 after it as absence.
func TestStoredAppsNoHeadOneRungFailingStaysUnknown(t *testing.T) {
	name, pass := "sdnh-rung", "sdnh rung passphrase"
	failing := profileRefV2(name+"#apps", pass)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/"+failing) {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	sdnhEnv(t, srv.URL)
	if appsHeadAbsent(srv.URL, name, pass) {
		t.Fatal("appsHeadAbsent = true although the v2 rung answered 500")
	}
	apps, known := sdnhRead(t, name, pass)
	if known || apps != nil {
		t.Fatalf("one rung answering 500: known=%v apps=%#v, want unknown", known, apps)
	}
}

func TestStoredAppsNoHeadUnreadableHeadStaysUnknown(t *testing.T) {
	name, pass := "sdnh-unreadable", "sdnh unreadable passphrase"
	base := newHTTPStore(t)
	sdnhEnv(t, base)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	putRef(base, headKey(base, name+"#apps", pass), postBlob(base, []byte("not a sealed head")))
	pushFenceSeq, pushFenceSampled = 0, false
	if _, ok := scopeManifest(base, name+"#apps", pass, nil); ok {
		t.Fatal("control: the forged head opened")
	}
	if _, h, _ := headRefWith(base, name+"#apps", pass, refProbeStrict); h == "" {
		t.Fatal("control: the forged head is not present")
	}
	if appsHeadAbsent(base, name, pass) {
		t.Fatal("appsHeadAbsent = true for a present head")
	}
	apps, known := sdnhRead(t, name, pass)
	if known || apps != nil {
		t.Fatalf("an unreadable head: known=%v apps=%#v, want unknown", known, apps)
	}
}

func TestStoredAppsNoHeadPresentHeadUnchanged(t *testing.T) {
	name, pass := "sdnh-present", "sdnh present passphrase"
	base := newHTTPStore(t)
	sdnhEnv(t, base)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, sdsePkg), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, sdsePkg, "base.apk"), prBytes(1<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "manifest.tsv"), []byte(sdsePkg+"\t7\t1\tondemand\tbase.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	deferPath := filepath.Join(t.TempDir(), "defer")
	if err := os.WriteFile(deferPath, []byte(sdsePkg+"/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)
	pushProfile(base, name+"#apps", pass, src)
	pushFenceSeq, pushFenceSampled = 0, false
	if appsHeadAbsent(base, name, pass) {
		t.Fatal("appsHeadAbsent = true for a sealed #apps head")
	}
	apps, known := sdnhRead(t, name, pass)
	if !known || apps[sdsePkg] <= 0 {
		t.Fatalf("a sealed head: known=%v apps=%v, want %s measured", known, apps, sdsePkg)
	}
}
