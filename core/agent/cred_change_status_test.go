package main

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// NWP-20261208-05: a passphrase change (ROTATE) or a recovery leaves one session-scope outcome record, and the
// in-session issue report turns it into cred_change* keys for the signed-in profile only.

const ccOld, ccNew = "horse battery staple correct", "a completely different passphrase"

// ccRecord reads the record in dir, requires the grammar, and splits it into its fields.
func ccRecord(t *testing.T, dir string) map[string]string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, credChangeFile))
	if err != nil {
		t.Fatalf("no cred-change record: %v", err)
	}
	line := strings.TrimSuffix(string(b), "\n")
	if !regexp.MustCompile(`^v=1 kind=(rotate|recover) path=(committed|partial) marker=[a-z]+ keyguard=[a-z]+ bind=[0-9]+ binderr=[01] inbox=[0-9]+ inboxerr=[01] matched=([0-9]+|-) new=[0-9a-f]{16} old=([0-9a-f]{16}|-)$`).MatchString(line) {
		t.Fatalf("record %q does not match the grammar", line)
	}
	m := map[string]string{}
	for _, f := range strings.Fields(line) {
		k, v, _ := strings.Cut(f, "=")
		m[k] = v
	}
	return m
}

func ccNoRecord(t *testing.T, dir string) {
	t.Helper()
	if _, err := os.Stat(filepath.Join(dir, credChangeFile)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a cred-change record exists (%v), want none", err)
	}
}

// ccWant checks every key in want against got.
func ccWant(t *testing.T, what string, got, want map[string]string) {
	t.Helper()
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: %s = %q, want %q (all: %v)", what, k, got[k], v, got)
		}
	}
}

// ccMerge runs the merge in session scope over dest.
func ccMerge(t *testing.T, dest string) map[string]string {
	t.Helper()
	s := map[string]string{}
	mergeCredChange(s, dest, false)
	return s
}

// ccKeys is the cred_change* keys of status.
func ccKeys(status map[string]string) map[string]string {
	m := map[string]string{}
	for k, v := range status {
		if strings.HasPrefix(k, "cred_change") {
			m[k] = v
		}
	}
	return m
}

// ccNoSecrets: every cred_change* value is a fixed word or an integer, and holds none of secrets.
func ccNoSecrets(t *testing.T, status map[string]string, secrets ...string) {
	t.Helper()
	re := regexp.MustCompile(`^([a-z]+|[0-9]+)$`)
	for k, v := range ccKeys(status) {
		if !re.MatchString(v) {
			t.Errorf("%s = %q is not a fixed word or an integer", k, v)
		}
		for _, s := range secrets {
			if s != "" && strings.Contains(v, s) {
				t.Errorf("%s = %q holds a name, passphrase, ref or digest", k, v)
			}
		}
	}
}

// ccSecrets is everything a status value must never hold for one profile and its two passphrases.
func ccSecrets(name, oldp, newp string) []string {
	o, n := profileRefV2(name, oldp), profileRefV2(name, newp)
	return []string{name, oldp, newp, o, n, refDigest(o), refDigest(n)}
}

// ccRotateFixture: a cap-mode profile with a telephony key, ready for ROTATE. Returns dest and the vault's TelPub.
func ccRotateFixture(t *testing.T, name string) (string, string) {
	t.Helper()
	useTempBindings(t)
	useTempInbox(t)
	dest := capRotateFixture(t)
	stubRekey(t, "OK")
	if createVault("s3", name, ccOld) == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	v, _ := openVaultHead("s3", name, ccOld)
	if v == nil || v.TelPub == "" {
		t.Fatal("precondition: the vault has no telephony key")
	}
	return dest, v.TelPub
}

// ccRecoverFixture is recoverReplyFixture with the test's own profile name.
func ccRecoverFixture(t *testing.T, name string) string {
	t.Helper()
	srv, _, _ := mockCapStore(t)
	t.Setenv("GATEWAY_URL", srv.URL)
	t.Setenv("S3_ACCESS_KEY", "")
	capReadCache = map[string]capEntry{}
	t.Setenv("NOWHERE_STATE", t.TempDir())
	wpath := filepath.Join(t.TempDir(), "wallet.json")
	t.Setenv("NOWHERE_WALLET", wpath)
	toks, err := newGatewayClient(srv.URL, gwDefault).buyFaucet(50)
	if err != nil {
		t.Fatal(err)
	}
	if err := saveWallet(wpath, &Wallet{Tokens: toks}); err != nil {
		t.Fatal(err)
	}
	mn := createVault("s3", name, ccOld)
	if mn == "" {
		t.Fatal("createVault (cap mode) returned no recovery code")
	}
	capReadCache = map[string]capEntry{}
	return mn
}

