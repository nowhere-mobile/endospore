package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// NWP-20260930-04: the v2 arrival wire, the replay table, bindings.conf integrity, and the SIM links in force when an
// arrival came in (telephony_arrival.go, bindings_check.go).

// useArrivalState gives a test an empty replay table, SIM-link history and class count, and a CLOCK_BOOTTIME it
// drives. telFixture calls it. The replay table persists beside the telephony inbox (NWP-20261021-08), so a test that
// still has the production inbox gets a temporary one here, and the per-run state of the table (its loaded flag, key
// and warning) starts clean and is put back at cleanup.
func useArrivalState(t *testing.T) *int64 {
	t.Helper()
	if telInboxBase == filepath.Join(stateDirDefault, telStateSubdir, "inbox") {
		useTempInbox(t)
	}
	oldR, oldO, oldH, oldZ, oldF, oldNow := telReplays, telReplayOrder, linkHistory, linkHorizon, linkFloor, bootNowMs
	oldKey, oldLoaded, oldKeyOn, oldNoDisk, oldDirty, oldLines, oldWarned :=
		telReplayKey, telReplayLoaded, telReplayKeyOn, telReplayNoDisk, telReplayDirty, telReplayLines, telReplayWarned
	telReplays, telReplayOrder, linkHistory, linkHorizon, linkFloor = map[[32]byte]*telReplay{}, nil, nil, map[string]int64{}, -1
	telReplayKey, telReplayLoaded, telReplayKeyOn, telReplayNoDisk, telReplayDirty, telReplayLines, telReplayWarned =
		nil, false, false, false, false, 0, false
	telClassMu.Lock()
	oldC := telClassCounts
	telClassCounts = map[string]int{}
	telClassMu.Unlock()
	clk := new(int64)
	*clk = 1_000_000
	bootNowMs = func() int64 { return *clk }
	t.Cleanup(func() {
		telReplays, telReplayOrder, linkHistory, linkHorizon, linkFloor, bootNowMs = oldR, oldO, oldH, oldZ, oldF, oldNow
		telReplayKey, telReplayLoaded, telReplayKeyOn, telReplayNoDisk, telReplayDirty, telReplayLines, telReplayWarned =
			oldKey, oldLoaded, oldKeyOn, oldNoDisk, oldDirty, oldLines, oldWarned
		telClassMu.Lock()
		telClassCounts = oldC
		telClassMu.Unlock()
	})
	return clk
}

func arrivalID(n int) string {
	h := sha256.Sum256([]byte(fmt.Sprint("arrival ", n)))
	return hex.EncodeToString(h[:])
}

func b64s(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

// iccidZ is a third SIM, beside unassign_records_test.go's X and Y.
const iccidZ = "89440000000000000033"

// late is an arrival stamp after every SIM-link change a test makes: a stamp ahead of the daemon's clock is read as
// "now" (arrivalLine).
const late = int64(1) << 40

// v2Tel is a v2 SEAL-TEL request.
func v2Tel(aid, kind string, sub int, iccid, from string, mono int64, body string) string {
	return "SEAL-TEL\nv2\n" + aid + "\n" + kind + "\n" + strconv.Itoa(sub) + "\n" + iccid + "\n" + b64s(from) +
		"\n1720000000000\n" + strconv.FormatInt(mono, 10) + "\n" + b64s(body) + "\n0\n0\n"
}

// v2Mms is a v2 SEAL-MMS request with one part per string.
func v2Mms(aid string, sub int, iccid string, mono int64, parts ...string) string {
	s := "SEAL-MMS\nv2\n" + aid + "\n" + strconv.Itoa(sub) + "\n" + iccid + "\n" + b64s("+15551234567") +
		"\n1720000000000\n" + strconv.FormatInt(mono, 10) + "\n-\n" + strconv.Itoa(len(parts)) + "\n"
	for _, p := range parts {
		s += b64s("text/plain") + "\n-\n" + b64s(p) + "\n"
	}
	return s
}

// bindFor binds iccid to ref with a real telephony key and returns that key's vault and DK, to open what was sealed.
func bindFor(t *testing.T, iccid, ref string) (*vault, []byte) {
	t.Helper()
	v, dk := vaultWithTelKey(t)
	if err := setBindingOwner(2, iccid, "L", "open", ref, v.TelPub); err != nil {
		t.Fatal(err)
	}
	return v, dk
}

// TestV2SealTelAndMmsSealWithTheirFields: a v2 request seals like v1, with its <from> base64 -- so a sender ID with a
// newline arrives whole -- and the same OK line.
func TestV2SealTelAndMmsSealWithTheirFields(t *testing.T) {
	telFixture(t)
	v, dk := bindFor(t, iccidX, "refA")
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1\nx", late, "hello")); got != "OK open "+b64s("L")+" 1" {
		t.Fatalf("v2 SEAL-TEL replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), v2Mms(arrivalID(2), 2, iccidX, late, "picture")); got != "OK open "+b64s("L")+" 1" {
		t.Fatalf("v2 SEAL-MMS replied %q", got)
	}
	items := readTelInboxItems(v, dk, "refA")
	if len(items) != 2 {
		t.Fatalf("sealed %d items, want 2: %+v", len(items), items)
	}
	for _, it := range items {
		switch it.Kind {
		case "sms":
			if it.From != "+1\nx" || it.Body != "hello" || it.SubID != 2 || it.When != 1720000000000 {
				t.Fatalf("the v2 text sealed as %+v", it)
			}
		case "mms":
			if len(it.Parts) != 1 || string(it.Parts[0].Data) != "picture" || it.From != "+15551234567" {
				t.Fatalf("the v2 MMS sealed as %+v", it)
			}
		default:
			t.Fatalf("sealed an item of kind %q", it.Kind)
		}
	}
}

// TestAnOldAgentRefusesV2WithNoSideEffect pins the claim the v2 wire rests on, against the v1 code this agent keeps:
// an agent from before v2 reads SEAL-TEL's "v2" as the kind and SEAL-MMS's <when_ms> as the part count, and refuses
// both, sealing nothing.
func TestAnOldAgentRefusesV2WithNoSideEffect(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	tel := strings.Split(strings.TrimPrefix(v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "hi"), "SEAL-TEL\n"), "\n")
	if got := driveSealTel(t, t.TempDir(), tel[:8]); got != "ERR bad kind\n" {
		t.Fatalf("the v1 SEAL-TEL handler given a v2 request replied %q", got)
	}
	mms := strings.Split(strings.TrimPrefix(v2Mms(arrivalID(2), 2, iccidX, late, "p"), "SEAL-MMS\n"), "\n")
	// The v1 header is six lines, and its sixth is the part count: in a v2 request that is <when_ms>.
	if _, err := readMmsParts(nil, mms[5]); err == nil || mms[5] != "1720000000000" {
		t.Fatalf("the v1 part count read from a v2 request (%q) was accepted: %v", mms[5], err)
	}
	if l := listSealed("refA"); l != nil {
		t.Fatalf("a v2 request refused by the v1 code sealed %v", l)
	}
}

