package main

// NWP-20260908-01: A FLAG THAT IS EXPORTED PROCESS-WIDE IS NOT SCOPED, WHATEVER ITS COMMENT SAYS.
//
// NOWHERE_CARRY_ESSENTIAL gates six behaviours in pushProfile -- above all the threshold-0 per-file
// alignment that turns a scope into one chunk region per file. It was written for #apps, two comments in
// main.go asserted that "appcode_seal alone sets" it, and appcode_seal's inline re-pass of the variable
// reads exactly like scoping. None of that was true: roamd `export`s the flag beside NOWHERE_ONDEMAND_MEDIA,
// so every agent it runs inherits it. Setting it in a ring conf to turn the #apps carry on -- the whole
// point of shipping it -- would also have switched the vault, #de, #media, #sys and #keys seals to
// file-aligned chunking, re-uploading each once, carrying nothing, and logging nothing about either.
//
// conf_flags_wired_test.go cannot see this: it asserts a documented flag is EXPORTED somewhere, which is the
// property that was true and harmful. This asserts the other half -- that a scope-restricted flag is pinned
// OFF at every push it does not belong to -- because "is it exported" and "where does it land" are different
// questions and only the second one matters at a seal.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// errNoSourceTree marks a bin directory that cannot be read: the test is running without the source tree, which
// is a skip, not a failure.
var errNoSourceTree = errors.New("cannot read the daemon scripts")

// listDaemonScripts lists the device-side shell daemons in dir -- the only place a conf flag can reach a process.
// NWP-20261024-06: the test-*.sh suites beside them are not daemons. They spell push calls and exports as anchors
// and mutation text, and read as daemon lines they replaced the real push sites and stood in for missing exports.
func listDaemonScripts(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("%w: %s: %v", errNoSourceTree, dir, err)
	}
	var out []string
	roamd := false
	for _, e := range entries {
		name := e.Name()
		if !e.Type().IsRegular() || !strings.HasSuffix(name, ".sh") || strings.HasPrefix(name, "test-") {
			continue
		}
		out = append(out, filepath.Join(dir, name))
		roamd = roamd || name == "nowhere_roamd.sh"
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("no daemon scripts under %s", dir)
	}
	if !roamd {
		return nil, fmt.Errorf("nowhere_roamd.sh is not among the daemon scripts under %s (%v) -- the filter kept "+
			"the wrong files, and every push site lives in roamd", dir, out)
	}
	return out, nil
}

