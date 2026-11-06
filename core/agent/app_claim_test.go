package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"testing"
)

// Each test pins exactly ONE of the three rules in claimsToPublish, so a mutation that breaks a rule fails a
// named test rather than a vague one. The rules are: a lapsed claim is dropped whoever owns it; another unit's
// live claim is carried forward verbatim; this unit's own entries are rebuilt from `held`, never merged.

const (
	unitA = "aaaa1111"
	unitB = "bbbb2222"
	t0    = int64(1_700_000_000)
)

// RULE 1, and it is the escape hatch the whole design rests on: an amnesiac handset that powers off never
// publishes a release, so its claims MUST expire by arithmetic or the app is stranded on every other device.
func TestClaim_ALapsedClaimIsDroppedWhoeverOwnsIt(t *testing.T) {
	old := map[string]appClaim{
		"com.stale.other": {Unit: unitB, At: t0 - claimTTL}, // exactly TTL old -> lapsed
		"com.stale.mine":  {Unit: unitA, At: t0 - claimTTL - 1},
		"com.live.other":  {Unit: unitB, At: t0 - claimTTL + 1}, // one second inside -> lives
	}
	out, refused := claimsToPublish(old, unitA, nil, t0)
	if _, ok := out["com.stale.other"]; ok {
		t.Error("another unit's LAPSED claim survived -- a powered-off handset strands this app forever")
	}
	if _, ok := out["com.stale.mine"]; ok {
		t.Error("this unit's own lapsed claim survived")
	}
	if c, ok := out["com.live.other"]; !ok || c.Unit != unitB {
		t.Errorf("a claim one second inside the TTL was dropped: %+v", out)
	}
	if len(refused) != 0 {
		t.Errorf("nothing was asked for, so nothing can be refused: %v", refused)
	}
}

// RULE 2: a publish rewrites only its OWN unit's entries. This is what makes two handsets sealing
// concurrently safe on a last-writer-wins head -- they write disjoint halves of one map.
func TestClaim_AnotherUnitsLiveClaimIsCarriedForwardVerbatim(t *testing.T) {
	theirs := appClaim{Unit: unitB, At: t0 - 5}
	old := map[string]appClaim{"com.theirs": theirs}
	out, _ := claimsToPublish(old, unitA, []string{"com.mine"}, t0)
	if got := out["com.theirs"]; got != theirs {
		t.Errorf("another unit's claim was rewritten: got %+v want %+v", got, theirs)
	}
	if got := out["com.mine"]; got.Unit != unitA || got.At != t0 {
		t.Errorf("this unit's own claim was not stamped now: %+v", got)
	}
}

// ⚠ FIRST DEVICE WINS (docs/product-decisions.md, 2026-09-10). The second handset does not take the app; the
// existing claim stands and the request comes back REFUSED so the user can be told.
func TestClaim_FirstDeviceWinsAndTheLoserIsNamed(t *testing.T) {
	held := appClaim{Unit: unitB, At: t0 - 1}
	old := map[string]appClaim{"com.contested": held}
	out, refused := claimsToPublish(old, unitA, []string{"com.contested", "com.free"}, t0)

	if out["com.contested"] != held {
		t.Errorf("the SECOND device took a live claim: %+v", out["com.contested"])
	}
	if !reflect.DeepEqual(refused, []string{"com.contested"}) {
		t.Errorf("the refusal was not reported: %v -- the user cannot be told what they lost", refused)
	}
	if c := out["com.free"]; c.Unit != unitA {
		t.Errorf("an uncontested package was not claimed: %+v", c)
	}
}

// RULE 3: a release is an ABSENCE, not a message. An app this handset no longer holds simply stops appearing.
func TestClaim_ReleasePropagatesByOmission(t *testing.T) {
	old := map[string]appClaim{
		"com.released": {Unit: unitA, At: t0 - 1},
		"com.kept":     {Unit: unitA, At: t0 - 1},
	}
	out, _ := claimsToPublish(old, unitA, []string{"com.kept"}, t0)
	if _, ok := out["com.released"]; ok {
		t.Error("a package this unit no longer holds is still claimed -- release never propagates")
	}
	if _, ok := out["com.kept"]; !ok {
		t.Error("a package this unit still holds was released")
	}
}

