package store

import (
	"context"
	"sort"
	"sync"

	"github.com/dubstudio/server/internal/model"
)

// Memory is an in-process Store. Data is lost on restart.
type Memory struct {
	mu      sync.RWMutex
	takes   map[string]model.Take
	players map[string]string
	clips   []model.Clip
}

// NewMemory returns an empty in-memory store. clips (optional) is returned by ListClips.
func NewMemory(clips []model.Clip) *Memory {
	return &Memory{takes: map[string]model.Take{}, players: map[string]string{}, clips: clips}
}

func (m *Memory) PutTake(_ context.Context, t model.Take) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.takes[t.TakeID] = t
	return nil
}

func (m *Memory) GetTake(_ context.Context, id string) (model.Take, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	t, ok := m.takes[id]
	if !ok {
		return model.Take{}, ErrNotFound
	}
	return t, nil
}

func (m *Memory) SetUploadStatus(_ context.Context, id, status string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.takes[id]
	if !ok {
		return ErrNotFound
	}
	t.UploadStatus = status
	m.takes[id] = t
	return nil
}

func (m *Memory) DeleteTake(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.takes, id)
	return nil
}

func (m *Memory) Leaderboard(_ context.Context, clipID string, limit int) ([]model.Take, error) {
	limit = ClampLimit(limit)
	m.mu.RLock()
	out := make([]model.Take, 0, len(m.takes))
	for _, t := range m.takes {
		if clipID == "" || t.ClipID == clipID {
			out = append(out, t)
		}
	}
	m.mu.RUnlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].Overall != out[j].Overall {
			return out[i].Overall > out[j].Overall
		}
		return out[i].CreatedAt > out[j].CreatedAt
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (m *Memory) UpsertPlayer(_ context.Context, id, nick string) error {
	if id == "" {
		return nil
	}
	m.mu.Lock()
	m.players[id] = nick
	m.mu.Unlock()
	return nil
}

func (m *Memory) ListClips(context.Context) ([]model.Clip, error) { return m.clips, nil }
