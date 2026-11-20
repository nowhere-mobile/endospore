package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type shoFixture struct {
	mu               sync.Mutex
	posts            int
	batch            []string
	gets             []string
	arrived          map[string]chan struct{}
	wait             bool
	failScope        bool
	failKey          string
	absent           map[string]bool
	tombstones       map[string]bool
	rendezvousFailed bool
}

func scopeHeadOverlapInline(_ string, fn func()) { fn() }

func newSHOFixture(t *testing.T) (*shoFixture, *httptest.Server) {
	t.Helper()
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("NOWHERE_MULTIDEVICE", "")
	t.Setenv("NOWHERE_UNIT_SRC", "")
	oldRetry := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = oldRetry })
	f := &shoFixture{arrived: map[string]chan struct{}{}, absent: map[string]bool{}, tombstones: map[string]bool{}}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/caps" {
			var req struct {
				Refs []string `json:"refs"`
			}
			_ = json.NewDecoder(r.Body).Decode(&req)
			f.mu.Lock()
			f.posts++
			f.batch = append([]string(nil), req.Refs...)
			f.mu.Unlock()
			caps := map[string]string{}
			for _, key := range req.Refs {
				caps[key] = srvURL(r, key)
			}
			_ = json.NewEncoder(w).Encode(capsResp{Caps: caps, TTLSeconds: 60})
			return
		}
		if r.URL.Path == "/cap" {
			io.WriteString(w, `{"url":"`+srvURL(r, r.URL.Query().Get("ref"))+`"}`)
			return
		}
		key := strings.TrimPrefix(r.URL.Path, "/obj/")
		f.mu.Lock()
		f.gets = append(f.gets, key)
		arrived, wait, fail := f.arrived[key], f.wait, f.failScope
		f.mu.Unlock()
		if arrived != nil {
			select {
			case <-arrived:
			default:
				close(arrived)
			}
		}
		if wait && arrived != nil {
			var other string
			for candidate := range f.arrived {
				if candidate != key {
					other = candidate
				}
			}
			f.mu.Lock()
			ch := f.arrived[other]
			f.mu.Unlock()
			select {
			case <-ch:
			case <-time.After(2 * time.Second):
				f.mu.Lock()
				f.rendezvousFailed = true
				f.mu.Unlock()
				http.Error(w, "peer missing", 504)
				return
			}
		}
		if fail && key == f.failKey {
			http.Error(w, "failed", 500)
			return
		}
		if f.absent[key] {
			http.NotFound(w, r)
			return
		}
		if f.tombstones[key] {
			return
		}
		if strings.HasPrefix(key, "ref/") {
			io.WriteString(w, "head-value")
			return
		}
		http.NotFound(w, r)
	})
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &httptest.Server{Listener: listener, Config: &http.Server{Handler: handler}}
	srv.Start()
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	resetCapReadCache(t)
	return f, srv
}

func srvURL(r *http.Request, key string) string { return "http://" + r.Host + "/obj/" + key }

func TestScopeHeadOverlap_CapBatchAndMemoHit(t *testing.T) {
	f, _ := newSHOFixture(t)
	const profile, pass = "shoone#de", "passphrase"
	bare, scope := "ref/"+profileRefV2("shoone", pass), "ref/"+profileRefV2(profile, pass)
	memo := refProbeMemo{}
	traceBefore := traceNow()
	traceDistinctBegin()
	join := scopeHeadOverlap("s3", profile, pass, memo)
	refProbe("s3", profileRefV2("shoone", pass))
	join()
	reads, keys := traceDistinctEnd()
	capCalls := traceNow().since(traceBefore).capN
	f.mu.Lock()
	posts, batch := f.posts, append([]string(nil), f.batch...)
	f.mu.Unlock()
	if posts != 1 {
		t.Errorf("O1: got %d gateway calls, want one batched /caps POST", posts)
	}
	if capCalls != 1 {
		t.Errorf("O1: traceCapN delta=%d, want one gateway round trip", capCalls)
	}
	if len(batch) != 2 || batch[0] != bare || batch[1] != scope {
		t.Errorf("O1: batch refs %q, want exactly bare and scope v2", batch)
	}
	if reads != 2 || keys != 2 {
		t.Errorf("O1: reads=%dx/%dkeys, want 2x/2keys", reads, keys)
	}
	f.mu.Lock()
	got := append([]string(nil), f.gets...)
	f.mu.Unlock()
	if len(got) != 2 {
		t.Errorf("O1: store reads %q, want one bare and one scope ref", got)
	}
	if _, ok := memo[profileRefV2(profile, pass)]; !ok {
		t.Errorf("O1: successful scope probe did not enter invocation memo")
	}
}

