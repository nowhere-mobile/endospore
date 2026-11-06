package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// NWP-20260930-04: the v2 arrival wire. The chooser mints one arrival id per arrival and sends it, with a monotonic
// arrival stamp, on every attempt, so a retry can never seal an arrival twice; the daemon keeps the first answer per
// arrival id and replays it. Designed in docs/owner-inbox-plan.md (PR C) and docs/backlog.md, "An SMS whose seal
// times out is never retried, a retried call or MMS can be sealed twice, and a bound SIM that sealed to nobody still
// reports success".
//
//	SEAL-TEL\nv2\n<aid>\n<kind>\n<sub_id>\n<iccid>\n<from_b64>\n<when_ms>\n<mono_ms>\n<body_b64>\n<call_type>\n<dur_sec>\n
//	SEAL-MMS\nv2\n<aid>\n<sub_id>\n<iccid>\n<from_b64>\n<when_ms>\n<mono_ms>\n<subject_b64>\n<nparts>\n + the parts
//
// <aid> is 64 lower-case hex characters, <mono_ms> the arrival's SystemClock.elapsedRealtime. An agent from before
// v2 refuses both with no side effect: SEAL-TEL reads "v2" as the kind (ERR bad kind), and SEAL-MMS reads <when_ms>
// as the part count (ERR bad nparts) -- which is why <mono_ms> comes after <when_ms>. A new verb name would instead
// fall through to the legacy login. <from> is base64, so a sender ID with a newline cannot shift the later fields.
//
// Replies, one line each; every one but ERR is kept and replayed to a repeat of the same arrival id:
//
//	OK <vis> <label_b64> <n> [STRIPPED] [PARTIAL] [LIVE <uid>]  bound, and kept for at least one owner (sealed or queued)
//	OWNER                                             unbound: sealed to the device-owner inbox (Slice D, telephony_owner.go)
//	FULL                                              unbound: the device-owner inbox is at its RAM budget -- nothing kept
//	NONE                                              unbound with no device-owner key yet (not verified since it landed): an accepted loss
//	UNRESOLVED                                         the SIM was not identified, it is on no line of bindings.conf
//	                                                   that reads back while one does not, or its SIM link when it
//	                                                   arrived is unknown
//	REMOVED                                            bound when it arrived and unassigned since: not kept, no notice
//	ERR nobody <vis>                                   bound, but no owner's seal landed and no owner is live
//	ERR <class>                                        a bad request or a refused caller
//
// A v1 request gets only today's replies (OK and NONE; handleSealTel, handleSealMms), so an older chooser never sees
// one it cannot read, and on every line of bindings.conf that reads back it gets today's answer. What changes for an
// older chooser: a line that does not read back is now left out whole, where the old reader kept what it could parse
// of it (docs/backlog.md, "A damaged line of bindings.conf leaves its SIM's arrivals unkept, and some damage cannot be
// repaired from the phone"); a SEAL-MMS from anyone but the user-0 gate answers ERR caller, which no chooser sends;
// a SEAL-TEL from anyone but the gate answers the same since NWP-20260930-05, which the chooser before it sent for a
// call declined in a stranger's session (the two ship in one image); and a v1 arrival sealed to nobody is logged once
// per daemon run.

// arrivalReq is one v2 SEAL-TEL or SEAL-MMS request.
type arrivalReq struct {
	verb  string
	aid   string
	mono  int64
	iccid string
	it    telItem
}

var (
	reArrivalID     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	errArrivalField = errors.New("request")
)

// readArrivalHead validates the v2 fields every arrival carries: the arrival id and the stamp.
func readArrivalHead(aid, mono string) (int64, error) {
	m, err := strconv.ParseInt(mono, 10, 64)
	if !reArrivalID.MatchString(aid) || err != nil || m < 0 {
		return 0, errArrivalField
	}
	return m, nil
}

