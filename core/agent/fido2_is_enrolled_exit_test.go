package main

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// NWP-20261020-01: roamd's `in` op maps the exit status of `fido2-is-enrolled` -- 0 = key needed, 1 = not
// enrolled, 5 = the store could not be read -- and answers BLANK NET on 5 instead of committing a key-enrolled
// profile's sign-in keyless. This pins the premise on the real CLI case: only "no head / not a vault / no fido2
// slot" exits 1, and a read that failed in transport exits exitStoreUnreachable. It passes on the code as it
// stands; it exists so the mapping in roamd cannot silently lose its input.

// TestFido2IsEnrolledHelperProcess is not a test: it is the agent, re-executed from the test binary by
// TestFido2IsEnrolledExitStatus, running the real `fido2-is-enrolled` case through main().
func TestFido2IsEnrolledHelperProcess(t *testing.T) {
	a := os.Getenv("NOWHERE_FIDO2_ENROLLED_HELPER")
	if a == "" {
		return
	}
	os.Args = append([]string{"nowhere_agent", "fido2-is-enrolled"}, strings.Split(a, "\n")...)
	main()
	os.Exit(0)
}

func TestFido2IsEnrolledExitStatus(t *testing.T) {
	os.Unsetenv("NOWHERE_FIDO2_HMAC")
	defer os.Unsetenv("NOWHERE_FIDO2_HMAC")
	const pass = "fido2 probe horse battery staple"
	live := newHTTPStore(t)
	createVault(live, "probekeyed", pass)
	c, s, h := fakeKey(t, "probe-key")
	if err := enrollFido2(live, "probekeyed", pass, c, s, h, false, "", nil); err != nil {
		t.Fatalf("enroll: %v", err)
	}
	createVault(live, "probeplain", pass)

	run := func(store, name string) (int, string) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestFido2IsEnrolledHelperProcess$", "-test.count=1")
		env := []string{"NOWHERE_FIDO2_ENROLLED_HELPER=" + strings.Join([]string{store, name, pass}, "\n")}
		for _, kv := range os.Environ() {
			k := kv[:strings.IndexByte(kv+"=", '=')]
			switch k {
			case "GATEWAY_URL", "S3_ACCESS_KEY", "NOWHERE_CHUNK_CACHE", "NOWHERE_STATE", "NOWHERE_PHASE", "NOWHERE_COMPRESS":
				continue // a plain-HTTP store, no cache, no session state
			}
			env = append(env, kv)
		}
		cmd.Env = append(env, "NOWHERE_STATE="+t.TempDir())
		out, err := cmd.CombinedOutput()
		if err == nil {
			return 0, string(out)
		}
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("running the agent: %v", err)
		}
		return ee.ExitCode(), string(out)
	}
	for _, c := range []struct {
		what, store, name string
		want              int
	}{
		{"a vault with an enrolled fido2 slot", live, "probekeyed", 0},
		{"a vault with no key", live, "probeplain", 1},
		{"an absent profile", live, "probeabsent", 1},
		{"a store that cannot be reached", deadStore(t), "probekeyed", exitStoreUnreachable},
	} {
		if code, out := run(c.store, c.name); code != c.want {
			t.Errorf("fido2-is-enrolled on %s exited %d, want %d\n%s", c.what, code, c.want, out)
		}
	}
}
