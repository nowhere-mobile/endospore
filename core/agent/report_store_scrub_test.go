package main

// A self-hosted store's endpoint host and bucket leave issue reports (h57 #5, NWP-20261205-13). handleSetStore
// logs the raw endpoint and bucket to login.log and logSafeStoreErr keeps the host, both on purpose: the device's
// own log keeps them. The report is what leaves the device, so its scrub replaces them (storeScrubPairs in
// redactIssueSecrets) on every log line, caller status value and the note. A managed report is unchanged.
// test-report-store-scrub.sh --mutate holds these tests to that shape.

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const storeScrubBlob = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// storeScrubLoginLog is the login.log both report tests build over: (a) the handleSetStore config line, (b) a store
// error in the shape logSafeStoreErr leaves, (c) a later line naming the bare hostname, (d) a virtual-host URL, (e)
// an unquoted path-style URL with its port (the quoted-token rule in scrubIssueLine can rewrite (b) first).
func storeScrubLoginLog(ep, bk string) string {
	return fmt.Sprintf("[logind] store config updated (%s / %s)\n", ep, bk) +
		`[roam] push: Put "https://store.example.test:9443/nw-bucket-7/blob/` + storeScrubBlob + `": dial tcp: lookup store.example.test: no such host` + "\n" +
		"[roam] resolver: store.example.test unreachable\n" +
		"[roam] head: GET https://nw-bucket-7.store.example.test/head -> 503\n" +
		"[roam] head: GET https://store.example.test:9443/nw-bucket-7/head -> 503\n"
}

const storeScrubNote = "cannot reach store.example.test since this morning"

func storeScrubExtra() map[string]string {
	return map[string]string{"probe": "https://Store.Example.test:9443/nw-bucket-7 timeout"}
}

// storeScrubTexts is every string of the report the store pass runs over: the log lines, the caller's status
// values and the note. The report's own status keys are fixed vocabulary and are not part of it.
func storeScrubTexts(rep issueReport, extra map[string]string) []string {
	var out []string
	for _, lines := range rep.Logs {
		out = append(out, lines...)
	}
	for k := range extra {
		out = append(out, rep.Status[k])
	}
	return append(out, rep.Note)
}

func TestSessionReportScrubsSelfHostedStore(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	const ep, bk = "https://Store.Example.test:9443/", "nw-bucket-7"
	t.Setenv("S3_ENDPOINT", ep)
	t.Setenv("S3_BUCKET", bk)
	t.Setenv("S3_ACCESS_KEY", "fake-access-for-test")
	t.Setenv("S3_SECRET_KEY", "fake-secret-for-test")
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")

	logPath := filepath.Join(dir, "login.log")
	before := []byte(storeScrubLoginLog(ep, bk))
	if err := os.WriteFile(logPath, before, 0o600); err != nil {
		t.Fatal(err)
	}
	extra := storeScrubExtra()
	rep := buildIssueReportWith("scrubhost1", false, storeScrubNote, extra, nil, nil)

	if n := len(rep.Logs["login.log"]); n < 5 {
		t.Fatalf("login.log carried %d lines, want the 5 planted: %q", n, rep.Logs["login.log"])
	}
	texts := storeScrubTexts(rep, extra)
	all := strings.Join(texts, "\n")
	for _, s := range texts {
		low := strings.ToLower(s)
		for _, leak := range []string{"https://store.example.test:9443", "store.example.test:9443", "store.example.test", "nw-bucket-7"} {
			if strings.Contains(low, leak) {
				t.Errorf("the report carries %q: %q", leak, s)
			}
		}
		// A shortest-first pass rewrites the hostname inside host:port and leaves the port behind.
		if strings.Contains(s, "9443") {
			t.Errorf("the report carries the store's port (a host:port scrubbed piecemeal): %q", s)
		}
	}
	for _, want := range []string{"<store-host>", "<bucket>"} {
		if !strings.Contains(all, want) {
			t.Errorf("no %s anywhere in the report:\n%s", want, all)
		}
	}
	if got := rep.Status["store_mode"]; got != "self-hosted" {
		t.Errorf("store_mode = %q, want self-hosted", got)
	}
	after, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Errorf("login.log on disk changed: the device's own log keeps the store's host and bucket")
	}
}

