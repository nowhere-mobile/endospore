package main

// The session's kept storage count (NWP-20261118-06). Decision of record: h48 #6 in docs/product-decisions.md,
// DECIDED 2026-10-30. The "What's using space" screen shows the last count with its age, a fresh count starts every
// time the screen opens, and it replaces the shown figure when it lands. A failed count keeps the old figure. The
// copy is RAM only: it is dropped at every sign-in, at session end and at a cold lock.
//
// Before this, GET-STORAGE-BREAKDOWN ran the worker afresh on every request and kept nothing. On a full phone the
// walk ran past the RO lane's 150 s stall budget, so the daemon answered ERR-TIMEOUT, threw the finished work away,
// and the next try met ERR-WORKER-BUSY. The walk now beats the watchdog (storageWalkBeat), and the count runs on its
// own goroutine, so it finishes and keeps its result after the screen stops waiting.
//
// Wire (no reply line names a profile):
//
//	STORAGE-COUNT-START           NONE | OK STARTED | OK RUNNING
//	GET-STORAGE-BREAKDOWN-CACHED  NONE | PENDING <running 0|1> <lastErr> | OK <nbytes> <countedAt unix> <running 0|1> <lastErr>\n<json>

import (
	"fmt"
	"net"
	"strings"
	"sync"
	"time"
)

// storageCountJob is one count. done closes once the count has ended, published or not; out is then its reply body:
// the merged JSON (it starts with '{') or one token (ERR-..., NONE).
type storageCountJob struct {
	done chan struct{}
	out  string
}

// storageCount is the process-global count state. json is exactly the bytes today's GET-STORAGE-BREAKDOWN reply
// carries after withStoreBytes ("" = no count this session). gen is bumped by every reset, so a count that began
// before a reset publishes nothing.
var storageCount struct {
	mu        sync.Mutex
	json      string
	countedAt time.Time
	running   bool
	cur       *storageCountJob
	lastErr   string // "none" or the last failed count's token; "" reads as "none"
	gen       uint64
}

// storageCountRun runs one count and returns its reply body. A package hook: tests replace it, so no test count ever
// reaches the RO lane.
var storageCountRun = storageCountRunDefault

// storageCountJoinedHook is test-only, nil in production: GET-STORAGE-BREAKDOWN calls it when it joins a running count.
var storageCountJoinedHook func()

// storageCountRunDefault is the body GET-STORAGE-BREAKDOWN ran inline until NWP-20261118-06, lifted unchanged.
func storageCountRunDefault(dest string) string {
	name, pass, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		return "NONE" // the session ended before the count began
	}
	out := strings.TrimSpace(triggerRoamWorker(dest, "storagebreakdown", name, "", uid, "", nil))
	// The worker emits the JSON object itself; anything else is one of its ERR-* tokens.
	if !strings.HasPrefix(out, "{") {
		if out == "" {
			out = "ERR-WORKER"
		}
		return out
	}
	// DIA-20260805-12: fold in the PLAN side. The worker walked local bytes; only the daemon has the store and
	// the passphrase, so the sealed per-package figures are read here and merged into the same reply -- the
	// screen needs both numbers at once and must not make two round trips that can disagree.
	//
	// Best-effort by construction: offline, or a profile that has not sealed since the Pkg index existed,
	// leaves StoreMeasured false and the local walk is served exactly as before. A store failure must never
	// blank the screen -- it is offered precisely when the user is over their plan and wants to act.
	if merged, err := withStoreBytes(out, name, pass, seFromSession(dest)); err == nil {
		out = merged
	}
	return out
}

// storageCountToken is the reply-line form of a failed count's result: its first field, so a token never carries a
// space or a newline into the CACHED header.
func storageCountToken(out string) string {
	if f := strings.Fields(out); len(f) > 0 {
		return f[0]
	}
	return "ERR-WORKER"
}

// startStorageCount joins the running count, or starts one through goSafe. started reports which.
func startStorageCount(dest string) (j *storageCountJob, started bool) {
	storageCount.mu.Lock()
	defer storageCount.mu.Unlock()
	if storageCount.running {
		return storageCount.cur, false
	}
	j = &storageCountJob{done: make(chan struct{})}
	storageCount.running = true
	storageCount.cur = j
	gen := storageCount.gen
	goSafe("storage count", func() {
		out := ""
		// Published from a defer, so a panic in the count still releases running and closes done (the
		// storedAppsCached lesson): a later START must not wait on a count that will never land.
		defer close(j.done)
		defer func() {
			if out == "" {
				out = "ERR-WORKER" // the count panicked
			}
			storageCount.mu.Lock()
			defer storageCount.mu.Unlock()
			j.out = out
			if storageCount.gen != gen {
				return // a reset after this count began: its result is not this session's
			}
			if strings.HasPrefix(out, "{") {
				storageCount.json = out
				storageCount.countedAt = time.Now().Round(0)
				storageCount.lastErr = "none"
			} else {
				storageCount.lastErr = storageCountToken(out)
			}
			storageCount.running = false
			storageCount.cur = nil
		}()
		out = storageCountRun(dest)
	})
	return j, true
}

// resetStorageCount drops the kept count. It is called at every sign-in (resetSealSignals), every session end
// (forgetSessionKeys) and the cold lock. A count still running publishes nothing; its waiter still gets its reply.
func resetStorageCount() {
	storageCount.mu.Lock()
	storageCount.json = ""
	storageCount.countedAt = time.Time{}
	storageCount.running = false
	storageCount.cur = nil
	storageCount.lastErr = "none"
	storageCount.gen++
	storageCount.mu.Unlock()
}

// handleStorageCountStart backs STORAGE-COUNT-START: the screen opened, so a fresh count starts unless one runs.
func handleStorageCountStart(conn net.Conn, dest string) {
	name, _, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	if _, started := startStorageCount(dest); started {
		fmt.Fprint(conn, "OK STARTED\n")
		return
	}
	fmt.Fprint(conn, "OK RUNNING\n")
}

// handleGetStorageBreakdownCached backs GET-STORAGE-BREAKDOWN-CACHED. It never starts a count.
func handleGetStorageBreakdownCached(conn net.Conn, dest string) {
	name, _, uid := readRoamSession(dest)
	if name == "" || uid == "" {
		fmt.Fprint(conn, "NONE\n") // nobody signed in
		return
	}
	storageCount.mu.Lock()
	json, at, running, lastErr := storageCount.json, storageCount.countedAt, storageCount.running, storageCount.lastErr
	storageCount.mu.Unlock()
	if lastErr == "" {
		lastErr = "none"
	}
	run := 0
	if running {
		run = 1
	}
	if json == "" {
		fmt.Fprintf(conn, "PENDING %d %s\n", run, lastErr)
		return
	}
	fmt.Fprintf(conn, "OK %d %d %d %s\n", len(json), at.Unix(), run, lastErr)
	fmt.Fprint(conn, json)
}
