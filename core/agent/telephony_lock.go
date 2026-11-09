package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// telMu serializes the telephony state -- the sealed inbox and the per-uid mailboxes under $STATE/tel, and
// bindings.conf -- in place of sessionMu (NWP-20260927-09). Until then the arrival and hand-off verbs serialized on
// sessionMu with every session-mutating command, and the chooser gives up first: 5 s for an SMS or a call attempt,
// 10 s for an MMS or a claim. An arrival during a login, a logoff's CLEAN-STORAGE (43.6 s on lynx, 2026-09-27), a
// delete or a materialise lost its gate notice, left no trace at all on an unbound SIM, and on a bound one was sealed
// late into a socket nobody read (docs/backlog.md, "Telephony arrivals wait on the daemon's session lock ...").
//
// The rules:
//   - SEAL-TEL, SEAL-MMS, GET-TELINGEST, ACK-TELINGEST and RESTAGE-TELINGEST take ONLY telMu (handleTelCmd). They
//     read their whole request before it, and write their reply after it.
//   - A session op takes telMu only around its telephony steps, and only for local file work -- never a store round
//     trip: ROAM-IN and RESUME in beginTelStaging, stageTelInboxLocked and endTelStaging; DELETE around its binding
//     purge and around its marker and mailbox removal; DELETE-BINDING around the whole unassign; SET-BINDING around
//     its write.
//   - Lock order is sessionMu, then telMu. Nothing that holds telMu takes sessionMu.
//   - The device-owner key (owner_key.go) publishes its file by a rename under telMu, taken inside ownerKeyMu: the
//     order is ownerKeyMu, then telMu, and nothing that holds telMu or sessionMu takes ownerKeyMu.
//
// What it guarantees: an arrival reads the session marker and acts on it -- a mailbox append or a sealed blob -- as
// one step with respect to a login's staging, so staging neither misses the blob nor drops the row; a claim reads and
// then removes each mailbox with no append in between; and an unassign's records and binding go together.
var telMu sync.Mutex

// telStagingUID is the user a ROAM-IN or RESUME handler is bringing up right now ("" when none); guarded by telMu.
// Its .roamsession marker already names the session, but the chooser switches into it only after the reply, and its
// providers settle after that. So an arrival for it is appended to its mailbox WITHOUT the LIVE kick, and the login's
// own delivery run claims it: a live run then would insert once, with no settle, into a session that cannot take it
// yet. It covers the daemon's handler from before the marker to the reply and, since NWP-20261006-03, past an OK
// reply until the session's own delivery run claims its mailbox, capped (telStagingUntil, holdTelStagingUntilClaim):
// after a ROAM-IN's reply the chooser still prepares the user for seconds before it switches, and an arrival in that
// gap used to be kicked live (docs/backlog.md, "An arrival after ROAM-IN has replied, but before the chooser has
// switched in and claimed ..."). A RESUME is held the same way. Kept in memory on purpose:
// a daemon restart drops the chooser's ROAM-IN or RESUME connection, which ends that bring-up, so "" is the right
// answer after one.
var telStagingUID string

// telStagingUntil caps a bring-up HELD past its handler's reply (NWP-20261006-03, see holdTelStagingUntilClaim); the
// zero time while the handler itself runs. Guarded by telMu.
var telStagingUntil time.Time

// telStagingHoldCap bounds a held bring-up: the session's own delivery run claims seconds after its switch, so a hold
// that outlives this means that run never came, and live delivery resumes rather than staying silent.
const telStagingHoldCap = 5 * time.Minute

// underTelMu runs fn holding telMu and releases it even if fn panics. handleLogin recovers from a panic, and a telMu
// left locked would silence every arrival until a reboot.
func underTelMu(fn func()) {
	telMu.Lock()
	defer telMu.Unlock()
	fn()
}

