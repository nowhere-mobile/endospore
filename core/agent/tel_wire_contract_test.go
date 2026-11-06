package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
)

// NWP-20261022-11: the v2 SEAL-TEL wire, held to one fixture (testdata/tel-wire-v2.txt) that the chooser's
// TelArrival is held to as well (core/chooser/tests/tel-wire). The file says what each column is.

const telWireFixturePath = "testdata/tel-wire-v2.txt"

type telWireReq struct {
	name, aid, kind, iccid, from, body, request string
	sub, callType, durSec                       int
	when, mono                                  int64
}

type telWireReply struct {
	name, line, kind, vis, label, sealed, liveUID, stripped, partial string
}

// telWireUnescape reads the fixture's escapes in one left-to-right pass: \\, \n and \t, nothing else.
func telWireUnescape(s string) (string, bool) {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' {
			b.WriteByte(s[i])
			continue
		}
		i++
		if i >= len(s) {
			return "", false
		}
		switch s[i] {
		case '\\':
			b.WriteByte('\\')
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		default:
			return "", false
		}
	}
	return b.String(), true
}

func telWireFixture(t *testing.T) ([]telWireReq, []telWireReply) {
	t.Helper()
	raw, err := os.ReadFile(telWireFixturePath)
	if err != nil {
		t.Fatalf("the wire fixture %s cannot be read: %v", telWireFixturePath, err)
	}
	var reqs []telWireReq
	var reps []telWireReply
	for n, line := range strings.Split(string(raw), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		cols := strings.Split(line, "\t")
		f := make([]string, len(cols))
		for i, c := range cols {
			u, ok := telWireUnescape(c)
			if !ok {
				t.Fatalf("%s:%d: field %d has a bad escape", telWireFixturePath, n+1, i+1)
			}
			f[i] = u
		}
		num := func(i int) int64 {
			v, err := strconv.ParseInt(f[i], 10, 64)
			if err != nil {
				t.Fatalf("%s:%d (%s): field %d %q is not a number", telWireFixturePath, n+1, f[1], i+1, f[i])
			}
			return v
		}
		switch {
		case f[0] == "REQ-TEL" && len(f) == 13:
			reqs = append(reqs, telWireReq{name: f[1], aid: f[2], kind: f[3], sub: int(num(4)), iccid: f[5], from: f[6],
				when: num(7), mono: num(8), body: f[9], callType: int(num(10)), durSec: int(num(11)), request: f[12]})
		case f[0] == "REPLY" && len(f) == 10:
			reps = append(reps, telWireReply{name: f[1], line: f[2], kind: f[3], vis: f[4], label: f[5], sealed: f[6],
				liveUID: f[7], stripped: f[8], partial: f[9]})
		default:
			t.Fatalf("%s:%d: %d fields of a %q record do not parse", telWireFixturePath, n+1, len(f), f[0])
		}
	}
	if len(reqs) == 0 || len(reps) == 0 {
		t.Fatalf("%s holds %d REQ-TEL and %d REPLY cases; both kinds are needed", telWireFixturePath, len(reqs), len(reps))
	}
	return reqs, reps
}

// The daemon's reader must read the chooser's request back as the inputs it was built from.
func TestTelWireRequestReadsAsSent(t *testing.T) {
	reqs, _ := telWireFixture(t)
	const head = "SEAL-TEL\nv2\n"
	for _, c := range reqs {
		t.Run(c.name, func(t *testing.T) {
			if !strings.HasPrefix(c.request, head) {
				t.Fatalf("the request does not start %q", head)
			}
			r := bufio.NewReader(strings.NewReader(strings.TrimPrefix(c.request, head)))
			a, err := readSealTelV2(r)
			if err != nil {
				t.Fatalf("readSealTelV2: %v", err)
			}
			if _, err := r.ReadByte(); err != io.EOF {
				t.Errorf("bytes left unread after the request")
			}
			it := a.it
			if a.aid != c.aid || it.Kind != c.kind || it.SubID != c.sub || a.iccid != c.iccid || it.From != c.from ||
				it.Body != c.body || it.When != c.when || a.mono != c.mono || it.CallType != c.callType || it.DurSec != c.durSec {
				t.Errorf("read back aid=%q kind=%q sub=%d iccid=%q from=%q body=%q when=%d mono=%d callType=%d dur=%d\nwant %+v",
					a.aid, it.Kind, it.SubID, a.iccid, it.From, it.Body, it.When, a.mono, it.CallType, it.DurSec, c)
			}
		})
	}
}

