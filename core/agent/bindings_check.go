package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// NWP-20260930-04: bindings.conf is read line by line, a line that does not read back is never read as "unbound", and
// an arrival is resolved against the SIM links in force when it came in.
//
// A DAMAGED LINE IS NEVER READ AS "UNBOUND". The old reader skipped what it could not parse, so a half-written or
// corrupted line read as fewer SIM links, or none: every arrival on that SIM answered NONE (an unbound SIM, kept for
// nobody), and the next binding write rewrote the file without the line, making the loss permanent. Now a line is
// trusted only when it reads back byte for byte through serializeLine, with no CR; any other line is DAMAGED, and so
// is the file's last line when it has no newline (it was cut short, and may have lost an owner). The file is FLAWED
// when it has a damaged line, no "v1" header, or no content at all. Only an ABSENT file means there are no SIM links.
//   - Every reader uses the lines that read back, exactly as before: v1 and v2 arrivals on those lines, TEL-OWNER and
//     the TEL-OWNED lists (the #158 outbound gate and the #176 SIM scope, which the chooser acts on), GET-BINDINGS.
//   - A v2 arrival on a SIM that no good line holds is UNRESOLVED while the file is flawed, never unbound: its line
//     may be the damaged one. A v1 arrival there answers NONE, as it did.
//   - Writers carry a damaged line forward, marked with a leading "#" so that it can never read back as a good line
//     with an owner missing. "Unbind all" of the ICCID a damaged line names removes it (the repair), and a profile
//     delete reduces every damaged line to its sub_id and ICCID, so no deleted identity is left behind, a co-owner on the line keeps its SIM (its DAMAGED marker stays), and a line naming no ICCID is dropped. A rewrite of a
//     flawed file with no damaged line (an empty file, no header) writes a clean one. (SUPERSEDED by NWP-20261110-01:
//     any rewrite of a flawed file writes a REBUILT one, see THE REBUILT MARK below.)
//   - Only a file that cannot be read at all is refused by the writers, and GET-BINDINGS says ERR damaged for it.
//   - A writer refuses a record that would not read back (an ICCID holding '|', say), so no write damages the file.
// docs/backlog.md, "A damaged line of bindings.conf leaves its SIM's arrivals unkept, and some damage cannot be repaired from the phone".
//
// NWP-20261110-01: THE REBUILT MARK (Q031, 2026-10-20, docs/product-decisions.md; the backlog row above). A damaged line
// that named no readable ICCID may have held a profile's SIM, and a delete that drops it, or a bind over an emptied or
// headerless file, would otherwise write a clean file in which that SIM reads as unbound and its texts are sealed to the
// device owner. So every writer marks a rewrite of a flawed file with a "#rebuilt" line (marksAfter), a rebuilt file stays
// rebuilt, and in it a SIM that no good line names is UNRESOLVED (arrivalLine answers lineDamaged, simUnboundNow false)
// until the owner binds it or marks it the phone's own line with a "#mine|<iccid>|" record (one per SIM, the ICCID as
// given). Both records start with "#" on purpose: a daemon from before this change reads each as a damaged line, so the
// file reads flawed there and an unnamed SIM answers UNRESOLVED, never the device owner's. An absent file stays
// unmarked. Two inferences Chester did not state: (a) a bind or unbind leaves a SIM's mine record as it is (a good line
// takes precedence while it exists); (b) the rule covers more than the three cases the decision names -- "Unbind all"
// of the ICCID a damaged line names, and a bind or rename over a flawed file, also mark the file rebuilt, from the
// decision's rule that damage never routes a profile's texts to the device owner.
//
// THE SIM LINKS WHEN AN ARRIVAL CAME IN. A retry, a request queued on telMu behind an unassign, or an MMS whose
// download finished up to 90 s after its push, all reach the daemon after a SIM link may have changed. Each binding
// writer records its change here, on CLOCK_BOOTTIME -- the clock the chooser stamps an arrival with
// (SystemClock.elapsedRealtime) -- and a v2 arrival is sealed only to the owners it had when it came in and has kept
// ever since. Recorded only after the write succeeds, under the telMu hold the writer runs in.

// errBindingsDamaged is a bindings.conf that exists and cannot be read at all: the writers refuse, and GET-BINDINGS and
// DELETE-BINDING answer "ERR damaged".
var errBindingsDamaged = errors.New("damaged")

// errBindingUnstorable is a record that would not read back as written: a field holding a delimiter or a newline.
var errBindingUnstorable = errors.New("unstorable")

