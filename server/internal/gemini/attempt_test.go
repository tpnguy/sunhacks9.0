package gemini

import (
	"context"
	"errors"
	"testing"
	"time"
)

// attemptBackend fails the first call and records which attempt each call saw, so we can check
// that the retry is tagged attempt 1 (which makes the real client switch to the fallback model).
type attemptBackend struct{ seen []int }

func (b *attemptBackend) Score(ctx context.Context, _ Input) (Scores, error) {
	b.seen = append(b.seen, AttemptFrom(ctx))
	if len(b.seen) == 1 {
		return Scores{}, errors.New("503 busy")
	}
	return Scores{Emotion: 7, Comedy: 6, EmotionReason: "ok", ComedyReason: "ok"}, nil
}
func (b *attemptBackend) Roast(context.Context, Input) (string, error) { return "fine", nil }
func (b *attemptBackend) Name() string                                 { return ScoredByGemini }

func TestRetryIsTaggedForFallbackModel(t *testing.T) {
	b := &attemptBackend{}
	res := NewJudge(b, time.Second).Judge(context.Background(), Input{})
	if res.ScoredBy != ScoredByGemini || res.Emotion != 7 {
		t.Fatalf("retry should succeed: %+v", res)
	}
	if len(b.seen) != 2 || b.seen[0] != 0 || b.seen[1] != 1 {
		t.Fatalf("attempts seen = %v, want [0 1]", b.seen)
	}
}
