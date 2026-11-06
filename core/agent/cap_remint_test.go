package main

// NWP-20260909-07: a presigned write cap has a lifetime, and a big seal can outlive it.
//
// The shape this pins: on lynx 2026-09-09 an imported profile's 12,317 chunks took 15m39s to upload against
// caps minted in ONE batch when the lease returned. They expired partway, and every retry re-presented the
// SAME dead URL -- `cap PUT -> 403` five times -- so the profile could not be sealed or logged off at all.
// capGet had handled this since #71; capPut never did.

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// what an expired presigned URL actually returns -- the body the old code truncated to "<?xml versio".
const expiredCapBody = `<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code>` +
	`<Message>Request has expired</Message><RequestId>abc</RequestId></Error>`

// fastRetries shrinks the backoff so a failing case does not spend 3s of wall clock in sleeps.
func fastRetries(t *testing.T) {
	t.Helper()
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old })
}

// capStore serves PUTs, 403ing every path except okPath.
func capStore(t *testing.T, okPath string, got *[]byte) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != okPath {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, expiredCapBody)
			return
		}
		b, _ := io.ReadAll(r.Body)
		*got = b
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// didPanic runs fn and reports whether it failed (capPut fails via check() -> panic).
func didPanic(fn func()) (failed bool) {
	defer func() {
		if recover() != nil {
			failed = true
		}
	}()
	fn()
	return
}

// THE FIX: a stale cap is re-minted and the write lands.
func TestCapPut_ReMintsAStaleCapAndSucceeds(t *testing.T) {
	fastRetries(t)
	var got []byte
	srv := capStore(t, "/fresh", &got)

	var mints int32
	body := []byte("chunk bytes")
	if failed := didPanic(func() {
		capPut("blob/stale", srv.URL+"/stale", nil, body, func() (string, map[string]string, error) {
			atomic.AddInt32(&mints, 1)
			return srv.URL + "/fresh", nil, nil
		})
	}); failed {
		t.Fatal("capPut gave up on an EXPIRED cap instead of re-minting it. That is the wedge: a slow upload " +
			"outlives the caps minted at lease time, and the profile can never be sealed or logged off.")
	}
	if string(got) != string(body) {
		t.Errorf("the store received %q, want %q", got, body)
	}
	if n := atomic.LoadInt32(&mints); n != 1 {
		t.Errorf("re-minted %d time(s), want exactly 1", n)
	}
}

// ...and a FRESH cap that still 403s is a real denial, not an expiry. It must fail, and must NOT keep asking
// the gateway for more caps -- otherwise a genuinely forbidden write loops against it.
func TestCapPut_AFreshCapThatIsStillForbiddenFailsWithoutLooping(t *testing.T) {
	fastRetries(t)
	var got []byte
	srv := capStore(t, "/never", &got) // nothing the client tries will be accepted

	var mints int32
	if failed := didPanic(func() {
		capPut("blob/stale", srv.URL+"/stale", nil, []byte("x"), func() (string, map[string]string, error) {
			atomic.AddInt32(&mints, 1)
			return srv.URL + "/also-denied", nil, nil
		})
	}); !failed {
		t.Fatal("a write the store refuses even on a FRESH cap was reported as success")
	}
	if n := atomic.LoadInt32(&mints); n != 1 {
		t.Errorf("re-minted %d time(s), want exactly 1 -- a 403 that survives a fresh cap is a denial, and "+
			"re-minting per attempt would hammer the gateway on every genuinely forbidden write", n)
	}
}

// THE CONTROL. Without it, "make capPut always succeed" would pass the test above wearing the same green tick.
func TestCapPut_WithNoRefreshStillFails(t *testing.T) {
	fastRetries(t)
	var got []byte
	srv := capStore(t, "/never", &got)

	if failed := didPanic(func() { capPut("blob/stale", srv.URL+"/stale", nil, []byte("x"), nil) }); !failed {
		t.Error("capPut with no refresh must still fail on a 403 -- the fix is a RE-MINT, not a suppression")
	}
}

