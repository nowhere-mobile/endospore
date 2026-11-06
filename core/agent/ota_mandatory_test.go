package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode"
)

// NWP-20261011-05: mandatory updates. These pin the signed metadata (nothing unverified is believed), the deadline
// rule (7 days critical, 30 mandatory, from the signed publication date, UTC), the OTA-STATUS lines the chooser reads,
// the walk that keeps an older mandatory release binding under a newer ordinary one, the "Sign out & install" request,
// and that every committed flag file is valid.

// testReleaseKey makes a throwaway release keypair; the public half in the base64url form `release` prints.
func testReleaseKey(t *testing.T) (pub string, priv ed25519.PrivateKey) {
	t.Helper()
	p, k, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(p), k
}

func signRelease(priv ed25519.PrivateKey, manifest string) string {
	return base64.RawURLEncoding.EncodeToString(ed25519.Sign(priv, []byte(manifest)))
}

// manifestWith builds an installer manifest the way make-web-package.sh does, with the given "ota" object (raw JSON,
// "" = none at all).
func manifestWith(dev, ota string) string {
	m := `{
  "edition": "endospore",
  "device": {"product": "` + dev + `", "label": "Pixel", "codename": "` + dev + `"},
  "version": "2026.10.12",
  "build": "2026101201",
  "images": [{"partition": "factory", "url": "/x", "size": 1, "sha256": "ab"}],
  "notes": "signed release — the page verifies the .sig"`
	if ota != "" {
		m += `,
  "ota": ` + ota
	}
	return m + "\n}\n"
}

const otaMand = `{"version": "0.5.45", "severity": "mandatory", "published": "2026-10-12", "reason": "Saves now go through a new check on our servers.", "consequence": "Once the servers require it, this phone cannot save changes or sign out."}`

func TestReleasePubKeyIsTheInstallPageKey(t *testing.T) {
	b, err := decodeB64URL(releasePubKey)
	if err != nil || len(b) != ed25519.PublicKeySize {
		t.Fatalf("releasePubKey does not decode to an ed25519 key: %d bytes, %v", len(b), err)
	}
	if !strings.HasPrefix(releasePubKey, "9oh6") || !strings.HasSuffix(releasePubKey, "T5Y") {
		t.Error("releasePubKey is not the key every release has been verified against (9oh6…T5Y, worklog.md)")
	}
	if otaReleaseKey != releasePubKey {
		t.Error("the phone checks fetched metadata against a key other than the release key")
	}
}

func TestVerifyOtaReleaseIsSignatureGated(t *testing.T) {
	pub, priv := testReleaseKey(t)
	otherPub, otherPriv := testReleaseKey(t)
	_ = otherPub
	man := manifestWith("lynx", otaMand)
	r, err := verifyOtaRelease(pub, []byte(man), signRelease(priv, man), "lynx", "0.5.45")
	if err != nil || !r.mandatory() || r.Reason != "Saves now go through a new check on our servers." ||
		r.Consequence != "Once the servers require it, this phone cannot save changes or sign out." {
		t.Fatalf("a correctly signed mandatory manifest: %+v, %v", r, err)
	}
	if _, err := verifyOtaRelease(pub, []byte(man), signRelease(priv, man)+"=", "lynx", "0.5.45"); err != nil {
		t.Errorf("a padded base64url signature was refused: %v", err)
	}
	for why, sig := range map[string]string{
		"no signature":               "",
		"signed by another key":      signRelease(otherPriv, man),
		"signature over other bytes": signRelease(priv, strings.Replace(man, "mandatory", "critical", 1)),
		"not base64":                 "!!!",
		"truncated":                  signRelease(priv, man)[:40],
	} {
		if r, err := verifyOtaRelease(pub, []byte(man), sig, "lynx", "0.5.45"); err == nil || r != nil {
			t.Errorf("%s: accepted (%+v)", why, r)
		}
	}
	// One flipped byte of the signed bytes: the text a phone would show must not be editable after signing.
	tampered := strings.Replace(man, "cannot save", "can't save", 1)
	if _, err := verifyOtaRelease(pub, []byte(tampered), signRelease(priv, man), "lynx", "0.5.45"); err == nil {
		t.Error("a manifest edited after signing was accepted")
	}
	if _, err := verifyOtaRelease("", []byte(man), signRelease(priv, man), "lynx", "0.5.45"); err == nil {
		t.Error("an empty key accepted a signature")
	}
	big := manifestWith("lynx", otaMand) + strings.Repeat(" ", otaReleaseMaxBytes)
	if _, err := verifyOtaRelease(pub, []byte(big), signRelease(priv, big), "lynx", "0.5.45"); err == nil {
		t.Error("an oversized manifest was accepted")
	}
}

func TestOtaReleaseFieldsFailSafe(t *testing.T) {
	ok := func(sev, extra string) string {
		return `{"version": "0.5.45", "severity": "` + sev + `", "published": "2026-10-12"` + extra + `}`
	}
	texts := `, "reason": "A reason.", "consequence": "A consequence."`
	if r, err := otaReleaseFields([]byte(manifestWith("lynx", ok("none", ""))), "lynx", "0.5.45"); err != nil || r.mandatory() {
		t.Errorf("an ordinary release: %+v, %v", r, err)
	}
	if r, err := otaReleaseFields([]byte(manifestWith("lynx", `{"version": "0.5.45", "severity": "none"}`)), "lynx", "0.5.45"); err != nil || r.mandatory() {
		t.Errorf("an ordinary release needs no date: %+v, %v", r, err)
	}
	if r, err := otaReleaseFields([]byte(manifestWith("lynx", ok("critical", texts))), "lynx", "0.5.45"); err != nil || r.Severity != "critical" {
		t.Errorf("a critical release: %+v, %v", r, err)
	}
	long := strings.Repeat("x", otaMandatoryTextMax+1)
	for why, m := range map[string]string{
		"no ota object":           manifestWith("lynx", ""),
		"another device":          manifestWith("tegu", ok("mandatory", texts)),
		"not JSON":                "{",
		"ota is not an object":    manifestWith("lynx", `"mandatory"`),
		"another version":         manifestWith("lynx", strings.Replace(ok("mandatory", texts), "0.5.45", "0.5.46", 1)),
		"no version":              manifestWith("lynx", `{"severity": "mandatory", "published": "2026-10-12"`+texts+`}`),
		"unknown severity":        manifestWith("lynx", ok("urgent", texts)),
		"severity in caps":        manifestWith("lynx", ok("MANDATORY", texts)),
		"no published date":       manifestWith("lynx", `{"version": "0.5.45", "severity": "mandatory"`+texts+`}`),
		"date with a time":        manifestWith("lynx", strings.Replace(ok("mandatory", texts), "2026-10-12", "2026-10-12T10:00:00Z", 1)),
		"date in another order":   manifestWith("lynx", strings.Replace(ok("mandatory", texts), "2026-10-12", "12-10-2026", 1)),
		"no reason":               manifestWith("lynx", ok("mandatory", `, "consequence": "A consequence."`)),
		"no consequence":          manifestWith("lynx", ok("mandatory", `, "reason": "A reason."`)),
		"blank reason":            manifestWith("lynx", ok("mandatory", `, "reason": "   ", "consequence": "A consequence."`)),
		"two-line reason":         manifestWith("lynx", ok("mandatory", `, "reason": "A\nB", "consequence": "A consequence."`)),
		"over-long consequence":   manifestWith("lynx", ok("mandatory", `, "reason": "A reason.", "consequence": "`+long+`"`)),
		"a security claim":        manifestWith("lynx", ok("critical", `, "reason": "Fixes a security flaw.", "consequence": "A consequence."`)),
		"a privacy claim":         manifestWith("lynx", ok("mandatory", `, "reason": "A reason.", "consequence": "Your privacy is at risk."`)),
		"padded reason":           manifestWith("lynx", ok("mandatory", `, "reason": " A reason.", "consequence": "A consequence."`)),
		"a control character":     manifestWith("lynx", ok("mandatory", `, "reason": "A\u0007reason.", "consequence": "A consequence."`)),
		"a version that is words": manifestWith("lynx", strings.Replace(ok("mandatory", texts), `"0.5.45"`, `"latest"`, 1)),
	} {
		if r, err := otaReleaseFields([]byte(m), "lynx", "0.5.45"); err == nil {
			t.Errorf("%s: accepted (%+v)", why, r)
		}
	}
}

