// Package api implements the HTTP contract in API.md.
package api

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/dubstudio/server/internal/catalog"
	"github.com/dubstudio/server/internal/gemini"
	"github.com/dubstudio/server/internal/media"
	"github.com/dubstudio/server/internal/metrics"
	"github.com/dubstudio/server/internal/model"
	"github.com/dubstudio/server/internal/store"
	"github.com/dubstudio/server/internal/timing"
)

// Server holds the handler dependencies.
type Server struct {
	Clips          *catalog.Catalog
	Store          store.Store
	Judge          *gemini.Judge
	Media          *media.Media // nil = S3 disabled
	Metrics        *metrics.Emitter
	PublicBaseURL  string
	MaxUploadBytes int64
	ModelName      string
}

// Handler returns the routed, middleware-wrapped handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /clips", s.listClips)
	mux.HandleFunc("POST /takes", s.createTake)
	mux.HandleFunc("POST /takes/{id}/uploaded", s.markUploaded)
	mux.HandleFunc("GET /leaderboard", s.leaderboard)
	mux.HandleFunc("GET /d/{id}", s.sharePage)
	mux.HandleFunc("POST /d/{id}/delete", s.deleteTake)
	mux.HandleFunc("GET /board", s.board)
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/board", http.StatusFound)
	})
	return logRequests(recoverPanics(mux))
}

// ---------- JSON endpoints ----------

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) listClips(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"clips": s.Clips.All()})
}

type takeMeta struct {
	ClipID      string         `json:"clip_id"`
	Nickname    string         `json:"nickname"`
	PlayerID    string         `json:"player_id"`
	VADSegments []model.Window `json:"vad_segments"`
	AudioMIME   string         `json:"audio_mime"`
	// AudioPeakDB is the loudest sample in the recording (dBFS), measured on the iPad.
	AudioPeakDB *float64 `json:"audio_peak_db,omitempty"`
}

type takeResponse struct {
	TakeID        string         `json:"take_id"`
	ClipID        string         `json:"clip_id"`
	Nickname      string         `json:"nickname"`
	Timing        int            `json:"timing"`
	Emotion       int            `json:"emotion"`
	Comedy        int            `json:"comedy"`
	Overall       int            `json:"overall"`
	Roast         string         `json:"roast"`
	EmotionReason string         `json:"emotion_reason"`
	ComedyReason  string         `json:"comedy_reason"`
	ScoredBy      string         `json:"scored_by"`
	LatencyMS     int64          `json:"latency_ms"`
	SpeechWindows []model.Window `json:"speech_windows"`
	VADSegments   []model.Window `json:"vad_segments"`
	UploadURL     string         `json:"upload_url"`
	ShareURL      string         `json:"share_url"`
}

const maxSegments = 500

