package main

// NWP-20261103-04: every "does this (name, pass) already have a profile?" probe that guards a NEW-vault write reads
// the head STRICTLY. The lenient reader takes a 403 on a fresh read cap for "no profile" (the hide-existence rule
// blind login needs), so a store that refuses reads while it accepts writes made CREATE, CREATE-CODE, PROMOTE and
// PROMOTE2 repoint an EXISTING profile's head and recovery ref at an empty vault. Each case below stands a real
// profile (ropRestored), answers GETs of its bare head with a status while writes pass through, drives the real
// handler over a pipe, and requires the refusal with the store byte-identical.

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// cesRefuseHead puts a proxy in front of the store that answers GETs of (name, pass)'s bare head key with status
// and passes everything else through. The returned func lists every gateway call other than /cap, /caps and /obj.
func cesRefuseHead(t *testing.T, srv *httptest.Server, name, pass string, status int) (gateway func() []string) {
	t.Helper()
	ref := profileRefV2(name, pass)
	target, _ := url.Parse(srv.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)
	var mu sync.Mutex
	var calls []string
	px := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/obj" && strings.Contains(r.URL.Query().Get("k"), ref) {
			w.WriteHeader(status)
			return
		}
		if r.URL.Path != "/cap" && r.URL.Path != "/caps" && r.URL.Path != "/obj" {
			mu.Lock()
			calls = append(calls, r.Method+" "+r.URL.Path)
			mu.Unlock()
		}
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(px.Close)
	t.Setenv("GATEWAY_URL", px.URL)
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { capReadCache = map[string]capEntry{} })
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), calls...)
	}
}

// cesReply is ropReply for a handler that may die: the agent's fail() panics, and on a goroutine of its own that
// would take the whole test process down with no failing assertion. A panic is a failed test here.
func cesReply(t *testing.T, h func(net.Conn)) string {
	t.Helper()
	var died error
	got := ropReply(t, func(c net.Conn) { died = recovered(func() { h(c) }) })
	if died != nil {
		t.Fatalf("the handler died instead of answering: %v", died)
	}
	return got
}

func TestCreateExistsStrictRefusesAFailedHeadRead(t *testing.T) {
	for _, status := range []int{http.StatusForbidden, http.StatusInternalServerError} {
		s := fmt.Sprint(status)
		t.Run("CREATE-"+s, func(t *testing.T) {
			srv, objs, mu := ropStore(t)
			name := "odtest61-" + s
			ropRestored(t, name, ropPass)
			before := ropSnapshot(objs, mu)
			cesRefuseHead(t, srv, name, ropPass, status)
			dest := t.TempDir()
			got := cesReply(t, func(c net.Conn) { handleCreate(c, dest, name, ropPass) })
			if got != "BLANK" {
				t.Fatalf("CREATE with the head read answering %d replied %q, want BLANK", status, got)
			}
			ropUnchanged(t, "CREATE", before, objs, mu)
			if _, err := os.Stat(dest + "/.roamsession"); err == nil {
				t.Error("a refused CREATE recorded a session")
			}
		})
		t.Run("CREATE-CODE-"+s, func(t *testing.T) {
			srv, objs, mu := ropStore(t)
			name := "odtest62-" + s
			ropRestored(t, name, ropPass)
			before := ropSnapshot(objs, mu)
			gateway := cesRefuseHead(t, srv, name, ropPass, status)
			got := cesReply(t, func(c net.Conn) { handleCreateCode(c, t.TempDir(), name, ropPass, "ABCD1234ABCD1234ABCD1234") })
			if got != "BLANK" {
				t.Fatalf("CREATE-CODE with the head read answering %d replied %q, want BLANK", status, got)
			}
			if calls := gateway(); len(calls) != 0 {
				t.Errorf("CREATE-CODE called the gateway before refusing (%v) -- the code must not be redeemed", calls)
			}
			ropUnchanged(t, "CREATE-CODE", before, objs, mu)
		})
		t.Run("PROMOTE2-"+s, func(t *testing.T) {
			srv, objs, mu := ropStore(t)
			ropReapReset(t)
			name := "odtest63-" + s
			dest := ropThrowaway(t, name, ropPass)
			ropRestored(t, name, ropNew)
			before := ropSnapshot(objs, mu)
			cesRefuseHead(t, srv, name, ropNew, status)
			stop := ropWorker(t, dest)
			got := cesReply(t, func(c net.Conn) { handlePromote2(c, dest, ropNew) })
			time.Sleep(700 * time.Millisecond)
			ops := stop()
			if got != "ERR-VAULT" {
				t.Fatalf("PROMOTE2 with the head read answering %d replied %q, want ERR-VAULT", status, got)
			}
			if len(ops) != 0 {
				t.Errorf("a refused PROMOTE2 handed the worker %v", ops)
			}
			if _, p, _ := readRoamSession(dest); p != ropPass {
				t.Error("a refused PROMOTE2 rewrote the session marker's passphrase")
			}
			if !isLocalSession(dest) {
				t.Error("a refused PROMOTE2 flipped the session to stored")
			}
			ropUnchanged(t, "PROMOTE2", before, objs, mu)
		})
		t.Run("PROMOTE-"+s, func(t *testing.T) {
			srv, objs, mu := ropStore(t)
			ropReapReset(t)
			name := "odtest64-" + s
			dest := ropThrowaway(t, name, ropPass)
			ropRestored(t, name, ropPass)
			before := ropSnapshot(objs, mu)
			cesRefuseHead(t, srv, name, ropPass, status)
			stop := ropWorker(t, dest)
			got := cesReply(t, func(c net.Conn) { handlePromote(c, dest) })
			time.Sleep(700 * time.Millisecond)
			ops := stop()
			if got != "ERR-VAULT" {
				t.Fatalf("PROMOTE with the head read answering %d replied %q, want ERR-VAULT", status, got)
			}
			if len(ops) != 0 {
				t.Errorf("a refused PROMOTE handed the worker %v", ops)
			}
			if !isLocalSession(dest) {
				t.Error("a refused PROMOTE flipped the session to stored")
			}
			ropUnchanged(t, "PROMOTE", before, objs, mu)
		})
	}
}

