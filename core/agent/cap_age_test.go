package main

// NWP-20261123-03: a write cap near the end of its life is re-minted before its PUT, timed on the device's boot
// clock from when its lease batch landed. The rule (capNearExpiry) first, then whole flushes against a fake
// gateway whose caps really die 900 s after they were minted, by a clock the test drives by hand.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// capAgeURL is a presigned-looking cap with the given X-Amz-Expires and X-Amz-Date (a field is left out when ""). It
// holds no real credential or signature.
func capAgeURL(expires, date string) string {
	q := []string{}
	if date != "" {
		q = append(q, "X-Amz-Date="+date)
	}
	if expires != "" {
		q = append(q, "X-Amz-Expires="+expires)
	}
	q = append(q, "X-Amz-Signature=deadbeef")
	return "https://store.invalid/b/k?" + strings.Join(q, "&")
}

const capAgeT0 = int64(10 * time.Hour / time.Millisecond) // a boot clock reading, in ms

func ms(d time.Duration) int64 { return d.Milliseconds() }

func TestCapAge_AFreshCapIsNotNearExpiry(t *testing.T) {
	u := capAgeURL("900", "20261102T000000Z")
	if capNearExpiry(capAgeT0, capAgeT0, u) {
		t.Error("a cap minted now reads as near its life")
	}
	if capNearExpiry(capAgeT0, capAgeT0+ms(12*time.Minute+59*time.Second), u) {
		t.Error("a 900 s cap 12m59s old reads as near its life, want only from 13m")
	}
}

func TestCapAge_AtLifeLessTheMarginItIs(t *testing.T) {
	u := capAgeURL("900", "20261102T000000Z")
	if !capNearExpiry(capAgeT0, capAgeT0+ms(13*time.Minute), u) {
		t.Error("a 900 s cap exactly 13m old (life less the 2 min margin) is not re-minted")
	}
	if capNearExpiry(capAgeT0, capAgeT0+ms(13*time.Minute)-1, u) {
		t.Error("a 900 s cap 1 ms short of 13m old is re-minted")
	}
	if !capNearExpiry(capAgeT0, capAgeT0+ms(20*time.Minute), u) {
		t.Error("a 900 s cap 20m old (dead) is not re-minted")
	}
}

func TestCapAge_AnUnreadableExpiresIsNeverNearExpiry(t *testing.T) {
	for _, exp := range []string{"", "abc", "-5", "1234567890", "9e2"} {
		u := capAgeURL(exp, "20261102T000000Z")
		if capNearExpiry(capAgeT0, capAgeT0+ms(24*time.Hour), u) {
			t.Errorf("X-Amz-Expires=%q: a cap with no readable life reads as near it, want today's path", exp)
		}
	}
}

func TestCapAge_TheSignedDateIsNotRead(t *testing.T) {
	now := time.Now().UTC()
	past := now.Add(-2 * time.Hour).Format("20060102T150405Z")
	future := now.Add(time.Hour).Format("20060102T150405Z")
	if capNearExpiry(capAgeT0, capAgeT0, capAgeURL("900", past)) {
		t.Error("a cap stamped now but signed (by the gateway's clock) two hours ago is re-minted: skew read as age")
	}
	if !capNearExpiry(capAgeT0, capAgeT0+ms(14*time.Minute), capAgeURL("900", future)) {
		t.Error("a cap stamped 14m ago but signed an hour in the future is not re-minted: skew hid its age")
	}
	for _, d := range []string{"", "yesterday"} {
		if capNearExpiry(capAgeT0, capAgeT0, capAgeURL("900", d)) || !capNearExpiry(capAgeT0, capAgeT0+ms(14*time.Minute), capAgeURL("900", d)) {
			t.Errorf("X-Amz-Date=%q changed the rule", d)
		}
	}
}

// ageGateway is a gateway and store in one server. Every write cap it mints carries X-Amz-Expires=900 (none when
// noExpires) and is recorded with the fake boot clock's reading; the store refuses a PUT through a cap the clock
// says is 900 s old or more with 403 ExpiredRequest. The clock is the test's: it reads t0 until the first PUT has
// been answered, then t0+advance -- what a long upload, or a suspend, does to it.
type ageGateway struct {
	*batchGateway
	mu        sync.Mutex
	clock     int64
	advance   int64
	noExpires bool
	capFail   func(ref string, n int) bool // POST /cap for ref, the n-th for it (from 1): answer 503?
	mint      map[int]int64                // cap id -> the clock when it was minted
	ids       int
	capsByRef map[string]int
	capPosts  int // POST /cap re-mints, every answer
	forbidden int // PUTs refused 403 ExpiredRequest
	okPuts    int // PUTs stored
}

