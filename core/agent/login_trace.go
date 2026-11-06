package main

// Login-latency trace (NWP-20260820-27): split the restore path's `key=` figure into what it is actually
// made of. LOG-ONLY -- nothing here changes behaviour, and every counter is a plain atomic add.
//
// WHY. NWP-20260820-26 profiled a whole login on lynx and found head resolution costs 6448ms of a 15.7s
// restore -- 1434/1126/1331/1217/1340 ms across the five scopes, 41% of the total, against only 9267ms of
// actual chunk restore. The same work on an IDLE device measures ~160ms end to end (the agent process floor
// is ~25ms), so the login pays roughly 10x, and from outside the process there was no way to say why. The
// two candidate causes point in OPPOSITE directions:
//
//   - round-trip latency -> overlapping the five scopes hides it (the `grant-135` shape, which worked)
//   - CPU/IO contention  -> overlapping makes the login WORSE
//
// So the backlog row asks for this split BEFORE any behaviour change. `other` is the load-bearing number: it
// is the residual after every measured network and KDF cost is subtracted. Small residual means latency;
// dominant residual means contention.
//
// WHY THE TWO NETWORK LEGS ARE COUNTED SEPARATELY. In cap mode every store read is TWO round trips to TWO
// DIFFERENT HOSTS: a gateway /cap POST (capReadURL -> readCap) for a presigned URL, then the presigned GET
// against the object store (capGet). "The gateway is slow" and "R2 is slow" need different fixes, and a
// single combined number cannot tell them apart. capReadCache absorbs the /cap leg for a repeated key within
// ONE process -- but roamd invokes this binary FIVE separate times per login
// (nowhere_roamd.sh's `"$AGENT" restore s3` calls for #sys, the vault, #de, #media and #apps), so the cache starts cold
// every time and the counts are per-invocation.
//
// WHY DISTINCT-VS-TOTAL. Reading the code while filing NWP-20260820-26 turned up the same tiny ref object
// being fetched repeatedly inside ONE invocation: profileDeleted (main.go) does refExists then getRef on
// the bare ref -- in cap mode BOTH are capGet("ref/"+ref), the identical request -- then headKey (main.go)
// probes the winning ref with refExists and resolveKey (main.go) immediately getRefs the very same ref.
// That is a code-reading claim, and this project's rule is that built is not proven. The distinct-vs-total
// counter settles it FROM THE DEVICE: if total materially exceeds distinct, the redundancy is real and
// measured, and the fix that follows is round-trip REMOVAL (which is correct under either hypothesis above)
// rather than concurrency.

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// Counters are process-global and monotonic; callers take a snapshot around the window they care about and
// diff it, so one binary can measure several windows (head resolution, then the chunk phase) independently.
var (
	traceCapN, traceCapNs int64 // gateway /cap fetches (capReadCache MISSES only) + ns spent in them
	traceGetN, traceGetNs int64 // store object reads (presigned GET, or the direct-S3 path) + ns spent
	traceKdfN, traceKdfNs int64 // Argon2 computations (deriveKey cache MISSES only) + ns spent
)

// traceDistinct records which store keys were read, but ONLY while it is non-nil, so it costs nothing on
// every other path. Two things bound it, and both matter: the window is closed the moment head resolution
// ends (a restore then fetches thousands of chunks, and an always-on set would grow with the profile), and
// `case "restore"` is a ONE-SHOT CLI invocation -- the long-lived daemon is `case "login-daemon"` and never
// re-enters that switch, so the map cannot accumulate across logins even on the early-return paths that
// exit without closing the window.
var (
	traceDistinctMu sync.Mutex
	traceDistinct   map[string]int
)

func traceRead(key string) {
	traceDistinctMu.Lock()
	if traceDistinct != nil {
		traceDistinct[key]++
	}
	traceDistinctMu.Unlock()
}

// traceDistinctBegin starts recording which keys are read. Safe to call more than once (it resets).
func traceDistinctBegin() {
	traceDistinctMu.Lock()
	traceDistinct = map[string]int{}
	traceDistinctMu.Unlock()
}

// traceDistinctEnd stops recording and returns (total reads, distinct keys) over the window.
func traceDistinctEnd() (total, distinct int) {
	traceDistinctMu.Lock()
	for _, n := range traceDistinct {
		total += n
		distinct++
	}
	traceDistinct = nil
	traceDistinctMu.Unlock()
	return
}

type storeTrace struct{ capN, capNs, getN, getNs, kdfN, kdfNs int64 }

func traceNow() storeTrace {
	return storeTrace{
		atomic.LoadInt64(&traceCapN), atomic.LoadInt64(&traceCapNs),
		atomic.LoadInt64(&traceGetN), atomic.LoadInt64(&traceGetNs),
		atomic.LoadInt64(&traceKdfN), atomic.LoadInt64(&traceKdfNs),
	}
}

func (a storeTrace) since(b storeTrace) storeTrace {
	return storeTrace{a.capN - b.capN, a.capNs - b.capNs, a.getN - b.getN,
		a.getNs - b.getNs, a.kdfN - b.kdfN, a.kdfNs - b.kdfNs}
}

// split renders the breakdown of a window whose wall clock was totalMs.
//
// `other` is deliberately clamped at zero rather than allowed to go negative: chunk fetches run CONCURRENTLY
// (cdcRestore, DIA-20260624-07), so summed per-call durations can legitimately exceed the wall clock and a
// negative residual would be an artefact of that overlap, not a measurement. Head resolution is sequential,
// so on the window this is actually used for the residual is meaningful.
func (d storeTrace) split(totalMs int64) string {
	ms := func(ns int64) int64 { return ns / 1e6 }
	other := totalMs - ms(d.capNs) - ms(d.getNs) - ms(d.kdfNs)
	if other < 0 {
		other = 0
	}
	return fmt.Sprintf("cap=%dx/%dms store=%dx/%dms kdf=%dx/%dms other=%dms",
		d.capN, ms(d.capNs), d.getN, ms(d.getNs), d.kdfN, ms(d.kdfNs), other)
}

// traceSince times fn and adds the elapsed to (n, ns). Used at the four call sites that actually block.
func traceSince(n, ns *int64, fn func()) {
	t0 := time.Now()
	fn()
	atomic.AddInt64(ns, int64(time.Since(t0)))
	atomic.AddInt64(n, 1)
}