func (s *Server) createTake(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	r.Body = http.MaxBytesReader(w, r.Body, s.MaxUploadBytes)
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("request larger than %d bytes", s.MaxUploadBytes))
			return
		}
		writeError(w, http.StatusBadRequest, "expected multipart/form-data with fields meta and audio: "+err.Error())
		return
	}
	defer r.MultipartForm.RemoveAll()

	var meta takeMeta
	if err := json.Unmarshal([]byte(r.FormValue("meta")), &meta); err != nil {
		writeError(w, http.StatusBadRequest, "meta must be a JSON string: "+err.Error())
		return
	}
	clip, ok := s.Clips.Get(strings.TrimSpace(meta.ClipID))
	if !ok {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown clip_id %q", meta.ClipID))
		return
	}
	if len(meta.VADSegments) > maxSegments {
		writeError(w, http.StatusBadRequest, "too many vad_segments")
		return
	}
	file, hdr, err := r.FormFile("audio")
	if err != nil {
		writeError(w, http.StatusBadRequest, "missing audio file field")
		return
	}
	audio, err := io.ReadAll(file)
	file.Close()
	if err != nil || len(audio) == 0 {
		writeError(w, http.StatusBadRequest, "empty or unreadable audio")
		return
	}
	mime := meta.AudioMIME
	if mime == "" {
		mime = hdr.Header.Get("Content-Type")
	}

	takeID := newUUID()
	nick := cleanNickname(meta.Nickname)
	vad := timing.Merge(timing.Clamp(meta.VADSegments, clip.Duration))
	timingScore := timing.Score(vad, clip.SpeechWindows, clip.Duration)

	// Debug logger: what the iPad actually sent. Look for msg="take_received".
	slog.Info("take_received",
		"take_id", takeID, "clip_id", clip.ClipID, "nickname", nick,
		"audio_bytes", len(audio), "audio_mime", mime, "upload_filename", hdr.Filename,
		"audio_sniff", sniffAudio(audio),
		"gemini_mime", gemini.GeminiAudioMIME(mime),
		"vad_raw_count", len(meta.VADSegments), "vad_raw", meta.VADSegments,
		"vad_clean", vad, "speech_windows", clip.SpeechWindows,
		"timing", timingScore, "debug_audio_key", media.DebugAudioKey(takeID))
	if s.Media.Enabled() {
		dctx, dcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
		if err := s.Media.PutDebugAudio(dctx, takeID, audio, mime); err != nil {
			slog.Warn("debug audio upload failed", "take_id", takeID, "err", err)
		}
		dcancel()
	}

	var res gemini.Result
	if why := noAudioReason(audio, meta.AudioPeakDB); why != "" {
		// Don't ask Gemini to judge silence: it will invent a performance from the beats.
		slog.Warn("no audio in take, skipping gemini", "take_id", takeID, "reason", why)
		res = gemini.NoAudioResult()
	} else {
		res = s.Judge.Judge(r.Context(), gemini.Input{
			Clip: clip, Audio: audio, MIME: mime, Timing: timingScore, VAD: vad,
		})
	}
	overall := model.Overall(timingScore, res.Emotion, res.Comedy)
	slog.Info("take_scored_detail", "take_id", takeID, "scored_by", res.ScoredBy,
		"timing", timingScore, "emotion", res.Emotion, "comedy", res.Comedy, "overall", overall,
		"roast", res.Roast, "ms", time.Since(start).Milliseconds())

	uploadURL, err := s.Media.PresignPut(r.Context(), takeID)
	if err != nil {
		slog.Error("presign put failed", "take_id", takeID, "err", err)
		uploadURL = ""
	}

	latency := time.Since(start).Milliseconds()
	take := model.Take{
		TakeID: takeID, PlayerID: meta.PlayerID, ClipID: clip.ClipID, Nickname: nick,
		Board: model.BoardAll, Timing: timingScore, Emotion: res.Emotion, Comedy: res.Comedy,
		Overall: overall, Roast: res.Roast, EmotionReason: res.EmotionReason, ComedyReason: res.ComedyReason,
		ScoredBy: res.ScoredBy, LatencyMS: latency, VADSegments: vad,
		UploadStatus: model.UploadPending, CreatedAt: time.Now().UTC().Format(time.RFC3339),
	}
	if s.Media.Enabled() {
		take.DubKey = media.DubKey(takeID)
	}
	// Don't lose the write if the iPad disconnects mid-request.
	wctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	if err := s.Store.PutTake(wctx, take); err != nil {
		slog.Error("put take failed", "take_id", takeID, "err", err)
		writeError(w, http.StatusInternalServerError, "could not save take")
		return
	}
	if meta.PlayerID != "" {
		go func(id, nick string) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := s.Store.UpsertPlayer(ctx, id, nick); err != nil {
				slog.Warn("upsert player failed", "err", err)
			}
		}(meta.PlayerID, nick)
	}

	s.Metrics.Scoring(metrics.ScoringEvent{
		LatencyMS: latency, GeminiTimeout: res.GeminiTimeout, FallbackUsed: res.FallbackUsed,
		ScoredBy: res.ScoredBy, ClipID: clip.ClipID, TakeID: takeID, Model: s.ModelName,
	})

	writeJSON(w, http.StatusOK, takeResponse{
		TakeID: takeID, ClipID: clip.ClipID, Nickname: nick,
		Timing: timingScore, Emotion: res.Emotion, Comedy: res.Comedy, Overall: overall,
		Roast: res.Roast, EmotionReason: res.EmotionReason, ComedyReason: res.ComedyReason,
		ScoredBy: res.ScoredBy, LatencyMS: latency,
		SpeechWindows: nonNil(clip.SpeechWindows), VADSegments: nonNil(vad),
		UploadURL: uploadURL, ShareURL: s.PublicBaseURL + "/d/" + takeID,
	})
}

