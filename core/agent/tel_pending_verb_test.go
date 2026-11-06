package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// NWP-20261026-20 -- TEL-PENDING: how many telephony records a reboot would destroy, asked by the gate's reap before
// it reboots a user that will not remove. One integer, the gate only, answered without sessionMu.

const tpvRef = "0123456789abcdef0123456789abcdef"

type tpvTree struct {
	inbox, owner, ingest string
}

// tpvBases points the three record bases at their own temp dirs and restores them when the test ends.
func tpvBases(t *testing.T) tpvTree {
	t.Helper()
	oldInbox, oldOwner, oldIngest := telInboxBase, ownerInboxBase, telIngestBase
	tr := tpvTree{inbox: filepath.Join(t.TempDir(), "inbox"), owner: filepath.Join(t.TempDir(), "owner"), ingest: filepath.Join(t.TempDir(), "ingest")}
	telInboxBase, ownerInboxBase, telIngestBase = tr.inbox, tr.owner, tr.ingest
	t.Cleanup(func() { telInboxBase, ownerInboxBase, telIngestBase = oldInbox, oldOwner, oldIngest })
	return tr
}

func tpvWrite(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		t.Fatal(err)
	}
}

// tpvPlant plants 2 inbox blobs, 1 owner item and a mailbox of 2 rows: 5 records.
func tpvPlant(t *testing.T, tr tpvTree) {
	t.Helper()
	tpvWrite(t, filepath.Join(tr.inbox, tpvRef, "0123456789abcdef.fedcba9876543210.seal"), "a")
	tpvWrite(t, filepath.Join(tr.inbox, tpvRef, "0123456789abcdef.fedcba9876543211.7.0123456789abcdef.pend"), "b")
	tpvWrite(t, filepath.Join(tr.owner, "0123456789abcdef.seal"), "c")
	tpvWrite(t, filepath.Join(tr.ingest, "telingest.7"), "sms 1 x\nsms 2 y\n")
}

func tpvAsk(t *testing.T) string {
	t.Helper()
	return driveLogin(t, t.TempDir(), "TEL-PENDING\n")
}

func TestTelPendingVerb_CountsPlantedRecords(t *testing.T) {
	tr := tpvBases(t)
	tpvPlant(t, tr)
	gatePeer(t, 0)
	want, err := telPendingCount()
	if err != nil || want != 5 {
		t.Fatalf("telPendingCount = %d, %v; want 5, nil", want, err)
	}
	if got, w := tpvAsk(t), fmt.Sprintf("OK %d", want); got != w {
		t.Fatalf("TEL-PENDING = %q, want %q", got, w)
	}
}

func TestTelPendingVerb_EmptyBasesAnswerZero(t *testing.T) {
	tr := tpvBases(t)
	gatePeer(t, 0)
	if got := tpvAsk(t); got != "OK 0" {
		t.Fatalf("absent bases: %q, want OK 0", got)
	}
	for _, d := range []string{tr.inbox, tr.owner, tr.ingest} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if got := tpvAsk(t); got != "OK 0" {
		t.Fatalf("empty bases: %q, want OK 0", got)
	}
}

func TestTelPendingVerb_UnreadableBaseAnswersERR(t *testing.T) {
	tr := tpvBases(t)
	gatePeer(t, 0)
	for name, p := range map[string]string{"inbox": tr.inbox, "owner": tr.owner, "ingest": tr.ingest} {
		tpvWrite(t, p, "x") // a file where the dir should be
		if got := tpvAsk(t); got != "ERR" {
			t.Errorf("unreadable %s base: %q, want ERR", name, got)
		}
		os.Remove(p)
	}
}

func TestTelPendingVerb_RefusesNonGatePeer(t *testing.T) {
	for _, uid := range []int{gateRoamedA, gateRoamedB, -1} {
		for _, broken := range []bool{false, true} {
			tr := tpvBases(t)
			if broken {
				tpvWrite(t, tr.inbox, "x") // a read would answer ERR
			} else {
				tpvPlant(t, tr) // a read would answer OK 5
			}
			gatePeer(t, uid)
			if got := tpvAsk(t); got != "DENIED" {
				t.Errorf("peer %d broken=%v: %q, want exactly DENIED", uid, broken, got)
			}
		}
	}
}

func TestTelPendingVerb_AnswersWhileSessionMuIsHeld(t *testing.T) {
	tr := tpvBases(t)
	tpvWrite(t, filepath.Join(tr.owner, "0123456789abcdef.seal"), "c")
	gatePeer(t, 0)
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if got := replyWhileHeld(t, 5*time.Second, "TEL-PENDING\n", "TEL-PENDING"); got != "OK 1" {
		t.Fatalf("TEL-PENDING with sessionMu held = %q, want OK 1", got)
	}
}

func TestTelPendingVerb_IsConcurrentSafe(t *testing.T) {
	if !concurrentSafeCmd("TEL-PENDING") {
		t.Fatal("TEL-PENDING is not in concurrentSafeCmd: it would wait on sessionMu behind the reap it informs")
	}
}
