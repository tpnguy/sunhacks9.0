package timing

import (
	"math"
	"testing"

	"github.com/dubstudio/server/internal/model"
)

func w(s, e float64) model.Window { return model.Window{Start: s, End: e} }

func near(t *testing.T, name string, got, want, eps float64) {
	t.Helper()
	if math.Abs(got-want) > eps {
		t.Errorf("%s = %.4f, want %.4f (±%g)", name, got, want, eps)
	}
}

// PLAN.md: "on a 3 s line, being 0.5 s late drops IoU from 1.0 → 2.5/3.5 ≈ 0.71".
// That example is the RAW IoU, without the 0.2 s tolerance.
func TestRawIoU_HalfSecondLateOn3sLine(t *testing.T) {
	ref := []model.Window{w(1, 4)}
	near(t, "on time", IoU([]model.Window{w(1, 4)}, ref), 1.0, 1e-9)
	near(t, "0.5s late", IoU([]model.Window{w(1.5, 4.5)}, ref), 2.5/3.5, 1e-9) // ≈ 0.714
	near(t, "0.5s early", IoU([]model.Window{w(0.5, 3.5)}, ref), 2.5/3.5, 1e-9)
}

// With the 0.2 s tolerance (the score actually shipped to players):
//
//	on time:     |[1,4] ∩ [0.8,4.2]| / |[1,4] ∪ [1,4]|     = 3.0/3.0 = 1.00 → 100
//	0.5 s late:  |[1.5,4.5] ∩ [0.8,4.2]| / |[1,4.5]|       = 2.7/3.5 ≈ 0.771 → 77
//	0.2 s late:  |[1.2,4.2] ∩ [0.8,4.2]| / |[1,4.2]|       = 3.0/3.2 ≈ 0.94 → 94
//
// So the tolerance softens lateness slightly (0.71 → 0.77) and keeps a perfect take at 100.
func TestScore_WithTolerance(t *testing.T) {
	ref := []model.Window{w(1, 4)}
	cases := []struct {
		name   string
		player []model.Window
		iou    float64
		score  int
	}{
		{"on time", []model.Window{w(1, 4)}, 1.0, 100},
		{"0.1s early start is free", []model.Window{w(0.9, 4)}, 1.0, 100},
		{"0.5s late", []model.Window{w(1.5, 4.5)}, 2.7 / 3.5, 77},
		{"0.2s late", []model.Window{w(1.2, 4.2)}, 3.0 / 3.2, 94},
		{"talks the whole clip", []model.Window{w(0, 15)}, 3.4 / 15, 23},
		{"silent during line, talks after", []model.Window{w(6, 9)}, 0, 0},
	}
	for _, c := range cases {
		near(t, c.name+" iou", TolerantIoU(c.player, ref, DefaultTolerance), c.iou, 1e-9)
		if got := Score(c.player, ref, 15); got != c.score {
			t.Errorf("%s: Score = %d, want %d", c.name, got, c.score)
		}
	}
}

// Documents why we don't use plain IoU against widened windows: it would cap a
// perfectly-timed 3 s line at 3/3.4 ≈ 0.88, and 0.5 s late would be 2.7/3.7 ≈ 0.73.
func TestPlainIoUAgainstWidenedWindows_Reference(t *testing.T) {
	ref := Widen([]model.Window{w(1, 4)}, DefaultTolerance)
	near(t, "perfect vs widened", IoU([]model.Window{w(1, 4)}, ref), 3.0/3.4, 1e-9)
	near(t, "late vs widened", IoU([]model.Window{w(1.5, 4.5)}, ref), 2.7/3.7, 1e-9)
}