// daemonScripts is listDaemonScripts on the checked-out bin directory.
func daemonScripts(t *testing.T) []string {
	t.Helper()
	out, err := listDaemonScripts(filepath.Join("..", "vendor-common", "bin"))
	if errors.Is(err, errNoSourceTree) {
		t.Skipf("%v -- this test needs the source tree", err)
	}
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// scopeRestrictedFlags: env flag -> the ONE profile-scope suffix whose push may inherit it. Add a row here
// when a new flag changes what a seal writes and is meant for a single scope.
var scopeRestrictedFlags = map[string]string{
	"NOWHERE_CARRY_ESSENTIAL":       "#apps",
	"NOWHERE_CARRY_ESSENTIAL_MEDIA": "#media",
}

var agentPushRe = regexp.MustCompile(`"\$AGENT" push s3 ("[^"]*")`)

// scanPushSites returns every agent push invocation in the given scripts, with the text of the invocation
// including any environment prefix carried on continuation lines above it. A profile with two sites is an error
// (NWP-20261024-06): keyed by profile, the later one used to win silently.
func scanPushSites(files []string) (map[string]string, error) {
	out := map[string]string{}
	where := map[string]string{} // profile-arg -> "<file>:<line>" of its first site
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, fmt.Errorf("read %s: %v", f, err)
		}
		lines := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
		for i, ln := range lines {
			m := agentPushRe.FindStringSubmatch(ln)
			if m == nil {
				continue
			}
			at := filepath.Base(f) + ":" + strconv.Itoa(i+1)
			if first, dup := where[m[1]]; dup {
				return nil, fmt.Errorf("agent push site %s found twice, at %s and at %s -- the scan keys by "+
					"profile, so the later one would silently replace the earlier", m[1], first, at)
			}
			where[m[1]] = at
			// Walk back over shell line-continuations so an env prefix on its own line counts.
			inv := []string{ln}
			for j := i - 1; j >= 0 && strings.HasSuffix(strings.TrimRight(lines[j], " \t"), `\`); j-- {
				inv = append([]string{lines[j]}, inv...)
			}
			out[m[1]] = strings.Join(inv, "\n")
		}
	}
	if len(out) < 4 {
		return nil, fmt.Errorf("found only %d agent push sites (%v) -- the matcher has drifted from the scripts, so a "+
			"missing pin would read as a pass", len(out), out)
	}
	return out, nil
}

func pushSites(t *testing.T) map[string]string { // profile-arg -> the invocation text
	t.Helper()
	out, err := scanPushSites(daemonScripts(t))
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// A flag is pinned at a push either LITERALLY (`FLAG=0`) or, for the shared `_push` helper, as a
// DEFAULTED PASSTHROUGH (`FLAG="${5:-0}"`) -- off unless that one caller opts in. The second form is not a
// loophole, but it moves the scoping decision to the CALL SITES, so it is only safe if exactly the right
// callers opt in. helperPassthrough returns the positional slot when a site uses that form.
var passthroughRe = func(flag string) *regexp.Regexp {
	return regexp.MustCompile(regexp.QuoteMeta(flag) + `="\$\{(\d+):-0\}"`)
}

// pushHelperCalls returns every `_push <label> <profile> ...` call with its argument count, following shell
// line-continuations so a call split over lines is counted whole.
var helperCallText = map[string]string{}

// pushHelperCallText is the raw text of each _push call, so an assertion can ask what a slot actually holds
// rather than only how many slots there are.
func pushHelperCallText(t *testing.T) map[string]string {
	t.Helper()
	pushHelperCalls(t)
	return helperCallText
}

// scanPushHelperCalls reads the `_push <label> <profile> ...` calls in the given scripts: each profile's argument
// count and call text. A profile called twice is an error, as in scanPushSites.
func scanPushHelperCalls(files []string) (map[string]int, map[string]string, error) {
	out := map[string]int{}
	text := map[string]string{}
	where := map[string]string{} // profile-arg -> "<file>:<line>" of its first call
	call := regexp.MustCompile(`_push\s+\w+\s+("[^"]*")`)
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, nil, fmt.Errorf("read %s: %v", f, err)
		}
		lines := strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n")
		for i, ln := range lines {
			m := call.FindStringSubmatch(ln)
			if m == nil || strings.Contains(ln, "_push() {") {
				continue
			}
			at := filepath.Base(f) + ":" + strconv.Itoa(i+1)
			if first, dup := where[m[1]]; dup {
				return nil, nil, fmt.Errorf("_push call %s found twice, at %s and at %s -- the scan keys by "+
					"profile, so the later one would silently replace the earlier", m[1], first, at)
			}
			where[m[1]] = at
			whole := ln
			for j := i; j < len(lines)-1 && strings.HasSuffix(strings.TrimRight(lines[j], " \t"), `\`); j++ {
				whole += " " + strings.TrimSpace(lines[j+1])
			}
			// $1 is the LABEL, which is written unquoted; every later argument is a quoted word. So the
			// shell's positional count is one more than the number of quoted words -- getting this off by
			// one would make a correctly-wired call look inert, which is worse than useless here.
			args := regexp.MustCompile(`"[^"]*"`).FindAllString(whole[strings.Index(whole, "_push"):], -1)
			out[m[1]] = 1 + len(args)
			text[m[1]] = whole
		}
	}
	return out, text, nil
}

