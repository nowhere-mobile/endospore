package main

import "testing"

// NWP-20261013-40: the report names the OTA version the phone runs, so ota_latest / ota_avail can be read
// against it. A host has no /system/etc/nowhere-ota-version, so both sides read the "0.0.0" fallback.

func TestOtaStatusMarkerCarriesRunningVersion(t *testing.T) {
	got, ok := otaStatusMarker()["ota_running"]
	if !ok {
		t.Fatal("otaStatusMarker has no ota_running key")
	}
	if got != runningOtaVersion() {
		t.Errorf("ota_running = %q, want runningOtaVersion() = %q", got, runningOtaVersion())
	}
}

func TestGateReportCarriesRunningVersion(t *testing.T) {
	rep := buildIssueReport("", true, "", nil, nil)
	got, ok := rep.Status["ota_running"]
	if !ok {
		t.Fatal("a gate-scope report has no ota_running in Status")
	}
	if got != runningOtaVersion() {
		t.Errorf("ota_running = %q, want %q", got, runningOtaVersion())
	}
}
