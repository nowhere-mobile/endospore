package main

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261026-09: SEAL-DELTA and SEAL-DELTA-WALK run in the login daemon, whose environment never carries
// NOWHERE_SE_SECRET, and passed scopeManifest a nil secret -- so a tied profile's re-keyed #apps / #media heads
// never opened: "Apps in your store: unknown right now.", an empty walk index, an update gated on its full size.
// The tests point sealDeltaBase at an in-process newHTTPStore.

const (
	sdsePkg   = "com.sdse.app"
	sdseVault = "vaultbig.bin" // a deferred file of the bare vault
)

var sdseSecret = bytes.Repeat([]byte{0x6c}, 32)

// sdseFixture is a tied profile whose bare vault holds a deferred file, whose #apps holds one deferred package and
// whose #media holds a deferred camera photo, #apps and #media re-keyed behind the `se` slot, with the daemon's empty environment. dest carries the session marker
// with the secret when withSecret is set.
func sdseFixture(t *testing.T, name string, withSecret bool) (dest, pass string) {
	t.Helper()
	base := newHTTPStore(t)
	oldBase := sealDeltaBase
	sealDeltaBase = base
	t.Cleanup(func() { sealDeltaBase = oldBase })
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	pass = "sdse " + name + " passphrase"
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
	// The forced-defer list is scope-agnostic, so one list defers the vault's file and the app's APK.
	deferPath := filepath.Join(t.TempDir(), "defer")
	if err := os.WriteFile(deferPath, []byte(sdseVault+"\n"+sdsePkg+"/base.apk\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_DEFER_LIST", deferPath)
	vsrc := t.TempDir()
	if err := os.WriteFile(filepath.Join(vsrc, sdseVault), prBytes(1<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, vsrc) // the bare vault first, as roamd pushes it
	pushProfile(base, name+"#apps", pass, src)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
	sdseSealMedia(t, base, name, pass)

	if err := sessionTie(base, name, pass, sdseSecret); err != nil {
		t.Fatal(err)
	}
	for _, suf := range []string{"#apps", "#media"} {
		switched := false
		for i := 0; i < 200 && !switched; i++ {
			st, err := largeScopeRekeyStep(base, name, pass, sdseSecret, suf)
			if err != nil {
				t.Fatalf("rekey %s step %d: %v", suf, i, err)
			}
			switched = st.Switched
		}
		if !switched {
			t.Fatalf("%s did not switch", suf)
		}
	}
	t.Setenv("NOWHERE_SE_SECRET", "") // the daemon's environment

	hexSE := ""
	if withSecret {
		hexSE = hex.EncodeToString(sdseSecret)
	}
	dest = t.TempDir()
	if err := markRoamSession(dest, name, pass, "12", hexSE); err != nil {
		t.Fatal(err)
	}
	sdseResetCaches(t)
	old := lastSealStartedAt.Load()
	oldLanded := lastLandedSealStartedAt.Load()
	t.Cleanup(func() {
		lastSealStartedAt.Store(old)
		lastLandedSealStartedAt.Store(oldLanded)
		sdseResetCaches(nil)
	})
	return dest, pass
}

// sdseResetCaches zeroes the two daemon caches; with a non-nil t it also zeroes them again at cleanup.
// sdseSealMedia seals #media holding one deferred camera photo into base.
func sdseSealMedia(t *testing.T, base, name, pass string) {
	t.Helper()
	d := t.TempDir()
	cam := filepath.Join(d, "DCIM", "Camera")
	if err := os.MkdirAll(cam, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cam, "big.jpg"), prBytes(3<<20), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_ONDEMAND_MEDIA", "1")
	pushProfile(base, name+"#media", pass, d)
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture
}

func sdseResetCaches(t *testing.T) {
	reset := func() {
		sealDeltaCache.mu.Lock()
		sealDeltaCache.name, sealDeltaCache.apps, sealDeltaCache.known = "", nil, false
		sealDeltaCache.at, sealDeltaCache.inFlight = time.Time{}, false
		sealDeltaCache.mu.Unlock()
		sealDeltaIdxCache.mu.Lock()
		sealDeltaIdxCache.name, sealDeltaIdxCache.at, sealDeltaIdxCache.ok = "", time.Time{}, false
		sealDeltaIdxCache.mu.Unlock()
	}
	reset()
	if t != nil {
		t.Cleanup(reset)
	}
}

// sdseSettled waits (3 s at most) for the cache's refresh to land.
func sdseSettled(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		sealDeltaCache.mu.Lock()
		done := !sealDeltaCache.inFlight && !sealDeltaCache.at.IsZero()
		sealDeltaCache.mu.Unlock()
		if done {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the stored-apps refresh did not land within 3 s")
}

func TestStoredAppsOpenATiedAppsHeadWithTheSessionSecret(t *testing.T) {
	name := "sdse-apps"
	_, pass := sdseFixture(t, name, true)
	base := sealDeltaBase

	if _, ok := scopeManifest(base, name+"#apps", pass, nil); ok {
		t.Fatal("control: a tied #apps head opened without the secret, so this test cannot tell the forms apart")
	}
	if _, ok := scopeManifest(base, name+"#apps", pass, sdseSecret); !ok {
		t.Fatal("control: the tied #apps head does not open with the secret")
	}

	storedAppsCached(name, pass, nil)
	sdseSettled(t)
	if apps, known := storedAppsCached(name, pass, nil); known || apps != nil {
		t.Fatalf("with no secret: known=%v apps=%v, want unknown", known, apps)
	}

	sdseResetCaches(nil)
	storedAppsCached(name, pass, sdseSecret)
	sdseSettled(t)
	apps, known := storedAppsCached(name, pass, sdseSecret)
	if !known || apps[sdsePkg] <= 0 {
		t.Fatalf("with the session's secret: known=%v apps=%v, want %s measured", known, apps, sdsePkg)
	}
}

func TestSealDeltaSEReplyMeasuresATiedProfile(t *testing.T) {
	name := "sdse-reply"
	dest, _ := sdseFixture(t, name, true)

	var r sealDeltaReply
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		out := ropReply(t, func(c net.Conn) { handleSealDelta(c, dest) })
		i := strings.Index(out, "\n")
		if i < 0 || !strings.HasPrefix(out, "OK ") {
			t.Fatalf("reply = %q, want OK <n> then JSON", out)
		}
		r = sealDeltaReply{}
		if err := json.Unmarshal([]byte(out[i+1:]), &r); err != nil {
			t.Fatal(err)
		}
		if r.StoredKnown {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !r.StoredKnown || r.StoredApps[sdsePkg] <= 0 {
		t.Fatalf("reply: storedMeasured=%v storedApps=%v, want %s measured", r.StoredKnown, r.StoredApps, sdsePkg)
	}
}

func TestSealDeltaSEWalkIndexesATiedProfile(t *testing.T) {
	walk := func(name string, withSecret bool) map[string]bool {
		dest, _ := sdseFixture(t, name, withSecret)
		lastSealStartedAt.Store(time.Now().Unix() - 60)
		lastLandedSealStartedAt.Store(time.Now().Unix() - 60)
		stop := ropWorker(t, dest)
		defer stop()
		ropReply(t, func(c net.Conn) { handleSealDeltaWalk(c, dest) })
		b, err := os.ReadFile(sealDeltaIdxPath(dest))
		if err != nil {
			t.Fatalf("no index written: %v", err)
		}
		return parseSdseIdx(string(b))
	}
	if got := walk("sdse-walk-ctl", false); len(got) != 0 {
		t.Fatalf("control: with no secret the index holds %v, want nothing", got)
	}
	got := walk("sdse-walk", true)
	vault, media := false, false
	for k := range got {
		vault = vault || k == "vault\t"+sdseVault
		media = media || strings.HasPrefix(k, "media\t") && strings.HasSuffix(k, "DCIM/Camera/big.jpg")
	}
	if !vault || !media {
		t.Fatalf("the index lacks a tied head's deferred file (vault=%v media=%v): %v", vault, media, got)
	}
}

// parseSdseIdx returns the index file's "scope\trel" keys.
func parseSdseIdx(s string) map[string]bool {
	out := map[string]bool{}
	for _, l := range strings.Split(strings.TrimSpace(s), "\n") {
		f := strings.Split(l, "\t")
		if len(f) >= 2 {
			out[f[0]+"\t"+f[1]] = true
		}
	}
	return out
}

// Source pin: no scopeManifest call in seal_delta.go passes a literal nil, and both handlers read the secret.
func TestSealDeltaSEHandlersPassTheSessionSecret(t *testing.T) {
	b, err := os.ReadFile("seal_delta.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if nilCall := regexp.MustCompile(`scopeManifest\([^)\n]*,\s*nil\s*(/\*.*?\*/)?\s*\)`); nilCall.MatchString(src) {
		t.Errorf("a scopeManifest call in seal_delta.go passes a literal nil secret: %q", nilCall.FindString(src))
	}
	body := func(fn string) string {
		i := strings.Index(src, "func "+fn+"(")
		if i < 0 {
			t.Fatalf("%s not found", fn)
		}
		rest := src[i+1:]
		if j := strings.Index(rest, "\nfunc "); j >= 0 {
			rest = rest[:j]
		}
		return rest
	}
	for _, fn := range []string{"handleSealDelta", "handleSealDeltaWalk"} {
		if !strings.Contains(body(fn), "se := seFromSession(dest)") {
			t.Errorf("%s no longer reads the session's secure-element secret", fn)
		}
	}
	if !strings.Contains(body("handleSealDelta"), "storedAppsCached(name, pass, se)") {
		t.Error("handleSealDelta does not pass the session's secret to storedAppsCached")
	}
	// NWP-20261202-10: the refresh is lifted into refreshSealDeltaIdx; the handler hands it the secret.
	if !strings.Contains(body("handleSealDeltaWalk"), `refreshSealDeltaIdx(dest, name, pass, se,`) {
		t.Error("handleSealDeltaWalk does not pass the session's secret to its index refresh")
	}
	if !strings.Contains(body("refreshSealDeltaIdx"), `scopeManifest(sealDeltaBase, name+suffix, pass, se)`) {
		t.Error("handleSealDeltaWalk's refresh does not pass the session's secret to scopeManifest")
	}
}
