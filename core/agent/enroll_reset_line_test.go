package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261119-22 (h49 #11, docs/product-decisions.md 2026-10-31): a create-throttle file that is there but cannot be
// read, does not parse or has no positive timestamp gives a full bucket, as a missing file does, on purpose. The
// damaged case logs one line with a fixed reason word; a missing file and a valid bucket log nothing. The line never
// prints the file's bytes or a profile.

const enrollResetMark = "[logind] enroll: the create throttle at "

// enrollPlanted is a profile-like string planted in a damaged file; the reset line must never carry it.
const enrollPlanted = "odresetprobe-Profile-Name"

// enrollResetLines returns the stderr lines that are the reset line.
func enrollResetLines(out string) []string {
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if strings.Contains(l, enrollResetMark) {
			lines = append(lines, l)
		}
	}
	return lines
}

func plantEnroll(t *testing.T, state string, raw []byte) {
	t.Helper()
	if err := os.WriteFile(state, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

// enrollSixCreates makes six creates in one capture and returns how many were allowed, whether the 6th was denied,
// and the stderr text.
func enrollSixCreates(t *testing.T) (allowed int, sixthDenied bool, out string) {
	t.Helper()
	out = captureStderr(t, func() {
		for i := 0; i < 6; i++ {
			ok, _ := enrollAllow()
			if i < 5 && ok {
				allowed++
			}
			if i == 5 {
				sixthDenied = !ok
			}
		}
	})
	return allowed, sixthDenied, out
}

// checkResetLine asserts exactly one reset line, naming the path, the reason word and the full bucket of 5, and no
// planted string anywhere in stderr.
func checkResetLine(t *testing.T, state, why, out string) {
	t.Helper()
	lines := enrollResetLines(out)
	if len(lines) != 1 {
		t.Fatalf("want exactly one reset line, got %d; stderr:\n%s", len(lines), out)
	}
	l := lines[0]
	for _, want := range []string{state, "(" + why + ")", "full bucket of 5", "h49 #11, by design"} {
		if !strings.Contains(l, want) {
			t.Errorf("reset line lacks %q: %s", want, l)
		}
	}
	if strings.Contains(l, enrollPlanted) {
		t.Errorf("reset line prints the file's content: %s", l)
	}
}

func TestEnrollResetLineUnparsable(t *testing.T) {
	state := setEnrollEnv(t, "5", "3600")
	plantEnroll(t, state, []byte(`{"tokens": `+enrollPlanted))
	allowed, denied, out := enrollSixCreates(t)
	if allowed != 5 || !denied {
		t.Fatalf("an unparsable file must give a full bucket of 5: allowed %d of 5, 6th denied %v", allowed, denied)
	}
	checkResetLine(t, state, "unparsable", out)
	if strings.Contains(out, enrollPlanted) {
		t.Errorf("stderr prints the file's content:\n%s", out)
	}
}

func TestEnrollResetLineNoTimestamp(t *testing.T) {
	state := setEnrollEnv(t, "5", "3600")
	// tokens 0 shows the file's count is not used when the timestamp is not positive.
	plantEnroll(t, state, []byte(`{"tokens":0,"ts":0}`))
	allowed, denied, out := enrollSixCreates(t)
	if allowed != 5 || !denied {
		t.Fatalf("a ts=0 file must give a full bucket of 5: allowed %d of 5, 6th denied %v", allowed, denied)
	}
	checkResetLine(t, state, "no-timestamp", out)
}

func TestEnrollResetLineReadError(t *testing.T) {
	state := setEnrollEnv(t, "5", "3600")
	if err := os.Mkdir(state, 0o700); err != nil {
		t.Fatal(err)
	}
	plantEnroll(t, filepath.Join(state, enrollPlanted), []byte(enrollPlanted))
	var ok bool
	out := captureStderr(t, func() { ok, _ = enrollAllow() })
	if !ok {
		t.Fatal("a file that cannot be read must give a full bucket: the create was denied")
	}
	// The save fails on a directory and prints its own line; only the reset line is checked.
	checkResetLine(t, state, "read-error", out)
}

func TestEnrollResetLineMissingIsSilent(t *testing.T) {
	setEnrollEnv(t, "5", "3600")
	allowed, denied, out := enrollSixCreates(t)
	if allowed != 5 || !denied {
		t.Fatalf("a missing file must give a full bucket of 5: allowed %d of 5, 6th denied %v", allowed, denied)
	}
	if lines := enrollResetLines(out); len(lines) != 0 {
		t.Fatalf("a missing file is an unseen device and must log no reset line, got:\n%s", out)
	}
}

func TestEnrollResetLineValidEmptyIsSilent(t *testing.T) {
	state := setEnrollEnv(t, "5", "3600")
	raw, err := json.Marshal(enrollBucket{Tokens: 0, TS: time.Now().Unix()})
	if err != nil {
		t.Fatal(err)
	}
	plantEnroll(t, state, raw)
	var ok bool
	var retry int
	out := captureStderr(t, func() { ok, retry = enrollAllow() })
	if ok || retry < 1 {
		t.Fatalf("a valid empty bucket must deny at once with a retry: ok %v retry %d", ok, retry)
	}
	if lines := enrollResetLines(out); len(lines) != 0 {
		t.Fatalf("a valid bucket must log no reset line, got:\n%s", out)
	}
}
