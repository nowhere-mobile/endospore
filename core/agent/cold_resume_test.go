package main

import (
	"bufio"
	"encoding/hex"
	"go/ast"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"
)

// NWP-20260924-01: a cold-lock resume must prove its entry INDEPENDENTLY of the CE.
//
// The defect, read from the code: roamd's verify op took `ls /data/user/N/android` as its ground truth, and ANY
// entry passes that while the CE is still readable -- the window before eviction, and indefinitely under
// EVICT-INCOMPLETE, which the maintainer's own phone hit twice in one evening. handleResume then made the wrong
// entry the session's passphrase, and the next seal published the owner's data as a NEW profile at (name, entry):
// restorable by whoever typed it, on any Nowhere device, with the name the gate had just shown them.
//
// These tests drive the REAL handleResume against a marker built by the REAL teardown (through the clw harness in
// coldlock_wait_order_test.go), with a fake roamd answering the RW lane's request file. "openAny" is the PRE-FIX
// roamd on a readable CE -- verify says OK to everything -- which is exactly the state the agent must survive.

const crPass = "hunter2-correct" // long and distinctive, so "the log never names it" means something

type crKind struct {
	name  string
	pin   string // "" = no PIN
	keyed bool
	se    string // hex; "" = none
	local bool
	// noSpec: a keyed session whose slot stash is empty at the lock, so the marker's line 7 is empty (NWP-20261017-03).
	// Every other keyed kind is locked with crSlotSpec, as a real keyed login stages one.
	noSpec bool
}

// crSlotSpec is a well-formed, non-secret slot spec (credId:salt:uv) for the marker's line 7.
const crSlotSpec = "Y3JlZC0x:c2FsdC0x:0"

var crKinds = []crKind{
	{name: "plain"},
	{name: "pin", pin: "4821"},
	{name: "pin+key", pin: "4821", keyed: true},
	{name: "key-nopin", keyed: true},
	{name: "se", se: strings.Repeat("5e", 32)},
	{name: "local", local: true},
}

type crLocked struct {
	dest     string
	keyguard string // what the teardown armed on the keyguard (armcred's new value, or rekey's derived one)
	h1       string // the owner's key hmac, hex; "" for a keyless session
	marker   []byte
	unlock   string // what the owner types: the PIN, else the passphrase
}

// crLock cold-locks a session of the given shape through the real teardown and returns what a resume faces.
func crLock(t *testing.T, k crKind) crLocked {
	t.Helper()
	dest, rec, _ := clwSetup(t)
	t.Cleanup(crReset)
	if err := markRoamSession(dest, "alice", crPass, "10", k.se); err != nil {
		t.Fatal(err)
	}
	if k.local {
		markLocalSession(dest)
	}
	if k.pin != "" {
		stashSessionPIN(dest, k.pin)
	}
	h1 := ""
	if k.keyed {
		clwFido2(t, dest)
		if !k.noSpec {
			if err := os.WriteFile(filepath.Join(dest, ".fido2slots"), []byte(crSlotSpec), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		b, err := os.ReadFile(filepath.Join(dest, ".fido2hmac"))
		if err != nil {
			t.Fatal(err)
		}
		h1 = strings.TrimSpace(string(b))
	}
	clwLock(t, dest, 0)
	if !clwWaitFor(3*time.Second, func() bool { return !coldLockInFlight() }) {
		t.Fatal("the cold lock never completed")
	}
	kg := ""
	for _, c := range rec.snapshot() {
		if c.op == "armcred" {
			kg = c.pass
		} else if c.op == "rekey" {
			kg = c.seSecret
		}
	}
	if k.keyed && clwExists(dest, ".fido2hmac") {
		t.Fatal("control failed: the cold-lock commit did not purge .fido2hmac, so a refusal's purge proves nothing")
	}
	marker, err := os.ReadFile(filepath.Join(dest, ".coldlock"))
	if err != nil || kg == "" {
		t.Fatalf("control failed: no marker (%v) or no keyguard credential captured (%q)", err, kg)
	}
	unlock := crPass
	if k.pin != "" {
		unlock = k.pin
	}
	return crLocked{dest: dest, keyguard: kg, h1: h1, marker: marker, unlock: unlock}
}

// crReset clears the process state a resume touches, so no test inherits another's.
func crReset() {
	// Reset the cache directly rather than through deriveKeyForget: this file must also COMPILE against the pre-fix
	// code, where it is run red to prove it reproduces the defect.
	deriveKeyMu.Lock()
	deriveKeyCache = map[string][]byte{}
	deriveKeyMu.Unlock()
	pendingReapMu.Lock()
	loginSettleUntil, loginWindowAt, loginDeferred = time.Time{}, time.Time{}, 0
	pendingSwitchUID, pendingLockUID, pendingReapUID = "", "", ""
	pendingReapMu.Unlock()
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
}

type crOp struct {
	op          string
	pass        string
	misses      int    // deriveKeyMisses at the instant the request was read
	se          string // line 5 of the request: for a rekey, the NEW credential
	coldlock    bool   // .coldlock existed when the request was read
	entryCached bool   // the KDF cache held a key for the typed entry when the request was read
	raw         string // the whole request file, every line
}

// crFake answers the RW lane's request file the way roamd would, from a script the test controls.
type crFake struct {
	mu        sync.Mutex
	ops       []crOp
	mode      string // "openAny": verify says OK to anything (a readable CE today); "keyguard": only to keyguard
	keyguard  string
	hmacHex   string // what the fido2hmac op finds in the port; "" = no key (ERR-NOKEY)
	verifyOut string // overrides verify's reply when set
	entry     string // the typed entry, so the fake can see whether it ever entered the KDF cache
	clearOut  string // overrides resumeclear's reply when set
}

func (f *crFake) opsNamed(op string) []crOp {
	var out []crOp
	for _, o := range f.snapshot() {
		if o.op == op {
			out = append(out, o)
		}
	}
	return out
}

func (f *crFake) snapshot() []crOp {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]crOp(nil), f.ops...)
}