// bindingsState is bindings.conf as read.
type bindingsState struct {
	lines      []simBinding // the lines that read back byte for byte, in file order
	damaged    []string     // the lines that do not, as written (a carried-forward line keeps its "#" mark)
	flawed     bool         // a damaged line, no header, or an empty file
	unreadable bool         // present but unreadable: nothing about it is known
	rebuilt    bool         // a "#rebuilt" mark: a SIM on no line and not mine stays unresolved (NWP-20261110-01)
	mine       []string     // the ICCIDs of the "#mine|<iccid>|" records, in file order, one per simTag (NWP-20261110-01)
}

const (
	bindingsRebuiltMark = "#rebuilt"
	bindingsMinePrefix  = "#mine|"
)

// mineTag reports whether a mine record marks the SIM with this tag as the phone's own line.
func (st bindingsState) mineTag(tag string) bool {
	for _, m := range st.mine {
		if simTag(m) == tag {
			return true
		}
	}
	return false
}

// mineICCIDStorable reports whether an ICCID can be written as a mine record and read back as given.
func mineICCIDStorable(iccid string) bool {
	return normICCID(iccid) != "" && !strings.ContainsAny(iccid, "|\r\n")
}

// mineRecordICCID returns the ICCID a row names when the row is exactly "#mine|<iccid>|" and re-serialises identically,
// else "".
func mineRecordICCID(row string) string {
	if len(row) < len(bindingsMinePrefix)+2 || !strings.HasPrefix(row, bindingsMinePrefix) || !strings.HasSuffix(row, "|") {
		return ""
	}
	iccid := row[len(bindingsMinePrefix) : len(row)-1]
	if !mineICCIDStorable(iccid) {
		return ""
	}
	return iccid
}

// readBindingsState reads bindings.conf. An absent file is the zero state. A flaw is logged the first time in a daemon
// run and counted after that (telClassNote).
func readBindingsState() bindingsState {
	data, err := os.ReadFile(bindingsPath)
	if errors.Is(err, fs.ErrNotExist) {
		return bindingsState{}
	}
	var st bindingsState
	if err != nil {
		st = bindingsState{flawed: true, unreadable: true}
	} else {
		st = parseBindingsText(string(data))
	}
	if st.flawed {
		telClassNote(telClassBindingsDamaged)
	}
	return st
}

// parseBindingsText splits a bindings.conf into the lines that read back and the lines that do not.
func parseBindingsText(s string) bindingsState {
	var st bindingsState
	if s == "" || !strings.HasSuffix(s, "\n") {
		st.flawed = true // cut short: an empty file, a data line with no newline, or the header alone ("v1")
	}
	rows := strings.Split(s, "\n")
	if rows[0] == "v1" {
		rows = rows[1:]
	} else {
		st.flawed = true // no header, or an empty file
	}
	last := len(rows) - 1
	for i, row := range rows {
		if i == last {
			if row != "" { // no final newline: cut short
				st.damaged = append(st.damaged, row)
				st.flawed = true
			}
			break
		}
		if row == "" {
			st.flawed = true
			continue
		}
		if row == bindingsRebuiltMark {
			st.rebuilt = true
			continue
		}
		if m := mineRecordICCID(row); m != "" {
			if !st.mineTag(simTag(m)) { // one record per SIM: a repeat is dropped, not damage
				st.mine = append(st.mine, m)
			}
			continue
		}
		if b, ok := parseLineStrict(row); ok {
			st.lines = append(st.lines, b)
		} else {
			st.damaged = append(st.damaged, row)
			st.flawed = true
		}
	}
	return st
}

// parseLineStrict parses one line and reports false unless serializeLine writes it back byte for byte and it holds no
// CR. That refuses a line without its five fields, a sub_id serializeLine would not write ("+2", "02"), an ICCID that
// normalises to nothing, a label that is not canonical base64, a visibility other than the three serializeLine writes
// (normVisibility would read it as "open", the least private dial), and an owner list with no owner or with any pair
// that is not "<ref>:<pub>" (the old reader dropped that co-owner silently).
func parseLineStrict(line string) (simBinding, bool) {
	if strings.ContainsRune(line, '\r') {
		return simBinding{}, false
	}
	f := strings.Split(line, "|")
	if len(f) != 5 {
		return simBinding{}, false
	}
	sub, err := strconv.Atoi(f[0])
	if err != nil || normICCID(f[1]) == "" {
		return simBinding{}, false
	}
	lb, err := base64.StdEncoding.DecodeString(f[2])
	if err != nil {
		return simBinding{}, false
	}
	b := simBinding{SubID: sub, ICCID: f[1], Label: string(lb), Visibility: f[3]} // any other dial fails the read-back
	for _, pair := range strings.Split(f[4], ",") {
		kv := strings.Split(pair, ":")
		if len(kv) != 2 || kv[0] == "" || kv[1] == "" {
			return simBinding{}, false
		}
		b.Owners = append(b.Owners, bindingOwner{ProfileRef: kv[0], TelPub: kv[1]})
	}
	if serializeLine(b) != line {
		return simBinding{}, false
	}
	return b, true
}