func TestEmptyInputs(t *testing.T) {
	ref := []model.Window{w(1, 4)}
	if got := IoU(nil, nil); got != 0 {
		t.Errorf("IoU(nil,nil) = %v, want 0", got)
	}
	if got := Score(nil, ref, 15); got != 0 {
		t.Errorf("silent player: Score = %d, want 0", got)
	}
	if got := Score([]model.Window{w(1, 4)}, nil, 15); got != 0 {
		t.Errorf("clip with no speech: Score = %d, want 0", got)
	}
	if got := Score(nil, nil, 15); got != 0 {
		t.Errorf("both empty: Score = %d, want 0", got)
	}
	if got := Score([]model.Window{}, []model.Window{}, 0); got != 0 {
		t.Errorf("empty slices: Score = %d, want 0", got)
	}
}

func TestOverlappingSegmentsAreMerged(t *testing.T) {
	// Overlapping + duplicate + out-of-order VAD output covering [1,4] exactly.
	player := []model.Window{w(2.5, 4), w(1, 2), w(1.5, 3), w(1, 2)}
	m := Merge(player)
	if len(m) != 1 || m[0] != w(1, 4) {
		t.Fatalf("Merge = %v, want [{1 4}]", m)
	}
	if got := Score(player, []model.Window{w(1, 4)}, 15); got != 100 {
		t.Errorf("Score = %d, want 100 (overlaps must not double-count)", got)
	}
	// Two ref lines whose widened windows overlap merge into one.
	wr := Widen([]model.Window{w(1, 2), w(2.3, 3)}, 0.2)
	if len(wr) != 1 || math.Abs(wr[0].Start-0.8) > 1e-9 || math.Abs(wr[0].End-3.2) > 1e-9 {
		t.Errorf("Widen = %v, want [{0.8 3.2}]", wr)
	}
}

func TestMergeDropsInvalidSegments(t *testing.T) {
	in := []model.Window{w(3, 2), w(1, 1), w(math.NaN(), 2), w(0, math.Inf(1)), w(5, 6)}
	m := Merge(in)
	if len(m) != 1 || m[0] != w(5, 6) {
		t.Fatalf("Merge = %v, want [{5 6}]", m)
	}
}

func TestWidenClampsAtZero(t *testing.T) {
	m := Widen([]model.Window{w(0.1, 1)}, 0.2)
	if m[0].Start != 0 {
		t.Errorf("start = %v, want 0", m[0].Start)
	}
}

func TestMultipleLines(t *testing.T) {
	ref := []model.Window{w(1, 3), w(6, 8)}
	// Nails line 1, misses line 2 entirely: 2 / (2 + 2) = 0.5
	if got := Score([]model.Window{w(1, 3)}, ref, 15); got != 50 {
		t.Errorf("Score = %d, want 50", got)
	}
	// Both lines perfect.
	if got := Score(ref, ref, 15); got != 100 {
		t.Errorf("Score = %d, want 100", got)
	}
}

func TestClampToClipDuration(t *testing.T) {
	// Speech after the clip ends (clip 5 s) is ignored rather than penalised.
	if got := Score([]model.Window{w(1, 4), w(5, 30)}, []model.Window{w(1, 4)}, 5); got != 100 {
		t.Errorf("Score = %d, want 100", got)
	}
}

func TestDeterministic(t *testing.T) {
	p := []model.Window{w(1.13, 2.71), w(3.0, 3.9)}
	r := []model.Window{w(1.2, 3.85)}
	first := Score(p, r, 14.2)
	for i := 0; i < 100; i++ {
		if got := Score(p, r, 14.2); got != first {
			t.Fatalf("non-deterministic: %d vs %d", got, first)
		}
	}
}

func TestOverall(t *testing.T) {
	cases := []struct{ timing, emo, com, want int }{
		{72, 6, 8, 71}, // 36 + 35 = 71
		{100, 10, 10, 100},
		{0, 0, 0, 0},
		{77, 5, 5, 64}, // 38.5 + 25 = 63.5 → 64
	}
	for _, c := range cases {
		if got := model.Overall(c.timing, c.emo, c.com); got != c.want {
			t.Errorf("Overall(%d,%d,%d) = %d, want %d", c.timing, c.emo, c.com, got, c.want)
		}
	}
}