func (f *crFake) verifies() []crOp {
	var out []crOp
	for _, o := range f.snapshot() {
		if o.op == "verify" {
			out = append(out, o)
		}
	}
	return out
}

func crStartFake(t *testing.T, dest string, f *crFake) {
	t.Helper()
	stop, done := make(chan struct{}), make(chan struct{})
	// Both lanes a resume can use: RW (verify, fido2hmac, resumeclear, btresume) and Cred (the rekey back).
	lanes := [][2]string{{filepath.Join(dest, laneRW.req), filepath.Join(dest, laneRW.res)},
		{filepath.Join(dest, laneCred.req), filepath.Join(dest, laneCred.res)}}
	go func() {
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			var b []byte
			var req, res string
			for _, l := range lanes {
				if x, err := os.ReadFile(l[0]); err == nil && len(x) > 0 {
					b, req, res = x, l[0], l[1]
					break
				}
			}
			if b == nil {
				time.Sleep(5 * time.Millisecond)
				continue
			}
			os.Remove(req)
			ln := strings.Split(string(b), "\n")
			for len(ln) < 5 {
				ln = append(ln, "")
			}
			f.mu.Lock()
			mode, kg, hx, vo, entry, co := f.mode, f.keyguard, f.hmacHex, f.verifyOut, f.entry, f.clearOut
			f.mu.Unlock()
			deriveKeyMu.Lock()
			m := deriveKeyMisses
			cached := false
			for ck := range deriveKeyCache {
				if entry != "" && strings.HasSuffix(ck, "\x00"+entry) {
					cached = true
				}
			}
			deriveKeyMu.Unlock()
			f.mu.Lock()
			f.ops = append(f.ops, crOp{op: ln[0], pass: ln[2], se: ln[4], misses: m, coldlock: clwExists(dest, ".coldlock"),
				entryCached: cached, raw: string(b)})
			f.mu.Unlock()
			out := "OK"
			switch ln[0] {
			case "verify":
				if vo != "" {
					out = vo
				} else if mode == "keyguard" && ln[2] != kg {
					out = "FAIL"
				}
			case "resumeclear":
				if co != "" {
					out = co
				} else if mode == "keyguard" && ln[2] != kg {
					out = "FAIL"
				}
			case "fido2hmac":
				if hx == "" {
					out = "ERR-NOKEY"
				} else {
					os.WriteFile(filepath.Join(dest, ".fido2hmac"), []byte(hx+"\n"), 0o600)
				}
			}
			tmp := res + ".tmp"
			os.WriteFile(tmp, []byte(out+"\n"), 0o600)
			os.Rename(tmp, res)
		}
	}()
	t.Cleanup(func() { close(stop); <-done })
}

