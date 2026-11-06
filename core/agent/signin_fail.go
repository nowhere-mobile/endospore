package main

// The failed-sign-in record (Q065, NWP-20261106-07, docs/product-decisions.md 2026-10-20 "eighteen
// recommendations accepted"). A gate-filed issue report is built at device scope, which leaves login.log out on
// purpose, so a user build could not say why a sign-in failed. The gate tells the daemon, with SIGNIN-SHOWN, which
// non-blank line it showed; the daemon keeps that code and its age in the state tmpfs (RAM; power-off clears it), and
// for "Couldn't load your data" also the op, the stall that ended it and the worker hold, as ages in seconds.
//
// THE COST, stated once: a gate report the user chooses to file tells the gateway that one sign-in failed and how
// long ago, which goes past the device scope's "no login-attempt history" rule (buildIssueReport's LEAST KNOWLEDGE
// note). It carries no name, p: tag, uid, ref or byte count, and links nothing to a profile or a payer.
//
// Written only for a line the gate showed other than the uniform blank (a throwaway landing, NEEDKEY and the blank
// leave nothing, so a wrong passphrase stays indistinguishable), and dropped at the next sign-in attempt that reaches
// the daemon, whatever its outcome.

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// signinFailFile lives in dest, the state tmpfs (/data/nowhere/state), which ci/check-durable-state.py excludes.
const signinFailFile = ".signin-fail"

// signinFailCode reports whether s is one of the gate's non-blank sign-in lines (NOWHERE-892 maps each to one word).
func signinFailCode(s string) bool {
	switch s {
	case "nostore", "unreachable", "slow", "busy", "phone-storage", "phone", "load":
		return true
	}
	return false
}

// signinFailMu guards the in-run facts and serializes the file write against the drop: SIGNIN-SHOWN is lock-free
// while the drops run under sessionMu, so they need a lock of their own.
var (
	signinFailMu sync.Mutex
	inRunHeld    bool
	inRunOp      string
	inRunStallS  int64
	inRunHoldS   int64
)

// noteInRun keeps what the last worker run looked like until the gate says whether it showed a failure for it.
func noteInRun(op string, stallS, holdS int64) {
	signinFailMu.Lock()
	inRunHeld, inRunOp, inRunStallS, inRunHoldS = true, op, stallS, holdS
	signinFailMu.Unlock()
}

// inRunFacts: stall is the time since the worker's progress line last changed (t0 when it never did), hold the time
// since t0, in whole seconds. A negative span is 0.
func inRunFacts(t0, lastChange, now time.Time) (stallS, holdS int64) {
	from := t0
	if lastChange.After(t0) {
		from = lastChange
	}
	secs := func(d time.Duration) int64 {
		if d < 0 {
			return 0
		}
		return int64(d / time.Second)
	}
	return secs(now.Sub(from)), secs(now.Sub(t0))
}

// recordSigninShown writes `<code>\t<unix>`, plus `\t<op>\t<stall_s>\t<hold_s>` for "load" while in-run facts are held.
func recordSigninShown(dest, code string, now time.Time) error {
	if !signinFailCode(code) {
		return fmt.Errorf("signin-shown: code outside the vocabulary")
	}
	signinFailMu.Lock()
	defer signinFailMu.Unlock()
	line := code + "\t" + strconv.FormatInt(now.Unix(), 10)
	if code == "load" && inRunHeld {
		line += fmt.Sprintf("\t%s\t%d\t%d", inRunOp, inRunStallS, inRunHoldS)
	}
	path := filepath.Join(dest, signinFailFile)
	return writeAtomic(path+".tmp", path, []byte(line+"\n"))
}

// dropSigninFail removes the record and forgets the in-run facts.
func dropSigninFail(dest string) {
	signinFailMu.Lock()
	defer signinFailMu.Unlock()
	path := filepath.Join(dest, signinFailFile)
	os.Remove(path)
	os.Remove(path + ".tmp")
	inRunHeld, inRunOp, inRunStallS, inRunHoldS = false, "", 0, 0
}

// signinFailMarker is the report's view of the record, the lastRebootMarker shape: no file, no keys; an unreadable or
// malformed file self-declares under last_signin_failure, and never echoes the file's bytes.
func signinFailMarker(dest string, now time.Time) map[string]string {
	b, err := os.ReadFile(filepath.Join(dest, signinFailFile))
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return map[string]string{"last_signin_failure": "unreadable: " + err.Error()}
	}
	bad := func(why string) map[string]string {
		return map[string]string{"last_signin_failure": "unparseable: " + why}
	}
	line, _, _ := strings.Cut(string(b), "\n")
	f := strings.Split(line, "\t")
	if len(f) != 2 && len(f) != 5 {
		return bad(fmt.Sprintf("%d fields", len(f)))
	}
	if !signinFailCode(f[0]) {
		return bad("unknown code")
	}
	at, err := strconv.ParseInt(f[1], 10, 64)
	if err != nil {
		return bad("bad timestamp")
	}
	out := map[string]string{
		"last_signin_failure":       f[0],
		"last_signin_failure_age_s": strconv.FormatInt(now.Unix()-at, 10),
	}
	if len(f) == 5 {
		if f[0] != "load" {
			return bad("facts on a non-load code")
		}
		stall, e1 := strconv.ParseInt(f[3], 10, 64)
		hold, e2 := strconv.ParseInt(f[4], 10, 64)
		if e1 != nil || e2 != nil || stall < 0 || hold < 0 || f[2] == "" || strings.Trim(f[2], "abcdefghijklmnopqrstuvwxyz") != "" {
			return bad("bad facts")
		}
		out["last_signin_failure_op"] = f[2]
		out["last_signin_failure_stall_s"] = f[3]
		out["last_signin_failure_hold_s"] = f[4]
	}
	return out
}

// mergeSigninFail adds the record to a gate report's status. Device scope only; it runs after the chooser's own
// status was merged, and clears any chooser-sent key of the same family, so the daemon's record is the only one.
func mergeSigninFail(status map[string]string, dest string, deviceScope bool, now time.Time) {
	if !deviceScope || status == nil {
		return
	}
	for k := range status {
		if strings.HasPrefix(k, "last_signin_failure") {
			delete(status, k)
		}
	}
	for k, v := range signinFailMarker(dest, now) {
		status[k] = v
	}
}

// handleSigninShown: "SIGNIN-SHOWN\n<code>\n" -> OK | ERR (the write failed) | ERR-ARGS (anything but a vocabulary word).
func handleSigninShown(conn net.Conn, r *bufio.Reader, dest string) {
	line, err := r.ReadString('\n')
	code := strings.TrimRight(line, "\r\n")
	if err != nil || !signinFailCode(code) {
		fmt.Fprint(conn, "ERR-ARGS\n")
		return
	}
	if err := recordSigninShown(dest, code, time.Now()); err != nil {
		fmt.Fprintf(os.Stderr, "[logind] signin-shown %s: not recorded (%v)\n", code, err)
		fmt.Fprint(conn, "ERR\n")
		return
	}
	fmt.Fprintf(os.Stderr, "[logind] signin-shown %s\n", code)
	fmt.Fprint(conn, "OK\n")
}
