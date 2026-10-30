package adaptive

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestAdaptiveRecoveryRequiresConsecutiveSuccessAndCooldown(t *testing.T) {
	now := time.Now()
	s := State{}.Apply(Sample{IPv4: true}, now)
	if !s.Verified || !s.IPv4Only {
		t.Fatal(s)
	}
	for i := 1; i <= 3; i++ {
		s = s.Apply(Sample{IPv6: true}, now.Add(time.Duration(i)*time.Minute))
	}
	if !s.IPv4Only {
		t.Fatal("recovered before cooldown")
	}
	s = s.Apply(Sample{}, now.Add(9*time.Minute))
	for i := 10; i <= 11; i++ {
		s = s.Apply(Sample{IPv6: true}, now.Add(time.Duration(i)*time.Minute))
	}
	if !s.IPv4Only {
		t.Fatal("unknown result did not reset streak")
	}
	s = s.Apply(Sample{IPv6: true}, now.Add(12*time.Minute))
	if s.IPv4Only {
		t.Fatal("did not recover")
	}
}

func TestAdaptiveUnknownDoesNotInventFamilyFailure(t *testing.T) {
	if s := (State{}).Apply(Sample{}, time.Now()); s.Verified || s.IPv4Only {
		t.Fatal(s)
	}
	s := State{}.Apply(Sample{IPv6: true}, time.Now()).Apply(Sample{}, time.Now())
	if s.IPv4Only {
		t.Fatal(s)
	}
	s = s.Apply(Sample{IPv4: true}, time.Now()).Apply(Sample{}, time.Now())
	if !s.IPv4Only {
		t.Fatal(s)
	}
}

func TestAdaptiveConcurrentChecksShareProbe(t *testing.T) {
	var calls int32
	entered, release := make(chan struct{}), make(chan struct{})
	c := New("node", "", func(context.Context) Sample {
		atomic.AddInt32(&calls, 1)
		close(entered)
		<-release
		return Sample{IPv4: true}
	})
	defer c.Close()
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if !c.Check(context.Background()).IPv4Only {
				t.Error("lost diagnosis")
			}
		}()
	}
	<-entered
	close(release)
	wg.Wait()
	if calls != 1 {
		t.Fatal(calls)
	}
}

func TestAdaptiveInvalidatedResultCannotBePublished(t *testing.T) {
	for _, global := range []bool{false, true} {
		entered, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
		c := New("node", "", func(context.Context) Sample { close(entered); <-release; return Sample{IPv4: true} })
		go func() { c.Check(context.Background()); close(done) }()
		<-entered
		if global {
			InvalidateAll()
		} else {
			c.Invalidate()
		}
		close(release)
		<-done
		if c.Snapshot().Verified {
			t.Fatal("old epoch published")
		}
		c.Close()
	}
}

func TestAdaptiveCancellationAndCloseAreNotFailures(t *testing.T) {
	entered, done := make(chan struct{}), make(chan struct{})
	c := New("node", "", func(ctx context.Context) Sample { close(entered); <-ctx.Done(); return Sample{IPv4: true} })
	go func() { c.Check(context.Background()); close(done) }()
	<-entered
	c.Close()
	<-done
	if c.Snapshot().Verified {
		t.Fatal("cancelled probe published")
	}
	c.Check(context.Background()) // Closed instances never start another probe.
}

func TestAdaptiveCacheIsPrivateIsolatedAndReverified(t *testing.T) {
	dir := t.TempDir()
	c := New("account-one", dir, func(context.Context) Sample { return Sample{IPv4: true} })
	c.Check(context.Background())
	c.Close()
	restored := New("account-one", dir, func(context.Context) Sample { return Sample{IPv6: true} })
	defer restored.Close()
	if !restored.Snapshot().IPv4Only {
		t.Fatal("cache missing")
	}
	restored.Check(context.Background())
	if restored.Snapshot().Successes != 1 {
		t.Fatal("cache skipped revalidation")
	}
	other := New("account-two", dir, func(context.Context) Sample { return Sample{} })
	defer other.Close()
	if other.Snapshot().Verified {
		t.Fatal("cross-account cache")
	}
	files, _ := os.ReadDir(dir)
	if len(files) != 1 {
		t.Fatal(files)
	}
	info, _ := os.Stat(filepath.Join(dir, files[0].Name()))
	if info.Mode().Perm()&0077 != 0 {
		t.Fatal("public diagnosis")
	}
}