// crResume sends RESUME exactly as the dispatcher would and returns the reply.
func crResume(t *testing.T, dest, entry string) string {
	t.Helper()
	server, client := net.Pipe()
	got := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(client).ReadString('\n')
		got <- strings.TrimRight(line, "\r\n")
	}()
	handleResume(server, dest, entry)
	server.Close()
	r := <-got
	client.Close()
	return r
}

var crDecoy = regexp.MustCompile(`^[0-9]{16}$`)

// crAssertUntouched: a refused resume leaves the cold lock exactly as it found it.
func crAssertUntouched(t *testing.T, l crLocked) {
	t.Helper()
	if b, _ := os.ReadFile(filepath.Join(l.dest, ".coldlock")); string(b) != string(l.marker) {
		t.Error(".coldlock changed on a refused resume")
	}
	if clwExists(l.dest, ".roamsession") {
		t.Error(".roamsession was written on a refused resume -- the entry became the seal passphrase")
	}
	if clwExists(l.dest, ".sessionpin") {
		t.Error(".sessionpin was written on a refused resume")
	}
	if sw, lk := clwFlags(); sw != "10" || lk != "10" {
		t.Errorf("flags = %q/%q, want 10/10 -- a refused resume cancelled the lock", sw, lk)
	}
	// #81: a cold device holds no key material, and a refusal must not leave any behind either.
	if clwExists(l.dest, ".fido2hmac") || os.Getenv("NOWHERE_FIDO2_HMAC") != "" {
		t.Error("a refused resume left the key hmac behind (#81)")
	}
}

// R1. THE DISCLOSURE. A wrong entry is refused even when the worker says OK -- i.e. on a CE that is still
// readable -- for every session shape, and the wrong entry never reaches the keyguard: a random decoy goes instead.
func TestColdResumeWrongEntryRefusedEvenWhenTheWorkerSaysOK(t *testing.T) {
	for _, k := range crKinds {
		t.Run(k.name, func(t *testing.T) {
			l := crLock(t, k)
			f := &crFake{mode: "openAny", hmacHex: l.h1}
			crStartFake(t, l.dest, f)
			wrong := "0000"
			if k.pin == "" {
				wrong = "not-the-passphrase"
			}
			if got := crResume(t, l.dest, wrong); got != "WRONGPASS" {
				t.Fatalf("a WRONG entry resumed (%q) on a readable CE: the next seal would publish the owner's data "+
					"as a new profile under %q", got, wrong)
			}
			crAssertUntouched(t, l)
			if n := len(f.opsNamed("resumeclear")); n != 0 {
				t.Errorf("the keyguard credential was cleared %d time(s) on a refused resume", n)
			}
			vs := f.verifies()
			if len(vs) != 1 {
				t.Fatalf("verify ran %d times, want exactly 1: every attempt must cost one keyguard evaluation", len(vs))
			}
			if !crDecoy.MatchString(vs[0].pass) || vs[0].pass == wrong {
				t.Errorf("the keyguard was sent %q, want a 16-digit decoy -- never the unproven entry", vs[0].pass)
			}
			if l.h1 != "" {
				h, _ := hex.DecodeString(l.h1)
				if vs[0].pass == coldCredPIN("alice", wrong, h) {
					t.Error("the keyguard was sent the credential derived from the wrong entry, not a decoy")
				}
			}
		})
	}
}

