package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

// storeXfer bounds a managed-store chunk transfer (capGetMaxOpt's presigned GET, capPutErrGuarded's PUT) by the
// bytes in flight beside it, not by storeHTTP's 60 s whole-request Timeout (NWP-20261203-10, the backlog row "A
// large `#media` seal over a slow uplink fails `media=failed`, and a sign-in restore over a slow link ends BLANK
// NET"). A seal runs sealUploadWorkers (8) PUTs at once and a restore downloadWorkers (24) GETs, each chunk up to
// cdcMax (4 MiB), and they share one link: on 2 Mbit/s eight 4 MiB PUTs take about 130 s, so the 60 s Timeout cut
// every one, every retry too. Device proof S9, lynx 2026111001, 2026-11-11: a 272 MB seal under a 2 Mbit tbf ended
// `media=failed` on `Client.Timeout exceeded`, and a 60 MiB vault restore under a 4 Mbit police ended BLANK NET.
//
// A fixed longer Timeout cannot help: it is too short for a slow link or too long for a real hang. So:
//
//   - THE DEADLINE is storeXferDeadline(the bytes every running storeXfer has in flight): storeXferFloor plus one
//     second per storeXferMinRate bytes, at most storeXferCeil. 8 x 4 MiB is 60 + 256 = 316 s; 24 x 4 MiB hits
//     the 10 min ceiling, still under the sign-in watchdog (roamInStallTicks, 900 s).
//   - IT IS RECHECKED WHEN IT FIRES, against the bytes in flight THEN, from the request's own start. A request is
//     priced at its add, so a wave's first request saw only itself: 8 x 4 MiB at 2 Mbit needs about 128 s, and
//     the first was given 92 s.
//   - A GET ALSO ENDS AFTER storeXferStall WITH NO BYTE. The stall timer starts before Do, so it bounds connect
//     and headers too, and every body Read that returns bytes restarts it. A PUT has no stall timer: its body is
//     copied to the socket at once, then the store is silent until it answers, so the deadline alone bounds it.
//   - Once headers arrive with a ContentLength, a GET's share moves from its estimate to that length.
//
// Residuals: an op on roamStallBudget (150 s: heal, mediad, a seal) whose chunks flow for longer than that with no
// progress write ends at the watchdog, not at the old 60 s timeout (a seal writes progress per finished blob, so
// 8 x 4 MiB under about 1.8 Mbit/s still reaches it); and a GET that trickles a byte every < 30 s is bounded only
// by the deadline. capSize, export_rekey and catalog.go stay on storeHTTP; direct-S3 mode is not touched.
//
// Vars so tests shrink them.
var (
	storeXferFloor         = 60 * time.Second // the deadline with nothing in flight
	storeXferMinRate int64 = 128 << 10        // bytes per second, about 1 Mbit/s: the slowest link the deadline allows for
	storeXferCeil          = 10 * time.Minute // the deadline never exceeds this
	storeXferStall         = 30 * time.Second // a GET with no body byte for this long ends
)

// storeXferInflight is the sum of the current shares of every running storeXfer request (bytes). sync/atomic only.
var storeXferInflight int64

var (
	errStoreXferDeadline = errors.New("store transfer deadline passed")
	errStoreXferStall    = errors.New("store transfer stalled")
)

// storeXferDeadline is the deadline for a request started with inflight bytes in flight, its own included.
func storeXferDeadline(inflight int64) time.Duration {
	d := storeXferFloor + time.Duration(inflight)*time.Second/time.Duration(storeXferMinRate)
	if d > storeXferCeil {
		return storeXferCeil
	}
	return d
}

// storeXfer sends req on a copy of storeHTTP with no Timeout (its Transport kept, #71), bounded as the block above
// says; est is the bytes the request is expected to move. The caller must Close the returned Body: Close releases
// the request's share of storeXferInflight and stops its timers. On a Do error everything is already released.
// A cut names its cause and wraps errStoreXferDeadline or errStoreXferStall; it holds no key and no URL.
func storeXfer(req *http.Request, est int64) (*http.Response, error) {
	start := time.Now()
	var share atomic.Int64
	share.Store(est)
	total := atomic.AddInt64(&storeXferInflight, est)
	c := *storeHTTP
	c.Timeout = 0
	ctx, cancel := context.WithCancelCause(req.Context())
	req = req.WithContext(ctx)
	dl := time.NewTimer(storeXferDeadline(total))
	var st *time.Timer
	var stC <-chan time.Time // nil for a PUT: never fires
	if req.Body == nil || req.Body == http.NoBody {
		st = time.NewTimer(storeXferStall)
		stC = st.C
	}
	done := make(chan struct{})
	var once sync.Once
	release := func() {
		once.Do(func() {
			dl.Stop()
			if st != nil {
				st.Stop()
			}
			atomic.AddInt64(&storeXferInflight, -share.Load())
			cancel(nil)
			close(done)
		})
	}
	goSafe("store-xfer", func() {
		for {
			select {
			case <-stC:
				cancel(fmt.Errorf("no data for %s: %w", storeXferStall, errStoreXferStall))
				return
			case <-dl.C:
				n := atomic.LoadInt64(&storeXferInflight)
				end := start.Add(storeXferDeadline(n))
				if left := time.Until(end); left > 0 {
					dl.Reset(left)
					continue
				}
				cancel(fmt.Errorf("transfer deadline %s for %d KiB in flight: %w", storeXferDeadline(n), n>>10, errStoreXferDeadline))
				return
			case <-done:
				return
			}
		}
	})
	resp, err := c.Do(req)
	if err != nil {
		release()
		return nil, storeXferErr(ctx, err)
	}
	if resp.ContentLength >= 0 {
		old := share.Swap(resp.ContentLength)
		atomic.AddInt64(&storeXferInflight, resp.ContentLength-old)
	}
	resp.Body = &storeXferBody{rc: resp.Body, st: st, ctx: ctx, release: release}
	return resp, nil
}

// storeXferErr returns the cut's cause when storeXfer's own timer ended the request, else err unchanged.
func storeXferErr(ctx context.Context, err error) error {
	if c := context.Cause(ctx); errors.Is(c, errStoreXferStall) || errors.Is(c, errStoreXferDeadline) {
		return c
	}
	return err
}

// storeXferBody restarts a GET's stall timer on every Read that returned bytes; Close releases the request.
type storeXferBody struct {
	rc      io.ReadCloser
	st      *time.Timer
	ctx     context.Context
	release func()
}

func (b *storeXferBody) Read(p []byte) (int, error) {
	n, err := b.rc.Read(p)
	if n > 0 && b.st != nil {
		b.st.Reset(storeXferStall)
	}
	if err != nil && err != io.EOF {
		err = storeXferErr(b.ctx, err)
	}
	return n, err
}

func (b *storeXferBody) Close() error {
	err := b.rc.Close()
	b.release()
	return err
}
