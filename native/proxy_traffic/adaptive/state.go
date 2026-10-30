// Package adaptive tracks verified outbound capability, never server address families.
package adaptive

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

var revision uint64

// Recheck on node selection or subscription/configuration replacement.
func InvalidateAll() { atomic.AddUint64(&revision, 1) }

const Interval = 5 * time.Minute
const Cooldown = 10 * time.Minute
const Expiry = 24 * time.Hour

// Sample is conclusive only after application responses through the tested exit.
// Both IPv6 destinations must fail while IPv4 works to declare a family outage.
type Sample struct{ IPv4, IPv6 bool }
type State struct {
	IPv4Only  bool      `json:"ipv4Only"`
	Verified  bool      `json:"verified"`
	Successes int       `json:"successes"`
	CheckedAt time.Time `json:"checkedAt"`
	ChangedAt time.Time `json:"changedAt"`
}

func (s State) Apply(sample Sample, now time.Time) State {
	if sample.IPv6 {
		s.Successes++
		if !s.Verified || (!s.IPv4Only) || (s.Successes >= 3 && now.Sub(s.ChangedAt) >= Cooldown) {
			if s.IPv4Only {
				s.ChangedAt = now
			}
			s.IPv4Only = false
		}
		s.Verified = true
	} else {
		s.Successes = 0
		if sample.IPv4 {
			if !s.IPv4Only || !s.Verified {
				s.ChangedAt = now
			}
			s.IPv4Only = true
			s.Verified = true
		}
		// Neither family responding is unknown, never a node-wide failure verdict.
	}
	if s.Successes > 3 {
		s.Successes = 3
	}
	s.CheckedAt = now
	return s
}

type Controller struct {
	mu         sync.Mutex
	state      State
	path       string
	probe      func(context.Context) Sample
	ctx        context.Context
	cancel     context.CancelFunc
	flight     chan struct{}
	generation uint64
	revision   uint64
	force      bool
	started    bool
	closed     bool
	lastUse    time.Time
}

func New(identity, directory string, probe func(context.Context) Sample) *Controller {
	ctx, cancel := context.WithCancel(context.Background())
	c := &Controller{state: State{}, probe: probe, ctx: ctx, cancel: cancel, force: true}
	if directory != "" {
		hash := sha256.Sum256([]byte(identity))
		c.path = filepath.Join(directory, hex.EncodeToString(hash[:])+".json")
		if info, err := os.Lstat(c.path); err == nil && info.Mode().IsRegular() && info.Size() <= 4096 {
			if data, err := os.ReadFile(c.path); err == nil {
				var state State
				if json.Unmarshal(data, &state) == nil && state.Verified && state.Successes >= 0 && state.Successes <= 3 && time.Since(state.CheckedAt) >= 0 && time.Since(state.CheckedAt) < Expiry && !state.ChangedAt.After(state.CheckedAt) {
					state.Successes = 0
					c.state = state
				}
			}
		}
	}
	return c
}

func (c *Controller) Snapshot() State { c.mu.Lock(); defer c.mu.Unlock(); return c.state }

// Invalidate rejects a probe from the previous selection/configuration epoch.
func (c *Controller) Invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.generation++
	c.force = true
	c.state.Successes = 0
}

func (c *Controller) Close() {
	c.mu.Lock()
	c.closed = true
	c.generation++
	c.mu.Unlock()
	c.cancel()
}

// Check is called before the first new flow; concurrent callers share one probe.
// Cancellation never turns the result into a permanent capability declaration.
func (c *Controller) Check(ctx context.Context) State {
	c.mu.Lock()
	c.lastUse = time.Now()
	c.mu.Unlock()
	return c.check(ctx)
}

func (c *Controller) check(ctx context.Context) State {
	c.mu.Lock()

	if c.closed {
		s := c.state
		c.mu.Unlock()
		return s
	}
	if !c.started {
		c.started = true
		go c.loop()
	}
	for {
		if ctx.Err() != nil {
			s := c.state
			c.mu.Unlock()
			return s
		}
		currentRevision := atomic.LoadUint64(&revision)
		if currentRevision != c.revision {
			c.force = true
			c.generation++
			c.state.Successes = 0
			c.revision = currentRevision
		}
		if c.flight != nil {
			flight := c.flight
			c.mu.Unlock()
			select {
			case <-flight:
			case <-ctx.Done():
				return c.Snapshot()
			case <-c.ctx.Done():
				return c.Snapshot()
			}
			c.mu.Lock()
			if c.closed {
				s := c.state
				c.mu.Unlock()
				return s
			}
			continue
		}
		if !c.force && time.Since(c.state.CheckedAt) < Interval {
			s := c.state
			c.mu.Unlock()
			return s
		}
		c.flight = make(chan struct{})
		flight := c.flight
		epoch := c.generation
		c.mu.Unlock()
		probeCtx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
		finished := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				cancel()
			case <-finished:
			}
		}()
		sample := c.probe(probeCtx)
		close(finished)
		cancelled := probeCtx.Err() != nil
		cancel()
		c.mu.Lock()
		if !c.closed && epoch == c.generation && currentRevision == atomic.LoadUint64(&revision) && !cancelled {
			c.state = c.state.Apply(sample, time.Now())
			c.force = false
			c.persistLocked()
		}
		close(flight)
		c.flight = nil
		s := c.state
		c.mu.Unlock()
		return s
	}
}

func (c *Controller) loop() {
	ticker := time.NewTicker(Interval)
	defer ticker.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-ticker.C:
			c.mu.Lock()
			active := !c.closed && time.Since(c.lastUse) < 2*Interval
			c.mu.Unlock()
			if active {
				c.check(c.ctx)
			} else {
				c.mu.Lock()
				c.started = false
				c.mu.Unlock()
				return
			}
		}
	}
}

func (c *Controller) persistLocked() {
	if c.path == "" || !c.state.Verified {
		return
	}
	directory := filepath.Dir(c.path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return
	}
	info, err := os.Lstat(directory)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return
	}
	// Bounded state cache; don't delete another process's files to make room.
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) > 1024 {
		return
	}
	data, err := json.Marshal(c.state)
	if err != nil {
		return
	}
	f, err := os.CreateTemp(directory, ".egress-")
	if err != nil {
		return
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(name, c.path)
	}
}
