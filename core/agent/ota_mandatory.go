package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// NWP-20261011-05 -- mandatory updates (docs/product-decisions.md, 2026-10-10: "a mandatory update is whatever we flag
// as one; the phone explains why and nags harder after its deadline, and never installs without asking").
//
// WHAT CARRIES THE FLAG. The web-installer manifest that make-web-package.sh writes for every release and that the
// operator already signs with the offline release key (`release sign`, the key whose public half the install page
// trusts, 9oh6…T5Y) gains an "ota" object:
//
//	"ota": {"version": "0.5.45", "severity": "mandatory", "published": "2026-10-12",
//	        "reason": "<one line>", "consequence": "<one line>"}
//
// e4-ota-publish.sh puts that signed manifest beside the OTA marker as ota/<dev>/release-<version> (an envelope:
// otaReleaseMagic, the base64url signature, then the manifest bytes verbatim), BEFORE the marker. The phone fetches
// it for the offered version, checks the signature against releasePubKey, and only then believes any of it. No new
// key: the release key already signs every release; what is new is that the phone carries its PUBLIC half.
//
// FAIL SAFE: nothing unverified ever nags. A missing envelope, a bad signature, a manifest for another device or
// another version, an unknown severity, an unparseable date or an empty or over-long reason all read as "not
// mandatory" -- the update is still offered, quietly, exactly as before. The publish runs the same checks with the
// same code (ota-release-check) and REFUSES, so a mandatory release cannot silently degrade to an ordinary one.
//
// THE DEADLINE is derived on the phone: the end of the 7th (critical) or 30th (mandatory) UTC day after the LATER of
// the signed publication date and the day this phone first saw the release (otaRelease.deadline). The 7 and 30 days are
// Chester's (2026-10-10); counting from first sight rather than from publication alone is this slice's, raised with him
// and NOT decided (docs/product-decisions.md). After the deadline the phone nags harder; it never installs on its own.
//
// THE TEXT is shown as signed. The phone never composes a reason of its own: titles, buttons and the overdue line are
// the chooser's; the reason and the consequence are exactly the signed strings. They follow the notes' wording rule
// (no privacy or security claims, docs/privacy-claims.md), checked before signing (the committed source file's test)
// and again at publish and on the phone.

// releasePubKey is the public half of the offline release key (base64url, 32 raw bytes) -- the same key the web
// installer page verifies manifests against (STOREFRONT_RELEASE_PUBKEY). Recorded in worklog.md (NWP-20260818-*:
// "The page's baked pubkey is 9oh6…"); every release since has been verified against it.
const releasePubKey = "9oh6DCFpqlGQeQjkfpl2XPjqmp0kpNDsnObc3DApT5Y"

// otaReleaseKey is the key the phone checks fetched metadata against: releasePubKey, swapped only by tests (which
// cannot sign with the real key).
var otaReleaseKey = releasePubKey

const (
	otaReleaseMagic     = "nowhere-ota-release 1"
	otaReleaseMaxBytes  = 16 << 10                 // a signed manifest is ~1 KB; anything near this is not one
	otaReleaseEnvMax    = otaReleaseMaxBytes + 256 // the envelope: the magic line, a signature line, the manifest
	otaMandatoryTextMax = 200                      // characters, for the reason and for the consequence
	otaCriticalDays     = 7
	otaMandatoryDays    = 30
)

// otaRelease is the verified "ota" object of one release's signed manifest.
type otaRelease struct {
	Version     string
	Severity    string    // "none" | "mandatory" | "critical"
	Published   time.Time // 00:00 UTC of the signed publication date (zero for severity none without a date)
	FirstSeen   time.Time // when THIS phone first verified this release as mandatory (zero = not recorded)
	Reason      string
	Consequence string
}

// mandatory reports whether this release must be installed by a deadline.
func (r *otaRelease) mandatory() bool {
	return r != nil && (r.Severity == "mandatory" || r.Severity == "critical")
}

