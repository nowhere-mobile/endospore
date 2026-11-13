package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// NWP-20261201-08, part 1 of 2 of the backlog row "The phone cannot tell its user about a known fault it could detect".
// The decision is docs/product-decisions.md, 2026-11-08, "no LLM in the OS; known faults are found by fixed, reviewable
// health-check rules, and the user decides what is done about one": a fixed set of reviewable rules, run periodically
// during a session, with no network and nothing leaving the phone. A check never repairs on its own and never signs a
// profile out. The last results go into the issue report.
//
// RULE SHAPE. A fixed, reviewable rule is a condition, a fix and a message. This file builds the condition; P12b builds
// the fix and the message. Each diagnosed incident becomes one more entry in healthRules.
//
// VERDICTS. FIRING, CLEAR, NOT-APPLICABLE, UNMEASURED.
//
// GET-HEALTH (gate callers only: gateCallerOK(ownerPeerUID(conn)), else `DENIED`), a RAM read, concurrent-safe. One line
// per rule: `<id> <VERDICT> <age_s>` (seconds since that rule's last measured check, -1 if none); `NONE` with no live
// session or when the stored results' uid is not the live session's.
//
// THE PROBE. The login daemon's domain may not run `dumpsys activity`, so roamd's read-only `healthprobe` runs it and
// pipes it to `healthoom <uid>`, which reads stdin, prints ONE line and exits 0:
// `gms adj=<n> state=<token> bound=<0|1>` | `gms ABSENT` | `ERR-PARSE <fixed class>`.
//
// A Go timer does not wake a suspended phone: a check waits until the phone is awake. The results live in RAM only.

// healthEvery is the time between two checks of a session.
const healthEvery = 5 * time.Minute

// healthPlayFrozenAfter is how long every measured check must be bad before play-push-frozen fires.
const healthPlayFrozenAfter = 15 * time.Minute

// healthOomMaxBytes bounds the dump healthoom reads. A longer dump is ERR-PARSE too-long: a cut-off dump must not read
// as ABSENT.
const healthOomMaxBytes = 8 << 20

// gmsOomAdjField is the adj field of the `oom:` line. Never `curRaw=`: that is the value before the cached-band
// adjustment, and it is not the adj the process runs at.
const gmsOomAdjField = "cur="

const (
	healthFiring        = "FIRING"
	healthClear         = "CLEAR"
	healthNotApplicable = "NOT-APPLICABLE"
	healthUnmeasured    = "UNMEASURED"
)

// healthEnabled lets the package's tests keep a stray tick off the RO lane (health_check_test.go).
var healthEnabled = true

// healthSleep is the loop's wait; tests replace it.
var healthSleep = time.Sleep

// healthNow is the checks' clock. Round(0) drops the monotonic reading, so an elapsed time includes suspend: the
// NWP-20260913-18 trap, see triggerRoamWorkerKind. DO NOT tidy the Round(0) away.
var healthNow = func() time.Time { return time.Now().Round(0) }

// healthProbeWorker is the RO-lane request; a var so a test can answer it. No passphrase: the RO lane refuses one.
var healthProbeWorker = func(dest, name, uid string) string {
	return triggerRoamWorker(dest, "healthprobe", name, "", uid, "", nil)
}

// healthLog writes one login.log line; a var so a test can read the lines.
var healthLog = func(line string) { fmt.Fprintln(os.Stderr, line) }

// healthProbe is one parsed reply. measured is false for every reply that is not an exact `gms ...` form: a probe
// error, ERR-WORKER-BUSY, ERR-TIMEOUT, ERR-LANE or ERR-PARSE.
type healthProbe struct {
	measured bool
	absent   bool
	adj      int
	state    string // "-" when the entry has no state line
	bound    bool
}

// healthRuleResult is one rule's last result for one session. fields is false until a check has measured a process,
// and again after one finds none. badSince is zero unless the current run of bad checks has started.
type healthRuleResult struct {
	verdict   string
	checkedAt time.Time
	badSince  time.Time
	fields    bool
	adj       int
	state     string
	bound     bool
}

// healthRule is one fixed rule. apply is the condition: pure, with the time passed in.
type healthRule struct {
	id        string
	statusKey string
	apply     func(r *healthRuleResult, p healthProbe, now time.Time)
}

// healthRules is the whole set. It is fixed at build time so that every rule can be reviewed line by line.
var healthRules = []healthRule{
	{id: "play-push-frozen", statusKey: "health_play_push_frozen", apply: applyPlayPushFrozen},
}

// healthResults holds the last results of the session with this uid. The results slice is parallel to healthRules.
type healthResults struct {
	uid     string
	checks  int
	results []healthRuleResult
}

// healthMu guards healthState only. It is never held across the probe.
var healthMu sync.Mutex

// healthState is nil when there are no results.
var healthState *healthResults

func newHealthResults(uid string) *healthResults {
	s := &healthResults{uid: uid, results: make([]healthRuleResult, len(healthRules))}
	for i := range s.results {
		s.results[i].verdict = healthUnmeasured
	}
	return s
}

