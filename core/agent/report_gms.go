package main

// NWP-20261201-01: the issue report's Play services evidence, the first slice of the backlog row "Play services' push
// process can be frozen for the rest of a session, so no push messages arrive until the next sign-in". Evidence only:
// no rule, no notice, no fix (those go through the health-check row).
//
// WHY THE WORKER READS IT. The login daemon's domain cannot ask the activity manager for a dump; roamd's `gmsstate` op
// can, on the read-only lane, and it pipes the two dumps through `nowhere_agent gmsstate <uid>`. The filter therefore
// runs in the worker: no other process, user or app reaches $RES, so nothing but the two fixed gms processes of this
// session's user reaches the daemon.
//
// THE REPLY: "OK <n>" (n = how many of the two processes a readable dump shows), the key=value lines in a fixed order,
// "--", then the excerpt. Any other first line is an error string the report shows as NOT collected.
//
// THE DUMP FORMAT is what the print statements of AOSP android15-release and GrapheneOS platform_frameworks_base branch
// 17 produce (ProcessRecord, ProcessList.dumpProcessOomList, ProcessStateRecord / psc/ProcessRecordInternal,
// ProcessCachedOptimizerRecord). The excerpt is the safety net if a label on a device differs from them.

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	gmsWordAbsent   = "absent"   // the dump was read and the process is not running
	gmsWordUnparsed = "unparsed" // the process is there and this field is missing or malformed; never a default 0
	gmsWordUnread   = "unread"   // that dump's nowhere-dump-rc= line is non-zero or missing

	gmsNamePersistent = "com.google.android.gms.persistent"
	gmsNameMain       = "com.google.android.gms"
	gmsNameCompat     = "app.grapheneos.gmscompat"

	gmsMaxExcerptLines = 40
	gmsMaxDumpBytes    = 8 << 20 // a cut dump loses its rc line, so it reports unread rather than half an answer
)

var gmsLabels = []string{"persistent", "main"}

// gmsReplyKeys is the reply's key order, and the whole set of keys mergeGmsState will take from a reply.
var gmsReplyKeys = []string{
	"gms_persistent_adj", "gms_persistent_procstate", "gms_persistent_frozen", "gms_persistent_started_s_ago",
	"gms_persistent_held_by",
	"gms_main_adj", "gms_main_procstate", "gms_main_frozen", "gms_main_started_s_ago",
}

var (
	reGmsProcHeaderAny = regexp.MustCompile(`^\s*\*(?:APP|PERS)\*\s`)
	reGmsProcHeader    = regexp.MustCompile(`^\s*\*(?:APP|PERS)\*\s.*\s\d+:([^/\s}]+)/u(\d+)a\d+\}`)
	reGmsOomEntryAny   = regexp.MustCompile(`^\s*(?:Proc|PERS)\s*#\s*\d+:\s`)
	reGmsOomName       = regexp.MustCompile(`\s\d+:([^/\s]+)/u(\d+)a\d+(?:\s|$)`)
	reGmsOomState      = regexp.MustCompile(`^\s*(?:Proc|PERS)\s*#\s*\d+:\s+\S+\s+\S/./([^ ]*)\s`)
	reGmsProcState     = regexp.MustCompile(`^[A-Z]{2,5}$`)
	reGmsAdj           = regexp.MustCompile(`\bcur=(-?\d+)\b`)
	reGmsFrozen        = regexp.MustCompile(`\bisFrozen=(true|false)\b`)
	reGmsElapsed       = regexp.MustCompile(`\bstartElapsedTime=(\S+)`)
	reGmsDuration      = regexp.MustCompile(`^-(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?(?:(\d+)ms)?$`)
	reGmsAdjSourceProc = regexp.MustCompile(`^Proc\{\d+:([^/}\s]+)/[^}\s]*\}$`)
	reGmsExcerptField  = regexp.MustCompile(`\b(?:curProcState|isFrozen|startUpTime|startUptimeTime|startElapsedTime)=`)
	reGmsDumpRC        = regexp.MustCompile(`^nowhere-dump-rc=(.*)$`)
)

