// Package rescore re-scores fallback takes asynchronously through SQS.
//
// When Gemini fails during POST /takes, the player still gets a scorecard right
// away (real timing score + "judges on a coffee break"). The take ID is put on
// an SQS queue; a worker long-polls the queue, re-runs the Gemini judges on the
// raw take audio kept in S3, and updates the take in DynamoDB, so the
// leaderboard and share page pick up the real scores.
//
// Failure handling is SQS's job, not ours: a message that can't be scored yet
// is simply not deleted, so it reappears after the queue's visibility timeout
// (natural backoff during an outage). After maxReceiveCount attempts the queue's
// redrive policy moves it to a dead-letter queue. A restart loses nothing.
package rescore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"

	"github.com/dubstudio/server/internal/gemini"
	"github.com/dubstudio/server/internal/media"
	"github.com/dubstudio/server/internal/model"
	"github.com/dubstudio/server/internal/store"
)

// SQSAPI is the subset of the SQS client used (mockable).
type SQSAPI interface {
	SendMessage(context.Context, *sqs.SendMessageInput, ...func(*sqs.Options)) (*sqs.SendMessageOutput, error)
	ReceiveMessage(context.Context, *sqs.ReceiveMessageInput, ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	DeleteMessage(context.Context, *sqs.DeleteMessageInput, ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
}

// Job is the message body. Audio is not in the message (SQS max is 256 KB);
// the worker reads it from S3.
type Job struct {
	TakeID     string `json:"take_id"`
	MIME       string `json:"mime"`
	EnqueuedAt string `json:"enqueued_at"`
}

// Queue sends jobs. A nil *Queue means re-scoring is disabled; Enqueue is nil-safe.
type Queue struct {
	client SQSAPI
	url    string
}

// NewQueue returns nil when url is empty (feature off).
func NewQueue(client SQSAPI, url string) *Queue {
	if url == "" || client == nil {
		return nil
	}
	return &Queue{client: client, url: url}
}

// Enabled reports whether re-scoring is on.
func (q *Queue) Enabled() bool { return q != nil }

// Enqueue puts a take on the re-score queue.
func (q *Queue) Enqueue(ctx context.Context, takeID, mime string) error {
	if q == nil {
		return nil
	}
	body, _ := json.Marshal(Job{TakeID: takeID, MIME: mime, EnqueuedAt: time.Now().UTC().Format(time.RFC3339)})
	_, err := q.client.SendMessage(ctx, &sqs.SendMessageInput{QueueUrl: aws.String(q.url), MessageBody: aws.String(string(body))})
	return err
}

// AudioSource fetches a take's raw audio (S3 in production).
type AudioSource interface {
	GetDebugAudio(ctx context.Context, takeID string) ([]byte, error)
}

// ClipSource looks up a clip by ID (the in-memory catalog).
type ClipSource interface {
	Get(clipID string) (model.Clip, bool)
}

// Judge is what the worker needs from gemini.Judge.
type Judge interface {
	Judge(ctx context.Context, in gemini.Input) gemini.Result
}

// Outcome of one job, reported to the metrics hook.
const (
	OutcomeRescored = "rescored" // Gemini answered; take updated
	OutcomeRetry    = "retry"    // Gemini still failing; message left for redelivery
	OutcomeDropped  = "dropped"  // nothing to do (take deleted, already scored, audio gone)
)

// ErrNoAudio is returned by an AudioSource when the take's audio no longer exists.
var ErrNoAudio = media.ErrNoAudio

// Worker consumes the re-score queue.
type Worker struct {
	Client  SQSAPI
	URL     string
	Store   store.Store
	Clips   ClipSource
	Audio   AudioSource
	Judge   Judge
	OnEvent func(takeID, outcome string, receiveCount int, ageMS int64) // optional (metrics)

	// WaitSeconds is the SQS long-poll wait (default 20, the maximum).
	WaitSeconds int32
}

// Run long-polls until ctx is cancelled. One message at a time on purpose: it
// caps the extra Gemini load from re-scores at one call pair, so a backlog
// after an outage can't starve live players of Gemini quota.
func (w *Worker) Run(ctx context.Context) {
	wait := w.WaitSeconds
	if wait == 0 {
		wait = 20
	}
	slog.Info("rescore worker started", "queue", w.URL)
	for ctx.Err() == nil {
		out, err := w.Client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:                    aws.String(w.URL),
			MaxNumberOfMessages:         1,
			WaitTimeSeconds:             wait,
			MessageSystemAttributeNames: []types.MessageSystemAttributeName{types.MessageSystemAttributeNameApproximateReceiveCount},
		})
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			slog.Warn("rescore receive failed", "err", err)
			sleep(ctx, 5*time.Second)
			continue
		}
		for _, m := range out.Messages {
			w.handle(ctx, m)
		}
	}
	slog.Info("rescore worker stopped")
}

