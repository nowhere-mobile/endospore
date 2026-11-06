package main

// NWP-20261027-02: the package's tests run with the failed-sign-in log scrub off. A BLANK reply schedules a logscrub
// on the RW lane, and the many existing fakes that answer a sign-in but not a logscrub would hold that lane for the
// whole worker timeout (150 s each). failed_signin_scrub_test.go enables it for the cases that exercise it.
// NWP-20261107-12: the same for the userdir re-check tick, which would hold the RW lane the same way.
func init() { failedSigninScrubEnabled = false; userdirRecheckEnabled = false }
