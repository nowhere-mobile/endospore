package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// newHTTPStore stands up a tiny content-addressed store speaking the shape the non-s3 code path uses:
// POST /blob (-> sha256 key), GET /blob/<key>, GET|PUT /ref/<ref>. A tombstoned ref serves 200 + "" (so
// getRef reads back ""), mirroring delRef's overwrite-to-empty. Returns the base URL.
func newHTTPStore(t *testing.T) string {
	t.Helper()
	var mu sync.Mutex
	blobs := map[string][]byte{}
	refs := map[string]string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch {
		case r.Method == "POST" && r.URL.Path == "/blob":
			body, _ := io.ReadAll(r.Body)
			h := sha256.Sum256(body)
			key := hex.EncodeToString(h[:])
			blobs[key] = body
			io.WriteString(w, key)
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/blob/"):
			if b, ok := blobs[strings.TrimPrefix(r.URL.Path, "/blob/")]; ok {
				w.Write(b)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/ref/"):
			body, _ := io.ReadAll(r.Body)
			refs[strings.TrimPrefix(r.URL.Path, "/ref/")] = string(body)
		case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/ref/"):
			delete(refs, strings.TrimPrefix(r.URL.Path, "/ref/")) // HARD-remove (not tombstone) -> simulates a LOST head
		case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/ref/"):
			if v, ok := refs[strings.TrimPrefix(r.URL.Path, "/ref/")]; ok {
				io.WriteString(w, v) // a tombstone is "" -> getRef reads ""
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { capBracketLeakCheck(t) }) // NWP-20261009-07: fail on a leaked bracket, never hang on it
	return srv.URL
}

// deleteProfile is the shared primitive behind the `delete-profile` CLI verb and the daemon DELETE verb.
// Security property: it removes a profile's head AND recovery refs ONLY when (name,pass) resolves, so a
// WRONG passphrase deletes nothing.
func TestDeleteProfileWrongPassIsNoop(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "alice", "correct horse battery"
	createVault(base, name, pass) // seeds the head ref + the recovery ref -> the vault blob

	head := getRef(base, headKey(base, name, pass))
	if head == "" {
		t.Fatal("setup: profile should resolve right after createVault")
	}
	v, isV := parseVault(getBlob(base, head))
	if !isV || v.RecoveryRef == "" {
		t.Fatal("setup: expected a vault head with a recovery ref")
	}

	// A wrong passphrase must NOT delete anything.
	if got := deleteProfile(base, name, "wrong-pass"); got != "notfound" {
		t.Fatalf("wrong passphrase: got %q, want \"notfound\"", got)
	}
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("a wrong passphrase wiped the head ref")
	}
	if getRef(base, v.RecoveryRef) == "" {
		t.Fatal("a wrong passphrase wiped the recovery ref")
	}

	// The right passphrase deletes both the head and the recovery refs.
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("correct passphrase: got %q, want \"deleted\"", got)
	}
	if getRef(base, headKey(base, name, pass)) != "" {
		t.Fatal("head ref still resolves after delete")
	}
	if getRef(base, v.RecoveryRef) != "" {
		t.Fatal("recovery ref still resolves after delete (recovery path not killed)")
	}

	// A second delete finds the tombstone and reports "gone" (it re-purges any scope leftovers -- #139's
	// pre-fix deletes left them behind -- but never claims a fresh delete).
	if got := deleteProfile(base, name, pass); got != "gone" {
		t.Fatalf("second delete: got %q, want \"gone\"", got)
	}
}

