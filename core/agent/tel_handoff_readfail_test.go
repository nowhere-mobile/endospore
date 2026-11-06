package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// NWP-20261017-25: the two telephony hand-offs (roam-in and resume) sat in a bare recover(), so a store read that
// failed after its retries left the sealed items undelivered with no log line. These tests pin the scrubbed
// FAILED line, the generic line for any other panic, and that nothing is dropped.

const thName, thPass = "thandoff", "correct horse battery staple"

// thSetup makes a profile in an http store, buffers one sealed SMS for it, and returns the store base, the head
// ref, the vault and the profile ref. The temp inbox and telephony fixtures are in place.
func thSetup(t *testing.T) (base, head string, v *vault, ref string) {
	t.Helper()
	telFixture(t)
	base = newHTTPStore(t)
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	createVault(base, thName, thPass)
	pinReadCapStore(t, base, 0)
	thRefKeyHex = strings.TrimPrefix(headKey("s3", thName, thPass), "ref/")
	head = getRef("s3", headKey("s3", thName, thPass))
	vv, isV := parseVault(getHeadBlob("s3", head))
	if !isV || vv == nil || vv.TelPub == "" {
		t.Fatalf("test profile has no telephony key (isV=%v)", isV)
	}
	ref = profileRefV2(thName, thPass)
	if err := sealItemToInbox(ref, vv.TelPub, simTag(iccidX), telItem{Kind: "sms", From: "+15551234567", When: 5, Body: "held"}); err != nil {
		t.Fatal(err)
	}
	return base, head, vv, ref
}

func thInboxCount(t *testing.T, ref string) int {
	t.Helper()
	ents, _ := os.ReadDir(telInboxDir(ref))
	n := 0
	for _, e := range ents {
		if !e.IsDir() {
			n++
		}
	}
	return n
}

// thLeaks fails if the line carries the unquoted name, a ref or a presigned URL's query.
func thLeaks(t *testing.T, out, ref string) {
	t.Helper()
	unq := strings.ReplaceAll(out, `"`+thName+`"`, "")
	for _, leak := range []string{thName, ref, headKeyRefHex(), "X-Amz-", "?k=", "?ref="} {
		if leak != "" && strings.Contains(unq, leak) {
			t.Fatalf("hand-off line leaks %q:\n%s", leak, out)
		}
	}
}

// thRefKeyHex is the head ref key, read once while the store is healthy (headKey itself reads the store).
var thRefKeyHex string

func headKeyRefHex() string { return thRefKeyHex }

func TestTelHandoffRoamInFailedReadIsLogged(t *testing.T) {
	_, head, _, ref := thSetup(t)
	pinReadCapStore(t, "http://127.0.0.1:1", 1<<30) // every object GET fails
	out := captureStderr(t, func() { telHandoffRoamIn(thName, thPass, head, nil, "11", nil) })
	if !strings.Contains(out, `roam-in "`+thName+`" -> telephony hand-off skipped: store read FAILED after retries (`) {
		t.Fatalf("no FAILED line on a failed read; stderr:\n%s", out)
	}
	thLeaks(t, out, ref)
	if n := thInboxCount(t, ref); n != 1 {
		t.Fatalf("the sealed item must stay in the inbox, found %d", n)
	}
}

func TestTelHandoffResumeFailedReadIsLogged(t *testing.T) {
	_, _, _, ref := thSetup(t)
	pinReadCapStore(t, "http://127.0.0.1:1", 1<<30)
	out := captureStderr(t, func() { telHandoffResume(thName, thPass, "11", nil) })
	if !strings.Contains(out, `resume "`+thName+`" -> telephony hand-off skipped: store read FAILED after retries (`) {
		t.Fatalf("no FAILED line on a failed read; stderr:\n%s", out)
	}
	thLeaks(t, out, ref)
	if n := thInboxCount(t, ref); n != 1 {
		t.Fatalf("the sealed item must stay in the inbox, found %d", n)
	}
}

