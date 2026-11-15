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
}

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