// gmsLabelFor is the single filter on what the parser may look at: only the two fixed process names, only this user.
func gmsLabelFor(name, user, uid string) string {
	if user != uid {
		return ""
	}
	switch name {
	case gmsNamePersistent:
		return "persistent"
	case gmsNameMain:
		return "main"
	}
	return ""
}

// gmsSections splits the worker's input at the whole-line markers, in their fixed order, so that a `Proc #` line in the
// processes dump is never read as an oom entry.
func gmsSections(dump string) (procs, oom []string) {
	state := 0
	for _, ln := range strings.Split(strings.ReplaceAll(dump, "\r\n", "\n"), "\n") {
		switch {
		case state == 0 && ln == "== processes":
			state = 1
		case state == 1 && ln == "== oom":
			state = 2
		case state == 1:
			procs = append(procs, ln)
		case state == 2:
			oom = append(oom, ln)
		}
	}
	return procs, oom
}

// gmsDumpReadable reads the section's own rc line: a missing line is a dump that did not finish.
func gmsDumpReadable(section []string) bool {
	rc := ""
	for _, ln := range section {
		if m := reGmsDumpRC.FindStringSubmatch(ln); m != nil {
			rc = m[1]
		}
	}
	return rc == "0"
}

func gmsIndent(ln string) int { return len(ln) - len(strings.TrimLeft(ln, " \t")) }

// gmsProcBlocks returns each target's first record of the processes dump. A block runs to the next record, or to a
// non-blank line indented less than a record's body, so the last record does not take in the sections after it.
func gmsProcBlocks(section []string, uid string) map[string][]string {
	blocks := map[string][]string{}
	for i := 0; i < len(section); {
		if !reGmsProcHeaderAny.MatchString(section[i]) {
			i++
			continue
		}
		j := i + 1
		for j < len(section) && !reGmsProcHeaderAny.MatchString(section[j]) &&
			(strings.TrimSpace(section[j]) == "" || gmsIndent(section[j]) >= 4) {
			j++
		}
		if m := reGmsProcHeader.FindStringSubmatch(section[i]); m != nil {
			if l := gmsLabelFor(m[1], m[2], uid); l != "" && blocks[l] == nil {
				blocks[l] = section[i:j]
			}
		}
		i = j
	}
	return blocks
}

// gmsOomBlocks returns each target's first entry of the oom list. A block runs to the next entry, or to a non-blank
// line indented no deeper than the entry.
func gmsOomBlocks(section []string, uid string) map[string][]string {
	blocks := map[string][]string{}
	for i := 0; i < len(section); {
		if !reGmsOomEntryAny.MatchString(section[i]) {
			i++
			continue
		}
		entryIndent := gmsIndent(section[i])
		j := i + 1
		for j < len(section) && !reGmsOomEntryAny.MatchString(section[j]) &&
			(strings.TrimSpace(section[j]) == "" || gmsIndent(section[j]) > entryIndent) {
			j++
		}
		if m := reGmsOomName.FindStringSubmatch(section[i]); m != nil {
			if l := gmsLabelFor(m[1], m[2], uid); l != "" && blocks[l] == nil {
				blocks[l] = section[i:j]
			}
		}
		i = j
	}
	return blocks
}

// gmsField applies the one check order every key shares: unread, absent, then the value or unparsed.
func gmsField(readable, found bool, value string, ok bool) string {
	switch {
	case !readable:
		return gmsWordUnread
	case !found:
		return gmsWordAbsent
	case !ok:
		return gmsWordUnparsed
	}
	return value
}

func gmsAdjOf(block []string) (string, bool) {
	for _, ln := range block {
		if strings.HasPrefix(strings.TrimSpace(ln), "oom adj:") {
			if m := reGmsAdj.FindStringSubmatch(ln); m != nil {
				return m[1], true
			}
			return "", false
		}
	}
	return "", false
}

func gmsFrozenOf(block []string) (string, bool) {
	for _, ln := range block {
		if m := reGmsFrozen.FindStringSubmatch(ln); m != nil {
			if m[1] == "true" {
				return "yes", true
			}
			return "no", true
		}
	}
	return "", false
}

