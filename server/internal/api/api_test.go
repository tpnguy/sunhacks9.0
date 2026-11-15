package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	server "github.com/dubstudio/server"
	"github.com/dubstudio/server/internal/catalog"
	"github.com/dubstudio/server/internal/gemini"
	"github.com/dubstudio/server/internal/metrics"
	"github.com/dubstudio/server/internal/store"
)

func newTestServer(t *testing.T) (*httptest.Server, *bytes.Buffer) {
	t.Helper()
	cat := catalog.New(nil, "", server.FallbackClipsJSON)
	if err := cat.Load(context.Background()); err != nil {
		t.Fatal(err)
	}
	var emf bytes.Buffer
	s := &Server{
		Clips: cat, Store: store.NewMemory(nil),
		Judge:          gemini.NewJudge(&gemini.Mock{}, time.Second),
		Metrics:        metrics.New(&emf),
		PublicBaseURL:  "http://example.test",
		MaxUploadBytes: 1 << 20,
	}
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return ts, &emf
}

func postTake(t *testing.T, url, meta string, audio []byte) *http.Response {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("meta", meta)
	if audio != nil {
		fw, _ := mw.CreateFormFile("audio", "take.m4a")
		_, _ = fw.Write(audio)
	}
	mw.Close()
	resp, err := http.Post(url+"/takes", mw.FormDataContentType(), &body)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestTakeFlow(t *testing.T) {
	ts, emf := newTestServer(t)
	meta := `{"clip_id":"tos-bridge","nickname":"ban","player_id":"p1","vad_segments":[{"start":1.2,"end":3.85},{"start":6.1,"end":8.4}],"audio_mime":"audio/mp4"}`
	resp := postTake(t, ts.URL, meta, []byte("fake audio bytes"))
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		t.Fatalf("status %d: %s", resp.StatusCode, b)
	}
	var tr takeResponse
	_ = json.NewDecoder(resp.Body).Decode(&tr)
	resp.Body.Close()
	if tr.Timing != 100 || tr.ScoredBy != "mock" || tr.Roast == "" || tr.UploadURL != "" || tr.ShareURL != "http://example.test/d/"+tr.TakeID {
		t.Errorf("bad response %+v", tr)
	}
	if want := (100 + (tr.Emotion+tr.Comedy)*5 + 1) / 2; tr.Overall != want {
		t.Errorf("overall %d want %d", tr.Overall, want)
	}
	if !strings.Contains(emf.String(), `"Namespace":"DubStudio"`) {
		t.Errorf("no EMF line: %s", emf.String())
	}

	// Leaderboard
	lb, _ := http.Get(ts.URL + "/leaderboard?clip_id=tos-bridge")
	var l struct {
		Entries []map[string]any `json:"entries"`
	}
	_ = json.NewDecoder(lb.Body).Decode(&l)
	lb.Body.Close()
	if len(l.Entries) != 1 || l.Entries[0]["take_id"] != tr.TakeID {
		t.Errorf("leaderboard %+v", l)
	}

	// Uploaded + share page + board + delete
	if r, _ := http.Post(ts.URL+"/takes/"+tr.TakeID+"/uploaded", "", nil); r.StatusCode != 200 {
		t.Errorf("uploaded status %d", r.StatusCode)
	}
	sp, _ := http.Get(ts.URL + "/d/" + tr.TakeID)
	b, _ := io.ReadAll(sp.Body)
	sp.Body.Close()
	if sp.StatusCode != 200 || !strings.Contains(string(b), "Blender Foundation") || !strings.Contains(string(b), "Delete my take") {
		t.Errorf("share page %d", sp.StatusCode)
	}
	bd, _ := http.Get(ts.URL + "/board")
	b, _ = io.ReadAll(bd.Body)
	bd.Body.Close()
	if !strings.Contains(string(b), "ban") || !strings.Contains(string(b), `http-equiv="refresh"`) {
		t.Errorf("board missing entry")
	}
	if r, _ := http.Post(ts.URL+"/d/"+tr.TakeID+"/delete", "", nil); r.StatusCode != 200 {
		t.Errorf("delete status %d", r.StatusCode)
	}
	if r, _ := http.Get(ts.URL + "/d/" + tr.TakeID); r.StatusCode != 404 {
		t.Errorf("after delete status %d", r.StatusCode)
	}
}

func TestTakeValidation(t *testing.T) {
	ts, _ := newTestServer(t)
	cases := []struct {
		name, meta string
		audio      []byte
		want       int
	}{
		{"unknown clip", `{"clip_id":"nope"}`, []byte("a"), 400},
		{"bad meta", `{not json`, []byte("a"), 400},
		{"no audio", `{"clip_id":"tos-bridge"}`, nil, 400},
		{"too big", `{"clip_id":"tos-bridge"}`, bytes.Repeat([]byte("x"), 2<<20), 413},
	}
	for _, c := range cases {
		r := postTake(t, ts.URL, c.meta, c.audio)
		r.Body.Close()
		if r.StatusCode != c.want {
			t.Errorf("%s: status %d want %d", c.name, r.StatusCode, c.want)
		}
	}
	if r, _ := http.Post(ts.URL+"/takes/00000000-0000-4000-8000-000000000000/uploaded", "", nil); r.StatusCode != 404 {
		t.Errorf("uploaded unknown: %d", r.StatusCode)
	}
}

func TestCleanNickname(t *testing.T) {
	if got := cleanNickname("  \x00 "); got != "Anonymous" {
		t.Errorf("got %q", got)
	}
	if got := cleanNickname("abcdefghijklmnopqrstuvwxyz"); len([]rune(got)) != 20 {
		t.Errorf("got %q", got)
	}
}