// parseGmsOom reduces `dumpsys activity oom` to healthoom's one line, for THIS uid's Play services persistent process.
// Only numbers, one state token and a fixed class can leave it: the dump names every app on the phone.
func parseGmsOom(dump, uid string) string {
	if uid == "" || strings.Trim(uid, "0123456789") != "" {
		return "ERR-PARSE no-uid"
	}
	lines := strings.Split(dump, "\n")
	start := -1
	for i, l := range lines {
		if strings.Contains(l, "Process OOM control") {
			start = i + 1
			break
		}
	}
	if start < 0 {
		return "ERR-PARSE no-section"
	}
	gms := regexp.MustCompile(`^[0-9]+:com\.google\.android\.gms\.persistent/u` + uid + `a[0-9]+$`)
	var entry []string
	in := false
	for _, l := range lines[start:] {
		t := strings.TrimSpace(l)
		if t == "" {
			continue
		}
		if len(l)-len(strings.TrimLeft(l, " ")) < 4 {
			break // the section's entries are indented 4 or more
		}
		if strings.HasPrefix(t, "Proc #") || strings.HasPrefix(t, "PERS #") {
			if in {
				break
			}
			for _, f := range strings.Fields(t) { // `Proc # 9:` has a space after the #: never index the header by field
				if gms.MatchString(f) {
					in = true
					break
				}
			}
			continue
		}
		if in {
			entry = append(entry, t)
		}
	}
	if !in {
		return "gms ABSENT"
	}
	adj, state, bound := "", "-", "0"
	for _, t := range entry {
		f := strings.Fields(t)
		switch {
		case strings.HasPrefix(t, "oom:"):
			for _, v := range f {
				if strings.HasPrefix(v, gmsOomAdjField) {
					adj = strings.TrimPrefix(v, gmsOomAdjField)
				}
			}
		case strings.HasPrefix(t, "state:"):
			if len(f) > 1 && strings.HasPrefix(f[1], "cur=") && len(f[1]) > len("cur=") {
				state = strings.TrimPrefix(f[1], "cur=")
			}
		case strings.Contains(t, "<=Proc{") && strings.Contains(t, ":app.grapheneos.gmscompat/u"+uid+"a"):
			bound = "1"
		}
	}
	if _, err := strconv.Atoi(adj); err != nil {
		return "ERR-PARSE no-adj"
	}
	return "gms adj=" + adj + " state=" + state + " bound=" + bound
}

// healthOomLine is the `healthoom` verb: at most healthOomMaxBytes of the dump on r, one line back.
func healthOomLine(r io.Reader, uid string) string {
	b, err := io.ReadAll(io.LimitReader(r, healthOomMaxBytes+1))
	if err != nil {
		return "ERR-PARSE read-failed"
	}
	if len(b) > healthOomMaxBytes {
		return "ERR-PARSE too-long"
	}
	return parseGmsOom(string(b), uid)
}

// healthReplyRE is the whole measured reply. The state token's character set keeps a dotted name out of every report.
var healthReplyRE = regexp.MustCompile(`^gms adj=(-?[0-9]{1,6}) state=([A-Za-z0-9_-]{1,16}) bound=([01])$`)

// parseHealthProbeReply accepts only the exact forms; every other reply is an unmeasured check.
func parseHealthProbeReply(reply string) healthProbe {
	reply = strings.TrimSpace(reply)
	if reply == "gms ABSENT" {
		return healthProbe{measured: true, absent: true}
	}
	m := healthReplyRE.FindStringSubmatch(reply)
	if m == nil {
		return healthProbe{}
	}
	adj, err := strconv.Atoi(m[1])
	if err != nil {
		return healthProbe{}
	}
	return healthProbe{measured: true, adj: adj, state: m[2], bound: m[3] == "1"}
}

// applyPlayPushFrozen is the condition of play-push-frozen: the section B row "Play services' push process can be
// frozen for the rest of a session". Bad is the cached band with no GmsCompat binding. An unmeasured check changes
// nothing. A good or ABSENT check clears badSince, so a set badSince means that every measured check since it was bad.
// FIRING holds until a measured check is good or ABSENT, a wall clock stepped back included. A bad check before the
// 15 minutes end is CLEAR with badSince kept: the fault is not established yet.
func applyPlayPushFrozen(r *healthRuleResult, p healthProbe, now time.Time) {
	if !p.measured {
		return
	}
	r.checkedAt = now
	if p.absent {
		r.verdict, r.badSince = healthNotApplicable, time.Time{}
		r.fields, r.adj, r.state, r.bound = false, 0, "", false
		return
	}
	r.fields, r.adj, r.state, r.bound = true, p.adj, p.state, p.bound
	bad := p.adj >= 900 && !p.bound
	if !bad {
		r.verdict, r.badSince = healthClear, time.Time{}
		return
	}
	if r.badSince.IsZero() {
		r.badSince = now
	}
	if r.verdict == healthFiring || now.Sub(r.badSince) >= healthPlayFrozenAfter {
		r.verdict = healthFiring
		return
	}
	r.verdict = healthClear
}