// TestManagedReportUnchangedByStoreScrub is a GUARD: it passes on the code before NWP-20261205-13 by design. A
// managed device (no S3_ACCESS_KEY) with stale S3_ENDPOINT/S3_BUCKET in its env builds the report it builds
// without them.
func TestManagedReportUnchangedByStoreScrub(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	t.Setenv("GATEWAY_URL", "https://gw.example.test")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")
	t.Setenv("S3_ACCESS_KEY", "")
	t.Setenv("S3_SECRET_KEY", "")
	t.Setenv("S3_ENDPOINT", "https://store.example.test:9443")
	t.Setenv("S3_BUCKET", "nw-bucket-7")
	if err := os.WriteFile(filepath.Join(dir, "login.log"), []byte(storeScrubLoginLog("https://store.example.test:9443", "nw-bucket-7")), 0o600); err != nil {
		t.Fatal(err)
	}
	extra := storeScrubExtra()
	stale := buildIssueReportWith("scrubhost2", false, storeScrubNote, extra, nil, nil)
	t.Setenv("S3_ENDPOINT", "")
	t.Setenv("S3_BUCKET", "")
	clean := buildIssueReportWith("scrubhost2", false, storeScrubNote, extra, nil, nil)

	if !reflect.DeepEqual(stale.Logs, clean.Logs) {
		t.Errorf("managed logs differ with stale S3_ENDPOINT/S3_BUCKET:\nstale %q\nclean %q", stale.Logs, clean.Logs)
	}
	if stale.Note != clean.Note {
		t.Errorf("managed note differs: %q vs %q", stale.Note, clean.Note)
	}
	for k := range extra {
		if stale.Status[k] != clean.Status[k] {
			t.Errorf("managed status %s differs: %q vs %q", k, stale.Status[k], clean.Status[k])
		}
	}
	if got := stale.Status["store_mode"]; got != "managed" {
		t.Errorf("store_mode = %q, want managed", got)
	}
	if all := strings.Join(storeScrubTexts(stale, extra), "\n"); !strings.Contains(strings.ToLower(all), "store.example.test") {
		t.Errorf("a managed report lost the host text it carries today:\n%s", all)
	}
}

// TestFingerprintShapedStatusValueScrubsStore: statusValue's #87 exemption returns a matched build fingerprint
// unscrubbed, and its field charset admits a hostname, a host:port and a bucket. The store pass runs first, so a
// fingerprint-SHAPED caller value loses the store; a real fingerprint holding no store string stays byte-identical
// (that half is a guard of #87 and passes on the code before NWP-20261205-13 by design).
func TestFingerprintShapedStatusValueScrubsStore(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("NOWHERE_DIR", dir)
	t.Setenv("S3_ENDPOINT", "https://Store.Example.test:9443/")
	t.Setenv("S3_BUCKET", "nw-bucket-7")
	t.Setenv("S3_ACCESS_KEY", "fake-access-for-test")
	t.Setenv("S3_SECRET_KEY", "fake-secret-for-test")
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("NOWHERE_GATEWAY_DEFAULT", "")

	const shaped = "nw-bucket-7/Store.Example.test/store.example.test:9443/AB1A.260101.001/2026110101:user/release-keys"
	const realFp = "google/lynx/lynx:17/CP2A.260605.012/2026090202:userdebug/release-keys"
	if !reIssueBuildFp.MatchString(shaped) {
		t.Fatalf("the probe value no longer matches reIssueBuildFp, so it does not reach the exemption: %q", shaped)
	}
	extra := map[string]string{"probe_fp": shaped, "os_build": realFp}
	rep := buildIssueReportWith("scrubhost3", false, "", extra, nil, nil)

	got := rep.Status["probe_fp"]
	low := strings.ToLower(got)
	for _, leak := range []string{"store.example.test", "nw-bucket-7"} {
		if strings.Contains(low, leak) {
			t.Errorf("a fingerprint-shaped status value carries %q: %q", leak, got)
		}
	}
	if got := rep.Status["os_build"]; got != realFp {
		t.Errorf("a real fingerprint changed (#87): got %q, want %q", got, realFp)
	}
}

func TestStoreScrubPairsShapes(t *testing.T) {
	const h, b = "<store-host>", "<bucket>"
	for _, tc := range []struct {
		name, gw, ak, ep, bk string
		want                 [][2]string
	}{
		{"scheme and port", "", "ak", "https://h.example.test:9000/", "bkt",
			[][2]string{{"https://h.example.test:9000", h}, {"h.example.test:9000", h}, {"h.example.test", h}, {"bkt", b}}},
		{"scheme, no port", "", "ak", "https://h.example.test", "bkt",
			[][2]string{{"https://h.example.test", h}, {"h.example.test", h}, {"bkt", b}}},
		{"no scheme, port", "", "ak", "h.example.test:9000", "bkt",
			[][2]string{{"h.example.test:9000", h}, {"h.example.test", h}, {"bkt", b}}},
		{"no scheme, no port", "", "ak", "h.example.test", "bkt",
			[][2]string{{"h.example.test", h}, {"bkt", b}}},
		{"IPv4", "", "ak", "http://192.0.2.10:9000", "bkt",
			[][2]string{{"http://192.0.2.10:9000", h}, {"192.0.2.10:9000", h}, {"192.0.2.10", h}, {"bkt", b}}},
		{"IPv6 and port", "", "ak", "https://[2001:db8::1]:9000", "bkt",
			[][2]string{{"https://[2001:db8::1]:9000", h}, {"[2001:db8::1]:9000", h}, {"2001:db8::1", h}, {"bkt", b}}},
		{"2-char bucket dropped", "", "ak", "https://h.example.test", "ab",
			[][2]string{{"https://h.example.test", h}, {"h.example.test", h}}},
		{"empty endpoint", "", "ak", "", "bkt",
			[][2]string{{"bkt", b}}},
		{"managed", "https://gw.example.test", "", "https://h.example.test", "bkt", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("GATEWAY_URL", tc.gw)
			t.Setenv("S3_ACCESS_KEY", tc.ak)
			t.Setenv("S3_ENDPOINT", tc.ep)
			t.Setenv("S3_BUCKET", tc.bk)
			if got := storeScrubPairs(); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("storeScrubPairs() = %q, want %q", got, tc.want)
			}
		})
	}
}