// beginTelStaging marks uid as coming up. The caller runs it BEFORE the session marker names uid, and defers
// endTelStaging. fresh is for a ROAM-IN: its uid is new, so any mailbox of it is a stale leftover, removed here --
// before any arrival can append to it, instead of at staging, where the removal would now take a row an arrival
// queued for this session. The error is that removal's; a roam-in then keeps its backlog sealed, as a failed
// removal at staging did. A RESUME keeps its mailbox: the rows in it are the same session's.
func beginTelStaging(uid string, fresh bool) error {
	var err error
	underTelMu(func() {
		if fresh {
			err = removeMailboxes(uid)
		}
		sweepGoneMailboxes() // NWP-20261006-14: and any ended session's plaintext mailbox
		telStagingUID = uid
		telStagingUntil = time.Time{}
	})
	return err
}

// endTelStaging ends uid's bring-up, unless another has begun since -- or it was HELD at its OK reply
// (NWP-20261006-03): a held bring-up outlives its handler and ends at the session's own claim or the cap.
func endTelStaging(uid string) {
	underTelMu(func() {
		if telStagingUID == uid && telStagingUntil.IsZero() {
			telStagingUID = ""
			telStagingUntil = time.Time{}
		}
	})
}

// holdTelStagingUntilClaim keeps uid's bring-up after its ROAM-IN or RESUME handler has replied OK, until the session's
// OWN delivery run claims its mailbox (serveGetTelIngest) or telStagingHoldCap passes. NWP-20261006-03: after the
// reply the chooser still prepares the user (prep, provisioning, prefs with a network round trip, the home role)
// before it switches in and kicks the login's run; an arrival in that gap was kicked LIVE into a session that could
// not take it yet -- one pass, no settle, before the SMS role was ceded -- and took the staged backlog with it. Held,
// the arrival is appended without a kick and the login's own settled run delivers it. Returns whether it held
// (false when another bring-up has begun since); the handler's deferred endTelStaging then leaves a held one alone.
// Since NWP-20261116-03 a ROAM-IN's claim releases it only after the late hand-off is done (beginTelHandoff).
func holdTelStagingUntilClaim(uid string) bool {
	held := false
	underTelMu(func() {
		if telStagingUID == uid {
			telStagingUntil = time.Now().Add(telStagingHoldCap)
			held = true
		}
	})
	return held
}

// telStagingHolds reports whether uid is being brought up now, so an arrival for it must not be kicked live: during
// its handler, or after it while held and not past the cap. Caller holds telMu.
func telStagingHolds(uid string) bool {
	return uid != "" && uid == telStagingUID && (telStagingUntil.IsZero() || time.Now().Before(telStagingUntil))
}

// telHandoffPending holds the uids whose ROAM-IN hand-off has not yet staged, failed or been skipped (h46 #1,
// NWP-20261116-03): the hand-off runs in the sign-in's late job, after the reply, so the session's delivery claim can
// come before it. A uid is "hand-off done" (the task's telHandoffDone) when it is ABSENT from this map: a RESUME,
// which stages before its reply, never adds one. Memory only; guarded by telMu.
var telHandoffPending = map[string]bool{}

// beginTelHandoff marks uid's hand-off pending. handleRoamIn calls it before its reply, after the throwaway return,
// so a claim that comes while startLateWork still waits out an older job keeps the hold. If the handler panics
// between this and startLateWork (only the reply's write sits between them), no job marks it done: the cap
// (telStagingHoldCap) still ends the hold, and the next sign-in has a new uid.
func beginTelHandoff(uid string) { underTelMu(func() { telHandoffPending[uid] = true }) }

// markTelHandoffDone marks uid's hand-off done: staged, failed, skipped, or its late job ended or was abandoned.
func markTelHandoffDone(uid string) { underTelMu(func() { delete(telHandoffPending, uid) }) }

// stageTelInboxGuarded is stageTelInboxLocked with the late job's last check INSIDE telMu (h46 #1), so no abandonment
// or sign-out lands between the check and the staging. mayWrite reads the .roamsession marker FILE and an atomic,
// never the store: telMu never waits on the network, and it takes no lock that sessionMu or ownerKeyMu ranks below.
// The hand-off is marked done in the same critical section, so a claim sees the staged rows and the release together.
// skipped reports that the check said no and nothing was staged; the sealed blobs then stay in the inbox.
func stageTelInboxGuarded(v *vault, dk []byte, profileRef, uid string, mayWrite func() bool) (n int, skipped bool, err error) {
	underTelMu(func() {
		defer delete(telHandoffPending, uid)
		if !lateMayWrite(mayWrite) {
			skipped = true
			return
		}
		n, err = stageTelInbox(v, dk, profileRef, uid)
	})
	return n, skipped, err
}