// TestV2RefusesABadArrivalIDOrStamp: the arrival id is 64 lower-case hex characters and the stamp a non-negative
// integer; anything else is ERR request, with nothing sealed. A good request is the control.
func TestV2RefusesABadArrivalIDOrStamp(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	for what, req := range map[string]string{
		"a short id":       v2Tel(arrivalID(1)[:63], "sms", 2, iccidX, "+1", late, "x"),
		"an upper-case id": v2Tel(strings.ToUpper(arrivalID(1)), "sms", 2, iccidX, "+1", late, "x"),
		"a negative stamp": v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", -1, "x"),
		"a stamp not a number": strings.Replace(v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x"),
			"\n1720000000000\n"+strconv.FormatInt(late, 10)+"\n", "\n1720000000000\nsoon\n", 1),
		"an MMS with a short id": v2Mms(arrivalID(1)[:10], 2, iccidX, late, "p"),
	} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR request" {
			t.Fatalf("%s: replied %q, want ERR request", what, got)
		}
	}
	if l := listSealed("refA"); l != nil {
		t.Fatalf("a refused request sealed %v", l)
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the good request replied %q", got)
	}
}

// TestV2RepeatIsSealedOnce: the same arrival id twice gives one record and the same reply; another id is another
// record (the control).
func TestV2RepeatIsSealedOnce(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	first, second := driveLogin(t, t.TempDir(), req), driveLogin(t, t.TempDir(), req)
	if first != second || !strings.HasPrefix(first, "OK ") {
		t.Fatalf("replies %q then %q, want the same OK", first, second)
	}
	if l := listSealed("refA"); len(l) != 1 {
		t.Fatalf("a repeated arrival left %d records, want 1", len(l))
	}
	driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x"))
	if l := listSealed("refA"); len(l) != 2 {
		t.Fatalf("a second arrival left %d records in all, want 2", len(l))
	}
}

// TestV2ConcurrentRepeatIsSealedOnce: two attempts of one arrival at once still give one record.
func TestV2ConcurrentRepeatIsSealedOnce(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Mms(arrivalID(1), 2, iccidX, late, "p")
	var wg sync.WaitGroup
	replies := make([]string, 8)
	for i := range replies {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			replies[i] = driveLogin(t, t.TempDir(), req)
		}(i)
	}
	wg.Wait()
	for _, r := range replies {
		if r != replies[0] || !strings.HasPrefix(r, "OK ") {
			t.Fatalf("concurrent attempts replied %q", replies)
		}
	}
	if l := listSealed("refA"); len(l) != 1 {
		t.Fatalf("concurrent attempts left %d records, want 1", len(l))
	}
}

// TestV2ReplaysLive: a repeat of a live delivery is answered with the same LIVE reply and appends nothing more.
func TestV2ReplaysLive(t *testing.T) {
	telFixture(t)
	dest := t.TempDir()
	liveFixture(t, dest, iccidX)
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	first := driveLogin(t, dest, req)
	if f := strings.Fields(first); len(f) != 6 || f[4] != "LIVE" || f[5] != "11" {
		t.Fatalf("the live arrival replied %q", first)
	}
	if again := driveLogin(t, dest, req); again != first {
		t.Fatalf("the repeat replied %q, want %q", again, first)
	}
	b, err := os.ReadFile(telIngestPath("11", simTag(iccidX)))
	if err != nil || strings.Count(string(b), "\n") != 1 {
		t.Fatalf("mailbox = %q, %v; want the one row", b, err)
	}
}

// TestV2NobodyIsAnErrAndIsNotKept: a bound SIM whose only owner's seal fails answers ERR nobody with its dial -- v1
// answers OK ... 0, which the chooser read as delivered -- and the ERR is not replayed: once the owner's key is
// fixed, the same arrival id seals.
func TestV2NobodyIsAnErrAndIsNotKept(t *testing.T) {
	telFixture(t)
	if err := setBindingOwner(2, iccidX, "L", "private", "refA", "not-a-key"); err != nil {
		t.Fatal(err)
	}
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	if got := driveLogin(t, t.TempDir(), req); got != "ERR nobody private" {
		t.Fatalf("a seal to nobody replied %q, want ERR nobody private", got)
	}
	if got := driveSealTel(t, t.TempDir(), []string{"sms", "2", iccidX, "+1", "1", b64s("x"), "0", "0"}); got != "OK private "+b64s("L")+" 0\n" {
		t.Fatalf("v1 replied %q, want today's OK ... 0", got)
	}
	bindFor(t, iccidX, "refA") // the same owner, now with a key that seals (and the dial open)
	if got := driveLogin(t, t.TempDir(), req); got != "OK open "+b64s("L")+" 1" {
		t.Fatalf("after the fix the same arrival replied %q, want it sealed", got)
	}
}

// TestV2PartialIsOKAndItsLogNamesNoOwnerCount: one owner's seal failing on a two-owner line still answers OK (with
// PARTIAL, so the gate can tell the other owner lost the record), and
// logs the same class line a one-owner line's total failure does, with no number in it -- a class that could only
// occur on a co-owned line would say that such a line exists.
func TestV2PartialIsOKAndItsLogNamesNoOwnerCount(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	if err := setBindingOwner(2, iccidX, "L", "open", "refB", "not-a-key"); err != nil {
		t.Fatal(err)
	}
	var reply string
	partial := captureStderr(t, func() { reply = driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")) })
	if reply != "OK open "+b64s("L")+" 1 PARTIAL" {
		t.Fatalf("a partial success replied %q", reply)
	}
	useArrivalState(t) // a fresh run's class count, so the next failure logs again
	if err := setBindingOwner(2, iccidY, "M", "open", "refC", "not-a-key"); err != nil {
		t.Fatal(err)
	}
	total := captureStderr(t, func() { driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidY, "+1", late, "x")) })
	if partial == "" || partial != total {
		t.Fatalf("a partial failure logged %q and a total one %q: they must be one class", partial, total)
	}
	if regexp.MustCompile(`[0-9]`).MatchString(strings.TrimPrefix(partial, "[logind] telephony: ")) {
		t.Fatalf("the class line carries a number: %q", partial)
	}
}

