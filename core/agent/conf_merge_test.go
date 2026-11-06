package main

// NWP-20260908-06: THE TWO CONFS MERGE. A RING SETTING MUST REACH A PROVISIONED DEVICE.
//
// The daemons used to pick ONE file: `CONF=/data/...; [ -f "$CONF" ] || CONF=/system/...`. On lynx the two
// shared ZERO keys -- /data carried GATEWAY_URL, NOWHERE_MULTIDEVICE and NOWHERE_CARRY_ESSENTIAL, while the
// ring supplied NOWHERE_GATEWAY_DEFAULT, NOWHERE_SEQ_GUARD and OTA_RING -- so all three ring keys were
// discarded, with no log line and no error.
//
// That is not a hypothetical. NWP-20260907-16 shipped the sequential guard to the beta ring; NWP-20260907-22
// then measured 29 detections with `refusal=false` throughout and worked out why: the flag was correct and
// the delivery was not. An evening of device time went into measuring a setting that was never applied.
//
// These tests run against the SHELL SOURCE, because that is where the rule lives. There is no Go code path
// to exercise -- which is exactly why it went unnoticed for so long.

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// confLoadingDaemons are the scripts that source a conf. Every one must load it the same way: four copies of
// a load rule is how the two layers drift apart, and this rule has already cost two silent flags.
var confLoadingDaemons = []string{
	"nowhere_roamd.sh", "nowhere_login.sh", "nowhere_mediad.sh", "nowhere_otad.sh",
}

func daemonSource(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "vendor-common", "bin", name))
	if err != nil {
		t.Skipf("cannot read %s (%v) -- this test needs the source tree", name, err)
	}
	return strings.ReplaceAll(string(b), "\r\n", "\n")
}

// THE MERGE ITSELF. Both files are sourced, ring FIRST so the device conf overrides it per key.
func TestConfLoadIsAMergeNotAReplace(t *testing.T) {
	for _, d := range confLoadingDaemons {
		src := daemonSource(t, d)

		// The old shape picked one file and stopped. Its signature is the `||` fallback assignment.
		if strings.Contains(src, `[ -f "$CONF" ] || CONF=/system/etc/nowhere/nowhere.conf`) {
			t.Errorf("%s still REPLACES: it falls back to the baked conf only when /data is absent, so every "+
				"ring key the device conf does not repeat is silently discarded. That is how "+
				"NOWHERE_SEQ_GUARD was measured for an evening without ever being set.", d)
			continue
		}

		iRing := strings.Index(src, "/system/etc/nowhere/nowhere.conf")
		iDev := strings.Index(src, "/data/nowhere/nowhere.conf")
		if iRing < 0 || iDev < 0 {
			t.Errorf("%s does not name both confs (ring at %d, device at %d)", d, iRing, iDev)
			continue
		}
		if iRing > iDev {
			t.Errorf("%s sources the DEVICE conf before the ring, so the ring would win. The order is the "+
				"contract: ring is the floor, the device overrides it key by key -- otherwise enrolment's "+
				"GATEWAY_URL is overwritten by the baked default on every boot.", d)
		}
	}
}

// AND ALL FOUR MUST DO IT IDENTICALLY. The rule is duplicated by necessity (four standalone scripts on
// /system/bin); this is what stops the copies drifting.
func TestEveryDaemonLoadsTheConfIdentically(t *testing.T) {
	loadRe := regexp.MustCompile(`(?s)CONF=\n(for _nwconf in .*?\nunset _nwconf)`)
	var first, firstName string
	for _, d := range confLoadingDaemons {
		m := loadRe.FindStringSubmatch(daemonSource(t, d))
		if m == nil {
			t.Errorf("%s has no recognisable merge block -- either it was rewritten by hand or it does not "+
				"load a conf at all", d)
			continue
		}
		if first == "" {
			first, firstName = m[1], d
			continue
		}
		if m[1] != first {
			t.Errorf("%s loads the conf differently from %s:\n--- %s ---\n%s\n--- %s ---\n%s",
				d, firstName, firstName, first, d, m[1])
		}
	}
	if first == "" {
		t.Fatal("no daemon matched the merge block at all -- the test cannot see what it claims to check")
	}
}

