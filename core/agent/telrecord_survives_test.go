package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260924-04. A sealed telephony record may be removed only once it has landed in its profile, or by
// the reboot that empties the tmpfs (product-decisions.md 2026-09-24, Chester verbatim: "bound - it should
// get wiped after it lands to the assigned sim profile store"; "unbound - it shouldnt get wiped by any
// profile (only the owner or a reboot can clean it)"). These tests pin the four ways that was broken: the
// session-state wipes took the whole telephony subtree; a login dropped the sealed copies before its
// hand-off was written; a resume overwrote the rows its re-kick exists to retry; and a failed logoff seal
// deleted the still-live session's mailbox (that rule and the delete's are driven through handleLogout and
// handleDelete in mailbox_rules_test.go since NWP-20261021-10).

// seedTelSubtree plants one sealed blob and one mailbox under dest's telephony subtree.
func seedTelSubtree(t *testing.T, dest string) (blob, mailbox string) {
	t.Helper()
	blob = filepath.Join(dest, telStateSubdir, "inbox", "someref", "a.seal")
	mailbox = filepath.Join(dest, telStateSubdir, "telingest.12")
	for _, p := range []string{blob, mailbox} {
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return blob, mailbox
}

func mustExist(t *testing.T, what, p string) {
	t.Helper()
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("%s is missing: %v", what, err)
	}
}

// useTempIngest points telIngestBase at a not-yet-existing telephony dir under a temp root, which is what a
// device has after boot until the first mailbox is written.
func useTempIngest(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), telStateSubdir)
	old := telIngestBase
	telIngestBase = dir
	t.Cleanup(func() { telIngestBase = old })
	return dir
}

func TestWipeSessionStateSparesTelephony(t *testing.T) {
	dest := t.TempDir()
	blob, mailbox := seedTelSubtree(t, dest)
	others := []string{".coldlock", "wallet.json", filepath.Join("headblobs", "x")}
	for _, o := range others {
		p := filepath.Join(dest, o)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	wipeSessionState(dest)
	mustExist(t, "the sealed blob", blob)
	mustExist(t, "the mailbox", mailbox)
	for _, o := range append(others, "headblobs") {
		if _, err := os.Stat(filepath.Join(dest, o)); !os.IsNotExist(err) {
			t.Fatalf("wipeSessionState left %s (err %v)", o, err)
		}
	}
	absent := filepath.Join(t.TempDir(), "absent")
	wipeSessionState(absent)
	if fi, err := os.Stat(absent); err != nil || !fi.IsDir() {
		t.Fatalf("wipeSessionState must leave the state dir existing: %v", err)
	}
}

// TestTelBasesLiveUnderTheSparedSubdir: the name wipeSessionState spares and the two bases must agree, or a
// base moved on its own is silently exposed to the wipes again.
func TestTelBasesLiveUnderTheSparedSubdir(t *testing.T) {
	root := filepath.Join(stateDirDefault, telStateSubdir)
	if telIngestBase != root {
		t.Fatalf("telIngestBase = %q, want %q", telIngestBase, root)
	}
	if filepath.Dir(telInboxBase) != root {
		t.Fatalf("telInboxBase = %q, want a child of %q", telInboxBase, root)
	}
}

// driveLogin sends one request to handleLogin over a pipe and returns the trimmed reply.
func driveLogin(t *testing.T, dest, req string) string {
	t.Helper()
	cli, srv := net.Pipe()
	go cli.Write([]byte(req))
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- string(b)
	}()
	handleLogin(srv, dest) // closes srv itself
	got := strings.TrimSpace(<-reply)
	cli.Close()
	return got
}

