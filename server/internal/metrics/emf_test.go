package metrics

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestScoringEMF(t *testing.T) {
	var buf bytes.Buffer
	New(&buf).Scoring(ScoringEvent{LatencyMS: 3120, GeminiTimeout: true, FallbackUsed: true, ScoredBy: "fallback", ClipID: "c", TakeID: "t"})
	var rec map[string]any
	if err := json.Unmarshal(buf.Bytes(), &rec); err != nil {
		t.Fatalf("not JSON: %v: %s", err, buf.String())
	}
	aws := rec["_aws"].(map[string]any)
	cw := aws["CloudWatchMetrics"].([]any)[0].(map[string]any)
	if cw["Namespace"] != "DubStudio" {
		t.Errorf("namespace = %v", cw["Namespace"])
	}
	if len(cw["Metrics"].([]any)) != 3 {
		t.Errorf("want 3 metrics")
	}
	if rec["scoring_latency_ms"].(float64) != 3120 || rec["gemini_timeout"].(float64) != 1 || rec["fallback_used"].(float64) != 1 {
		t.Errorf("bad values: %v", rec)
	}
	if rec["Service"] != ServiceName {
		t.Errorf("dimension value missing")
	}
}