func TestOtaDeadlineArithmetic(t *testing.T) {
	day := func(s string) time.Time {
		d, err := time.ParseInLocation("2006-01-02", s, time.UTC)
		if err != nil {
			t.Fatal(err)
		}
		return d
	}
	at := func(s string) time.Time {
		v, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	for _, c := range []struct {
		sev, published, deadline string
	}{
		{"critical", "2026-10-12", "2026-10-20T00:00:00Z"},  // the end of D+7, UTC
		{"mandatory", "2026-10-12", "2026-11-12T00:00:00Z"}, // the end of D+30: 31 days after D's midnight
		{"mandatory", "2026-12-15", "2027-01-15T00:00:00Z"}, // across a year
		{"critical", "2028-02-25", "2028-03-04T00:00:00Z"},  // across a leap day
		{"mandatory", "2026-03-01", "2026-04-01T00:00:00Z"}, // across a DST change elsewhere: UTC days have none
	} {
		r := &otaRelease{Severity: c.sev, Published: day(c.published)}
		if got := r.deadline(); !got.Equal(at(c.deadline)) {
			t.Errorf("%s published %s: deadline %s, want %s", c.sev, c.published, got.UTC().Format(time.RFC3339), c.deadline)
		}
		d := at(c.deadline)
		if r.overdue(d.Add(-time.Second)) {
			t.Errorf("%s %s: overdue a second before the deadline", c.sev, c.published)
		}
		if !r.overdue(d) || !r.overdue(d.Add(48*time.Hour)) {
			t.Errorf("%s %s: not overdue at or after the deadline", c.sev, c.published)
		}
	}
	// The date is a UTC date whatever the phone's zone: parsing in a far-east zone must not move the deadline.
	saved := time.Local
	time.Local = time.FixedZone("UTC+14", 14*3600)
	t.Cleanup(func() { time.Local = saved })
	pub, priv := testReleaseKey(t)
	man := manifestWith("lynx", otaMand)
	r, err := verifyOtaRelease(pub, []byte(man), signRelease(priv, man), "lynx", "0.5.45")
	if err != nil {
		t.Fatal(err)
	}
	if !r.deadline().Equal(at("2026-11-12T00:00:00Z")) {
		t.Errorf("the phone's zone moved the deadline: %s", r.deadline().UTC())
	}
	// The same instant seen from a zone 26 hours away is the same verdict.
	inst := at("2026-11-11T23:59:59Z")
	if r.overdue(inst.In(time.FixedZone("UTC-12", -12*3600))) || r.overdue(inst.In(time.Local)) {
		t.Error("overdue depends on the zone the instant is expressed in")
	}
	if (&otaRelease{Severity: "none", Published: day("2020-01-01")}).overdue(at("2030-01-01T00:00:00Z")) {
		t.Error("an ordinary release is never overdue")
	}
}

func TestOtaReleaseEnvelope(t *testing.T) {
	man := manifestWith("lynx", otaMand)
	env := otaReleaseEnvelope([]byte(man), "c2ln\n")
	sig, m, err := openOtaReleaseEnvelope(env)
	if err != nil || sig != "c2ln" || string(m) != man {
		t.Fatalf("round trip: %q %q %v", sig, m, err)
	}
	for why, b := range map[string]string{
		"no magic":   "c2ln\n" + man,
		"wrong vers": "nowhere-ota-release 2\nc2ln\n" + man,
		"truncated":  otaReleaseMagic + "\nc2ln",
	} {
		if _, _, err := openOtaReleaseEnvelope([]byte(b)); err == nil {
			t.Errorf("%s: opened", why)
		}
	}
}

// fetchOtaRelease reads the ref, then the blob, refuses a blob that does not hash to its name, and believes only a
// signature by the release key.
func TestFetchOtaReleaseVerifies(t *testing.T) {
	pub, priv := testReleaseKey(t)
	saved := otaReleaseKey
	otaReleaseKey = pub
	t.Cleanup(func() { otaReleaseKey = saved })
	_, otherPriv := testReleaseKey(t)

	man := manifestWith("lynx", otaMand)
	blobs := map[string][]byte{}
	refs := map[string]string{}
	put := func(ref string, body []byte, rename bool) {
		sum := sha256.Sum256(body)
		h := hex.EncodeToString(sum[:])
		if rename {
			// Flip the first hex digit, so the name is never the blob's own hash. A fixed "00" prefix WAS the hash
			// for one blob in 256, and testReleaseKey's key, so the envelope, is random per run (NWP-20261027-27).
			if h[0] == '0' {
				h = "1" + h[1:]
			} else {
				h = "0" + h[1:]
			}
		}
		blobs[h], refs[ref] = body, h
	}
	put("ota/lynx/release-0.5.45", otaReleaseEnvelope([]byte(man), signRelease(priv, man)), false)
	put("ota/lynx/release-0.5.46", otaReleaseEnvelope([]byte(man), signRelease(priv, man)), false) // 0.5.45's, filed under 0.5.46
	put("ota/tegu/release-0.5.45", otaReleaseEnvelope([]byte(man), signRelease(otherPriv, man)), false)
	put("ota/pixel/release-0.5.45", otaReleaseEnvelope([]byte(manifestWith("pixel", otaMand)), signRelease(priv, manifestWith("pixel", otaMand))), true)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ref, ok := strings.CutPrefix(r.URL.Path, "/ref/"); ok {
			if v, ok := refs[ref]; ok {
				w.Write([]byte(v))
				return
			}
		}
		if k, ok := strings.CutPrefix(r.URL.Path, "/blob/"); ok {
			if v, ok := blobs[k]; ok {
				w.Write(v)
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()
	if r, err := fetchOtaRelease(srv.URL, "lynx", "0.5.45"); err != nil || !r.mandatory() {
		t.Fatalf("published signed metadata: %+v, %v", r, err)
	}
	if r, err := fetchOtaRelease(srv.URL, "lynx", "0.5.44"); r != nil || err != nil {
		t.Errorf("nothing published must be (nil, nil): %+v, %v", r, err)
	}
	if r, err := fetchOtaRelease(srv.URL, "lynx", "0.5.46"); err == nil || r != nil {
		t.Error("a signed manifest replayed under another version was believed")
	}
	if r, err := fetchOtaRelease(srv.URL, "tegu", "0.5.45"); err == nil || r != nil {
		t.Error("metadata signed by another key was believed")
	}
	if r, err := fetchOtaRelease(srv.URL, "pixel", "0.5.45"); err == nil || r != nil {
		t.Error("a blob that does not hash to its name was believed")
	}
}

func TestMostUrgentOtaRelease(t *testing.T) {
	d := func(s string) time.Time { v, _ := time.ParseInLocation("2006-01-02", s, time.UTC); return v }
	none := &otaRelease{Version: "0.5.47", Severity: "none", Published: d("2026-10-20")}
	m45 := &otaRelease{Version: "0.5.45", Severity: "mandatory", Published: d("2026-10-01")} // due 2026-11-01
	c46 := &otaRelease{Version: "0.5.46", Severity: "critical", Published: d("2026-10-20")}  // due 2026-10-28
	m46 := &otaRelease{Version: "0.5.46", Severity: "mandatory", Published: d("2026-09-28")} // due 2026-10-29
	if got := mostUrgentOtaRelease([]*otaRelease{none}); got != nil {
		t.Errorf("only ordinary releases: %+v", got)
	}
	if got := mostUrgentOtaRelease([]*otaRelease{none, m45}); got != m45 {
		t.Errorf("an older mandatory release under a newer ordinary one must still bind: %+v", got)
	}
	if got := mostUrgentOtaRelease([]*otaRelease{m45, c46}); got != c46 {
		t.Errorf("the deadline due first wins: %+v", got)
	}
	if got := mostUrgentOtaRelease([]*otaRelease{c46, m46}); got != c46 {
		t.Errorf("critical 10-28 before mandatory 10-29: %+v", got)
	}
	tie := &otaRelease{Version: "0.5.44", Severity: "mandatory", Published: d("2026-09-27")} // due 2026-10-28, same as c46
	if got := mostUrgentOtaRelease([]*otaRelease{tie, c46}); got != c46 {
		t.Errorf("on the same instant critical wins: %+v", got)
	}
	if got := mostUrgentOtaRelease(nil); got != nil {
		t.Error("nothing verified must be nothing mandatory")
	}
}

func TestOtaMandatoryVersionsCoversTheChain(t *testing.T) {
	chain := []*otaNotes{{Version: "0.5.47"}, {Version: "0.5.46"}, {Version: "0.5.45"}}
	if got := strings.Join(otaMandatoryVersions("0.5.47", chain), ","); got != "0.5.47,0.5.46,0.5.45" {
		t.Errorf("versions %s", got)
	}
	if got := strings.Join(otaMandatoryVersions("0.5.47", nil), ","); got != "0.5.47" {
		t.Errorf("no notes walk: the offered version is still checked, got %s", got)
	}
}

func resetOtaMand(t *testing.T) {
	saved := otaSeenPath
	otaSeenPath = filepath.Join(t.TempDir(), "ota-seen")
	t.Cleanup(func() {
		otaSeenPath = saved
		otaMandMu.Lock()
		otaMandOffered, otaMandBest, otaMandRetryAt = "", nil, time.Time{}
		otaMandMu.Unlock()
	})
}

func TestRefreshOtaMandatoryCachesAndRetries(t *testing.T) {
	resetOtaMand(t)
	d := func(s string) time.Time { v, _ := time.ParseInLocation("2006-01-02", s, time.UTC); return v }
	m45 := &otaRelease{Version: "0.5.45", Severity: "mandatory", Published: d("2026-10-01"), Reason: "R", Consequence: "C"}
	calls := 0
	fetch := func(v string) (*otaRelease, error) {
		calls++
		switch v {
		case "0.5.45":
			return m45, nil
		case "0.5.46":
			return nil, errors.New("offline")
		}
		return nil, nil
	}
	refreshOtaMandatory("s3", "0.5.47", []string{"0.5.47", "0.5.46", "0.5.45"}, true, fetch)
	if got := otaMandatoryFor("0.5.47"); got != m45 {
		t.Fatalf("what did verify must be used even when another fetch failed: %+v", got)
	}
	if otaMandatoryFor("0.5.48") != nil {
		t.Error("an answer for one offer was served for another")
	}
	otaMandMu.Lock()
	retryAt := otaMandRetryAt
	otaMandMu.Unlock()
	if d := time.Until(retryAt); d <= 0 || d > otaNotesRetry {
		t.Errorf("a walk with a failed fetch must schedule a retry within otaNotesRetry, got %v", d)
	}
	n := calls
	refreshOtaMandatory("s3", "0.5.47", []string{"0.5.47", "0.5.46", "0.5.45"}, true, fetch)
	if calls != n {
		t.Error("an incomplete walk was retried before otaNotesRetry")
	}
	otaMandMu.Lock()
	otaMandRetryAt = time.Now().Add(-time.Second)
	otaMandMu.Unlock()
	refreshOtaMandatory("s3", "0.5.47", []string{"0.5.47", "0.5.46", "0.5.45"}, true, fetch)
	if calls == n {
		t.Error("an incomplete walk was never retried")
	}
	// A complete walk is not repeated for the same offer.
	ok := func(v string) (*otaRelease, error) { calls++; return nil, nil }
	refreshOtaMandatory("s3", "0.5.50", []string{"0.5.50"}, true, ok)
	n = calls
	refreshOtaMandatory("s3", "0.5.50", []string{"0.5.50"}, true, ok)
	if calls != n {
		t.Error("a complete walk was repeated")
	}
	otaMandMu.Lock()
	complete := otaMandRetryAt.IsZero()
	otaMandMu.Unlock()
	if !complete {
		t.Error("a walk where every fetch answered scheduled a retry")
	}
	if otaMandatoryFor("0.5.50") != nil {
		t.Error("nothing published must be nothing mandatory")
	}
}

// Review finding 3: a notes walk that stopped short (a transient store error) gives a truncated version list. Every
// fetch on that list can succeed, and the answer must STILL be retried -- a mandatory release below the cut would
// otherwise go unseen until the offer changed. Once the walk completes, the retry finds it.
func TestRefreshOtaMandatoryRetriesATruncatedChain(t *testing.T) {
	resetOtaMand(t)
	d, _ := time.ParseInLocation("2006-01-02", "2026-10-01", time.UTC)
	m45 := &otaRelease{Version: "0.5.45", Severity: "mandatory", Published: d, Reason: "R", Consequence: "C"}
	fetch := func(v string) (*otaRelease, error) {
		if v == "0.5.45" {
			c := *m45
			return &c, nil
		}
		return nil, nil
	}
	// The walk got only 0.5.47 and 0.5.46 before failing: 0.5.45 is below the cut.
	refreshOtaMandatory("s3", "0.5.47", []string{"0.5.47", "0.5.46"}, false, fetch)
	if otaMandatoryFor("0.5.47") != nil {
		t.Fatal("nothing mandatory was in the truncated list")
	}
	otaMandMu.Lock()
	retry := otaMandRetryAt
	otaMandMu.Unlock()
	if retry.IsZero() {
		t.Fatal("a truncated walk was cached as complete -- the mandatory 0.5.45 below the cut would never be seen")
	}
	otaMandMu.Lock()
	otaMandRetryAt = time.Now().Add(-time.Second)
	otaMandMu.Unlock()
	refreshOtaMandatory("s3", "0.5.47", []string{"0.5.47", "0.5.46", "0.5.45"}, true, fetch)
	got := otaMandatoryFor("0.5.47")
	if got == nil || got.Version != "0.5.45" {
		t.Fatalf("the retried, complete walk did not find the mandatory release: %+v", got)
	}
	// And it was stamped first-seen now, on plain /data: the deadline counts from today, not the signed date.
	if got.FirstSeen.IsZero() || time.Since(got.FirstSeen) > time.Minute {
		t.Errorf("first-seen not recorded: %v", got.FirstSeen)
	}
	if b, err := os.ReadFile(otaSeenPath); err != nil || !strings.HasPrefix(string(b), "0.5.45 ") {
		t.Errorf("first-seen not persisted: %q %v", b, err)
	}
}

// Review finding 10: the release blob is read bounded -- an oversized object is refused, never held whole.
func TestFetchOtaReleaseRefusesAnOversizedBlob(t *testing.T) {
	big := append([]byte(otaReleaseMagic+"\nsig\n"), make([]byte, 4*otaReleaseEnvMax)...)
	sum := sha256.Sum256(big)
	h := hex.EncodeToString(sum[:])
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ref/ota/lynx/release-0.5.45":
			w.Write([]byte(h))
		case "/blob/" + h:
			w.Write(big)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	r, err := fetchOtaRelease(srv.URL, "lynx", "0.5.45")
	if err == nil || r != nil || !strings.Contains(err.Error(), "over") {
		t.Fatalf("an oversized blob: %+v, %v", r, err)
	}
	if b, ok := getBlobSoftMax(srv.URL, h, 100); !ok || len(b) != 100 {
		t.Errorf("the bounded read returned %d bytes, want exactly the 100 asked for", len(b))
	}
}

func TestOtaMandatoryLines(t *testing.T) {
	d, _ := time.ParseInLocation("2006-01-02", "2026-10-12", time.UTC)
	r := &otaRelease{Version: "0.5.45", Severity: "critical", Published: d, Reason: "Why it matters.", Consequence: "What breaks."}
	var b strings.Builder
	writeOtaMandatoryLines(&b, r, d.Add(24*time.Hour))
	want := "MANDATORY critical 1792454400 due\nREASON Why it matters.\nCONSEQUENCE What breaks.\n"
	if b.String() != want {
		t.Fatalf("lines:\n%q\nwant\n%q", b.String(), want)
	}
	b.Reset()
	writeOtaMandatoryLines(&b, r, time.Unix(1792454400, 0))
	if !strings.HasPrefix(b.String(), "MANDATORY critical 1792454400 overdue\n") {
		t.Errorf("at the deadline: %q", b.String())
	}
	b.Reset()
	writeOtaMandatoryLines(&b, nil, d)
	writeOtaMandatoryLines(&b, &otaRelease{Severity: "none"}, d)
	if b.String() != "" {
		t.Errorf("an ordinary or unverified update must add nothing: %q", b.String())
	}
}

func TestParseOtaMandatorySource(t *testing.T) {
	good := "version 0.5.45\nseverity critical\nreason A reason.\nconsequence A consequence.\n"
	r, err := parseOtaMandatorySource(good)
	if err != nil || r.Version != "0.5.45" || r.Severity != "critical" || r.Reason != "A reason." || r.Consequence != "A consequence." {
		t.Fatalf("good: %+v, %v", r, err)
	}
	if _, err := parseOtaMandatorySource(strings.ReplaceAll(good, "\n", "\r\n")); err != nil {
		t.Errorf("CRLF refused: %v", err)
	}
	for why, s := range map[string]string{
		"severity none":     strings.Replace(good, "critical", "none", 1),
		"unknown severity":  strings.Replace(good, "critical", "high", 1),
		"no reason line":    "version 0.5.45\nseverity critical\nconsequence A consequence.\n",
		"lines reordered":   "version 0.5.45\nseverity critical\nconsequence A consequence.\nreason A reason.\n",
		"an extra line":     good + "- a point\n",
		"bad version":       strings.Replace(good, "0.5.45", "next", 1),
		"empty reason":      strings.Replace(good, "reason A reason.", "reason ", 1),
		"claim in reason":   strings.Replace(good, "A reason.", "Keeps you safe.", 1),
		"over-long reason":  strings.Replace(good, "A reason.", strings.Repeat("y", otaMandatoryTextMax+1), 1),
		"tab in the reason": strings.Replace(good, "A reason.", "A\treason.", 1),
	} {
		if _, err := parseOtaMandatorySource(s); err == nil {
			t.Errorf("%s: accepted", why)
		}
	}
}

func TestOtaReleaseMatchesSource(t *testing.T) {
	src := &otaRelease{Version: "0.5.45", Severity: "mandatory", Reason: "R.", Consequence: "C."}
	signed := &otaRelease{Version: "0.5.45", Severity: "mandatory", Reason: "R.", Consequence: "C."}
	if err := otaReleaseMatchesSource(signed, src); err != nil {
		t.Errorf("agreeing: %v", err)
	}
	if err := otaReleaseMatchesSource(&otaRelease{Severity: "none"}, nil); err != nil {
		t.Errorf("an ordinary release with no file: %v", err)
	}
	for why, c := range map[string][2]*otaRelease{
		"flag committed, manifest built without it": {{Version: "0.5.45", Severity: "none"}, src},
		"manifest mandatory, no file committed":     {signed, nil},
		"severity differs":                          {{Version: "0.5.45", Severity: "critical", Reason: "R.", Consequence: "C."}, src},
		"reason edited after signing":               {{Version: "0.5.45", Severity: "mandatory", Reason: "R!", Consequence: "C."}, src},
		"consequence differs":                       {{Version: "0.5.45", Severity: "mandatory", Reason: "R.", Consequence: "C!"}, src},
	} {
		if err := otaReleaseMatchesSource(c[0], c[1]); err == nil {
			t.Errorf("%s: accepted", why)
		}
	}
}

func TestOtaAfterLogoff(t *testing.T) {
	t.Cleanup(func() { setOtaAfterLogoff("0", time.Now(), false) })
	now := time.Now() // carries a monotonic reading, as the daemon's stamp does
	const n1, n2 = "0f1e2d3c-aaaa-bbbb", "99887766-cccc-dddd"
	set := func(line string, inFlight bool) {
		t.Helper()
		if err := setOtaAfterLogoff(line, now, inFlight); err != nil {
			t.Fatalf("%q: %v", line, err)
		}
	}
	if otaAfterLogoffPending(11, now) {
		t.Fatal("no request was made")
	}
	set("1 11 "+n1, false)
	if otaAfterLogoffPending(12, now) {
		t.Error("a request by user 11 counted at the reap of user 12 (an orphan sweep, another session)")
	}
	if !otaAfterLogoffPending(11, now.Add(10*time.Minute)) {
		t.Fatal("user 11's request was not pending at user 11's reap -- and must have survived user 12's")
	}
	if !otaAfterLogoffPending(11, now.Add(10*time.Minute)) {
		t.Error("asking consumed the request: a RETRY must keep it")
	}
	if consumeOtaAfterLogoff(12) {
		t.Error("consuming for user 12 reported a request user 12 never made")
	}
	if !otaAfterLogoffPending(11, now) {
		t.Error("consuming for user 12 removed user 11's request")
	}
	if !consumeOtaAfterLogoff(11) {
		t.Error("consuming user 11's request reported nothing consumed -- the install would never start")
	}
	if otaAfterLogoffPending(11, now) {
		t.Error("a consumed request was still pending")
	}
	// Round 4, F2: a withdrawal between the pending check and the consume must win -- consume reports false, and the
	// handler then starts nothing.
	set("1 11 "+n1, false)
	if !otaAfterLogoffPending(11, now) {
		t.Fatal("setup")
	}
	set("0 "+n1, false) // the requesting Profile withdraws, after the gate's pending check
	if consumeOtaAfterLogoff(11) {
		t.Error("a request withdrawn after the pending check was consumed -- the install would overrun the withdrawal")
	}
	if consumeOtaAfterLogoff(0) {
		t.Error("an empty slot was consumed for uid 0")
	}
	set("1 11 "+n1, false)
	set("0 "+n2, false) // another Profile instance's withdrawal
	if !otaAfterLogoffPending(11, now) {
		t.Error("a withdrawal with another instance's nonce removed this one's request")
	}
	set("0 "+n1, true) // the requesting Profile: its sign-out was refused (its own nonce wins, in flight or not)
	if otaAfterLogoffPending(11, now) {
		t.Error("a request withdrawn by its own Profile (a refused sign-out) was still pending")
	}
	set("1 11 "+n1, false)
	set("0", true) // a Profile RE-CREATED while the sign-out is in flight (a rotation)
	if !otaAfterLogoffPending(11, now) {
		t.Error("a Profile re-created mid sign-out cancelled the install that sign-out was about to deliver")
	}
	set("0", false) // a fresh Profile screen with no sign-out in flight: whatever an earlier one left is stale
	if otaAfterLogoffPending(11, now) {
		t.Error("a request left by an earlier Profile survived a fresh Profile's withdrawal")
	}
	set("1 11 "+n1, false)
	if otaAfterLogoffPending(11, now.Add(otaAfterLogoffTTL)) {
		t.Error("a request past its TTL was pending")
	}
	if otaAfterLogoffPending(11, now) {
		t.Error("an expired request was not cleared")
	}
	set("1 11 "+n1, false)
	if otaAfterLogoffPending(11, now.Add(-time.Minute)) {
		t.Error("a request stamped after now was pending")
	}
	// The TTL is monotonic: the stamp keeps its monotonic reading (Round(0) would strip it, and Sub would then follow
	// the wall clock -- a clock change could expire or revive a request).
	set("1 11 "+n1, false)
	if !strings.Contains(now.String(), "m=") {
		t.Fatal("the test's clock has no monotonic reading; it cannot check the TTL is monotonic")
	}
	otaAfterLogoffMu.Lock()
	hasMono := strings.Contains(otaAfterLogoffCur.at.String(), "m=")
	otaAfterLogoffMu.Unlock()
	if !hasMono {
		t.Error("the request's stamp lost its monotonic reading -- the TTL would follow wall-clock changes")
	}
	for _, bad := range []string{"", "1", "1 11", "1 x " + n1, "1 0 " + n1, "1 -3 " + n1, "1 11 NOT-HEX!", "1 11 ab", "2", "0 a b", "yes"} {
		if err := setOtaAfterLogoff(bad, now, false); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
	if !otaAfterLogoffPending(11, now) {
		t.Error("a malformed line changed the pending request")
	}
}

// The request must come FROM the user it names: SO_PEERCRED uid / 100000. Withdrawals need no check.
func TestOtaAfterLogoffCaller(t *testing.T) {
	const n = "0f1e2d3c-aaaa-bbbb"
	if err := otaAfterLogoffCaller("1 11 "+n, 11*100000+10123); err != nil {
		t.Errorf("user 11's own Profile: %v", err)
	}
	for why, c := range map[string]struct {
		line string
		peer int
	}{
		"another user's Profile":     {"1 11 " + n, 12*100000 + 10123},
		"the gate claiming user 11":  {"1 11 " + n, 10123},
		"an unknown peer":            {"1 11 " + n, -1},
		"a uid that is not a number": {"1 x " + n, 11*100000 + 10123},
		"a short request":            {"1 11", 11*100000 + 10123},
	} {
		if err := otaAfterLogoffCaller(c.line, c.peer); err == nil {
			t.Errorf("%s: accepted", why)
		}
	}
	for _, w := range []string{"0", "0 " + n} {
		if err := otaAfterLogoffCaller(w, -1); err != nil {
			t.Errorf("withdrawal %q refused: %v", w, err)
		}
	}
}

// Only a final answer consumes the request; a session operation in flight (the reap's own clean-up) is RETRY.
func TestOtaAfterLogoffStep(t *testing.T) {
	for _, c := range []struct {
		pending bool
		blocker string
		action  string
		consume bool
	}{
		{false, "", "NONE", false},
		{false, "busy", "NONE", false},
		{true, "busy", "RETRY", false},
		{true, "session", "REFUSED", true},
		{true, "coldlock", "REFUSED", true},
		{true, "none", "REFUSED", true},
		{true, "", "APPLY", true},
	} {
		a, k := otaAfterLogoffStep(c.pending, c.blocker)
		if a != c.action || k != c.consume {
			t.Errorf("pending=%v blocker=%q: %s consume=%v, want %s %v", c.pending, c.blocker, a, k, c.action, c.consume)
		}
	}
}

func TestOtaAfterLogoffBlocker(t *testing.T) {
	for _, c := range []struct {
		free, live, cold, avail bool
		want                    string
	}{
		{true, false, false, true, ""},
		{false, false, false, true, "busy"},  // a login in flight
		{true, true, false, true, "session"}, // someone is signed in
		{true, false, true, true, "coldlock"},
		{true, false, false, false, "none"},
		{false, true, true, false, "busy"},
	} {
		if got := otaAfterLogoffBlocker(c.free, c.live, c.cold, c.avail); got != c.want {
			t.Errorf("free=%v live=%v cold=%v avail=%v: %q, want %q", c.free, c.live, c.cold, c.avail, got, c.want)
		}
	}
}

// First-seen: persisted (not tmpfs), returned unchanged once recorded, damaged lines never trusted, bounded.
func TestRecordOtaFirstSeen(t *testing.T) {
	p := filepath.Join(t.TempDir(), "ota-seen")
	t0 := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	if got := recordOtaFirstSeen(p, "0.5.45", t0); !got.Equal(t0) {
		t.Fatalf("first sight: %v", got)
	}
	if got := recordOtaFirstSeen(p, "0.5.45", t0.Add(72*time.Hour)); !got.Equal(t0) {
		t.Errorf("a later sight moved the first-seen time: %v", got)
	}
	b, _ := os.ReadFile(p)
	if string(b) != "0.5.45 1792486800\n" {
		t.Errorf("file: %q", b)
	}
	os.WriteFile(p, []byte("garbage\n0.5.45 notanumber\nlatest 5\n0.5.44 1700000000\n"), 0o600)
	if got := recordOtaFirstSeen(p, "0.5.45", t0); !got.Equal(t0) {
		t.Errorf("a damaged line was trusted: %v", got)
	}
	if got := recordOtaFirstSeen(p, "0.5.44", t0); !got.Equal(time.Unix(1700000000, 0)) {
		t.Errorf("a good line beside damaged ones was lost: %v", got)
	}
	for i := 0; i < otaSeenMax+5; i++ {
		recordOtaFirstSeen(p, "1.0."+itoa(i), t0)
	}
	b, _ = os.ReadFile(p)
	if n := strings.Count(string(b), "\n"); n != otaSeenMax {
		t.Errorf("%d lines kept, want the newest %d", n, otaSeenMax)
	}
	// ...and it is the NEWEST that are kept: the version just seen and the ones before it, not the oldest.
	if !strings.HasSuffix(string(b), "1.0."+itoa(otaSeenMax+4)+" 1792486800\n") ||
		!strings.HasPrefix(string(b), "1.0.5 ") || strings.Contains(string(b), "0.5.44 ") {
		t.Errorf("the wrong lines were kept:\n%s", b)
	}
	// Unwritable: the answer is now, and nothing breaks.
	bad := filepath.Join(t.TempDir(), "no-such-dir", "ota-seen")
	if got := recordOtaFirstSeen(bad, "0.5.45", t0); !got.Equal(t0) {
		t.Errorf("unwritable path: %v", got)
	}
	if otaSeenPath != "/data/nowhere/ota-seen" {
		t.Errorf("first-seen lives at %s; it must be plain /data, which a reboot keeps ($NOWHERE_STATE is tmpfs)", otaSeenPath)
	}
}

// The deadline counts from the later of the signed date and the day THIS phone first saw the release: a ring promoted
// late, or a phone that was off, gets its full window; a phone can never get less than the signed date allows.
func TestOtaDeadlineCountsFromFirstSeen(t *testing.T) {
	pub := time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)
	at := func(s string) time.Time { v, _ := time.Parse(time.RFC3339, s); return v }
	for _, c := range []struct {
		sev, firstSeen, want string
	}{
		{"critical", "", "2026-10-20T00:00:00Z"},                           // nothing recorded: the signed date
		{"critical", "2026-10-12T23:30:00Z", "2026-10-20T00:00:00Z"},       // seen the day it was published
		{"critical", "2026-10-21T08:00:00Z", "2026-10-29T00:00:00Z"},       // promoted after a soak: a full 7 days from then
		{"critical", "2026-10-01T08:00:00Z", "2026-10-20T00:00:00Z"},       // seen "before" publication (a wrong clock): signed date wins
		{"mandatory", "2026-11-30T22:00:00-05:00", "2027-01-01T00:00:00Z"}, // 03:00 UTC Dec 1: the UTC day counts
	} {
		r := &otaRelease{Severity: c.sev, Published: pub}
		if c.firstSeen != "" {
			r.FirstSeen = at(c.firstSeen)
		}
		if got := r.deadline(); !got.Equal(at(c.want)) {
			t.Errorf("%s first seen %q: %s, want %s", c.sev, c.firstSeen, got.UTC().Format(time.RFC3339), c.want)
		}
	}
}

// Every committed flag file is valid and named for its version. A bad one fails here, at commit, before the manifest
// it would go into is ever signed.
func TestCommittedOtaMandatoryFilesAreValid(t *testing.T) {
	dir := filepath.Join("..", "..", "editions", "endospore", "ota-mandatory")
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("%s: %v", dir, err)
	}
	for _, e := range ents {
		if e.Name() == "README" {
			continue
		}
		r, err := otaMandatorySourceFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Errorf("%s: %v", e.Name(), err)
			continue
		}
		if r.Version != e.Name() {
			t.Errorf("%s describes version %s", e.Name(), r.Version)
		}
	}
}

// The wiring a unit test cannot reach: the refresh verifies the metadata, OTA-STATUS serves it after AVAIL, the
// sign-out request verbs exist and run outside sessionMu, and the publish and packaging scripts carry their halves.
func TestOtaMandatoryIsWired(t *testing.T) {
	read := func(p string) string {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	main := read("main.go")
	refresh := main[strings.Index(main, "func refreshOtaCache() {"):]
	refresh = refresh[:strings.Index(refresh, "\n}\n")]
	// Pinned as one block, byte for byte: a string-contains check passes on the same lines wrapped in a dead branch.
	block := "\t\trefreshOtaNotes(\"s3\", latest, runningOtaVersion())\n" +
		"\t\t// NWP-20261011-05: and whether installing it is mandatory -- the signed release metadata of the offered\n" +
		"\t\t// version and of every version the notes walk found under it (ota_mandatory.go). After the notes, because\n" +
		"\t\t// their chain is what names those versions.\n" +
		"\t\totaNotesMu.Lock()\n" +
		"\t\tvar chain []*otaNotes\n" +
		"\t\tcomplete := false // a walk that stopped short (store error, cap) is retried, not taken as the whole list\n" +
		"\t\tif otaNotesOffered == latest {\n" +
		"\t\t\tchain, complete = otaNotesChain, !otaNotesMore\n" +
		"\t\t}\n" +
		"\t\totaNotesMu.Unlock()\n" +
		"\t\tdev := otaDev()\n" +
		"\t\trefreshOtaMandatory(\"s3\", latest, otaMandatoryVersions(latest, chain), complete,\n" +
		"\t\t\tfunc(v string) (*otaRelease, error) { return fetchOtaRelease(\"s3\", dev, v) })\n" +
		"\t}" // the end of refreshOtaCache's body: `refresh` is cut just before its closing brace
	if !strings.Contains(refresh, "\tif latest != \"\" && avail {\n"+block) {
		t.Error("refreshOtaCache no longer verifies the release metadata on every refresh that finds an update")
	}
	st := main[strings.Index(main, `if name == "OTA-STATUS" {`):]
	st = st[:strings.Index(st, `if name == "OTA-REFRESH" {`)]
	avail := st[strings.Index(st, `fmt.Fprintf(conn, "AVAIL %s\n", latest)`):]
	avail = avail[:strings.Index(avail, "} else {")]
	if !strings.Contains(avail, "writeOtaMandatoryLines(&ml, otaMandatoryFor(latest), time.Now())") {
		t.Error("OTA-STATUS no longer adds the mandatory lines after AVAIL")
	}
	if !strings.Contains(main, `if name == "OTA-AFTER-LOGOFF" {`) {
		t.Error("OTA-AFTER-LOGOFF is gone")
	}
	// The after-logoff install, pinned as one block, byte for byte: a pending request for THIS user, sessionMu by
	// TryLock, every blocker, then otaAfterLogoffStep decides -- RETRY keeps the request, only a final answer consumes it.
	apply := `		v, _ := r.ReadString('\n')
		vf := strings.Fields(v)
		uid, err := -1, errors.New("no uid")
		if len(vf) > 0 {
			uid, err = strconv.Atoi(vf[0])
		}
		pending := err == nil && otaAfterLogoffPending(uid, time.Now())
		if len(vf) == 2 && vf[1] == "drop" {
			if pending && consumeOtaAfterLogoff(uid) {
				fmt.Fprintf(os.Stderr, "[ota] sign out & install for user %d dropped by the gate\n", uid)
				fmt.Fprint(conn, "DROPPED\n")
			} else {
				fmt.Fprint(conn, "NONE\n")
			}
			return
		}
		why := ""
		if pending {
			// Held only for the checks and the (instant) kick, never across the install.
			free := sessionMu.TryLock()
			if free {
				defer sessionMu.Unlock()
			}
			_, avail, fresh, _ := otaStatusCached()
			_, clErr := os.Stat(filepath.Join(dest, ".coldlock"))
			why = otaAfterLogoffBlocker(free, roamSessionExists(dest), clErr == nil, fresh && avail)
		}
		action, consume := otaAfterLogoffStep(pending, why)
		if consume && !consumeOtaAfterLogoff(uid) {
			// Withdrawn or dropped since the pending check: the withdrawal wins, nothing starts.
			action = "NONE"
		}
		switch action {
		case "NONE":
			fmt.Fprint(conn, "NONE\n")
		case "RETRY", "REFUSED":
			fmt.Fprintf(os.Stderr, "[ota] sign out & install for user %d: %s %s\n", uid, action, why)
			fmt.Fprintf(conn, "%s %s\n", action, why)
		default:
			handleOtaApply(conn, dest)
		}
		return
	}
`
	// The request handler, pinned the same way: the caller check (SO_PEERCRED) and the in-flight guard on a bare "0".
	req := `		v, _ := r.ReadString('\n')
		line := strings.TrimSpace(v)
		pendingReapMu.Lock()
		inFlight := sealInFlight || pendingSwitchUID != "" || pendingReapUID != ""
		pendingReapMu.Unlock()
		if err := otaAfterLogoffCaller(line, peerUID(conn)); err != nil {
			fmt.Fprintf(os.Stderr, "[ota] sign out & install request refused: %v\n", err)
			fmt.Fprint(conn, "ERR\n")
			return
		}
		if err := setOtaAfterLogoff(line, time.Now(), inFlight); err != nil {
			fmt.Fprint(conn, "ERR\n")
			return
		}
		fmt.Fprint(conn, "OK\n")
		return
	}
`
	if i := strings.Index(main, `if name == "OTA-AFTER-LOGOFF" {`); i < 0 || !strings.Contains(main[i:], req) {
		t.Error("OTA-AFTER-LOGOFF no longer checks the caller and the sign-out in flight before it records")
	}
	if i := strings.Index(main, `if name == "OTA-APPLY-AFTER-LOGOFF" {`); i < 0 {
		t.Error("OTA-APPLY-AFTER-LOGOFF is gone")
	} else if body := main[i:]; !strings.Contains(body[:strings.Index(body, "\n\t}\n")+4], apply) {
		t.Error("OTA-APPLY-AFTER-LOGOFF no longer takes, checks and kicks in that order")
	}
	for _, v := range []string{"OTA-AFTER-LOGOFF", "OTA-APPLY-AFTER-LOGOFF"} {
		if !concurrentSafeCmd(v) {
			t.Errorf("%s must not wait behind sessionMu (it is sent the moment before LOGOUT; the apply TryLocks itself)", v)
		}
	}
	pub := read(filepath.Join("..", "..", "editions", "endospore", "build", "e4-ota-publish.sh"))
	if !strings.Contains(pub, `"$AGENT" ota-release-put s3 "$REL_MAN" "$REL_SIG" "$DEV" "$VERSION" "$MAND_SRC"`) {
		t.Error("e4-ota-publish.sh no longer publishes the signed release metadata")
	}
	pkg := read(filepath.Join("..", "..", "editions", "endospore", "build", "make-web-package.sh"))
	if !strings.Contains(pkg, `"ota": $OTA_JSON`) {
		t.Error("make-web-package.sh no longer writes the ota object into the manifest the operator signs")
	}
}

// The writer and the reader agree: what ota-release-fields.sh (the build host's writer, run by make-web-package.sh)
// puts in a manifest, once signed, verifies on the phone and matches the committed flag file it came from -- including
// text that needs JSON escaping. And the writer refuses a malformed flag file before anything is signed. It runs the
// real script, so it needs bash and python3; it FAILS without them rather than skipping, because a check that quietly
// does not run reads exactly like one that passed.
func TestOtaReleaseFieldsScriptRoundTrip(t *testing.T) {
	script := filepath.Join("..", "..", "editions", "endospore", "build", "ota-release-fields.sh")
	run := func(env []string, args ...string) (string, error) {
		cmd := exec.Command("bash", append([]string{script}, args...)...)
		cmd.Env = append(os.Environ(), env...)
		out, err := cmd.Output()
		return strings.TrimSpace(string(out)), err
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Fatal("bash is required for this test")
	}
	if _, err := exec.LookPath("python3"); err != nil {
		t.Fatal("python3 is required for this test (the build host's writer is Python)")
	}
	dir := t.TempDir()
	src := filepath.Join(dir, "0.5.45")
	text := "version 0.5.45\nseverity critical\nreason Sign-in now asks the servers \"who's there\" \\ differently — café.\nconsequence After the deadline this phone can't sign in.\n"
	if err := os.WriteFile(src, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
	pub, priv := testReleaseKey(t)
	want, err := parseOtaMandatorySource(text)
	if err != nil {
		t.Fatal(err)
	}
	obj, err := run([]string{"NOWHERE_OTA_PUBLISHED=2026-10-12"}, "0.5.45", src)
	if err != nil {
		t.Fatalf("writer on a good file: %v (%s)", err, obj)
	}
	man := manifestWith("lynx", obj)
	r, err := verifyOtaRelease(pub, []byte(man), signRelease(priv, man), "lynx", "0.5.45")
	if err != nil {
		t.Fatalf("the writer's output does not verify on the phone: %v\n%s", err, man)
	}
	if err := otaReleaseMatchesSource(r, want); err != nil {
		t.Errorf("the writer's output disagrees with its source: %v", err)
	}
	if r.Published.Format("2006-01-02") != "2026-10-12" {
		t.Errorf("published %s, want the override 2026-10-12", r.Published)
	}
	// No file: an ordinary release, dated today (UTC).
	obj, err = run(nil, "0.5.45", filepath.Join(dir, "absent"))
	if err != nil {
		t.Fatalf("writer with no file: %v", err)
	}
	man = manifestWith("lynx", obj)
	r, err = verifyOtaRelease(pub, []byte(man), signRelease(priv, man), "lynx", "0.5.45")
	if err != nil || r.mandatory() || otaReleaseMatchesSource(r, nil) != nil {
		t.Errorf("an ordinary release: %+v, %v", r, err)
	}
	if today := time.Now().UTC().Format("2006-01-02"); r.Published.Format("2006-01-02") != today {
		t.Errorf("published %s, want today (UTC) %s", r.Published.Format("2006-01-02"), today)
	}
	for why, c := range map[string]struct{ env, file, version string }{
		"the file names another version": {"", strings.Replace(text, "0.5.45", "0.5.46", 1), "0.5.45"},
		"severity none in a file":        {"", strings.Replace(text, "critical", "none", 1), "0.5.45"},
		"a missing line":                 {"", "version 0.5.45\nseverity critical\nreason R.\n", "0.5.45"},
		"lines out of order":             {"", "version 0.5.45\nreason R.\nseverity critical\nconsequence C.\n", "0.5.45"},
		"an empty reason":                {"", "version 0.5.45\nseverity critical\nreason  \nconsequence C.\n", "0.5.45"},
		"a bad override date":            {"NOWHERE_OTA_PUBLISHED=2026-13-40", text, "0.5.45"},
		"a date that is not a date":      {"NOWHERE_OTA_PUBLISHED=tomorrow", text, "0.5.45"},
		"a version that is not x.y.z":    {"", text, "latest"},
	} {
		p := filepath.Join(dir, "case")
		os.WriteFile(p, []byte(c.file), 0o644)
		var env []string
		if c.env != "" {
			env = []string{c.env}
		}
		if out, err := run(env, c.version, p); err == nil {
			t.Errorf("%s: the writer accepted it: %s", why, out)
		}
	}
	// Text the reader refuses (checkOtaText, and the newline rule): the writer must refuse each before anything is
	// signed. Each row also asks the reader, so a row can only hold what the reader refuses.
	flag := func(reason, consequence string) string {
		return "version 0.5.45\nseverity critical\nreason " + reason + "\nconsequence " + consequence + "\n"
	}
	const goodReason, goodConsequence = "A reason.", "A consequence."
	for id, c := range map[string]struct{ why, file string }{
		"w1":  {"a reason with a trailing space", flag("A reason. ", goodConsequence)},
		"w2":  {"a consequence with a leading space", flag(goodReason, " A consequence.")},
		"w3":  {"a reason holding a tab", flag("A\treason.", goodConsequence)},
		"w4":  {"a reason of 201 characters", flag(strings.Repeat("x", 201), goodConsequence)},
		"w5":  {"a reason saying security", flag("Fixes a security problem in sign-in.", goodConsequence)},
		"w6":  {"a reason saying Privacy", flag("Privacy settings now load faster.", goodConsequence)},
		"w7":  {"a reason saying encrypted", flag("Backups are encrypted differently.", goodConsequence)},
		"w8":  {"a reason saying can't see", flag("Our servers can't see the old format.", goodConsequence)},
		"w9":  {"a reason holding the byte 0xff", flag("Bad byte \xff here.", goodConsequence)},
		"w10": {"a reason with ésafe (ASCII \\b sits between é and s)", flag("Now ésafe to use.", goodConsequence)},
		"w11": {"a lone CR at the end of the file", "version 0.5.45\nseverity critical\nreason A reason.\nconsequence A consequence.\r"},
		"w12": {"a reason with ſ, which RE2 folds to s", flag("Sign-in is anonymou\u017fly faster.", goodConsequence)},
		"w13": {"a reason with the Kelvin sign, which RE2 folds to k", flag("No more trac\u212aing pixels.", goodConsequence)},
	} {
		if _, err := parseOtaMandatorySource(c.file); err == nil {
			t.Errorf("%s (%s): the reader accepts it, so it is not a parity case", id, c.why)
		}
		p := filepath.Join(dir, "text-"+id)
		if err := os.WriteFile(p, []byte(c.file), 0o644); err != nil {
			t.Fatal(err)
		}
		if out, err := run([]string{"NOWHERE_OTA_PUBLISHED=2026-10-12"}, "0.5.45", p); err == nil {
			t.Errorf("%s (%s): the writer accepted what the reader refuses: %s", id, c.why, out)
		}
	}
	// The longest reason the reader allows: 200 characters, each two bytes. Both accept it, and the writer's JSON
	// verifies and matches its source.
	long := flag(strings.Repeat("é", 200), goodConsequence)
	want, err = parseOtaMandatorySource(long)
	if err != nil {
		t.Fatalf("the reader refuses 200 characters: %v", err)
	}
	p := filepath.Join(dir, "text-200")
	if err := os.WriteFile(p, []byte(long), 0o644); err != nil {
		t.Fatal(err)
	}
	obj, err = run([]string{"NOWHERE_OTA_PUBLISHED=2026-10-12"}, "0.5.45", p)
	if err != nil {
		t.Fatalf("writer on a 200-character reason: %v (%s)", err, obj)
	}
	man = manifestWith("lynx", obj)
	r, err = verifyOtaRelease(pub, []byte(man), signRelease(priv, man), "lynx", "0.5.45")
	if err != nil {
		t.Fatalf("the writer's 200-character output does not verify: %v", err)
	}
	if err := otaReleaseMatchesSource(r, want); err != nil {
		t.Errorf("the writer's 200-character output disagrees with its source: %v", err)
	}
}

// The writer's three copies of the reader's text rules are single lines, and this holds each equal to the Go it
// mirrors: the claim-word pattern (ota_notes.go), the characters RE2's (?i) folds beyond ASCII (derived from
// unicode.SimpleFold, so a Unicode change shows here), and the length cap.
func TestOtaReleaseFieldsClaimWordsMatchTheReader(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "editions", "endospore", "build", "ota-release-fields.sh"))
	if err != nil {
		t.Fatal(err)
	}
	only := func(prefix string) string {
		var found []string
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, prefix) {
				found = append(found, l)
			}
		}
		if len(found) != 1 {
			t.Fatalf("want exactly one line starting %q in ota-release-fields.sh, found %d", prefix, len(found))
		}
		return found[0]
	}
	src := otaNotesClaimWords.String()
	if !strings.HasPrefix(src, "(?i)") {
		t.Fatalf("otaNotesClaimWords no longer starts with (?i): %s", src)
	}
	if got, want := only(`CLAIM_WORDS = r"`), `CLAIM_WORDS = r"`+strings.TrimPrefix(src, "(?i)")+`"`; got != want {
		t.Errorf("CLAIM_WORDS drifted from otaNotesClaimWords:\n got %s\nwant %s", got, want)
	}
	var folds []string
	for c := 'a'; c <= 'z'; c++ {
		var wide []rune
		for r := unicode.SimpleFold(c); r != c; r = unicode.SimpleFold(r) {
			if r > 0x7f {
				wide = append(wide, r)
			}
		}
		if len(wide) > 1 {
			t.Fatalf("%q folds to %d non-ASCII runes; CLAIM_FOLDS holds one per letter", c, len(wide))
		}
		if len(wide) == 1 {
			folds = append(folds, fmt.Sprintf("%q: \"\\u%04x\"", string(c), wide[0]))
		}
	}
	if got, want := only("CLAIM_FOLDS = "), "CLAIM_FOLDS = {"+strings.Join(folds, ", ")+"}"; got != want {
		t.Errorf("CLAIM_FOLDS drifted from unicode.SimpleFold:\n got %s\nwant %s", got, want)
	}
	if got, want := only("TEXT_MAX = "), fmt.Sprintf("TEXT_MAX = %d", otaMandatoryTextMax); got != want {
		t.Errorf("TEXT_MAX drifted: got %s, want %s", got, want)
	}
}

