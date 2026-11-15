package store

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/dubstudio/server/internal/model"
)

// GSI names from API.md.
const (
	IndexByClip      = "by_clip"
	IndexGlobalBoard = "global_board"
)

// DynamoAPI is the subset of the DynamoDB client used (mockable).
type DynamoAPI interface {
	PutItem(context.Context, *dynamodb.PutItemInput, ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error)
	GetItem(context.Context, *dynamodb.GetItemInput, ...func(*dynamodb.Options)) (*dynamodb.GetItemOutput, error)
	UpdateItem(context.Context, *dynamodb.UpdateItemInput, ...func(*dynamodb.Options)) (*dynamodb.UpdateItemOutput, error)
	DeleteItem(context.Context, *dynamodb.DeleteItemInput, ...func(*dynamodb.Options)) (*dynamodb.DeleteItemOutput, error)
	Query(context.Context, *dynamodb.QueryInput, ...func(*dynamodb.Options)) (*dynamodb.QueryOutput, error)
	Scan(context.Context, *dynamodb.ScanInput, ...func(*dynamodb.Options)) (*dynamodb.ScanOutput, error)
}

// Dynamo is the DynamoDB-backed Store.
type Dynamo struct {
	db           DynamoAPI
	takesTable   string
	clipsTable   string
	playersTable string
}

// NewDynamo wires a Dynamo store.
func NewDynamo(db DynamoAPI, takesTable, clipsTable, playersTable string) *Dynamo {
	return &Dynamo{db: db, takesTable: takesTable, clipsTable: clipsTable, playersTable: playersTable}
}

func (d *Dynamo) PutTake(ctx context.Context, t model.Take) error {
	t.Board = model.BoardAll // global_board GSI partition key
	item, err := attributevalue.MarshalMap(t)
	if err != nil {
		return fmt.Errorf("marshal take: %w", err)
	}
	_, err = d.db.PutItem(ctx, &dynamodb.PutItemInput{TableName: aws.String(d.takesTable), Item: item})
	return err
}

func (d *Dynamo) GetTake(ctx context.Context, id string) (model.Take, error) {
	out, err := d.db.GetItem(ctx, &dynamodb.GetItemInput{
		TableName: aws.String(d.takesTable),
		Key:       map[string]types.AttributeValue{"take_id": &types.AttributeValueMemberS{Value: id}},
	})
	if err != nil {
		return model.Take{}, err
	}
	if len(out.Item) == 0 {
		return model.Take{}, ErrNotFound
	}
	var t model.Take
	if err := attributevalue.UnmarshalMap(out.Item, &t); err != nil {
		return model.Take{}, err
	}
	return t, nil
}

func (d *Dynamo) SetUploadStatus(ctx context.Context, id, status string) error {
	_, err := d.db.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:                 aws.String(d.takesTable),
		Key:                       map[string]types.AttributeValue{"take_id": &types.AttributeValueMemberS{Value: id}},
		UpdateExpression:          aws.String("SET upload_status = :s"),
		ConditionExpression:       aws.String("attribute_exists(take_id)"),
		ExpressionAttributeValues: map[string]types.AttributeValue{":s": &types.AttributeValueMemberS{Value: status}},
	})
	var ccf *types.ConditionalCheckFailedException
	if errors.As(err, &ccf) {
		return ErrNotFound
	}
	return err
}

// UpdateScores is a single conditional UpdateItem: the GSIs re-sort the take on
// the leaderboard automatically because `overall` is their sort key.
func (d *Dynamo) UpdateScores(ctx context.Context, id string, r Rescore) error {
	n := func(v int) types.AttributeValue { return &types.AttributeValueMemberN{Value: strconv.Itoa(v)} }
	s := func(v string) types.AttributeValue { return &types.AttributeValueMemberS{Value: v} }
	_, err := d.db.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(d.takesTable),
		Key:       map[string]types.AttributeValue{"take_id": s(id)},
		UpdateExpression: aws.String("SET emotion = :e, comedy = :c, overall = :o, roast = :r, " +
			"emotion_reason = :er, comedy_reason = :cr, scored_by = :sb, rescored_at = :at"),
		ConditionExpression: aws.String("attribute_exists(take_id) AND scored_by = :fb"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":e": n(r.Emotion), ":c": n(r.Comedy), ":o": n(r.Overall), ":r": s(r.Roast),
			":er": s(r.EmotionReason), ":cr": s(r.ComedyReason), ":sb": s(r.ScoredBy),
			":at": s(r.RescoredAt), ":fb": s(scoredByFallback),
		},
	})
	var ccf *types.ConditionalCheckFailedException
	if errors.As(err, &ccf) {
		return ErrNotFound
	}
	return err
}

