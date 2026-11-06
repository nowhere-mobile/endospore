package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// #21: OTA-STATUS must surface an in-flight or failed install from otad's $STATE/ota.res, and defer to the
// live published-vs-installed check (return "") for absent / terminal-idle phases -- otherwise re-entering the
// screen mid-apply re-offers "Update available" and a silent failure looks like success.
func TestOtaResState(t *testing.T) {
	dest := t.TempDir()
	res := filepath.Join(dest, "ota.res")

	cases := []struct{ file, want string }{
		{"STAGING", "DOWNLOADING"},
		{"STAGING\n", "DOWNLOADING"},
		{"APPLYING 0.4.0", "APPLYING 0.4.0"},
		{"APPLYING ?", "APPLYING"},     // otad writes "?" when the version is unknown -> no bogus " ?" suffix
		{"OK 0.4.0", "APPLYING 0.4.0"}, // applied, reboot imminent -> keep showing "Installing"
		{"ERR-RESTORE", "FAILED ERR-RESTORE"},
		{"ERR-PAYLOAD", "FAILED ERR-PAYLOAD"},
		{"ERR-APPLY", "FAILED ERR-APPLY"},
		{"UPTODATE 0.4.0", ""}, // terminal-idle -> defer to the live check
		{"NONE", ""},
		{"", ""},          // empty file
		{"   \n", ""},     // whitespace only
		{"WHAT-EVEN", ""}, // unknown token -> defer, never mislead
	}
	for _, c := range cases {
		if err := os.WriteFile(res, []byte(c.file), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := otaResState(dest); got != c.want {
			t.Errorf("ota.res=%q: got %q, want %q", c.file, got, c.want)
		}
	}

	// Absent file -> "" (fall through to the live check).
	os.Remove(res)
	if got := otaResState(dest); got != "" {
		t.Errorf("absent ota.res: got %q, want \"\"", got)
	}
}

// #93: "cannot check" must never be reported as "up to date". The old code answered NONE whenever no
// successful check had completed, and the gate renders NONE as "Up to date" -- so a device that had never
// once reached the store told its owner it was current, indistinguishably from a real check. Worse, the
// refresh was skipped outright whenever S3_ENDPOINT was empty, which is EVERY managed (cap-mode) device:
// getRef reads the pointer through capGet in that mode and never touches S3_ENDPOINT at all, so the cache
// was never populated on the entire enrolled fleet.
//
// otaWhyUnknown is what lets the handler tell the three apart. It reads shared state, so each case resets
// it explicitly rather than relying on order.
func TestOtaWhyUnknownDistinguishesNoStoreFromUnreachable(t *testing.T) {
	reset := func() {
		otaCacheMu.Lock()
		otaLastTry, otaLastErr = time.Time{}, ""
		otaCacheMu.Unlock()
	}
	t.Cleanup(reset)

	// never attempted -> "pending" (boot / cold-lock). NOT an error, and NOT "up to date".
	reset()
	if got := otaWhyUnknown(); got != "pending" {
		t.Errorf("no attempt yet: got %q, want pending", got)
	}

	// attempted, but there is no store to ask at all (un-enrolled device).
	reset()
	otaCacheMu.Lock()
	otaLastTry, otaLastErr = time.Now(), "no-store"
	otaCacheMu.Unlock()
	if got := otaWhyUnknown(); got != "no-store" {
		t.Errorf("no store: got %q, want no-store", got)
	}

	// attempted and the store could not be reached -> "couldn't check", never "up to date".
	reset()
	otaCacheMu.Lock()
	otaLastTry, otaLastErr = time.Now(), "unreachable"
	otaCacheMu.Unlock()
	if got := otaWhyUnknown(); got != "unreachable" {
		t.Errorf("unreachable: got %q, want unreachable", got)
	}

	// a LATER success clears the error, so a transient outage does not stick as a permanent warning.
	reset()
	otaCacheMu.Lock()
	otaLastTry, otaLastErr = time.Now(), ""
	otaCacheMu.Unlock()
	if got := otaWhyUnknown(); got != "pending" {
		t.Errorf("after success with no cached answer: got %q, want pending", got)
	}
}
