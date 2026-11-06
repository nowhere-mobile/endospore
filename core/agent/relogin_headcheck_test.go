package main

import (
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20261103-02 (Q068): RELOGIN looks for a stored head under the session's name and passphrase BEFORE it discards
// anything. A stored head takes today's path; a definite absence keeps the session as a throwaway (NOSTORED); a failed
// read keeps everything (ERR-STORE).

// rhcEnv points the head check at base and gives the test fresh caches and an empty reap state.
func rhcEnv(t *testing.T, base string) {
	t.Helper()
	old := reloginStoreBase
	reloginStoreBase = base
	resetReap := func() {
		pendingReapMu.Lock()
		pendingReapUID, pendingSwitchUID = "", ""
		pendingReapMu.Unlock()
	}
	resetReap()
	t.Cleanup(func() { reloginStoreBase = old; resetReap() })
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache = nil
	contentCacheMu.Unlock()
	t.Setenv("NOWHERE_STATE", t.TempDir())
}

// rhcOffline makes dest a live offline session for (name, pass) on user 21.
func rhcOffline(t *testing.T, name, pass string) string {
	t.Helper()
	dest := t.TempDir()
	if err := markRoamSession(dest, name, pass, "21", ""); err != nil {
		t.Fatal(err)
	}
	markLocalSession(dest)
	markOfflineSession(dest)
	return dest
}

func rhcRelogin(t *testing.T, dest string) string {
	t.Helper()
	return strings.TrimSpace(unixRoundTrip(t, func(c net.Conn) { handleRelogin(c, dest) }))
}

func rhcExists(dest, f string) bool {
	_, err := os.Stat(filepath.Join(dest, f))
	return err == nil
}

func rhcReapQueued() bool {
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	return pendingReapUID != "" || pendingSwitchUID != ""
}

// rhcKept asserts the session was left whole: a throwaway, still rostered, nothing queued.
func rhcKept(t *testing.T, dest string) {
	t.Helper()
	if !rhcExists(dest, ".localsession") {
		t.Error(".localsession is gone: the session was not kept as a throwaway")
	}
	if n, _, u := readRoamSession(dest); n == "" || u != "21" {
		t.Errorf(".roamsession damaged: name=%q uid=%q", n, u)
	}
	for _, f := range []string{".relogin", reloginTmpFile} {
		if rhcExists(dest, f) {
			t.Errorf("%s was written", f)
		}
	}
	if rhcReapQueued() {
		t.Error("a reap/switch was queued")
	}
}

func TestReloginHeadStoredOK(t *testing.T) {
	name, pass := "rhc-stored", "rhc stored passphrase"
	base := newHTTPStore(t)
	rhcEnv(t, base)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	dest := rhcOffline(t, name, pass)
	if got := rhcRelogin(t, dest); got != "OK" {
		t.Fatalf("stored head: got %q want OK", got)
	}
	if !rhcExists(dest, ".relogin") {
		t.Error(".relogin was not queued")
	}
	if isOfflineSession(dest) {
		t.Error("offline marker must be cleared")
	}
	pendingReapMu.Lock()
	defer pendingReapMu.Unlock()
	if pendingReapUID != "21" || pendingSwitchUID != "21" {
		t.Errorf("reap not queued: reap=%q switch=%q", pendingReapUID, pendingSwitchUID)
	}
}

func TestReloginHeadNoneKept(t *testing.T) {
	name, pass := "rhc-absent", "rhc absent passphrase"
	base := newHTTPStore(t)
	rhcEnv(t, base)
	if _, h, _ := headRefWith(base, name, pass, refProbeStrict); h != "" {
		t.Fatal("control: the store holds a head")
	}
	dest := rhcOffline(t, name, pass)
	if got := rhcRelogin(t, dest); got != "NOSTORED" {
		t.Fatalf("no head: got %q want NOSTORED", got)
	}
	if isOfflineSession(dest) || rhcExists(dest, ".offlinesession") {
		t.Error(".offlinesession survived: GET-OFFLINE would keep the prompt up")
	}
	rhcKept(t, dest)
}

func TestReloginHeadTombstone(t *testing.T) {
	name, pass := "rhc-tomb", "rhc tomb passphrase"
	base := newHTTPStore(t)
	rhcEnv(t, base)
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	putRef(base, headKey(base, name, pass), "")
	pushFenceSeq, pushFenceSampled = 0, false
	if _, h, have := headRefWith(base, name, pass, refProbeStrict); h != "" || !have {
		t.Fatalf("control: want a tombstoned head, got have=%v head=%q", have, h)
	}
	dest := rhcOffline(t, name, pass)
	if got := rhcRelogin(t, dest); got != "NOSTORED" {
		t.Fatalf("tombstoned head: got %q want NOSTORED", got)
	}
	rhcKept(t, dest)
}

func TestReloginHeadReadFails(t *testing.T) {
	cases := []struct {
		label, name string
		handler     func(name, pass string) http.HandlerFunc
	}{
		{"500", "rhc-500", func(string, string) http.HandlerFunc {
			return func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusInternalServerError) }
		}},
		{"403", "rhc-403", func(string, string) http.HandlerFunc {
			return func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusForbidden) }
		}},
		{"rung", "rhc-rung", func(name, pass string) http.HandlerFunc {
			failing := profileRefV2(name, pass)
			return func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/"+failing) {
					w.WriteHeader(http.StatusInternalServerError)
					return
				}
				w.WriteHeader(http.StatusNotFound)
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			pass := "rhc " + c.label + " passphrase"
			srv := httptest.NewServer(c.handler(c.name, pass))
			t.Cleanup(srv.Close)
			rhcEnv(t, srv.URL)
			dest := rhcOffline(t, c.name, pass)
			if got := rhcRelogin(t, dest); got != "ERR-STORE" {
				t.Fatalf("failed read: got %q want ERR-STORE", got)
			}
			if !isOfflineSession(dest) {
				t.Error("the offline marker was cleared: the prompt would withdraw and a retry is impossible")
			}
			rhcKept(t, dest)
		})
	}
}

func TestReloginStoredHeadTriple(t *testing.T) {
	name, pass := "rhc-triple", "rhc triple passphrase"
	base := newHTTPStore(t)
	rhcEnv(t, base)
	if stored, err := reloginStoredHead(base, name, pass); stored || err != nil {
		t.Fatalf("empty store: stored=%v err=%v, want false, nil", stored, err)
	}
	if createVault(base, name, pass) == "" {
		t.Fatal("createVault returned no recovery code")
	}
	if stored, err := reloginStoredHead(base, name, pass); !stored || err != nil {
		t.Fatalf("vault: stored=%v err=%v, want true, nil", stored, err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusInternalServerError) }))
	t.Cleanup(srv.Close)
	if stored, err := reloginStoredHead(srv.URL, name, pass); stored || err == nil {
		t.Fatalf("500 store: stored=%v err=%v, want false and an error", stored, err)
	}
}
