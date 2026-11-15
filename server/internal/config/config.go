// Package config reads server settings from the environment (and an optional .env file).
package config

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"time"
)

// DefaultGeminiModel is the current stable Gemini Flash model
// (https://aistudio.google.com/docs/models, checked 2026-11-14).
const DefaultGeminiModel = "gemini-4-hydrogen"

// DefaultGeminiFallbackModel is used for the retry when the primary model errors or times out.
// Picked by benchmarking real takes on 2026-11-15: it answered in ~7 s while newer models 504'd.
const DefaultGeminiFallbackModel = "gemini-3.5-flash"

// Config holds every setting from API.md plus a few optional tunables.
type Config struct {
	Port                string
	GeminiAPIKey        string
	GeminiModel         string
	GeminiFallbackModel string
	AWSRegion           string
	TakesTable          string
	ClipsTable          string
	PlayersTable        string
	MediaBucket         string
	PublicBaseURL       string
	Store               string // "dynamo" or "memory"
	ClipsFile           string
	RescoreQueueURL     string // SQS queue for async re-scoring of fallback takes; empty = off

	GeminiTimeout  time.Duration // per attempt
	MaxUploadBytes int64
}

// Load reads the env (after loading .env if present).
func Load() Config {
	envFile := getenv("ENV_FILE", ".env")
	_ = LoadDotEnv(envFile)

	c := Config{
		Port:                getenv("PORT", "8080"),
		GeminiAPIKey:        strings.TrimSpace(os.Getenv("GEMINI_API_KEY")),
		GeminiModel:         getenv("GEMINI_MODEL", DefaultGeminiModel),
		GeminiFallbackModel: getenv("GEMINI_FALLBACK_MODEL", DefaultGeminiFallbackModel),
		AWSRegion:           getenv("AWS_REGION", "us-west-2"),
		TakesTable:          getenv("TAKES_TABLE", "dubstudio-takes"),
		ClipsTable:          getenv("CLIPS_TABLE", "dubstudio-clips"),
		PlayersTable:        getenv("PLAYERS_TABLE", "dubstudio-players"),
		MediaBucket:         strings.TrimSpace(os.Getenv("MEDIA_BUCKET")),
		PublicBaseURL:       strings.TrimRight(getenv("PUBLIC_BASE_URL", "http://localhost:8080"), "/"),
		Store:               strings.ToLower(getenv("STORE", "dynamo")),
		ClipsFile:           getenv("CLIPS_FILE", "../clips/clips.json"),
		RescoreQueueURL:     strings.TrimSpace(os.Getenv("RESCORE_QUEUE_URL")),
		GeminiTimeout:       15 * time.Second,
		MaxUploadBytes:      5 << 20,
	}
	if v, err := strconv.Atoi(os.Getenv("GEMINI_TIMEOUT_SECONDS")); err == nil && v > 0 {
		c.GeminiTimeout = time.Duration(v) * time.Second
	}
	if v, err := strconv.ParseInt(os.Getenv("MAX_UPLOAD_BYTES"), 10, 64); err == nil && v > 0 {
		c.MaxUploadBytes = v
	}
	return c
}

// MockGemini reports whether Gemini calls are faked (no API key).
func (c Config) MockGemini() bool { return c.GeminiAPIKey == "" }

func getenv(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

// LoadDotEnv sets KEY=VALUE pairs from path into the environment. Existing env
// vars win (so systemd/SSM-provided values are never overridden). Supports
// comments (#), blank lines, optional "export " prefix and single/double quotes.
func LoadDotEnv(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' && v[len(v)-1] == '"' || v[0] == '\'' && v[len(v)-1] == '\'') {
			v = v[1 : len(v)-1]
		} else if i := strings.Index(v, " #"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		if _, exists := os.LookupEnv(k); !exists && k != "" {
			os.Setenv(k, v)
		}
	}
	return sc.Err()
}