// Round 4, F1: GET-RELOGIN runs outside sessionMu (the reap's clean-up holds it), so it must take the queued creds
// atomically: of two concurrent reads exactly one gets them, and the other a definitive NONE.
func TestGetReloginTakesAtomically(t *testing.T) {
	if !concurrentSafeCmd("GET-RELOGIN") {
		t.Fatal("GET-RELOGIN waits behind sessionMu: a read that times out behind the reap's clean-up still consumes the creds")
	}
	for round := 0; round < 50; round++ {
		dest := t.TempDir()
		os.WriteFile(filepath.Join(dest, ".relogin"), []byte("carol\npw\n"), 0o600)
		got := make(chan string, 2)
		for i := 0; i < 2; i++ {
			go func() { got <- unixRoundTrip(t, func(c net.Conn) { handleGetRelogin(c, dest) }) }()
		}
		a, b := <-got, <-got
		if strings.Count(a+b, "OK\ncarol\npw\n") != 1 || strings.Count(a+b, "NONE\n") != 1 {
			t.Fatalf("round %d: two concurrent reads got %q and %q -- want exactly one OK and one NONE", round, a, b)
		}
		if _, err := os.Stat(filepath.Join(dest, ".relogin")); !os.IsNotExist(err) {
			t.Fatalf("round %d: the creds survived the take", round)
		}
		if _, err := os.Stat(filepath.Join(dest, reloginTakenFile)); !os.IsNotExist(err) {
			t.Fatalf("round %d: the taken copy (a cleartext passphrase) was left in the state dir", round)
		}
	}
}