func (d *Dynamo) DeleteTake(ctx context.Context, id string) error {
	_, err := d.db.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: aws.String(d.takesTable),
		Key:       map[string]types.AttributeValue{"take_id": &types.AttributeValueMemberS{Value: id}},
	})
	return err
}

// LeaderboardQuery builds the GSI query: a single descending Query with Limit, no Scan.
func (d *Dynamo) LeaderboardQuery(clipID string, limit int) *dynamodb.QueryInput {
	in := &dynamodb.QueryInput{
		TableName:        aws.String(d.takesTable),
		ScanIndexForward: aws.Bool(false), // overall descending
		Limit:            aws.Int32(int32(ClampLimit(limit))),
	}
	if clipID != "" {
		in.IndexName = aws.String(IndexByClip)
		in.KeyConditionExpression = aws.String("clip_id = :pk")
		in.ExpressionAttributeValues = map[string]types.AttributeValue{":pk": &types.AttributeValueMemberS{Value: clipID}}
	} else {
		in.IndexName = aws.String(IndexGlobalBoard)
		in.KeyConditionExpression = aws.String("board = :pk")
		in.ExpressionAttributeValues = map[string]types.AttributeValue{":pk": &types.AttributeValueMemberS{Value: model.BoardAll}}
	}
	return in
}

func (d *Dynamo) Leaderboard(ctx context.Context, clipID string, limit int) ([]model.Take, error) {
	out, err := d.db.Query(ctx, d.LeaderboardQuery(clipID, limit))
	if err != nil {
		return nil, err
	}
	takes := make([]model.Take, 0, len(out.Items))
	if err := attributevalue.UnmarshalListOfMaps(out.Items, &takes); err != nil {
		return nil, err
	}
	return takes, nil
}

func (d *Dynamo) UpsertPlayer(ctx context.Context, id, nick string) error {
	if id == "" || d.playersTable == "" {
		return nil
	}
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := d.db.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName:        aws.String(d.playersTable),
		Key:              map[string]types.AttributeValue{"player_id": &types.AttributeValueMemberS{Value: id}},
		UpdateExpression: aws.String("SET nickname = :n, last_seen = :t, created_at = if_not_exists(created_at, :t), consented_at = if_not_exists(consented_at, :t)"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":n": &types.AttributeValueMemberS{Value: nick},
			":t": &types.AttributeValueMemberS{Value: now},
		},
	})
	return err
}

// ListClips scans the (tiny, ~4–6 item) clips table. Only used to fill the
// in-memory catalog at startup / every few minutes — never on a request path.
func (d *Dynamo) ListClips(ctx context.Context) ([]model.Clip, error) {
	var clips []model.Clip
	var start map[string]types.AttributeValue
	for page := 0; page < 10; page++ {
		out, err := d.db.Scan(ctx, &dynamodb.ScanInput{TableName: aws.String(d.clipsTable), ExclusiveStartKey: start})
		if err != nil {
			return nil, err
		}
		var batch []model.Clip
		if err := attributevalue.UnmarshalListOfMaps(out.Items, &batch); err != nil {
			return nil, err
		}
		clips = append(clips, batch...)
		if len(out.LastEvaluatedKey) == 0 {
			break
		}
		start = out.LastEvaluatedKey
	}
	return clips, nil
}

// PutClip writes one clip (used by cmd/seedclips).
func PutClip(ctx context.Context, db DynamoAPI, table string, c model.Clip) error {
	item, err := attributevalue.MarshalMap(c)
	if err != nil {
		return err
	}
	_, err = db.PutItem(ctx, &dynamodb.PutItemInput{TableName: aws.String(table), Item: item})
	return err
}