func TestCredChangeRotateLive(t *testing.T) {
	const name = "ccrotlive"
	dest, pub := ccRotateFixture(t, name)
	oldRef, newRef := profileRefV2(name, ccOld), profileRefV2(name, ccNew)
	if err := setBindingOwner(1, "8901000000000001", "line", "open", oldRef, pub); err != nil {
		t.Fatal(err)
	}
	if err := setBindingOwner(2, "8901000000000002", "line", "open", oldRef, pub); err != nil {
		t.Fatal(err)
	}
	rbSeal(t, oldRef)
	liveMarker(t, dest, name, ccOld, "10", "")
	if got := rotateVerb(t, dest, name, ccOld, ccNew); got != "OK 0" {
		t.Fatalf("ROTATE replied %q, want OK 0", got)
	}
	ccWant(t, "record", ccRecord(t, dest), map[string]string{
		"kind": "rotate", "path": "committed", "marker": "rekeyed", "keyguard": "rekeyed",
		"bind": "2", "binderr": "0", "inbox": "1", "inboxerr": "0", "matched": "-",
		"new": refDigest(newRef), "old": refDigest(oldRef),
	})
	s := ccMerge(t, dest)
	ccWant(t, "merge", s, map[string]string{
		"cred_change": "rotate", "cred_change_path": "committed", "cred_change_marker": "rekeyed",
		"cred_change_keyguard": "rekeyed", "cred_change_marker_now": "matches",
		"cred_change_sim_bindings": "2", "cred_change_sim_bindings_err": "0",
		"cred_change_sim_inbox": "1", "cred_change_sim_inbox_err": "0", "cred_change_sim_owned_now": "2",
	})
	if _, ok := s["cred_change_sim_matched"]; ok {
		t.Errorf("a rotation reported cred_change_sim_matched: %v", s)
	}
	ccNoSecrets(t, s, ccSecrets(name, ccOld, ccNew)...)
}

func TestCredChangeRotateStale(t *testing.T) {
	const name = "ccrotstale"
	dest, _ := ccRotateFixture(t, name)
	liveMarker(t, dest, name, "whatever a late writer put back", "12", "")
	if got := rotateVerb(t, dest, name, ccOld, ccNew); got != "OK 0" {
		t.Fatalf("ROTATE replied %q, want OK 0", got)
	}
	ccWant(t, "record", ccRecord(t, dest), map[string]string{
		"kind": "rotate", "path": "committed", "marker": "repaired", "keyguard": "untouched",
	})
	ccWant(t, "merge", ccMerge(t, dest), map[string]string{"cred_change_marker_now": "matches"})
}

func TestCredChangeReverted(t *testing.T) {
	const name = "ccrevert"
	dest, _ := ccRotateFixture(t, name)
	liveMarker(t, dest, name, ccOld, "10", "")
	if got := rotateVerb(t, dest, name, ccOld, ccNew); got != "OK 0" {
		t.Fatalf("ROTATE replied %q, want OK 0", got)
	}
	ccWant(t, "merge before", ccMerge(t, dest), map[string]string{"cred_change_marker_now": "matches"})
	// A later writer puts the OLD passphrase back: the report must say so.
	if err := markRoamSession(dest, name, ccOld, "10", ""); err != nil {
		t.Fatal(err)
	}
	s := ccMerge(t, dest)
	ccWant(t, "merge after", s, map[string]string{"cred_change": "rotate", "cred_change_marker_now": "reverted"})
	ccNoSecrets(t, s, ccSecrets(name, ccOld, ccNew)...)
}

