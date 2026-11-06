package main

import (
	"errors"
	"os"
	"testing"
)

// NWP-20261020-27: jitterEpochs is the plan-activation privacy delay (docs/billing-plan-model.md, timing defence 1).
// These pin its stated rules: the default range, the 0 override, the typo fallback, uniform override draws and the
// fail-toward-delay error path.

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errors.New("no entropy") }

const jitterDraws = 3000

func jitterSeen(t *testing.T, env string, set bool) (seen map[int64]int, max int64) {
	t.Helper()
	if set {
		t.Setenv("ACTIVATION_JITTER_EPOCHS", env)
	} else {
		// Truly absent, not empty: t.Setenv registers the restore, then Unsetenv removes the variable.
		t.Setenv("ACTIVATION_JITTER_EPOCHS", "")
		os.Unsetenv("ACTIVATION_JITTER_EPOCHS")
	}
	seen = map[int64]int{}
	for i := 0; i < jitterDraws; i++ {
		v := jitterEpochs()
		if v < 0 {
			t.Fatalf("env %q: drew %d", env, v)
		}
		seen[v]++
		if v > max {
			max = v
		}
	}
	return
}

func requireDefaultRange(t *testing.T, env string, set bool) {
	t.Helper()
	seen, _ := jitterSeen(t, env, set)
	for v := range seen {
		if v < 0 || v > activationJitterEpochs {
			t.Fatalf("env %q: %d outside 0..%d", env, v, activationJitterEpochs)
		}
	}
	for v := int64(0); v <= activationJitterEpochs; v++ {
		if seen[v] == 0 {
			t.Fatalf("env %q: never drew %d in %d draws (%v)", env, v, jitterDraws, seen)
		}
	}
}

func TestJitterEpochs_UnsetIsDefaultRange(t *testing.T) { requireDefaultRange(t, "", false) }

func TestJitterEpochs_ZeroOverrideIsZero(t *testing.T) {
	for _, env := range []string{"0", " 0 "} {
		seen, _ := jitterSeen(t, env, true)
		if len(seen) != 1 || seen[0] != jitterDraws {
			t.Fatalf("env %q: want only 0, got %v", env, seen)
		}
	}
}

func TestJitterEpochs_TypoFallsToDefault(t *testing.T) {
	for _, env := range []string{"-1", "x", "2.5", "1e3"} {
		requireDefaultRange(t, env, true)
	}
}

func TestJitterEpochs_LargeOverrideIsUniformOverWholeRange(t *testing.T) {
	seen, max := jitterSeen(t, "1000", true)
	for v := range seen {
		if v > 1000 {
			t.Fatalf("drew %d above the override 1000", v)
		}
	}
	if max <= 255 {
		t.Fatalf("max over %d draws of 0..1000 is %d; a one-byte draw caps at 255", jitterDraws, max)
	}
}

func TestJitterEpochs_MaxInt64BoundDoesNotOverflow(t *testing.T) {
	seen, _ := jitterSeen(t, "9223372036854775807", true)
	if len(seen) == 0 {
		t.Fatal("no draws")
	}
}

func TestJitterEpochs_ReadErrorFailsTowardDelay(t *testing.T) {
	old := jitterRand
	jitterRand = failingReader{}
	defer func() { jitterRand = old }()
	t.Setenv("ACTIVATION_JITTER_EPOCHS", "")
	os.Unsetenv("ACTIVATION_JITTER_EPOCHS")
	if got := jitterEpochs(); got != activationJitterEpochs {
		t.Fatalf("unset, read error: got %d, want %d", got, activationJitterEpochs)
	}
	t.Setenv("ACTIVATION_JITTER_EPOCHS", "7")
	if got := jitterEpochs(); got != 7 {
		t.Fatalf("override 7, read error: got %d, want 7", got)
	}
}