// R2. A keyed resume adopts ONLY a resume-scoped key assertion. .fido2hmac.pre is the login's: a fresh-login
// assert made with the TYPIST's own profile and key must not satisfy a keyed resume of somebody else's session.
func TestColdResumeIgnoresALoginNFCStash(t *testing.T) {
	l := crLock(t, crKind{name: "pin+key", pin: "4821", keyed: true})
	f := &crFake{mode: "openAny"} // no key in the port
	crStartFake(t, l.dest, f)
	typist := strings.Repeat("ab", fido2HMACLen)
	if err := os.WriteFile(filepath.Join(l.dest, ".fido2hmac.pre"), []byte(typist), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := crResume(t, l.dest, "0000"); got != "NEEDKEY" {
		t.Fatalf("resume replied %q, want NEEDKEY: a login-time key assertion satisfied a keyed resume", got)
	}
	if clwExists(l.dest, ".roamsession") {
		t.Error(".roamsession was written")
	}
	if !clwExists(l.dest, ".fido2hmac.pre") {
		t.Error(".fido2hmac.pre was consumed -- it belongs to the login `in` op, not the resume")
	}
}

// R3. The PIN is never made the passphrase. Before the fix a failed unwrap FELL BACK to the entry. Here the wrap
// is sealed under PIN 1111 while the keyguard accepts 2222 -- a divergence the fix makes unreachable, since
// .sessionpin is now written only at proven points -- and the entry is 2222.
func TestColdResumeNeverMakesThePINThePassphrase(t *testing.T) {
	l := crLock(t, crKind{name: "pin", pin: "1111"})
	f := &crFake{mode: "keyguard", keyguard: "2222"}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, "2222"); got != "WRONGPASS" {
		name, pass, _ := readRoamSession(l.dest)
		t.Fatalf("resume replied %q and re-marked the session as (%q, %q): an entry that does not open the marker "+
			"became the seal passphrase", got, name, pass)
	}
	crAssertUntouched(t, l)
}

// R4. A marker with no proof -- only an older agent within this boot can write one -- is refused before any
// worker op runs.
func TestColdResumeRefusesAMarkerWithoutAProof(t *testing.T) {
	dest, _, _ := clwSetup(t)
	t.Cleanup(crReset)
	marker := []byte("alice\n10\n\nnokey\nnopin\n\n\n")
	if err := os.WriteFile(filepath.Join(dest, ".coldlock"), marker, 0o600); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(dest, ".roamsession"))
	f := &crFake{mode: "openAny"}
	crStartFake(t, dest, f)
	if got := crResume(t, dest, crPass); got != "WRONGPASS" {
		t.Fatalf("a proofless marker resumed (%q)", got)
	}
	if ops := f.snapshot(); len(ops) != 0 {
		t.Errorf("worker ops ran for a proofless marker: %v", ops)
	}
	if b, _ := os.ReadFile(filepath.Join(dest, ".coldlock")); string(b) != string(marker) {
		t.Error("the marker changed")
	}
}

// R5. Every attempt spends exactly one UNCACHED Argon2 before the keyguard sees anything, right entry or wrong, cache
// warm or cold -- so a warm cache cannot make a right entry faster than a wrong one -- and the typed secret never
// enters the cache. The COLD run is what catches a second, cached derivation on the proven path (the pre-fix
// coldCredPIN(name, entry, h)): with the cache warm it is free, with it cold it is a second miss.
func TestColdResumeSpendsOneUncachedArgon2BeforeVerify(t *testing.T) {
	for _, warm := range []bool{true, false} {
		for _, tc := range []struct{ name, entry string }{{"right", crPass}, {"wrong", "not-the-passphrase"}} {
			name := tc.name + "/cold-cache"
			if warm {
				name = tc.name + "/warm-cache"
			}
			t.Run(name, func(t *testing.T) {
				l := crLock(t, crKind{name: "key-nopin", keyed: true})
				f := &crFake{mode: "openAny", hmacHex: l.h1, entry: tc.entry}
				crStartFake(t, l.dest, f)
				if warm {
					deriveKey("alice", crPass) // warm the cache with the RIGHT secret
				}
				deriveKeyMu.Lock()
				m0 := deriveKeyMisses
				deriveKeyMu.Unlock()
				crResume(t, l.dest, tc.entry)
				vs := f.verifies()
				if len(vs) != 1 {
					t.Fatalf("verify ran %d times", len(vs))
				}
				if d := vs[0].misses - m0; d != 1 {
					t.Errorf("%d Argon2 computations before the keyguard was asked, want exactly 1 (uncached)", d)
				}
				if !warm && vs[0].entryCached {
					t.Error("the typed entry was in the KDF cache before the keyguard was asked -- a cached derivation ran")
				}
			})
		}
	}
}