func newAgeGateway(t *testing.T, advance time.Duration) *ageGateway {
	t.Helper()
	a := &ageGateway{batchGateway: &batchGateway{}, clock: capAgeT0, advance: ms(advance), mint: map[int]int64{}, capsByRef: map[string]int{}}
	old := bootNowMs
	bootNowMs = func() int64 { a.mu.Lock(); defer a.mu.Unlock(); return a.clock }
	t.Cleanup(func() { bootNowMs = old })
	t.Setenv("NOWHERE_SEAL_UPLOAD_WORKERS", "1") // the blob pass in order, so the clock switch lands on the first PUT
	objs := map[string][]byte{}
	mux := http.NewServeMux()
	// capURL mints one write cap; a.mu is held.
	capURL := func(host, ref string) string {
		a.ids++
		a.mint[a.ids] = a.clock
		u := "http://" + host + "/obj?k=" + url.QueryEscape(ref) + "&id=" + strconv.Itoa(a.ids) + "&X-Amz-Date=20261102T000000Z"
		if !a.noExpires {
			u += "&X-Amz-Expires=900"
		}
		return u
	}
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		k := q.Get("k")
		a.mu.Lock()
		defer a.mu.Unlock()
		if r.Method != http.MethodPut {
			b, ok := objs[k]
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Write(b)
			return
		}
		b, _ := io.ReadAll(r.Body)
		id, _ := strconv.Atoi(q.Get("id"))
		minted, known := a.mint[id]
		if !known {
			w.WriteHeader(http.StatusForbidden)
			io.WriteString(w, `<Error><Code>AccessDenied</Code></Error>`)
			return
		}
		if q.Get("X-Amz-Expires") != "" && a.clock-minted >= 900_000 {
			a.forbidden++
			w.WriteHeader(http.StatusForbidden)
			io.WriteString(w, expiredRequestBody)
			return
		}
		objs[k] = b
		a.okPuts++
		if a.okPuts == 1 {
			a.clock += a.advance // after the first PUT is judged and answered: never a sleep
		}
	})
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		a.mu.Lock()
		defer a.mu.Unlock()
		if r.Method != http.MethodPost { // a read cap: never expires here, never counted
			json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
			return
		}
		var req capBoundReq
		json.NewDecoder(r.Body).Decode(&req)
		a.capPosts++
		a.capsByRef[req.Ref]++
		if a.capFail != nil && a.capFail(req.Ref, a.capsByRef[req.Ref]) {
			w.WriteHeader(http.StatusServiceUnavailable)
			io.WriteString(w, `{"error":"try later"}`)
			return
		}
		json.NewEncoder(w).Encode(capBoundResp{URL: capURL(r.Host, req.Ref)})
	})
	mux.HandleFunc("GET /quote", func(w http.ResponseWriter, _ *http.Request) {
		json.NewEncoder(w).Encode(quoteInfo{Denom: "1GBmo", GBPerToken: 1, EpochSeconds: 604800, EpochsPerLease: 4, CurrentEpoch: 42})
	})
	mux.HandleFunc("POST /tokens", func(w http.ResponseWriter, r *http.Request) {
		var req tokensReq
		json.NewDecoder(r.Body).Decode(&req)
		var out tokensResp
		for i := 0; i < req.Count; i++ {
			out.Tokens = append(out.Tokens, Token{Denom: "1GBmo", Nonce: fmt.Sprintf("cag%d", i), Exp: 1 << 62, Sig: "sig"})
		}
		json.NewEncoder(w).Encode(out)
	})
	mux.HandleFunc("POST /lease", func(w http.ResponseWriter, r *http.Request) {
		var req leaseReq
		json.NewDecoder(r.Body).Decode(&req)
		if !req.Free {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		a.mu.Lock()
		defer a.mu.Unlock()
		out := leaseInfo{ThroughEpoch: 99, WriteCaps: map[string]string{}}
		for ref := range req.Refs {
			out.WriteCaps[ref] = capURL(r.Host, ref)
		}
		for k := range req.Expire {
			out.ExpireApplied = append(out.ExpireApplied, k)
		}
		json.NewEncoder(w).Encode(out)
	})
	a.srv = httptest.NewServer(mux)
	t.Cleanup(a.srv.Close)
	return a
}

func (a *ageGateway) counts() (capPosts, forbidden, okPuts int) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.capPosts, a.forbidden, a.okPuts
}

// ageSeal runs one free-lease flush of five blobs and the head for name in batches of three (so batch 0 takes the
// flushStart fallback and the later batches mergeLeaseInfo's stamp), and returns stderr.
func ageSeal(t *testing.T, a *ageGateway, name string) string {
	t.Helper()
	freeFixture(t, a.batchGateway, 3)
	fastRetries(t)
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	var rec any
	out := captureStderr(t, func() { rec = batchSeal(t, name, "pass of "+name, 5, nil, nil) })
	if rec != nil {
		t.Fatalf("the flush failed: %v\n%s", rec, out)
	}
	return out
}

const preMintLine = "cap-flush: re-minted "

