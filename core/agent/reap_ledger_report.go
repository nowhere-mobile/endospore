package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strconv"
	"strings"
)

// reapLedgerPath is roamd's durable reap ledger (nowhere_roamd.sh: cleanstorage, bootsweep, the recheck); a var so
// tests can point it at a temp file.
var reapLedgerPath = "/data/nowhere/reap-ledger"

// reapLedgerTailBytes bounds what a report reads of the ledger. A reader must not trust the writer's bound: an
// untrimmed ledger (a dev build, a boot that never ran the trim) grows forever.
const reapLedgerTailBytes = 256 << 10

// reapLedgerCounts renders the reap ledger as issue-report status keys (NWP-20261107-14, Q143): counts per class
// only, never a uid, a time, a census or a name.
//
//	reap_ledger_rows    "<n>" rows read, "0 (no ledger)" when the file is absent, "unreadable: <error class>" when
//	                    it is there and cannot be read (that key alone, no path)
//	reap_ledger_classes "boot=<n> clean=<n> gaveup=<n> husk=<n> other=<n> recheck=<n> residue=<n>
//	                    retried=<n>", every class always present
//	reap_ledger_userdir "blind=<n> timeout=<n>": rows whose userdir field is anchor:blind / anchor:timeout (Q037's
//	                    size of the stuck-reap residual)
//
// A class=<c> field with c in clean/gaveup/husk/recheck/residue/retried counts as c (gaveup and retried since
// NWP-20261114-25, #67), a `userdir ctx=boot` row as boot, anything else (or a malformed row) as other. Only the last
// reapLedgerTailBytes are read.
func reapLedgerCounts(path string) map[string]string {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]string{"reap_ledger_rows": "0 (no ledger)"}
	}
	if err != nil {
		return reapLedgerUnreadable(err)
	}
	defer f.Close()
	b, err := reapLedgerTail(f)
	if err != nil {
		return reapLedgerUnreadable(err)
	}
	n := map[string]int{}
	rows, blind, timeout := 0, 0, 0
	for _, ln := range strings.Split(string(b), "\n") {
		fields := strings.Fields(ln)
		if len(fields) == 0 {
			continue
		}
		rows++
		n[reapLedgerClass(fields)]++
		for _, fl := range fields {
			switch {
			case strings.HasPrefix(fl, "userdir=anchor:blind"):
				blind++
			case strings.HasPrefix(fl, "userdir=anchor:timeout"):
				timeout++
			}
		}
	}
	return map[string]string{
		"reap_ledger_rows": strconv.Itoa(rows),
		"reap_ledger_classes": fmt.Sprintf("boot=%d clean=%d gaveup=%d husk=%d other=%d recheck=%d residue=%d retried=%d",
			n["boot"], n["clean"], n["gaveup"], n["husk"], n["other"], n["recheck"], n["residue"], n["retried"]),
		"reap_ledger_userdir": fmt.Sprintf("blind=%d timeout=%d", blind, timeout),
	}
}

// reapLedgerClass: the class= value when it is one of roamd's six (gaveup and retried are the reap retry's outcomes,
// NWP-20261114-25, #67), a bootsweep row as boot, anything else other.
func reapLedgerClass(fields []string) string {
	for _, fl := range fields {
		if c, ok := strings.CutPrefix(fl, "class="); ok {
			switch c {
			case "clean", "gaveup", "husk", "recheck", "residue", "retried":
				return c
			}
			return "other"
		}
	}
	if len(fields) >= 3 && fields[1] == "userdir" && fields[2] == "ctx=boot" {
		return "boot"
	}
	return "other"
}

// reapLedgerTail reads at most the last reapLedgerTailBytes; when it starts mid-file the first (partial) line goes.
func reapLedgerTail(f *os.File) ([]byte, error) {
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	cut := false
	if st.Mode().IsRegular() && st.Size() > reapLedgerTailBytes {
		if _, err := f.Seek(st.Size()-reapLedgerTailBytes, io.SeekStart); err != nil {
			return nil, err
		}
		cut = true
	}
	b, err := io.ReadAll(io.LimitReader(f, reapLedgerTailBytes))
	if err != nil {
		return nil, err
	}
	if cut {
		i := strings.IndexByte(string(b), '\n')
		if i < 0 {
			return nil, nil
		}
		b = b[i+1:]
	}
	return b, nil
}

// reapLedgerUnreadable self-declares a ledger that is there but cannot be read, like lastRebootMarker: the error's
// class only (the *fs.PathError's inner error), never the path.
func reapLedgerUnreadable(err error) map[string]string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		err = pe.Err
	}
	return map[string]string{"reap_ledger_rows": "unreadable: " + err.Error()}
}