func pushHelperCalls(t *testing.T) map[string]int { // profile-arg -> number of arguments passed
	t.Helper()
	out, text, err := scanPushHelperCalls(daemonScripts(t))
	if err != nil {
		t.Fatal(err)
	}
	helperCallText = text
	return out
}

// EVERY PUSH THAT IS NOT THE FLAG'S OWN SCOPE MUST PIN IT OFF.
func TestScopeRestrictedFlagsArePinnedOffAtEveryOtherPush(t *testing.T) {
	sites := pushSites(t)
	for flag, ownScope := range scopeRestrictedFlags {
		pinned := 0
		for profile, inv := range sites {
			if strings.Contains(profile, ownScope) {
				continue // the scope the flag exists for
			}
			if slot := passthroughRe(flag).FindStringSubmatch(inv); slot != nil {
				// The shared helper defaults it OFF; which callers opt in is asserted separately below.
				pinned++
				continue
			}
			if !strings.Contains(inv, flag+"=0") {
				t.Errorf("%s does NOT pin %s off:\n%s\n\n"+
					"roamd exports %s process-wide, so this push inherits whatever a ring conf sets. For "+
					"NOWHERE_CARRY_ESSENTIAL that means threshold-0 file-aligned chunking on a scope the "+
					"carry cannot serve: a one-region-per-file re-upload that carries nothing.",
					profile, flag, inv, flag)
				continue
			}
			pinned++
		}
		if pinned == 0 {
			t.Errorf("no push pins %s off -- either the flag is unused or this test matched nothing", flag)
		}
	}
}

// AND THE FLAG'S OWN SCOPE MUST STILL RECEIVE IT, or the pin has been applied too widely and slice 5c is
// silently dead. The two failures look identical in a log; only this direction catches the second.
func TestScopeRestrictedFlagsStillReachTheirOwnScope(t *testing.T) {
	sites := pushSites(t)
	for flag, ownScope := range scopeRestrictedFlags {
		found := false
		for profile, inv := range sites {
			if passthroughRe(flag).MatchString(inv) {
				// A shared helper's profile argument is positional ("$2"), so its scope is not visible here.
				// TestPassthroughFlagsAreOptedInByExactlyTheirOwnScope asserts reachability for that shape.
				found = true
				continue
			}
			if !strings.Contains(profile, ownScope) {
				continue
			}
			found = true
			if strings.Contains(inv, flag+"=0") {
				t.Errorf("%s pins %s OFF at its own scope -- the carry can never run:\n%s", profile, flag, inv)
			}
		}
		if !found {
			t.Errorf("no push site for scope %s (flag %s); the scope may have been renamed", ownScope, flag)
		}
	}
}

// AND FOR A DEFAULTED PASSTHROUGH, EXACTLY THE RIGHT CALLERS MUST OPT IN.
//
// `_push` serves the vault, #de and #media from one invocation, so `FLAG="${5:-0}"` moves the scoping to its
// CALL SITES: whoever passes a fifth argument gets the flag. That is invisible to the assertions above --
// they only see the helper -- so it is asserted here directly. A future caller that adds an argument for an
// unrelated reason turns this flag on for that scope, silently, and this is what catches it.
func TestPassthroughFlagsAreOptedInByExactlyTheirOwnScope(t *testing.T) {
	sites, calls := pushSites(t), pushHelperCalls(t)
	callText := pushHelperCallText(t)
	if len(calls) == 0 {
		t.Skip("no _push helper calls found -- the helper may have been renamed")
	}
	for flag, ownScope := range scopeRestrictedFlags {
		var slot int
		for _, inv := range sites {
			if m := passthroughRe(flag).FindStringSubmatch(inv); m != nil {
				slot, _ = strconv.Atoi(m[1])
			}
		}
		if slot == 0 {
			continue // this flag is pinned literally everywhere; nothing to resolve
		}
		for profile, argc := range calls {
			// ⚠ COUNTING THE ARGUMENT IS NOT ENOUGH: a call that passes an empty string in that slot has the
			// right shape and turns the flag off. Require the argument to actually reference the variable.
			optedIn := argc >= slot && strings.Contains(callText[profile], flag)
			wantsIt := strings.Contains(profile, ownScope)
			switch {
			case optedIn && !wantsIt:
				t.Errorf("%s passes %d argument(s) to _push, so it picks up %s from slot %d -- but %s is for "+
					"%s only. A caller that adds an argument for an unrelated reason turns the flag on for "+
					"its scope silently.", profile, argc, flag, slot, flag, ownScope)
			case !optedIn && wantsIt:
				t.Errorf("%s passes only %d argument(s), so it never receives %s (slot %d) -- the flag is "+
					"documented, exported, and reaches nothing. That is how NOWHERE_SEQ_GUARD shipped inert.",
					profile, argc, flag, slot)
			}
		}
	}
}

