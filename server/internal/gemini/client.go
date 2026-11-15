package gemini

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"google.golang.org/genai"
)

// Temperatures: the scorer is deterministic, the roaster is creative.
const (
	ScoreTemperature = 0.0
	RoastTemperature = 1.1
)

// scoreSchema is the JSON schema for the scoring call's structured output.
var scoreSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"emotion":        map[string]any{"type": "integer", "minimum": 0, "maximum": 10, "description": "Emotion score 0-10, anchored to the 3/6/9 rubric."},
		"comedy":         map[string]any{"type": "integer", "minimum": 0, "maximum": 10, "description": "Comedy score 0-10, anchored to the 3/6/9 rubric."},
		"emotion_reason": map[string]any{"type": "string", "description": "One short sentence about the delivery vs. the beats."},
		"comedy_reason":  map[string]any{"type": "string", "description": "One short sentence about what was (not) funny."},
	},
	"required":             []string{"emotion", "comedy", "emotion_reason", "comedy_reason"},
	"propertyOrdering":     []string{"emotion_reason", "emotion", "comedy_reason", "comedy"},
	"additionalProperties": false,
}

// roastSchema is the JSON schema for the roast call.
var roastSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"roast": map[string]any{"type": "string", "description": "One-line talent-show-judge verdict on the performance, max ~25 words."},
	},
	"required":             []string{"roast"},
	"additionalProperties": false,
}

// Client is the real Gemini backend (google.golang.org/genai, Gemini Developer API).
type Client struct {
	c             *genai.Client
	model         string
	fallbackModel string // used for retries; "" = retry the same model
	scorerPrompt  string
	roasterPrompt string
	thinking      genai.ThinkingLevel
}

// NewClient creates a Gemini backend. thinkingLevel "" leaves the model default.
func NewClient(ctx context.Context, apiKey, model, fallbackModel, scorerPrompt, roasterPrompt, thinkingLevel string) (*Client, error) {
	c, err := genai.NewClient(ctx, &genai.ClientConfig{APIKey: apiKey, Backend: genai.BackendGeminiAPI})
	if err != nil {
		return nil, err
	}
	return &Client{
		c: c, model: model, fallbackModel: fallbackModel, scorerPrompt: scorerPrompt, roasterPrompt: roasterPrompt,
		thinking: genai.ThinkingLevel(strings.ToUpper(strings.TrimSpace(thinkingLevel))),
	}, nil
}

func (g *Client) Name() string { return ScoredByGemini }

func (g *Client) Score(ctx context.Context, in Input) (Scores, error) {
	text, err := g.generate(ctx, g.scorerPrompt, ScoreTemperature, scoreSchema, in, BuildContext(in, false))
	if err != nil {
		return Scores{}, err
	}
	var s Scores
	if err := json.Unmarshal([]byte(text), &s); err != nil {
		return Scores{}, fmt.Errorf("score schema: %w (raw %.200q)", err, text)
	}
	return s, nil
}

func (g *Client) Roast(ctx context.Context, in Input) (string, error) {
	text, err := g.generate(ctx, g.roasterPrompt, RoastTemperature, roastSchema, in, BuildContext(in, true))
	if err != nil {
		return "", err
	}
	var r struct {
		Roast string `json:"roast"`
	}
	if err := json.Unmarshal([]byte(text), &r); err != nil {
		return "", fmt.Errorf("roast schema: %w (raw %.200q)", err, text)
	}
	return r.Roast, nil
}

func (g *Client) generate(ctx context.Context, system string, temp float32, schema any, in Input, contextText string) (string, error) {
	cfg := &genai.GenerateContentConfig{
		SystemInstruction:     genai.NewContentFromText(system, genai.RoleUser),
		Temperature:           genai.Ptr(temp),
		ResponseMIMEType:      "application/json",
		ResponseJsonSchema:    schema,
		CandidateCount:        1,
		AutomaticContinuation: genai.Ptr(false), // stay inside our timeout budget
	}
	if temp == 0 {
		cfg.Seed = genai.Ptr[int32](42) // extra determinism for the scorer
	}
	model := g.model
	if AttemptFrom(ctx) > 0 && g.fallbackModel != "" {
		model = g.fallbackModel
	}
	// Thinking level is tuned for the primary model; let the fallback use its own default.
	if g.thinking != "" && model == g.model {
		cfg.ThinkingConfig = &genai.ThinkingConfig{ThinkingLevel: g.thinking}
	}
	contents := []*genai.Content{genai.NewContentFromParts([]*genai.Part{
		genai.NewPartFromText(contextText),
		genai.NewPartFromBytes(in.Audio, GeminiAudioMIME(in.MIME)),
	}, genai.RoleUser)}

	start := time.Now()
	resp, err := g.c.Models.GenerateContent(ctx, model, contents, cfg)
	if err != nil {
		return "", fmt.Errorf("%s: %w", model, err)
	}
	slog.Info("gemini call ok", "model", model, "attempt", AttemptFrom(ctx)+1, "ms", time.Since(start).Milliseconds())
	text := strings.TrimSpace(resp.Text())
	if text == "" {
		reason := ""
		if len(resp.Candidates) > 0 {
			reason = string(resp.Candidates[0].FinishReason)
		}
		if resp.PromptFeedback != nil {
			reason += " block=" + string(resp.PromptFeedback.BlockReason)
		}
		return "", fmt.Errorf("empty response (%s)", reason)
	}
	return text, nil
}

// GeminiAudioMIME maps the iPad's audio_mime to a type from Gemini's supported
// list (https://aistudio.google.com/docs/audio): AAC-in-MP4 (.m4a) → audio/m4a.
func GeminiAudioMIME(m string) string {
	m = strings.ToLower(strings.TrimSpace(m))
	if i := strings.IndexByte(m, ';'); i >= 0 {
		m = strings.TrimSpace(m[:i])
	}
	switch m {
	case "", "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/mp4a-latm", "video/mp4":
		return "audio/m4a"
	case "audio/x-wav", "audio/wave":
		return "audio/wav"
	}
	return m
}
