package main

import (
	"crypto/md5"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// #116 write-side integrity: capPut must FAIL LOUDLY (bounded retries -> panic; the previous head survives)
// when the store's ETag proves it durably wrote different bytes than we sent (a torn PUT / transit
// corruption) -- the class that put the corrupt chunk in b's and nfctest's stores.
func TestCapPutRejectsTornWrite(t *testing.T) {
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	var puts int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&puts, 1)
		body, _ := io.ReadAll(r.Body)
		torn := body[:len(body)/2] // the store "wrote" only half the object
		sum := md5.Sum(torn)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	defer func() {
		if r := recover(); r == nil {
			t.Fatal("capPut must fail (panic via check) when the store's ETag mismatches the body md5")
		}
		if n := atomic.LoadInt32(&puts); n < 2 {
			t.Fatalf("a torn write should be retried before failing, got %d attempt(s)", n)
		}
	}()
	capPut("blob/obj", srv.URL+"/obj", nil, []byte("these bytes must arrive whole or the seal must fail"), nil)
}

// The happy path: a store that echoes the correct single-part MD5 ETag passes the readback check.
func TestCapPutAcceptsVerifiedWrite(t *testing.T) {
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if cm := r.Header.Get("Content-MD5"); cm == "" {
			t.Error("capPut must send Content-MD5 so the store can verify the body")
		}
		sum := md5.Sum(body)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	capPut("blob/obj", srv.URL+"/obj", nil, []byte("verified payload"), nil) // must not panic
}

// A presigner that SIGNS Content-MD5 makes our unsigned header a SignatureDoesNotMatch 403. capPut must
// degrade (drop the header for the process) and succeed on the retry -- the ETag readback still verifies.
func TestCapPutDegradesWhenStoreRejectsUnsignedMD5(t *testing.T) {
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.Header.Get("Content-MD5") != "" {
			w.WriteHeader(http.StatusForbidden)
			io.WriteString(w, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
			return
		}
		sum := md5.Sum(body)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:])+`"`)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	capPut("blob/obj", srv.URL+"/obj", nil, []byte("degrade gracefully"), nil) // must not panic
	if !capPutNoMD5.Load() {
		t.Fatal("capPut must latch the no-MD5 degrade after a SignatureDoesNotMatch")
	}
}

// A store with OPAQUE (non-MD5) ETags -- e.g. multipart-style "<hex>-<n>" -- must not false-positive.
func TestCapPutSkipsOpaqueETags(t *testing.T) {
	t.Cleanup(func() { capPutNoMD5.Store(false) })
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		w.Header().Set("ETag", `"deadbeefdeadbeefdeadbeefdeadbeef-3"`) // multipart marker -> not comparable
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	capPut("blob/obj", srv.URL+"/obj", nil, []byte("opaque etag payload"), nil) // must not panic
}