func TestCredChangePartial(t *testing.T) {
	const name = "ccpartial"
	rb := s3RetryBase
	s3RetryBase = time.Millisecond
	t.Cleanup(func() { s3RetryBase = rb })
	dest, pub := ccRotateFixture(t, name)
	oldRef := profileRefV2(name, ccOld)
	rbBind(t, oldRef, pub)
	rbSeal(t, oldRef)
	liveMarker(t, dest, name, ccOld, "10", "")
	victim := ""
	capStorePutHook = func(key string, body []byte) error {
		if victim == "" && strings.HasPrefix(key, "ref/") && len(body) == 0 {
			victim = key
		}
		if key == victim {
			return errTestStoreRefused
		}
		return nil
	}
	got := rotateVerb(t, dest, name, ccOld, ccNew)
	capStorePutHook = nil
	if victim == "" || got != "ERR-SESSION" {
		t.Fatalf("precondition: victim %q reply %q, want a committed-but-errored rotation", victim, got)
	}
	ccWant(t, "record", ccRecord(t, dest), map[string]string{
		"kind": "rotate", "path": "partial", "marker": "rekeyed", "keyguard": "rekeyed", "bind": "1", "inbox": "1",
	})
	ccWant(t, "merge", ccMerge(t, dest), map[string]string{"cred_change_path": "partial", "cred_change_marker_now": "matches"})
}

func TestCredChangeRefused(t *testing.T) {
	const name = "ccrefused"
	dest, _ := ccRotateFixture(t, name)
	liveMarker(t, dest, name, "not the session passphrase", "10", "")
	if got := rotateVerb(t, dest, name, "not the session passphrase", ccNew); strings.HasPrefix(got, "OK") {
		t.Fatalf("ROTATE replied %q, want a refusal", got)
	}
	ccNoRecord(t, dest)
	// The positive control: the right passphrase does write one.
	liveMarker(t, dest, name, ccOld, "10", "")
	if got := rotateVerb(t, dest, name, ccOld, ccNew); got != "OK 0" {
		t.Fatalf("ROTATE replied %q, want OK 0", got)
	}
	ccRecord(t, dest)
}

func TestCredChangeRecover(t *testing.T) {
	t.Run("one owner", func(t *testing.T) {
		const name = "ccrecover1"
		useTempBindings(t)
		useTempInbox(t)
		mn := ccRecoverFixture(t, name)
		v, _ := openVaultHead("s3", name, ccOld)
		if v == nil || v.TelPub == "" {
			t.Fatal("precondition: the vault has no telephony key")
		}
		oldRef := profileRefV2(name, ccOld)
		rbBind(t, oldRef, v.TelPub)
		rbSeal(t, oldRef)
		if got := recoverReply(name, mn, recNewPass); got != "OK" {
			t.Fatalf("recoverReply = %q, want OK", got)
		}
		ccWant(t, "record", ccRecord(t, loginStateDir()), map[string]string{
			"kind": "recover", "path": "committed", "marker": "none", "keyguard": "untouched",
			"matched": "1", "bind": "1", "inbox": "1", "old": refDigest(oldRef),
			"new": refDigest(profileRefV2(name, recNewPass)),
		})
		if err := markRoamSession(loginStateDir(), name, recNewPass, "10", ""); err != nil {
			t.Fatal(err)
		}
		s := ccMerge(t, loginStateDir())
		ccWant(t, "merge", s, map[string]string{
			"cred_change": "recover", "cred_change_marker_now": "matches", "cred_change_sim_matched": "1",
			"cred_change_sim_bindings": "1", "cred_change_sim_inbox": "1", "cred_change_sim_owned_now": "1",
		})
		ccNoSecrets(t, s, ccSecrets(name, ccOld, recNewPass)...)
	})
	t.Run("two owners", func(t *testing.T) {
		const name = "ccrecover2"
		useTempBindings(t)
		useTempInbox(t)
		mn := ccRecoverFixture(t, name)
		v, _ := openVaultHead("s3", name, ccOld)
		if v == nil || v.TelPub == "" {
			t.Fatal("precondition: the vault has no telephony key")
		}
		rbBind(t, profileRefV2(name, ccOld), v.TelPub)
		rbBind(t, "bbbb2222", v.TelPub)
		if got := recoverReply(name, mn, recNewPass); got != "OK" {
			t.Fatalf("recoverReply = %q, want OK", got)
		}
		ccWant(t, "record", ccRecord(t, loginStateDir()), map[string]string{
			"kind": "recover", "matched": "2", "old": "-", "bind": "0", "inbox": "0",
		})
	})
}

