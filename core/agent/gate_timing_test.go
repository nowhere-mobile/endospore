package main

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// NWP-20260820-29. gatePhaseOK is the whole validation on GATE-TIMING's only string field, and that field is
// concatenated into a line of the DURABLE log -- the same log the issue reporter reads back and ships off the
// device. The gate is the device owner and already drives the entire login over this socket, so this is not a
// trust boundary; it is here so that the day someone adds a second caller, a newline or a control character
// cannot forge log lines. Pinning it costs nothing and the alternative is finding out from a report.
//
// NWP-20261118-19. A charset is not enough: "alice" passed [a-z][a-z0-9-]{0,23}, and the line is written
// unquoted, so log_scrub's quoted-token rule cannot take a profile name out of it (the IDLE-TRACE finding,
// NWP-20261106-19). The phase must now be one of gateTimingPhases, the phases the gate sends.
// TestGateTimingPhasesCoverTheChooser keeps that set and the chooser's gateTiming call sites in step.
func TestGatePhaseOK(t *testing.T) {
	// Literals, not a range over gateTimingPhases: a set that loses a phase must fail here too.
	good := []string{
		"tap-to-createuser",
		"createroamuser-total",
		"create-user",
		"seed-ssaid",
		"start-user",
		"clear-restrictions",
		"dozeapply",
		"prefs-unread",
	}
	for _, s := range good {
		if !gatePhaseOK(s) {
			t.Errorf("gatePhaseOK(%q) = false, want true", s)
		}
	}

	bad := []string{
		"alice",                     // a profile name -- the charset let it through
		"bob2",                      // a profile name with a digit
		"my-name",                   // a profile name with a dash
		"a",                         // charset-valid, not a phase
		"x1",                        // charset-valid, not a phase
		"a-b-c",                     // charset-valid, not a phase
		"abcdefghijklmnopqrstuvwx",  // 24, the old limit, not a phase
		"dozeapply ",                // a near miss: the handler trims, gatePhaseOK must not
		"Dozeapply",                 // a near miss: uppercase
		"",                          // empty
		"abcdefghijklmnopqrstuvwxy", // 25, one over
		"Create-User",               // uppercase
		"1abc",                      // leading digit
		"-abc",                      // leading dash
		"a b",                       // space
		"a\nb",                      // NEWLINE -- the one that would forge a log line
		"a\tb",                      // tab
		"a_b",                       // underscore
		"a.b",                       // dot
		"a/b",                       // slash
		"a\x00b",                    // NUL
		"héllo",                     // non-ASCII
		"[gate] TIMING x 0ms",       // a whole forged line
	}
	for _, s := range bad {
		if gatePhaseOK(s) {
			t.Errorf("gatePhaseOK(%q) = true, want false", s)
		}
	}
}

// gateTimingMinCalls is the fewest gateTiming calls the chooser scan may find. Fewer means the method was
// renamed or the scan broke, and a coverage check over nothing would pass.
const gateTimingMinCalls = 7

// TestGateTimingPhasesCoverTheChooser reads the chooser's sources and collects the first argument of every
// gateTiming call. Each must be ONE string literal (a variable phase is the hole this slice closes), each
// literal must be in gateTimingPhases, and each entry of gateTimingPhases must be sent by some call. A new
// gateTiming phase in the chooser fails here until it is added to the set.
func TestGateTimingPhasesCoverTheChooser(t *testing.T) {
	files, _ := filepath.Glob("../chooser/src/com/nowhere/chooser/*.java")
	if len(files) == 0 {
		t.Fatal("no chooser sources found under ../chooser/src/com/nowhere/chooser")
	}
	sent := map[string]bool{}
	calls := 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		base := filepath.Base(f)
		// idleTraceCalls skips the declaration (`void gateTiming(`) and any longer name ending in gateTiming.
		for _, a := range idleTraceCalls(string(raw), "gateTiming") {
			calls++
			arg := strings.TrimSpace(idleTraceSplitArgs(a)[0])
			lits := idleTraceJavaStrings(arg)
			if len(arg) < 2 || arg[0] != '"' || arg[len(arg)-1] != '"' || len(lits) != 1 {
				t.Errorf("%s: gateTiming(%s, ...): the phase is not one string literal", base, arg)
				continue
			}
			sent[lits[0]] = true
			if !gateTimingPhases[lits[0]] {
				t.Errorf("%s: gateTiming(%q, ...) sends a phase gateTimingPhases does not hold", base, lits[0])
			}
		}
	}
	if calls < gateTimingMinCalls {
		t.Fatalf("the scan found %d gateTiming calls, want at least %d (renamed method or broken scan?)",
			calls, gateTimingMinCalls)
	}
	for p := range gateTimingPhases {
		if !sent[p] {
			t.Errorf("gateTimingPhases holds %q, but no chooser gateTiming call sends it", p)
		}
	}
}

// TestGateTimingRefusesAnUnknownPhase calls handleGateTiming directly: the dispatcher has already read the
// GATE-TIMING verb line, so the reader holds only the phase and the ms lines. An unknown phase answers ERR and
// prints nothing. The positive control proves the stdout capture works and pins the line format.
func TestGateTimingRefusesAnUnknownPhase(t *testing.T) {
	run := func(req string) (reply, out string) {
		srv, cli := net.Pipe()
		got := make(chan string, 1)
		go func() {
			b, _ := bufio.NewReader(cli).ReadString('\n')
			got <- b
		}()
		out = captureStdout(t, func() {
			handleGateTiming(srv, bufio.NewReader(strings.NewReader(req)))
		})
		srv.Close()
		reply = <-got
		cli.Close()
		return reply, out
	}

	reply, out := run("alice\n12\n")
	if reply != "ERR\n" {
		t.Errorf("phase \"alice\": reply %q, want \"ERR\\n\"", reply)
	}
	if strings.Contains(out, "TIMING") || strings.Contains(out, "alice") {
		t.Errorf("phase \"alice\": stdout holds %q, want nothing", out)
	}

	reply, out = run("dozeapply\n12\n")
	if reply != "OK\n" {
		t.Errorf("phase \"dozeapply\": reply %q, want \"OK\\n\"", reply)
	}
	if out != "[gate] TIMING dozeapply 12ms\n" {
		t.Errorf("phase \"dozeapply\": stdout %q, want %q", out, "[gate] TIMING dozeapply 12ms\n")
	}
}