// POSIX ONLY. These run under /system/bin/sh, not bash. `bash -n` is a poor proxy: it accepts constructs the
// device shell has never had, and a conf that fails to load takes the gateway down with it.
func TestConfLoadUsesNoBashisms(t *testing.T) {
	for _, d := range confLoadingDaemons {
		src := daemonSource(t, d)
		if !strings.HasPrefix(src, "#!/system/bin/sh") {
			t.Errorf("%s: unexpected shebang -- this test's premise is that these are POSIX sh", d)
		}
		for _, bad := range []struct{ frag, why string }{
			{"<(", "process substitution"},
			{"[[ ", "the bash [[ test"},
			{"${!", "indirect expansion"},
			{"+=(", "array append"},
		} {
			if strings.Contains(src, bad.frag) {
				t.Errorf("%s uses %s (%q), which /system/bin/sh may not have. A conf load that fails takes "+
					"the gateway with it, and bash -n will not catch this.", d, bad.why, bad.frag)
			}
		}
	}
}

// THE DIAGNOSTIC MUST NEVER PRINT A VALUE. A conf can carry S3 credentials, and roam.log is quoted verbatim
// in support tickets -- the log's own header says "status only -- never creds".
func TestConfMergeDiagnosticLogsKeyNamesOnly(t *testing.T) {
	src := daemonSource(t, "nowhere_roamd.sh")
	i := strings.Index(src, "conf merge:")
	if i < 0 {
		t.Fatal("roamd does not report what the merge did. Without it, 'is my flag live on this handset?' " +
			"is unanswerable on a locked user build -- which is precisely how an evening of measurement " +
			"was spent on a flag that was never set.")
	}
	line := src[i:]
	if j := strings.IndexByte(line, '\n'); j > 0 {
		line = line[:j]
	}
	// It must extract NAMES. The whole point of the `grep -o '...='` + `tr -d '='` shape is that a value can
	// never reach the log; a bare `cat` or a grep without -o would print the credentials themselves.
	if !strings.Contains(src, `grep -o "^[A-Za-z_][A-Za-z0-9_]*=" "$1"`) {
		t.Error("the key extraction is not the name-only form. Anything that prints whole conf LINES puts " +
			"S3_SECRET_KEY into roam.log, which ships in support tickets.")
	}
	for _, leak := range []string{"$S3_", "${S3_", "cat /data/nowhere/nowhere.conf", "cat /system/etc/nowhere/nowhere.conf"} {
		if strings.Contains(line, leak) {
			t.Errorf("the conf-merge log line contains %q -- it must print key NAMES only", leak)
		}
	}
}

// AND THE RING MUST NOT ARM A REFUSAL BY ACCIDENT. Before the merge, a ring value never reached a
// provisioned handset; now it does. NOWHERE_SEQ_GUARD=1 would refuse a divergent seal on ANY data scope, and
// roamd maps that refusal to ERR-REFUSED for the WHOLE logoff -- so sign-out wedges. Only the #media scope is
// exempt, and only when the NWP-20260908-04 carry is on.
func TestRingDoesNotArmTheSequentialRefusal(t *testing.T) {
	dir := filepath.Join("..", "vendor-common", "etc", "rings")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Skipf("cannot read %s (%v)", dir, err)
	}
	checked := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".conf") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		checked++
		for _, ln := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
			if strings.TrimSpace(ln) == "NOWHERE_SEQ_GUARD=1" {
				t.Errorf("%s arms NOWHERE_SEQ_GUARD. Since the conf load became a MERGE this value actually "+
					"reaches provisioned handsets, and a refused seal on any data scope fails the whole "+
					"logoff and leaves the session signed in. Two handsets diverge by construction "+
					"(NWP-20260907-22: 29 detections in one evening across all four scopes), so this would "+
					"wedge sign-out. Turning it on is the open product decision in docs/product-decisions.md.",
					e.Name())
			}
		}
	}
	if checked == 0 {
		t.Fatal("no ring confs found -- the test matched nothing and would pass vacuously")
	}
}

// ---------------------------------------------------------------------------------------------------
// and now RUN it. Everything above reads the source; this executes the extracted block under a real sh,
// because the failure being fixed was behavioural and a shape assertion cannot see a behaviour.
// ---------------------------------------------------------------------------------------------------

// mergeBlock extracts roamd's conf-load block, retargeted at two temp files so it can be run in isolation.
func mergeBlock(t *testing.T, ring, dev string) string {
	t.Helper()
	src := daemonSource(t, "nowhere_roamd.sh")
	i := strings.Index(src, "CONF=\nfor _nwconf in ")
	if i < 0 {
		t.Fatal("cannot find the merge block in roamd -- the extraction has drifted from the source")
	}
	end := strings.Index(src[i:], "unset _nwconf")
	if end < 0 {
		t.Fatal("merge block has no terminator")
	}
	blk := src[i : i+end+len("unset _nwconf")]
	blk = strings.ReplaceAll(blk, "/system/etc/nowhere/nowhere.conf", ring)
	blk = strings.ReplaceAll(blk, "/data/nowhere/nowhere.conf", dev)
	return blk
}