func TestCredChangeSessionEnd(t *testing.T) {
	t.Setenv("NOWHERE_STATE", t.TempDir())
	writeCredChange(loginStateDir(), credChangeRec{Kind: "rotate", Path: "committed", Marker: "rekeyed",
		Keyguard: "rekeyed", Matched: -1, New: refDigest("ccsessend-new"), Old: refDigest("ccsessend-old")})
	ccRecord(t, loginStateDir())
	forgetSessionKeys("test")
	ccNoRecord(t, loginStateDir())

	// The CLI `recover` calls recoverVault directly: not the daemon, so no record.
	const name = "ccsessend"
	useTempBindings(t)
	useTempInbox(t)
	mn := ccRecoverFixture(t, name)
	if err := recoverVault("s3", name, mn, recNewPass); err != nil {
		t.Fatal(err)
	}
	ccNoRecord(t, loginStateDir())
	takeRecoverCarry()
}

func TestCredChangeScope(t *testing.T) {
	const name, pass = "ccscope", "pw-ccscope"
	dest := t.TempDir()
	ref := profileRefV2(name, pass)
	mine := credChangeRec{Kind: "rotate", Path: "committed", Marker: "rekeyed", Keyguard: "rekeyed",
		Bind: 1, Inbox: 1, Matched: -1, New: refDigest(ref), Old: refDigest(profileRefV2(name, "an older one"))}

	// (a) device scope adds nothing, even over a matching record and marker.
	writeCredChange(dest, mine)
	if err := markRoamSession(dest, name, pass, "10", ""); err != nil {
		t.Fatal(err)
	}
	if got := ccMerge(t, dest)["cred_change_marker_now"]; got != "matches" {
		t.Fatalf("precondition: session-scope merge gave marker_now %q, want matches", got)
	}
	s := map[string]string{}
	mergeCredChange(s, dest, true)
	if k := ccKeys(s); len(k) != 0 {
		t.Errorf("device scope added %v", k)
	}

	// (b) no marker: nothing.
	nomark := t.TempDir()
	writeCredChange(nomark, mine)
	if k := ccKeys(ccMerge(t, nomark)); len(k) != 0 {
		t.Errorf("no marker added %v", k)
	}

	// (c) another profile's record under this profile's marker: nothing.
	other := credChangeRec{Kind: "rotate", Path: "committed", Marker: "rekeyed", Keyguard: "rekeyed", Matched: -1,
		New: refDigest(profileRefV2("ccscopeother", "pw-new")), Old: refDigest(profileRefV2("ccscopeother", "pw-old"))}
	writeCredChange(dest, other)
	if k := ccKeys(ccMerge(t, dest)); len(k) != 0 {
		t.Errorf("another profile's record added %v", k)
	}

	// (d) a caller-sent key never survives, in any scope.
	empty := t.TempDir()
	s = map[string]string{"cred_change_marker": "forged", "other": "kept"}
	mergeCredChange(s, empty, true)
	if _, ok := s["cred_change_marker"]; ok || s["other"] != "kept" {
		t.Errorf("after the merge: %v, want the forged key gone and the rest kept", s)
	}

	// (e) a malformed or oversize record: cred_change=unreadable alone.
	for _, body := range []string{"v=1 kind=rotate garbage\n", strings.Repeat("x", 600)} {
		bad := t.TempDir()
		if err := markRoamSession(bad, name, pass, "10", ""); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(bad, credChangeFile), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if k := ccKeys(ccMerge(t, bad)); len(k) != 1 || k["cred_change"] != "unreadable" {
			t.Errorf("a %d-byte bad record gave %v, want cred_change=unreadable alone", len(body), k)
		}
	}

	// (f) through the real handler: session scope speaks, gate scope does not, a forged key is replaced.
	dest = rcSetup(t, name, "10")
	writeCredChange(dest, mine)
	rep := rcPreview(t, dest, `{"preview":true,"status":{"cred_change_marker":"forged"}}`)
	ccWant(t, "report", rep.Status, map[string]string{
		"cred_change": "rotate", "cred_change_marker": "rekeyed", "cred_change_marker_now": "matches",
	})
	ccNoSecrets(t, rep.Status, name, pass, ref, refDigest(ref), mine.Old)
	rep = rcPreview(t, dest, `{"preview":true,"gate":true,"status":{"cred_change_marker":"forged"}}`)
	if k := ccKeys(rep.Status); len(k) != 0 {
		t.Errorf("gate scope report carries %v", k)
	}
}