// Round 5, F-B: the RELOGIN writer puts .relogin in place atomically (temp + rename), so a concurrent take sees the
// whole file or none -- never the empty inode an O_TRUNC write exposes, which it would take and lose.
func TestWriteQueuedReloginIsAtomic(t *testing.T) {
	dest := t.TempDir()
	if err := writeQueuedRelogin(dest, "carol", "pw one"); err != nil {
		t.Fatal(err)
	}
	if err := writeQueuedRelogin(dest, "carol", "pw two"); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dest, ".relogin"))
	if err != nil || string(b) != "carol\npw two\n" {
		t.Fatalf("queued: %q %v", b, err)
	}
	if fi, _ := os.Stat(filepath.Join(dest, ".relogin")); fi == nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("queued creds are not 0600: %v", fi)
	}
	if _, err := os.Stat(filepath.Join(dest, ".relogin.tmp")); !os.IsNotExist(err) {
		t.Error("the temp file was left behind")
	}
	// Deterministic (round 7): a rename into place gives .relogin a NEW inode every time; a write straight to .relogin
	// (O_TRUNC on the same inode -- the window where a concurrent take renames an empty file) keeps the old one.
	before, err := os.Stat(filepath.Join(dest, ".relogin"))
	if err != nil {
		t.Fatal(err)
	}
	if err := writeQueuedRelogin(dest, "carol", "pw three"); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(filepath.Join(dest, ".relogin"))
	if err != nil {
		t.Fatal(err)
	}
	if os.SameFile(before, after) {
		t.Error("writeQueuedRelogin rewrote .relogin in place -- not a rename, so a concurrent take can grab it half-written")
	}
	// ...and a writer that cannot write its temp file must leave the queued relogin exactly as it was.
	os.Mkdir(filepath.Join(dest, reloginTmpFile), 0o700)
	if err := writeQueuedRelogin(dest, "mallory", "other"); err == nil {
		t.Error("writeQueuedRelogin succeeded with its temp path blocked -- it is not writing through the temp file")
	}
	if b, _ := os.ReadFile(filepath.Join(dest, ".relogin")); string(b) != "carol\npw three\n" {
		t.Errorf("a failed write changed the queued relogin: %q", b)
	}
	os.Remove(filepath.Join(dest, reloginTmpFile))
	// Stress: a writer and a taker racing. Every OK must carry complete creds; with a non-atomic write the taker can
	// grab a half-written file, and then the creds of that write are gone for good.
	for round := 0; round < 200; round++ {
		d := t.TempDir()
		done := make(chan struct{})
		go func() { writeQueuedRelogin(d, "carol", "pw"); close(done) }()
		var got []string
		for i := 0; i < 3; i++ {
			got = append(got, unixRoundTrip(t, func(c net.Conn) { handleGetRelogin(c, d) }))
		}
		<-done
		got = append(got, unixRoundTrip(t, func(c net.Conn) { handleGetRelogin(c, d) }))
		oks := 0
		for _, g := range got {
			switch g {
			case "OK\ncarol\npw\n":
				oks++
			case "NONE\n":
			default:
				t.Fatalf("round %d: a take returned %q", round, g)
			}
		}
		if oks != 1 {
			t.Fatalf("round %d: one queued relogin was taken %d times (want exactly once): %q", round, oks, got)
		}
	}
	// The wiring: RELOGIN writes through it, and both login paths and daemon start clear a half-taken copy.
	src, _ := os.ReadFile("main.go")
	m := string(src)
	if !strings.Contains(m, "writeQueuedRelogin(dest, name, pass) // NWP-20261011-05") {
		t.Error("RELOGIN no longer queues through writeQueuedRelogin")
	}
	for _, ctx := range []string{
		"os.Remove(filepath.Join(dest, \".relogin\")) // #97: a resolved login supersedes any queued auto-relogin\n\t\tremoveReloginTaken(dest) ",
		"os.Remove(filepath.Join(dest, \".relogin\")) // #97: a fresh offline login supersedes any stale queued relogin\n\tremoveReloginTaken(dest) ",
	} {
		if !strings.Contains(m, ctx) {
			t.Errorf("a login path no longer removes the half-taken relogin beside .relogin: %q", ctx[:60])
		}
	}
	if !strings.Contains(m, "\tremoveReloginTaken(dest)\n\t// NWP-20261010-10 (round 6): a restart pending when the daemon last ran gives the session back.\n\trecoverRestartMarker(dest)\n\tgoSafeLoop(\"periodic-seal loop\", func() { syncLoop(dest) })") {
		t.Error("daemon start no longer clears a half-taken relogin")
	}
	// Round 6: a half-written .relogin.tmp (logind died between write and rename) holds the passphrase too. The one
	// helper -- run at daemon start (pinned above) and in both login paths -- removes it beside the taken copy, and the
	// writer writes to exactly that name.
	d := t.TempDir()
	for _, f := range []string{reloginTakenFile, reloginTmpFile, ".relogin"} {
		os.WriteFile(filepath.Join(d, f), []byte("x\ny\n"), 0o600)
	}
	removeReloginTaken(d)
	for _, f := range []string{reloginTakenFile, reloginTmpFile} {
		if _, err := os.Stat(filepath.Join(d, f)); !os.IsNotExist(err) {
			t.Errorf("removeReloginTaken left %s (a cleartext passphrase)", f)
		}
	}
	if _, err := os.Stat(filepath.Join(d, ".relogin")); err != nil {
		t.Error("removeReloginTaken removed a queued relogin that is still due")
	}
	if reloginTmpFile != ".relogin.tmp" || !strings.Contains(m, "\ttmp := filepath.Join(dest, reloginTmpFile)\n") {
		t.Error("the writer's temp file is not the one removeReloginTaken cleans up")
	}
}