func TestScopeHeadOverlap_ConcurrentWithBareRead(t *testing.T) {
	f, _ := newSHOFixture(t)
	const profile, pass = "shotwo#de", "passphrase"
	bareKey := "ref/" + profileRefV2("shotwo", pass)
	scopeKey := "ref/" + profileRefV2(profile, pass)
	f.wait = true
	f.arrived[bareKey] = make(chan struct{})
	f.arrived[scopeKey] = make(chan struct{})
	join := scopeHeadOverlap("s3", profile, pass, refProbeMemo{})
	bareDone := make(chan struct{})
	goSafe("scope-head-overlap-test", func() { defer close(bareDone); refProbe("s3", profileRefV2("shotwo", pass)) })
	join()
	select {
	case <-bareDone:
	case <-time.After(2 * time.Second):
		t.Fatal("O2: bare GET did not rendezvous with scope GET")
	}
	f.mu.Lock()
	failed := f.rendezvousFailed
	f.mu.Unlock()
	if failed {
		t.Fatal("O2: one GET returned before the peer arrived")
	}
}

func TestScopeHeadOverlap_MissDoesNotMemoize(t *testing.T) {
	f, _ := newSHOFixture(t)
	const profile, pass = "shothree#de", "wrong passphrase"
	f.absent["ref/"+profileRefV2(profile, pass)] = true
	memo := refProbeMemo{}
	join := scopeHeadOverlap("s3", profile, pass, memo)
	join()
	if _, ok := memo[profileRefV2(profile, pass)]; ok {
		t.Fatal("O3: absent scope was recorded in the memo")
	}
}

func TestScopeHeadOverlap_BlindMissRequestShape(t *testing.T) {
	requestShape := func(name, pass string) []string {
		t.Helper()
		f, _ := newSHOFixture(t)
		f.absent["ref/"+profileRefV2(name+"#de", pass)] = true
		join := scopeHeadOverlap("s3", name+"#de", pass, refProbeMemo{})
		join()
		f.mu.Lock()
		defer f.mu.Unlock()
		shape := []string{"POST /caps"}
		for _, key := range f.batch {
			shape = append(shape, "cap "+key[:strings.IndexByte(key, '/')+1]+"v2")
		}
		for _, key := range f.gets {
			shape = append(shape, "GET "+key[:strings.IndexByte(key, '/')+1]+"v2")
		}
		return shape
	}
	wrong := requestShape("shoblindone", "wrong passphrase")
	unknown := requestShape("shoblindtwo", "correct passphrase")
	if strings.Join(wrong, ",") != strings.Join(unknown, ",") {
		t.Fatalf("O3: wrong-pass and unknown-name request sets differ: %q vs %q", wrong, unknown)
	}
}

func TestScopeHeadOverlap_TombstonedBareHeadRefusesScope(t *testing.T) {
	for _, scope := range []string{"#de", "#sys", "#media", "#apps", "#keys"} {
		t.Run(scope, func(t *testing.T) {
			f, _ := newSHOFixture(t)
			name, pass := "shotombstone"+strings.TrimPrefix(scope, "#"), "passphrase"
			f.tombstones["ref/"+profileRefV2(name, pass)] = true
			deleted, locked, head, ok := bhrRestoreHead("s3", name+scope, pass)
			if !deleted || locked || ok || head != "" {
				t.Fatalf("O3: tombstoned profile restored: deleted=%v locked=%v head=%q ok=%v", deleted, locked, head, ok)
			}
			f.mu.Lock()
			defer f.mu.Unlock()
			for _, key := range f.gets {
				if strings.HasPrefix(key, "blob/") {
					t.Fatalf("O3: refused scope fetched a restore blob: %q", key)
				}
			}
		})
	}
}

