package main

// NWP-20261123-01: IN CAP MODE THE RECEIPT MOVES ONLY AFTER ITS HEAD'S PUT HAS LANDED.
//
// putRefBytesGuarded only BUFFERS a pointer in cap mode, so putHeadGuarded's re-anchor and pushProfile's
// writeRestoreReceipt used to run before the deferred capFlush had written anything. A blob PUT that failed, a
// head PUT that failed, or a head the publish pass refused then left the receipt on a head the store never got,
// and the next seal logged STALE BASE against it -- with NOWHERE_SEQ_GUARD=1, every later seal refused
// (frankel NW-b636a742c916). These tests drive the real pushProfile through a front that resets the connection
// before or after the store applies a PUT.

import (
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	raPass        = iota // forward the request
	raResetBefore        // reset the connection; the store never sees the PUT
	raResetAfter         // forward the PUT, then reset the connection; the store applied it, the client saw an error
)

// raFront fronts the mock cap store. mode picks, per object PUT, what the front does with it.
type raFront struct {
	mu   sync.Mutex
	mode func(k string) int
}

func (f *raFront) set(mode func(k string) int) {
	f.mu.Lock()
	f.mode = mode
	f.mu.Unlock()
}

// raReset drops the connection with no response.
func raReset(w http.ResponseWriter) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		panic("raReset: the response writer cannot be hijacked")
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		panic(err)
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetLinger(0)
	}
	conn.Close()
}

