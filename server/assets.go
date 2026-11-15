// Package server holds files embedded into the binary: Gemini prompts and a
// fallback clip catalog, so the server runs even if ../clips/clips.json is missing.
package server

import _ "embed"

// ScorerPrompt is the system prompt for the temperature-0 scoring call.
//
//go:embed prompts/scorer_system.txt
var ScorerPrompt string

// RoasterPrompt is the system prompt for the higher-temperature roast call.
//
//go:embed prompts/roaster_system.txt
var RoasterPrompt string

// FallbackClipsJSON is used when neither DynamoDB nor CLIPS_FILE provide clips.
//
//go:embed testdata/clips.json
var FallbackClipsJSON []byte