// The convergence property, and the reason this cannot become the permanent 2-cycle the #media carry has:
// alternate publishes by two handsets must preserve BOTH sets, forever.
func TestClaim_TwoHandsetsAlternatingNeverLoseEachOther(t *testing.T) {
	var m map[string]appClaim
	now := t0
	for i := 0; i < 6; i++ {
		now += 30
		m, _ = claimsToPublish(m, unitA, []string{"com.a"}, now)
		now += 30
		m, _ = claimsToPublish(m, unitB, []string{"com.b"}, now)
	}
	if len(m) != 2 || m["com.a"].Unit != unitA || m["com.b"].Unit != unitB {
		t.Fatalf("two handsets lost each other's claims after 6 rounds: %+v", m)
	}
}

// A nil map keeps a manifest byte-identical to one written before this index existed -- the same omitempty
// discipline every other index in chunkManifest follows.
func TestClaim_NothingToRecordPublishesNil(t *testing.T) {
	if out, _ := claimsToPublish(nil, unitA, nil, t0); out != nil {
		t.Errorf("an empty claim set published %+v, not nil", out)
	}
	// ... and a map that becomes empty after expiry must also collapse to nil, not to {}.
	old := map[string]appClaim{"com.gone": {Unit: unitB, At: t0 - claimTTL - 1}}
	if out, _ := claimsToPublish(old, unitA, nil, t0); out != nil {
		t.Errorf("a fully-expired claim set published %+v, not nil", out)
	}
}

func TestClaimsHeldByOthers_ExcludesOwnUnitAndLapsed(t *testing.T) {
	m := map[string]appClaim{
		"com.other.live":   {Unit: unitB, At: t0 - 1},
		"com.other.lapsed": {Unit: unitB, At: t0 - claimTTL},
		"com.mine":         {Unit: unitA, At: t0 - 1},
	}
	got := claimsHeldByOthers(m, unitA, t0)
	want := map[string]string{"com.other.live": unitB}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	if claimsHeldByOthers(map[string]appClaim{"com.mine": {Unit: unitA, At: t0}}, unitA, t0) != nil {
		t.Error("a set holding only our own claims must be nil, not an empty map")
	}
}

// Sanity on the TTL itself: it has to outlast several sync cycles, or a claim lapses while the app is
// genuinely in use and the decision's discard fires for no reason.
func TestClaim_TTLOutlastsSeveralSyncCycles(t *testing.T) {
	if claimTTL < 4*syncIntervalDefault {
		t.Fatalf("claimTTL %ds is under four sync cycles (%ds) -- a busy handset would lose its own claims",
			claimTTL, 4*syncIntervalDefault)
	}
}

func sortedKeys(m map[string]appClaim) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// A publish must not invent packages: the result is exactly (other units' live claims) + (what we hold).
func TestClaim_PublishInventsNothing(t *testing.T) {
	old := map[string]appClaim{"com.other": {Unit: unitB, At: t0 - 1}}
	out, _ := claimsToPublish(old, unitA, []string{"com.mine", ""}, t0)
	if got, want := sortedKeys(out), []string{"com.mine", "com.other"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v (an empty package name must be skipped, not claimed)", got, want)
	}
}

// ---- the two files that join this to the rest of the system ----------------------------------------