// raFlushEnv is a cap-mode store with a front, receipts armed, the sequential guard on and the retry backoff shrunk.
func raFlushEnv(t *testing.T) (*raFront, map[string][]byte, *sync.Mutex) {
	t.Helper()
	objs, mu := capLockEnv(t)
	inner, err := url.Parse(os.Getenv("GATEWAY_URL"))
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("NOWHERE_SEQ_GUARD", "1")
	resetSealCaches()
	t.Cleanup(resetSealCaches)
	t.Cleanup(clearStaleHit)
	old := s3RetryBase
	s3RetryBase = time.Millisecond // a failed PUT's five attempts take milliseconds, not seconds
	t.Cleanup(func() { s3RetryBase = old })
	f := &raFront{}
	proxy := httputil.NewSingleHostReverseProxy(inner) // the default Director keeps Host, so caps name the front
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m := raPass
		if r.Method == http.MethodPut && r.URL.Path == "/obj" {
			f.mu.Lock()
			if f.mode != nil {
				m = f.mode(r.URL.Query().Get("k"))
			}
			f.mu.Unlock()
		}
		switch m {
		case raResetBefore:
			raReset(w)
		case raResetAfter:
			proxy.ServeHTTP(httptest.NewRecorder(), r)
			raReset(w)
		default:
			proxy.ServeHTTP(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	capReadCache = map[string]capEntry{}
	return f, objs, mu
}

// raSeal runs one push of src and returns its stdout and its panic, if any. The panic is recovered INSIDE the
// capture, which does not restore stdout on a panic.
func raSeal(t *testing.T, name, pass, src string) (out string, panicked any) {
	t.Helper()
	sealRefused, sealRefusedWhy = false, ""
	clearStaleHit()
	capReadCache = map[string]capEntry{}
	out = captureStdout(t, func() {
		defer func() { panicked = recover() }()
		pushProfile("s3", name, pass, src)
	})
	return out, panicked
}

// raHeadKey is the store key of the head pushProfile writes for (name, pass).
func raHeadKey(name, pass string) string {
	ref, _ := headWriteRef(name, pass)
	return "ref/" + ref
}

func raStored(objs map[string][]byte, mu *sync.Mutex, key string) string {
	mu.Lock()
	defer mu.Unlock()
	return strings.TrimSpace(string(objs[key]))
}

func raReceipt(name, pass string) string { return restoreReceiptHead(profileRefV2(name, pass)) }

func raWrite(t *testing.T, dir, payload string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte(payload), 0o600); err != nil {
		t.Fatal(err)
	}
}

// raFirstSeal creates the profile and seals it once, cleanly. It returns the tree and the head the seal stored,
// which the receipt names.
func raFirstSeal(t *testing.T, objs map[string][]byte, mu *sync.Mutex, name, pass string) (src, h1 string) {
	t.Helper()
	createVault("s3", name, pass)
	src = t.TempDir()
	raWrite(t, src, "the first payload of "+name)
	out, p := raSeal(t, name, pass, src)
	if p != nil || sealRefused || sealStaleHit {
		t.Fatalf("fixture: the first seal failed (panic %v, refused %v, stale %v):\n%s", p, sealRefused, sealStaleHit, out)
	}
	h1 = raStored(objs, mu, raHeadKey(name, pass))
	if h1 == "" {
		t.Fatal("fixture: the first seal stored no head")
	}
	if got := raReceipt(name, pass); got != h1 {
		t.Fatalf("fixture: the receipt names %q after a clean seal, want the stored head %q", short(got), short(h1))
	}
	return src, h1
}

// raNextSealIsClean pushes src again with the front passing everything: it must succeed, log no STALE BASE, and
// leave the receipt on the head it stored.
func raNextSealIsClean(t *testing.T, objs map[string][]byte, mu *sync.Mutex, name, pass, src string) {
	t.Helper()
	out, p := raSeal(t, name, pass, src)
	if strings.Contains(out, "STALE BASE") {
		t.Fatalf("the next seal logged STALE BASE -- the receipt named a head the store never held:\n%s", out)
	}
	if p != nil || sealRefused {
		t.Fatalf("the next seal failed (panic %v, refused %v %q):\n%s", p, sealRefused, sealRefusedWhy, out)
	}
	if h, r := raStored(objs, mu, raHeadKey(name, pass)), raReceipt(name, pass); r != h {
		t.Fatalf("after the next seal the receipt names %q, the store holds %q", short(r), short(h))
	}
}

// A: the head pointer's PUT fails on every attempt, before the store applies it.
func TestReceiptAfterFlush_A_HeadPutFailsReceiptStays(t *testing.T) {
	f, objs, mu := raFlushEnv(t)
	name, pass := "rafheadfail", "receipt after flush head fail"
	src, h1 := raFirstSeal(t, objs, mu, name, pass)
	hk := raHeadKey(name, pass)

	raWrite(t, src, "a second payload the store never gets a head for")
	f.set(func(k string) int {
		if k == hk {
			return raResetBefore
		}
		return raPass
	})
	out, p := raSeal(t, name, pass, src)
	f.set(nil)
	if p == nil {
		t.Fatalf("the push whose head PUT failed did not fail:\n%s", out)
	}
	if got := raStored(objs, mu, hk); got != h1 {
		t.Fatalf("the store's head moved to %q though its PUT never reached the store", short(got))
	}
	if got := raReceipt(name, pass); got != h1 {
		t.Fatalf("the receipt moved to %q, a head the store never got; want %q", short(got), short(h1))
	}
	raNextSealIsClean(t, objs, mu, name, pass, src)
}

// A2: a blob PUT fails, so the flush fails before its publish pass (the ticket's likeliest shape).
func TestReceiptAfterFlush_A2_BlobPutFailsReceiptStays(t *testing.T) {
	f, objs, mu := raFlushEnv(t)
	name, pass := "rafblobfail", "receipt after flush blob fail"
	src, h1 := raFirstSeal(t, objs, mu, name, pass)
	hk := raHeadKey(name, pass)

	raWrite(t, src, "a second payload whose blobs never land")
	f.set(func(k string) int {
		if strings.HasPrefix(k, "blob/") {
			return raResetBefore
		}
		return raPass
	})
	out, p := raSeal(t, name, pass, src)
	f.set(nil)
	if p == nil {
		t.Fatalf("the push whose blob PUTs failed did not fail:\n%s", out)
	}
	if got := raStored(objs, mu, hk); got != h1 {
		t.Fatalf("the store's head moved to %q though the flush never reached its pointers", short(got))
	}
	if got := raReceipt(name, pass); got != h1 {
		t.Fatalf("the receipt moved to %q, a head the store never got; want %q", short(got), short(h1))
	}
	raNextSealIsClean(t, objs, mu, name, pass, src)
}

// B: a lost response. The store applies the head PUT each time, and the client sees a reset each time.
func TestReceiptAfterFlush_B_LostResponseCountsAsLanded(t *testing.T) {
	f, objs, mu := raFlushEnv(t)
	name, pass := "raflostresp", "receipt after flush lost response"
	src, h1 := raFirstSeal(t, objs, mu, name, pass)
	hk := raHeadKey(name, pass)

	raWrite(t, src, "a second payload whose head PUT lands but whose answer is lost")
	f.set(func(k string) int {
		if k == hk {
			return raResetAfter
		}
		return raPass
	})
	out, p := raSeal(t, name, pass, src)
	f.set(nil)
	if p != nil {
		t.Fatalf("the push whose head PUT the store applied failed (%v) -- one read shows the head landed:\n%s", p, out)
	}
	h2 := raStored(objs, mu, hk)
	if h2 == h1 || h2 == "" {
		t.Fatalf("the store's head did not move (%q)", short(h2))
	}
	if got := raReceipt(name, pass); got != h2 {
		t.Fatalf("the receipt names %q, want the head the store holds %q", short(got), short(h2))
	}
	raNextSealIsClean(t, objs, mu, name, pass, src)
}

// C: another writer moves the head after this push read it, so the publish pass refuses the head.
func TestReceiptAfterFlush_C_StaleRefusalAtFlushKeepsReceipt(t *testing.T) {
	_, objs, mu := raFlushEnv(t)
	name, pass := "rafstale", "receipt after flush stale refusal"
	src, h1 := raFirstSeal(t, objs, mu, name, pass)
	hk := raHeadKey(name, pass)

	raWrite(t, src, "a second payload whose head another writer beats")
	moveHeadAtFlush(objs, mu, name, pass)
	out, _ := raSeal(t, name, pass, src)
	capStorePutHook = nil
	if !sealStaleHit {
		t.Fatalf("the publish pass did not refuse the moved head:\n%s", out)
	}
	if got := raStored(objs, mu, hk); got != strings.Repeat("cd", 32) {
		t.Fatalf("the store's head is %q, want the other writer's", short(got))
	}
	if got := raReceipt(name, pass); got != h1 {
		t.Fatalf("the receipt moved to %q, a head the publish pass refused; want %q", short(got), short(h1))
	}
}

// D: a clean cap-mode push still moves the receipt, each time.
func TestReceiptAfterFlush_D_CapPushMovesReceipt(t *testing.T) {
	_, objs, mu := raFlushEnv(t)
	name, pass := "rafcapclean", "receipt after flush cap clean"
	src, h1 := raFirstSeal(t, objs, mu, name, pass)
	raWrite(t, src, "a second clean payload")
	raNextSealIsClean(t, objs, mu, name, pass, src)
	if h2 := raStored(objs, mu, raHeadKey(name, pass)); h2 == h1 {
		t.Fatal("the second clean seal did not move the head")
	}
}

// D: a direct-store push (no gateway) still moves the receipt, each time.
func TestReceiptAfterFlush_D_DirectPushMovesReceipt(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	resetSealCaches()
	t.Cleanup(resetSealCaches)
	t.Cleanup(clearStaleHit)
	base := newHTTPStore(t)
	name, pass := "rafdirect", "receipt after flush direct store"
	createVault(base, name, pass)
	src := t.TempDir()
	for i, payload := range []string{"the first direct payload", "the second direct payload"} {
		raWrite(t, src, payload)
		sealRefused, sealRefusedWhy = false, ""
		pushProfile(base, name, pass, src)
		if sealRefused {
			t.Fatalf("direct seal %d was refused (%q)", i+1, sealRefusedWhy)
		}
		if h, r := getRef(base, headKey(base, name, pass)), raReceipt(name, pass); h == "" || r != h {
			t.Fatalf("direct seal %d: the receipt names %q, the store holds %q", i+1, short(r), short(h))
		}
	}
}

// raBracket opens a cap bracket with a session for (name, pass), runs fn inside it and flushes it.
func raBracket(name, pass string, fn func()) {
	n := capBegin()
	defer capEndBracket(n)
	capSetSession(name, pass, deriveKey(name, pass))
	fn()
	capFlush(n)
}

// D: a session with NO receipt still gets none -- the re-anchor updates a receipt and never mints one -- and one
// that holds a receipt has it moved once the head's PUT landed.
func TestReceiptAfterFlush_D_NoReceiptIsNeverMinted(t *testing.T) {
	_, objs, mu := raFlushEnv(t)
	name, pass := "rafnomint", "receipt after flush never mint"
	rref := profileRefV2(name, pass)
	h1, h2 := strings.Repeat("a1", 32), strings.Repeat("b2", 32)
	raBracket(name, pass, func() { putHead("s3", name, pass, h1) })
	if got := raStored(objs, mu, raHeadKey(name, pass)); got != h1 {
		t.Fatalf("fixture: the head did not land (%q)", short(got))
	}
	if haveRestoreReceipt(rref) {
		t.Fatal("a head write minted a receipt for a session that had none")
	}
	writeRestoreReceipt(rref, h1)
	raBracket(name, pass, func() { putHead("s3", name, pass, h2) })
	if got := raReceipt(name, pass); got != h2 {
		t.Fatalf("the receipt names %q after the head's PUT landed, want %q", short(got), short(h2))
	}
}

// E: capAbort drops the registered hooks, and a later bracket on the same key does not inherit them.
func TestReceiptAfterFlush_E_AbortDropsHooks(t *testing.T) {
	_, objs, mu := raFlushEnv(t)
	name, pass := "rafabort", "receipt after flush abort"
	r := profileRefV2(name, pass)
	ran := 0
	n := capBegin()
	capSetSession(name, pass, deriveKey(name, pass))
	putRef("s3", r, strings.Repeat("c3", 32))
	capAfterPublish(r, func() { ran++ })
	capAbort()
	if ran != 0 {
		t.Fatalf("capAbort ran %d hook(s)", ran)
	}
	capEndBracket(n)
	later := 0
	raBracket(name, pass, func() {
		putRef("s3", r, strings.Repeat("c3", 32))
		capAfterPublish(r, func() { later++ })
	})
	if ran != 0 {
		t.Fatalf("a later bracket ran %d hook(s) the aborted one registered", ran)
	}
	if later != 1 {
		t.Fatalf("the later bracket ran its own hook %d time(s), want once", later)
	}
	if got := raStored(objs, mu, "ref/"+r); got != strings.Repeat("c3", 32) {
		t.Fatalf("the later bracket's pointer did not land (%q)", short(got))
	}
}

// Outside a buffering bracket the pointer was written directly and has landed: the hook runs at once, once.
func TestReceiptAfterFlush_HookRunsAtOnceOutsideABracket(t *testing.T) {
	ran := 0
	capAfterPublish("rafdirecthook", func() { ran++ })
	if ran != 1 {
		t.Fatalf("outside a bracket the hook ran %d time(s) before capAfterPublish returned, want once", ran)
	}
}

// A hook registered for one value does not run when the bracket rewrote the pointer with another.
func TestReceiptAfterFlush_RewrittenValueRunsNoHook(t *testing.T) {
	_, objs, mu := raFlushEnv(t)
	name, pass := "rafrewrite", "receipt after flush rewrite"
	r := profileRefV2(name, pass)
	v1, v2 := strings.Repeat("d4", 32), strings.Repeat("e5", 32)
	ran := 0
	raBracket(name, pass, func() {
		putRef("s3", r, v1)
		capAfterPublish(r, func() { ran++ })
		putRef("s3", r, v2)
	})
	if ran != 0 {
		t.Fatalf("a hook registered for %q ran after %q landed", short(v1), short(v2))
	}
	if got := raStored(objs, mu, "ref/"+r); got != v2 {
		t.Fatalf("the store holds %q, want %q", short(got), short(v2))
	}
}