// #139: a delete must purge EVERY scope ref (v2 + legacy), not just the bare head -- the old delete left
// #de/#media/#sys/... in the store and a re-login resurrected the profile with its data (live on odtest,
// 2026-08-14). Also locks the wrong-pass no-op for scopes and the "gone" re-purge.
func TestDeleteProfilePurgesAllScopes(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "frank", "purge horse battery staple"
	createVault(base, name, pass)

	// Seed scope heads as a lived-in profile would have them (v2 for all, plus one legacy leftover).
	for _, s := range []string{"#de", "#media", "#sys", "#apps", "#keys", "#wallet"} {
		putRef(base, profileRefV2(name+s, pass), "head-"+s)
	}
	putRef(base, profileRefLegacy(name+"#de", pass), "legacy-de")

	// A wrong passphrase touches NONE of them.
	if got := deleteProfile(base, name, "wrong-pass"); got != "notfound" {
		t.Fatalf("wrong passphrase: got %q, want \"notfound\"", got)
	}
	if getRef(base, profileRefV2(name+"#de", pass)) == "" {
		t.Fatal("a wrong passphrase wiped a scope ref")
	}

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q, want \"deleted\"", got)
	}
	for _, s := range deleteScopeSuffixes {
		if got := getRef(base, profileRefV2(name+s, pass)); got != "" {
			t.Fatalf("scope %q v2 ref still resolves after delete: %q", s, got)
		}
		if got := getRef(base, profileRefLegacy(name+s, pass)); got != "" {
			t.Fatalf("scope %q legacy ref still resolves after delete: %q", s, got)
		}
	}
	// The purged scope refs are TOMBSTONES (exist empty), not hard-removed -- same rationale as the head.
	if !refExists(base, profileRefV2(name+"#de", pass)) {
		t.Fatal("a purged scope ref should be a tombstone (exists empty), not hard-removed")
	}

	// Re-delete: "gone", and still nothing resolves.
	if got := deleteProfile(base, name, pass); got != "gone" {
		t.Fatalf("re-delete: got %q, want \"gone\"", got)
	}
}

// #142: recreating a name whose delete was INTERRUPTED mid-purge (bare head tombstoned, scope refs still
// live -- crash / power-off / ERR-STORE) must not inherit the old data. createVault purges the leftovers
// before writing the new head; without that, the new head clears the tombstone, the #687 restore guard goes
// blind, and the old #de/#media come back live under a profile the user believes is brand new.
func TestCreateVaultPurgesInterruptedDeleteLeftovers(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "heidi", "recreate horse battery staple"
	createVault(base, name, pass)
	for _, s := range []string{"#de", "#media", "#apps"} {
		putRef(base, profileRefV2(name+s, pass), "old-head-"+s)
	}

	// Simulate the interrupted delete: the bare head is tombstoned (delete got that far) but the scope
	// purge never ran. This is exactly the state #687's heal cannot repair once a new head exists.
	delRef(base, profileRefV2(name, pass), "", nil)
	if !profileDeleted(base, name, pass) {
		t.Fatal("setup: the bare head should read as a delete tombstone")
	}
	if getRef(base, profileRefV2(name+"#de", pass)) == "" {
		t.Fatal("setup: the #de leftover should still be live")
	}

	createVault(base, name, pass) // recreate the same name+passphrase

	for _, s := range []string{"#de", "#media", "#apps"} {
		if got := getRef(base, profileRefV2(name+s, pass)); got != "" {
			t.Fatalf("scope %q survived the recreate (old data would restore): %q", s, got)
		}
	}
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("the recreated profile must resolve (the purge must not eat the new head)")
	}
	if profileDeleted(base, name, pass) {
		t.Fatal("the recreated profile must NOT read as deleted")
	}
}

// #139 defense in depth: profileDeleted gates scope restores. It is true ONLY for an explicit delete
// tombstone on the BARE head -- an absent-everywhere name (throwaway / wrong pass) stays false, so blind
// login behaves exactly as before.
func TestProfileDeletedGuard(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "grace", "guard horse battery staple"

	if profileDeleted(base, name, pass) || profileDeleted(base, name+"#de", pass) {
		t.Fatal("a never-created name must not read as deleted")
	}
	createVault(base, name, pass)
	if profileDeleted(base, name+"#de", pass) {
		t.Fatal("a LIVE profile must not read as deleted")
	}
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q, want \"deleted\"", got)
	}
	if !profileDeleted(base, name, pass) || !profileDeleted(base, name+"#de", pass) {
		t.Fatal("a tombstoned profile must read as deleted for the bare name AND its scopes")
	}
	if profileDeleted(base, name, "wrong-pass") {
		t.Fatal("wrong-pass creds must not read as deleted (they resolve nothing)")
	}
}