func (s *Server) markUploaded(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		writeError(w, http.StatusNotFound, "take not found")
		return
	}
	err := s.Store.SetUploadStatus(r.Context(), id, model.UploadUploaded)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "take not found")
		return
	}
	if err != nil {
		slog.Error("mark uploaded failed", "take_id", id, "err", err)
		writeError(w, http.StatusInternalServerError, "could not update take")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) leaderboard(w http.ResponseWriter, r *http.Request) {
	clipID := strings.TrimSpace(r.URL.Query().Get("clip_id"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	takes, err := s.Store.Leaderboard(r.Context(), clipID, store.ClampLimit(limit))
	if err != nil {
		slog.Error("leaderboard failed", "err", err)
		writeError(w, http.StatusInternalServerError, "leaderboard unavailable")
		return
	}
	entries := make([]model.LeaderboardEntry, 0, len(takes))
	for _, t := range takes {
		entries = append(entries, t.Entry())
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries})
}

// ---------- helpers ----------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func nonNil(ws []model.Window) []model.Window {
	if ws == nil {
		return []model.Window{}
	}
	return ws
}

func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

var idRe = regexp.MustCompile(`^[0-9a-fA-F-]{8,64}$`)

func validID(id string) bool { return idRe.MatchString(id) }

const maxNickRunes = 20

func cleanNickname(s string) string {
	var b strings.Builder
	n := 0
	for _, r := range strings.TrimSpace(s) {
		if unicode.IsControl(r) {
			continue
		}
		if n == maxNickRunes {
			break
		}
		b.WriteRune(r)
		n++
	}
	out := strings.TrimSpace(b.String())
	if out == "" {
		return "Anonymous"
	}
	return out
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		if r.URL.Path == "/healthz" {
			return
		}
		slog.Info("http", "method", r.Method, "path", r.URL.Path, "status", sw.status, "ms", time.Since(start).Milliseconds())
	})
}

func recoverPanics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				slog.Error("panic", "path", r.URL.Path, "err", v)
				writeError(w, http.StatusInternalServerError, "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// Thresholds for treating a take as "we couldn't hear you".
const (
	minAudioPayloadBytes = 2000  // < ~0.25 s of 64 kbps AAC
	silentPeakDB         = -45.0 // loudest sample quieter than this = nobody spoke
)

// noAudioReason returns why a take has nothing for Gemini to judge, or "".
func noAudioReason(audio []byte, peakDB *float64) string {
	if n := mdatPayload(audio); n >= 0 && n < minAudioPayloadBytes {
		return fmt.Sprintf("audio payload only %d bytes", n)
	}
	if peakDB != nil && *peakDB < silentPeakDB {
		return fmt.Sprintf("silent: peak %.1f dBFS", *peakDB)
	}
	return ""
}

// mdatPayload returns the size of the audio data in an MP4/M4A file, or -1 if
// the file isn't MP4 (unknown formats are passed to Gemini as-is).
func mdatPayload(b []byte) int {
	if len(b) < 12 || string(b[4:8]) != "ftyp" {
		return -1
	}
	i := strings.Index(string(b), "mdat")
	if i < 4 {
		return 0
	}
	sz := int(b[i-4])<<24 | int(b[i-3])<<16 | int(b[i-2])<<8 | int(b[i-1])
	if sz == 0 { // size 0 = "extends to end of file"
		return len(b) - i - 4
	}
	return max(sz-8, 0)
}

// sniffAudio describes the container from its header bytes, for debug logs:
// an AAC .m4a starts with "....ftyp" and must contain an "mdat" box with data.
func sniffAudio(b []byte) string {
	if len(b) < 12 {
		return fmt.Sprintf("too short (%d bytes)", len(b))
	}
	head := fmt.Sprintf("% x", b[:12])
	desc := "unknown"
	switch {
	case string(b[4:8]) == "ftyp":
		desc = "mp4/m4a brand=" + strings.TrimSpace(string(b[8:12]))
	case string(b[0:4]) == "RIFF":
		desc = "wav"
	case string(b[0:4]) == "caff":
		desc = "caf (Gemini does not accept CAF)"
	}
	if i := strings.Index(string(b), "mdat"); i >= 4 {
		sz := int(b[i-4])<<24 | int(b[i-3])<<16 | int(b[i-2])<<8 | int(b[i-1])
		desc += fmt.Sprintf(", mdat=%d bytes", sz)
	} else if desc != "wav" {
		desc += ", NO mdat box (no audio data)"
	}
	return desc + " [" + head + "]"
}