// gmsAgoSeconds reads TimeUtils.formatDuration of a past moment: "0", or a leading '-' and at least one unit. The "--"
// printed for a time of 0, and a future (+) time, are not an age. Whole seconds; the millisecond part is dropped.
func gmsAgoSeconds(s string) (string, bool) {
	if s == "0" {
		return "0", true
	}
	m := reGmsDuration.FindStringSubmatch(s)
	if m == nil || s == "-" {
		return "", false
	}
	unit := []int64{86400, 3600, 60, 1}
	var total int64
	for i, n := range unit {
		if m[i+1] == "" {
			continue
		}
		v, err := strconv.ParseInt(m[i+1], 10, 64)
		if err != nil || v > 1_000_000_000 {
			return "", false
		}
		total += v * n
	}
	return strconv.FormatInt(total, 10), true
}

// gmsStartedOf reads startElapsedTime, not startUpTime: elapsed time counts deep sleep, so it matches a wall clock.
func gmsStartedOf(block []string) (string, bool) {
	for _, ln := range block {
		if m := reGmsElapsed.FindStringSubmatch(ln); m != nil {
			return gmsAgoSeconds(m[1])
		}
	}
	return "", false
}

func gmsStateOf(block []string) (string, bool) {
	if len(block) == 0 {
		return "", false
	}
	if m := reGmsOomState.FindStringSubmatch(block[0]); m != nil && reGmsProcState.MatchString(m[1]) {
		return m[1], true
	}
	return "", false
}

// gmsHeldBy reads the entry's `<target><=<source>` line. The framework prints only the ONE binding that set the adj,
// so "none" means no binding set it, not that nothing is bound. A source that is not `Proc{pid:name/...}`, {null}
// included, names no process and is unparsed. A process name is compared exactly.
func gmsHeldBy(block []string) (string, bool) {
	for _, ln := range block[1:] {
		_, source, found := strings.Cut(ln, "<=")
		if !found {
			continue
		}
		m := reGmsAdjSourceProc.FindStringSubmatch(strings.TrimSpace(source))
		if m == nil {
			return "", false
		}
		if m[1] == gmsNameCompat {
			return "gmscompat", true
		}
		return "other", true
	}
	return "none", true
}

// gmsAdjSideKept says whether one side of a `<=` line may leave the phone: only Play services' own names, and GmsCompat.
// A bare prefix test would pass com.google.android.gmsfoo; a value with a space in it is not a single name.
func gmsAdjSideKept(name string) bool {
	if strings.ContainsAny(name, " \t") {
		return false
	}
	if name == gmsNameMain || name == gmsNameCompat {
		return true
	}
	return strings.HasPrefix(name, gmsNameMain+".") || strings.HasPrefix(name, gmsNameMain+"/") ||
		strings.HasPrefix(name, gmsNameMain+":")
}

func gmsAdjSide(side string) string {
	if side == "{null}" { // a fixed framework word, and the whole explanation of an unparsed held_by
		return side
	}
	name := side
	if m := reGmsAdjSourceProc.FindStringSubmatch(side); m != nil {
		name = m[1]
	}
	if gmsAdjSideKept(name) {
		return side
	}
	return "<app>"
}

// gmsRewriteAdjLine judges each side of a `<=` line as a whole. A token-by-token rewrite would keep a foreign class name.
func gmsRewriteAdjLine(ln string) string {
	target, source, found := strings.Cut(ln, "<=")
	if !found {
		return ln
	}
	return ln[:gmsIndent(ln)] + gmsAdjSide(strings.TrimSpace(target)) + "<=" + gmsAdjSide(strings.TrimSpace(source))
}

func gmsProcExcerptLine(i int, ln string) bool {
	return i == 0 || strings.HasPrefix(strings.TrimSpace(ln), "oom adj:") || reGmsExcerptField.MatchString(ln)
}