// TestV2PartialWordOnlyWhenSomeOwnersMissed: PARTIAL rides the OK only when the arrival was kept for some but not
// every owner of a two-owner SIM; kept for none is ERR nobody, and a live owner counts as kept.
func TestV2PartialWordOnlyWhenSomeOwnersMissed(t *testing.T) {
	bad := func(ref, label string) {
		t.Helper()
		if err := setBindingOwner(2, iccidX, label, "open", ref, "not-a-key"); err != nil {
			t.Fatal(err)
		}
	}
	L := b64s("L")
	for _, c := range []struct {
		name  string
		setup func(dest string)
		want  []string
	}{
		{"both keys good", func(string) { bindFor(t, iccidX, "refA"); bindFor(t, iccidX, "refB") },
			[]string{"OK", "open", L, "2"}},
		{"one key bad", func(string) { bindFor(t, iccidX, "refA"); bad("refB", "L") },
			[]string{"OK", "open", L, "1", "PARTIAL"}},
		{"both keys bad", func(string) { bad("refA", "L"); bad("refB", "L") },
			[]string{"ERR", "nobody", "open"}},
		{"one live, other key bad", func(dest string) { liveFixture(t, dest, iccidX); bad("refB", "RedPocket") },
			[]string{"OK", "open", b64s("RedPocket"), "0", "PARTIAL", "LIVE", "11"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			telFixture(t)
			dest := t.TempDir()
			c.setup(dest)
			got := strings.Fields(driveLogin(t, dest, v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")))
			if strings.Join(got, " ") != strings.Join(c.want, " ") {
				t.Fatalf("replied %q, want %q", got, c.want)
			}
		})
	}
}

// TestV2UnboundUnresolvedAndSubIDFallback: an ICCID with no binding is unbound (NONE); an arrival with no ICCID is
// matched by its sub_id, and is UNRESOLVED when that matches nothing or is below 0. Nothing is kept for either.
func TestV2UnboundUnresolvedAndSubIDFallback(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA") // sub_id 2
	vM, _ := vaultWithTelKey(t)
	if err := setBindingOwner(-1, iccidY, "M", "open", "refB", vM.TelPub); err != nil { // a SIM bound by hand: sub_id -1
		t.Fatal(err)
	}
	for i, c := range []struct {
		sub   int
		iccid string
		want  string
	}{{2, iccidZ, "NONE"}, {7, "", "UNRESOLVED"}, {-1, "", "UNRESOLVED"}} {
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(i), "call", c.sub, c.iccid, "+1", late, "")); got != c.want {
			t.Fatalf("sub %d, iccid %q: replied %q, want %s", c.sub, c.iccid, got, c.want)
		}
	}
	if a, b := listSealed("refA"), listSealed("refB"); a != nil || b != nil {
		t.Fatalf("an unbound or unresolved arrival was sealed: %v %v", a, b)
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(9), "call", 2, "", "+1", late, "")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("no ICCID but a matching sub_id replied %q, want OK", got)
	}
}

// TestV2FollowsTheSIMLinksWhenItArrived: an arrival is sealed only to the owners it had when it came in and has kept
// ever since. A v1 request uses the links in force now (the control).
func TestV2FollowsTheSIMLinksWhenItArrived(t *testing.T) {
	type step func(t *testing.T)
	bindB := func(t *testing.T) { bindFor(t, iccidX, "refB") }
	dropB := func(t *testing.T) {
		if _, err := removeBindingOwner(iccidX, "refB"); err != nil {
			t.Fatal(err)
		}
	}
	unassign := func(t *testing.T) {
		if _, err := removeBindingOwner(iccidX, ""); err != nil {
			t.Fatal(err)
		}
	}
	bindA := func(t *testing.T) { bindFor(t, iccidX, "refA") }
	for _, c := range []struct {
		name         string
		before       []step // SIM links when the arrival came in
		after        []step // changed after it arrived, before it was processed
		want         string // reply prefix
		sealA, sealB int
	}{
		{"unassigned since", []step{bindA}, []step{unassign}, "REMOVED", 0, 0},
		{"a co-owner added since", []step{bindA}, []step{bindB}, "OK ", 1, 0},
		{"a co-owner removed since", []step{bindA, bindB}, []step{dropB}, "OK ", 1, 0},
		{"bound only since", nil, []step{bindA}, "NONE", 0, 0},
		{"unassigned and bound again since", []step{bindA}, []step{unassign, bindA}, "REMOVED", 0, 0},
		{"unchanged", []step{bindA, bindB}, nil, "OK ", 1, 1},
	} {
		t.Run(c.name, func(t *testing.T) {
			telFixture(t)
			clk := useArrivalState(t)
			for _, s := range c.before {
				s(t)
			}
			*clk += 1000
			stamp := *clk
			for _, s := range c.after {
				*clk += 1000
				s(t)
			}
			*clk += 1000
			got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", stamp, "x"))
			if !strings.HasPrefix(got, c.want) {
				t.Fatalf("replied %q, want %s", got, c.want)
			}
			if a, b := len(listSealed("refA")), len(listSealed("refB")); a != c.sealA || b != c.sealB {
				t.Fatalf("sealed A %d, B %d; want %d, %d", a, b, c.sealA, c.sealB)
			}
		})
	}
	t.Run("v1 uses the links in force now", func(t *testing.T) {
		telFixture(t)
		clk := useArrivalState(t)
		bindA(t)
		*clk += 1000
		bindB(t)
		if got := driveSealTel(t, t.TempDir(), []string{"sms", "2", iccidX, "+1", "1", b64s("x"), "0", "0"}); !strings.HasSuffix(got, " 2\n") {
			t.Fatalf("v1 replied %q, want it sealed to both owners now", got)
		}
	})
}

// TestV2BeforeTheHorizonIsUnresolved: once a change to a SIM is pruned from the history, an arrival stamped before
// it cannot be resolved; one stamped after it can.
func TestV2BeforeTheHorizonIsUnresolved(t *testing.T) {
	telFixture(t)
	clk := useArrivalState(t)
	bindFor(t, iccidX, "refA")
	old := *clk - 1
	*clk += linkHistoryKeep.Milliseconds() + 1000
	bindFor(t, iccidY, "refA") // any later write prunes the first change
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", old, "x")); got != "UNRESOLVED" {
		t.Fatalf("an arrival before the horizon replied %q, want UNRESOLVED", got)
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", *clk, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("an arrival after the horizon replied %q, want OK", got)
	}
}

// TestV2ReplayAfterAnUnassignIsRemoved: once a SIM loses its last owner, a repeat of an arrival it kept is answered
// REMOVED -- the unassign deleted the record, so the reply must not announce it again.
func TestV2ReplayAfterAnUnassignIsRemoved(t *testing.T) {
	telFixture(t)
	asGate(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	if got := driveLogin(t, t.TempDir(), req); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); !strings.HasPrefix(got, "OK") {
		t.Fatalf("the unassign replied %q", got)
	}
	if got := driveLogin(t, t.TempDir(), req); got != "REMOVED" {
		t.Fatalf("the repeat after the unassign replied %q, want REMOVED", got)
	}
}