// NWP-20261017-17: a cold lock is a sign-out the "Sign out & install" request did not start, so taking one withdraws
// the request -- otherwise the locked session's later wipe reaches maybeInstallAfterLogoff and installs.
func TestColdLockWithdrawsSignOutAndInstallRequest(t *testing.T) {
	save := otaAfterLogoffCur
	t.Cleanup(func() {
		otaAfterLogoffMu.Lock()
		otaAfterLogoffCur = save
		otaAfterLogoffMu.Unlock()
	})
	now := time.Now()
	if err := setOtaAfterLogoff("1 10 abcdef0123456789", now, false); err != nil {
		t.Fatal(err)
	}
	if !otaAfterLogoffPending(10, now) {
		t.Fatal("setup: the request was not recorded")
	}
	logged := captureStderr(t, func() { withdrawOtaAfterLogoffForColdLock("10") })
	if otaAfterLogoffPending(10, now) {
		t.Error("a cold lock left the install request pending")
	}
	if !strings.Contains(logged, "[ota]") || !strings.Contains(logged, "user 10") {
		t.Errorf("a dropped request left no [ota] line naming the user; stderr %q", logged)
	}
	if strings.Contains(logged, "abcdef0123456789") {
		t.Errorf("the log line carries the nonce: %q", logged)
	}
	logged = captureStderr(t, func() { withdrawOtaAfterLogoffForColdLock("10") })
	if logged != "" {
		t.Errorf("nothing was pending, yet a line was logged: %q", logged)
	}
}