// readBindingsChecked is the good lines, and errBindingsDamaged when the file exists and cannot be read.
func readBindingsChecked() ([]simBinding, error) {
	st := readBindingsState()
	if st.unreadable {
		return nil, errBindingsDamaged
	}
	return st.lines, nil
}

// damagedLineICCID is the ICCID a damaged line names, "" when it names none: its second field, after any "#" mark.
func damagedLineICCID(row string) string {
	f := strings.Split(strings.TrimPrefix(row, "#"), "|")
	if len(f) < 2 {
		return ""
	}
	return normICCID(f[1])
}

// redactDamagedIdentity strips every owner token from a damaged line, keeping only its sub_id and ICCID -- the fields
// a damaged line needs for arrivalLine (its SIM stays DAMAGED, not unbound) and for the "Unbind all" repair
// (damagedLineICCID). A profile delete calls it on every damaged line, so no profile's ref -- the deleted one, a
// co-owner's, or a hex prefix of one left by a cut-short line -- survives in the file that outlives a reboot
// (NWP-20260903-21). Returns "" for a line that names no ICCID: it carries no SIM and no repair handle, so a delete
// drops it. The result is not itself a good line (three fields), so it stays DAMAGED.
func redactDamagedIdentity(row string) string {
	f := strings.Split(strings.TrimPrefix(row, "#"), "|")
	if len(f) < 2 || normICCID(f[1]) == "" {
		return ""
	}
	return "#" + f[0] + "|" + f[1] + "|"
}

// simUnboundNow reports whether the SIM with this tag has no owner right now. A flawed file answers false unless a good
// line holds the SIM: its link may be the damaged line, so a re-staged row is put back rather than dropped
// (restageTelIngest). A rebuilt file answers false for a SIM no line names unless a mine record marks it
// (NWP-20261110-01).
func simUnboundNow(tag string) bool {
	st := readBindingsState()
	for _, b := range st.lines {
		if simTag(b.ICCID) == tag {
			return false
		}
	}
	return !st.flawed && (!st.rebuilt || st.mineTag(tag))
}

// noBindingsReply is GET-BINDINGS' answer when it has no good line to list: ERR damaged for an unreadable file, OK, the
// marks and the damaged marker for a flawed one, OK and the marks for a file with marks (NWP-20261110-02: a rebuilt
// file with no good line is not NONE, which reads as "nothing to repair"), else NONE. It takes the state GET-BINDINGS
// already read: that verb runs lock-free (NWP-20261011-43), so reading the file again could answer from a newer one.
func noBindingsReply(st bindingsState) string {
	if st.unreadable {
		return "ERR damaged\n"
	}
	marks := bindingsMarksReply(st)
	if st.flawed {
		return "OK\n" + marks + bindingsDamagedMarker
	}
	if marks != "" {
		return "OK\n" + marks
	}
	return "NONE\n"
}

// bindingsDamagedMarker ends a GET-BINDINGS list when bindings.conf is flawed: a line owner mode shows as "some SIM
// bindings could not be read". A chooser from before NWP-20260930-05 skips it, as it skips any line without five fields.
const bindingsDamagedMarker = "DAMAGED\n"

// damagedMarker is bindingsDamagedMarker when the state GET-BINDINGS read is flawed, else "".
func damagedMarker(st bindingsState) string {
	if st.flawed {
		return bindingsDamagedMarker
	}
	return ""
}

// unbindRefusal is DELETE-BINDING's refusal, given before it deletes anything: ERR for an empty ICCID or a per-owner
// profileRef (handleDeleteBinding says why), ERR damaged for a bindings.conf that cannot be read at all -- whose unbind
// would refuse only after the records had gone -- and "" to go ahead.
func unbindRefusal(iccid, profileRef string) string {
	if normICCID(iccid) == "" || profileRef != "" {
		return "ERR\n"
	}
	if readBindingsState().unreadable {
		return "ERR damaged\n"
	}
	return ""
}

// linkChange is one change to a SIM's owners. at is CLOCK_BOOTTIME in milliseconds.
type linkChange struct {
	tag           string
	at            int64
	before, after map[string]bool // owner profile refs
}