// damagedXLines is every way a line of bindings.conf can fail to read back, each on SIM X (iccidX). All but the last
// are written with their newline; the last is cut short, so it goes last in the file with none.
func damagedXLines() map[string]string {
	good := "2|" + iccidX + "|" + b64s("L") + "|open|refA:pubA"
	return map[string]string{
		"four fields":             "2|" + iccidX + "|" + b64s("L") + "|open",
		"a sixth field":           good + "|x",
		"a sub_id not a number":   "x|" + iccidX + "|" + b64s("L") + "|open|refA:pubA",
		"a sub_id not as written": "+2|" + iccidX + "|" + b64s("L") + "|open|refA:pubA",
		"a label not base64":      "2|" + iccidX + "|L!|open|refA:pubA",
		"an unknown dial":         "2|" + iccidX + "|" + b64s("L") + "|public|refA:pubA",
		"no owner":                "2|" + iccidX + "|" + b64s("L") + "|open|",
		"a bad co-owner":          good + ",refB",
		"a CR":                    good + "\r",
		"a commented-out line":    "# " + good,
		"cut short":               good,
	}
}

// TestADamagedLineIsNeverUnbound: a line that does not read back leaves its SIM unknown -- a v2 arrival on it is
// UNRESOLVED (v1: NONE, as before) -- while every line that does read back answers as before, for v1 and v2, TEL-OWNER
// and GET-BINDINGS, which ends with DAMAGED. A write elsewhere carries the damaged line forward, marked so that it can
// never read back (the cut-short line is the one that would), and "Unbind all" of its ICCID removes it.
func TestADamagedLineIsNeverUnbound(t *testing.T) {
	asGate(t)
	carol := profileRefV2("carol", "pw-carol")
	for what, xLine := range damagedXLines() {
		t.Run(what, func(t *testing.T) {
			telFixture(t)
			vC, _ := vaultWithTelKey(t)
			yLine := "3|" + iccidY + "|" + b64s("M") + "|open|" + carol + ":" + vC.TelPub
			body := "v1\n" + yLine + "\n" + xLine + "\n"
			if what == "cut short" {
				body = strings.TrimSuffix(body, "\n")
			}
			if err := os.WriteFile(bindingsPath, []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
				t.Fatalf("v2 on the damaged line replied %q, want UNRESOLVED", got)
			}
			if got := driveSealTel(t, t.TempDir(), []string{"sms", "2", iccidX, "+1", "1", b64s("x"), "0", "0"}); got != "NONE\n" {
				t.Fatalf("v1 on the damaged line replied %q, want NONE", got)
			}
			if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 3, iccidY, "+1", late, "x")); got != "OK open "+b64s("M")+" 1" {
				t.Fatalf("v2 on the good line replied %q", got)
			}
			if got := driveSealTel(t, t.TempDir(), []string{"sms", "3", iccidY, "+1", "1", b64s("x"), "0", "0"}); got != "OK open "+b64s("M")+" 1\n" {
				t.Fatalf("v1 on the good line replied %q", got)
			}
			if got := driveLogin(t, t.TempDir(), "TEL-OWNER\ncarol\npw-carol\n"); got != "YES" {
				t.Fatalf("TEL-OWNER for the good line's owner replied %q, want YES", got)
			}
			if got := driveLogin(t, t.TempDir(), "TEL-OWNER\nstranger\npw\n"); got != "NO" {
				t.Fatalf("TEL-OWNER for a stranger replied %q, want NO", got)
			}
			if got := driveLogin(t, t.TempDir(), "TEL-OWNED-ICCIDS\ncarol\npw-carol\n"); got != "OK\n"+iccidY {
				t.Fatalf("TEL-OWNED-ICCIDS replied %q", got)
			}
			if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); !strings.HasPrefix(got, "OK\n3|"+iccidY+"|"+b64s("M")+"|open|1") || !strings.HasSuffix(got, "\nDAMAGED") {
				t.Fatalf("GET-BINDINGS replied %q, want the good line and DAMAGED", got)
			}
			if got := driveLogin(t, t.TempDir(), "SET-BINDING\n4\n"+iccidZ+"\n"+b64s("N")+"\nopen\nrefZ\npubZ\n"); got != "OK" {
				t.Fatalf("SET-BINDING elsewhere replied %q, want OK", got)
			}
			if b, _ := os.ReadFile(bindingsPath); !strings.Contains(string(b), "\n#") {
				t.Fatalf("the damaged line was not carried forward marked:\n%s", b)
			}
			if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(3), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
				t.Fatalf("after a write elsewhere the damaged line's SIM replied %q, want UNRESOLVED", got)
			}
			if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); got != "OK" {
				t.Fatalf("Unbind all of the damaged line's ICCID replied %q, want OK", got)
			}
			if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(4), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
				t.Fatalf("after the repair the file is rebuilt and the SIM replied %q, want UNRESOLVED", got)
			}
			if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); strings.Contains(got, "DAMAGED") {
				t.Fatalf("after the repair GET-BINDINGS still says %q", got)
			}
		})
	}
}

// TestAFlawedFileWithNoDamagedLine: an empty file, or one with no header, is flawed: a SIM on no good line is
// UNRESOLVED, not unbound, and GET-BINDINGS says DAMAGED. A good line in it still answers. The next binding write
// writes a REBUILT file (NWP-20261110-01), and from then on a SIM on no line stays UNRESOLVED until it is bound or
// marked mine.
func TestAFlawedFileWithNoDamagedLine(t *testing.T) {
	asGate(t)
	t.Run("empty", func(t *testing.T) {
		telFixture(t)
		if err := os.WriteFile(bindingsPath, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
			t.Fatalf("an empty file answered %q, want UNRESOLVED", got)
		}
		if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != "OK\nDAMAGED" {
			t.Fatalf("GET-BINDINGS on an empty file replied %q", got)
		}
		if got := driveLogin(t, t.TempDir(), "TEL-OWNER\ncarol\npw-carol\n"); got != "NO" {
			t.Fatalf("TEL-OWNER on an empty file replied %q, want NO", got)
		}
		bindFor(t, iccidY, "refC")
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
			t.Fatalf("after a rebuilt write the SIM replied %q, want UNRESOLVED", got)
		}
	})
	t.Run("header only, cut short", func(t *testing.T) {
		telFixture(t)
		if err := os.WriteFile(bindingsPath, []byte("v1"), 0o600); err != nil { // the header with no newline: cut short
			t.Fatal(err)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
			t.Fatalf("a cut-short header answered %q, want UNRESOLVED", got)
		}
		if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != "OK\nDAMAGED" {
			t.Fatalf("GET-BINDINGS on a cut-short header replied %q", got)
		}
	})
	t.Run("no header", func(t *testing.T) {
		telFixture(t)
		bindFor(t, iccidX, "refA")
		b, _ := os.ReadFile(bindingsPath)
		if err := os.WriteFile(bindingsPath, []byte(strings.TrimPrefix(string(b), "v1\n")), 0o600); err != nil {
			t.Fatal(err)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
			t.Fatalf("a good line in a headerless file replied %q, want OK", got)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidY, "+1", late, "x")); got != "UNRESOLVED" {
			t.Fatalf("a SIM on no line of a headerless file replied %q, want UNRESOLVED", got)
		}
		bindFor(t, iccidZ, "refC")
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(3), "sms", 2, iccidY, "+1", late, "x")); got != "UNRESOLVED" {
			t.Fatalf("after a rebuilt write the SIM replied %q, want UNRESOLVED", got)
		}
	})
}