// The refusal must NAME itself. The old log line was `cap PUT -> 403: <?xml versio`: short() cuts at 12 chars
// and every S3 error body opens with the XML declaration, so which 403 it was could only be inferred.
func TestStoreErrCode_NamesTheRefusalInsteadOfTheXmlHeader(t *testing.T) {
	if got := storeErrCode([]byte(expiredCapBody)); got != "AccessDenied" {
		t.Errorf("storeErrCode = %q, want %q", got, "AccessDenied")
	}
	if got := short(expiredCapBody); !strings.HasPrefix(got, "<?xml") {
		t.Fatalf("fixture drifted: short() should still yield the useless XML prefix, got %q", got)
	}
	// A body that is not S3 XML must degrade to the old behaviour rather than return nothing.
	if got := storeErrCode([]byte("plain failure text")); got != short("plain failure text") {
		t.Errorf("non-XML body: storeErrCode = %q, want the short() fallback %q", got, short("plain failure text"))
	}
	// A malformed/unterminated Code element must not return half the document.
	if got := storeErrCode([]byte("<Code>" + strings.Repeat("x", 200))); !strings.HasPrefix(got, "<Code>") {
		t.Errorf("unterminated <Code> should fall back to short(), got %q", got)
	}
}

// NWP-20261113-10: the one re-mint is spent only when it produced a cap, and a refused fresh cap says when it was
// signed. Before this slice `reminted = true` ran BEFORE refresh(), so one failed POST /cap (a gateway timeout, a
// 503 on a failed ledger read) spent the one-shot silently and every remaining attempt presented the same expired
// cap. And a fresh cap the store refused too left nothing saying when it had been signed, so a stale signing time
// or clock skew could not be told apart from anything else.

const expiredRequestBody = `<?xml version="1.0" encoding="UTF-8"?><Error><Code>ExpiredRequest</Code>` +
	`<Message>Request has expired</Message></Error>`

// remintStore answers 200 on okPath and 403 ExpiredRequest on every other path, counting PUTs per path.
type remintStore struct {
	srv   *httptest.Server
	mu    sync.Mutex
	puts  map[string]int
	got   []byte
	total int
}

func newRemintStore(t *testing.T, okPath string) *remintStore {
	t.Helper()
	s := &remintStore{puts: map[string]int{}}
	s.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.puts[r.URL.Path]++
		s.total++
		s.mu.Unlock()
		if r.URL.Path != okPath {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, expiredRequestBody)
			return
		}
		s.mu.Lock()
		s.got = b
		s.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(s.srv.Close)
	return s
}

// linesWith returns the lines of out that contain sub.
func linesWith(out, sub string) []string {
	var r []string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, sub) {
			r = append(r, l)
		}
	}
	return r
}

// (a) a failed re-mint is not the one re-mint: the next attempt runs it again, and the write lands on the fresh cap.
func TestCapPut_AFailedReMintIsTriedAgainOnTheNextAttempt(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	s := newRemintStore(t, "/fresh")

	var mints int32
	body := []byte("chunk bytes")
	var err error
	out := captureStderr(t, func() {
		err = capPutErr("blob/a", s.srv.URL+"/stale", nil, body, func() (string, map[string]string, error) {
			if atomic.AddInt32(&mints, 1) == 1 {
				return "", nil, errors.New("gateway POST /cap: HTTP 503 (ledger read failed)")
			}
			return s.srv.URL + "/fresh", nil, nil
		})
	})
	if err != nil {
		t.Fatalf("capPutErr = %v, want nil: one failed POST /cap spent the one re-mint, so every later attempt "+
			"presented the same expired cap and the seal failed", err)
	}
	if n := atomic.LoadInt32(&mints); n != 2 {
		t.Errorf("refresh called %d time(s), want 2 (the failed re-mint, then the one that produced a cap)", n)
	}
	if string(s.got) != string(body) {
		t.Errorf("the fresh cap received %q, want %q", s.got, body)
	}
	ls := linesWith(out, "re-mint failed")
	if len(ls) != 1 {
		t.Fatalf("stderr holds %d `re-mint failed` line(s), want 1:\n%s", len(ls), out)
	}
	if !strings.Contains(ls[0], "-- trying again on the next attempt") {
		t.Errorf("the re-mint-failed line does not say it is tried again: %q", ls[0])
	}
}