// handleColdLock must call the helper past the logoffInFlight refusal and the already-in-flight return (the point
// the lock is actually taken). NOWHERE_COLDLOCK_MAIN_SRC points a mutated copy at it (core/chooser/test-ota-request-withdraw.sh).
func TestHandleColdLockWithdrawsOtaRequestWhenLockTaken(t *testing.T) {
	path := "main.go"
	if p := os.Getenv("NOWHERE_COLDLOCK_MAIN_SRC"); p != "" {
		path = p
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	body := stripComments(funcBody(t, string(b), "handleColdLock"))
	at := func(sub string) int {
		for i, l := range body {
			if strings.Contains(l, sub) {
				return i
			}
		}
		return -1
	}
	refuse, running, call := at("if logoffInFlight(uid) {"), at("coldLockRunning = true"), at("withdrawOtaAfterLogoffForColdLock(uid)")
	if refuse < 0 || running < 0 {
		t.Fatalf("handleColdLock anchors moved (refusal %d, running %d) -- this test is stale, not the code", refuse, running)
	}
	if call < 0 {
		t.Fatal("handleColdLock no longer calls withdrawOtaAfterLogoffForColdLock: a cold-locked session's later wipe would install a stale request")
	}
	if call < refuse || call < running {
		t.Errorf("the withdrawal (line %d) runs before the lock is taken (refusal %d, running %d)", call, refuse, running)
	}
}