// TestAnUnreadableFileIsRefused: a bindings.conf that exists and cannot be read is the one case the writers refuse,
// and GET-BINDINGS and DELETE-BINDING say ERR damaged; arrivals are UNRESOLVED (v1 NONE) and TEL-OWNER NO.
func TestAnUnreadableFileIsRefused(t *testing.T) {
	asGate(t)
	telFixture(t)
	if err := os.Mkdir(bindingsPath, 0o700); err != nil {
		t.Fatal(err)
	}
	for req, want := range map[string]string{
		"GET-BINDINGS\n": "ERR damaged",
		"SET-BINDING\n2\n" + iccidY + "\n" + b64s("L") + "\nopen\nrefC\npubC\n": "ERR damaged",
		"DELETE-BINDING\n" + iccidX + "\n\n":                                    "ERR damaged",
		"TEL-OWNER\ncarol\npw-carol\n":                                          "NO",
		v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x"):                  "UNRESOLVED",
	} {
		if got := driveLogin(t, t.TempDir(), req); got != want {
			t.Fatalf("%q replied %q, want %q", strings.SplitN(req, "\n", 2)[0], got, want)
		}
	}
	if _, err := removeBindingOwnerEverywhere("refA"); err != errBindingsDamaged {
		t.Fatalf("the delete purge returned %v", err)
	}
}

// TestAFieldThatWouldNotReadBackIsRefused: SET-BINDING refuses a record that would not read back as written -- an ICCID
// holding '|', as owner mode's free-text ICCID field allows -- and leaves the file byte-identical, so no write of ours
// can damage it. The good line still answers.
func TestAFieldThatWouldNotReadBackIsRefused(t *testing.T) {
	asGate(t)
	telFixture(t)
	bindFor(t, iccidY, "refC")
	before, _ := os.ReadFile(bindingsPath)
	v, _ := vaultWithTelKey(t)
	if got := driveLogin(t, t.TempDir(), "SET-BINDING\n3\n8944|0001\n"+b64s("M")+"\nopen\nrefB\n"+v.TelPub+"\n"); got != "ERR unstorable" {
		t.Fatalf("an ICCID holding '|' replied %q, want ERR unstorable", got)
	}
	if after, _ := os.ReadFile(bindingsPath); string(after) != string(before) {
		t.Fatalf("the refused write changed the file:\n%s", after)
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidY, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the good line replied %q after the refusal", got)
	}
}

// TestALabelHoldingAPipeRoundTripsBase64 (NWP-20261011-19): the label is base64 on both owner-mode verbs, as in
// bindings.conf. setBindingOwner's read-back check sees the label base64, so it stores a "Work|Home"; GET-BINDINGS
// then wrote it raw and the line split into the wrong fields while still passing the chooser's 5-field check, and a
// raw newline in SET-BINDING shifted every later request field.
func TestALabelHoldingAPipeRoundTripsBase64(t *testing.T) {
	asGate(t)
	for _, label := range []string{"Work|Home", "Work\nHome"} {
		t.Run(strconv.Quote(label), func(t *testing.T) {
			telFixture(t)
			v, _ := vaultWithTelKey(t)
			if got := driveLogin(t, t.TempDir(), "SET-BINDING\n3\n"+iccidY+"\n"+b64s(label)+"\nnotify\nrefB\n"+v.TelPub+"\n"); got != "OK" {
				t.Fatalf("SET-BINDING with the label %q replied %q, want OK", label, got)
			}
			got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n")
			lines := strings.Split(got, "\n")
			if len(lines) != 2 || lines[0] != "OK" {
				t.Fatalf("GET-BINDINGS replied %q, want OK and one SIM line", got)
			}
			f := strings.Split(lines[1], "|")
			if len(f) != 5 {
				t.Fatalf("the SIM line %q has %d fields, want 5", lines[1], len(f))
			}
			if dec, err := base64.StdEncoding.DecodeString(f[2]); err != nil || string(dec) != label {
				t.Fatalf("field 3 %q decodes to %q (%v), want %q", f[2], dec, err, label)
			}
			if f[0] != "3" || f[1] != iccidY || f[3] != "notify" || f[4] != "1" {
				t.Fatalf("the SIM line %q lost its other fields", lines[1])
			}
		})
	}
}

// TestANonBase64LabelIsRefusedUnwritten (NWP-20261011-19): a SET-BINDING label that does not decode answers ERR
// unstorable -- the reply the chooser maps to BINDING_UNSTORABLE; it always encodes, so this is a malformed request --
// and leaves bindings.conf byte-identical.
func TestANonBase64LabelIsRefusedUnwritten(t *testing.T) {
	asGate(t)
	telFixture(t)
	bindFor(t, iccidY, "refC")
	before, _ := os.ReadFile(bindingsPath)
	v, _ := vaultWithTelKey(t)
	if got := driveLogin(t, t.TempDir(), "SET-BINDING\n3\n"+iccidZ+"\nnot*base64\nopen\nrefB\n"+v.TelPub+"\n"); got != "ERR unstorable" {
		t.Fatalf("a label that is not base64 replied %q, want ERR unstorable", got)
	}
	if after, _ := os.ReadFile(bindingsPath); string(after) != string(before) {
		t.Fatalf("the refused write changed the file:\n%s", after)
	}
	if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != "OK\n2|"+iccidY+"|"+b64s("L")+"|open|1" {
		t.Fatalf("GET-BINDINGS after the refusal replied %q", got)
	}
}