// stageTelInboxLocked is stageTelInbox under telMu. The caller resolves the vault and DK first, outside it: those
// are store reads, and telMu must never wait on the network.
func stageTelInboxLocked(v *vault, dk []byte, profileRef, uid string) (n int, err error) {
	underTelMu(func() { n, err = stageTelInbox(v, dk, profileRef, uid) })
	return n, err
}

// telCmd reports whether handleTelCmd serves a verb.
func telCmd(name string) bool {
	switch name {
	case "SEAL-TEL", "SEAL-MMS", "GET-TELINGEST", "ACK-TELINGEST", "RESTAGE-TELINGEST", "ACK-TELROWS":
		return true
	}
	return false
}

// The verdicts the arrival verbs return for handleTelCmd's log.
const (
	telVerdictErr         = "refused"
	telVerdictUnbound     = "unbound SIM, nothing kept"
	telVerdictLive        = "delivered to the live session"
	telVerdictQueued      = "queued for the session being brought up"
	telVerdictSealed      = "sealed"
	telVerdictKeptNowhere = "bound SIM, kept NOWHERE"
)

// arrivalVerdict names what one arrival's delivery did.
func arrivalVerdict(sealed int, appended string, kick bool) string {
	switch {
	case kick:
		return telVerdictLive
	case appended != "":
		return telVerdictQueued
	case sealed > 0:
		return telVerdictSealed
	}
	return telVerdictKeptNowhere
}

// telSlowWait is the telMu wait above which a telephony verb is logged. A quicker verb is logged only when it went
// wrong: a line for every arrival would put the time of every call and text into login.log, which rides every
// in-session issue report, including a SIM whose owner set its gate notice to "private".
const telSlowWait = time.Second

