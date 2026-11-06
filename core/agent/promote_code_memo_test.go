package main

import (
	"net"
	"strings"
	"testing"
	"time"
)

// NWP-20261116-04 (h46 #7): a Save to your store (PROMOTE2) whose reply was lost hands its recovery words over once
// on the repeat Save, from the session that saved; the words live in the Q048 memo under their own prefix.

// pmemoSaved signs a throwaway in as name, saves it with PROMOTE2 (same passphrase: no re-key), joins the background
// seal before it stops the stub worker, and returns the dest and the words the save answered. wrap, when set, wraps
// the handler's conn. A seal still running after the test held laneRW and the "promote" announce, so later tests
// (the re-key batch, the rent gate) saw a busy daemon; a fixed sleep did not cover a slow syscall.Sync on CI.
func pmemoSaved(t *testing.T, name string, wrap func(net.Conn) net.Conn) (dest, words string) {
	t.Helper()
	tr := trackGoSafe(t)
	ropStore(t)
	ropReapReset(t)
	dest = ropThrowaway(t, name, ropPass)
	stop := ropWorker(t, dest)
	got := ropReply(t, func(c net.Conn) {
		if wrap != nil {
			c = wrap(c)
		}
		handlePromote2(c, dest, ropPass)
	})
	tr.wait(t, 60*time.Second) // the promote seal asks the worker in a goroutine: join it while the worker answers
	stop()
	if n := tr.count("promote-seal"); n != 0 {
		t.Fatalf("%d promote seal(s) still running after the save", n)
	}
	if !strings.HasPrefix(got, "OK RECOVERY ") {
		t.Fatalf("the save replied %q, want OK RECOVERY <words>", got)
	}
	if isLocalSession(dest) {
		t.Fatal("the save left the session local")
	}
	return dest, strings.TrimPrefix(got, "OK RECOVERY ")
}

func pmemoPromote2(t *testing.T, dest string) string {
	t.Helper()
	return ropReply(t, func(c net.Conn) { handlePromote2(c, dest, ropPass) })
}

// P1: the repeat PROMOTE2 inside the window gets the words the save minted, once.
func TestPromoteCodeMemoRepeatPromote2GetsTheWordsOnce(t *testing.T) {
	memoClock(t)
	dest, words := pmemoSaved(t, "pmemo-p1", nil)
	if got := pmemoPromote2(t, dest); got != "OK RECOVERY "+words {
		t.Fatalf("the repeat Save replied %q, want OK RECOVERY <the words the save minted>", got)
	}
	if got := pmemoPromote2(t, dest); got != "ERR-ALREADY" {
		t.Fatalf("the third Save replied %q, want ERR-ALREADY: the words are handed over once", got)
	}
}

// P2: past the window the repeat PROMOTE2 gets ERR-ALREADY.
func TestPromoteCodeMemoNothingAfterTheWindow(t *testing.T) {
	now := memoClock(t)
	dest, _ := pmemoSaved(t, "pmemo-p2", nil)
	*now = now.Add(createCodeMemoTTL)
	if got := pmemoPromote2(t, dest); got != "ERR-ALREADY" {
		t.Fatalf("a repeat Save after the window replied %q, want ERR-ALREADY", got)
	}
}

// P3: a sign-in in between ends the window.
func TestPromoteCodeMemoSignInBetweenForgets(t *testing.T) {
	memoClock(t)
	dest, _ := pmemoSaved(t, "pmemo-p3", nil)
	verb(func(c net.Conn) { handleRoamIn(c, t.TempDir(), "", "", "", "", "") })
	if got := pmemoPromote2(t, dest); got != "ERR-ALREADY" {
		t.Fatalf("a repeat Save after a sign-in replied %q, want ERR-ALREADY", got)
	}
}

