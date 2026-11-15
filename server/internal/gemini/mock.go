package gemini

import (
	"context"
	"hash/fnv"
	"math/rand/v2"
	"time"
)

// Mock fakes Gemini when GEMINI_API_KEY is empty. Scores are deterministic per
// (clip, audio bytes) so re-submitting the same take gives the same numbers;
// roasts are random. It sleeps a little so the iPad's "judges deliberating"
// animation can be exercised.
type Mock struct {
	MinDelay, MaxDelay time.Duration
}

// NewMock returns a mock backend with a 300–900 ms fake latency.
func NewMock() *Mock {
	return &Mock{MinDelay: 300 * time.Millisecond, MaxDelay: 900 * time.Millisecond}
}

func (m *Mock) Name() string { return ScoredByMock }

var mockRoasts = []string{
	"You screamed at the sunset and whispered at the explosion.",
	"That table got slammed with more emotion than you put into the entire scene.",
	"I've seen more panic from a houseplant, and the houseplant had better comic timing.",
	"That was dreadful. I loved it. Don't tell anyone I said that.",
	"You treated a life-or-death confession like a grocery list, and still forgot the eggs.",
	"Your timing was immaculate; shame the jokes didn't get the memo.",
	"Bold choice to play a car chase like a bedtime story. Wrong, but bold.",
	"You arrived two seconds after the character did, which is commitment to being late.",
}

var emotionReasons = []string{
	"Flat through the big beat; the slam deserved more than a shrug.",
	"Some energy at the slam, but the quiet moment was rushed.",
	"Real panic right on the beat and a crisp deadpan after.",
}

var comedyReasons = []string{
	"The joke was mumbled and never landed.",
	"One solid laugh, then it fizzled out.",
	"A committed absurd bit that paid off on the final line.",
}

func (m *Mock) sleep(ctx context.Context) error {
	d := m.MinDelay
	if m.MaxDelay > m.MinDelay {
		d += time.Duration(rand.Int64N(int64(m.MaxDelay - m.MinDelay)))
	}
	select {
	case <-time.After(d):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *Mock) Score(ctx context.Context, in Input) (Scores, error) {
	if err := m.sleep(ctx); err != nil {
		return Scores{}, err
	}
	h := fnv.New64a()
	h.Write([]byte(in.Clip.ClipID))
	h.Write(in.Audio)
	v := h.Sum64()
	e := 3 + int(v%7)      // 3..9
	c := 3 + int((v>>8)%7) // 3..9
	return Scores{
		Emotion: e, Comedy: c,
		EmotionReason: emotionReasons[(e-3)/3%3],
		ComedyReason:  comedyReasons[(c-3)/3%3],
	}, nil
}

func (m *Mock) Roast(ctx context.Context, _ Input) (string, error) {
	if err := m.sleep(ctx); err != nil {
		return "", err
	}
	return mockRoasts[rand.IntN(len(mockRoasts))], nil
}
