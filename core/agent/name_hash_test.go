package main

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// NWP-20261117-11 (#54): '#' is the agent's scope separator (pushProfile cuts a name at its first '#'), so a vault
// created as "jo#home" would be handled as scope "home" of a profile "jo". CREATE, CREATE-CODE, PROMOTE and PROMOTE2
// refuse a name holding '#' with ERR-NAME before the store, the gateway, the enrollment bucket or the re-key worker is
// touched. The refusal depends on the typed name alone. Sign-in is unchanged: an existing name still signs in.

const nhStrong = "a passphrase for the hash name case" // clears the floor, so a check moved after it still reaches the store

// nhHashNames are the shapes of a name holding '#'; each test makes them unique with its own tag.
func nhHashNames(tag string) []string {
	return []string{"jo" + tag + "#home", "#lead" + tag, "trail" + tag + "#", "a" + tag + "#b#c"}
}

// TestNameHash_CreateRefusesBeforeTheStore: CREATE answers ERR-NAME with no store request, the wallet untouched and
// the enrollment bucket unspent, for a strong and for a weak passphrase.
func TestNameHash_CreateRefusesBeforeTheStore(t *testing.T) {
	dest, wpath := createCodeEnv(t, "NHCODE_NHCODE_NHCODE_NHC", 3)
	seen := clSpy(t)
	fundWallet(t, wpath, 4)
	walletBefore, _ := os.ReadFile(wpath)
	t.Setenv("NOWHERE_ENROLL_MAX", "1") // one enrollment in the bucket: a refused create must not spend it
	blobCache, contentCache = nil, nil
	before := len(seen())

	for _, n := range nhHashNames("nh1") {
		for _, p := range []string{nhStrong, "short"} {
			if got := verb(func(c net.Conn) { handleCreate(c, dest, n, p) }); got != "ERR-NAME" {
				t.Errorf("CREATE %q (pass len %d) replied %q, want ERR-NAME", n, len(p), got)
			}
		}
	}
	if got := seen()[before:]; len(got) != 0 {
		t.Errorf("CREATE with a '#' name reached the store/gateway before refusing: %v", got)
	}
	if b, err := os.ReadFile(wpath); err != nil || string(b) != string(walletBefore) {
		t.Errorf("a refused CREATE touched the wallet (err %v)", err)
	}
	if ok, _ := enrollAllow(); !ok {
		t.Error("a refused CREATE spent the enrollment bucket")
	}
}

// TestNameHash_CreateCodeRefusesBeforeTheDrain: CREATE-CODE answers ERR-NAME before the floor, the gateway check, the
// code check, the throttle and the drain: no store or gateway request, no staged claim, the bucket unspent.
func TestNameHash_CreateCodeRefusesBeforeTheDrain(t *testing.T) {
	dest, wpath := createCodeEnv(t, "NHCODE_NHCODE_NHCODE_NHC", 3)
	seen := clSpy(t)
	fundWallet(t, wpath, 4)
	walletBefore, _ := os.ReadFile(wpath)
	t.Setenv("NOWHERE_ENROLL_MAX", "1")
	blobCache, contentCache = nil, nil
	before := len(seen())

	for _, n := range nhHashNames("nh2") {
		for _, c := range []struct{ what, pass, code string }{
			{"a valid code", nhStrong, "NHCODE_NHCODE_NHCODE_NHC"},
			{"no code", nhStrong, ""},                                  // the base answers ERR-NOCODE
			{"a weak passphrase", "short", "NHCODE_NHCODE_NHCODE_NHC"}, // the base answers WEAK
		} {
			if got := verb(func(x net.Conn) { handleCreateCode(x, dest, n, c.pass, c.code) }); got != "ERR-NAME" {
				t.Errorf("CREATE-CODE %q with %s replied %q, want ERR-NAME", n, c.what, got)
			}
			if _, err := os.Stat(createStagingPath(n, c.pass)); err == nil {
				t.Errorf("CREATE-CODE %q with %s staged a claim -- the code was drained", n, c.what)
			}
		}
	}
	if got := seen()[before:]; len(got) != 0 {
		t.Errorf("CREATE-CODE with a '#' name reached the store/gateway before refusing: %v", got)
	}
	if b, err := os.ReadFile(wpath); err != nil || string(b) != string(walletBefore) {
		t.Errorf("a refused CREATE-CODE touched the wallet (err %v)", err)
	}
	if ok, _ := enrollAllow(); !ok {
		t.Error("a refused CREATE-CODE spent the enrollment bucket")
	}

	t.Setenv("GATEWAY_URL", "") // the base answers ERR: no managed gateway
	if got := verb(func(x net.Conn) { handleCreateCode(x, dest, "jonh2g#home", nhStrong, "NHCODE_NHCODE_NHCODE_NHC") }); got != "ERR-NAME" {
		t.Errorf("CREATE-CODE with no gateway replied %q, want ERR-NAME", got)
	}
}