// gmsExcerpt keeps only allowlisted lines of the two processes' blocks, the safety net if a field label differs.
func gmsExcerpt(procs, oom map[string][]string) []string {
	var out []string
	for _, l := range gmsLabels {
		for i, ln := range procs[l] {
			if gmsProcExcerptLine(i, ln) {
				out = append(out, strings.TrimRight(ln, " \t"))
			}
		}
		for i, ln := range oom[l] {
			switch {
			case i == 0:
				out = append(out, strings.TrimRight(ln, " \t"))
			case strings.Contains(ln, "<="):
				out = append(out, gmsRewriteAdjLine(ln))
			}
		}
	}
	if len(out) > gmsMaxExcerptLines {
		out = out[:gmsMaxExcerptLines]
	}
	return out
}

// parseGmsState is the worker half: it turns the two dumps into the reply. Every other process, user and app is
// dropped by gmsProcBlocks and gmsOomBlocks before a field is read.
func parseGmsState(dump, uid string) string {
	if uid == "" || strings.Trim(uid, "0123456789") != "" {
		return "ERR-UID the worker was given no numeric user id\n"
	}
	procSec, oomSec := gmsSections(dump)
	procOK, oomOK := gmsDumpReadable(procSec), gmsDumpReadable(oomSec)
	procs, oom := map[string][]string{}, map[string][]string{}
	if procOK {
		procs = gmsProcBlocks(procSec, uid)
	}
	if oomOK {
		oom = gmsOomBlocks(oomSec, uid)
	}
	n := 0
	var kv strings.Builder
	for _, l := range gmsLabels {
		p, o := procs[l], oom[l]
		if p != nil || o != nil {
			n++
		}
		v, ok := gmsAdjOf(p)
		fmt.Fprintf(&kv, "gms_%s_adj=%s\n", l, gmsField(procOK, p != nil, v, ok))
		v, ok = gmsStateOf(o)
		fmt.Fprintf(&kv, "gms_%s_procstate=%s\n", l, gmsField(oomOK, o != nil, v, ok))
		v, ok = gmsFrozenOf(p)
		fmt.Fprintf(&kv, "gms_%s_frozen=%s\n", l, gmsField(procOK, p != nil, v, ok))
		v, ok = gmsStartedOf(p)
		fmt.Fprintf(&kv, "gms_%s_started_s_ago=%s\n", l, gmsField(procOK, p != nil, v, ok))
		if l == "persistent" {
			v, ok = "", false
			if o != nil {
				v, ok = gmsHeldBy(o)
			}
			fmt.Fprintf(&kv, "gms_persistent_held_by=%s\n", gmsField(oomOK, o != nil, v, ok))
		}
	}
	return fmt.Sprintf("OK %d\n%s--\n%s\n", n, kv.String(), strings.Join(gmsExcerpt(procs, oom), "\n"))
}

// gmsStateWait bounds how long a report waits for the worker. The report's preview is a user-facing action.
var gmsStateWait = 15 * time.Second

// gmsStateWorker is the RO-lane request, and it never carries a passphrase. A var so a test can prove handleReportIssue
// really asks it.
var gmsStateWorker = func(dest, name, uid string) string {
	return triggerRoamWorker(dest, "gmsstate", name, "", uid, "", nil)
}

// fetchGmsState asks the RO-lane worker, bounded like fetchUiderrors: the op runs on in its goroutine if the wait
// expires; it only reads, and the RO lane's own slot keeps it from piling up.
func fetchGmsState(dest, name, uid string) string {
	if name == "" || uid == "" {
		return "ERR-NOSESSION the session marker names no profile or no user id, and the worker filters by that user, so nothing can be asked"
	}
	ch := make(chan string, 1)
	goSafe("gmsstate", func() { ch <- gmsStateWorker(dest, name, uid) })
	select {
	case r := <-ch:
		return r
	case <-time.After(gmsStateWait):
		return fmt.Sprintf("ERR-TIMEOUT the worker did not answer within %s", gmsStateWait)
	}
}

var reGmsValueBySuffix = map[string]*regexp.Regexp{
	"adj":           regexp.MustCompile(`^-?[0-9]{1,6}$`), // a persistent process has a negative adj
	"procstate":     reGmsProcState,
	"frozen":        regexp.MustCompile(`^(?:yes|no)$`),
	"started_s_ago": regexp.MustCompile(`^[0-9]{1,16}$`),
	"held_by":       regexp.MustCompile(`^(?:gmscompat|other|none)$`),
}

