// Package model holds the shared data types from API.md.
package model

// Window is a time span in seconds from clip start (speech window or VAD segment).
type Window struct {
	Start float64 `json:"start" dynamodbav:"start"`
	End   float64 `json:"end" dynamodbav:"end"`
}

// Beat is a hand-corrected semantic moment in a clip.
type Beat struct {
	T       float64 `json:"t" dynamodbav:"t"`
	Desc    string  `json:"desc" dynamodbav:"desc"`
	Emotion string  `json:"emotion" dynamodbav:"emotion"`
}

// Clip matches clips/clips.json and the dubstudio-clips table.
type Clip struct {
	ClipID        string   `json:"clip_id" dynamodbav:"clip_id"`
	Title         string   `json:"title" dynamodbav:"title"`
	VideoFile     string   `json:"video_file" dynamodbav:"video_file"`
	Duration      float64  `json:"duration" dynamodbav:"duration"`
	SpeechWindows []Window `json:"speech_windows" dynamodbav:"speech_windows"`
	Beats         []Beat   `json:"beats" dynamodbav:"beats"`
	License       string   `json:"license" dynamodbav:"license"`
	Attribution   string   `json:"attribution" dynamodbav:"attribution"`
}

// Upload states for a take's dub video.
const (
	UploadPending  = "pending"
	UploadUploaded = "uploaded"
)

// BoardAll is the constant partition key of the global_board GSI.
const BoardAll = "ALL"

// Take is one scored performance; it is the dubstudio-takes item.
type Take struct {
	TakeID        string   `json:"take_id" dynamodbav:"take_id"`
	PlayerID      string   `json:"player_id,omitempty" dynamodbav:"player_id,omitempty"`
	ClipID        string   `json:"clip_id" dynamodbav:"clip_id"`
	Nickname      string   `json:"nickname" dynamodbav:"nickname"`
	Board         string   `json:"-" dynamodbav:"board"`
	Timing        int      `json:"timing" dynamodbav:"timing"`
	Emotion       int      `json:"emotion" dynamodbav:"emotion"`
	Comedy        int      `json:"comedy" dynamodbav:"comedy"`
	Overall       int      `json:"overall" dynamodbav:"overall"`
	Roast         string   `json:"roast" dynamodbav:"roast"`
	EmotionReason string   `json:"emotion_reason" dynamodbav:"emotion_reason"`
	ComedyReason  string   `json:"comedy_reason" dynamodbav:"comedy_reason"`
	ScoredBy      string   `json:"scored_by" dynamodbav:"scored_by"`
	LatencyMS     int64    `json:"latency_ms" dynamodbav:"latency_ms"`
	VADSegments   []Window `json:"vad_segments" dynamodbav:"vad_segments"`
	DubKey        string   `json:"dub_key,omitempty" dynamodbav:"dub_key,omitempty"`
	UploadStatus  string   `json:"upload_status" dynamodbav:"upload_status"`
	CreatedAt     string   `json:"created_at" dynamodbav:"created_at"` // RFC3339 UTC
}

// LeaderboardEntry is one row of GET /leaderboard.
type LeaderboardEntry struct {
	TakeID    string `json:"take_id"`
	Nickname  string `json:"nickname"`
	ClipID    string `json:"clip_id"`
	Overall   int    `json:"overall"`
	Timing    int    `json:"timing"`
	Emotion   int    `json:"emotion"`
	Comedy    int    `json:"comedy"`
	CreatedAt string `json:"created_at"`
}

// Entry converts a take into a leaderboard row.
func (t Take) Entry() LeaderboardEntry {
	return LeaderboardEntry{
		TakeID: t.TakeID, Nickname: t.Nickname, ClipID: t.ClipID,
		Overall: t.Overall, Timing: t.Timing, Emotion: t.Emotion, Comedy: t.Comedy,
		CreatedAt: t.CreatedAt,
	}
}

// Overall implements API.md: round(0.5×timing + 0.5×((emotion+comedy)/2×10)), clamped to 0..100.
func Overall(timing, emotion, comedy int) int {
	v := 0.5*float64(timing) + 0.5*(float64(emotion+comedy)/2*10)
	o := int(v + 0.5)
	if o < 0 {
		return 0
	}
	if o > 100 {
		return 100
	}
	return o
}
