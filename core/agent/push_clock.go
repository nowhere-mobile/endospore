package main

import "time"

// NWP-20261117-33: a push's summary used to print ONE duration, time.Since(t0), and the upload figure in
// pushSplit was time.Since(tFlush) too. Both are monotonic: time.Now() carries a monotonic reading, and Since/Sub
// use it whenever both operands carry one. On Linux that clock is CLOCK_MONOTONIC, which STOPS in suspend. So a
// seal the phone slept through reported only the minutes it was awake: frankel's ticket NW-a17e164b51d3 showed
// pushes of 7m24s while roamd's date stamps put the seal at 20m35s, and the 13 minutes asleep read as unexplained
// slowness. A reading stripped with Round(0) keeps only the wall clock, which keeps counting in suspend, so the
// callers take one of each and these renderers name the difference.
//
// The difference is "asleep" only by inference. A wall-clock step (a time sync during the seal) moves the wall
// reading too, and nothing here can tell a step from a suspend; it reads as asleep. A BACKWARD step puts wall below
// mono, which is why asleep is clamped at 0 rather than printed negative.

// sleepNote is the wall-clock note a duration carries: "" when wall and mono differ by less than a second (so a
// seal that never slept logs exactly as it did before), else " (wall <wall>, asleep <wall-mono>)", asleep never
// negative. All figures are rounded to the millisecond, as the summary always was.
func sleepNote(mono, wall time.Duration) string {
	d := wall - mono
	if d > -time.Second && d < time.Second {
		return ""
	}
	asleep := d
	if asleep < 0 {
		asleep = 0
	}
	return " (wall " + wall.Round(time.Millisecond).String() + ", asleep " + asleep.Round(time.Millisecond).String() + ")"
}

// pushClock renders a push summary's duration: "in <mono>", plus sleepNote's wall time and minutes asleep when
// the two clocks disagree by a second or more.
func pushClock(mono, wall time.Duration) string {
	return "in " + mono.Round(time.Millisecond).String() + sleepNote(mono, wall)
}