// NWP-20261024-06: THE SCANS READ THE SIX DAEMONS, NOT THE SUITES BESIDE THEM, AND A PROFILE HAS ONE SITE.
//
// Both scans used to read every bin/*.sh, the 109 test-*.sh suites included, and keyed their maps by profile
// with the last match winning. A suite sorts after nowhere_roamd.sh, so a suite line that merely spelled a push
// replaced roamd's (the 2026-10-18 integration failure: an awk anchor read as a 2-argument #media call), and a
// suite's mutation text satisfied the export parser. The scans are pure functions so a refusal can be asserted.
func TestDaemonScriptsExcludeSuitesAndPushSitesAreUnique(t *testing.T) {
	// (a) the real tree. This is the only skip path: it needs the checked-out bin directory.
	real := daemonScripts(t)
	hasRoamd := false
	for _, p := range real {
		if strings.HasPrefix(filepath.Base(p), "test-") {
			t.Errorf("daemonScripts returned the suite %s", p)
		}
		hasRoamd = hasRoamd || filepath.Base(p) == "nowhere_roamd.sh"
	}
	if !hasRoamd {
		t.Errorf("daemonScripts does not contain nowhere_roamd.sh: %v", real)
	}

	roamd, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", "nowhere_roamd.sh"))
	if err != nil {
		t.Fatal(err)
	}
	// tree writes roamd plus the extra files into a fresh temp directory.
	tree := func(extra map[string]string) string {
		files := map[string]string{"nowhere_roamd.sh": string(roamd)}
		for name, body := range extra {
			files[name] = body
		}
		return writeTree(t, files)
	}
	// scans runs the listing and both scans on dir, reporting any error.
	scans := func(label, dir string) (map[string]string, map[string]int, map[string]string, bool) {
		files, err := listDaemonScripts(dir)
		if err != nil {
			t.Errorf("%s: listDaemonScripts: %v", label, err)
			return nil, nil, nil, false
		}
		sites, err := scanPushSites(files)
		if err != nil {
			t.Errorf("%s: scanPushSites: %v", label, err)
			return nil, nil, nil, false
		}
		counts, texts, err := scanPushHelperCalls(files)
		if err != nil {
			t.Errorf("%s: scanPushHelperCalls: %v", label, err)
			return nil, nil, nil, false
		}
		return sites, counts, texts, true
	}

	// R: roamd alone, the reference.
	rSites, rCounts, rTexts, ok := scans("tree R", tree(nil))
	if !ok {
		return
	}

	// A: a suite that spells a push of each kind is not read.
	suite := `_push media "${name}#media"
"$AGENT" push s3 "${name}#keys"
`
	aSites, aCounts, aTexts, ok := scans("tree A", tree(map[string]string{"test-plant.sh": suite}))
	if ok && (!reflect.DeepEqual(aSites, rSites) || !reflect.DeepEqual(aCounts, rCounts) || !reflect.DeepEqual(aTexts, rTexts)) {
		t.Errorf("tree A: a test-*.sh suite changed what the scans read")
	}

	// B: a second daemon script that pushes profiles roamd already pushes is refused, naming both places.
	dup := `"$AGENT" push s3 "${name}#apps" "$(pw "$pass")" "$STAGE"
_push de "${name}#de" "/x"
`
	bFiles, err := listDaemonScripts(tree(map[string]string{"nowhere_dup.sh": dup}))
	if err != nil {
		t.Fatalf("tree B: listDaemonScripts: %v", err)
	}
	_, err = scanPushSites(bFiles)
	wantInError(t, "tree B scanPushSites", err, `"${name}#apps"`, "nowhere_dup.sh:1", "nowhere_roamd.sh:")
	_, _, err = scanPushHelperCalls(bFiles)
	wantInError(t, "tree B scanPushHelperCalls", err, `"${name}#de"`, "nowhere_dup.sh:2", "nowhere_roamd.sh:")

	// C: daemons without roamd mean the filter kept the wrong files.
	_, err = listDaemonScripts(writeTree(t, map[string]string{"nowhere_other.sh": "true\n", "test-x.sh": "true\n"}))
	wantInError(t, "tree C listDaemonScripts", err, "nowhere_roamd.sh")
}