// The drop list taught this: a "package name" with a path separator means the producer wrote paths, and
// acting on it as a basename could reach an unrelated subtree.
func TestFileHeldList_SkipsPathsCommentsAndDuplicates(t *testing.T) {
	p := t.TempDir() + "/held"
	bs := string(rune(92)) // a literal backslash, BUILT not escaped: a shell heredoc ate the escaped pair
	// here once already, and Go then saw an unknown escape sequence.
	body := "com.one\n# a comment\n\ncom.two\ncom.one\n../etc/passwd\nsub/dir\n" + "back" + bs + "slash" + "\n"
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("NOWHERE_HELD_LIST", p)
	got := fileHeldList()
	want := []string{"com.one", "com.two"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestFileHeldList_AbsentMeansHoldNothing(t *testing.T) {
	t.Setenv("NOWHERE_HELD_LIST", "")
	if got := fileHeldList(); got != nil {
		t.Fatalf("unset env returned %v", got)
	}
	t.Setenv("NOWHERE_HELD_LIST", t.TempDir()+"/does-not-exist")
	if got := fileHeldList(); got != nil {
		t.Fatalf("unreadable file returned %v -- a handset that cannot say what it holds must hold nothing", got)
	}
}

// ⚠ The file must be written even when EMPTY: an empty file is the instruction to RELEASE. Skipping the
// write would leave the last non-empty list in place, so an app released on the other handset would stay
// shut here for the rest of the session.
func TestWriteClaimsOut_EmptyIsWrittenNotSkipped(t *testing.T) {
	p := t.TempDir() + "/claims"
	t.Setenv("NOWHERE_CLAIMS_OUT", p)

	writeClaimsOut(map[string]appClaim{"com.mine": {Unit: unitA, At: t0}}, unitA, t0)
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("nothing written when only our own claims exist: %v", err)
	}
	if strings.Contains(string(b), "com.mine") {
		t.Errorf("our OWN claim was written to the enforcement list:\n%s", b)
	}
}

func TestWriteClaimsOut_NamesTheHolderAndIsDeterministic(t *testing.T) {
	p := t.TempDir() + "/claims"
	t.Setenv("NOWHERE_CLAIMS_OUT", p)
	m := map[string]appClaim{
		"com.zzz":  {Unit: unitB, At: t0},
		"com.aaa":  {Unit: unitB, At: t0},
		"com.mine": {Unit: unitA, At: t0},
		"com.old":  {Unit: unitB, At: t0 - claimTTL}, // lapsed: must not be enforced
	}
	writeClaimsOut(m, unitA, t0)
	b, _ := os.ReadFile(p)
	var lines []string
	for _, ln := range strings.Split(string(b), "\n") {
		if ln != "" && !strings.HasPrefix(ln, "#") {
			lines = append(lines, ln)
		}
	}
	want := []string{"com.aaa\t" + unitB, "com.zzz\t" + unitB}
	if !reflect.DeepEqual(lines, want) {
		t.Fatalf("got %v want %v (sorted, holder named, own + lapsed excluded)", lines, want)
	}
}

// ---- the scope gate, end to end through a real push ------------------------------------------------

// ⚠ THIS IS A BUG I WROTE AND CAUGHT BEFORE IT SHIPPED. writeClaimsOut writes EVEN WHEN EMPTY, because an
// empty file is the instruction to RELEASE. The first version of the wiring called it after every push, so
// a #de or #media seal -- which computes no claims and passes nil -- would have written an empty
// enforcement file seconds after the vault seal established the holds, releasing every app this handset
// was keeping shut, silently, on a timer.
//
// ⚠⚠ AND THE FIRST VERSION OF THIS TEST COULD NOT CATCH IT. It seeded claims only from THIS unit, and
// claimsHeldByOthers excludes our own by design -- so the enforcement file was empty in both the good and
// the mutated run, and "unchanged" was true for the wrong reason. A mutation that removes the gate passed.
// The fix is the second unit below: without a claim owned by SOMEONE ELSE there is nothing to clobber.
func TestClaims_AScopedSealPublishesNothingAndDoesNotClobberTheEnforcementFile(t *testing.T) {
	fenceTestEnv(t)
	t.Setenv("NOWHERE_SEAL_FORCE", "1")

	origUnit := unitIDPath
	defer func() { unitIDPath = origUnit }()

	name, pass := "alice", "correct horse battery"
	base := newHookStore(t, nil)
	createVault(base, name, pass)

	dir := t.TempDir()
	held := dir + "/held"
	out := dir + "/claims"
	t.Setenv("NOWHERE_HELD_LIST", held)
	t.Setenv("NOWHERE_CLAIMS_OUT", out)

	write := func(p, body string) {
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	// UNIT ONE holds com.theirs.
	unitIDPath = dir + "/unit-one"
	write(held, "com.theirs\n")
	sealDone()
	pushProfile(base, name, pass, seedDir(t, 2))

	// UNIT TWO holds com.mine. Now the head carries a claim owned by someone else, which is the only way
	// the enforcement file is non-empty and a clobber is detectable at all.
	unitIDPath = dir + "/unit-two"
	write(held, "com.mine\n")
	sealDone()
	pushProfile(base, name, pass, seedDir(t, 3))

	m := headManifestOf(t, base, name, pass)
	if len(m.Claims) != 2 {
		t.Fatalf("expected both units' claims in the head, got %+v", m.Claims)
	}
	first, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("the bare seal wrote no enforcement file: %v", err)
	}
	if !strings.Contains(string(first), "com.theirs") {
		t.Fatalf("the enforcement file does not name the OTHER unit's package, so this test cannot detect a"+
			" clobber:\n%s", first)
	}
	if strings.Contains(string(first), "com.mine") {
		t.Errorf("our OWN held package was written to the enforcement list:\n%s", first)
	}

	// ... and a SCOPED seal must leave both the index and the file alone.
	sealDone()
	pushProfile(base, name+"#de", pass, seedDir(t, 2))

	if dm := headManifestOf(t, base, name+"#de", pass); len(dm.Claims) != 0 {
		t.Errorf("a #de seal published %d claim(s) -- the index must have ONE home", len(dm.Claims))
	}
	after, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("the enforcement file vanished after a scoped seal: %v", err)
	}
	if string(after) != string(first) {
		t.Fatalf("a #de seal REWROTE the enforcement file -- every hold would be released seconds after the"+
			" vault seal set them.\nbefore: %q\nafter:  %q", first, after)
	}
	if bm := headManifestOf(t, base, name, pass); len(bm.Claims) != 2 {
		t.Errorf("the bare head lost claims after a scoped seal: %+v", bm.Claims)
	}
}

