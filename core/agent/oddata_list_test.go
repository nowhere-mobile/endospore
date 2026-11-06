package main

// NWP-20261125-08 (h53 #1): RESTORE-ODDATA's list form. One request carries up to odRestoreMaxList packages; each
// is restored by its own odrestore op and answered by its own line before the next op starts, and a sign-out
// stops the list between packages.

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

type odListOp struct{ op, pkg, kind string }

// odListFake replaces odRestoreWorker. each, when set, runs inside the op for the i-th call (from 1) before it
// answers "OK <pkg>".
func odListFake(t *testing.T, each func(i int, pkg string)) func() []odListOp {
	t.Helper()
	bootWakeFakes(t)
	old := odRestoreWorker
	t.Cleanup(func() { odRestoreWorker = old })
	var mu sync.Mutex
	var ops []odListOp
	odRestoreWorker = func(dest, op, name, pass, uid, seSecret, kind, srcUnit, intent string, onProg func(string)) string {
		mu.Lock()
		ops = append(ops, odListOp{op, srcUnit, kind})
		i := len(ops)
		mu.Unlock()
		if each != nil {
			each(i, srcUnit)
		}
		return "OK " + srcUnit + "\n"
	}
	return func() []odListOp {
		mu.Lock()
		defer mu.Unlock()
		return append([]odListOp(nil), ops...)
	}
}

// odListSession makes dest a signed-in, roamed session.
func odListSession(t *testing.T, dest, profile string) {
	t.Helper()
	if err := markRoamSession(dest, profile, "pw-"+profile, "11", ""); err != nil {
		t.Fatal(err)
	}
}

// odListServe runs the handler on one end of a pipe and sends every line the client end reads on the channel,
// which it closes at EOF. done closes when the handler returns.
func odListServe(dest, payload string) (lines <-chan string, done <-chan struct{}) {
	cli, srv := net.Pipe()
	ch := make(chan string, 64)
	fin := make(chan struct{})
	go func() { handleRestoreOdData(srv, dest, payload); close(fin); srv.Close() }()
	go func() {
		defer close(ch)
		r := bufio.NewReader(cli)
		for {
			l, err := r.ReadString('\n')
			if err != nil {
				return
			}
			ch <- strings.TrimRight(l, "\n")
		}
	}()
	return ch, fin
}

// odListAll serves payload and takes every reply line.
func odListAll(t *testing.T, dest, payload string) []string {
	t.Helper()
	lines, _ := odListServe(dest, payload)
	return odListRead(t, lines)
}

// odListRead takes every line up to EOF, each bounded by 5 s.
func odListRead(t *testing.T, lines <-chan string) []string {
	t.Helper()
	var got []string
	for {
		select {
		case l, ok := <-lines:
			if !ok {
				return got
			}
			got = append(got, l)
		case <-time.After(5 * time.Second):
			t.Fatalf("no EOF after %q", got)
		}
	}
}

func odListEqual(t *testing.T, what string, got, want []string) {
	t.Helper()
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("%s: got %q want %q", what, got, want)
	}
}

func TestOddataList_OneNameIsToday(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odlist-one")
	ops := odListFake(t, nil)
	odListEqual(t, "reply", odListAll(t, dest, "org.fossify.math"), []string{"OK org.fossify.math"})
	got := ops()
	if len(got) != 1 || got[0] != (odListOp{"odrestore", "org.fossify.math", ""}) {
		t.Errorf("ops: got %+v want one odrestore op for org.fossify.math with an empty kind", got)
	}
}

