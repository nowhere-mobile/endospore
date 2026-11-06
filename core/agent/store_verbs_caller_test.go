package main

import (
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261021-18: SET-STORE, SET-STORE-MANAGED and TEST-STORE answer only the user-0 gate and root (backlog: "A roamed
// session could repoint or wipe the phone's store"). A roamed session's chooser shares the gate's appId and SELinux
// domain, so the accept-time pin alone cannot tell the two apart.

var storeConfigVerbs = []string{"SET-STORE", "SET-STORE-MANAGED", "TEST-STORE"}

// storeVerbFixture points the conf at a temp dir and the managed gateway at a dead loopback port, so no case can
// reach the production gateway, and saves the store environment.
func storeVerbFixture(t *testing.T) string {
	t.Helper()
	conf := tempConf(t, "S3_ENDPOINT=https://store.example\nS3_BUCKET=b\n")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "http://127.0.0.1:1")
	t.Setenv("GATEWAY_URL", "")
	for _, k := range []string{"S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY"} {
		t.Setenv(k, "orig-"+k)
	}
	return conf
}

func storeEnvSnapshot() string {
	var b strings.Builder
	for _, k := range []string{"S3_ENDPOINT", "S3_REGION", "S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET_KEY", "GATEWAY_URL", "NOWHERE_GATEWAY_DEFAULT"} {
		b.WriteString(k + "=" + os.Getenv(k) + "\n")
	}
	return b.String()
}

// driveSplit sends the verb line, then the request lines in a second write, runs handleLogin, and returns the reply
// and whether the second write was left unconsumed. net.Pipe is synchronous: a write blocks until read, so the handler
// returning with the write still pending (it fails when the daemon closes its end) means it never read the lines.
func driveSplit(t *testing.T, verb, rest string) (reply string, unread bool) {
	t.Helper()
	cli, srv := net.Pipe()
	wrote := make(chan int, 1)
	go func() {
		cli.Write([]byte(verb + "\n"))
		n, _ := cli.Write([]byte(rest))
		wrote <- n
	}()
	got := make(chan string, 1)
	go func() { b, _ := io.ReadAll(cli); got <- string(b) }()
	handleLogin(srv, t.TempDir()) // closes srv itself
	reply = strings.TrimSpace(<-got)
	cli.Close()
	return reply, <-wrote == 0
}

func TestStoreConfigCmdIsTheThreeVerbs(t *testing.T) {
	for _, v := range storeConfigVerbs {
		if !storeConfigCmd(v) {
			t.Errorf("%s is a store-config verb", v)
		}
	}
	for _, v := range []string{"GET-STORE", "PING-STORE", "STATUS", "LOGIN", "", "set-store", "SET-STORE "} {
		if storeConfigCmd(v) {
			t.Errorf("%q is not a store-config verb", v)
		}
	}
}

// TestStoreVerbsRefuseAnyoneButTheGateAndRoot: each verb answers DENIED to a roamed chooser, another user-0 app, an
// unpinned daemon and a failed peerUID, writes nothing, leaves the environment alone, and leaves the request unread.
func TestStoreVerbsRefuseAnyoneButTheGateAndRoot(t *testing.T) {
	conf := storeVerbFixture(t)
	before, err := os.ReadFile(conf)
	if err != nil {
		t.Fatal(err)
	}
	envBefore := storeEnvSnapshot()
	for _, c := range []struct {
		what        string
		uid, pinned int
	}{
		{"the chooser in a roamed user", 10123 + 11*100000, 10123},
		{"a roamed chooser whose full uid equals the pin", 10123 + 11*100000, 10123 + 11*100000},
		{"another app in user 0", 10200, 10123},
		{"an unpinned daemon", 10123, -1},
		{"a peer with no uid", -1, 10123},
		{"a peer with no uid on an unpinned daemon", -1, -1},
	} {
		asCaller(t, c.uid, c.pinned)
		for _, verb := range storeConfigVerbs {
			got, unread := driveSplit(t, verb, "https://evil.example\nus\nbkt\nak\nsk\n")
			if got != "DENIED" {
				t.Errorf("%s: %s answered %q, want DENIED", c.what, verb, got)
			}
			if !unread {
				t.Errorf("%s: %s read the request lines before refusing", c.what, verb)
			}
		}
	}
	if after, _ := os.ReadFile(conf); string(after) != string(before) {
		t.Errorf("a refused caller changed the store conf:\n%s", after)
	}
	if got := storeEnvSnapshot(); got != envBefore {
		t.Errorf("a refused caller changed the store environment:\nbefore %s\nafter  %s", envBefore, got)
	}
}

// TestStoreVerbsServeTheGateAndRoot: the pinned gate and root reach each handler, with no network.
func TestStoreVerbsServeTheGateAndRoot(t *testing.T) {
	for _, c := range []struct {
		what string
		uid  int
	}{{"the gate", 10123}, {"root", 0}} {
		conf := storeVerbFixture(t)
		before, _ := os.ReadFile(conf)
		envBefore := storeEnvSnapshot()
		asCaller(t, c.uid, 10123)
		if got := driveLogin(t, t.TempDir(), "SET-STORE\n\n\n\n\n\n"); got != "ERR-FIELDS" {
			t.Errorf("%s: SET-STORE with empty fields answered %q, want ERR-FIELDS", c.what, got)
		}
		if got := driveLogin(t, t.TempDir(), "TEST-STORE\n\n\n\n\n\n"); got != "ERR-FIELDS" {
			t.Errorf("%s: TEST-STORE with empty fields answered %q, want ERR-FIELDS", c.what, got)
		}
		if got := driveLogin(t, t.TempDir(), "SET-STORE-MANAGED\n"); got != "ERR-NET" {
			t.Errorf("%s: SET-STORE-MANAGED answered %q, want ERR-NET", c.what, got)
		}
		if after, _ := os.ReadFile(conf); string(after) != string(before) {
			t.Errorf("%s: an unreachable gateway changed the conf:\n%s", c.what, after)
		}
		if got := storeEnvSnapshot(); got != envBefore {
			t.Errorf("%s: the store environment changed:\nbefore %s\nafter  %s", c.what, envBefore, got)
		}
	}
}

// TestStoreVerbRefusalSkipsSessionMu: the refusal answers while sessionMu is held and with no request body.
func TestStoreVerbRefusalSkipsSessionMu(t *testing.T) {
	storeVerbFixture(t)
	asCaller(t, 10123+11*100000, 10123)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	for _, verb := range storeConfigVerbs {
		select {
		case got := <-driveLoginAsync(t, t.TempDir(), verb+"\n"):
			if got != "DENIED" {
				t.Errorf("%s answered %q while sessionMu was held, want DENIED", verb, got)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s: no reply within 3s while sessionMu was held", verb)
		}
	}
}

// TestStoreVerbRefusalSourcePin: handleLogin refuses before the first sessionMu use, after the owner-mode refusal.
func TestStoreVerbRefusalSourcePin(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	h := stripComments(funcBody(t, string(b), "handleLogin"))
	idx := func(s string) int {
		for i, l := range h {
			if strings.Contains(l, s) {
				return i
			}
		}
		return -1
	}
	guard := idx("refusedStoreConfigCaller(conn, name)")
	if guard < 0 {
		t.Fatal("handleLogin never calls refusedStoreConfigCaller")
	}
	if o := idx("refusedOwnerModeCaller(conn, name)"); o < 0 || o > guard {
		t.Errorf("refusedStoreConfigCaller (line %d) must follow refusedOwnerModeCaller (line %d)", guard, o)
	}
	for _, later := range []string{"sessionMu.TryLock()", "sessionMu.Lock()", `name == "SET-STORE" {`, `name == "SET-STORE-MANAGED"`, `name == "TEST-STORE"`} {
		if i := idx(later); i < 0 || i < guard {
			t.Errorf("handleLogin reaches %s (line %d of its body) before the store-config refusal (line %d)", later, i, guard)
		}
	}
}
