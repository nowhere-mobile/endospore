package main

// NWP-20260908-12: THE DENIAL COLLECTOR NEVER RAN — IT COULD NOT FIND ITS OWN BINARIES.
//
// avcDenials exec'd bare names, resolved through $PATH, and the login daemon's PATH does not contain
// /system/bin. So every attempt on a real handset died at
//     logcat (exec: "logcat": executable file not found in $PATH)
// before any permission was ever consulted. Both binaries exist and are world-executable on device.
//
// ⚠ AND THAT MATTERS BEYOND THE ONE-LINE FIX. avcSection's own comment explains the empty section as a
// SEPOLICY problem -- "logcat needs logd read access and dmesg needs CAP_SYSLOG and the login daemon's
// domain (nowhere), where the collector runs, may have neither on a user build" -- and cites all six
// tickets ever filed as evidence. That hypothesis may be right, but it was never tested: the exec failed first, on every one of them. A cause that has never been
// reached is a guess wearing evidence's clothes.
//
// On a locked user build the issue reporter is the ONLY diagnostic channel, so a denial section that cannot
// run is not a cosmetic defect.

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// avcCall is one command avcDenials asked readDiagFn to run.
type avcCall struct {
	name string
	argv []string
}

// stubAvc swaps avcSourceCmds for table and readDiagFn for a recorder, restoring both when the test ends.
// The recorder returns out[name] as the command's output and errs[name] as its failure.
func stubAvc(t *testing.T, table [][]string, out, errs map[string]string) *[]avcCall {
	t.Helper()
	origFn, origTable := readDiagFn, avcSourceCmds
	t.Cleanup(func() { readDiagFn, avcSourceCmds = origFn, origTable })
	avcSourceCmds = table
	calls := &[]avcCall{}
	readDiagFn = func(name string, argv ...string) ([]byte, diagSource) {
		*calls = append(*calls, avcCall{name, append([]string{}, argv...)})
		return []byte(out[name]), diagSource{name: name, err: errs[name]}
	}
	return calls
}

// THE FIX, ASSERTED ON BEHAVIOUR. Neither binary exists on a host, so the exec is swapped for a recorder
// and the test sees exactly what avcDenials runs. It runs a distinctive table, so a loop that stops reading
// avcSourceCmds (an inline literal, say) records the wrong commands; the real table is then checked on its
// own for the property the bug violated.
func TestAvcCollectorUsesAbsolutePaths(t *testing.T) {
	realTable := avcSourceCmds
	calls := stubAvc(t, [][]string{{"/test/a", "-x"}, {"/test/b"}}, nil, nil)

	avcDenials(100)

	want := []avcCall{{"/test/a", []string{"-x"}}, {"/test/b", []string{}}}
	if !reflect.DeepEqual(*calls, want) {
		t.Errorf("avcDenials ran %+v, want %+v -- it no longer runs avcSourceCmds, in order", *calls, want)
	}

	if len(realTable) == 0 {
		t.Fatal("avcSourceCmds is empty -- the absolute-path check below would pass vacuously")
	}
	for _, c := range realTable {
		if len(c) == 0 || !filepath.IsAbs(c[0]) {
			t.Errorf("denial source %q is not an absolute path. A bare name resolves through $PATH, and the "+
				"daemon's PATH does not include /system/bin -- so it fails with 'executable file not found' "+
				"before any permission is checked, and the report says the sources were unreadable for the "+
				"wrong reason.", c)
		}
	}
}