// R6. The cold-lock commit leaves no unlock secret in the KDF cache: its KEYS are the plaintext (name, PIN) and
// (name, passphrase), which would undo #81's "a cold device holds no PIN". Seeded the way a live daemon is --
// profileRefV2, the vault KEK and head resolution all derive (name, passphrase) during the session -- and run for
// a PIN and a no-PIN session, so each of the two keys has a case that can fail.
func TestColdLockLeavesNoUnlockSecretInTheKDFCache(t *testing.T) {
	for _, k := range []crKind{{name: "pin", pin: "4821"}, {name: "plain"}} {
		t.Run(k.name, func(t *testing.T) {
			deriveKey("alice", crPass) // the live session's own derivation
			crLock(t, k)
			deriveKeyMu.Lock()
			defer deriveKeyMu.Unlock()
			for ck := range deriveKeyCache {
				if strings.Contains(ck, "4821") || strings.Contains(ck, crPass) {
					t.Errorf("the KDF cache still holds a key for %q after the cold-lock commit", strings.ReplaceAll(ck, "\x00", "/"))
				}
			}
		})
	}
}

// R7. The log never says WHICH attempt opened the marker. During a Gatekeeper timeout the right credential and a
// decoy get the same refusal from the keyguard, and a log line that still told them apart would be the unthrottled
// oracle the decoy exists to prevent -- login.log rides every in-session issue report. So a PROVEN entry refused
// by the keyguard and an UNPROVEN one must leave byte-identical lines, and neither may carry a secret.
func TestColdResumeRefusalLogDoesNotRevealTheProof(t *testing.T) {
	logs := map[string]string{}
	var l crLocked
	for _, tc := range []struct{ name, entry string }{{"proven", "4821"}, {"unproven", "0000"}} {
		t.Run(tc.name, func(t *testing.T) {
			l = crLock(t, crKind{name: "pin+key", pin: "4821", keyed: true})
			f := &crFake{mode: "openAny", verifyOut: "FAIL", hmacHex: l.h1} // a throttled keyguard refuses both
			crStartFake(t, l.dest, f)
			var got string
			out := captureStderr(t, func() { got = crResume(t, l.dest, tc.entry) })
			if got != "WRONGPASS" {
				t.Fatalf("resume replied %q against a refusing keyguard", got)
			}
			crAssertUntouched(t, l)
			for _, ln := range strings.Split(out, "\n") {
				if strings.Contains(ln, "[logind] resume ") {
					logs[tc.name] += ln + "\n"
				}
			}
			h, _ := hex.DecodeString(l.h1)
			wrap := strings.Split(string(l.marker), "\n")[5]
			for label, secret := range map[string]string{"the PIN": "4821", "the passphrase": crPass, "the key hmac": l.h1,
				"the marker's proof": wrap, "the credential": coldCredPIN("alice", "4821", h)} {
				if secret != "" && strings.Contains(out, secret) {
					t.Errorf("the log carries %s", label)
				}
			}
		})
	}
	if logs["proven"] == "" {
		t.Fatal("control failed: no resume log line was captured, so the comparison below proves nothing")
	}
	if logs["proven"] != logs["unproven"] {
		t.Errorf("a refused PROVEN entry and a refused UNPROVEN one logged differently -- the log is an oracle:"+
			"\n proven:   %q\n unproven: %q", logs["proven"], logs["unproven"])
	}
}

// R8. A keyed resume adopts the RESUME-scoped NFC stash, and consumes it whatever the outcome.
func TestColdResumeAdoptsOnlyTheResumeNFCStash(t *testing.T) {
	for _, tc := range []struct {
		name, entry, want string
	}{{"right PIN", "4821", "OK 10"}, {"wrong PIN", "0000", "WRONGPASS"}} {
		t.Run(tc.name, func(t *testing.T) {
			l := crLock(t, crKind{name: "pin+key", pin: "4821", keyed: true})
			f := &crFake{mode: "keyguard", keyguard: l.keyguard} // no key in the port: the NFC stash is the only source
			crStartFake(t, l.dest, f)
			if err := os.WriteFile(filepath.Join(l.dest, ".fido2hmac.resume"), []byte(l.h1), 0o600); err != nil {
				t.Fatal(err)
			}
			if got := crResume(t, l.dest, tc.entry); got != tc.want {
				t.Fatalf("resume replied %q, want %q", got, tc.want)
			}
			if clwExists(l.dest, ".fido2hmac.resume") {
				t.Error(".fido2hmac.resume survived the resume attempt")
			}
			if tc.want == "WRONGPASS" {
				crAssertUntouched(t, l)
			}
			if tc.want == "OK 10" {
				if vs := f.verifies(); len(vs) != 1 || vs[0].pass != l.keyguard {
					t.Errorf("verify saw %v, want exactly the keyguard credential", vs)
				}
			}
		})
	}
}