// readSealTelV2 reads the ten lines after SEAL-TEL's "v2". A body or sender that is not base64 is kept empty, as
// v1 keeps its body.
func readSealTelV2(r *bufio.Reader) (*arrivalReq, error) {
	f, err := readLines(r, 10)
	if err != nil {
		return nil, err
	}
	mono, err := readArrivalHead(f[0], f[6])
	if err != nil {
		return nil, err
	}
	if f[1] != "sms" && f[1] != "call" {
		return nil, errors.New("bad kind")
	}
	subID, _ := strconv.Atoi(f[2])
	when, _ := strconv.ParseInt(f[5], 10, 64)
	callType, _ := strconv.Atoi(f[8])
	durSec, _ := strconv.Atoi(f[9])
	it := telItem{Kind: f[1], SubID: subID, From: b64orEmpty(f[4]), When: when, Body: b64orEmpty(f[7]), CallType: callType, DurSec: durSec}
	return &arrivalReq{verb: "SEAL-TEL", aid: f[0], mono: mono, iccid: f[3], it: it}, nil
}

// readSealMmsV2 reads the header lines after SEAL-MMS's "v2", then the parts, as readSealMms does.
func readSealMmsV2(r *bufio.Reader) (*arrivalReq, error) {
	h, err := readLines(r, 8)
	if err != nil {
		return nil, err
	}
	mono, err := readArrivalHead(h[0], h[5])
	if err != nil {
		return nil, err
	}
	parts, err := readMmsParts(r, h[7])
	if err != nil {
		return nil, err
	}
	subID, _ := strconv.Atoi(h[1])
	when, _ := strconv.ParseInt(h[4], 10, 64)
	it := telItem{Kind: "mms", SubID: subID, From: b64orEmpty(h[3]), When: when, Subject: b64orEmpty(h[6]), Parts: parts}
	return &arrivalReq{verb: "SEAL-MMS", aid: h[0], mono: mono, iccid: h[2], it: it}, nil
}

// telReplay is the first answer to one arrival id.
type telReplay struct {
	reply string
	tag   string // the SIM's tag when the answer was OK, so an unassign can turn it into REMOVED
	at    int64  // bootNowMs() when it was kept, the clock the state tmpfs shares
}

// The replay table, guarded by telMu: the first answer that is not an ERR to each arrival id, keyed by an HMAC of the
// verb and id, so the table never holds an arrival id itself. NWP-20261021-08: it outlives a daemon restart, because
// the chooser retries one arrival with the same id for a minute and init restarts the daemon when it dies -- without
// it a retry across the restart sealed the arrival a second time (Chester's 2026-09-27 answer 1, "no-duplicate
// retries"). It is kept in the state tmpfs beside the SIM-link floor, in .replays (one line per answer: the HMAC in
// hex, the time kept, the SIM tag or "-", the reply in base64), under the key in .replay-key (32 random bytes, minted
// by the first daemon run of the boot and adopted by every later one). That is RAM: both files go at power-off with
// the sealed inbox they describe, so a reboot cannot leave a duplicate. An entry lives telReplayTTL by CLOCK_BOOTTIME,
// the chooser's MMS transaction window, and the table holds at most telReplayMax, evicting the oldest. A file that
// cannot be read or written never changes a reply: the table is then memory-only for the run, as it was before, and
// one content-free line says so. What stays: a daemon that dies between a seal's write and its table entry (one
// append) still seals the retry twice.
var (
	telReplays      = map[[32]byte]*telReplay{}
	telReplayOrder  [][32]byte
	telReplayKey    []byte // nil until telReplayLoad
	telReplayLoaded bool   // the files were read in this daemon run
	telReplayKeyOn  bool   // telReplayKey is the one in .replay-key
	telReplayNoDisk bool   // the key file cannot be read or created: memory only for this run
	telReplayDirty  bool   // .replays must be rewritten from memory before the next append
	telReplayLines  int    // lines in .replays, for the 2*telReplayMax rewrite
	telReplayWarned bool   // the once-per-run persist-failure line was written
)

const (
	telReplayTTL = 12 * time.Hour
	telReplayMax = 4096
)

func newTelReplayKey() []byte {
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		panic(err) // the kernel's random source failed: nothing in the daemon is safe
	}
	return k
}

