// Package metrics emits CloudWatch Embedded Metric Format (EMF) JSON lines to stdout.
// On EC2, systemd → journald → CloudWatch agent ships them, and CloudWatch turns
// them into metrics in the DubStudio namespace with no PutMetricData calls.
package metrics

import (
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"
)

const (
	Namespace   = "DubStudio"
	ServiceName = "dubstudio-server"
)

// Emitter writes EMF records. The zero value is not usable; use New or Default.
type Emitter struct {
	mu sync.Mutex
	w  io.Writer
}

// New returns an Emitter writing to w.
func New(w io.Writer) *Emitter { return &Emitter{w: w} }

// Default writes to stdout (regular logs go to stderr, so stdout is EMF only).
var Default = New(os.Stdout)

// ScoringEvent is one POST /takes outcome.
type ScoringEvent struct {
	LatencyMS     int64
	GeminiTimeout bool
	FallbackUsed  bool
	ScoredBy      string
	ClipID        string
	TakeID        string
	Model         string
}

type metricDef struct {
	Name string `json:"Name"`
	Unit string `json:"Unit"`
}

type directive struct {
	Namespace  string      `json:"Namespace"`
	Dimensions [][]string  `json:"Dimensions"`
	Metrics    []metricDef `json:"Metrics"`
}

// Scoring emits scoring_latency_ms, gemini_timeout and fallback_used.
// Dimension: Service only (low cardinality); clip/take ids ride along as
// searchable properties in Logs Insights.
func (e *Emitter) Scoring(ev ScoringEvent) {
	rec := map[string]any{
		"_aws": map[string]any{
			"Timestamp": time.Now().UnixMilli(),
			"CloudWatchMetrics": []directive{{
				Namespace:  Namespace,
				Dimensions: [][]string{{"Service"}},
				Metrics: []metricDef{
					{Name: "scoring_latency_ms", Unit: "Milliseconds"},
					{Name: "gemini_timeout", Unit: "Count"},
					{Name: "fallback_used", Unit: "Count"},
				},
			}},
		},
		"Service":            ServiceName,
		"scoring_latency_ms": ev.LatencyMS,
		"gemini_timeout":     b2i(ev.GeminiTimeout),
		"fallback_used":      b2i(ev.FallbackUsed),
		"scored_by":          ev.ScoredBy,
		"clip_id":            ev.ClipID,
		"take_id":            ev.TakeID,
		"model":              ev.Model,
		"event":              "take_scored",
	}
	e.write(rec)
}

// Rescore emits rescore_success / rescore_retry / rescore_dropped (Count) and,
// on success, rescore_delay_ms: how long the take waited in SQS before Gemini
// recovered. One record per SQS job.
func (e *Emitter) Rescore(takeID, outcome string, attempt int, ageMS int64) {
	metricsList := []metricDef{
		{Name: "rescore_success", Unit: "Count"},
		{Name: "rescore_retry", Unit: "Count"},
		{Name: "rescore_dropped", Unit: "Count"},
	}
	rec := map[string]any{
		"Service":         ServiceName,
		"rescore_success": b2i(outcome == "rescored"),
		"rescore_retry":   b2i(outcome == "retry"),
		"rescore_dropped": b2i(outcome == "dropped"),
		"take_id":         takeID,
		"outcome":         outcome,
		"attempt":         attempt,
		"event":           "take_rescored",
	}
	if outcome == "rescored" {
		metricsList = append(metricsList, metricDef{Name: "rescore_delay_ms", Unit: "Milliseconds"})
		rec["rescore_delay_ms"] = ageMS
	}
	rec["_aws"] = map[string]any{
		"Timestamp": time.Now().UnixMilli(),
		"CloudWatchMetrics": []directive{{
			Namespace: Namespace, Dimensions: [][]string{{"Service"}}, Metrics: metricsList,
		}},
	}
	e.write(rec)
}

func (e *Emitter) write(rec map[string]any) {
	b, err := json.Marshal(rec)
	if err != nil {
		return
	}
	b = append(b, '\n')
	e.mu.Lock()
	defer e.mu.Unlock()
	_, _ = e.w.Write(b)
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