// TestNameHash_PromoteRefusesBeforeTheStoreAndTheRekey: PROMOTE and PROMOTE2 on a throwaway named with '#' answer
// ERR-NAME with no store request and no worker op; the throwaway stays a throwaway.
func TestNameHash_PromoteRefusesBeforeTheStoreAndTheRekey(t *testing.T) {
	tr := trackGoSafe(t)
	ropStore(t)
	ropReapReset(t)
	seen := clSpy(t)
	blobCache, contentCache = nil, nil
	before := len(seen())
	const n = "jonh3#home"
	dest := ropThrowaway(t, n, ropPass)
	stop := ropWorker(t, dest)

	if got := ropReply(t, func(c net.Conn) { handlePromote(c, dest) }); got != "ERR-NAME" {
		t.Errorf("PROMOTE replied %q, want ERR-NAME", got)
	}
	if got := ropReply(t, func(c net.Conn) { handlePromote2(c, dest, ropNew) }); got != "ERR-NAME" {
		t.Errorf("PROMOTE2 with a new passphrase replied %q, want ERR-NAME", got)
	}
	if got := ropReply(t, func(c net.Conn) { handlePromote2(c, dest, "") }); got != "ERR-NAME" {
		t.Errorf("PROMOTE2 with no passphrase replied %q, want ERR-NAME", got)
	}
	time.Sleep(700 * time.Millisecond) // a removed check seals in a goroutine; give it time to ask
	tr.wait(t, 10*time.Second)
	ops := stop()

	if len(ops) != 0 {
		t.Errorf("a refused save handed the worker %v", ops)
	}
	if got := seen()[before:]; len(got) != 0 {
		t.Errorf("a refused save reached the store: %v", got)
	}
	if !isLocalSession(dest) {
		t.Error("a refused save turned the throwaway into a stored session")
	}
	if gn, gp, _ := readRoamSession(dest); gn != n || gp != ropPass {
		t.Errorf("a refused save changed the session to %q", gn)
	}
}

// TestNameHash_TheReplyIsTheSameForEveryPassphrase: the refusal is the same bytes for every passphrase and names
// nothing typed.
func TestNameHash_TheReplyIsTheSameForEveryPassphrase(t *testing.T) {
	tr := trackGoSafe(t)
	dest, _ := createCodeEnv(t, "NHCODE_NHCODE_NHCODE_NHC", 3)
	seen := clSpy(t)
	blobCache, contentCache = nil, nil
	const n = "jonh4#home"
	var replies []string
	for _, p := range []string{nhStrong, "another long passphrase for the same name", "weak"} {
		replies = append(replies,
			verb(func(c net.Conn) { handleCreate(c, dest, n, p) }),
			verb(func(c net.Conn) { handleCreateCode(c, dest, n, p, "NHCODE_NHCODE_NHCODE_NHC") }))
	}
	if got := seen(); len(got) != 0 {
		t.Errorf("a refused create reached the store/gateway: %v", got)
	}

	ropStore(t)
	ropReapReset(t)
	seen = clSpy(t)
	dest = ropThrowaway(t, "jonh4p#home", ropPass)
	stop := ropWorker(t, dest)
	for _, p := range []string{ropPass, ropNew, "a third strong passphrase for promote"} {
		replies = append(replies, ropReply(t, func(c net.Conn) { handlePromote2(c, dest, p) }))
	}
	time.Sleep(700 * time.Millisecond)
	tr.wait(t, 10*time.Second)
	if ops := stop(); len(ops) != 0 {
		t.Errorf("a refused PROMOTE2 handed the worker %v", ops)
	}
	if got := seen(); len(got) != 0 {
		t.Errorf("a refused PROMOTE2 reached the store: %v", got)
	}
	for i, r := range replies {
		if r != "ERR-NAME" {
			t.Errorf("reply %d is %q, want ERR-NAME for every passphrase", i, r)
		}
		if strings.Contains(r, "jo") || strings.Contains(r, "home") {
			t.Errorf("reply %d (%q) names the typed profile", i, r)
		}
	}
}