// NWP-20260911-02. THE HANDOFF IS ONLY A HANDOFF IF ITS READER CAN OPEN IT.
//
// The seal runs as root and writes this file into the CHOOSER’s own files dir, so the 0600 file it creates
// is root:root and the app that has to read it gets EACCES. Every layer above kept reporting success:
// roamd logged "claims: N package(s) held elsewhere", the chooser was kicked, and AppClaim.readClaims
// swallowed the failed open as "nothing is held elsewhere" -- so the enforcement was INERT: no claim was
// read, no hold was taken, no receipt was written. ⚠ The RELEASE hazard is prospective, not what happened:
// an empty record is the instruction to release, so a failed read would drop every hold a session held --
// and the same bug guaranteed it held none (corrected in NWP-20260912-03). Shipped in NWP-20260911-01 and
// device-proven broken on lynx on 2026-09-11, both directions (hold and release).
//
// ⚠ WHY THE SEAM, AND WHAT THIS TEST DOES NOT PROVE. A test process cannot chown to another uid, and
// comparing the written file’s owner to its directory’s passes identically with and without the fix (both
// are the test user), so the obvious test is INERT -- the failure mode this file’s header warns about. The
// seam records that the call was MADE, with the ids the DIRECTORY reports, against the TMP path -- i.e.
// before the rename, so the reader never sees the file under the wrong owner. It does not prove the kernel
// honoured the chown; only the device can, and it did.
func TestWriteClaimsOut_GivesTheFileToTheDirectoryOwnerBeforeTheRename(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "nowhere-claims")
	t.Setenv("NOWHERE_CLAIMS_OUT", p)

	var gotPath string
	var gotUID, gotGID int
	var calls int
	orig := chownFile
	t.Cleanup(func() { chownFile = orig })
	chownFile = func(name string, uid, gid int) error {
		calls++
		gotPath, gotUID, gotGID = name, uid, gid
		return nil
	}

	writeClaimsOut(map[string]appClaim{"com.theirs": {Unit: unitB, At: t0}}, unitA, t0)

	if calls == 0 {
		t.Fatalf("the enforcement file was written but never given to the app that reads it: the chooser" +
			" gets EACCES, reads that as an EMPTY record, and releases every hold it was enforcing")
	}
	if want := p + ".tmp"; gotPath != want {
		t.Errorf("chowned %q, want the TMP path %q -- doing it after the rename leaves a window in which"+
			" the reader can open the file under the wrong owner", gotPath, want)
	}
	st, err := os.Stat(dir)
	if err != nil {
		t.Fatalf("stat %s: %v", dir, err)
	}
	sys, ok := st.Sys().(*syscall.Stat_t)
	if !ok {
		t.Skip("no syscall.Stat_t on this platform")
	}
	if gotUID != int(sys.Uid) || gotGID != int(sys.Gid) {
		t.Errorf("chowned to %d:%d, want the DIRECTORY’s owner %d:%d -- the directory is the app’s own"+
			" files dir, and its owner is the only id that can read what we write there",
			gotUID, gotGID, sys.Uid, sys.Gid)
	}
}