// linkHistory holds the changes of the last linkHistoryKeep, oldest first, and linkHorizon, per SIM tag, the time of
// the newest change pruned from it: an arrival stamped before that cannot be resolved. Both are guarded by telMu and
// kept in memory, so a daemon restart forgets them. What survives the restart is the time of the newest change, in the
// state tmpfs beside the telephony inbox (linkFloorPath), which lives exactly as long as CLOCK_BOOTTIME does: a
// restarted daemon reads it once as linkFloor, and answers UNRESOLVED for an arrival stamped before it, instead of
// resolving that arrival against the links in force now -- after an unassign and a re-bind that would hand it to the
// profile bound since, against the 2026-09-24 answer 2 in docs/product-decisions.md.
var (
	linkHistory []linkChange
	linkHorizon = map[string]int64{}
	linkFloor   = int64(-1) // the newest change before this daemon run; -1 until read
)

// linkHistoryKeep matches the replay table's window (telReplayTTL); binding changes are owner-mode taps, so a few
// hundred entries is far more than a day holds.
const (
	linkHistoryKeep = 12 * time.Hour
	linkHistoryMax  = 256
)

// bootNowMs is CLOCK_BOOTTIME in milliseconds, the clock of SystemClock.elapsedRealtime. A var so a test can drive it.
var bootNowMs = func() int64 {
	var ts unix.Timespec
	if unix.ClockGettime(unix.CLOCK_BOOTTIME, &ts) != nil {
		return 0
	}
	return ts.Nano() / int64(time.Millisecond)
}

// linkFloorPath is beside the telephony inbox, so a test's temporary inbox moves it too. It holds a number only.
func linkFloorPath() string { return filepath.Join(filepath.Dir(telInboxBase), ".links-changed") }

// loadLinkFloor reads linkFloor the first time it is asked for in a daemon run. Caller holds telMu.
func loadLinkFloor() int64 {
	if linkFloor < 0 {
		linkFloor = 0
		if b, err := os.ReadFile(linkFloorPath()); err == nil {
			if v, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil && v > 0 {
				linkFloor = v
			}
		}
	}
	return linkFloor
}

// linkSnapshot maps each SIM's tag to its owner refs. Legacy duplicate lines for one SIM are merged.
func linkSnapshot(bs []simBinding) map[string]map[string]bool {
	out := map[string]map[string]bool{}
	for _, b := range bs {
		tag := simTag(b.ICCID)
		if out[tag] == nil {
			out[tag] = map[string]bool{}
		}
		for _, o := range b.Owners {
			out[tag][o.ProfileRef] = true
		}
	}
	return out
}

// recordLinkChanges records every SIM whose owners differ between prev and next, keeps the time of the newest change
// in linkFloorPath, and turns the replayed replies of a SIM left with no owner into REMOVED, so a retry is never told
// that a record the unassign deleted was kept. Called by the binding writers after a successful write, under telMu.
//
// unknownBefore is the SIMs whose owners we did not know just before this write: a SIM bound or repaired whose only
// line, before the write, was the damaged one (setBindingOwner, removeBindingOwner's repair). Their link history has
// no trustworthy "before", so an arrival stamped before this write must resolve UNRESOLVED, not unbound -- the
// horizon is raised to now for them, so arrivalLine returns lineLinkUnknown for any earlier stamp.
func recordLinkChanges(prev, next map[string]map[string]bool, unknownBefore []string) {
	loadLinkFloor() // this run's floor is the time before any change it makes
	now := bootNowMs()
	changed := false
	for _, tag := range unionKeys(prev, next) {
		if sameRefs(prev[tag], next[tag]) {
			continue
		}
		changed = true
		linkHistory = append(linkHistory, linkChange{tag: tag, at: now, before: copyRefs(prev[tag]), after: copyRefs(next[tag])})
		if len(next[tag]) == 0 {
			telReplayRemoveTag(tag)
		}
	}
	for _, tag := range unknownBefore { // a SIM whose pre-write line was damaged: earlier arrivals are unresolvable
		if linkHorizon[tag] < now {
			linkHorizon[tag] = now
		}
		changed = true
	}
	if changed {
		p := linkFloorPath()
		if os.MkdirAll(filepath.Dir(p), 0o700) != nil ||
			writeAtomic(p+".tmp", p, []byte(strconv.FormatInt(now, 10))) != nil {
			// Without the floor a restart resolves an in-flight arrival against the links in force now; log it
			// (content-free) so the fail-open is not silent. docs/backlog.md, the S2 row's residual.
			fmt.Fprintf(os.Stderr, "[logind] telephony: could not persist the SIM-link floor; a restart may resolve an in-flight arrival against current links\n")
		}
	}
	pruneLinkHistory(now)
}

