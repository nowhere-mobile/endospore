package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/minio/minio-go/v7"
)

// NWP-20261120-21: TEST-STORE (the Store screen's "Test connection") and PING-STORE (its connection banner) map one
// BucketExists to a verdict the chooser renders. BucketExists sends a HEAD, and a HEAD error response has no body, so
// minio makes the code up from the status: 403 -> AccessDenied, 404 -> NoSuchBucket (which BucketExists turns into
// false, nil). The named codes InvalidAccessKeyId / SignatureDoesNotMatch never match on this path; the 403 status arm
// is the only one that maps a wrong key to ERR-AUTH. These tests drive every verdict through handleLogin against a
// local S3 fake; test-store-verdicts.sh --mutate proves they are not vacuous.

const verdictBucket = "nwtest-verdicts" // a valid S3 bucket name
const verdictRegion = "us-east-1"       // a set region: minio makes no GetBucketLocation call

// verdictStore is a local S3 fake that answers HEAD /<bucket> with one status and records every request.
type verdictStore struct {
	url  string
	mu   sync.Mutex
	reqs []string // "METHOD path auth=yes|no", in order
	odd  []string // every request that is not HEAD /<bucket>[/]
}

func (v *verdictStore) seen() (reqs, odd []string) {
	v.mu.Lock()
	defer v.mu.Unlock()
	return append([]string(nil), v.reqs...), append([]string(nil), v.odd...)
}

// startVerdictStore answers HEAD /<bucket> (path style) with status. Anything else gets 400, which minio does not
// retry, and is recorded as odd.
func startVerdictStore(t *testing.T, status int) *verdictStore {
	t.Helper()
	v := &verdictStore{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := "no"
		if r.Header.Get("Authorization") != "" {
			auth = "yes"
		}
		line := r.Method + " " + r.URL.Path + " auth=" + auth
		v.mu.Lock()
		v.reqs = append(v.reqs, line)
		ok := r.Method == http.MethodHead && strings.Trim(r.URL.Path, "/") == verdictBucket
		if !ok {
			v.odd = append(v.odd, line)
		}
		v.mu.Unlock()
		if !ok {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(status)
	}))
	t.Cleanup(srv.Close)
	v.url = srv.URL
	return v
}

// closedStoreURL starts a server, takes its URL and closes it: a dial there is refused.
func closedStoreURL(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.NotFoundHandler())
	u := srv.URL
	srv.Close()
	return u
}

// fewStoreRetries sets minio.MaxRetry to 1 (minio.New copies it into the client) and restores it on cleanup. A refused
// dial is otherwise retried 10 times (about 8 s), and --mutate runs every closed-port case four more times.
func fewStoreRetries(t *testing.T) {
	t.Helper()
	old := minio.MaxRetry
	minio.MaxRetry = 1
	t.Cleanup(func() { minio.MaxRetry = old })
}

// freshS3Client saves s3client and s3bucket, clears s3client so s3Init builds one from the environment, and puts
// both back on cleanup.
func freshS3Client(t *testing.T) {
	t.Helper()
	cl, bk := s3client, s3bucket
	s3client = nil
	t.Cleanup(func() { s3client, s3bucket = cl, bk })
}

// checkVerdictRequests: a store that was reached saw only signed HEAD /<bucket> requests; one that must not be reached
// saw none.
func checkVerdictRequests(t *testing.T, v *verdictStore, reached bool) {
	t.Helper()
	if v == nil {
		return
	}
	reqs, odd := v.seen()
	if len(odd) > 0 {
		t.Errorf("the fake store got requests other than HEAD /%s: %q", verdictBucket, odd)
	}
	if !reached {
		if len(reqs) > 0 {
			t.Errorf("the fake store was reached, want no request: %q", reqs)
		}
		return
	}
	if len(reqs) == 0 {
		t.Errorf("the fake store got no request, want HEAD /%s", verdictBucket)
	}
	for _, r := range reqs {
		if !strings.HasSuffix(r, " auth=yes") {
			t.Errorf("an unsigned request reached the fake store: %q", r)
		}
	}
}