// avcDenials' own logic -- filter, dedup, cap, newest-wins, early stop, failure recording -- driven through
// the seam against a swapped table, so no case depends on the real table's length.
func TestAvcDenialsCollects(t *testing.T) {
	const (
		d1 = `avc: denied { read } for comm="a" scontext=u:r:x:s0 tcontext=u:object_r:y:s0 tclass=file`
		d2 = `avc: denied { write } for comm="b" scontext=u:r:x:s0 tcontext=u:object_r:y:s0 tclass=file`
		d3 = `avc: denied { open } for comm="c" scontext=u:r:x:s0 tcontext=u:object_r:y:s0 tclass=file`
	)
	two := [][]string{{"/test/a"}, {"/test/b"}}

	t.Run("keeps only avc denials, trimmed", func(t *testing.T) {
		stubAvc(t, two, map[string]string{
			"/test/a": "  " + d1 + "\t\n" +
				`avc: granted { read } for comm="a"` + "\n" + // avc: but not denied
				"open denied by something else\n" + // denied but not avc:
				"\n",
		}, nil)
		out, _ := avcDenials(100)
		if want := []string{d1}; !reflect.DeepEqual(out, want) {
			t.Errorf("out = %q, want %q", out, want)
		}
	})

	t.Run("dedups within and across sources", func(t *testing.T) {
		stubAvc(t, two, map[string]string{
			"/test/a": d1 + "\n" + d1 + "\n" + d2 + "\n",
			"/test/b": d2 + "\n  " + d1 + "\n" + d3 + "\n",
		}, nil)
		out, srcs := avcDenials(100)
		if want := []string{d1, d2, d3}; !reflect.DeepEqual(out, want) {
			t.Errorf("out = %q, want %q", out, want)
		}
		if len(srcs) != 2 {
			t.Errorf("srcs = %+v, want both sources recorded", srcs)
		}
	})

	t.Run("stops at max and keeps the newest", func(t *testing.T) {
		calls := stubAvc(t, two, map[string]string{
			"/test/a": d1 + "\n" + d2 + "\n" + d3 + "\n",
			"/test/b": `avc: denied { never } from the source that must not run` + "\n",
		}, nil)
		out, srcs := avcDenials(2)
		if len(*calls) != 1 || len(srcs) != 1 || srcs[0].name != "/test/a" {
			t.Errorf("calls = %+v, srcs = %+v -- the second source must not be attempted once max is reached",
				*calls, srcs)
		}
		if want := []string{d2, d3}; !reflect.DeepEqual(out, want) {
			t.Errorf("out = %q, want the newest two %q", out, want)
		}
	})

	t.Run("records a failing source and still runs the next", func(t *testing.T) {
		calls := stubAvc(t, two,
			map[string]string{"/test/b": d1 + "\n"},
			map[string]string{"/test/a": "exec: boom"})
		out, srcs := avcDenials(100)
		if want := []diagSource{{name: "/test/a", err: "exec: boom"}, {name: "/test/b"}}; !reflect.DeepEqual(srcs, want) {
			t.Errorf("srcs = %+v, want %+v", srcs, want)
		}
		if len(*calls) != 2 {
			t.Errorf("calls = %+v, want the second source run after the first failed", *calls)
		}
		if want := []string{d1}; !reflect.DeepEqual(out, want) {
			t.Errorf("out = %q, want %q", out, want)
		}
	})
}

// AND THE HONEST-FAILURE REPORTING MUST SURVIVE. The value of DIA-20260811-10 is that an unreadable source
// says so; a fix that made the section silently empty again would be worse than the bug.
func TestAvcSectionStillDistinguishesUnreadableFromClean(t *testing.T) {
	unreadable := avcSection(nil, []diagSource{{name: "/system/bin/logcat", err: "boom"}}, nil)
	joined := strings.Join(unreadable, "\n")
	if !strings.Contains(joined, "NO source could be read") ||
		!strings.Contains(joined, "does NOT mean the device is denial-free") {
		t.Errorf("an all-sources-failed report no longer says so: %q", joined)
	}

	clean := strings.Join(avcSection(nil, []diagSource{{name: "/system/bin/logcat"}}, nil), "\n")
	if !strings.Contains(clean, "no denials in the captured window") {
		t.Errorf("a readable-but-clean report no longer says so: %q", clean)
	}
	if strings.Contains(clean, "NO source could be read") {
		t.Error("a readable source was reported as unreadable -- the two states must stay distinguishable")
	}
}