// The real-world bug: a deleted profile that is a LIVE roamed session gets sealed by the continuous syncLoop,
// and the seal (push) used to RE-CREATE the tombstoned head -> the profile could log in again. pushProfile
// must NOT resurrect a deleted bare (gate) profile, while still lazy-creating the "#de"/"#media" data refs.
func TestSealDoesNotResurrectDeletedProfile(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "bob", "hunter2 horse battery"
	createVault(base, name, pass)
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("setup: profile should resolve")
	}

	// A normal seal of a LIVE profile updates it in place (head stays resolvable).
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("a seal of a live profile must keep it resolvable")
	}

	// Delete it, then seal again (as the live syncLoop would): the seal must NOT bring it back.
	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q, want \"deleted\"", got)
	}
	if getRef(base, headKey(base, name, pass)) != "" {
		t.Fatal("head should be tombstoned right after delete")
	}
	pushProfile(base, name, pass, src) // a post-delete seal (the bug: this used to resurrect the head)
	if got := getRef(base, headKey(base, name, pass)); got != "" {
		t.Fatalf("seal RESURRECTED a deleted profile: head=%q, want empty", got)
	}

	// ⚠ THIS ASSERTION USED TO PIN THE BUG. It read "the #de/#media data refs are EXEMPT -- they
	// legitimately lazy-create on their first seal" and called pushProfile on a scope of a profile that had
	// just been DELETED, requiring the ref to appear. That exemption IS the resurrection: NWP-20260912-10
	// proved on husky + lynx that a second handset re-creates #de/#media/#sys after the other deletes, so a
	// profile reads deleted while its data stays in the store, unreachable by anyone including its owner.
	// Lazy-create is legitimate on a LIVE profile, which is what the next test asserts -- not on a deleted one.
	pushProfile(base, name+"#media", pass, src)
	if got := getRef(base, headKey(base, name+"#media", pass)); got != "" {
		t.Fatalf("a scope seal RESURRECTED a deleted profile: %s#media=%q, want empty", name, got)
	}
}

// The other direction, so the guard above cannot be "fixed" by refusing everything: on a LIVE profile a
// scope ref MUST still lazy-create on its first seal. This is the behaviour the old, wrongly-placed
// assertion was reaching for -- it just tested it against a deleted profile.
func TestScopeSealLazyCreatesOnLiveProfile(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "gina", "live horse battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("live"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#media", pass, src)
	if getRef(base, headKey(base, name+"#media", pass)) == "" {
		t.Fatal("a #media data ref must lazy-create on its first seal for a LIVE profile")
	}
}

// NWP-20260912-10, the cross-device case this guard exists for, with NO publish fence involved -- which is
// what makes it the OTHER handset. The fence lives in $NOWHERE_STATE/seal-fence, a per-device tmpfs, so the
// handset that did not perform the delete has no marker and its scope seals used to sail straight through.
// Here the delete and the seal share a process, so to model the second handset honestly the fence is
// CLEARED before the scope seal: what is left is exactly what lynx had -- the store, and nothing else.
func TestScopeSealSkipsWhenBareHeadIsTombstonedElsewhere(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "hana", "other handset battery staple"
	createVault(base, name, pass)

	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("data"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name+"#de", pass, src)
	if getRef(base, headKey(base, name+"#de", pass)) == "" {
		t.Fatal("setup: #de should exist before the delete")
	}

	if got := deleteProfile(base, name, pass); got != "deleted" {
		t.Fatalf("delete: got %q, want \"deleted\"", got)
	}
	// Become the OTHER handset: no fence marker, only what the store says.
	t.Setenv("NOWHERE_STATE", t.TempDir())

	pushProfile(base, name+"#de", pass, src)
	if got := getRef(base, headKey(base, name+"#de", pass)); got != "" {
		t.Fatalf("the second handset RESURRECTED a deleted profile’s #de: %q, want empty", got)
	}
	// ⚠⚠ AND IT MUST **NOT** SET sealRefused. This assertion is inverted from what it was, and a device
	// proved why: the first cut set it, the LOGOFF seal then reported
	//     OUT <profile> ERR-REFUSED PARTIAL:de=refused,media=refused,sys=refused
	// and logind correctly refused to reap a session it could not save -- so the handset could not sign
	// out, permanently, because a deleted profile’s bare head is a tombstone forever. Not writing here is
	// the CORRECT OUTCOME, not a failure: the profile is gone, so there is nothing to save. The bare guard
	// reaches the same conclusion for the same situation and returns clean.
	if sealRefused {
		t.Fatal("a deleted profile must not WEDGE the sign-out: skipping the write is the correct outcome, " +
			"not a seal failure, and a refusal here can never succeed on a retry (NWP-20260912-07)")
	}
}

