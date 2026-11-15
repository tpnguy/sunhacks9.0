// Package timing computes the deterministic timing score: time-IoU between the
// player's VAD segments and the clip's reference speech windows.
//
// Gemini never touches this number. Same input → same output, always.
package timing

import (
	"math"
	"sort"

	"github.com/dubstudio/server/internal/model"
)

// DefaultTolerance is how far (seconds) each reference window is widened on each side.
const DefaultTolerance = 0.2

// Merge sorts segments, drops invalid ones (NaN/Inf, end <= start) and merges
// overlapping or touching segments. The input slice is not modified.
func Merge(segs []model.Window) []model.Window {
	clean := make([]model.Window, 0, len(segs))
	for _, s := range segs {
		if !finite(s.Start) || !finite(s.End) || s.End <= s.Start {
			continue
		}
		clean = append(clean, s)
	}
	sort.Slice(clean, func(i, j int) bool { return clean[i].Start < clean[j].Start })
	out := make([]model.Window, 0, len(clean))
	for _, s := range clean {
		if n := len(out); n > 0 && s.Start <= out[n-1].End {
			if s.End > out[n-1].End {
				out[n-1].End = s.End
			}
			continue
		}
		out = append(out, s)
	}
	return out
}

// Widen grows every window by tol on each side (start clamped at 0) and re-merges.
func Widen(segs []model.Window, tol float64) []model.Window {
	w := make([]model.Window, 0, len(segs))
	for _, s := range segs {
		w = append(w, model.Window{Start: math.Max(0, s.Start-tol), End: s.End + tol})
	}
	return Merge(w)
}

// Clamp restricts segments to [0, maxT]. maxT <= 0 means no upper bound.
func Clamp(segs []model.Window, maxT float64) []model.Window {
	out := make([]model.Window, 0, len(segs))
	for _, s := range segs {
		if s.Start < 0 {
			s.Start = 0
		}
		if maxT > 0 && s.End > maxT {
			s.End = maxT
		}
		if s.End > s.Start {
			out = append(out, s)
		}
	}
	return out
}

// Length is the total duration covered by the (merged) segments.
func Length(segs []model.Window) float64 {
	var total float64
	for _, s := range Merge(segs) {
		total += s.End - s.Start
	}
	return total
}

// Intersection is the duration covered by both a and b.
func Intersection(a, b []model.Window) float64 {
	a, b = Merge(a), Merge(b)
	var total float64
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		lo := math.Max(a[i].Start, b[j].Start)
		hi := math.Min(a[i].End, b[j].End)
		if hi > lo {
			total += hi - lo
		}
		if a[i].End < b[j].End {
			i++
		} else {
			j++
		}
	}
	return total
}

// Union is the duration covered by a or b.
func Union(a, b []model.Window) float64 {
	return Length(a) + Length(b) - Intersection(a, b)
}

// IoU is plain time intersection-over-union in 0..1 (no tolerance). Returns 0 when
// both inputs are empty.
func IoU(a, b []model.Window) float64 {
	u := Union(a, b)
	if u <= 0 {
		return 0
	}
	return Intersection(a, b) / u
}

// TolerantIoU is the IoU used for the game score:
//
//	|player ∩ widen(ref, tol)| / |player ∪ ref|
//
// The reference windows are widened by tol on each side when deciding which player
// speech "counts" (so starting 0.2 s early is free), but the union uses the raw
// reference so that a perfectly timed take scores exactly 1.0. (Plain IoU against
// widened windows would cap a perfect 3 s line at 3/3.4 ≈ 0.88.) The result is
// always in 0..1 because player∩widened ⊆ player ⊆ player∪ref.
func TolerantIoU(player, ref []model.Window, tol float64) float64 {
	p := Merge(player)
	r := Merge(ref)
	u := Union(p, r)
	if u <= 0 {
		return 0
	}
	v := Intersection(p, Widen(r, tol)) / u
	if v > 1 {
		v = 1
	}
	return v
}

// Score returns the 0..100 timing score from API.md: round(100 × IoU) with the
// reference windows widened by DefaultTolerance and segments merged. Player segments
// are clamped to the clip duration (if > 0).
func Score(player, ref []model.Window, clipDuration float64) int {
	p := Clamp(player, clipDuration)
	return int(math.Round(100 * TolerantIoU(p, ref, DefaultTolerance)))
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