// P4: a repeat CREATE with the same name and passphrase never takes a promote's words; the PROMOTE2 still does.
func TestPromoteCodeMemoRepeatCreateNeverTakesThem(t *testing.T) {
	memoClock(t)
	const name = "pmemo-p4"
	dest, words := pmemoSaved(t, name, nil)
	if got := ropReply(t, func(c net.Conn) { handleCreate(c, t.TempDir(), name, ropPass) }); got != "EXISTS" {
		t.Fatalf("a CREATE over the saved profile replied %q, want a bare EXISTS: a create never takes a save's words", got)
	}
	if got := pmemoPromote2(t, dest); got != "OK RECOVERY "+words {
		t.Fatalf("the repeat Save after a CREATE replied %q, want OK RECOVERY <the words the save minted>", got)
	}
}

// P5: PROMOTE (not PROMOTE2) does not hand the words over, and leaves them for a PROMOTE2.
func TestPromoteCodeMemoPromoteDoesNotHandOver(t *testing.T) {
	memoClock(t)
	dest, words := pmemoSaved(t, "pmemo-p5", nil)
	if got := ropReply(t, func(c net.Conn) { handlePromote(c, dest) }); got != "ERR-ALREADY" {
		t.Fatalf("PROMOTE from the saved session replied %q, want ERR-ALREADY", got)
	}
	if got := pmemoPromote2(t, dest); got != "OK RECOVERY "+words {
		t.Fatalf("the PROMOTE2 after a PROMOTE replied %q, want OK RECOVERY <the words the save minted>", got)
	}
}

// P6: across the save and two repeats, no log line holds the phrase or any two of its words in order.
func TestPromoteCodeMemoLogsNoWords(t *testing.T) {
	memoClock(t)
	stop := memoCapture(t)
	var dest, words string
	func() {
		defer func() {
			if t.Failed() {
				stop()
			}
		}()
		dest, words = pmemoSaved(t, "pmemo-p6", nil)
	}()
	second := pmemoPromote2(t, dest)
	third := pmemoPromote2(t, dest)
	logs := stop()
	if second != "OK RECOVERY "+words || third != "ERR-ALREADY" {
		t.Fatalf("the repeats replied %q then %q, want OK RECOVERY <words> then ERR-ALREADY", second, third)
	}
	if n := strings.Count(logs, "a lost save's recovery words handed over once (h46 #7)"); n != 1 {
		t.Errorf("the handover line was logged %d times, want once", n)
	}
	// As TestCreateCodeMemoRepeatCreateGetsTheCodeOnce: a single BIP-39 word is not evidence (NWP-20261021-25).
	ws, lf := strings.Fields(words), strings.Fields(logs)
	if strings.Contains(logs, words) {
		t.Fatalf("a log line carries the recovery code:\n%s", logs)
	}
	for i := 0; i+1 < len(ws); i++ {
		for j := 0; j+1 < len(lf); j++ {
			if lf[j] == ws[i] && lf[j+1] == ws[i+1] {
				t.Fatalf("a log line carries the mnemonic words %q %q in order:\n%s", ws[i], ws[i+1], logs)
			}
		}
	}
}

// pmemoProbeConn records, when the handler writes OK RECOVERY, whether the memo already holds the promote entry.
type pmemoProbeConn struct {
	net.Conn
	key            string
	sawReply, held bool
}

func (c *pmemoProbeConn) Write(b []byte) (int, error) {
	if strings.HasPrefix(string(b), "OK RECOVERY ") {
		c.sawReply = true
		createCodeMemoMu.Lock() // released before the write goes on, so the memo is never locked across the reply
		_, c.held = createCodeMemo[c.key]
		createCodeMemoMu.Unlock()
	}
	return c.Conn.Write(b)
}

// P7: promoteToStore remembers the words BEFORE it writes the reply, so a reply that never arrives is covered. A
// failing reply write cannot show this: promoteToStore ignores Fprintf's error, so a later remember still runs.
func TestPromoteCodeMemoRememberedBeforeTheReply(t *testing.T) {
	memoClock(t)
	const name = "pmemo-p7"
	probe := &pmemoProbeConn{key: promoteCodeMemoKey(name, ropPass)}
	pmemoSaved(t, name, func(c net.Conn) net.Conn { probe.Conn = c; return probe })
	if !probe.sawReply || !probe.held {
		t.Fatalf("at the OK RECOVERY write: reply seen=%v, memo held the words=%v; promoteToStore must remember them first",
			probe.sawReply, probe.held)
	}
}
