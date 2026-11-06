package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261010-15: retryVpnup must SAY how the always-on VPN step ended. Before, any OK stopped it silently -- roamd's
// no-helper branch answered OK for work it never did (#122) -- and a give-up after ~90 s left no line at all, so a
// session whose VPN was never applied read exactly like one where it was.

func withVpnupSeams(t *testing.T, replies []string) *int {
	t.Helper()
	oldW, oldS, oldN := vpnupWorker, vpnupSleep, vpnupTries
	t.Cleanup(func() { vpnupWorker, vpnupSleep, vpnupTries = oldW, oldS, oldN })
	calls := 0
	vpnupWorker = func(dest, name, pass, uid string) string {
		calls++
		if calls <= len(replies) {
			return replies[calls-1]
		}
		return replies[len(replies)-1]
	}
	vpnupSleep = func(time.Duration) {}
	vpnupTries = 5
	return &calls
}

func TestRetryVpnupLogsOnlyWhatWasNotDone(t *testing.T) {
	cases := []struct {
		name    string
		replies []string
		calls   int
		want    string // substring of the log; "" = no line at all
	}{
		{"applied after a retry is quiet", []string{"NOTREADY", "OK APPLIED"}, 2, ""},
		{"nothing to apply is quiet", []string{"OK NONE"}, 1, ""},
		{"no helper is logged as NOT applied (#122)", []string{"OK NOHELPER"}, 1, "NOT applied: this image ships no helper"},
		{"an on-demand VPN app is logged as waiting, not applied", []string{"OK DEFERRED"}, 1, "waits for its on-demand app"},
		{"an older roamd's bare OK is not taken as applied", []string{"OK"}, 1, `finished with "OK"`},
		{"giving up is logged with the last reply", []string{"NOTREADY"}, 5, `gave up after 5 tries (last reply "NOTREADY")`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			calls := withVpnupSeams(t, tc.replies)
			// A live session's marker (NWP-20261113-20: retryVpnup stops once its session is gone).
			dest := t.TempDir()
			if err := os.WriteFile(filepath.Join(dest, roamSessionFile), []byte("Secret Profile\npass\n17\n"), 0o600); err != nil {
				t.Fatalf("write marker: %v", err)
			}
			out := captureStderr(t, func() { retryVpnup(dest, "Secret Profile", "pass", "17") })
			if *calls != tc.calls {
				t.Fatalf("worker called %d times, want %d", *calls, tc.calls)
			}
			if tc.want == "" {
				if out != "" {
					t.Fatalf("want no log line, got %q", out)
				}
				return
			}
			if !strings.Contains(out, tc.want) || !strings.Contains(out, "user 17") {
				t.Fatalf("log %q lacks %q or the uid", out, tc.want)
			}
			// The #39 rule: roam and login logs carry no profile name.
			if strings.Contains(out, "Secret") || strings.Contains(out, "Profile") {
				t.Fatalf("log carries the profile name: %q", out)
			}
		})
	}
}

func TestVpnupReplyTokenKeepsOnlyTheFirstLineInASafeSet(t *testing.T) {
	for in, want := range map[string]string{
		"OK APPLIED":            "OK APPLIED",
		"NOTREADY\nsecond line": "NOTREADY",
		"ERR-TIMEOUT":           "ERR-TIMEOUT",
		`ERR "quoted" a@b.c`:    "ERR quoted abc",
		strings.Repeat("A", 80): strings.Repeat("A", 40),
		"":                      "",
	} {
		if got := vpnupReplyToken(in); got != want {
			t.Errorf("vpnupReplyToken(%q) = %q, want %q", in, got, want)
		}
	}
}