// deadline is the end of the Nth UTC day after the release reached THIS phone: day D is the later of the signed
// publication date and the UTC day the phone first saw the release (FirstSeen), and the release is due by the end of
// D+N -- so whatever hour it arrived, the phone has at least N whole days.
//
// Why not the signed date alone: it is fixed when the manifest is generated, and a release can reach a ring long after
// that -- e4-ota-promote.sh moves only the marker, so a critical fix that soaked 8 days on beta would reach the stable
// fleet already overdue. "Counted from publication" (the decision) means publication to the phone, and the first time
// the phone saw the offer is exactly that. FirstSeen only ever LENGTHENS the window (max), it is this phone's own
// record, and an attacker who could forge it would only delay their own nag.
func (r *otaRelease) deadline() time.Time {
	days := otaMandatoryDays
	if r.Severity == "critical" {
		days = otaCriticalDays
	}
	base := r.Published
	if fs := r.FirstSeen.UTC(); !fs.IsZero() {
		if d := time.Date(fs.Year(), fs.Month(), fs.Day(), 0, 0, 0, 0, time.UTC); d.After(base) {
			base = d
		}
	}
	return base.AddDate(0, 0, days+1)
}

// overdue reports whether now is at or past the deadline.
func (r *otaRelease) overdue(now time.Time) bool { return r.mandatory() && !now.Before(r.deadline()) }

// otaReleaseManifest is the part of the installer manifest the phone reads. Everything else is the install page's.
type otaReleaseManifest struct {
	Device struct {
		Codename string `json:"codename"`
	} `json:"device"`
	OTA *struct {
		Version     string `json:"version"`
		Severity    string `json:"severity"`
		Published   string `json:"published"`
		Reason      string `json:"reason"`
		Consequence string `json:"consequence"`
	} `json:"ota"`
}

// checkOtaText validates one signed line of copy: present, one line, bounded, printable, and no privacy or security
// claim (the notes' rule, docs/privacy-claims.md).
func checkOtaText(what, s string) error {
	if strings.TrimSpace(s) == "" {
		return fmt.Errorf("%s is empty", what)
	}
	if s != strings.TrimSpace(s) {
		return fmt.Errorf("%s has leading or trailing space", what)
	}
	if !utf8.ValidString(s) {
		return fmt.Errorf("%s is not UTF-8", what)
	}
	if n := utf8.RuneCountInString(s); n > otaMandatoryTextMax {
		return fmt.Errorf("%s is %d characters, over %d", what, n, otaMandatoryTextMax)
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return fmt.Errorf("%s has a control character", what)
		}
	}
	if w := otaNotesClaimWords.FindString(s); w != "" {
		return fmt.Errorf("%s says %q: no privacy or security claims (docs/privacy-claims.md)", what, w)
	}
	return nil
}

// otaReleaseFields validates the "ota" object of a manifest whose signature has ALREADY been checked, binding it to
// this device and the version it is published for.
func otaReleaseFields(manifest []byte, dev, version string) (*otaRelease, error) {
	var m otaReleaseManifest
	if err := json.Unmarshal(manifest, &m); err != nil {
		return nil, fmt.Errorf("manifest does not parse: %v", err)
	}
	if m.Device.Codename != dev {
		return nil, fmt.Errorf("manifest is for device %q, not %q", m.Device.Codename, dev)
	}
	if m.OTA == nil {
		return nil, errors.New(`manifest has no "ota" object (built before NWP-20261011-05)`)
	}
	o := m.OTA
	if !otaVersionRe.MatchString(o.Version) || o.Version != version {
		return nil, fmt.Errorf("manifest describes version %q, not %q", o.Version, version)
	}
	r := &otaRelease{Version: o.Version, Severity: o.Severity}
	switch o.Severity {
	case "none", "mandatory", "critical":
	default:
		return nil, fmt.Errorf("unknown severity %q", o.Severity)
	}
	if o.Published != "" {
		p, err := time.ParseInLocation("2006-01-02", o.Published, time.UTC)
		if err != nil {
			return nil, fmt.Errorf("published %q is not a YYYY-MM-DD date", o.Published)
		}
		r.Published = p
	}
	if !r.mandatory() {
		return r, nil
	}
	if r.Published.IsZero() {
		return nil, fmt.Errorf("a %s release has no published date, so it has no deadline", o.Severity)
	}
	if err := checkOtaText("reason", o.Reason); err != nil {
		return nil, err
	}
	if err := checkOtaText("consequence", o.Consequence); err != nil {
		return nil, err
	}
	r.Reason, r.Consequence = o.Reason, o.Consequence
	return r, nil
}

