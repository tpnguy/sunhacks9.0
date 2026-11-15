// Package gemini is the "AI scores taste" half of DubStudio: a temperature-0
// scoring call (emotion, comedy) and a higher-temperature roast call, run in
// parallel with per-attempt timeouts, one retry, and a designed fallback.
package gemini

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"strings"
	"sync"
	"time"

	"github.com/dubstudio/server/internal/model"
)

// ScoredBy values.
const (
	ScoredByGemini   = "gemini"
	ScoredByFallback = "fallback"
	ScoredByMock     = "mock"
	ScoredByNoAudio  = "no_audio" // nothing audible was recorded; Gemini was not called
)

// NoAudioRoasts are shown when the recording is empty or silent.
var NoAudioRoasts = []string{
	"The judges leaned in, cupped their ears, and heard absolutely nothing. Check the mic and try again.",
	"A bold artistic choice: total silence. Unfortunately the judges score sound.",
	"We couldn't hear a thing. Either the mic is off or you've mastered the silent film.",
}

// NoAudioResult is the scorecard for a take with nothing audible to judge.
func NoAudioResult() Result {
	return Result{
		Emotion: 0, Comedy: 0,
		EmotionReason: "We couldn't hear you.", ComedyReason: "We couldn't hear you.",
		Roast: NoAudioRoasts[rand.IntN(len(NoAudioRoasts))], ScoredBy: ScoredByNoAudio,
	}
}

// FallbackScore is used for emotion and comedy when scoring fails.
const FallbackScore = 5

// FallbackRoasts are the canned "judges on a coffee break" lines.
var FallbackRoasts = []string{
	"The judges are on a coffee break. Your timing score is real, though, and it's watching you.",
	"The judges are on a coffee break; they heard you were coming and needed a minute.",
	"The judges are on a coffee break. Bold of you to perform without supervision.",
	"The judges are on a coffee break. Consider this a standing ovation from an empty chair.",
}

// Input is everything the judges get. The player's selfie/avatar never is.
type Input struct {
	Clip   model.Clip
	Audio  []byte
	MIME   string
	Timing int // deterministic timing score, roaster only
	VAD    []model.Window
}

// Result is the merged scorecard from both calls (or fallbacks).
type Result struct {
	Emotion       int
	Comedy        int
	EmotionReason string
	ComedyReason  string
	Roast         string
	ScoredBy      string
	GeminiTimeout bool // any attempt hit its deadline
	FallbackUsed  bool // score or roast fell back
}

// Scores is the structured output of the scoring call.
type Scores struct {
	Emotion       int    `json:"emotion"`
	Comedy        int    `json:"comedy"`
	EmotionReason string `json:"emotion_reason"`
	ComedyReason  string `json:"comedy_reason"`
}

// Backend performs single model calls. Implemented by the real Gemini client and the mock.
type Backend interface {
	Score(ctx context.Context, in Input) (Scores, error)
	Roast(ctx context.Context, in Input) (string, error)
	Name() string // ScoredByGemini or ScoredByMock
}

// Judge orchestrates both calls with timeouts, retry and fallback.
type Judge struct {
	backend Backend
	timeout time.Duration // per attempt
	retries int
}

// NewJudge wraps a backend. timeout is per attempt; there is 1 retry.
func NewJudge(b Backend, timeout time.Duration) *Judge {
	return &Judge{backend: b, timeout: timeout, retries: 1}
}

// Mode reports "gemini" or "mock".
func (j *Judge) Mode() string { return j.backend.Name() }

// Judge never fails: on any error it returns a fallback scorecard so the UI stays consistent.
func (j *Judge) Judge(ctx context.Context, in Input) Result {
	var (
		wg                 sync.WaitGroup
		scores             Scores
		roast              string
		scoreErr, roastErr error
		scoreTO, roastTO   bool
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		scoreTO, scoreErr = j.withRetry(ctx, "score", func(c context.Context) error {
			s, err := j.backend.Score(c, in)
			if err == nil {
				err = validateScores(&s)
			}
			if err == nil {
				scores = s
			}
			return err
		})
	}()
	go func() {
		defer wg.Done()
		roastTO, roastErr = j.withRetry(ctx, "roast", func(c context.Context) error {
			r, err := j.backend.Roast(c, in)
			r = cleanRoast(r)
			if err == nil && r == "" {
				err = errors.New("empty roast")
			}
			if err == nil {
				roast = r
			}
			return err
		})
	}()
	wg.Wait()

	res := Result{GeminiTimeout: scoreTO || roastTO, ScoredBy: j.backend.Name()}
	if scoreErr != nil {
		slog.Warn("gemini score failed, using fallback", "err", scoreErr)
		res.Emotion, res.Comedy = FallbackScore, FallbackScore
		res.EmotionReason = "The judges missed this one; everyone gets a 5."
		res.ComedyReason = "The judges missed this one; everyone gets a 5."
		res.ScoredBy = ScoredByFallback
		res.FallbackUsed = true
	} else {
		res.Emotion, res.Comedy = scores.Emotion, scores.Comedy
		res.EmotionReason, res.ComedyReason = scores.EmotionReason, scores.ComedyReason
	}
	if roastErr != nil {
		slog.Warn("gemini roast failed, using canned roast", "err", roastErr)
		res.Roast = FallbackRoasts[rand.IntN(len(FallbackRoasts))]
		res.FallbackUsed = true
	} else {
		res.Roast = roast
	}
	return res
}