// TestADeleteRedactsEveryDamagedLineIdentity: a profile delete reduces every damaged line to its sub_id and ICCID, so
// no profile's ref survives -- the deleted one, a co-owner's on the same line (dropping the line whole would take the
// co-owner's SIM with it, NWP-20260930-04's finding), or a hex prefix of a ref left by a cut-short line that
// Contains(ref+":") would miss (NWP-20260903-21). The SIMs the markers name stay DAMAGED: their arrivals are
// UNRESOLVED, not unbound, and "Unbind all" still repairs them.
func TestADeleteRedactsEveryDamagedLineIdentity(t *testing.T) {
	telFixture(t)
	// A good line (refC on Y); a co-owned damaged line for X (refA and refB, "L!" is not base64); and a last line
	// cut short inside a ref that begins with the deleted "refA" (no ":" after it, so Contains("refA:") misses it).
	body := "v1\n3|" + iccidY + "|" + b64s("M") + "|open|refC:pubC\n" +
		"2|" + iccidX + "|L!|open|refA:pubA,refB:pubB\n" +
		"4|" + iccidZ + "|" + b64s("N") + "|open|refAlong"
	if err := os.WriteFile(bindingsPath, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if n, err := removeBindingOwnerEverywhere("refA"); n != 2 || err != nil {
		t.Fatalf("the purge = %d, %v; want both damaged lines redacted", n, err)
	}
	s, _ := os.ReadFile(bindingsPath)
	for _, leak := range []string{"refA", "refB", "pubA", "pubB"} { // "refA" covers the deleted ref and its prefix
		if strings.Contains(string(s), leak) {
			t.Fatalf("the purge left %q in the file:\n%s", leak, s)
		}
	}
	if !strings.Contains(string(s), "refC:pubC") {
		t.Fatalf("the purge dropped the good line:\n%s", s)
	}
	if !strings.Contains(string(s), "#2|"+iccidX+"|") || !strings.Contains(string(s), "#4|"+iccidZ+"|") {
		t.Fatalf("a damaged line lost its ICCID marker:\n%s", s)
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" {
		t.Fatalf("after the purge the co-owned SIM replied %q, want UNRESOLVED", got)
	}
	if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); !strings.Contains(got, "DAMAGED") {
		t.Fatalf("after the purge GET-BINDINGS replied %q, want DAMAGED", got)
	}
	if got := driveLogin(t, t.TempDir(), "DELETE-BINDING\n"+iccidX+"\n\n"); got != "OK" {
		t.Fatalf("Unbind all of the co-owned SIM's ICCID replied %q, want OK", got)
	}
}

// TestABindOrRepairOfADamagedSIMLeavesEarlierArrivalsUnresolved: a SIM whose only line is damaged has unknown owners.
// An arrival stamped before the owner binds it again, or before "Unbind all" repairs it, must be UNRESOLVED -- the
// history's empty "before" for a newly-bound SIM must not read as "was unbound" (NWP-20260930-04's finding).
func TestABindOrRepairOfADamagedSIMLeavesEarlierArrivalsUnresolved(t *testing.T) {
	damagedOnly := "v1\n2|" + iccidX + "|L!|open|refA:pubA\n"
	t.Run("bind", func(t *testing.T) {
		telFixture(t)
		clk := useArrivalState(t)
		if err := os.WriteFile(bindingsPath, []byte(damagedOnly), 0o600); err != nil {
			t.Fatal(err)
		}
		stamp := *clk // the arrival came in while the SIM was damaged
		*clk += 1000
		bindFor(t, iccidX, "refC") // the owner binds X again, later
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", stamp, "x")); got != "UNRESOLVED" {
			t.Fatalf("an arrival from before the re-bind replied %q, want UNRESOLVED", got)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
			t.Fatalf("an arrival after the re-bind replied %q, want OK", got)
		}
	})
	t.Run("repair", func(t *testing.T) {
		telFixture(t)
		clk := useArrivalState(t)
		if err := os.WriteFile(bindingsPath, []byte(damagedOnly), 0o600); err != nil {
			t.Fatal(err)
		}
		stamp := *clk
		*clk += 1000
		if _, err := removeBindingOwner(iccidX, ""); err != nil { // "Unbind all" repairs the damaged line
			t.Fatal(err)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", stamp, "x")); got != "UNRESOLVED" {
			t.Fatalf("an arrival from before the repair replied %q, want UNRESOLVED", got)
		}
		if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x")); got != "UNRESOLVED" { // rebuilt (NWP-20261110-01): the repaired SIM stays unresolved until it is bound or marked mine
			t.Fatalf("an arrival after the repair replied %q, want UNRESOLVED", got)
		}
	})
}

// TestADamagedFileKeepsARestagedRow: a re-staged row whose SIM link cannot be read is put back, not dropped as if its
// SIM had been unassigned. The control is a clean file without that SIM, which drops it.
func TestADamagedFileKeepsARestagedRow(t *testing.T) {
	useTempIngest(t)
	useTempBindings(t)
	useArrivalState(t)
	row := "call 5 3 0 KzE -" + simTag(iccidX) + " 1"
	if err := os.WriteFile(bindingsPath, []byte("v1\n2|"+iccidX+"|L!|open|refA:pubA\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if dropped, err := restageTelIngest("12", row); dropped || err != nil {
		t.Fatalf("with a damaged file the row was dropped=%v, %v", dropped, err)
	}
	if err := os.WriteFile(bindingsPath, []byte("v1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if dropped, err := restageTelIngest("12", row); !dropped || err != nil {
		t.Fatalf("with a clean file and no such SIM the row was dropped=%v, %v; want dropped", dropped, err)
	}
}

// TestALinkChangeIsRecordedOnlyWhenItsWriteLands: a writer that fails leaves no history entry, so an arrival is never
// resolved against a change that did not happen.
func TestALinkChangeIsRecordedOnlyWhenItsWriteLands(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	first := driveLogin(t, t.TempDir(), req)
	n := len(linkHistory)
	dir := filepath.Dir(bindingsPath)
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	for what, write := range map[string]func() error{
		"setBindingOwner":              func() error { return setBindingOwner(2, iccidX, "L", "open", "refB", "pubB") },
		"removeBindingOwner":           func() error { _, err := removeBindingOwner(iccidX, ""); return err },
		"removeBindingOwnerEverywhere": func() error { _, err := removeBindingOwnerEverywhere("refA"); return err },
	} {
		if err := write(); err == nil {
			t.Skipf("%s: the directory is still writable (root?): cannot make the write fail", what)
		}
		if len(linkHistory) != n {
			t.Fatalf("a failed %s recorded a change: %d entries, want %d", what, len(linkHistory), n)
		}
		if got := driveLogin(t, t.TempDir(), req); got != first {
			t.Fatalf("after a failed %s the repeat replied %q, want %q", what, got, first)
		}
	}
}

// TestWriteBindingsSyncs pins the synced publish: the temp file is synced before the rename, and the directory after.
func TestWriteBindingsSyncs(t *testing.T) {
	b, err := os.ReadFile("bindings.go")
	if err != nil {
		t.Fatal(err)
	}
	body := strings.Join(stripComments(funcBody(t, string(b), "writeBindingsMarked")), "\n")
	s, r, d := strings.Index(body, "fh.Sync()"), strings.Index(body, "os.Rename(tmp, bindingsPath)"), strings.Index(body, "d.Sync()")
	if s < 0 || r < 0 || d < 0 || !(s < r && r < d) {
		t.Fatalf("writeBindingsMarked must sync the temp file, rename it, then sync the directory (at %d, %d, %d)", s, r, d)
	}
}

// TestSealMmsAnswersOnlyTheGate: SEAL-MMS from anyone but the user-0 gate is ERR caller and seals nothing, for v1 and
// v2. The gate is the control.
func TestSealMmsAnswersOnlyTheGate(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	v1 := "SEAL-MMS\n2\n" + iccidX + "\n-\n1\n-\n1\n-\n-\n" + b64s("p") + "\n"
	asCaller(t, 1010123, 10123) // the chooser in a roamed user
	for what, req := range map[string]string{"v1": v1, "v2": v2Mms(arrivalID(1), 2, iccidX, late, "p")} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR caller" {
			t.Fatalf("%s from a roamed session replied %q, want ERR caller", what, got)
		}
	}
	if l := listSealed("refA"); l != nil {
		t.Fatalf("a refused caller sealed %v", l)
	}
	asGate(t)
	if got := driveLogin(t, t.TempDir(), v1); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("v1 from the gate replied %q", got)
	}
}

