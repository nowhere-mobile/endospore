package main

import (
	"strings"
	"testing"
	"time"
)

// NWP-20261205-03: an in-session issue report carries, for each health rule with a Fix, the seconds since this
// session's last successful Fix (fix_age=<s>) or fix=none, beside bad_for. The seams are package vars, so none of these
// tests may run in parallel. Each test has its own uid and profile name.

// hfaFiring gives uid a FIRING play-push-frozen result at the fixture's clock.
func hfaFiring(clock time.Time, uid string) {
	healthState = newHealthResults(uid)
	healthState.results[0] = healthBadResult(clock)
}

func TestHealthFixAgeRecorded(t *testing.T) {
	clock, _, _ := healthFixture(t)
	hfaFiring(*clock, "61")
	healthFixRecord("61", "play-push-frozen", clock.Add(-600*time.Second))
	st := map[string]string{}
	mergeHealth(st, "61", false)
	if got := st["health_play_push_frozen"]; got != "FIRING age=30 adj=920 state=CAC bound=0 bad_for=1170 fix_age=600" {
		t.Errorf("health_play_push_frozen = %q, want it to end with bad_for=1170 fix_age=600", got)
	}
}

func TestHealthFixAgeNone(t *testing.T) {
	clock, _, _ := healthFixture(t)
	hfaFiring(*clock, "60")
	st := map[string]string{}
	mergeHealth(st, "60", false)
	if got := st["health_play_push_frozen"]; !strings.HasSuffix(got, " bad_for=1170 fix=none") {
		t.Errorf("health_play_push_frozen = %q, want it to end with bad_for=1170 fix=none", got)
	}
}

// A report for another uid must neither see the Fix nor reset the recorded state.
func TestHealthFixAgeOtherUID(t *testing.T) {
	clock, _, _ := healthFixture(t)
	hfaFiring(*clock, "63")
	healthFixRecord("62", "play-push-frozen", clock.Add(-60*time.Second))
	st := map[string]string{}
	mergeHealth(st, "63", false)
	if got := st["health_play_push_frozen"]; !strings.HasSuffix(got, " fix=none") || strings.Contains(got, "fix_age=") {
		t.Errorf("health_play_push_frozen = %q, want it to end with fix=none", got)
	}
	healthFixState.Lock()
	uid := healthFixState.uid
	_, has := healthFixState.at["play-push-frozen"]
	healthFixState.Unlock()
	if uid != "62" || !has {
		t.Errorf("the report reset the Fix state: uid %q, entry present %v; want uid \"62\" with its entry", uid, has)
	}
}

func TestHealthFixAgeClockBack(t *testing.T) {
	clock, _, _ := healthFixture(t)
	hfaFiring(*clock, "65")
	healthFixRecord("65", "play-push-frozen", clock.Add(30*time.Second))
	st := map[string]string{}
	mergeHealth(st, "65", false)
	if got := st["health_play_push_frozen"]; !strings.HasSuffix(got, " fix_age=0") || strings.Contains(got, "fix_age=-") {
		t.Errorf("health_play_push_frozen = %q, want it to end with fix_age=0", got)
	}
}

func TestHealthFixAgeNoFixRule(t *testing.T) {
	clock, _, _ := healthFixture(t)
	prevRules := healthRules
	t.Cleanup(func() { healthRules = prevRules })
	healthRules = append(healthRules[:len(healthRules):len(healthRules)],
		healthRule{id: "no-fix-rule", statusKey: "health_no_fix_rule", apply: func(*healthRuleResult, healthProbe, time.Time) {}})
	hfaFiring(*clock, "66")
	healthState.results[1] = healthBadResult(*clock)
	healthFixRecord("66", "play-push-frozen", clock.Add(-60*time.Second))
	st := map[string]string{}
	mergeHealth(st, "66", false)
	got, ok := st["health_no_fix_rule"]
	if !ok || strings.Contains(got, "fix_age=") || strings.Contains(got, "fix=none") {
		t.Errorf("health_no_fix_rule = %q (present %v), want it present with no Fix field", got, ok)
	}
	if got := st["health_play_push_frozen"]; !strings.HasSuffix(got, " fix_age=60") {
		t.Errorf("health_play_push_frozen = %q, want it to end with fix_age=60", got)
	}
}

func TestHealthFixAgeGateScope(t *testing.T) {
	clock, _, _ := healthFixture(t)
	hfaFiring(*clock, "67")
	healthFixRecord("67", "play-push-frozen", clock.Add(-60*time.Second))
	st := map[string]string{"keep": "k"}
	mergeHealth(st, "67", true)
	for k, v := range st {
		if strings.HasPrefix(k, "health_") {
			t.Errorf("a gate report carries %s=%q", k, v)
		}
	}
}

// TestHealthFixAgeReport is a real handleReportIssue preview, as TestHealthReachesTheIssueReport is.
func TestHealthFixAgeReport(t *testing.T) {
	clock, _, _ := healthFixture(t)
	dest := dsSetup(t, "hfage-rep", "64", 64*100000+10123)
	hfaFiring(*clock, "64")
	healthFixRecord("64", "play-push-frozen", clock.Add(-120*time.Second))
	prevWorker := uiderrorsWorker
	t.Cleanup(func() { uiderrorsWorker = prevWorker })
	uiderrorsWorker = func(string, string, string) string { return "" }
	c := &dsConn{r: strings.NewReader("")}
	handleReportIssue(c, dest, `{"preview":true,"status":{}}`)
	if out := c.out.String(); !strings.Contains(out, " bad_for=1170 fix_age=120\"") {
		t.Errorf("the report does not carry fix_age=120 in health_play_push_frozen: %s", out)
	}
}
