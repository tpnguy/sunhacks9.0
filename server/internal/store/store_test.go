package store

import (
	"context"
	"fmt"
	"testing"

	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"

	"github.com/dubstudio/server/internal/model"
)

func TestMemoryLeaderboard(t *testing.T) {
	ctx := context.Background()
	m := NewMemory(nil)
	for i, o := range []int{50, 90, 70, 10} {
		clip := "a"
		if i%2 == 1 {
			clip = "b"
		}
		_ = m.PutTake(ctx, model.Take{TakeID: fmt.Sprint(i), ClipID: clip, Overall: o})
	}
	all, _ := m.Leaderboard(ctx, "", 3)
	if len(all) != 3 || all[0].Overall != 90 || all[1].Overall != 70 || all[2].Overall != 50 {
		t.Errorf("global = %+v", all)
	}
	a, _ := m.Leaderboard(ctx, "a", 10)
	if len(a) != 2 || a[0].Overall != 70 {
		t.Errorf("clip a = %+v", a)
	}
	if err := m.SetUploadStatus(ctx, "nope", model.UploadUploaded); err != ErrNotFound {
		t.Errorf("want ErrNotFound, got %v", err)
	}
	_ = m.DeleteTake(ctx, "1")
	if _, err := m.GetTake(ctx, "1"); err != ErrNotFound {
		t.Errorf("deleted take still there")
	}
}

func TestDynamoLeaderboardQueryUsesGSIDescending(t *testing.T) {
	d := NewDynamo(nil, "dubstudio-takes", "dubstudio-clips", "dubstudio-players")
	q := d.LeaderboardQuery("tos-bridge", 0)
	if *q.IndexName != IndexByClip || *q.ScanIndexForward || *q.Limit != 10 || *q.KeyConditionExpression != "clip_id = :pk" {
		t.Errorf("by_clip query wrong: %+v", q)
	}
	g := d.LeaderboardQuery("", 500)
	if *g.IndexName != IndexGlobalBoard || *g.ScanIndexForward || *g.Limit != 100 {
		t.Errorf("global query wrong: %+v", g)
	}
	if v := g.ExpressionAttributeValues[":pk"].(*types.AttributeValueMemberS).Value; v != "ALL" {
		t.Errorf("board pk = %q", v)
	}
}

func TestTakeMarshalHasGSIKeys(t *testing.T) {
	item, err := attributevalue.MarshalMap(model.Take{TakeID: "x", ClipID: "c", Overall: 42, Board: model.BoardAll})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := item["overall"].(*types.AttributeValueMemberN); !ok {
		t.Errorf("overall must be N, got %T", item["overall"])
	}
	if s, ok := item["board"].(*types.AttributeValueMemberS); !ok || s.Value != "ALL" {
		t.Errorf("board must be S ALL, got %v", item["board"])
	}
	if _, ok := item["clip_id"].(*types.AttributeValueMemberS); !ok {
		t.Errorf("clip_id must be S")
	}
}