// handleTelCmd serves the telephony verbs under telMu (see telMu). The whole request is read first, so waiting can
// never cut it short -- the fields used to be read after sessionMu, with their errors discarded, and a wait past the
// 60 s connection deadline sealed what had been buffered. A short read, a SEAL-MMS part count outside
// 0..maxMmsParts, a SEAL-MMS part whose data is not base64, or a bad SEAL-TEL kind answers ERR and changes nothing;
// SEAL-MMS's other base64 fields (from, subject, a part's type or name) are kept empty when they do not decode, a
// SEAL-TEL body that is not base64 is kept with an empty body (readSealTel), and unparseable numeric fields read as
// 0, as before. The reply is built under telMu and written
// after it, so a chooser that is slow to read never holds it.
func handleTelCmd(conn net.Conn, r *bufio.Reader, dest, name string) {
	var f []string
	var mmsICCID, row string
	var ackKeys []string // ACK-TELROWS (NWP-20261006-05)
	var mms telItem
	var arr *arrivalReq // a v2 arrival (telephony_arrival.go); nil for v1
	var err error
	switch name {
	case "SEAL-TEL":
		f, arr, err = readSealTel(r)
	case "SEAL-MMS":
		mmsICCID, mms, arr, err = readSealMms(r)
	case "RESTAGE-TELINGEST":
		var l []string
		if l, err = readLines(r, 1); err == nil {
			row = l[0]
		}
	case "ACK-TELROWS":
		// "ACK-TELROWS\n<n>\n<kind> <when_ms>\n" x n: the rows this session's chooser has INSERTED. Their pending
		// copies are deleted (ackPending); anything not listed stays for the next sign-in.
		var l []string
		if l, err = readLines(r, 1); err == nil {
			n, perr := strconv.Atoi(strings.TrimSpace(l[0]))
			if perr != nil || n < 0 || n > maxAckRows {
				err = errAckCount
			} else if ackKeys, err = readLines(r, n); err != nil {
				ackKeys = nil
			}
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "[logind] %s refused: %v\n", name, err) // the error names a field, never its value
		fmt.Fprintf(conn, "ERR %v\n", err)
		return
	}
	// Only the user-0 gate seals: it alone downloads an MMS (WapPushDeliverReceiver, NWP-20260930-04), and since
	// NWP-20260930-05 a call declined in a stranger's session is handed to it to seal (RejectedCallSealReceiver).
	// Checked after the request is read and before telMu, with no write.
	if (name == "SEAL-MMS" || name == "SEAL-TEL") && !ownerCallerOK(ownerPeerUID(conn)) {
		telClassNote(telClassSealCaller)
		fmt.Fprint(conn, "ERR caller\n")
		return
	}
	puid := peerUID(conn)
	var out bytes.Buffer
	verdict := ""
	start := time.Now()
	var waited time.Duration
	underTelMu(func() {
		waited = time.Since(start)
		switch name {
		case "SEAL-TEL", "SEAL-MMS":
			switch {
			case arr != nil:
				verdict = sealArrival(&out, dest, arr)
			case name == "SEAL-TEL":
				verdict = handleSealTel(&out, dest, f)
			default:
				verdict = handleSealMms(&out, dest, mmsICCID, mms)
			}
		case "GET-TELINGEST":
			serveGetTelIngest(&out, puid)
		case "ACK-TELINGEST":
			// #149: GET-TELINGEST CLAIMS (atomically takes) the mailbox, so there is nothing left to ACK. Kept as an
			// accepted no-op for wire compatibility with the chooser (and a mixed daemon/chooser window).
			out.WriteString("OK\n")
		case "RESTAGE-TELINGEST":
			serveRestageTelIngest(&out, puid, row)
		case "ACK-TELROWS":
			// Peer-authorized like GET-TELINGEST: a session acknowledges only rows handed to its OWN user.
			if puid <= 0 {
				out.WriteString("ERR\n")
			} else {
				fmt.Fprintf(&out, "OK %d\n", ackPending(strconv.Itoa(puid/100000), ackKeys))
			}
		}
	})
	if verdict == telVerdictKeptNowhere { // a v1 arrival sealed to nobody: once per run, as v2's (NWP-20260930-04)
		telClassNote(telClassNotEveryOwner)
	}
	if waited >= telSlowWait || verdict == telVerdictErr {
		fmt.Fprintf(os.Stderr, "[logind] %s waited %dms for telMu -> %s\n", name, waited.Milliseconds(), orDash(verdict))
	}
	conn.Write(out.Bytes())
}

// orDash is s, or "-" when it is empty.
func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// maxAckRows bounds one ACK-TELROWS (NWP-20261006-05); a delivery run is a session's backlog, far under this.
const maxAckRows = 4096

// errAckCount is an ACK-TELROWS whose count line is not a number in range.
var errAckCount = errors.New("count")

// errShortRequest is a request cut off before its last newline: EOF, or the connection deadline.
var errShortRequest = errors.New("short request")

// readLines reads n newline-terminated lines, each with its line ending trimmed. A line with no newline is an error,
// never a field: the old readers took whatever had arrived.
func readLines(r *bufio.Reader, n int) ([]string, error) {
	out := make([]string, n)
	for i := range out {
		s, err := r.ReadString('\n')
		if err != nil {
			return nil, errShortRequest
		}
		out[i] = strings.TrimRight(s, "\r\n")
	}
	return out, nil
}