// withRetry runs fn up to 1+retries times, each with its own timeout.
func (j *Judge) withRetry(ctx context.Context, what string, fn func(context.Context) error) (timedOut bool, err error) {
	for attempt := 0; attempt <= j.retries; attempt++ {
		if ctx.Err() != nil {
			return timedOut, ctx.Err()
		}
		actx, cancel := context.WithTimeout(WithAttempt(ctx, attempt), j.timeout)
		err = fn(actx)
		if errors.Is(actx.Err(), context.DeadlineExceeded) {
			timedOut = true
			if err == nil {
				err = actx.Err()
			}
		}
		cancel()
		if err == nil {
			return timedOut, nil
		}
		slog.Warn("gemini attempt failed", "call", what, "attempt", attempt+1, "err", err, "err_detail", fmt.Sprintf("%+v", err))
	}
	return timedOut, err
}

func validateScores(s *Scores) error {
	if s.Emotion < 0 || s.Emotion > 10 || s.Comedy < 0 || s.Comedy > 10 {
		return fmt.Errorf("scores out of range: emotion=%d comedy=%d", s.Emotion, s.Comedy)
	}
	s.EmotionReason = strings.TrimSpace(s.EmotionReason)
	s.ComedyReason = strings.TrimSpace(s.ComedyReason)
	return nil
}

func cleanRoast(r string) string {
	r = strings.TrimSpace(r)
	r = strings.Trim(r, "\"“”")
	r = strings.TrimSpace(r)
	if len([]rune(r)) > 280 {
		r = string([]rune(r)[:277]) + "..."
	}
	return r
}

// BuildContext renders the clip timeline that accompanies the audio.
// includeTiming adds the code-computed timing score (roaster only; the scorer
// must not judge timing).
func BuildContext(in Input, includeTiming bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "Clip: %q (%.1f s long). t=0 of the audio is the start of the clip.\n", in.Clip.Title, in.Clip.Duration)
	b.WriteString("When the on-screen characters speak (reference speech windows): ")
	b.WriteString(fmtWindows(in.Clip.SpeechWindows))
	b.WriteString("\nBeats (timestamp: what happens on screen → emotion the scene calls for):\n")
	if len(in.Clip.Beats) == 0 {
		b.WriteString("- (no beats provided)\n")
	}
	for _, bt := range in.Clip.Beats {
		fmt.Fprintf(&b, "- %.1f s: %s → %s\n", bt.T, bt.Desc, bt.Emotion)
	}
	if includeTiming {
		b.WriteString("When the player spoke (detected by voice activity): ")
		b.WriteString(fmtWindows(in.VAD))
		fmt.Fprintf(&b, "\nTiming score computed by code (0–100, how well they talked when the characters talk): %d\n", in.Timing)
	}
	b.WriteString("The player's recorded performance is attached as audio.")
	return b.String()
}

func fmtWindows(ws []model.Window) string {
	if len(ws) == 0 {
		return "(none)"
	}
	parts := make([]string, 0, len(ws))
	for _, w := range ws {
		parts = append(parts, fmt.Sprintf("%.1f–%.1f s", w.Start, w.End))
	}
	return strings.Join(parts, ", ")
}

type attemptKey struct{}

// WithAttempt tags a call with its retry number so the backend can switch to the fallback
// model on a retry (a busy or slow model rarely recovers within seconds).
func WithAttempt(ctx context.Context, attempt int) context.Context {
	return context.WithValue(ctx, attemptKey{}, attempt)
}

// AttemptFrom returns the retry number (0 = first try).
func AttemptFrom(ctx context.Context) int {
	if n, ok := ctx.Value(attemptKey{}).(int); ok {
		return n
	}
	return 0
}
