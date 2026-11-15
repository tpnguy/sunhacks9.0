package gemini

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dubstudio/server/internal/model"
)

type fakeBackend struct {
	scoreCalls, roastCalls atomic.Int32
	score                  func(ctx context.Context, call int32) (Scores, error)
	roast                  func(ctx context.Context, call int32) (string, error)
}

func (f *fakeBackend) Name() string { return ScoredByGemini }
func (f *fakeBackend) Score(ctx context.Context, _ Input) (Scores, error) {
	return f.score(ctx, f.scoreCalls.Add(1))
}
func (f *fakeBackend) Roast(ctx context.Context, _ Input) (string, error) {
	return f.roast(ctx, f.roastCalls.Add(1))
}

func okScore(context.Context, int32) (Scores, error) {
	return Scores{Emotion: 7, Comedy: 8, EmotionReason: "e", ComedyReason: "c"}, nil
}
func okRoast(context.Context, int32) (string, error) { return "\"Nice.\"", nil }
func hang(ctx context.Context) error                 { <-ctx.Done(); return ctx.Err() }

func TestJudgeHappyPath(t *testing.T) {
	j := NewJudge(&fakeBackend{score: okScore, roast: okRoast}, time.Second)
	r := j.Judge(context.Background(), Input{})
	if r.Emotion != 7 || r.Comedy != 8 || r.Roast != "Nice." || r.ScoredBy != "gemini" || r.FallbackUsed || r.GeminiTimeout {
		t.Errorf("unexpected %+v", r)
	}
}

func TestJudgeRetrySucceeds(t *testing.T) {
	f := &fakeBackend{
		score: func(ctx context.Context, n int32) (Scores, error) {
			if n == 1 {
				return Scores{}, errors.New("503")
			}
			return okScore(ctx, n)
		},
		roast: okRoast,
	}
	r := NewJudge(f, time.Second).Judge(context.Background(), Input{})
	if r.ScoredBy != "gemini" || r.Emotion != 7 || f.scoreCalls.Load() != 2 {
		t.Errorf("retry failed: %+v calls=%d", r, f.scoreCalls.Load())
	}
}

func TestJudgeTimeoutFallback(t *testing.T) {
	f := &fakeBackend{
		score: func(ctx context.Context, _ int32) (Scores, error) { return Scores{}, hang(ctx) },
		roast: func(ctx context.Context, _ int32) (string, error) { return "", hang(ctx) },
	}
	start := time.Now()
	r := NewJudge(f, 50*time.Millisecond).Judge(context.Background(), Input{})
	if el := time.Since(start); el > 500*time.Millisecond {
		t.Errorf("took %v; calls must run in parallel with bounded retries", el)
	}
	if r.ScoredBy != "fallback" || r.Emotion != 5 || r.Comedy != 5 || !r.FallbackUsed || !r.GeminiTimeout {
		t.Errorf("unexpected %+v", r)
	}
	if !strings.Contains(r.Roast, "coffee break") {
		t.Errorf("roast = %q", r.Roast)
	}
	if f.scoreCalls.Load() != 2 || f.roastCalls.Load() != 2 {
		t.Errorf("want 1 retry each, got score=%d roast=%d", f.scoreCalls.Load(), f.roastCalls.Load())
	}
}

func TestJudgeOutOfRangeIsFallback(t *testing.T) {
	f := &fakeBackend{
		score: func(context.Context, int32) (Scores, error) { return Scores{Emotion: 11, Comedy: 3}, nil },
		roast: okRoast,
	}
	r := NewJudge(f, time.Second).Judge(context.Background(), Input{})
	if r.ScoredBy != "fallback" || r.Emotion != 5 || r.Roast != "Nice." {
		t.Errorf("unexpected %+v", r)
	}
}

func TestRoastOnlyFailure(t *testing.T) {
	f := &fakeBackend{score: okScore, roast: func(context.Context, int32) (string, error) { return "  ", nil }}
	r := NewJudge(f, time.Second).Judge(context.Background(), Input{})
	if r.ScoredBy != "gemini" || !r.FallbackUsed || r.Roast == "" {
		t.Errorf("unexpected %+v", r)
	}
}

func TestMockDeterministicScores(t *testing.T) {
	m := &Mock{}
	in := Input{Clip: model.Clip{ClipID: "x"}, Audio: []byte("same audio")}
	a, _ := m.Score(context.Background(), in)
	b, _ := m.Score(context.Background(), in)
	if a != b || a.Emotion < 3 || a.Emotion > 9 || a.Comedy < 3 || a.Comedy > 9 {
		t.Errorf("mock scores %+v %+v", a, b)
	}
}

func TestBuildContext(t *testing.T) {
	in := Input{
		Clip:   model.Clip{Title: "T", Duration: 14.2, SpeechWindows: []model.Window{{Start: 1.2, End: 3.85}}, Beats: []model.Beat{{T: 4, Desc: "he slams the table", Emotion: "anger"}}},
		Timing: 72,
	}
	s := BuildContext(in, false)
	if !strings.Contains(s, "4.0 s: he slams the table → anger") || strings.Contains(s, "Timing score") {
		t.Errorf("scorer context:\n%s", s)
	}
	if !strings.Contains(BuildContext(in, true), "Timing score computed by code (0–100, how well they talked when the characters talk): 72") {
		t.Errorf("roaster context missing timing")
	}
}

func TestGeminiAudioMIME(t *testing.T) {
	for in, want := range map[string]string{"audio/mp4": "audio/m4a", "": "audio/m4a", "audio/x-m4a": "audio/m4a", "audio/wav": "audio/wav", "audio/aac": "audio/aac"} {
		if got := GeminiAudioMIME(in); got != want {
			t.Errorf("%q → %q, want %q", in, got, want)
		}
	}
}