// TestLegacyLogoffSparesTelephony drives the LOGOFF verb end to end: no legacy .session marker, so there is
// nothing to push, and the wipe runs.
func TestLegacyLogoffSparesTelephony(t *testing.T) {
	dest := t.TempDir()
	blob, mailbox := seedTelSubtree(t, dest)
	other := filepath.Join(dest, "wallet.json")
	if err := os.WriteFile(other, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, dest, "LOGOFF\n"); got != "OK" {
		t.Fatalf("LOGOFF reply %q, want OK", got)
	}
	mustExist(t, "the sealed blob", blob)
	mustExist(t, "the mailbox", mailbox)
	if _, err := os.Stat(other); !os.IsNotExist(err) {
		t.Fatalf("LOGOFF did not wipe the rest of the session state (err %v)", err)
	}
}

// TestLegacyLoginFallthroughSparesTelephony drives the legacy login fallthrough end to end: an unknown name
// with no store configured fails the restore and takes the "uniform clean blank" wipe.
func TestLegacyLoginFallthroughSparesTelephony(t *testing.T) {
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	dest := t.TempDir()
	blob, mailbox := seedTelSubtree(t, dest)
	other := filepath.Join(dest, "wallet.json")
	if err := os.WriteFile(other, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := driveLogin(t, dest, "stranger\nsome passphrase\n"); got != "BLANK" {
		t.Fatalf("legacy login reply %q, want BLANK", got)
	}
	mustExist(t, "the sealed blob", blob)
	mustExist(t, "the mailbox", mailbox)
	if _, err := os.Stat(other); !os.IsNotExist(err) {
		t.Fatalf("the failed legacy login did not wipe the rest of the session state (err %v)", err)
	}
}

// TestCreateSparesTelephony: a stranger enrolling a new profile at the gate must not take anyone's pending
// records. Cap mode, like the fielded fleet (the setup of TestAddDeviceVerbNamesWhichCredentialWasWrong).
func TestCreateSparesTelephony(t *testing.T) {
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	dest := t.TempDir()
	t.Setenv("NOWHERE_STATE", dest)
	t.Setenv("NOWHERE_ENROLL_STATE", filepath.Join(t.TempDir(), "enroll")) // never the host's /data (enroll_test.go)
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	blob, mailbox := seedTelSubtree(t, dest)
	other := filepath.Join(dest, ".coldlock")
	if err := os.WriteFile(other, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	cli, conn := net.Pipe()
	reply := make(chan string, 1)
	go func() {
		b, _ := io.ReadAll(cli)
		reply <- dropCreateProgress(string(b))
	}()
	handleCreate(conn, dest, "telcreateco", "horse battery staple correct")
	conn.Close()
	got := <-reply
	cli.Close()
	if !strings.HasPrefix(got, "OK ") {
		t.Fatalf("CREATE reply %q, want OK", got)
	}
	mustExist(t, "the sealed blob", blob)
	mustExist(t, "the mailbox", mailbox)
	if _, err := os.Stat(other); !os.IsNotExist(err) {
		t.Fatalf("CREATE did not wipe the rest of the session state (err %v)", err)
	}
}

func TestPushSetNeverSealsTheTelephonySubtree(t *testing.T) {
	base, _, _ := countingStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	root := t.TempDir()
	for _, d := range []string{"realdata", telStateSubdir} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, d, "f"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	const name, pass = "telsealco", "correct horse battery staple"
	if n := pushSet(base, name, pass, root); n != 1 {
		t.Fatalf("pushSet sealed %d items, want 1 (realdata only, never the telephony subtree)", n)
	}
}

// TestRestoreSetNeverUntarsOverTheTelephonySubtree: a manifest item that resolves ON or INSIDE the telephony
// subtree -- by any spelling, or "." whose tar carries tel/ entries -- must not be unpacked over other
// profiles' pending records. The raw-name check this replaced let every spelling but "tel" through.
func TestRestoreSetNeverUntarsOverTheTelephonySubtree(t *testing.T) {
	base, _, _ := countingStore(t)
	t.Setenv("NOWHERE_STATE", t.TempDir())
	t.Setenv("GATEWAY_URL", "")
	t.Setenv("S3_ACCESS_KEY", "")
	const name, pass = "telrestco", "correct horse battery staple"
	key := deriveKey(name, pass)
	pack := func(rel string) (string, int) {
		src := t.TempDir()
		p := filepath.Join(src, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("forged"), 0o600); err != nil {
			t.Fatal(err)
		}
		raw := tarDir(src)
		return postBlob(base, seal(key, raw)), len(raw)
	}
	planted, pn := pack("planted")
	viaDot, dn := pack(filepath.Join(telStateSubdir, "telingest.99"))
	items := []Item{{Name: "realdata", Ref: planted, Size: pn}, {Name: ".", Ref: viaDot, Size: dn}}
	for _, n := range []string{telStateSubdir, telStateSubdir + "/", "./" + telStateSubdir, "x/../" + telStateSubdir, telStateSubdir + "/inbox"} {
		items = append(items, Item{Name: n, Ref: planted, Size: pn})
	}
	mj, _ := json.Marshal(Manifest{Items: items})
	putRef(base, profileRefV2(name, pass), postBlob(base, seal(key, mj)))

	dest := t.TempDir()
	blob, mailbox := seedTelSubtree(t, dest)
	n, ok := restoreSet(base, name, pass, dest, 99, false)
	if !ok || n != 1 {
		t.Fatalf("restoreSet = %d, %v; want 1, true (realdata only)", n, ok)
	}
	mustExist(t, "the restored realdata item", filepath.Join(dest, "realdata", "planted"))
	var under []string
	filepath.Walk(filepath.Join(dest, telStateSubdir), func(p string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() {
			under = append(under, p)
		}
		return nil
	})
	if len(under) != 2 {
		t.Fatalf("the telephony subtree holds %v; want only the two seeded files", under)
	}
	for _, p := range []string{blob, mailbox} {
		if b, err := os.ReadFile(p); err != nil || string(b) != "x" {
			t.Fatalf("%s was overwritten (%q, %v)", p, b, err)
		}
	}
}

func TestStageTelInboxKeepsSealedWhenHandOffFails(t *testing.T) {
	useTempInbox(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	for _, w := range []int64{1, 2} {
		if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: w, Body: "b"}); err != nil {
			t.Fatal(err)
		}
	}
	// The mailbox dir cannot be created: its parent is a regular FILE.
	f := filepath.Join(t.TempDir(), "notadir")
	if err := os.WriteFile(f, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := telIngestBase
	telIngestBase = filepath.Join(f, telStateSubdir)
	t.Cleanup(func() { telIngestBase = old })
	n, err := stageTelInbox(v, dk, ref, "12")
	if err == nil || n != 0 {
		t.Fatalf("stage = %d, %v; want 0 and the hand-off error", n, err)
	}
	if l := listSealed(ref); len(l) != 2 {
		t.Fatalf("%d sealed blobs left, want 2 -- dropped although nothing was handed off", len(l))
	}
}

func TestStageTelInboxDropsWhatItHandedOff(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	for _, w := range []int64{1, 2} {
		if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: w, Body: "b"}); err != nil {
			t.Fatal(err)
		}
	}
	n, err := stageTelInbox(v, dk, ref, "12")
	if err != nil || n != 2 {
		t.Fatalf("stage = %d, %v; want 2, nil", n, err)
	}
	if l := listSealed(ref); l != nil {
		t.Fatalf("handed-off blobs were not dropped: %v", l)
	}
	b, err := claimTelIngest("12")
	if err != nil || strings.Count(string(b), "\n") != 2 {
		t.Fatalf("mailbox = %q, %v; want 2 rows", b, err)
	}
}