// thCorruptBlobStore is a cap gateway whose every blob/ object is the wrong bytes, so getHeadBlob refuses the head
// through fail() (a string panic, not a storeReadErr).
func thCorruptBlobStore(t *testing.T, base string) {
	t.Helper()
	old := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = old })
	mux := http.NewServeMux()
	mux.HandleFunc("/cap", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(capResp{URL: "http://" + r.Host + "/obj?k=" + url.QueryEscape(r.URL.Query().Get("ref"))})
	})
	mux.HandleFunc("/obj", func(w http.ResponseWriter, r *http.Request) {
		k := r.URL.Query().Get("k")
		if strings.HasPrefix(k, "blob/") {
			w.Write([]byte("not the bytes this hash names"))
			return
		}
		resp, err := http.Get(base + "/" + k)
		if err != nil {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	t.Setenv("GATEWAY_URL", srv.URL)
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { capReadCache = map[string]capEntry{} })
}

func TestTelHandoffCorruptHeadGetsTheGenericLine(t *testing.T) {
	base, head, _, ref := thSetup(t)
	for _, run := range []struct {
		kind string
		fn   func()
	}{
		{"roam-in", func() { telHandoffRoamIn(thName, thPass, head, nil, "11", nil) }},
		{"resume", func() { telHandoffResume(thName, thPass, "11", nil) }},
	} {
		thCorruptBlobStore(t, base)
		out := captureStderr(t, run.fn)
		if !strings.Contains(out, run.kind+` "`+thName+`" -> telephony hand-off skipped: unexpected failure (details withheld)`) {
			t.Fatalf("%s: no generic line; stderr:\n%s", run.kind, out)
		}
		if strings.Contains(out, "FAILED") || strings.Contains(out, head) || strings.Contains(out, "corrupt head blob") {
			t.Fatalf("%s: the generic line prints the panic value or claims a read failure:\n%s", run.kind, out)
		}
		thLeaks(t, out, ref)
		if n := thInboxCount(t, ref); n != 1 {
			t.Fatalf("%s: the sealed item must stay, found %d", run.kind, n)
		}
	}
}

// The failed read's text must go through logSafeStoreErr: a presigned URL's query never reaches the line.
func TestTelHandoffPanicScrubsTheErrorText(t *testing.T) {
	e := storeReadErr{&url.Error{Op: "Get", URL: "http://store.invalid/obj?X-Amz-Signature=abc&k=blob%2Fx", Err: io.ErrUnexpectedEOF}}
	out := captureStderr(t, func() { telHandoffPanic("resume", thName, e) })
	if !strings.Contains(out, "FAILED") {
		t.Fatalf("no FAILED line:\n%s", out)
	}
	if strings.Contains(out, "X-Amz-") || strings.Contains(out, "?") {
		t.Fatalf("query text reached the line:\n%s", out)
	}
}

// A healthy store stages as before and prints no FAILED line.
func TestTelHandoffHealthyStoreStages(t *testing.T) {
	_, head, _, ref := thSetup(t)
	for _, run := range []struct {
		kind string
		fn   func()
	}{
		{"roam-in", func() { telHandoffRoamIn(thName, thPass, head, nil, "11", nil) }},
		{"resume", func() { telHandoffResume(thName, thPass, "12", nil) }},
	} {
		if run.kind == "resume" {
			if err := sealItemToInbox(ref, mustTelPub(t, head), simTag(iccidX), telItem{Kind: "sms", From: "+2", When: 6, Body: "again"}); err != nil {
				t.Fatal(err)
			}
		}
		out := captureStderr(t, run.fn)
		if strings.Contains(out, "FAILED") || strings.Contains(out, "withheld") {
			t.Fatalf("%s: a healthy store logged a failure:\n%s", run.kind, out)
		}
		if !strings.Contains(out, " sealed telephony item(s) for the session chooser") {
			t.Fatalf("%s: nothing staged; stderr:\n%s", run.kind, out)
		}
	}
}

func mustTelPub(t *testing.T, head string) string {
	t.Helper()
	v, _ := parseVault(getHeadBlob("s3", head))
	return v.TelPub
}

// The reply must still be written whatever the read does: the hand-off swallows the panic.
func TestTelHandoffNeverRethrows(t *testing.T) {
	for _, r := range []any{storeReadErr{io.ErrUnexpectedEOF}, "a string", 42} {
		captureStderr(t, func() { telHandoffPanic("roam-in", thName, r) })
	}
}