// 14 minutes after the lease, every later cap is inside its last 2 minutes: each is re-minted before its PUT, once.
func TestCapFlush_ACapNearItsLifeIsReMintedBeforeItsPut(t *testing.T) {
	a := newAgeGateway(t, 14*time.Minute)
	out := ageSeal(t, a, "capagenear")
	posts, forbidden, puts := a.counts()
	if puts < 6 {
		t.Fatalf("%d PUT(s) stored, want at least the five blobs and the head", puts)
	}
	if forbidden != 0 {
		t.Errorf("%d PUT(s) refused 403, want 0", forbidden)
	}
	if posts != puts-1 {
		t.Errorf("%d POST /cap for %d PUTs, want %d: every PUT after the clock moved re-mints its cap once, before it", posts, puts, puts-1)
	}
	want := fmt.Sprintf("%s%d cap(s) before their PUT (0 failed, sent on the old cap) (NWP-20261123-03)", preMintLine, puts-1)
	if ls := linesWith(out, preMintLine); len(ls) != 1 || !strings.Contains(ls[0], want) {
		t.Errorf("want one line %q, got %q", want, ls)
	}
}

// A suspend: only the boot clock moves, 20 minutes, past every cap's life. Nothing is sent on a dead cap.
func TestCapFlush_ACapThatExpiredInSuspendIsReMinted(t *testing.T) {
	a := newAgeGateway(t, 20*time.Minute)
	ageSeal(t, a, "capagesleep")
	posts, forbidden, puts := a.counts()
	if forbidden != 0 {
		t.Errorf("%d PUT(s) refused 403 ExpiredRequest after the suspend, want 0: a dead cap was sent", forbidden)
	}
	if posts != puts-1 {
		t.Errorf("%d POST /cap for %d PUTs, want %d", posts, puts, puts-1)
	}
}

// The same flush with the clock not advanced: no re-mint, no line.
func TestCapFlush_NoClockAdvanceNoReMint(t *testing.T) {
	a := newAgeGateway(t, 0)
	out := ageSeal(t, a, "capagestill")
	posts, forbidden, _ := a.counts()
	if posts != 0 || forbidden != 0 {
		t.Errorf("%d POST /cap and %d 403(s) on fresh caps, want 0 and 0", posts, forbidden)
	}
	if ls := linesWith(out, preMintLine); len(ls) != 0 {
		t.Errorf("a count line on a flush that re-minted nothing: %q", ls)
	}
}

// A cap with no X-Amz-Expires has no life to read: it is never pre-minted, however old.
func TestCapFlush_ACapWithNoExpiresIsNeverReMinted(t *testing.T) {
	a := newAgeGateway(t, 14*time.Minute)
	a.noExpires = true
	out := ageSeal(t, a, "capagenoexp")
	posts, forbidden, _ := a.counts()
	if posts != 0 || forbidden != 0 {
		t.Errorf("%d POST /cap and %d 403(s) for caps with no X-Amz-Expires, want 0 and 0", posts, forbidden)
	}
	if ls := linesWith(out, preMintLine); len(ls) != 0 {
		t.Errorf("a count line on a flush that re-minted nothing: %q", ls)
	}
}

// A pre-mint that fails (503) sends the PUT on the old cap as before: refused 403, re-minted by the backstop, sent
// again, and the seal still finishes. Nothing logged holds a URL or a signed field.
func TestCapFlush_AFailedReMintFallsBackToTheForbiddenPath(t *testing.T) {
	a := newAgeGateway(t, 20*time.Minute)
	a.capFail = func(_ string, n int) bool { return n == 1 }
	out := ageSeal(t, a, "capagefail")
	posts, forbidden, puts := a.counts()
	if forbidden != puts-1 {
		t.Errorf("%d PUT(s) refused 403, want %d: each failed pre-mint sends its PUT on the dead cap once", forbidden, puts-1)
	}
	if posts != 2*(puts-1) {
		t.Errorf("%d POST /cap, want %d: the failed pre-mint and the 403 re-mint, per PUT", posts, 2*(puts-1))
	}
	want := fmt.Sprintf("%s%d cap(s) before their PUT (%d failed, sent on the old cap) (NWP-20261123-03)", preMintLine, puts-1, puts-1)
	if ls := linesWith(out, preMintLine); len(ls) != 1 || !strings.Contains(ls[0], want) {
		t.Errorf("want one line %q, got %q", want, ls)
	}
	if ls := linesWith(out, "re-mint before the PUT failed"); len(ls) != puts-1 {
		t.Errorf("%d `re-mint before the PUT failed` line(s), want %d", len(ls), puts-1)
	}
	for _, l := range strings.Split(out, "\n") {
		for _, bad := range []string{"http://", "X-Amz-", a.srv.URL} {
			if strings.Contains(l, bad) {
				t.Errorf("stderr line holds %q: %q", bad, l)
			}
		}
	}
}