func TestScopeHeadOverlap_Gates(t *testing.T) {
	for _, tc := range []struct {
		base, profile string
		multi         bool
	}{{"s3", "shobare", false}, {"http", "shoflat#de", false}, {"s3", "shounit#de", true}} {
		t.Run(tc.profile, func(t *testing.T) {
			f, _ := newSHOFixture(t)
			if tc.multi {
				t.Setenv("NOWHERE_MULTIDEVICE", "1")
			}
			join := scopeHeadOverlap(tc.base, tc.profile, "passphrase", refProbeMemo{})
			join()
			f.mu.Lock()
			defer f.mu.Unlock()
			if f.posts != 0 || len(f.gets) != 0 {
				t.Errorf("O4: gated path did work: posts=%d gets=%q", f.posts, f.gets)
			}
		})
	}
}

func TestScopeHeadOverlap_DirectS3DoesNotStartWorker(t *testing.T) {
	_, srv := newSHOFixture(t)
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ENDPOINT", strings.TrimPrefix(srv.URL, "http://"))
	t.Setenv("S3_BUCKET", "scope-head-overlap-test")
	t.Setenv("S3_REGION", "us-east-1")
	t.Setenv("S3_ACCESS_KEY", "test-key")
	t.Setenv("S3_SECRET_KEY", "test-secret")
	s3InitMu.Lock()
	oldClient, oldBucket := s3client, s3bucket
	s3client, s3bucket = nil, ""
	s3InitMu.Unlock()
	t.Cleanup(func() {
		s3InitMu.Lock()
		s3client, s3bucket = oldClient, oldBucket
		s3InitMu.Unlock()
	})
	started := make(chan struct{}, 1)
	finished := make(chan struct{})
	track := func(job string) func() {
		if job == "scope-head-overlap" {
			started <- struct{}{}
			return func() { close(finished) }
		}
		return func() {}
	}
	goSafeTrack.Store(&track)
	t.Cleanup(func() { goSafeTrack.Store(nil) })
	join := scopeHeadOverlap("s3", "shodirect#de", "passphrase", refProbeMemo{})
	join()
	select {
	case <-started:
		select {
		case <-finished:
		case <-time.After(2 * time.Second):
			t.Error("O4: direct-S3 worker did not finish at the local test server")
		}
		t.Fatal("O4: direct S3 started speculative scope read")
	default:
	}
}

func TestScopeHeadOverlap_FailedProbeDoesNotMemoize(t *testing.T) {
	failureRun := func(profile string, overlap bool) (string, int, refProbeMemo) {
		t.Helper()
		f, _ := newSHOFixture(t)
		f.failScope = true
		const pass = "passphrase"
		ref := profileRefV2(profile, pass)
		f.failKey = "ref/" + ref
		memo := refProbeMemo{}
		var panicText string
		func() {
			defer func() {
				if r := recover(); r != nil {
					panicText = fmt.Sprint(r)
				}
			}()
			if overlap {
				join := scopeHeadOverlap("s3", profile, pass, memo)
				join()
				memo.probe("s3", ref)
				return
			}
			refProbe("s3", ref)
		}()
		f.mu.Lock()
		defer f.mu.Unlock()
		return panicText, len(f.gets), memo
	}
	baselinePanic, baselineGets, _ := failureRun("shfivebaseline#de", false)
	gotPanic, gotGets, memo := failureRun("shfiveoverlap#de", true)
	if !strings.Contains(gotPanic, "status 500") || !strings.Contains(baselinePanic, "status 500") {
		t.Fatalf("O5: caller outcomes %q and %q did not both report the store failure", gotPanic, baselinePanic)
	}
	if gotGets != baselineGets*2 {
		t.Fatalf("O5: speculative failure and live resolution made %d scope GETs, want twice baseline %d", gotGets, baselineGets*2)
	}
	if _, ok := memo[profileRefV2("shfiveoverlap#de", "passphrase")]; ok {
		t.Fatal("O5: failed probe entered memo")
	}
}
