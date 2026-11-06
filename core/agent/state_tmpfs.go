package main

// NWP-20261117-07 (decision #30, docs/product-decisions.md): the state dir must be a tmpfs before anything is written
// into it. nowhere.rc mounts the tmpfs in the same trigger that starts nowhere_login; if that mount fails, the dir is a
// plain directory on durable f2fs, and a sign-in would leave .roamsession (name and passphrase), roam.req, the wallet,
// the fido2 hmac stash and the telephony inbox there, where they survive power-off. So the sign-in, create and resume
// verbs refuse with ERR-NOTMPFS at their dispatch, before any request line is read or any credential work runs: the
// answer is the same for every name and passphrase.
//
// ⚠ ONLY A DEFINITE "NO" REFUSES. A statfs that FAILS is unknown and never refuses: on every enforcing build the daemon
// (u:r:nowhere:s0) is denied filesystem getattr on the MOUNTED state tmpfs, whose superblock the rc's context= mount
// labels nowhere_data_file, a file_type nowhere.te grants no filesystem class on (the NWP-20260831-12 class). Refusing on
// the error would refuse every sign-in on every enforcing build while off-device CI stays green. A failed mount leaves a
// plain /data dir, whose labeledfs superblock this domain can statfs (dataFreeBytes does), so a missing tmpfs still
// answers a definite no.

import (
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// stateStatfs returns the f_type of dir's filesystem. A var so tests can answer for a temp dir that is not a tmpfs.
var stateStatfs = func(dir string) (int64, error) {
	var st unix.Statfs_t
	if err := unix.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Type), nil
}

type tmpfsAnswer int

const (
	tmpfsUnknown tmpfsAnswer = iota // statfs failed: never refuses
	tmpfsYes
	tmpfsNo
)

// word is the fixed issue-report value of a.
func (a tmpfsAnswer) word() string {
	switch a {
	case tmpfsYes:
		return "yes"
	case tmpfsNo:
		return "no"
	}
	return "unknown"
}

// stateTmpfs answers whether dir is on a tmpfs, with the f_type statfs gave and its error.
func stateTmpfs(dir string) (tmpfsAnswer, int64, error) {
	ft, err := stateStatfs(dir)
	if err != nil {
		return tmpfsUnknown, 0, err
	}
	if ft == unix.TMPFS_MAGIC {
		return tmpfsYes, ft, nil
	}
	return tmpfsNo, ft, nil
}

// loginStateDir is the login daemon's state dir: $NOWHERE_STATE, else stateDirDefault (as loginDaemon reads it).
func loginStateDir() string {
	if d := os.Getenv("NOWHERE_STATE"); d != "" {
		return d
	}
	return stateDirDefault
}

// stateTmpfsStartLine is the line loginDaemon logs once at start.
func stateTmpfsStartLine(dest string) string {
	a, ft, err := stateTmpfs(dest)
	switch a {
	case tmpfsYes:
		return fmt.Sprintf("[logind] state dir %s: tmpfs", dest)
	case tmpfsNo:
		return fmt.Sprintf("[logind] state dir %s: NOT a tmpfs (f_type 0x%x) -- sign-in, create and resume answer ERR-NOTMPFS (#30)", dest, ft)
	}
	return fmt.Sprintf("[logind] state dir %s: tmpfs check unknown (%v) -- not refusing (#30)", dest, err)
}

// refuseNoTmpfs answers ERR-NOTMPFS when dest is DEFINITELY not a tmpfs and reports whether it did. It runs before the
// request lines are read, so the reply and the log line carry nothing of the name or passphrase.
func refuseNoTmpfs(conn net.Conn, dest string) bool {
	a, ft, _ := stateTmpfs(dest)
	if a != tmpfsNo {
		return false
	}
	fmt.Fprintf(os.Stderr, "[logind] sign-in refused: state dir %s is NOT a tmpfs (f_type 0x%x) (#30)\n", dest, ft)
	fmt.Fprint(conn, "ERR-NOTMPFS\n")
	return true
}
