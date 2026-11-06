package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20261124-07 (#5 of the 2026-11-02 entry, docs/product-decisions.md). Backlog row "An unreadable bare vault head
// reads as "not locked" ...": a bare head whose ref or blob cannot be read is a store failure. The sign-in answers
// BLANK NET before anything records it, the CLI restore of a scope exits exitStoreUnreachable, restore-app and mediad
// refuse, and scopeHeadMayBeCreated is false. A definite 404 stays absence, so an unknown name is still a throwaway.

// huFaults is the set of store keys ("ref/<r>", "blob/<h>") whose GETs fail, and how: "403" answers a 403, "cut"
// closes the connection with no response. A key "ref/*" fails every ref read.
type huFaults struct {
	mu sync.Mutex
	m  map[string]string
}

func (f *huFaults) set(k, mode string) {
	f.mu.Lock()
	f.m[k] = mode
	f.mu.Unlock()
}

func (f *huFaults) clear() {
	f.mu.Lock()
	f.m = map[string]string{}
	f.mu.Unlock()
}

func (f *huFaults) mode(k string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if m, ok := f.m[k]; ok {
		return m
	}
	if strings.HasPrefix(k, "ref/") {
		return f.m["ref/*"]
	}
	return ""
}

// huServe answers a faulted GET; false means the request is not faulted.
func huServe(w http.ResponseWriter, mode string) bool {
	switch mode {
	case "403":
		w.WriteHeader(http.StatusForbidden)
	case "cut":
		if c, _, err := w.(http.Hijacker).Hijack(); err == nil {
			c.Close()
		}
	default:
		return false
	}
	return true
}

// huCap is a cap-mode store (mockCapStore) behind a fault proxy, a funded wallet at the session's wallet path, and a
// session state dir. The proxy keeps the incoming Host, so the mock's /cap answers presigned URLs on the proxy and
// every object GET passes through it.
type huCap struct {
	dest   string
	faults *huFaults
}

func huCapEnv(t *testing.T) *huCap {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	target, _ := url.Parse(srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	f := &huFaults{m: map[string]string{}}
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && huServe(w, f.mode(r.URL.Query().Get("k"))) {
			return
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	t.Setenv("GATEWAY_URL", px.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	for _, k := range []string{"NOWHERE_MULTIDEVICE", "NOWHERE_UNIT_SRC", "NOWHERE_SE_SECRET", "NOWHERE_FIDO2_HMAC"} {
		t.Setenv(k, "")
	}
	capReadCache = map[string]capEntry{}
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old; capReadCache = map[string]capEntry{} })
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	t.Setenv("NOWHERE_WALLET", walletPathFor(dest))
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(walletPathFor(dest), &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	h := &huCap{dest: dest, faults: f}
	h.fresh()
	return h
}

// fresh drops every local copy of a stored blob, so the next read of a head blob reaches the store.
func (h *huCap) fresh() {
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	contentCacheMu.Lock()
	contentCache, contentCacheLoadedTag = nil, ""
	contentCacheMu.Unlock()
	os.RemoveAll(filepath.Join(h.dest, "headblobs"))
	capReadCache = map[string]capEntry{}
}

// vault creates a vault profile and returns its bare head.
func (h *huCap) vault(t *testing.T, name, pass string) string {
	t.Helper()
	if createVault("s3", name, pass) == "" {
		t.Fatal("createVault returned no recovery code -- fixture bug")
	}
	head := getRef("s3", headKey("s3", name, pass))
	if head == "" {
		t.Fatal("the created profile has no head -- fixture bug")
	}
	h.fresh()
	return head
}

func TestHeadUnreadable_TriState(t *testing.T) {
	h := huCapEnv(t)
	const name, pass = "hu-tri", "hu tri horse battery staple"
	head := h.vault(t, name, pass)
	open := func(v *vault) []byte { return openVaultDK(v, name, pass) }
	v2 := "ref/" + profileRefV2(name, pass)

	if l, u := vaultHeadLocked("s3", head, open); l || u {
		t.Fatalf("control: a readable untied head: locked=%v unreadable=%v, want neither", l, u)
	}
	for _, mode := range []string{"cut", "403"} {
		h.fresh()
		h.faults.set("blob/"+head, mode)
		if l, u := vaultHeadLocked("s3", head, open); l || !u {
			t.Errorf("head blob read %s: vaultHeadLocked locked=%v unreadable=%v, want unreadable (never \"not locked\")", mode, l, u)
		}
		if l, u := scopeOwnerLocked("s3", name+"#de", pass); l || !u {
			t.Errorf("head blob read %s: scopeOwnerLocked locked=%v unreadable=%v, want unreadable", mode, l, u)
		}
		if _, _, ok := roamInHead("s3", name, pass, ""); ok {
			t.Errorf("head blob read %s: roamInHead reads the head as readable", mode)
		}
		h.faults.clear()
	}
	for _, mode := range []string{"403", "cut"} {
		h.fresh()
		h.faults.set(v2, mode)
		if l, u := scopeOwnerLocked("s3", name+"#de", pass); l || !u {
			t.Errorf("bare ref read %s: scopeOwnerLocked locked=%v unreadable=%v, want unreadable (a 403 is not absence here)", mode, l, u)
		}
		if got, _, ok := roamInHead("s3", name, pass, ""); ok {
			t.Errorf("bare ref read %s: roamInHead answers readable with head %q", mode, got)
		}
		h.faults.clear()
	}

	h.fresh()
	if hd, l, u := scopeOwnerHeadWith("s3", "hu-tri-absent#de", pass, nil); hd != "" || l || u {
		t.Errorf("absent profile: head=%q locked=%v unreadable=%v, want no head, neither", hd, l, u)
	}
	if hd, v, ok := roamInHead("s3", "hu-tri-absent", pass, ""); hd != "" || v != nil || !ok {
		t.Errorf("absent profile: roamInHead head=%q vault=%v readable=%v, want a readable absence", hd, v != nil, ok)
	}
	if hd, v, ok := roamInHead("s3", name, pass, ""); hd != head || v == nil || !ok {
		t.Errorf("control: roamInHead head=%q (want %q) vault=%v readable=%v", hd, head, v != nil, ok)
	}

	const legacy = "hu-tri-legacy"
	bn := capBegin()
	lhead := seedLegacyProfile(t, "s3", legacy, pass)
	capFlush(bn)
	h.fresh()
	if l, u := scopeOwnerLocked("s3", legacy+"#de", pass); l || u {
		t.Errorf("legacy head: locked=%v unreadable=%v, want neither", l, u)
	}
	if hd, v, ok := roamInHead("s3", legacy, pass, ""); hd != lhead || v != nil || !ok {
		t.Errorf("legacy head: roamInHead head=%q vault=%v readable=%v, want the head, no vault, readable", hd, v != nil, ok)
	}

	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	h.fresh()
	if l, u := scopeOwnerLocked("s3", name+"#de", pass); !l || u {
		t.Errorf("tied elsewhere, no chip: locked=%v unreadable=%v, want locked", l, u)
	}
	t.Setenv("NOWHERE_SE_SECRET", hex.EncodeToString(seA))
	h.fresh()
	if l, u := scopeOwnerLocked("s3", name+"#de", pass); l || u {
		t.Errorf("tied here, with the chip: locked=%v unreadable=%v, want neither", l, u)
	}
}

// huRoamIn signs name/pass in through the real handleRoamIn, with a worker that answers the restore `in` with OK 21.
func huRoamIn(t *testing.T, h *huCap, name, pass string) (reply, log string) {
	t.Helper()
	lateWorkDrain(t)
	out := captureStderr(t, func() {
		reply = ropReply(t, func(c net.Conn) { handleRoamIn(c, h.dest, name, pass, "21", "", "") })
	})
	return reply, out
}

func huRoamInSetup(t *testing.T) *huCap {
	t.Helper()
	h := huCapEnv(t)
	loginWindowState(t)
	rwWorker(t, h.dest, map[string]string{"in": "OK 21"})
	return h
}

func huExists(dest, f string) bool {
	_, err := os.Stat(filepath.Join(dest, f))
	return err == nil
}

// huAssertBlankNet: the reply is exactly BLANK NET and nothing of the sign-in was recorded or touched.
func huAssertBlankNet(t *testing.T, h *huCap, name, reply, log string, wallet []byte) {
	t.Helper()
	if reply != "BLANK NET" {
		t.Errorf("the reply is %q, want exactly \"BLANK NET\" (the gate's \"Couldn't reach your storage\" with a retry)", reply)
	}
	for _, f := range []string{".roamsession", ".localsession"} {
		if huExists(h.dest, f) {
			t.Errorf("%s was written: an unreadable head recorded a session", f)
		}
	}
	if !huExists(h.dest, ".coldlock") {
		t.Error("the parked session's .coldlock was removed")
	}
	if got, err := os.ReadFile(walletPathFor(h.dest)); err != nil || !bytes.Equal(got, wallet) {
		t.Errorf("the wallet was touched (err %v)", err)
	}
	if want := "roam-in BLANK NET \"" + name + "\" (the stored head could not be read)"; !strings.Contains(log, want) {
		t.Errorf("the log lacks %q:\n%s", want, log)
	}
	if !strings.Contains(log, "KDF cache forgotten (blank sign-in)") {
		t.Errorf("the session keys were not forgotten:\n%s", log)
	}
	if strings.Contains(log, "LOCAL/throwaway") {
		t.Errorf("an unreadable head became a throwaway:\n%s", log)
	}
}

func huParkAndWallet(t *testing.T, h *huCap) []byte {
	t.Helper()
	if err := os.WriteFile(filepath.Join(h.dest, ".coldlock"), []byte("15\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	w, err := os.ReadFile(walletPathFor(h.dest))
	if err != nil {
		t.Fatal(err)
	}
	return w
}

func TestHeadUnreadable_RoamInRefRead(t *testing.T) {
	h := huRoamInSetup(t)
	const name, pass = "hu-roamin-ref", "hu roamin ref horse battery staple"
	h.vault(t, name, pass)
	wallet := huParkAndWallet(t, h)
	h.faults.set("ref/"+profileRefV2(name, pass), "403") // capGet would read this as absent: the row's case
	reply, log := huRoamIn(t, h, name, pass)
	huAssertBlankNet(t, h, name, reply, log, wallet)
}

func TestHeadUnreadable_RoamInBlobRead(t *testing.T) {
	h := huRoamInSetup(t)
	const name, pass = "hu-roamin-blob", "hu roamin blob horse battery staple"
	head := h.vault(t, name, pass)
	wallet := huParkAndWallet(t, h)
	h.faults.set("blob/"+head, "cut")
	reply, log := huRoamIn(t, h, name, pass)
	huAssertBlankNet(t, h, name, reply, log, wallet)
}

// Blind login: on a store whose every ref read fails, the right passphrase and a wrong one get the same reply.
func TestHeadUnreadable_RoamInIsCredentialIndependent(t *testing.T) {
	h := huRoamInSetup(t)
	const name, pass = "hu-roamin-blind", "hu roamin blind horse battery staple"
	h.vault(t, name, pass)
	h.faults.set("ref/*", "403")
	for _, p := range []string{pass, "a passphrase this profile does not have"} {
		wallet := huParkAndWallet(t, h)
		reply, log := huRoamIn(t, h, name, p)
		huAssertBlankNet(t, h, name, reply, log, wallet)
	}
}

// Controls: a definite absence is still a throwaway, and so is a readable head tied to another phone (NWP-20261006-10).
func TestHeadUnreadable_RoamInControls(t *testing.T) {
	h := huRoamInSetup(t)
	reply, log := huRoamIn(t, h, "hu-roamin-nobody", "hu nobody horse battery staple")
	if reply != "OK 21" || !huExists(h.dest, ".roamsession") || !huExists(h.dest, ".localsession") {
		t.Errorf("an unknown name: reply %q, .roamsession %v, .localsession %v, want a throwaway sign-in\n%s",
			reply, huExists(h.dest, ".roamsession"), huExists(h.dest, ".localsession"), log)
	}
	const name, pass = "hu-roamin-tied", "hu roamin tied horse battery staple"
	h.vault(t, name, pass)
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	h.fresh()
	os.Remove(filepath.Join(h.dest, ".localsession"))
	reply, log = huRoamIn(t, h, name, pass)
	if reply != "OK 21" || !huExists(h.dest, ".localsession") || !strings.Contains(log, "does not open on this phone") {
		t.Errorf("a readable head tied elsewhere: reply %q, .localsession %v, want a throwaway\n%s",
			reply, huExists(h.dest, ".localsession"), log)
	}
}

// TestHeadUnreadableVerbHelper is not a test: it is the agent, re-executed from the test binary, running one verb
// through main() so the exit code is the one roamd reads. NOWHERE_HU_VERB_HELPER holds the arguments, verb first.
func TestHeadUnreadableVerbHelper(t *testing.T) {
	a := os.Getenv("NOWHERE_HU_VERB_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

func huVerb(t *testing.T, args ...string) (int, string) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestHeadUnreadableVerbHelper$", "-test.count=1")
	env := []string{"NOWHERE_HU_VERB_HELPER=" + strings.Join(args, "\n")}
	for _, kv := range os.Environ() {
		k := kv[:strings.IndexByte(kv+"=", '=')]
		switch k {
		case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS",
			"NOWHERE_HU_VERB_HELPER":
			continue // a plain-HTTP store, no cache, no session state
		}
		env = append(env, kv)
	}
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err == nil {
		return 0, string(out)
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		t.Fatalf("running the agent: %v", err)
	}
	return ee.ExitCode(), string(out)
}

// huPlainProfile is a plain-HTTP store holding a vault profile; it returns the store and the vault's head.
func huPlainProfile(t *testing.T, name, pass string) (string, string) {
	t.Helper()
	for _, k := range []string{"GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_STATE", "NOWHERE_MULTIDEVICE", "NOWHERE_UNIT_SRC",
		"NOWHERE_SE_SECRET", "NOWHERE_FIDO2_HMAC"} {
		t.Setenv(k, "")
	}
	oc, rb := chunkCacheDir, s3RetryBase
	chunkCacheDir, s3RetryBase = "", time.Millisecond
	t.Cleanup(func() { chunkCacheDir, s3RetryBase = oc, rb })
	blobCacheMu.Lock()
	blobCache = nil
	blobCacheMu.Unlock()
	base := newHTTPStore(t)
	createVault(base, name, pass)
	head := getRef(base, headKey(base, name, pass))
	if head == "" {
		t.Fatal("the created profile has no head -- fixture bug")
	}
	return base, head
}

func huEmpty(t *testing.T, dir string) bool {
	t.Helper()
	es, err := os.ReadDir(dir)
	return err == nil && len(es) == 0
}

func TestHeadUnreadable_RestoreVerbScope(t *testing.T) {
	const name, pass = "hu-restore", "hu restore horse battery staple"
	base, head := huPlainProfile(t, name, pass)
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "hu-de.txt"), []byte("the #de scope's own data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#de", pass, src)

	dest := t.TempDir()
	code, out := huVerb(t, "restore", faultyStore(t, base, map[string]bool{head: true}, nil), name+"#de", pass, dest)
	if code != exitStoreUnreachable {
		t.Errorf("restore of a scope whose bare head blob was cut exited %d, want exitStoreUnreachable (%d)\n%s", code, exitStoreUnreachable, out)
	}
	if !huEmpty(t, dest) {
		t.Error("the refused scope restore wrote into its dest")
	}
	if !strings.Contains(out, "its bare head could not be read -> refusing scope restore (store unreachable)") {
		t.Errorf("the refusal line is missing:\n%s", out)
	}
	if strings.Contains(out, pass) {
		t.Error("the output carries the passphrase")
	}
	dest = t.TempDir()
	if code, out := huVerb(t, "restore", base, name+"#de", pass, dest); code != 0 {
		t.Errorf("control: restore from a healthy store exited %d\n%s", code, out)
	} else if _, err := os.Stat(filepath.Join(dest, "hu-de.txt")); err != nil {
		t.Errorf("control: the healthy restore did not restore the scope: %v\n%s", err, out)
	}
}

func TestHeadUnreadable_RestoreAppRefuses(t *testing.T) {
	const name, pass = "hu-restoreapp", "hu restore app horse battery staple"
	base, head := huPlainProfile(t, name, pass)
	dest := t.TempDir()
	code, out := huVerb(t, "restore-app", faultyStore(t, base, map[string]bool{head: true}, nil), name+"#apps", pass,
		"org.example.hu", dest)
	if code != exitStoreUnreachable {
		t.Errorf("restore-app with the bare head blob cut exited %d, want exitStoreUnreachable (%d)\n%s", code, exitStoreUnreachable, out)
	}
	if !strings.Contains(out, "the store could not be read -> refusing") {
		t.Errorf("the refusal line is missing:\n%s", out)
	}
	if !huEmpty(t, dest) {
		t.Error("the refused restore-app wrote into its dest")
	}
	if _, out := huVerb(t, "restore-app", base, name+"#apps", pass, "org.example.hu", t.TempDir()); strings.Contains(out, "could not be read") {
		t.Errorf("control: a healthy store refused as unreadable:\n%s", out)
	}
}

func TestHeadUnreadable_MediadServesNothing(t *testing.T) {
	h := huCapEnv(t)
	const name, pass = "hu-mediad", "hu mediad horse battery staple"
	head := h.vault(t, name, pass)
	h.faults.set("blob/"+head, "cut")
	userDir, cacheDir := t.TempDir(), t.TempDir()
	var err error
	log := captureStderr(t, func() {
		err = recovered(func() { runMediad([]string{"s3", name, pass, userDir, cacheDir}) })
	})
	if err != nil {
		t.Errorf("mediad died on an unreadable head instead of returning: %v", err)
	}
	if !strings.Contains(log, "mediad: the store could not be read for this profile's head -> serving nothing") {
		t.Errorf("mediad's refusal line is missing:\n%s", log)
	}
	if strings.Contains(log, "nothing mounted") || strings.Contains(log, "overlay(s) total") {
		t.Errorf("mediad went on to serve:\n%s", log)
	}
	if !huEmpty(t, userDir) || !huEmpty(t, cacheDir) {
		t.Error("mediad wrote into the session's dirs")
	}
}

func TestHeadUnreadable_ScopeHeadMayBeCreated(t *testing.T) {
	h := huCapEnv(t) // NOWHERE_STATE is set and holds no receipt: sessionHoldsBareReceipt is false
	const name, pass = "hu-mayc", "hu may create horse battery staple"
	head := h.vault(t, name, pass)
	if !scopeHeadMayBeCreated("s3", name+"#de", pass) {
		t.Fatal("control: a readable untied head does not let its scope head be created")
	}
	for k, mode := range map[string]string{"blob/" + head: "cut", "ref/" + profileRefV2(name, pass): "403"} {
		h.fresh()
		h.faults.set(k, mode)
		var got bool
		if err := recovered(func() { got = scopeHeadMayBeCreated("s3", name+"#de", pass) }); err != nil {
			t.Errorf("%s %s: scopeHeadMayBeCreated panicked: %v", k[:4], mode, err)
		} else if got {
			t.Errorf("%s %s: an unreadable bare head answers \"present and open\": the scope head would be created", k[:4], mode)
		}
		h.faults.clear()
	}
	if err := sessionTie("s3", name, pass, seA); err != nil {
		t.Fatal(err)
	}
	h.fresh()
	if scopeHeadMayBeCreated("s3", name+"#de", pass) {
		t.Error("control: a head tied elsewhere lets its scope head be created")
	}
}
