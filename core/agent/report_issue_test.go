package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The scrub is the safety-critical surface of "Report an issue": a leak here ships a credential or a phone
// number off-device. These tests pin the drops, the redactions, and -- most importantly -- an adversarial sweep
// asserting none of a battery of planted secrets survives into the marshaled report body.

func TestScrubDropsCredentialLines(t *testing.T) {
	drop := []string{
		`agent: passphrase rejected for profile`,
		// NWP-20260903-50: this fixture used to read `RECOVERY word1 word2 word3 (recovery phrase)` and
		// passed on the PARENTHETICAL alone -- "recovery phrase" was already a keyword, so the RECOVERY
		// prefix it appeared to pin was never tested. Removing just the parenthetical made the line survive
		// the scrub COMPLETELY UNTOUCHED. This is now the real emitted shape, with no help.
		`RECOVERY abandon ability able about above absent absorb abstract absurd abuse access`,
		`OK 0 RECOVERY abandon ability able about above absent absorb abstract absurd abuse access`,
		`restore mnemonic seed phrase = a b c`,
		`GET https://s3/blob?X-Amz-Signature=deadbeef&X-Amz-Credential=AKIA`,
		`Authorization: Bearer eyJhbGciOiJ`,
		`S3_SECRET_KEY=abc123 loaded`,
		`-----BEGIN PRIVATE KEY-----`,
		`user typed password again`,
	}
	for _, ln := range drop {
		if s, keep := scrubIssueLine(ln, nil); keep {
			t.Errorf("credential line survived scrub: %q -> %q", ln, s)
		}
	}
}

// The other half of the same keyword: "recovery " must NOT eat the diagnostics that merely MENTION
// recovery in passing. login.log is the only diagnostic channel a user build has, so a scrub that
// over-drops is its own defect -- and the corrupt-head-blob failure below is exactly the line you need
// when a head will not load. A bare "recovery" keyword would swallow every one of these.
func TestScrubKeepsRecoveryMentions(t *testing.T) {
	for _, ln := range []string{
		`corrupt head blob in store: blob/abc is 12 bytes -- REFUSING (that would overwrite the vault and drop 2FA/recovery)`,
		`enrolled: hardened (pass-only slot dropped; open via SE device or recovery)`,
	} {
		if _, keep := scrubIssueLine(ln, nil); !keep {
			t.Errorf("diagnostic wrongly dropped -- the keyword is too broad: %q", ln)
		}
	}
}

func TestScrubRedactsProfileName(t *testing.T) {
	for _, ln := range []string{
		`[logind] periodic seal "alice" user 10 -> OK`,
		`restore: profile alice (12 chunks)`,
		`ALICE resumed`, // case-insensitive
	} {
		s, keep := scrubIssueLine(ln, []string{"alice"})
		if !keep {
			t.Fatalf("useful line wrongly dropped: %q", ln)
		}
		if strings.Contains(strings.ToLower(s), "alice") {
			t.Errorf("profile name not redacted: %q -> %q", ln, s)
		}
		if !strings.Contains(s, "<name>") {
			t.Errorf("expected <name> placeholder: %q -> %q", ln, s)
		}
	}
	// A too-short "secret" must never be redacted (would shred normal words).
	if s := redactIssueSecrets("a cat sat", []string{"a"}); s != "a cat sat" {
		t.Errorf("1-char secret must be ignored, got %q", s)
	}
}

func TestScrubRedactsPatterns(t *testing.T) {
	cases := []struct{ in, wantSub, notSub string }{
		{`fetch https://api.nowhere.mobile/cap?op=read&ref=ref%2Fwallet%2Fx`, "?<redacted>", "wallet"},
		{`leased ref/blob/aabbccddeeff00112233445566778899`, "<ref>", "blob/aabb"},
		{`sms from +14155550123 delivered`, "<num>", "4155550123"},
		{`contact bob@example.com bounced`, "<email>", "example.com"},
		{`wifi ssid=HomeSecret joined`, "<ssid>", "HomeSecret"},
		{`bond mac a4:83:e7:11:22:33 paired`, "<mac>", "a4:83:e7"},
		{`profileRef 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa9988 head`, "<hex>", "9f8e7d6c"},
		{`token QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5YWJj redeemed`, "<token>", "QUJDREVGR0hJSktM"},
	}
	for _, c := range cases {
		s, keep := scrubIssueLine(c.in, nil)
		if !keep {
			t.Fatalf("line dropped unexpectedly: %q", c.in)
		}
		if !strings.Contains(s, c.wantSub) {
			t.Errorf("%q -> %q; want substring %q", c.in, s, c.wantSub)
		}
		if c.notSub != "" && strings.Contains(s, c.notSub) {
			t.Errorf("%q -> %q; still leaks %q", c.in, s, c.notSub)
		}
	}
}

