package main

import (
	"strconv"
	"time"
)

// NWP-20261123-03: a write cap is re-minted BEFORE its PUT once it is near the end of its life.
//
// capFlush leases every batch before it sends any PUT, and the gateway mints each cap with a 15-minute life. On
// a seal longer than that (lynx 2026102201: 43,719 #media chunks in 31m50s) every remaining blob was first sent
// on a dead cap, refused 403 ExpiredRequest, then re-minted and sent again (7,565 refetch lines): two PUTs and
// one POST /cap per blob, which made exactly the long seals longer. capPutErrGuarded's one 403 re-mint stays as
// the backstop; this rule only saves the PUT it would have wasted.
//
// The age is measured on the device's own clock, from its own stamp: when mergeLeaseInfo merged the batch that
// minted the cap. X-Amz-Date is the gateway's clock and is never read here, so clock skew between the device
// and the gateway cannot trigger a re-mint (or hide one).

// capRemintMargin is how long before the end of a cap's life it is re-minted. The PUT itself must finish inside
// the cap's life: a 4 MiB chunk on a slow uplink, plus retryStore's backoff on a transient, can take that long.
const capRemintMargin = 2 * time.Minute

// capNow is CLOCK_BOOTTIME in milliseconds (bootNowMs), not time.Now: the monotonic clock stops in suspend, so a
// cap that expired while the phone slept would read as fresh -- on exactly the long seals this exists for.
// bootNowMs is called late, not copied at init, so a test that drives bootNowMs drives this too. A var so a test
// can replace it. bootNowMs answers 0 when the clock cannot be read: the stamp and now are then both 0, the age
// is 0, and capNearExpiry says false, which is the path before this rule existed.
var capNow = func() int64 { return bootNowMs() }

// capNearExpiry reports whether a cap stamped at mintedAtMs (capNow) is, at nowMs, within capRemintMargin of
// the life its X-Amz-Expires states. Only X-Amz-Expires is read, through capSignedFields. An absent or malformed
// one ("?") is false: the cap goes out as it did before this rule, never into a re-mint per PUT.
func capNearExpiry(mintedAtMs, nowMs int64, capURL string) bool {
	_, exp := capSignedFields(capURL)
	if exp == "?" {
		return false
	}
	life, err := strconv.ParseInt(exp, 10, 64)
	if err != nil {
		return false
	}
	return nowMs-mintedAtMs >= life*1000-capRemintMargin.Milliseconds()
}