// runMerge executes the real block over the two given conf bodies and reports the resulting variables.
// A body of "" means that file does not exist, which is a distinct case from an empty file.
func runMerge(t *testing.T, ringBody, devBody string, want ...string) map[string]string {
	t.Helper()
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skipf("no POSIX sh available (%v)", err)
	}
	d := t.TempDir()
	ring, dev := filepath.Join(d, "ring.conf"), filepath.Join(d, "dev.conf")
	for p, body := range map[string]string{ring: ringBody, dev: devBody} {
		if body == "" {
			continue // absent on purpose
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	script := mergeBlock(t, ring, dev) + "\n"
	for _, v := range append(want, "CONF") {
		script += "echo \"" + v + "=${" + v + ":-<unset>}\"\n"
	}
	out, err := exec.Command(sh, "-c", script).CombinedOutput()
	if err != nil {
		t.Fatalf("the merge block failed to run under sh: %v\n%s\nscript:\n%s", err, out, script)
	}
	got := map[string]string{}
	for _, ln := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(ln), "="); ok {
			got[k] = v
		}
	}
	return got
}

// THE BUG, EXECUTED. lynx's real geometry: two confs with no keys in common. Before the merge the ring's
// three keys were discarded outright.
func TestConfMerge_RingKeysSurviveADeviceConfThatDoesNotMentionThem(t *testing.T) {
	got := runMerge(t,
		"NOWHERE_GATEWAY_DEFAULT=https://api-beta.example\nNOWHERE_SEQ_GUARD=1\nOTA_RING=beta\n",
		"GATEWAY_URL=https://api-beta.example\nNOWHERE_MULTIDEVICE=0\nNOWHERE_CARRY_ESSENTIAL=0\n",
		"NOWHERE_SEQ_GUARD", "OTA_RING", "GATEWAY_URL", "NOWHERE_MULTIDEVICE")

	if got["NOWHERE_SEQ_GUARD"] != "1" || got["OTA_RING"] != "beta" {
		t.Errorf("ring keys did not survive: NOWHERE_SEQ_GUARD=%q OTA_RING=%q. This is the exact shape that "+
			"made NWP-20260907-16's flag invisible to the fleet for a whole evening of measurement.",
			got["NOWHERE_SEQ_GUARD"], got["OTA_RING"])
	}
	if got["GATEWAY_URL"] == "<unset>" || got["NOWHERE_MULTIDEVICE"] != "0" {
		t.Errorf("device keys were lost: GATEWAY_URL=%q NOWHERE_MULTIDEVICE=%q",
			got["GATEWAY_URL"], got["NOWHERE_MULTIDEVICE"])
	}
}

// PRECEDENCE. The device conf must win on a shared key, or enrolment's GATEWAY_URL is overwritten by the
// baked default on every boot.
func TestConfMerge_TheDeviceConfWinsOnASharedKey(t *testing.T) {
	got := runMerge(t,
		"GATEWAY_URL=https://baked.example\n",
		"GATEWAY_URL=https://enrolled.example\n",
		"GATEWAY_URL")
	if got["GATEWAY_URL"] != "https://enrolled.example" {
		t.Fatalf("GATEWAY_URL=%q -- the ring overrode the device. Enrolment writes this key into /data, so "+
			"the baked default winning would un-enrol the handset on every boot.", got["GATEWAY_URL"])
	}
}

// EACH FILE ALONE, and neither. A device with no /data conf is a fresh flash; one with no ring conf is a
// prod build, which bakes nothing at all.
func TestConfMerge_EitherFileAloneAndNeither(t *testing.T) {
	if got := runMerge(t, "OTA_RING=beta\n", "", "OTA_RING"); got["OTA_RING"] != "beta" {
		t.Errorf("ring-only device lost its ring: %q", got["OTA_RING"])
	}
	if got := runMerge(t, "", "GATEWAY_URL=https://x.example\n", "GATEWAY_URL"); got["GATEWAY_URL"] != "https://x.example" {
		t.Errorf("device-only conf was not loaded: %q", got["GATEWAY_URL"])
	}
	got := runMerge(t, "", "", "GATEWAY_URL")
	if got["CONF"] != "<unset>" && got["CONF"] != "" {
		t.Errorf("CONF=%q with no conf anywhere -- callers test `[ -n \"$CONF\" ]` to decide whether any "+
			"conf loaded, and nowhere_login gates its whole export block on it", got["CONF"])
	}
}