// decodeB64URL accepts base64url with or without padding (what `release sign` writes is unpadded).
func decodeB64URL(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(strings.TrimSpace(s), "="))
}

// verifyReleaseSig reports whether sigB64 (base64url) is a valid signature over msg by the base64url key pubB64.
func verifyReleaseSig(pubB64 string, msg []byte, sigB64 string) bool {
	pub, err := decodeB64URL(pubB64)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return false
	}
	sig, err := decodeB64URL(sigB64)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(pub, msg, sig)
}

// verifyOtaRelease checks a signed manifest and returns its verified "ota" object. The signature is checked FIRST:
// nothing in an unsigned manifest is read.
func verifyOtaRelease(pubB64 string, manifest []byte, sigB64, dev, version string) (*otaRelease, error) {
	if len(manifest) == 0 || len(manifest) > otaReleaseMaxBytes {
		return nil, fmt.Errorf("manifest is %d bytes", len(manifest))
	}
	if !verifyReleaseSig(pubB64, manifest, sigB64) {
		return nil, errors.New("the release signature does not verify")
	}
	return otaReleaseFields(manifest, dev, version)
}

// otaReleaseEnvelope is what the store holds: one blob, so the signature and the bytes it covers can never be
// fetched from two different publishes.
func otaReleaseEnvelope(manifest []byte, sigB64 string) []byte {
	return []byte(otaReleaseMagic + "\n" + strings.TrimSpace(sigB64) + "\n" + string(manifest))
}

// openOtaReleaseEnvelope splits an envelope into the signature and the manifest bytes, verbatim.
func openOtaReleaseEnvelope(b []byte) (sigB64 string, manifest []byte, err error) {
	rest, ok := strings.CutPrefix(string(b), otaReleaseMagic+"\n")
	if !ok {
		return "", nil, errors.New("not a release envelope")
	}
	sig, man, ok := strings.Cut(rest, "\n")
	if !ok {
		return "", nil, errors.New("truncated release envelope")
	}
	return sig, []byte(man), nil
}

func otaReleaseRef(dev, version string) string { return "ota/" + dev + "/release-" + version }

