package main

import "strings"

// scopeHeadOverlap keeps Q036's decisions inside one restore invocation. This
// batches only capability requests; it does not stage head decisions across
// processes as NWP-20260820-33 refused.
func scopeHeadOverlap(base, profile, pass string, memo refProbeMemo) (join func()) {
	join = func() {}
	if !capMode() || !isS3(base) {
		return join
	}
	i := strings.IndexByte(profile, '#')
	if i < 0 || (multiDeviceEnabled() && isPerUnitRef(profile)) {
		return join
	}
	bare := profile
	if i >= 0 {
		bare = profile[:i]
	}
	scopeRef := profileRefV2(profile, pass)
	bareRef := profileRefV2(bare, pass)
	prefetchReadCaps([]string{"ref/" + bareRef, "ref/" + scopeRef})
	result := refProbeRead{}
	complete, panicked := false, false
	done := make(chan struct{})
	goSafe("scope-head-overlap", func() {
		defer close(done)
		defer func() {
			if recover() != nil {
				panicked = true
			}
		}()
		var haveVal bool
		result.exists, result.val, haveVal = refProbe(base, scopeRef)
		complete = result.exists && haveVal
	})
	return func() {
		<-done
		if complete && !panicked {
			memo[scopeRef] = result
		}
	}
}