// writeTree writes exactly the given files into a fresh temp directory and returns it.
func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// wantInError requires err to be non-nil and to contain every want.
func wantInError(t *testing.T, label string, err error, want ...string) {
	t.Helper()
	if err == nil {
		t.Errorf("%s: expected an error, got none", label)
		return
	}
	for _, w := range want {
		if !strings.Contains(err.Error(), w) {
			t.Errorf("%s: error %q does not contain %q", label, err, w)
		}
	}
}

// NWP-20260908-07: A RING MAY NOT SET A FLAG THE CONF TEMPLATE DOES NOT DOCUMENT.
//
// The ring confs are the only lever that reaches a fleet, and since NWP-20260908-06 made the conf load a
// MERGE they actually arrive. TestEveryDocumentedConfFlagIsExportedByADaemon walks the other direction --
// documented flags must be exported -- and cannot see this one: a ring can quietly set a key that appears in
// no template, so an operator reading nowhere.conf.example has no way to learn it exists, let alone that it
// is already on for their devices.
func TestEveryRingFlagIsDocumentedInTheConfTemplate(t *testing.T) {
	root := filepath.Join("..", "vendor-common")
	tmpl, err := os.ReadFile(filepath.Join(root, "etc", "nowhere.conf.example"))
	if err != nil {
		t.Skipf("cannot read the conf template (%v)", err)
	}
	ringDir := filepath.Join(root, "etc", "rings")
	entries, err := os.ReadDir(ringDir)
	if err != nil {
		t.Skipf("cannot read %s (%v)", ringDir, err)
	}

	keyRe := regexp.MustCompile(`(?m)^([A-Za-z_][A-Za-z0-9_]*)=`)
	checked := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".conf") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(ringDir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		for _, m := range keyRe.FindAllStringSubmatch(string(b), -1) {
			k := m[1]
			if !strings.HasPrefix(k, "NOWHERE_") {
				continue // GATEWAY_URL, OTA_RING and friends predate the NOWHERE_ convention
			}
			checked++
			// The template presents optional flags commented out, so match either form.
			if !regexp.MustCompile(`(?m)^#?\s*` + regexp.QuoteMeta(k) + `=`).Match(tmpl) {
				t.Errorf("%s sets %s, which nowhere.conf.example does not document. The ring is what reaches "+
					"real devices, so an operator would have a flag live on their handsets that the file "+
					"they were told to read never mentions.", e.Name(), k)
			}
		}
	}
	if checked == 0 {
		t.Fatal("no NOWHERE_* keys found in any ring conf -- the test matched nothing and would pass vacuously")
	}
}