// R10. An EARLY refusal -- an empty entry, before any key step -- still consumes a resume NFC stash. Left behind,
// the owner's key assertion would let the NEXT attempt skip the tap: 2FA with the key's presence no longer required
// at the moment of the resume. (Found by mutation: R8 could not see this, because the key step consumes the stash
// itself on every path R8 takes.)
func TestColdResumeEarlyRefusalConsumesTheNFCStash(t *testing.T) {
	l := crLock(t, crKind{name: "pin+key", pin: "4821", keyed: true})
	f := &crFake{mode: "openAny"}
	crStartFake(t, l.dest, f)
	if err := os.WriteFile(filepath.Join(l.dest, ".fido2hmac.resume"), []byte(l.h1), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := crResume(t, l.dest, ""); got != "WRONGPASS" {
		t.Fatalf("an empty entry got %q", got)
	}
	if clwExists(l.dest, ".fido2hmac.resume") {
		t.Error("the owner's key assertion survived a refused resume -- the next attempt could adopt it without a tap")
	}
	if ops := f.snapshot(); len(ops) != 0 {
		t.Errorf("worker ops ran for an empty entry: %v", ops)
	}
}

// R9. The key hmac is read only for a KEYED marker. A stray value in the environment on a keyless one used to
// change the credential, so the owner's correct passphrase was refused.
func TestColdResumeIgnoresAStrayHmacOnAKeylessMarker(t *testing.T) {
	l := crLock(t, crKind{name: "plain"})
	f := &crFake{mode: "keyguard", keyguard: l.keyguard}
	crStartFake(t, l.dest, f)
	os.Setenv("NOWHERE_FIDO2_HMAC", strings.Repeat("cd", fido2HMACLen))
	if got := crResume(t, l.dest, crPass); got != "OK 10" {
		t.Fatalf("the owner's correct passphrase was refused (%q) because of a stray hmac on a keyless marker", got)
	}
}

// G1. GUARD: the owner's correct entry still resumes, for every session shape, and the session comes back
// recorded with the passphrase -- never the PIN.
func TestColdResumeCorrectEntryResumes(t *testing.T) {
	for _, k := range crKinds {
		t.Run(k.name, func(t *testing.T) {
			l := crLock(t, k)
			f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1}
			crStartFake(t, l.dest, f)
			if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
				t.Fatalf("the owner's correct entry was refused (%q)", got)
			}
			name, pass, uid := readRoamSession(l.dest)
			if name != "alice" || pass != crPass || uid != "10" {
				t.Errorf(".roamsession = (%q, %q, %q), want (alice, the passphrase, 10)", name, pass, uid)
			}
			if se := readRoamSessionSE(l.dest); se != k.se {
				t.Errorf("the SE secret came back as %q, want %q", se, k.se)
			}
			if got := sessionPIN(l.dest); got != k.pin {
				t.Errorf(".sessionpin = %q, want %q", got, k.pin)
			}
			if vs := f.verifies(); len(vs) != 1 || vs[0].pass != l.keyguard {
				t.Errorf("verify saw %v, want exactly the keyguard credential", vs)
			}
			if clwExists(l.dest, ".coldlock") {
				t.Error(".coldlock survived a successful resume")
			}
			// The credential is cleared exactly once, with the keyguard value, and only AFTER the resume committed:
			// cleared before, a resume that then failed to commit stranded the owner on a credential-less user.
			cs := f.opsNamed("resumeclear")
			if len(cs) != 1 || cs[0].pass != l.keyguard {
				t.Fatalf("resumeclear ran %v, want exactly once with the keyguard credential", cs)
			}
			if cs[0].coldlock {
				t.Error("the keyguard credential was cleared while .coldlock was still parked -- before the resume " +
					"committed, so a failure between the two strands the owner")
			}
		})
	}
}