// The flip side of the no-resurrect guard (#19, DIA-20260624-05): a LOST head -- the ref OBJECT is gone
// (churn / corruption / partial state), NOT tombstoned -- on a LIVE session must RECOVER on the next seal,
// not be skipped forever. The distinction is tombstone (delRef leaves an empty object that EXISTS) vs an
// ABSENT ref (not-found). A deleted profile is always tombstoned AND reaped (no live session), so this can
// never resurrect a delete.
func TestSealRecoversLostHead(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "dave", "lost horse battery staple"
	createVault(base, name, pass)
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("setup: profile should resolve right after createVault")
	}

	// Simulate a LOST head: HARD-remove the ref object (404/not-found), distinct from a delete tombstone
	// (which leaves an empty object that EXISTS). The "#de"/"#media" data refs survive (as for t/t1234).
	req, _ := http.NewRequest(http.MethodDelete, base+"/ref/"+headKey(base, name, pass), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if refExists(base, headKey(base, name, pass)) {
		t.Fatal("setup: a LOST head must read as ABSENT (not a tombstone)")
	}
	if getRef(base, headKey(base, name, pass)) != "" {
		t.Fatal("setup: a lost head should resolve empty")
	}

	// A live session seals -> the lost head RECOVERS (re-created + resolvable), unlike a tombstoned delete.
	src := t.TempDir()
	if err := os.WriteFile(filepath.Join(src, "f"), []byte("recovered"), 0o600); err != nil {
		t.Fatal(err)
	}
	pushProfile(base, name, pass, src)
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("a LOST head was NOT recovered by the live-session seal (#19 regression)")
	}

	// And a DELETE tombstone still does NOT recover (the safety property is preserved). Re-create, delete,
	// seal -> stays gone.
	name2, pass2 := "erin", "deleted horse battery staple"
	createVault(base, name2, pass2)
	if got := deleteProfile(base, name2, pass2); got != "deleted" {
		t.Fatalf("delete: got %q, want \"deleted\"", got)
	}
	pushProfile(base, name2, pass2, src)
	if getRef(base, headKey(base, name2, pass2)) != "" {
		t.Fatal("a tombstoned (deleted) profile must STAY gone after a seal")
	}
}

// deleteForSession backs the daemon DELETE verb. A "Delete this profile" on a session NOT backed by a stored
// profile -- a throwaway blind login, or a profile already deleted (re-entered via a stale-read login) -- is a
// no-op that carries on to the reap, NOT a "wrong passphrase" error. But a session WITH a real profile and a
// WRONG confirm passphrase must still fail (never silently no-op, or a mistyped confirm would "delete" a
// profile that survives -- the DIA-50 guard). (DIA-20260617-04)
func TestDeleteForSession(t *testing.T) {
	base := newHTTPStore(t)
	name, pass := "carol", "correct horse battery"
	createVault(base, name, pass)

	// Real profile + WRONG confirm passphrase (the LOGIN creds are correct) -> "wrongpass", nothing deleted.
	if got := deleteForSession(base, name, "wrong-pass", name, pass, nil); got != "wrongpass" {
		t.Fatalf("real profile + wrong confirm: got %q, want \"wrongpass\"", got)
	}
	if getRef(base, headKey(base, name, pass)) == "" {
		t.Fatal("a wrong confirm passphrase deleted the profile")
	}

	// Real profile + CORRECT confirm passphrase -> "deleted".
	if got := deleteForSession(base, name, pass, name, pass, nil); got != "deleted" {
		t.Fatalf("real profile + correct confirm: got %q, want \"deleted\"", got)
	}
	if getRef(base, headKey(base, name, pass)) != "" {
		t.Fatal("head still resolves after a successful delete")
	}

	// The profile is now GONE: re-deleting the SAME still-logged-in session (login creds == typed, but the
	// head is a tombstone) -> "gone" (purge leftovers + carry on), NOT "wrongpass". This is the stale-head
	// re-login case that used to surface a misleading "couldn't delete -- check your passphrase".
	if got := deleteForSession(base, name, pass, name, pass, nil); got != "gone" {
		t.Fatalf("already-deleted session: got %q, want \"gone\"", got)
	}

	// A genuine throwaway session (no login creds recorded at all) -> "noop".
	if got := deleteForSession(base, "ghost", "whatever", "", "", nil); got != "noop" {
		t.Fatalf("throwaway session: got %q, want \"noop\"", got)
	}
}