// gmsValidValue re-checks one reply value in the daemon: each value skips statusValue, so each must be a closed form.
func gmsValidValue(key, value string) bool {
	if value == gmsWordAbsent || value == gmsWordUnparsed || value == gmsWordUnread {
		return true
	}
	rest, found := strings.CutPrefix(key, "gms_persistent_")
	if !found {
		rest = strings.TrimPrefix(key, "gms_main_")
	}
	re := reGmsValueBySuffix[rest]
	return re != nil && re.MatchString(value)
}

const gmsNotHealthy = " -- this does NOT mean Play services was healthy"

// gmsNotCollected writes the ALWAYS-HONEST outcome, the uiderrorsSection rule: "we read it" and "we could not read it"
// must never be the same output.
func gmsNotCollected(rep *issueReport, why string, secrets []string) {
	rep.Status["gms_state"] = "not-collected"
	h := scrubIssueLines([]string{"gms: NOT collected -- " + why + gmsNotHealthy}, secrets)
	if len(h) == 0 { // a worker error string that tripped a drop keyword: keep the verdict, lose only the reason
		h = []string{"gms: NOT collected -- the reason was withheld by the scrub" + gmsNotHealthy}
	}
	rep.Logs["gms"] = h
}

// mergeGmsState adds the evidence to an in-session report. Every caller-sent gms_* key goes first, at both scopes, so
// only this function can set one. A gate report carries none of it, and the worker is never asked for one.
func mergeGmsState(rep *issueReport, fetch func() string, deviceScope bool, secrets ...string) {
	if rep == nil {
		return
	}
	for k := range rep.Status {
		if strings.HasPrefix(k, "gms_") {
			delete(rep.Status, k)
		}
	}
	if deviceScope {
		return
	}
	if rep.Status == nil {
		rep.Status = map[string]string{}
	}
	if rep.Logs == nil {
		rep.Logs = map[string][]string{}
	}
	if fetch == nil {
		gmsNotCollected(rep, "no worker was asked (not a device build)", secrets)
		return
	}
	reply := strings.TrimRight(strings.ReplaceAll(fetch(), "\r\n", "\n"), "\n")
	first, rest, _ := strings.Cut(reply, "\n")
	first = strings.TrimSpace(first)
	f := strings.Fields(first)
	if len(f) != 2 || f[0] != "OK" || (f[1] != "0" && f[1] != "1" && f[1] != "2") {
		why := first
		switch {
		case why == "":
			why = "the worker returned nothing"
		case strings.HasPrefix(why, "ERR-LANE"):
			// ⚠ No drop keyword in this text: the scrub would delete the whole header (uiderrorsSection's warning).
			why += " (the worker refused the op: its roamd predates NWP-20261201-01, or a credential reached the read-only lane)"
		case !strings.HasPrefix(why, "ERR"):
			// Not echoed: a reply without the protocol's header could be dump content.
			why = "the worker's reply was malformed (not ERR, and not an OK header with a process count)"
		}
		gmsNotCollected(rep, why, secrets)
		return
	}
	kv := map[string]string{}
	var excerpt []string
	inExcerpt := false
	for _, ln := range strings.Split(rest, "\n") {
		switch {
		case inExcerpt:
			if strings.TrimSpace(ln) != "" {
				excerpt = append(excerpt, ln)
			}
		case ln == "--":
			inExcerpt = true
		default:
			if k, v, found := strings.Cut(ln, "="); found {
				kv[k] = v
			}
		}
	}
	if len(excerpt) > gmsMaxExcerptLines {
		excerpt = excerpt[:gmsMaxExcerptLines]
	}
	rep.Status["gms_state"] = "ok"
	for _, k := range gmsReplyKeys {
		v, found := kv[k]
		if !found || !gmsValidValue(k, v) {
			v = gmsWordUnparsed
		}
		rep.Status[k] = v
	}
	head := fmt.Sprintf("gms: %s of 2 Play services processes found for the user of this session; the gms_* status keys carry the parsed fields, and these lines are the dumps they came from", f[1])
	rep.Logs["gms"] = scrubIssueLines(append([]string{head}, excerpt...), secrets)
}
