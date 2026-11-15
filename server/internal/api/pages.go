package api

import (
	"context"
	"embed"
	"errors"
	"html/template"
	"log/slog"
	"net/http"
	"time"

	"github.com/dubstudio/server/internal/model"
	"github.com/dubstudio/server/internal/store"
)

//go:embed templates/*.html
var templateFS embed.FS

var tmpl = template.Must(template.New("").Funcs(template.FuncMap{
	"inc": func(i int) int { return i + 1 },
}).ParseFS(templateFS, "templates/*.html"))

type sharePageData struct {
	Take       model.Take
	Clip       model.Clip
	HasClip    bool
	VideoURL   string
	Uploading  bool
	S3Disabled bool
}

type messagePageData struct {
	Title   string
	Heading string
	Body    string
}

func render(w http.ResponseWriter, status int, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer") // keep presigned URLs out of Referer
	w.WriteHeader(status)
	if err := tmpl.ExecuteTemplate(w, name, data); err != nil {
		slog.Error("template", "name", name, "err", err)
	}
}

func notFoundPage(w http.ResponseWriter) {
	render(w, http.StatusNotFound, "message.html", messagePageData{
		Title: "Not found", Heading: "This take has left the stage",
		Body: "It may have been deleted, or it expired after 7 days.",
	})
}

// GET /d/{id}: scorecard + freshly signed video URL (or "still uploading").
func (s *Server) sharePage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		notFoundPage(w)
		return
	}
	take, err := s.Store.GetTake(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		notFoundPage(w)
		return
	}
	if err != nil {
		slog.Error("get take", "take_id", id, "err", err)
		render(w, http.StatusInternalServerError, "message.html", messagePageData{Title: "Error", Heading: "Technical difficulties", Body: "Please try again in a moment."})
		return
	}
	clip, hasClip := s.Clips.Get(take.ClipID)
	data := sharePageData{Take: take, Clip: clip, HasClip: hasClip, S3Disabled: !s.Media.Enabled()}

	if s.Media.Enabled() {
		if take.UploadStatus != model.UploadUploaded {
			// Self-heal if the iPad uploaded but never called /takes/{id}/uploaded.
			if ok, err := s.Media.Exists(r.Context(), id); err == nil && ok {
				take.UploadStatus = model.UploadUploaded
				if err := s.Store.SetUploadStatus(r.Context(), id, model.UploadUploaded); err != nil {
					slog.Warn("self-heal upload status", "err", err)
				}
			}
		}
		if take.UploadStatus == model.UploadUploaded {
			u, err := s.Media.PresignGet(r.Context(), id)
			if err != nil {
				slog.Error("presign get", "take_id", id, "err", err)
			}
			data.VideoURL = u
		}
		data.Uploading = data.VideoURL == ""
	}
	render(w, http.StatusOK, "share.html", data)
}

// POST /d/{id}/delete: delete the S3 object and the take row.
func (s *Server) deleteTake(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !validID(id) {
		notFoundPage(w)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := s.Media.Delete(ctx, id); err != nil {
		slog.Error("delete dub", "take_id", id, "err", err)
		render(w, http.StatusInternalServerError, "message.html", messagePageData{Title: "Error", Heading: "Couldn't delete the video", Body: "Please try again. It will also expire automatically after 7 days."})
		return
	}
	if err := s.Store.DeleteTake(ctx, id); err != nil {
		slog.Error("delete take", "take_id", id, "err", err)
		render(w, http.StatusInternalServerError, "message.html", messagePageData{Title: "Error", Heading: "Couldn't delete the take", Body: "The video is gone; please try again to remove the score."})
		return
	}
	slog.Info("take deleted by owner", "take_id", id)
	render(w, http.StatusOK, "message.html", messagePageData{
		Title: "Deleted", Heading: "Your take is gone",
		Body: "The video, the recording and your score have been deleted. Thanks for playing LARPStudio.",
	})
}

type boardClip struct {
	Clip    model.Clip
	Entries []model.Take
}

type boardData struct {
	Top       []model.Take
	Clips     []boardClip
	Titles    map[string]string
	Updated   string
	Refresh   int
	TakeCount int
}

// GET /board: auto-refreshing leaderboard for a second screen.
func (s *Server) board(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	top, err := s.Store.Leaderboard(ctx, "", 10)
	if err != nil {
		slog.Error("board global", "err", err)
	}
	data := boardData{Top: top, Titles: map[string]string{}, Refresh: 5, Updated: time.Now().Format("15:04:05")}
	for _, c := range s.Clips.All() {
		data.Titles[c.ClipID] = c.Title
		entries, err := s.Store.Leaderboard(ctx, c.ClipID, 3)
		if err != nil {
			slog.Error("board clip", "clip_id", c.ClipID, "err", err)
		}
		data.Clips = append(data.Clips, boardClip{Clip: c, Entries: entries})
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	render(w, http.StatusOK, "board.html", data)
}