// telReplayDir, telReplayKeyPath and telReplayPath are beside the telephony inbox, so a test's temporary inbox moves
// them too.
func telReplayDir() string     { return filepath.Dir(telInboxBase) }
func telReplayKeyPath() string { return filepath.Join(telReplayDir(), ".replay-key") }
func telReplayPath() string    { return filepath.Join(telReplayDir(), ".replays") }

// telReplayWarn writes the one line a run says about the table not persisting. It names no id, tag, reply, time or
// path, and no error: a *PathError prints its path.
func telReplayWarn() {
	if telReplayWarned {
		return
	}
	telReplayWarned = true
	fmt.Fprintf(os.Stderr, "[logind] telephony: could not persist the replay table; a restart may seal a retried arrival twice\n")
}

// telReplayLoad reads the key and the table the first time either is asked for in a daemon run. With no key file it
// writes nothing: the key is created by the first put. Caller holds telMu.
func telReplayLoad() {
	if telReplayLoaded {
		return
	}
	telReplayLoaded = true
	b, err := os.ReadFile(telReplayKeyPath())
	switch {
	case err == nil && len(b) == 32:
		telReplayKey = append([]byte(nil), b...)
		telReplayKeyOn = true
	case err == nil: // a torn create: the ids in .replays were made under another key
		telReplayKey = newTelReplayKey()
		if writeAtomic(telReplayKeyPath()+".tmp", telReplayKeyPath(), telReplayKey) != nil {
			telReplayNoDisk = true
			telReplayWarn()
			return
		}
		telReplayKeyOn = true
		if writeAtomic(telReplayPath()+".tmp", telReplayPath(), nil) != nil {
			telReplayDirty = true
			telReplayWarn()
		}
		return
	case errors.Is(err, os.ErrNotExist):
		telReplayKey = newTelReplayKey()
		telReplayDirty = true // a .replays left without its key is rewritten by the first put
		return
	default:
		telReplayKey = newTelReplayKey()
		telReplayNoDisk = true
		telReplayWarn()
		return
	}
	data, err := os.ReadFile(telReplayPath())
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		telReplayDirty = true
		telReplayWarn()
		return
	}
	kept, lines, dropped := telReplayParse(data, bootNowMs())
	for _, k := range kept {
		telReplays[k.id] = k.e
		telReplayOrder = append(telReplayOrder, k.id)
	}
	telReplayLines = lines
	if dropped {
		telReplayRewrite()
	}
}

type telReplayRow struct {
	id [32]byte
	e  *telReplay
}

// telReplayParse reads .replays: the rows to keep, oldest first and at most telReplayMax, how many lines it read, and
// whether anything else was dropped (a line that does not parse, an expired or repeated one, the oldest past the cap,
// a torn tail), so the file is rewritten before an append can join a fragment.
func telReplayParse(data []byte, now int64) (kept []telReplayRow, lines int, dropped bool) {
	if len(data) > 0 && data[len(data)-1] != '\n' {
		dropped = true
	}
	seen := map[[32]byte]bool{}
	for _, ln := range strings.Split(string(data), "\n") {
		if ln == "" {
			continue
		}
		lines++
		f := strings.Split(ln, " ")
		if len(f) != 4 || len(f[0]) != 64 || f[0] != strings.ToLower(f[0]) {
			dropped = true
			continue
		}
		raw, err := hex.DecodeString(f[0])
		at, err2 := strconv.ParseInt(f[1], 10, 64)
		reply, err3 := base64.StdEncoding.DecodeString(f[3])
		if err != nil || err2 != nil || at < 0 || err3 != nil || (f[2] != "-" && !isSimTag(f[2])) ||
			!strings.HasSuffix(string(reply), "\n") || strings.HasPrefix(string(reply), "ERR") {
			dropped = true
			continue
		}
		var id [32]byte
		copy(id[:], raw)
		if now-at >= telReplayTTL.Milliseconds() || seen[id] {
			dropped = true
			continue
		}
		seen[id] = true
		tag := f[2]
		if tag == "-" {
			tag = ""
		}
		kept = append(kept, telReplayRow{id, &telReplay{reply: string(reply), tag: tag, at: at}})
	}
	if len(kept) > telReplayMax {
		kept = kept[len(kept)-telReplayMax:]
		dropped = true
	}
	return kept, lines, dropped
}