func (w *Worker) handle(ctx context.Context, m types.Message) {
	var job Job
	if err := json.Unmarshal([]byte(aws.ToString(m.Body)), &job); err != nil || job.TakeID == "" {
		slog.Warn("rescore: bad message, dropping", "body", aws.ToString(m.Body), "err", err)
		w.delete(ctx, m)
		return
	}
	receives, _ := strconv.Atoi(m.Attributes[string(types.MessageSystemAttributeNameApproximateReceiveCount)])
	var ageMS int64
	if t, err := time.Parse(time.RFC3339, job.EnqueuedAt); err == nil {
		ageMS = time.Since(t).Milliseconds()
	}

	outcome, err := w.Process(ctx, job)
	if err != nil {
		slog.Warn("rescore failed", "take_id", job.TakeID, "attempt", receives, "err", err)
	} else {
		slog.Info("rescore", "take_id", job.TakeID, "outcome", outcome, "attempt", receives, "age_ms", ageMS)
	}
	if outcome != OutcomeRetry {
		w.delete(ctx, m)
	}
	if w.OnEvent != nil {
		w.OnEvent(job.TakeID, outcome, receives, ageMS)
	}
}

// Process re-scores one take. It returns OutcomeRetry (with the reason) when
// the message should be redelivered later.
func (w *Worker) Process(ctx context.Context, job Job) (string, error) {
	take, err := w.Store.GetTake(ctx, job.TakeID)
	if errors.Is(err, store.ErrNotFound) {
		return OutcomeDropped, nil // player used delete-my-take
	}
	if err != nil {
		return OutcomeRetry, fmt.Errorf("get take: %w", err)
	}
	if take.ScoredBy != gemini.ScoredByFallback {
		return OutcomeDropped, nil // already re-scored (SQS is at-least-once)
	}
	clip, ok := w.Clips.Get(take.ClipID)
	if !ok {
		return OutcomeDropped, fmt.Errorf("clip %q no longer in catalog", take.ClipID)
	}
	audio, err := w.Audio.GetDebugAudio(ctx, job.TakeID)
	if errors.Is(err, ErrNoAudio) {
		return OutcomeDropped, err
	}
	if err != nil {
		return OutcomeRetry, fmt.Errorf("get audio: %w", err)
	}

	res := w.Judge.Judge(ctx, gemini.Input{
		Clip: clip, Audio: audio, MIME: job.MIME, Timing: take.Timing, VAD: take.VADSegments,
	})
	if res.ScoredBy == gemini.ScoredByFallback {
		return OutcomeRetry, errors.New("gemini still failing")
	}

	err = w.Store.UpdateScores(ctx, job.TakeID, store.Rescore{
		Emotion: res.Emotion, Comedy: res.Comedy,
		Overall:       model.Overall(take.Timing, res.Emotion, res.Comedy),
		Roast:         res.Roast,
		EmotionReason: res.EmotionReason, ComedyReason: res.ComedyReason,
		ScoredBy:   res.ScoredBy,
		RescoredAt: time.Now().UTC().Format(time.RFC3339),
	})
	if errors.Is(err, store.ErrNotFound) {
		return OutcomeDropped, nil // deleted or re-scored while Gemini was thinking
	}
	if err != nil {
		return OutcomeRetry, fmt.Errorf("update take: %w", err)
	}
	return OutcomeRescored, nil
}

func (w *Worker) delete(ctx context.Context, m types.Message) {
	dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if _, err := w.Client.DeleteMessage(dctx, &sqs.DeleteMessageInput{QueueUrl: aws.String(w.URL), ReceiptHandle: m.ReceiptHandle}); err != nil {
		slog.Warn("rescore delete message failed", "err", err)
	}
}

func sleep(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