// TestStoreVerdictTestStore: TEST-STORE, as the gate, answers OK, ERR-AUTH, ERR-BUCKET, ERR-NET and ERR-CONFIG, and
// saves nothing.
func TestStoreVerdictTestStore(t *testing.T) {
	for _, c := range []struct {
		name    string
		status  int    // the fake's answer; 0 = no fake
		closed  bool   // the endpoint is a closed port
		suffix  string // appended to the endpoint
		want    string
		reached bool
	}{
		{name: "200", status: 200, want: "OK", reached: true},
		{name: "403", status: 403, want: "ERR-AUTH", reached: true},
		{name: "404", status: 404, want: "ERR-BUCKET", reached: true},
		{name: "closed port", closed: true, want: "ERR-NET"},
		{name: "path in endpoint", status: 200, suffix: "/x", want: "ERR-CONFIG"},
	} {
		t.Run(c.name, func(t *testing.T) {
			conf := storeVerbFixture(t)
			asGate(t)
			fewStoreRetries(t)
			var v *verdictStore
			ep := ""
			if c.closed {
				ep = closedStoreURL(t)
			} else {
				v = startVerdictStore(t, c.status)
				ep = v.url
			}
			ep += c.suffix
			before, err := os.ReadFile(conf)
			if err != nil {
				t.Fatal(err)
			}
			envBefore := storeEnvSnapshot()
			cl := s3client
			got := driveLogin(t, t.TempDir(),
				"TEST-STORE\n"+ep+"\n"+verdictRegion+"\n"+verdictBucket+"\nnwtest-ak\nnwtest-sk\n")
			if got != c.want {
				t.Errorf("TEST-STORE against %s (%s) answered %q, want %q", c.name, ep, got, c.want)
			}
			if after, _ := os.ReadFile(conf); string(after) != string(before) {
				t.Errorf("TEST-STORE changed the store conf:\n%s", after)
			}
			if got := storeEnvSnapshot(); got != envBefore {
				t.Errorf("TEST-STORE changed the store environment:\nbefore %s\nafter  %s", envBefore, got)
			}
			if s3client != cl {
				t.Error("TEST-STORE replaced the daemon's store client")
			}
			checkVerdictRequests(t, v, c.reached)
		})
	}
}

// TestStoreVerdictPingStore: PING-STORE, with S3_* pointed at the fake and no gateway, answers OK, ERR-AUTH,
// ERR-BUCKET, ERR-NET and ERR-NOSTORE, and changes no conf or environment.
func TestStoreVerdictPingStore(t *testing.T) {
	for _, c := range []struct {
		name    string
		status  int  // the fake's answer
		closed  bool // the endpoint is a closed port
		nokeys  bool // S3_ACCESS_KEY and S3_SECRET_KEY empty: no store configured
		want    string
		reached bool
	}{
		{name: "200", status: 200, want: "OK", reached: true},
		{name: "403", status: 403, want: "ERR-AUTH", reached: true},
		{name: "404", status: 404, want: "ERR-BUCKET", reached: true},
		{name: "closed port", closed: true, want: "ERR-NET"},
		{name: "no store", status: 200, nokeys: true, want: "ERR-NOSTORE"},
	} {
		t.Run(c.name, func(t *testing.T) {
			conf := storeVerbFixture(t) // GATEWAY_URL="": the managed arm is skipped
			asGate(t)
			fewStoreRetries(t)
			var v *verdictStore
			ep := ""
			if c.closed {
				ep = closedStoreURL(t)
			} else {
				v = startVerdictStore(t, c.status)
				ep = v.url
			}
			ak, sk := "nwtest-ak", "nwtest-sk"
			if c.nokeys {
				ak, sk = "", ""
			}
			t.Setenv("S3_ENDPOINT", ep)
			t.Setenv("S3_REGION", verdictRegion)
			t.Setenv("S3_BUCKET", verdictBucket)
			t.Setenv("S3_ACCESS_KEY", ak)
			t.Setenv("S3_SECRET_KEY", sk)
			freshS3Client(t)
			before, err := os.ReadFile(conf)
			if err != nil {
				t.Fatal(err)
			}
			envBefore := storeEnvSnapshot()
			got := driveLogin(t, t.TempDir(), "PING-STORE\n")
			if got != c.want {
				t.Errorf("PING-STORE against %s (%s) answered %q, want %q", c.name, ep, got, c.want)
			}
			if after, _ := os.ReadFile(conf); string(after) != string(before) {
				t.Errorf("PING-STORE changed the store conf:\n%s", after)
			}
			if got := storeEnvSnapshot(); got != envBefore {
				t.Errorf("PING-STORE changed the store environment:\nbefore %s\nafter  %s", envBefore, got)
			}
			checkVerdictRequests(t, v, c.reached)
		})
	}
}