// fetchOtaRelease reads a published version's signed manifest and verifies it. (nil, nil) means none is published --
// a release before this feature, or one published without its manifest, which is never mandatory.
func fetchOtaRelease(base, dev, version string) (r *otaRelease, err error) {
	defer func() {
		if p := recover(); p != nil {
			r, err = nil, fmt.Errorf("store: %v", p)
		}
	}()
	h := getRef(base, otaReleaseRef(dev, version))
	if h == "" {
		return nil, nil
	}
	// Bounded read: an envelope is the magic, a signature line and a manifest of at most otaReleaseMaxBytes. Read one
	// byte past that so a larger blob is refused WITHOUT being held whole.
	b, ok := getBlobSoftMax(base, h, otaReleaseEnvMax+1)
	if !ok {
		return nil, fmt.Errorf("release blob %.12s missing", h)
	}
	if len(b) > otaReleaseEnvMax {
		return nil, fmt.Errorf("release blob %.12s is over %d bytes", h, otaReleaseEnvMax)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != h {
		return nil, fmt.Errorf("release blob %.12s does not match its name", h)
	}
	sig, man, err := openOtaReleaseEnvelope(b)
	if err != nil {
		return nil, err
	}
	return verifyOtaRelease(otaReleaseKey, man, sig, dev, version)
}

// mostUrgentOtaRelease picks, from the verified releases between the running version and the offered one, the
// mandatory one due first (critical before mandatory on the same instant). Installing the offered version installs
// every release before it, so a mandatory 0.5.45 still binds a phone on 0.5.44 that is offered an ordinary 0.5.46.
func mostUrgentOtaRelease(rs []*otaRelease) *otaRelease {
	var best *otaRelease
	for _, r := range rs {
		if !r.mandatory() {
			continue
		}
		if best == nil || r.deadline().Before(best.deadline()) ||
			(r.deadline().Equal(best.deadline()) && r.Severity == "critical" && best.Severity != "critical") {
			best = r
		}
	}
	return best
}

// --- the daemon's cache, refreshed with the notes off the request path; OTA-STATUS answers from memory ---
var (
	otaMandMu      sync.Mutex
	otaMandOffered string      // the offered version this answer is for
	otaMandBest    *otaRelease // nil = nothing mandatory (or nothing verified)
	otaMandRetryAt time.Time   // a walk that hit a store error is retried after this (zero = complete)
)

// otaMandatoryVersions is every version installing `offered` would bring: the offered one plus each one the notes
// walk found between it and the running version.
func otaMandatoryVersions(offered string, chain []*otaNotes) []string {
	vs := []string{offered}
	for _, n := range chain {
		if n.Version != offered {
			vs = append(vs, n.Version)
		}
	}
	return vs
}

// refreshOtaMandatory verifies the signed manifests for `offered` and the versions under it, unless the cache already
// holds a complete answer for that offer. A store error leaves the answer built from what DID verify, retried later.
func refreshOtaMandatory(base, offered string, versions []string, chainComplete bool, fetch func(string) (*otaRelease, error)) {
	now := time.Now().Round(0)
	otaMandMu.Lock()
	fresh := otaMandOffered == offered && (otaMandRetryAt.IsZero() || now.Before(otaMandRetryAt))
	otaMandMu.Unlock()
	if offered == "" || fresh {
		return
	}
	var got []*otaRelease
	failed := false
	for _, v := range versions {
		r, err := fetch(v)
		if err != nil {
			// Logged without identity: a version string and why its metadata was not believed.
			fmt.Fprintf(os.Stderr, "[ota] release metadata for %s not used: %s\n", v, logSafeErrText(err))
			failed = true
			continue
		}
		if r != nil {
			if r.mandatory() {
				r.FirstSeen = recordOtaFirstSeen(otaSeenPath, r.Version, now) // before mostUrgent: it moves the deadline
			}
			got = append(got, r)
		}
	}
	best := mostUrgentOtaRelease(got)
	otaMandMu.Lock()
	otaMandOffered, otaMandBest, otaMandRetryAt = offered, best, time.Time{}
	// A failed fetch, or a notes walk that stopped short (a transient store error there leaves the version list
	// truncated, and a mandatory release below the cut would go unseen until the offer changed): retry later.
	if failed || !chainComplete {
		otaMandRetryAt = now.Add(otaNotesRetry)
	}
	otaMandMu.Unlock()
}

// --- first-seen: when this phone first verified a release as mandatory (the deadline's base, see deadline) ---
//
// Kept on plain /data beside the other device-level OTA settings (ota-auto, ota-time), NOT in $NOWHERE_STATE: that is
// tmpfs, so a reboot -- which every OTA install ends in, and which an owner can do at will -- would restart the window.
// One line per version, "<version> <unix seconds>", newest last, at most otaSeenMax lines. It names OS versions and
// times only: device-level, like the marker it follows, and nothing about who uses the phone.
var otaSeenPath = "/data/nowhere/ota-seen" // var so tests point it at a temp file

const otaSeenMax = 16

// recordOtaFirstSeen returns when this phone first saw `version`, recording `now` if it never had. A read or write
// failure returns `now` (and keeps nothing): the window then starts at the latest possible moment, the lenient
// direction, and the next refresh tries again.
func recordOtaFirstSeen(path, version string, now time.Time) time.Time {
	var lines []string
	if b, err := os.ReadFile(path); err == nil {
		for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
			f := strings.Fields(l)
			if len(f) != 2 || !otaVersionRe.MatchString(f[0]) {
				continue // a damaged line is dropped, never trusted
			}
			sec, err := strconv.ParseInt(f[1], 10, 64)
			if err != nil || sec <= 0 {
				continue
			}
			if f[0] == version {
				return time.Unix(sec, 0)
			}
			lines = append(lines, f[0]+" "+f[1])
		}
	}
	lines = append(lines, fmt.Sprintf("%s %d", version, now.Unix()))
	if len(lines) > otaSeenMax {
		lines = lines[len(lines)-otaSeenMax:]
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err == nil {
		if err := os.Rename(tmp, path); err != nil {
			os.Remove(tmp)
		}
	}
	return now
}

// otaMandatoryFor returns the cached mandatory release for `offered`, or nil.
func otaMandatoryFor(offered string) *otaRelease {
	otaMandMu.Lock()
	defer otaMandMu.Unlock()
	if otaMandOffered != offered {
		return nil
	}
	return otaMandBest
}

// writeOtaMandatoryLines renders the optional lines OTA-STATUS adds after `AVAIL <version>` when the update is
// mandatory:
//
//	MANDATORY <mandatory|critical> <deadline unix seconds> <due|overdue>
//	REASON <signed text>
//	CONSEQUENCE <signed text>
//
// Separate lines, never fields on the AVAIL line: every OTA-STATUS caller reads line 1 and the version is "the rest
// of the line" there, so an older chooser keeps working untouched.
func writeOtaMandatoryLines(w *strings.Builder, r *otaRelease, now time.Time) {
	if !r.mandatory() {
		return
	}
	state := "due"
	if r.overdue(now) {
		state = "overdue"
	}
	fmt.Fprintf(w, "MANDATORY %s %d %s\nREASON %s\nCONSEQUENCE %s\n", r.Severity, r.deadline().Unix(), state, r.Reason, r.Consequence)
}

// --- the source file a release's flag is written in, committed before the build ---
//
// editions/endospore/ota-mandatory/<version>:
//
//	version 0.5.45
//	severity mandatory
//	reason <one line>
//	consequence <one line>
//
// make-web-package.sh copies it into the manifest the operator signs; e4-ota-publish.sh refuses a signed manifest
// that does not say the same thing (ota-release-check). No file = severity none.

// parseOtaMandatorySource reads one committed source file.
func parseOtaMandatorySource(text string) (*otaRelease, error) {
	lines := strings.Split(strings.TrimRight(strings.ReplaceAll(text, "\r\n", "\n"), "\n"), "\n")
	if len(lines) != 4 {
		return nil, fmt.Errorf("want exactly 4 lines (version, severity, reason, consequence), got %d", len(lines))
	}
	field := func(i int, key string) (string, error) {
		v, ok := strings.CutPrefix(lines[i], key+" ")
		if !ok {
			return "", fmt.Errorf("line %d must be `%s <value>`, got %q", i+1, key, lines[i])
		}
		return v, nil
	}
	r := &otaRelease{}
	var err error
	if r.Version, err = field(0, "version"); err != nil {
		return nil, err
	}
	if !otaVersionRe.MatchString(r.Version) {
		return nil, fmt.Errorf("version %q is not x.y.z", r.Version)
	}
	if r.Severity, err = field(1, "severity"); err != nil {
		return nil, err
	}
	if r.Severity != "mandatory" && r.Severity != "critical" {
		return nil, fmt.Errorf("severity must be mandatory or critical, got %q (an ordinary release has no file)", r.Severity)
	}
	if r.Reason, err = field(2, "reason"); err != nil {
		return nil, err
	}
	if err := checkOtaText("reason", r.Reason); err != nil {
		return nil, err
	}
	if r.Consequence, err = field(3, "consequence"); err != nil {
		return nil, err
	}
	if err := checkOtaText("consequence", r.Consequence); err != nil {
		return nil, err
	}
	return r, nil
}

// otaReleaseMatchesSource reports why a verified manifest disagrees with the committed source (nil = it agrees). src
// nil means no file was committed for the version, i.e. the release is ordinary.
func otaReleaseMatchesSource(r, src *otaRelease) error {
	if src == nil {
		if r.mandatory() {
			return fmt.Errorf("the signed manifest says %s, but no ota-mandatory file is committed for %s", r.Severity, r.Version)
		}
		return nil
	}
	if r.Severity != src.Severity || r.Reason != src.Reason || r.Consequence != src.Consequence {
		return fmt.Errorf("the signed manifest says %s %q / %q; the committed file says %s %q / %q -- regenerate and re-sign the manifest",
			r.Severity, r.Reason, r.Consequence, src.Severity, src.Reason, src.Consequence)
	}
	return nil
}

// --- "Sign out & install" (Profile): the user's request, carried across the sign-out to the gate ---
//
// Profile runs in the signed-in user and the install runs from the gate on user 0, after the sign-out has saved the
// session and removed it. The daemon is the one thing both can reach, so it holds the request in RAM, BOUND to the
// session that made it: the Android user id of the requesting Profile (checked against the socket's SO_PEERCRED, never
// taken on the client's word) and a nonce of that Profile instance.
//   - Profile sets it ("1 <uid> <nonce>") immediately before LOGOUT and withdraws its own ("0 <nonce>") if the sign-out
//     is refused. A fresh Profile screen withdraws any pending one ("0") -- a request left by an earlier screen of a
//     session that is still signed in is stale -- EXCEPT while a sign-out is in flight: a Profile re-created mid
//     sign-out (a rotation) must not cancel the install that sign-out is about to deliver.
//   - The gate asks once the reap of user <uid> is done and no relogin is queued (OTA-APPLY-AFTER-LOGOFF <uid>). Only a
//     request made by that same user counts; a reap of any other user (an orphan sweep, a superseded cold lock) leaves
//     it alone.
//   - The daemon then starts the install itself, and only if nothing else is going on: no live or cold-locked session,
//     no session operation in flight, and an update still offered (otaAfterLogoffBlocker). A session operation in
//     flight is TRANSIENT -- the reap's own storage clean-up holds sessionMu for half a minute -- so it answers RETRY
//     and KEEPS the request; only a final answer (started, or refused for a reason that waiting will not change)
//     consumes it (otaAfterLogoffStep). The manual Install button (OTA-APPLY) is unchanged.
//
// The TTL bounds a request whose sign-out never completed and was never withdrawn (a crash). Two hours covers the
// slowest sign-out seal (roamd's anti-wedge watchdog is 22 minutes) many times over. It is measured on Go's MONOTONIC
// clock (the stamp keeps its monotonic reading -- no Round(0)), so a wall-clock change can neither expire a request nor
// revive one. Suspend pauses that clock, which only lengthens the bound; the request still fires only at the reap of the
// user that made it, and a user id is not handed out again within a boot.
const otaAfterLogoffTTL = 2 * time.Hour

type otaAfterLogoffReq struct {
	at    time.Time // zero = no request; carries a monotonic reading
	uid   int
	nonce string
}

var (
	otaAfterLogoffMu  sync.Mutex
	otaAfterLogoffCur otaAfterLogoffReq
)

var otaNonceRe = regexp.MustCompile(`^[0-9a-f-]{8,64}$`)

// otaAfterLogoffCaller checks a "1 <uid> <nonce>" request against the socket peer: the claimed user must be the user
// the connection really comes from (SO_PEERCRED uid / 100000). Withdrawals need no check -- they can only remove.
// peer < 0 (unknown) fails closed.
func otaAfterLogoffCaller(line string, peer int) error {
	f := strings.Fields(line)
	if len(f) == 0 || f[0] != "1" {
		return nil
	}
	if len(f) != 3 {
		return fmt.Errorf("bad request %q", line)
	}
	uid, err := strconv.Atoi(f[1])
	if err != nil || peer < 0 || peer/100000 != uid {
		return fmt.Errorf("request for user %q from peer uid %d", f[1], peer)
	}
	return nil
}

// setOtaAfterLogoff applies one OTA-AFTER-LOGOFF value line: "1 <uid> <nonce>" records a request; "0" withdraws any,
// unless a sign-out is in flight (logoffInFlight), when it changes nothing; "0 <nonce>" withdraws only the request that
// nonce made. Anything else is refused and changes nothing.
func setOtaAfterLogoff(line string, now time.Time, logoffInFlight bool) error {
	f := strings.Fields(line)
	otaAfterLogoffMu.Lock()
	defer otaAfterLogoffMu.Unlock()
	switch {
	case len(f) == 3 && f[0] == "1":
		uid, err := strconv.Atoi(f[1])
		if err != nil || uid <= 0 || !otaNonceRe.MatchString(f[2]) {
			return fmt.Errorf("bad request %q", line)
		}
		otaAfterLogoffCur = otaAfterLogoffReq{at: now, uid: uid, nonce: f[2]}
	case len(f) == 1 && f[0] == "0":
		if !logoffInFlight {
			otaAfterLogoffCur = otaAfterLogoffReq{}
		}
	case len(f) == 2 && f[0] == "0":
		if otaAfterLogoffCur.nonce == f[1] {
			otaAfterLogoffCur = otaAfterLogoffReq{}
		}
	default:
		return fmt.Errorf("bad request %q", line)
	}
	return nil
}

// withdrawOtaAfterLogoffForColdLock drops any pending "Sign out & install" request when a cold lock is taken
// (NWP-20261017-17). A cold lock is a sign-out the request did not start -- the idle timeout takes it without ever
// opening Profile -- and its later wipe reaches maybeInstallAfterLogoff, which would start an install nobody tapped
// at that moment. Unconditional on the uid: the lock ends the session the request was made in.
func withdrawOtaAfterLogoffForColdLock(uid string) {
	otaAfterLogoffMu.Lock()
	dropped := !otaAfterLogoffCur.at.IsZero()
	otaAfterLogoffCur = otaAfterLogoffReq{}
	otaAfterLogoffMu.Unlock()
	if dropped {
		fmt.Fprintf(os.Stderr, "[ota] cold lock for user %s withdrew a pending sign-out-and-install request\n", uid)
	}
}

// otaAfterLogoffPending reports whether a live request made by user uid is pending. It does NOT consume it (see
// otaAfterLogoffStep); an expired request is cleared.
func otaAfterLogoffPending(uid int, now time.Time) bool {
	otaAfterLogoffMu.Lock()
	defer otaAfterLogoffMu.Unlock()
	c := otaAfterLogoffCur
	if c.at.IsZero() {
		return false
	}
	if age := now.Sub(c.at); age >= otaAfterLogoffTTL || age < 0 {
		otaAfterLogoffCur = otaAfterLogoffReq{}
		return false
	}
	return c.uid == uid
}

// consumeOtaAfterLogoff clears the request made by user uid (and only that one), and reports whether there was one to
// clear. The install starts only when this says true: between the pending check and here a drop or the requesting
// Profile's own withdrawal may have removed it, and that must win.
func consumeOtaAfterLogoff(uid int) bool {
	otaAfterLogoffMu.Lock()
	defer otaAfterLogoffMu.Unlock()
	if otaAfterLogoffCur.at.IsZero() || otaAfterLogoffCur.uid != uid {
		return false
	}
	otaAfterLogoffCur = otaAfterLogoffReq{}
	return true
}

// otaAfterLogoffBlocker says why a pending request must NOT start the install now ("" = nothing stands in the way).
func otaAfterLogoffBlocker(sessionOpFree, liveSession, coldLocked, avail bool) string {
	switch {
	case !sessionOpFree:
		return "busy" // a session operation is in flight (the reap's clean-up, a login): transient
	case liveSession:
		return "session"
	case coldLocked:
		return "coldlock"
	case !avail:
		return "none" // no update is offered any more
	}
	return ""
}

// otaAfterLogoffStep turns (is a request pending for this user, what blocks it) into the reply and whether the
// request is consumed: NONE (nothing to do), RETRY (transient: keep it, the gate asks again), REFUSED (final: consume
// it -- whatever superseded it wins, and the update is still offered in Settings), APPLY (start it and consume it).
func otaAfterLogoffStep(pending bool, blocker string) (action string, consume bool) {
	switch {
	case !pending:
		return "NONE", false
	case blocker == "busy":
		return "RETRY", false
	case blocker != "":
		return "REFUSED", true
	}
	return "APPLY", true
}

// otaMandatorySourceFile reads and validates a committed editions/endospore/ota-mandatory/<version> file.
func otaMandatorySourceFile(path string) (*otaRelease, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseOtaMandatorySource(string(b))
}

// limitBody bounds a store read: max <= 0 reads everything (the default for every existing caller), otherwise at most
// max bytes reach the caller.
func limitBody(r io.Reader, max int64) io.Reader {
	if max <= 0 {
		return r
	}
	return io.LimitReader(r, max)
}

// getBlobSoftMax is getBlobSoft reading at most max bytes (0 = no bound).
func getBlobSoftMax(base, hash string, max int64) ([]byte, bool) {
	key := "blob/" + hash
	if isS3(base) {
		if capMode() {
			return capGetMax(key, max)
		}
		return s3GetMax(key, max)
	}
	resp, err := http.Get(base + "/" + key)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	b, err := io.ReadAll(limitBody(resp.Body, max))
	if err != nil {
		return nil, false
	}
	return b, true
}