// G5 (final check). When the post-commit clear is not confirmed on a KEYED session, the keyguard still holds
// coldCredPIN -- 16 hex characters nobody can type. The resume must rekey it back to the entry (proven by then,
// and the unlock secret), the teardown abort's own unwind, or the owner lands on a keyguard they cannot open. A
// keyless session needs no rekey: its credential already is what the owner typed.
func TestColdResumeUnconfirmedClearRekeysAKeyedSessionBack(t *testing.T) {
	for _, k := range []crKind{{name: "pin+key", pin: "4821", keyed: true}, {name: "key-nopin", keyed: true}, {name: "pin", pin: "4821"}} {
		t.Run(k.name, func(t *testing.T) {
			l := crLock(t, k)
			f := &crFake{mode: "keyguard", keyguard: l.keyguard, hmacHex: l.h1, clearOut: "FAIL"}
			crStartFake(t, l.dest, f)
			if got := crResume(t, l.dest, l.unlock); got != "OK 10" {
				t.Fatalf("the owner's correct entry was refused (%q) because the clear was not confirmed", got)
			}
			rks := f.opsNamed("rekey")
			if !k.keyed {
				if len(rks) != 0 {
					t.Errorf("a keyless session was rekeyed after an unconfirmed clear: %v", rks)
				}
				return
			}
			if len(rks) != 1 || rks[0].pass != l.keyguard || rks[0].se != l.unlock {
				t.Fatalf("rekey ops = %v, want one from the cold credential back to the typed entry: the owner would "+
					"land on a keyguard holding 16 hex characters they cannot type", rks)
			}
		})
	}
}

// G2. GUARD: a wrong entry on a COLD CE (the keyguard refuses it) is refused, as it always was.
func TestColdResumeWrongEntryOnAColdCERefused(t *testing.T) {
	l := crLock(t, crKind{name: "pin", pin: "4821"})
	f := &crFake{mode: "keyguard", keyguard: l.keyguard}
	crStartFake(t, l.dest, f)
	if got := crResume(t, l.dest, "0000"); got != "WRONGPASS" {
		t.Fatalf("resume replied %q", got)
	}
	crAssertUntouched(t, l)
}

// G3. GUARD: a PROVEN entry is still refused when the keyguard or the worker does not say OK.
func TestColdResumeProvenEntryNeedsTheKeyguardToo(t *testing.T) {
	for _, out := range []string{"FAIL", "ERR-UID", "ERR-TIMEOUT"} {
		t.Run(out, func(t *testing.T) {
			l := crLock(t, crKind{name: "plain"})
			f := &crFake{mode: "openAny", verifyOut: out}
			crStartFake(t, l.dest, f)
			if got := crResume(t, l.dest, crPass); got != "WRONGPASS" {
				t.Fatalf("a proven entry resumed (%q) although the worker replied %s", got, out)
			}
			crAssertUntouched(t, l)
		})
	}
}

// G4. GUARD: the functions that can write a passphrase into .roamsession are exactly the known set. Each of them
// is a place an unverified secret could become the seal passphrase -- the shape this slice closed in
// handleResume -- so a new one must be reviewed for it, not slip in unnoticed. With a control: handleResume
// must be found, or the walk proves nothing.
func TestRoamSessionPassWritersAreEnumerated(t *testing.T) {
	// EVERY non-test file in the package, not main.go alone (P0 slice review): a writer added anywhere must show up.
	fset := token.NewFileSet()
	ents, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read the package dir: %v", err)
	}
	var decls []ast.Decl
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, n, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", n, err)
		}
		decls = append(decls, f.Decls...)
	}
	found := map[string]bool{}
	for _, d := range decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Body == nil {
			continue
		}
		ast.Inspect(fd.Body, func(n ast.Node) bool {
			if c, ok := n.(*ast.CallExpr); ok {
				if id, ok := c.Fun.(*ast.Ident); ok && (id.Name == "markRoamSession" || id.Name == "rearmRoamSession" || id.Name == "writeRoamSession") {
					found[fd.Name.Name] = true
				}
			}
			return true
		})
	}
	if !found["handleResume"] {
		t.Fatal("control failed: handleResume's markRoamSession call was not found, so the walk proves nothing")
	}
	// markRoamSession and rearmRoamSession are the wrappers themselves (roamsession_marker.go). Since NWP-20261005-26
	// both call writeRoamSession, which is counted too, so a writer that goes round the wrappers still shows up.
	want := []string{"handleLogout", "handlePromote2", "handleResume", "handleRoamIn", "handleRoamInOffline",
		"handleRollback", "handleRotate", "markRoamSession", "rearmRoamSession"}
	var got []string
	for k := range found {
		got = append(got, k)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("the functions writing .roamsession are %v, want %v. A NEW writer must be checked for the "+
			"NWP-20260924-01 shape -- an unverified secret becoming the seal passphrase -- before it is added here", got, want)
	}
}