// readSealTel reads SEAL-TEL's eight fields (#135 B2), the arrival of one SMS or call at the gate:
//
//	"SEAL-TEL\n<kind>\n<sub_id>\n<iccid>\n<from>\n<when_ms>\n<body_b64>\n<call_type>\n<dur_sec>\n"
//
// Reply (handleSealTel): "OK <visibility> <label_b64> <sealed_count> [LIVE <uid>]" (SIM bound) | "NONE" (unbound SIM:
// an INTERIM drop) | "ERR ...". The caller uses <visibility>/<label> for the gate notice. Only a short request is
// refused. A body that is not base64 is NOT: the shipped chooser sends <from> raw, so a sender ID with a newline shifts
// the later fields, and refusing that would leave the arrival no record and no notice; handleSealTel keeps it with an
// empty body instead, as it always did.
//
// NWP-20260930-04: a first line of "v2" is a v2 request instead (readSealTelV2, telephony_arrival.go).
func readSealTel(r *bufio.Reader) ([]string, *arrivalReq, error) {
	first, err := readLines(r, 1)
	if err != nil {
		return nil, nil, err
	}
	if first[0] == "v2" {
		a, err := readSealTelV2(r)
		return nil, a, err
	}
	rest, err := readLines(r, 7)
	if err != nil {
		return nil, nil, err
	}
	return append(first, rest...), nil, nil
}

// readSealMms reads SEAL-MMS (#150 P2), an MMS downloaded at the gate. Like SEAL-TEL but variable-length (base64
// fields, "-" = empty; the parts are read in a loop):
//
//	"SEAL-MMS\n<sub_id>\n<iccid>\n<from_b64>\n<when_ms>\n<subject_b64>\n<nparts>\n"
//	then nparts x: "<ct_b64>\n<name_b64>\n<data_b64>\n"
//
// Reply (handleSealMms): "OK <visibility> <label_b64> <sealed_count> [STRIPPED] [LIVE <uid>]" (SIM bound; STRIPPED =
// an over-cap MMS had its media dropped to a content-free notice; LIVE = delivered straight into a signed-in owner's
// session) | "NONE" (unbound SIM: an INTERIM drop) | "ERR ...". The chooser is the only (peer-authed) caller and
// bounds the download size. A part whose data is not base64 is refused: it used to be sealed empty.
//
// NWP-20260930-04: a first line of "v2" is a v2 request instead (readSealMmsV2, telephony_arrival.go).
func readSealMms(r *bufio.Reader) (string, telItem, *arrivalReq, error) {
	first, err := readLines(r, 1)
	if err != nil {
		return "", telItem{}, nil, err
	}
	if first[0] == "v2" {
		a, err := readSealMmsV2(r)
		return "", telItem{}, a, err
	}
	rest, err := readLines(r, 5)
	if err != nil {
		return "", telItem{}, nil, err
	}
	hdr := append(first, rest...)
	subID, _ := strconv.Atoi(hdr[0])
	when, _ := strconv.ParseInt(hdr[3], 10, 64)
	parts, err := readMmsParts(r, hdr[5])
	if err != nil {
		return "", telItem{}, nil, err
	}
	// from is base64 so a sender-crafted From with a newline can't desync the fixed header.
	it := telItem{Kind: "mms", SubID: subID, From: b64orEmpty(hdr[2]), When: when, Subject: b64orEmpty(hdr[4]), Parts: parts}
	return hdr[1], it, nil, nil
}

// readMmsParts reads SEAL-MMS's part count and then its parts. A count outside 0..maxMmsParts, or a part whose data
// is not base64, is refused: such a part used to be sealed empty.
func readMmsParts(r *bufio.Reader, count string) ([]mmsPart, error) {
	nparts, err := strconv.Atoi(count)
	if err != nil || nparts < 0 || nparts > maxMmsParts {
		return nil, errors.New("bad nparts")
	}
	parts := make([]mmsPart, 0, nparts)
	for i := 0; i < nparts; i++ {
		p, err := readLines(r, 3)
		if err != nil {
			return nil, err
		}
		data, err := base64.StdEncoding.DecodeString(p[2])
		if err != nil {
			return nil, fmt.Errorf("part %d's data is not base64", i)
		}
		parts = append(parts, mmsPart{ContentType: b64orEmpty(p[0]), Name: b64orEmpty(p[1]), Data: data})
	}
	return parts, nil
}