func TestScrubRedactsFormattedPhoneKeepsTimestamps(t *testing.T) {
	// Separator-formatted numbers (realistically only via the free-form note) must be caught...
	for _, c := range []struct{ in, notSub string }{
		{"call me at +1 415-555-0123 please", "415"},
		{"reach (415) 555-0123 anytime", "555-0123"},
		{"intl +44 20 7946 0958", "7946"},
	} {
		s := redactIssueSecrets(c.in, nil)
		if strings.Contains(s, c.notSub) {
			t.Errorf("formatted phone leaked: %q -> %q (still has %q)", c.in, s, c.notSub)
		}
	}
	// ...without mangling ISO timestamps (no +/parens), which support needs to read.
	for _, ts := range []string{"2026-07-14 20:53:11", "at 2026-07-14T20:53:11Z", "date 07-14 20:53"} {
		s := redactIssueSecrets(ts, nil)
		if strings.Contains(s, "<num>") {
			t.Errorf("timestamp wrongly redacted: %q -> %q", ts, s)
		}
	}
}

func TestScrubKeepsUsefulBenignLines(t *testing.T) {
	// Operational lines the support engineer needs must survive (only the name redacted).
	for _, ln := range []string{
		`[logind] mediad kicked for user 10`,
		`[logind] wifi-mirror: 2 network(s) queued for the gate`,
		`  retry cap GET (5/5): dial tcp: network is unreachable`,
		`seal v3 ok epoch 42`,
	} {
		s, keep := scrubIssueLine(ln, []string{"alice"})
		if !keep {
			t.Errorf("benign line wrongly dropped: %q", ln)
		}
		if s == "" {
			t.Errorf("benign line blanked: %q", ln)
		}
	}
}

// TestReportAdversarialSweep plants every secret class into logs + note + status, builds the full report, and
// asserts NONE of the raw secrets appears anywhere in the marshaled body. This is the gun-safety test.
func TestReportAdversarialSweep(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	t.Setenv("GATEWAY_URL", "https://api.nowhere.mobile")
	t.Setenv("S3_ACCESS_KEY", "")

	planted := []string{
		"alice",                        // profile name
		"correct horse battery staple", // (in a passphrase line -> whole line dropped)
		"+14155550123",                 // phone
		"bob@example.com",              // email
		"HomeSecretSSID",               // wifi
		"a4:83:e7:11:22:33",            // mac
		"9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa9988", // hex ref
		"AKIAIOSFODNN7EXAMPLE",                             // an access-key-ish token
		"ref/wallet/alice",                                 // store ref
	}
	loglines := []string{
		`[logind] periodic seal "alice" user 10 -> OK`,
		`agent: passphrase "correct horse battery staple" rejected`,
		`sms from +14155550123 to alice`,
		`export mailed to bob@example.com`,
		`wifi ssid=HomeSecretSSID joined`,
		`bt bond a4:83:e7:11:22:33`,
		`GET https://api.nowhere.mobile/cap?op=read&ref=ref%2Fwallet%2Falice`,
		`leased ref/wallet/alice size 0`,
		`profileRef 9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa9988`,
		`S3_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE`,
	}
	if err := os.WriteFile(filepath.Join(dir, "login.log"), []byte(strings.Join(loglines, "\n")), 0o600); err != nil {
		t.Fatal(err)
	}

	// NWP-20261010-06: the uiderrors section rides the same sweep, with every planted class in its lines too.
	uiderrors := func() string {
		return "OK 4096 0 0 10\n" + strings.Join([]string{
			"10/10/26, 5:04 PM: Destroying /data/user_de/10/com.example.alice.notes due to: com.android.server.pm.PackageManagerException: Package com.example.alice.notes is unknown",
			"10/10/26, 5:05 PM: Destroying /data/user/10/org.example.sync due to: token=9f8e7d6c5b4a39281706f5e4d3c2b1a0ffeeddccbbaa9988 ref/wallet/alice",
			"10/10/26, 5:06 PM: Package com.example.dialer mismatched uid; last caller +14155550123 bob@example.com ssid=HomeSecretSSID",
			"10/10/26, 5:07 PM: Destroying /data/user_de/10/com.example.bt due to: bond a4:83:e7:11:22:33 S3_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE",
			`10/10/26, 5:08 PM: Wiping com.example.vault: passphrase "correct horse battery staple" store rebuilt`,
		}, "\n")
	}
	rep := buildIssueReport("alice", false, "please help, my number is +14155550123 and email bob@example.com", nil, uiderrors)
	body, err := json.Marshal(rep)
	if err != nil {
		t.Fatal(err)
	}
	got := string(body)
	for _, sec := range planted {
		if strings.Contains(got, sec) {
			t.Errorf("SECRET LEAKED into report: %q\n---\n%s", sec, got)
		}
	}
	// Sanity: the report is not empty -- it still carries scrubbed operational value.
	if len(rep.Logs["login.log"]) == 0 {
		t.Fatal("report carried no log lines (scrub ate everything)")
	}
	// ...and the uiderrors section still names what it exists to name: the packages and the dirs.
	ue := uiderrorsJSON(t, rep)
	for _, keep := range []string{"/data/user_de/10/com.example.", "org.example.sync due to:", "com.example.dialer mismatched uid", "com.example.bt due to:"} {
		if !strings.Contains(ue, keep) {
			t.Errorf("the scrub ate %q from the uiderrors section:\n%s", keep, ue)
		}
	}
	if rep.Status["store_mode"] != "managed" {
		t.Errorf("store_mode = %q, want managed", rep.Status["store_mode"])
	}
}