// healthSessionLive is the runner's and the verbs' test of a live session's uid.
func healthSessionLive(uid string) bool { return uid != "" && uid != "0" }

// healthClampS is d in whole seconds, never negative: a clock step must not print a false value.
func healthClampS(d time.Duration) int64 {
	if d < 0 {
		return 0
	}
	return int64(d / time.Second)
}

// healthLogFields is the login.log detail of a result: known fields only, no profile and no app.
func healthLogFields(r *healthRuleResult) string {
	var f []string
	if r.fields {
		b := 0
		if r.bound {
			b = 1
		}
		f = append(f, fmt.Sprintf("adj=%d", r.adj), fmt.Sprintf("bound=%d", b))
	}
	if !r.badSince.IsZero() {
		f = append(f, fmt.Sprintf("bad_for=%dm", healthClampS(r.checkedAt.Sub(r.badSince))/60))
	}
	if len(f) == 0 {
		return ""
	}
	return " (" + strings.Join(f, " ") + ")"
}

// healthTick runs one check of the live session, and reports whether it sent a probe.
func healthTick(dest string) bool {
	if !healthEnabled {
		return false
	}
	name, _, uid := readRoamSession(dest)
	if name == "" || !healthSessionLive(uid) {
		healthMu.Lock()
		healthState = nil
		healthMu.Unlock()
		return false
	}
	healthMu.Lock()
	if healthState == nil || healthState.uid != uid {
		healthState = newHealthResults(uid)
	}
	healthState.checks++
	healthMu.Unlock()

	p := parseHealthProbeReply(healthProbeWorker(dest, name, uid))
	now := healthNow()
	var changes []string
	healthMu.Lock()
	if healthState != nil && healthState.uid == uid {
		for i, rule := range healthRules {
			r := &healthState.results[i]
			was := r.verdict
			rule.apply(r, p, now)
			if r.verdict != was {
				changes = append(changes, fmt.Sprintf("[logind] health %s: %s -> %s%s", rule.id, was, r.verdict, healthLogFields(r)))
			}
		}
	}
	healthMu.Unlock()
	for _, l := range changes {
		healthLog(l)
	}
	return true
}

// healthLoop is started only through goSafeLoop in loginDaemon.
func healthLoop(dest string) {
	for {
		healthSleep(healthEvery)
		healthTick(dest)
	}
}

// handleGetHealth answers GET-HEALTH: the contract is at the top of this file.
func handleGetHealth(conn net.Conn, dest string) {
	if !gateCallerOK(ownerPeerUID(conn)) {
		conn.Write([]byte("DENIED\n"))
		return
	}
	name, _, uid := readRoamSession(dest)
	now := healthNow()
	var b strings.Builder
	healthMu.Lock()
	if name != "" && healthSessionLive(uid) && healthState != nil && healthState.uid == uid {
		for i, rule := range healthRules {
			r := &healthState.results[i]
			age := int64(-1)
			if !r.checkedAt.IsZero() {
				age = healthClampS(now.Sub(r.checkedAt))
			}
			fmt.Fprintf(&b, "%s %s %d\n", rule.id, r.verdict, age)
		}
	}
	healthMu.Unlock()
	if b.Len() == 0 {
		conn.Write([]byte("NONE\n"))
		return
	}
	conn.Write([]byte(b.String()))
}

// healthStatusValue is one rule's issue-report value: known fields only, and no profile or app name.
func healthStatusValue(r *healthRuleResult, now time.Time) string {
	f := []string{r.verdict}
	if !r.checkedAt.IsZero() {
		f = append(f, fmt.Sprintf("age=%d", healthClampS(now.Sub(r.checkedAt))))
	}
	if r.fields {
		f = append(f, fmt.Sprintf("adj=%d", r.adj))
		if r.state != "-" {
			f = append(f, "state="+r.state)
		}
		b := 0
		if r.bound {
			b = 1
		}
		f = append(f, fmt.Sprintf("bound=%d", b))
	}
	if !r.badSince.IsZero() {
		f = append(f, fmt.Sprintf("bad_for=%d", healthClampS(r.checkedAt.Sub(r.badSince))))
	}
	return strings.Join(f, " ")
}

// mergeHealth adds the session's last results (uid) to an in-session report's status, after buildIssueReportWith, as
// mergeDaySummary does. It deletes every caller-sent health_ key first, at every scope, so only this file can set one.
// A gate report carries none, and neither does a report for a uid the stored results are not for.
func mergeHealth(status map[string]string, uid string, deviceScope bool) {
	for k := range status { // a nil map ranges zero times
		if strings.HasPrefix(k, "health_") {
			delete(status, k)
		}
	}
	if deviceScope || status == nil {
		return
	}
	now := healthNow()
	healthMu.Lock()
	defer healthMu.Unlock()
	if healthState == nil || !healthSessionLive(uid) || healthState.uid != uid {
		return
	}
	for i, rule := range healthRules {
		status[rule.statusKey] = healthStatusValue(&healthState.results[i], now)
	}
	status["health_checks"] = strconv.Itoa(healthState.checks)
}