// serveGetTelIngest (#135 delivery v2): "GET-TELINGEST\n" -> atomically TAKE the caller's OWN user's pending decrypted
// telephony rows (staged by stageTelInbox at roam-in or resume, or queued by an arrival). The ROAMED chooser inserts
// them into its own SMS/CallLog with a verify-first query-back (unlike the su:s0 worker, which couldn't verify --
// #360/#362). Caller identity is SO_PEERCRED (uid/100000 = userId) on top of the pinned-appId gate: a session only
// ever reads rows staged FOR it. Reply "OK\n<row>..." | "NONE". claimTelIngest takes every mailbox file of the uid
// (one per SIM since NWP-20260924-07) under telMu, so a concurrent arrival's append can't be deleted unread (the #149
// lost-append race). It serves every file it read AND removed; one that will not read or will not go is left for the
// next claim.
func serveGetTelIngest(w io.Writer, puid int) {
	if puid <= 0 {
		fmt.Fprint(w, "NONE\n")
		return
	}
	u := strconv.Itoa(puid / 100000)
	// NWP-20261006-03: the session's own delivery run has come: the held bring-up ends here, and later arrivals go live.
	// NWP-20261116-03 (h46 #1): but only once a ROAM-IN's late hand-off has staged, failed or been skipped
	// (telHandoffPending). Before that the claim serves the mailbox and leaves the hold; telStagingHoldCap still ends it.
	// The residual: TelIngest sends ONE GET-TELINGEST per login run, at the START of the run, before its 20 s settle
	// (TelIngest.run). Rows the hand-off stages after that claim are not delivered by it. The hold then lasts to the
	// cap, 5 minutes from the reply, so texts that arrive in that window are appended without a live kick. Those rows
	// and those arrivals wait for the next claim: a cold-lock RESUME re-kick (#385), or the first arrival after the cap,
	// whose live run takes the whole mailbox. None is lost if the session ends first: the sealed copies stay pending
	// until ACK-TELROWS (telephony_pending.go), and the profile's next sign-in stages them again.
	if telStagingUID == u && !telStagingUntil.IsZero() && !telHandoffPending[u] {
		telStagingUID, telStagingUntil = "", time.Time{}
	}
	b, _ := claimTelIngest(u)
	if len(b) == 0 {
		fmt.Fprint(w, "NONE\n")
		return
	}
	fmt.Fprintf(w, "OK\n%s", string(b))
}

// serveRestageTelIngest (#135 Part 3): the roamed chooser could not persist this telephony row this delivery run (a
// transient insert failure that outlasted the 3 re-verify passes). Append it BACK to the caller's OWN mailbox so a
// later kick -- e.g. the cold-lock RESUME re-kick (#385) -- retries it, instead of log-and-dropping it (GET-TELINGEST
// already popped the mailbox; ACK is a no-op). Peer-authorized by SO_PEERCRED (uid/100000 = userId), same as GET -- a
// session only re-stages rows FOR its own user. The chooser caps retries via a trailing retry token on the row, so
// this does not loop. UserManagerService keeps every user id removed during a boot out of reuse until the reboot
// (GrapheneOS refuses to recycle at all; AOSP only at id exhaustion), and the tmpfs dies with the boot, so a re-staged
// row is not served to a different profile short of a system_server restart that keeps the tmpfs. The mailbox carries
// no profile tag, so that is not guaranteed by construction (docs/backlog.md). Wire: "RESTAGE-TELINGEST\n<row>\n".
func serveRestageTelIngest(w io.Writer, puid int, row string) {
	if puid <= 0 {
		fmt.Fprint(w, "ERR\n")
		return
	}
	if row == "" {
		fmt.Fprint(w, "OK\n")
		return
	}
	// NWP-20260924-07: a call row carries its SIM tag, so it goes back to that SIM's mailbox -- or is dropped (reply
	// OK: the chooser must not retry it) when that SIM was unassigned while the chooser held it. NWP-20261005-15: an
	// SMS or MMS row (the chooser re-stages those too now) gets the same treatment, from its own slot since
	// NWP-20261130-01, else from the SIM it was claimed from.
	if _, err := restageTelIngest(strconv.Itoa(puid/100000), row); err != nil {
		fmt.Fprint(w, "ERR\n")
		return
	}
	fmt.Fprint(w, "OK\n")
}