func TestOddataList_ThreeInOrder(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odlist-three")
	pkgs := []string{"org.fossify.math", "org.fossify.notes", "org.fossify.clock"}
	var lines <-chan string
	var early []string
	ready := make(chan struct{})
	ops := odListFake(t, func(i int, pkg string) {
		<-ready
		if i == 1 {
			return
		}
		// Op i may start only after line i-1 was written. A blocking receive, bounded: on net.Pipe the
		// handler's write returns when the client's Read takes the bytes, before the line reaches the channel.
		select {
		case l := <-lines:
			early = append(early, l)
			if want := pkgs[i-2] + " OK " + pkgs[i-2]; l != want {
				t.Errorf("before op %d: line %q want %q", i, l, want)
			}
		case <-time.After(5 * time.Second):
			t.Errorf("op %d started before reply %d was written", i, i-1)
		}
	})
	var done <-chan struct{}
	lines, done = odListServe(dest, strings.Join(pkgs, " "))
	close(ready)
	// The fake ops take lines 1 and 2; this side reads only after the handler returns.
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("the handler did not return")
	}
	got := append(early, odListRead(t, lines)...)
	odListEqual(t, "replies", got, []string{
		"org.fossify.math OK org.fossify.math",
		"org.fossify.notes OK org.fossify.notes",
		"org.fossify.clock OK org.fossify.clock",
		"END 3",
	})
	all := ops()
	if len(all) != 3 {
		t.Fatalf("ops: got %+v want 3", all)
	}
	tok := regexp.MustCompile(`^(b[0-9a-f]{8})\.([0-9]+)\.3$`)
	var b string
	for i, o := range all {
		m := tok.FindStringSubmatch(o.kind)
		if o.op != "odrestore" || o.pkg != pkgs[i] || m == nil || m[2] != string(rune('1'+i)) {
			t.Errorf("op %d: got %+v want odrestore %s with token b<8 hex>.%d.3", i+1, o, pkgs[i], i+1)
			continue
		}
		if i == 0 {
			b = m[1]
		} else if m[1] != b {
			t.Errorf("op %d: b-part %s, op 1 had %s", i+1, m[1], b)
		}
	}
}

func TestOddataList_CancelStops(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odlist-cancel")
	// The fake creates od-cancel inside op 1, so it exists before the handler's check for package 2. This is the
	// deterministic form of "a sign-out begins after the first reply".
	ops := odListFake(t, func(i int, pkg string) {
		if i == 1 {
			if err := os.WriteFile(filepath.Join(dest, odCancelFile), []byte("1\n"), 0o600); err != nil {
				t.Errorf("od-cancel: %v", err)
			}
		}
	})
	got := odListAll(t, dest, "org.fossify.math org.fossify.notes org.fossify.clock")
	odListEqual(t, "replies", got, []string{
		"org.fossify.math OK org.fossify.math",
		"org.fossify.notes STOPPED",
		"org.fossify.clock STOPPED",
		"END 1",
	})
	if all := ops(); len(all) != 1 || all[0].pkg != "org.fossify.math" || !strings.HasSuffix(all[0].kind, ".1.3") {
		t.Errorf("ops: got %+v want one op for org.fossify.math with a .1.3 token", all)
	}
}

func TestOddataList_RefusesWholeList(t *testing.T) {
	dest := t.TempDir()
	odListSession(t, dest, "odlist-refuse")
	ops := odListFake(t, nil)
	var seventeen []string
	for i := 0; i < 17; i++ {
		seventeen = append(seventeen, "org.fossify.app"+string(rune('a'+i)))
	}
	for what, payload := range map[string]string{
		"an invalid name": "org.fossify.math ../etc org.fossify.notes",
		"a duplicate":     "org.fossify.math org.fossify.notes org.fossify.math",
		"17 names":        strings.Join(seventeen, " "),
	} {
		odListEqual(t, what, odListAll(t, dest, payload), []string{"ERR-PKG"})
	}
	if all := ops(); len(all) != 0 {
		t.Errorf("a refused list ran ops: %+v", all)
	}
}

func TestOddataList_NoSessionOnce(t *testing.T) {
	dest := t.TempDir()
	ops := odListFake(t, nil)
	odListEqual(t, "reply", odListAll(t, dest, "org.fossify.math org.fossify.notes"), []string{"NONE"})
	if all := ops(); len(all) != 0 {
		t.Errorf("no session ran ops: %+v", all)
	}
}