// TestDropSealedSparesALateArrival: a blob buffered after the read must survive the drop -- the old clear
// removed the profile's whole directory, deleting it unread.
func TestDropSealedSparesALateArrival(t *testing.T) {
	useTempInbox(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: 1, Body: "early"}); err != nil {
		t.Fatal(err)
	}
	_, opened := readTelInbox(v, dk, ref)
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: 2, Body: "late"}); err != nil {
		t.Fatal(err)
	}
	dropSealed(opened)
	left := readTelInboxItems(v, dk, ref)
	if len(left) != 1 || left[0].When != 2 {
		t.Fatalf("after the drop, want only the late arrival, got %+v", left)
	}
}

// TestResumeStagingKeepsRowsAlreadyWaiting: a resume's mailbox can already hold a row the chooser re-staged
// for retry and a live arrival from before the lock. Staging must add to them, not replace them.
func TestResumeStagingKeepsRowsAlreadyWaiting(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	v, dk := vaultWithTelKey(t)
	const ref, uid = "reftest", "12"
	const restaged = "call 5 3 0 KzE - 1"
	if err := appendTelIngestRaw(uid, restaged); err != nil {
		t.Fatal(err)
	}
	if err := appendTelIngest(uid, "", telItem{Kind: "sms", From: "+2", When: 6, Body: "live"}); err != nil {
		t.Fatal(err)
	}
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+3", When: 7, Body: "sealed"}); err != nil {
		t.Fatal(err)
	}
	if n, err := stageTelInbox(v, dk, ref, uid); err != nil || n != 1 {
		t.Fatalf("stage = %d, %v; want 1, nil", n, err)
	}
	b, err := claimTelIngest(uid)
	if err != nil {
		t.Fatal(err)
	}
	rows := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(rows) != 3 || rows[0] != restaged || !strings.HasPrefix(rows[1], "sms 6 ") || !strings.HasPrefix(rows[2], "sms 7 ") {
		t.Fatalf("mailbox after a resume stage = %q; want the re-staged row, the live row, then the sealed one", rows)
	}
}

