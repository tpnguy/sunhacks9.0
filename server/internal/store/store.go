// Package store persists takes (and reads clips/players). Two implementations:
// DynamoDB (production) and in-memory (STORE=memory, local dev and tests).
package store

import (
	"context"
	"errors"

	"github.com/dubstudio/server/internal/model"
)

// ErrNotFound is returned when a take does not exist.
var ErrNotFound = errors.New("not found")

// Store is everything the HTTP layer needs from persistence.
type Store interface {
	PutTake(ctx context.Context, t model.Take) error
	GetTake(ctx context.Context, takeID string) (model.Take, error)
	// SetUploadStatus updates upload_status; ErrNotFound if the take is missing.
	SetUploadStatus(ctx context.Context, takeID, status string) error
	DeleteTake(ctx context.Context, takeID string) error
	// Leaderboard returns the top `limit` takes by overall desc, for one clip
	// (clipID != "") or across all clips.
	Leaderboard(ctx context.Context, clipID string, limit int) ([]model.Take, error)
	// UpsertPlayer records a player's latest nickname (best effort).
	UpsertPlayer(ctx context.Context, playerID, nickname string) error
	// ListClips reads the clips table (catalog source).
	ListClips(ctx context.Context) ([]model.Clip, error)
	// UpdateScores replaces a fallback take's Gemini scores. It only applies
	// while the take exists and is still scored_by "fallback"; otherwise it
	// returns ErrNotFound (deleted, or already re-scored by a duplicate message).
	UpdateScores(ctx context.Context, takeID string, r Rescore) error
}

// Rescore is the Gemini half of a scorecard, written by the async re-score worker.
type Rescore struct {
	Emotion, Comedy, Overall           int
	Roast, EmotionReason, ComedyReason string
	ScoredBy                           string
	RescoredAt                         string // RFC3339 UTC
}

// scoredByFallback mirrors gemini.ScoredByFallback (store must not import gemini).
const scoredByFallback = "fallback"

// ClampLimit normalises a leaderboard limit to 1..100 (default 10).
func ClampLimit(n int) int {
	if n <= 0 {
		return 10
	}
	if n > 100 {
		return 100
	}
	return n
}
