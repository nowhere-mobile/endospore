package main

import (
	"errors"
	"io"
	"net"
	"os"
	"strings"
	"testing"
)

// NWP-20261006-21: a store read that fails in transport after every retry exits exitStoreUnreachable, so roamd
// can answer "BLANK NET" at sign-in (a retry, never the rollback) and otad can stop reading it as "up to date".
// A read that SUCCEEDED and returned something wrong -- a missing blob -- must not be marked.

func panicOf(f func()) (r any) {
	defer func() { r = recover() }()
	f()
	return nil
}

func deadStore(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close() // nothing listens there now: a dial is refused
	return "http://" + addr
}

func TestExitStatusStoreUnreachable(t *testing.T) {
	if got := exitStatus(storeReadErr{io.ErrUnexpectedEOF}); got != exitStoreUnreachable {
		t.Errorf("a store read failure exits %d, want %d", got, exitStoreUnreachable)
	}
	if got := exitStatus(errors.New("blob not found: abc")); got != 1 {
		t.Errorf("an ordinary failure exits %d, want 1", got)
	}
	if exitStoreUnreachable == exitNoCredit || exitStoreUnreachable == exitSealRefused || exitStoreUnreachable == 1 {
		t.Error("exitStoreUnreachable must be distinct from every other agent exit code")
	}
}

func TestADeadStoreIsUnreachable(t *testing.T) {
	base := deadStore(t)
	for what, f := range map[string]func(){
		"getBlob": func() { getBlob(base, "abc") },
		"getRef":  func() { getRef(base, "abc") },
	} {
		r := panicOf(f)
		e, _ := r.(error)
		if e == nil || !errors.Is(e, errStoreUnreachable) {
			t.Errorf("%s against a refused dial panicked with %v, want an errStoreUnreachable", what, r)
		} else if exitStatus(r) != exitStoreUnreachable {
			t.Errorf("%s: the panic does not map to exitStoreUnreachable", what)
		}
	}
}

func TestAMissingBlobIsNotUnreachable(t *testing.T) {
	base := newHTTPStore(t)
	r := panicOf(func() { getBlob(base, "0000000000000000000000000000000000000000000000000000000000000000") })
	if r == nil {
		t.Fatal("control: a missing blob did not fail at all")
	}
	if e, _ := r.(error); errors.Is(e, errStoreUnreachable) {
		t.Fatal("a missing blob was marked unreachable: the gate would hide the rollback from a damaged save")
	}
	if exitStatus(r) != 1 {
		t.Errorf("a missing blob exits %d, want 1", exitStatus(r))
	}
}

// The managed-store reads and the direct-S3 reads mark their transport failures too (neither can run here
// without a gateway or a bucket), and the daemon passes "BLANK NET" through rather than flattening it.
func TestUnreachableIsMarkedOnEveryReadPathAndPassedThrough(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	body := func(sig string) string {
		i := strings.Index(src, sig)
		if i < 0 {
			t.Fatalf("%s not found", sig)
		}
		rest := src[i:]
		return rest[:strings.Index(rest, "\n}\n")]
	}
	for _, sig := range []string{"func capGet(key string) ([]byte, bool) {", "func s3Get(key string) ([]byte, bool) {"} {
		if !strings.Contains(body(sig), "checkRead(") {
			t.Errorf("%s no longer marks a transport failure unreachable", sig)
		}
	}
	h := body("func handleRoamIn(")
	if !strings.Contains(h, `strings.HasPrefix(out, "BLANK NET")`) || !strings.Contains(h, `fmt.Fprint(conn, "BLANK NET\n")`) {
		t.Error(`handleRoamIn no longer passes roamd's "BLANK NET" through to the gate`)
	}
}
