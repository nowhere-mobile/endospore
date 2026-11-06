package main

import (
	"bufio"
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// NWP-20261125-19: the READ side's agent half of the next-sign-in skip notice (backlog row "`pushProfile`'s
// tombstone skips report "Saved" and the next login tells nobody (#119)", h50 #6). A sign-in under EITHER passphrase
// reads the notice; the shown record (an inference: its address is not stated by Chester) stops a second showing.

// skipNoticeShownWant computes the shown address INSIDE the test, never through skipNoticeShownRef, so a mutant of
// that function cannot move both sides.
func skipNoticeShownWant(dk []byte) string {
	mac := hmac.New(sha256.New, dk)
	mac.Write([]byte("nowhere-skip-notice-shown-v1"))
	return hex.EncodeToString(mac.Sum(nil))
}

// skipNoticeMinute is the notice minute the fixture's clock writes, in unix seconds.
func skipNoticeMinute() int64 { return skipNoticeClock.Unix() / 60 * 60 }

// skipNoticeReadFix is the fixture after the skip: a passphrase change on phone A, then a bare push on phone B that
// takes the tombstone exit and writes the notice.
func skipNoticeReadFix(t *testing.T, name string) *skipNoticeFix {
	t.Helper()
	f := newSkipNoticeFix(t, name)
	f.rotate(t)
	if out := f.push(t, f.name); !strings.Contains(out, "push: skip notice written") {
		t.Fatalf("setup: the skip did not write the notice:\n%s", out)
	}
	return f
}

// shownTime opens the stored shown record with the DK in the test; ok=false when there is none.
func (f *skipNoticeFix) shownTime(t *testing.T) (int64, bool) {
	t.Helper()
	val, ok := f.s.ref(skipNoticeShownWant(f.dk0))
	if !ok {
		return 0, false
	}
	pt, ok := unwrap(f.dk0, strings.TrimSpace(val))
	if !ok {
		t.Fatal("the shown record does not open under the profile DK")
	}
	var m map[string]any
	if err := json.Unmarshal(pt, &m); err != nil {
		t.Fatalf("the shown record is not JSON: %v", err)
	}
	if len(m) != 1 {
		t.Fatalf("the shown record must hold only its time; got %v", m)
	}
	tm, isNum := m["time"].(float64)
	if !isNum {
		t.Fatalf("the shown record's time is not a number: %v", m)
	}
	return int64(tm), true
}

func TestSkipNoticeReadAfterRotation(t *testing.T) {
	f := skipNoticeReadFix(t, "skn-r1")
	rec, show, err := readSkipNotice(f.base, f.name, f.newp, nil)
	if err != nil {
		t.Fatalf("readSkipNotice under the new passphrase: %v", err)
	}
	if !show {
		t.Fatal("a notice with no shown record was not shown")
	}
	if rec.Phone != skipNoticeLabel || rec.Time != skipNoticeMinute() {
		t.Fatalf("want {%q, %d}; got {%q, %d}", skipNoticeLabel, skipNoticeMinute(), rec.Phone, rec.Time)
	}
}

func TestSkipNoticeReadShownOnce(t *testing.T) {
	f := skipNoticeReadFix(t, "skn-r2")
	T := skipNoticeMinute()
	if err := markSkipNoticeShown(f.base, f.name, f.newp, nil, T); err != nil {
		t.Fatalf("markSkipNoticeShown(T): %v", err)
	}
	if got, ok := f.shownTime(t); !ok || got != T {
		t.Fatalf("the shown record holds %d (present=%v), want %d", got, ok, T)
	}
	if _, show, err := readSkipNotice(f.base, f.name, f.newp, nil); err != nil || show {
		t.Fatalf("after the mark: show=%v err=%v, want show false", show, err)
	}

	// A later skip writes a later notice: it shows again.
	skipNoticeNow = func() time.Time { return skipNoticeClock.Add(60 * time.Second) }
	f.push(t, f.name)
	rec, show, err := readSkipNotice(f.base, f.name, f.newp, nil)
	if err != nil || !show || rec.Time != T+60 {
		t.Fatalf("a later notice: show=%v time=%d err=%v, want show true at %d", show, rec.Time, err, T+60)
	}

	// Mark the later one, then the earlier one: the later time stays.
	if err := markSkipNoticeShown(f.base, f.name, f.newp, nil, T+60); err != nil {
		t.Fatalf("markSkipNoticeShown(T+60): %v", err)
	}
	if err := markSkipNoticeShown(f.base, f.name, f.newp, nil, T); err != nil {
		t.Fatalf("markSkipNoticeShown(T) after T+60: %v", err)
	}
	if got, _ := f.shownTime(t); got != T+60 {
		t.Fatalf("marking an earlier time lowered the shown record to %d, want %d", got, T+60)
	}
	if _, show, err := readSkipNotice(f.base, f.name, f.newp, nil); err != nil || show {
		t.Fatalf("after marking T+60 then T: show=%v err=%v, want show false", show, err)
	}
}

func TestSkipNoticeReadAbsentAndForeign(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-r3")
	f.rotate(t) // no push: no notice
	if _, ok := f.s.ref(skipNoticeWant(f.dk0)); ok {
		t.Fatal("setup: a notice exists with no skip")
	}
	if _, show, err := readSkipNotice(f.base, f.name, f.newp, nil); err != nil || show {
		t.Fatalf("no notice: show=%v err=%v, want show false and no error", show, err)
	}

	other := sha256.Sum256([]byte("another profile's key"))
	js, _ := json.Marshal(skipNoticeRecord{Phone: skipNoticeLabel, Time: skipNoticeMinute()})
	putRef(f.base, skipNoticeWant(f.dk0), base64.StdEncoding.EncodeToString(seal(other[:], js)))
	if _, show, err := readSkipNotice(f.base, f.name, f.newp, nil); err == nil || show {
		t.Fatalf("a notice sealed under another key: show=%v err=%v, want an error and show false", show, err)
	}
	putRef(f.base, skipNoticeWant(f.dk0), base64.StdEncoding.EncodeToString(seal(f.dk0, []byte("not json"))))
	if _, show, err := readSkipNotice(f.base, f.name, f.newp, nil); err == nil || show {
		t.Fatalf("a notice that does not parse: show=%v err=%v, want an error and show false", show, err)
	}
}

// skipNoticeVerbDrive runs h on a REAL unix socket (net.Pipe cannot half-close): the client writes req, closes its
// write side so a ReadString past req returns io.EOF, and the trimmed reply comes back. The socket dir is short
// (a t.TempDir() path can pass the 108-byte sun_path limit). The 20 s is a hang guard, not a timing claim.
func skipNoticeVerbDrive(t *testing.T, req string, h func(c net.Conn, r *bufio.Reader)) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "sn")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	l, err := net.Listen("unix", filepath.Join(dir, "s"))
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	served := make(chan struct{})
	go func() {
		defer close(served)
		c, err := l.Accept()
		if err != nil {
			return
		}
		h(c, bufio.NewReader(c))
		c.Close()
	}()
	cli, err := net.Dial("unix", filepath.Join(dir, "s"))
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	if _, err := cli.Write([]byte(req)); err != nil {
		t.Fatal(err)
	}
	if err := cli.(*net.UnixConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- string(b)
	}()
	select {
	case got := <-reply:
		<-served
		return strings.TrimSpace(got)
	case <-time.After(20 * time.Second):
		t.Fatalf("no reply to %q", req)
		return ""
	}
}

