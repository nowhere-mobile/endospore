package main

// NWP-20260910-03: the seal's blob upload runs bounded-concurrent instead of strictly one at a time.
//
// This is the path the #45 OOM and the #45 data-loss fix both live on, so these pin the two properties that
// must survive concurrency -- every blob is uploaded exactly once, and a failure still FAILS THE SEAL on the
// caller's goroutine rather than killing the process from a worker.

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func blobWork(n int) []capBlobRef {
	w := make([]capBlobRef, n)
	for i := range w {
		w[i] = capBlobRef{key: "blob/" + string(rune('a'+i%26)) + string(rune('0'+i/26)), off: int64(i), size: 1}
	}
	return w
}

// EVERY BLOB, EXACTLY ONCE. A dropped or repeated blob is a corrupt or over-charged seal.
func TestUploadBlobs_UploadsEveryBlobExactlyOnce(t *testing.T) {
	for _, workers := range []int{1, 2, 8, 64} {
		work := blobWork(200)
		var mu sync.Mutex
		seen := map[string]int{}
		var doneN int64
		uploadBlobsWithin(t, work, workers, func(b capBlobRef, rbuf *[]byte) {
			mu.Lock()
			seen[b.key]++
			mu.Unlock()
		}, func(b capBlobRef) { atomic.AddInt64(&doneN, 1) })

		if len(seen) != len(work) {
			t.Errorf("workers=%d: uploaded %d distinct blob(s), want %d", workers, len(seen), len(work))
		}
		for k, n := range seen {
			if n != 1 {
				t.Errorf("workers=%d: blob %s uploaded %d times, want 1", workers, k, n)
			}
		}
		if got := atomic.LoadInt64(&doneN); got != int64(len(work)) {
			t.Errorf("workers=%d: done called %d time(s), want %d", workers, got, len(work))
		}
	}
}

// EACH WORKER GETS ITS OWN BUFFER -- that is the #45 RAM bound. If they shared one, two workers would read
// into the same backing array and a blob could ship another blob's bytes.
func TestUploadBlobs_EachWorkerHasItsOwnBuffer(t *testing.T) {
	const W = 4
	work := blobWork(64)
	var mu sync.Mutex
	ptrs := map[*byte]bool{}
	// ⚠ FORCE the overlap, do not hope for it. The first version of this test just counted distinct buffers
	// and failed about 1 run in 4: the jobs channel is unbounded in neither direction and the work here is
	// trivial, so ONE worker can legitimately drain all 64 jobs before the others are ever scheduled. Go
	// promises concurrency, not parallelism, and an assertion that assumes otherwise is a flaky test rather
	// than a real finding. The barrier below holds the first W arrivals until all W are in flight, which is
	// the only state in which "does each worker have its own buffer" is even observable.
	var barrier sync.WaitGroup
	barrier.Add(W)
	var arrivals int32
	uploadBlobsWithin(t, work, W, func(b capBlobRef, rbuf *[]byte) {
		if cap(*rbuf) < 8 {
			*rbuf = make([]byte, 8)
		}
		mu.Lock()
		ptrs[&(*rbuf)[0]] = true // identity of this worker's backing array
		mu.Unlock()
		if atomic.AddInt32(&arrivals, 1) <= int32(W) {
			barrier.Done() // this worker is in flight...
			barrier.Wait() // ...hold until the other W-1 are too
		}
	}, func(b capBlobRef) {})
	if len(ptrs) < 2 {
		t.Errorf("saw %d distinct buffer(s) across the workers -- a SHARED buffer would let one blob ship "+
			"another blob's bytes", len(ptrs))
	}
	if len(ptrs) > W {
		t.Errorf("saw %d distinct buffers for %d workers -- buffers are being reallocated per blob, which is "+
			"the allocation churn the serial loop deliberately avoided", len(ptrs), W)
	}
}

// A FAILURE MUST STILL FAIL THE SEAL, on the CALLER's goroutine. upload1 fails by panic; if that escaped a
// worker it would kill the process instead of leaving the previous head intact (#45).
func TestUploadBlobs_AFailurePanicsOnTheCaller(t *testing.T) {
	work := blobWork(100)
	var attempts int64
	failed := uploadBlobsWithin(t, work, 8, func(b capBlobRef, rbuf *[]byte) {
		atomic.AddInt64(&attempts, 1)
		panic("cap PUT -> 403")
	}, func(b capBlobRef) {
		t.Error("done was called for a blob whose upload panicked")
	}) != nil
	if !failed {
		t.Fatal("a panicking upload did not fail the caller -- the seal would publish pointers for blobs " +
			"that never landed, which is exactly what the #45 ordering exists to prevent")
	}
	// ...and it must STOP, not grind through every remaining blob against a cap that is already dead.
	if n := atomic.LoadInt64(&attempts); n >= int64(len(work)) {
		t.Errorf("attempted %d of %d uploads after the first failure -- one dead cap must not become %d "+
			"doomed uploads", n, len(work), len(work))
	}
}

// The kill-switch must genuinely serialise: workers=1 is the pre-NWP-20260910-03 behaviour.
func TestUploadBlobs_OneWorkerIsStrictlySerial(t *testing.T) {
	work := blobWork(50)
	var inFlight, maxSeen int64
	uploadBlobsWithin(t, work, 1, func(b capBlobRef, rbuf *[]byte) {
		n := atomic.AddInt64(&inFlight, 1)
		for {
			m := atomic.LoadInt64(&maxSeen)
			if n <= m || atomic.CompareAndSwapInt64(&maxSeen, m, n) {
				break
			}
		}
		atomic.AddInt64(&inFlight, -1)
	}, func(b capBlobRef) {})
	if maxSeen != 1 {
		t.Errorf("workers=1 ran %d uploads concurrently, want strictly 1 -- the kill-switch must restore the "+
			"serial path exactly", maxSeen)
	}
}

// The default must actually BE concurrent, or the whole slice is inert. Without this, "workers=1 always"
// would pass every test above.
func TestSealUploadWorkers_DefaultsToConcurrent(t *testing.T) {
	t.Setenv("NOWHERE_SEAL_UPLOAD_WORKERS", "")
	if n := sealUploadWorkers(); n <= 1 {
		t.Errorf("sealUploadWorkers() = %d by default -- the seal would still be strictly serial", n)
	}
	t.Setenv("NOWHERE_SEAL_UPLOAD_WORKERS", "1")
	if n := sealUploadWorkers(); n != 1 {
		t.Errorf("the kill-switch is not honoured: got %d, want 1", n)
	}
}

// uploadBlobsWithin runs uploadBlobs on its own goroutine and returns the value it panicked with (nil when it
// returned). NWP-20261014-66: BOUNDED, so a worker that leaves mu held fails the test in seconds instead of hanging
// the whole binary to its timeout.
func uploadBlobsWithin(t *testing.T, work []capBlobRef, workers int, upload1 func(capBlobRef, *[]byte), done func(capBlobRef)) any {
	t.Helper()
	res := make(chan any, 1)
	go func() {
		defer func() { res <- recover() }()
		uploadBlobs(work, workers, upload1, done)
	}()
	select {
	case r := <-res:
		return r
	case <-time.After(10 * time.Second):
		t.Fatal("uploadBlobs did not return within 10s -- a worker left mu held, or a job was never drained")
		return nil
	}
}
