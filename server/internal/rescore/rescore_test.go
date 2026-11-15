package rescore

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"

	"github.com/dubstudio/server/internal/gemini"
	"github.com/dubstudio/server/internal/model"
	"github.com/dubstudio/server/internal/store"
)

type fakeSQS struct {
	sent    []string
	deleted []string
}

func (f *fakeSQS) SendMessage(_ context.Context, in *sqs.SendMessageInput, _ ...func(*sqs.Options)) (*sqs.SendMessageOutput, error) {
	f.sent = append(f.sent, aws.ToString(in.MessageBody))
	return &sqs.SendMessageOutput{}, nil
}
func (f *fakeSQS) ReceiveMessage(context.Context, *sqs.ReceiveMessageInput, ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error) {
	return &sqs.ReceiveMessageOutput{}, nil
}
func (f *fakeSQS) DeleteMessage(_ context.Context, in *sqs.DeleteMessageInput, _ ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error) {
	f.deleted = append(f.deleted, aws.ToString(in.ReceiptHandle))
	return &sqs.DeleteMessageOutput{}, nil
}

type fakeAudio struct{ err error }

func (a fakeAudio) GetDebugAudio(context.Context, string) ([]byte, error) {
	return []byte("audio"), a.err
}

type fakeClips struct{}

func (fakeClips) Get(id string) (model.Clip, bool) {
	return model.Clip{ClipID: id, Duration: 10}, id == "c1"
}

type fakeJudge struct{ res gemini.Result }

func (j fakeJudge) Judge(context.Context, gemini.Input) gemini.Result { return j.res }

var good = gemini.Result{Emotion: 8, Comedy: 6, Roast: "Bravo.", ScoredBy: gemini.ScoredByGemini}
var bad = gemini.Result{Emotion: 5, Comedy: 5, Roast: "coffee", ScoredBy: gemini.ScoredByFallback, FallbackUsed: true}

func setup(t *testing.T, j gemini.Result) (*Worker, *store.Memory, *fakeSQS) {
	t.Helper()
	st := store.NewMemory(nil)
	_ = st.PutTake(context.Background(), model.Take{
		TakeID: "t1", ClipID: "c1", Timing: 80, Emotion: 5, Comedy: 5, Overall: 65, ScoredBy: gemini.ScoredByFallback,
	})
	q := &fakeSQS{}
	return &Worker{Client: q, URL: "q", Store: st, Clips: fakeClips{}, Audio: fakeAudio{}, Judge: fakeJudge{j}}, st, q
}

func msg(takeID string) types.Message {
	b, _ := json.Marshal(Job{TakeID: takeID, MIME: "audio/mp4"})
	return types.Message{Body: aws.String(string(b)), ReceiptHandle: aws.String("rh-" + takeID),
		Attributes: map[string]string{"ApproximateReceiveCount": "1"}}
}

func TestRescoreUpdatesTakeAndDeletesMessage(t *testing.T) {
	w, st, q := setup(t, good)
	var outcome string
	w.OnEvent = func(_, o string, _ int, _ int64) { outcome = o }
	w.handle(context.Background(), msg("t1"))

	got, _ := st.GetTake(context.Background(), "t1")
	if got.ScoredBy != gemini.ScoredByGemini || got.Emotion != 8 || got.Comedy != 6 || got.Roast != "Bravo." {
		t.Fatalf("take not re-scored: %+v", got)
	}
	if want := model.Overall(80, 8, 6); got.Overall != want || got.RescoredAt == "" {
		t.Fatalf("overall=%d want %d, rescored_at=%q", got.Overall, want, got.RescoredAt)
	}
	if outcome != OutcomeRescored || len(q.deleted) != 1 {
		t.Fatalf("outcome=%s deleted=%v", outcome, q.deleted)
	}
}

func TestGeminiStillDownLeavesMessageForRetry(t *testing.T) {
	w, st, q := setup(t, bad)
	w.handle(context.Background(), msg("t1"))
	if len(q.deleted) != 0 {
		t.Fatal("message deleted although Gemini still failing; SQS must redeliver it")
	}
	if got, _ := st.GetTake(context.Background(), "t1"); got.ScoredBy != gemini.ScoredByFallback {
		t.Fatalf("take changed on failed re-score: %+v", got)
	}
}

func TestDeletedOrAlreadyScoredTakeIsDropped(t *testing.T) {
	w, st, q := setup(t, good)
	w.handle(context.Background(), msg("missing")) // delete-my-take happened
	w.handle(context.Background(), msg("t1"))      // re-scores
	w.handle(context.Background(), msg("t1"))      // duplicate delivery (SQS is at-least-once)
	if len(q.deleted) != 3 {
		t.Fatalf("want all 3 messages deleted, got %v", q.deleted)
	}
	if got, _ := st.GetTake(context.Background(), "t1"); got.Emotion != 8 {
		t.Fatalf("unexpected take %+v", got)
	}
}

func TestMissingAudioIsDropped(t *testing.T) {
	w, _, q := setup(t, good)
	w.Audio = fakeAudio{err: ErrNoAudio}
	w.handle(context.Background(), msg("t1"))
	if len(q.deleted) != 1 {
		t.Fatal("expired audio should drop the job, not retry forever")
	}
}

func TestEnqueueAndNilQueue(t *testing.T) {
	var off *Queue
	if off.Enabled() || off.Enqueue(context.Background(), "x", "y") != nil {
		t.Fatal("nil queue must be a no-op")
	}
	f := &fakeSQS{}
	q := NewQueue(f, "url")
	if err := q.Enqueue(context.Background(), "t1", "audio/mp4"); err != nil || len(f.sent) != 1 {
		t.Fatalf("enqueue: err=%v sent=%v", err, f.sent)
	}
	var j Job
	_ = json.Unmarshal([]byte(f.sent[0]), &j)
	if j.TakeID != "t1" || j.MIME != "audio/mp4" || j.EnqueuedAt == "" {
		t.Fatalf("bad job %+v", j)
	}
}