// TestNameHash_ANameWithoutHashGetsItsUsualAnswer: the check keys on '#' alone; a plain name gets its usual answer.
func TestNameHash_ANameWithoutHashGetsItsUsualAnswer(t *testing.T) {
	dest, _ := createCodeEnv(t, "NHCODE_NHCODE_NHCODE_NHC", 3)
	blobCache, contentCache = nil, nil
	if got := verb(func(c net.Conn) { handleCreateCode(c, dest, "namehash-plain", nhStrong, "") }); got != "ERR-NOCODE" {
		t.Errorf("CREATE-CODE with a plain name and no code replied %q, want ERR-NOCODE", got)
	}
	t.Setenv("GATEWAY_URL", "") // no store configured
	if got := verb(func(c net.Conn) { handleCreate(c, dest, "namehash-plain", nhStrong) }); got != "NOSTORE" {
		t.Errorf("CREATE with a plain name and no store replied %q, want NOSTORE", got)
	}

	ropReapReset(t)
	pdest := ropThrowaway(t, "namehash-plain-p", ropPass)
	stop := ropWorker(t, pdest)
	got := ropReply(t, func(c net.Conn) { handlePromote(c, pdest) })
	if ops := stop(); len(ops) != 0 {
		t.Errorf("PROMOTE with no store handed the worker %v", ops)
	}
	if got != "NOSTORE" {
		t.Errorf("PROMOTE of a plain-named throwaway with no store replied %q, want NOSTORE", got)
	}
}

// TestNameHash_SignInIsUntouched: ROAM-IN gains no name refusal. On a busy worker lane a '#' name and a plain name
// both reach the worker call and get ERR-WORKER-BUSY; the busy reply comes after BLANK and NOSTORE, so a name check
// anywhere before it would change the '#' name's reply. The source half pins the three checks to their functions.
func TestNameHash_SignInIsUntouched(t *testing.T) {
	f := walletFailSetup(t)
	loginWindowState(t)
	resetAbandoned(t, map[string]string{laneRW.svc: "in"})
	prev := workerState
	workerState = func(svc string) string {
		if svc == laneRW.svc {
			return "running"
		}
		return prev(svc)
	}
	t.Cleanup(func() { workerState = prev })

	var replies []string
	for _, c := range []struct{ name, pass string }{
		{"jonh6#home", "a passphrase for the hash name"},
		{"namehash-signin", "a passphrase for the plain name"},
	} {
		reply, _ := roamInBusyDrive(t, f, c.name, c.pass)
		replies = append(replies, reply)
		if reply != "ERR-WORKER-BUSY" {
			t.Errorf("sign-in as %q replied %q, want ERR-WORKER-BUSY", c.name, reply)
		}
		if _, err := os.Stat(filepath.Join(f.dest, laneRW.req)); err == nil {
			t.Errorf("sign-in as %q wrote a request to roamd on a busy lane", c.name)
		}
	}
	if replies[0] != replies[1] {
		t.Errorf("the sign-in reply depends on '#' in the name: %q vs %q", replies[0], replies[1])
	}

	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	const lit = `fmt.Fprint(conn, "ERR-NAME\n")`
	if c := strings.Count(string(src), lit); c != 3 {
		t.Errorf("main.go holds %d copies of %s, want 3 (createPrecheck, handleCreateCode, promoteGuards)", c, lit)
	}
	for _, fn := range []string{"createPrecheck", "handleCreateCode", "promoteGuards"} {
		if c := strings.Count(nhBody(t, string(src), fn), lit); c != 1 {
			t.Errorf("%s holds %d ERR-NAME replies, want 1", fn, c)
		}
	}
	for _, fn := range []string{"handleRoamIn", "handleRoamInOffline"} {
		if strings.Contains(nhBody(t, string(src), fn), "ERR-NAME") {
			t.Errorf("%s refuses a name: sign-in must not change", fn)
		}
	}
}

// nhBody returns the body of the top-level func named fn: from its func line to the next line that is exactly "}".
func nhBody(t *testing.T, src, fn string) string {
	t.Helper()
	i := strings.Index(src, "\nfunc "+fn+"(")
	if i < 0 {
		t.Fatalf("main.go has no func %s", fn)
	}
	rest := src[i+1:]
	j := strings.Index(rest, "\n}\n")
	if j < 0 {
		t.Fatalf("func %s has no closing line", fn)
	}
	return rest[:j]
}