// TestSealTelAnswersOnlyTheGate: SEAL-TEL from anyone but the user-0 gate is ERR caller and seals nothing, for v1 and
// v2 -- since NWP-20260930-05 the chooser hands a call declined in a stranger's session to user 0 to seal
// (RejectedCallSealReceiver), so no chooser sends it from a roamed user. The controls: the gate is answered, and
// GET-TELINGEST, which a roamed session's chooser sends for its own records, is not refused.
func TestSealTelAnswersOnlyTheGate(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	v1 := telRequests()["SEAL-TEL"]
	asCaller(t, 1010123, 10123) // the chooser in a roamed user
	for what, req := range map[string]string{"v1": v1, "v2": v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")} {
		if got := driveLogin(t, t.TempDir(), req); got != "ERR caller" {
			t.Fatalf("%s from a roamed session replied %q, want ERR caller", what, got)
		}
	}
	if l := listSealed("refA"); l != nil {
		t.Fatalf("a refused caller sealed %v", l)
	}
	if got := driveLogin(t, t.TempDir(), "GET-TELINGEST\n"); got == "ERR caller" {
		t.Fatal("GET-TELINGEST from a roamed session was refused: a session could not take its own records")
	}
	asGate(t)
	if got := driveLogin(t, t.TempDir(), v1); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("v1 from the gate replied %q", got)
	}
}

// TestTelClassIsLoggedOncePerRun: three unresolved arrivals log one line, the first; none of them logs the number, the
// arrival id or the body. (They carry no ICCID; TestADamagedLineLogsNoICCID covers one that does.)
func TestTelClassIsLoggedOncePerRun(t *testing.T) {
	telFixture(t)
	var lines []string
	for i := 0; i < 3; i++ {
		out := captureStderr(t, func() {
			driveLogin(t, t.TempDir(), v2Tel(arrivalID(i), "sms", 7, "", "+15559876543", late, "secret body"))
		})
		lines = append(lines, out)
	}
	if !strings.Contains(lines[0], telClassUnresolved) {
		t.Fatalf("the first unresolved arrival logged %q", lines[0])
	}
	if lines[1] != "" || lines[2] != "" {
		t.Fatalf("later ones logged %q and %q, want nothing", lines[1], lines[2])
	}
	for _, leak := range []string{"5559876543", "secret", arrivalID(0), arrivalID(0)[:16]} {
		if strings.Contains(lines[0], leak) {
			t.Fatalf("the class line carries %q: %q", leak, lines[0])
		}
	}
	telClassMu.Lock()
	n := telClassCounts[telClassUnresolved]
	telClassMu.Unlock()
	if n != 3 {
		t.Fatalf("counted %d unresolved arrivals, want 3", n)
	}
}

// TestTelClassesGoOnlyIntoAGateReport: the classes seen ride a gate report's status, never an in-session one's, and
// with no count: how many arrivals reached a line is message metadata, shown at the gate to whoever opens the report.
func TestTelClassesGoOnlyIntoAGateReport(t *testing.T) {
	useArrivalState(t)
	for i := 0; i < 3; i++ {
		telClassNote(telClassRemoved)
	}
	if got := buildIssueReport("", true, "", nil, nil).Status["telephony_classes"]; got != telClassRemoved || regexp.MustCompile(`[0-9]`).MatchString(got) {
		t.Fatalf("the gate report's telephony_classes = %q, want the class alone", got)
	}
	if got, ok := buildIssueReport("alice", false, "", nil, nil).Status["telephony_classes"]; ok {
		t.Fatalf("an in-session report carries telephony_classes = %q", got)
	}
}

// TestReplayTableForgetsAfterItsWindow: an entry older than telReplayTTL is gone, so the table cannot grow for a day.
func TestReplayTableForgetsAfterItsWindow(t *testing.T) {
	clk := useArrivalState(t)
	id := telReplayID("SEAL-TEL", arrivalID(1))
	telReplayPut(id, "NONE\n", "")
	if _, ok := telReplayGet(id); !ok {
		t.Fatal("a fresh entry is missing")
	}
	*clk += telReplayTTL.Milliseconds() + 60_000
	if _, ok := telReplayGet(id); ok {
		t.Fatal("an expired entry was replayed")
	}
}

// TestV2SealsToEveryLineOfASIM: a SIM written under two spellings (a legacy duplicate, padded and unpadded) is one SIM:
// an arrival is sealed to the owners of both lines it had when it came in and has kept since.
func TestV2SealsToEveryLineOfASIM(t *testing.T) {
	telFixture(t)
	clk := useArrivalState(t)
	vA, _ := vaultWithTelKey(t)
	vB, _ := vaultWithTelKey(t)
	vC, _ := vaultWithTelKey(t)
	if err := writeBindings([]simBinding{
		{SubID: 2, ICCID: iccidX, Label: "L", Visibility: "open", Owners: []bindingOwner{{"refA", vA.TelPub}}},
		{SubID: 3, ICCID: iccidX + "F", Label: "L", Visibility: "open", Owners: []bindingOwner{{"refB", vB.TelPub}}},
	}, nil); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	stamp := *clk
	*clk += 1000
	if err := setBindingOwner(2, iccidX, "L", "open", "refC", vC.TelPub); err != nil { // C joins the first line
		t.Fatal(err)
	}
	*clk += 1000
	if _, err := removeBindingOwner(iccidX, "refA"); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", stamp, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("replied %q, want OK: B was an owner when it arrived and has stayed one", got)
	}
	if a, b, c := len(listSealed("refA")), len(listSealed("refB")), len(listSealed("refC")); a != 0 || b != 1 || c != 0 {
		t.Fatalf("sealed A %d, B %d, C %d; want only B", a, b, c)
	}
}