// (b) a re-mint that keeps failing is bounded by retryStore's attempts, never presents anything but the stale cap,
// and prints no URL, query string or token.
func TestCapPut_AReMintThatKeepsFailingIsBoundedAndPrintsNoCap(t *testing.T) {
	cases := []struct {
		name    string
		refresh func() (string, map[string]string, error)
	}{
		{"refresh errors", func() (string, map[string]string, error) {
			return "", nil, fmt.Errorf("Post \"https://gw.invalid/cap?op=write&tok=SECRETTOK\": i/o timeout")
		}},
		{"refresh returns no URL", func() (string, map[string]string, error) { return "", nil, nil }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fastRetries(t)
			t.Cleanup(func() { capPutNoMD5.Store(false) })
			s := newRemintStore(t, "/never")

			var mints int32
			var err error
			out := captureStderr(t, func() {
				err = capPutErr("blob/b", s.srv.URL+"/stale?X-Amz-Signature=staleSIG", nil, []byte("x"),
					func() (string, map[string]string, error) {
						atomic.AddInt32(&mints, 1)
						return c.refresh()
					})
			})
			if err == nil {
				t.Fatal("a write whose re-mint never produced a cap was reported as success")
			}
			s.mu.Lock()
			total, stale := s.total, s.puts["/stale"]
			s.mu.Unlock()
			if total != storeRetryAttempts || stale != storeRetryAttempts {
				t.Errorf("%d PUT(s), %d to the stale cap, want %d, all to the stale cap", total, stale, storeRetryAttempts)
			}
			if n := atomic.LoadInt32(&mints); n != storeRetryAttempts {
				t.Errorf("refresh called %d time(s), want %d: each attempt on the stale cap runs the re-mint again, "+
					"bounded by retryStore", n, storeRetryAttempts)
			}
			ls := linesWith(out, "re-mint failed")
			if len(ls) != storeRetryAttempts {
				t.Errorf("stderr holds %d `re-mint failed` line(s), want %d:\n%s", len(ls), storeRetryAttempts, out)
			}
			for _, l := range ls {
				if strings.Contains(l, "?") {
					t.Errorf("a re-mint-failed line holds a query string: %q", l)
				}
			}
			for _, l := range strings.Split(out, "\n") {
				for _, bad := range []string{s.srv.URL, "staleSIG", "SECRETTOK", "?op=", "?X-Amz"} {
					if strings.Contains(l, bad) {
						t.Errorf("stderr line holds %q: %q", bad, l)
					}
				}
			}
		})
	}
}

// (c) a fresh cap the store refuses too fails without another re-mint, and logs when it was signed against the
// device clock -- reading only X-Amz-Date and X-Amz-Expires, never the signature.
func TestCapPut_ARefusedFreshCapLogsWhenItWasSigned(t *testing.T) {
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	s := newRemintStore(t, "/never")

	var mints int32
	var err error
	out := captureStderr(t, func() {
		err = capPutErr("blob/c", s.srv.URL+"/stale", nil, []byte("x"), func() (string, map[string]string, error) {
			atomic.AddInt32(&mints, 1)
			return s.srv.URL + "/fresh?X-Amz-Date=20261024T004159Z&X-Amz-Expires=900&X-Amz-Signature=deadbeef", nil, nil
		})
	})
	if err == nil {
		t.Fatal("a write the store refuses even on a FRESH cap was reported as success")
	}
	if !strings.Contains(err.Error(), "403") || !strings.Contains(err.Error(), "ExpiredRequest") {
		t.Errorf("capPutErr = %v, want it to name 403 ExpiredRequest", err)
	}
	if n := atomic.LoadInt32(&mints); n != 1 {
		t.Errorf("refresh called %d time(s), want exactly 1: a fresh cap that still 403s is not re-minted", n)
	}
	re := regexp.MustCompile(`the re-minted cap was refused too \(ExpiredRequest\): signed 20261024T004159Z for 900s, ` +
		`device clock [0-9]{8}T[0-9]{6}Z`)
	if !re.MatchString(out) {
		t.Errorf("stderr does not say when the refused fresh cap was signed against the device clock:\n%s", out)
	}
	for _, bad := range []string{"deadbeef", "X-Amz-Signature", s.srv.URL} {
		if strings.Contains(out, bad) {
			t.Errorf("stderr holds %q:\n%s", bad, out)
		}
	}
}
