// Command server runs the DubStudio API.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/s3"

	server "github.com/dubstudio/server"
	"github.com/dubstudio/server/internal/api"
	"github.com/dubstudio/server/internal/catalog"
	"github.com/dubstudio/server/internal/config"
	"github.com/dubstudio/server/internal/gemini"
	"github.com/dubstudio/server/internal/media"
	"github.com/dubstudio/server/internal/metrics"
	"github.com/dubstudio/server/internal/store"
)

func main() {
	// Plain logs → stderr; stdout is reserved for CloudWatch EMF lines.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})))

	cfg := config.Load()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	needAWS := cfg.Store != "memory" || cfg.MediaBucket != ""
	var (
		st  store.Store
		src catalog.Source
		med *media.Media
	)
	if needAWS {
		awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(cfg.AWSRegion))
		if err != nil {
			slog.Error("aws config", "err", err)
			os.Exit(1)
		}
		if cfg.Store != "memory" {
			d := store.NewDynamo(dynamodb.NewFromConfig(awsCfg), cfg.TakesTable, cfg.ClipsTable, cfg.PlayersTable)
			st, src = d, d
		}
		if cfg.MediaBucket != "" {
			med = media.New(s3.NewFromConfig(awsCfg), cfg.MediaBucket)
		}
	}
	if st == nil {
		st = store.NewMemory(nil)
	}

	cat := catalog.New(src, cfg.ClipsFile, server.FallbackClipsJSON)
	lctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	if err := cat.Load(lctx); err != nil {
		cancel()
		slog.Error("no clips", "err", err)
		os.Exit(1)
	}
	cancel()
	go cat.Refresh(ctx, 5*time.Minute)

	var backend gemini.Backend
	if cfg.MockGemini() {
		slog.Warn("GEMINI_API_KEY empty: running in MOCK mode (fake scores, canned roasts)")
		backend = gemini.NewMock()
	} else {
		thinking, set := os.LookupEnv("GEMINI_THINKING_LEVEL")
		if !set {
			thinking = "low" // latency matters more than deep reasoning for a 15 s take
		}
		c, err := gemini.NewClient(ctx, cfg.GeminiAPIKey, cfg.GeminiModel, cfg.GeminiFallbackModel, server.ScorerPrompt, server.RoasterPrompt, thinking)
		if err != nil {
			slog.Error("gemini client", "err", err)
			os.Exit(1)
		}
		backend = c
	}

	srv := &api.Server{
		Clips: cat, Store: st, Media: med, Metrics: metrics.Default,
		Judge:          gemini.NewJudge(backend, cfg.GeminiTimeout),
		PublicBaseURL:  cfg.PublicBaseURL,
		MaxUploadBytes: cfg.MaxUploadBytes,
		ModelName:      cfg.GeminiModel,
	}
	httpSrv := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second, // scoring can take ~2×timeout
		IdleTimeout:       120 * time.Second,
	}

	slog.Info("dubstudio server starting",
		"port", cfg.Port, "store", map[bool]string{true: "memory", false: "dynamo"}[cfg.Store == "memory"],
		"gemini", backend.Name(), "model", cfg.GeminiModel, "fallback_model", cfg.GeminiFallbackModel, "s3", med.Enabled(),
		"clips", len(cat.All()), "clips_source", cat.Origin(), "public_base_url", cfg.PublicBaseURL)

	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(sctx)
	}()
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("listen", "err", err)
		os.Exit(1)
	}
	slog.Info("server stopped")
}