// TestLoginAndResumeStageInTheRightMode pins the two call sites (NWP-20260927-09): both begin the bring-up before
// their session marker and end it on every exit, both stage under telMu, only roam-in drops a stale mailbox (a new
// uid) -- at the bring-up, before any arrival can queue a row -- and neither writes a mailbox itself.
func TestLoginAndResumeStageInTheRightMode(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	// NWP-20261017-25: the staging itself lives in the lifted hand-off each handler calls once.
	// NWP-20261116-03 (h46 #1): a ROAM-IN stages in its late job, through the guarded hand-off and the guarded stage.
	for fn, hand := range map[string][3]string{
		"handleRoamIn": {"staleErr := beginTelStaging(uid, true)", "telHandoffRoamInGuarded",
			"stageTelInboxGuarded(v, dk, profileRefV2(name, pass), uid, mayWrite)"},
		"handleResume": {"beginTelStaging(uid, false)", "telHandoffResume", "stageTelInboxLocked(v, dk, profileRefV2(name, pass), uid)"},
	} {
		begin := hand[0]
		lines := stripComments(funcBody(t, src, fn))
		body := strings.Join(lines, "\n")
		for _, want := range []string{begin, "defer endTelStaging(uid)", hand[1] + "("} {
			if strings.Count(body, want) != 1 {
				t.Fatalf("%s must contain %q once", fn, want)
			}
		}
		handBody := strings.Join(stripComments(funcBody(t, src, hand[1])), "\n")
		if strings.Count(handBody, hand[2]) != 1 {
			t.Fatalf("%s must stage under telMu once", hand[1])
		}
		body += "\n" + handBody
		at := func(s string) int {
			for i, l := range lines {
				if strings.Contains(l, s) {
					return i
				}
			}
			return -1
		}
		// The defer on the very next line, so no exit can come between the begin and the defer and leave the
		// bring-up pinned (every later arrival for that session would then wait for a claim instead of going live).
		if at(begin) < 0 || at(begin) > at("markRoamSession(") || at("defer endTelStaging(uid)") != at(begin)+1 {
			t.Fatalf("%s must begin the bring-up, and defer its end on the next line, before the marker names the session", fn)
		}
		// No mailbox writer or claimer outside the telMu helpers: the primitives, and the functions that rely on
		// handleTelCmd's hold ("appendTelIngest" also matches its Raw and Batch forms; "stageTelInbox(" does not match
		// "stageTelInboxLocked(").
		for _, bad := range []string{"stageTelInbox(", "appendTelIngest", "appendMailbox(", "claimTelIngest(", "restageTelIngest(", "removeMailboxes(", "deleteSimMailboxes(",
			"deliverToOwners(", "handleSealTel(", "handleSealMms(", "serveGetTelIngest(", "serveRestageTelIngest(", "telStagingUID"} {
			if strings.Contains(body, bad) {
				t.Fatalf("%s bypasses the telMu helpers (%s)", fn, bad)
			}
		}
	}
}