// pruneLinkHistory drops changes older than linkHistoryKeep, and the oldest past linkHistoryMax, moving each SIM's
// horizon up to the newest change dropped.
func pruneLinkHistory(now int64) {
	cut := 0
	for cut < len(linkHistory) && (now-linkHistory[cut].at > linkHistoryKeep.Milliseconds() || len(linkHistory)-cut > linkHistoryMax) {
		if c := linkHistory[cut]; c.at > linkHorizon[c.tag] {
			linkHorizon[c.tag] = c.at
		}
		cut++
	}
	linkHistory = linkHistory[cut:]
}

// lineClass is what an arrival's SIM link was when it came in.
type lineClass int

const (
	lineBound       lineClass = iota // bound then and still, to at least one of the same owners
	lineUnbound                      // no owner when it arrived
	lineUnresolved                   // the SIM was not identified
	lineDamaged                      // no good line holds the SIM, and bindings.conf has one that did not read back
	lineLinkUnknown                  // stamped before this SIM's history horizon, or before a daemon restart's floor
	lineRemoved                      // bound when it arrived, and none of those owners has stayed an owner since
)

// arrivalLine resolves a v2 arrival: its SIM (by ICCID, or by sub_id only when it carries none, as bindingForSubID
// does), and the owners it had at the stamp that have stayed owners ever since -- an owner removed and added back in
// between counts as removed, since the unassign deleted that owner's records. Every good line of the SIM counts, a
// legacy duplicate spelling included; the binding it returns has the first line's label and dial and only those
// owners. An arrival with no ICCID whose sub_id matches no good line is unresolved, even if its line was unassigned
// since it came in (REMOVED would be right then; the history is kept by SIM, not by sub_id). Caller holds telMu.
func arrivalLine(subID int, iccid string, stamp int64) (simBinding, lineClass) {
	st := readBindingsState()
	if st.unreadable {
		return simBinding{}, lineDamaged
	}
	tag := ""
	if normICCID(iccid) != "" {
		tag = simTag(iccid)
	} else {
		if subID < 0 {
			return simBinding{}, lineUnresolved
		}
		for _, b := range st.lines {
			if b.SubID == subID {
				tag = simTag(b.ICCID)
				break
			}
		}
		if tag == "" {
			return simBinding{}, lineUnresolved
		}
	}
	var lines []simBinding // every good line of this SIM: a legacy duplicate spelling is the same SIM (linkSnapshot)
	for _, b := range st.lines {
		if simTag(b.ICCID) == tag {
			lines = append(lines, b)
		}
	}
	now := bootNowMs()
	if stamp > now {
		stamp = now
	}
	pruneLinkHistory(now)
	if stamp < linkHorizon[tag] || stamp < loadLinkFloor() {
		return simBinding{}, lineLinkUnknown
	}
	current := linkSnapshot(lines)[tag]
	var then, kept map[string]bool
	for _, c := range linkHistory {
		if c.tag != tag || c.at <= stamp {
			continue
		}
		if then == nil {
			then, kept = c.before, copyRefs(c.before)
		}
		kept = intersectRefs(kept, c.after)
	}
	if then == nil {
		if len(lines) == 0 && st.flawed {
			return simBinding{}, lineDamaged // its line may be the one that did not read back
		}
		then, kept = current, current
	}
	if len(then) == 0 {
		if st.rebuilt && !st.mineTag(tag) {
			return simBinding{}, lineDamaged // NWP-20261110-01: nobody's until bound or marked mine, never the device owner's
		}
		return simBinding{}, lineUnbound
	}
	kept = intersectRefs(kept, current)
	if len(kept) == 0 {
		return simBinding{}, lineRemoved
	}
	b := lines[0]
	b.Owners = nil
	seen := map[string]bool{}
	for _, l := range lines {
		for _, o := range l.Owners {
			if kept[o.ProfileRef] && !seen[o.ProfileRef] {
				seen[o.ProfileRef] = true
				b.Owners = append(b.Owners, o)
			}
		}
	}
	return b, lineBound
}

func unionKeys(a, b map[string]map[string]bool) []string {
	var out []string
	for k := range a {
		out = append(out, k)
	}
	for k := range b {
		if _, ok := a[k]; !ok {
			out = append(out, k)
		}
	}
	return out
}

func sameRefs(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

func copyRefs(a map[string]bool) map[string]bool {
	out := make(map[string]bool, len(a))
	for k := range a {
		out[k] = true
	}
	return out
}

func intersectRefs(a, b map[string]bool) map[string]bool {
	out := map[string]bool{}
	for k := range a {
		if b[k] {
			out[k] = true
		}
	}
	return out
}
