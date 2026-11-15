// Package catalog holds the in-memory clip list. Clips change rarely, so they are
// loaded at startup (DynamoDB clips table → CLIPS_FILE → embedded testdata) and
// refreshed periodically; /clips and POST /takes never hit the database for clips.
package catalog

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"sort"
	"sync"
	"time"

	"github.com/dubstudio/server/internal/model"
)

// Source loads clips from somewhere (e.g. the DynamoDB clips table).
type Source interface {
	ListClips(ctx context.Context) ([]model.Clip, error)
}

// Catalog is a concurrency-safe clip cache.
type Catalog struct {
	mu     sync.RWMutex
	clips  []model.Clip
	byID   map[string]model.Clip
	origin string

	db       Source // may be nil
	file     string
	embedded []byte
}

// New builds a catalog; call Load before serving.
func New(db Source, file string, embedded []byte) *Catalog {
	return &Catalog{db: db, file: file, embedded: embedded, byID: map[string]model.Clip{}}
}

// Load tries each source in order and keeps the first non-empty result.
func (c *Catalog) Load(ctx context.Context) error {
	if c.db != nil {
		clips, err := c.db.ListClips(ctx)
		if err == nil && len(clips) > 0 {
			c.set(clips, "dynamodb")
			return nil
		}
		slog.Warn("clips: DynamoDB unavailable or empty, falling back to file", "err", err)
	}
	if c.file != "" {
		if b, err := os.ReadFile(c.file); err == nil {
			clips, err := Parse(b)
			if err == nil && len(clips) > 0 {
				c.set(clips, c.file)
				return nil
			}
			slog.Warn("clips: bad CLIPS_FILE, falling back to embedded", "file", c.file, "err", err)
		} else {
			slog.Warn("clips: CLIPS_FILE not readable, falling back to embedded", "file", c.file, "err", err)
		}
	}
	clips, err := Parse(c.embedded)
	if err != nil || len(clips) == 0 {
		return fmt.Errorf("no clips from any source: %w", err)
	}
	c.set(clips, "embedded testdata")
	return nil
}

// Refresh reloads every interval until ctx is done; errors keep the old list.
func (c *Catalog) Refresh(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			lctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			if err := c.Load(lctx); err != nil {
				slog.Warn("clips refresh failed", "err", err)
			}
			cancel()
		}
	}
}

// Parse decodes a clips.json array.
func Parse(b []byte) ([]model.Clip, error) {
	var clips []model.Clip
	if err := json.Unmarshal(b, &clips); err != nil {
		return nil, err
	}
	out := clips[:0]
	for _, cl := range clips {
		if cl.ClipID != "" {
			out = append(out, cl)
		}
	}
	return out, nil
}

func (c *Catalog) set(clips []model.Clip, origin string) {
	sort.SliceStable(clips, func(i, j int) bool { return clips[i].ClipID < clips[j].ClipID })
	by := make(map[string]model.Clip, len(clips))
	for _, cl := range clips {
		if cl.SpeechWindows == nil {
			cl.SpeechWindows = []model.Window{}
		}
		if cl.Beats == nil {
			cl.Beats = []model.Beat{}
		}
		by[cl.ClipID] = cl
	}
	c.mu.Lock()
	changed := c.origin != origin || len(c.clips) != len(clips)
	c.clips, c.byID, c.origin = clips, by, origin
	c.mu.Unlock()
	if changed {
		slog.Info("clips loaded", "count", len(clips), "source", origin)
	}
}

// All returns every clip (copy of the slice).
func (c *Catalog) All() []model.Clip {
	c.mu.RLock()
	defer c.mu.RUnlock()
	out := make([]model.Clip, 0, len(c.clips))
	for _, cl := range c.clips {
		out = append(out, c.byID[cl.ClipID])
	}
	return out
}

// Get returns a clip by id.
func (c *Catalog) Get(id string) (model.Clip, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	cl, ok := c.byID[id]
	return cl, ok
}

// Origin says where the current clips came from.
func (c *Catalog) Origin() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.origin
}