// AND THE NEW SEMANTIC, PINNED. Omitting a key no longer disables it -- that is the deliberate cost of the
// merge, and the ring confs now rely on it (an explicit 0 is how a setting is turned off).
func TestConfMerge_OmittingAKeyNoLongerDisablesIt(t *testing.T) {
	got := runMerge(t, "NOWHERE_SEQ_GUARD=1\n", "GATEWAY_URL=https://x.example\n", "NOWHERE_SEQ_GUARD")
	if got["NOWHERE_SEQ_GUARD"] != "1" {
		t.Fatalf("NOWHERE_SEQ_GUARD=%q -- expected the ring value to stand", got["NOWHERE_SEQ_GUARD"])
	}
	off := runMerge(t, "NOWHERE_SEQ_GUARD=1\n", "NOWHERE_SEQ_GUARD=0\n", "NOWHERE_SEQ_GUARD")
	if off["NOWHERE_SEQ_GUARD"] != "0" {
		t.Fatalf("an explicit 0 in the device conf did not turn it off (%q). Under the merge that is the "+
			"ONLY way to disable a ring setting, and the ring confs document it as such.",
			off["NOWHERE_SEQ_GUARD"])
	}
}

// NWP-20260908-08: THE DIAGNOSTIC MUST BE ONE LINE, AND THIS IS ASSERTED BY RUNNING IT.
//
// It shipped in 2026090802 emitting a MULTI-LINE entry: the key list comes back newline-separated and was
// interpolated inside a quoted echo, so `grep "conf merge:"` showed only the first key and the remaining
// names looked like unrelated log lines. Found on the device, not by the test suite -- because the test that
// existed only checked that no VALUE leaked, which was true and beside the point.
func TestConfMergeDiagnosticIsASingleLine(t *testing.T) {
	sh, err := exec.LookPath("sh")
	if err != nil {
		t.Skipf("no POSIX sh available (%v)", err)
	}
	src := daemonSource(t, "nowhere_roamd.sh")

	// Lift the extractor and the report out of roamd and run them over two real conf files.
	i := strings.Index(src, "_nwkeys() {")
	j := strings.Index(src, "unset _nwring")
	if i < 0 || j < 0 {
		t.Fatal("cannot find the conf-merge diagnostic in roamd -- the extraction has drifted")
	}
	block := src[i : j+len("unset _nwring _nwover _k _j")]

	d := t.TempDir()
	ring, dev := filepath.Join(d, "ring.conf"), filepath.Join(d, "dev.conf")
	if err := os.WriteFile(ring, []byte("NOWHERE_CARRY_ESSENTIAL_MEDIA=1\nNOWHERE_SEQ_GUARD=0\nOTA_RING=beta\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dev, []byte("GATEWAY_URL=https://x.example\nNOWHERE_MULTIDEVICE=0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script := strings.NewReplacer(
		"/system/etc/nowhere/nowhere.conf", ring,
		"/data/nowhere/nowhere.conf", dev,
		`>> "$LOG"`, "",
	).Replace(block)

	out, err := exec.Command(sh, "-c", script).CombinedOutput()
	if err != nil {
		t.Fatalf("the diagnostic failed to run under sh: %v\n%s", err, out)
	}
	got := strings.TrimRight(string(out), "\n")
	if strings.Contains(got, "\n") {
		t.Fatalf("the conf-merge report spans %d lines:\n%s\n\nA multi-line entry breaks `grep \"conf merge:\"` "+
			"-- it shows the first key and drops the rest, which is exactly how this shipped in 2026090802.",
			strings.Count(got, "\n")+1, got)
	}
	// And it must still say something useful, or a one-line empty string would pass.
	for _, want := range []string{"NOWHERE_CARRY_ESSENTIAL_MEDIA", "OTA_RING", "GATEWAY_URL"} {
		if !strings.Contains(got, want) {
			t.Errorf("the report does not name %s: %q", want, got)
		}
	}
	if strings.Contains(got, "https://x.example") {
		t.Errorf("the report leaked a VALUE: %q -- key names only", got)
	}
}