// NWP-20261011-46: the count line is the ONLY audible record of a release, and claimsToPublish returns nil at
// exactly that moment. So the zero case must render as a real line, not as nothing.
func TestClaimsLogLine_NilMapIsTheZeroLine(t *testing.T) {
	const want = " claims: 0 held by this device, 0 by other device(s)"
	for name, idx := range map[string]map[string]appClaim{"nil": nil, "empty": {}} {
		got := claimsLogLine("p", idx, unitA)
		if !strings.HasPrefix(got, "push: profile "+logProfile("p")) || !strings.HasSuffix(got, want) {
			t.Errorf("%s map: got %q, want the profile's logProfile name and ...%q", name, got, want)
		}
	}
}

func TestClaimsLogLine_SplitsMineFromTheirsAndNamesNoPackage(t *testing.T) {
	idx := map[string]appClaim{
		"com.mine.one":   {Unit: unitA, At: t0},
		"com.mine.two":   {Unit: unitA, At: t0},
		"com.theirs.one": {Unit: unitB, At: t0},
		"com.theirs.two": {Unit: "cccc3333", At: t0},
		"com.theirs.3":   {Unit: unitB, At: t0},
	}
	got := claimsLogLine("p", idx, unitA)
	if want := " claims: 2 held by this device, 3 by other device(s)"; !strings.HasSuffix(got, want) {
		t.Errorf("got %q, want ...%q", got, want)
	}
	for pkg := range idx {
		if strings.Contains(got, pkg) {
			t.Errorf("the line names %q -- roam.log outlives every wipe, so it must carry counts only: %q", pkg, got)
		}
	}
}

// The print site in pushProfile must sit under the bare-vault guard and under NOTHING that reads claimsIdx: the
// old `if claimsIdx != nil` guard is what made the release silent. A source check, because pushProfile needs a
// live store to run.
func TestClaimsLogLine_PrintIsNotGatedOnTheClaimIndex(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var push *ast.FuncDecl
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Name.Name == "pushProfile" {
			push = fd
		}
	}
	if push == nil {
		t.Fatal("pushProfile not found in main.go")
	}
	mentions := func(n ast.Node, name string) bool {
		found := false
		ast.Inspect(n, func(m ast.Node) bool {
			if id, ok := m.(*ast.Ident); ok && id.Name == name {
				found = true
			}
			return !found
		})
		return found
	}
	sites := 0
	var stack []ast.Node
	ast.Inspect(push.Body, func(n ast.Node) bool {
		if n == nil {
			stack = stack[:len(stack)-1]
			return false
		}
		stack = append(stack, n)
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if id, ok := call.Fun.(*ast.Ident); !ok || id.Name != "claimsLogLine" {
			return true
		}
		sites++
		var guards []*ast.IfStmt
		for _, a := range stack {
			if is, ok := a.(*ast.IfStmt); ok {
				guards = append(guards, is)
			}
		}
		if len(guards) != 1 {
			t.Errorf("%s: claimsLogLine sits under %d if statements, want exactly the bare-vault guard",
				fset.Position(call.Pos()), len(guards))
		}
		for _, g := range guards {
			if mentions(g.Cond, "claimsIdx") || mentions(g.Cond, "claimsRefused") {
				t.Errorf("%s: the claims line is gated on the claim index again -- it goes silent at the release",
					fset.Position(g.Pos()))
			}
			if !mentions(g.Cond, "profile") || !mentions(g.Cond, "IndexByte") {
				t.Errorf("%s: the claims line's guard is not the bare-vault check on profile",
					fset.Position(g.Pos()))
			}
		}
		return true
	})
	if sites != 1 {
		t.Errorf("pushProfile calls claimsLogLine %d times, want 1", sites)
	}
}