// TestMailboxWritersCreateTheTelephonySubtree: after boot the subtree does not exist until something writes
// it. Every mailbox writer must create it, or the first live SMS after a boot is lost.
func TestMailboxWritersCreateTheTelephonySubtree(t *testing.T) {
	it := telItem{Kind: "sms", From: "+1", When: 1, Body: "b"}
	tagX := simTag("8944000000000000001")
	for name, write := range map[string]func(string) error{
		"appendTelIngest":      func(u string) error { return appendTelIngest(u, tagX, it) },
		"appendTelIngestRaw":   func(u string) error { return appendTelIngestRaw(u, "call 1 3 0 - -"+tagX) },
		"appendTelIngestBatch": func(u string) error { return appendTelIngestBatch(u, tagX, []telItem{it}) },
	} {
		useTempIngest(t)
		if err := write("12"); err != nil {
			t.Fatalf("%s into a fresh boot's missing subtree: %v", name, err)
		}
		mustExist(t, name+"'s mailbox", telIngestPath("12", tagX))
	}
}

// TestStageRemovesTheEmptyInboxDir: once everything is handed off AND acknowledged the profile's directory goes
// too (its mtime would otherwise record the last delivery until the reboot); it stays while any blob remains,
// pending ones included (NWP-20261006-05).
func TestStageRemovesTheEmptyInboxDir(t *testing.T) {
	useTempInbox(t)
	useTempIngest(t)
	v, dk := vaultWithTelKey(t)
	const ref = "reftest"
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: 1, Body: "b"}); err != nil {
		t.Fatal(err)
	}
	if _, err := stageTelInbox(v, dk, ref, "12"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(telInboxDir(ref)); err != nil {
		t.Fatalf("the dir went while a copy was still pending (err %v)", err)
	}
	if n := ackPending("12", []string{"sms 1"}); n != 1 {
		t.Fatalf("ack removed %d copies, want 1", n)
	}
	if _, err := os.Stat(telInboxDir(ref)); !os.IsNotExist(err) {
		t.Fatalf("the emptied inbox dir was left behind (err %v)", err)
	}
	if err := sealItemToInbox(ref, v.TelPub, "", telItem{Kind: "sms", From: "+1", When: 2, Body: "b"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(telInboxDir(ref), "garbage.seal"), []byte("not a box"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := stageTelInbox(v, dk, ref, "12"); err != nil {
		t.Fatal(err)
	}
	if l := listSealed(ref); len(l) != 1 {
		t.Fatalf("the unopenable blob must stay (and its dir with it), got %v", l)
	}
	// Nothing to stage: an empty dir (a failed arrival's MkdirAll) still goes.
	const other = "emptyref"
	if err := os.MkdirAll(telInboxDir(other), 0o700); err != nil {
		t.Fatal(err)
	}
	if n, err := stageTelInbox(v, dk, other, "12"); err != nil || n != 0 {
		t.Fatalf("stage of an empty inbox = %d, %v", n, err)
	}
	if _, err := os.Stat(telInboxDir(other)); !os.IsNotExist(err) {
		t.Fatalf("an empty inbox dir survived a stage with nothing to hand off (err %v)", err)
	}
}

// TestWriteAtomicLeavesNoTemp: a failed publish removes its temp file. The sealed-blob writer goes through it (the
// fresh-mailbox writer did too, until NWP-20260927-09 made every mailbox write an append).
func TestWriteAtomicLeavesNoTemp(t *testing.T) {
	dir := t.TempDir()
	dst := filepath.Join(dir, "dst")
	if err := os.MkdirAll(filepath.Join(dst, "occupied"), 0o700); err != nil { // a non-empty dir: the rename fails
		t.Fatal(err)
	}
	tmp := filepath.Join(dir, ".dst.tmp")
	if err := writeAtomic(tmp, dst, []byte("rows")); err == nil {
		t.Fatal("writeAtomic over a non-empty directory must fail")
	}
	if _, err := os.Stat(tmp); !os.IsNotExist(err) {
		t.Fatalf("the temp file was left behind (err %v)", err)
	}

	b, err := os.ReadFile("telephony_inbox.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(stripComments(funcBody(t, string(b), "bufferSealed")), "\n"), "writeAtomic(") {
		t.Fatal("bufferSealed must publish through writeAtomic")
	}
}

// TestBatchAppendRollsBackAShortWrite: every append is all or nothing. A short write must leave the mailbox
// exactly as it was, or a caller that keeps its sealed copy delivers the landed half twice and the next append
// is glued onto a line with no newline. Covers all three appenders; and a rollback that itself fails says so.
func TestBatchAppendRollsBackAShortWrite(t *testing.T) {
	useTempIngest(t)
	const uid = "12"
	if err := appendTelIngestRaw(uid, "call 5 3 0 KzE - 1"); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(telIngestPath(uid, ""))
	if err != nil {
		t.Fatal(err)
	}
	old := telAppendWrite
	t.Cleanup(func() { telAppendWrite = old })
	telAppendWrite = func(fh *os.File, s string) (int, error) {
		n, _ := fh.WriteString(s[:len(s)/2])
		return n, os.ErrInvalid // the half that landed, and a failure
	}
	it := telItem{Kind: "sms", From: "+1", When: 1, Body: "one"}
	for name, write := range map[string]func() error{
		"appendTelIngestBatch": func() error { return appendTelIngestBatch(uid, "", []telItem{it, it}) },
		"appendTelIngest":      func() error { return appendTelIngest(uid, "", it) },
		"appendTelIngestRaw":   func() error { return appendTelIngestRaw(uid, "call 6 3 0 KzI - 2") },
	} {
		if err := write(); err == nil {
			t.Fatalf("%s: a short write must be reported", name)
		}
		if after, _ := os.ReadFile(telIngestPath(uid, "")); string(after) != string(before) {
			t.Fatalf("%s: mailbox after a short write = %q, want it rolled back to %q", name, after, before)
		}
	}
	// The rollback's own failure: the fake closes the file, so the truncate-back cannot run.
	telAppendWrite = func(fh *os.File, s string) (int, error) {
		n, _ := fh.WriteString(s[:len(s)/2])
		fh.Close()
		return n, os.ErrInvalid
	}
	if err := appendTelIngest(uid, "", it); err == nil || !strings.Contains(err.Error(), "rollback failed") {
		t.Fatalf("a failed rollback must be reported as one, got %v", err)
	}
}

// TestTelephonyLogLinesQuoteTheName: the reap's log_scrub redacts only QUOTED runs, so a profile name printed
// bare reaches the persistent login.log in the clear -- the #39 roster. The staging lines must use %q.
func TestTelephonyLogLinesQuoteTheName(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, fn := range []string{"telHandoffRoamInGuarded", "telHandoffResume"} {
		for _, l := range stripComments(funcBody(t, string(b), fn)) {
			if !strings.Contains(l, "telephony hand-off FAILED") && !strings.Contains(l, "sealed telephony item(s)") {
				continue
			}
			seen++
			if !strings.Contains(l, "%q") || strings.Contains(l, "Fprintln") {
				t.Fatalf("%s logs the profile name unquoted: %s", fn, strings.TrimSpace(l))
			}
			if scrubbed(fmt.Sprintf(`"%s"`, "alice")) == `"alice"` {
				t.Fatal("the scrub mirror is broken") // control: the log_scrub mirror must redact a quoted name
			}
		}
	}
	if seen != 4 {
		t.Fatalf("found %d telephony staging log lines, want 4 -- this test is stale, not the code", seen)
	}
}