// The daemon's formatter must write the OK and ERR nobody lines the chooser's fixture says it reads.
func TestTelWireOKAndErrNobodyFormat(t *testing.T) {
	_, reps := telWireFixture(t)
	ok, nobody := 0, 0
	for _, c := range reps {
		switch {
		case c.kind == "OK":
			sealed, err := strconv.Atoi(c.sealed)
			if err != nil {
				t.Fatalf("%s: sealed %q is not a count", c.name, c.sealed)
			}
			live := ""
			if c.liveUID != "-1" {
				live = c.liveUID
			}
			label := base64.StdEncoding.EncodeToString([]byte(c.label))
			if got := okArrivalReply(c.vis, label, sealed, c.stripped == "1", c.partial == "1", live); got != c.line+"\n" {
				t.Errorf("%s: okArrivalReply = %q, want %q", c.name, got, c.line+"\n")
			}
			ok++
		case strings.HasPrefix(c.line, "ERR nobody "):
			if got := errNobodyReply(c.vis); got != c.line+"\n" {
				t.Errorf("%s: errNobodyReply = %q, want %q", c.name, got, c.line+"\n")
			}
			nobody++
		}
	}
	if ok == 0 || nobody == 0 {
		t.Fatalf("the fixture checked %d OK and %d ERR nobody replies; both are needed", ok, nobody)
	}
	// Appended but not kicked: sealBoundArrival gives liveUID "", and the line carries no LIVE.
	if got := okArrivalReply("open", "TA==", 1, false, false, ""); got != "OK open TA== 1\n" || strings.Contains(got, "LIVE") {
		t.Errorf("an arrival not kicked: %q, want %q", got, "OK open TA== 1\n")
	}
}

// sealBoundArrival puts LIVE on the line only when the session was kicked: a held bring-up takes the arrival (appended
// is set) but is not kicked, and the chooser reads LIVE as "show it now".
func TestTelWireHeldSessionGetsNoLive(t *testing.T) {
	resetStaging(t)
	useTempInbox(t)
	useTempIngest(t)
	dest := t.TempDir()
	if err := markRoamSession(dest, "alice", "pw", "10", ""); err != nil {
		t.Fatal(err)
	}
	v, _ := vaultWithTelKey(t)
	b := simBinding{SubID: 1, ICCID: iccidX, Label: "L", Visibility: "open",
		Owners: []bindingOwner{{profileRefV2("alice", "pw"), v.TelPub}}}
	if err := beginTelStaging("10", false); err != nil {
		t.Fatal(err)
	}
	holdTelStagingUntilClaim("10")
	a := &arrivalReq{verb: "SEAL-TEL", it: testSMS}
	var reply string
	underTelMu(func() { reply, _ = sealBoundArrival(dest, b, a) })
	if !strings.HasPrefix(reply, "OK open ") || strings.Contains(reply, " LIVE ") {
		t.Fatalf("held bring-up: reply %q, want an OK line with no LIVE", reply)
	}
	var w bytes.Buffer
	underTelMu(func() { serveGetTelIngest(&w, 10*100000+5) })
	underTelMu(func() { reply, _ = sealBoundArrival(dest, b, a) })
	if !strings.HasSuffix(reply, " LIVE 10\n") {
		t.Fatalf("after the session's own claim: reply %q, want it to end ` LIVE 10`", reply)
	}
}