func TestSkipNoticeReadVerbsScoped(t *testing.T) {
	f := skipNoticeReadFix(t, "skn-r4")
	T := skipNoticeMinute()
	dest := t.TempDir()
	if err := writeRoamSession(dest, f.name, f.newp, "10", "", true); err != nil {
		t.Fatal(err)
	}
	oldPeer := sessionPeerUID
	t.Cleanup(func() { sessionPeerUID = oldPeer })
	asUser := func(u int) { sessionPeerUID = func(net.Conn) int { return u*100000 + 10123 } }
	get := func() string {
		return skipNoticeVerbDrive(t, "", func(c net.Conn, _ *bufio.Reader) { handleGetSkipNotice(c, dest, f.base) })
	}
	shown := func(req string) string {
		return skipNoticeVerbDrive(t, req, func(c net.Conn, r *bufio.Reader) { handleSkipNoticeShown(c, r, dest, f.base) })
	}
	unchanged := func(what string, refs0 map[string]string) {
		t.Helper()
		if refs1, _ := f.s.snapshot(); !reflect.DeepEqual(refs0, refs1) {
			t.Fatalf("%s: a refused verb wrote to the store", what)
		}
	}
	tline := strconv.FormatInt(T, 10)

	// (a) an app of another Android user.
	asUser(11)
	refs0, _ := f.s.snapshot()
	if got := get(); got != "NONE" {
		t.Fatalf("another user's GET-SKIP-NOTICE: %q, want NONE", got)
	}
	if got := shown(tline + "\n"); got != "ERR" {
		t.Fatalf("another user's SKIP-NOTICE-SHOWN: %q, want ERR", got)
	}
	unchanged("another user", refs0)

	// (b) the session's own user.
	asUser(10)
	if got, want := get(), "NOTICE "+skipNoticeLabel+"\t"+tline; got != want {
		t.Fatalf("the session's GET-SKIP-NOTICE: %q, want %q", got, want)
	}

	// (c) a throwaway session.
	lp := filepath.Join(dest, ".localsession")
	if err := os.WriteFile(lp, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := get(); got != "NONE" {
		t.Fatalf("a throwaway's GET-SKIP-NOTICE: %q, want NONE", got)
	}
	if got := shown(tline + "\n"); got != "ERR" {
		t.Fatalf("a throwaway's SKIP-NOTICE-SHOWN: %q, want ERR", got)
	}
	unchanged("a throwaway", refs0)
	os.Remove(lp)

	// (d) the session's own user, but the time line is cut or not a number: nothing is written.
	for _, req := range []string{tline, "abc\n", "\n", "-60\n"} {
		if got := shown(req); got != "ERR" {
			t.Fatalf("SKIP-NOTICE-SHOWN %q: %q, want ERR", req, got)
		}
		unchanged("SKIP-NOTICE-SHOWN "+strconv.Quote(req), refs0)
	}

	// The whole line marks it shown, and GET then answers NONE.
	if got := shown(tline + "\n"); got != "OK" {
		t.Fatalf("SKIP-NOTICE-SHOWN %s: %q, want OK", tline, got)
	}
	if got, _ := f.shownTime(t); got != T {
		t.Fatalf("SKIP-NOTICE-SHOWN stored %d, want %d", got, T)
	}
	if got := get(); got != "NONE" {
		t.Fatalf("GET-SKIP-NOTICE after SKIP-NOTICE-SHOWN: %q, want NONE", got)
	}

	// (e) the dispatch arms: complete requests, no session -> NONE / ERR (net.Pipe never half-closes).
	if got := driveLogin(t, t.TempDir(), "GET-SKIP-NOTICE\n"); got != "NONE" {
		t.Fatalf("handleLogin GET-SKIP-NOTICE with no session: %q, want NONE", got)
	}
	if got := driveLogin(t, t.TempDir(), "SKIP-NOTICE-SHOWN\n60\n"); got != "ERR" {
		t.Fatalf("handleLogin SKIP-NOTICE-SHOWN with no session: %q, want ERR", got)
	}
}

func TestSkipNoticeReadLabelOneLine(t *testing.T) {
	f := newSkipNoticeFix(t, "skn-r4f")
	f.rotate(t)
	T := skipNoticeMinute()
	// deviceLabel() refuses a label with a tab or a newline, so a push cannot write one: plant the record.
	js, _ := json.Marshal(map[string]any{"phone": "A\tB\nC\x7f", "time": T})
	putRef(f.base, skipNoticeWant(f.dk0), base64.StdEncoding.EncodeToString(seal(f.dk0, js)))
	dest := t.TempDir()
	if err := writeRoamSession(dest, f.name, f.newp, "10", "", true); err != nil {
		t.Fatal(err)
	}
	oldPeer := sessionPeerUID
	t.Cleanup(func() { sessionPeerUID = oldPeer })
	sessionPeerUID = func(net.Conn) int { return 10*100000 + 10123 }
	got := skipNoticeVerbDrive(t, "", func(c net.Conn, _ *bufio.Reader) { handleGetSkipNotice(c, dest, f.base) })
	if want := "NOTICE ABC\t" + strconv.FormatInt(T, 10); got != want || strings.Count(got, "\t") != 1 {
		t.Fatalf("GET-SKIP-NOTICE with a control-laden label: %q, want %q", got, want)
	}
}

func TestSkipNoticeReadShownLeavesNotice(t *testing.T) {
	f := skipNoticeReadFix(t, "skn-r5")
	want := skipNoticeWant(f.dk0)
	before, ok := f.s.ref(want)
	if !ok {
		t.Fatal("setup: no notice")
	}
	if err := markSkipNoticeShown(f.base, f.name, f.newp, nil, skipNoticeMinute()); err != nil {
		t.Fatalf("markSkipNoticeShown: %v", err)
	}
	if after, ok := f.s.ref(want); !ok || after != before {
		t.Fatal("the shown write changed the notice's ref")
	}
	sv, ok := f.s.ref(skipNoticeShownWant(f.dk0))
	if !ok || sv == before {
		t.Fatalf("no distinct shown record at hex(HMAC(dk, %q))", "nowhere-skip-notice-shown-v1")
	}
	rec, show, err := readSkipNotice(f.base, f.name, f.newp, nil)
	if err != nil || show || rec.Phone != skipNoticeLabel || rec.Time != skipNoticeMinute() {
		t.Fatalf("after the mark: rec=%+v show=%v err=%v, want the notice back with show false", rec, show, err)
	}
}

func TestSkipNoticeReadCapMode(t *testing.T) {
	f := skipNoticeReadFix(t, "skn-r6")
	T := skipNoticeMinute()
	g := newSkipNoticeGateway(t)
	refs, _ := f.s.snapshot()
	f.s.mu.Lock()
	for k, v := range refs {
		g.objs["ref/"+k] = []byte(v)
	}
	for k, b := range f.s.blobs {
		g.objs["blob/"+k] = append([]byte(nil), b...)
	}
	f.s.mu.Unlock()
	t.Setenv("GATEWAY_URL", g.srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Cleanup(func() { capReadCache = map[string]capEntry{} })
	t.Cleanup(func() { capBracketLeakCheck(t) })
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	if err := saveWallet(wpath, &Wallet{Tokens: []Token{{Denom: "1GBmo", Nonce: "snr1", Exp: 1 << 62, Sig: "sig"},
		{Denom: "1GBmo", Nonce: "snr2", Exp: 1 << 62, Sig: "sig"}}}); err != nil {
		t.Fatal(err)
	}
	wallet0, err := os.ReadFile(wpath)
	if err != nil {
		t.Fatal(err)
	}

	if rec, show, err := readSkipNotice("s3", f.name, f.newp, nil); err != nil || !show || rec.Time != T {
		t.Fatalf("cap read: rec=%+v show=%v err=%v, want the notice shown", rec, show, err)
	}
	g.reset()
	if err := markSkipNoticeShown("s3", f.name, f.newp, nil, T); err != nil { // not under recover: a panic fails the test
		t.Fatalf("cap mark: %v", err)
	}
	if !g.has("ref/" + skipNoticeShownWant(f.dk0)) {
		t.Fatal("cap mark: the shown record did not land at the gateway")
	}
	g.mu.Lock()
	leases := append([]leaseReq(nil), g.leases...)
	g.mu.Unlock()
	if len(leases) == 0 {
		t.Fatal("cap mark: no lease")
	}
	holder := profileRefV2(f.name, f.newp)
	for _, l := range leases {
		if l.Profile != holder || len(l.Tokens)+len(l.BlindTokens) != 0 {
			t.Fatalf("cap mark: not a token-free lease under the current identity: profile=%v tokens=%d",
				l.Profile == holder, len(l.Tokens)+len(l.BlindTokens))
		}
	}
	if w, _ := os.ReadFile(wpath); !bytes.Equal(w, wallet0) {
		t.Fatal("cap mark: the wallet changed")
	}
	capReadCache = map[string]capEntry{}
	if _, show, err := readSkipNotice("s3", f.name, f.newp, nil); err != nil || show {
		t.Fatalf("cap read after the mark: show=%v err=%v, want show false", show, err)
	}

	// The gateway refuses the lease: an error, no panic, nothing landed, no bracket left open.
	g.mu.Lock()
	g.leaseCode = http.StatusForbidden
	shown0 := append([]byte(nil), g.objs["ref/"+skipNoticeShownWant(f.dk0)]...)
	g.mu.Unlock()
	if err := markSkipNoticeShown("s3", f.name, f.newp, nil, T+60); err == nil {
		t.Fatal("cap mark with the lease refused: no error")
	}
	g.mu.Lock()
	shown1 := g.objs["ref/"+skipNoticeShownWant(f.dk0)]
	g.mu.Unlock()
	if !bytes.Equal(shown0, shown1) {
		t.Fatal("cap mark with the lease refused: the shown record changed")
	}
	capBracketLeakCheck(t)
}