func TestTrimIssueReportUnderCeiling(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	// A log far larger than the ceiling; every line benign so nothing is dropped by scrub.
	var b strings.Builder
	for i := 0; i < 20000; i++ {
		b.WriteString("[logind] periodic seal user 10 -> OK some filler to add bytes here and there\n")
	}
	if err := os.WriteFile(filepath.Join(dir, "roam.log"), []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	rep := buildIssueReport("", false, "", nil, nil)
	body, _ := json.Marshal(rep)
	if len(body) > maxIssueReportBytes {
		t.Fatalf("report %d bytes exceeds ceiling %d", len(body), maxIssueReportBytes)
	}
}

// TestIssueReportRedactsDepartedProfileNames (DIA-20260807-11) reproduces the leak the amnesia coverage
// sweep found and lynx confirmed: buildIssueReport seeds `secrets` with the LIVE profile name only, so every
// OTHER identity that ever used the handset survived the scrub -- into the on-screen "View what's sent"
// preview and into the uploaded body. The lines below are verbatim shapes taken off lynx 2026-08-07.
func TestIssueReportRedactsDepartedProfileNames(t *testing.T) {
	const live = "currentuser"
	departed := []string{"odtest35", "odtest10", "cm"}

	lines := []string{
		`[roamd] OUT odtest35 #sys accounts push rc=0 Fri Aug  7 18:48:51 EDT 2026`,
		`[roamd] OUT odtest35 (user 11) +de +media Fri Aug  7 18:49:00 EDT 2026`,
		`[roamd] IN odtest10 -> user 12 (+de +media)`,
		// NWP-20261008-09: `[roamd] GRANT cm -> 134 perms (user 12)` stood here. It came in with this test (20eb8343),
		// and no roamd ever printed a name in that line: every version prints `GRANT -> $n perms`, or from d47fe77c on
		// `GRANT (<package filter>) -> $n perms` (git log -G'GRANT.*-> \$n perms' -- nowhere_roamd.sh: a3a65d70,
		// d47fe77c, ba5080ba). The old one-word rule ate whatever followed GRANT, so the fixture passed; the scrub now
		// keeps that name-less line whole (TestIssueReportNameRulesKeepTheDiagnostics), so it is gone from this list.
		`[logind] periodic seal "odtest35" user 11 -> OK`,
		`[logind] roam-in "odtest10" -> user 12`,
		// DIA-20260807-13: the shapes the first pass missed. roamd appends the AGENT's output straight into
		// roam.log, so these arrive with no bracket tag at all; and mediad writes a bare verb form. All four
		// logs this report ships carry them. Verbatim from lynx 2026-08-07.
		`restore: profile "odtest35" (legacy 1024 B) -> /data/user/11`,
		`push: profile "odtest35" (vault) -> 18 chunks (0 net-skipped, 0 crypto-skipped), gen 7a8f1a1c v9 in 8.2s`,
		`mediad: profile "odtest10" deferred 42 files`,
		`[mediad] start cm -> user 11 Fri Aug  7 07:36:19 EDT 2026`,
		// DIA-20260807-14: the shapes round three still missed, again found on the device. Note the SECOND
		// quoted token on the pay-rent line -- the old first-match rule redacted only the first.
		`mediad: serving 2 overlay(s) for "odtest10"`,
		`[logind] pay-rent "odtest35": free tier unavailable for "odtest35" (HTTP 402) -- add credit`,
		// NWP-20260922-05: the fido2 shapes. #81 and NWP-20260824-05 added five roamd lines that name the
		// profile after a verb NONE of the positional rules carry (fido2-enroll / fido2 profile), and they
		// joined neither this list nor roamd's own log_scrub -- so on a handset whose owner uses a security
		// key, every login left the name in roam.log permanently (it is on plain /data, which the boot-wipe
		// cannot reach because that works by removing a USER). Fixed at the EMITTER: roamd now quotes the
		// name, which puts it under the default-deny quoted-token rule both scrubbers already carry -- no
		// fifth pattern, in a list that has now drifted three times. These are the emitted forms verbatim;
		// that roamd really emits them THIS way is the other half, asserted by test-log-name-scrub.sh.
		`[roamd] fido2 profile "odtest35" -> requesting the security key Mon Sep 22 08:00:00 EDT 2026`,
		`[roamd] fido2 profile "odtest10" -> NFC-first: no USB flip, returning NEEDKEY Mon Sep 22 08:00:00 EDT 2026`,
		`[roamd] fido2-enroll OK for "cm" Mon Sep 22 08:00:00 EDT 2026`,
		`[roamd] fido2-enroll FAILED for "odtest35" Mon Sep 22 08:00:00 EDT 2026`,
	}
	for _, ln := range lines {
		got, keep := scrubIssueLine(ln, []string{live})
		if !keep {
			continue // dropped entirely by a drop-keyword; nothing can leak from a line that is not sent
		}
		for _, d := range departed {
			if strings.Contains(got, d) {
				t.Errorf("departed profile %q survived the scrub:\n  in:  %s\n  out: %s", d, ln, got)
			}
		}
		if !strings.Contains(got, "<name>") {
			t.Errorf("no redaction marker, so the name position was not matched:\n  in:  %s\n  out: %s", ln, got)
		}
	}
}

// TestIssueReportKeepsRestorePaths guards the scope of the above: `[restore] skip %q` quotes FILE PATHS, and
// those are what make a broken restore diagnosable (they are how DIA-20260806-10 was found). They are not
// identity and must survive. A scrub that eats them trades a real leak for a real blindness.
// *(Since NWP-20261201-24, h60 #9: the skip lines print `pkg=` or `scope=` and an error code, no path. The exemption
// now serves the `[restore] rejected ...` lines and the skip lines older builds wrote; the input below is one of those.)*
func TestIssueReportKeepsRestorePaths(t *testing.T) {
	ln := `[restore] skip "net.thunderbird.android/databases/global.db": mkdir parent: permission denied`
	got, _ := scrubIssueLine(ln, []string{"currentuser"})
	if !strings.Contains(got, "net.thunderbird.android") {
		t.Errorf("restore path was redacted; a denied-restore report becomes undiagnosable:\n  out: %s", got)
	}
}

// TestGateScopeExcludesSessionLogs (NWP-20260819-01) pins the gate reporter's blind-login boundary: with
// device scope the report must carry ONLY device-level logs. login.log is the sharp one -- its verbs
// ("roam-in BLANK" vs "-> user" vs "NEEDKEY") are a profile-existence oracle that the name scrub cannot
// close, and the preview path renders the report on-screen at the gate. If this test fails, the gate has
// become a no-network oracle for whoever holds the handset.
func TestGateScopeExcludesSessionLogs(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	for _, f := range []string{"login.log", "roam.log", "mediad.log", "provision.log", "ota.log"} {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("[x] benign line for "+f+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	rep := buildIssueReport("", true, "", nil, nil)
	for _, banned := range []string{"login.log", "roam.log", "mediad.log"} {
		if _, ok := rep.Logs[banned]; ok {
			t.Errorf("device-scope report carries session log %q -- the gate preview is an existence oracle again", banned)
		}
	}
	for _, want := range []string{"ota.log", "provision.log"} {
		if _, ok := rep.Logs[want]; !ok {
			t.Errorf("device-scope report is missing %q, the log it exists to carry", want)
		}
	}
}

// TestSessionScopeCarriesOtaLog (NWP-20260819-01): ota.log joins the SESSION set too -- update_engine's
// rejection reason lands there and nowhere else, and its absence is why #740 was diagnosed by hypothesis.
func TestSessionScopeCarriesOtaLog(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	if err := os.WriteFile(filepath.Join(dir, "ota.log"), []byte("[otad] update_engine FAILED/timeout\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rep := buildIssueReport("alice", false, "", nil, nil)
	if len(rep.Logs["ota.log"]) == 0 {
		t.Fatal("session report dropped ota.log -- OTA failures are a black box again")
	}
}

// TestTrimOrderReachesEverySection guards trimIssueReport's delete list: a section key missing from
// issueTrimOrder is never deleted, so it silently becomes the most privileged thing in the report. The
// review of the first cut (NWP-20260819-01) found it inert twice over: it compared collection against its
// OWN copy of the list (deleting a key from the real one stayed green), and its fixture could never exceed
// the ceiling (scrubIssueLog caps every log at 300 lines first), so trim never ran at all. Now: every
// collected section must appear in THE real issueTrimOrder, at both scopes.
func TestTrimOrderReachesEverySection(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	long := strings.Repeat("[x] filler line that is entirely benign and adds bytes\n", 400)
	for _, f := range []string{"login.log", "roam.log", "mediad.log", "provision.log", "ota.log"} {
		if err := os.WriteFile(filepath.Join(dir, f), []byte(long), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	for _, scope := range []bool{false, true} {
		rep := buildIssueReport("", scope, "", nil, nil)
		mergeGmsState(&rep, func() string { return "OK 0\n--\n" }, scope) // NWP-20261201-01: a section buildIssueReport does not add
		if _, got := rep.Logs["gms"]; got == scope {
			t.Errorf("scope=%v: gms section present=%v -- the session scope collects it and the gate scope does not", scope, got)
		}
		for key := range rep.Logs {
			found := false
			for _, o := range issueTrimOrder { // THE list, not a copy
				if o == key {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("scope=%v: collected section %q is absent from issueTrimOrder -- it can never be deleted", scope, key)
			}
		}
	}
}

// TestTrimActuallyDeletesInOrder exercises the delete path itself, which buildIssueReport can never reach
// (the per-log 300-line cap keeps its output under the ceiling): hand-build a report whose sections are each
// few-lined but huge, so halving is unavailable (needs >40 lines) and deletion is the only move. The trim
// must land under the ceiling and must have deleted a strict PREFIX of issueTrimOrder -- earlier keys gone
// before later ones survive.
func TestTrimActuallyDeletesInOrder(t *testing.T) {
	huge := strings.Repeat("x", 2000)
	rep := issueReport{Kind: "issue-report", Status: map[string]string{}, Logs: map[string][]string{}}
	for _, k := range issueTrimOrder {
		lines := make([]string, 20) // <= 40 lines: the halving step cannot apply, only deletion can
		for i := range lines {
			lines[i] = huge
		}
		rep.Logs[k] = lines
	}
	trimIssueReport(&rep)
	b, _ := json.Marshal(rep)
	if len(b) > maxIssueReportBytes {
		t.Fatalf("trim left %d bytes, ceiling is %d", len(b), maxIssueReportBytes)
	}
	deletedPrefix := true
	for _, k := range issueTrimOrder {
		if _, ok := rep.Logs[k]; ok {
			deletedPrefix = false // first survivor: everything after must also survive
		} else if !deletedPrefix {
			t.Errorf("section %q was deleted although an earlier-in-order section survived", k)
		}
	}
	if _, ok := rep.Logs["avc"]; !ok && len(rep.Logs) > 0 {
		t.Error("avc was deleted while other sections survived -- it is deliberately last")
	}
}

// TestIssueGatewayURLFallback (NWP-20260819-01): a never-enrolled device has no GATEWAY_URL by construction
// (the setup rings bake only NOWHERE_GATEWAY_DEFAULT), and enrolment failures are exactly what the gate
// reporter exists to carry. Enrolled wins when both are set.
func TestIssueGatewayURLFallback(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "https://api-beta.example/")
	if got := issueGatewayURL(); got != "https://api-beta.example" {
		t.Errorf("fallback = %q, want the trimmed default", got)
	}
	t.Setenv("GATEWAY_URL", "https://api.example/")
	if got := issueGatewayURL(); got != "https://api.example" {
		t.Errorf("enrolled URL = %q, want GATEWAY_URL to win", got)
	}
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")
	if got := issueGatewayURL(); got != "" {
		t.Errorf("both empty should yield %q (ERR-NOGW), got %q", "", got)
	}
}