// TestV2AfterADaemonRestartIsUnresolved: the history dies with the daemon, but the time of the newest link change is
// kept in the state tmpfs, so a restarted daemon answers UNRESOLVED for an arrival stamped before it -- instead of
// sealing it to the profile bound since an unassign, which is another profile's message in its inbox.
func TestV2AfterADaemonRestartIsUnresolved(t *testing.T) {
	telFixture(t)
	clk := useArrivalState(t)
	bindFor(t, iccidX, "refA")
	*clk += 1000
	stamp := *clk
	*clk += 1000
	if _, err := removeBindingOwner(iccidX, ""); err != nil {
		t.Fatal(err)
	}
	*clk += 1000
	bindFor(t, iccidX, "refB")
	*clk += 1000
	linkHistory, linkHorizon, linkFloor = nil, map[string]int64{}, -1 // the daemon restarts
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", stamp, "x")); got != "UNRESOLVED" {
		t.Fatalf("an arrival from before the restart replied %q, want UNRESOLVED", got)
	}
	if l := listSealed("refB"); l != nil {
		t.Fatalf("an arrival from A's tenure was sealed to B: %v", l)
	}
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(2), "sms", 2, iccidX, "+1", late, "x")); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("an arrival after the restart replied %q, want OK", got)
	}
}

// TestReplayTableHoldsAtMostItsCap: past telReplayMax the oldest entry goes, whatever its age.
func TestReplayTableHoldsAtMostItsCap(t *testing.T) {
	useArrivalState(t)
	for i := 0; i <= telReplayMax; i++ {
		telReplayPut(telReplayID("SEAL-TEL", arrivalID(i)), "NONE\n", "")
	}
	if len(telReplays) != telReplayMax || len(telReplayOrder) != telReplayMax {
		t.Fatalf("the table holds %d/%d, want %d", len(telReplays), len(telReplayOrder), telReplayMax)
	}
	if _, ok := telReplayGet(telReplayID("SEAL-TEL", arrivalID(0))); ok {
		t.Fatal("the oldest entry was kept past the cap")
	}
	if _, ok := telReplayGet(telReplayID("SEAL-TEL", arrivalID(telReplayMax))); !ok {
		t.Fatal("the newest entry was evicted")
	}
}

// TestAKeptOKTurnsRemovedOnlyWithTheLastOwner: a co-owner added or removed leaves a kept OK as it was; the SIM's last
// owner going turns it into REMOVED.
func TestAKeptOKTurnsRemovedOnlyWithTheLastOwner(t *testing.T) {
	telFixture(t)
	bindFor(t, iccidX, "refA")
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")
	first := driveLogin(t, t.TempDir(), req)
	if !strings.HasPrefix(first, "OK ") {
		t.Fatalf("replied %q", first)
	}
	bindFor(t, iccidX, "refB")
	if got := driveLogin(t, t.TempDir(), req); got != first {
		t.Fatalf("after a co-owner was added the repeat replied %q, want %q", got, first)
	}
	if _, err := removeBindingOwner(iccidX, "refB"); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), req); got != first {
		t.Fatalf("after a co-owner was removed the repeat replied %q, want %q", got, first)
	}
	if _, err := removeBindingOwner(iccidX, "refA"); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), req); got != "REMOVED" {
		t.Fatalf("after the last owner went the repeat replied %q, want REMOVED", got)
	}
}

// TestV2WireFieldsLandWhereTheyBelong: a call's type and duration, an MMS's subject, and an MMS's stamp are each read
// from their own position.
func TestV2WireFieldsLandWhereTheyBelong(t *testing.T) {
	telFixture(t)
	clk := useArrivalState(t)
	v, dk := bindFor(t, iccidX, "refA")
	call := strings.TrimSuffix(v2Tel(arrivalID(1), "call", 2, iccidX, "+1", late, ""), "0\n0\n") + "3\n45\n"
	if got := driveLogin(t, t.TempDir(), call); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the call replied %q", got)
	}
	mms := strings.Replace(v2Mms(arrivalID(2), 2, iccidX, late, "p"), "\n-\n1\n", "\n"+b64s("subj")+"\n1\n", 1)
	if got := driveLogin(t, t.TempDir(), mms); !strings.HasPrefix(got, "OK ") {
		t.Fatalf("the MMS replied %q", got)
	}
	var sawCall, sawMms bool
	for _, it := range readTelInboxItems(v, dk, "refA") {
		switch it.Kind {
		case "call":
			sawCall = it.CallType == 3 && it.DurSec == 45
		case "mms":
			sawMms = it.Subject == "subj"
		}
	}
	if !sawCall || !sawMms {
		t.Fatalf("the call's type and duration, or the MMS's subject, were not read from their positions (call %v, mms %v)", sawCall, sawMms)
	}
	*clk += 1000
	stamp := *clk
	*clk += 1000
	if _, err := removeBindingOwner(iccidX, ""); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, t.TempDir(), v2Mms(arrivalID(3), 2, iccidX, stamp, "p")); got != "REMOVED" {
		t.Fatalf("an MMS stamped before the unassign replied %q, want REMOVED", got)
	}
}

// TestADamagedLineLogsNoICCID: the class line for a damaged bindings.conf, on an arrival that carries an ICCID, names
// neither the ICCID nor its tag, the number, the body or the arrival id.
func TestADamagedLineLogsNoICCID(t *testing.T) {
	telFixture(t)
	if err := os.WriteFile(bindingsPath, []byte("v1\n2|"+iccidX+"|L!|open|refA:pubA\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	req := v2Tel(arrivalID(1), "sms", 2, iccidX, "+15559876543", late, "secret body")
	var got string
	out := captureStderr(t, func() { got = driveLogin(t, t.TempDir(), req) })
	if got != "UNRESOLVED" {
		t.Fatalf("replied %q", got)
	}
	if !strings.Contains(out, telClassBindingsDamaged) {
		t.Fatalf("no class line (the control): %q", out)
	}
	for _, leak := range []string{iccidX, simTag(iccidX), "5559876543", "secret", arrivalID(1)[:16]} {
		if strings.Contains(out, leak) {
			t.Fatalf("the log carries %q: %q", leak, out)
		}
	}
}

// TestAnAbsentFileIsNoSIMLinks: only an absent bindings.conf means no SIM links: an arrival is unbound (NONE), a
// re-staged row of a SIM is dropped as unassigned, and GET-BINDINGS says NONE with no DAMAGED -- the control for every
// flawed-file test above.
func TestAnAbsentFileIsNoSIMLinks(t *testing.T) {
	asGate(t)
	telFixture(t)
	if got := driveLogin(t, t.TempDir(), v2Tel(arrivalID(1), "sms", 2, iccidX, "+1", late, "x")); got != "NONE" {
		t.Fatalf("an arrival with no file replied %q, want NONE", got)
	}
	if got := driveLogin(t, t.TempDir(), "GET-BINDINGS\n"); got != "NONE" {
		t.Fatalf("GET-BINDINGS with no file replied %q, want NONE", got)
	}
	if !simUnboundNow(simTag(iccidX)) {
		t.Fatal("with no file a SIM reads as bound, or unknown")
	}
	if _, err := os.Stat(bindingsPath); !os.IsNotExist(err) {
		t.Fatalf("reading an absent file created it (%v)", err)
	}
}