// A create whose claim is still staged says so on the failed-read refusal, and the claim stays for the retry.
func TestCreateExistsStrictFailedReadKeepsTheStagedClaim(t *testing.T) {
	srv, objs, mu := ropStore(t)
	const name = "odtest65"
	ropRestored(t, name, ropPass)
	before := ropSnapshot(objs, mu)
	cesRefuseHead(t, srv, name, ropPass, http.StatusForbidden)
	staged := createStagingPath(name, ropPass)
	if err := os.WriteFile(staged, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := cesReply(t, func(c net.Conn) { handleCreate(c, t.TempDir(), name, ropPass) })
	if got != "BLANK STAGED" {
		t.Fatalf("CREATE with a staged claim and a refused head read replied %q, want BLANK STAGED", got)
	}
	if _, err := os.Stat(staged); err != nil {
		t.Errorf("the staged claim did not survive the refusal: %v", err)
	}
	ropUnchanged(t, "CREATE", before, objs, mu)
}

// Controls: the strict probe still finds a profile, still permits a fresh name, and a tombstone is still absent.
func TestCreateExistsStrictControls(t *testing.T) {
	_, objs, mu := ropStore(t)
	const name = "odtest66"
	ropRestored(t, name, ropPass)
	before := ropSnapshot(objs, mu)
	if got := cesReply(t, func(c net.Conn) { handleCreate(c, t.TempDir(), name, ropPass) }); got != "EXISTS" {
		t.Fatalf("CREATE of a stood profile replied %q, want EXISTS", got)
	}
	ropUnchanged(t, "CREATE", before, objs, mu)
	if got := cesReply(t, func(c net.Conn) { handleCreate(c, t.TempDir(), "odtest67", ropPass) }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE of a fresh name replied %q, want OK", got)
	}
}

func TestCreateExistsStrictATombstoneIsAbsent(t *testing.T) {
	_, objs, mu := ropStore(t)
	const name = "odtest68"
	ropRestored(t, name, ropPass)
	ref := profileRefV2(name, ropPass)
	n := 0
	mu.Lock()
	for k := range objs {
		if strings.Contains(k, ref) {
			objs[k] = []byte{}
			n++
		}
	}
	mu.Unlock()
	if n == 0 {
		t.Fatal("fixture: no stored object carries the profile's head ref")
	}
	capReadCache = map[string]capEntry{}
	pushFenceSeq, pushFenceSampled = 0, false // see rotateFixture: one test binary shares the fence sample
	if ok, err := headExistsStrict("s3", name, ropPass); ok || err != nil {
		t.Fatalf("headExistsStrict over a tombstoned head = (%v, %v), want (false, nil)", ok, err)
	}
	if got := cesReply(t, func(c net.Conn) { handleCreate(c, t.TempDir(), name, ropPass) }); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE over a tombstoned name replied %q, want OK", got)
	}
}