// telReplayLine is one row of .replays.
func telReplayLine(id [32]byte, e *telReplay) string {
	tag := e.tag
	if tag == "" {
		tag = "-"
	}
	return hex.EncodeToString(id[:]) + " " + strconv.FormatInt(e.at, 10) + " " + tag + " " +
		base64.StdEncoding.EncodeToString([]byte(e.reply)) + "\n"
}

// telReplayRewrite writes .replays whole from memory. Caller holds telMu.
func telReplayRewrite() {
	var sb strings.Builder
	n := 0
	for _, id := range telReplayOrder {
		if e, ok := telReplays[id]; ok {
			sb.WriteString(telReplayLine(id, e))
			n++
		}
	}
	if os.MkdirAll(telReplayDir(), 0o700) != nil ||
		writeAtomic(telReplayPath()+".tmp", telReplayPath(), []byte(sb.String())) != nil {
		telReplayDirty = true
		telReplayWarn()
		return
	}
	telReplayLines, telReplayDirty = n, false
}

// telReplayPersist makes the table just changed durable in the state tmpfs: the key first, if the boot has none yet,
// then one appended line, or a whole rewrite when the file needs one. A failure only warns. Caller holds telMu.
func telReplayPersist(line string) {
	if telReplayNoDisk {
		return
	}
	if !telReplayKeyOn {
		if os.MkdirAll(telReplayDir(), 0o700) != nil ||
			writeAtomic(telReplayKeyPath()+".tmp", telReplayKeyPath(), telReplayKey) != nil {
			telReplayNoDisk = true
			telReplayWarn()
			return
		}
		telReplayKeyOn = true
	}
	if telReplayDirty || telReplayLines >= 2*telReplayMax {
		telReplayRewrite() // from memory, so it already holds this entry
		return
	}
	f, err := os.OpenFile(telReplayPath(), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil && os.MkdirAll(telReplayDir(), 0o700) == nil {
		f, err = os.OpenFile(telReplayPath(), os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	}
	if err != nil {
		telReplayDirty = true
		telReplayWarn()
		return
	}
	n, err := f.Write([]byte(line))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil || n != len(line) {
		telReplayDirty = true
		telReplayWarn()
		return
	}
	telReplayLines++
}

func telReplayID(verb, aid string) [32]byte {
	telReplayLoad()
	m := hmac.New(sha256.New, telReplayKey)
	m.Write([]byte(verb + "\x00" + aid))
	var id [32]byte
	copy(id[:], m.Sum(nil))
	return id
}

// telReplayGet returns the first answer to this arrival id, if one is kept. Caller holds telMu.
func telReplayGet(id [32]byte) (string, bool) {
	telReplayPrune()
	e, ok := telReplays[id]
	if !ok {
		return "", false
	}
	return e.reply, true
}

// telReplayPut keeps an answer, in memory and in .replays. An ERR is never kept: the next attempt must try again.
// Caller holds telMu.
func telReplayPut(id [32]byte, reply, tag string) {
	if strings.HasPrefix(reply, "ERR") {
		return
	}
	telReplayPrune()
	for len(telReplayOrder) >= telReplayMax {
		delete(telReplays, telReplayOrder[0])
		telReplayOrder = telReplayOrder[1:]
	}
	telReplays[id] = &telReplay{reply: reply, tag: tag, at: bootNowMs()}
	telReplayOrder = append(telReplayOrder, id)
	telReplayPersist(telReplayLine(id, telReplays[id]))
}

func telReplayPrune() {
	for len(telReplayOrder) > 0 {
		e, ok := telReplays[telReplayOrder[0]]
		if ok && bootNowMs()-e.at < telReplayTTL.Milliseconds() {
			return
		}
		delete(telReplays, telReplayOrder[0])
		telReplayOrder = telReplayOrder[1:]
	}
}

// telReplayRemoveTag turns every kept OK for this SIM into REMOVED, in memory and in .replays. It loads first: a
// restarted daemon unassigned before its first arrival must still change the table its retry will read. Caller holds
// telMu.
func telReplayRemoveTag(tag string) {
	telReplayLoad()
	changed := false
	for _, e := range telReplays {
		if e.tag == tag {
			e.reply = "REMOVED\n"
			changed = true
		}
	}
	if changed && telReplayKeyOn && !telReplayNoDisk {
		telReplayRewrite()
	}
}

// The v2 verdicts, for handleTelCmd's slow-wait line.
const (
	telVerdictReplayed    = "a repeat, answered from the replay table"
	telVerdictUnresolved  = "SIM not resolved, nothing kept"
	telVerdictRemoved     = "unassigned since it arrived, nothing kept"
	telVerdictSealedNoone = "bound SIM, kept for nobody"
	telVerdictOwner       = "unbound SIM, sealed to the device owner"
	telVerdictOwnerFull   = "unbound SIM, owner inbox at its budget -- nothing kept"
)

// sealArrival serves one v2 arrival: it replays a repeat, resolves the SIM link in force when the arrival came in,
// and seals a bound one to the owners it has kept since. It returns its verdict for handleTelCmd's log. Caller holds
// telMu.
func sealArrival(w io.Writer, dest string, a *arrivalReq) string {
	id := telReplayID(a.verb, a.aid)
	if reply, ok := telReplayGet(id); ok {
		telClassNote(telClassReplayed)
		io.WriteString(w, reply)
		return telVerdictReplayed
	}
	b, class := arrivalLine(a.it.SubID, a.iccid, a.mono)
	var reply, verdict, tag string
	switch class {
	case lineUnbound:
		reply, verdict = sealUnboundToOwner(a) // Slice D: the unbound SIM is the device owner's line (telephony_owner.go)
	case lineUnresolved:
		telClassNote(telClassUnresolved)
		reply, verdict = "UNRESOLVED\n", telVerdictUnresolved
	case lineDamaged: // readBindingsState already noted telClassBindingsDamaged
		reply, verdict = "UNRESOLVED\n", telVerdictUnresolved
	case lineLinkUnknown:
		telClassNote(telClassLinkUnknown)
		reply, verdict = "UNRESOLVED\n", telVerdictUnresolved
	case lineRemoved:
		telClassNote(telClassRemoved)
		reply, verdict = "REMOVED\n", telVerdictRemoved
	default:
		reply, verdict = sealBoundArrival(dest, b, a)
		tag = simTag(b.ICCID)
	}
	telReplayPut(id, reply, tag)
	io.WriteString(w, reply)
	return verdict
}

// sealBoundArrival hands a bound arrival to its owners (deliverToOwners) and builds the OK line, or ERR nobody when
// no owner's seal landed and no owner is live. An MMS over the size cap is kept without its media, as v1 does.
func sealBoundArrival(dest string, b simBinding, a *arrivalReq) (string, string) {
	it := a.it
	stripped := false
	if a.verb == "SEAL-MMS" && telItemOversize(it) {
		it.Parts = nil
		it.Note = "too-large"
		stripped = true
	}
	sealed, appended, kick := deliverToOwners(dest, b, it)
	kept := sealed
	if appended != "" {
		kept++
	}
	if kept < len(b.Owners) {
		telClassNote(telClassNotEveryOwner) // one class for a partial and a total failure: see telClassNotEveryOwner
	}
	vis := noticeVisibility(b.Visibility)
	if kept == 0 {
		return errNobodyReply(vis), telVerdictSealedNoone
	}
	// LIVE only when kicked: deliverToOwners sets appended whenever the live session's mailbox took the arrival, also
	// while its bring-up is held (telStagingHolds), and a held session must not be kicked -- so the line carries no LIVE then.
	liveUID := ""
	if kick {
		liveUID = appended
	}
	label := base64.StdEncoding.EncodeToString([]byte(b.Label))
	return okArrivalReply(vis, label, sealed, stripped, kept > 0 && kept < len(b.Owners), liveUID), arrivalVerdict(sealed, appended, kick)
}

// okArrivalReply is the OK line of a bound arrival: "OK <vis> <label_b64> <n>", then " STRIPPED" when an MMS was kept
// without its media, then " PARTIAL" when it was kept for some but not every owner of its SIM (Q029: the gate's reply
// only, the log keeps one class), then " LIVE <uid>" when liveUID is set. The chooser's TelArrival.parse reads it;
// core/agent/testdata/tel-wire-v2.txt holds both sides to it.
func okArrivalReply(vis, labelB64 string, sealed int, stripped, partial bool, liveUID string) string {
	tail := ""
	if stripped {
		tail += " STRIPPED"
	}
	if partial {
		tail += " PARTIAL"
	}
	if liveUID != "" {
		tail += " LIVE " + liveUID
	}
	return fmt.Sprintf("OK %s %s %d%s\n", vis, labelB64, sealed, tail)
}

// errNobodyReply is the reply of a bound arrival that no owner's seal reached while no owner was live.
func errNobodyReply(vis string) string {
	return "ERR nobody " + vis + "\n"
}

// The telephony classes logged once per daemon run (telClassNote). A class seen on every arrival -- a full store, a
// damaged bindings.conf -- would otherwise put the time of every call and text into login.log, which rides every
// in-session issue report. Later occurrences are only counted in memory; a gate report names the classes seen, with no
// count (telClassSummary). None names a number, an ICCID, a SIM tag, an arrival id, a ref, or how many owners a line
// has.
const (
	telClassUnresolved      = "an arrival's SIM was not identified"
	telClassLinkUnknown     = "an arrival's SIM link when it came in is unknown"
	telClassRemoved         = "an arrival's SIM was unassigned since it came in"
	telClassReplayed        = "a repeated arrival was answered from the replay table"
	telClassBindingsDamaged = "bindings.conf is damaged"
	telClassSealCaller      = "a SEAL-TEL or SEAL-MMS caller that is not the user-0 gate was refused"
	// ONE class for a partial and a total failure, on purpose: a class for "one owner's seal failed" could only
	// occur on a line with two or more owners, so its line alone would tell a reader of login.log that such a line
	// exists -- the per-SIM owner count the 2026-09-01 (e) decision calls a blind-login leak.
	telClassNotEveryOwner = "an arrival was not kept for every owner of its SIM"
	// Slice D (telephony_owner.go): the device-owner inbox. No number, no count -- just the class.
	telClassOwnerNoKey = "an unbound-SIM arrival found no device-owner key to seal to"
	telClassOwnerFull  = "an unbound-SIM arrival was dropped: the device-owner inbox is at its budget"
	telClassBoundFull  = "a bound-SIM arrival was dropped: the bound inbox is at its budget"
)

var (
	telClassMu     sync.Mutex
	telClassCounts = map[string]int{}
)

// telClassNote counts one occurrence of a class and logs the first in this daemon run.
func telClassNote(class string) {
	telClassMu.Lock()
	n := telClassCounts[class]
	telClassCounts[class] = n + 1
	telClassMu.Unlock()
	if n == 0 {
		fmt.Fprintf(os.Stderr, "[logind] telephony: %s (logged once per daemon run; later ones are only counted)\n", class)
	}
}

// telClassSummary names every class seen in this daemon run, sorted, or "" when there is none -- with NO count. The gate
// report it goes into (buildIssueReport, device scope) is shown on screen at the gate to whoever opens it -- on a
// rental phone, the operator -- and sent to the gateway, and how many arrivals reached a renter's line since the boot is
// message metadata docs/privacy-claims.md says the operator does not learn.
func telClassSummary() string {
	telClassMu.Lock()
	defer telClassMu.Unlock()
	var out []string
	for c := range telClassCounts {
		out = append(out, c)
	}
	sort.Strings(out)
	return strings.Join(out, "; ")
}

// withTelClasses adds telClassSummary to a gate report's status, as "telephony_classes", and to nothing else: an
// in-session report already carries login.log, which logged the first of each.
func withTelClasses(m map[string]string, deviceScope bool) map[string]string {
	s := telClassSummary()
	if !deviceScope || s == "" {
		return m
	}
	if m == nil {
		m = map[string]string{}
	}
	m["telephony_classes"] = s
	return m
}
